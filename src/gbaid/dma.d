module gbaid.dma;

import core.atomic : MemoryOrder, atomicLoad, atomicOp;
import core.thread;

import gbaid.cycle;
import gbaid.memory;
import gbaid.interrupt;
import gbaid.halt;
import gbaid.util;

public class DMAs {
    private CycleSharer4* cycleSharer;
    private MemoryBus* memory;
    private IoRegisters* ioRegisters;
    private InterruptHandler interruptHandler;
    private HaltHandler haltHandler;
    private Thread thread;
    private bool running = false;
    mixin privateFields!(int, "sourceAddress", 0, 4);
    mixin privateFields!(int, "destinationAddress", 0, 4);
    mixin privateFields!(int, "wordCount", 0, 4);
    mixin privateFields!(int, "control", 0, 4);
    mixin privateFields!(Timing, "timing", Timing.DISABLED, 4);
    private shared int triggered = 0;

    public this(CycleSharer4* cycleSharer, MemoryBus* memory, IoRegisters* ioRegisters,
            InterruptHandler interruptHandler, HaltHandler haltHandler) {
        this.cycleSharer = cycleSharer;
        this.memory = memory;
        this.ioRegisters = ioRegisters;
        this.interruptHandler = interruptHandler;
        this.haltHandler = haltHandler;

        ioRegisters.setPostWriteMonitor!0xB8(&onPostWrite!0);
        ioRegisters.setPostWriteMonitor!0xC4(&onPostWrite!1);
        ioRegisters.setPostWriteMonitor!0xD0(&onPostWrite!2);
        ioRegisters.setPostWriteMonitor!0xDC(&onPostWrite!3);
    }

    public void start() {
        if (thread is null) {
            thread = new Thread(&run);
            thread.name = "DMAs";
            running = true;
            thread.start();
        }
    }

    public void stop() {
        running = false;
        if (thread !is null) {
            thread.join(false);
            thread = null;
        }
    }

    public bool isRunning() {
        return running;
    }

    public void signalVBLANK() {
        triggerDMAs!(Timing.VBLANK);
    }

    public void signalHBLANK() {
        triggerDMAs!(Timing.HBLANK);
    }

    private void onPostWrite(int channel)
            (IoRegisters* ioRegisters, int address, int shift, int mask, int oldControl, int newControl) {
        if (!(mask & 0xFFFF0000)) {
            return;
        }

        control!channel = newControl >>> 16;
        timing!channel = newControl.getTiming!channel();

        if (!checkBit(oldControl, 31) && checkBit(newControl, 31)) {
            sourceAddress!channel = ioRegisters.getUnMonitored!int(address - 8).formatSourceAddress!channel();
            destinationAddress!channel = ioRegisters.getUnMonitored!int(address - 4).formatDestinationAddress!channel();
            wordCount!channel = newControl.getWordCount!channel();
            triggerDMAs!(Timing.IMMEDIATE);
        }
    }

    private void triggerDMAs(Timing trigger)() {
        if (timing!0 == trigger) {
            triggered.atomicOp!"|="(1 << 0);
            haltHandler.dmaHalt(true);
        }
        if (timing!1 == trigger) {
            triggered.atomicOp!"|="(1 << 1);
            haltHandler.dmaHalt(true);
        }
        if (timing!2 == trigger) {
            triggered.atomicOp!"|="(1 << 2);
            haltHandler.dmaHalt(true);
        }
        if (timing!3 == trigger) {
            triggered.atomicOp!"|="(1 << 3);
            haltHandler.dmaHalt(true);
        }
    }

    private void run() {
        scope (exit) {
            cycleSharer.hasStopped!2();
        }
        while (running) {
            // Check if any of the DMAs are triggered
            if (triggered.atomicLoad!(MemoryOrder.raw) == 0) {
                cycleSharer.wasteCycles!2();
                continue;
            }
            // Run the triggered DMAs with respect to priority
            if (updateChannel!0()) {
                continue;
            }
            if (updateChannel!1()) {
                continue;
            }
            if (updateChannel!2()) {
                continue;
            }
            updateChannel!3();
        }
    }

    private bool updateChannel(int channel)() {
        // Only run if triggered
        if (!triggered.atomicOp!"&"(1 << channel)) {
            return false;
        }
        // Copy a single word
        cycleSharer.takeCycles!2(3);
        copyWord!channel();
        // Finalize the DMA when the transfer is complete
        if (wordCount!channel <= 0) {
            cycleSharer.takeCycles!2(3);
            finalizeDMA!channel();
        }
        return true;
    }

