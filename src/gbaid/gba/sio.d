module gbaid.gba.sio;

import gbaid.util;

import gbaid.gba.io;
import gbaid.gba.interrupt;

private struct MultiplayerControl {
    private byte baudRate = 0;
    private bool child = false;
    private bool childrenReady = false;
    private byte id = 0;
    private bool error = false;
    private bool active = false;
    private bool interrupt = false;
}

public class SerialPort {
    private InterruptHandler interruptHandler;
    private MultiplayerControl control;
    private int data1 = 0;
    private int data2 = 0;
    private short data3 = 0;
    private bool stateSc = false, stateSd = false, stateSi = false, stateSo = false;
    private bool dirSc = false, dirSd = false, dirSi = false, dirSo = false;
    private bool interruptSi = false;
    private byte mode1 = 0;
    private byte mode2 = 0;
    private size_t remainingCycles = 0;

    public this(IoRegisters* ioRegisters, InterruptHandler interruptHandler) {
        this.interruptHandler = interruptHandler;

        ioRegisters.mapAddress(0x128, &control.baudRate, 0b11, 0);
        ioRegisters.mapAddress(0x128, &control.child, 0b1, 2);
        ioRegisters.mapAddress(0x128, &control.childrenReady, 0b1, 3);
        ioRegisters.mapAddress(0x128, &control.id, 0b11, 4);
        ioRegisters.mapAddress(0x128, &control.error, 0b1, 6);
        ioRegisters.mapAddress(0x128, &control.active, 0b1, 7).postWriteMonitor(&onPostWriteActive);
        ioRegisters.mapAddress(0x128, &control.interrupt, 0b1, 14);

        ioRegisters.mapAddress(0x120, &data1, 0xFFFFFFFF, 0);
        ioRegisters.mapAddress(0x124, &data2, 0xFFFFFFFF, 0);
        ioRegisters.mapAddress(0x128, &data3, 0xFFFF, 16).postWriteMonitor(&onPostWriteData3);

        ioRegisters.mapAddress(0x134, &stateSc, 0b1, 0);
        ioRegisters.mapAddress(0x134, &stateSd, 0b1, 1);
        ioRegisters.mapAddress(0x134, &stateSi, 0b1, 2);
        ioRegisters.mapAddress(0x134, &stateSo, 0b1, 3);
        ioRegisters.mapAddress(0x134, &dirSc, 0b1, 4);
        ioRegisters.mapAddress(0x134, &dirSd, 0b1, 5);
        ioRegisters.mapAddress(0x134, &dirSi, 0b1, 6);
        ioRegisters.mapAddress(0x134, &dirSo, 0b1, 7);
        ioRegisters.mapAddress(0x134, &interruptSi, 0b1, 8);

        ioRegisters.mapAddress(0x128, &mode1, 0b11, 12).postWriteMonitor(&onPostWriteMode);
        ioRegisters.mapAddress(0x134, &mode2, 0b11, 14).postWriteMonitor(&onPostWriteMode);
    }

    private void onPostWriteMode(int mask, int oldValue, int newValue) {
        import std.stdio : writefln;
        import std.conv : to;
        writefln!"%s"(ioMode.to!string());

        control.child = false;
        control.childrenReady = ioMode == IoMode.MULTIPLAYER;
    }

    private void onPostWriteActive(int mask, int oldValue, int newValue) {
        if (ioMode == IoMode.MULTIPLAYER) {
            import std.stdio : writefln;
            writefln!"active: %s -> %s"(oldValue, newValue);
            data1 = 0xFFFFFFFF;
            data2 = 0xFFFFFFFF;
            remainingCycles = 4096;
        }
    }

    private void onPostWriteData3(int mask, int oldValue, int newValue) {
        if (ioMode == IoMode.MULTIPLAYER) {
            import std.stdio : writefln;
            writefln!"send: %04x"(newValue);
        }
    }

    public size_t emulate(size_t cycles) {
        if (ioMode != IoMode.MULTIPLAYER || !control.active) {
            return 0;
        }
        if (remainingCycles <= cycles) {
            data1.setBits(0, 15, data3);
            control.active = false;
            control.id = 0;
            control.error = false;
            if (control.interrupt) {
                interruptHandler.requestInterrupt(InterruptSource.SERIAL_COMMUNICATION);
            }
            remainingCycles = 0;
        } else {
            remainingCycles -= cycles;
        }
        return 0;
    }

    @property private IoMode ioMode() {
        final switch (mode2) {
            case 0b00:
            case 0b01: {
                final switch (mode1) {
                    case 0b00:
                        return IoMode.NORMAL_8BIT;
                    case 0b01:
                        return IoMode.NORMAL_32BIT;
                    case 0b10:
                        return IoMode.MULTIPLAYER;
                    case 0b11:
                        return IoMode.UART;
                }
            }
            case 0b10:
                return IoMode.GENERAL_PURPOSE;
            case 0b11:
                return IoMode.JOYBUS;
        }
    }
}

private enum IoMode {
    NORMAL_8BIT, NORMAL_32BIT, MULTIPLAYER, UART, JOYBUS, GENERAL_PURPOSE
}
