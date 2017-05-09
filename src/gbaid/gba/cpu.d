module gbaid.gba.cpu;

import std.array : array;
import std.algorithm.searching : count;
import std.algorithm.iteration : splitter;
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

    public bool halted() {
        return irqSignal;
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
            // "Decode" the second instruction in the pipeline (we don't need to actually do anything)
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
        registers.setSPSR(Mode.IRQ, registers.getCPSR());
        registers.set(Mode.IRQ, Register.LR, registers.getExecutedPC() + 4);
        registers.setPC(0x18);
        registers.setFlag(CPSRFlag.I, 1);
        registers.setFlag(CPSRFlag.T, Set.ARM);
        registers.setMode(Mode.IRQ);
        branch();
    }
}

public struct Registers {
    private immutable size_t[REGISTER_LOOKUP_LENGTH] registerIndices = createRegisterLookupTable();
    private int[REGISTER_COUNT] registers;
    private int cpsrRegister;
    private int[1 << MODE_BITS] spsrRegisters;
    private bool modifiedPC = false;

    @property public Mode mode() {
        return cast(Mode) (cpsrRegister & 0x1F);
    }

    @property public Set instructionSet() {
        return cast(Set) cpsrRegister.getBit(CPSRFlag.T);
    }

    public int get(int register) {
        return get(mode, register);
    }

    public int get(Mode mode, int register) {
        return registers[registerIndices[(mode & 0xF) << REGISTER_BITS | register]];
    }

    public int getPC() {
        return registers[Register.PC];
    }

    public int getCPSR() {
        return cpsrRegister;
    }

    public int getSPSR() {
        return getSPSR(mode);
    }

    public int getSPSR(Mode mode) {
        if (mode == Mode.SYSTEM || mode == Mode.USER) {
            throw new Exception("The SPSR register does not exist in the system and user modes");
        }
        return spsrRegisters[mode & 0xF];
    }

    public void set(int register, int value) {
        set(mode, register, value);
    }

    public void set(Mode mode, int register, int value) {
        registers[registerIndices[(mode & 0xF) << REGISTER_BITS | register]] = value;
        if (register == Register.PC) {
            modifiedPC = true;
        }
    }

    public void setPC(int value) {
        registers[Register.PC] = value;
        modifiedPC = true;
    }

    public void setCPSR(int value) {
        cpsrRegister = value;
    }

    public void setSPSR(int value) {
        setSPSR(mode, value);
    }

    public void setSPSR(Mode mode, int value) {
        if (mode == Mode.SYSTEM || mode == Mode.USER) {
            throw new Exception("The SPSR register does not exist in the system and user modes");
        }
        spsrRegisters[mode & 0xF] = value;
    }

    public int getFlag(CPSRFlag flag) {
        return cpsrRegister.getBit(flag);
    }

    public void setFlag(CPSRFlag flag, int b) {
        cpsrRegister.setBit(flag, b);
    }

    public template setApsrFlags(string bits) {
        mixin(genApsrSetterSignature(bits.count(',')) ~ genApsrSetterImpl(array(bits.splitter(","))));
    }

    public void setMode(Mode mode) {
        cpsrRegister.setBits(0, 4, mode);
    }

    public void incrementPC() {
        final switch (instructionSet) {
            case Set.ARM:
                registers[Register.PC] = (registers[Register.PC] & ~3) + 4;
                break;
            case Set.THUMB:
                registers[Register.PC] = (registers[Register.PC] & ~1) + 2;
                break;
        }
    }

