module gbaid.arm;

import std.conv;
import std.string;

import gbaid.memory;
import gbaid.cpu;
import gbaid.util;

private template genTable(alias instructionFamily, int bitCount, alias unsupported, int index = 0) {
    private void function(Registers, Memory, int)[] genTable() {
        static if (index < (1 << bitCount)) {
            static if (__traits(compiles, &instructionFamily!index)) {
                void function(Registers, Memory, int) entry = &instructionFamily!index;
            } else {
                void function(Registers, Memory, int) entry = &unsupported;
            }
            return [entry] ~ genTable!(instructionFamily, bitCount, unsupported, index + 1)();
        } else {
            return [];
        }
    }
}

void function(Registers, Memory, int)[] genARMTable() {
    // Bits are OpCode(4),S(1)
    // where S is set flags
    void function(Registers, Memory, int)[] dataProcessingRegisterImmediateInstructions = genTable!(dataProcessing_RegShiftImm, 5, unsupported);
    void function(Registers, Memory, int)[] dataProcessingRegisterInstructions = genTable!(dataProcessing_RegShiftReg, 5, unsupported);
    void function(Registers, Memory, int)[] dataProcessingImmediateInstructions = genTable!(dataProcessing_Imm, 5, unsupported);

    // Bits are P(1)
    // where P is use SPSR
    void function(Registers, Memory, int)[] psrTransferImmediateInstructions = [
        &cpsrWriteImmediate, &spsrWriteImmediate,
    ];

    // Bits are P(1),~L(1)
    // where P is use SPSR and L is load
    void function(Registers, Memory, int)[] psrTransferRegisterInstructions = [
        &cpsrRead, &cpsrWriteRegister, &spsrRead, &spsrWriteRegister,
    ];

    // Bits are A(1),S(1)
    // where A is accumulate and S is set flags
    void function(Registers, Memory, int)[] multiplyIntInstructions = [
        &multiplyMUL,   &multiplyMULS,   &multiplyMLA,   &multiplyMLAS,
    ];

    // Bits are ~U(1),A(1),S(1)
    // where U is unsigned, A is accumulate and S is set flags
    void function(Registers, Memory, int)[] multiplyLongInstructions = [
        &multiplyUMULL, &multiplyUMULLS, &multiplyUMLAL, &multiplyUMLALS,
        &multiplySMULL, &multiplySMULLS, &multiplySMLAL, &multiplySMLALS,
    ];

    string genInstructionTemplateTable(string instruction, int bitCount, int offset = 0) {
        auto s = "[";
        foreach (i; 0 .. 1 << bitCount) {
            if (i % 4 == 0) {
                s ~= "\n";
            }
            s ~= "&" ~ instruction ~ "!(" ~ (i + offset).to!string ~ "),";
        }
        s ~= "\n]";
        return s;
    }

    // Bits are P(1),U(1),B(1),W(1),L(1)
    // where P is pre-increment, U is up-increment, B is byte quantity, W is write back and L is load
    mixin ("void function(Registers, Memory, int)[] singleDataTransferImmediateInstructions = " ~ genInstructionTemplateTable("singleDataTransfer", 5) ~ ";");

    // Bits are P(1),U(1),B(1),W(1),L(1)
    // where P is pre-increment, U is up-increment, B is byte quantity, W is write back and L is load
    mixin ("void function(Registers, Memory, int)[] singleDataTransferRegisterInstructions = " ~ genInstructionTemplateTable("singleDataTransfer", 5, 32) ~ ";");

    string getHalfwordAndSignedDataTransferInstructionTable(bool immediate) {
        auto s = "[";
        foreach (i; 0 .. 64) {
            if (i % 4 == 0) {
                s ~= "\n";
            }
            // Insert the I bit just before P(1),U(1)
            int code = (i & 0x30) << 1 | (immediate & 1) << 4 | i & 0xF;
            // If L, then there is no opCode for ~S and ~H; otherwise only opCode for ~S and H exists
            if (code.checkBit(2) ? (code & 0b11) == 0 : (code & 0b11) != 1) {
                s ~= "&unsupported, ";
            } else if (!code.checkBit(6) && code.checkBit(3)) {
                // If post-increment, then write-back is always enabled and W should be 0
                s ~= "&unsupported, ";
            } else {
                s ~= "&halfwordAndSignedDataTransfer!(" ~ code.to!string ~ "), ";
            }
        }
        s ~= "\n]";
        return s;
    }

    // Bits are P(1),U(1),W(1),L(1),S(1),H(1)
    // where P is pre-increment, U is up-increment, W is write back and L is load, S is signed and H is halfword
    mixin ("void function(Registers, Memory, int)[] halfwordAndSignedDataTransferRegisterInstructions = " ~ getHalfwordAndSignedDataTransferInstructionTable(false) ~ ";");
    mixin ("void function(Registers, Memory, int)[] halfwordAndSignedDataTransferImmediateInstructions = " ~ getHalfwordAndSignedDataTransferInstructionTable(true) ~ ";");

    // Bits are B(1)
    // where B is byte quantity
    void function(Registers, Memory, int)[] singleDataSwapInstructions = [
        &singleDataSwapInt, &singleDataSwapByte,
    ];

    // Bits are P(1),U(1),S(1),W(1),L(1)
    // where P is pre-increment, U is up-increment, S is load PSR or force user, W is write back and L is load
    mixin ("void function(Registers, Memory, int)[] blockDataTransferInstructions = " ~ genInstructionTemplateTable("blockDataTransfer", 5) ~ ";");

    // Bits are L(1)
    // where L is link
    void function(Registers, Memory, int)[] branchAndBranchWithLinkInstructions = [
        &branch, &branchAndLink,
    ];

    /*
        The instruction encoding, modified from: http://problemkaputt.de/gbatek.htm#arminstructionsummary

        |..3 ..................2 ..................1 ..................0|
        |1_0_9_8_7_6_5_4_3_2_1_0_9_8_7_6_5_4_3_2_1_0_9_8_7_6_5_4_3_2_1_0|
        |_Cond__|0_0_0|___Op__|S|__Rn___|__Rd___|__Shift__|Typ|0|__Rm___| DataProc
        |_Cond__|0_0_0|___Op__|S|__Rn___|__Rd___|__Rs___|0|Typ|1|__Rm___| DataProc
        |_Cond__|0_0_1|___Op__|S|__Rn___|__Rd___|_Shift_|___Immediate___| DataProc
        |_Cond__|0_0_1_1_0|P|1|0|_Field_|__Rd___|_Shift_|___Immediate___| PSR Imm
        |_Cond__|0_0_0_1_0|P|L|0|_Field_|__Rd___|0_0_0_0|0_0_0_0|__Rm___| PSR Reg
        |_Cond__|0_0_0_1_0_0_1_0_1_1_1_1_1_1_1_1_1_1_1_1|0_0|L|1|__Rn___| BX,BLX
        |_Cond__|0_0_0_0_0_0|A|S|__Rd___|__Rn___|__Rs___|1_0_0_1|__Rm___| Multiply
        |_Cond__|0_0_0_0_1|U|A|S|_RdHi__|_RdLo__|__Rs___|1_0_0_1|__Rm___| MulLong
        |_Cond__|0_0_0_1_0|B|0_0|__Rn___|__Rd___|0_0_0_0|1_0_0_1|__Rm___| TransSwp12
        |_Cond__|0_0_0|P|U|0|W|L|__Rn___|__Rd___|0_0_0_0|1|S|H|1|__Rm___| TransReg10
        |_Cond__|0_0_0|P|U|1|W|L|__Rn___|__Rd___|OffsetH|1|S|H|1|OffsetL| TransImm10
        |_Cond__|0_1_0|P|U|B|W|L|__Rn___|__Rd___|_________Offset________| TransImm9
        |_Cond__|0_1_1|P|U|B|W|L|__Rn___|__Rd___|__Shift__|Typ|0|__Rm___| TransReg9
        |_Cond__|1_0_0|P|U|S|W|L|__Rn___|__________Register_List________| BlockTrans
        |_Cond__|1_0_1|L|___________________Offset______________________| B,BL,BLX
        |_Cond__|1_1_1_1|_____________Ignored_by_Processor______________| SWI

        The op code is the concatenation of bits 20 to 27 with bits 4 to 7
        For some instructions some of these bits are not used, hence the need for don't cares
        Anything not covered by the table must raise an UNDEFINED interrupt
    */

    auto merger = new TableMerger(12, &unsupported);
    merger.addSubTable("000tttttddd0", dataProcessingRegisterImmediateInstructions);
    merger.addSubTable("000ttttt0dd1", dataProcessingRegisterInstructions);
    merger.addSubTable("001tttttdddd", dataProcessingImmediateInstructions);
    merger.addSubTable("00110t10dddd", psrTransferImmediateInstructions);
    merger.addSubTable("00010tt00000", psrTransferRegisterInstructions);
    merger.addSubTable("000100100001", &branchAndExchange);
    merger.addSubTable("000000tt1001", multiplyIntInstructions);
    merger.addSubTable("00001ttt1001", multiplyLongInstructions);
    merger.addSubTable("00010t001001", singleDataSwapInstructions);
    merger.addSubTable("000tt0tt1tt1", halfwordAndSignedDataTransferRegisterInstructions);
    merger.addSubTable("000tt1tt1tt1", halfwordAndSignedDataTransferImmediateInstructions);
    merger.addSubTable("010tttttdddd", singleDataTransferImmediateInstructions);
    merger.addSubTable("011tttttddd0", singleDataTransferRegisterInstructions);
    merger.addSubTable("100tttttdddd", blockDataTransferInstructions);
    merger.addSubTable("101tdddddddd", branchAndBranchWithLinkInstructions);
    merger.addSubTable("1111dddddddd", &softwareInterrupt);

    return merger.getTable();
}

