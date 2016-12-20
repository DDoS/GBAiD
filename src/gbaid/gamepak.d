module gbaid.gamepak;

import core.time : TickDuration;

import std.format : format;
import std.file : read, FileException;
import std.algorithm.iteration : splitter;
import std.algorithm.comparison : min;
import std.typecons : tuple, Tuple;
import std.traits : EnumMembers;
import std.meta : Alias;

import gbaid.fast_mem;
import gbaid.util;

public enum uint MAX_ROM_SIZE = 32 * BYTES_PER_MIB;
public enum uint EEPROM_SIZE = 8 * BYTES_PER_KIB;
public enum uint ROM_MASK = 0x1FFFFFF;
public enum uint SAVE_MASK = 0xFFFF;
public enum uint EEPROM_MASK_HIGH = 0xFFFF00;
public enum uint EEPROM_MASK_LOW = 0x0;

public enum SaveMemoryKind : string {
    EEPROM = "EEPROM_V",
    SRAM = "SRAM_V",
    FLASH_512K = "FLASH_V|FLASH512_V",
    FLASH_1M = "FLASH1M_V",
    UNKNOWN = ""
}

public enum SaveConfiguration {
    SRAM,
    SRAM_EEPROM,
    FLASH_512K,
    FLASH_512K_EEPROM,
    FLASH_1M,
    FLASH_1M_EEPROM,
    EEPROM,
    AUTO
}

public alias SaveMemoryConfiguration = Tuple!(SaveMemoryKind, bool);

public enum SaveMemoryConfiguration[SaveConfiguration] saveMemoryForConfiguration = [
    SaveConfiguration.SRAM: tuple(SaveMemoryKind.SRAM, false),
    SaveConfiguration.SRAM_EEPROM: tuple(SaveMemoryKind.SRAM, true),
    SaveConfiguration.FLASH_512K: tuple(SaveMemoryKind.FLASH_512K, false),
    SaveConfiguration.FLASH_512K_EEPROM: tuple(SaveMemoryKind.FLASH_512K, true),
    SaveConfiguration.FLASH_1M: tuple(SaveMemoryKind.FLASH_1M, false),
    SaveConfiguration.FLASH_1M_EEPROM: tuple(SaveMemoryKind.FLASH_1M, true),
    SaveConfiguration.EEPROM: tuple(SaveMemoryKind.EEPROM, true),
    SaveConfiguration.AUTO: tuple(SaveMemoryKind.UNKNOWN, false)
];

public alias GameRom = Rom!MAX_ROM_SIZE;
public alias Sram = Ram!(32 * BYTES_PER_KIB);
public alias Flash512K = Flash!(64 * BYTES_PER_KIB);
public alias Flash1M = Flash!(128 * BYTES_PER_KIB);

private union SaveMemory {
    private Sram* sram;
    private Flash512K* flash512k;
    private Flash1M* flash1m;
}

public struct GamePak {
    private GameRom rom;
    private SaveMemoryKind saveKind;
    private SaveMemory save;
    private Eeprom* eeprom;
    private int delegate(uint) _unusedMemory = null;
    private uint eepromMask;
    private uint actualRomByteSize;

    @disable public this();

    public this(string romFile) {
        this(romFile, null);
    }

    public this(string romFile, string saveFile) {
        rom = romFile is null ? GameRom(new byte[0]) : GameRom(readFileAndSize(romFile, actualRomByteSize));
        //loadSave(saveFile);
    }

    public this(string romFile, SaveConfiguration saveConfig) {
        rom = GameRom(readFileAndSize(romFile, actualRomByteSize));
        allocateNewSave(saveMemoryForConfiguration[saveConfig]);
    }

    @property public void unusedMemory(int delegate(uint) unusedMemory) {
        assert (unusedMemory !is null);
        _unusedMemory = unusedMemory;
    }

    public T get(T)(uint address) if (IsValidSize!T) {
        auto highAddress = address >>> 24;
        switch (highAddress) {
            case 0x0: .. case 0x4:
                address &= ROM_MASK;
                if (address < actualRomByteSize) {
                    return rom.get!T(address);
                }
                return cast(T) _unusedMemory(address);
            case 0x5:
                auto lowAddress = address & 0xFFFFFF;
                if (eeprom !is null && (lowAddress & eepromMask) == eepromMask) {
                    static if (is(T == short) || is(T == ushort)) {
                        return eeprom.get!T(lowAddress & ~eepromMask);
                    } else {
                        return cast(T) _unusedMemory(address);
                    }
                }
                goto case 0x4;
            case 0x6:
                address &= SAVE_MASK;
                switch (saveKind) with (SaveMemoryKind) {
                    case SRAM:
                        return save.sram.get!T(address);
                    case FLASH_512K:
                        static if (is(T == byte) || is(T == ubyte)) {
                            return save.flash512k.get!T(address);
                        } else {
                            return cast(T) _unusedMemory(address);
                        }
                    case FLASH_1M:
                        static if (is(T == byte) || is(T == ubyte)) {
                            return save.flash1m.get!T(address);
                        } else {
                            return cast(T) _unusedMemory(address);
                        }
                    default:
                        return cast(T) _unusedMemory(address);
                }
            default:
                return cast(T) _unusedMemory(address);
        }
    }

