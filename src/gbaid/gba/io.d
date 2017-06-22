module gbaid.gba.io;

import std.meta : Alias;
import std.format : format;

import gbaid.util;

public enum uint IO_REGISTERS_SIZE = 1 * BYTES_PER_KIB;

public struct IoRegisters {
    private Register[][IO_REGISTERS_SIZE / int.sizeof] registerSets;

    public auto mapAddress(T)(uint address, T* valuePtr, int mask, int shift,
            bool readable = true, bool writable = true) {
        if ((address & 0b11) != 0) {
            throw new Exception(format("Address %08x is not 4 byte aligned", address));
        }
        if (address >= IO_REGISTERS_SIZE) {
            throw new Exception(format("Address out of bounds: %08x >= %08x", address, IO_REGISTERS_SIZE));
        }
        address >>>= 2;
        foreach (register; registerSets[address]) {
            if ((mask << shift) & (register.mask << register.shift)) {
                throw new Exception("Overlapping masks");
            }
        }

        registerSets[address] ~= Register(valuePtr, mask, shift, readable, writable);

        struct Builder {
            Register* register;

            Builder readMonitor(ReadMonitor monitor) {
                register.onRead = monitor;
                return this;
            }

            Builder preWriteMonitor(PreWriteMonitor monitor) {
                register.onPreWrite = monitor;
                return this;
            }

            Builder postWriteMonitor(PostWriteMonitor monitor) {
                register.onPostWrite = monitor;
                return this;
            }
        }

        return Builder(&registerSets[address][$ - 1]);
    }

    private alias lsb(T) = Alias!(((1 << IntSizeLog2!T) - 1) ^ 0b11);
    private alias bits(T) = Alias!(cast(int) ((1L << T.sizeof * 8) - 1));

    public alias getUnMonitored(T) = get!(T, false);

    public T get(T, bool monitored = true)(uint address) if (IsInt8to32Type!T) {
        auto shift = (address & lsb!T) << 3;
        auto mask = bits!T << shift;
        auto registers = registerSets[(address & ~3) >>> 2];
        int readValue = 0;
        foreach (register; registers) {
            if (!register.readable) {
                continue;
            }
            auto modifiedMask = (mask >>> register.shift) & register.mask;
            if (modifiedMask == 0) {
                continue;
            }
            auto value = register.value & modifiedMask;
            static if (monitored) {
                if (register.onRead !is null) {
                    register.onRead(modifiedMask, value);
                }
            }
            readValue |= (value & modifiedMask) << register.shift;
        }
        static if (is(T == uint) || is(T == int)) {
            return readValue;
        } else {
            return cast(T) (readValue >>> shift);
        }
    }

    public alias setUnMonitored(T) = set!(T, false);

    public void set(T, bool monitored = true)(uint address, T value) if (IsInt8to32Type!T) {
        auto shift = (address & lsb!T) << 3;
        auto mask = bits!T << shift;
        static if (is(T == uint) || is(T == int)) {
            int intValue = value;
        } else {
            int intValue = value.ucast() << shift;
        }
        auto registers = registerSets[(address & ~3) >>> 2];
        foreach (register; registers) {
            if (!register.writable) {
                continue;
            }
            auto modifiedMask = (mask >>> register.shift) & register.mask;
            if (modifiedMask == 0) {
                continue;
            }
            auto newValue = (intValue >>> register.shift) & modifiedMask;
            static if (monitored) {
                if (register.onPreWrite is null || register.onPreWrite(modifiedMask, newValue)) {
                    auto oldValue = register.value & modifiedMask;
                    newValue &= modifiedMask;
                    register.value = newValue | register.value & ~modifiedMask;
                    if (register.onPostWrite !is null) {
                        register.onPostWrite(modifiedMask, oldValue, newValue);
                    }
                }
            } else {
                register.value = newValue;
            }
        }
    }
}

private alias ReadMonitor = void delegate(int, ref int);
private alias PreWriteMonitor = bool delegate(int, ref int);
private alias PostWriteMonitor = void delegate(int, int, int);

private union ValuePtr {
    bool* valueBool;
    byte* valueByte;
    short* valueShort;
    int* valueInt;
}

private enum ValueSize {
    BOOL, BYTE, SHORT, INT
}

private struct Register {
    private ReadMonitor onRead = null;
    private PreWriteMonitor onPreWrite = null;
    private PostWriteMonitor onPostWrite = null;
    private ValuePtr valuePtr;
    private int valueSize;
    private int mask;
    private int shift;
    private bool readable;
    private bool writable;

