module gbaid.system;

import std.stdio;
import std.string;

import derelict.sdl2.sdl;

import gbaid.display;
import gbaid.cpu;
import gbaid.memory;
import gbaid.dma;
import gbaid.interrupt;
import gbaid.halt;
import gbaid.input;
import gbaid.timer;
import gbaid.graphics;
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
    private int lastBIOSPreFetch;
    private Graphics graphics;

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

        graphics = new Graphics(Display.HORIZONTAL_RESOLUTION, Display.VERTICAL_RESOLUTION);
    }

    public void setGamePak(GamePak gamePak) {
        if (gamePak is null) {
            throw new Exception("GamePak is null");
        }
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
        graphics.setScale(scale);
    }

    public void setDisplayFilteringMode(FilteringMode mode) {
        graphics.setFilteringMode(mode);
    }

    public void setDisplayUpscalingMode(UpscalingMode mode) {
        graphics.setUpscalingMode(mode);
    }

    public MainMemory getMemory() {
        return memory;
    }

    public void run() {
        try {
            if (!DerelictSDL2.isLoaded) {
                DerelictSDL2.load();
            }
            SDL_Init(0);

            graphics.create();

            keypad.start();
            timers.start();
            dmas.start();
            processor.start();
            display.start();

            graphics.draw(display.lockFrame());
            display.unlockFrame();

        } catch (Exception ex) {
            writeln("Emulator encountered an exception, system stopping...");
            writeln("Exception: ", ex.msg);
        } finally {
            display.stop();
            processor.stop();
            dmas.stop();
            timers.stop();
            keypad.stop();

            graphics.destroy();

            SDL_Quit();
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
