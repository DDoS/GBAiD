module gbaid.gba.dma;

import gbaid.util;

import gbaid.gba.memory;
import gbaid.gba.interrupt;
import gbaid.gba.halt;

public class DMAs {
    private MemoryBus* memory;
    private IoRegisters* ioRegisters;
    private InterruptHandler interruptHandler;
    private HaltHandler haltHandler;
    mixin privateFields!(int, "sourceAddress", 0, 4);
    mixin privateFields!(int, "destinationAddress", 0, 4);
    mixin privateFields!(int, "wordCount", 0, 4);
    mixin privateFields!(int, "control", 0, 4);
    mixin privateFields!(Timing, "timing", Timing.DISABLED, 4);
    private int triggered = 0;

    public this(MemoryBus* memory, IoRegisters* ioRegisters, InterruptHandler interruptHandler, HaltHandler haltHandler) {
        this.memory = memory;
        this.ioRegisters = ioRegisters;
        this.interruptHandler = interruptHandler;
        this.haltHandler = haltHandler;

        ioRegisters.setPostWriteMonitor!0xB8(&onPostWrite!0);
        ioRegisters.setPostWriteMonitor!0xC4(&onPostWrite!1);
        ioRegisters.setPostWriteMonitor!0xD0(&onPostWrite!2);
        ioRegisters.setPostWriteMonitor!0xDC(&onPostWrite!3);
    }

    public alias signalVBLANK = triggerDMAs!(Timing.VBLANK);
    public alias signalHBLANK = triggerDMAs!(Timing.HBLANK);

    public alias signalSoundQueueA = triggerDMAs!(Timing.SOUND_QUEUE_A);
    public alias signalSoundQueueB = triggerDMAs!(Timing.SOUND_QUEUE_B);

    private void onPostWrite(int channel)
            (IoRegisters* ioRegisters, int address, int shift, int mask, int oldControl, int newControl) {
        if (!(mask & 0xFFFF0000)) {
            return;
        }

        control!channel = newControl >>> 16;
        auto destAddress = ioRegisters.getUnMonitored!int(address - 4).formatDestinationAddress!channel();
        timing!channel = newControl.getTiming!channel(destAddress);

        if (!checkBit(oldControl, 31) && checkBit(newControl, 31)) {
            sourceAddress!channel = ioRegisters.getUnMonitored!int(address - 8).formatSourceAddress!channel();
            destinationAddress!channel = destAddress;
            wordCount!channel = newControl.getWordCount!channel();
            triggerDMAs!(Timing.IMMEDIATE);
        }
    }

    private void triggerDMAs(Timing trigger)() {
        if (timing!0 == trigger) {
            triggered |= 1 << 0;
            haltHandler.dmaHalt(true);
        }
        if (timing!1 == trigger) {
            triggered |= 1 << 1;
            haltHandler.dmaHalt(true);
        }
        if (timing!2 == trigger) {
            triggered |= 1 << 2;
            haltHandler.dmaHalt(true);
        }
        if (timing!3 == trigger) {
            triggered |= 1 << 3;
            haltHandler.dmaHalt(true);
        }
    }

    public size_t emulate(size_t cycles) {
        // Check if any of the DMAs are triggered
        if (triggered == 0) {
            // If not then discard all the cycles
            return 0;
        }
        // Run the DMAs with respect to priority
        if (updateChannel!0(cycles)) {
            // More cycles left, move to down in priority
            if (updateChannel!1(cycles)) {
                // More cycles left, move to down in priority
                if (updateChannel!2(cycles)) {
                    // More cycles left, move to down in priority
                    updateChannel!3(cycles);
                    // Out of DMAs to run, waste all the cycles left
                    return 0;
                }
            }
        }
        return cycles;
    }

    private bool updateChannel(int channel)(ref size_t cycles) {
        // Only run if triggered and enabled
        if (!(triggered & (1 << channel)) || !control!channel.checkBit(15)) {
            // No transfer to do
            return true;
        }
        // Use 3 cycles per word and for the finalization step
        while (cycles >= 3) {
            // Take the cycles
            cycles -= 3;
            if (wordCount!channel > 0) {
                // Copy a single word
                copyWord!channel();
            } else {
                // Finalize the DMA when the transfer is complete
                finalizeDMA!channel();
                // The transfer is complete
                return true;
            }
        }
        // The transfer is incomplete because we ran out of cycles
        return false;
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
            // Only keep the trigger for repeating DMAs if the timing is immediate
            if (timing!channel != Timing.IMMEDIATE) {
                haltHandler.dmaHalt((triggered &= ~(1 << channel)) != 0);
            }
        } else {
            // Clear the DMA enable bit
            ioRegisters.setUnMonitored!short(dmaAddress + 2, cast(short) (control & 0x7FFF));
            timing!channel = Timing.DISABLED;
            // Always clear the trigger for single-run DMAs
            haltHandler.dmaHalt((triggered &= ~(1 << channel)) != 0);
        }
        // Trigger DMA end interrupt if enabled
        if (checkBit(control, 14)) {
            interruptHandler.requestInterrupt(InterruptSource.DMA_0 + channel);
        }
    }

    private void copyWord(int channel)() {
        int control = control!channel;

        int type = void;
        int sourceAddressControl = control.getBits(7, 8);
        int destinationAddressControl = void;
        switch (timing!channel) with(Timing) {
            case DISABLED:
                assert (0);
            case SOUND_QUEUE_A:
            case SOUND_QUEUE_B:
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

private Timing getTiming(int channel)(int fullControl, int destinationAddress) {
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
                switch (destinationAddress) {
                    case 0x40000A0:
                        return Timing.SOUND_QUEUE_A;
                    case 0x40000A4:
                        return Timing.SOUND_QUEUE_B;
                    default:
                        return Timing.DISABLED;
                }
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
    SOUND_QUEUE_A,
    SOUND_QUEUE_B,
    VIDEO_CAPTURE
}

private enum ChannelRunResult {
    DISABLED, NOT_ENOUGH_CYCLES, RAN
}
