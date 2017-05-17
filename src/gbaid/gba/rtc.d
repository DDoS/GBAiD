module gbaid.gba.rtc;

import gbaid.util;

import gbaid.gba.gpio;

private enum Register {
    NONE,
    CONTROL,
    DATETIME,
    TIME,
    FORCE_RESET,
    FORCE_IRQ
}

private enum Register[] REGISTER_INDICES = [
    Register.FORCE_RESET, Register.NONE, Register.DATETIME, Register.FORCE_IRQ,
    Register.CONTROL, Register.NONE, Register.TIME, Register.NONE
];

private enum State {
    WRITE_COMMAND, WRITE_PARAMETERS, READ_PARAMETERS
}

// In order: year, month, day, day of the week, hour, minutes and seconds
private enum ubyte[] DATETIME_CLEARED_VALUES = [0, 1, 1, 0, 0, 0, 0];

public struct Rtc {
    private bool selected = false;
    private bool clock = false;
    private bool io = false;
    private ubyte bitBuffer = 0;
    private uint bufferIndex = 0;
    private State state = State.WRITE_COMMAND;
    private Register command = Register.NONE;
    private uint parameterIndex = 0;
    private ubyte controlRegister = 0;
    private ubyte[7] datetimeRegisters = DATETIME_CLEARED_VALUES;

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
            final switch (state) with (State) {
                case WRITE_COMMAND:
                case WRITE_PARAMETERS: {
                    // Read the IO pin into the bit buffer
                    bitBuffer |= io << bufferIndex;
                    bufferIndex += 1;
                    // We received a byte, so process it
                    if (bufferIndex == 8) {
                        processInputByte(bitBuffer);
                        // Clear the buffer for the next byte
                        bitBuffer = 0;
                        bufferIndex = 0;
                    }
                    break;
                }
                case READ_PARAMETERS: {
                    // Get the next byte to output if the buffer is empty
                    if (bufferIndex == 0) {
                        bitBuffer = nextOutputByte();
                        bufferIndex = 8;
                    }
                    // Write the next buffered bit to the IO pin
                    io = (bitBuffer >>> (8 - bufferIndex)) & 0b1;
                    bufferIndex -= 1;
                    break;
                }
            }
        }
        clock = value;
    }

    private void processInputByte(ubyte input) {
        final switch (state) with (State) {
            case WRITE_COMMAND: {
                // The first nibble must be 6
                if ((input & 0b1111) != 6) {
                    break;
                }
                // Update the state accordingly
                state =  input & 0x80 ? READ_PARAMETERS : WRITE_PARAMETERS;
                command = REGISTER_INDICES[input >>> 4 & 0b111];
                import std.stdio; writefln("%08b %s %s", input, command, state);
                // Process commands that don't have any parameters
                switch (command) with (Register) {
                    case FORCE_RESET:
                        // Clear all the registers
                        controlRegister = 0;
                        datetimeRegisters = DATETIME_CLEARED_VALUES;
                        break;
                    case FORCE_IRQ:
                        // TODO: Trigger a GamePak interrupt
                        break;
                    default:
                        // Get ready for receiving parameters for the other commands
                        bitBuffer = 0;
                        bufferIndex = 0;
                        parameterIndex = 0;
                }
                break;
            }
            case WRITE_PARAMETERS: {
                import std.stdio; writefln("%08b", input);
                switch (command) with (Register) {
                    case CONTROL:
                        // Input one byte
                        if (parameterIndex < 1) {
                            controlRegister = input;
                        }
                        break;
                    case DATETIME:
                        // Input seven bytes
                        if (parameterIndex < 7) {
                            datetimeRegisters[parameterIndex] = input;
                        }
                        break;
                    case TIME:
                        // Input three bytes
                        if (parameterIndex < 3) {
                            datetimeRegisters[parameterIndex + 4] = input;
                        }
                        break;
                    default:
                        // No parameters or doesn't correspond to any register, ignore the write
                }
                // Increment for the next parameter
                parameterIndex += 1;
                break;
            }
            case READ_PARAMETERS:
                throw new Exception("Unexpected state when processing an input byte: READ_PARAMETERS");
        }
    }

    private ubyte nextOutputByte() {
        if (state != State.READ_PARAMETERS) {
            throw new Exception("Unexpected state when processing an output byte: WRITE_*");
        }
        ubyte output = 0xFF;
        switch (command) with (Register) {
            case CONTROL:
                // Output one byte
                if (parameterIndex < 1) {
                    output = controlRegister;
                }
                break;
            case DATETIME:
                // Output seven bytes
                if (parameterIndex < 7) {
                    output = datetimeRegisters[parameterIndex];
                }
                break;
            case TIME:
                // Output three bytes
                if (parameterIndex < 3) {
                    output = datetimeRegisters[parameterIndex + 4];
                }
                break;
            default:
                // No parameters or doesn't correspond to any register
        }
        import std.stdio; writefln("%08b", output);
        // Increment for the next parameter
        parameterIndex += 1;
        return output;
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
            state = State.WRITE_COMMAND;
            // Not all register bits are used. Those should be 0. We can clear them here.
            clearUnusedRegisterBits();
        }
        selected = value;
    }

    private void clearUnusedRegisterBits() {
        controlRegister &= 0b01101010;
        datetimeRegisters[1] &= 0b00011111;
        datetimeRegisters[2] &= 0b00111111;
        datetimeRegisters[3] &= 0b00000111;
        datetimeRegisters[4] &= 0b01111111;
        datetimeRegisters[5] &= 0b01111111;
        datetimeRegisters[6] &= 0b01111111;
    }

    private bool readFloating() {
        return false;
    }

    private void writeFloating(bool value) {
    }
}
