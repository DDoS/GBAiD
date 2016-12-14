module gbaid.memory;

import core.time : TickDuration;

import std.format : format;
import std.file : read, FileException;

import gbaid.util;

public alias IORegisters = MonitoredMemory!RAM;

public enum uint BYTES_PER_KIB = 1024;
public enum uint BYTES_PER_MIB = BYTES_PER_KIB * BYTES_PER_KIB;

public abstract class Memory {
    public abstract size_t getCapacity();

    public abstract void[] getArray(uint address);

    public abstract void* getPointer(uint address);

    public abstract byte getByte(uint address);

    public abstract void setByte(uint address, byte b);

    public abstract short getShort(uint address);

    public abstract void setShort(uint address, short s);

    public abstract int getInt(uint address);

    public abstract void setInt(uint address, int i);
}

public class MainMemory : MappedMemory {
    public static enum uint BIOS_SIZE = 16 * BYTES_PER_KIB;
    private static enum uint BOARD_WRAM_SIZE = 256 * BYTES_PER_KIB;
    private static enum uint CHIP_WRAM_SIZE = 32 * BYTES_PER_KIB;
    private static enum uint IO_REGISTERS_SIZE = 1 * BYTES_PER_KIB;
    private static enum uint PALETTE_SIZE = 1 * BYTES_PER_KIB;
    private static enum uint VRAM_SIZE = 96 * BYTES_PER_KIB;
    private static enum uint OAM_SIZE = 1 * BYTES_PER_KIB;
    public static enum uint BIOS_START = 0x00000000;
    private static enum uint BIOS_MASK = 0x3FFF;
    private static enum uint BOARD_WRAM_MASK = 0x3FFFF;
    private static enum uint CHIP_WRAM_MASK = 0x7FFF;
    private static enum uint IO_REGISTERS_END = 0x040003FE;
    private static enum uint IO_REGISTERS_MASK = 0x3FF;
    private static enum uint PALETTE_MASK = 0x3FF;
    private static enum uint VRAM_MASK = 0x1FFFF;
    private static enum uint VRAM_LOWER_MASK = 0xFFFF;
    private static enum uint VRAM_HIGH_MASK = 0x17FFF;
    private static enum uint OAM_MASK = 0x3FF;
    private static enum uint GAME_PAK_START = 0x08000000;
    private DelegatedROM unusedMemory;
    private ProtectedROM bios;
    private RAM boardWRAM;
    private RAM chipWRAM;
    private IORegisters ioRegisters;
    private RAM palette;
    private RAM vram;
    private RAM oam;
    private Memory gamePak;
    private size_t capacity;

    public this(string biosFile) {
        unusedMemory = new DelegatedROM(0);
        bios = new ProtectedROM(biosFile, BIOS_SIZE);
        boardWRAM = new RAM(BOARD_WRAM_SIZE);
        chipWRAM = new RAM(CHIP_WRAM_SIZE);
        ioRegisters = new IORegisters(new RAM(IO_REGISTERS_SIZE));
        palette = new Palette(PALETTE_SIZE);
        vram = new VRAM(VRAM_SIZE, ioRegisters);
        oam = new OAM(OAM_SIZE);
        gamePak = new NullMemory();
        updateCapacity();
    }

    private void updateCapacity() {
        capacity = bios.getCapacity()
            + boardWRAM.getCapacity()
            + chipWRAM.getCapacity()
            + ioRegisters.getCapacity()
            + vram.getCapacity()
            + oam.getCapacity()
            + palette.getCapacity()
            + gamePak.getCapacity();
    }

    public ProtectedROM getBIOS() {
        return bios;
    }

    public IORegisters getIORegisters() {
        return ioRegisters;
    }

    public RAM getPalette() {
        return palette;
    }

    public RAM getVRAM() {
        return vram;
    }

    public RAM getOAM() {
        return oam;
    }

    public Memory getGamePak() {
        return gamePak;
    }

