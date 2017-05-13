module gbaid.gba.memory;

import core.time : TickDuration;

import std.traits : MutableOf, ImmutableOf;
import std.meta : Alias, AliasSeq, staticIndexOf;
import std.typecons : tuple, Tuple;
import std.algorithm.comparison : min;
import std.file : read, FileException;
import std.format : format;

import gbaid.util;

import gbaid.gba.save;

public alias Ram(uint byteSize) = Memory!(byteSize, false);
public alias Rom(uint byteSize) = Memory!(byteSize, true);

public alias Bios = Rom!BIOS_SIZE;
public alias BoardWram = Ram!BOARD_WRAM_SIZE;
public alias ChipWram = Ram!CHIP_WRAM_SIZE;
public alias Palette = Ram!PALETTE_SIZE;
public alias Vram = Ram!VRAM_SIZE;
public alias Oam = Ram!OAM_SIZE;
public alias GameRom = Rom!MAX_ROM_SIZE;
public alias Sram = Ram!(memoryCapacityForSaveKind[SaveMemoryKind.SRAM]);
public alias Flash512K = Flash!(memoryCapacityForSaveKind[SaveMemoryKind.FLASH_512K]);
public alias Flash1M = Flash!(memoryCapacityForSaveKind[SaveMemoryKind.FLASH_1M]);

private alias ValidSizes = AliasSeq!(byte, ubyte, short, ushort, int, uint);
private alias IsValidSize(T) = Alias!(staticIndexOf!(T, ValidSizes) >= 0);

public alias SaveMemoryConfiguration = Tuple!(SaveMemoryKind, bool);

private template SizeBase2Power(T) {
    static if (is(T == byte) || is(T == ubyte)) {
        private alias SizeBase2Power = Alias!0;
    } else static if (is(T == short) || is(T == ushort)) {
        private alias SizeBase2Power = Alias!1;
    } else static if (is(T == int) || is(T == uint)) {
        private alias SizeBase2Power = Alias!2;
    } else {
        static assert (0);
    }
}

private alias AlignmentMask(T) = Alias!(~((1 << SizeBase2Power!T) - 1));

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

public enum uint BIOS_SIZE = 16 * BYTES_PER_KIB;
public enum uint BOARD_WRAM_SIZE = 256 * BYTES_PER_KIB;
public enum uint CHIP_WRAM_SIZE = 32 * BYTES_PER_KIB;
public enum uint IO_REGISTERS_SIZE = 1 * BYTES_PER_KIB;
public enum uint PALETTE_SIZE = 1 * BYTES_PER_KIB;
public enum uint VRAM_SIZE = 96 * BYTES_PER_KIB;
public enum uint OAM_SIZE = 1 * BYTES_PER_KIB;
public enum uint MAX_ROM_SIZE = 32 * BYTES_PER_MIB;
public enum uint EEPROM_SIZE = memoryCapacityForSaveKind[SaveMemoryKind.EEPROM];

public enum uint BIOS_START = 0x00000000;
public enum uint BIOS_MASK = 0x3FFF;
public enum uint BOARD_WRAM_MASK = 0x3FFFF;
public enum uint CHIP_WRAM_MASK = 0x7FFF;
public enum uint IO_REGISTERS_END = 0x040003FE;
public enum uint IO_REGISTERS_MASK = 0x3FF;
public enum uint PALETTE_MASK = 0x3FF;
public enum uint VRAM_MASK = 0x1FFFF;
public enum uint VRAM_LOWER_MASK = 0xFFFF;
public enum uint VRAM_HIGH_MASK = 0x17FFF;
public enum uint OAM_MASK = 0x3FF;
public enum uint GAME_PAK_START = 0x08000000;
public enum uint ROM_MASK = 0x1FFFFFF;
public enum uint SAVE_MASK = 0xFFFF;
public enum uint EEPROM_MASK_HIGH = 0xFFFF00;
public enum uint EEPROM_MASK_LOW = 0x0;

