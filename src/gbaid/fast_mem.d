module gbaid.fast_mem;

import std.traits : MutableOf, ImmutableOf;
import std.meta : Alias, AliasSeq, staticIndexOf;
import std.file : read, FileException;

public struct Memory(bool readOnly) {
    private alias ValidSizes = AliasSeq!(byte, ubyte, short, ushort, int, uint);
    private Mod!(void[]) rawMemory;
    mixin memoryViews!ValidSizes;
    private immutable size_t byteSize;

    static if (!readOnly) {
        public this(size_t byteSize) {
            rawMemory.length = byteSize;
            this.byteSize = byteSize;
            mixin(setMemoryViewsCode!ValidSizes);
        }
    }

    public this(void[] memory) {
        static if (readOnly) {
            rawMemory = memory.idup;
        } else {
            rawMemory = memory.dup;
        }
        byteSize = memory.length;
        mixin(setMemoryViewsCode!ValidSizes);
    }

    public this(string file, uint maxSize) {
        try {
            this(read(file, maxSize));
        } catch (FileException ex) {
            throw new Exception("Cannot read ROM file", ex);
        }
    }

    public size_t getByteSize() {
        return byteSize;
    }

    public Mod!T get(T)(uint address) if (isValidSize!T) {
        return mixin(memoryCode!T)[address >> sizeBase2Power!T];
    }

    static if (!readOnly) {
        public void set(T)(uint address, T v) if (isValidSize!T) {
            mixin(memoryCode!T)[address >> sizeBase2Power!T] = v;
        }
    }

    public Mod!(T[]) getArray(T)(uint address, uint size) if (isValidSize!T) {
        auto start = address >> sizeBase2Power!T;
        return mixin(memoryCode!T)[start .. start + (size >> sizeBase2Power!T)];
    }

    public Mod!(T*) getPointer(T)(uint address) if (isValidSize!T) {
        return mixin(memoryCode!T).ptr + (address >> sizeBase2Power!T);
    }

    private alias memoryCode(T) = Alias!(T.stringof ~ "Memory");

    private mixin template memoryViews(T, Ts...) {
        mixin("private Mod!(T[]) " ~ memoryCode!T ~ ";");
        static if (Ts.length > 0) {
            mixin memoryViews!Ts;
        }
    }

    private template setMemoryViewsCode(T, Ts...) {
        private alias setMemoryViewCode = Alias!(memoryCode!T ~ " = cast(Mod!(" ~ T.stringof ~ "[])) rawMemory;");
        static if (Ts.length <= 0) {
            private alias setMemoryViewsCode = Alias!setMemoryViewCode;
        } else {
            private alias setMemoryViewsCode = Alias!(setMemoryViewCode ~ setMemoryViewsCode!Ts);
        }
    }

    private template Mod(T) {
        static if (readOnly) {
            private alias Mod = ImmutableOf!T;
        } else {
            private alias Mod = MutableOf!T;
        }
    }

    private enum isValidSize(T) = staticIndexOf!(T, ValidSizes) >= 0;

    private template sizeBase2Power(T) {
        static if (is(T == byte) || is(T == ubyte)) {
            private enum sizeBase2Power = 0;
        } else static if (is(T == short) || is(T == ushort)) {
            private enum sizeBase2Power = 1;
        } else static if (is(T == int) || is(T == uint)) {
            private enum sizeBase2Power = 2;
        } else {
            static assert (0);
        }
    }
}

unittest {
    auto ram = Memory!false(1024);

    static assert(is(typeof(ram.get!ushort(2)) == ushort));
    static assert(is(typeof(ram.getPointer!ushort(3)) == ushort*));
    static assert(is(typeof(ram.getArray!ushort(5, 2)) == ushort[]));

    ram.set!ushort(2, 34);
    assert(*ram.getPointer!ushort(2) == 34);
    assert(ram.getArray!ushort(2, 8) == [34, 0, 0, 0]);
}

unittest {
    int[] data = [9, 8, 7, 6, 5, 4, 3, 2, 1, 0];
    auto rom = Memory!true(data);

    static assert(!__traits(compiles, Memory!true(1024)));
    static assert(!__traits(compiles, rom.set!int(8, 34)));
    static assert(is(typeof(rom.get!int(4)) == immutable int));
    static assert(is(typeof(rom.getPointer!int(8)) == immutable int*));
    static assert(is(typeof(rom.getArray!int(24, 12)) == immutable int[]));

    assert(rom.get!int(4) == 8);
    assert(*rom.getPointer!int(8) == 7);
    assert(rom.getArray!int(24, 12) == [3, 2, 1]);
}
