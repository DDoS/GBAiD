module gbaid.gba.sio;

import gbaid.util;

import gbaid.gba.io;
import gbaid.gba.interrupt;

public enum CommunicationState {
    IDLE,
    INIT_DONE,
    WRITE_DONE,
    READ_DONE,
    FINALIZE_DONE
}

public interface Communication {
    public CommunicationState getState();
    public void setReady(uint index, bool ready);
    public bool allReady();

    public void init();

    public void writeDone(uint index, bool done);
    public bool writeDone(uint index);

    public void readDone(uint index, bool done);
    public bool readDone(uint index);

    public void finalizeDone(uint index, bool done);
    public bool finalizeDone(uint index);

    public void deinit();

    public uint read(uint index);
    public void write(uint index, uint data);
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
    private uint index = 0;
    private size_t waitCycles = 0;

    public this(IoRegisters* ioRegisters, InterruptHandler interruptHandler, uint index) {
        this.interruptHandler = interruptHandler;

        this.index = index;
        control.child = index != 0;

        _communication = new NullCommunication();

        ioRegisters.mapAddress(0x128, &control.baudRate, 0b11, 0);
        ioRegisters.mapAddress(0x128, &control.child, 0b1, 2, true, false);
        ioRegisters.mapAddress(0x128, &control.allReady, 0b1, 3, true, false);
        ioRegisters.mapAddress(0x128, &control.id, 0b11, 4, true, false);
        ioRegisters.mapAddress(0x128, &control.error, 0b1, 6, true, false);
        ioRegisters.mapAddress(0x128, &control.active, 0b1, 7, true, index == 0).postWriteMonitor(&onPostWriteActive);
        ioRegisters.mapAddress(0x128, &control.interrupt, 0b1, 14);

        ioRegisters.mapAddress(0x120, &data1, 0xFFFFFFFF, 0);
        ioRegisters.mapAddress(0x124, &data2, 0xFFFFFFFF, 0);
        ioRegisters.mapAddress(0x128, &data3, 0xFFFF, 16).postWriteMonitor(&onPostWriteData3);

        ioRegisters.mapAddress(0x134, &stateSc, 0b1, 0).readMonitor(&test);
        ioRegisters.mapAddress(0x134, &stateSd, 0b1, 1).readMonitor(&test);
        ioRegisters.mapAddress(0x134, &stateSi, 0b1, 2).readMonitor(&test);
        ioRegisters.mapAddress(0x134, &stateSo, 0b1, 3).readMonitor(&test);
        ioRegisters.mapAddress(0x134, &dirSc, 0b1, 4);
        ioRegisters.mapAddress(0x134, &dirSd, 0b1, 5);
        ioRegisters.mapAddress(0x134, &dirSi, 0b1, 6);
        ioRegisters.mapAddress(0x134, &dirSo, 0b1, 7);
        ioRegisters.mapAddress(0x134, &interruptSi, 0b1, 8);

        ioRegisters.mapAddress(0x128, &mode1, 0b11, 12).postWriteMonitor(&onPostWriteMode);
        ioRegisters.mapAddress(0x134, &mode2, 0b11, 14).postWriteMonitor(&onPostWriteMode);
    }

    import std.stdio : writefln;

    void test(int, ref int) {
        writefln("yes");
    }

    @property public void communication(Communication communication) {
        _communication = communication;
    }

    private void onPostWriteMode(int mask, int oldValue, int newValue) {
        if (oldValue == newValue) {
            return;
        }
        if (ioMode == IoMode.MULTIPLAYER) {
            //writefln("%s ready", index);
            _communication.setReady(index, true);
        } else {
            import std.conv : to;
            //writefln("%s not ready: %s", index, ioMode.to!string());
            _communication.setReady(index, false);
        }
    }

    private void onPostWriteActive(int mask, int oldValue, int newValue) {
        if (oldValue || !newValue) {
            return;
        }
        if (ioMode == IoMode.MULTIPLAYER && index == 0) {
            //writefln("init");
            _communication.init();
        }
    }

    private void onPostWriteData3(int mask, int oldValue, int newValue) {
        if (ioMode == IoMode.MULTIPLAYER) {
            //writefln!"%s sends %04x"(index, newValue);
        }
    }

    public size_t emulate(size_t cycles) {
        waitCycles += cycles;

        if (ioMode != IoMode.MULTIPLAYER) {
            return 0;
        }

        control.allReady = _communication.allReady();

        final switch (_communication.getState()) with (CommunicationState) {
            case IDLE:
                break;
            case INIT_DONE: {
                if (!_communication.writeDone(index)) {
                    control.active = true;
                    _communication.write(index, data3);
                    waitCycles = 0;

                    //writefln("%s wrote %04x", index, data3);
                    _communication.writeDone(index, true);
                }
                break;
            }
            case WRITE_DONE: {
                if (!_communication.readDone(index) && waitCycles >= 1024) {
                    data1.setBits(0, 15, _communication.read(0));
                    data1.setBits(16, 31, _communication.read(1));
                    data2.setBits(0, 15, _communication.read(2));
                    data2.setBits(16, 31, _communication.read(3));

                    //writefln("%s read %08x %08x", index, data1, data2);
                    _communication.readDone(index, true);
                }
                break;
            }
            case READ_DONE: {
                if (!_communication.finalizeDone(index)) {
                    control.active = false;
                    control.id = cast(byte) index;
                    control.error = false;

                    if (control.interrupt) {
                        interruptHandler.requestInterrupt(InterruptSource.SERIAL_COMMUNICATION);
                    }

                    //writefln("%s finalized", index);
                    _communication.finalizeDone(index, true);
                }
                break;
            }
            case FINALIZE_DONE: {
                if (index == 0) {
                    //writefln("deinit\n");
                    _communication.deinit();
                }
                break;
            }
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
    public override CommunicationState getState() {
        return CommunicationState.IDLE;
    }

    public override void setReady(uint index, bool ready) {
    }

    public override bool allReady() {
        return false;
    }

    public override void init() {
    }

    public override void writeDone(uint index, bool done) {
    }

    public override bool writeDone(uint index) {
        return true;
    }

    public override void readDone(uint index, bool done) {
    }

    public override bool readDone(uint index) {
        return true;
    }

    public override void finalizeDone(uint index, bool done) {
    }

    public override bool finalizeDone(uint index) {
        return true;
    }

    public void deinit() {
    }

    public override uint read(uint index) {
        return 0xFFFFFFFF;
    }

    public override void write(uint index, uint data) {
    }
}
