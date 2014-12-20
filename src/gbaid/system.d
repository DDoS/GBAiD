module gbaid.system;

import core.time;
import core.thread;
import core.sync.semaphore;
import core.atomic;

import std.stdio;
import std.string;
import std.traits;
import std.typecons;
import std.algorithm;

import derelict.sdl2.sdl;

import gbaid.arm;
import gbaid.graphics;
import gbaid.memory;
import gbaid.input;
import gbaid.util;

public alias InterruptSource = InterruptHandler.InterruptSource;
public alias IORegisters = MonitoredMemory!RAM;

public class GameBoyAdvance {
    private MainMemory memory;
    private ARM7TDMI processor;
    private InterruptHandler interruptHandler;
    private Display display;
    private Keypad keypad;
    private Timers timers;
    private DMAs dmas;
    private bool running = false;

    public this(string biosFile) {
        if (biosFile is null) {
            throw new NullPathException("BIOS");
        }

        memory = new MainMemory(biosFile);

        IORegisters ioRegisters = memory.getIORegisters();

        processor = new ARM7TDMI(memory);
        interruptHandler = new InterruptHandler(ioRegisters, processor);
        keypad = new Keypad(ioRegisters, interruptHandler);
        timers = new Timers(ioRegisters, interruptHandler);
        dmas = new DMAs(memory, ioRegisters, interruptHandler);
        display = new Display(ioRegisters, memory.getPalette(), memory.getVRAM(), memory.getOAM(), interruptHandler, dmas);

        processor.setEntryPointAddress(MainMemory.BIOS_START);
    }

    public void loadROM(string file) {
        if (file is null) {
            throw new NullPathException("ROM");
        }
        checkNotRunning();
        memory.getGamePak().loadROM(file);
    }

    public void loadSave(string file) {
        if (file is null) {
            throw new NullPathException("save");
        }
        checkNotRunning();
        memory.getGamePak().loadSave(file);
    }

    public void saveSave(string file) {
        if (file is null) {
            throw new NullPathException("save");
        }
        checkNotRunning();
        memory.getGamePak().saveSave(file);
    }

    public void loadNewSave() {
        checkNotRunning();
        memory.getGamePak().loadEmptySave();
    }

    public void setDisplayScale(float scale) {
        display.setScale(scale);
    }

    public void setDisplayUpscalingMode(UpscalingMode mode) {
        display.setUpscalingMode(mode);
    }

    public MainMemory getMemory() {
        return memory;
    }

    public void run() {
        checkNotRunning();
        if (!memory.getGamePak().hasROM()) {
            throw new NoROMException();
        }
        if (!memory.getGamePak().hasSave()) {
            throw new NoSaveException();
        }
        if (!DerelictSDL2.isLoaded) {
            DerelictSDL2.load();
        }
        SDL_Init(0);
        keypad.start();
        dmas.start();
        timers.start();
        processor.start();
        display.run();
        processor.stop();
        timers.stop();
        dmas.stop();
        keypad.stop();
        SDL_Quit();
    }

    private void checkNotRunning() {
        if (running) {
            throw new EmulatorRunningException();
        }
    }
}

public static class MainMemory : MappedMemory {
    private static immutable uint BIOS_SIZE = 16 * BYTES_PER_KIB;
    private static immutable uint BOARD_WRAM_SIZE = 256 * BYTES_PER_KIB;
    private static immutable uint CHIP_WRAM_SIZE = 32 * BYTES_PER_KIB;
    private static immutable uint IO_REGISTERS_SIZE = 1 * BYTES_PER_KIB;
    private static immutable uint PALETTE_SIZE = 1 * BYTES_PER_KIB;
    private static immutable uint VRAM_SIZE = 96 * BYTES_PER_KIB;
    private static immutable uint OAM_SIZE = 1 * BYTES_PER_KIB;
    private static immutable uint BIOS_START = 0x00000000;
    private static immutable uint BIOS_MASK = 0x3FFF;
    private static immutable uint BOARD_WRAM_MASK = 0x3FFFF;
    private static immutable uint CHIP_WRAM_MASK = 0x7FFF;
    private static immutable uint CHIP_WRAM_MIRROR_START = 0xFFFF00;
    private static immutable uint CHIP_WRAM_MIRROR_MASK = 0x7FFF;
    private static immutable uint IO_REGISTERS_END = 0x040003FE;
    private static immutable uint IO_REGISTERS_MASK = 0x3FF;
    private static immutable uint PALETTE_MASK = 0x3FF;
    private static immutable uint VRAM_END = 0x06017FFF;
    private static immutable uint VRAM_MASK = 0x1FFFF;
    private static immutable uint OAM_MASK = 0x3FF;
    private static immutable uint GAME_PAK_START = 0x08000000;
    private NullMemory unusedMemory;
    private ROM bios;
    private RAM boardWRAM;
    private RAM chipWRAM;
    private IORegisters ioRegisters;
    private RAM vram;
    private RAM oam;
    private RAM palette;
    private GamePak gamePak;
    private ulong capacity;

