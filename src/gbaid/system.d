module gbaid.system;

import core.time : TickDuration;
import core.thread : Thread;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;

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

private enum size_t CYCLES_PER_FRAME = (Display.HORIZONTAL_RESOLUTION + Display.BLANKING_RESOLUTION)
        * (Display.VERTICAL_RESOLUTION + Display.BLANKING_RESOLUTION) * Display.CYCLES_PER_DOT;
private enum size_t CYCLE_BATCH_SIZE = Display.CYCLES_PER_DOT * 4;
private enum size_t CYCLE_BATCHES_PER_FRAME = CYCLES_PER_FRAME / CYCLE_BATCH_SIZE;
private enum double NS_PER_CYCLE = 2.0 ^^ -24 * 1e9;
private const TickDuration FRAME_DURATION;

public static this() {
    FRAME_DURATION = TickDuration.from!"nsecs"(cast(size_t) (CYCLES_PER_FRAME * NS_PER_CYCLE));
}

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
    private Condition frameSync;
    private bool coreRunning = false;

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

        frameSync = new Condition(new Mutex());
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
        if (!DerelictSDL2.isLoaded) {
            DerelictSDL2.load();
        }
        SDL_Init(0);
        graphics.create();

        scope (exit) {
            graphics.destroy();
            SDL_Quit();
        }

        auto coreThread = new Thread(&systemCore);
        coreThread.name = "GBA";
        coreRunning = true;
        coreThread.start();

        auto timer = new Timer();
        short[Display.FRAME_SIZE] frame;
        while (!graphics.isCloseRequested()) {
            timer.start();
            // Signal the emulator to emulate a frame
            synchronized (frameSync.mutex) {
                frameSync.notify();
            }
            // Display the frame once drawn
            display.getFrame(frame);
            graphics.draw(frame);
            // Wait for the actual duration of a frame
            timer.waitUntil(FRAME_DURATION);
        }

        coreRunning = false;
        synchronized (frameSync.mutex) {
            frameSync.notify();
        }
        coreThread.join();
    }

    private void systemCore() {
        keypad.create();
        scope (exit) {
            keypad.destroy();
        }

        timers.init();
        dmas.init();
        processor.init();
        display.init();

        size_t displayCycles = CYCLE_BATCH_SIZE;
        size_t processorCycles = CYCLE_BATCH_SIZE;
        size_t dmasCycles = CYCLE_BATCH_SIZE;
        size_t timersCycles = CYCLE_BATCH_SIZE;

        while (coreRunning) {
            // Wait for a signal to emulate a frame
            synchronized (frameSync.mutex) {
                frameSync.wait();
            }
            // Update the input state
            keypad.poll();
            // Run all the system components using tick batching
            foreach (i; 0 .. CYCLE_BATCHES_PER_FRAME) {
                displayCycles = display.run(displayCycles) + CYCLE_BATCH_SIZE;
                processorCycles = processor.run(processorCycles) + CYCLE_BATCH_SIZE;
                dmasCycles = dmas.run(dmasCycles) + CYCLE_BATCH_SIZE;
                timersCycles = timers.run(timersCycles) + CYCLE_BATCH_SIZE;
            }
        }
    }

    public void saveSave(string saveFile) {
        memory.gamePak.saveSave(saveFile);
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