    private this(T)(T* valuePtr, int mask, int shift, bool readable, bool writable) {
        this.mask = mask;
        this.shift = shift;
        this.readable = readable;
        this.writable = writable;

        static if (is(T == bool)) {
            this.valuePtr.valueBool = valuePtr;
            valueSize = ValueSize.BOOL;
        } else static if (is(T == byte)) {
            this.valuePtr.valueByte = valuePtr;
            valueSize = ValueSize.BYTE;
        } else static if (is(T == short)) {
            this.valuePtr.valueShort = valuePtr;
            valueSize = ValueSize.SHORT;
        } else static if (is(T == int)) {
            this.valuePtr.valueInt = valuePtr;
            valueSize = ValueSize.INT;
        } else {
            static assert (0);
        }
    }

    @property
    private int value() {
        final switch (valueSize) with (ValueSize) {
            case BOOL:
                return *valuePtr.valueBool & 0b1;
            case BYTE:
                return *valuePtr.valueByte & 0xFF;
            case SHORT:
                return *valuePtr.valueShort & 0xFFFF;
            case INT:
                return *valuePtr.valueInt;
        }
    }

    @property
    private void value(int value) {
        final switch (valueSize) with (ValueSize) {
            case BOOL:
                *valuePtr.valueBool = cast(bool) value;
                break;
            case BYTE:
                *valuePtr.valueByte = cast(byte) value;
                break;
            case SHORT:
                *valuePtr.valueShort = cast(short) value;
                break;
            case INT:
                *valuePtr.valueInt = value;
                break;
        }
    }
}

unittest {
    class TestMonitor {
        int expectedMask;
        int expectedValue;
        int expectedOldValue;
        int expectedNewValue;

        void expected(int mask, int value) {
            expectedMask = mask;
            expectedValue = value;
        }

        void expected(int mask, int preWriteValue, int oldValue, int newValue) {
            expected(mask, preWriteValue);
            expectedOldValue = oldValue;
            expectedNewValue = newValue;
        }

        void onRead(int mask, ref int value) {
            assert (expectedMask == mask);
            assert (expectedValue == value);
        }

        bool onPreWrite(int mask, ref int newValue) {
            assert (expectedMask == mask);
            assert (expectedValue == newValue);
            return true;
        }

        void onPostWrite(int mask, int oldValue, int newValue) {
            assert (expectedMask == mask);
            assert (expectedOldValue == oldValue);
            assert (expectedNewValue == newValue);
        }
    }

    auto io = IoRegisters();
    auto monitor1 = new TestMonitor();
    auto monitor2 = new TestMonitor();
    auto monitor3 = new TestMonitor();
    auto monitor4 = new TestMonitor();

    bool data1 = false;
    byte data2 = 0;
    short data3 = 0;
    int data4 = 0;

    io.mapAddress(0x10, &data1, 0b1, 9)
            .readMonitor(&monitor1.onRead)
            .preWriteMonitor(&monitor1.onPreWrite)
            .postWriteMonitor(&monitor1.onPostWrite);
    io.mapAddress(0x10, &data2, 0xDF, 10)
            .readMonitor(&monitor2.onRead)
            .preWriteMonitor(&monitor2.onPreWrite)
            .postWriteMonitor(&monitor2.onPostWrite);
    io.mapAddress(0x14, &data3, 0xFCCF, 16)
            .readMonitor(&monitor3.onRead)
            .preWriteMonitor(&monitor3.onPreWrite)
            .postWriteMonitor(&monitor3.onPostWrite);
    io.mapAddress(0x18, &data4, 0xFFFFFF, 0)
            .readMonitor(&monitor4.onRead)
            .preWriteMonitor(&monitor4.onPreWrite)
            .postWriteMonitor(&monitor4.onPostWrite);

    monitor1.expected(0b1, 0b1, 0b0, 0b1);
    monitor2.expected(0xDF, 0b1, 0b0, 0b1);
    io.set!int(0x10, 0x700);
    assert (io.get!int(0x10) == 0x600);
    assert (data1);
    assert (data2 == cast(byte) 0b1);

    monitor3.expected(0xFCCF, 0xFCCF, 0, 0xFCCF);
    io.set!int(0x14, 0xFFFFFFFF);
    assert (io.get!int(0x14) == 0xFCCF0000);
    assert (data3 == cast(short) 0xFCCF);

    monitor4.expected(0x00FFFFFF, 0x00356789, 0, 0x00356789);
    io.set!int(0x18, 0x12356789);
    assert (io.get!int(0x18) == 0x00356789);
    assert (data4 == 0x00356789);

    monitor4.expected(0x00FF0000, 0x00CD0000, 0x00350000, 0x00CD0000);
    io.set!short(0x1A, cast(short) 0xABCD);
    monitor4.expected(0x00FFFFFF, 0x00CD6789);
    assert (io.get!int(0x18) == 0x00CD6789);
    assert (data4 == 0x00CD6789);

    monitor4.expected(0x00FF0000, 0x00CD0000);
    assert (io.get!short(0x1A) == 0x00CD);
}