    private this(string biosFile) {
        unusedMemory = new NullMemory();
        bios = new ROM(biosFile, BIOS_SIZE);
        boardWRAM = new RAM(BOARD_WRAM_SIZE);
        chipWRAM = new RAM(CHIP_WRAM_SIZE);
        ioRegisters = new IORegisters(new RAM(IO_REGISTERS_SIZE));
        vram = new RAM(VRAM_SIZE);
        oam = new RAM(OAM_SIZE);
        palette = new RAM(PALETTE_SIZE);
        gamePak = new GamePak();
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

    private IORegisters getIORegisters() {
        return ioRegisters;
    }

    private RAM getPalette() {
        return palette;
    }

    private RAM getVRAM() {
        return vram;
    }

    private RAM getOAM() {
        return oam;
    }

    private GamePak getGamePak() {
        return gamePak;
    }

    protected override Memory map(ref uint address) {
        int highAddress = address >> 24;
        int lowAddress = address & 0xFFFFFF;
        switch (highAddress) {
            case 0x0:
                if (lowAddress & ~BIOS_MASK) {
                    return unusedMemory;
                }
                address &= BIOS_MASK;
                return bios;
            case 0x2:
                if (lowAddress & ~BOARD_WRAM_MASK) {
                    return unusedMemory;
                }
                address &= BOARD_WRAM_MASK;
                return boardWRAM;
            case 0x3:
                if (lowAddress & ~CHIP_WRAM_MASK) {
                    if ((lowAddress & CHIP_WRAM_MIRROR_START) == CHIP_WRAM_MIRROR_START) {
                        address &= CHIP_WRAM_MIRROR_MASK;
                        return chipWRAM;
                    }
                    return unusedMemory;
                }
                address &= CHIP_WRAM_MASK;
                return chipWRAM;
            case 0x4:
                if (address > IO_REGISTERS_END) {
                    return unusedMemory;
                }
                address &= IO_REGISTERS_MASK;
                return ioRegisters;
            case 0x5:
                if (lowAddress & ~PALETTE_MASK) {
                    return unusedMemory;
                }
                address &= PALETTE_MASK;
                return palette;
            case 0x6:
                if (address > VRAM_END) {
                    return unusedMemory;
                }
                address &= VRAM_MASK;
                return vram;
            case 0x7:
                if (lowAddress & ~OAM_MASK) {
                    return unusedMemory;
                }
                address &= OAM_MASK;
                return oam;
            case 0x8: .. case 0xE:
                address -= GAME_PAK_START;
                return gamePak;
            default:
                return unusedMemory;
        }
    }

    public override ulong getCapacity() {
        return capacity;
    }
}

private static class GamePak : MappedMemory {
    private static immutable uint MAX_ROM_SIZE = 32 * BYTES_PER_MIB;
    private static immutable uint ROM_START = 0x00000000;
    private static immutable uint ROM_END = 0x05FFFFFF;
    private static immutable uint SAVE_START = 0x06000000;
    private static immutable uint SAVE_END = 0x0600FFFF;
    private static immutable uint EEPROM_START_NARROW = 0x05FFFF00;
    private static immutable uint EEPROM_START_WIDE = 0x05000000;
    private static immutable uint EEPROM_END = 0x05FFFFFF;
    private NullMemory unusedMemory;
    private Memory rom;
    private Memory save;
    private Memory eeprom;
    private bool hasEEPROM;
    private uint eepromStart;
    private ulong capacity;

