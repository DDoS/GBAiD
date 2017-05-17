module gbaid.gba.rtc;

import gbaid.util;

import gbaid.gba.gpio;

private enum Register {
    NONE = 0,
    CONTROL = 1,
    DATETIME = 2,
    TIME = 3,
    FORCE_RESET = 4,
    FORCE_IRQ = 5
}

private enum Register[] REGISTER_INDICES = [
    Register.FORCE_RESET, Register.NONE, Register.DATETIME, Register.FORCE_IRQ,
    Register.CONTROL, Register.NONE, Register.TIME, Register.NONE
];

private enum int[] REGISTER_PARAMETER_COUNTS = [0, 1, 7, 3, 0, 0];

private enum State {
    READ_COMMAND, READ_PARAMETERS
}

public struct Rtc {
    private bool selected = false;
    private bool clock = false;
    private bool io = false;
    private ubyte bitBuffer = 0;
    private uint bufferIndex = 0;
    private State state = State.READ_COMMAND;
    private Register register = Register.NONE;
    private bool readCommand = false;

    @property public GpioChip chip() {
        GpioChip chip;
        chip.readPin0 = &readClock;
        chip.writePin0 = &writeClock;
        chip.readPin1 = &readIo;
        chip.writePin1 = &writeIo;
        chip.readPin2 = &readSelect;
        chip.writePin2 = &writeSelect;
        chip.readPin3 = &readFloating;
        chip.writePin3 = &writeFloating;
        return chip;
    }

    private bool readClock() {
        return clock;
    }

    private void writeClock(bool value) {
        if (!selected) {
            return;
        }
        // We read or write the IO pin on the rising edge
        if (!clock && value) {
            bitBuffer |= io << bufferIndex;
            bufferIndex += 1;
            // We received a byte, so process it
            if (bufferIndex == 8) {
                processByte(bitBuffer);
                bitBuffer = 0;
                bufferIndex = 0;
            }
        }
        clock = value;
    }

    private void processByte(ubyte b) {
        final switch (state) with (State) {
            case READ_COMMAND: {
                // The first nibble must be 6
                if ((b & 0b1111) != 6) {
                    break;
                }
                // Update the state accordingly
                state = READ_PARAMETERS;
                register = REGISTER_INDICES[b >>> 4 & 0b111];
                readCommand = b >>> 7;
                import std.stdio; writefln("%08b %s %s", bitBuffer, register, readCommand ? "read" : "write");
                break;
            }
            case READ_PARAMETERS: {
                import std.stdio; writefln("%08b", bitBuffer);
            }
        }
    }

    private bool readIo() {
        return io;
    }

    private void writeIo(bool value) {
        io = value;
    }

    private bool readSelect() {
        return selected;
    }

    private void writeSelect(bool value) {
        if (selected && !value) {
            // Clear the bit buffer when deselected and reset the state
            bitBuffer = 0;
            bufferIndex = 0;
            state = State.READ_COMMAND;
        }
        selected = value;
    }

    private bool readFloating() {
        return false;
    }

    private void writeFloating(bool value) {
    }
}
