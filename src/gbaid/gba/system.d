module gbaid.gba.system;

import gbaid.util;

import gbaid.gba.display;
import gbaid.gba.cpu;
import gbaid.gba.memory;
import gbaid.gba.dma;
import gbaid.gba.interrupt;
import gbaid.gba.halt;
import gbaid.gba.keypad;
import gbaid.gba.sound;
import gbaid.gba.timer;

public class GameBoyAdvance {
    private static enum size_t CYCLE_BATCH_SIZE = Display.CYCLES_PER_DOT * 4;
    private MemoryBus memory;
    private ARM7TDMI processor;
    private InterruptHandler interruptHandler;
    private HaltHandler haltHandler;
    private Display display;
    private Keypad keypad;
    private SoundChip soundChip;
    private Timers timers;
    private DMAs dmas;
    private int lastBIOSPreFetch;
    private size_t displayCycles = 0;
    private size_t processorCycles = 0;
    private size_t dmasCycles = 0;
    private size_t timersCycles = 0;
    private size_t soundChipCycles = 0;
    private size_t keypadCycles = 0;

    public this(void[] bios, GamePakData gamePakData) {
        memory = MemoryBus(bios, gamePakData);
        memory.biosReadFallback = &biosReadFallback;
        memory.unusedMemory = &unusedReadFallBack;

        auto ioRegisters = memory.ioRegisters;

        processor = new ARM7TDMI(&memory, BIOS_START);
        haltHandler = new HaltHandler(processor);
        interruptHandler = new InterruptHandler(ioRegisters, processor, haltHandler);
        keypad = new Keypad(ioRegisters, interruptHandler);
        dmas = new DMAs(&memory, ioRegisters, interruptHandler, haltHandler);
        soundChip = new SoundChip(ioRegisters, dmas);
        timers = new Timers(memory.newIoRegisters, interruptHandler, soundChip);
        display = new Display(ioRegisters, memory.palette, memory.vram, memory.oam, interruptHandler, dmas);

        memory.biosReadGuard = &biosReadGuard;
        memory.gamePak.interruptHandler = interruptHandler;
    }

    @property public FrameSwapper frameSwapper() {
        return display.frameSwapper;
    }

    @property public void audioReceiver(AudioReceiver receiver) {
        soundChip.receiver = receiver;
    }

    @property public GamePakData gamePakSaveData() {
        return memory.gamePak.saveData;
    }

    public void setKeypadState(KeypadState state) {
        keypad.setState(state);
    }

    public void emulate(size_t cycles) {
        // If an exception occurs during emulation, swap the frame to release any thread waiting on this one
        scope (failure) {
            frameSwapper.swapFrame();
        }
        // Split cycles into batches, and process these first
        auto fullBatches = cycles / CYCLE_BATCH_SIZE;
        foreach (i; 0 .. fullBatches) {
            displayCycles = display.emulate(displayCycles + CYCLE_BATCH_SIZE);
            processorCycles = processor.emulate(processorCycles + CYCLE_BATCH_SIZE);
            dmasCycles = dmas.emulate(dmasCycles + CYCLE_BATCH_SIZE);
            timersCycles = timers.emulate(timersCycles + CYCLE_BATCH_SIZE);
            soundChipCycles = soundChip.emulate(soundChipCycles + CYCLE_BATCH_SIZE);
            keypadCycles = keypad.emulate(keypadCycles + CYCLE_BATCH_SIZE);
        }
        // An incomplete batch of cycles might be lef over, so process it too
        auto partialBatch = cycles % CYCLE_BATCH_SIZE;
        if (partialBatch > 0) {
            displayCycles = display.emulate(displayCycles + partialBatch);
            processorCycles = processor.emulate(processorCycles + partialBatch);
            dmasCycles = dmas.emulate(dmasCycles + partialBatch);
            timersCycles = timers.emulate(timersCycles + partialBatch);
            soundChipCycles = soundChip.emulate(soundChipCycles + partialBatch);
            keypadCycles = keypad.emulate(keypadCycles + partialBatch);
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
