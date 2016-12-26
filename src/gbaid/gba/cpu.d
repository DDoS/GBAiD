module gbaid.gba.cpu;

import std.algorithm.searching : count;
import std.string : format;
import std.traits : hasUDA;

import gbaid.util;

import gbaid.gba.memory;
import gbaid.gba.arm;
import gbaid.gba.thumb;

private enum uint AVERAGE_CPI = 2;

public class ARM7TDMI {
    private MemoryBus* memory;
    private Registers registers;
    private bool haltSignal = false;
    private bool irqSignal = false;
    private int instruction;
    private int decoded;

    public this(MemoryBus* memory, uint entryPointAddress = 0x0) {
        this.memory = memory;
        // Initialize to ARM in system mode
        registers.setFlag(CPSRFlag.T, Set.ARM);
        registers.setMode(Mode.SYSTEM);
        // Initialize the stack pointers
        registers.set(Mode.SUPERVISOR, Register.SP, 0x3007FE0);
        registers.set(Mode.IRQ, Register.SP, 0x3007FA0);
        registers.set(Mode.USER, Register.SP, 0x3007F00);
        // Set first instruction
        registers.setPC(entryPointAddress);
        // Branch to instruction
        branch();
    }

    public void halt(bool state) {
        haltSignal = state;
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

    public size_t emulate(size_t cycles) {
        debug (outputInstructions) {
            scope (failure) {
                registers.dumpInstructions();
                registers.dumpRegisters();
            }
        }
        // Discard all the cycles if halted
        if (haltSignal) {
            return 0;
        }
        // Otherwise use up 2 cycles per instruction
        while (cycles >= AVERAGE_CPI) {
            // Take the cycles for the instruction
            cycles -= AVERAGE_CPI;
            // Check for an IRQ
            if (irqSignal && !registers.getFlag(CPSRFlag.I)) {
                // Branch to the handler
                branchIRQ();
                continue;
            }
            // Fetch the next instruction in the pipeline
            int nextInstruction = fetchInstruction();
            // Decode the second instruction in the pipeline
            int nextDecoded = instruction;
            instruction = nextInstruction;
            // Execute the last instruction in the pipeline
            final switch (registers.instructionSet) {
                case Set.ARM:
                    executeARMInstruction(&registers, memory, decoded);
                    break;
                case Set.THUMB:
                    executeTHUMBInstruction(&registers, memory, decoded);
                    break;
            }
            decoded = nextDecoded;
            // Then go to the next instruction
            if (registers.wasPCModified()) {
                branch();
            } else {
                registers.incrementPC();
            }
            // Discard all the cycles if the instruction caused a halt
            if (haltSignal) {
                return 0;
            }
        }
        return cycles;
    }

    private void branch() {
        // fetch first instruction
        instruction = fetchInstruction();
        registers.incrementPC();
        // fetch second and decode first
        int nextInstruction = fetchInstruction();
        decoded = instruction;
        instruction = nextInstruction;
        registers.incrementPC();
    }

    private int fetchInstruction() {
        final switch (registers.instructionSet) {
            case Set.ARM:
                return memory.get!int(registers.getPC());
            case Set.THUMB:
                return memory.get!short(registers.getPC()).mirror();
        }
    }

    private void branchIRQ() {
        registers.set(Mode.IRQ, Register.SPSR, registers.getCPSR());
        registers.set(Mode.IRQ, Register.LR, registers.getExecutedPC() + 4);
        registers.setPC(0x18);
        registers.setFlag(CPSRFlag.I, 1);
        registers.setFlag(CPSRFlag.T, Set.ARM);
        registers.setMode(Mode.IRQ);
        branch();
    }
}

public struct Registers {
    private int[37] registers;
    private Mode _mode;
    private Set _set;
    private bool modifiedPC = false;

    @property public Mode mode() {
        return _mode;
    }

    @property public Set instructionSet() {
        return _set;
    }

    public int get(int register) {
        return get(_mode, register);
    }

