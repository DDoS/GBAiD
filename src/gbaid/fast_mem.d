module gbaid.fast_mem;

import std.traits : MutableOf, ImmutableOf;
import std.meta : Alias, AliasSeq, staticIndexOf;
import std.file : read, FileException;
import std.format : format;

import gbaid.gamepak;
import gbaid.util;

public alias Ram(uint byteSize) = Memory!(byteSize, false);
public alias Rom(uint byteSize) = Memory!(byteSize, true);

private alias ValidSizes = AliasSeq!(byte, ubyte, short, ushort, int, uint);
// TODO: make me private after merger with gamepak.d
public alias IsValidSize(T) = Alias!(staticIndexOf!(T, ValidSizes) >= 0);

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

public enum uint BYTES_PER_KIB = 1024;
public enum uint BYTES_PER_MIB = BYTES_PER_KIB * BYTES_PER_KIB;

public enum uint BIOS_SIZE = 16 * BYTES_PER_KIB;
public enum uint BOARD_WRAM_SIZE = 256 * BYTES_PER_KIB;
public enum uint CHIP_WRAM_SIZE = 32 * BYTES_PER_KIB;
public enum uint IO_REGISTERS_SIZE = 1 * BYTES_PER_KIB;
public enum uint PALETTE_SIZE = 1 * BYTES_PER_KIB;
public enum uint VRAM_SIZE = 96 * BYTES_PER_KIB;
public enum uint OAM_SIZE = 1 * BYTES_PER_KIB;

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

public struct Memory(uint byteSize, bool readOnly) {
    private Mod!(void[byteSize]) memory;

    static if (readOnly) {
        @disable public this();
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

    public Mod!T get(T)(uint address) if (IsValidSize!T) {
        return *cast(Mod!T*) (memory.ptr + address);
    }

    static if (!readOnly) {
        public void set(T)(uint address, T v) if (IsValidSize!T) {
            *cast(Mod!T*) (memory.ptr + address) = v;
        }
    }

    public Mod!(T[]) getArray(T)(uint address, uint size) if (IsValidSize!T) {
        return cast(Mod!(T[])) memory[address .. address + size];
    }

    public Mod!(T*) getPointer(T)(uint address) if (IsValidSize!T) {
        return cast(Mod!T*) (memory.ptr + address);
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

public alias Bios = Rom!BIOS_SIZE;
public alias BoardWram = Ram!BOARD_WRAM_SIZE;
public alias ChipWram = Ram!CHIP_WRAM_SIZE;
public alias Palette = Ram!PALETTE_SIZE;
public alias Vram = Ram!VRAM_SIZE;
public alias Oam = Ram!OAM_SIZE;

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

    public this(string biosFile, string romFile) {
        _bios = Bios(biosFile);
        _gamePak = GamePak(romFile);
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
                    if (address < 0x10000 || (ioRegisters.get!short(0x0) & 0b111) > 2 && address < 0x14000) {
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
