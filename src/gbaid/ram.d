module gbaid.ram;

public class RAM {
    private int[] memory;

    public this(ulong capacity) {
        memory = new int[capacity];
    }

    public ulong getCapacity() {
        return memory.length;
    }

    public byte getByte(int address) {
        return cast(byte) (memory[address / 4] >> address % 4 * 8 & 0xFF);
    }

    public void setByte(int address, byte b) {
        int wordAddress = address / 4;
        int offset = address % 4 * 8;
        memory[wordAddress] = memory[wordAddress] & ~(0xFF << offset) | (b & 0xFF) << offset;
    }

    public short getShort(int address) {
        return cast(short) (memory[address / 2] >> address % 2 * 16 & 0xFFFF);
    }

    public void setShort(int address, short s) {
        int wordAddress = address / 2;
        int offset = address % 2 * 16;
        memory[wordAddress] = memory[wordAddress] & ~(0xFFFF << offset) | (s & 0xFFFF) << offset;
    }

    public int getWord(int address) {
        return memory[address];
    }

    public void setWord(int address, int w) {
        memory[address] = w;
    }

    public long getLong(int address) {
        address *= 2;
        return cast(long) memory[address] & 0xFFFFFFFF | cast(long) memory[address + 1] << 32;
    }

    public void setLong(int address, long l) {
        address *= 2;
        memory[address] = cast(int) l;
        memory[address + 1] = cast(int) (l >> 32);
    }
}
