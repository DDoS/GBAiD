module gbaid.util;

public ulong ucast(int v) {
    return cast(ulong) v & 0xFFFFFFFF;
}

public bool checkBit(int i, int b) {
    return cast(bool) getBit(i, b);
}

public int getBit(int i, int b) {
    return i >> b & 1;
}

public void setBit(ref int i, int b, int n) {
    i = i & ~(1 << b) | (n & 1) << b;
}

public int getBits(int i, int a, int b) {
    return i >> a & (1 << b - a + 1) - 1;
}

public void setBits(ref int i, int a, int b, int n) {
    int mask = (1 << b - a + 1) - 1 << a;
    i = i & ~mask | n << a & mask;
}

public bool carried(int a, int b, int r) {
    return cast(uint) r < cast(uint) a;
}

public bool overflowed(int a, int b, int r) {
    int rn = getBit(r, 31);
    return getBit(a, 31) != rn && getBit(b, 31) != rn;
}

template getSafe(T) {
    public T getSafe(T[] array, int index) {
        if (index < 0 || index >= array.length) {
            T t;
            return t;
        }
        return array[index];
    }
}