private mixin template decodeOpDataProcessing_RegShiftImm() {
    mixin decodeOpDataProcessing_RegShiftReg!true;
}

private mixin template decodeOpDataProcessing_RegShiftReg() {
    mixin decodeOpDataProcessing_RegShiftReg!false;
}

private mixin template decodeOpDataProcessing_Imm() {
    // Decode
    int rn = getBits(instruction, 16, 19);
    int rd = getBits(instruction, 12, 15);
    int op1 = registers.get(rn);
    // Get op2
    int shift = getBits(instruction, 8, 11) * 2;
    int op2 = rotateRight(instruction & 0xFF, shift);
    int carry = shift == 0 ? registers.getFlag(CPSRFlag.C) : getBit(op2, 31);
}

private mixin template decodeOpDataProcessing_RegShiftReg(bool immediateShift) {
    // Decode
    int rn = getBits(instruction, 16, 19);
    int rd = getBits(instruction, 12, 15);
    int op1 = registers.get(rn);
    // Get op2
    int shiftSrc = getBit(instruction, 4);
    static if (immediateShift) {
        int shift = getBits(instruction, 7, 11);
    } else {
        int shift = registers.get(getBits(instruction, 8, 11));
    }
    int shiftType = getBits(instruction, 5, 6);
    int carry;
    int op2 = registers.applyShift(shiftType, shift, cast(bool) shiftSrc, registers.get(instruction & 0b1111), carry);
}