    public void setGamePak(Memory gamePak) {
        this.gamePak = gamePak;
        updateCapacity();
    }

    public void setBIOSProtection(bool delegate(uint) guard, int delegate(uint) fallback) {
        bios.setGuard(guard);
        bios.setFallback(fallback);
    }

    public void setUnusedMemoryFallBack(int delegate(uint) fallback) {
        unusedMemory.setDelegate(fallback);
    }

    protected override Memory map(ref uint address) {
        int highAddress = address >>> 24;
        int lowAddress = address & 0xFFFFFF;
        switch (highAddress) {
            case 0x0:
                if (lowAddress & ~BIOS_MASK) {
                    return unusedMemory;
                }
                address &= BIOS_MASK;
                return bios;
            case 0x1:
                return unusedMemory;
            case 0x2:
                address &= BOARD_WRAM_MASK;
                return boardWRAM;
            case 0x3:
                address &= CHIP_WRAM_MASK;
                return chipWRAM;
            case 0x4:
                if (address > IO_REGISTERS_END) {
                    return unusedMemory;
                }
                address &= IO_REGISTERS_MASK;
                return ioRegisters;
            case 0x5:
                address &= PALETTE_MASK;
                return palette;
            case 0x6:
                address &= VRAM_MASK;
                if (address & ~VRAM_LOWER_MASK) {
                    address &= VRAM_HIGH_MASK;
                }
                return vram;
            case 0x7:
                address &= OAM_MASK;
                return oam;
            case 0x8: .. case 0xE:
                address -= GAME_PAK_START;
                return gamePak;
            default:
                return unusedMemory;
        }
    }

    public override size_t getCapacity() {
        return capacity;
    }
}

public static class Palette : RAM {
    public this(size_t capacity) {
        super(capacity);
    }

    public override void setByte(uint address, byte b) {
        super.setShort(address, b << 8 | b & 0xFF);
    }
}

public class VRAM : RAM {
    private IORegisters ioRegisters;

    public this(size_t capacity, IORegisters ioRegisters) {
        super(capacity);
        this.ioRegisters = ioRegisters;
    }

    public override void setByte(uint address, byte b) {
        if (address < 0x10000 || (ioRegisters.getShort(0x0) & 0b111) > 2 && address < 0x14000) {
            super.setShort(address, b << 8 | b & 0xFF);
        }
    }
}

public static class OAM : RAM {
    public this(size_t capacity) {
        super(capacity);
    }

    public override void setByte(uint address, byte b) {
    }
}

public class ROM : Memory {
    protected void[] memoryRaw;
    protected byte[] memoryByte;
    protected short[] memoryShort;
    protected int[] memoryInt;

    protected this(size_t capacity) {
        this.memoryRaw = new byte[capacity];

        this.memoryByte = cast(byte[]) this.memoryRaw;
        this.memoryShort = cast(short[]) this.memoryRaw;
        this.memoryInt = cast(int[]) this.memoryRaw;
    }

    public this(void[] memory) {
        this(memory.length);
        this.memoryRaw[] = memory[];

        this.memoryByte = cast(byte[]) this.memoryRaw;
        this.memoryShort = cast(short[]) this.memoryRaw;
        this.memoryInt = cast(int[]) this.memoryRaw;
    }

    public this(string file, uint maxSize) {
        try {
            this(read(file, maxSize));
        } catch (FileException ex) {
            throw new Exception("Cannot initialize ROM", ex);
        }
    }

    public override size_t getCapacity() {
        return memoryByte.length;
    }

    public override void[] getArray(uint address) {
        return memoryRaw[address .. $];
    }

    public override void* getPointer(uint address) {
        return memoryRaw.ptr + address;
    }

    public override byte getByte(uint address) {
        return memoryByte[address];
    }

    public override void setByte(uint address, byte b) {
    }

    public override short getShort(uint address) {
        return memoryShort[address >> 1];
    }

    public override void setShort(uint address, short s) {
    }

    public override int getInt(uint address) {
        return memoryInt[address >> 2];
    }

