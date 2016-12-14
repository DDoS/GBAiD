module gbaid.gamepak;

import core.time : TickDuration;

import std.stdio : File;
import std.algorithm : min;
import std.typecons : tuple, Tuple;
import std.traits : EnumMembers;

import gbaid.memory;
import gbaid.util;

public alias SaveConfiguration = GamePak.SaveConfiguration;

public class GamePak : MappedMemory {
    private static enum uint MAX_ROM_SIZE = 32 * BYTES_PER_MIB;
    private static enum uint ROM_MASK = 0x1FFFFFF;
    private static enum uint SAVE_MASK = 0xFFFF;
    private static enum uint EEPROM_MASK_HIGH = 0xFFFF00;
    private static enum uint EEPROM_MASK_LOW = 0x0;
    private DelegatedROM unusedMemory;
    private ROM rom;
    private Memory save;
    private Memory eeprom;
    private uint eepromMask;
    private size_t capacity;

    public this(string romFile) {
        unusedMemory = new DelegatedROM(0);

        if (romFile is null) {
            throw new NullPathException("ROM");
        }
        loadROM(romFile);
    }

    public this(string romFile, string saveFile) {
        this(romFile);

        if (saveFile is null) {
            throw new NullPathException("save");
        }
        loadSave(saveFile);

        updateCapacity();
    }

    public this(string romFile, SaveConfiguration saveConfig) {
        this(romFile);

        final switch (saveConfig) {
            case SaveConfiguration.SRAM:
                save = new RAM(SaveMemory.SRAM[1]);
                eeprom = unusedMemory;
                break;
            case SaveConfiguration.SRAM_EEPROM:
                save = new RAM(SaveMemory.SRAM[1]);
                eeprom = new EEPROM(SaveMemory.EEPROM[1]);
                break;
            case SaveConfiguration.FLASH64K:
                save = new Flash(SaveMemory.FLASH512[1]);
                eeprom = unusedMemory;
                break;
            case SaveConfiguration.FLASH64K_EEPROM:
                save = new Flash(SaveMemory.FLASH512[1]);
                eeprom = new EEPROM(SaveMemory.EEPROM[1]);
                break;
            case SaveConfiguration.FLASH128K:
                save = new Flash(SaveMemory.FLASH1M[1]);
                eeprom = unusedMemory;
                break;
            case SaveConfiguration.FLASH128K_EEPROM:
                save = new Flash(SaveMemory.FLASH1M[1]);
                eeprom = new EEPROM(SaveMemory.EEPROM[1]);
                break;
            case SaveConfiguration.EEPROM:
                save = unusedMemory;
                eeprom = new EEPROM(SaveMemory.EEPROM[1]);
                break;
            case SaveConfiguration.AUTO:
                autoNewSave();
                break;
        }

        updateCapacity();
    }

    private void updateCapacity() {
        capacity = rom.getCapacity() + save.getCapacity() + eeprom.getCapacity();
    }

    private void loadROM(string romFile) {
        rom = new ROM(romFile, MAX_ROM_SIZE);
        eepromMask = rom.getCapacity() > 16 * BYTES_PER_MIB ? EEPROM_MASK_HIGH : EEPROM_MASK_LOW;
    }

    private void loadSave(string saveFile) {
        save = unusedMemory;
        eeprom = unusedMemory;
        Memory[] loaded = loadFromFile(saveFile);
        foreach (Memory memory; loaded) {
            if (cast(EEPROM) memory) {
                eeprom = memory;
            } else if (cast(Flash) memory || cast(RAM) memory) {
                save = memory;
            } else {
                throw new Exception("Unsupported memory save type: " ~ typeid(memory).name);
            }
        }
    }