private void dataProcessing_RegShiftImm(int code)(Registers registers, Memory memory, int instruction) {
    dataProcessing!(decodeOpDataProcessing_RegShiftImm, code.getBits(1, 4), code.checkBit(0))(registers, memory, instruction);
}

private void dataProcessing_RegShiftReg(int code)(Registers registers, Memory memory, int instruction) {
    dataProcessing!(decodeOpDataProcessing_RegShiftReg, code.getBits(1, 4), code.checkBit(0))(registers, memory, instruction);
}

private void dataProcessing_Imm(int code)(Registers registers, Memory memory, int instruction) {
    dataProcessing!(decodeOpDataProcessing_Imm, code.getBits(1, 4), code.checkBit(0))(registers, memory, instruction);
}

private void setDataProcessingFlags(Registers registers, int rd, int res, int overflow, int carry) {
    int zero = res == 0;
    int negative = res < 0;
    if (rd == Register.PC) {
        registers.set(Register.CPSR, registers.get(Register.SPSR));
    } else {
        registers.setAPSRFlags(negative, zero, carry, overflow);
    }
}

private void dataProcessing(alias decodeOperands, int opCode: 0, bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "AND");
    mixin decodeOperands;
    // Operation
    int res = op1 & op2;
    registers.set(rd, res);
    // Flag updates
    static if (setFlags) {
        int overflow = registers.getFlag(CPSRFlag.V);
        setDataProcessingFlags(registers, rd, res, overflow, carry);
    }
}

