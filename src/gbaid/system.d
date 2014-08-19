module gbaid.system;

import core.thread;
import core.sync.semaphore;

import std.stdio;
import std.string;

import gbaid.arm;
import gbaid.graphics;
import gbaid.memory;
import gbaid.util;

public class GameBoyAdvance {
    private ARM7TDMI processor;
    private GameBoyAdvanceDisplay display;
    private GameBoyAdvanceMemory memory;
    private bool running = false;

    public this(string biosFile) {
        if (biosFile is null) {
            throw new NullPathException("BIOS");
        }
        processor = new ARM7TDMI();
        display = new GameBoyAdvanceDisplay();
        memory = new GameBoyAdvanceMemory(biosFile);
        processor.setMemory(memory);
        processor.setEntryPointAddress(GameBoyAdvanceMemory.BIOS_START);
        display.setMemory(memory);
    }

    public void loadROM(string file) {
        if (file is null) {
            throw new NullPathException("ROM");
        }
        checkNotRunning();
        memory.loadGamepakROM(file);
    }

    public void loadSRAM(string file) {
        if (file is null) {
            throw new NullPathException("SRAM");
        }
        checkNotRunning();
        memory.loadGamepakSRAM(file);
    }

    public GameBoyAdvanceMemory getMemory() {
        return memory;
    }

    public void start() {
        checkNotRunning();
        if (!memory.hasGamepakROM()) {
            throw new NoROMException();
        }
        if (!memory.hasGamepakSRAM()) {
            memory.loadEmptyGamepakSRAM();
        }
        processor.start();
        display.run();
        processor.stop();
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
        private static immutable uint IO_REGISTERS_SIZE = 1 * BYTES_PER_KIB;
        private static immutable uint PALETTE_RAM_SIZE = 1 * BYTES_PER_KIB;
        private static immutable uint VRAM_SIZE = 96 * BYTES_PER_KIB;
        private static immutable uint OAM_SIZE = 1 * BYTES_PER_KIB;
        private static immutable uint MAX_GAMEPAK_ROM_SIZE = 32 * BYTES_PER_MIB;
        private static immutable uint MAX_GAMEPAK_SRAM_SIZE = 64 * BYTES_PER_KIB;
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
        private static immutable uint GAMEPAK_SRAM_START = 0x0E000000;
        private static immutable uint GAMEPAK_SRAM_END = 0x0E00FFFF;
        private Memory bios;
        private Memory boardWRAM = new RAM(BOARD_WRAM_SIZE);
        private Memory chipWRAM = new RAM(CHIP_WRAM_SIZE);
        private IORegisters ioRegisters;
        private Memory vram = new RAM(VRAM_SIZE);
        private Memory oam = new RAM(OAM_SIZE);
        private Memory paletteRAM = new RAM(PALETTE_RAM_SIZE);
        private Memory gamepakROM;
        private Memory gamepackSRAM;
        private Memory unusedMemory = new UnusedMemory();
        private ulong capacity;

        private this(string biosFile) {
            bios = new ROM(biosFile, BIOS_SIZE);
            ioRegisters = new IORegisters();
            updateCapacity();
        }

        private void loadGamepakROM(string romFile) {
            gamepakROM = new ROM(romFile, MAX_GAMEPAK_ROM_SIZE);
            updateCapacity();
        }

        private void loadGamepakSRAM(string sramFile) {
            gamepackSRAM = new RAM(sramFile, MAX_GAMEPAK_SRAM_SIZE);
            updateCapacity();
        }

        private bool hasGamepakROM() {
            return gamepakROM !is null;
        }

        private bool hasGamepakSRAM() {
            return gamepackSRAM !is null;
        }

        private void loadEmptyGamepakSRAM() {
            gamepackSRAM = new RAM(MAX_GAMEPAK_SRAM_SIZE);
        }

        private void updateCapacity() {
            capacity = bios.getCapacity() + boardWRAM.getCapacity() + chipWRAM.getCapacity() + oam.getCapacity()
                + paletteRAM.getCapacity()
                + (gamepakROM !is null ? gamepakROM.getCapacity() : 0)
                + (gamepackSRAM !is null ? gamepackSRAM.getCapacity() : 0);
        }

        public ulong getCapacity() {
            return capacity;
        }

        public byte getByte(uint address) {
            Memory memory = map(address);
            return memory.getByte(address);
        }

        public void setByte(uint address, byte b) {
            Memory memory = map(address);
            memory.setByte(address, b);
        }

        public short getShort(uint address) {
            Memory memory = map(address);
            return memory.getShort(address);
        }

        public void setShort(uint address, short s) {
            Memory memory = map(address);
            memory.setShort(address, s);
        }

        public int getInt(uint address) {
            Memory memory = map(address);
            return memory.getInt(address);
        }

        public void setInt(uint address, int i) {
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
                address -= GAMEPAK_ROM_START;
                address %= MAX_GAMEPAK_ROM_SIZE;
                if (address < gamepakROM.getCapacity()) {
                    return gamepakROM;
                } else {
                    return unusedMemory;
                }
            }
            if (address >= GAMEPAK_SRAM_START && address <= GAMEPAK_SRAM_END) {
                address -= GAMEPAK_SRAM_START;
                if (address < gamepackSRAM.getCapacity()) {
                    return gamepackSRAM;
                } else {
                    return unusedMemory;
                }
            }
            return unusedMemory;
        }

        public void requestInterrupt(InterruptSource source) {
            ioRegisters.requestInterrupt(source);
        }