    private this() {
        unusedMemory = new NullMemory();
        rom = unusedMemory;
        save = unusedMemory;
        eeprom = unusedMemory;
        updateCapacity();
    }

    private void updateCapacity() {
        capacity = rom.getCapacity() + save.getCapacity() + eeprom.getCapacity();
    }

    private void loadROM(string romFile) {
        rom = new ROM(romFile, MAX_ROM_SIZE);
        eepromStart = rom.getCapacity() > 16 * BYTES_PER_MIB ? EEPROM_START_NARROW : EEPROM_START_WIDE;
        updateCapacity();
    }

    private void loadSave(string saveFile) {
        Memory[] loaded = loadFromFile(saveFile);
        foreach (Memory memory; loaded) {
            if (cast(EEPROM) memory) {
                eeprom = memory;
                hasEEPROM = true;
            } else if (cast(Flash) memory || cast(RAM) memory) {
                save = memory;
            } else {
                throw new Exception("Unsupported memory save type: " ~ typeid(memory).name);
            }
        }
        updateCapacity();
    }

    private void saveSave(string saveFile) {
        if (cast(NullMemory) eeprom) {
            saveToFile(saveFile, save);
        } else {
            saveToFile(saveFile, save, eeprom);
        }
    }

    private bool hasROM() {
        return !(cast(NullMemory) rom);
    }

    private bool hasSave() {
        return !(cast(NullMemory) save) || hasEEPROM;
    }

    private void loadEmptySave() {
        // Detect save types and size using ID strings in ROM
        bool hasFlash = false;
        int saveSize = SaveMemory.SRAM[1];
        char[] romChars = cast(char[]) rom.getArray(0);
        auto saveTypes = EnumMembers!SaveMemory;
        for (ulong i = 0; i < romChars.length; i += 4) {
            foreach (saveType; saveTypes) {
                string saveID = saveType[0];
                if (romChars[i .. min(i + saveID.length, romChars.length)] == saveID) {
                    final switch (saveID) {
                        case SaveMemory.EEPROM[0]:
                            hasEEPROM = true;
                            break;
                        case SaveMemory.FLASH[0]:
                        case SaveMemory.FLASH512[0]:
                        case SaveMemory.FLASH1M[0]:
                            hasFlash = true;
                            saveSize = saveType[1];
                            break;
                    }
                }
            }
        }
        // Allocate the memory
        if (hasFlash) {
            save = new Flash(saveSize);
        } else {
            save = new RAM(saveSize);
        }
        if (hasEEPROM) {
            eeprom = new EEPROM(SaveMemory.EEPROM[1]);
        }
        // Update the capacity
        updateCapacity();
    }

    protected override Memory map(ref uint address) {
        if (address >= ROM_START && address <= ROM_END) {
            if (hasEEPROM && address >= eepromStart && address <= EEPROM_END) {
                address -= eepromStart;
                return eeprom;
            }
            address -= ROM_START;
            address &= MAX_ROM_SIZE - 1;
            if (address < rom.getCapacity()) {
                return rom;
            } else {
                return unusedMemory;
            }
        }
        if (address >= SAVE_START && address <= SAVE_END) {
            address -= SAVE_START;
            if (address < save.getCapacity()) {
                return save;
            } else {
                return unusedMemory;
            }
        }
        return unusedMemory;
    }

    public override ulong getCapacity() {
        return capacity;
    }