private void dataProcessing(alias decodeOperands, int opCode: 1, bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "EOR");
    mixin decodeOperands;
    // Operation
    int res = op1 ^ op2;
    registers.set(rd, res);
    // Flag updates
    static if (setFlags) {
        int overflow = registers.getFlag(CPSRFlag.V);
        setDataProcessingFlags(registers, rd, res, overflow, carry);
    }
}


private void dataProcessing(alias decodeOperands, int opCode: 2, bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "SUB");
    mixin decodeOperands;
    // Operation
    int res = op1 - op2;
    registers.set(rd, res);
    // Flag updates
    static if (setFlags) {
        int overflow = overflowedSub(op1, op2, res);
        carry = !borrowedSub(op1, op2, res);
        setDataProcessingFlags(registers, rd, res, overflow, carry);
    }
}

private void dataProcessing(alias decodeOperands, int opCode: 3, bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "RSB");
    mixin decodeOperands;
    // Operation
    int res = op2 - op1;
    registers.set(rd, res);
    // Flag updates
    static if (setFlags) {
        int overflow = overflowedSub(op2, op1, res);
        carry = !borrowedSub(op2, op1, res);
        setDataProcessingFlags(registers, rd, res, overflow, carry);
    }
}

private void dataProcessing(alias decodeOperands, int opCode: 4, bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "ADD");
    mixin decodeOperands;
    // Operation
    int res = op1 + op2;
    registers.set(rd, res);
    // Flag updates
    static if (setFlags) {
        int overflow = overflowedAdd(op1, op2, res);
        carry = carriedAdd(op1, op2, res);
        setDataProcessingFlags(registers, rd, res, overflow, carry);
    }
}

private void dataProcessing(alias decodeOperands, int opCode: 5, bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "ADC");
    mixin decodeOperands;
    // Operation
    int tmp = op1 + op2;
    int res = tmp + carry;
    registers.set(rd, res);
    // Flag updates
    static if (setFlags) { // TODO: check if this is correct
        int overflow = overflowedAdd(op1, op2, tmp) || overflowedAdd(tmp, carry, res);
        carry = carriedAdd(op1, op2, tmp) || carriedAdd(tmp, carry, res);
        setDataProcessingFlags(registers, rd, res, overflow, carry);
    }
}

private void dataProcessing(alias decodeOperands, int opCode: 6, bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "SBC");
    mixin decodeOperands;
    // Operation
    int tmp = op1 - op2;
    int res = tmp - !carry; // TODO: check if this is correct
    registers.set(rd, res);
    // Flag updates
    static if (setFlags) { // TODO: check if this is correct
        int overflow = overflowedSub(op1, op2, tmp) || overflowedSub(tmp, !carry, res);
        carry = !borrowedSub(op1, op2, tmp) && !borrowedSub(tmp, !carry, res);
        setDataProcessingFlags(registers, rd, res, overflow, carry);
    }
}

private void dataProcessing(alias decodeOperands, int opCode: 7, bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "RSC");
    mixin decodeOperands;
    // Operation
    int tmp = op2 - op1;
    int res = tmp - !carry; // TODO: check if this is correct
    registers.set(rd, res);
    // Flag updates
    static if (setFlags) { // TODO: check if this is correct
        int overflow = overflowedSub(op2, op1, tmp) || overflowedSub(tmp, !carry, res);
        carry = !borrowedSub(op2, op1, tmp) && !borrowedSub(tmp, !carry, res);
        setDataProcessingFlags(registers, rd, res, overflow, carry);
    }
}

private void dataProcessing(alias decodeOperands, int opCode: 8, bool setFlags: true)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "TST");
    mixin decodeOperands;
    // Operation
    int res = op1 & op2;
    // Flag updates
    int overflow = registers.getFlag(CPSRFlag.V);
    setDataProcessingFlags(registers, rd, res, overflow, carry);
}

