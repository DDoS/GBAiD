module gbaid.gba.dma;

import std.meta : AliasSeq;

import gbaid.util;

import gbaid.gba.io;
import gbaid.gba.memory;
import gbaid.gba.interrupt;
import gbaid.gba.halt;

public class DMAs {
    private MemoryBus* memory;
    private IoRegisters* ioRegisters;
    private InterruptHandler interruptHandler;
    private HaltHandler haltHandler;
    mixin declareFields!(int, true, "srcAddress", 0, 4);
    mixin declareFields!(int, true, "destAddress", 0, 4);
    mixin declareFields!(int, true, "_wordCount", 0, 4);
    mixin declareFields!(int, true, "control", 0, 4);
    mixin declareFields!(Timing, true, "timing", Timing.DISABLED, 4);
    mixin declareFields!(int, true, "internSrcAddress", 0, 4);
    mixin declareFields!(int, true, "internDestAddress", 0, 4);
    mixin declareFields!(int, true, "internWordCount", 0, 4);
    private int triggered = 0;

    public this(MemoryBus* memory, IoRegisters* ioRegisters, InterruptHandler interruptHandler, HaltHandler haltHandler) {
        this.memory = memory;
        this.ioRegisters = ioRegisters;
        this.interruptHandler = interruptHandler;
        this.haltHandler = haltHandler;

        ioRegisters.mapAddress(0xB0, &srcAddress!0, 0x07FFFFFF, 0);
        ioRegisters.mapAddress(0xB4, &destAddress!0, 0x07FFFFFF, 0).postWriteMonitor(&onDestPostWrite!0);
        ioRegisters.mapAddress(0xB8, &_wordCount!0, 0x3FFF, 0);
        ioRegisters.mapAddress(0xB8, &control!0, 0xFFF0, 16).postWriteMonitor(&onControlPostWrite!0);

        ioRegisters.mapAddress(0xBC, &srcAddress!1, 0x0FFFFFFF, 0);
        ioRegisters.mapAddress(0xC0, &destAddress!1, 0x07FFFFFF, 0).postWriteMonitor(&onDestPostWrite!1);
        ioRegisters.mapAddress(0xC4, &_wordCount!1, 0x3FFF, 0);
        ioRegisters.mapAddress(0xC4, &control!1, 0xFFF0, 16).postWriteMonitor(&onControlPostWrite!1);

        ioRegisters.mapAddress(0xC8, &srcAddress!2, 0x0FFFFFFF, 0);
        ioRegisters.mapAddress(0xCC, &destAddress!2, 0x07FFFFFF, 0).postWriteMonitor(&onDestPostWrite!2);
        ioRegisters.mapAddress(0xD0, &_wordCount!2, 0x3FFF, 0);
        ioRegisters.mapAddress(0xD0, &control!2, 0xFFF0, 16).postWriteMonitor(&onControlPostWrite!2);

        ioRegisters.mapAddress(0xD4, &srcAddress!3, 0x0FFFFFFF, 0);
        ioRegisters.mapAddress(0xD8, &destAddress!3, 0x0FFFFFFF, 0).postWriteMonitor(&onDestPostWrite!3);
        ioRegisters.mapAddress(0xDC, &_wordCount!3, 0xFFFF, 0);
        ioRegisters.mapAddress(0xDC, &control!3, 0xFFF0, 16).postWriteMonitor(&onControlPostWrite!3);
    }

    public alias signalVBLANK = triggerDMAs!(Timing.VBLANK);
    public alias signalHBLANK = triggerDMAs!(Timing.HBLANK);

    public alias signalSoundQueueA = triggerDMAs!(Timing.SOUND_QUEUE_A);
    public alias signalSoundQueueB = triggerDMAs!(Timing.SOUND_QUEUE_B);

    private void onDestPostWrite(int channel)(int mask, int oldDest, int newDest) {
        // Update the timing (this is a special case for SOUND_QUEUE_X timings, which depend on the destination)
        updateTiming!channel();
    }

    private void onControlPostWrite(int channel)(int mask, int oldControl, int newControl) {
        updateTiming!channel();
        // If the DMA enable bit goes high, reload the addresses and word count, and signal the immediate timing
        if (mask.checkBit(15) && !oldControl.checkBit(15) && newControl.checkBit(15)) {
            internSrcAddress!channel = srcAddress!channel;
            internDestAddress!channel = destAddress!channel;
            internWordCount!channel = wordCount!channel;
            triggerDMAs!(Timing.IMMEDIATE);
        }
    }