    public override void setInt(uint address, int i) {
    }
}

public class RAM : ROM {
    public this(size_t capacity) {
        super(capacity);
    }

    public this(void[] memory) {
        super(memory);
    }

    public this(string file, uint maxByteSize) {
        super(file, maxByteSize);
    }

    public override void setByte(uint address, byte b) {
        memoryByte[address] = b;
    }

    public override void setShort(uint address, short s) {
        memoryShort[address >> 1] = s;
    }

    public override void setInt(uint address, int i) {
        memoryInt[address >> 2] = i;
    }
}

public abstract class MappedMemory : Memory {
    protected abstract Memory map(ref uint address);

    public override void[] getArray(uint address) {
        Memory memory = map(address);
        return memory.getArray(address);
    }

    public override void* getPointer(uint address) {
        Memory memory = map(address);
        return memory.getPointer(address);
    }

    public override byte getByte(uint address) {
        Memory memory = map(address);
        return memory.getByte(address);
    }

    public override void setByte(uint address, byte b) {
        Memory memory = map(address);
        memory.setByte(address, b);
    }

    public override short getShort(uint address) {
        Memory memory = map(address);
        return memory.getShort(address);
    }

    public override void setShort(uint address, short s) {
        Memory memory = map(address);
        memory.setShort(address, s);
    }

    public override int getInt(uint address) {
        Memory memory = map(address);
        return memory.getInt(address);
    }

    public override void setInt(uint address, int i) {
        Memory memory = map(address);
        memory.setInt(address, i);
    }
}

public class MonitoredMemory(M : Memory) : Memory {
    private alias ReadMonitorDelegate = void delegate(Memory, int, int, int, ref int);
    private alias PreWriteMonitorDelegate = bool delegate(Memory, int, int, int, ref int);
    private alias PostWriteMonitorDelegate = void delegate(Memory, int, int, int, int, int);
    private M memory;
    private MemoryMonitor[] monitors;

    public this(M memory) {
        this.memory = memory;
        monitors = new MemoryMonitor[divFourRoundUp(memory.getCapacity())];
    }

    public void addMonitor(ReadMonitorDelegate monitor, int address, int size) {
        addMonitor(new ReadMemoryMonitor(monitor), address, size);
    }

    public void addMonitor(PreWriteMonitorDelegate monitor, int address, int size) {
        addMonitor(new PreWriteMemoryMonitor(monitor), address, size);
    }

    public void addMonitor(PostWriteMonitorDelegate monitor, int address, int size) {
        addMonitor(new PostWriteMemoryMonitor(monitor), address, size);
    }

    public void addMonitor(MemoryMonitor monitor, int address, int size) {
        address >>= 2;
        size = divFourRoundUp(size);
        foreach (i; address .. address + size) {
            monitors[i] = monitor;
        }
    }

    public M getMonitored() {
        return memory;
    }

    public override size_t getCapacity() {
        return memory.getCapacity();
    }

    public override void[] getArray(uint address) {
        return memory.getArray(address);
    }

    public override void* getPointer(uint address) {
        return memory.getPointer(address);
    }

    public override byte getByte(uint address) {
        byte b = memory.getByte(address);
        MemoryMonitor monitor = getMonitor(address);
        if (monitor !is null) {
            int alignedAddress = address & ~3;
            int shift = ((address & 3) << 3);
            int mask = 0xFF << shift;
            int intValue = ucast(b) << shift;
            monitor.onRead(memory, alignedAddress, shift, mask, intValue);
            b = cast(byte) ((intValue & mask) >> shift);
        }
        return b;
    }

    public override void setByte(uint address, byte b) {
        MemoryMonitor monitor = getMonitor(address);
        if (monitor !is null) {
            int alignedAddress = address & ~3;
            int shift = ((address & 3) << 3);
            int mask = 0xFF << shift;
            int intValue = ucast(b) << shift;
            bool write = monitor.onPreWrite(memory, alignedAddress, shift, mask, intValue);
            if (write) {
                int oldValue = memory.getInt(alignedAddress);
                b = cast(byte) ((intValue & mask) >> shift);
                memory.setByte(address, b);
                int newValue = oldValue & ~mask | intValue & mask;
                monitor.onPostWrite(memory, alignedAddress, shift, mask, oldValue, newValue);
            }
        } else {
            memory.setByte(address, b);
        }
    }

