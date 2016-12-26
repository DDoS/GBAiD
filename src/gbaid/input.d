module gbaid.input;

import derelict.sdl2.sdl;

import gbaid.util;

import gbaid.gba.keypad;

public interface InputSource {
    public void create();

    public void destroy();

    public KeypadState pollKeypad();
}

public class Keyboard : InputSource {
    private int[10] buttonCodeMap = [
        SDL_SCANCODE_P,
        SDL_SCANCODE_L,
        SDL_SCANCODE_TAB,
        SDL_SCANCODE_RETURN,
        SDL_SCANCODE_D,
        SDL_SCANCODE_A,
        SDL_SCANCODE_W,
        SDL_SCANCODE_S,
        SDL_SCANCODE_RSHIFT,
        SDL_SCANCODE_LSHIFT
    ];

    public void map(Button button, int key) {
        buttonCodeMap[button] = key;
    }

    public override void create() {
    }

    public override void destroy() {
    }

    public override KeypadState pollKeypad() {
        const ubyte* keyboard = SDL_GetKeyboardState(null);
        KeypadState state;
        foreach (buttonIndex, buttonCode; buttonCodeMap) {
            state.setPressed(cast(Button) buttonIndex, cast(bool) keyboard[buttonCode]);
        }
        return state;
    }
}

public class Controller : InputSource {
    private SDL_GameController* controller = null;
    private int[10] buttonCodeMap = [
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

    public void map(Button button, int controllerButton) {
        buttonCodeMap[button] = controllerButton;
    }

    public void map(Button button, int controllerAxis, float percent, bool direction) {
        int threshold = cast(int) ((percent < 0 ? 0 : percent > 1 ? 1 : percent) * 0xFFFF - 0x8000);
        stickMap[button] = StickMapping(controllerAxis, threshold, direction);
    }

    public override void create() {
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

    public override void destroy() {
        if (controller) {
            SDL_GameControllerClose(controller);
        }
    }

    public override KeypadState pollKeypad() {
        KeypadState state;
        if (!controller) {
            return state;
        }
        foreach (buttonIndex, buttonCode; buttonCodeMap) {
            if (buttonCode != SDL_CONTROLLER_BUTTON_INVALID) {
                state.setPressed(cast(Button) buttonIndex, cast(bool) SDL_GameControllerGetButton(controller, buttonCode));
            }
        }
        foreach (buttonIndex, stick; stickMap) {
            if (stick.axis != SDL_CONTROLLER_AXIS_INVALID) {
                int amplitude = SDL_GameControllerGetAxis(controller, stick.axis);
                if ((stick.direction ? amplitude : -amplitude) >= stick.threshold) {
                    state.setPressed(cast(Button) buttonIndex, true);
                }
            }
        }
        return state;
    }

    private static struct StickMapping {
        private int axis = SDL_CONTROLLER_AXIS_INVALID;
        private int threshold;
        private bool direction;
    }
}

public class InputException : Exception {
    protected this(string msg) {
        super(msg);
    }

    protected this(string msg, string info) {
        super(msg ~ ": " ~ info);
    }
}