public enum string[][SaveMemoryKind] saveMemoryIdsForKind = [
    SaveMemoryKind.EEPROM: ["EEPROM_V"],
    SaveMemoryKind.SRAM: ["SRAM_V"],
    SaveMemoryKind.FLASH_512K: ["FLASH_V", "FLASH512_V"],
    SaveMemoryKind.FLASH_1M: ["FLASH1M_V"],
];

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

public struct Memory(uint byteSize, bool readOnly) {
    private Mod!(void[byteSize]) memory;

    static if (readOnly) {
        @disable public this();
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

    public Mod!T get(T)(uint address) if (IsValidSize!T) {
        return *cast(Mod!T*) (memory.ptr + (address & AlignmentMask!T));
    }

    static if (!readOnly) {
        public void set(T)(uint address, T v) if (IsValidSize!T) {
            *cast(Mod!T*) (memory.ptr + (address & AlignmentMask!T)) = v;
        }
    }

    public Mod!(T[]) getArray(T)(uint address = 0x0, uint size = byteSize) if (IsValidSize!T) {
        address &= AlignmentMask!T;
        return cast(Mod!(T[])) (memory[address .. address + size]);
    }

    public Mod!(T*) getPointer(T)(uint address) if (IsValidSize!T) {
        return cast(Mod!T*) (memory.ptr + (address & AlignmentMask!T));
    }

    private template Mod(T) {
        static if (readOnly) {
            private alias Mod = ImmutableOf!T;
        } else {
            private alias Mod = MutableOf!T;
        }
    }
}

public struct IoRegisters {
    private alias ReadMonitor = void delegate(IoRegisters*, int, int, int, ref int);
    private alias PreWriteMonitor = bool delegate(IoRegisters*, int, int, int, ref int);
    private alias PostWriteMonitor = void delegate(IoRegisters*, int, int, int, int, int);
    private MonitoredValue[(IO_REGISTERS_SIZE + int.sizeof - 1) / int.sizeof] monitoredValues;

    public void setReadMonitor(int address)(ReadMonitor monitor) if (IsIntAligned!address) {
        monitoredValues[address >> 2].onRead = monitor;
    }

    public void setPreWriteMonitor(int address)(PreWriteMonitor monitor) if (IsIntAligned!address) {
        monitoredValues[address >> 2].onPreWrite = monitor;
    }

    public void setPostWriteMonitor(int address)(PostWriteMonitor monitor) if (IsIntAligned!address) {
        monitoredValues[address >> 2].onPostWrite = monitor;
    }

    public alias getUnMonitored(T) = get!(T, false);

    public T get(T, bool monitored = true)(uint address) if (IsValidSize!T) {
        alias lsb = Alias!(((1 << SizeBase2Power!T) - 1) ^ 3);
        auto shift = (address & lsb) << 3;
        alias bits = Alias!(cast(uint) ((1L << T.sizeof * 8) - 1));
        auto mask = bits << shift;
        auto alignedAddress = address & ~3;
        auto monitor = monitoredValues.ptr + (alignedAddress >> 2);
        auto value = monitor.value;
        static if (monitored) {
            if (monitor.onRead !is null) {
                monitor.onRead(&this, alignedAddress, shift, mask, value);
            }
        }
        return cast(T) ((value & mask) >> shift);
    }

    public alias setUnMonitored(T) = set!(T, false);

