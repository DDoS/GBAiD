module gbaid.util;

import core.time : Duration, TickDuration, hnsecs;
import core.thread : Thread;

import std.path : expandTilde, absolutePath, buildNormalizedPath;
import std.conv : to;

public enum uint BYTES_PER_KIB = 1024;
public enum uint BYTES_PER_MIB = BYTES_PER_KIB * BYTES_PER_KIB;

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

public bool checkBits(int i, int m, int b) {
    return (i & m) == b;
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

public int sign(long v) {
    if (v == 0) {
        return 0;
    }
    return 1 - (v >>> 62 & 0b10);
}

public int mirror(byte b) {
    int bi = b & 0xFF;
    return bi << 24 | bi << 16 | bi << 8 | bi;
}

public int mirror(short s) {
    return s << 16 | s & 0xFFFF;
}

public int bitCount(int i) {
    i = i - (i >>> 1 & 0x55555555);
    i = (i & 0x33333333) + (i >>> 2 & 0x33333333);
    return (i + (i >>> 4) & 0x0F0F0F0F) * 0x01010101 >>> 24;
}

public int rotateRight(int i, int shift) {
    return i >>> shift | i << 32 - shift;
}

public bool carriedAdd(int a, int b, int c) {
    int negativeA = a >> 31;
    int negativeB = b >> 31;
    int negativeC = c >> 31;
    return negativeA && negativeB || negativeA && !negativeC || negativeB && !negativeC;
}

public bool overflowedAdd(int a, int b, int c) {
    int negativeA = a >> 31;
    int negativeB = b >> 31;
    int negativeC = c >> 31;
    return negativeA && negativeB && !negativeC || !negativeA && !negativeB && negativeC;
}

public bool borrowedSub(int a, int b, int c) {
    int negativeA = a >> 31;
    int negativeB = b >> 31;
    int negativeC = c >> 31;
    return (!negativeA || negativeB) && (!negativeA || negativeC) && (negativeB || negativeC);
}

public bool overflowedSub(int a, int b, int c) {
    int negativeA = a >> 31;
    int negativeB = b >> 31;
    int negativeC = c >> 31;
    return negativeA && !negativeB && !negativeC || !negativeA && negativeB && negativeC;
}

public T getSafe(T)(T[] array, int index, T def) {
    if (index < 0 || index >= array.length) {
        return def;
    }
    return array[index];
}

public void addAll(K, V)(ref V[K] to, V[K] from) {
    foreach (k; from.byKey()) {
        to[k] = from[k];
    }
}

public void removeAll(K, V)(ref V[K] to, V[K] from) {
    foreach (k; from.byKey()) {
        to.remove(k);
    }
}

public string toDString(inout(char)[] cs) {
    return toDString(cs.ptr, cs.length);
}

public string toDString(inout(char)* cs) {
    return toDString(cs, size_t.max);
}

public string toDString(inout(char)* cs, size_t length) {
    size_t end;
    foreach (i; 0 .. length) {
        if (!cs[i]) {
            end = i;
            break;
        }
    }
    return cs[0 .. end].idup;
}

public string expandPath(string relative) {
    return buildNormalizedPath(absolutePath(expandTilde(relative)));
}

public mixin template privateFields(T, string name, alias init, uint count) if (count > 0) {
    import std.conv : to;
    import std.traits : fullyQualifiedName;
    mixin("private " ~ T.stringof ~ " " ~ name ~ (count - 1).to!string() ~ " = " ~ fullyQualifiedName!init ~ ";");

    static if (count == 1) {
        import std.meta : Alias;
        mixin("private alias " ~ name ~ "(uint index) = Alias!(mixin(\"" ~ name ~ "\" ~ index.to!string()));");
    } else static if (count > 1) {
        mixin privateFields!(T, name, init, count - 1);
    }
}

public class NullPathException : Exception {
    public this(string type) {
        super("Path to \"" ~ type ~ "\" file is null");
    }
}

public class Timer {
    private static enum long YIELD_TIME = 1000;
    private TickDuration startTime;

    public void start() {
        startTime = TickDuration.currSystemTick();
    }

    public alias reset = start;
    public alias restart = start;

    public TickDuration getTime() {
        return TickDuration.currSystemTick() - startTime;
    }

    public void waitUntil(TickDuration time) {
        Duration duration = hnsecs(time.hnsecs() - getTime().hnsecs() - YIELD_TIME);
        if (!duration.isNegative()) {
            Thread.sleep(duration);
        }
        while (getTime() < time) {
            Thread.yield();
        }
    }
}
