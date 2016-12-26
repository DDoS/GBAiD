module gbaid.system;

import core.time : TickDuration;

import gbaid.display;
import gbaid.cpu;
import gbaid.memory;
import gbaid.dma;
import gbaid.interrupt;
import gbaid.halt;
import gbaid.keypad;
import gbaid.timer;
import gbaid.save;
import gbaid.util;

public class GameBoyAdvance {
    public static enum size_t CYCLES_PER_FRAME = (Display.HORIZONTAL_RESOLUTION + Display.BLANKING_RESOLUTION)
            * (Display.VERTICAL_RESOLUTION + Display.BLANKING_RESOLUTION) * Display.CYCLES_PER_DOT;
    private static enum size_t CYCLE_BATCH_SIZE = Display.CYCLES_PER_DOT * 4;
    private enum double NS_PER_CYCLE = 2.0 ^^ -24 * 1e9;
    public static const TickDuration FRAME_DURATION;
    private MemoryBus memory;
    private ARM7TDMI processor;
    private InterruptHandler interruptHandler;
    private HaltHandler haltHandler;
    private Display display;
    private Keypad keypad;
    private Timers timers;
    private DMAs dmas;
    private int lastBIOSPreFetch;
    private size_t displayCycles = 0;
    private size_t processorCycles = 0;
    private size_t dmasCycles = 0;
    private size_t timersCycles = 0;
    private size_t keypadCycles = 0;

    public static this() {
        FRAME_DURATION = TickDuration.from!"nsecs"(cast(size_t) (CYCLES_PER_FRAME * NS_PER_CYCLE));
    }

    public this(Save)(string biosFile, string romFile, Save save) {
        if (biosFile is null) {
            throw new NullPathException("BIOS");
        }

        static if (is(Save == SaveConfiguration) || is(Save == string)) {
            memory = MemoryBus(biosFile, romFile, save);
        } else {
            static assert (0, "Expected a SaveConfiguration value or a file path as a string");
        }

        memory.biosReadGuard = &nullBiosReadGuard;
        memory.biosReadFallback = &biosReadFallback;
        memory.unusedMemory = &unusedReadFallBack;

        auto ioRegisters = memory.ioRegisters;

        processor = new ARM7TDMI(&memory, BIOS_START);
        haltHandler = new HaltHandler(processor);
        interruptHandler = new InterruptHandler(ioRegisters, processor, haltHandler);
        keypad = new Keypad(ioRegisters, interruptHandler);
        timers = new Timers(ioRegisters, interruptHandler);
        dmas = new DMAs(&memory, ioRegisters, interruptHandler, haltHandler);
        display = new Display(ioRegisters, memory.palette, memory.vram, memory.oam, interruptHandler, dmas);

        memory.biosReadGuard = &biosReadGuard;
    }

    public void setKeypadState(KeypadState state) {
        keypad.setState(state);
    }

    public void getFrame(short[] frame) {
        display.getFrame(frame);
    }

    public void emulate(size_t cycles = CYCLES_PER_FRAME) {
        auto fullBatches = cycles / CYCLE_BATCH_SIZE;
        foreach (i; 0 .. fullBatches) {
            displayCycles = display.emulate(displayCycles + CYCLE_BATCH_SIZE);
            processorCycles = processor.emulate(processorCycles + CYCLE_BATCH_SIZE);
            dmasCycles = dmas.emulate(dmasCycles + CYCLE_BATCH_SIZE);
            timersCycles = timers.emulate(timersCycles + CYCLE_BATCH_SIZE);
            keypadCycles = keypad.emulate(keypadCycles + CYCLE_BATCH_SIZE);
        }

        auto partialBatch = cycles % CYCLE_BATCH_SIZE;
        if (partialBatch > 0) {
            displayCycles = display.emulate(displayCycles + partialBatch);
            processorCycles = processor.emulate(processorCycles + partialBatch);
            dmasCycles = dmas.emulate(dmasCycles + partialBatch);
            timersCycles = timers.emulate(timersCycles + partialBatch);
            keypadCycles = keypad.emulate(keypadCycles + partialBatch);
        }
    }

    public void saveSave(string saveFile) {
        memory.gamePak.saveSave(saveFile);
    }

    private bool nullBiosReadGuard(uint address) {
        return true;
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
