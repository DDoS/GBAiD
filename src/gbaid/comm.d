module gbaid.comm;

import std.mmfile;

import gbaid.util;

import gbaid.gba.sio : Communication;

private struct SharedData {
    private uint count;
    private uint receipt;
    uint[4] data;
    ubyte[4] ready;
    ubyte[4] wrote;

    static assert (count.offsetof == 0);
    static assert (receipt.offsetof == 4);
    static assert (data.offsetof == 8);
    static assert (ready.offsetof == 24);
    static assert (wrote.offsetof == 28);
    static assert (SharedData.sizeof == 32);
}

public class MappedMemoryCommunication : Communication {
    private uint index;
    private MmFile file;

    public this(uint index) {
        this.index = index;

        file = new MmFile("test", MmFile.Mode.readWrite, SharedData.sizeof, null);

        if (index == 0) {
            foreach (i; 0 .. file.length) {
                file[i] = 0xFF;
            }
            auto shared_ = getShared();
            shared_.count = 1;
            shared_.receipt = 0;
        } else {
            getShared().count += 1;
        }
    }

    public ~this() {
        setReady(index, true);
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
        foreach (i; 0 .. shared_.count) {
            ready &= shared_.ready[i] != 0;
        }
        return ready;
    }

    public override void begin(uint receipt) {
        if (receipt == 0) {
            return;
        }

        auto shared_ = getShared();
        shared_.receipt = receipt;

        foreach (i; 0 .. shared_.count) {
            shared_.wrote[i] = 0;
        }
    }

    public override uint ongoing() {
        return getShared().receipt;
    }

    public override uint dataIn(uint index) {
        return getShared().data[index];
    }

    public override void dataOut(uint receipt, uint index, uint data) {
        auto shared_ = getShared();
        if (receipt == 0 || shared_.receipt != receipt) {
            return;
        }

        shared_.data[index] = data;

        shared_.wrote[index] = 0xFF;
        bool allWrote = true;
        foreach (i; 0 .. shared_.count) {
            allWrote &= shared_.wrote[i] != 0;
        }
        if (allWrote) {
            shared_.receipt = 0;
        }
    }
}