    public override short getShort(uint address) {
        address &= ~1;
        short s = memory.getShort(address);
        MemoryMonitor monitor = getMonitor(address);
        if (monitor !is null) {
            int alignedAddress = address & ~3;
            int shift = ((address & 2) << 3);
            int mask = 0xFFFF << shift;
            int intValue = ucast(s) << shift;
            monitor.onRead(memory, alignedAddress, shift, mask, intValue);
            s = cast(short) ((intValue & mask) >> shift);
        }
        return s;
    }

    public override void setShort(uint address, short s) {
        address &= ~1;
        MemoryMonitor monitor = getMonitor(address);
        if (monitor !is null) {
            int alignedAddress = address & ~3;
            int shift = ((address & 2) << 3);
            int mask = 0xFFFF << shift;
            int intValue = ucast(s) << shift;
            bool write = monitor.onPreWrite(memory, alignedAddress, shift, mask, intValue);
            if (write) {
                int oldValue = memory.getInt(alignedAddress);
                s = cast(short) ((intValue & mask) >> shift);
                memory.setShort(address, s);
                int newValue = oldValue & ~mask | intValue & mask;
                monitor.onPostWrite(memory, alignedAddress, shift, mask, oldValue, newValue);
            }
        } else {
            memory.setShort(address, s);
        }
    }

    public override int getInt(uint address) {
        address &= ~3;
        int i = memory.getInt(address);
        MemoryMonitor monitor = getMonitor(address);
        if (monitor !is null) {
            int alignedAddress = address;
            int shift = 0;
            int mask = 0xFFFFFFFF;
            int intValue = i;
            monitor.onRead(memory, alignedAddress, shift, mask, intValue);
            i = intValue;
        }
        return i;
    }

    public override void setInt(uint address, int i) {
        address &= ~3;
        MemoryMonitor monitor = getMonitor(address);
        if (monitor !is null) {
            int alignedAddress = address;
            int shift = 0;
            int mask = 0xFFFFFFFF;
            int intValue = i;
            bool write = monitor.onPreWrite(memory, alignedAddress, shift, mask, intValue);
            if (write) {
                int oldValue = memory.getInt(alignedAddress);
                i = intValue;
                memory.setInt(address, i);
                int newValue = oldValue & ~mask | intValue & mask;
                monitor.onPostWrite(memory, alignedAddress, shift, mask, oldValue, newValue);
            }
        } else {
            memory.setInt(address, i);
        }
    }

    private MemoryMonitor getMonitor(int address) {
        return monitors[address >> 2];
    }

    private static int divFourRoundUp(size_t i) {
        return cast(int) ((i >> 2) + ((i & 0b11) ? 1 : 0));
    }

    private static class ReadMemoryMonitor : MemoryMonitor {
        private ReadMonitorDelegate monitor;

        private this(ReadMonitorDelegate monitor) {
            this.monitor = monitor;
        }

        protected override void onRead(Memory memory, int address, int shift, int mask, ref int value) {
            monitor(memory, address, shift, mask, value);
        }
    }

    private static class PreWriteMemoryMonitor : MemoryMonitor {
        private PreWriteMonitorDelegate monitor;

        private this(PreWriteMonitorDelegate monitor) {
            this.monitor = monitor;
        }

        protected override bool onPreWrite(Memory memory, int address, int shift, int mask, ref int value) {
            return monitor(memory, address, shift, mask, value);
        }
    }

    private static class PostWriteMemoryMonitor : MemoryMonitor {
        private PostWriteMonitorDelegate monitor;

        private this(PostWriteMonitorDelegate monitor) {
            this.monitor = monitor;
        }

