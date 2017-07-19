module gbaid.gba.halt;

import gbaid.gba.io;
import gbaid.gba.cpu;

public class HaltHandler {
    private ARM7TDMI processor;
    private bool softwareHalted = false, dmaHalted = false;

    public this(IoRegisters* ioRegisters, ARM7TDMI processor) {
        this.processor = processor;

        ioRegisters.mapAddress(0x300, null, 0b1, 15).preWriteMonitor(&onHaltRequestPreWrite);
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

    private bool onHaltRequestPreWrite(int mask, ref int haltMode) {
        if (haltMode) {
            // TODO: implement stop
            throw new Error("Stop unimplemented");
        } else {
            softwareHalted = true;
            updateState();
        }
        return true;
    }
}
