module gbaid.arm;

import core.thread;
import core.sync.mutex;
import core.sync.condition;

import std.stdio;
import std.conv;
import std.string;

import gbaid.memory;
import gbaid.util;

public class ARM7TDMI {
    private alias HaltTask = bool delegate();
    private Memory memory;
    private uint entryPointAddress = 0x0;
    private HaltTask haltTask;
    private Thread thread;
    private bool running = false;
    private int[37] registers = new int[37];
    private Mode mode = Mode.SYSTEM;
    private bool haltSignal = false;
    private bool irqSignal = false;
    private Pipeline armPipeline;
    private Pipeline thumbPipeline;
    private Pipeline pipeline;
    private int instruction;
    private int decoded;
    private bool branchSignal = false;

    public this(Memory memory) {
        this.memory = memory;
        armPipeline = new ARMPipeline();
        thumbPipeline = new THUMBPipeline();
        pipeline = armPipeline;
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
        return getRegister(Register.PC) - 2 * pipeline.getPCIncrement();
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
            setRegister(Mode.SUPERVISOR, Register.SP, 0x3007FE0);
            setRegister(Mode.IRQ, Register.SP, 0x3007FA0);
            setRegister(Mode.USER, Register.SP, 0x3007F00);
            // initialize to ARM in system mode
            setFlag(CPSRFlag.T, Set.ARM);
            setMode(Mode.SYSTEM);
            updateModeAndSet();
            // set first instruction
            setRegister(Register.PC, entryPointAddress);
            // branch to instruction
            branch();
            // start ticking
            while (running) {
                if (irqSignal) {
                    branchIRQ();
                }
                tick();
                while (haltSignal) {
                    if (!haltTask()) {
                        Thread.yield();
                    }
                }
                updateModeAndSet();
                if (branchSignal) {
                    branch();
                } else {
                    pipeline.incrementPC();
                }
            }
        } catch (Exception ex) {
            writeln("ARM CPU encountered an exception, thread stopping...");
            writeln("Exception: ", ex.msg);
            debug (outputInstructions) {
                dumpInstructions();
                dumpRegisters();
            }
        }
    }

    private void branch() {
        // fetch first instruction
        instruction = pipeline.fetch();
        pipeline.incrementPC();
        // fetch second and decode first
        int nextInstruction = pipeline.fetch();
        decoded = pipeline.decode(instruction);
        instruction = nextInstruction;
        pipeline.incrementPC();
        branchSignal = false;
    }

    private void tick() {
        // fetch
        int nextInstruction = pipeline.fetch();
        // decode
        int nextDecoded = pipeline.decode(instruction);
        instruction = nextInstruction;
        // execute
        pipeline.execute(decoded);
        decoded = nextDecoded;
    }

    private void updateModeAndSet() {
        mode = getMode();
        pipeline = getFlag(CPSRFlag.T) ? thumbPipeline : armPipeline;
    }

    private void branchIRQ() {
        if (getFlag(CPSRFlag.I)) {
            return;
        }
        setRegister(Mode.IRQ, Register.SPSR, getRegister(Register.CPSR));
        setFlag(CPSRFlag.I, 1);
        setFlag(CPSRFlag.T, Set.ARM);
        setRegister(Mode.IRQ, Register.LR, getRegister(Register.PC) - pipeline.getPCIncrement() * 2 + 4);
        setRegister(Register.PC, 0x18);
        setMode(Mode.IRQ);
        updateModeAndSet();
        branch();
    }

    private interface Pipeline {
        protected Set getSet();
        protected int fetch();
        protected int decode(int instruction);
        protected void execute(int instruction);
        protected uint getPCIncrement();
        protected void incrementPC();
    }

    private class ARMPipeline : Pipeline {
        private void delegate(int)[] dataProcessingInstructions;
        private void delegate(int)[] multiplyInstructions;
        private void delegate(int)[] singleDataTransferInstructions;
        private void delegate(int)[] halfwordAndSignedDataTransferInstructions;

        private this() {
            // Bits are I(1),OpCode(4),S(1)
            // where I is the immediate flag and S the set flags flag
            dataProcessingInstructions = [
                &registerOp2AND,  &registerOp2ANDS,  &registerOp2EOR,     &registerOp2EORS,
                &registerOp2SUB,  &registerOp2SUBS,  &registerOp2RSB,     &registerOp2RSBS,
                &registerOp2ADD,  &registerOp2ADDS,  &registerOp2ADC,     &registerOp2ADCS,
                &registerOp2SBC,  &registerOp2SBCS,  &registerOp2RSC,     &registerOp2RSCS,
                &cpsrRead,        &registerOp2TST,   &cpsrWriteRegister,  &registerOp2TEQ,
                &spsrRead,        &registerOp2CMP,   &spsrWriteRegister,  &registerOp2CMN,
                &registerOp2ORR,  &registerOp2ORRS,  &registerOp2MOV,     &registerOp2MOVS,
                &registerOp2BIC,  &registerOp2BICS,  &registerOp2MVN,     &registerOp2MVNS,
                &immediateOp2AND, &immediateOp2ANDS, &immediateOp2EOR,    &immediateOp2EORS,
                &immediateOp2SUB, &immediateOp2SUBS, &immediateOp2RSB,    &immediateOp2RSBS,
                &immediateOp2ADD, &immediateOp2ADDS, &immediateOp2ADC,    &immediateOp2ADCS,
                &immediateOp2SBC, &immediateOp2SBCS, &immediateOp2RSC,    &immediateOp2RSCS,
                &unsupported,     &immediateOp2TST,  &cpsrWriteImmediate, &immediateOp2TEQ,
                &unsupported,     &immediateOp2CMP,  &spsrWriteImmediate, &immediateOp2CMN,
                &immediateOp2ORR, &immediateOp2ORRS, &immediateOp2MOV,    &immediateOp2MOVS,
                &immediateOp2BIC, &immediateOp2BICS, &immediateOp2MVN,    &immediateOp2MVNS,
            ];
            // Bits are L(1),~U(1),A(1),S(1)
            // where L is the long flag, U is the unsigned flag, A is the accumulate flag and S is the set flags flag
            multiplyInstructions = [
                &multiplyMUL,   &multiplyMULS,   &multiplyMLA,   &multiplyMLAS,
                &unsupported,   &unsupported,    &unsupported,   &unsupported,
                &multiplyUMULL, &multiplyUMULLS, &multiplyUMLAL, &multiplyUMLALS,
                &multiplySMULL, &multiplySMULLS, &multiplySMLAL, &multiplySMLALS,
            ];

            // Bits are I(1),P(1),U(1),B(1),W(1),L(1)
            // where I is not immediate, P is pre-increment, U is up-increment, B is byte quantity, W is write back
            // and L is load
            string genSingleDataTransferInstructionTable() {
                auto s = "[";
                foreach (i; 0 .. 64) {
                    if (i % 4 == 0) {
                        s ~= "\n";
                    }
                    s ~= "&singleDataTransfer!(" ~ i.to!string ~ "),";
                }
                s ~= "\n]";
                return s;
            }

            mixin("singleDataTransferInstructions = " ~ genSingleDataTransferInstructionTable() ~ ";");

            // Bits are P(1),U(1),I(1),W(1),L(1),OpCode(2)
            // where P is pre-increment, U is up-increment, I is immediate, W is write back and L is load
            string getHalfwordAndSignedDataTransferInstructionTable() {
                auto s = "[";
                foreach (i; 0 .. 128) {
                    if (i % 4 == 0) {
                        s ~= "\n";
                    }
                    // If L, then there is no opCode for 0; otherwise only opCode for 1 exists
                    if (i.checkBit(2) ? i.getBits(0, 1) == 0 : i.getBits(0, 1) != 1) {
                        s ~= "&unsupported, ";
                    } else if (!i.checkBit(6) && i.checkBit(3)) {
                        // If post-increment, then write-back is always enabled and W should be 0
                        s ~= "&unsupported, ";
                    } else {
                        s ~= "&halfwordAndSignedDataTransfer!(" ~ i.to!string ~ "), ";
                    }
                }
                s ~= "\n]";
                return s;
            }

            mixin("halfwordAndSignedDataTransferInstructions = " ~ getHalfwordAndSignedDataTransferInstructionTable() ~ ";");
        }

        protected Set getSet() {
            return Set.ARM;
        }

        protected override int fetch() {
            return memory.getInt(getRegister(Register.PC));
        }

        protected override int decode(int instruction) {
            // Nothing to do
            return instruction;
        }

        protected override void execute(int instruction) {
            if (checkBits(instruction, 0b00001111111111111111111111010000, 0b00000001001011111111111100010000)) {
                branchAndExchange(instruction);
            } else if (checkBits(instruction, 0b00001111101100000000000000000000, 0b00000011001000000000000000000000)) {
                psrTransfer(instruction);
            } else if (checkBits(instruction, 0b00001111100100000000111111110000, 0b00000001000000000000000000000000)) {
                psrTransfer(instruction);
            } else if (checkBits(instruction, 0b00001110000000000000000000010000, 0b00000000000000000000000000000000)) {
                dataProcessing(instruction);
            } else if (checkBits(instruction, 0b00001110000000000000000010010000, 0b00000000000000000000000000010000)) {
                dataProcessing(instruction);
            } else if (checkBits(instruction, 0b00001110000000000000000000000000, 0b00000010000000000000000000000000)) {
                dataProcessing(instruction);
            } else if (checkBits(instruction, 0b00001111110000000000000011110000, 0b00000000000000000000000010010000)) {
                multiplyAndMultiplyAccumulate(instruction);
            } else if (checkBits(instruction, 0b00001111100000000000000011110000, 0b00000000100000000000000010010000)) {
                multiplyAndMultiplyAccumulate(instruction);
            } else if (checkBits(instruction, 0b00001111101100000000111111110000, 0b00000001000000000000000010010000)) {
                singleDataSwap(instruction);
            } else if (checkBits(instruction, 0b00001110010000000000111110010000, 0b00000000000000000000000010010000)) {
                halfwordAndSignedDataTransfer(instruction);
            } else if (checkBits(instruction, 0b00001110010000000000000010010000, 0b00000000010000000000000010010000)) {
                halfwordAndSignedDataTransfer(instruction);
            } else if (checkBits(instruction, 0b00001110000000000000000000000000, 0b00000100000000000000000000000000)) {
                singleDataTransfer(instruction);
            } else if (checkBits(instruction, 0b00001110000000000000000000010000, 0b00000110000000000000000000000000)) {
                singleDataTransfer(instruction);
            } else if (checkBits(instruction, 0b00001110000000000000000000010000, 0b00000110000000000000000000010000)) {
                undefined(instruction);
            } else if (checkBits(instruction, 0b00001110000000000000000000000000, 0b00001000000000000000000000000000)) {
                blockDataTransfer(instruction);
            } else if (checkBits(instruction, 0b00001110000000000000000000000000, 0b00001010000000000000000000000000)) {
                branchAndBranchWithLink(instruction);
            } else if (checkBits(instruction, 0b00001111000000000000000000000000, 0b00001111000000000000000000000000)) {
                softwareInterrupt(instruction);
            } else {
                unsupported(instruction);
            }
        }

        protected override uint getPCIncrement() {
            return 4;
        }

        protected override void incrementPC() {
            registers[Register.PC] = (registers[Register.PC] & ~3) + 4;
        }

        private void branchAndExchange(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "BX");
            int address = getRegister(instruction & 0xF);
            if (address & 0b1) { // TODO: check this condition
                setFlag(CPSRFlag.T, Set.THUMB);
            }
            setRegister(Register.PC, address & ~1);
        }

        private void branchAndBranchWithLink(int instruction) {
            int opCode = getBit(instruction, 24);
            if (opCode) {
                branchAndLink(instruction);
            } else {
                branch(instruction);
            }
        }

        private void branch(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "B");
            int offset = instruction & 0xFFFFFF;
            // sign extend the offset
            offset <<= 8;
            offset >>= 8;
            int pc = getRegister(Register.PC);
            setRegister(Register.PC, pc + offset * 4);
        }

        private void branchAndLink(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "BL");
            int offset = instruction & 0xFFFFFF;
            // sign extend the offset
            offset <<= 8;
            offset >>= 8;
            int pc = getRegister(Register.PC);
            setRegister(Register.LR, pc - 4);
            setRegister(Register.PC, pc + offset * 4);
        }

        private void setDataProcessingFlags(int rd, int res, int overflow, int carry) {
            int zero = res == 0;
            int negative = res < 0;
            if (rd == Register.PC) {
                setRegister(Register.CPSR, getRegister(Register.SPSR));
            } else {
                setAPSRFlags(negative, zero, carry, overflow);
            }
        }

        private mixin template decodeOp2Immediate() {
            // Decode
            int rn = getBits(instruction, 16, 19);
            int rd = getBits(instruction, 12, 15);
            int op1 = getRegister(rn);
            // Get op2
            int shift = getBits(instruction, 8, 11) * 2;
            int op2 = rotateRight(instruction & 0xFF, shift);
            int carry = shift == 0 ? getFlag(CPSRFlag.C) : getBit(op2, 31);
        }

        private mixin template decodeOp2Register() {
            // Decode
            int rn = getBits(instruction, 16, 19);
            int rd = getBits(instruction, 12, 15);
            int op1 = getRegister(rn);
            // Get op2
            int shiftSrc = getBit(instruction, 4);
            int shift = shiftSrc ? getRegister(getBits(instruction, 8, 11)) & 0xFF : getBits(instruction, 7, 11);
            int shiftType = getBits(instruction, 5, 6);
            int carry;
            int op2 = applyShift(shiftType, shift, cast(bool) shiftSrc, getRegister(instruction & 0b1111), carry);
        }

        private void dataProcessingAND(alias decodeOperands, bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "AND");
            mixin decodeOperands;
            // Operation
            int res = op1 & op2;
            setRegister(rd, res);
            // Flag updates
            static if (setFlags) {
                int overflow = getFlag(CPSRFlag.V);
                setDataProcessingFlags(rd, res, overflow, carry);
            }
        }

        private alias immediateOp2AND = dataProcessingAND!(decodeOp2Immediate, false);
        private alias immediateOp2ANDS = dataProcessingAND!(decodeOp2Immediate, true);
        private alias registerOp2AND = dataProcessingAND!(decodeOp2Register, false);
        private alias registerOp2ANDS = dataProcessingAND!(decodeOp2Register, true);

        private void dataProcessingEOR(alias decodeOperands, bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "EOR");
            mixin decodeOperands;
            // Operation
            int res = op1 ^ op2;
            setRegister(rd, res);
            // Flag updates
            static if (setFlags) {
                int overflow = getFlag(CPSRFlag.V);
                setDataProcessingFlags(rd, res, overflow, carry);
            }
        }

        private alias immediateOp2EOR = dataProcessingEOR!(decodeOp2Immediate, false);
        private alias immediateOp2EORS = dataProcessingEOR!(decodeOp2Immediate, true);
        private alias registerOp2EOR = dataProcessingEOR!(decodeOp2Register, false);
        private alias registerOp2EORS = dataProcessingEOR!(decodeOp2Register, true);

        private void dataProcessingSUB(alias decodeOperands, bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "SUB");
            mixin decodeOperands;
            // Operation
            int res = op1 - op2;
            setRegister(rd, res);
            // Flag updates
            static if (setFlags) {
                int overflow = overflowedSub(op1, op2, res);
                carry = !borrowedSub(op1, op2, res);
                setDataProcessingFlags(rd, res, overflow, carry);
            }
        }

        private alias immediateOp2SUB = dataProcessingSUB!(decodeOp2Immediate, false);
        private alias immediateOp2SUBS = dataProcessingSUB!(decodeOp2Immediate, true);
        private alias registerOp2SUB = dataProcessingSUB!(decodeOp2Register, false);
        private alias registerOp2SUBS = dataProcessingSUB!(decodeOp2Register, true);

        private void dataProcessingRSB(alias decodeOperands, bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "RSB");
            mixin decodeOperands;
            // Operation
            int res = op2 - op1;
            setRegister(rd, res);
            // Flag updates
            static if (setFlags) {
                int overflow = overflowedSub(op2, op1, res);
                carry = !borrowedSub(op2, op1, res);
                setDataProcessingFlags(rd, res, overflow, carry);
            }
        }

        private alias immediateOp2RSB = dataProcessingRSB!(decodeOp2Immediate, false);
        private alias immediateOp2RSBS = dataProcessingRSB!(decodeOp2Immediate, true);
        private alias registerOp2RSB = dataProcessingRSB!(decodeOp2Register, false);
        private alias registerOp2RSBS = dataProcessingRSB!(decodeOp2Register, true);

        private void dataProcessingADD(alias decodeOperands, bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "ADD");
            mixin decodeOperands;
            // Operation
            int res = op1 + op2;
            setRegister(rd, res);
            // Flag updates
            static if (setFlags) {
                int overflow = overflowedAdd(op1, op2, res);
                carry = carriedAdd(op1, op2, res);
                setDataProcessingFlags(rd, res, overflow, carry);
            }
        }

        private alias immediateOp2ADD = dataProcessingADD!(decodeOp2Immediate, false);
        private alias immediateOp2ADDS = dataProcessingADD!(decodeOp2Immediate, true);
        private alias registerOp2ADD = dataProcessingADD!(decodeOp2Register, false);
        private alias registerOp2ADDS = dataProcessingADD!(decodeOp2Register, true);

        private void dataProcessingADC(alias decodeOperands, bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "ADC");
            mixin decodeOperands;
            // Operation
            int tmp = op1 + op2;
            int res = tmp + carry;
            setRegister(rd, res);
            // Flag updates
            static if (setFlags) { // TODO: check if this is correct
                int overflow = overflowedAdd(op1, op2, tmp) || overflowedAdd(tmp, carry, res);
                carry = carriedAdd(op1, op2, tmp) || carriedAdd(tmp, carry, res);
                setDataProcessingFlags(rd, res, overflow, carry);
            }
        }

        private alias immediateOp2ADC = dataProcessingADC!(decodeOp2Immediate, false);
        private alias immediateOp2ADCS = dataProcessingADC!(decodeOp2Immediate, true);
        private alias registerOp2ADC = dataProcessingADC!(decodeOp2Register, false);
        private alias registerOp2ADCS = dataProcessingADC!(decodeOp2Register, true);

        private void dataProcessingSBC(alias decodeOperands, bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "SBC");
            mixin decodeOperands;
            // Operation
            int tmp = op1 - op2;
            int res = tmp - !carry; // TODO: check if this is correct
            setRegister(rd, res);
            // Flag updates
            static if (setFlags) { // TODO: check if this is correct
                int overflow = overflowedSub(op1, op2, tmp) || overflowedSub(tmp, !carry, res);
                carry = !borrowedSub(op1, op2, tmp) && !borrowedSub(tmp, !carry, res);
                setDataProcessingFlags(rd, res, overflow, carry);
            }
        }

        private alias immediateOp2SBC = dataProcessingSBC!(decodeOp2Immediate, false);
        private alias immediateOp2SBCS = dataProcessingSBC!(decodeOp2Immediate, true);
        private alias registerOp2SBC = dataProcessingSBC!(decodeOp2Register, false);
        private alias registerOp2SBCS = dataProcessingSBC!(decodeOp2Register, true);

        private void dataProcessingRSC(alias decodeOperands, bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "RSC");
            mixin decodeOperands;
            // Operation
            int tmp = op2 - op1;
            int res = tmp - !carry; // TODO: check if this is correct
            setRegister(rd, res);
            // Flag updates
            static if (setFlags) { // TODO: check if this is correct
                int overflow = overflowedSub(op2, op1, tmp) || overflowedSub(tmp, !carry, res);
                carry = !borrowedSub(op2, op1, tmp) && !borrowedSub(tmp, !carry, res);
                setDataProcessingFlags(rd, res, overflow, carry);
            }
        }

        private alias immediateOp2RSC = dataProcessingRSC!(decodeOp2Immediate, false);
        private alias immediateOp2RSCS = dataProcessingRSC!(decodeOp2Immediate, true);
        private alias registerOp2RSC = dataProcessingRSC!(decodeOp2Register, false);
        private alias registerOp2RSCS = dataProcessingRSC!(decodeOp2Register, true);

        private void dataProcessingTST(alias decodeOperands)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "TST");
            mixin decodeOperands;
            // Operation
            int res = op1 & op2;
            // Flag updates
            int overflow = getFlag(CPSRFlag.V);
            setDataProcessingFlags(rd, res, overflow, carry);
        }

        private alias immediateOp2TST = dataProcessingTST!decodeOp2Immediate;
        private alias registerOp2TST = dataProcessingTST!decodeOp2Register;
        // TODO: what does the P varient do?

        private void dataProcessingTEQ(alias decodeOperands)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "TEQ");
            mixin decodeOperands;
            // Operation
            int res = op1 ^ op2;
            // Flag updates
            int overflow = getFlag(CPSRFlag.V);
            setDataProcessingFlags(rd, res, overflow, carry);
        }

        private alias immediateOp2TEQ = dataProcessingTEQ!decodeOp2Immediate;
        private alias registerOp2TEQ = dataProcessingTEQ!decodeOp2Register;

        private void dataProcessingCMP(alias decodeOperands)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "CMP");
            mixin decodeOperands;
            // Operation
            int res = op1 - op2;
            // Flag updates
            int overflow = overflowedSub(op1, op2, res);
            carry = !borrowedSub(op1, op2, res);
            setDataProcessingFlags(rd, res, overflow, carry);
        }

        private alias immediateOp2CMP = dataProcessingCMP!decodeOp2Immediate;
        private alias registerOp2CMP = dataProcessingCMP!decodeOp2Register;

        private void dataProcessingCMN(alias decodeOperands)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "CMN");
            mixin decodeOperands;
            // Operation
            int res = op1 + op2;
            // Flag updates
            int overflow = overflowedAdd(op1, op2, res);
            carry = carriedAdd(op1, op2, res);
            setDataProcessingFlags(rd, res, overflow, carry);
        }

        private alias immediateOp2CMN = dataProcessingCMN!decodeOp2Immediate;
        private alias registerOp2CMN = dataProcessingCMN!decodeOp2Register;

        private void dataProcessingORR(alias decodeOperands, bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "ORR");
            mixin decodeOperands;
            // Operation
            int res = op1 | op2;
            setRegister(rd, res);
            // Flag updates
            static if (setFlags) {
                int overflow = getFlag(CPSRFlag.V);
                setDataProcessingFlags(rd, res, overflow, carry);
            }
        }

        private alias immediateOp2ORR = dataProcessingORR!(decodeOp2Immediate, false);
        private alias immediateOp2ORRS = dataProcessingORR!(decodeOp2Immediate, true);
        private alias registerOp2ORR = dataProcessingORR!(decodeOp2Register, false);
        private alias registerOp2ORRS = dataProcessingORR!(decodeOp2Register, true);

        private void dataProcessingMOV(alias decodeOperands, bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "MOV");
            mixin decodeOperands;
            // Operation
            int res = op2;
            setRegister(rd, res);
            // Flag updates
            static if (setFlags) {
                int overflow = getFlag(CPSRFlag.V);
                setDataProcessingFlags(rd, res, overflow, carry);
            }
        }

        private alias immediateOp2MOV = dataProcessingMOV!(decodeOp2Immediate, false);
        private alias immediateOp2MOVS = dataProcessingMOV!(decodeOp2Immediate, true);
        private alias registerOp2MOV = dataProcessingMOV!(decodeOp2Register, false);
        private alias registerOp2MOVS = dataProcessingMOV!(decodeOp2Register, true);

        private void dataProcessingBIC(alias decodeOperands, bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "BIC");
            mixin decodeOperands;
            // Operation
            int res = op1 & ~op2;
            setRegister(rd, res);
            // Flag updates
            static if (setFlags) {
                int overflow = getFlag(CPSRFlag.V);
                setDataProcessingFlags(rd, res, overflow, carry);
            }
        }

        private alias immediateOp2BIC = dataProcessingBIC!(decodeOp2Immediate, false);
        private alias immediateOp2BICS = dataProcessingBIC!(decodeOp2Immediate, true);
        private alias registerOp2BIC = dataProcessingBIC!(decodeOp2Register, false);
        private alias registerOp2BICS = dataProcessingBIC!(decodeOp2Register, true);

        private void dataProcessingMVN(alias decodeOperands, bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "MVN");
            mixin decodeOperands;
            // Operation
            int res = ~op2;
            setRegister(rd, res);
            // Flag updates
            static if (setFlags) {
                int overflow = getFlag(CPSRFlag.V);
                setDataProcessingFlags(rd, res, overflow, carry);
            }
        }

        private alias immediateOp2MVN = dataProcessingMVN!(decodeOp2Immediate, false);
        private alias immediateOp2MVNS = dataProcessingMVN!(decodeOp2Immediate, true);
        private alias registerOp2MVN = dataProcessingMVN!(decodeOp2Register, false);
        private alias registerOp2MVNS = dataProcessingMVN!(decodeOp2Register, true);

        private void dataProcessing(int instruction) {
            int code = getBits(instruction, 20, 25);
            dataProcessingInstructions[code](instruction);
        }

        private mixin template decodeOpPrsrImmediate() {
            int op = rotateRight(instruction & 0xFF, getBits(instruction, 8, 11) * 2);
        }

        private mixin template decodeOpPrsrRegister() {
            int op = getRegister(instruction & 0xF);
        }

        private int getPsrMask(int instruction) {
            int mask = 0;
            if (checkBit(instruction, 19)) {
                // flags
                mask |= 0xFF000000;
            }
            // status and extension can be ignored in ARMv4T
            if (checkBit(instruction, 16)) {
                // control
                mask |= 0xFF;
            }
            return mask;
        }

        private void cpsrRead(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "MRS");
            int rd = getBits(instruction, 12, 15);
            setRegister(rd, getRegister(Register.CPSR));
        }

        private void cpsrWrite(alias decodeOperand)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "MSR");
            mixin decodeOperand;
            int mask = getPsrMask(instruction) & (0xF0000000 | (getMode() != Mode.USER ? 0xCF : 0));
            int cpsr = getRegister(Register.CPSR);
            setRegister(Register.CPSR, cpsr & ~mask | op & mask);
        }

        private alias cpsrWriteImmediate = cpsrWrite!decodeOpPrsrImmediate;
        private alias cpsrWriteRegister = cpsrWrite!decodeOpPrsrRegister;

        private void spsrRead(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "MRS");
            int rd = getBits(instruction, 12, 15);
            setRegister(rd, getRegister(Register.SPSR));
        }

        private void spsrWrite(alias decodeOperand)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "MSR");
            mixin decodeOperand;
            int mask = getPsrMask(instruction) & 0xF00000EF;
            int spsr = getRegister(Register.SPSR);
            setRegister(Register.SPSR, spsr & ~mask | op & mask);
        }

        private alias spsrWriteImmediate = spsrWrite!decodeOpPrsrImmediate;
        private alias spsrWriteRegister = spsrWrite!decodeOpPrsrRegister;

        private void psrTransfer(int instruction) {
            int code = getBits(instruction, 20, 25);
            dataProcessingInstructions[code](instruction);
        }

        private void setMultiplyIntResult(bool setFlags)(int rd, int res) {
            setRegister(rd, res);
            static if (setFlags) {
                setAPSRFlags(res < 0, res == 0);
            }
        }

        private void setMultiplyLongResult(bool setFlags)(int rd, int rn, long res) {
            int resLo = cast(int) res;
            int resHi = cast(int) (res >> 32);
            setRegister(rn, resLo);
            setRegister(rd, resHi);
            static if (setFlags) {
                setAPSRFlags(res < 0, res == 0);
            }
        }

        private mixin template decodeOpMultiply() {
            int rd = getBits(instruction, 16, 19);
            int op2 = getRegister(getBits(instruction, 8, 11));
            int op1 = getRegister(instruction & 0xF);
        }

        private void multiplyInt(bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "MUL");
            mixin decodeOpMultiply;
            int res = op1 * op2;
            setMultiplyIntResult!setFlags(rd, res);
        }

        private alias multiplyMUL = multiplyInt!(false);
        private alias multiplyMULS = multiplyInt!(true);

        private void multiplyAccumulateInt(bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "MLA");
            mixin decodeOpMultiply;
            int op3 = getRegister(getBits(instruction, 12, 15));
            int res = op1 * op2 + op3;
            setMultiplyIntResult!setFlags(rd, res);
        }

        private alias multiplyMLA = multiplyAccumulateInt!(false);
        private alias multiplyMLAS = multiplyAccumulateInt!(true);

        private void multiplyLongUnsigned(bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "UMULL");
            mixin decodeOpMultiply;
            int rn = getBits(instruction, 12, 15);
            ulong res = ucast(op1) * ucast(op2);
            setMultiplyLongResult!setFlags(rd, rn, res);
        }

        private alias multiplyUMULL = multiplyLongUnsigned!(false);
        private alias multiplyUMULLS = multiplyLongUnsigned!(true);

        private void multiplyAccumulateLongUnsigned(bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "UMLAL");
            mixin decodeOpMultiply;
            int rn = getBits(instruction, 12, 15);
            ulong op3 = ucast(getRegister(rd)) << 32 | ucast(getRegister(rn));
            ulong res = ucast(op1) * ucast(op2) + op3;
            setMultiplyLongResult!setFlags(rd, rn, res);
        }

        private alias multiplyUMLAL = multiplyAccumulateLongUnsigned!(false);
        private alias multiplyUMLALS = multiplyAccumulateLongUnsigned!(true);

        private void multiplyLongSigned(bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "SMULL");
            mixin decodeOpMultiply;
            int rn = getBits(instruction, 12, 15);
            long res = cast(long) op1 * cast(long) op2;
            setMultiplyLongResult!setFlags(rd, rn, res);
        }

        private alias multiplySMULL = multiplyLongSigned!(false);
        private alias multiplySMULLS = multiplyLongSigned!(true);

        private void multiplyAccumulateLongSigned(bool setFlags)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "SMLAL");
            mixin decodeOpMultiply;
            int rn = getBits(instruction, 12, 15);
            long op3 = ucast(getRegister(rd)) << 32 | ucast(getRegister(rn));
            long res = cast(long) op1 * cast(long) op2 + op3;
            setMultiplyLongResult!setFlags(rd, rn, res);
        }

        private alias multiplySMLAL = multiplyAccumulateLongSigned!(false);
        private alias multiplySMLALS = multiplyAccumulateLongSigned!(true);

        private void multiplyAndMultiplyAccumulate(int instruction) {
            int code = getBits(instruction, 20, 23);
            multiplyInstructions[code](instruction);
        }

        private mixin template decodeOpSingleDataTransferImmediate() {
            int rn = getBits(instruction, 16, 19);
            int rd = getBits(instruction, 12, 15);
            int offset = instruction & 0xFFF;
        }

        private mixin template decodeOpSingleDataTransferRegister() {
            int rn = getBits(instruction, 16, 19);
            int rd = getBits(instruction, 12, 15);
            int shift = getBits(instruction, 7, 11);
            int shiftType = getBits(instruction, 5, 6);
            int carry;
            int offset = applyShift(shiftType, shift, false, getRegister(instruction & 0b1111), carry);
        }

        private template singleDataTransfer(byte flags) if (!flags.checkBit(5)) {
            private void singleDataTransfer(int instruction) {
                singleDataTransfer!(decodeOpSingleDataTransferImmediate, flags)(instruction);
            }
        }

        private template singleDataTransfer(byte flags) if (flags.checkBit(5)) {
            private void singleDataTransfer(int instruction) {
                singleDataTransfer!(decodeOpSingleDataTransferRegister, flags)(instruction);
            }
        }

        private void singleDataTransfer(alias decodeOperands, byte flags)(int instruction) {
            singleDataTransfer!(decodeOperands, flags.checkBit(4), flags.checkBit(3),
                    flags.checkBit(2), flags.checkBit(1), flags.checkBit(0))(instruction);
        }

        private void singleDataTransfer(alias decodeOperands, bool preIncr, bool upIncr, bool byteQty,
                    bool writeBack, bool load)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            // TODO: what does NoPrivilege do?
            debug (outputInstructions) logInstruction(instruction, (load ? "LDR" : "STR") ~ (byteQty ? "B" : ""));
            mixin decodeOperands;
            int address = getRegister(rn);
            // Do pre-increment if needed
            static if (preIncr) {
                static if (upIncr) {
                    address += offset;
                } else {
                    address -= offset;
                }
            }
            // Read or write memory
            static if (load) {
                static if (byteQty) {
                    setRegister(rd, memory.getByte(address) & 0xFF);
                } else {
                    setRegister(rd, rotateRead(address, memory.getInt(address)));
                }
            } else {
                static if (byteQty) {
                    memory.setByte(address, cast(byte) getRegister(rd));
                } else {
                    memory.setInt(address, getRegister(rd));
                }
            }
            // Do post-increment and write back if needed
            static if (preIncr) {
                static if (writeBack) {
                    setRegister(rn, address);
                }
            } else {
                static if (upIncr) {
                    address += offset;
                } else {
                    address -= offset;
                }
                // Always do write back in post increment
                setRegister(rn, address);
            }
        }

        private void singleDataTransfer(int instruction) {
            int code = getBits(instruction, 20, 25);
            singleDataTransferInstructions[code](instruction);
        }

        private void halfwordAndSignedDataTransfer(byte flags)(int instruction) {
            halfwordAndSignedDataTransfer!(flags.checkBit(6), flags.checkBit(5), flags.checkBit(4),
                    flags.checkBit(3), flags.checkBit(2), flags.getBits(0, 1))(instruction);
        }

        private void halfwordAndSignedDataTransfer(bool preIncr, bool upIncr, bool immediate,
                    bool writeBack, bool load, byte opCode)(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            // Decode operands
            int rn = getBits(instruction, 16, 19);
            int rd = getBits(instruction, 12, 15);
            static if (immediate) {
                int upperOffset = getBits(instruction, 8, 11);
                int lowerOffset = instruction & 0xF;
                int offset = upperOffset << 4 | lowerOffset;
            } else {
                int offset = getRegister(instruction & 0xF);
            }
            int address = getRegister(rn);
            // Do pre-increment if needed
            static if (preIncr) {
                static if (upIncr) {
                    address += offset;
                } else {
                    address -= offset;
                }
            }
            // Read or write memory
            static if (load) {
                static if (opCode == 1) {
                    debug (outputInstructions) logInstruction(instruction, "LDRH");
                    setRegister(rd, rotateRead(address, memory.getShort(address)));
                } else static if (opCode == 2) {
                    debug (outputInstructions) logInstruction(instruction, "LDRSB");
                    setRegister(rd, memory.getByte(address));
                } else static if (opCode == 3) {
                    debug (outputInstructions) logInstruction(instruction, "LDRSH");
                    setRegister(rd, rotateReadSigned(address, memory.getShort(address)));
                } else {
                    static assert (0);
                }
            } else {
                static if (opCode == 1) {
                    debug (outputInstructions) logInstruction(instruction, "STRH");
                    memory.setShort(address, cast(short) getRegister(rd));
                } else {
                    static assert (0);
                }
            }
            // Do post-increment and write back if needed
            static if (preIncr) {
                static if (writeBack) {
                    setRegister(rn, address);
                }
            } else {
                static if (upIncr) {
                    address += offset;
                } else {
                    address -= offset;
                }
                // Always do write back in post increment, the flag should be 0
                static if (writeBack) {
                    static assert (0);
                }
                setRegister(rn, address);
            }
        }

        private void halfwordAndSignedDataTransfer(int instruction) {
            int code = getBits(instruction, 20, 24) << 2 | getBits(instruction, 5, 6);
            halfwordAndSignedDataTransferInstructions[code](instruction);
        }

        private void blockDataTransfer(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            int preIncr = getBit(instruction, 24);
            int upIncr = getBit(instruction, 23);
            int loadPSR = getBit(instruction, 22);
            int writeBack = getBit(instruction, 21);
            int load = getBit(instruction, 20);
            int rn = getBits(instruction, 16, 19);
            int registerList = instruction & 0xFFFF;
            int address = getRegister(rn);
            if (load) {
                debug (outputInstructions) logInstruction(instruction, "LDM");
            } else {
                debug (outputInstructions) logInstruction(instruction, "STM");
            }
            Mode mode = this.outer.mode;
            if (loadPSR) {
                if (load && checkBit(registerList, 15)) {
                    setRegister(Register.CPSR, getRegister(Register.SPSR));
                } else {
                    mode = Mode.USER;
                }
            }
            if (upIncr) {
                foreach (i; 0 .. 16) {
                    if (checkBit(registerList, i)) {
                        if (preIncr) {
                            address += 4;
                            if (load) {
                                setRegister(mode, i, memory.getInt(address));
                            } else {
                                memory.setInt(address, getRegister(mode, i));
                            }
                        } else {
                            if (load) {
                                setRegister(mode, i, memory.getInt(address));
                            } else {
                                memory.setInt(address, getRegister(mode, i));
                            }
                            address += 4;
                        }
                    }
                }
            } else {
                int size = 4 * bitCount(registerList);
                address -= size;
                int currentAddress = address;
                foreach (i; 0 .. 16) {
                    if (checkBit(registerList, i)) {
                        if (preIncr) {
                            if (load) {
                                setRegister(mode, i, memory.getInt(currentAddress));
                            } else {
                                memory.setInt(currentAddress, getRegister(mode, i));
                            }
                            currentAddress += 4;
                        } else {
                            currentAddress += 4;
                            if (load) {
                                setRegister(mode, i, memory.getInt(currentAddress));
                            } else {
                                memory.setInt(currentAddress, getRegister(mode, i));
                            }
                        }
                    }
                }
            }
            if (writeBack) {
                setRegister(mode, rn, address);
            }
        }

        private void singleDataSwap(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            int byteQuantity = getBit(instruction, 22);
            int rn = getBits(instruction, 16, 19);
            int rd = getBits(instruction, 12, 15);
            int rm = instruction & 0xF;
            int address = getRegister(rn);
            debug (outputInstructions) logInstruction(instruction, "SWP");
            if (byteQuantity) {
                int b = memory.getByte(address) & 0xFF;
                memory.setByte(address, cast(byte) getRegister(rm));
                setRegister(rd, b);
            } else {
                int w = rotateRead(address, memory.getInt(address));
                memory.setInt(address, getRegister(rm));
                setRegister(rd, w);
            }
        }

        private void softwareInterrupt(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "SWI");
            setRegister(Mode.SUPERVISOR, Register.SPSR, getRegister(Register.CPSR));
            setFlag(CPSRFlag.I, 1);
            setRegister(Mode.SUPERVISOR, Register.LR, getRegister(Register.PC) - 4);
            setRegister(Register.PC, 0x8);
            setMode(Mode.SUPERVISOR);
        }

        private void undefined(int instruction) {
            if (!checkCondition(getConditionBits(instruction))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "UNDEFINED");
            setRegister(Mode.UNDEFINED, Register.SPSR, getRegister(Register.CPSR));
            setFlag(CPSRFlag.I, 1);
            setRegister(Mode.UNDEFINED, Register.LR, getRegister(Register.PC) - 4);
            setRegister(Register.PC, 0x4);
            setMode(Mode.UNDEFINED);
        }

        private void unsupported(int instruction) {
            throw new UnsupportedARMInstructionException(getRegister(Register.PC) - 8, instruction);
        }
    }

    private class THUMBPipeline : Pipeline {
        protected Set getSet() {
            return Set.THUMB;
        }

        protected override int fetch() {
            return mirror(memory.getShort(getRegister(Register.PC)));
        }

        protected override int decode(int instruction) {
            // Nothing to do
            return instruction;
        }

        protected override void execute(int instruction) {
            if (checkBits(instruction, 0b1111100000000000, 0b0001100000000000)) {
                addAndSubtract(instruction);
            } else if (checkBits(instruction, 0b1110000000000000, 0b0000000000000000)) {
                moveShiftedRegister(instruction);
            } else if (checkBits(instruction, 0b1110000000000000, 0b0010000000000000)) {
                moveCompareAddAndSubtractImmediate(instruction);
            } else if (checkBits(instruction, 0b1111110000000000, 0b0100000000000000)) {
                aluOperations(instruction);
            } else if (checkBits(instruction, 0b1111110000000000, 0b0100010000000000)) {
                hiRegisterOperationsAndBranchExchange(instruction);
            } else if (checkBits(instruction, 0b1111100000000000, 0b0100100000000000)) {
                loadPCRelative(instruction);
            } else if (checkBits(instruction, 0b1111001000000000, 0b0101000000000000)) {
                loadAndStoreWithRegisterOffset(instruction);
            } else if (checkBits(instruction, 0b1111001000000000, 0b0101001000000000)) {
                loadAndStoreSignExtentedByteAndHalfword(instruction);
            } else if (checkBits(instruction, 0b1110000000000000, 0b0110000000000000)) {
                loadAndStoreWithImmediateOffset(instruction);
            } else if (checkBits(instruction, 0b1111000000000000, 0b1000000000000000)) {
                loadAndStoreHalfWord(instruction);
            } else if (checkBits(instruction, 0b1111000000000000, 0b1001000000000000)) {
                loadAndStoreSPRelative(instruction);
            } else if (checkBits(instruction, 0b1111000000000000, 0b1010000000000000)) {
                getRelativeAddresss(instruction);
            } else if (checkBits(instruction, 0b1111111100000000, 0b1011000000000000)) {
                addOffsetToStackPointer(instruction);
            } else if (checkBits(instruction, 0b1111011000000000, 0b1011010000000000)) {
                pushAndPopRegisters(instruction);
            } else if (checkBits(instruction, 0b1111000000000000, 0b1100000000000000)) {
                multipleLoadAndStore(instruction);
            } else if (checkBits(instruction, 0b1111111100000000, 0b1101111100000000)) {
                softwareInterrupt(instruction);
            } else if (checkBits(instruction, 0b1111000000000000, 0b1101000000000000)) {
                conditionalBranch(instruction);
            } else if (checkBits(instruction, 0b1111100000000000, 0b1110000000000000)) {
                unconditionalBranch(instruction);
            } else if (checkBits(instruction, 0b1111000000000000, 0b1111000000000000)) {
                longBranchWithLink(instruction);
            } else {
                unsupported(instruction);
            }
        }

        protected override uint getPCIncrement() {
            return 2;
        }

        protected override void incrementPC() {
            registers[Register.PC] = (registers[Register.PC] & ~1) + 2;
        }

        private void moveShiftedRegister(int instruction) {
            int shiftType = getBits(instruction, 11, 12);
            int shift = getBits(instruction, 6, 10);
            int op = getRegister(getBits(instruction, 3, 5));
            int rd = instruction & 0b111;
            debug (outputInstructions) {
                final switch (shiftType) {
                    case 0:
                        logInstruction(instruction, "LSL");
                        break;
                    case 1:
                        logInstruction(instruction, "LSR");
                        break;
                    case 2:
                        logInstruction(instruction, "ASR");
                        break;
                }
            }
            int carry;
            op = applyShift(shiftType, shift, false, op, carry);
            setRegister(rd, op);
            setAPSRFlags(op < 0, op == 0, carry);
        }

        private void addAndSubtract(int instruction) {
            int op2Src = getBit(instruction, 10);
            int opCode = getBit(instruction, 9);
            int rn = getBits(instruction, 6, 8);
            int op2;
            if (op2Src) {
                // immediate
                op2 = rn;
            } else {
                // register
                op2 = getRegister(rn);
            }
            int op1 = getRegister(getBits(instruction, 3, 5));
            int rd = instruction & 0b111;
            int res;
            int carry, overflow;
            if (opCode) {
                // SUB
                debug (outputInstructions) logInstruction(instruction, "SUB");
                res = op1 - op2;
                carry = !borrowedSub(op1, op2, res);
                overflow = overflowedSub(op1, op2, res);
            } else {
                // ADD
                debug (outputInstructions) logInstruction(instruction, "ADD");
                res = op1 + op2;
                carry = carriedAdd(op1, op2, res);
                overflow = overflowedAdd(op1, op2, res);
            }
            setRegister(rd, res);
            setAPSRFlags(res < 0, res == 0, carry, overflow);
        }

        private void moveCompareAddAndSubtractImmediate(int instruction) {
            int opCode = getBits(instruction, 11, 12);
            int rd = getBits(instruction, 8, 10);
            int op2 = instruction & 0xFF;
            final switch (opCode) {
                case 0:
                    // MOV
                    debug (outputInstructions) logInstruction(instruction, "MOV");
                    setRegister(rd, op2);
                    setAPSRFlags(op2 < 0, op2 == 0);
                    break;
                case 1:
                    // CMP
                    debug (outputInstructions) logInstruction(instruction, "CMP");
                    int op1 = getRegister(rd);
                    int v = op1 - op2;
                    setAPSRFlags(v < 0, v == 0, !borrowedSub(op1, op2, v), overflowedSub(op1, op2, v));
                    break;
                case 2:
                    // ADD
                    debug (outputInstructions) logInstruction(instruction, "ADD");
                    int op1 = getRegister(rd);
                    int res = op1 + op2;
                    setRegister(rd, res);
                    setAPSRFlags(res < 0, res == 0, carriedAdd(op1, op2, res), overflowedAdd(op1, op2, res));
                    break;
                case 3:
                    // SUB
                    debug (outputInstructions) logInstruction(instruction, "SUB");
                    int op1 = getRegister(rd);
                    int res = op1 - op2;
                    setRegister(rd, res);
                    setAPSRFlags(res < 0, res == 0, !borrowedSub(op1, op2, res), overflowedSub(op1, op2, res));
                    break;
            }
        }

        private void aluOperations(int instruction) {
            int opCode = getBits(instruction, 6, 9);
            int op2 = getRegister(getBits(instruction, 3, 5));
            int rd = instruction & 0b111;
            int op1 = getRegister(rd);
            final switch (opCode) {
                case 0x0:
                    // AND
                    debug (outputInstructions) logInstruction(instruction, "AND");
                    int res = op1 & op2;
                    setRegister(rd, res);
                    setAPSRFlags(res < 0, res == 0);
                    break;
                case 0x1:
                    // EOR
                    debug (outputInstructions) logInstruction(instruction, "EOR");
                    int res = op1 ^ op2;
                    setRegister(rd, res);
                    setAPSRFlags(res < 0, res == 0);
                    break;
                case 0x2:
                    // LSL
                    debug (outputInstructions) logInstruction(instruction, "LSL");
                    int carry;
                    int res = applyShift(0, op2 & 0xFF, true, op1, carry);
                    setRegister(rd, res);
                    setAPSRFlags(res < 0, res == 0, carry);
                    break;
                case 0x3:
                    // LSR
                    debug (outputInstructions) logInstruction(instruction, "LSR");
                    int carry;
                    int res = applyShift(1, op2 & 0xFF, true, op1, carry);
                    setRegister(rd, res);
                    setAPSRFlags(res < 0, res == 0, carry);
                    break;
                case 0x4:
                    // ASR
                    debug (outputInstructions) logInstruction(instruction, "ASR");
                    int carry;
                    int res = applyShift(2, op2 & 0xFF, true, op1, carry);
                    setRegister(rd, res);
                    setAPSRFlags(res < 0, res == 0, carry);
                    break;
                case 0x5:
                    // ADC
                    debug (outputInstructions) logInstruction(instruction, "ADC");
                    int carry = getFlag(CPSRFlag.C);
                    int tmp = op1 + op2;
                    int res = tmp + carry;
                    setRegister(rd, res);
                    setAPSRFlags(res < 0, res == 0,
                        carriedAdd(op1, op2, tmp) || carriedAdd(tmp, carry, res),
                        overflowedAdd(op1, op2, tmp) || overflowedAdd(tmp, carry, res));
                    break;
                case 0x6:
                    // SBC
                    debug (outputInstructions) logInstruction(instruction, "SBC");
                    int carry = getFlag(CPSRFlag.C);
                    int tmp = op1 - op2;
                    int res = tmp - !carry;
                    setRegister(rd, res);
                    setAPSRFlags(res < 0, res == 0,
                        !borrowedSub(op1, op2, tmp) && !borrowedSub(tmp, !carry, res),
                        overflowedSub(op1, op2, tmp) || overflowedSub(tmp, !carry, res));
                    break;
                case 0x7:
                    // ROR
                    debug (outputInstructions) logInstruction(instruction, "ROR");
                    int carry;
                    int res = applyShift(3, op2 & 0xFF, true, op1, carry);
                    setRegister(rd, res);
                    setAPSRFlags(res < 0, res == 0, carry);
                    break;
                case 0x8:
                    // TST
                    debug (outputInstructions) logInstruction(instruction, "TST");
                    int v = op1 & op2;
                    setAPSRFlags(v < 0, v == 0);
                    break;
                case 0x9:
                    // NEG
                    debug (outputInstructions) logInstruction(instruction, "NEG");
                    int res = 0 - op2;
                    setRegister(rd, res);
                    setAPSRFlags(res < 0, res == 0, !borrowedSub(0, op2, res), overflowedSub(0, op2, res));
                    break;
                case 0xA:
                    // CMP
                    debug (outputInstructions) logInstruction(instruction, "CMP");
                    int v = op1 - op2;
                    setAPSRFlags(v < 0, v == 0, !borrowedSub(op1, op2, v), overflowedSub(op1, op2, v));
                    break;
                case 0xB:
                    // CMN
                    debug (outputInstructions) logInstruction(instruction, "CMN");
                    int v = op1 + op2;
                    setAPSRFlags(v < 0, v == 0, carriedAdd(op1, op2, v), overflowedAdd(op1, op2, v));
                    break;
                case 0xC:
                    // ORR
                    debug (outputInstructions) logInstruction(instruction, "ORR");
                    int res = op1 | op2;
                    setRegister(rd, res);
                    setAPSRFlags(res < 0, res == 0);
                    break;
                case 0xD:
                    // MUL
                    debug (outputInstructions) logInstruction(instruction, "MUL");
                    int res = op1 * op2;
                    setRegister(rd, res);
                    setAPSRFlags(res < 0, res == 0);
                    break;
                case 0xE:
                    // BIC
                    debug (outputInstructions) logInstruction(instruction, "BIC");
                    int res = op1 & ~op2;
                    setRegister(rd, res);
                    setAPSRFlags(res < 0, res == 0);
                    break;
                case 0xF:
                    // MNV
                    debug (outputInstructions) logInstruction(instruction, "MNV");
                    int res = ~op2;
                    setRegister(rd, res);
                    setAPSRFlags(res < 0, res == 0);
                    break;
            }
        }

        private void hiRegisterOperationsAndBranchExchange(int instruction) {
            int opCode = getBits(instruction, 8, 9);
            int rs = getBits(instruction, 3, 6);
            int rd = instruction & 0b111 | getBit(instruction, 7) << 3;
            final switch (opCode) {
                case 0:
                    // ADD
                    debug (outputInstructions) logInstruction(instruction, "ADD");
                    setRegister(rd, getRegister(rd) + getRegister(rs));
                    break;
                case 1:
                    // CMP
                    debug (outputInstructions) logInstruction(instruction, "CMP");
                    int op1 = getRegister(rd);
                    int op2 = getRegister(rs);
                    int v = op1 - op2;
                    setAPSRFlags(v < 0, v == 0, !borrowedSub(op1, op2, v), overflowedSub(op1, op2, v));
                    break;
                case 2:
                    // MOV
                    debug (outputInstructions) logInstruction(instruction, "MOV");
                    setRegister(rd, getRegister(rs));
                    break;
                case 3:
                    // BX
                    debug (outputInstructions) logInstruction(instruction, "BX");
                    int address = getRegister(rs);
                    if (!(address & 0b1)) {
                        setFlag(CPSRFlag.T, Set.ARM);
                    }
                    setRegister(Register.PC, address & ~1);
                    break;
            }
        }

        private void loadPCRelative(int instruction) {
            int rd = getBits(instruction, 8, 10);
            int offset = (instruction & 0xFF) * 4;
            int pc = getRegister(Register.PC);
            int address = (pc & ~3) + offset;
            debug (outputInstructions) logInstruction(instruction, "LDR");
            setRegister(rd, rotateRead(address, memory.getInt(address)));
        }

        private void loadAndStoreWithRegisterOffset(int instruction) {
            int opCode = getBits(instruction, 10, 11);
            int offset = getRegister(getBits(instruction, 6, 8));
            int base = getRegister(getBits(instruction, 3, 5));
            int rd = instruction & 0b111;
            int address = base + offset;
            final switch (opCode) {
                case 0:
                    debug (outputInstructions) logInstruction(instruction, "STR");
                    memory.setInt(address, getRegister(rd));
                    break;
                case 1:
                    debug (outputInstructions) logInstruction(instruction, "STRB");
                    memory.setByte(address, cast(byte) getRegister(rd));
                    break;
                case 2:
                    debug (outputInstructions) logInstruction(instruction, "LDR");
                    setRegister(rd, rotateRead(address, memory.getInt(address)));
                    break;
                case 3:
                    debug (outputInstructions) logInstruction(instruction, "LDRB");
                    setRegister(rd, memory.getByte(address) & 0xFF);
                    break;
            }
        }

        private void loadAndStoreSignExtentedByteAndHalfword(int instruction) {
            int opCode = getBits(instruction, 10, 11);
            int offset = getRegister(getBits(instruction, 6, 8));
            int base = getRegister(getBits(instruction, 3, 5));
            int rd = instruction & 0b111;
            int address = base + offset;
            final switch (opCode) {
                case 0:
                    debug (outputInstructions) logInstruction(instruction, "STRH");
                    memory.setShort(address, cast(short) getRegister(rd));
                    break;
                case 1:
                    debug (outputInstructions) logInstruction(instruction, "LDSB");
                    setRegister(rd, memory.getByte(address));
                    break;
                case 2:
                    debug (outputInstructions) logInstruction(instruction, "LDRH");
                    setRegister(rd, rotateRead(address, memory.getShort(address)));
                    break;
                case 3:
                    debug (outputInstructions) logInstruction(instruction, "LDSH");
                    setRegister(rd, rotateReadSigned(address, memory.getShort(address)));
                    break;
            }
        }

        private void loadAndStoreWithImmediateOffset(int instruction) {
            int opCode = getBits(instruction, 11, 12);
            int offset = getBits(instruction, 6, 10);
            int base = getRegister(getBits(instruction, 3, 5));
            int rd = instruction & 0b111;
            final switch (opCode) {
                case 0:
                    debug (outputInstructions) logInstruction(instruction, "STR");
                    memory.setInt(base + offset * 4, getRegister(rd));
                    break;
                case 1:
                    debug (outputInstructions) logInstruction(instruction, "LDR");
                    int address = base + offset * 4;
                    setRegister(rd, rotateRead(address, memory.getInt(address)));
                    break;
                case 2:
                    debug (outputInstructions) logInstruction(instruction, "STRB");
                    memory.setByte(base + offset, cast(byte) getRegister(rd));
                    break;
                case 3:
                    debug (outputInstructions) logInstruction(instruction, "LDRB");
                    setRegister(rd, memory.getByte(base + offset) & 0xFF);
            }
        }

        private void loadAndStoreHalfWord(int instruction) {
            int opCode = getBit(instruction, 11);
            int offset = getBits(instruction, 6, 10) * 2;
            int base = getRegister(getBits(instruction, 3, 5));
            int rd = instruction & 0b111;
            int address = base + offset;
            if (opCode) {
                debug (outputInstructions) logInstruction(instruction, "LDRH");
                setRegister(rd, rotateRead(address, memory.getShort(address)));
            } else {
                debug (outputInstructions) logInstruction(instruction, "STRH");
                memory.setShort(address, cast(short) getRegister(rd));
            }
        }

        private void loadAndStoreSPRelative(int instruction) {
            int opCode = getBit(instruction, 11);
            int rd = getBits(instruction, 8, 10);
            int offset = (instruction & 0xFF) * 4;
            int sp = getRegister(Register.SP);
            int address = sp + offset;
            if (opCode) {
                debug (outputInstructions) logInstruction(instruction, "LDR");
                setRegister(rd, rotateRead(address, memory.getInt(address)));
            } else {
                debug (outputInstructions) logInstruction(instruction, "STR");
                memory.setInt(address, getRegister(rd));
            }
        }

        private void getRelativeAddresss(int instruction) {
            int opCode = getBit(instruction, 11);
            int rd = getBits(instruction, 8, 10);
            int offset = (instruction & 0xFF) * 4;
            if (opCode) {
                debug (outputInstructions) logInstruction(instruction, "ADD");
                setRegister(rd, getRegister(Register.SP) + offset);
            } else {
                debug (outputInstructions) logInstruction(instruction, "ADD");
                setRegister(rd, (getRegister(Register.PC) & ~3) + offset);
            }
        }

        private void addOffsetToStackPointer(int instruction) {
            int opCode = getBit(instruction, 7);
            int offset = (instruction & 0x7F) * 4;
            if (opCode) {
                debug (outputInstructions) logInstruction(instruction, "ADD");
                setRegister(Register.SP, getRegister(Register.SP) - offset);
            } else {
                debug (outputInstructions) logInstruction(instruction, "ADD");
                setRegister(Register.SP, getRegister(Register.SP) + offset);
            }
        }

        private void pushAndPopRegisters(int instruction) {
            int opCode = getBit(instruction, 11);
            int pcAndLR = getBit(instruction, 8);
            int registerList = instruction & 0xFF;
            int sp = getRegister(Register.SP);
            if (opCode) {
                debug (outputInstructions) logInstruction(instruction, "POP");
                foreach (i; 0 .. 8) {
                    if (checkBit(registerList, i)) {
                        setRegister(i, memory.getInt(sp));
                        sp += 4;
                    }
                }
                if (pcAndLR) {
                    setRegister(Register.PC, memory.getInt(sp));
                    sp += 4;
                }
            } else {
                debug (outputInstructions) logInstruction(instruction, "PUSH");
                int size = 4 * (bitCount(registerList) + pcAndLR);
                sp -= size;
                int address = sp;
                foreach (i; 0 .. 8) {
                    if (checkBit(registerList, i)) {
                        memory.setInt(address, getRegister(i));
                        address += 4;
                    }
                }
                if (pcAndLR) {
                    memory.setInt(address, getRegister(Register.LR));
                }
            }
            setRegister(Register.SP, sp);
        }

        private void multipleLoadAndStore(int instruction) {
            int opCode = getBit(instruction, 11);
            int rb = getBits(instruction, 8, 10);
            int registerList = instruction & 0xFF;
            int address = getRegister(rb);
            if (opCode) {
                debug (outputInstructions) logInstruction(instruction, "LDMIA");
                foreach (i; 0 .. 8) {
                    if (checkBit(registerList, i)) {
                        setRegister(i, memory.getInt(address));
                        address += 4;
                    }
                }
            } else {
                debug (outputInstructions) logInstruction(instruction, "STMIA");
                foreach (i; 0 .. 8) {
                    if (checkBit(registerList, i)) {
                        memory.setInt(address, getRegister(i));
                        address += 4;
                    }
                }
            }
            setRegister(rb, address);
        }

        private void conditionalBranch(int instruction) {
            if (!checkCondition(getBits(instruction, 8, 11))) {
                return;
            }
            debug (outputInstructions) logInstruction(instruction, "B");
            int offset = instruction & 0xFF;
            // sign extend the offset
            offset <<= 24;
            offset >>= 24;
            setRegister(Register.PC, getRegister(Register.PC) + offset * 2);
        }

        private void softwareInterrupt(int instruction) {
            debug (outputInstructions) logInstruction(instruction, "SWI");
            setRegister(Mode.SUPERVISOR, Register.SPSR, getRegister(Register.CPSR));
            setFlag(CPSRFlag.I, 1);
            setFlag(CPSRFlag.T, Set.ARM);
            setRegister(Mode.SUPERVISOR, Register.LR, getRegister(Register.PC) - 2);
            setRegister(Register.PC, 0x8);
            setMode(Mode.SUPERVISOR);
        }

        private void unconditionalBranch(int instruction) {
            debug (outputInstructions) logInstruction(instruction, "B");
            int offset = instruction & 0x7FF;
            // sign extend the offset
            offset <<= 21;
            offset >>= 21;
            setRegister(Register.PC, getRegister(Register.PC) + offset * 2);
        }

        private void longBranchWithLink(int instruction) {
            int opCode = getBit(instruction, 11);
            int offset = instruction & 0x7FF;
            if (opCode) {
                debug (outputInstructions) logInstruction(instruction, "BL");
                int address = getRegister(Register.LR) + (offset << 1);
                setRegister(Register.LR, getRegister(Register.PC) - 2 | 1);
                setRegister(Register.PC, address);
            } else {
                debug (outputInstructions) logInstruction(instruction, "BL_");
                // sign extend the offset
                offset <<= 21;
                offset >>= 21;
                setRegister(Register.LR, getRegister(Register.PC) + (offset << 12));
            }
        }

        private void unsupported(int instruction) {
            throw new UnsupportedTHUMBInstructionException(getRegister(Register.PC) - 4, instruction);
        }
    }

    private int applyShift(int shiftType, int shift, bool shiftSrc, int op, out int carry) {
        final switch (shiftType) {
            // LSL
            case 0:
                if (shiftSrc) {
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
                if (shiftSrc) {
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
                if (shiftSrc) {
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
                if (shiftSrc) {
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

    private int getFlag(CPSRFlag flag) {
        return getBit(registers[Register.CPSR], flag);
    }

    private void setFlag(CPSRFlag flag, int b) {
        setBit(registers[Register.CPSR], flag, b);
    }

    private void setAPSRFlags(int n, int z) {
        setBits(registers[Register.CPSR], 30, 31, z | n << 1);
    }

    private void setAPSRFlags(int n, int z, int c) {
        setBits(registers[Register.CPSR], 29, 31, c | z << 1 | n << 2);
    }

    private void setAPSRFlags(int n, int z, int c, int v) {
        setBits(registers[Register.CPSR], 28, 31, v | c << 1 | z << 2 | n << 3);
    }

    private Mode getMode() {
        return cast(Mode) (registers[Register.CPSR] & 0b11111);
    }

    private void setMode(Mode mode) {
        setBits(registers[Register.CPSR], 0, 4, mode);
    }

    private bool checkCondition(int condition) {
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

    private int getRegister(int register) {
        return getRegister(mode, register);
    }

    private int getRegister(Mode mode, int register) {
        return registers[getRegisterIndex(mode, register)];
    }

    private void setRegister(int register, int value) {
        setRegister(mode, register, value);
    }

    private void setRegister(Mode mode, int register, int value) {
        if (register == Register.PC) {
            branchSignal = true;
        }
        registers[getRegisterIndex(mode, register)] = value;
    }

    debug (outputInstructions) {
        private enum uint queueMaxSize = 1024;
        private Instruction[queueMaxSize] lastInstructions = new Instruction[queueMaxSize];
        private uint queueSize = 0;
        private uint index = 0;

        private void logInstruction(int code, string mnemonic) {
            logInstruction(getProgramCounter(), code, mnemonic);
        }

        private void logInstruction(int address, int code, string mnemonic) {
            Set set = pipeline.getSet();
            if (set == Set.THUMB) {
                code &= 0xFFFF;
            }
            lastInstructions[index].mode = mode;
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
                final switch (lastInstructions[j].set) with (Set) {
                    case ARM:
                        writefln("%-10s| %08x: %08x %s", lastInstructions[j].mode, lastInstructions[j].address, lastInstructions[j].code, lastInstructions[j].mnemonic);
                        break;
                    case THUMB:
                        writefln("%-10s| %08x: %04x     %s", lastInstructions[j].mode, lastInstructions[j].address, lastInstructions[j].code, lastInstructions[j].mnemonic);
                        break;
                }
            }
        }

        public void dumpRegisters() {
            writefln("Dumping last known register states:");
            foreach (i; 0 .. 18) {
                writefln("%-4s: %08x", cast(Register) i, getRegister(i));
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

private int getConditionBits(int instruction) {
    return instruction >>> 28;
}

private int rotateRead(int address, int value) {
    return rotateRight(value, (address & 3) << 3);
}

private int rotateRead(int address, short value) {
    return rotateRight(value & 0xFFFF, (address & 1) << 3);
}

private int rotateReadSigned(int address, short value) {
    return value >> ((address & 1) << 3);
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

private bool carriedAdd(int a, int b, int c) {
    int negativeA = a >> 31;
    int negativeB = b >> 31;
    int negativeC = c >> 31;
    return negativeA && negativeB || negativeA && !negativeC || negativeB && !negativeC;
}

private bool overflowedAdd(int a, int b, int c) {
    int negativeA = a >> 31;
    int negativeB = b >> 31;
    int negativeC = c >> 31;
    return negativeA && negativeB && !negativeC || !negativeA && !negativeB && negativeC;
}

private bool borrowedSub(int a, int b, int c) {
    int negativeA = a >> 31;
    int negativeB = b >> 31;
    int negativeC = c >> 31;
    return (!negativeA || negativeB) && (!negativeA || negativeC) && (negativeB || negativeC);
}

private bool overflowedSub(int a, int b, int c) {
    int negativeA = a >> 31;
    int negativeB = b >> 31;
    int negativeC = c >> 31;
    return negativeA && !negativeB && !negativeC || !negativeA && negativeB && negativeC;
}

private enum Set {
    ARM = 0,
    THUMB = 1
}

private enum Mode {
    USER = 16,
    FIQ = 17,
    IRQ = 18,
    SUPERVISOR = 19,
    ABORT = 23,
    UNDEFINED = 27,
    SYSTEM = 31
}

private enum Register {
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

private enum CPSRFlag {
    N = 31,
    Z = 30,
    C = 29,
    V = 28,
    Q = 27,
    I = 7,
    F = 6,
    T = 5,
}

public class UnsupportedARMInstructionException : Exception {
    protected this(int address, int instruction) {
        super(format("This ARM instruction is unsupported by the implementation\n%08x: %08x", address, instruction));
    }
}

public class UnsupportedTHUMBInstructionException : Exception {
    protected this(int address, int instruction) {
        super(format("This THUMB instruction is unsupported by the implementation\n%08x: %04x", address, instruction & 0xFFFF));
    }
}
