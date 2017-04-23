module gbaid.gba.keypad;

import gbaid.util;

import gbaid.gba.memory;
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

public struct KeypadState {
    private enum short CLEARED = 0b1111111111;
    private short bits = CLEARED;

    public void clear() {
        bits = CLEARED;
    }

    public bool isPressed(Button button) {
        return !bits.checkBit(button);
    }

    public void setPressed(Button button, bool pressed = true) {
        if (pressed) {
            bits &= ~(1 << button);
        } else {
            bits |= 1 << button;
        }
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
    private IoRegisters* ioRegisters;
    private InterruptHandler interruptHandler;
    private KeypadState state;
    private ptrdiff_t cyclesUntilNextUpdate = 0;

    public this(IoRegisters* ioRegisters, InterruptHandler interruptHandler) {
        this.ioRegisters = ioRegisters;
        this.interruptHandler = interruptHandler;
    }

    public void setState(KeypadState state) {
        this.state = state;
    }

    public size_t emulate(size_t cycles) {
        cyclesUntilNextUpdate -= cycles;
        if (cyclesUntilNextUpdate <= 0) {
            cyclesUntilNextUpdate += CYCLES_PER_FRAME;
            ioRegisters.setUnMonitored!short(0x130, state.bits);
            int control = ioRegisters.getUnMonitored!short(0x132);
            if (checkBit(control, 14)) {
                int state = ~state.bits & 0x3FF;
                int requested = control & 0x3FF;
                if (checkBit(control, 15)) {
                    if ((state & requested) == requested) {
                        interruptHandler.requestInterrupt(InterruptSource.KEYPAD);
                    }
                } else if (state & requested) {
                    interruptHandler.requestInterrupt(InterruptSource.KEYPAD);
                }
            }
        }
        return 0;
    }
}