    private void autoNewSave() {
        // Detect save types and size using ID strings in ROM
        bool hasSRAM = false, hasFlash = false, hasEEPROM = false;
        int saveSize = SaveMemory.SRAM[1], eepromSize = SaveMemory.EEPROM[1];
        char[] romChars = cast(char[]) rom.getArray(0);
        auto saveTypes = EnumMembers!SaveMemory;
        for (size_t i = 0; i < romChars.length; i += 4) {
            foreach (saveType; saveTypes) {
                string saveID = saveType[0];
                if (romChars[i .. min(i + saveID.length, romChars.length)] == saveID) {
                    final switch (saveID) with (SaveMemory) {
                        case SRAM[0]:
                            hasSRAM = true;
                            saveSize = saveType[1];
                            break;
                        case EEPROM[0]:
                            hasEEPROM = true;
                            saveSize = saveType[1];
                            break;
                        case FLASH[0]:
                        case FLASH512[0]:
                        case FLASH1M[0]:
                            hasFlash = true;
                            saveSize = saveType[1];
                            break;
                    }
                }
            }
        }
        // Allocate the memory
        if (hasFlash) {
            save = new Flash(saveSize);
        } else {
            save = new RAM(saveSize);
        }
        if (hasEEPROM) {
            eeprom = new EEPROM(eepromSize);
        } else {
            eeprom = unusedMemory;
        }
    }

    public void setUnusedMemoryFallBack(int delegate(uint) fallback) {
        unusedMemory.setDelegate(fallback);
    }

    protected override Memory map(ref uint address) {
        int highAddress = address >>> 24;
        int lowAddress = address & 0xFFFFFF;
        switch (highAddress) {
            case 0x0: .. case 0x4:
                address &= ROM_MASK;
                if (address < rom.getCapacity()) {
                    return rom;
                } else {
                    return unusedMemory;
                }
            case 0x5:
                if (eeprom !is null && (lowAddress & eepromMask) == eepromMask) {
                    address = lowAddress & ~eepromMask;
                    return eeprom;
                }
                goto case 0x4;
            case 0x6:
                address &= SAVE_MASK;
                return save;
            default:
                return unusedMemory;
        }
    }

    public override size_t getCapacity() {
        return capacity;
    }

    public void saveSave(string saveFile) {
        if (cast(EEPROM) eeprom is null) {
            saveToFile(saveFile, save);
        } else if (cast(RAM) save is null && cast(Flash) save is null) {
            saveToFile(saveFile, eeprom);
        } else {
            saveToFile(saveFile, save, eeprom);
        }
    }

    private static enum SaveMemory : Tuple!(string, uint) {
        EEPROM = tuple("EEPROM_V", 8 * BYTES_PER_KIB),
        SRAM = tuple("SRAM_V", 64 * BYTES_PER_KIB),
        FLASH = tuple("FLASH_V", 64 * BYTES_PER_KIB),
        FLASH512 = tuple("FLASH512_V", 64 * BYTES_PER_KIB),
        FLASH1M = tuple("FLASH1M_V", 128 * BYTES_PER_KIB)
    }

    public static enum SaveConfiguration {
        SRAM,
        SRAM_EEPROM,
        FLASH64K,
        FLASH64K_EEPROM,
        FLASH128K,
        FLASH128K_EEPROM,
        EEPROM,
        AUTO
    }
}

public class Flash : RAM {
    private static enum uint PANASONIC_64K_ID = 0x1B32;
    private static enum uint SANYO_128K_ID = 0x1362;
    private static enum uint DEVICE_ID_ADDRESS = 0x1;
    private static enum uint FIRST_CMD_ADDRESS = 0x5555;
    private static enum uint SECOND_CMD_ADDRESS = 0x2AAA;
    private static enum uint FIRST_CMD_START_BYTE = 0xAA;
    private static enum uint SECOND_CMD_START_BYTE = 0x55;
    private static enum uint ID_MODE_START_CMD_BYTE = 0x90;
    private static enum uint ID_MODE_STOP_CMD_BYTE = 0xF0;
    private static enum uint ERASE_CMD_BYTE = 0x80;
    private static enum uint ERASE_ALL_CMD_BYTE = 0x10;
    private static enum uint ERASE_SECTOR_CMD_BYTE = 0x30;
    private static enum uint WRITE_BYTE_CMD_BYTE = 0xA0;
    private static enum uint SWITCH_BANK_CMD_BYTE = 0xB0;
    private static TickDuration WRITE_TIMEOUT = 10;
    private static TickDuration ERASE_SECTOR_TIMEOUT = 500;
    private static TickDuration ERASE_ALL_TIMEOUT = 500;
    private uint deviceID;
    private Mode mode = Mode.NORMAL;
    private uint cmdStage = 0;
    private bool timedCMD = false;
    private TickDuration cmdTimeOut;
    private uint eraseSectorTarget;
    private uint sectorOffset = 0;

