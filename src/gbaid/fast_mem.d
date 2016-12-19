module gbaid.fast_mem;

import std.traits : MutableOf, ImmutableOf;
import std.meta : Alias, AliasSeq, staticIndexOf;
import std.file : read, FileException;

import gbaid.util;

public alias Ram(uint byteSize) = Memory!(byteSize, false);
public alias Rom(uint byteSize) = Memory!(byteSize, true);

private alias ValidSizes = AliasSeq!(byte, ubyte, short, ushort, int, uint);
private alias IsValidSize(T) = Alias!(staticIndexOf!(T, ValidSizes) >= 0);

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
        assert(memory.length == byteSize);
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

    public void addReadMonitor(int address)(ReadMonitor monitor) if (IsIntAligned!address) {
        monitoredValues[address >> 2].onRead = monitor;
    }

    public void addPreWriteMonitor(int address)(PreWriteMonitor monitor) if (IsIntAligned!address) {
        monitoredValues[address >> 2].onPreWrite = monitor;
    }

    public void addPostWriteMonitor(int address)(PostWriteMonitor monitor) if (IsIntAligned!address) {
        monitoredValues[address >> 2].onPostWrite = monitor;
    }

    public T get(T)(uint address) if (IsValidSize!T) {
        alias lsb = Alias!(((1 << SizeBase2Power!T) - 1) ^ 3);
        auto shift = (address & lsb) << 3;
        alias bits = Alias!(cast(uint) ((1L << T.sizeof * 8) - 1));
        auto mask = bits << shift;
        auto alignedAddress = address & ~3;
        auto monitor = monitoredValues.ptr + (alignedAddress >> 2);
        auto value = monitor.value;
        if (monitor.onRead !is null) {
            monitor.onRead(&this, alignedAddress, shift, mask, value);
        }
        return cast(T) ((value & mask) >> shift);
    }

    public void set(T)(uint address, T value) if (IsValidSize!T) {
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
        if (monitor.onPreWrite is null || monitor.onPreWrite(&this, alignedAddress, shift, mask, intValue)) {
            auto oldValue = monitor.value;
            auto newValue = oldValue & ~mask | intValue & mask;
            monitor.value = newValue;
            if (monitor.onPostWrite !is null) {
                monitor.onPostWrite(&this, alignedAddress, shift, mask, oldValue, newValue);
            }
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

    io.addReadMonitor!0x14(&monitor.onRead);
    io.addPreWriteMonitor!0x14(&monitor.onPreWrite);
    io.addPostWriteMonitor!0x14(&monitor.onPostWrite);

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