    public void set(T, bool monitored = true)(uint address, T value) if (IsValidSize!T) {
        alias lsb = Alias!(((1 << SizeBase2Power!T) - 1) ^ 3);
        auto shift = (address & lsb) << 3;
        alias bits = Alias!(cast(uint) ((1L << T.sizeof * 8) - 1));
        auto mask = bits << shift;
        static if (is(T == int) || is(T == uint)) {
            int intValue = value;
        } else {
            int intValue = value.ucast() << shift;
        }
        auto alignedAddress = address & ~3;
        auto monitor = monitoredValues.ptr + (alignedAddress >> 2);
        static if (monitored) {
            if (monitor.onPreWrite is null || monitor.onPreWrite(&this, alignedAddress, shift, mask, intValue)) {
                auto oldValue = monitor.value;
                auto newValue = oldValue & ~mask | intValue & mask;
                monitor.value = newValue;
                if (monitor.onPostWrite !is null) {
                    monitor.onPostWrite(&this, alignedAddress, shift, mask, oldValue, newValue);
                }
            }
        } else {
            auto oldValue = monitor.value;
            monitor.value = oldValue & ~mask | intValue & mask;
        }
    }

    private alias IsIntAligned(int address) = Alias!((address & 0b11) == 0);

    private static struct MonitoredValue {
        private ReadMonitor onRead = null;
        private PreWriteMonitor onPreWrite = null;
        private PostWriteMonitor onPostWrite = null;
        private int value;
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
    private void[byteSize] memory;
    private Mode mode = Mode.NORMAL;
    private uint cmdStage = 0;
    private uint eraseSectorTarget;
    private uint sectorOffset = 0;

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

    public T get(T)(uint address) if (is(T == byte) || is(T == ubyte)) {
        if (mode == Mode.ID && address <= DEVICE_ID_ADDRESS) {
            return cast(T) (DeviceID >> ((address & 0b1) << 3));
        }
        return *cast(T*) (memory.ptr + address + sectorOffset);
    }

    public void set(T)(uint address, T value) if (is(T == byte) || is(T == ubyte)) {
        uint intValue = value & 0xFF;
        // Handle commands completions
        switch (mode) {
            case Mode.ERASE_ALL:
                if (address == 0x0 && intValue == 0xFF) {
                    mode = Mode.NORMAL;
                }
                break;
            case Mode.ERASE_SECTOR:
                if (address == eraseSectorTarget && intValue == 0xFF) {
                    mode = Mode.NORMAL;
                }
                break;
            case Mode.WRITE_BYTE:
                *cast(T*) (memory.ptr + address + sectorOffset) = value;
                mode = Mode.NORMAL;
                break;
            case Mode.SWITCH_BANK:
                sectorOffset = (value & 0b1) << 16;
                mode = Mode.NORMAL;
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
                            erase(0x0, byteSize);
                        }
                        break;
                    case WRITE_BYTE_CMD_BYTE:
                        mode = Mode.WRITE_BYTE;
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
                erase(address + sectorOffset, 4 * BYTES_PER_KIB);
            }
        }
    }

    public T[] getArray(T)(uint address = 0x0, uint size = byteSize) if (IsValidSize!T) {
        return cast(T[]) (memory[address .. address + size]);
    }

    private void erase(uint address, uint size) {
        auto byteMemory = cast(byte*) (memory.ptr + address);
        byteMemory[0 .. size] = cast(byte) 0xFF;
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
        (cast(byte[]) memory)[0 .. $] = cast(byte) 0xFF;
    }

    public this(void[] memory) {
        auto byteSize = this.memory.length;
        if (memory.length > byteSize) {
            throw new Exception(format("Expected a memory size of %dB, but got %dB", byteSize, memory.length));
        }
        this.memory[0 .. memory.length] = memory[];
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
        return cast(T[]) (memory[address .. address + size]);
    }