// TODO: what does the P varient do?
private void dataProcessing(alias decodeOperands, int opCode: 9, bool setFlags: true)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "TEQ");
    mixin decodeOperands;
    // Operation
    int res = op1 ^ op2;
    // Flag updates
    int overflow = registers.getFlag(CPSRFlag.V);
    setDataProcessingFlags(registers, rd, res, overflow, carry);
}

private void dataProcessing(alias decodeOperands, int opCode: 10, bool setFlags: true)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "CMP");
    mixin decodeOperands;
    // Operation
    int res = op1 - op2;
    // Flag updates
    int overflow = overflowedSub(op1, op2, res);
    carry = !borrowedSub(op1, op2, res);
    setDataProcessingFlags(registers, rd, res, overflow, carry);
}

private void dataProcessing(alias decodeOperands, int opCode: 11, bool setFlags: true)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "CMN");
    mixin decodeOperands;
    // Operation
    int res = op1 + op2;
    // Flag updates
    int overflow = overflowedAdd(op1, op2, res);
    carry = carriedAdd(op1, op2, res);
    setDataProcessingFlags(registers, rd, res, overflow, carry);
}

private void dataProcessing(alias decodeOperands, int opCode: 12, bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "ORR");
    mixin decodeOperands;
    // Operation
    int res = op1 | op2;
    registers.set(rd, res);
    // Flag updates
    static if (setFlags) {
        int overflow = registers.getFlag(CPSRFlag.V);
        setDataProcessingFlags(registers, rd, res, overflow, carry);
    }
}

private void dataProcessing(alias decodeOperands, int opCode: 13, bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MOV");
    mixin decodeOperands;
    // Operation
    int res = op2;
    registers.set(rd, res);
    // Flag updates
    static if (setFlags) {
        int overflow = registers.getFlag(CPSRFlag.V);
        setDataProcessingFlags(registers, rd, res, overflow, carry);
    }
}

private void dataProcessing(alias decodeOperands, int opCode: 14, bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "BIC");
    mixin decodeOperands;
    // Operation
    int res = op1 & ~op2;
    registers.set(rd, res);
    // Flag updates
    static if (setFlags) {
        int overflow = registers.getFlag(CPSRFlag.V);
        setDataProcessingFlags(registers, rd, res, overflow, carry);
    }
}

private void dataProcessing(alias decodeOperands, int opCode: 15, bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MVN");
    mixin decodeOperands;
    // Operation
    int res = ~op2;
    registers.set(rd, res);
    // Flag updates
    static if (setFlags) {
        int overflow = registers.getFlag(CPSRFlag.V);
        setDataProcessingFlags(registers, rd, res, overflow, carry);
    }
}

private void dataProcessing(alias decodeOperands, int opCode, bool setFlags)(Registers registers, Memory memory, int instruction) {
    static assert (0);
}

private mixin template decodeOpPrsrImmediate() {
    int op = rotateRight(instruction & 0xFF, getBits(instruction, 8, 11) * 2);
}

private mixin template decodeOpPrsrRegister() {
    int op = registers.get(instruction & 0xF);
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

private void cpsrRead(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MRS");
    int rd = getBits(instruction, 12, 15);
    registers.set(rd, registers.get(Register.CPSR));
}

private void cpsrWrite(alias decodeOperand)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MSR");
    mixin decodeOperand;
    int mask = getPsrMask(instruction) & (0xF0000000 | (registers.getMode() != Mode.USER ? 0xCF : 0));
    int cpsr = registers.get(Register.CPSR);
    registers.set(Register.CPSR, cpsr & ~mask | op & mask);
}

private alias cpsrWriteImmediate = cpsrWrite!decodeOpPrsrImmediate;
private alias cpsrWriteRegister = cpsrWrite!decodeOpPrsrRegister;

private void spsrRead(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MRS");
    int rd = getBits(instruction, 12, 15);
    registers.set(rd, registers.get(Register.SPSR));
}

private void spsrWrite(alias decodeOperand)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MSR");
    mixin decodeOperand;
    int mask = getPsrMask(instruction) & 0xF00000EF;
    int spsr = registers.get(Register.SPSR);
    registers.set(Register.SPSR, spsr & ~mask | op & mask);
}

