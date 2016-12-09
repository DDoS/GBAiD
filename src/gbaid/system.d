module gbaid.system;

import std.stdio;
import std.string;

import derelict.sdl2.sdl;

import gbaid.graphics;
import gbaid.cpu;
import gbaid.memory;
import gbaid.dma;
import gbaid.interrupt;
import gbaid.halt;
import gbaid.input;
import gbaid.timer;
import gbaid.util;

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
            dmas.start();
            processor.start();
            display.run();
        } catch (Exception ex) {
            writeln("Emulator encountered an exception, system stopping...");
            writeln("Exception: ", ex.msg);
        } finally {
            processor.stop();
            dmas.stop();
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
