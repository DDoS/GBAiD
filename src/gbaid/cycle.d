module gbaid.cycle;

import core.atomic : MemoryOrder, atomicLoad, atomicStore, atomicOp;
import core.thread : Thread;

import gbaid.util;

public alias CycleSharer4 = CycleSharer!4;

public template CycleSharer(uint numberOfSharers) if (numberOfSharers > 0 && numberOfSharers <= 32) {
    public struct CycleSharer {
        private enum sharersMask = (1 << numberOfSharers) - 1;
        public immutable size_t cycleBatchSize;
        private shared size_t availableCycles = 0;
        private ptrdiff_t distributedCycle(uint id) = 0;
        private shared uint doneWithCycles = 0;
        private shared uint runningSharers = sharersMask;

        public this(size_t cycleBatchSize) {
            this.cycleBatchSize = cycleBatchSize;
        }

        public void giveCycles(size_t cycles) {
            availableCycles.atomicOp!"+="(cycles);
        }

        public void waitForCycleDepletion() {
            while (availableCycles.atomicLoad!(MemoryOrder.raw) >= cycleBatchSize) {
                Thread.yield();
            }
        }

        public void hasStopped(uint id)() if (id < numberOfSharers) {
            runningSharers.atomicOp!"&="(~(1 << id));
        }

        public size_t takeBatchCycles(uint id)() {
            takeCycles!id(cycleBatchSize);
            return cycleBatchSize;
        }

        public void takeCycles(uint id)(size_t cycles) if (id < numberOfSharers) {
            while (true) {
                // If we have available cycles, then take them and return
                auto remainingCycles = distributedCycle!id - cast(ptrdiff_t) cycles;
                if (remainingCycles >= 0) {
                    distributedCycle!id = remainingCycles;
                    break;
                }
                // Otherwise we mark that we are done with the cycles
                enum sharerBit = 1 << id;
                doneWithCycles.atomicOp!"|="(sharerBit);
                // If this is the first sharer, wait until all others are also done
                // For any other sharer, wait until the first sharer has reset the "done" flags
                enum barrierCondition = id == 0 ? "!= (sharersMask & runningSharers.atomicLoad!(MemoryOrder.raw))"
                        : "& sharerBit";
                while (mixin("doneWithCycles.atomicLoad!(MemoryOrder.raw) " ~ barrierCondition)) {
                }
                // The first sharer takes care of distributing a new batch of cycles
                static if (id == 0) {
                    // Wait if necessary for cycles to become available
                    while (availableCycles.atomicLoad!(MemoryOrder.raw) < cycleBatchSize) {
                    }
                    // Take the cycles from the available ones
                    availableCycles.atomicOp!"-="(cycleBatchSize);
                    // Clear the "done" flags to lift the barrier
                    doneWithCycles.atomicStore!(MemoryOrder.raw)(0);
                }
                // Self-distribute the cycles
                distributedCycle!id += cycleBatchSize;
                // Go back to trying to take cycles
            }
        }
    }
}