    static this() {
        WRITE_TIMEOUT = TickDuration.from!"msecs"(10);
        ERASE_SECTOR_TIMEOUT = TickDuration.from!"msecs"(500);
        ERASE_ALL_TIMEOUT = TickDuration.from!"msecs"(500);
    }

    public this(size_t capacity) {
        super(capacity);
        erase(0, cast(uint) capacity);
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
        if (memoryByte.length > 64 * BYTES_PER_KIB) {
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
        if (timedCMD && TickDuration.currSystemTick() >= cmdTimeOut) {
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
            case Mode.SWITCH_BANK:
                sectorOffset = (b & 0b1) << 16;
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
                            mode = Mode.SWITCH_BANK;
                        }
                        break;
                    default:
                }
            } else if (!(address & 0xFF0FFF) && value == ERASE_SECTOR_CMD_BYTE && mode == Mode.ERASE) {
                mode = Mode.ERASE_SECTOR;
                eraseSectorTarget = address;
                startTimedCMD(ERASE_SECTOR_TIMEOUT);
                erase(address + sectorOffset, 4 * BYTES_PER_KIB);
            }
        }
    }

    private void startTimedCMD(TickDuration timeOut) {
        cmdTimeOut = TickDuration.currSystemTick() + timeOut;
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
        SWITCH_BANK
    }
}

public class EEPROM : RAM {
    private Mode mode = Mode.NORMAL;
    private int targetAddress = 0;
    private int currentAddressBit = 0, currentReadBit = 0;
    private int[3] writeBuffer;

    public this(size_t capacity) {
        super(capacity);
        foreach (i; 0 .. capacity) {
            memoryByte[i] = cast(byte) 0xFF;
        }
    }

    public this(void[] memory) {
        super(memory);
    }

    public this(string file, uint maxByteSize) {
        super(file, maxByteSize);
    }

    public override byte getByte(uint address) {
        throw new UnsupportedMemoryWidthException(address, 1);
    }

    public override void setByte(uint address, byte b) {
        throw new UnsupportedMemoryWidthException(address, 1);
    }

    public override short getShort(uint address) {
        if (mode == Mode.WRITE) {
            // get write address and offset in write buffer
            int actualAddress = void;
            int bitOffset = void;
            if (currentAddressBit > 73) {
                actualAddress = targetAddress >>> 18;
                bitOffset = 14;
            } else {
                actualAddress = targetAddress >>> 26;
                bitOffset = 6;
            }
            actualAddress <<= 3;
            // get data to write from buffer
            long toWrite = 0;
            foreach (int i; 0 .. 64) {
                toWrite |= ucast(getBit(writeBuffer[i + bitOffset >> 5], i + bitOffset & 31)) << 63 - i;
            }
            // write data
            super.setInt(actualAddress, cast(int) toWrite);
            super.setInt(actualAddress + 4, cast(int) (toWrite >>> 32));
            // end write mode
            mode = Mode.NORMAL;
            targetAddress = 0;
            currentAddressBit = 0;
        } else if (mode == Mode.READ) {
            // get data
            short data = void;
            if (currentReadBit < 4) {
                // first 4 bits are 0
                data = 0;
            } else {
                // get read address depending on amount of bits received
                int actualAddress = void;
                if (currentAddressBit > 9) {
                    actualAddress = targetAddress >>> 18;
                } else {
                    actualAddress = targetAddress >>> 26;
                }
                actualAddress <<= 3;
                actualAddress += 7 - (currentReadBit - 4 >> 3);
                // get the data bit
                data = cast(short) getBit(super.getByte(actualAddress), 7 - (currentReadBit - 4 & 7));
            }
            // end read mode on last bit
            if (currentReadBit == 67) {
                mode = Mode.NORMAL;
                targetAddress = 0;
                currentAddressBit = 0;
                currentReadBit = 0;
            } else {
                // increment current read bit and save address
                currentReadBit++;
            }
            return data;
        }
        // return ready
        return 1;
    }

