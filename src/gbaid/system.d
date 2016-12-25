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
import gbaid.save;
import gbaid.graphics;
import gbaid.util;

public class GameBoyAdvance {
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

        static if (is(Save == SaveConfiguration) || is(Save == string)) {
            memory = MemoryBus(biosFile, romFile, save);
        } else {
            static assert (0, "Expected a SaveConfiguration value or a file path as a string");
        }

        auto ioRegisters = memory.ioRegisters;

        processor = new ARM7TDMI(&memory);
        haltHandler = new HaltHandler(processor);
        interruptHandler = new InterruptHandler(ioRegisters, processor, haltHandler);
        keypad = new Keypad(ioRegisters, interruptHandler);
        timers = new Timers(ioRegisters, interruptHandler);
        dmas = new DMAs(&memory, ioRegisters, interruptHandler, haltHandler);
        display = new Display(ioRegisters, memory.palette, memory.vram, memory.oam, interruptHandler, dmas);

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

            timers.init();
            dmas.init();
            processor.init();
            display.init();

            enum cyclesPerFrame = (240 + 68) * (160 + 68) * 4;
            enum cycleBatchSize = 4 * 4;
            enum cycleBatchesPerFrame = cyclesPerFrame / cycleBatchSize;
            enum nanoSecondsPerCycle = 2.0 ^^ -24 * 1e9;
            auto frameDuration = TickDuration.from!"nsecs"(cast(size_t) (cyclesPerFrame * nanoSecondsPerCycle));

            Timer timer = new Timer();
            size_t displayCycles = cycleBatchSize;
            size_t processorCycles = cycleBatchSize;
            size_t dmasCycles = cycleBatchSize;
            size_t timersCycles = cycleBatchSize;

            while (!graphics.isCloseRequested()) {
                timer.start();
                // Update the input state
                keypad.poll();
                // Run all the system components for a frame, using tick batching
                foreach (i; 0 .. cycleBatchesPerFrame) {
                    displayCycles = display.run(displayCycles) + cycleBatchSize;
                    processorCycles = processor.run(processorCycles) + cycleBatchSize;
                    dmasCycles = dmas.run(dmasCycles) + cycleBatchSize;
                    timersCycles = timers.run(timersCycles) + cycleBatchSize;
                }
                // Display the frame once drawn
                graphics.draw(display.getFrame());
                // Wait for the actual duration of a frame
                timer.waitUntil(frameDuration);
            }

        } catch (Exception ex) {
            writeln("Emulator encountered an exception, system stopping...");
            writeln("Exception: ", ex.msg);
        } finally {

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
