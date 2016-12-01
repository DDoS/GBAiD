module gbaid.timer;

import core.time : TickDuration;

import std.algorithm : max, min;

import gbaid.memory;
import gbaid.interrupt;
import gbaid.util;

public class Timers {
    private RAM ioRegisters;
    private InterruptHandler interruptHandler;
    private long[4] startTimes = new long[4];
    private long[4] endTimes = new long[4];
    private Scheduler scheduler;
    private int[4] irqTasks = new int[4];
    private void delegate()[4] irqHandlers;

    public this(IORegisters ioRegisters, InterruptHandler interruptHandler) {
        this.ioRegisters = ioRegisters.getMonitored();
        this.interruptHandler = interruptHandler;
        scheduler = new Scheduler();
        irqHandlers = [&irqHandler!0, &irqHandler!1, &irqHandler!2, &irqHandler!3];
        ioRegisters.addMonitor(new TimerMemoryMonitor(), 0x100, 16);
    }

    public void start() {
        scheduler.start();
    }

    public void stop() {
        scheduler.shutdown();
    }

    private class TimerMemoryMonitor : MemoryMonitor {
        protected override void onRead(Memory ioRegisters, int address, int shift, int mask, ref int value) {
            // ignore reads that aren't on the counter
            if (!(mask & 0xFFFF)) {
                return;
            }
            // fetch the timer number and information
            int i = (address - 0x100) / 4;
            int timer = ioRegisters.getInt(address);
            int control = timer >>> 16;
            int reload = timer & 0xFFFF;
            // convert the full tick count to the 16 bit format used by the GBA
            short counter = formatTickCount(getTickCount(i, control, reload), reload);
            // write the counter to the value
            value = value & ~mask | counter & mask;
        }

        protected override void onPostWrite(Memory ioRegisters, int address, int shift, int mask, int previousTimer, int newTimer) {
            // get the timer number and previous value
            int i = (address - 0x100) / 4;
            // check writes to the control byte for enable changes
            if (mask & 0xFF0000) {
                // check using the previous control value for a change in the enable bit
                if (!checkBit(previousTimer, 23)) {
                    if (checkBit(newTimer, 23)) {
                        // 0 to 1, reset the start time
                        startTimes[i] = TickDuration.currSystemTick().nsecs();
                    }
                } else if (!checkBit(newTimer, 23)) {
                    // 1 to 0, set the end time
                    endTimes[i] = TickDuration.currSystemTick().nsecs();
                }
            }
            // get the control and reload
            int control = newTimer >>> 16;
            int reload = newTimer & 0xFFFF;
            // update the IRQs
            if (isRunning(i, control)) {
                // check for IRQ enable if the time is running
                if (checkBit(control, 6)) {
                    // (re)schedule the IRQ
                    scheduleIRQ(i, control, reload);
                } else {
                    // cancel the IRQ
                    cancelIRQ(i);
                }
            } else {
                // cancel the IRQs and any dependent ones (upcounters)
                cancelIRQ(i);
                cancelDependentIRQs(i + 1);
            }
        }
    }

    private bool isRunning(int i, int control) {
        // check if timer is an upcounter
        if (i != 0 && checkBit(control, 2)) {
            // upcounters must also also have the previous timer running
            int previousControl = ioRegisters.getInt(i * 4 + 0xFC) >>> 16;
            return checkBit(control, 7) && isRunning(i - 1, previousControl);
        } else {
            // regular timers must just be running
            return checkBit(control, 7);
        }
    }

    private void irqHandler(int i)() {
        interruptHandler.requestInterrupt(InterruptSource.TIMER_0_OVERFLOW + i);
        irqTasks[i] = 0;
        scheduleIRQ(i);
    }

    private void scheduleIRQ(int i) {
        int timer = ioRegisters.getInt(i * 4 + 0x100);
        int control = timer >>> 16;
        int reload = timer & 0xFFFF;
        scheduleIRQ(i, control, reload);
    }

