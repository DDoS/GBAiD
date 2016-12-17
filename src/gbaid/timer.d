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
    private ushort reloadValue(int timer) = 0;
    private int control(int timer) = 0;
    private int subTicks(int timer) = 0;
    private ushort ticks(int timer) = 0;

    public this(CycleSharer4* cycleSharer, IORegisters ioRegisters, InterruptHandler interruptHandler) {
        assert (cycleSharer.cycleBatchSize < ushort.max);
        this.cycleSharer = cycleSharer;
        this.ioRegisters = ioRegisters.getMonitored();
        this.interruptHandler = interruptHandler;
        ioRegisters.addMonitor(new TimerMemoryMonitor!0(), 0x100, 4);
        ioRegisters.addMonitor(new TimerMemoryMonitor!1(), 0x104, 4);
        ioRegisters.addMonitor(new TimerMemoryMonitor!2(), 0x108, 4);
        ioRegisters.addMonitor(new TimerMemoryMonitor!3(), 0x10C, 4);
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
            thread.join();
            thread = null;
            cycleSharer.hasStopped!3();
        }
    }

    public bool isRunning() {
        return running;
    }

    private void run() {
        while (running) {
            auto cycles = cast(ushort) cycleSharer.takeBatchCycles!3();
            auto previousOverflows = updateTimer!0(cycles, 0);
            previousOverflows = updateTimer!1(cycles, previousOverflows);
            previousOverflows = updateTimer!2(cycles, previousOverflows);
            updateTimer!3(cycles, previousOverflows);
        }
    }

    private int updateTimer(int timer)(ushort cycles, int previousOverflows) {
        // Check that the timer is enabled
        if (!control!timer.checkBit(7)) {
            return false;
        }
        // Check the ticking condition
        int newTicks = void;
        if (control!timer.checkBit(2)) {
            // Count-up timing: increment if the previous timer overflowed
            newTicks = previousOverflows;
        } else {
            // Update the sub-ticks according to the pre-scaler
            subTicks!timer += cycles;
            auto preScalerBase2Power = control!timer.getPreScalerBase2Power();
            // We tick for each completed sub-tick
            newTicks = subTicks!timer >> preScalerBase2Power;
            subTicks!timer &= (1 << preScalerBase2Power) - 1;
        }
        // Only tick if we need to
        if (newTicks <= 0) {
            return false;
        }
        // Check for an overflow
        auto ticksUntilOverflow = ushort.max - ticks!timer + 1;
        if (newTicks < ticksUntilOverflow) {
            // No overflow, just increment the tick counter
            ticks!timer += newTicks;
            return 0;
        }
        // If we overflow, start by consuming the new ticks to that overflow
        newTicks -= ticksUntilOverflow;
        // Reload the value and add any extra ticks past the overflows
        ticksUntilOverflow = ushort.max - reloadValue!timer + 1;
        ticks!timer = cast(ushort) (reloadValue!timer + newTicks % ticksUntilOverflow);
        // Trigger an IRQ on overflow if requested
        if (control!timer.checkBit(6)) {
            interruptHandler.requestInterrupt(InterruptSource.TIMER_0_OVERFLOW + timer);
        }
        // Return the first overflow plus any extra
        return 1 + newTicks / ticksUntilOverflow;
    }

    private class TimerMemoryMonitor(int timer) : MemoryMonitor {
        protected override void onRead(Memory ioRegisters, int address, int shift, int mask, ref int value) {
            // Ignore reads that aren't on the counter
            if (!(mask & 0xFFFF)) {
                return;
            }
            // Write the tick count to the value
            value = value & ~mask | ticks!timer & mask;
        }

        protected override void onPostWrite(Memory ioRegisters, int address, int shift, int mask, int oldTimer, int newTimer) {
            // Update the control and reload value
            reloadValue!timer = cast(ushort) (newTimer & 0xFFFF);
            control!timer = newTimer >>> 16;
            // Reset the timer if the enable bit goes from 0 to 1
            if (!oldTimer.checkBit(23) && newTimer.checkBit(23)) {
                subTicks!timer = 0;
                ticks!timer = reloadValue!timer;
            }
        }
    }
}

private int getPreScalerBase2Power(int control) {
    final switch (control & 0b11) {
        case 0:
            return 0;
        case 1:
            return 6;
        case 2:
            return 8;
        case 3:
            return 10;
    }
}