    public void set(T)(uint address, T value) if (IsValidSize!T) {
        auto highAddress = address >>> 24;
        switch (highAddress) {
            case 0x5:
                auto lowAddress = address & 0xFFFFFF;
                if (eeprom !is null && (lowAddress & eepromMask) == eepromMask) {
                    static if (is(T == short) || is(T == ushort)) {
                        return eeprom.set!T(lowAddress & ~eepromMask, value);
                    }
                }
                goto default;
            case 0x6:
                address &= SAVE_MASK;
                switch (saveKind) with (SaveMemoryKind) {
                    case SRAM:
                        return save.sram.set!T(address, value);
                    case FLASH_512K:
                        static if (is(T == byte) || is(T == ubyte)) {
                            save.flash512k.set!T(address, value);
                        }
                        return;
                    case FLASH_1M:
                        static if (is(T == byte) || is(T == ubyte)) {
                             save.flash1m.set!T(address, value);
                        }
                        return;
                    default:
                        return;
                }
            default:
                return;
        }
    }

    private void allocateNewSave(SaveMemoryConfiguration saveConfig) {
        saveKind = saveConfig[0];
        final switch (saveKind) with (SaveMemoryKind) {
            case UNKNOWN:
                autoNewSave();
                return;
            case SRAM:
                save.sram = new Sram();
                break;
            case FLASH_512K:
                save.flash512k = new Flash512K(true);
                break;
            case FLASH_1M:
                save.flash1m = new Flash1M(true);
                break;
            case EEPROM:
                save.sram = null;
                break;
        }
        eeprom = saveConfig[1] ? new Eeprom(true) : null;
    }

    private void autoNewSave() {
        // Get the ID strings for the save kinds
        SaveMemoryKind[string] saveKindForId;
        foreach (string saveKind; EnumMembers!SaveMemoryKind) {
            foreach (saveId; saveKind.splitter('|')) {
                if (saveId.length <= 0) {
                    continue;
                }
                saveKindForId[saveId] = cast(SaveMemoryKind) saveKind;
            }
        }
        // Detect save types and size using ID strings in ROM
        auto foundKind = SaveMemoryKind.SRAM;
        auto hasEeprom = false;
        auto romChars = rom.getArray!ubyte(0, actualRomByteSize);
        for (size_t i = 0; i < romChars.length; i += 4) {
            foreach (saveId, saveKind; saveKindForId) {
                if (romChars[i .. min(i + saveId.length, $)] == saveId) {
                    if (saveKind == SaveMemoryKind.EEPROM) {
                        hasEeprom = true;
                    } else {
                        foundKind = saveKind;
                    }
                }
            }
        }
        // Allocate the memory
        import std.stdio : writeln;
        writeln(foundKind, ' ', hasEeprom);
        allocateNewSave(tuple(foundKind, hasEeprom));
    }

    /*private void loadSave(string saveFile) {
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
    }*/

    /*public void saveSave(string saveFile) {
        if (cast(EEPROM) eeprom is null) {
            saveToFile(saveFile, save);
        } else if (cast(RAM) save is null && cast(Flash) save is null) {
            saveToFile(saveFile, eeprom);
        } else {
            saveToFile(saveFile, save, eeprom);
        }
    }*/

    private static void[] readFileAndSize(string file, ref uint size) {
        try {
            auto memory = file.read();
            size = cast(uint) memory.length;
            return memory;
        } catch (FileException ex) {
            throw new Exception("Cannot read memory file", ex);
        }
    }
}

public struct Flash(uint byteSize) if (byteSize == 64 * BYTES_PER_KIB || byteSize == 128 * BYTES_PER_KIB) {
    private alias DeviceID = Alias!(byteSize == 64 * BYTES_PER_KIB ? PANASONIC_64K_ID : SANYO_128K_ID);
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
    private void[byteSize] memory;
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

    public this(bool erase) {
        if (!erase) {
            return;
        }
        this.erase(0x0, byteSize);
    }

    public this(void[] memory) {
        if (byteSize != memory.length) {
            throw new Exception(format("The expected a memory size of %dB, but got %dB", byteSize, memory.length));
        }
        this.memory[] = memory[];
    }

    public this(string file) {
        try {
            this(file.read());
        } catch (FileException ex) {
            throw new Exception("Cannot read memory file", ex);
        }
    }

