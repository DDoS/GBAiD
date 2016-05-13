module gbaid.cpu;

import core.thread;
import core.sync.mutex;
import core.sync.condition;

import std.stdio;
import std.conv;
import std.string;
import std.traits;

import gbaid.memory;
import gbaid.arm, gbaid.thumb;
import gbaid.util;

public class ARM7TDMI {
    private alias HaltTask = bool delegate();
    private Memory memory;
    private uint entryPointAddress = 0x0;
    private HaltTask haltTask;
    private Thread thread;
    private bool running = false;
    private Registers registers;
    private bool haltSignal = false;
    private bool irqSignal = false;
    private int instruction;
    private int decoded;

    public this(Memory memory) {
        this.memory = memory;
        registers = new Registers();
    }

    public void setEntryPointAddress(uint entryPointAddress) {
        this.entryPointAddress = entryPointAddress;
    }

    public void setHaltTask(HaltTask haltTask) {
        this.haltTask = haltTask;
    }

    public void start() {
        if (thread is null) {
            thread = new Thread(&run);
            thread.name = "ARM CPU";
            running = true;
            thread.start();
        }
    }

    public void stop() {
        if (thread !is null) {
            running = false;
            if (isHalted()) {
                halt(false);
            }
            thread = null;
        }
    }

    public bool isRunning() {
        return running;
    }

    public void halt(bool state) {
        haltSignal = state;
    }

    public bool isHalted() {
        return haltSignal;
    }

    public void irq(bool state) {
        irqSignal = state;
    }

    public bool inIRQ() {
        return irqSignal;
    }

    public int getProgramCounter() {
        return registers.getExecutedPC();
    }

    public int getPreFetch() {
        return instruction;
    }

    public int getNextInstruction() {
        return decoded;
    }

    private void run() {
        try {
            // initialize the stack pointers
            registers.set(Mode.SUPERVISOR, Register.SP, 0x3007FE0);
            registers.set(Mode.IRQ, Register.SP, 0x3007FA0);
            registers.set(Mode.USER, Register.SP, 0x3007F00);
            // initialize to ARM in system mode
            registers.setFlag(CPSRFlag.T, Set.ARM);
            registers.setMode(Mode.SYSTEM);
            // set first instruction
            registers.set(Register.PC, entryPointAddress);
            // branch to instruction
            branch();
            // start ticking
            while (running) {
                if (irqSignal) {
                    branchIRQ();
                }
                tick();
                //registers.dumpInstructions(1);
                while (haltSignal) {
                    if (!haltTask()) {
                        Thread.yield();
                    }
                }
                if (registers.wasPCModified()) {
                    branch();
                } else {
                    registers.incrementPC();
                }
            }
        } catch (Exception ex) {
            writeln("ARM CPU encountered an exception, thread stopping...");
            writeln("Exception: ", ex.msg);
            debug (outputInstructions) {
                registers.dumpInstructions();
                registers.dumpRegisters();
            }
        }
    }

    private void branch() {
        // fetch first instruction
        instruction = fetchInstruction();
        registers.incrementPC();
        // fetch second and decode first
        int nextInstruction = fetchInstruction();
        decoded = decodeInstruction(instruction);
        instruction = nextInstruction;
        registers.incrementPC();
    }

    private void tick() {
        // fetch
        int nextInstruction = fetchInstruction();
        // decode
        int nextDecoded = decodeInstruction(instruction);
        instruction = nextInstruction;
        // execute
        executeInstruction(decoded);
        decoded = nextDecoded;
    }

    private int fetchInstruction() {
        final switch (registers.getSet()) {
            case Set.ARM:
                return memory.getInt(registers.get(Register.PC));
            case Set.THUMB:
                return mirror(memory.getShort(registers.get(Register.PC)));
        }
    }

    private int decodeInstruction(int instruction) {
        // Does nothing since this only helps if we execute fetch/decode and execute in parallel
        return instruction;
    }

