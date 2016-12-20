module gbaid.system;

import std.stdio;
import std.string;

import derelict.sdl2.sdl;

import gbaid.display;
import gbaid.cpu;
import gbaid.fast_mem;
import gbaid.dma;
import gbaid.interrupt;
import gbaid.halt;
import gbaid.input;
import gbaid.timer;
import gbaid.cycle;
import gbaid.gamepak;
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

            keypad.start();
            timers.start();
            dmas.start();
            processor.start();
            display.start();

            while (!graphics.isCloseRequested()) {
                enum cyclesForAFrame = (240 + 68) * (160 + 68) * 4;
                cycleSharer.giveCycles(cyclesForAFrame);
                graphics.draw(display.lockFrame());
                display.unlockFrame();
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
            keypad.stop();
            display.stop();

            graphics.destroy();

            SDL_Quit();
        }
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
