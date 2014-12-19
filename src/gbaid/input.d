module gbaid.input;

import core.thread;
import core.time;

import derelict.sdl2.sdl;

import gbaid.system;
import gbaid.memory;
import gbaid.util;

private alias InterruptHandler = GameBoyAdvance.InterruptHandler;
private alias InterruptSource = GameBoyAdvance.InterruptSource;

public class GameBoyAdvanceKeypad {
    private static TickDuration INPUT_PERIOD;
    private Memory ioRegisters;
    private InterruptHandler interruptHandler;
    private int[10] keyMap = [
        SDL_SCANCODE_P,
        SDL_SCANCODE_O,
        SDL_SCANCODE_TAB,
        SDL_SCANCODE_RETURN,
        SDL_SCANCODE_D,
        SDL_SCANCODE_A,
        SDL_SCANCODE_W,
        SDL_SCANCODE_S,
        SDL_SCANCODE_E,
        SDL_SCANCODE_Q
    ];
    private Thread thread;
    private shared bool running = false;

    static this() {
        INPUT_PERIOD = TickDuration.from!"nsecs"(16666667);
    }

    public this(MonitoredMemory ioRegisters, InterruptHandler interruptHandler) {
        this.ioRegisters = ioRegisters.getMonitored();
        this.interruptHandler = interruptHandler;
    }

    public void map(Key gbaKey, int button) {
        keyMap[gbaKey] = button;
    }

    public void start() {
        if (thread is null) {
            thread = new Thread(&run);
            thread.name = "Input";
            running = true;
            thread.start();
        }
    }

    public void stop() {
        if (thread !is null) {
            running = false;
            thread = null;
        }
    }

    private void run() {
        Timer timer = new Timer();
        while (running) {
            timer.start();
            int state = ~updateState();
            int control = ioRegisters.getShort(0x132);
            if (checkBit(control, 14)) {
                int requested = control & 0x3FF;
                if (checkBit(control, 15)) {
                    if ((state & requested) == requested) {
                        interruptHandler.requestInterrupt(InterruptSource.KEYPAD);
                    }
                } else if (state & requested) {
                    interruptHandler.requestInterrupt(InterruptSource.KEYPAD);
                }
            }
            timer.waitUntil(INPUT_PERIOD);
        }
    }

    private int updateState() {
        const ubyte* keyboard = SDL_GetKeyboardState(null);
        int keypadState = 0;
        foreach (i, key; keyMap) {
            keypadState |= keyboard[key] << i;
        }
        keypadState = ~keypadState & 0x3FF;
        ioRegisters.setShort(0x130, cast(short) keypadState);
        return keypadState;
    }

    public static enum Key {
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
}