    private void executeInstruction(int instruction) {
        final switch (registers.getSet()) {
            case Set.ARM:
                executeARMInstruction(registers, memory, instruction);
                break;
            case Set.THUMB:
                executeTHUMBInstruction(registers, memory, instruction);
                break;
        }
    }

    private void branchIRQ() {
        if (registers.getFlag(CPSRFlag.I)) {
            return;
        }
        registers.set(Mode.IRQ, Register.SPSR, registers.get(Register.CPSR));
        registers.set(Mode.IRQ, Register.LR, registers.getExecutedPC() + 4);
        registers.set(Register.PC, 0x18);
        registers.setFlag(CPSRFlag.I, 1);
        registers.setFlag(CPSRFlag.T, Set.ARM);
        registers.setMode(Mode.IRQ);
        branch();
    }
}

public class Registers {
    private int[37] registers = new int[37];
    private bool modifiedPC = false;

    public int get(int register) {
        return get(getMode(), register);
    }

    public int get(Mode mode, int register) {
        return registers[getRegisterIndex(mode, register)];
    }

    public void set(int register, int value) {
        set(getMode(), register, value);
    }

    public void set(Mode mode, int register, int value) {
        if (register == Register.PC) {
            modifiedPC = true;
        }
        registers[getRegisterIndex(mode, register)] = value;
    }

    public int getFlag(CPSRFlag flag) {
        return getBit(registers[Register.CPSR], flag);
    }

    public void setFlag(CPSRFlag flag, int b) {
        setBit(registers[Register.CPSR], flag, b);
    }

    public void setAPSRFlags(int n, int z) {
        setBits(registers[Register.CPSR], 30, 31, z | n << 1);
    }

    public void setAPSRFlags(int n, int z, int c) {
        setBits(registers[Register.CPSR], 29, 31, c | z << 1 | n << 2);
    }

    public void setAPSRFlags(int n, int z, int c, int v) {
        setBits(registers[Register.CPSR], 28, 31, v | c << 1 | z << 2 | n << 3);
    }

    public Mode getMode() {
        return cast(Mode) (registers[Register.CPSR] & 0b11111);
    }

    public void setMode(Mode mode) {
        setBits(registers[Register.CPSR], 0, 4, mode);
    }

    public Set getSet() {
        return cast(Set) registers[Register.CPSR].getBit(5);
    }

    public void incrementPC() {
        final switch (getSet()) {
            case Set.ARM:
                registers[Register.PC] = (registers[Register.PC] & ~3) + 4;
                break;
            case Set.THUMB:
                registers[Register.PC] = (registers[Register.PC] & ~1) + 2;
                break;
        }
    }

    public int getExecutedPC() {
        final switch (getSet()) {
            case Set.ARM:
                return registers[Register.PC] - 8;
            case Set.THUMB:
                return registers[Register.PC] - 4;
        }
    }

    public bool wasPCModified() {
        auto value = modifiedPC;
        modifiedPC = false;
        return value;
    }

