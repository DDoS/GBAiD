module gbaid.util;

import core.time : Duration, MonoTime, hnsecs;
import core.thread : Thread;

import std.meta : Alias, AliasSeq, staticIndexOf;
import std.path : expandTilde, absolutePath, buildNormalizedPath;
import std.conv : to;

public enum uint BYTES_PER_KIB = 1024;
public enum uint BYTES_PER_MIB = BYTES_PER_KIB * BYTES_PER_KIB;

public alias Int8to32Types = AliasSeq!(byte, ubyte, short, ushort, int, uint);
public alias IsInt8to32Type(T) = Alias!(staticIndexOf!(T, Int8to32Types) >= 0);

public template IntSizeLog2(T) {
    static if (is(T == byte) || is(T == ubyte)) {
        private alias IntSizeLog2 = Alias!0;
    } else static if (is(T == short) || is(T == ushort)) {
        private alias IntSizeLog2 = Alias!1;
    } else static if (is(T == int) || is(T == uint)) {
        private alias IntSizeLog2 = Alias!2;
    } else static if (is(T == long) || is(T == ulong)) {
        private alias IntSizeLog2 = Alias!3;
    } else {
        static assert (0, "Not an integer type");
    }
}

public alias IntAlignMask(T) = Alias!(~((1 << IntSizeLog2!T) - 1));

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

public int rotateRight(int i, int shift) {
    return i >>> shift | i << 32 - shift;
}

int nextPowerOf2(int i) {
    i--;
    i |= i >> 1;
    i |= i >> 2;
    i |= i >> 4;
    i |= i >> 8;
    i |= i >> 16;
    return i + 1;
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

public mixin template declareFields(T, bool private_, string name, alias init, uint count) if (count > 0) {
    import std.conv : to;
    import std.traits : fullyQualifiedName;
    import std.meta : Alias;

    alias visibility = Alias!(private_ ? "private" : "public");

    mixin(visibility ~ " " ~ T.stringof ~ " " ~ name ~ (count - 1).to!string() ~ " = " ~ fullyQualifiedName!init ~ ";");

    static if (count == 1) {
        mixin(visibility ~ " alias " ~ name ~ "(uint index) = Alias!(mixin(\"" ~ name ~ "\" ~ index.to!string()));");
    } else static if (count > 1) {
        mixin declareFields!(T, private_, name, init, count - 1);
    }
}

public class NullPathException : Exception {
    public this(string type) {
        super("Path to \"" ~ type ~ "\" file is null");
    }
}

public class Timer {
    private static enum Duration YIELD_TIME = hnsecs(1000);
    private MonoTime startTime;

    public void start() {
        startTime = MonoTime.currTime();
    }

    public alias reset = start;
    public alias restart = start;

    @property public Duration elapsed() {
        return MonoTime.currTime() - startTime;
    }

    public void waitUntil(Duration time) {
        Duration duration = time - elapsed - YIELD_TIME;
        if (!duration.isNegative()) {
            Thread.sleep(duration);
        }
        while (elapsed < time) {
            Thread.yield();
        }
    }
}
