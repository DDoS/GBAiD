module gbaid.gba.keypad;

import gbaid.util;

import gbaid.gba.io;
import gbaid.gba.interrupt;
import gbaid.gba.display : CYCLES_PER_FRAME;

public enum Button {
    A = 0,
    B = 1,
    SELECT = 2,
    START = 3,
    RIGHT = 4,
    LEFT = 5,
    UP = 6,
    DOWN = 7,
    R = 8,
    L = 9
}

private enum STATE_BITS_CLEARED = 0b1111111111;

public struct KeypadState {
    private int bits = STATE_BITS_CLEARED;

    public void clear() {
        bits = STATE_BITS_CLEARED;
    }

    public bool isPressed(Button button) {
        return !bits.checkBit(button);
    }

    public void setPressed(Button button, bool pressed = true) {
        bits.setBit(button, !pressed);
    }

    public KeypadState opBinary(string op)(KeypadState that) if (op == "|") {
        KeypadState combined;
        combined.bits = this.bits & that.bits;
        return combined;
    }

    public KeypadState opOpAssign(string op)(KeypadState that) if (op == "|") {
        bits &= that.bits;
        return this;
    }
}

public class Keypad {
    private InterruptHandler interruptHandler;
    private ptrdiff_t cyclesUntilNextUpdate = 0;
    private int stateBits = STATE_BITS_CLEARED;
    private int control = 0;

    public this(IoRegisters* ioRegisters, InterruptHandler interruptHandler) {
        this.interruptHandler = interruptHandler;

        ioRegisters.mapAddress(0x130, &stateBits, 0x3FF, 0, true, false);
        ioRegisters.mapAddress(0x130, &control, 0xC3FF, 16);
    }

    public void setState(KeypadState state) {
        stateBits = state.bits;
    }

    public size_t emulate(size_t cycles) {
        cyclesUntilNextUpdate -= cycles;
        if (cyclesUntilNextUpdate > 0) {
            return 0;
        }
        cyclesUntilNextUpdate += CYCLES_PER_FRAME;
        if (control.checkBit(14)) {
            auto pressedBits = ~stateBits & 0x3FF;
            auto requested = control & 0x3FF;
            if (control.checkBit(15)) {
                if ((pressedBits & requested) == requested) {
                    interruptHandler.requestInterrupt(InterruptSource.KEYPAD);
                }
            } else if (pressedBits & requested) {
                interruptHandler.requestInterrupt(InterruptSource.KEYPAD);
            }
        }
        return 0;
    }
}
