module gbaid.interrupt;

import gbaid.memory;
import gbaid.cpu;
import gbaid.halt;
import gbaid.util;

public class InterruptHandler {
    private RAM ioRegisters;
    private ARM7TDMI processor;
    private HaltHandler haltHandler;

    public this(IORegisters ioRegisters, ARM7TDMI processor, HaltHandler haltHandler) {
        this.ioRegisters = ioRegisters.getMonitored();
        this.processor = processor;
        this.haltHandler = haltHandler;
        ioRegisters.addMonitor(&onInterruptAcknowledgePreWrite, 0x202, 2);
        ioRegisters.addMonitor(&onHaltRequestPostWrite, 0x301, 1);
    }

    public void requestInterrupt(int source) {
        if ((ioRegisters.getInt(0x208) & 0b1) && checkBit(ioRegisters.getShort(0x200), source)) {
            int flags = ioRegisters.getShort(0x202);
            setBit(flags, source, 1);
            ioRegisters.setShort(0x202, cast(short) flags);
            processor.irq(true);
            haltHandler.softwareHalt(false);
        }
    }

    private bool onInterruptAcknowledgePreWrite(Memory ioRegisters, int address, int shift, int mask, ref int value) {
        value = ioRegisters.getInt(0x200) & ~value | value & 0xFFFF;
        processor.irq((value & 0x3FFF0000) != 0);
        return true;
    }

    private void onHaltRequestPostWrite(Memory ioRegisters, int address, int shift, int mask, int oldValue, int newValue) {
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
