module gbaid.system;

import core.time;
import core.thread;
import core.sync.condition;
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

public alias IORegisters = MonitoredMemory!RAM;
public alias SaveConfiguration = GamePak.SaveConfiguration;
public alias InterruptSource = InterruptHandler.InterruptSource;

public class GameBoyAdvance {
    private MainMemory memory;
    private ARM7TDMI processor;
    private InterruptHandler interruptHandler;
    private HaltHandler haltHandler;
    private Display display;
    private Keypad keypad;
    private Timers timers;
    private DMAs dmas;
    private bool running = false;
    private int lastBIOSPreFetch;

    public this(string biosFile) {
        if (biosFile is null) {
            throw new NullPathException("BIOS");
        }

        memory = new MainMemory(biosFile);

        IORegisters ioRegisters = memory.getIORegisters();

        processor = new ARM7TDMI(memory);
        haltHandler = new HaltHandler(processor);
        interruptHandler = new InterruptHandler(ioRegisters, processor, haltHandler);
        keypad = new Keypad(ioRegisters, interruptHandler);
        timers = new Timers(ioRegisters, interruptHandler);
        dmas = new DMAs(memory, ioRegisters, interruptHandler, haltHandler);
        display = new Display(ioRegisters, memory.getPalette(), memory.getVRAM(), memory.getOAM(), interruptHandler, dmas);

        memory.setBIOSProtection(&biosReadGuard, &biosReadFallback);
        memory.setUnusedMemoryFallBack(&unusedReadFallBack);

        processor.setEntryPointAddress(MainMemory.BIOS_START);
    }

    public void setGamePak(GamePak gamePak) {
        if (gamePak is null) {
            throw new NullGamePakException();
        }
        checkNotRunning();
        gamePak.setUnusedMemoryFallBack(&unusedReadFallBack);
        memory.setGamePak(gamePak);
    }

    public void useKeyboard() {
        keypad.changeInput!Keyboard();
    }

    public void useController() {
        keypad.changeInput!Controller();
    }

    public void setDisplayScale(float scale) {
        display.setScale(scale);
    }

    public void setDisplayFilteringMode(FilteringMode mode) {
        display.setFilteringMode(mode);
    }

    public void setDisplayUpscalingMode(UpscalingMode mode) {
        display.setUpscalingMode(mode);
    }

    public MainMemory getMemory() {
        return memory;
    }

    public void run() {
        checkNotRunning();
        try {
            if (!DerelictSDL2.isLoaded) {
                DerelictSDL2.load();
            }
            SDL_Init(0);
            keypad.start();
            timers.start();
            processor.start();
            display.run();
        } catch (Exception ex) {
            writeln("Emulator encountered an exception, system stopping...");
            writeln("Exception: ", ex.msg);
        } finally {
            processor.stop();
            timers.stop();
            keypad.stop();
            SDL_Quit();
        }
    }

    private void checkNotRunning() {
        if (running) {
            throw new EmulatorRunningException();
        }
    }

    private bool biosReadGuard(uint address) {
        if (processor.getProgramCounter() < cast(int) MainMemory.BIOS_SIZE) {
            lastBIOSPreFetch = processor.getPreFetch();
            return true;
        }
        return false;
    }

    private int biosReadFallback(uint address) {
        return lastBIOSPreFetch;
    }

    private int unusedReadFallBack(uint address) {
        return processor.getPreFetch();
    }
}

public class MainMemory : MappedMemory {
    private static enum uint BIOS_SIZE = 16 * BYTES_PER_KIB;
    private static enum uint BOARD_WRAM_SIZE = 256 * BYTES_PER_KIB;
    private static enum uint CHIP_WRAM_SIZE = 32 * BYTES_PER_KIB;
    private static enum uint IO_REGISTERS_SIZE = 1 * BYTES_PER_KIB;
    private static enum uint PALETTE_SIZE = 1 * BYTES_PER_KIB;
    private static enum uint VRAM_SIZE = 96 * BYTES_PER_KIB;
    private static enum uint OAM_SIZE = 1 * BYTES_PER_KIB;
    private static enum uint BIOS_START = 0x00000000;
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
    private RAM vram;
    private RAM oam;
    private RAM palette;
    private Memory gamePak;
    private size_t capacity;