        protected override void onPostWrite(Memory memory, int address, int shift, int mask, int oldValue, int newValue) {
            monitor(memory, address, shift, mask, oldValue, newValue);
        }
    }
}

public abstract class MemoryMonitor {
    protected void onRead(Memory memory, int address, int shift, int mask, ref int value) {
    }

    protected bool onPreWrite(Memory memory, int address, int shift, int mask, ref int value) {
        return true;
    }

    protected void onPostWrite(Memory memory, int address, int shift, int mask, int oldValue, int newValue) {
    }
}

public class ProtectedROM : ROM {
    private bool delegate(uint) guard;
    private int delegate(uint) fallback;

    public this(void[] memory) {
        super(memory);
        guard = &unguarded;
        fallback = &nullFallback;
    }

    public this(string file, uint maxSize) {
        super(file, maxSize);
        guard = &unguarded;
        fallback = &nullFallback;
    }

    public void setGuard(bool delegate(uint) guard) {
        this.guard = guard;
    }

    public void setFallback(int delegate(uint) fallback) {
        this.fallback = fallback;
    }

    public override byte getByte(uint address) {
        if (guard(address)) {
            return super.getByte(address);
        }
        return cast(byte) fallback(address);
    }

    public override short getShort(uint address) {
        if (guard(address)) {
            return super.getShort(address);
        }
        return cast(short) fallback(address);
    }

    public override int getInt(uint address) {
        if (guard(address)) {
            return super.getInt(address);
        }
        return fallback(address);
    }

    private bool unguarded(uint address) {
        return true;
    }

    private int nullFallback(uint address) {
        return 0;
    }
}

public class DelegatedROM : Memory {
    private int delegate(uint) memory;
    private size_t apparentCapacity;

    public this(size_t apparentCapacity) {
        this.apparentCapacity = apparentCapacity;
        memory = &nullDelegate;
    }

    public void setDelegate(int delegate(uint) memory) {
        this.memory = memory;
    }

    public override size_t getCapacity() {
        return apparentCapacity;
    }

    public override void[] getArray(uint address) {
        throw new UnsupportedMemoryOperationException("getArray");
    }

    public override void* getPointer(uint address) {
        throw new UnsupportedMemoryOperationException("getPointer");
    }

    public override byte getByte(uint address) {
        return cast(byte) memory(address);
    }

    public override void setByte(uint address, byte b) {
    }

    public override short getShort(uint address) {
        return cast(short) memory(address);
    }

    public override void setShort(uint address, short s) {
    }

    public override int getInt(uint address) {
        return memory(address);
    }

    public override void setInt(uint address, int i) {
    }

    private int nullDelegate(uint address) {
        return 0;
    }
}

public class NullMemory : Memory {
    public override size_t getCapacity() {
        return 0;
    }

    public override void[] getArray(uint address) {
        return null;
    }

    public override void* getPointer(uint address) {
        return null;
    }

    public override byte getByte(uint address) {
        return 0;
    }

    public override void setByte(uint address, byte b) {
    }

    public override short getShort(uint address) {
        return 0;
    }

    public override void setShort(uint address, short s) {
    }

    public override int getInt(uint address) {
        return 0;
    }

    public override void setInt(uint address, int i) {
    }
}

public class ReadOnlyException : Exception {
    public this(uint address) {
        super(format("Memory is read only: 0x%08X", address));
    }
}

public class UnsupportedMemoryWidthException : Exception {
    public this(uint address, uint badByteWidth) {
        super(format("Attempted to access 0x%08X with unsupported memory width of %s bytes", address, badByteWidth));
    }
}

public class BadAddressException : Exception {
    public this(uint address) {
        this("Invalid address", address);
    }

    public this(string message, uint address) {
        super(format("%s: 0x%08X", message, address));
    }
}

public class UnsupportedMemoryOperationException : Exception {
    public this(string operation) {
        super(format("Unsupported operation: %s", operation));
    }
}
