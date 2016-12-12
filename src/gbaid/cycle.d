module gbaid.cycle;

import core.atomic : MemoryOrder, atomicLoad, atomicStore, atomicOp;
import core.thread : Thread;

import std.conv : to;

import gbaid.util;

public template CycleSharer(uint numberOfSharers) if (numberOfSharers > 0 && numberOfSharers <= 32) {
    private mixin template declarePrivateFields(T, string name, size_t count) {
        mixin("private " ~ T.stringof ~ " " ~ name ~ (count - 1).to!string() ~ ";");
        static if (count > 1) {
            mixin declarePrivateFields!(T, name, count - 1);
        }
    }

    public class CycleSharer {
        private immutable size_t cycleBatchSize;
        private shared size_t availableCycles = 0;
        mixin declarePrivateFields!(ptrdiff_t, "distributedCycles", numberOfSharers);
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
            while (true) {
                // If we have available cycles, then take them and return
                enum getDistributedCycles = "distributedCycles" ~ id.to!string();
                auto remainingCycles = mixin(getDistributedCycles) - cast(ptrdiff_t) cycles;
                if (remainingCycles >= 0) {
                    mixin(getDistributedCycles) = remainingCycles;
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
                mixin(getDistributedCycles) += cycleBatchSize;
                // Go back to trying to take cycles
            }
        }
    }
}