    private static enum SaveMemory {
        EEPROM = tuple("EEPROM_V", 8 * BYTES_PER_KIB),
        SRAM = tuple("SRAM_V", 64 * BYTES_PER_KIB),
        FLASH = tuple("FLASH_V", 64 * BYTES_PER_KIB),
        FLASH512 = tuple("FLASH512_V", 64 * BYTES_PER_KIB),
        FLASH1M = tuple("FLASH1M_V", 128 * BYTES_PER_KIB)
    }
}

public static class DMAs {
    private MainMemory memory;
    private InterruptHandler interruptHandler;
    private RAM ioRegisters;
    private Thread thread;
    private shared bool running = false;
    private Semaphore semaphore;
    private shared int signals = 0;
    private shared int[4] sourceAddresses = new int[4];
    private shared int[4] destinationAddresses = new int[4];
    private shared int[4] wordCounts = new int[4];

    private this(MainMemory memory, IORegisters ioRegisters, InterruptHandler interruptHandler) {
        this.memory = memory;
        this.interruptHandler = interruptHandler;
        this.ioRegisters = ioRegisters.getMonitored();
        semaphore = new Semaphore();
        ioRegisters.addMonitor(&onPostWrite, 0xBA, 2);
        ioRegisters.addMonitor(&onPostWrite, 0xC6, 2);
        ioRegisters.addMonitor(&onPostWrite, 0xD2, 2);
        ioRegisters.addMonitor(&onPostWrite, 0xDE, 2);
    }

    private void start() {
        thread = new Thread(&run);
        thread.name = "DMA";
        running = true;
        thread.start();
    }

    private void stop() {
        if (running) {
            running = false;
            semaphore.notify();
        }
    }

    public void signalVBLANK() {
        atomicOp!"|="(signals, 0b10);
        semaphore.notify();
    }

    public void signalHBLANK() {
        atomicOp!"|="(signals, 0b100);
        semaphore.notify();
    }

    private void onPostWrite(Memory ioRegisters, int address, int shift, int mask, int oldControl, int newControl) {
        if (!checkBit(newControl, 31) || checkBit(oldControl, 31)) {
            return;
        }

        int channel = (address - 0xB8) / 0xC;
        sourceAddresses[channel] = formatSourceAddress(ioRegisters.getInt(address - 8), channel);
        destinationAddresses[channel] = formatDestinationAddress(ioRegisters.getInt(address - 4), channel);
        wordCounts[channel] = formatWordCount(newControl, channel);

        atomicOp!"|="(signals, 0b1);
        interruptHandler.dmaHalt();
        semaphore.notify();
    }

    private void run() {
        while (true) {
            semaphore.wait();
            if (!running) {
                return;
            }
            while (atomicLoad(signals) != 0) {
                for (int s = 0; s < 4; s++) {
                    if (checkBit(atomicLoad(signals), s)) {
                        atomicOp!"&="(signals, ~(1 << s));
                        for (int c = 0; c < 4; c++) {
                            tryDMA(c, s);
                        }
                        interruptHandler.dmaResume();
                    }
                }
            }
        }
    }

    private void tryDMA(int channel, int source) {
        int dmaAddress = channel * 0xC + 0xB8;

        int control = ioRegisters.getShort(dmaAddress + 2);
        if (!checkBit(control, 15)) {
            return;
        }

        int startTiming = getBits(control, 12, 13);
        if (startTiming != source) {
            return;
        }

        int wordCount = wordCounts[channel];
        int type = void;
        int destinationAddressControl = void;

        if (startTiming == 3) {
            if (channel == 1 || channel == 2) {
                wordCount = 4;
                type = 1;
                destinationAddressControl = 2;
            } else if (channel == 3) {
                // TODO: implement video capture
            }
        } else {
            type = getBit(control, 10);
            destinationAddressControl = getBits(control, 5, 6);
        }

        int sourceAddressControl = getBits(control, 7, 8);
        int repeat = getBit(control, 9);
        int endIRQ = getBit(control, 14);

        int increment = type ? 4 : 2;

        interruptHandler.dmaHalt();

        //writefln("DMA %s %08x to %08x, %x bytes, timing %s", channel, sourceAddresses[channel], destinationAddresses[channel], wordCount * increment, startTiming);

        for (int i = 0; i < wordCount; i++) {
            if (type) {
                memory.setInt(destinationAddresses[channel], memory.getInt(sourceAddresses[channel]));
            } else {
                memory.setShort(destinationAddresses[channel], memory.getShort(sourceAddresses[channel]));
            }
            modifyAddress(sourceAddresses[channel], sourceAddressControl, increment);
            modifyAddress(destinationAddresses[channel], destinationAddressControl, increment);
        }

        if (repeat) {
            wordCounts[channel] = formatWordCount(ioRegisters.getInt(dmaAddress), channel);
            if (destinationAddressControl == 3) {
                destinationAddresses[channel] = formatDestinationAddress(ioRegisters.getInt(dmaAddress - 4), channel);
            }
            atomicOp!"|="(signals, 0b1);
        } else {
            ioRegisters.setShort(dmaAddress + 2, cast(short) (control & 0x7FFF));
        }

        if (endIRQ) {
            interruptHandler.requestInterrupt(InterruptSource.DMA_0 + channel);
        }

        interruptHandler.dmaResume();
    }

