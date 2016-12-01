module gbaid.dma;

import gbaid.memory;
import gbaid.interrupt;
import gbaid.halt;
import gbaid.util;

public class DMAs {
    private MainMemory memory;
    private RAM ioRegisters;
    private InterruptHandler interruptHandler;
    private HaltHandler haltHandler;
    private bool interruptDMA = false;
    private int[4] sourceAddresses = new int[4];
    private int[4] destinationAddresses = new int[4];
    private int[4] wordCounts = new int[4];
    private int[4] controls = new int[4];
    private Timing[4] timings = new Timing[4];
    private int incomplete = 0;

    public this(MainMemory memory, IORegisters ioRegisters, InterruptHandler interruptHandler, HaltHandler haltHandler) {
        this.memory = memory;
        this.ioRegisters = ioRegisters.getMonitored();
        this.interruptHandler = interruptHandler;
        this.haltHandler = haltHandler;

        ioRegisters.addMonitor(&onPostWrite, 0xBA, 2);
        ioRegisters.addMonitor(&onPostWrite, 0xC6, 2);
        ioRegisters.addMonitor(&onPostWrite, 0xD2, 2);
        ioRegisters.addMonitor(&onPostWrite, 0xDE, 2);

        haltHandler.setHaltTask(&dmaTask);
    }

    public void signalVBLANK() {
        updateDMAs(Timing.VBLANK);
    }

    public void signalHBLANK() {
        updateDMAs(Timing.HBLANK);
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
            updateDMAs(Timing.IMMEDIATE);
        }
    }

    private void updateDMAs(Timing timing) {
        foreach (int channel; 0 .. 4) {
            if (timings[channel] == timing) {
                setBit(incomplete, channel, 1);
            }
        }
        if (!incomplete) {
            return;
        }
        haltHandler.dmaHalt(true);
        interruptDMA = true;
    }

    private bool dmaTask() {
        bool ran = cast(bool) incomplete;
        while (incomplete) {
            foreach (int channel; 0 .. 4) {
                if (checkBit(incomplete, channel)) {
                    interruptDMA = false;
                    if (!runDMA(channel)) {
                        break;
                    }
                }
            }
        }
        haltHandler.dmaHalt(false);
        return ran;
    }

    private bool runDMA(int channel) {
        int control = controls[channel];

        if (!doCopy(channel, control)) {
            return false;
        }

        int dmaAddress = channel * 0xC + 0xB8;
        if (checkBit(control, 9)) {
            wordCounts[channel] = getWordCount(channel, ioRegisters.getInt(dmaAddress));
            if (getBits(control, 5, 6) == 3) {
                destinationAddresses[channel] = formatDestinationAddress(channel, ioRegisters.getInt(dmaAddress - 4));
            }
        } else {
            ioRegisters.setShort(dmaAddress + 2, cast(short) (control & 0x7FFF));
            timings[channel] = Timing.DISABLED;
        }

        if (checkBit(control, 14)) {
            interruptHandler.requestInterrupt(InterruptSource.DMA_0 + channel);
        }

        return true;
    }

    private bool doCopy(int channel, int control) {
        int startTiming = getBits(control, 12, 13);

        int type = void;
        int destinationAddressControl = void;
        if (startTiming == 3) {
            if (channel == 1 || channel == 2) {
                type = 1;
                destinationAddressControl = 2;
            } else if (channel == 3) {
                // TODO: implement video capture
            }
        } else {
            type = getBit(control, 10);
            destinationAddressControl = getBits(control, 5, 6);
        }

        int sourceAddressControl = getBits(control, 7, 8);
        int increment = type ? 4 : 2;

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

        while (wordCounts[channel] > 0) {
            if (interruptDMA) {
                interruptDMA = false;
                return false;
            }

            if (type) {
                memory.setInt(destinationAddresses[channel], memory.getInt(sourceAddresses[channel]));
            } else {
                memory.setShort(destinationAddresses[channel], memory.getShort(sourceAddresses[channel]));
            }

            modifyAddress(sourceAddresses[channel], sourceAddressControl, increment);
            modifyAddress(destinationAddresses[channel], destinationAddressControl, increment);
            wordCounts[channel]--;
        }

        setBit(incomplete, channel, 0);

        return true;
    }

    private static void modifyAddress(ref int address, int control, int amount) {
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

    private static int formatSourceAddress(int channel, int sourceAddress) {
        if (channel == 0) {
            return sourceAddress & 0x7FFFFFF;
        }
        return sourceAddress & 0xFFFFFFF;
    }

    private static int formatDestinationAddress(int channel, int destinationAddress) {
        if (channel == 3) {
            return destinationAddress & 0xFFFFFFF;
        }
        return destinationAddress & 0x7FFFFFF;
    }

    private static int getWordCount(int channel, int fullControl) {
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

    private static Timing getTiming(int channel, int fullControl) {
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

    private static enum Timing {
        DISABLED,
        IMMEDIATE,
        VBLANK,
        HBLANK,
        SOUND_FIFO,
        VIDEO_CAPTURE
    }
}
