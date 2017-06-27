module gbaid.gba.halt;

import gbaid.gba.io;
import gbaid.gba.cpu;

public class HaltHandler {
    private IoRegisters* ioRegisters;
    private ARM7TDMI processor;
    private bool haltMode = false;
    private bool softwareHalted = false, dmaHalted = false;

    public this(IoRegisters* ioRegisters, ARM7TDMI processor) {
        this.ioRegisters = ioRegisters;
        this.processor = processor;

        ioRegisters.mapAddress(0x300, &haltMode, 0b1, 15).postWriteMonitor(&onHaltRequestPostWrite);
    }

    public void irqTriggered() {
        softwareHalted = false;
        updateState();
    }

    public void dmaHalt(bool state) {
        dmaHalted = state;
        updateState();
    }

    private void updateState() {
        processor.halt(softwareHalted || dmaHalted);
    }

    private void onHaltRequestPostWrite(int mask, int oldValue, int newValue) {
        if (haltMode) {
            // TODO: implement stop
            throw new Error("Stop unimplemented");
        } else {
            softwareHalted = true;
            updateState();
        }
    }
}