    private void modifyAddress(ref shared int address, int control, int amount) {
        final switch (control) {
            case 0:
            case 3:
                atomicOp!"+="(address, amount);
                break;
            case 1:
                atomicOp!"-="(address, amount);
                break;
            case 2:
                break;
        }
    }

    private int formatSourceAddress(int sourceAddress, int channel) {
        if (channel == 0) {
            return sourceAddress & 0x7FFFFFF;
        }
        return sourceAddress & 0xFFFFFFF;
    }

    private int formatDestinationAddress(int destinationAddress, int channel) {
        if (channel == 3) {
            return destinationAddress & 0xFFFFFFF;
        }
        return destinationAddress & 0x7FFFFFF;
    }

    private int formatWordCount(int wordCount, int channel) {
        if (channel < 3) {
            wordCount &= 0x3FFF;
            if (wordCount == 0) {
                return 0x4000;
            }
            return wordCount;
        }
        wordCount &= 0xFFFF;
        if (wordCount == 0) {
            return 0x10000;
        }
        return wordCount;
    }
}

private static class Timers {
    private InterruptHandler interruptHandler;
    private RAM ioRegisters;
    private long[4] startTimes = new long[4];
    private long[4] endTimes = new long[4];
    private Scheduler scheduler;
    private int[4] irqTasks = new int[4];
    private void delegate()[4] irqHandlers;

    public this(IORegisters ioRegisters, InterruptHandler interruptHandler) {
        this.interruptHandler = interruptHandler;
        this.ioRegisters = ioRegisters.getMonitored();
        scheduler = new Scheduler();
        irqHandlers = [&irqHandler!0, &irqHandler!1, &irqHandler!2, &irqHandler!3];
        ioRegisters.addMonitor(new TimerMemoryMonitor(), 0x100, 16);
    }

    private void start() {
        scheduler.start();
    }

    private void stop() {
        scheduler.shutdown();
    }

    private class TimerMemoryMonitor : MemoryMonitor {
        protected override void onRead(Memory ioRegisters, int address, int shift, int mask, ref int value) {
            // ignore reads that aren't on the counter
            if (!(mask & 0xFFFF)) {
                return;
            }
            // fetch the timer number and information
            int i = (address - 0x100) / 4;
            int timer = ioRegisters.getInt(address);
            int control = timer >>> 16;
            int reload = timer & 0xFFFF;
            // convert the full tick count to the 16 bit format used by the GBA
            short counter = formatTickCount(getTickCount(i, control, reload), reload);
            // write the counter to the value
            value = value & ~mask | counter & mask;
        }

        protected override void onPostWrite(Memory ioRegisters, int address, int shift, int mask, int previousTimer, int newTimer) {
            // get the timer number and previous value
            int i = (address - 0x100) / 4;
            // check writes to the control byte for enable changes
            if (mask & 0xFF0000) {
                // check using the previous control value for a change in the enable bit
                if (!checkBit(previousTimer, 23)) {
                    if (checkBit(newTimer, 23)) {
                        // 0 to 1, reset the start time
                        startTimes[i] = TickDuration.currSystemTick().nsecs();
                    }
                } else if (!checkBit(newTimer, 23)) {
                    // 1 to 0, set the end time
                    endTimes[i] = TickDuration.currSystemTick().nsecs();
                }
            }
            // get the control and reload
            int control = newTimer >>> 16;
            int reload = newTimer & 0xFFFF;
            // update the IRQs
            if (isRunning(i, control)) {
                // check for IRQ enable if the time is running
                if (checkBit(control, 6)) {
                    // (re)schedule the IRQ
                    scheduleIRQ(i, control, reload);
                } else {
                    // cancel the IRQ
                    cancelIRQ(i);
                }
            } else {
                // cancel the IRQs and any dependent ones (upcounters)
                cancelIRQ(i);
                cancelDependentIRQs(i + 1);
            }
        }
    }

