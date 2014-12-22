module gbaid.util;

import core.time;
import core.thread;
import core.sync.condition;

import std.conv;
import std.path;
import std.range;
import std.algorithm;
import std.container;

public uint ucast(byte v) {
    return cast(uint) v & 0xFF;
}

public uint ucast(short v) {
    return cast(uint) v & 0xFFFF;
}

public ulong ucast(int v) {
    return cast(ulong) v & 0xFFFFFFFF;
}

public bool checkBit(int i, int b) {
    return cast(bool) getBit(i, b);
}

public bool checkBits(int i, int m, int b) {
    return (i & m) == b;
}

public int getBit(int i, int b) {
    return i >> b & 1;
}

public void setBit(ref int i, int b, int n) {
    i = i & ~(1 << b) | (n & 1) << b;
}

public int getBits(int i, int a, int b) {
    return i >> a & (1 << b - a + 1) - 1;
}

public void setBits(ref int i, int a, int b, int n) {
    int mask = (1 << b - a + 1) - 1 << a;
    i = i & ~mask | n << a & mask;
}

public int sign(long v) {
    if (v == 0) {
        return 0;
    }
    return 1 - (v >>> 62 & 0b10);
}

template getSafe(T) {
    public T getSafe(T[] array, int index, T def) {
        if (index < 0 || index >= array.length) {
            return def;
        }
        return array[index];
    }
}

template addAll(K, V) {
    public void addAll(ref V[K] to, V[K] from) {
        foreach (k; from.byKey()) {
            to[k] = from[k];
        }
    }
}

template removeAll(K, V) {
    public void removeAll(ref V[K] to, V[K] from) {
        foreach (k; from.byKey()) {
            to.remove(k);
        }
    }
}

public string toString(char[] cs) {
    ulong end;
    foreach (i; 0 .. cs.length) {
        if (cs[i] == '\0') {
            end = i;
            break;
        }
    }
    return to!string(cs[0 .. end]);
}

public string expandPath(string relative) {
    return buildNormalizedPath(absolutePath(expandTilde(relative)));
}

public class Scheduler {
    private alias TaskFunction = void delegate();
    private Thread thread;
    private Mutex mutex;
    private Condition emptyCondition;
    private Condition waitingCondition;
    private bool running = false;
    private int nextFreeID = 1;
    private Task* first;

    public this() {
        mutex = new Mutex();
        emptyCondition = new Condition(mutex);
        waitingCondition = new Condition(mutex);
    }

    public void start() {
        thread = new Thread(&run);
        thread.name = "Scheduler";
        running = true;
        thread.start();
    }

    public void shutdown() {
        if (running) {
            first = null;
            running = false;
            emptyCondition.notify();
            waitingCondition.notify();
        }
    }

    public int schedule(long scheduledTime, TaskFunction run) {
        return schedule(TickDuration.from!"nsecs"(scheduledTime), run);
    }

    public int schedule(TickDuration scheduledTime, TaskFunction run) {
        synchronized (this) {
            // generate an ID
            int id = nextFreeID++;
            // create the task on the heap
            Task* task = new Task(id, scheduledTime, run);
            // insert the task in the chain according to it's priority
            Task* previous = null;
            Task* current = first;
            // find the spot in the chain
            while (current != null && *task >= *current) {
                previous = current;
                current = current.next;
            }
            // insert as first if there's no previous
            if (previous == null) {
                first = task;
            } else {
                previous.next = task;
                task.previous = previous;
            }
            if (current != null) {
                current.previous = task;
                task.next = current;
            }
            // notify the thread
            synchronized (mutex) {
                // only notify the thread on waiting when the task was inserted at front
                if (*first == *task) {
                    waitingCondition.notify();
                }
                // always notify the thread on empty
                emptyCondition.notify();
            }
            // return the ID for cancelling
            return id;
        }
    }

    public bool cancel(int id) {
        synchronized (this) {
            // check if there's anything to cancel
            if (first == null) {
                return false;
            }
            // remove the task if present
            Task* previous = null;
            Task* current = first;
            // look for the task in the chain
            while ((*current).id != id) {
                if (current.next == null) {
                    // not in chain
                    return false;
                }
                previous = current;
                current = current.next;
            }
            // keep track of the old first for later use
            Task* oldFirst = first;
            // remove from the correct spot
            if (previous == null) {
                first = current.next;
                if (first != null) {
                    first.previous = null;
                }
            } else {
                previous.next = current.next;
                if (current.next != null) {
                    current.next.previous = previous;
                }
            }
            // check if there's no remaining task or the first was removed
            if (first == null || *first != *oldFirst) {
                 // if so, notify the thread on waiting
                synchronized (mutex) {
                    waitingCondition.notify();
                }
            }
            return true;
        }
    }

    private void run() {
        Task next;
        Duration waitTime;
        while (running) {
            // wait until we get a task
            while (first == null) {
                synchronized (mutex) {
                    emptyCondition.wait();
                }
                // check for shutdown on wake up
                if (!running) {
                    return;
                }
            }
            // fetch the first task, but don't remove to allow cancelling
            next = *first;
            // wait until it's time to run it
            waitTime = dur!"nsecs"(next.scheduledTime.nsecs() - TickDuration.currSystemTick().nsecs());
            if (!waitTime.isNegative()) {
                synchronized (mutex) {
                    waitingCondition.wait(waitTime);
                }
            }
            // make sure the task wasn't cancelled
            if (first != null && next == *first) {
                // check if we're past the scheduled time
                if (TickDuration.currSystemTick() >= next.scheduledTime) {
                    // remove and run the task
                    first = first.next;
                    if (first != null) {
                        first.previous = null;
                    }
                    next.run();
                }
            }
        }
    }

    private static struct Task {
        private int id;
        private TickDuration scheduledTime;
        private TaskFunction run;
        private Task* previous;
        private Task* next;

        public bool opEquals()(auto ref const Task other) const {
            return id == other.id;
        }

        public int opCmp(ref const Task other) const {
            return sign((scheduledTime - other.scheduledTime).nsecs());
        }
    }
}

public class Timer {
    private static enum long YIELD_TIME = 1000;
    private TickDuration startTime;

    public void start() {
        startTime = TickDuration.currSystemTick();
    }

    public alias reset = start;
    public alias restart = start;

    public TickDuration getTime() {
        return TickDuration.currSystemTick() - startTime;
    }

    public void waitUntil(TickDuration time) {
        Duration duration = hnsecs(time.hnsecs() - getTime().hnsecs() - YIELD_TIME);
        if (!duration.isNegative()) {
            Thread.sleep(duration);
        }
        while (getTime() < time) {
            Thread.yield();
        }
    }
}
