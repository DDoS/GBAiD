module gbaid.dma;

import core.thread;

import gbaid.memory;
import gbaid.interrupt;
import gbaid.halt;
import gbaid.util;

public class DMAs {
    private MainMemory memory;
    private RAM ioRegisters;
    private InterruptHandler interruptHandler;
    private HaltHandler haltHandler;
    private Thread thread;
    private bool running = false;
    private int[4] sourceAddresses;
    private int[4] destinationAddresses;
    private int[4] wordCounts;
    private int[4] controls;
    private Timing[4] timings;
    private int triggered = 0;
    private int availableCycles = 0;

    public this(MainMemory memory, IORegisters ioRegisters, InterruptHandler interruptHandler, HaltHandler haltHandler) {
        this.memory = memory;
        this.ioRegisters = ioRegisters.getMonitored();
        this.interruptHandler = interruptHandler;
        this.haltHandler = haltHandler;

        ioRegisters.addMonitor(&onPostWrite, 0xBA, 2);
        ioRegisters.addMonitor(&onPostWrite, 0xC6, 2);
        ioRegisters.addMonitor(&onPostWrite, 0xD2, 2);
        ioRegisters.addMonitor(&onPostWrite, 0xDE, 2);
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
        if (thread !is null) {
            running = false;
            thread = null;
        }
    }

    public bool isRunning() {
        return running;
    }

    public void signalVBLANK() {
        triggerDMAs(Timing.VBLANK);
    }

    public void signalHBLANK() {
        triggerDMAs(Timing.HBLANK);
    }

    public void giveCycles(int cycles) {
        availableCycles += cycles;
    }

    private void takeCycles(int cycles) {
        while (availableCycles < cycles) {
            Thread.yield();
        }
        availableCycles -= cycles;
    }

    private void onPostWrite(Memory ioRegisters, int address, int shift, int mask, int oldControl, int newControl) {
        if (!(mask & 0xFFFF0000)) {
            return;
        }

        int channel = (address - 0xB8) / 0xC;
        controls[channel] = newControl >>> 16;
        timings[channel] = getTiming(channel, newControl);

        if (!checkBit(oldControl, 31) && checkBit(newControl, 31)) {
            sourceAddresses[channel] = formatSourceAddress(channel, ioRegisters.getInt(address - 8));
            destinationAddresses[channel] = formatDestinationAddress(channel, ioRegisters.getInt(address - 4));
            wordCounts[channel] = getWordCount(channel, newControl);
            triggerDMAs(Timing.IMMEDIATE);
        }
    }

    private void triggerDMAs(Timing timing) {
        foreach (int channel; 0 .. 4) {
            if (timings[channel] == timing) {
                triggered.setBit(channel, 1);
            }
        }
    }

    private void run() {
        while (running) {
            while (availableCycles <= 0) {
                Thread.yield();
            }
            // Halt if any of the DMAs are triggered
            haltHandler.dmaHalt(triggered != 0);
            foreach (int channel; 0 .. 4) {
                // Run the first triggered DMA with respect to priority
                if (triggered.checkBit(channel)) {
                    // Copy a single word
                    takeCycles(3);
                    copyWord(channel);
                    // Finalize the DMA when the transfer is complete
                    if (wordCounts[channel] <= 0) {
                        takeCycles(3);
                        finalizeDMA(channel);
                    }
                    break;
                }
            }
        }
    }

    private void finalizeDMA(int channel) {
        int control = controls[channel];

        int dmaAddress = channel * 0xC + 0xB8;
        if (checkBit(control, 9)) {
            // Repeating DMA
            wordCounts[channel] = getWordCount(channel, ioRegisters.getInt(dmaAddress));
            if (getBits(control, 5, 6) == 3) {
                destinationAddresses[channel] = formatDestinationAddress(channel, ioRegisters.getInt(dmaAddress - 4));
            }
        } else {
            // Clear the DMA enable bit
            ioRegisters.setShort(dmaAddress + 2, cast(short) (control & 0x7FFF));
            timings[channel] = Timing.DISABLED;
        }
        // Trigger DMA end interrupt if enabled
        if (checkBit(control, 14)) {
            interruptHandler.requestInterrupt(InterruptSource.DMA_0 + channel);
        }

        triggered.setBit(channel, 0);
    }

    private void copyWord(int channel) {
        int control = controls[channel];

        int type = void;
        int sourceAddressControl = getBits(control, 7, 8);
        int destinationAddressControl = void;
        switch (timings[channel]) with(Timing) {
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
                type = getBit(control, 10);
                destinationAddressControl = getBits(control, 5, 6);
        }
        int increment = type ? 4 : 2;

        if (type) {
            memory.setInt(destinationAddresses[channel], memory.getInt(sourceAddresses[channel]));
        } else {
            memory.setShort(destinationAddresses[channel], memory.getShort(sourceAddresses[channel]));
        }

        modifyAddress(sourceAddresses[channel], sourceAddressControl, increment);
        modifyAddress(destinationAddresses[channel], destinationAddressControl, increment);
        wordCounts[channel]--;
    }
}

/*
debug (outputDMAs) writefln(
    "DMA %s %08x%s to %08x%s, %04x bytes, timing %s",
    channel,
    sourceAddresses[channel],
    sourceAddressControl == 0 ? "++" : sourceAddressControl == 1 ? "--" : "  ",
    destinationAddresses[channel],
    destinationAddressControl == 0 || destinationAddressControl == 3 ? "++" : destinationAddressControl == 1 ? "--" : "  ",
    wordCounts[channel] * increment,
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

private int formatSourceAddress(int channel, int sourceAddress) {
    if (channel == 0) {
        return sourceAddress & 0x7FFFFFF;
    }
    return sourceAddress & 0xFFFFFFF;
}

private int formatDestinationAddress(int channel, int destinationAddress) {
    if (channel == 3) {
        return destinationAddress & 0xFFFFFFF;
    }
    return destinationAddress & 0x7FFFFFF;
}

private int getWordCount(int channel, int fullControl) {
    if (getBits(fullControl, 28, 29) == 3) {
        if (channel == 1 || channel == 2) {
            return 0x4;
        } else if (channel == 3) {
            // TODO: implement video capture
            return 0x0;
        }
    }
    if (channel < 3) {
        fullControl &= 0x3FFF;
        if (fullControl == 0) {
            return 0x4000;
        }
        return fullControl;
    }
    fullControl &= 0xFFFF;
    if (fullControl == 0) {
        return 0x10000;
    }
    return fullControl;
}

private Timing getTiming(int channel, int fullControl) {
    if (!checkBit(fullControl, 31)) {
        return Timing.DISABLED;
    }
    final switch (getBits(fullControl, 28, 29)) {
        case 0:
            return Timing.IMMEDIATE;
        case 1:
            return Timing.VBLANK;
        case 2:
            return Timing.HBLANK;
        case 3:
            final switch (channel) {
                case 1:
                case 2:
                    return Timing.SOUND_FIFO;
                case 3:
                    return Timing.VIDEO_CAPTURE;
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
