module gbaid.timer;

import core.thread;

import gbaid.cycle;
import gbaid.memory;
import gbaid.interrupt;
import gbaid.util;

public class Timers {
    private CycleSharer4* cycleSharer;
    private RAM ioRegisters;
    private InterruptHandler interruptHandler;
    private Thread thread;
    private bool running = false;
    private ushort[4] reloadValues;
    private int[4] controls;
    private int[4] subTicks;
    private ushort[4] ticks;

    public this(CycleSharer4* cycleSharer, IORegisters ioRegisters, InterruptHandler interruptHandler) {
        this.cycleSharer = cycleSharer;
        this.ioRegisters = ioRegisters.getMonitored();
        this.interruptHandler = interruptHandler;
        ioRegisters.addMonitor(new TimerMemoryMonitor(), 0x100, 16);
    }

    public void start() {
        if (thread is null) {
            thread = new Thread(&run);
            thread.name = "Timers";
            running = true;
            thread.start();
        }
    }

    public void stop() {
        if (thread !is null) {
            running = false;
            thread = null;
        }
    }

    public bool isRunning() {
        return running;
    }

    private void run() {
        while (running) {
            cycleSharer.takeCycles!3(1);
            auto previousOverflowed = false;
            foreach (timer; 0 .. 4) {
                // Check that the timer is enabled
                auto control = controls[timer];
                if (!control.checkBit(7)) {
                    previousOverflowed = false;
                    continue;
                }
                // Check the ticking condition
                bool shouldTick = void;
                if (control.checkBit(2)) {
                    // Count-up timing: increment if the previous timer overflowed
                    shouldTick = previousOverflowed;
                } else {
                    // Update the sub-ticks according to the pre-scaler
                    subTicks[timer]++;
                    if (subTicks[timer] >= control.getTickLength()) {
                        // We tick when a sub-tick is complete
                        subTicks[timer] = 0;
                        shouldTick = true;
                    } else {
                        shouldTick = false;
                    }
                }
                // Tick if we should
                if (shouldTick) {
                    // Check for an overflow
                    previousOverflowed = ticks[timer] == ushort.max;
                    if (previousOverflowed) {
                        // If we overflow, write the reload value instead
                        ticks[timer] = reloadValues[timer];
                        // Trigger an IRQ on overflow if requested
                        if (control.checkBit(6)) {
                            interruptHandler.requestInterrupt(InterruptSource.TIMER_0_OVERFLOW + timer);
                        }
                    } else {
                        ticks[timer]++;
                    }
                }
            }
        }
    }

    private class TimerMemoryMonitor : MemoryMonitor {
        protected override void onRead(Memory ioRegisters, int address, int shift, int mask, ref int value) {
            // Ignore reads that aren't on the counter
            if (!(mask & 0xFFFF)) {
                return;
            }
            // Write the tick count to the value
            int timer = (address - 0x100) / 4;
            value = value & ~mask | ticks[timer] & mask;
        }

        protected override void onPostWrite(Memory ioRegisters, int address, int shift, int mask, int oldTimer, int newTimer) {
            // Get the timer number
            int timer = (address - 0x100) / 4;
            // Update the control and reload value
            reloadValues[timer] = cast(ushort) (newTimer & 0xFFFF);
            controls[timer] = newTimer >>> 16;
            // Reset the timer if the enable bit goes from 0 to 1
            if (!oldTimer.checkBit(23) && newTimer.checkBit(23)) {
                subTicks[timer] = 0;
                ticks[timer] = reloadValues[timer];
            }
        }
    }
}

private int getTickLength(int control) {
    final switch (control & 0b11) {
        case 0:
            return 1;
        case 1:
            return 64;
        case 2:
            return 256;
        case 3:
            return 1024;
    }
}