    private void scheduleIRQ(int i, int control, int reload) {
        cancelIRQ(i);
        long nextIRQ = cast(long) getTimeUntilIRQ(i, control, reload) + TickDuration.currSystemTick().nsecs();
        irqTasks[i] = scheduler.schedule(nextIRQ, irqHandlers[i]);
    }

    private void cancelIRQ(int i) {
        if (irqTasks[i] > 0) {
            scheduler.cancel(irqTasks[i]);
            irqTasks[i] = 0;
        }
    }

    private void cancelDependentIRQs(int i) {
        if (i > 3) {
            // prevent infinite recursion
            return;
        }
        int control = ioRegisters.getInt(i * 4 + 0x100) >>> 16;
        // if upcounter, cancel the IRQ and check the next timer
        if (checkBit(control, 2)) {
            cancelIRQ(i);
            cancelDependentIRQs(i + 1);
        }
    }

    private double getTimeUntilIRQ(int i, int control, int reload) {
        // the time per tick multiplied by the number of ticks until overflow
        double tickPeriod = getTickPeriod(i, control);
        int remainingTicks = 0x10000 - formatTickCount(getTickCount(i, control, reload), reload);
        return tickPeriod * remainingTicks;
    }

    private short formatTickCount(double tickCount, int reload) {
        // remove overflows if any
        if (tickCount > 0xFFFF) {
            tickCount = (tickCount - reload) % (0x10000 - reload) + reload;
        }
        // return as 16-bit
        return cast(short) tickCount;
    }

    private double getTickCount(int i, int control, int reload) {
        // convert the time into using the period ticks and add the reload value
        double tickPeriod = getTickPeriod(i, control);
        long timeDelta = getTimeDelta(i, control);
        return timeDelta / tickPeriod + reload;
    }

    private long getTimeDelta(int i, int control) {
        long getEndTime(int i, int control) {
            // if running, return current time, else use end time, set when it was disabled
            return checkBit(control, 7) ? TickDuration.currSystemTick().nsecs() : endTimes[i];
        }
        // upcounters are a special case because they depend on the previous timers
        if (i != 0 && checkBit(control, 2)) {
            // they only tick if all previous upcounters and the normal timer are ticking
            long maxStartTime = startTimes[i], minEndTime = getEndTime(i, control);
            // get the latest start time and earliest end time
            while (--i >= 0 && checkBit(control, 2)) {
                maxStartTime = max(maxStartTime, startTimes[i]);
                control = ioRegisters.getInt(i * 4 + 0x100) >>> 16;
                minEndTime = min(minEndTime, getEndTime(i, control));
            }
            // if the delta of the exterma is negative, it never ran
            long timeDelta = minEndTime - maxStartTime;
            return timeDelta > 0 ? timeDelta : 0;
        }
        // for normal timers, get the delta from start to end (or current if running)
        return getEndTime(i, control) - startTimes[i];
    }

    private double getTickPeriod(int i, int control) {
        // tick duration for a 16.78MHz clock
        enum double clockTickPeriod = 2.0 ^^ -24 * 1e9;
        // handle up-counting timers separately
        if (i != 0 && checkBit(control, 2)) {
            // get the previous timer's tick period
            int previousTimer = ioRegisters.getInt(i * 4 + 0xFC);
            int previousControl = previousTimer >>> 16;
            int previousReload = previousTimer & 0xFFFF;
            double previousTickPeriod = getTickPeriod(i - 1, previousControl);
            // this timer increments when the previous one overflows, so multiply by the ticks until overflow
            return previousTickPeriod * (0x10000 - previousReload);
        } else {
            // compute the pre-scaler period
            int preScaler = control & 0b11;
            if (preScaler == 0) {
                preScaler = 1;
            } else {
                preScaler = 1 << (preScaler << 1) + 4;
            }
            // compute and return the full tick period in ns
            return clockTickPeriod * preScaler;
        }
    }
}
