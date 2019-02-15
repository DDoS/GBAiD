module gbaid.comm;

import core.atomic : MemoryOrder, atomicLoad, atomicStore, atomicOp;

import gbaid.util;

import gbaid.gba.sio : Communication, CommunicationState;

public class SharedSerialData {
    public shared uint[4] data;
    /*
        [0, 3] -> connected
        [4, 7] -> ready
        [8, 11] -> read
        [12, 15] -> finalized
        16 -> active
    */
    public shared uint status;

    this() {
        data[] = 0xFFFFFFFF;
        status = 0;
    }
}

public class MappedMemoryCommunication : Communication {
    private uint index;
    private SharedSerialData _shared;

    public this(uint index, SharedSerialData _shared) {
        this.index = index;
        this._shared = _shared;

        atomicOp!"|="(_shared.status, 1 << index);
    }

    public ~this() {
        atomicOp!"&="(_shared.status, ~(1 << index));
        atomicStore!(MemoryOrder.raw)(_shared.data[index], 0xFFFFFFFF);
    }

    public override CommunicationState getState() {
        uint status = atomicLoad!(MemoryOrder.raw)(_shared.status);

        uint connected = status.getBits(0, 3);
        bool allRead = status.getBits(8, 11) == connected;
        bool allFinalized = status.getBits(12, 15) == connected;
        bool active = status.checkBit(16);

        if (active && allRead && allFinalized) {
            return CommunicationState.FINALIZE_DONE;
        }
        if (active && allRead) {
            return CommunicationState.READ_DONE;
        }
        if (active) {
            return CommunicationState.WRITE_DONE;
        }
        return CommunicationState.IDLE;
    }

    public override void setReady(uint index, bool ready) {
        if (ready) {
            atomicOp!"|="(_shared.status, 0b10000 << index);
        } else {
            atomicOp!"&="(_shared.status, ~(0b1000100010000 << index));
            atomicStore!(MemoryOrder.raw)(_shared.data[index], 0xFFFFFFFF);
        }
    }

    public override bool allReady() {
        uint status = atomicLoad!(MemoryOrder.raw)(_shared.status);
        uint connected = status.getBits(0, 3);
        return status.getBits(4, 7) == connected;
    }

    public override void init() {
        atomicOp!"|="(_shared.status, 1 << 16);
    }

    public override void readDone(uint index, bool done) {
        atomicOp!"|="(_shared.status, 1 << index + 8);
    }

    public override bool readDone(uint index) {
        return atomicLoad!(MemoryOrder.raw)(_shared.status).checkBit(index + 8);
    }

    public override void finalizeDone(uint index, bool done) {
        atomicOp!"|="(_shared.status, 1 << index + 12);
    }

    public override bool finalizeDone(uint index) {
        return atomicLoad!(MemoryOrder.raw)(_shared.status).checkBit(index + 12);
    }

    public override void deinit() {
        atomicOp!"&="(_shared.status, ~0b11111111100000000);
    }

    public override uint read(uint index) {
        return atomicLoad!(MemoryOrder.raw)(_shared.data[index]);
    }

    public override void write(uint index, uint word) {
        atomicStore!(MemoryOrder.raw)(_shared.data[index], word);
    }
}
