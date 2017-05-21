module gbaid.gba.rtc;

import core.thread : Thread;
import core.time : Duration, hnsecs, minutes;

import std.datetime : DateTime, Clock;
import std.format : format;

import gbaid.util;

import gbaid.gba.gpio;
import gbaid.gba.interrupt;

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

public enum uint RTC_SIZE = RtcData.sizeof;

public struct Rtc {
    private InterruptHandler _interruptHandler = null;
    private MinuteInterrupter minuteInterrupter = null;
    private bool selected = false;
    private bool clock = false;
    private bool io = false;
    private ubyte bitBuffer;
    private uint bufferIndex;
    private State state;
    private Register command;
    private uint parameterIndex;
    private RtcData data;

    @disable public this();

    public ~this() {
        minuteInterrupter.stop();
    }

    public this(void[] data) {
        if (data.length == 0) {
            // Simulate power-on for the first time
            this.data.powerOff();
        } else if (data.length == RTC_SIZE) {
            (cast(void*) &this.data)[0 .. RtcData.sizeof] = data[];
        } else {
            throw new Exception("Expected 0 or 24 bytes");
        }
    }

    @property public void interruptHandler(InterruptHandler interruptHandler) {
        _interruptHandler = interruptHandler;
        minuteInterrupter = new MinuteInterrupter(interruptHandler);
        minuteInterrupter.enabled = cast(bool) (data.controlRegister & 0b1000);
    }

    @property private InterruptHandler interruptHandler() {
        if (_interruptHandler is null) {
            throw new Exception("The RTC was to request an interrupt, but no handler was set");
        }
        return _interruptHandler;
    }

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

    @property public ubyte[] dataArray() {
        return (cast(ubyte*) &data)[0 .. RtcData.sizeof];
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
                // Process commands that don't have any parameters
                switch (command) with (Register) {
                    case FORCE_RESET:
                        data.forceReset();
                        break;
                    case FORCE_IRQ:
                        interruptHandler.requestInterrupt(InterruptSource.GAMEPAK);
                        break;
                    default:
                        // Get ready for receiving parameters for the other commands
                        parameterIndex = 0;
                }
                break;
            }
            case WRITE_PARAMETERS: {
                switch (command) with (Register) {
                    case CONTROL:
                        // Input one byte
                        if (parameterIndex < 1) {
                            // Clear the unused bits
                            data.controlRegister = input & 0b01101010;
                            // Enable minute interrupter if required
                            minuteInterrupter.enabled = cast(bool) (data.controlRegister & 0b1000);
                        }
                        break;
                    case DATETIME:
                        // Input seven bytes
                        if (parameterIndex < 7) {
                            data.datetimeRegisters[parameterIndex] = input;
                            // Update the last set datetime after the last parameter
                            if (parameterIndex == 6) {
                                data.updateLastSetDatetime();
                            }
                        }
                        break;
                    case TIME:
                        // Input three bytes
                        if (parameterIndex < 3) {
                            data.datetimeRegisters[parameterIndex + 4] = input;
                            // Update the last set datetime after the last parameter
                            if (parameterIndex == 2) {
                                data.updateLastSetDatetime();
                            }
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
                throw new Exception(format("Unexpected state when processing an input byte: %s", state));
        }
    }

    private ubyte nextOutputByte() {
        if (state != State.READ_PARAMETERS) {
            throw new Exception(format("Unexpected state when processing an output byte: %s", state));
        }
        ubyte output = 0xFF;
        switch (command) with (Register) {
            case CONTROL:
                // Output one byte
                if (parameterIndex < 1) {
                    output = data.controlRegister;
                }
                break;
            case DATETIME:
                // Output seven bytes
                if (parameterIndex < 7) {
                    // Update the current datetime before the first parameter
                    if (parameterIndex == 0) {
                        data.updateDateTimeRegisters();
                    }
                    output = data.datetimeRegisters[parameterIndex];
                }
                break;
            case TIME:
                // Output three bytes
                if (parameterIndex < 3) {
                    // Update the current datetime before the first parameter
                    if (parameterIndex == 0) {
                        data.updateDateTimeRegisters();
                    }
                    output = data.datetimeRegisters[parameterIndex + 4];
                }
                break;
            default:
                // No parameters or doesn't correspond to any register
        }
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
        if (!selected && value) {
            // Clear the bit buffer and update the state when selected
            bitBuffer = 0;
            bufferIndex = 0;
            state = State.WRITE_COMMAND;
        }
        selected = value;
    }

    private bool readFloating() {
        return false;
    }

    private void writeFloating(bool value) {
    }
}

private class MinuteInterrupter {
    private enum Duration ONE_MINUTE = minutes(1);
    private InterruptHandler interruptHandler;
    private Thread thread = null;
    private bool running = false;
    private bool _enabled = false;

    private this(InterruptHandler interruptHandler) {
        this.interruptHandler = interruptHandler;
    }

