module gbaid.memory;

import core.thread;
import core.time;

import std.string;
import std.file;

public immutable uint BYTES_PER_KIB = 1024;
public immutable uint BYTES_PER_MIB = BYTES_PER_KIB * BYTES_PER_KIB;

public interface Memory {
    ulong getCapacity();

    void[] getArray(uint address);

    void* getPointer(uint address);

    byte getByte(uint address);

    void setByte(uint address, byte b);

    short getShort(uint address);

    void setShort(uint address, short s);

    int getInt(uint address);

    void setInt(uint address, int i);
}

public class ROM : Memory {
    protected shared void[] memory;

    protected this(ulong capacity) {
        this.memory = new shared ubyte[capacity];
    }

    public this(void[] memory) {
        this(memory.length);
        this.memory[] = memory[];
    }

    public this(string file, uint maxSize) {
        try {
            this(read(file, maxSize));
        } catch (FileException ex) {
            throw new Exception("Cannot initialize ROM", ex);
        }
    }

    public ulong getCapacity() {
        return memory.length;
    }

    public void[] getArray(uint address) {
        return cast(void[]) memory[address .. $];
    }

    public void* getPointer(uint address) {
        return cast(void*) memory.ptr + address;
    }

    public byte getByte(uint address) {
        return (cast(byte[]) memory)[address];
    }

    public void setByte(uint address, byte b) {
    }

    public short getShort(uint address) {
        return (cast(short[]) memory)[address >> 1];
    }

    public void setShort(uint address, short s) {
    }

    public int getInt(uint address) {
        return (cast(int[]) memory)[address >> 2];
    }

    public void setInt(uint address, int i) {
    }
}

public class RAM : ROM {
    public this(ulong capacity) {
        super(capacity);
    }

    public this(void[] memory) {
        super(memory);
    }

    public this(string file, uint maxByteSize) {
        super(file, maxByteSize);
    }

    public override void setByte(uint address, byte b) {
        (cast(byte[]) memory)[address] = b;
    }

    public override void setShort(uint address, short s) {
        (cast(short[]) memory)[address >> 1] = s;
    }

    public override void setInt(uint address, int i) {
        (cast(int[]) memory)[address >> 2] = i;
    }
}

public class Flash : RAM { import std.stdio;
    private static immutable uint PANASONIC_64K_ID = 0x1B32;
    private static immutable uint SANYO_128K_ID = 0x1362;
    private static immutable uint DEVICE_ID_ADDRESS = 0x1;
    private static immutable uint FIRST_CMD_ADDRESS = 0x5555;
    private static immutable uint SECOND_CMD_ADDRESS = 0x2AAA;
    private static immutable uint FIRST_CMD_START_BYTE = 0xAA;
    private static immutable uint SECOND_CMD_START_BYTE = 0x55;
    private static immutable uint ID_MODE_START_CMD_BYTE = 0x90;
    private static immutable uint ID_MODE_STOP_CMD_BYTE = 0xF0;
    private static immutable uint ERASE_CMD_BYTE = 0x80;
    private static immutable uint ERASE_ALL_CMD_BYTE = 0x10;
    private static immutable uint ERASE_SECTOR_CMD_BYTE = 0x30;
    private static immutable uint WRITE_BYTE_CMD_BYTE = 0xA0;
    private static immutable uint SWITCH_BANK_CMD_BYTE = 0xB0;
    private static TickDuration WRITE_TIMEOUT = 10;
    private static TickDuration ERASE_SECTOR_TIMEOUT = 500;
    private static TickDuration ERASE_ALL_TIMEOUT = 500;
    private uint deviceID;
    private Mode mode = Mode.NORMAL;
    private uint cmdStage = 0;
    private bool timedCMD = false;
    private TickDuration cmdStartTime;
    private TickDuration cmdTimeOut;
    private uint eraseSectorTarget;
    private uint sectorOffset = 0;

    static this() {
        WRITE_TIMEOUT = TickDuration.from!"msecs"(10);
        ERASE_SECTOR_TIMEOUT = TickDuration.from!"msecs"(500);
        ERASE_ALL_TIMEOUT = TickDuration.from!"msecs"(500);
    }

    public this(ulong capacity) {
        super(capacity);
        idChip();
    }

    public this(void[] memory) {
        super(memory);
        idChip();
    }

    public this(string file, uint maxByteSize) {
        super(file, maxByteSize);
        idChip();
    }

    private void idChip() {
        if (memory.length > 64 * BYTES_PER_KIB) {
            deviceID = SANYO_128K_ID;
        } else {
            deviceID = PANASONIC_64K_ID;
        }
    }

    public override byte getByte(uint address) {
        if (mode == Mode.ID && address <= DEVICE_ID_ADDRESS) {
            return cast(byte) (deviceID >> ((address & 0b1) << 3));
        }
        return super.getByte(address + sectorOffset);
    }

