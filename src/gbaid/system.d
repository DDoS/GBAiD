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
        processor.run(0);
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

        // TODO: map memory
        public byte getByte(uint address) {
            return 0;
        }

        public void setByte(uint address, byte b) {
        }

        public short getShort(uint address) {
            return 0;
        }

        public void setShort(uint address, short s) {
        }

        public int getInt(uint address) {
            return 0;
        }

        public void setInt(uint address, int i) {
        }

        public long getLong(uint address) {
            return 0;
        }

        public void setLong(uint address, long l) {
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