    private void enabled(bool enabled) {
        _enabled = enabled;
        if (_enabled) {
            start();
        }
    }

    private void start() {
        if (running) {
            return;
        }
        thread = new Thread(&run);
        thread.isDaemon = true;
        running = true;
        thread.start();
    }

    private void stop() {
        if (!running) {
            return;
        }
        running = false;
        thread = null;
    }

    private void run() {
        auto timer = new Timer();
        size_t nextMinute = 1;
        timer.start();
        while (running) {
            timer.waitUntil(ONE_MINUTE * nextMinute);
            nextMinute += 1;
            if (running && _enabled) {
                interruptHandler.requestInterrupt(InterruptSource.GAMEPAK);
            }
        }
    }
}

private struct RtcData {
    // Register order: year, month, day, day of the week, hour, minutes and seconds
    private enum ubyte[] DATETIME_CLEARED_VALUES = [0, 1, 1, 0, 0, 0, 0];
    private long lastSetDatetimeTime;
    private ubyte controlRegister;
    private ubyte[7] datetimeRegisters;
    private ubyte[7] lastSetDatetimeRegisters;

    static assert (lastSetDatetimeTime.offsetof == 0);
    static assert (controlRegister.offsetof == 8);
    static assert (datetimeRegisters.offsetof == 9);
    static assert (lastSetDatetimeRegisters.offsetof == 16);
    static assert (RtcData.sizeof == 24);

    private void powerOff() {
        controlRegister = 0x80;
        datetimeRegisters = DATETIME_CLEARED_VALUES;
        updateLastSetDatetime();
    }

    private void forceReset() {
        controlRegister = 0;
        datetimeRegisters = DATETIME_CLEARED_VALUES;
        updateLastSetDatetime();
    }

    private void updateLastSetDatetime() {
        // Clear the unused bits
        datetimeRegisters[1] &= 0b00011111;
        datetimeRegisters[2] &= 0b00111111;
        datetimeRegisters[3] &= 0b00000111;
        datetimeRegisters[4] &= 0b01111111;
        datetimeRegisters[5] &= 0b01111111;
        datetimeRegisters[6] &= 0b01111111;
        // We'll use this data to update the datetime registers when they are read
        lastSetDatetimeRegisters = datetimeRegisters;
        lastSetDatetimeTime = Clock.currStdTime();
    }

    private void updateDateTimeRegisters() {
        // Convert the original datetime registers to a DateTime object
        auto oldYear = lastSetDatetimeRegisters[0].bcdToDecimal() + 2000;
        auto oldHour = (lastSetDatetimeRegisters[4] & 0x3F).bcdToDecimal();
        // If the RTC is in 12h mode, we have to adjust the hour when it's PM
        if (!(controlRegister & 0x40) && (lastSetDatetimeRegisters[4] & 0x40)) {
            oldHour += 12;
        }
        auto oldDateTime = DateTime(
                oldYear, lastSetDatetimeRegisters[1].bcdToDecimal(), lastSetDatetimeRegisters[2].bcdToDecimal(),
                oldHour, lastSetDatetimeRegisters[5].bcdToDecimal(), lastSetDatetimeRegisters[6].bcdToDecimal()
        );
        // Add to it the time elapsed since it was set. This is the RTC's current datetime
        auto dateTime = oldDateTime + hnsecs(Clock.currStdTime() - lastSetDatetimeTime);
        // Check that the year is valid for the RTC's range
        if (dateTime.year < 2000 || dateTime.year > 2099) {
            throw new Exception(format("I'm sorry, but the RTC wasn't designed to work in the year %d", dateTime.year));
        }
        auto year = (dateTime.year - 2000).decimalToBcd();
        // Calculate the day of the week (the number assignment in the RTC is decided by the user)
        auto dayOfTheWeekOffset = cast(int) lastSetDatetimeRegisters[3] - oldDateTime.dayOfWeek;
        auto dayOfTheWeek = (dateTime.dayOfWeek + dayOfTheWeekOffset + 7) % 7;
        // Calculate the hour register: start with the AM/PM flag
        auto hour = (dateTime.hour >= 12) << 6;
        // If the RTC is in 12h mode, we have to adjust the hour
        if (hour & 0x40) {
            hour |= dateTime.hour.decimalToBcd();
        } else {
            hour |= (dateTime.hour % 12).decimalToBcd();
        }
        // Update the datetime registers to the current datetime
        datetimeRegisters = [
            year, dateTime.month.decimalToBcd(), dateTime.day.decimalToBcd(), cast(ubyte) dayOfTheWeek,
            cast(ubyte) hour, dateTime.minute.decimalToBcd(), dateTime.second.decimalToBcd()
        ];
    }
}

private ubyte decimalToBcd(int decimal) {
    return cast(ubyte) (((decimal / 10) << 4) + decimal % 10);
}

private int bcdToDecimal(ubyte bcd) {
    return ((bcd & 0xF0) >>> 4) * 10 + (bcd & 0xF);
}