    private this(string biosFile) {
        unusedMemory = new DelegatedROM(0);
        bios = new ProtectedROM(biosFile, BIOS_SIZE);
        boardWRAM = new RAM(BOARD_WRAM_SIZE);
        chipWRAM = new RAM(CHIP_WRAM_SIZE);
        ioRegisters = new IORegisters(new RAM(IO_REGISTERS_SIZE));
        vram = new RAM(VRAM_SIZE);
        oam = new RAM(OAM_SIZE);
        palette = new RAM(PALETTE_SIZE);
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

    private ProtectedROM getBIOS() {
        return bios;
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
        return cast(GamePak) gamePak;
    }

    private void setGamePak(GamePak gamePak) {
        this.gamePak = gamePak;
        updateCapacity();
    }

    private void setBIOSProtection(bool delegate(uint) guard, int delegate(uint) fallback) {
        bios.setGuard(guard);
        bios.setFallback(fallback);
    }

    private void setUnusedMemoryFallBack(int delegate(uint) fallback) {
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

public class GamePak : MappedMemory {
    private static enum uint MAX_ROM_SIZE = 32 * BYTES_PER_MIB;
    private static enum uint ROM_MASK = 0x1FFFFFF;
    private static enum uint SAVE_MASK = 0xFFFF;
    private static enum uint EEPROM_MASK_HIGH = 0xFFFF00;
    private static enum uint EEPROM_MASK_LOW = 0x0;
    private DelegatedROM unusedMemory;
    private ROM rom;
    private Memory save;
    private Memory eeprom;
    private uint eepromMask;
    private size_t capacity;

    private this(string romFile) {
        unusedMemory = new DelegatedROM(0);

        if (romFile is null) {
            throw new NullPathException("ROM");
        }
        loadROM(romFile);
    }

    public this(string romFile, string saveFile) {
        this(romFile);

        if (saveFile is null) {
            throw new NullPathException("save");
        }
        loadSave(saveFile);

        updateCapacity();
    }

    public this(string romFile, SaveConfiguration saveConfig) {
        this(romFile);

        final switch (saveConfig) {
            case SaveConfiguration.SRAM:
                save = new RAM(SaveMemory.SRAM[1]);
                eeprom = unusedMemory;
                break;
            case SaveConfiguration.SRAM_EEPROM:
                save = new RAM(SaveMemory.SRAM[1]);
                eeprom = new EEPROM(SaveMemory.EEPROM[1]);
                break;
            case SaveConfiguration.FLASH64K:
                save = new Flash(SaveMemory.FLASH512[1]);
                eeprom = unusedMemory;
                break;
            case SaveConfiguration.FLASH64K_EEPROM:
                save = new Flash(SaveMemory.FLASH512[1]);
                eeprom = new EEPROM(SaveMemory.EEPROM[1]);
                break;
            case SaveConfiguration.FLASH128K:
                save = new Flash(SaveMemory.FLASH1M[1]);
                eeprom = unusedMemory;
                break;
            case SaveConfiguration.FLASH128K_EEPROM:
                save = new Flash(SaveMemory.FLASH1M[1]);
                eeprom = new EEPROM(SaveMemory.EEPROM[1]);
                break;
            case SaveConfiguration.EEPROM:
                save = unusedMemory;
                eeprom = new EEPROM(SaveMemory.EEPROM[1]);
                break;
            case SaveConfiguration.AUTO:
                autoNewSave();
                break;
        }

        updateCapacity();
    }

    private void updateCapacity() {
        capacity = rom.getCapacity() + save.getCapacity() + eeprom.getCapacity();
    }

    private void loadROM(string romFile) {
        rom = new ROM(romFile, MAX_ROM_SIZE);
        eepromMask = rom.getCapacity() > 16 * BYTES_PER_MIB ? EEPROM_MASK_HIGH : EEPROM_MASK_LOW;
    }

    private void loadSave(string saveFile) {
        save = unusedMemory;
        eeprom = unusedMemory;
        Memory[] loaded = loadFromFile(saveFile);
        foreach (Memory memory; loaded) {
            if (cast(EEPROM) memory) {
                eeprom = memory;
            } else if (cast(Flash) memory || cast(RAM) memory) {
                save = memory;
            } else {
                throw new Exception("Unsupported memory save type: " ~ typeid(memory).name);
            }
        }
    }

    private void autoNewSave() {
        // Detect save types and size using ID strings in ROM
        bool hasSRAM = false, hasFlash = false, hasEEPROM = false;
        int saveSize = SaveMemory.SRAM[1], eepromSize = SaveMemory.EEPROM[1];
        char[] romChars = cast(char[]) rom.getArray(0);
        auto saveTypes = EnumMembers!SaveMemory;
        for (size_t i = 0; i < romChars.length; i += 4) {
            foreach (saveType; saveTypes) {
                string saveID = saveType[0];
                if (romChars[i .. min(i + saveID.length, romChars.length)] == saveID) {
                    final switch (saveID) with (SaveMemory) {
                        case SRAM[0]:
                            hasSRAM = true;
                            saveSize = saveType[1];
                            break;
                        case EEPROM[0]:
                            hasEEPROM = true;
                            saveSize = saveType[1];
                            break;
                        case FLASH[0]:
                        case FLASH512[0]:
                        case FLASH1M[0]:
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
            eeprom = new EEPROM(eepromSize);
        } else {
            eeprom = unusedMemory;
        }
    }

    private void setUnusedMemoryFallBack(int delegate(uint) fallback) {
        unusedMemory.setDelegate(fallback);
    }

    protected override Memory map(ref uint address) {
        int highAddress = address >>> 24;
        int lowAddress = address & 0xFFFFFF;
        switch (highAddress) {
            case 0x0: .. case 0x4:
                address &= ROM_MASK;
                if (address < rom.getCapacity()) {
                    return rom;
                } else {
                    return unusedMemory;
                }
            case 0x5:
                if (eeprom !is null && (lowAddress & eepromMask) == eepromMask) {
                    address = lowAddress & ~eepromMask;
                    return eeprom;
                }
                goto case 0x4;
            case 0x6:
                address &= SAVE_MASK;
                return save;
            default:
                return unusedMemory;
        }
    }

    public override size_t getCapacity() {
        return capacity;
    }

    public void saveSave(string saveFile) {
        if (cast(EEPROM) eeprom is null) {
            saveToFile(saveFile, save);
        } else if (cast(RAM) save is null && cast(Flash) save is null) {
            saveToFile(saveFile, eeprom);
        } else {
            saveToFile(saveFile, save, eeprom);
        }
    }

    private static enum SaveMemory : Tuple!(string, uint) {
        EEPROM = tuple("EEPROM_V", 8 * BYTES_PER_KIB),
        SRAM = tuple("SRAM_V", 64 * BYTES_PER_KIB),
        FLASH = tuple("FLASH_V", 64 * BYTES_PER_KIB),
        FLASH512 = tuple("FLASH512_V", 64 * BYTES_PER_KIB),
        FLASH1M = tuple("FLASH1M_V", 128 * BYTES_PER_KIB)
    }

    public static enum SaveConfiguration {
        SRAM,
        SRAM_EEPROM,
        FLASH64K,
        FLASH64K_EEPROM,
        FLASH128K,
        FLASH128K_EEPROM,
        EEPROM,
        AUTO
    }
}

public class DMAs {
    private MainMemory memory;
    private RAM ioRegisters;
    private InterruptHandler interruptHandler;
    private HaltHandler haltHandler;
    private bool interruptDMA = false;
    private int[4] sourceAddresses = new int[4];
    private int[4] destinationAddresses = new int[4];
    private int[4] wordCounts = new int[4];
    private int[4] controls = new int[4];
    private Timing[4] timings = new Timing[4];
    private int incomplete = 0;

    private this(MainMemory memory, IORegisters ioRegisters, InterruptHandler interruptHandler, HaltHandler haltHandler) {
        this.memory = memory;
        this.ioRegisters = ioRegisters.getMonitored();
        this.interruptHandler = interruptHandler;
        this.haltHandler = haltHandler;

        ioRegisters.addMonitor(&onPostWrite, 0xBA, 2);
        ioRegisters.addMonitor(&onPostWrite, 0xC6, 2);
        ioRegisters.addMonitor(&onPostWrite, 0xD2, 2);
        ioRegisters.addMonitor(&onPostWrite, 0xDE, 2);

        haltHandler.setHaltTask(&dmaTask);
    }

    public void signalVBLANK() {
        updateDMAs(Timing.VBLANK);
    }

    public void signalHBLANK() {
        updateDMAs(Timing.HBLANK);
    }

    private void onPostWrite(Memory ioRegisters, int address, int shift, int mask, int oldControl, int newControl) {
        if (!(mask & 0xFFFF0000)) {
            return;
        }

        int channel = (address - 0xB8) / 0xC;
        controls[channel] = newControl >>> 16;
        timings[channel] = getTiming(channel, newControl);

        if (!checkBit(oldControl, 31) && checkBit(newControl, 31)) {
            sourceAddresses[channel] = formatSourceAddress(channel, ioRegisters.getInt(address - 8));
            destinationAddresses[channel] = formatDestinationAddress(channel, ioRegisters.getInt(address - 4));
            wordCounts[channel] = getWordCount(channel, newControl);
            updateDMAs(Timing.IMMEDIATE);
        }
    }

    private void updateDMAs(Timing timing) {
        foreach (int channel; 0 .. 4) {
            if (timings[channel] == timing) {
                setBit(incomplete, channel, 1);
            }
        }
        if (!incomplete) {
            return;
        }
        haltHandler.dmaHalt(true);
        interruptDMA = true;
    }

    private bool dmaTask() {
        bool ran = cast(bool) incomplete;
        while (incomplete) {
            foreach (int channel; 0 .. 4) {
                if (checkBit(incomplete, channel)) {
                    interruptDMA = false;
                    if (!runDMA(channel)) {
                        break;
                    }
                }
            }
        }
        haltHandler.dmaHalt(false);
        return ran;
    }

    private bool runDMA(int channel) {
        int control = controls[channel];

        if (!doCopy(channel, control)) {
            return false;
        }

        int dmaAddress = channel * 0xC + 0xB8;
        if (checkBit(control, 9)) {
            wordCounts[channel] = getWordCount(channel, ioRegisters.getInt(dmaAddress));
            if (getBits(control, 5, 6) == 3) {
                destinationAddresses[channel] = formatDestinationAddress(channel, ioRegisters.getInt(dmaAddress - 4));
            }
        } else {
            ioRegisters.setShort(dmaAddress + 2, cast(short) (control & 0x7FFF));
            timings[channel] = Timing.DISABLED;
        }

        if (checkBit(control, 14)) {
            interruptHandler.requestInterrupt(InterruptSource.DMA_0 + channel);
        }

        return true;
    }

    private bool doCopy(int channel, int control) {
        int startTiming = getBits(control, 12, 13);

        int type = void;
        int destinationAddressControl = void;
        if (startTiming == 3) {
            if (channel == 1 || channel == 2) {
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
        int increment = type ? 4 : 2;

        debug (outputDMAs) writefln(
            "DMA %s %08x%s to %08x%s, %04x bytes, timing %s",
            channel,
            sourceAddresses[channel],
            sourceAddressControl == 0 ? "++" : sourceAddressControl == 1 ? "--" : "  ",
            destinationAddresses[channel],
            destinationAddressControl == 0 || destinationAddressControl == 3 ? "++" : destinationAddressControl == 1 ? "--" : "  ",
            wordCounts[channel] * increment,
            getTiming(channel, control << 16)
        );

        while (wordCounts[channel] > 0) {
            if (interruptDMA) {
                interruptDMA = false;
                return false;
            }

            if (type) {
                memory.setInt(destinationAddresses[channel], memory.getInt(sourceAddresses[channel]));
            } else {
                memory.setShort(destinationAddresses[channel], memory.getShort(sourceAddresses[channel]));
            }

            modifyAddress(sourceAddresses[channel], sourceAddressControl, increment);
            modifyAddress(destinationAddresses[channel], destinationAddressControl, increment);
            wordCounts[channel]--;
        }

        setBit(incomplete, channel, 0);

        return true;
    }

    private static void modifyAddress(ref int address, int control, int amount) {
        final switch (control) {
            case 0:
            case 3:
                address += amount;
                break;
            case 1:
                address -= amount;
                break;
            case 2:
                break;
        }
    }

    private static int formatSourceAddress(int channel, int sourceAddress) {
        if (channel == 0) {
            return sourceAddress & 0x7FFFFFF;
        }
        return sourceAddress & 0xFFFFFFF;
    }

    private static int formatDestinationAddress(int channel, int destinationAddress) {
        if (channel == 3) {
            return destinationAddress & 0xFFFFFFF;
        }
        return destinationAddress & 0x7FFFFFF;
    }

    private static int getWordCount(int channel, int fullControl) {
        if (getBits(fullControl, 28, 29) == 3) {
            if (channel == 1 || channel == 2) {
                return 0x4;
            } else if (channel == 3) {
                // TODO: implement video capture
                return 0x0;
            }
        }
        if (channel < 3) {
            fullControl &= 0x3FFF;
            if (fullControl == 0) {
                return 0x4000;
            }
            return fullControl;
        }
        fullControl &= 0xFFFF;
        if (fullControl == 0) {
            return 0x10000;
        }
        return fullControl;
    }

    private static Timing getTiming(int channel, int fullControl) {
        if (!checkBit(fullControl, 31)) {
            return Timing.DISABLED;
        }
        final switch (getBits(fullControl, 28, 29)) {
            case 0:
                return Timing.IMMEDIATE;
            case 1:
                return Timing.VBLANK;
            case 2:
                return Timing.HBLANK;
            case 3:
                final switch (channel) {
                    case 1:
                    case 2:
                        return Timing.SOUND_FIFO;
                    case 3:
                        return Timing.VIDEO_CAPTURE;
                }
        }
    }

    private static enum Timing {
        DISABLED,
        IMMEDIATE,
        VBLANK,
        HBLANK,
        SOUND_FIFO,
        VIDEO_CAPTURE
    }
}

private class Timers {
    private RAM ioRegisters;
    private InterruptHandler interruptHandler;
    private long[4] startTimes = new long[4];
    private long[4] endTimes = new long[4];
    private Scheduler scheduler;
    private int[4] irqTasks = new int[4];
    private void delegate()[4] irqHandlers;

    public this(IORegisters ioRegisters, InterruptHandler interruptHandler) {
        this.ioRegisters = ioRegisters.getMonitored();
        this.interruptHandler = interruptHandler;
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

    private void irqHandler(int i)() {
        interruptHandler.requestInterrupt(InterruptSource.TIMER_0_OVERFLOW + i);
        irqTasks[i] = 0;
        scheduleIRQ(i);
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
        double tickPeriod = getTickPeriod(i, control);
        int remainingTicks = 0x10000 - formatTickCount(getTickCount(i, control, reload), reload);
        return tickPeriod * remainingTicks;
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
        double tickPeriod = getTickPeriod(i, control);
        long timeDelta = getTimeDelta(i, control);
        return timeDelta / tickPeriod + reload;
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

public class InterruptHandler {
    private RAM ioRegisters;
    private ARM7TDMI processor;
    private HaltHandler haltHandler;

    private this(IORegisters ioRegisters, ARM7TDMI processor, HaltHandler haltHandler) {
        this.ioRegisters = ioRegisters.getMonitored();
        this.processor = processor;
        this.haltHandler = haltHandler;
        ioRegisters.addMonitor(&onInterruptAcknowledgePreWrite, 0x202, 2);
        ioRegisters.addMonitor(&onHaltRequestPostWrite, 0x301, 1);
    }

    public void requestInterrupt(int source) {
        if ((ioRegisters.getInt(0x208) & 0b1) && checkBit(ioRegisters.getShort(0x200), source)) {
            int flags = ioRegisters.getShort(0x202);
            setBit(flags, source, 1);
            ioRegisters.setShort(0x202, cast(short) flags);
            processor.irq(true);
            haltHandler.softwareHalt(false);
        }
    }

    private bool onInterruptAcknowledgePreWrite(Memory ioRegisters, int address, int shift, int mask, ref int value) {
        value = ioRegisters.getInt(0x200) & ~value | value & 0xFFFF;
        processor.irq((value & 0x3FFF0000) != 0);
        return true;
    }

    private void onHaltRequestPostWrite(Memory ioRegisters, int address, int shift, int mask, int oldValue, int newValue) {
        if (checkBit(mask, 15)) {
            if (checkBit(newValue, 15)) {
                // TODO: implement stop
            } else {
                haltHandler.softwareHalt(true);
            }
        }
    }

    public static enum InterruptSource {
        LCD_VBLANK = 0,
        LCD_HBLANK = 1,
        LCD_VCOUNTER_MATCH = 2,
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

private class HaltHandler {
    private ARM7TDMI processor;
    private bool softwareHalted = false, dmaHalted = false;

    private this(ARM7TDMI processor) {
        this.processor = processor;
    }

    private void setHaltTask(bool delegate() haltTask) {
        processor.setHaltTask(haltTask);
    }

    private void softwareHalt(bool state) {
        softwareHalted = state;
        updateState();
    }

    private void dmaHalt(bool state) {
        dmaHalted = state;
        updateState();
    }

    private void updateState() {
        processor.halt(softwareHalted || dmaHalted);
    }
}

public class NullPathException : Exception {
    protected this(string type) {
        super("Path to \"" ~ type ~ "\" file is null");
    }
}

public class NullGamePakException : Exception {
    protected this() {
        super("Game Pak is null");
    }
}

public class EmulatorRunningException : Exception {
    protected this() {
        super("Cannot perform this action while the emulator is running");
    }
}
