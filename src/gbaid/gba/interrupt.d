module gbaid.gba.interrupt;

import gbaid.util;

import gbaid.gba.memory;
import gbaid.gba.cpu;
import gbaid.gba.halt;

public class InterruptHandler {
    private IoRegisters* ioRegisters;
    private ARM7TDMI processor;
    private HaltHandler haltHandler;

    public this(IoRegisters* ioRegisters, ARM7TDMI processor, HaltHandler haltHandler) {
        this.ioRegisters = ioRegisters;
        this.processor = processor;
        this.haltHandler = haltHandler;
        ioRegisters.setPreWriteMonitor!0x200(&onInterruptAcknowledgePreWrite);
        ioRegisters.setPostWriteMonitor!0x300(&onHaltRequestPostWrite);
    }

    public void requestInterrupt(int source) {
        int irqControl = ioRegisters.getUnMonitored!int(0x200);
        irqControl.setBit(source + 16, 1);
        ioRegisters.setUnMonitored!int(0x200, irqControl);
        checkForIrq(irqControl);
    }

    private bool onInterruptAcknowledgePreWrite(IoRegisters* ioRegisters, int address, int shift, int mask,
            ref int irqControl) {
        enum int acknowledgeMask = 0x3FFF0000;
        // Ignore a write outside the acknowledge mask
        if (!(mask & acknowledgeMask)) {
            return true;
        }
        // Mask out all but the bits of the interrupt acknowledge register
        int acknowledgeValue = irqControl & acknowledgeMask;
        // Invert the mask to clear the bits of the interrupts being acknowledged, and merge with the lower half
        irqControl = ioRegisters.getUnMonitored!int(0x200) & acknowledgeMask & ~acknowledgeValue | irqControl & 0xFFFF;
        // Trigger another IRQ if any is still not acknowledged
        checkForIrq(irqControl);
        return true;
    }

    private void checkForIrq(int irqControl) {
        auto irq = ioRegisters.getUnMonitored!int(0x208) & 0b1 && irqControl >>> 16 & (irqControl & 0xFFFF);
        processor.irq(irq);
        if (irq) {
            haltHandler.softwareHalt(false);
        }
    }

    private void onHaltRequestPostWrite(IoRegisters* ioRegisters, int address, int shift, int mask, int oldValue, int newValue) {
        if (checkBit(mask, 15)) {
            if (checkBit(newValue, 15)) {
                // TODO: implement stop
                throw new Error("Stop unimplemented");
            } else {
                haltHandler.softwareHalt(true);
            }
        }
    }
}

public static enum InterruptSource {
    LCD_VBLANK = 0,
    LCD_HBLANK = 1,
    LCD_VCOUNTER_MATCH = 2,
    TIMER_0_OVERFLOW = 3,
    TIMER_1_OVERFLOW = 4,
    TIMER_2_OVERFLOW = 5,
    TIMER_3_OVERFLOW = 6,
    SERIAL_COMMUNICATION = 7,
    DMA_0 = 8,
    DMA_1 = 9,
    DMA_2 = 10,
    DMA_3 = 11,
    KEYPAD = 12,
    GAMEPAK = 13
}