    public int get(Mode mode, int register) {
        return registers[getRegisterIndex(mode, register)];
    }

    public int getPC() {
        return registers[Register.PC];
    }

    public int getCPSR() {
        return registers[Register.CPSR];
    }

    public void set(int register, int value) {
        set(_mode, register, value);
    }

    public void set(Mode mode, int register, int value) {
        registers[getRegisterIndex(mode, register)] = value;
        if (register == Register.PC) {
            modifiedPC = true;
        } else if (register == Register.CPSR) {
            _mode = cast(Mode) value.getBits(0, 4);
            _set = cast(Set) value.getBit(CPSRFlag.T);
        }
    }

    public void setPC(int value) {
        registers[Register.PC] = value;
        modifiedPC = true;
    }

    public void setCPSR(int value) {
        registers[Register.CPSR] = value;
        _mode = cast(Mode) value.getBits(0, 4);
        _set = cast(Set) value.getBit(CPSRFlag.T);
    }

    public int getFlag(CPSRFlag flag) {
        return registers[Register.CPSR].getBit(flag);
    }

    public void setFlag(CPSRFlag flag, int b) {
        registers[Register.CPSR].setBit(flag, b);
        if (flag == CPSRFlag.T) {
            _set = cast(Set) b;
        }
    }

    public void setAPSRFlags(int n, int z) {
        registers[Register.CPSR].setBits(30, 31, z | n << 1);
    }

    public void setAPSRFlags(int n, int z, int c) {
        registers[Register.CPSR].setBits(29, 31, c | z << 1 | n << 2);
    }

    public void setAPSRFlags(int n, int z, int c, int v) {
        registers[Register.CPSR].setBits(28, 31, v | c << 1 | z << 2 | n << 3);
    }

    public void setMode(Mode mode) {
        registers[Register.CPSR].setBits(0, 4, mode);
        _mode = mode;
    }

    public void incrementPC() {
        final switch (_set) {
            case Set.ARM:
                registers[Register.PC] = (registers[Register.PC] & ~3) + 4;
                break;
            case Set.THUMB:
                registers[Register.PC] = (registers[Register.PC] & ~1) + 2;
                break;
        }
    }