    private static enum Mode {
        NORMAL = 2,
        READ = 1,
        WRITE = 0
    }
}

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
        actualRomByteSize = actualRomByteSize.nextPowerOf2();
        if (saveFile is null) {
            allocateNewSave(saveMemoryForConfiguration[SaveConfiguration.AUTO]);
        } else {
            loadSave(saveFile);
        }
    }

    public this(string romFile, SaveConfiguration saveConfig) {
        rom = GameRom(readFileAndSize(romFile, actualRomByteSize));
        actualRomByteSize = actualRomByteSize.nextPowerOf2();
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
                address &= actualRomByteSize - 1;
                return rom.get!T(address);
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
                    case EEPROM:
                        return cast(T) _unusedMemory(address);
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
                        throw new Error("Unexpected save kind");
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
                        eeprom.set!T(lowAddress & ~eepromMask, value);
                    }
                }
                return;
            case 0x6:
                address &= SAVE_MASK;
                switch (saveKind) with (SaveMemoryKind) {
                    case EEPROM:
                        return;
                    case SRAM:
                        save.sram.set!T(address, value);
                        return;
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
                        throw new Error("Unexpected save kind");
                }
            default:
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
            case EEPROM:
                break;
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
                throw new Error("Unexpected save kind");
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

public struct MemoryBus {
    private Bios _bios;
    private BoardWram _boardWRAM;
    private ChipWram _chipWRAM;
    private IoRegisters _ioRegisters;
    private Palette _palette;
    private Vram _vram;
    private Oam _oam;
    private GamePak _gamePak;
    private int delegate(uint) _unusedMemory = null;
    private bool delegate(uint) _biosReadGuard = null;
    private int delegate(uint) _biosReadFallback = null;

    @disable public this();

    public this(string biosFile, string romFile, SaveConfiguration saveConfig) {
        _bios = Bios(biosFile);
        _gamePak = GamePak(romFile, saveConfig);
    }

    public this(string biosFile, string romFile, string saveFile) {
        _bios = Bios(biosFile);
        _gamePak = GamePak(romFile, saveFile);
    }

    @property public Bios* bios() {
        return &_bios;
    }

    @property public BoardWram* boardWRAM() {
        return &_boardWRAM;
    }

    @property public ChipWram* chipWRAM() {
        return &_chipWRAM;
    }

    @property public IoRegisters* ioRegisters() {
        return &_ioRegisters;
    }

    @property public Palette* palette() {
        return &_palette;
    }

    @property public Vram* vram() {
        return &_vram;
    }

    @property public Oam* oam() {
        return &_oam;
    }

    @property public GamePak* gamePak() {
        return &_gamePak;
    }

    @property public void unusedMemory(int delegate(uint) unusedMemory) {
        assert (unusedMemory !is null);
        _unusedMemory = unusedMemory;
        gamePak.unusedMemory = _unusedMemory;
    }

    @property public void biosReadGuard(bool delegate(uint) biosReadGuard) {
        _biosReadGuard = biosReadGuard;
    }

    @property public void biosReadFallback(int delegate(uint) biosReadFallback) {
        _biosReadFallback = biosReadFallback;
    }

    public T get(T)(uint address) if (IsValidSize!T) {
        auto highAddress = address >>> 24;
        switch (highAddress) {
            case 0x0:
                auto lowAddress = address & 0xFFFFFF;
                if (lowAddress & ~BIOS_MASK) {
                    return cast(T) _unusedMemory(address);
                }
                if (!_biosReadGuard(address)) {
                    return cast(T) _biosReadFallback(address);
                }
                return _bios.get!T(address & BIOS_MASK);
            case 0x1:
                return cast(T) _unusedMemory(address);
            case 0x2:
                return _boardWRAM.get!T(address & BOARD_WRAM_MASK);
            case 0x3:
                return _chipWRAM.get!T(address & CHIP_WRAM_MASK);
            case 0x4:
                if (address > IO_REGISTERS_END) {
                    return cast(T) _unusedMemory(address);
                }
                return _ioRegisters.get!T(address & IO_REGISTERS_MASK);
            case 0x5:
                return _palette.get!T(address & PALETTE_MASK);
            case 0x6:
                address &= VRAM_MASK;
                if (address & ~VRAM_LOWER_MASK) {
                    address &= VRAM_HIGH_MASK;
                }
                return _vram.get!T(address);
            case 0x7:
                return _oam.get!T(address & OAM_MASK);
            case 0x8: .. case 0xE:
                return _gamePak.get!T(address - GAME_PAK_START);
            default:
                return cast(T) _unusedMemory(address);
        }
    }

