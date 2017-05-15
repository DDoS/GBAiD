module gbaid.gba.gpio;

import std.conv : to;

public enum uint GPIO_ROM_START_ADDRESS = 0xC4;
public enum uint GPIO_ROM_END_ADDRESS = 0xCA;

public alias IoEmitter = ubyte delegate();
public alias IoReceiver = void delegate(ubyte data);

public struct GpioPort {
    private bool readable = false;
    private ubyte directionFlags = 0b0000;
    private short _valueAtCa = 0;
    private IoReceiver _receiver = null;
    private IoEmitter _emitter = null;

    @property public void valueAtCa(short value) {
        _valueAtCa = value;
    }

    @property public bool enabled() {
        return _receiver !is null && _emitter !is null;
    }

    @property public void emitter(IoEmitter emitter) {
        _emitter = emitter;
    }

    @property public void receiver(IoReceiver receiver) {
        _receiver = receiver;
    }

    public T get(T)(uint address) {
        static if (is(T == int) || is(T == uint)) {
            uint alignedAddress = address & ~0b11;
        } else {
            uint alignedAddress = address & ~0b1;
        }
        short shortValue = void;
        switch (alignedAddress) {
            case 0xC4:
                shortValue = data;
                break;
            case 0xC6:
                shortValue = direction;
                break;
            case 0xC8:
                shortValue = data;
                break;
            case 0xCA:
                shortValue = _valueAtCa;
                break;
            default:
                throw new Exception("Invalid GPIO address: " ~ address.to!string);
        }
        static if (is(T == byte) || is(T == ubyte)) {
            return cast(byte) (shortValue >>> (address & 0b1) * 8);
        } else static if (is(T == short) || is(T == ushort)) {
            return shortValue;
        } else static if (is(T == int) || is(T == uint)) {
            return get!short(alignedAddress + 2) << 16 | shortValue & 0xFFFF;
        } else {
            static assert (0);
        }
    }

    public void set(T)(uint address, T value) {
        static if (is(T == byte) || is(T == ubyte)) {
            short shortValue = cast(short) ((value & 0xFF) << (address & 0b1) * 8);
            address &= ~0b1;
        } else static if (is(T == short) || is(T == ushort)) {
            short shortValue = value;
            address &= ~0b1;
        } else static if (is(T == int) || is(T == uint)) {
            short shortValue = cast(short) value;
            address &= ~0b11;
            set!short(address + 2, cast(short) (value >>> 16));
        } else {
            static assert (0);
        }
        switch (address) {
            case 0xC4:
                data = shortValue;
                break;
            case 0xC6:
                direction = shortValue;
                break;
            case 0xC8:
                data = shortValue;
                break;
            case 0xCA:
                break;
            default:
                throw new Exception("Invalid GPIO address: " ~ address.to!string);
        }
    }

    @property private short direction() {
        if (!readable) {
            return 0;
        }
        return cast(short) readable & 0b1;
    }

    @property private void direction(short value) {
        readable = value & 0b1;
    }

    @property private short control() {
        if (!readable) {
            return 0;
        }
        return cast(short) directionFlags & 0b1111;
    }

    @property private void control(short value) {
        directionFlags = value & 0b1111;
    }

    @property private short data() {
        if (!readable) {
            return 0;
        }
        return cast(short) _emitter() & directionFlags;
    }

    @property private void data(short value) {
        _receiver(value & (~directionFlags & 0b1111));
    }
}