    private bool isRunning(int i, int control) {
        // check if timer is an upcounter
        if (i != 0 && checkBit(control, 2)) {
            // upcounters must also also have the previous timer running
            int previousControl = ioRegisters.getInt(i * 4 + 0xFC) >>> 16;
            return checkBit(control, 7) && isRunning(i - 1, previousControl);
        } else {
            // regular timers must just be running
            return checkBit(control, 7);
        }
    }

    private template irqHandler(int i) {
        private void irqHandler() {
            interruptHandler.requestInterrupt(InterruptSource.TIMER_0_OVERFLOW + i);
            irqTasks[i] = 0;
            scheduleIRQ(i);
        }
    }

    private void scheduleIRQ(int i) {
        int timer = ioRegisters.getInt(i * 4 + 0x100);
        int control = timer >>> 16;
        int reload = timer & 0xFFFF;
        scheduleIRQ(i, control, reload);
    }

    private void scheduleIRQ(int i, int control, int reload) {
        cancelIRQ(i);
        long nextIRQ = cast(long) getTimeUntilIRQ(i, control, reload) + TickDuration.currSystemTick().nsecs();
        irqTasks[i] = scheduler.schedule(nextIRQ, irqHandlers[i]);
    }

    private void cancelIRQ(int i) {
        if (irqTasks[i] > 0) {
            scheduler.cancel(irqTasks[i]);
            irqTasks[i] = 0;
        }
    }

    private void cancelDependentIRQs(int i) {
        if (i > 3) {
            // prevent infinite recursion
            return;
        }
        int control = ioRegisters.getInt(i * 4 + 0x100) >>> 16;
        // if upcounter, cancel the IRQ and check the next timer
        if (checkBit(control, 2)) {
            cancelIRQ(i);
            cancelDependentIRQs(i + 1);
        }
    }

    private double getTimeUntilIRQ(int i, int control, int reload) {
        // the time per tick multiplied by the number of ticks until overflow
        int remainingTicks = 0x10000 - formatTickCount(getTickCount(i, control, reload), reload);
        return getTickPeriod(i, control) * remainingTicks;
    }

    private short formatTickCount(double tickCount, int reload) {
        // remove overflows if any
        if (tickCount > 0xFFFF) {
            tickCount = (tickCount - reload) % (0x10000 - reload) + reload;
        }
        // return as 16-bit
        return cast(short) tickCount;
    }

    private double getTickCount(int i, int control, int reload) {
        // convert the time into using the period ticks and add the reload value
        return getTimeDelta(i, control) / getTickPeriod(i, control) + reload;
    }

    private long getTimeDelta(int i, int control) {
        long getEndTime(int i, int control) {
            // if running, return current time, else use end time, set when it was disabled
            return checkBit(control, 7) ? TickDuration.currSystemTick().nsecs() : endTimes[i];
        }
        // upcounters are a special case because they depend on the previous timers
        if (i != 0 && checkBit(control, 2)) {
            // they only tick if all previous upcounters and the normal timer are ticking
            long maxStartTime = startTimes[i], minEndTime = getEndTime(i, control);
            // get the latest start time and earliest end time
            while (--i >= 0 && checkBit(control, 2)) {
                maxStartTime = max(maxStartTime, startTimes[i]);
                control = ioRegisters.getInt(i * 4 + 0x100) >>> 16;
                minEndTime = min(minEndTime, getEndTime(i, control));
            }
            // if the delta of the exterma is negative, it never ran
            long timeDelta = minEndTime - maxStartTime;
            return timeDelta > 0 ? timeDelta : 0;
        }
        // for normal timers, get the delta from start to end (or current if running)
        return getEndTime(i, control) - startTimes[i];
    }