    public T get(T)(uint address) if (is(T == byte) || is(T == ubyte)) {
        if (mode == Mode.ID && address <= DEVICE_ID_ADDRESS) {
            return cast(byte) (DeviceID >> ((address & 0b1) << 3));
        }
        return *cast(T*) (memory.ptr + address + sectorOffset);
    }

    public void set(T)(uint address, T value) if (is(T == byte) || is(T == ubyte)) {
        uint intValue = value & 0xFF;
        // Handle command time-outs
        if (timedCMD && TickDuration.currSystemTick() >= cmdTimeOut) {
            endCMD();
        }
        // Handle commands completions
        switch (mode) {
            case Mode.ERASE_ALL:
                if (address == 0x0 && intValue == 0xFF) {
                    endCMD();
                }
                break;
            case Mode.ERASE_SECTOR:
                if (address == eraseSectorTarget && intValue == 0xFF) {
                    endCMD();
                }
                break;
            case Mode.WRITE_BYTE:
                *cast(byte*) (memory.ptr + address + sectorOffset) = value;
                endCMD();
                break;
            case Mode.SWITCH_BANK:
                sectorOffset = (value & 0b1) << 16;
                endCMD();
                break;
            default:
        }
        // Handle command initialization and execution
        if (address == FIRST_CMD_ADDRESS && intValue == FIRST_CMD_START_BYTE) {
            cmdStage = 1;
        } else if (cmdStage == 1) {
            if (address == SECOND_CMD_ADDRESS && intValue == SECOND_CMD_START_BYTE) {
                cmdStage = 2;
            } else {
                cmdStage = 0;
            }
        } else if (cmdStage == 2) {
            cmdStage = 0;
            // execute
            if (address == FIRST_CMD_ADDRESS) {
                switch (intValue) {
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
                            erase(0x0, byteSize);
                        }
                        break;
                    case WRITE_BYTE_CMD_BYTE:
                        mode = Mode.WRITE_BYTE;
                        startTimedCMD(WRITE_TIMEOUT);
                        break;
                    case SWITCH_BANK_CMD_BYTE:
                        if (DeviceID == SANYO_128K_ID) {
                            mode = Mode.SWITCH_BANK;
                        }
                        break;
                    default:
                }
            } else if (!(address & 0xFF0FFF) && intValue == ERASE_SECTOR_CMD_BYTE && mode == Mode.ERASE) {
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
        auto byteMemory = cast(byte*) memory.ptr;
        foreach (i; address .. address + size) {
            *byteMemory = cast(byte) 0xFF;
            byteMemory++;
        }
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

public struct Eeprom {
    private void[EEPROM_SIZE] memory;
    private Mode mode = Mode.NORMAL;
    private int targetAddress = 0;
    private int currentAddressBit = 0;
    private int currentReadBit = 0;
    private int[3] writeBuffer;

    public this(bool erase) {
        if (!erase) {
            return;
        }
        auto byteMemory = cast(byte*) memory.ptr;
        foreach (i; 0 .. memory.length) {
            *byteMemory = cast(byte) 0xFF;
            byteMemory++;
        }
    }

    public this(void[] memory) {
        if (this.memory.length != memory.length) {
            throw new Exception(format("The expected a memory size of %dB, but got %dB",
                    this.memory.length, memory.length));
        }
        this.memory[] = memory[];
    }

    public this(string file) {
        try {
            this(file.read());
        } catch (FileException ex) {
            throw new Exception("Cannot read memory file", ex);
        }
    }

    public T get(T)(uint address) if (is(T == short) || is (T == ushort)) {
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
                toWrite |= writeBuffer[i + bitOffset >> 5].getBit(i + bitOffset & 31).ucast() << 63 - i;
            }
            // write data
            auto intMemory = cast(int*) (memory.ptr + actualAddress);
            *intMemory = cast(int) toWrite;
            *(intMemory + 1) = cast(int) (toWrite >>> 32);
            // end write mode
            mode = Mode.NORMAL;
            targetAddress = 0;
            currentAddressBit = 0;
        } else if (mode == Mode.READ) {
            // get data
            T data = void;
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
                auto byteMemory = cast(byte*) (memory.ptr + actualAddress);
                data = cast(T) (*byteMemory).getBit(7 - (currentReadBit - 4 & 7));
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

    public void set(T)(uint address, T value) if (is(T == short) || is (T == ushort)) {
        // get relevant bit
        int bit = value & 0b1;
        // if in write mode, buffer the bit
        if (mode == Mode.WRITE) {
            writeBuffer[currentAddressBit - 2 >> 5].setBit(currentAddressBit - 2 & 31, bit);
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
                targetAddress.setBit(33 - currentAddressBit, bit);
            }
            currentAddressBit++;
        }
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
/*
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
}*/