        private static class UnusedMemory : Memory {
            public override ulong getCapacity() {
                return 0;
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

        private class IORegisters : RAM {
            private static immutable uint INTERRUPT_ENABLE_REGISTER = 0x00000200;
            private static immutable uint INTERRUPT_REQUEST_FLAGS = 0x00000202;
            private static immutable uint INTERRUPT_MASTER_ENABLE_REGISTER = 0x00000208;
            private Thread dmaThread;
            private shared bool dmaRunning = false;
            private Semaphore dmaSemaphore;
            private shared int dmaSignals = 0;

            private this() {
                super(IO_REGISTERS_SIZE);
                dmaSemaphore = new Semaphore(0);
                dmaThread = new Thread(&runDMA);
                dmaThread.isDaemon(true);
                dmaRunning = true;
                dmaThread.start();
            }

            public override byte getByte(uint address) {
                return super.getByte(address);
            }

            public override void setByte(uint address, byte b) {
                if (!handleSpecialWrite(address, ucast(b))) {
                    super.setByte(address, b);
                }
            }

            public override short getShort(uint address) {
                return super.getShort(address);
            }

            public override void setShort(uint address, short s) {
                if (!handleSpecialWrite(address, ucast(s))) {
                    super.setShort(address, s);
                }
            }

            public override int getInt(uint address) {
                return super.getInt(address);
            }

            public override void setInt(uint address, int i) {
                if (!handleSpecialWrite(address, i)) {
                    super.setInt(address, i);
                }
            }

            private void requestInterrupt(int source) {
                if (super.getInt(INTERRUPT_MASTER_ENABLE_REGISTER) && checkBit(super.getShort(INTERRUPT_ENABLE_REGISTER), source)) {
                    int flags = super.getShort(INTERRUPT_REQUEST_FLAGS);
                    setBit(flags, source, 1);
                    super.setShort(INTERRUPT_REQUEST_FLAGS, cast(short) flags);
                    processor.triggerIRQ();
                    if (processor.isHalted()) {
                        processor.resume();
                    }
                }
            }

            private bool handleSpecialWrite(uint address, int i) {
                switch (address) {
                    case 0x00000202:
                        handleInterruptAcknowledgeWrite(i);
                        return true;
                    case 0x00000301:
                        handleHaltRequest();
                        return true;
                    case 0x000000BA:
                    case 0x000000C6:
                    case 0x000000D2:
                    case 0x000000DE:
                        handleDMA(address, i);
                        return true;
                    default:
                        return false;
                }
            }

            private void handleInterruptAcknowledgeWrite(int i) {
                int flags = super.getShort(INTERRUPT_REQUEST_FLAGS);
                flags &= ~i;
                super.setShort(INTERRUPT_REQUEST_FLAGS, cast(short) flags);
            }

            private void handleHaltRequest() {
                processor.halt();
            }

            private void handleDMA(int address, int control) {
                super.setShort(address, cast(short) control);
                if (!checkBit(control, 15)) {
                    return;
                }
                dmaSignals |= 0b1;
                dmaSemaphore.notify();
            }

            private void runDMA() {
                void tryDMA(int channel, int source) {
                    int dmaAddress = channel * 12 + 0xB0;

                    int control = super.getShort(dmaAddress + 10);
                    if (!checkBit(control, 15)) {
                        return;
                    }

                    int startTiming = getBits(control, 12, 13);writefln("DMA %s %s %s", channel, source, startTiming);
                    if (startTiming != source) {
                        return;
                    }

                    int sourceAddress = super.getInt(dmaAddress);
                    int destinationAddress = super.getInt(dmaAddress + 4);

                    int wordCount = void;
                    int type = void;
                    int destinationAddressControl = void;
                    bool halt = void;

                    if (startTiming == 3) {
                        if (channel == 1 || channel == 2) {
                            wordCount = 4;
                            type = 1;
                            destinationAddressControl = 2;
                            halt = false;
                        } else if (channel == 3) {
                            // TODO: implement video capture
                        }
                    } else {
                        wordCount = super.getShort(dmaAddress + 8);
                        if (channel < 3) {
                            if (wordCount == 0) {
                                wordCount = 0x3FFF;
                            }
                            wordCount &= 0x3FFF;
                        } else {
                            if (wordCount == 0) {
                                wordCount = 0xFFFF;
                            }
                            wordCount &= 0xFFFF;
                        }
                        wordCount++;
                        type = getBit(control, 10);
                        destinationAddressControl = getBits(control, 5, 6);
                        halt = true;
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

                    int increment = type ? 2 : 4;
                    GameBoyAdvanceMemory memory = this.outer.outer.memory;
                    if (halt) {
                        processor.halt();
                    }
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
                    } else if (halt) {
                        processor.resume();
                    }
                    setBit(control, 15, repeat);
                    setShort(dmaAddress + 10, cast(short) control);
                }

                while (dmaRunning) {
                    dmaSemaphore.wait();
                    for (int s = 0; s < 4; s++) {
                        if (checkBit(dmaSignals, s)) {
                            int signals = dmaSignals;
                            setBit(signals, s, 0);
                            dmaSignals = signals;
                            for (int c = 0; c < 4; c++) {
                                tryDMA(c, s);
                            }
                        }
                    }
                }
            }
        }

        public static enum InterruptSource : int {
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

public class EmulatorRunningException : Exception {
    protected this() {
        super("Cannot perform this action while the emulator is running");
    }
}
