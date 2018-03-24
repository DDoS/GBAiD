module gbaid.comm;

import std.mmfile;

import gbaid.util;

import gbaid.gba.sio : Communication;

private struct SharedData {
    private uint[4] data;
    private ubyte[4] connected;
    private ubyte[4] ready;
    private ubyte[4] wrote;
    private ubyte active;

    static assert (data.offsetof == 0);
    static assert (connected.offsetof == 16);
    static assert (ready.offsetof == 20);
    static assert (wrote.offsetof == 24);
    static assert (active.offsetof == 28);
    static assert (SharedData.sizeof == 32);
}

public class MappedMemoryCommunication : Communication {
    private uint index;
    private MmFile file;

    public this(uint index) {
        this.index = index;

        file = new MmFile("test", MmFile.Mode.readWrite, SharedData.sizeof, null);

        auto shared_ = getShared();
        if (index == 0) {
            shared_.active = 0;
            shared_.data[] = 0xFFFFFFFF;
            shared_.connected[] = 0;
            shared_.ready[] = 0;
            shared_.wrote[] = 0xFF;
        }
        shared_.connected[index] = 0xFF;
    }

    public ~this() {
        auto shared_ = getShared();
        shared_.connected[index] = 0;
        shared_.data[index] = 0xFFFFFFFF;
    }

    private SharedData* getShared() {
        return cast(SharedData*) file[];
    }

    public override void setReady(uint index, bool ready) {
        getShared().ready[index] = ready ? 0xFF : 0;
    }

    public override bool allReady() {
        auto shared_ = getShared();
        bool ready = true;
        foreach (i, conn; shared_.connected) {
            if (conn) {
                ready &= shared_.ready[i] != 0;
            }
        }
        return ready;
    }

    public override void begin(uint index) {
        auto shared_ = getShared();
        if (index == 0) {
            shared_.active = 0xFF;
        }
        shared_.data[index] = 0xFFFFFFFF;
    }

    public override void end(uint index) {
        auto shared_ = getShared();
        if (index == 0) {
            shared_.active = 0;
        }
        shared_.wrote[index] = 0;
    }

    public override uint ongoing() {
        auto shared_ = getShared();
        bool notWritten = false;
        foreach (i, conn; shared_.connected) {
            if (conn) {
                notWritten |= shared_.wrote[i] == 0;
            }
        }
        return shared_.active != 0 && notWritten;
    }

    public override uint dataIn(uint index) {
        return getShared().data[index];
    }

    public override void dataOut(uint index, uint data) {
        auto shared_ = getShared();
        shared_.data[index] = data;
        shared_.wrote[index] = 0xFF;
    }
}
