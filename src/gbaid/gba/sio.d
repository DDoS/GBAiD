module gbaid.gba.sio;

import gbaid.util;

import gbaid.gba.io;
import gbaid.gba.interrupt;

public alias SerialIn = uint delegate(uint index);
public alias SerialOut = void delegate(uint index, uint data);

public interface Communication {
    public void setReady(uint index, bool ready);
    public bool allReady();
    public void begin(uint receipt);
    public uint ongoing();
    public uint dataIn(uint index);
    public void dataOut(uint receipt, uint index, uint data);
}

private enum IoMode {
    NORMAL_8BIT, NORMAL_32BIT, MULTIPLAYER, UART, JOYBUS, GENERAL_PURPOSE
}

private struct MultiplayerControl {
    private byte baudRate = 0;
    private bool child = false;
    private bool allReady = false;
    private byte id = 0;
    private bool error = false;
    private bool active = false;
    private bool interrupt = false;
}

public class SerialPort {
    private InterruptHandler interruptHandler;
    private Communication _communication;
    private MultiplayerControl control;
    private int data1 = 0;
    private int data2 = 0;
    private short data3 = 0;
    private bool stateSc = false, stateSd = false, stateSi = false, stateSo = false;
    private bool dirSc = false, dirSd = false, dirSi = false, dirSo = false;
    private bool interruptSi = false;
    private byte mode1 = 0;
    private byte mode2 = 0;
    private uint _index = 0;
    private uint receipt = 0;
    private bool endWait = false;

    public this(IoRegisters* ioRegisters, InterruptHandler interruptHandler) {
        this.interruptHandler = interruptHandler;

        _communication = new NullCommunication();

        ioRegisters.mapAddress(0x128, &control.baudRate, 0b11, 0);
        ioRegisters.mapAddress(0x128, &control.child, 0b1, 2);
        ioRegisters.mapAddress(0x128, &control.allReady, 0b1, 3);
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

    @property public void index(uint index) {
        _index = index;
    }

    @property public void communication(Communication communication) {
        _communication = communication;
    }

    import std.stdio : writefln;

    private void onPostWriteMode(int mask, int oldValue, int newValue) {
        if (oldValue == newValue) {
            return;
        }
        if (ioMode == IoMode.MULTIPLAYER) {
            if (_index == 0) {
                control.child = false;
                writefln("parent ready");
            } else {
                control.child = true;
                writefln("child %s ready", _index);
            }
            _communication.setReady(_index, true);
        } else {
            _communication.setReady(_index, false);
        }
        endWait = false;
    }

    private void onPostWriteActive(int mask, int oldValue, int newValue) {
        if (oldValue || !newValue) {
            return;
        }
        if (ioMode == IoMode.MULTIPLAYER && _index == 0) {
            receipt += 1;
            _communication.begin(receipt);
            _communication.dataOut(receipt, _index, data3);
            endWait = true;
            writefln("parent wrote %04x", data3);
        }
    }

    private void onPostWriteData3(int mask, int oldValue, int newValue) {
        if (oldValue == newValue) {
            return;
        }
        if (ioMode == IoMode.MULTIPLAYER) {
            import std.stdio : writefln;
            writefln!"send: %04x"(newValue);
        }
    }

    public size_t emulate(size_t cycles) {
        if (ioMode != IoMode.MULTIPLAYER) {
            return 0;
        }

        control.allReady = _communication.allReady();

        auto ongoingReceipt = _communication.ongoing();
        if (ongoingReceipt == 0) {
            if (endWait) {
                endWait = false;
                data1.setBits(0, 15, _communication.dataIn(0));
                data1.setBits(16, 31, _communication.dataIn(1));
                data2.setBits(0, 15, _communication.dataIn(2));
                data2.setBits(16, 31, _communication.dataIn(3));

                control.active = false;
                control.id = cast(byte) _index;
                control.error = false;

                if (control.interrupt) {
                    interruptHandler.requestInterrupt(InterruptSource.SERIAL_COMMUNICATION);
                }

                if (_index == 0) {
                    writefln("parent read %08x %08x", data1, data2);
                } else {
                    writefln("child %s read %08x %08x", _index, data1, data2);
                }
            }
        } else if (ongoingReceipt != receipt) {
            control.active = true;
            receipt = ongoingReceipt;
            _communication.dataOut(receipt, _index, data3);
            endWait = true;
            writefln("child %s wrote %04x", _index, data3);
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

private class NullCommunication : Communication {
    public override void setReady(uint index, bool ready) {
    }

    public override bool allReady() {
        return false;
    }

    public override void begin(uint receipt) {
    }

    public override uint ongoing() {
        return 0;
    }

    public override uint dataIn(uint index) {
        return 0xFFFFFFFF;
    }

    public override void dataOut(uint receipt, uint index, uint data) {
    }
}