    public void set(T)(uint address, T value) if (IsValidSize!T) {
        auto highAddress = address >>> 24;
        switch (highAddress) {
            case 0x2:
                _boardWRAM.set!T(address & BOARD_WRAM_MASK, value);
                break;
            case 0x3:
                _chipWRAM.set!T(address & CHIP_WRAM_MASK, value);
                break;
            case 0x4:
                if (address <= IO_REGISTERS_END) {
                    _ioRegisters.set!T(address & IO_REGISTERS_MASK, value);
                }
                break;
            case 0x5:
                static if (is(T == byte) || is(T == ubyte)) {
                    _palette.set!short(address & PALETTE_MASK, value << 8 | value & 0xFF);
                } else {
                    _palette.set!T(address & PALETTE_MASK, value);
                }
                break;
            case 0x6:
                address &= VRAM_MASK;
                if (address & ~VRAM_LOWER_MASK) {
                    address &= VRAM_HIGH_MASK;
                }
                static if (is(T == byte) || is(T == ubyte)) {
                    if (address < 0x10000 || (ioRegisters.getUnMonitored!short(0x0) & 0b111) > 2 && address < 0x14000) {
                        _vram.set!short(address, value << 8 | value & 0xFF);
                    }
                } else {
                    _vram.set!T(address, value);
                }
                break;
            case 0x7:
                static if (!is(T == byte) && !is(T == ubyte)) {
                    _oam.set!T(address & OAM_MASK, value);
                }
                break;
            case 0x8: .. case 0xE:
                _gamePak.set!T(address - GAME_PAK_START, value);
                break;
            default:
        }
    }
}

unittest {
    auto ram = Ram!1024();

    static assert(is(typeof(ram.get!ushort(2)) == ushort));
    static assert(is(typeof(ram.getPointer!ushort(3)) == ushort*));
    static assert(is(typeof(ram.getArray!ushort(5, 2)) == ushort[]));

    ram.set!ushort(2, 34);
    assert(*ram.getPointer!ushort(2) == 34);
    assert(ram.getArray!ushort(2, 8) == [34, 0, 0, 0]);
}

unittest {
    int[] data = [9, 8, 7, 6, 5, 4, 3, 2, 1, 0];
    auto rom = Rom!40(data);

    static assert(!__traits(compiles, Rom!40()));
    static assert(!__traits(compiles, rom.set!int(8, 34)));
    static assert(is(typeof(rom.get!int(4)) == immutable int));
    static assert(is(typeof(rom.getPointer!int(8)) == immutable int*));
    static assert(is(typeof(rom.getArray!int(24, 12)) == immutable int[]));

    assert(rom.get!int(4) == 8);
    assert(*rom.getPointer!int(8) == 7);
    assert(rom.getArray!int(24, 12) == [3, 2, 1]);
}

