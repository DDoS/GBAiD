module gbaid.gamepak;

import core.time : TickDuration;

import std.format : format;
import std.file : read, FileException;
import std.algorithm.iteration : splitter;
import std.algorithm.comparison : min;
import std.typecons : tuple, Tuple;
import std.traits : EnumMembers;
import std.meta : Alias;
import std.stdio : File;
import std.bitmanip : littleEndianToNative, nativeToLittleEndian;
import std.digest.crc : CRC32;
import std.zlib : compress, uncompress;

import gbaid.fast_mem;
import gbaid.util;

public enum uint MAX_ROM_SIZE = 32 * BYTES_PER_MIB;
public enum uint EEPROM_SIZE = 8 * BYTES_PER_KIB;
public enum uint ROM_MASK = 0x1FFFFFF;
public enum uint SAVE_MASK = 0xFFFF;
public enum uint EEPROM_MASK_HIGH = 0xFFFF00;
public enum uint EEPROM_MASK_LOW = 0x0;

private enum int SAVE_CURRENT_VERSION = 1;
private immutable char[8] SAVE_FORMAT_MAGIC = "GBAiDSav";

public enum SaveMemoryKind : int {
    EEPROM = 0,
    SRAM = 1,
    FLASH_512K = 2,
    FLASH_1M = 3,
    UNKNOWN = -1
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

public enum string[][SaveMemoryKind] saveMemoryIdsForKind = [
    SaveMemoryKind.EEPROM: ["EEPROM_V"],
    SaveMemoryKind.SRAM: ["SRAM_V"],
    SaveMemoryKind.FLASH_512K: ["FLASH_V", "FLASH512_V"],
    SaveMemoryKind.FLASH_1M: ["FLASH1M_V"],
];

public alias SaveMemoryConfiguration = Tuple!(SaveMemoryKind, bool);
public alias RawSaveMemory = Tuple!(SaveMemoryKind, ubyte[]);

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

public enum int[SaveMemoryKind] memoryCapacityForSaveKind = [
    SaveMemoryKind.EEPROM: EEPROM_SIZE,
    SaveMemoryKind.SRAM: 32 * BYTES_PER_KIB,
    SaveMemoryKind.FLASH_512K: 64 * BYTES_PER_KIB,
    SaveMemoryKind.FLASH_1M: 128 * BYTES_PER_KIB,
];

public alias GameRom = Rom!MAX_ROM_SIZE;
public alias Sram = Ram!(memoryCapacityForSaveKind[SaveMemoryKind.SRAM]);
public alias Flash512K = Flash!(memoryCapacityForSaveKind[SaveMemoryKind.FLASH_512K]);
public alias Flash1M = Flash!(memoryCapacityForSaveKind[SaveMemoryKind.FLASH_1M]);

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

    public this(string romFile, string saveFile) {
        rom = GameRom(readFileAndSize(romFile, actualRomByteSize));
        if (saveFile is null) {
            allocateNewSave(saveMemoryForConfiguration[SaveConfiguration.AUTO]);
        } else {
            loadSave(saveFile);
        }
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
                        assert (0);
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
                        assert (0);
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
        // Detect save types and size using ID strings in ROM
        auto foundKind = SaveMemoryKind.SRAM;
        auto hasEeprom = false;
        auto romChars = rom.getArray!ubyte(0x0, actualRomByteSize);
        foreach (saveKind, saveIds; saveMemoryIdsForKind) {
            foreach (saveId; saveIds) {
                for (size_t i = 0; i < romChars.length; i += 4) {
                    if (romChars[i .. min(i + saveId.length, $)] != saveId) {
                        continue;
                    }
                    if (saveKind == SaveMemoryKind.EEPROM) {
                        hasEeprom = true;
                    } else {
                        foundKind = saveKind;
                    }
                }
            }
        }
        // Allocate the memory
        allocateNewSave(tuple(foundKind, hasEeprom));
    }

