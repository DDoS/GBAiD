module gbaid.gba.memory;

import core.time : TickDuration;

import std.meta : Alias;
import std.traits : ImmutableOf;
import std.format : format;

import gbaid.util;

import gbaid.gba.io;
import gbaid.gba.gpio;
import gbaid.gba.rtc;
import gbaid.gba.interrupt;

public import gbaid.gba.rtc : RTC_SIZE;

public alias Ram(uint byteSize) = Memory!(byteSize, false);
public alias Rom(uint byteSize) = Memory!(byteSize, true);

public alias Bios = Rom!BIOS_SIZE;
public alias BoardWram = Ram!BOARD_WRAM_SIZE;
public alias ChipWram = Ram!CHIP_WRAM_SIZE;
public alias Palette = Ram!PALETTE_SIZE;
public alias Vram = Ram!VRAM_SIZE;
public alias Oam = Ram!OAM_SIZE;
public alias GameRom = Rom!MAX_ROM_SIZE;
public alias Sram = Ram!SRAM_SIZE;
public alias Flash512K = Flash!FLASH_512K_SIZE;
public alias Flash1M = Flash!FLASH_1M_SIZE;

public enum MainSaveKind {
    SRAM, FLASH_512K, FLASH_1M, NONE
}

public enum uint BIOS_SIZE = 16 * BYTES_PER_KIB;
public enum uint BOARD_WRAM_SIZE = 256 * BYTES_PER_KIB;
public enum uint CHIP_WRAM_SIZE = 32 * BYTES_PER_KIB;
public enum uint IO_REGISTERS_SIZE = 1 * BYTES_PER_KIB;
public enum uint PALETTE_SIZE = 1 * BYTES_PER_KIB;
public enum uint VRAM_SIZE = 96 * BYTES_PER_KIB;
public enum uint OAM_SIZE = 1 * BYTES_PER_KIB;
public enum uint MAX_ROM_SIZE = 32 * BYTES_PER_MIB;
public enum uint SRAM_SIZE = 32 * BYTES_PER_KIB;
public enum uint FLASH_512K_SIZE = 64 * BYTES_PER_KIB;
public enum uint FLASH_1M_SIZE = 128 * BYTES_PER_KIB;
public enum uint EEPROM_SIZE = 8 * BYTES_PER_KIB;

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
public enum uint SRAM_MASK = 0x7FFF;
public enum uint FLASH_MASK = 0xFFFF;
public enum uint EEPROM_MASK_NARROW = 0xFFFF00;
public enum uint EEPROM_MASK_WIDE = 0x0;

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

    public Mod!T get(T)(uint address) if (IsInt8to32Type!T) {
        return *cast(Mod!T*) (memory.ptr + (address & IntAlignMask!T));
    }

    static if (!readOnly) {
        public void set(T)(uint address, T v) if (IsInt8to32Type!T) {
            *cast(Mod!T*) (memory.ptr + (address & IntAlignMask!T)) = v;
        }
    }

    public Mod!(T[]) getArray(T)(uint address = 0x0, uint size = byteSize) if (IsInt8to32Type!T) {
        address &= IntAlignMask!T;
        return cast(Mod!(T[])) (memory[address .. address + size]);
    }

    public Mod!(T*) getPointer(T)(uint address) if (IsInt8to32Type!T) {
        return cast(Mod!T*) (memory.ptr + (address & IntAlignMask!T));
    }

    private template Mod(T) {
        static if (readOnly) {
            private alias Mod = ImmutableOf!T;
        } else {
            private alias Mod = T;
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
    private void[byteSize] memory;
    private Mode mode = Mode.NORMAL;
    private uint cmdStage = 0;
    private uint eraseSectorTarget;
    private uint sectorOffset = 0;

    public this(void[] memory) {
        if (memory.length == 0) {
            this.erase(0x0, byteSize);
        } else if (memory.length <= byteSize) {
            this.memory[0 .. memory.length] = memory[];
        } else {
            throw new Exception(format("Expected a memory size of 0 or %dB, but got %dB", byteSize, memory.length));
        }
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

    public T[] getArray(T)(uint address = 0x0, uint size = byteSize) if (IsInt8to32Type!T) {
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

    public this(void[] memory) {
        auto byteSize = this.memory.length;
        if (memory.length == 0) {
            (cast(byte[]) memory)[0 .. $] = cast(byte) 0xFF;
        } else if (memory.length <= byteSize) {
            this.memory[0 .. memory.length] = memory[];
        } else {
            throw new Exception(format("Expected a memory size of 0 or %dB, but got %dB", byteSize, memory.length));
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

    public T[] getArray(T)(uint address = 0x0, uint size = EEPROM_SIZE) if (IsInt8to32Type!T) {
        return cast(T[]) (memory[address .. address + size]);
    }

    private static enum Mode {
        NORMAL = 2,
        READ = 1,
        WRITE = 0
    }
}

public struct GamePakData {
    public void[] rom;
    public void[] mainSave;
    public MainSaveKind mainSaveKind;
    public void[] eeprom;
    public bool eepromEnabled;
    public void[] rtc;
    public bool rtcEnabled;
}

private union SaveMemory {
    private Sram* sram;
    private Flash512K* flash512k;
    private Flash1M* flash1m;
}

public struct GamePak {
    private GameRom rom;
    private GpioPort gpio;
    private MainSaveKind saveKind;
    private SaveMemory save;
    private Eeprom* eeprom = null;
    private Rtc* rtc = null;
    private int delegate(uint) _unusedMemory = null;
    private uint eepromMask;
    private uint actualRomByteSize;

    @disable public this();

    public this(GamePakData data) {
        rom = GameRom(data.rom);
        actualRomByteSize = (cast(int) data.rom.length).nextPowerOf2();
        eepromMask = actualRomByteSize <= 16 * BYTES_PER_MIB ? EEPROM_MASK_WIDE : EEPROM_MASK_NARROW;
        gpio.valueAtCa = rom.get!short(0xCA);

        saveKind = data.mainSaveKind;
        final switch (saveKind) with (MainSaveKind) {
            case SRAM:
                save.sram = new Sram(data.mainSave);
                break;
            case FLASH_512K:
                save.flash512k = new Flash512K(data.mainSave);
                break;
            case FLASH_1M:
                save.flash1m = new Flash1M(data.mainSave);
                break;
            case NONE:
                break;
        }
        if (data.eepromEnabled) {
            eeprom = new Eeprom(data.eeprom);
        }
        if (data.rtcEnabled) {
            rtc = new Rtc(data.rtc);
            gpio.chip = rtc.chip;
            gpio.enabled = true;
        }
    }

    @property public GamePakData saveData() {
        GamePakData data;
        data.mainSaveKind = saveKind;
        final switch (saveKind) with (MainSaveKind) {
            case SRAM:
                data.mainSave = save.sram.getArray!ubyte();
                break;
            case FLASH_512K:
                data.mainSave = save.flash512k.getArray!ubyte();
                break;
            case FLASH_1M:
                data.mainSave = save.flash1m.getArray!ubyte();
                break;
            case NONE:
                data.mainSave = null;
                break;
        }
        if (eeprom !is null) {
            data.eeprom = eeprom.getArray!ubyte();
            data.eepromEnabled = true;
        } else {
            data.eepromEnabled = false;
        }
        if (rtc !is null) {
            data.rtc = rtc.dataArray;
            data.rtcEnabled = true;
        } else {
            data.rtcEnabled = false;
        }
        return data;
    }

    @property public void interruptHandler(InterruptHandler interruptHandler) {
        if (rtc !is null) {
            rtc.interruptHandler = interruptHandler;
        }
    }

    @property public void unusedMemory(int delegate(uint) unusedMemory) {
        assert (unusedMemory !is null);
        _unusedMemory = unusedMemory;
    }

    public T get(T)(uint address) if (IsInt8to32Type!T) {
        auto highAddress = address >>> 24;
        switch (highAddress) {
            case 0x0: .. case 0x4:
                address &= actualRomByteSize - 1;
                if (address >= GPIO_ROM_START_ADDRESS && address < GPIO_ROM_END_ADDRESS && gpio.enabled) {
                    return gpio.get!T(address);
                }
                return rom.get!T(address);
            case 0x5:
                auto lowAddress = address & 0xFFFFFF;
                if (eeprom !is null && (lowAddress & eepromMask) == eepromMask) {
                    static if (is(T == short) || is(T == ushort)) {
                        return eeprom.get!T(lowAddress & ~eepromMask);
                    } else {
                        return cast(T) _unusedMemory(address & IntAlignMask!T);
                    }
                }
                goto case 0x4;
            case 0x6:
                final switch (saveKind) with (MainSaveKind) {
                    case SRAM:
                        address &= SRAM_MASK;
                        return save.sram.get!T(address);
                    case FLASH_512K:
                        static if (is(T == byte) || is(T == ubyte)) {
                            address &= FLASH_MASK;
                            return save.flash512k.get!T(address);
                        } else {
                            return cast(T) _unusedMemory(address & IntAlignMask!T);
                        }
                    case FLASH_1M:
                        static if (is(T == byte) || is(T == ubyte)) {
                            address &= FLASH_MASK;
                            return save.flash1m.get!T(address);
                        } else {
                            return cast(T) _unusedMemory(address & IntAlignMask!T);
                        }
                    case NONE:
                        return cast(T) _unusedMemory(address & IntAlignMask!T);
                }
            default:
                return cast(T) _unusedMemory(address & IntAlignMask!T);
        }
    }

    public void set(T)(uint address, T value) if (IsInt8to32Type!T) {
        auto highAddress = address >>> 24;
        switch (highAddress) {
            case 0x0: .. case 0x4:
                address &= actualRomByteSize - 1;
                if (address >= GPIO_ROM_START_ADDRESS && address < GPIO_ROM_END_ADDRESS && gpio.enabled) {
                    gpio.set!T(address, value);
                }
                return;
            case 0x5:
                auto lowAddress = address & 0xFFFFFF;
                if (eeprom !is null && (lowAddress & eepromMask) == eepromMask) {
                    static if (is(T == short) || is(T == ushort)) {
                        eeprom.set!T(lowAddress & ~eepromMask, value);
                    }
                }
                return;
            case 0x6:
                final switch (saveKind) with (MainSaveKind) {
                    case SRAM:
                        address &= SRAM_MASK;
                        save.sram.set!T(address, value);
                        return;
                    case FLASH_512K:
                        static if (is(T == byte) || is(T == ubyte)) {
                            address &= FLASH_MASK;
                            save.flash512k.set!T(address, value);
                        }
                        return;
                    case FLASH_1M:
                        static if (is(T == byte) || is(T == ubyte)) {
                            address &= FLASH_MASK;
                            save.flash1m.set!T(address, value);
                        }
                        return;
                    case NONE:
                        return;
                }
            default:
                return;
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
    private int delegate(uint) _unusedMemory;
    private bool delegate(uint) _biosReadGuard;
    private int delegate(uint) _biosReadFallback = null;

    @disable public this();

    public this(void[] bios, GamePakData gamePakData) {
        _bios = Bios(bios);
        _gamePak = GamePak(gamePakData);
        _unusedMemory = &zeroUnusedMemory;
        _biosReadGuard = &noBiosReadGuard;
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

    private int zeroUnusedMemory(uint address) {
        return 0;
    }

    private bool noBiosReadGuard(uint address) {
        return true;
    }

    public T get(T)(uint address) if (IsInt8to32Type!T) {
        auto highAddress = address >>> 24;
        switch (highAddress) {
            case 0x0:
                auto lowAddress = address & 0xFFFFFF;
                if (lowAddress & ~BIOS_MASK) {
                    return cast(T) _unusedMemory(address & IntAlignMask!T);
                }
                auto alignedAddress = address & IntAlignMask!T;
                if (!_biosReadGuard(alignedAddress)) {
                    return cast(T) _biosReadFallback(alignedAddress);
                }
                return _bios.get!T(address & BIOS_MASK);
            case 0x1:
                return cast(T) _unusedMemory(address & IntAlignMask!T);
            case 0x2:
                return _boardWRAM.get!T(address & BOARD_WRAM_MASK);
            case 0x3:
                return _chipWRAM.get!T(address & CHIP_WRAM_MASK);
            case 0x4:
                if (address > IO_REGISTERS_END) {
                    return cast(T) _unusedMemory(address & IntAlignMask!T);
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
                return cast(T) _unusedMemory(address & IntAlignMask!T);
        }
    }

    public void set(T)(uint address, T value) if (IsInt8to32Type!T) {
        auto highAddress = address >>> 24;
        switch (highAddress) {
            case 0x2:
                _boardWRAM.set!T(address & BOARD_WRAM_MASK, value);
                return;
            case 0x3:
                _chipWRAM.set!T(address & CHIP_WRAM_MASK, value);
                return;
            case 0x4:
                if (address <= IO_REGISTERS_END) {
                    _ioRegisters.set!T(address & IO_REGISTERS_MASK, value);
                }
                return;
            case 0x5:
                static if (is(T == byte) || is(T == ubyte)) {
                    _palette.set!short(address & PALETTE_MASK, value << 8 | value & 0xFF);
                } else {
                    _palette.set!T(address & PALETTE_MASK, value);
                }
                return;
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
                return;
            case 0x7:
                static if (!is(T == byte) && !is(T == ubyte)) {
                    _oam.set!T(address & OAM_MASK, value);
                }
                return;
            case 0x8: .. case 0xE:
                _gamePak.set!T(address - GAME_PAK_START, value);
                return;
            default:
                return;
        }
    }
}

public int rotateRead(int address, int value) {
    return value.rotateRight((address & 3) << 3);
}

public int rotateRead(int address, short value) {
    return rotateRight(value & 0xFFFF, (address & 1) << 3);
}

public int rotateReadSigned(int address, short value) {
    return value >> ((address & 1) << 3);
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
