module gbaid.gba.interrupt;

import gbaid.util;

import gbaid.gba.io;
import gbaid.gba.cpu;
import gbaid.gba.halt;

public class InterruptHandler {
    private ARM7TDMI processor;
    private HaltHandler haltHandler;
    private bool masterEnable = false;
    private int enable = 0;
    private int request = 0;

    public this(IoRegisters* ioRegisters, ARM7TDMI processor, HaltHandler haltHandler) {
        this.processor = processor;
        this.haltHandler = haltHandler;

        ioRegisters.mapAddress(0x208, &masterEnable, 0b1, 0);
        ioRegisters.mapAddress(0x200, &enable, 0x3FFF, 0);
        ioRegisters.mapAddress(0x200, &request, 0x3FFF, 16)
                .preWriteMonitor(&onInterruptAcknowledgePreWrite)
                .postWriteMonitor(&onInterruptAcknowledgePostWrite);
    }

    public void requestInterrupt(int source) {
        request.setBit(source, 1);
        checkForIrq();
    }

    private bool onInterruptAcknowledgePreWrite(int mask, ref int acknowledged) {
        // Clear the acknowledged interrupts and replace the value by the updated request bits
        acknowledged = request & ~acknowledged;
        return true;
    }

    private void onInterruptAcknowledgePostWrite(int mask, int oldRequest, int newRequest) {
        // Trigger another IRQ if any is still not acknowledged
        checkForIrq();
    }

    private void checkForIrq() {
        auto irq = masterEnable && (request & enable);
        processor.irq(irq);
        if (irq) {
            haltHandler.irqTriggered();
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