private alias spsrWriteImmediate = spsrWrite!decodeOpPrsrImmediate;
private alias spsrWriteRegister = spsrWrite!decodeOpPrsrRegister;

private void branchAndExchange(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "BX");
    int address = registers.get(instruction & 0xF);
    if (address & 0b1) { // TODO: check this condition
        registers.setFlag(CPSRFlag.T, Set.THUMB);
    }
    registers.set(Register.PC, address & ~1);
}

private void setMultiplyIntResult(bool setFlags)(Registers registers, int rd, int res) {
    registers.set(rd, res);
    static if (setFlags) {
        registers.setAPSRFlags(res < 0, res == 0);
    }
}

private void setMultiplyLongResult(bool setFlags)(Registers registers, int rd, int rn, long res) {
    int resLo = cast(int) res;
    int resHi = cast(int) (res >> 32);
    registers.set(rn, resLo);
    registers.set(rd, resHi);
    static if (setFlags) {
        registers.setAPSRFlags(res < 0, res == 0);
    }
}

private mixin template decodeOpMultiply() {
    int rd = getBits(instruction, 16, 19);
    int op2 = registers.get(getBits(instruction, 8, 11));
    int op1 = registers.get(instruction & 0xF);
}

private void multiplyInt(bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MUL");
    mixin decodeOpMultiply;
    int res = op1 * op2;
    setMultiplyIntResult!setFlags(registers, rd, res);
}

private alias multiplyMUL = multiplyInt!(false);
private alias multiplyMULS = multiplyInt!(true);

private void multiplyAccumulateInt(bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MLA");
    mixin decodeOpMultiply;
    int op3 = registers.get(getBits(instruction, 12, 15));
    int res = op1 * op2 + op3;
    setMultiplyIntResult!setFlags(registers, rd, res);
}

private alias multiplyMLA = multiplyAccumulateInt!(false);
private alias multiplyMLAS = multiplyAccumulateInt!(true);

private void multiplyLongUnsigned(bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "UMULL");
    mixin decodeOpMultiply;
    int rn = getBits(instruction, 12, 15);
    ulong res = ucast(op1) * ucast(op2);
    setMultiplyLongResult!setFlags(registers, rd, rn, res);
}

private alias multiplyUMULL = multiplyLongUnsigned!(false);
private alias multiplyUMULLS = multiplyLongUnsigned!(true);

private void multiplyAccumulateLongUnsigned(bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "UMLAL");
    mixin decodeOpMultiply;
    int rn = getBits(instruction, 12, 15);
    ulong op3 = ucast(registers.get(rd)) << 32 | ucast(registers.get(rn));
    ulong res = ucast(op1) * ucast(op2) + op3;
    setMultiplyLongResult!setFlags(registers, rd, rn, res);
}

private alias multiplyUMLAL = multiplyAccumulateLongUnsigned!(false);
private alias multiplyUMLALS = multiplyAccumulateLongUnsigned!(true);

private void multiplyLongSigned(bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "SMULL");
    mixin decodeOpMultiply;
    int rn = getBits(instruction, 12, 15);
    long res = cast(long) op1 * cast(long) op2;
    setMultiplyLongResult!setFlags(registers, rd, rn, res);
}

private alias multiplySMULL = multiplyLongSigned!(false);
private alias multiplySMULLS = multiplyLongSigned!(true);

private void multiplyAccumulateLongSigned(bool setFlags)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "SMLAL");
    mixin decodeOpMultiply;
    int rn = getBits(instruction, 12, 15);
    long op3 = ucast(registers.get(rd)) << 32 | ucast(registers.get(rn));
    long res = cast(long) op1 * cast(long) op2 + op3;
    setMultiplyLongResult!setFlags(registers, rd, rn, res);
}

private alias multiplySMLAL = multiplyAccumulateLongSigned!(false);
private alias multiplySMLALS = multiplyAccumulateLongSigned!(true);

private void singleDataSwap(bool byteQty)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "SWP");
    // Decode operands
    int rn = getBits(instruction, 16, 19);
    int rd = getBits(instruction, 12, 15);
    int rm = instruction & 0xF;
    int address = registers.get(rn);
    // Do memory swap
    static if (byteQty) {
        int b = memory.getByte(address) & 0xFF;
        memory.setByte(address, cast(byte) registers.get(rm));
        registers.set(rd, b);
    } else {
        int w = rotateRead(address, memory.getInt(address));
        memory.setInt(address, registers.get(rm));
        registers.set(rd, w);
    }
}

