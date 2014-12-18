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

public class GameBoyAdvance {
    private ARM7TDMI processor;
    private GameBoyAdvanceDisplay display;
    private GameBoyAdvanceMemory memory;
    private GameBoyAdvanceKeypad keypad;
    private bool running = false;

    public this(string biosFile) {
        if (biosFile is null) {
            throw new NullPathException("BIOS");
        }
        processor = new ARM7TDMI();
        display = new GameBoyAdvanceDisplay();
        memory = new GameBoyAdvanceMemory(biosFile);
        keypad = new GameBoyAdvanceKeypad();
        processor.setMemory(memory);
        processor.setEntryPointAddress(GameBoyAdvanceMemory.BIOS_START);
        display.setMemory(memory);
        keypad.setMemory(memory);
    }

    public void loadROM(string file) {
        if (file is null) {
            throw new NullPathException("ROM");
        }
        checkNotRunning();
        memory.getGamepak().loadROM(file);
    }

    public void loadSave(string file) {
        if (file is null) {
            throw new NullPathException("save");
        }
        checkNotRunning();
        memory.getGamepak().loadSave(file);
    }

    public void saveSave(string file) {
        if (file is null) {
            throw new NullPathException("save");
        }
        checkNotRunning();
        memory.getGamepak().saveSave(file);
    }

    public void loadNewSave() {
        checkNotRunning();
        memory.getGamepak().loadEmptySave();
    }

    public void setDisplayScale(float scale) {
        display.setScale(scale);
    }

    public void setDisplayUpscalingMode(UpscalingMode mode) {
        display.setUpscalingMode(mode);
    }

    public GameBoyAdvanceMemory getMemory() {
        return memory;
    }

    public void run() {
        checkNotRunning();
        if (!memory.getGamepak().hasROM()) {
            throw new NoROMException();
        }
        if (!memory.getGamepak().hasSave()) {
            throw new NoSaveException();
        }
        if (!DerelictSDL2.isLoaded) {
            DerelictSDL2.load();
        }
        SDL_Init(0);
        memory.start();
        keypad.start();
        processor.start();
        display.run();
        processor.stop();
        keypad.stop();
        memory.stop();
        SDL_Quit();
    }

    private void checkNotRunning() {
        if (running) {
            throw new EmulatorRunningException();
        }
    }

    public class GameBoyAdvanceMemory : MappedMemory {
        private static immutable uint BIOS_SIZE = 16 * BYTES_PER_KIB;
        private static immutable uint BOARD_WRAM_SIZE = 256 * BYTES_PER_KIB;
        private static immutable uint CHIP_WRAM_SIZE = 32 * BYTES_PER_KIB;
        private static immutable uint PALETTE_RAM_SIZE = 1 * BYTES_PER_KIB;
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
        private static immutable uint PALETTE_RAM_MASK = 0x3FF;
        private static immutable uint VRAM_END = 0x06017FFF;
        private static immutable uint VRAM_MASK = 0x1FFFF;
        private static immutable uint OAM_MASK = 0x3FF;
        private static immutable uint GAMEPAK_START = 0x08000000;
        private Memory unusedMemory;
        private Memory bios;
        private Memory boardWRAM;
        private Memory chipWRAM;
        private IORegisters ioRegisters;
        private Memory vram;
        private Memory oam;
        private Memory paletteRAM;
        private Gamepak gamepak;
        private ulong capacity;

        private this(string biosFile) {
            unusedMemory = new NullMemory();
            bios = new ROM(biosFile, BIOS_SIZE);
            boardWRAM = new RAM(BOARD_WRAM_SIZE);
            chipWRAM = new RAM(CHIP_WRAM_SIZE);
            ioRegisters = new IORegisters();
            vram = new RAM(VRAM_SIZE);
            oam = new RAM(OAM_SIZE);
            paletteRAM = new RAM(PALETTE_RAM_SIZE);
            gamepak = new Gamepak();
            updateCapacity();
        }

        private void start() {
            ioRegisters.start();
        }

