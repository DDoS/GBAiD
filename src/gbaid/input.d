module gbaid.input;

import core.thread;
import core.time;

import derelict.sdl2.sdl;

import gbaid.system;
import gbaid.memory;
import gbaid.util;

public class Keypad {
    private static TickDuration INPUT_PERIOD;
    private RAM ioRegisters;
    private InterruptHandler interruptHandler;
    private InputSource source;
    private Thread thread;
    private bool running = false;

    static this() {
        INPUT_PERIOD = TickDuration.from!"nsecs"(16666667);
    }

    public this(IORegisters ioRegisters, InterruptHandler interruptHandler) {
        this.ioRegisters = ioRegisters.getMonitored();
        this.interruptHandler = interruptHandler;
        source = new Keyboard();
    }

    public template changeInput(T : InputSource) {
        public void changeInput() {
            if (!(cast(T) source)) {
                if (running) {
                    source.destroy();
                }
                source = new T();
                if (running) {
                    source.create();
                }
            }
        }
    }

    public void start() {
        if (thread is null) {
            thread = new Thread(&run);
            thread.name = "Input";
            running = true;
            source.create();
            thread.start();
        }
    }

    public void stop() {
        if (thread !is null) {
            running = false;
            source.destroy();
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
        int keypadState = ~source.getKeypadState() & 0x3FF;
        ioRegisters.setShort(0x130, cast(short) keypadState);
        return keypadState;
    }
}

public abstract class InputSource {
    protected void create() {
    }

    protected void destroy() {
    }

    public abstract int getKeypadState();
}

public class Keyboard : InputSource {
    private int[10] buttonMap = [
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

    public void map(Button gbaButton, int key) {
        buttonMap[gbaButton] = key;
    }

    protected override int getKeypadState() {
        const ubyte* keyboard = SDL_GetKeyboardState(null);
        int keypadState = 0;
        foreach (i, button; buttonMap) {
            keypadState |= keyboard[button] << i;
        }
        return keypadState;
    }
}

public class Controller : InputSource {
    private SDL_GameController* controller = null;
    private int[10] buttonMap = [
        SDL_CONTROLLER_BUTTON_A,
        SDL_CONTROLLER_BUTTON_B,
        SDL_CONTROLLER_BUTTON_BACK,
        SDL_CONTROLLER_BUTTON_START,
        SDL_CONTROLLER_BUTTON_DPAD_RIGHT,
        SDL_CONTROLLER_BUTTON_DPAD_LEFT,
        SDL_CONTROLLER_BUTTON_DPAD_UP,
        SDL_CONTROLLER_BUTTON_DPAD_DOWN,
        SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,
        SDL_CONTROLLER_BUTTON_LEFTSHOULDER
    ];
    private StickMapping[10] stickMap = [
        StickMapping(),
        StickMapping(),
        StickMapping(),
        StickMapping(),
        StickMapping(SDL_CONTROLLER_AXIS_LEFTX, 0x4000, true),
        StickMapping(SDL_CONTROLLER_AXIS_LEFTX, 0x4000, false),
        StickMapping(SDL_CONTROLLER_AXIS_LEFTY, 0x4000, false),
        StickMapping(SDL_CONTROLLER_AXIS_LEFTY, 0x4000, true),
        StickMapping(SDL_CONTROLLER_AXIS_TRIGGERRIGHT, 0x3000, true),
        StickMapping(SDL_CONTROLLER_AXIS_TRIGGERLEFT, 0x3000, true)
    ];

    public void map(Button gbaButton, int controllerButton) {
        buttonMap[gbaButton] = controllerButton;
    }

    public void map(Button gbaButton, int controllerAxis, float percent, bool direction) {
        int threshold = cast(int) ((percent < 0 ? 0 : percent > 1 ? 1 : percent) * 0xFFFF - 0x8000);
        stickMap[gbaButton] = StickMapping(controllerAxis, threshold, direction);
    }

    protected override void create() {
        if (controller) {
            return;
        }
        if (!SDL_WasInit(SDL_INIT_GAMECONTROLLER)) {
            if (SDL_InitSubSystem(SDL_INIT_GAMECONTROLLER) < 0) {
                throw new InputException("Failed to initialize the SDL controller system", toDString(SDL_GetError()));
            }
        }
        foreach (i; 0 .. SDL_NumJoysticks()) {
            if (SDL_IsGameController(i)) {
                controller = SDL_GameControllerOpen(i);
                if (controller) {
                    return;
                } else {
                    throw new InputException("Could not open controller", toDString(SDL_GetError()));
                }
            }
        }
        throw new InputException("No controller found");
    }

    protected override void destroy() {
        if (controller) {
            SDL_GameControllerClose(controller);
        }
    }

    protected override int getKeypadState() {
        if (!controller) {
            return 0;
        }
        int keypadState = 0;
        foreach (i, button; buttonMap) {
            if (button != SDL_CONTROLLER_BUTTON_INVALID) {
                keypadState |= SDL_GameControllerGetButton(controller, button) << i;
            }
        }
        foreach (i, stick; stickMap) {
            if (stick.axis != SDL_CONTROLLER_AXIS_INVALID) {
                int amplitude = SDL_GameControllerGetAxis(controller, stick.axis);
                if ((stick.direction ? amplitude : -amplitude) >= stick.threshold) {
                    keypadState |= 1 << i;
                }
            }
        }
        return keypadState;
    }

    private static struct StickMapping {
        private int axis = SDL_CONTROLLER_AXIS_INVALID;
        private int threshold;
        private bool direction;
    }
}

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

public class InputException : Exception {
    protected this(string msg) {
        super(msg);
    }

    protected this(string msg, string info) {
        super(msg ~ ": " ~ info);
    }
}
