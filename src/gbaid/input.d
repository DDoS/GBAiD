module gbaid.input;

import core.thread;
import core.time;

import derelict.sdl2.sdl;

import gbaid.system;
import gbaid.util;

private alias GameBoyAdvanceMemory = GameBoyAdvance.GameBoyAdvanceMemory;
private alias InterruptSource = GameBoyAdvance.InterruptSource;

public class GameBoyAdvanceKeypad {
    private static TickDuration INPUT_PERIOD;
    private GameBoyAdvanceMemory memory;
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

    public void setMemory(GameBoyAdvanceMemory memory) {
        this.memory = memory;
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
            if (SDL_WasInit(SDL_INIT_EVERYTHING)) {
                int state = ~updateState();
                int control = memory.getShort(0x4000132);
                if (checkBit(control, 14)) {
                    int requested = control & 0x3FF;
                    if (checkBit(control, 15)) {
                        if ((state & requested) == requested) {
                            memory.requestInterrupt(InterruptSource.KEYPAD);
                        }
                    } else if (state & requested) {
                        memory.requestInterrupt(InterruptSource.KEYPAD);
                    }
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
        memory.setShort(0x4000130, cast(short) keypadState);
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
