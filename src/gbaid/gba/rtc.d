module gbaid.gba.rtc;

import gbaid.util;

import gbaid.gba.gpio;

public struct Rtc {
    private bool selected = false;
    private bool clock = false;
    private bool io = false;
    private long bitBuffer = 0;
    private uint bufferIndex = 0;

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
        if (!clock && value) {
            // We read or write the IO pin on the rising edge
            bitBuffer.setBit(bufferIndex, io);
            bufferIndex += 1;
            if (bufferIndex == 8) {
                import std.stdio; writefln("%08b", bitBuffer);
            }
            bufferIndex %= typeof(bitBuffer).sizeof * 8;
        }
        clock = value;
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
            // Clear the bit buffer when deselected
            bitBuffer = 0;
            bufferIndex = 0;
        }
        selected = value;
    }

    private bool readFloating() {
        return false;
    }

    private void writeFloating(bool value) {
    }
}
