module gbaid.system;

import std.string : string;

import gbaid.arm;
import gbaid.memory;

public class GameBoyAdvance {
    private ARMProcessor processor = new ARMProcessor();
    private GBAMemory memory = null;
    private bool running = false;

    public this() {
        this(null);
    }

    public this(string romFile) {
        if (romFile !is null) {
            memory = new GBAMemory(romFile);
        }
    }

    public void loadROM(string romFile) {
        checkNotRunning();
        memory = new GBAMemory(romFile);
    }

    public void start() {
        if (memory is null) {
            throw new NoROMException();
        }
        checkNotRunning();
        processor.setMemory(memory);
        // TODO: start at proper location
        processor.run(GBAMemory.GAMEPAK_ROM_START);
    }

    private void checkNotRunning() {
        if (running) {
            throw new EmulatorRunningException();
        }
    }

    public class GBAMemory : Memory {
        private static immutable uint BIOS_SIZE = 16 * BYTES_PER_KIB;
        private static immutable uint WRAM_SIZE = 288 * BYTES_PER_KIB;
        private static immutable uint VRAM_SIZE = 96 * BYTES_PER_KIB;
        private static immutable uint OAM_SIZE = 1 * BYTES_PER_KIB;
        private static immutable uint PALETTE_RAM_SIZE = 1 * BYTES_PER_KIB;
        private static immutable uint MAX_GAMEPAK_ROM_SIZE = 32 * BYTES_PER_MIB;
        private static immutable uint MAX_GAMEPAK_SRAM_SIZE = 64 * BYTES_PER_KIB;
        private static immutable uint BIOS_START = 0x00000000;
        private static immutable uint BIOS_END = 0x00003FFF;
        private static immutable uint WRAM_START = 0x02000000;
        private static immutable uint WRAM_END = 0x03007FFF;
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
        private ROM bios;
        private RAM wram = new RAM(WRAM_SIZE);
        private RAM vram = new RAM(VRAM_SIZE);
        private RAM oam = new RAM(OAM_SIZE);
        private RAM paletteRAM = new RAM(PALETTE_RAM_SIZE);
        private ROM gamepakROM;
        private RAM gamepackSRAM;
        private ulong capacity;

        public this(string romFile) {
            // TODO: load bios
            bios = new ROM(new int[0]);
            gamepakROM = new ROM(romFile, MAX_GAMEPAK_ROM_SIZE);
            // TODO: load SRAM
            gamepackSRAM = new RAM(0);
            capacity = bios.getCapacity() + wram.getCapacity() + oam.getCapacity()
                + paletteRAM.getCapacity() + gamepakROM.getCapacity() + gamepackSRAM.getCapacity();
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

        public long getLong(uint address) {
            Memory memory = map(address);
            return memory.getLong(address);
        }

        public void setLong(uint address, long l) {
            Memory memory = map(address);
            memory.setLong(address, l);
        }

        private Memory map(ref uint address) {
            if (address <= BIOS_END) {
                address -= BIOS_START;
                return bios;
            }
            if (address <= WRAM_END) {
                address -= WRAM_START;
                return wram;
            }
            if (address <= PALETTE_RAM_END) {
                address -= PALETTE_RAM_START;
                return paletteRAM;
            }
            if (address <= VRAM_END) {
                address -= VRAM_START;
                return vram;
            }
            if (address <= OAM_END) {
                address -= OAM_START;
                return oam;
            }
            if (address <= GAMEPAK_ROM_END) {
                address -= GAMEPAK_ROM_START;
                address %= MAX_GAMEPAK_ROM_SIZE;
                return gamepakROM;
            }
            if (address <= GAMEPAK_SRAM_END) {
                address -= GAMEPAK_SRAM_START;
                return gamepackSRAM;
            }
            throw new BadAddressException(address);
        }
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