private alias singleDataSwapInt = singleDataSwap!false;
private alias singleDataSwapByte = singleDataSwap!true;

private void halfwordAndSignedDataTransfer(byte flags)(Registers registers, Memory memory, int instruction) {
    halfwordAndSignedDataTransfer!(flags.checkBit(6), flags.checkBit(5), flags.checkBit(4),
            flags.checkBit(3), flags.checkBit(2), flags.getBit(1), flags.getBit(0))(registers, memory, instruction);
}

private void halfwordAndSignedDataTransfer(bool preIncr, bool upIncr, bool immediate,
            bool writeBack, bool load, bool signed, bool half)(Registers registers, Memory memory, int instruction) {
    // Decode operands
    int rn = getBits(instruction, 16, 19);
    int rd = getBits(instruction, 12, 15);
    static if (immediate) {
        int upperOffset = getBits(instruction, 8, 11);
        int lowerOffset = instruction & 0xF;
        int offset = upperOffset << 4 | lowerOffset;
    } else {
        int offset = registers.get(instruction & 0xF);
    }
    int address = registers.get(rn);
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
        static if (half) {
            static if (signed) {
                debug (outputInstructions) registers.logInstruction(instruction, "LDRSH");
                registers.set(rd, rotateReadSigned(address, memory.getShort(address)));
            } else {
                debug (outputInstructions) registers.logInstruction(instruction, "LDRH");
                registers.set(rd, rotateRead(address, memory.getShort(address)));
            }
        } else {
            static if (signed) {
                debug (outputInstructions) registers.logInstruction(instruction, "LDRSB");
                registers.set(rd, memory.getByte(address));
            } else {
                static assert (0);
            }
        }
    } else {
        static if (half && !signed) {
            debug (outputInstructions) registers.logInstruction(instruction, "STRH");
            memory.setShort(address, cast(short) registers.get(rd));
        } else {
            static assert (0);
        }
    }
    // Do post-increment and write back if needed
    static if (preIncr) {
        static if (writeBack) {
            registers.set(rn, address);
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
        registers.set(rn, address);
    }
}

private void singleDataTransfer(byte flags)(Registers registers, Memory memory, int instruction) {
    singleDataTransfer!(flags.checkBit(5), flags.checkBit(4), flags.checkBit(3),
            flags.checkBit(2), flags.checkBit(1), flags.checkBit(0))(registers, memory, instruction);
}

private void singleDataTransfer(bool notImmediate, bool preIncr, bool upIncr, bool byteQty,
            bool writeBack, bool load)(Registers registers, Memory memory, int instruction) {
    // TODO: what does NoPrivilege do?
    // Decode operands
    int rn = getBits(instruction, 16, 19);
    int rd = getBits(instruction, 12, 15);
    static if (notImmediate) {
        int shift = getBits(instruction, 7, 11);
        int shiftType = getBits(instruction, 5, 6);
        int carry;
        int offset = registers.applyShift(shiftType, shift, false, registers.get(instruction & 0b1111), carry);
    } else {
        int offset = instruction & 0xFFF;
    }
    int address = registers.get(rn);
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
            debug (outputInstructions) registers.logInstruction(instruction, "LDRB");
            registers.set(rd, memory.getByte(address) & 0xFF);
        } else {
            debug (outputInstructions) registers.logInstruction(instruction, "LDR");
            registers.set(rd, rotateRead(address, memory.getInt(address)));
        }
    } else {
        static if (byteQty) {
            debug (outputInstructions) registers.logInstruction(instruction, "STRB");
            memory.setByte(address, cast(byte) registers.get(rd)); // TODO: check if this is correct
        } else {
            debug (outputInstructions) registers.logInstruction(instruction, "STR");
            memory.setInt(address, registers.get(rd));
        }
    }
    // Do post-increment and write back if needed
    static if (preIncr) {
        static if (writeBack) {
            registers.set(rn, address);
        }
    } else {
        static if (upIncr) {
            address += offset;
        } else {
            address -= offset;
        }
        // Always do write back in post increment
        registers.set(rn, address);
    }
}

