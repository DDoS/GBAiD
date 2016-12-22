module gbaid.interrupt;

import gbaid.memory;
import gbaid.cpu;
import gbaid.halt;
import gbaid.util;

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
        if ((ioRegisters.getUnMonitored!int(0x208) & 0b1) && checkBit(ioRegisters.getUnMonitored!short(0x200), source)) {
            int flags = ioRegisters.getUnMonitored!short(0x202);
            setBit(flags, source, 1);
            ioRegisters.setUnMonitored!short(0x202, cast(short) flags);
            processor.irq(true);
            haltHandler.softwareHalt(false);
        }
    }

    private bool onInterruptAcknowledgePreWrite(IoRegisters* ioRegisters, int address, int shift, int mask, ref int value) {
        value = ioRegisters.getUnMonitored!int(0x200) & ~value | value & 0xFFFF;
        processor.irq((value & 0x3FFF0000) != 0);
        return true;
    }

    private void onHaltRequestPostWrite(IoRegisters* ioRegisters, int address, int shift, int mask, int oldValue, int newValue) {
        if (checkBit(mask, 15)) {
            if (checkBit(newValue, 15)) {
                // TODO: implement stop
                assert (0);
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