    private void loadSave(string saveFile) {
        void checkSaveMissing(ref bool found) {
            if (found) {
                throw new Exception("Found more than one possible save memory in the save file");
            }
            found = true;
        }

        RawSaveMemory[] memories = saveFile.loadSaveFile();
        bool foundSave = false;
        bool foundEeprom = false;
        foreach (memory; memories) {
            switch (memory[0]) with (SaveMemoryKind) {
                case SRAM:
                    checkSaveMissing(foundSave);
                    save.sram = new Sram(memory[1]);
                    saveKind = SRAM;
                    break;
                case FLASH_512K:
                    checkSaveMissing(foundSave);
                    save.flash512k = new Flash512K(memory[1]);
                    saveKind = FLASH_512K;
                    break;
                case FLASH_1M:
                    checkSaveMissing(foundSave);
                    save.flash1m = new Flash1M(memory[1]);
                    saveKind = FLASH_1M;
                    break;
                case EEPROM:
                    checkSaveMissing(foundEeprom);
                    eeprom = new Eeprom(memory[1]);
                    break;
                default:
                    throw new Exception(format("Unsupported memory save type: %d", memory[0]));
            }
        }
    }

    public void saveSave(string saveFile) {
        RawSaveMemory[] memories;
        switch (saveKind) with (SaveMemoryKind) {
            case SRAM:
                memories ~= tuple(saveKind, save.sram.getArray!ubyte());
                break;
            case FLASH_512K:
                memories ~= tuple(saveKind, save.flash512k.getArray!ubyte());
                break;
            case FLASH_1M:
                memories ~= tuple(saveKind, save.flash1m.getArray!ubyte());
                break;
            default:
                assert (0);
        }
        if (eeprom !is null) {
            memories ~= tuple(SaveMemoryKind.EEPROM, eeprom.getArray!ubyte());
        }
        memories.saveSaveFile(saveFile);
    }

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
        if (memory.length > byteSize) {
            throw new Exception(format("Expected a memory size of %dB, but got %dB", byteSize, memory.length));
        }
        this.memory[0 .. memory.length] = memory[];
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

