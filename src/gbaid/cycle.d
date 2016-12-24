module gbaid.cycle;

import core.atomic : MemoryOrder, atomicLoad, atomicStore, atomicOp;
import core.thread : Thread;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;

import gbaid.util;

public alias CycleSharer4 = CycleSharer!4;

public template CycleSharer(uint numberOfSharers) if (numberOfSharers > 0 && numberOfSharers <= 32) {
    public struct CycleSharer {
        private enum sharersMask = (1 << numberOfSharers) - 1;
        public immutable size_t cycleBatchSize;
        private Condition waitForCycles;
        private shared size_t availableCycles = 0;
        private ptrdiff_t distributedCycle(uint id) = 0;
        private shared uint doneWithBatch = 0;
        private shared uint runningSharers = sharersMask;

        public this(size_t cycleBatchSize) {
            this.cycleBatchSize = cycleBatchSize;
        }

        public void giveCycles(size_t cycles) {
            availableCycles.atomicOp!"+="(cycles);
            synchronized (waitForCycles.mutex) {
                waitForCycles.notifyAll();
            }
        }

        public void waitForCycleDepletion() {
            while (availableCycles.atomicLoad!(MemoryOrder.raw) >= cycleBatchSize) {
                Thread.yield();
            }
        }

        public void hasStopped(uint id)() if (id < numberOfSharers) {
            runningSharers.atomicOp!"&="(~(1 << id));
        }

        public size_t takeBatchCycles(uint id)() if (id < numberOfSharers) {
            takeCycles!id(cycleBatchSize);
            return cycleBatchSize;
        }

        public void takeCycles(uint id)(size_t cycles) if (id < numberOfSharers) {
            takeCycles!(id, false)(cycles);
        }

        public void wasteCycles(uint id)() if (id < numberOfSharers) {
            takeCycles!(id, true)(0);
        }

        private void takeCycles(uint id, bool waste)(size_t cycles) {
            while (true) {
                static if (waste) {
                    // Take all the cycles and don't return
                    distributedCycle!id = 0;
                } else {
                    // If we have available cycles, then take them and return
                    auto remainingCycles = distributedCycle!id - cast(ptrdiff_t) cycles;
                    if (remainingCycles >= 0) {
                        distributedCycle!id = remainingCycles;
                        break;
                    }
                }
                // If we run out of cycles, mark that we are done with the batch
                enum sharerBit = 1 << id;
                doneWithBatch.atomicOp!"|="(sharerBit);
                // If this is the first sharer, wait until all others are also done
                // For any other sharer, wait until the first sharer has reset the "done" flags
                enum barrierCondition = id == 0 ? "!= (sharersMask & runningSharers.atomicLoad!(MemoryOrder.raw))"
                        : "& sharerBit";
                while (mixin("doneWithBatch.atomicLoad!(MemoryOrder.raw) " ~ barrierCondition)) {
                    // Let the other sharers go to sleep if we run out of available cycles
                    static if (id > 0) {
                        while (availableCycles.atomicLoad!(MemoryOrder.raw) < cycleBatchSize) {
                            synchronized (waitForCycles.mutex) {
                                waitForCycles.wait();
                            }
                        }
                    }
                }
                // The first sharer takes care of distributing a new batch of cycles
                static if (id == 0) {
                    // If we run out of available cycles, wait for more
                    while (availableCycles.atomicLoad!(MemoryOrder.raw) < cycleBatchSize) {
                        synchronized (waitForCycles.mutex) {
                            waitForCycles.wait();
                        }
                    }
                    // Take the cycles from the available ones
                    availableCycles.atomicOp!"-="(cycleBatchSize);
                    // Clear the "done" flags to lift the barrier
                    doneWithBatch.atomicStore!(MemoryOrder.raw)(0);
                }
                // Self-distribute the cycles
                distributedCycle!id += cycleBatchSize;
                // If wasting cycles, return once we get a new batch of cycles
                static if (waste) {
                    break;
                }
                // Else go back to trying to take cycles
            }
        }
    }
}