unittest {
    class TestMonitor {
        int expectedAddress;
        int expectedShift;
        int expectedMask;
        int expectedValue;
        int expectedOldValue;
        int expectedNewValue;

        void expected(int address, int shift, int mask, int value) {
            expectedAddress = address;
            expectedShift = shift;
            expectedMask = mask;
            expectedValue = value;
        }

        void expected(int address, int shift, int mask, int preWriteValue, int oldValue, int newValue) {
            expected(address, shift, mask, preWriteValue);
            expectedOldValue = oldValue;
            expectedNewValue = newValue;
        }

        void onRead(IoRegisters* io, int address, int shift, int mask, ref int value) {
            assert (expectedAddress == address);
            assert (expectedShift == shift);
            assert (expectedMask == mask);
            assert (expectedValue == value);
        }

        bool onPreWrite(IoRegisters* io, int address, int shift, int mask, ref int newValue) {
            assert (expectedAddress == address);
            assert (expectedShift == shift);
            assert (expectedMask == mask);
            assert (expectedValue == newValue);
            return true;
        }

        void onPostWrite(IoRegisters* io, int address, int shift, int mask, int oldValue, int newValue) {
            assert (expectedAddress == address);
            assert (expectedShift == shift);
            assert (expectedMask == mask);
            assert (expectedOldValue == oldValue);
            assert (expectedNewValue == newValue);
        }
    }

    auto io = IoRegisters();
    auto monitor = new TestMonitor();

    static assert(!__traits(compiles, io.addReadMonitor!0x2(&monitor.onRead)));

    io.setReadMonitor!0x14(&monitor.onRead);
    io.setPreWriteMonitor!0x14(&monitor.onPreWrite);
    io.setPostWriteMonitor!0x14(&monitor.onPostWrite);

    monitor.expected(0x14, 0, 0xFFFFFFFF, 0x2, 0x0, 0x2);
    io.set!int(0x14, 0x2);
    monitor.expected(0x14, 0, 0xFFFFFFFF, 0x3, 0x2, 0x3);
    io.set!int(0x15, 0x3);
    monitor.expected(0x14, 0, 0xFFFFFFFF, 0x5, 0x3, 0x5);
    io.set!int(0x16, 0x5);
    monitor.expected(0x14, 0, 0xFFFFFFFF, 0x7, 0x5, 0x7);
    io.set!int(0x17, 0x7);

    monitor.expected(0x14, 0, 0xFFFF, 0x2, 0x7, 0x2);
    io.set!short(0x14, 2);
    monitor.expected(0x14, 0, 0xFFFF, 0x3, 0x2, 0x3);
    io.set!short(0x15, 3);
    monitor.expected(0x14, 16, 0xFFFF0000, 0x50000, 0x3, 0x50003);
    io.set!short(0x16, 5);
    monitor.expected(0x14, 16, 0xFFFF0000, 0x70000, 0x50003, 0x70003);
    io.set!short(0x17, 7);

    monitor.expected(0x14, 0, 0xFF, 0x2, 0x70003, 0x70002);
    io.set!byte(0x14, 2);
    monitor.expected(0x14, 8, 0xFF00, 0x300, 0x70002, 0x70302);
    io.set!byte(0x15, 3);
    monitor.expected(0x14, 16, 0xFF0000, 0x50000, 0x70302, 0x50302);
    io.set!byte(0x16, 5);
    monitor.expected(0x14, 24, 0xFF000000, 0x7000000, 0x50302, 0x7050302);
    io.set!byte(0x17, 7);

    monitor.expected(0x14, 0, 0xFF, 0x7050302);
    io.get!byte(0x14);
    monitor.expected(0x14, 8, 0xFF00, 0x7050302);
    io.get!byte(0x15);
    monitor.expected(0x14, 16, 0xFF0000, 0x7050302);
    io.get!byte(0x16);
    monitor.expected(0x14, 24, 0xFF000000, 0x7050302);
    io.get!byte(0x17);

    monitor.expected(0x14, 0, 0xFFFF, 0x7050302);
    io.get!short(0x14);
    monitor.expected(0x14, 0, 0xFFFF, 0x7050302);
    io.get!short(0x15);
    monitor.expected(0x14, 16, 0xFFFF0000, 0x7050302);
    io.get!short(0x16);
    monitor.expected(0x14, 16, 0xFFFF0000, 0x7050302);
    io.get!short(0x17);

    monitor.expected(0x14, 0, 0xFFFFFFFF, 0x7050302);
    io.get!int(0x14);
    monitor.expected(0x14, 0, 0xFFFFFFFF, 0x7050302);
    io.get!int(0x15);
    monitor.expected(0x14, 0, 0xFFFFFFFF, 0x7050302);
    io.get!int(0x16);
    monitor.expected(0x14, 0, 0xFFFFFFFF, 0x7050302);
    io.get!int(0x17);
}