    public int applyShift(bool registerShift)(int shiftType, int shift, int op, out int carry) {
        final switch (shiftType) {
            // LSL
            case 0:
                static if (registerShift) {
                    if (shift == 0) {
                        carry = getFlag(CPSRFlag.C);
                        return op;
                    } else if (shift < 32) {
                        carry = getBit(op, 32 - shift);
                        return op << shift;
                    } else if (shift == 32) {
                        carry = op & 0b1;
                        return 0;
                    } else {
                        carry = 0;
                        return 0;
                    }
                } else {
                    if (shift == 0) {
                        carry = getFlag(CPSRFlag.C);
                        return op;
                    } else {
                        carry = getBit(op, 32 - shift);
                        return op << shift;
                    }
                }
            // LSR
            case 1:
                static if (registerShift) {
                    if (shift == 0) {
                        carry = getFlag(CPSRFlag.C);
                        return op;
                    } else if (shift < 32) {
                        carry = getBit(op, shift - 1);
                        return op >>> shift;
                    } else if (shift == 32) {
                        carry = getBit(op, 31);
                        return 0;
                    } else {
                        carry = 0;
                        return 0;
                    }
                } else {
                    if (shift == 0) {
                        carry = getBit(op, 31);
                        return 0;
                    } else {
                        carry = getBit(op, shift - 1);
                        return op >>> shift;
                    }
                }
            // ASR
            case 2:
                static if (registerShift) {
                    if (shift == 0) {
                        carry = getFlag(CPSRFlag.C);
                        return op;
                    } else if (shift < 32) {
                        carry = getBit(op, shift - 1);
                        return op >> shift;
                    } else {
                        carry = getBit(op, 31);
                        return carry ? 0xFFFFFFFF : 0;
                    }
                } else {
                    if (shift == 0) {
                        carry = getBit(op, 31);
                        return carry ? 0xFFFFFFFF : 0;
                    } else {
                        carry = getBit(op, shift - 1);
                        return op >> shift;
                    }
                }
            // ROR
            case 3:
                static if (registerShift) {
                    if (shift == 0) {
                        carry = getFlag(CPSRFlag.C);
                        return op;
                    } else if (shift & 0b11111) {
                        shift &= 0b11111;
                        carry = getBit(op, shift - 1);
                        return rotateRight(op, shift);
                    } else {
                        carry = getBit(op, 31);
                        return op;
                    }
                } else {
                    if (shift == 0) {
                        // RRX
                        carry = op & 0b1;
                        return getFlag(CPSRFlag.C) << 31 | op >>> 1;
                    } else {
                        carry = getBit(op, shift - 1);
                        return rotateRight(op, shift);
                    }
                }
        }
    }

    public bool checkCondition(int condition) {
        int flags = registers[Register.CPSR];
        final switch (condition) {
            case 0x0:
                // EQ
                return checkBit(flags, CPSRFlag.Z);
            case 0x1:
                // NE
                return !checkBit(flags, CPSRFlag.Z);
            case 0x2:
                // CS/HS
                return checkBit(flags, CPSRFlag.C);
            case 0x3:
                // CC/LO
                return !checkBit(flags, CPSRFlag.C);
            case 0x4:
                // MI
                return checkBit(flags, CPSRFlag.N);
            case 0x5:
                // PL
                return !checkBit(flags, CPSRFlag.N);
            case 0x6:
                // VS
                return checkBit(flags, CPSRFlag.V);
            case 0x7:
                // VC
                return !checkBit(flags, CPSRFlag.V);
            case 0x8:
                // HI
                return checkBit(flags, CPSRFlag.C) && !checkBit(flags, CPSRFlag.Z);
            case 0x9:
                // LS
                return !checkBit(flags, CPSRFlag.C) || checkBit(flags, CPSRFlag.Z);
            case 0xA:
                // GE
                return checkBit(flags, CPSRFlag.N) == checkBit(flags, CPSRFlag.V);
            case 0xB:
                // LT
                return checkBit(flags, CPSRFlag.N) != checkBit(flags, CPSRFlag.V);
            case 0xC:
                // GT
                return !checkBit(flags, CPSRFlag.Z) && checkBit(flags, CPSRFlag.N) == checkBit(flags, CPSRFlag.V);
            case 0xD:
                // LE
                return checkBit(flags, CPSRFlag.Z) || checkBit(flags, CPSRFlag.N) != checkBit(flags, CPSRFlag.V);
            case 0xE:
                // AL
                return true;
            case 0xF:
                // NV
                return false;
        }
    }

