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
        memory.loadGamepakROM(file);
    }

    public void loadSave(string file) {
        if (file is null) {
            throw new NullPathException("save");
        }
        checkNotRunning();
        memory.loadGamepakSave(file);
    }

    public void saveSave(string file) {
        if (file is null) {
            throw new NullPathException("save");
        }
        checkNotRunning();
        memory.saveGamepakSave(file);
    }

    public void loadNewSave() {
        checkNotRunning();
        memory.loadEmptyGamepakSave();
    }

    public void setDisplayScale(float scale) {
        display.setScale(scale);
    }

    public GameBoyAdvanceMemory getMemory() {
        return memory;
    }

    public void run() {
        checkNotRunning();
        if (!memory.hasGamepakROM()) {
            throw new NoROMException();
        }
        if (!memory.hasGamepakSave()) {
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

    public class GameBoyAdvanceMemory : Memory {
        private static immutable uint BIOS_SIZE = 16 * BYTES_PER_KIB;
        private static immutable uint BOARD_WRAM_SIZE = 256 * BYTES_PER_KIB;
        private static immutable uint CHIP_WRAM_SIZE = 32 * BYTES_PER_KIB;
        private static immutable uint PALETTE_RAM_SIZE = 1 * BYTES_PER_KIB;
        private static immutable uint VRAM_SIZE = 96 * BYTES_PER_KIB;
        private static immutable uint OAM_SIZE = 1 * BYTES_PER_KIB;
        private static immutable uint MAX_GAMEPAK_ROM_SIZE = 32 * BYTES_PER_MIB;
        private static immutable uint CHIP_WRAM_MIRROR_OFFSET = 0xFF8000;
        private static immutable uint BIOS_START = 0x00000000;
        private static immutable uint BIOS_END = 0x00003FFF;
        private static immutable uint BOARD_WRAM_START = 0x02000000;
        private static immutable uint BOARD_WRAM_END = 0x0203FFFF;
        private static immutable uint CHIP_WRAM_START = 0x03000000;
        private static immutable uint CHIP_WRAM_END = 0x03007FFF;
        private static immutable uint CHIP_WRAM_MIRROR_START = 0x03FFFF00;
        private static immutable uint CHIP_WRAM_MIRROR_END = 0x03FFFFFF;
        private static immutable uint IO_REGISTERS_START = 0x04000000;
        private static immutable uint IO_REGISTERS_END = 0x040003FE;
        private static immutable uint PALETTE_RAM_START = 0x05000000;
        private static immutable uint PALETTE_RAM_END = 0x050003FF;
        private static immutable uint VRAM_START = 0x06000000;
        private static immutable uint VRAM_END = 0x06017FFF;
        private static immutable uint OAM_START = 0x07000000;
        private static immutable uint OAM_END = 0x070003FF;
        private static immutable uint GAMEPAK_ROM_START = 0x08000000;
        private static immutable uint GAMEPAK_ROM_END = 0x0DFFFFFF;
        private static immutable uint GAMEPAK_SAVE_START = 0x0E000000;
        private static immutable uint GAMEPAK_SAVE_END = 0x0E00FFFF;
        private static immutable uint GAMEPAK_EEPROM_START_NARROW = 0x0DFFFF00;
        private static immutable uint GAMEPAK_EEPROM_START_WIDE = 0x0D000000;
        private static immutable uint GAMEPAK_EEPROM_END = 0x0DFFFFFF;
        private Memory unusedMemory;
        private Memory bios;
        private Memory boardWRAM;
        private Memory chipWRAM;
        private IORegisters ioRegisters;
        private Memory vram;
        private Memory oam;
        private Memory paletteRAM;
        private Memory gamepakROM;
        private Memory gamepakSave;
        private Memory gamepakEEPROM;
        private bool hasEEPROM;
        private uint eepromStart;
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
            gamepakROM = unusedMemory;
            gamepakSave = unusedMemory;
            gamepakEEPROM = unusedMemory;
            updateCapacity();
        }

        private void start() {
            ioRegisters.start();
        }

        private void stop() {
            ioRegisters.stop();
        }

        private void loadGamepakROM(string romFile) {
            gamepakROM = new ROM(romFile, MAX_GAMEPAK_ROM_SIZE);
            eepromStart = gamepakROM.getCapacity() > 16 * BYTES_PER_MIB
                    ? GAMEPAK_EEPROM_START_NARROW
                    : GAMEPAK_EEPROM_START_WIDE;
            updateCapacity();
        }

        private void loadGamepakSave(string saveFile) {
            Memory[] save = loadFromFile(saveFile);
            foreach (Memory memory; save) {
                if (cast(EEPROM) memory) {
                    gamepakEEPROM = memory;
                    hasEEPROM = true;
                } else if (cast(Flash) memory || cast(RAM) memory) {
                    gamepakSave = memory;
                } else {
                    throw new Exception("Unsupported memory save type: " ~ typeid(memory).name);
                }
            }
            updateCapacity();
        }

        private void saveGamepakSave(string saveFile) {
            if (cast(NullMemory) gamepakEEPROM) {
                saveToFile(saveFile, gamepakSave);
            } else {
                saveToFile(saveFile, gamepakSave, gamepakEEPROM);
            }
        }

        private bool hasGamepakROM() {
            return !(cast(NullMemory) gamepakROM);
        }

        private bool hasGamepakSave() {
            return !(cast(NullMemory) gamepakSave);
        }

        private bool hasGamepakEEPROM() {
            return !(cast(NullMemory) gamepakEEPROM);
        }

        private void loadEmptyGamepakSave() {
            // Detect save types and size using ID strings in ROM
            bool hasFlash = false;
            int saveSize = GamepakSaveMemory.SRAM[1];
            char[] romChars = cast(char[]) gamepakROM.getArray(0);
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
                gamepakSave = new Flash(saveSize);
            } else {
                gamepakSave = new RAM(saveSize);
            }
            if (hasEEPROM) {
                gamepakEEPROM = new EEPROM(GamepakSaveMemory.EEPROM[1]);
            }
            // Update the capacity
            updateCapacity();
        }

        private void updateCapacity() {
            capacity = bios.getCapacity()
                + boardWRAM.getCapacity()
                + chipWRAM.getCapacity()
                + ioRegisters.getCapacity()
                + vram.getCapacity()
                + oam.getCapacity()
                + paletteRAM.getCapacity()
                + gamepakROM.getCapacity()
                + gamepakSave.getCapacity()
                + gamepakEEPROM.getCapacity();
        }

        public override ulong getCapacity() {
            return capacity;
        }

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

        private Memory map(ref uint address) {
            if (address >= BIOS_START && address <= BIOS_END) {
                address -= BIOS_START;
                return bios;
            }
            if (address >= BOARD_WRAM_START && address <= BOARD_WRAM_END) {
                address -= BOARD_WRAM_START;
                return boardWRAM;
            }
            if (address >= CHIP_WRAM_START && address <= CHIP_WRAM_END) {
                address -= CHIP_WRAM_START;
                return chipWRAM;
            }
            if (address >= CHIP_WRAM_MIRROR_START && address <= CHIP_WRAM_MIRROR_END) {
                address -= CHIP_WRAM_MIRROR_OFFSET + CHIP_WRAM_START;
                return chipWRAM;
            }
            if (address >= IO_REGISTERS_START && address <= IO_REGISTERS_END) {
                address -= IO_REGISTERS_START;
                return ioRegisters;
            }
            if (address >= PALETTE_RAM_START && address <= PALETTE_RAM_END) {
                address -= PALETTE_RAM_START;
                return paletteRAM;
            }
            if (address >= VRAM_START && address <= VRAM_END) {
                address -= VRAM_START;
                return vram;
            }
            if (address >= OAM_START && address <= OAM_END) {
                address -= OAM_START;
                return oam;
            }
            if (address >= GAMEPAK_ROM_START && address <= GAMEPAK_ROM_END) {
                if (hasEEPROM && address >= eepromStart && address <= GAMEPAK_EEPROM_END) {
                    address -= eepromStart;
                    return gamepakEEPROM;
                }
                address -= GAMEPAK_ROM_START;
                address &= (MAX_GAMEPAK_ROM_SIZE - 1);
                if (address < gamepakROM.getCapacity()) {
                    return gamepakROM;
                } else {
                    return unusedMemory;
                }
            }
            if (address >= GAMEPAK_SAVE_START && address <= GAMEPAK_SAVE_END) {
                address -= GAMEPAK_SAVE_START;
                if (address < gamepakSave.getCapacity()) {
                    return gamepakSave;
                } else {
                    return unusedMemory;
                }
            }
            return unusedMemory;
        }

        public void requestInterrupt(InterruptSource source) {
            ioRegisters.requestInterrupt(source);
        }

        public void signalEvent(SignalEvent event) {
            ioRegisters.signalEvent(event);
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
            timerIRQHandlers = [&timer0IRQ, &timer1IRQ, &timer2IRQ, &timer3IRQ];
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
            handleSpecialWrite(address, b);
            super.setByte(address, b);
        }

        public override short getShort(uint address) {
            short s = super.getShort(address);
            handleSpecialRead(address, s);
            return s;
        }

        public override void setShort(uint address, short s) {
            handleSpecialWrite(address, s);
            super.setShort(address, s);
        }

        public override int getInt(uint address) {
            int i = super.getInt(address);
            handleSpecialRead(address, i);
            return i;
        }

        public override void setInt(uint address, int i) {
            handleSpecialWrite(address, i);
            super.setInt(address, i);
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

        private void handleSpecialWrite(uint address, ref byte b) {
            int alignedAddress = address & ~3;
            int shift = ((address & 3) << 3);
            int mask = 0xFF << shift;
            int intValue = ucast(b) << shift;
            handleSpecialWrite(alignedAddress, shift, mask, intValue);
            b = cast(byte) ((intValue & mask) >> shift);
        }

        private void handleSpecialWrite(uint address, ref short s) {
            address &= ~1;
            int alignedAddress = address & ~3;
            int shift = ((address & 2) << 3);
            int mask = 0xFFFF << shift;
            int intValue = ucast(s) << shift;
            handleSpecialWrite(alignedAddress, shift, mask, intValue);
            s = cast(short) ((intValue & mask) >> shift);
        }

        private void handleSpecialWrite(uint address, ref int i) {
            address &= ~3;
            int alignedAddress = address;
            int shift = 0;
            int mask = 0xFFFFFFFF;
            int intValue = i;
            handleSpecialWrite(alignedAddress, shift, mask, intValue);
            i = intValue;
        }

        private void handleSpecialWrite(int address, int shift, int mask, ref int value) {
            switch (address) {
                case 0x000000B8:
                case 0x000000C4:
                case 0x000000D0:
                case 0x000000DC:
                    handleDMA(address, shift, mask, value);
                    break;
                case 0x00000100:
                case 0x00000104:
                case 0x00000108:
                case 0x0000010C:
                    handleTimerWrite(address, shift, mask, value);
                    break;
                case 0x00000200:
                    handleInterruptAcknowledgeWrite(address, shift, mask, value);
                    break;
                case 0x00000300:
                    handleHaltRequest(address, shift, mask, value);
                    break;
                default:
                    break;
            }
        }

        private void handleInterruptAcknowledgeWrite(int address, int shift, int mask, ref int value) {
            int flags = super.getInt(0x00000200);
            setBits(value, 16, 31, (flags & ~value) >> 16);
        }

        private void handleHaltRequest(int address, int shift, int mask, ref int value) {
            if (!checkBit(mask, 15)) {
                return;
            }
            if (checkBit(value, 15)) {
                // TODO: implement stop
            } else {
                irqHalt = true;
                processor.halt();
            }
        }

        private void handleDMA(int address, int shift, int mask, ref int value) {
            int dmaFullControl = super.getInt(address);
            if (!checkBit(value, 31) || checkBit(dmaFullControl, 31)) {
                return;
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

                int sourceAddress = dmaSourceAddresses[channel];
                int destinationAddress = dmaDestinationAddresses[channel];
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

                void modifyAddress(ref int address, int control, int amount) {
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

                int increment = type ? 4 : 2;
                GameBoyAdvanceMemory memory = this.outer.memory;

                dmaHalt = true;
                processor.halt();

                //writefln("DMA %s %08x to %08x, %x bytes, timing %s", channel, sourceAddress, destinationAddress, wordCount * increment, startTiming);

                for (int i = 0; i < wordCount; i++) {
                    if (type) {
                        memory.setInt(destinationAddress, memory.getInt(sourceAddress));
                    } else {
                        memory.setShort(destinationAddress, memory.getShort(sourceAddress));
                    }
                    modifyAddress(sourceAddress, sourceAddressControl, increment);
                    modifyAddress(destinationAddress, destinationAddressControl, increment);
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
                    short dmaControl = super.getShort(dmaAddress + 2);
                    dmaControl &= 0x7FFF;
                    super.setShort(dmaAddress + 2, dmaControl);
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

        private void handleTimerWrite(int address, int shift, int mask, ref int value) {
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
            // get the timer including the current write
            int timer = previousTimer & ~mask | value & mask;
            // ignore IRQs in disabled timers
            if (!checkBit(timer, 23)) {
                return;
            }
            // TODO: if this is an upcounter, we need to check if the previous timer is running too
            // get the control and reload
            int control = timer >>> 16;
            int reload = timer & 0xFFFF;
            // check using the previous control value for a change in the IRQ bit
            if (checkBit(timer, 22)) {
                // (re)schedule the IRQ
                scheduleTimerIRQ(i, control, reload);
            } else {
                // cancel the IRQ
                cancelTimerIRQ(i);
            }
        }

        private void timer0IRQ() {
            timerIRQ(0);
        }

        private void timer1IRQ() {
            timerIRQ(1);
        }

        private void timer2IRQ() {
            timerIRQ(2);
        }

        private void timer3IRQ() {
            timerIRQ(3);
        }

        private void timerIRQ(int i) {
            requestInterrupt(InterruptSource.TIMER_0_OVERFLOW + i);
            timerIRQTasks[i] = 0;
            scheduleTimerIRQ(i);
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

        private double getTimeUntilIRQ(int i, int control, int reload) {
            // the time per tick multiplied by the number of ticks until overflow
            int remainingTicks = 0x10000 - formatTickCount(getTickCount(i, control, reload), reload);
            return getTickPeriod(i, control, reload) * remainingTicks;
        }

        private short formatTickCount(double tickCount, int reload) {
            // remove overflows if any
            if (tickCount > 0xFFFF) {
                tickCount = (tickCount - reload) % 0x10000 + reload;
            }
            // return as 16-bit
            return cast(short) tickCount;
        }

        private double getTickCount(int i, int control, int reload) {
            // get the delta from start to end (or current if running)
            long timeDelta = void;
            if (checkBit(control, 7)) {
                timeDelta = (TickDuration.currSystemTick().nsecs() - timerStartTimes[i]);
            } else {
                timeDelta = (timerEndTimes[i] - timerStartTimes[i]);
            }
            // then convert the time into using the period ticks and add the reload value
            return (timeDelta / getTickPeriod(i, control, reload)) + reload;
        }

        private double getTickPeriod(int i, int control, int reload) {
            // tick duration for a 16.78MHz clock
            enum double clockTickPeriod = 2.0 ^^ -24 * 1e9;
            // handle up-counting timers separately
            if (i != 0 && checkBit(control, 2)) {
                // get the previous timer's tick period
                int previousTimer = super.getInt(i * 4 + 0xFC);
                int previousControl = previousTimer >>> 16;
                int previousReload = previousTimer & 0xFFFF;
                double previousTickPeriod = getTickPeriod(i - 1, previousControl, previousReload);
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