    private double getTickPeriod(int i, int control) {
        // tick duration for a 16.78MHz clock
        enum double clockTickPeriod = 2.0 ^^ -24 * 1e9;
        // handle up-counting timers separately
        if (i != 0 && checkBit(control, 2)) {
            // get the previous timer's tick period
            int previousTimer = ioRegisters.getInt(i * 4 + 0xFC);
            int previousControl = previousTimer >>> 16;
            int previousReload = previousTimer & 0xFFFF;
            double previousTickPeriod = getTickPeriod(i - 1, previousControl);
            // this timer increments when the previous one overflows, so multiply by the ticks until overflow
            return previousTickPeriod * (0x10000 - previousReload);
        } else {
            // compute the pre-scaler period
            int preScaler = control & 0b11;
            if (preScaler == 0) {
                preScaler = 1;
            } else {
                preScaler = 1 << (preScaler << 1) + 4;
            }
            // compute and return the full tick period in ns
            return clockTickPeriod * preScaler;
        }
    }
}

public static class InterruptHandler {
    private ARM7TDMI processor;
    private RAM ioRegisters;
    private bool isSoftwareHalt = false, isDMAHalt = false;

    private this(IORegisters ioRegisters, ARM7TDMI processor) {
        this.processor = processor;
        this.ioRegisters = ioRegisters.getMonitored();
        ioRegisters.addMonitor(&onInterruptAcknowledgePreWrite, 0x202, 2);
        ioRegisters.addMonitor(&onHaltRequestPostWrite, 0x301, 1);
    }

    public void requestInterrupt(int source) {
        if ((ioRegisters.getInt(0x208) & 0b1) && checkBit(ioRegisters.getShort(0x200), source)) {
            int flags = ioRegisters.getShort(0x202);
            setBit(flags, source, 1);
            ioRegisters.setShort(0x202, cast(short) flags);
            processor.triggerIRQ();
            isSoftwareHalt = false;
            tryResume();
        }
    }

    private bool onInterruptAcknowledgePreWrite(Memory ioRegisters, int address, int shift, int mask, ref int value) {
        int flags = ioRegisters.getInt(0x200);
        setBits(value, 16, 31, (flags & ~value) >> 16);
        return true;
    }

    private void dmaHalt() {
        isDMAHalt = true;
        processor.halt();
    }

    private void dmaResume() {
        isDMAHalt = false;
        tryResume();
    }

    private void onHaltRequestPostWrite(Memory ioRegisters, int address, int shift, int mask, int oldValue, int newValue) {
        if (checkBit(mask, 15)) {
            if (checkBit(newValue, 15)) {
                // TODO: implement stop
            } else {
                isSoftwareHalt = true;
                processor.halt();
            }
        }
    }

    private void tryResume() {
        if (!isSoftwareHalt && !isDMAHalt) {
            processor.resume();
        }
    }

    public static enum InterruptSource {
        LCD_V_BLANK = 0,
        LCD_H_BLANK = 1,
        LCD_V_COUNTER_MATCH = 2,
        TIMER_0_OVERFLOW = 3,
        TIMER_1_OVERFLOW = 4,
        TIMER_2_OVERFLOW = 5,
        TIMER_3_OVERFLOW = 6,
        SERIAL_COMMUNICATION = 7,
        DMA_0 = 8,
        DMA_1 = 9,
        DMA_2 = 10,
        DMA_3 = 11,
        KEYPAD = 12,
        GAMEPAK = 13
    }
}

public class NullPathException : Exception {
    protected this(string type) {
        super("Path to \"" ~ type ~ "\" file is null");
    }
}

public class NoROMException : Exception {
    protected this() {
        super("No loaded gamepak ROM");
    }
}

public class NoSaveException : Exception {
    protected this() {
        super("No loaded gamepak save");
    }
}

public class EmulatorRunningException : Exception {
    protected this() {
        super("Cannot perform this action while the emulator is running");
    }
}