    public int getExecutedPC() {
        final switch (instructionSet) {
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

    public int applyShift(bool registerShift)(int shiftType, ubyte shift, int op, out int carry) {
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
        final switch (condition) {
            case 0x0:
                // EQ
                return cpsrRegister.checkBit(CPSRFlag.Z);
            case 0x1:
                // NE
                return !cpsrRegister.checkBit(CPSRFlag.Z);
            case 0x2:
                // CS/HS
                return cpsrRegister.checkBit(CPSRFlag.C);
            case 0x3:
                // CC/LO
                return !cpsrRegister.checkBit(CPSRFlag.C);
            case 0x4:
                // MI
                return cpsrRegister.checkBit(CPSRFlag.N);
            case 0x5:
                // PL
                return !cpsrRegister.checkBit(CPSRFlag.N);
            case 0x6:
                // VS
                return cpsrRegister.checkBit(CPSRFlag.V);
            case 0x7:
                // VC
                return !cpsrRegister.checkBit(CPSRFlag.V);
            case 0x8:
                // HI
                return cpsrRegister.checkBit(CPSRFlag.C) && !cpsrRegister.checkBit(CPSRFlag.Z);
            case 0x9:
                // LS
                return !cpsrRegister.checkBit(CPSRFlag.C) || cpsrRegister.checkBit(CPSRFlag.Z);
            case 0xA:
                // GE
                return cpsrRegister.checkBit(CPSRFlag.N) == cpsrRegister.checkBit(CPSRFlag.V);
            case 0xB:
                // LT
                return cpsrRegister.checkBit(CPSRFlag.N) != cpsrRegister.checkBit(CPSRFlag.V);
            case 0xC:
                // GT
                return !cpsrRegister.checkBit(CPSRFlag.Z)
                        && cpsrRegister.checkBit(CPSRFlag.N) == cpsrRegister.checkBit(CPSRFlag.V);
            case 0xD:
                // LE
                return cpsrRegister.checkBit(CPSRFlag.Z)
                    || cpsrRegister.checkBit(CPSRFlag.N) != cpsrRegister.checkBit(CPSRFlag.V);
            case 0xE:
                // AL
                return true;
            case 0xF:
                // NV
                return false;
        }
    }

    debug (outputInstructions) {
        import std.stdio : writeln, writef, writefln;

        private enum size_t CPU_LOG_SIZE = 32;
        private CpuState[CPU_LOG_SIZE] cpuLog;
        private size_t logSize = 0;
        private size_t index = 0;

        public void logInstruction(int code, string mnemonic) {
            logInstruction(getExecutedPC(), code, mnemonic);
        }

        public void logInstruction(int address, int code, string mnemonic) {
            if (instructionSet == Set.THUMB) {
                code &= 0xFFFF;
            }
            cpuLog[index].mode = mode;
            cpuLog[index].address = address;
            cpuLog[index].code = code;
            cpuLog[index].mnemonic = mnemonic;
            cpuLog[index].set = instructionSet;
            foreach (i; 0 .. 16) {
                cpuLog[index].registers[i] = get(i);
            }
            cpuLog[index].cpsrRegister = cpsrRegister;
            if (mode != Mode.SYSTEM && mode != Mode.USER) {
                cpuLog[index].spsrRegister = getSPSR();
            }
            index = (index + 1) % CPU_LOG_SIZE;
            if (logSize < CPU_LOG_SIZE) {
                logSize++;
            }
        }

        public void dumpInstructions() {
            dumpInstructions(logSize);
        }

        public void dumpInstructions(size_t amount) {
            amount = amount > logSize ? logSize : amount;
            auto start = (logSize < CPU_LOG_SIZE ? 0 : index) + logSize - amount;
            if (amount > 1) {
                writefln("Dumping last %s instructions executed:", amount);
            }
            foreach (i; 0 .. amount) {
                cpuLog[(i + start) % CPU_LOG_SIZE].dump();
            }
        }

        private static struct CpuState {
            private Mode mode;
            private int address;
            private int code;
            private string mnemonic;
            private Set set;
            private int[16] registers;
            private int cpsrRegister;
            private int spsrRegister;

            private void dump() {
                writefln("%s", mode);
                // Dump register values
                foreach (i; 0 .. 4) {
                    writef("%-4s", cast(Register) (i * 4));
                    foreach (j; 0 .. 4) {
                        writef(" %08X", registers[i * 4 + j]);
                    }
                    writeln();
                }
                writef("CPSR %08X", cpsrRegister);
                if (mode != Mode.SYSTEM && mode != Mode.USER) {
                    writef(", SPSR %08X", spsrRegister);
                }
                writeln();
                // Dump instruction
                final switch (set) {
                    case Set.ARM:
                        writefln("%08X: %08X %s", address, code, mnemonic);
                        break;
                    case Set.THUMB:
                        writefln("%08X: %08X     %s", address, code, mnemonic);
                        break;
                }
                writeln();
            }
        }
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
}

public enum CPSRFlag {
    N = 31,
    Z = 30,
    C = 29,
    V = 28,
    I = 7,
    F = 6,
    T = 5,
}

private enum REGISTER_COUNT = 31;
private enum REGISTER_BITS = 4;
private enum MODE_BITS = 4;
private enum REGISTER_LOOKUP_LENGTH = 1 << (MODE_BITS + REGISTER_BITS);

private size_t[] createRegisterLookupTable() {
    size_t[] table;
    table.length = REGISTER_LOOKUP_LENGTH;
    // For all modes: R0 - R15 = 0 - 15
    void setIndex(int mode, int register, size_t i) {
        table[(mode & 0xF) << REGISTER_BITS | register] = i;
    }
    size_t i = void;
    foreach (mode; 0 .. 1 << MODE_BITS) {
        i = 0;
        foreach (register; 0 .. 1 << REGISTER_BITS) {
            setIndex(mode, register, i++);
        }
    }
    // Except: R8_fiq - R14_fiq
    setIndex(Mode.FIQ, 8, i++);
    setIndex(Mode.FIQ, 9, i++);
    setIndex(Mode.FIQ, 10, i++);
    setIndex(Mode.FIQ, 11, i++);
    setIndex(Mode.FIQ, 12, i++);
    setIndex(Mode.FIQ, 13, i++);
    setIndex(Mode.FIQ, 14, i++);
    // Except: R13_svc - R14_svc
    setIndex(Mode.SUPERVISOR, 13, i++);
    setIndex(Mode.SUPERVISOR, 14, i++);
    // Except: R13_abt - R14_abt
    setIndex(Mode.ABORT, 13, i++);
    setIndex(Mode.ABORT, 14, i++);
    // Except: R13_irq - R14_irq
    setIndex(Mode.IRQ, 13, i++);
    setIndex(Mode.IRQ, 14, i++);
    // Except: R13_und - R14_und
    setIndex(Mode.UNDEFINED, 13, i++);
    setIndex(Mode.UNDEFINED, 14, i++);
    return table;
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

private string genApsrSetterSignature(size_t argCount) {
    argCount += 1;
    auto signature = "public void setApsrFlags(";
    foreach (i; 0 .. argCount) {
        signature ~= format("int i%d", i);
        if (i + 1 < argCount) {
            signature ~= ", ";
        }
    }
    return signature ~ ") ";
}

private string genApsrSetterImpl(string[] flagSets) {
    int mask = 0;
    foreach (flagSet; flagSets) {
        foreach (flag; flagSet) {
            int bitMask = getApsrFlagMask(flag);
            if (mask & bitMask) {
                throw new Exception("Duplicate flag: " ~ flag);
            }
            mask |= bitMask;
        }
    }

    auto code = "auto newFlags = ";
    foreach (int i, flagSet; flagSets) {
        code ~= genApsrSetterImplExtractBits(i, flagSet);
        if (i + 1 < flagSets.length) {
            code ~= " | ";
        }
    }
    code ~= ";\n";
    code ~= format("    cpsrRegister = cpsrRegister & 0x%08X | (newFlags << 28);\n",
            ~(mask << 28));
    return format("{\n    %s}", code);
}

private string genApsrSetterImplExtractBits(int argIndex, string flagSet) {
    int[] shifts;
    int[] masks;
    foreach (i, flag; flagSet) {
        auto flagIndex = getApsrFlagIndex(flag);
        if (flagIndex < 0) {
            continue;
        }
        auto shift = cast(int) (flagSet.length - 1 - i) - flagIndex;
        auto mask = 1 << flagIndex;
        if (shifts.length > 0 && shifts[$ - 1] == shift) {
            masks[$ - 1] |= mask;
        } else {
            shifts ~= shift;
            masks ~= mask;
        }
    }

    auto code = "";
    foreach (i, shift; shifts) {
        string shiftOp = void;
        if (shift > 0) {
            shiftOp = format(" >>> %d", shift);
        } else if (shift < 0) {
            shiftOp = format(" << %d", -shift);
        } else {
            shiftOp = "";
        }
        code ~= format("(i%d%s) & 0b%04b", argIndex, shiftOp, masks[i]);
        if (i < shifts.length - 1) {
            code ~= " | ";
        }
    }
    return code;
}

private int getApsrFlagMask(char flag) {
    auto bitIndex = getApsrFlagIndex(flag);
    return bitIndex < 0 ? 0 : (1 << bitIndex);
}

private int getApsrFlagIndex(char flag) {
    switch (flag) {
        case 'N':
            return 3;
        case 'Z':
            return 2;
        case 'C':
            return 1;
        case 'V':
            return 0;
        case '0':
            return -1;
        default:
            throw new Exception("Unknown flag: " ~ flag);
    }
}
