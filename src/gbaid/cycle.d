module gbaid.cycle;

import core.atomic : MemoryOrder, atomicLoad, atomicStore, atomicOp;
import core.thread : Thread;

import gbaid.util;

public template CycleSharer(uint numberOfSharers) if (numberOfSharers > 0 && numberOfSharers <= 32) {
    public class CycleSharer {
        private immutable size_t cycleBatchSize;
        private shared size_t availableCycles = 0;
        private size_t[numberOfSharers] distributedCycles;
        private shared uint doneWithCycles = 0;

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

        public void takeCycles(uint id)(size_t cycles) if (id < numberOfSharers) {
            import std.stdio;
            while (true) {
                // If we have available cycles, then take them and return
                if (distributedCycles[id] >= cycles) {
                    distributedCycles[id] -= cycles;
                    break;
                }
                // Otherwise we mark that we are done with the cycles
                enum sharerBit = 1 << id;
                doneWithCycles.atomicOp!"|="(sharerBit);
                // If this is the first sharer, wait until all others are also done
                // For any other sharer, wait until the first sharer has reset the "done" flags
                enum sharersMask = (1 << numberOfSharers) - 1;
                enum barrierCondition = id == 0 ? "!= sharersMask" : "& sharerBit";
                while (mixin("doneWithCycles.atomicLoad!(MemoryOrder.raw) " ~ barrierCondition)) {
                    Thread.yield();
                    //writeln("1 ", id, ' ', doneWithCycles.atomicLoad!(MemoryOrder.raw));
                }
                // The first sharer takes care of distributing a new batch of cycles
                static if (id == 0) {
                    // Wait if necessary for cycles to become available
                    while (availableCycles.atomicLoad!(MemoryOrder.raw) < cycleBatchSize) {
                        Thread.yield();
                        //writeln("2 ", availableCycles.atomicLoad!(MemoryOrder.raw));
                    }
                    // Take the cycles from the available ones
                    availableCycles.atomicOp!"-="(cycleBatchSize);
                    // Distribute them to each sharer
                    foreach (id; 0 .. numberOfSharers) {
                        distributedCycles[id] += cycleBatchSize;
                    }
                    // Clear the "done" flags to lift the barrier
                    doneWithCycles.atomicStore!(MemoryOrder.raw)(0);
                }
                // Go back to trying to take cycles
            }
        }
    }
}
