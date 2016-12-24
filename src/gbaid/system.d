module gbaid.system;

import core.time : TickDuration;

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
import gbaid.cycle;
import gbaid.save;
import gbaid.graphics;
import gbaid.util;

public class GameBoyAdvance {
    private CycleSharer4 cycleSharer;
    private MemoryBus memory;
    private ARM7TDMI processor;
    private InterruptHandler interruptHandler;
    private HaltHandler haltHandler;
    private Display display;
    private Keypad keypad;
    private Timers timers;
    private DMAs dmas;
    private int lastBIOSPreFetch;
    private Graphics graphics;

    public this(Save)(string biosFile, string romFile, Save save) {
        if (biosFile is null) {
            throw new NullPathException("BIOS");
        }

        cycleSharer = CycleSharer4(4 * 4);


        static if (is(Save == SaveConfiguration) || is(Save == string)) {
            memory = MemoryBus(biosFile, romFile, save);
        } else {
            static assert (0, "Expected a SaveConfiguration value or a file path as a string");
        }

        auto ioRegisters = memory.ioRegisters;

        processor = new ARM7TDMI(&cycleSharer, &memory);
        haltHandler = new HaltHandler(processor);
        interruptHandler = new InterruptHandler(ioRegisters, processor, haltHandler);
        keypad = new Keypad(ioRegisters, interruptHandler);
        timers = new Timers(&cycleSharer, ioRegisters, interruptHandler);
        dmas = new DMAs(&cycleSharer, &memory, ioRegisters, interruptHandler, haltHandler);
        display = new Display(&cycleSharer, ioRegisters, memory.palette, memory.vram, memory.oam, interruptHandler, dmas);

        memory.biosReadGuard = &biosReadGuard;
        memory.biosReadFallback = &biosReadFallback;
        memory.unusedMemory = &unusedReadFallBack;

        processor.setEntryPointAddress(BIOS_START);

        graphics = new Graphics(Display.HORIZONTAL_RESOLUTION, Display.VERTICAL_RESOLUTION);
    }

    @property public MemoryBus* memoryBus() {
        return &memory;
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

    public void run() {
        try {
            if (!DerelictSDL2.isLoaded) {
                DerelictSDL2.load();
            }
            SDL_Init(0);

            graphics.create();
            keypad.create();

            timers.start();
            dmas.start();
            processor.start();
            display.start();

            enum cyclesPerFrame = (240 + 68) * (160 + 68) * 4;
            enum nanoSecondsPerCycle = 2.0 ^^ -24 * 1e9;
            auto frameDuration = TickDuration.from!"nsecs"(cast(size_t) (cyclesPerFrame * nanoSecondsPerCycle));

            Timer timer = new Timer();
            while (!graphics.isCloseRequested()) {
                timer.start();
                // Give enough cycles to emulate an entire frame
                cycleSharer.giveCycles(cyclesPerFrame);
                // Update the input state
                keypad.poll();
                // Wait for the frame to be drawn, then display it
                graphics.draw(display.lockFrame());
                display.unlockFrame();
                // Wait for the actual duration of a frame
                timer.waitUntil(frameDuration);
                // Wait for any cycles not depleted
                cycleSharer.waitForCycleDepletion();
            }

        } catch (Exception ex) {
            writeln("Emulator encountered an exception, system stopping...");
            writeln("Exception: ", ex.msg);
        } finally {
            cycleSharer.giveCycles(size_t.max);

            processor.stop();
            dmas.stop();
            timers.stop();
            display.stop();

            keypad.destroy();
            graphics.destroy();

            SDL_Quit();
        }
    }

    public void saveSave(string saveFile) {
        memoryBus.gamePak.saveSave(saveFile);
    }

    private bool biosReadGuard(uint address) {
        if (processor.getProgramCounter() < cast(int) BIOS_SIZE) {
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