    public override void setShort(uint address, short s) {
        // get relevant bit
        int bit = s & 0b1;
        // if in write mode, buffer the bit
        if (mode == Mode.WRITE) {
            setBit(writeBuffer[currentAddressBit - 2 >> 5],  currentAddressBit - 2 & 31, bit);
        }
        // then process as command or address bit
        if (currentAddressBit == 0) {
            // check for first command bit
            if (bit == 0b1) {
                // wait for second bit
                currentAddressBit++;
            }
        } else if (currentAddressBit == 1) {
            // second command bit, set mode to the command
            mode = cast(Mode) bit;
            currentAddressBit++;
        } else {
            // set address if we have a command
            if (currentAddressBit < 16) {
                // max address size if 14 (+2 including command bits)
                setBit(targetAddress, 33 - currentAddressBit, bit);
            }
            currentAddressBit++;
        }
    }

    public override int getInt(uint address) {
        throw new UnsupportedMemoryWidthException(address, 4);
    }

    public override void setInt(uint address, int i) {
        throw new UnsupportedMemoryWidthException(address, 4);
    }

    private static enum Mode {
        NORMAL = 2,
        READ = 1,
        WRITE = 0
    }
}

/*
 TODO: fix endianness
       add magic and version numbers
       checksums

 Format:
    Header:
        1 int: number of memory objects (n)
        n int pairs:
            1 int: memory type ID
                0: ROM
                1: RAM
                2: Flash
                3: EEPROM
            1 int: memory capacity in bytes (c)
    Body:
        n byte groups:
            c bytes: memory
 */

public Memory[] loadFromFile(string filePath) {
    Memory fromTypeID(int id, void[] contents) {
        final switch (id) {
            case 0:
                return new ROM(contents);
            case 1:
                return new RAM(contents);
            case 2:
                return new Flash(contents);
            case 3:
                return new EEPROM(contents);
        }
    }
    // open file in binary read
    File file = File(filePath, "rb");
    // read size of header
    int[1] lengthBytes = new int[1];
    // remove once fixed!
    file.rawRead(lengthBytes);
    int length = lengthBytes[0];
    // read type and capacity information
    int[] header = new int[length * 2];
    file.rawRead(header);
    // read memory objects
    Memory[] memories = new Memory[length];
    foreach (i; 0 .. length) {
        int pair = i * 2;
        int type = header[pair];
        int capacity = header[pair + 1];
        void[] contents = new byte[capacity];
        file.rawRead(contents);
        memories[i] = fromTypeID(type, contents);
    }
    return memories;
    // closing is done automatically
}

public void saveToFile(string filePath, Memory[] memories ...) {
    int toTypeID(Memory memory) {
        // order matters because of inheritance, check subclasses first
        if (cast(EEPROM) memory !is null) {
            return 3;
        }
        if (cast(Flash) memory !is null) {
            return 2;
        }
        if (cast(RAM) memory !is null) {
            return 1;
        }
        if (cast(ROM) memory !is null) {
            return 0;
        }
        throw new Exception("Unsupported memory type: " ~ typeid(memory).name);
    }
    // build the header
    int length = cast(int) memories.length;
    int[] header = new int[1 + length * 2];
    header[0] = length;
    foreach (int i, Memory memory; memories) {
        int pair = 1 + i * 2;
        header[pair] = toTypeID(memory);
        header[pair + 1] = cast(int) memory.getCapacity();
    }
    // open the file in binary write mode
    File file = File(filePath, "wb");
    // write the header
    file.rawWrite(header);
    // write the rest of the memory objects
    foreach (Memory memory; memories) {
        file.rawWrite(memory.getArray(0));
    }
    // closing is done automatically
}