private static string genBlockDataTransferOperation(bool preIncr, bool load) {
    auto memoryOp = load ? "registers.set(mode, i, memory.getInt(address));\n" :
            "memory.setInt(address, registers.get(mode, i));\n";
    string incr = "address += 4;\n";
    auto singleOp = preIncr ? incr ~ memoryOp : memoryOp ~ incr;
    return
        `foreach (i; 0 .. 16) {
            if (checkBit(registerList, i)) {
                ` ~ singleOp ~ `
            }
        }`;
}

private void blockDataTransfer(byte flags)(Registers registers, Memory memory, int instruction) {
    blockDataTransfer!(flags.checkBit(4), flags.checkBit(3), flags.checkBit(2),
            flags.checkBit(1), flags.checkBit(0))(registers, memory, instruction);
}

private void blockDataTransfer(bool preIncr, bool upIncr, bool loadPSR,
            bool writeBack, bool load)(Registers registers, Memory memory, int instruction) {
    static if (load) {
        debug (outputInstructions) registers.logInstruction(instruction, "LDM");
    } else {
        debug (outputInstructions) registers.logInstruction(instruction, "STM");
    }
    // Decode operands
    int rn = getBits(instruction, 16, 19);
    int registerList = instruction & 0xFFFF;
    // Force user mode or restore PSR flag
    static if (loadPSR) {
        Mode mode = Mode.USER;
        static if (load) {
            if (checkBit(registerList, 15)) {
                registers.set(Register.CPSR, registers.get(Register.SPSR));
                mode = registers.getMode();
            }
        }
    } else {
        Mode mode = registers.getMode();
    }
    // Memory transfer
    int baseAddress = registers.get(rn);
    int address;
    static if (upIncr) {
        address = baseAddress;
        mixin (genBlockDataTransferOperation(preIncr, load));
    } else {
        baseAddress -= 4 * bitCount(registerList);
        address = baseAddress;
        // Load order is always in increasing memory order, even when
        // using down-increment. This means we use bit counting to find
        // the final address and use up-increments instead. This
        // does reverse the pre-increment behaviour though
        mixin (genBlockDataTransferOperation(!preIncr, load));
        // The address to write back is the corrected base
        address = baseAddress;
    }
    static if (writeBack) {
        registers.set(mode, rn, address);
    }
}

private void branch(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "B");
    int offset = instruction & 0xFFFFFF;
    // sign extend the offset
    offset <<= 8;
    offset >>= 8;
    int pc = registers.get(Register.PC);
    registers.set(Register.PC, pc + offset * 4);
}

private void branchAndLink(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "BL");
    int offset = instruction & 0xFFFFFF;
    // sign extend the offset
    offset <<= 8;
    offset >>= 8;
    int pc = registers.get(Register.PC);
    registers.set(Register.LR, pc - 4);
    registers.set(Register.PC, pc + offset * 4);
}

private void softwareInterrupt(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "SWI");
    registers.set(Mode.SUPERVISOR, Register.SPSR, registers.get(Register.CPSR));
    registers.set(Mode.SUPERVISOR, Register.LR, registers.get(Register.PC) - 4);
    registers.set(Register.PC, 0x8);
    registers.setFlag(CPSRFlag.I, 1);
    registers.setMode(Mode.SUPERVISOR);
}

private void undefined(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "UND");
    registers.set(Mode.UNDEFINED, Register.SPSR, registers.get(Register.CPSR));
    registers.set(Mode.UNDEFINED, Register.LR, registers.get(Register.PC) - 4);
    registers.set(Register.PC, 0x4);
    registers.setFlag(CPSRFlag.I, 1);
    registers.setMode(Mode.UNDEFINED);
}

private void unsupported(Registers registers, Memory memory, int instruction) {
    throw new UnsupportedARMInstructionException(registers.get(Register.PC) - 8, instruction);
}

public class UnsupportedARMInstructionException : Exception {
    private this(int address, int instruction) {
        super(format("This ARM instruction is unsupported by the implementation\n%08x: %08x", address, instruction));
    }
}