    private void finalizeDMA(int channel)() {
        int control = control!channel;

        int dmaAddress = channel * 0xC + 0xB8;
        if (checkBit(control, 9)) {
            // Repeating DMA
            wordCount!channel = ioRegisters.getUnMonitored!int(dmaAddress).getWordCount!channel();
            if (getBits(control, 5, 6) == 3) {
                destinationAddress!channel = ioRegisters.getUnMonitored!int(dmaAddress - 4).formatDestinationAddress!channel();
            }
        } else {
            // Clear the DMA enable bit
            ioRegisters.setUnMonitored!short(dmaAddress + 2, cast(short) (control & 0x7FFF));
            timing!channel = Timing.DISABLED;
        }
        // Trigger DMA end interrupt if enabled
        if (checkBit(control, 14)) {
            interruptHandler.requestInterrupt(InterruptSource.DMA_0 + channel);
        }

        haltHandler.dmaHalt(triggered.atomicOp!"&="(~(1 << channel)) != 0);
    }

    private void copyWord(int channel)() {
        int control = control!channel;

        int type = void;
        int sourceAddressControl = control.getBits(7, 8);
        int destinationAddressControl = void;
        switch (timing!channel) with(Timing) {
            case DISABLED:
                assert (0);
            case SOUND_FIFO:
                type = 1;
                destinationAddressControl = 2;
                break;
            case VIDEO_CAPTURE:
                // TODO: implement video capture
                assert (0);
            default:
                type = control.getBit(10);
                destinationAddressControl = getBits(control, 5, 6);
        }
        int increment = type ? 4 : 2;

        if (type) {
            memory.set!int(destinationAddress!channel, memory.get!int(sourceAddress!channel));
        } else {
            memory.set!short(destinationAddress!channel, memory.get!short(sourceAddress!channel));
        }

        sourceAddress!channel.modifyAddress(sourceAddressControl, increment);
        destinationAddress!channel.modifyAddress(destinationAddressControl, increment);
        wordCount!channel--;
    }
}

/*
debug (outputDMAs) writefln(
    "DMA %s %08x%s to %08x%s, %04x bytes, timing %s",
    channel,
    sourceAddress!channel,
    sourceAddressControl == 0 ? "++" : sourceAddressControl == 1 ? "--" : "  ",
    destinationAddress!channel,
    destinationAddressControl == 0 || destinationAddressControl == 3 ? "++" : destinationAddressControl == 1 ? "--" : "  ",
    wordCount!channel * increment,
    getTiming(channel, control << 16)
);
*/

private void modifyAddress(ref int address, int control, int amount) {
    final switch (control) {
        case 0:
        case 3:
            address += amount;
            break;
        case 1:
            address -= amount;
            break;
        case 2:
            break;
    }
}

private int formatSourceAddress(int channel)(int sourceAddress) {
    static if (channel == 0) {
        return sourceAddress & 0x7FFFFFF;
    } else {
        return sourceAddress & 0xFFFFFFF;
    }
}

private int formatDestinationAddress(int channel)(int destinationAddress) {
    static if (channel == 3) {
        return destinationAddress & 0xFFFFFFF;
    } else {
        return destinationAddress & 0x7FFFFFF;
    }
}

private int getWordCount(int channel)(int fullControl) {
    if (fullControl.getBits(28, 29) == 3) {
        static if (channel == 1 || channel == 2) {
            return 0x4;
        } else static if (channel == 3) {
            // TODO: implement video capture
            return 0x0;
        } else {
            assert (0);
        }
    }
    static if (channel < 3) {
        fullControl &= 0x3FFF;
        if (fullControl == 0) {
            return 0x4000;
        }
        return fullControl;
    } else {
        fullControl &= 0xFFFF;
        if (fullControl == 0) {
            return 0x10000;
        }
        return fullControl;
    }
}

private Timing getTiming(int channel)(int fullControl) {
    if (!fullControl.checkBit(31)) {
        return Timing.DISABLED;
    }
    final switch (fullControl.getBits(28, 29)) {
        case 0:
            return Timing.IMMEDIATE;
        case 1:
            return Timing.VBLANK;
        case 2:
            return Timing.HBLANK;
        case 3:
            static if (channel == 1 || channel == 2) {
                return Timing.SOUND_FIFO;
            } static if (channel == 3) {
                return Timing.VIDEO_CAPTURE;
            } else {
                assert (0);
            }
    }
}

private enum Timing {
    DISABLED,
    IMMEDIATE,
    VBLANK,
    HBLANK,
    SOUND_FIFO,
    VIDEO_CAPTURE
}