    private int getRegisterIndex(Mode mode, int register) {
        /*
            R0 - R15: 0 - 15
            CPSR: 16
            R8_fiq - R14_fiq: 17 - 23
            SPSR_fiq = 24
            R13_svc - R14_svc = 25 - 26
            SPSR_svc = 27
            R13_abt - R14_abt = 28 - 29
            SPSR_abt = 30
            R13_irq - R14_irq = 31 - 32
            SPSR_irq = 33
            R13_und - R14_und = 34 - 35
            SPSR_und = 36
        */
        final switch (mode) with (Mode) {
            case USER:
            case SYSTEM:
                return register;
            case FIQ:
                switch (register) {
                    case 8: .. case 14:
                        return register + 9;
                    case 17:
                        return register + 7;
                    default:
                        return register;
                }
            case SUPERVISOR:
                switch (register) {
                    case 13: .. case 14:
                        return register + 12;
                    case 17:
                        return register + 10;
                    default:
                        return register;
                }
            case ABORT:
                switch (register) {
                    case 13: .. case 14:
                        return register + 15;
                    case 17:
                        return register + 13;
                    default:
                        return register;
                }
            case IRQ:
                switch (register) {
                    case 13: .. case 14:
                        return register + 18;
                    case 17:
                        return register + 16;
                    default:
                        return register;
                }
            case UNDEFINED:
                switch (register) {
                    case 13: .. case 14:
                        return register + 21;
                    case 17:
                        return register + 19;
                    default:
                        return register;
                }
        }
    }

    debug (outputInstructions) {
        private enum uint queueMaxSize = 1024;
        private Instruction[queueMaxSize] lastInstructions = new Instruction[queueMaxSize];
        private uint queueSize = 0;
        private uint index = 0;

        public void logInstruction(int code, string mnemonic) {
            logInstruction(getExecutedPC(), code, mnemonic);
        }

        public void logInstruction(int address, int code, string mnemonic) {
            Set set = getSet();
            if (set == Set.THUMB) {
                code &= 0xFFFF;
            }
            lastInstructions[index].mode = getMode();
            lastInstructions[index].address = address;
            lastInstructions[index].code = code;
            lastInstructions[index].mnemonic = mnemonic;
            lastInstructions[index].set = set;
            index = (index + 1) % queueMaxSize;
            if (queueSize < queueMaxSize) {
                queueSize++;
            }
        }

        public void dumpInstructions() {
            dumpInstructions(queueSize);
        }

        public void dumpInstructions(uint amount) {
            amount = amount > queueSize ? queueSize : amount;
            uint start = (queueSize < queueMaxSize ? 0 : index) + queueSize - amount;
            if (amount > 1) {
                writefln("Dumping last %s instructions executed:", amount);
            }
            foreach (uint i; 0 .. amount) {
                uint j = (i + start) % queueMaxSize;
                final switch (lastInstructions[j].set) {
                    case Set.ARM:
                        writefln("%-10s| %08x: %08x %s", lastInstructions[j].mode, lastInstructions[j].address, lastInstructions[j].code, lastInstructions[j].mnemonic);
                        break;
                    case Set.THUMB:
                        writefln("%-10s| %08x: %04x     %s", lastInstructions[j].mode, lastInstructions[j].address, lastInstructions[j].code, lastInstructions[j].mnemonic);
                        break;
                }
            }
        }

        public void dumpRegisters() {
            writefln("Dumping last known register states:");
            foreach (i; 0 .. 18) {
                writefln("%-4s: %08x", cast(Register) i, get(i));
            }
        }

        private static struct Instruction {
            private Mode mode;
            private int address;
            private int code;
            private string mnemonic;
            private Set set;
        }
    }
}

public void function(Registers, Memory, int)[] createTable(int bitCount,
        void function(Registers, Memory, int) nullInstruction) {
    auto table = new void function(Registers, Memory, int)[1 << bitCount];
    foreach (i, t; table) {
        table[i] = nullInstruction;
    }
    return table;
}

// TODO: more template conditions, use UFCS