    public int getExecutedPC() {
        final switch (_set) {
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
                        carry = op.getBit(32 - shift);
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
                        carry = op.getBit(32 - shift);
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
                        carry = op.getBit(shift - 1);
                        return op >>> shift;
                    } else if (shift == 32) {
                        carry = op.getBit(31);
                        return 0;
                    } else {
                        carry = 0;
                        return 0;
                    }
                } else {
                    if (shift == 0) {
                        carry = op.getBit(31);
                        return 0;
                    } else {
                        carry = op.getBit(shift - 1);
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
                        carry = op.getBit(shift - 1);
                        return op >> shift;
                    } else {
                        carry = op.getBit(31);
                        return carry ? 0xFFFFFFFF : 0;
                    }
                } else {
                    if (shift == 0) {
                        carry = op.getBit(31);
                        return carry ? 0xFFFFFFFF : 0;
                    } else {
                        carry = op.getBit(shift - 1);
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
                        carry = op.getBit(shift - 1);
                        return op.rotateRight(shift);
                    } else {
                        carry = op.getBit(31);
                        return op;
                    }
                } else {
                    if (shift == 0) {
                        // RRX
                        carry = op & 0b1;
                        return getFlag(CPSRFlag.C) << 31 | op >>> 1;
                    } else {
                        carry = op.getBit(shift - 1);
                        return op.rotateRight(shift);
                    }
                }
        }
    }

    public bool checkCondition(int condition) {
        int flags = registers[Register.CPSR];
        final switch (condition) {
            case 0x0:
                // EQ
                return flags.checkBit(CPSRFlag.Z);
            case 0x1:
                // NE
                return !flags.checkBit(CPSRFlag.Z);
            case 0x2:
                // CS/HS
                return flags.checkBit(CPSRFlag.C);
            case 0x3:
                // CC/LO
                return !flags.checkBit(CPSRFlag.C);
            case 0x4:
                // MI
                return flags.checkBit(CPSRFlag.N);
            case 0x5:
                // PL
                return !flags.checkBit(CPSRFlag.N);
            case 0x6:
                // VS
                return flags.checkBit(CPSRFlag.V);
            case 0x7:
                // VC
                return !flags.checkBit(CPSRFlag.V);
            case 0x8:
                // HI
                return flags.checkBit(CPSRFlag.C) && !flags.checkBit(CPSRFlag.Z);
            case 0x9:
                // LS
                return !flags.checkBit(CPSRFlag.C) || flags.checkBit(CPSRFlag.Z);
            case 0xA:
                // GE
                return flags.checkBit(CPSRFlag.N) == flags.checkBit(CPSRFlag.V);
            case 0xB:
                // LT
                return flags.checkBit(CPSRFlag.N) != flags.checkBit(CPSRFlag.V);
            case 0xC:
                // GT
                return !flags.checkBit(CPSRFlag.Z) && flags.checkBit(CPSRFlag.N) == flags.checkBit(CPSRFlag.V);
            case 0xD:
                // LE
                return flags.checkBit(CPSRFlag.Z) || flags.checkBit(CPSRFlag.N) != flags.checkBit(CPSRFlag.V);
            case 0xE:
                // AL
                return true;
            case 0xF:
                // NV
                return false;
        }
    }

    private static int getRegisterIndex(Mode mode, int register) {
        if (register < 8) {
            return register;
        }
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
        private Executor[queueMaxSize] lastInstructions;
        private uint queueSize = 0;
        private uint index = 0;

        public void logInstruction(int code, string mnemonic) {
            logInstruction(getExecutedPC(), code, mnemonic);
        }

        public void logInstruction(int address, int code, string mnemonic) {
            if (_set == Set.THUMB) {
                code &= 0xFFFF;
            }
            lastInstructions[index].mode = _mode;
            lastInstructions[index].address = address;
            lastInstructions[index].code = code;
            lastInstructions[index].mnemonic = mnemonic;
            lastInstructions[index].set = _set;
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

        private static struct Executor {
            private Mode mode;
            private int address;
            private int code;
            private string mnemonic;
            private Set set;
        }
    }
}

public alias Executor = void function(Registers*, MemoryBus*, int);

public Executor[] createTable(alias nullInstruction)(int bitCount) {
    auto table = new Executor[1 << bitCount];
    foreach (i, t; table) {
        table[i] = &nullInstruction;
    }
    return table;
}

public void addSubTable(string bits, alias instructionFamily, alias nullInstruction)(Executor[] table) {
    // Generate the subtable
    auto subTable = createTable!(instructionFamily, bits.count('t'), nullInstruction)();
    // Check that there are as many bits as in the table length
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
            if (subTable[tableBitValue] is &nullInstruction) {
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
            if (table[index] !is &nullInstruction) {
                throw new Exception(format("The entry at index %d in sub-table with bits \"%s\" conflicts with "
                        ~ "a previously added one", tableBitValue, bits));
            }
            table[index] = subTable[tableBitValue];
        }
    }
}

private Executor[] createTable(alias instructionFamily, int bitCount, alias unsupported, int index = 0)() {
    static if (bitCount == 0) {
        return [&instructionFamily!()];
    } else static if (index < (1 << bitCount)) {
        static if (hasUDA!(instructionFamily!index, "unsupported")) {
            return [&unsupported] ~ createTable!(instructionFamily, bitCount, unsupported, index + 1)();
        } else {
            return [&instructionFamily!index] ~ createTable!(instructionFamily, bitCount, unsupported, index + 1)();
        }
    } else {
        return [];
    }
}

public int rotateRead(int address, int value) {
    return value.rotateRight((address & 3) << 3);
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
