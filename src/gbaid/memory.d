module gbaid.memory;

import std.string;
import std.file;

public immutable uint BYTES_PER_KIB = 1024;
public immutable uint BYTES_PER_MIB = BYTES_PER_KIB * BYTES_PER_KIB;

public interface Memory {
    ulong getCapacity();

    void* getPointer(uint address);

    byte getByte(uint address);

    void setByte(uint address, byte b);

    short getShort(uint address);

    void setShort(uint address, short s);

    int getInt(uint address);

    void setInt(uint address, int i);
}

public class ROM : Memory {
    protected shared void[] memory;

    protected this(ulong capacity) {
        this.memory = new shared ubyte[capacity];
    }

    public this(void[] memory) {
        this(memory.length);
        this.memory[] = memory[];
    }

    public this(string file, uint maxSize) {
        try {
            this(read(file, maxSize));
        } catch (FileException ex) {
            throw new Exception("Cannot initialize ROM", ex);
        }
    }

    public ulong getCapacity() {
        return memory.length;
    }

    public void* getPointer(uint address) {
        return cast(void*) memory.ptr + address;
    }

    public byte getByte(uint address) {
        return (cast(byte[]) memory)[address];
    }

    public void setByte(uint address, byte b) {
    }

    public short getShort(uint address) {
        return (cast(short[]) memory)[address >> 1];
    }

    public void setShort(uint address, short s) {
    }

    public int getInt(uint address) {
        return (cast(int[]) memory)[address >> 2];
    }

    public void setInt(uint address, int i) {
    }
}

public class RAM : ROM {
    public this(ulong capacity) {
        super(capacity);
    }

    public this(void[] memory) {
        super(memory);
    }

    public this(string file, uint maxByteSize) {
        super(file, maxByteSize);
    }

    public override void setByte(uint address, byte b) {
        (cast(byte[]) memory)[address] = b;
    }

    public override void setShort(uint address, short s) {
        (cast(short[]) memory)[address >> 1] = s;
    }

    public override void setInt(uint address, int i) {
        (cast(int[]) memory)[address >> 2] = i;
    }
}

public class ReadOnlyException : Exception {
    public this(uint address) {
        super(format("Memory is read only: 0x%X", address));
    }
}


public class BadAddressException : Exception {
    public this(uint address) {
        super(format("Invalid address: 0x%X", address));
    }
}