public void function(Registers, Memory, int)[] genTable(alias instructionFamily, int bitCount,
        alias unsupported, int index = 0)() {
    static if (bitCount == 0) {
        return [&instructionFamily!()];
    } else static if (index < (1 << bitCount)) {
        static if (hasUDA!(instructionFamily!index, "unsupported")) {
            return [&unsupported] ~ genTable!(instructionFamily, bitCount, unsupported, index + 1)();
        } else {
            return [&instructionFamily!index] ~ genTable!(instructionFamily, bitCount, unsupported, index + 1)();
        }
    } else {
        return [];
    }
}

public void addSubTable(void function(Registers, Memory, int)[] table, string bits,
        void function(Registers, Memory, int)[] subTable, void function(Registers, Memory, int) nullInstruction) {
    int bitCount = cast(int) bits.length;
    if (1 << bitCount != table.length) {
        throw new Exception("Wrong number of bits");
    }
    // Count don't cares and table bits (and validate bit types)
    int dontCareCount = 0;
    int tableBitCount = 0;
    foreach (b; bits) {
        switch (b) {
            case '0':
            case '1':
                break;
            case 'd':
                dontCareCount++;
                break;
            case 't':
                tableBitCount++;
                break;
            default:
                throw new Exception("Unknown bit type: '" ~ b ~ "'");
        }
    }
    if (1 << tableBitCount != subTable.length) {
        throw new Exception("Wrong number of sub-table bits");
    }
    // Enumerate combinations generated by the bit string
    // 0 and 1 literals, d for don't care, t for table
    // Start with all the 1 literals, which won't change
    int fixed = 0;
    foreach (int i, b; bits) {
        if (b == '1') {
            fixed.setBit(bitCount - 1 - i, 1);
        }
    }
    // Now for every combination of don't cares create an
    // intermediary value, which is only missing table bits
    foreach (dontCareValue; 0 .. 1 << dontCareCount) {
        int intermediary = fixed;
        int dc = dontCareCount - 1;
        foreach (int i, b; bits) {
            if (b == 'd') {
                intermediary.setBit(bitCount - 1 - i, dontCareValue.getBit(dc));
                dc--;
            }
        }
        // Now for every combination of table bits create the
        // final value and assign the pointer in the table
        foreach (tableBitValue; 0 .. 1 << tableBitCount) {
            // Ignore null instructions
            if (subTable[tableBitValue] is nullInstruction) {
                continue;
            }
            int index = intermediary;
            int tc = tableBitCount - 1;
            foreach (int i, b; bits) {
                if (b == 't') {
                    index.setBit(bitCount - 1 - i, tableBitValue.getBit(tc));
                    tc--;
                }
            }
            // Check if there's a conflict first
            if (table[index] !is nullInstruction) {
                throw new Exception("The entry at index " ~ tableBitValue.to!string ~
                    " in sub-table with bits \"" ~ bits ~ "\" conflicts with a previously added one");
            }
            table[index] = subTable[tableBitValue];
        }
    }
}

public int rotateRead(int address, int value) {
    return rotateRight(value, (address & 3) << 3);
}

public int rotateRead(int address, short value) {
    return rotateRight(value & 0xFFFF, (address & 1) << 3);
}

public int rotateReadSigned(int address, short value) {
    return value >> ((address & 1) << 3);
}

public enum Set {
    ARM = 0,
    THUMB = 1
}

public enum Mode {
    USER = 16,
    FIQ = 17,
    IRQ = 18,
    SUPERVISOR = 19,
    ABORT = 23,
    UNDEFINED = 27,
    SYSTEM = 31
}

public enum Register {
    R0 = 0,
    R1 = 1,
    R2 = 2,
    R3 = 3,
    R4 = 4,
    R5 = 5,
    R6 = 6,
    R7 = 7,
    R8 = 8,
    R9 = 9,
    R10 = 10,
    R11 = 11,
    R12 = 12,
    SP = 13,
    LR = 14,
    PC = 15,
    CPSR = 16,
    SPSR = 17
}

public enum CPSRFlag {
    N = 31,
    Z = 30,
    C = 29,
    V = 28,
    Q = 27,
    I = 7,
    F = 6,
    T = 5,
}