    public T[] getArray(T)(uint address = 0x0, uint size = byteSize) if (IsValidSize!T) {
        return cast(T[]) memory[address .. address + size];
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
        auto byteSize = this.memory.length;
        if (memory.length > byteSize) {
            throw new Exception(format("Expected a memory size of %dB, but got %dB", byteSize, memory.length));
        }
        this.memory[0 .. memory.length] = memory[];
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

    public T[] getArray(T)(uint address = 0x0, uint size = EEPROM_SIZE) if (IsValidSize!T) {
        return cast(T[]) memory[address .. address + size];
    }

    private static enum Mode {
        NORMAL = 2,
        READ = 1,
        WRITE = 0
    }
}

/*
All ints are 32 bit and stored in little endian.
The CRCs are calculated on the little endian values

Format:
    Header:
        8 bytes: magic number (ASCII string of "GBAiDSav")
        1 int: version number
        1 int: option flags
        1 int: number of memory objects (n)
        1 int: CRC of the memory header (excludes magic number)
    Body:
        n memory blocks:
            1 int: memory kind ID, as per the SaveMemoryKind enum
            1 int: compressed memory size in bytes (c)
            c bytes: memory compressed with zlib
            1 int: CRC of the memory block
*/

public RawSaveMemory[] loadSaveFile(string filePath) {
    // Open the file in binary to read
    auto file = File(filePath, "rb");
    // Read the first 8 bytes to make sure it is a save file for GBAiD
    char[8] magicChars;
    file.rawRead(magicChars);
    if (magicChars != SAVE_FORMAT_MAGIC) {
        throw new Exception(format("Not a GBAiD save file (magic number isn't \"%s\" in ASCII)", SAVE_FORMAT_MAGIC));
    }
    // Read the version number
    auto versionNumber = file.readLittleEndianInt();
    // Use the proper reader for the version
    switch (versionNumber) {
        case 1:
            return file.readRawSaveMemories!1();
        default:
            throw new Exception(format("Unknown save file version: %d", versionNumber));
    }
}

private RawSaveMemory[] readRawSaveMemories(int versionNumber: 1)(File file) {
    CRC32 hash;
    hash.put([0x1, 0x0, 0x0, 0x0]);
    // Read the options flags, which are unused in this version
    auto optionFlags = file.readLittleEndianInt(&hash);
    // Read the number of save memories in the file
    auto memoryCount = file.readLittleEndianInt(&hash);
    // Read the header CRC checksum
    ubyte[4] headerCrc;
    file.rawRead(headerCrc);
    // Check the CRC
    if (hash.finish() != headerCrc) {
        throw new Exception("The save file has a corrupted header, the CRCs do not match");
    }
    // Read all the raw save memories according to the configurations given by the header
    RawSaveMemory[] saveMemories;
    foreach (i; 0 .. memoryCount) {
        saveMemories ~= file.readRawSaveMemory!versionNumber();
    }
    return saveMemories;
}

private RawSaveMemory readRawSaveMemory(int versionNumber: 1)(File file) {
    CRC32 hash;
    // Read the memory kind
    auto kindId = file.readLittleEndianInt(&hash);
    // Read the memory compressed size
    auto compressedSize = file.readLittleEndianInt(&hash);
    // Read the compressed bytes for the memory
    ubyte[] memoryCompressed;
    memoryCompressed.length = compressedSize;
    file.rawRead(memoryCompressed);
    hash.put(memoryCompressed);
    // Read the block CRC checksum
    ubyte[4] blockCrc;
    file.rawRead(blockCrc);
    // Check the CRC
    if (hash.finish() != blockCrc) {
        throw new Exception("The save file has a corrupted memory block, the CRCs do not match");
    }
    // Get the memory length according to the kind
    auto saveKind = cast(SaveMemoryKind) kindId;
    auto uncompressedSize = memoryCapacityForSaveKind[saveKind];
    // Uncompress the memory
    auto memoryUncompressed = cast(ubyte[]) memoryCompressed.uncompress(uncompressedSize);
    // Check that the uncompressed length matches the one for the kind
    if (memoryUncompressed.length != uncompressedSize) {
        throw new Exception(format("The uncompressed save memory has a different length than its kind: %d != %d",
                memoryUncompressed.length, uncompressedSize));
    }
    return tuple(saveKind, memoryUncompressed);
}

public void saveSaveFile(RawSaveMemory[] saveMemories, string filePath) {
    // Open the file in binary to write
    auto file = File(filePath, "wb");
    // First we write the magic
    file.rawWrite(SAVE_FORMAT_MAGIC);
    // Next we write the current version
    CRC32 hash;
    file.writeLittleEndianInt(SAVE_CURRENT_VERSION, &hash);
    // Next we write the option flags, which are empty since they are unused
    file.writeLittleEndianInt(0, &hash);
    // Next we write the number of memory blocks
    file.writeLittleEndianInt(cast(int) saveMemories.length, &hash);
    // Next we write the header CRC
    file.rawWrite(hash.finish());
    // Finally write the memory blocks
    foreach (saveMemory; saveMemories) {
        file.writeRawSaveMemory(saveMemory);
    }
}

private void writeRawSaveMemory(File file, RawSaveMemory saveMemory) {
    CRC32 hash;
    // Write the memory kind
    file.writeLittleEndianInt(saveMemory[0], &hash);
    // Compress the save memory
    auto memoryCompressed = saveMemory[1].compress();
    // Write the memory compressed size
    file.writeLittleEndianInt(cast(int) memoryCompressed.length, &hash);
    // Write the compressed bytes for the memory
    hash.put(memoryCompressed);
    file.rawWrite(memoryCompressed);
    // Write the block CRC
    file.rawWrite(hash.finish());
}

private int readLittleEndianInt(File file, CRC32* hash = null) {
    ubyte[4] numberBytes;
    file.rawRead(numberBytes);
    if (hash !is null) {
        hash.put(numberBytes);
    }
    return numberBytes.littleEndianToNative!int();
}

private void writeLittleEndianInt(File file, int i, CRC32* hash = null) {
    auto numberBytes = i.nativeToLittleEndian();
    if (hash !is null) {
        hash.put(numberBytes);
    }
    file.rawWrite(numberBytes);
}
