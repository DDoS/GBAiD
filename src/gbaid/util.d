module gbaid.util;

import std.conv;

public uint ucast(byte v) {
    return cast(uint) v & 0xFF;
}

public uint ucast(short v) {
    return cast(uint) v & 0xFFFF;
}

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

public uint countBits(uint i) {
     i = i - (i >>> 1 & 0x55555555);
     i = (i & 0x33333333) + (i >>> 2 & 0x33333333);
     return (i + (i >>> 4) & 0x0F0F0F0F) * 0x01010101 >>> 24;
}

template getSafe(T) {
    public T getSafe(T[] array, int index, T def) {
        if (index < 0 || index >= array.length) {
            return def;
        }
        return array[index];
    }
}

template addAll(K, V) {
    public void addAll(ref V[K] to, V[K] from) {
        foreach (k; from.byKey()) {
            to[k] = from[k];
        }
    }
}

template removeAll(K, V) {
    public void removeAll(ref V[K] to, V[K] from) {
        foreach (k; from.byKey()) {
            to.remove(k);
        }
    }
}

public string toString(char[] cs) {
    ulong end;
    foreach (i; 0 .. cs.length) {
        if (cs[i] == '\0') {
            end = i;
            break;
        }
    }
    return to!string(cs[0 .. end]);
}
