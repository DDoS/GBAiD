module gbaid.gba.gpio;

import std.conv : to;
import std.meta : AliasSeq;

import gbaid.util;

public enum uint GPIO_ROM_START_ADDRESS = 0xC4;
public enum uint GPIO_ROM_END_ADDRESS = 0xCA;

public alias IoPinOut = bool delegate();
public alias IoPinIn = void delegate(bool pin);

public struct GpioChip {
    mixin declareFields!(IoPinOut, false, "readPin", null, 4);
    mixin declareFields!(IoPinIn, false, "writePin", null, 4);
}

public struct GpioPort {
    public bool enabled = false;
    private bool readable = false;
    private ubyte directionFlags = 0b0000;
    private short _valueAtCa = 0;
    private GpioChip _chip;

    @property public void valueAtCa(short value) {
        _valueAtCa = value;
    }

    @property public void chip(GpioChip chip) {
        _chip = chip;
    }

    public T get(T)(uint address) {
        // 32 bit reads must be aligned at 4 instead of 2
        static if (is(T == int) || is(T == uint)) {
            uint alignedAddress = address & ~0b11;
        } else {
            uint alignedAddress = address & ~0b1;
        }
        // Read the value from the register
        short shortValue = void;
        switch (alignedAddress) {
            case 0xC4:
                shortValue = data;
                break;
            case 0xC6:
                shortValue = direction;
                break;
            case 0xC8:
                shortValue = control;
                break;
            case 0xCA:
                shortValue = _valueAtCa;
                break;
            default:
                throw new Exception("Invalid GPIO address: " ~ address.to!string);
        }
        // Convert the register value to the correct format
        static if (is(T == byte) || is(T == ubyte)) {
            return cast(byte) (shortValue >>> (address & 0b1) * 8);
        } else static if (is(T == short) || is(T == ushort)) {
            return shortValue;
        } else static if (is(T == int) || is(T == uint)) {
            // For ints, we must do a second read for the upper bits
            return get!short(alignedAddress + 2) << 16 | shortValue & 0xFFFF;
        } else {
            static assert (0);
        }
    }

    public void set(T)(uint address, T value) {
        // Convert the value to a short based on the address, and align the address to the correct register
        static if (is(T == byte) || is(T == ubyte)) {
            short shortValue = cast(short) ((value & 0xFF) << (address & 0b1) * 8);
            address &= ~0b1;
        } else static if (is(T == short) || is(T == ushort)) {
            short shortValue = value;
            address &= ~0b1;
        } else static if (is(T == int) || is(T == uint)) {
            short shortValue = cast(short) value;
            address &= ~0b11;
            // For ints, we must do a second write for the upper bits
            set!short(address + 2, cast(short) (value >>> 16));
        } else {
            static assert (0);
        }
        // Write the value
        switch (address) {
            case 0xC4:
                data = shortValue;
                break;
            case 0xC6:
                direction = shortValue;
                break;
            case 0xC8:
                control = shortValue;
                break;
            case 0xCA:
                break;
            default:
                throw new Exception("Invalid GPIO address: " ~ address.to!string);
        }
    }

    @property private short control() {
        if (!readable) {
            return 0;
        }
        return cast(short) readable.checkBit(0);
    }

    @property private void control(short value) {
        readable = value.checkBit(0);
    }

    @property private short direction() {
        if (!readable) {
            return 0;
        }
        return cast(short) directionFlags.getBits(0, 3);
    }

    @property private void direction(short value) {
        directionFlags = cast(ubyte) value.getBits(0, 3);
    }

    @property private short data() {
        if (!readable) {
            return 0;
        }
        // Read from the input pins
        int data = 0;
        foreach (pin; AliasSeq!(0, 1, 2, 3)) {
            if (!directionFlags.checkBit(pin)) {
                data.setBit(pin, _chip.readPin!pin());
            }
        }
        return cast(short) data;
    }

    @property private void data(short value) {
        // Write to the output pins
        foreach (pin; AliasSeq!(0, 1, 2, 3)) {
            if (directionFlags.checkBit(pin)) {
                _chip.writePin!pin(value.checkBit(pin));
            }
        }
    }
}