        private void stop() {
            ioRegisters.stop();
        }

        private void updateCapacity() {
            capacity = bios.getCapacity()
                + boardWRAM.getCapacity()
                + chipWRAM.getCapacity()
                + ioRegisters.getCapacity()
                + vram.getCapacity()
                + oam.getCapacity()
                + paletteRAM.getCapacity()
                + gamepak.getCapacity();
        }

        private Gamepak getGamepak() {
            return gamepak;
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
                    if (lowAddress & ~PALETTE_RAM_MASK) {
                        return unusedMemory;
                    }
                    address &= PALETTE_RAM_MASK;
                    return paletteRAM;
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
                    address -= GAMEPAK_START;
                    return gamepak;
                default:
                    return unusedMemory;
            }
        }

        public override ulong getCapacity() {
            return capacity;
        }

        public void requestInterrupt(InterruptSource source) {
            ioRegisters.requestInterrupt(source);
        }

        public void signalEvent(SignalEvent event) {
            ioRegisters.signalEvent(event);
        }
    }

    private class Gamepak : MappedMemory {
        private static immutable uint MAX_ROM_SIZE = 32 * BYTES_PER_MIB;
        private static immutable uint ROM_START = 0x00000000;
        private static immutable uint ROM_END = 0x05FFFFFF;
        private static immutable uint SAVE_START = 0x06000000;
        private static immutable uint SAVE_END = 0x0600FFFF;
        private static immutable uint EEPROM_START_NARROW = 0x05FFFF00;
        private static immutable uint EEPROM_START_WIDE = 0x05000000;
        private static immutable uint EEPROM_END = 0x05FFFFFF;
        private Memory unusedMemory;
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
            int saveSize = GamepakSaveMemory.SRAM[1];
            char[] romChars = cast(char[]) rom.getArray(0);
            auto saveTypes = EnumMembers!GamepakSaveMemory;
            for (ulong i = 0; i < romChars.length; i += 4) {
                foreach (saveType; saveTypes) {
                    string saveID = saveType[0];
                    if (romChars[i .. min(i + saveID.length, romChars.length)] == saveID) {
                        final switch (saveID) {
                            case GamepakSaveMemory.EEPROM[0]:
                                hasEEPROM = true;
                                break;
                            case GamepakSaveMemory.FLASH[0]:
                            case GamepakSaveMemory.FLASH512[0]:
                            case GamepakSaveMemory.FLASH1M[0]:
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
                eeprom = new EEPROM(GamepakSaveMemory.EEPROM[1]);
            }
            // Update the capacity
            updateCapacity();
        }

        public override ulong getCapacity() {
            return capacity;
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

        private static enum GamepakSaveMemory {
            EEPROM = tuple("EEPROM_V", 8 * BYTES_PER_KIB),
            SRAM = tuple("SRAM_V", 64 * BYTES_PER_KIB),
            FLASH = tuple("FLASH_V", 64 * BYTES_PER_KIB),
            FLASH512 = tuple("FLASH512_V", 64 * BYTES_PER_KIB),
            FLASH1M = tuple("FLASH1M_V", 128 * BYTES_PER_KIB)
        }
    }

    private class IORegisters : RAM {
        private static immutable uint IO_REGISTERS_SIZE = 1 * BYTES_PER_KIB;
        private shared bool irqHalt = false;
        private Thread dmaThread;
        private shared bool dmaRunning = false;
        private Semaphore dmaSemaphore;
        private shared int dmaSignals = 0;
        private shared bool dmaHalt = false;
        private shared int[4] dmaSourceAddresses = new int[4];
        private shared int[4] dmaDestinationAddresses = new int[4];
        private shared int[4] dmaWordCounts = new int[4];
        private shared long[4] timerStartTimes = new long[4];
        private shared long[4] timerEndTimes = new long[4];
        private Scheduler timerScheduler;
        private shared int[4] timerIRQTasks = new int[4];
        private shared void delegate()[4] timerIRQHandlers;

        private this() {
            super(IO_REGISTERS_SIZE);
            dmaSemaphore = new Semaphore();
            timerScheduler = new Scheduler();
            timerIRQHandlers = [&timerIRQ!0, &timerIRQ!1, &timerIRQ!2, &timerIRQ!3];
        }

        private void start() {
            dmaThread = new Thread(&runDMA);
            dmaThread.name = "DMA";
            dmaRunning = true;
            dmaThread.start();
            timerScheduler.start();
        }

        private void stop() {
            if (dmaRunning) {
                dmaRunning = false;
                dmaSemaphore.notify();
            }
            timerScheduler.shutdown();
        }

        public override byte getByte(uint address) {
            byte b = super.getByte(address);
            handleSpecialRead(address, b);
            return b;
        }

        public override void setByte(uint address, byte b) {
            if (handleSpecialWrite(address, b)) {
                super.setByte(address, b);
            }
        }

        public override short getShort(uint address) {
            short s = super.getShort(address);
            handleSpecialRead(address, s);
            return s;
        }

        public override void setShort(uint address, short s) {
            if (handleSpecialWrite(address, s)) {
                super.setShort(address, s);
            }
        }

        public override int getInt(uint address) {
            int i = super.getInt(address);
            handleSpecialRead(address, i);
            return i;
        }

        public override void setInt(uint address, int i) {
            if (handleSpecialWrite(address, i)) {
                super.setInt(address, i);
            }
        }

        private void handleSpecialRead(uint address, ref byte b) {
            int alignedAddress = address & ~3;
            int shift = ((address & 3) << 3);
            int mask = 0xFF << shift;
            int intValue = ucast(b) << shift;
            handleSpecialRead(alignedAddress, shift, mask, intValue);
            b = cast(byte) ((intValue & mask) >> shift);
        }

        private void handleSpecialRead(uint address, ref short s) {
            address &= ~1;
            int alignedAddress = address & ~3;
            int shift = ((address & 2) << 3);
            int mask = 0xFFFF << shift;
            int intValue = ucast(s) << shift;
            handleSpecialRead(alignedAddress, shift, mask, intValue);
            s = cast(short) ((intValue & mask) >> shift);
        }

        private void handleSpecialRead(uint address, ref int i) {
            address &= ~3;
            int alignedAddress = address;
            int shift = 0;
            int mask = 0xFFFFFFFF;
            int intValue = i;
            handleSpecialRead(alignedAddress, shift, mask, intValue);
            i = intValue;
        }

        private void handleSpecialRead(int address, int shift, int mask, ref int value) {
            switch (address) {
                case 0x00000100:
                case 0x00000104:
                case 0x00000108:
                case 0x0000010C:
                    handleTimerRead(address, shift, mask, value);
                    break;
                default:
                    break;
            }
        }

        private bool handleSpecialWrite(uint address, ref byte b) {
            int alignedAddress = address & ~3;
            int shift = ((address & 3) << 3);
            int mask = 0xFF << shift;
            int intValue = ucast(b) << shift;
            bool write = handleSpecialWrite(alignedAddress, shift, mask, intValue);
            b = cast(byte) ((intValue & mask) >> shift);
            return write;
        }

        private bool handleSpecialWrite(uint address, ref short s) {
            address &= ~1;
            int alignedAddress = address & ~3;
            int shift = ((address & 2) << 3);
            int mask = 0xFFFF << shift;
            int intValue = ucast(s) << shift;
            bool write = handleSpecialWrite(alignedAddress, shift, mask, intValue);
            s = cast(short) ((intValue & mask) >> shift);
            return write;
        }

        private bool handleSpecialWrite(uint address, ref int i) {
            address &= ~3;
            int alignedAddress = address;
            int shift = 0;
            int mask = 0xFFFFFFFF;
            int intValue = i;
            bool write = handleSpecialWrite(alignedAddress, shift, mask, intValue);
            i = intValue;
            return write;
        }

        private bool handleSpecialWrite(int address, int shift, int mask, ref int value) {
            switch (address) {
                case 0x00000028:
                case 0x0000002C:
                case 0x00000038:
                case 0x0000003C:
                    return handleAffineReferencePointWrite(address, shift, mask, value);
                case 0x000000B8:
                case 0x000000C4:
                case 0x000000D0:
                case 0x000000DC:
                    return handleDMAWrite(address, shift, mask, value);
                case 0x00000100:
                case 0x00000104:
                case 0x00000108:
                case 0x0000010C:
                    return handleTimerWrite(address, shift, mask, value);
                case 0x00000200:
                    return handleInterruptAcknowledgeWrite(address, shift, mask, value);
                case 0x00000300:
                    return handleHaltRequestWrite(address, shift, mask, value);
                default:
                    return true;
            }
        }

        private bool handleAffineReferencePointWrite(int address, int shift, int mask, ref int value) {
            super.setInt(address, super.getInt(address) & ~mask | value & mask);
            display.reloadInternalAffineReferencePoint(address >> 4);
            return false;
        }

        private bool handleInterruptAcknowledgeWrite(int address, int shift, int mask, ref int value) {
            int flags = super.getInt(0x00000200);
            setBits(value, 16, 31, (flags & ~value) >> 16);
            return true;
        }

        private bool handleHaltRequestWrite(int address, int shift, int mask, ref int value) {
            if (!checkBit(mask, 15)) {
                return true;
            }
            if (checkBit(value, 15)) {
                // TODO: implement stop
            } else {
                irqHalt = true;
                processor.halt();
            }
            return true;
        }

        private bool handleDMAWrite(int address, int shift, int mask, ref int value) {
            int dmaFullControl = super.getInt(address);
            if (!checkBit(value, 31) || checkBit(dmaFullControl, 31)) {
                return true;
            }

            dmaFullControl = dmaFullControl & ~mask | value & mask;

            int channel = (address - 0xB8) / 0xC;
            dmaSourceAddresses[channel] = formatDMASourceAddress(super.getInt(address - 8), channel);
            dmaDestinationAddresses[channel] = formatDMADestinationAddress(super.getInt(address - 4), channel);
            dmaWordCounts[channel] = formatDMAWordCount(dmaFullControl, channel);

            super.setInt(address, dmaFullControl);

            atomicOp!"|="(dmaSignals, 0b1);
            dmaHalt = true;
            processor.halt();
            dmaSemaphore.notify();

            return false;
        }

        private void runDMA() {
            void tryDMA(int channel, int source) {
                int dmaAddress = channel * 0xC + 0xB8;

                int control = super.getShort(dmaAddress + 2);
                if (!checkBit(control, 15)) {
                    dmaHalt = false;
                    tryResume();
                    return;
                }

                int startTiming = getBits(control, 12, 13);
                if (startTiming != source) {
                    dmaHalt = false;
                    tryResume();
                    return;
                }

                int wordCount = dmaWordCounts[channel];
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

                void modifyAddress(ref shared int address, int control, int amount) {
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

                int increment = type ? 4 : 2;
                GameBoyAdvanceMemory memory = this.outer.memory;

                dmaHalt = true;
                processor.halt();

                //writefln("DMA %s %08x to %08x, %x bytes, timing %s", channel, dmaSourceAddresses[channel], dmaDestinationAddresses[channel], wordCount * increment, startTiming);

                for (int i = 0; i < wordCount; i++) {
                    if (type) {
                        memory.setInt(dmaDestinationAddresses[channel], memory.getInt(dmaSourceAddresses[channel]));
                    } else {
                        memory.setShort(dmaDestinationAddresses[channel], memory.getShort(dmaSourceAddresses[channel]));
                    }
                    modifyAddress(dmaSourceAddresses[channel], sourceAddressControl, increment);
                    modifyAddress(dmaDestinationAddresses[channel], destinationAddressControl, increment);
                }

                if (endIRQ) {
                    requestInterrupt(InterruptSource.DMA_0 + channel);
                }

                dmaHalt = false;
                tryResume();

                if (repeat) {
                    dmaWordCounts[channel] = formatDMAWordCount(super.getInt(dmaAddress), channel);
                    if (destinationAddressControl == 3) {
                        dmaDestinationAddresses[channel] = formatDMADestinationAddress(super.getInt(dmaAddress - 4), channel);
                    }
                    atomicOp!"|="(dmaSignals, 0b1);
                } else {
                    int oldDMAControl = void, newDMAControl = void;
                    do {
                        oldDMAControl = super.getInt(dmaAddress);
                        newDMAControl &= 0x7FFFFFFF;
                    } while (!super.compareAndSet(dmaAddress, oldDMAControl, newDMAControl));
                }
            }

            while (true) {
                dmaSemaphore.wait();
                if (!dmaRunning) {
                    return;
                }
                while (atomicLoad(dmaSignals) != 0) {
                    for (int s = 0; s < 4; s++) {
                        if (checkBit(atomicLoad(dmaSignals), s)) {
                            atomicOp!"&="(dmaSignals, ~(1 << s));
                            for (int c = 0; c < 4; c++) {
                                tryDMA(c, s);
                            }
                        }
                    }
                }
            }
        }

        private int formatDMASourceAddress(int sourceAddress, int channel) {
            if (channel == 0) {
                return sourceAddress & 0x7FFFFFF;
            }
            return sourceAddress & 0xFFFFFFF;
        }

        private int formatDMADestinationAddress(int destinationAddress, int channel) {
            if (channel == 3) {
                return destinationAddress & 0xFFFFFFF;
            }
            return destinationAddress & 0x7FFFFFF;
        }

        private int formatDMAWordCount(int wordCount, int channel) {
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

        private void handleTimerRead(int address, int shift, int mask, ref int value) {
            // ignore reads that aren't on the counter
            if (!(mask & 0xFFFF)) {
                return;
            }
            // fetch the timer number and information
            int i = (address - 0x100) / 4;
            int timer = super.getInt(address);
            int control = timer >>> 16;
            int reload = timer & 0xFFFF;
            // convert the full tick count to the 16 bit format used by the GBA
            short counter = formatTickCount(getTickCount(i, control, reload), reload);
            // write the counter to the value
            value = value & ~mask | counter & mask;
        }

        private bool handleTimerWrite(int address, int shift, int mask, ref int value) {
            // get the timer number and previous value
            int i = (address - 0x100) / 4;
            int previousTimer = super.getInt(address);
            // check writes to the control byte for enable changes
            if (mask & 0xFF0000) {
                // check using the previous control value for a change in the enable bit
                if (!checkBit(previousTimer, 23)) {
                    if (checkBit(value, 23)) {
                        // 0 to 1, reset the start time
                        timerStartTimes[i] = TickDuration.currSystemTick().nsecs();
                    }
                } else if (!checkBit(value, 23)) {
                    // 1 to 0, set the end time
                    timerEndTimes[i] = TickDuration.currSystemTick().nsecs();
                }
            }
            // get the full timer including the current write
            int timer = previousTimer & ~mask | value & mask;
            // get the control and reload
            int control = timer >>> 16;
            int reload = timer & 0xFFFF;
            // update the IRQs
            if (isTimerRunning(i, control)) {
                // check for IRQ enable if the time is running
                if (checkBit(control, 6)) {
                    // (re)schedule the IRQ
                    scheduleTimerIRQ(i, control, reload);
                } else {
                    // cancel the IRQ
                    cancelTimerIRQ(i);
                }
            } else {
                // cancel the IRQs and any dependent ones (upcounters)
                cancelTimerIRQ(i);
                cancelDependentTimerIRQs(i + 1);
            }
            return true;
        }

        private bool isTimerRunning(int i, int control) {
            // check if timer is an upcounter
            if (i != 0 && checkBit(control, 2)) {
                // upcounters must also also have the previous timer running
                int previousControl = super.getInt(i * 4 + 0xFC) >>> 16;
                return checkBit(control, 7) && isTimerRunning(i - 1, previousControl);
            } else {
                // regular timers must just be running
                return checkBit(control, 7);
            }
        }

        private template timerIRQ(int i) {
            private void timerIRQ() {
                requestInterrupt(InterruptSource.TIMER_0_OVERFLOW + i);
                timerIRQTasks[i] = 0;
                scheduleTimerIRQ(i);
            }
        }

        private void scheduleTimerIRQ(int i) {
            int timer = super.getInt(i * 4 + 0x100);
            int control = timer >>> 16;
            int reload = timer & 0xFFFF;
            scheduleTimerIRQ(i, control, reload);
        }

        private void scheduleTimerIRQ(int i, int control, int reload) {
            cancelTimerIRQ(i);
            long nextIRQ = cast(long) getTimeUntilIRQ(i, control, reload) + TickDuration.currSystemTick().nsecs();
            timerIRQTasks[i] = timerScheduler.schedule(nextIRQ, timerIRQHandlers[i]);
        }

        private void cancelTimerIRQ(int i) {
            if (timerIRQTasks[i] > 0) {
                timerScheduler.cancel(timerIRQTasks[i]);
                timerIRQTasks[i] = 0;
            }
        }

        private void cancelDependentTimerIRQs(int i) {
            if (i > 3) {
                // prevent infinite recursion
                return;
            }
            int control = super.getInt(i * 4 + 0x100) >>> 16;
            // if upcounter, cancel the IRQ and check the next timer
            if (checkBit(control, 2)) {
                cancelTimerIRQ(i);
                cancelDependentTimerIRQs(i + 1);
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
                return checkBit(control, 7) ? TickDuration.currSystemTick().nsecs() : timerEndTimes[i];
            }
            // upcounters are a special case because they depend on the previous timers
            if (i != 0 && checkBit(control, 2)) {
                // they only tick if all previous upcounters and the normal timer are ticking
                long maxStartTime = timerStartTimes[i], minEndTime = getEndTime(i, control);
                // get the latest start time and earliest end time
                while (--i >= 0 && checkBit(control, 2)) {
                    maxStartTime = max(maxStartTime, timerStartTimes[i]);
                    control = super.getInt(i * 4 + 0x100) >>> 16;
                    minEndTime = min(minEndTime, getEndTime(i, control));
                }
                // if the delta of the exterma is negative, it never ran
                long timeDelta = minEndTime - maxStartTime;
                return timeDelta > 0 ? timeDelta : 0;
            }
            // for normal timers, get the delta from start to end (or current if running)
            return getEndTime(i, control) - timerStartTimes[i];
        }

        private double getTickPeriod(int i, int control) {
            // tick duration for a 16.78MHz clock
            enum double clockTickPeriod = 2.0 ^^ -24 * 1e9;
            // handle up-counting timers separately
            if (i != 0 && checkBit(control, 2)) {
                // get the previous timer's tick period
                int previousTimer = super.getInt(i * 4 + 0xFC);
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

        private void requestInterrupt(int source) {
            if (super.getInt(0x00000208) && checkBit(super.getShort(0x00000200), source)) {
                int flags = super.getShort(0x00000202);
                setBit(flags, source, 1);
                super.setShort(0x00000202, cast(short) flags);
                processor.triggerIRQ();
                irqHalt = false;
                tryResume();
            }
        }

        private void signalEvent(int event) {
            final switch (event) {
                case SignalEvent.V_BLANK:
                    atomicOp!"|="(dmaSignals, 0b10);
                    dmaSemaphore.notify();
                    break;
                case SignalEvent.H_BLANK:
                    atomicOp!"|="(dmaSignals, 0b100);
                    dmaSemaphore.notify();
                    break;
            }
        }

        private void tryResume() {
            if (!irqHalt && !dmaHalt) {
                processor.resume();
            }
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

    public static enum SignalEvent {
        V_BLANK = 0,
        H_BLANK = 1
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