    private void updateTiming(int channel)() {
        if (!control!channel.checkBit(15)) {
            timing!channel = Timing.DISABLED;
            return;
        }
        final switch (control!channel.getBits(12, 13)) {
            case 0:
                timing!channel = Timing.IMMEDIATE;
                break;
            case 1:
                timing!channel = Timing.VBLANK;
                break;
            case 2:
                timing!channel = Timing.HBLANK;
                break;
            case 3: {
                static if (channel == 1 || channel == 2) {
                    switch (destAddress!channel) {
                        case 0x40000A0:
                            timing!channel =  Timing.SOUND_QUEUE_A;
                            break;
                        case 0x40000A4:
                            timing!channel =  Timing.SOUND_QUEUE_B;
                            break;
                        default:
                            timing!channel = Timing.DISABLED;
                    }
                } else static if (channel == 3) {
                    timing!channel = Timing.VIDEO_CAPTURE;
                } else {
                    throw new Error("Can't use special DMA timing for channel 0");
                }
            }
        }
    }

    @property
    private int wordCount(int channel)() {
        if (control!channel.getBits(12, 13) == 3) {
            static if (channel == 1 || channel == 2) {
                return 0x4;
            } else static if (channel == 3) {
                // TODO: implement video capture
                throw new Error("Unimplemented: video capture DMAs");
            } else {
                throw new Error("Can't use special DMA timing for channel 0");
            }
        }
        if (_wordCount!channel == 0) {
            static if (channel == 3) {
                return 0x10000;
            } else {
                return 0x4000;
            }
        }
        return _wordCount!channel;
    }

    private void triggerDMAs(Timing trigger)() {
        foreach (channel; AliasSeq!(0, 1, 2, 3)) {
            if (timing!channel == trigger) {
                triggered.setBit(channel, 1);
            }
        }
        // Stop the CPU if any transfer has been started
        haltHandler.dmaHalt(triggered != 0);
    }

    public size_t emulate(size_t cycles) {
        // Check if any of the DMAs are triggered
        if (triggered != 0) {
            // Run the DMAs with respect to priority
            foreach (channel; AliasSeq!(0, 1, 2, 3)) {
                if (updateChannel!channel(cycles)) {
                    static if (channel == 3) {
                        // Out of DMAs to run, waste all the cycles left
                        cycles = 0;
                    }
                } else {
                    break;
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
            if (internWordCount!channel > 0) {
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
            // Repeating DMA, reload the word count
            internWordCount!channel = wordCount!channel;
            if (control!channel.getBits(5, 6) == 3) {
                // We also reload the destination address, and we must also check for timing changes
                internDestAddress!channel = destAddress!channel;
                updateTiming!channel();
            }
            // Clear the trigger is the DMA timing isn't immediate
            if (timing!channel != Timing.IMMEDIATE) {
                triggered.setBit(channel, 0);
            }
        } else {
            // Clear the DMA enable bit
            control!channel.setBit(15, 0);
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
        int srcAddressControl = control!channel.getBits(7, 8);
        int destAddressControl = void;
        switch (timing!channel) with (Timing) {
            case DISABLED:
                throw new Error("DMA channel is disabled");
            case SOUND_QUEUE_A:
            case SOUND_QUEUE_B:
                type = 1;
                destAddressControl = 2;
                break;
            case VIDEO_CAPTURE:
                // TODO: implement video capture
                throw new Error("Unimplemented: video capture DMAs");
            default:
                type = control!channel.getBit(10);
                destAddressControl = control!channel.getBits(5, 6);
        }
        int increment = type ? 4 : 2;

        if (type) {
            memory.set!int(internDestAddress!channel, memory.get!int(internSrcAddress!channel));
        } else {
            memory.set!short(internDestAddress!channel, memory.get!short(internSrcAddress!channel));
        }

        internSrcAddress!channel.modifyAddress(srcAddressControl, increment);
        internDestAddress!channel.modifyAddress(destAddressControl, increment);
        internWordCount!channel--;
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

private enum Timing {
    DISABLED,
    IMMEDIATE,
    VBLANK,
    HBLANK,
    SOUND_QUEUE_A,
    SOUND_QUEUE_B,
    VIDEO_CAPTURE
}
