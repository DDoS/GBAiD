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
    mixin declareFields!(int, true, "sourceAddress", 0, 4);
    mixin declareFields!(int, true, "destinationAddress", 0, 4);
    mixin declareFields!(int, true, "wordCount", 0, 4);
    mixin declareFields!(int, true, "control", 0, 4);
    mixin declareFields!(Timing, true, "timing", Timing.DISABLED, 4);
    private int triggered = 0;

    public this(MemoryBus* memory, IoRegisters* ioRegisters, InterruptHandler interruptHandler, HaltHandler haltHandler) {
        this.memory = memory;
        this.ioRegisters = ioRegisters;
        this.interruptHandler = interruptHandler;
        this.haltHandler = haltHandler;

        ioRegisters.setPostWriteMonitor!0xB4(&onDestinationPostWrite!0);
        ioRegisters.setPostWriteMonitor!0xB8(&onControlPostWrite!0);

        ioRegisters.setPostWriteMonitor!0xC0(&onDestinationPostWrite!1);
        ioRegisters.setPostWriteMonitor!0xC4(&onControlPostWrite!1);

        ioRegisters.setPostWriteMonitor!0xCC(&onDestinationPostWrite!2);
        ioRegisters.setPostWriteMonitor!0xD0(&onControlPostWrite!2);

        ioRegisters.setPostWriteMonitor!0xD8(&onDestinationPostWrite!3);
        ioRegisters.setPostWriteMonitor!0xDC(&onControlPostWrite!3);
    }

    public alias signalVBLANK = triggerDMAs!(Timing.VBLANK);
    public alias signalHBLANK = triggerDMAs!(Timing.HBLANK);

    public alias signalSoundQueueA = triggerDMAs!(Timing.SOUND_QUEUE_A);
    public alias signalSoundQueueB = triggerDMAs!(Timing.SOUND_QUEUE_B);

    private void onDestinationPostWrite(int channel)
            (IoRegisters* ioRegisters, int address, int shift, int mask, int oldDestination, int newDestination) {
        // Update the timing (this is a special case for SOUND_QUEUE_X timings)
        auto fullControl = ioRegisters.getUnMonitored!int(address + 4);
        timing!channel = fullControl.getTiming!channel(newDestination.formatDestinationAddress!channel());
    }

    private void onControlPostWrite(int channel)
            (IoRegisters* ioRegisters, int address, int shift, int mask, int oldControl, int newControl) {
        // Ignore writes only on the word count
        if (!(mask & 0xFFFF0000)) {
            return;
        }
        // Update the control bits and the timing
        control!channel = newControl >>> 16;
        auto destAddress = ioRegisters.getUnMonitored!int(address - 4).formatDestinationAddress!channel();
        timing!channel = newControl.getTiming!channel(destAddress);
        // If the DMA enable bit goes high, reload the addresses and word count, and signal the immediate timing
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
        }
        if (timing!1 == trigger) {
            triggered |= 1 << 1;
        }
        if (timing!2 == trigger) {
            triggered |= 1 << 2;
        }
        if (timing!3 == trigger) {
            triggered |= 1 << 3;
        }
        // Stop the CPU if any transfer has been started
        haltHandler.dmaHalt(triggered != 0);
    }

    public size_t emulate(size_t cycles) {
        // Check if any of the DMAs are triggered
        if (triggered != 0) {
            // Run the DMAs with respect to priority
            if (updateChannel!0(cycles)) {
                // More cycles left, move to down in priority
                if (updateChannel!1(cycles)) {
                    // More cycles left, move to down in priority
                    if (updateChannel!2(cycles)) {
                        // More cycles left, move to down in priority
                        if (updateChannel!3(cycles)) {
                            // Out of DMAs to run, waste all the cycles left
                            cycles = 0;
                        }
                    }
                }
            }
        } else {
            // If not then discard all the cycles
            cycles = 0;
        }
        // Restart the CPU if all transfers are complete
        haltHandler.dmaHalt(triggered != 0);
        return cycles;
    }

    private bool updateChannel(int channel)(ref size_t cycles) {
        // Only run if triggered
        if (!triggered.checkBit(channel)) {
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
        int dmaAddress = channel * 0xC + 0xB8;
        if (control!channel.checkBit(9)) {
            // Repeating DMA, reload the word count, and optionally the destination address
            wordCount!channel = ioRegisters.getUnMonitored!int(dmaAddress).getWordCount!channel();
            if (control!channel.getBits(5, 6) == 3) {
                // If we reload the destination address, we must also check for timing changes
                destinationAddress!channel =
                        ioRegisters.getUnMonitored!int(dmaAddress - 4).formatDestinationAddress!channel();
                timing!channel = (control!channel << 16).getTiming!channel(destinationAddress!channel);
            }
            // Clear the trigger is the DMA timing isn't immediate
            if (timing!channel != Timing.IMMEDIATE) {
                triggered.setBit(channel, 0);
            }
        } else {
            // Clear the DMA enable bit
            control!channel.setBit(15, 0);
            ioRegisters.setUnMonitored!short(dmaAddress + 2, cast(short) control!channel);
            timing!channel = Timing.DISABLED;
            // Always clear the trigger for single-run DMAs
            triggered.setBit(channel, 0);
        }
        // Trigger DMA end interrupt if enabled
        if (control!channel.checkBit(14)) {
            interruptHandler.requestInterrupt(InterruptSource.DMA_0 + channel);
        }
    }

    private void copyWord(int channel)() {
        int type = void;
        int sourceAddressControl = control!channel.getBits(7, 8);
        int destinationAddressControl = void;
        switch (timing!channel) with (Timing) {
            case DISABLED:
                throw new Error("DMA channel is disabled");
            case SOUND_QUEUE_A:
            case SOUND_QUEUE_B:
                type = 1;
                destinationAddressControl = 2;
                break;
            case VIDEO_CAPTURE:
                // TODO: implement video capture
                throw new Error("Unimplemented: video capture DMAs");
            default:
                type = control!channel.getBit(10);
                destinationAddressControl = control!channel.getBits(5, 6);
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
        return sourceAddress & 0x7FFFFFE;
    } else {
        return sourceAddress & 0xFFFFFFE;
    }
}

private int formatDestinationAddress(int channel)(int destinationAddress) {
    static if (channel == 3) {
        return destinationAddress & 0xFFFFFFE;
    } else {
        return destinationAddress & 0x7FFFFFE;
    }
}

private int getWordCount(int channel)(int fullControl) {
    if (fullControl.getBits(28, 29) == 3) {
        static if (channel == 1 || channel == 2) {
            return 0x4;
        } else static if (channel == 3) {
            // TODO: implement video capture
            throw new Error("Unimplemented: video capture DMAs");
        } else {
            throw new Error("Can't use special DMA timing for channel 0");
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
        case 0: {
            return Timing.IMMEDIATE;
        }
        case 1: {
            return Timing.VBLANK;
        }
        case 2: {
            return Timing.HBLANK;
        }
        case 3: {
            static if (channel == 1 || channel == 2) {
                switch (destinationAddress) {
                    case 0x40000A0:
                        return Timing.SOUND_QUEUE_A;
                    case 0x40000A4:
                        return Timing.SOUND_QUEUE_B;
                    default:
                        break;
                }
                return Timing.DISABLED;
            } else static if (channel == 3) {
                return Timing.VIDEO_CAPTURE;
            } else {
                throw new Error("Can't use special DMA timing for channel 0");
            }
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
