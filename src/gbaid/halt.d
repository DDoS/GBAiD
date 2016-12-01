module gbaid.halt;

import gbaid.cpu;

public class HaltHandler {
    private ARM7TDMI processor;
    private bool softwareHalted = false, dmaHalted = false;

    public this(ARM7TDMI processor) {
        this.processor = processor;
    }

    public void setHaltTask(bool delegate() haltTask) {
        processor.setHaltTask(haltTask);
    }

    public void softwareHalt(bool state) {
        softwareHalted = state;
        updateState();
    }

    public void dmaHalt(bool state) {
        dmaHalted = state;
        updateState();
    }

    public void updateState() {
        processor.halt(softwareHalted || dmaHalted);
    }
}