    public override void setByte(uint address, byte b) {
        uint value = b & 0xFF;
        // Handle command time-outs
        if (timedCMD && TickDuration.currSystemTick >= cmdTimeOut) {
            endCMD();
        }
        // Handle commands completions
        switch (mode) {
            case Mode.ERASE_ALL:
                if (address == 0x0 && value == 0xFF) {
                    endCMD();
                }
                break;
            case Mode.ERASE_SECTOR:
                if (address == eraseSectorTarget && value == 0xFF) {
                    endCMD();
                }
                break;
            case Mode.WRITE_BYTE:
                super.setByte(address + sectorOffset, b);
                endCMD();
                break;
            default:
        }
        // Handle command initialization and execution
        if (address == FIRST_CMD_ADDRESS && value == FIRST_CMD_START_BYTE) {
            cmdStage = 1;
        } else if (cmdStage == 1) {
            if (address == SECOND_CMD_ADDRESS && value == SECOND_CMD_START_BYTE) {
                cmdStage = 2;
            } else {
                cmdStage = 0;
            }
        } else if (cmdStage == 2) {
            cmdStage = 0;
            // execute
            if (address == FIRST_CMD_ADDRESS) {
                switch (value) {
                    case ID_MODE_START_CMD_BYTE:
                        mode = Mode.ID;
                        break;
                    case ID_MODE_STOP_CMD_BYTE:
                        mode = Mode.NORMAL;
                        break;
                    case ERASE_CMD_BYTE:
                        mode = Mode.ERASE;
                        break;
                    case ERASE_ALL_CMD_BYTE:
                        if (mode == Mode.ERASE) {
                            mode = Mode.ERASE_ALL;
                            startTimedCMD(ERASE_ALL_TIMEOUT);
                            erase(0x0, cast(uint) getCapacity());
                        }
                        break;
                    case WRITE_BYTE_CMD_BYTE:
                        mode = Mode.WRITE_BYTE;
                        startTimedCMD(WRITE_TIMEOUT);
                        break;
                    case SWITCH_BANK_CMD_BYTE:
                        if (deviceID == SANYO_128K_ID) {
                            sectorOffset = (b & 0b1) << 16;
                        }
                        break;
                    default:
                }
            } else if (!(address & 0xFF0FFF) && value == ERASE_SECTOR_CMD_BYTE && mode == Mode.ERASE) {
                mode = Mode.ERASE_SECTOR;
                eraseSectorTarget = address;
                startTimedCMD(ERASE_SECTOR_TIMEOUT);
                erase(address, 4 * BYTES_PER_KIB);
            }
        }
    }

    private void startTimedCMD(TickDuration timeOut) {
        cmdStartTime = TickDuration.currSystemTick();
        cmdTimeOut = cmdStartTime + timeOut;
        timedCMD = true;
    }

    private void endCMD() {
        mode = Mode.NORMAL;
        timedCMD = false;
    }

    private void erase(uint address, uint size) {
        foreach (i; address .. address + size) {
            super.setByte(i, cast(byte) 0xFF);
        }
    }

    public override short getShort(uint address) {
        throw new UnsupportedMemoryWidthException(address, 2);
    }

    public override void setShort(uint address, short s) {
        throw new UnsupportedMemoryWidthException(address, 2);
    }

    public override int getInt(uint address) {
        throw new UnsupportedMemoryWidthException(address, 4);
    }

    public override void setInt(uint address, int i) {
        throw new UnsupportedMemoryWidthException(address, 4);
    }

    private static enum Mode {
        NORMAL,
        ID,
        ERASE,
        ERASE_ALL,
        ERASE_SECTOR,
        WRITE_BYTE,
    }
}

public class EEPROM : RAM {
    public this(ulong capacity) {
        super(capacity);
    }

    public this(void[] memory) {
        super(memory);
    }

    public this(string file, uint maxByteSize) {
        super(file, maxByteSize);
    }
}

public class NullMemory : Memory {
    public ulong getCapacity() {
        return 0;
    }

    public void[] getArray(uint address) {
        return null;
    }

    public void* getPointer(uint address) {
        return null;
    }

    public byte getByte(uint address) {
        return 0;
    }

    public void setByte(uint address, byte b) {
    }

    public short getShort(uint address) {
        return 0;
    }

    public void setShort(uint address, short s) {
    }

    public int getInt(uint address) {
        return 0;
    }

    public void setInt(uint address, int i) {
    }
}

public class ReadOnlyException : Exception {
    public this(uint address) {
        super(format("Memory is read only: 0x%X", address));
    }
}

public class UnsupportedMemoryWidthException : Exception {
    public this(uint address, uint badByteWidth) {
        super(format("Attempted to access 0x%X with unsupported memory width of %s bytes", address, badByteWidth));
    }
}

public class BadAddressException : Exception {
    public this(uint address) {
        super(format("Invalid address: 0x%X", address));
    }
}

public void saveToFile(Memory memory, string file) {
    try {
        write(file, memory.getArray(0));
    } catch (FileException ex) {
        throw new Exception("Cannot write memory to file", ex);
    }
}
