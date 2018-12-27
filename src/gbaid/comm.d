module gbaid.comm;

import gbaid.util;

import gbaid.gba.sio : Communication, CommunicationState;

public class SharedSerialData {
    public uint[4] data;
    public bool[4] connected;
    public bool[4] ready;
    public bool[4] written;
    public bool[4] read;
    public bool[4] finalized;
    public bool active;

    this() {
        active = false;
        data[] = 0xFFFFFFFF;
        connected[] = false;
        ready[] = false;
        written[] = false;
        read[] = false;
    }
}

public class MappedMemoryCommunication : Communication {
    private uint index;
    private SharedSerialData _shared;

    public this(uint index, SharedSerialData _shared) {
        this.index = index;
        this._shared = _shared;

        _shared.connected[index] = true;
    }

    public ~this() {
        _shared.connected[index] = false;
        _shared.data[index] = 0xFFFFFFFF;
    }

    public override CommunicationState getState() {
        bool allRead = allRead(), allWritten = allWritten(), allFinalized = allFinalized();
        if (_shared.active && allWritten && allRead && allFinalized) {
            return CommunicationState.FINALIZE_DONE;
        }
        if (_shared.active && allWritten && allRead) {
            return CommunicationState.READ_DONE;
        }
        if (_shared.active && allWritten) {
            return CommunicationState.WRITE_DONE;
        }
        if (_shared.active) {
            return CommunicationState.INIT_DONE;
        }
        return CommunicationState.IDLE;
    }

    private bool allWritten() {
        bool written = true;
        foreach (i, conn; _shared.connected) {
            if (conn) {
                written &= _shared.written[i];
            }
        }
        return written;
    }

    private bool allRead() {
        bool read = true;
        foreach (i, conn; _shared.connected) {
            if (conn) {
                read &= _shared.read[i];
            }
        }
        return read;
    }

    private bool allFinalized() {
        bool finalized = true;
        foreach (i, conn; _shared.connected) {
            if (conn) {
                finalized &= _shared.finalized[i];
            }
        }
        return finalized;
    }

    public override void setReady(uint index, bool ready) {
        _shared.ready[index] = ready;
        if (!ready) {
            _shared.data[index] = 0xFFFFFFFF;
            _shared.written[index] = false;
            _shared.read[index] = false;
        }
    }

    public override bool allReady() {
        bool ready = true;
        foreach (i, conn; _shared.connected) {
            if (conn) {
                ready &= _shared.ready[i];
            }
        }
        return ready;
    }

    public override void init() {
        _shared.active = true;
    }

    public override void writeDone(uint index, bool done) {
        _shared.written[index] = done;
    }

    public override bool writeDone(uint index) {
        return _shared.written[index];
    }

    public override void readDone(uint index, bool done) {
        _shared.read[index] = done;
    }

    public override bool readDone(uint index) {
        return _shared.read[index];
    }

    public override void finalizeDone(uint index, bool done) {
        _shared.finalized[index] = done;
    }

    public override bool finalizeDone(uint index) {
        return _shared.finalized[index];
    }

    public override void deinit() {
        _shared.active = false;
        _shared.written[] = false;
        _shared.read[] = false;
        _shared.finalized[] = false;
    }

    public override uint read(uint index) {
        return _shared.data[index];
    }

    public override void write(uint index, uint word) {
        _shared.data[index] = word;
    }
}
