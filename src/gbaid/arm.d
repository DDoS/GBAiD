module gbaid.arm;

import std.string;

import gbaid.memory;
import gbaid.cpu;
import gbaid.util;

// Using enum leads to a severe performance penalty for some reason...
private immutable ARM_EXECUTORS = createARMTable();

public void executeARMInstruction(Registers registers, Memory memory, int instruction) {
    if (!registers.checkCondition(instruction >>> 28)) {
        return;
    }
    int code = getBits(instruction, 20, 27) << 4 | getBits(instruction, 4, 7);
    ARM_EXECUTORS[code](registers, memory, instruction);
}

private Executor[] createARMTable() {
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

    auto table = createTable!(unsupported)(12);

    // Bits are OpCode(4),S(1)
    // where S is set flags
    addSubTable!("000tttttddd0", dataProcessing_RegShiftImm, unsupported)(table);
    addSubTable!("000ttttt0dd1", dataProcessing_RegShiftReg, unsupported)(table);
    addSubTable!("001tttttdddd", dataProcessing_Imm, unsupported)(table);

    // Bits are P(1)
    // where P is use SPSR
    addSubTable!("00110t10dddd", psrTransfer_Imm, unsupported)(table);

    // Bits are P(1),~L(1)
    // where P is use SPSR and L is load
    addSubTable!("00010tt00000", psrTransfer_Reg, unsupported)(table);

    // No bits
    addSubTable!("000100100001", branchAndExchange, unsupported)(table);

    // Bits are A(1),S(1)
    // where A is accumulate and S is set flags
    addSubTable!("000000tt1001", multiply_Int, unsupported)(table);

    // Bits are ~U(1),A(1),S(1)
    // where U is unsigned, A is accumulate and S is set flags
    addSubTable!("00001ttt1001", multiply_Long, unsupported)(table);

    // Bits are B(1)
    // where B is byte quantity
    addSubTable!("00010t001001", singleDataSwap, unsupported)(table);

    // Bits are P(1),U(1),W(1),L(1),S(1),H(1)
    // where P is pre-increment, U is up-increment, W is write back and L is load, S is signed and H is halfword
    addSubTable!("000tt0tt1tt1", halfwordAndSignedDataTransfer_Reg, unsupported)(table);
    addSubTable!("000tt1tt1tt1", halfwordAndSignedDataTransfer_Imm, unsupported)(table);

    // Bits are P(1),U(1),B(1),W(1),L(1)
    // where P is pre-increment, U is up-increment, B is byte quantity, W is write back and L is load
    addSubTable!("010tttttdddd", singleDataTransfer_Imm, unsupported)(table);
    addSubTable!("011tttttddd0", singleDataTransfer_Reg, unsupported)(table);

    // Bits are P(1),U(1),S(1),W(1),L(1)
    // where P is pre-increment, U is up-increment, S is load PSR or force user, W is write back and L is load
    addSubTable!("100tttttdddd", blockDataTransfer, unsupported)(table);

    // Bits are L(1)
    // where L is link
    addSubTable!("101tdddddddd", branchAndBranchWithLink, unsupported)(table);

    // No bits
    addSubTable!("1111dddddddd", softwareInterrupt, unsupported)(table);

    return table;
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
    static if (immediateShift) {
        int shift = getBits(instruction, 7, 11);
    } else {
        int shift = registers.get(getBits(instruction, 8, 11));
    }
    int shiftType = getBits(instruction, 5, 6);
    int carry;
    int op2 = registers.applyShift!(!immediateShift)(shiftType, shift, registers.get(instruction & 0b1111), carry);
}

private template dataProcessing_RegShiftImm(int code) if (code.getBits(5, 31) == 0) {
    private alias dataProcessing_RegShiftImm =
        dataProcessing!(decodeOpDataProcessing_RegShiftImm, code.getBits(1, 4), code.checkBit(0));
}

private template dataProcessing_RegShiftReg(int code) if (code.getBits(5, 31) == 0) {
    private alias dataProcessing_RegShiftReg =
        dataProcessing!(decodeOpDataProcessing_RegShiftReg, code.getBits(1, 4), code.checkBit(0));
}

private template dataProcessing_Imm(int code) if (code.getBits(5, 31) == 0) {
    private alias dataProcessing_Imm =
        dataProcessing!(decodeOpDataProcessing_Imm, code.getBits(1, 4), code.checkBit(0));
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

@("unsupported")
private template dataProcessing(alias decodeOperands, int opCode, bool setFlags)
        if (opCode >= 8 && opCode <= 11 && !setFlags) {
    private alias dataProcessing = unsupported;
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

private mixin template decodeOpPsrTransfer_Imm() {
    int op = rotateRight(instruction & 0xFF, getBits(instruction, 8, 11) * 2);
}

private mixin template decodeOpPsrTransfer_Reg() {
    int op = registers.get(instruction & 0xF);
}

private template psrTransfer_Imm(int code) if (code.getBits(1, 31) == 0) {
    private alias psrTransfer_Imm = psrTransfer!(decodeOpPsrTransfer_Imm, code.checkBit(0), true);
}

private template psrTransfer_Reg(int code) if (code.getBits(2, 31) == 0) {
    private alias psrTransfer_Reg = psrTransfer!(decodeOpPsrTransfer_Reg, code.checkBit(1), code.checkBit(0));
}

private void psrTransfer(alias decodeOperand, bool useSPSR: false, bool notLoad: false)(Registers registers, Memory memory, int instruction)
        if (__traits(isSame, decodeOperand, decodeOpPsrTransfer_Reg)) {
    debug (outputInstructions) registers.logInstruction(instruction, "MRS");
    int rd = getBits(instruction, 12, 15);
    registers.set(rd, registers.get(Register.CPSR));
}

private void psrTransfer(alias decodeOperand, bool useSPSR: false, bool notLoad: true)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MSR");
    mixin decodeOperand;
    int mask = getPsrMask(instruction) & (0xF0000000 | (registers.getMode() != Mode.USER ? 0xCF : 0));
    int cpsr = registers.get(Register.CPSR);
    registers.set(Register.CPSR, cpsr & ~mask | op & mask);
}

private void psrTransfer(alias decodeOperand, bool useSPSR: true, bool notLoad: false)(Registers registers, Memory memory, int instruction)
        if (__traits(isSame, decodeOperand, decodeOpPsrTransfer_Reg)) {
    debug (outputInstructions) registers.logInstruction(instruction, "MRS");
    int rd = getBits(instruction, 12, 15);
    registers.set(rd, registers.get(Register.SPSR));
}

private void psrTransfer(alias decodeOperand, bool useSPSR: true, bool notLoad: true)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MSR");
    mixin decodeOperand;
    int mask = getPsrMask(instruction) & 0xF00000EF;
    int spsr = registers.get(Register.SPSR);
    registers.set(Register.SPSR, spsr & ~mask | op & mask);
}

@("unsupported")
private template psrTransfer(alias decodeOperand, bool useSPSR, bool notLoad)
        if (!notLoad && !__traits(isSame, decodeOperand, decodeOpPsrTransfer_Reg)) {
    private alias psrTransfer = unsupported;
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

private void branchAndExchange()(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "BX");
    int address = registers.get(instruction & 0xF);
    if (address & 0b1) { // TODO: check this condition
        registers.setFlag(CPSRFlag.T, Set.THUMB);
    }
    registers.set(Register.PC, address & ~1);
}

private mixin template decodeOpMultiply() {
    int rd = getBits(instruction, 16, 19);
    int op2 = registers.get(getBits(instruction, 8, 11));
    int op1 = registers.get(instruction & 0xF);
}

private template multiply_Int(int code) if (code.getBits(2, 31) == 0) {
    private alias multiply_Int = multiply!(false, false, code.checkBit(1), code.checkBit(0));
}

private template multiply_Long(int code) if (code.getBits(3, 31) == 0) {
    private alias multiply_Long = multiply!(true, code.checkBit(2), code.checkBit(1), code.checkBit(0));
}

private void multiply(bool long_: false, bool notUnsigned: false, bool accumulate: false, bool setFlags)
        (Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MUL");
    mixin decodeOpMultiply;
    int res = op1 * op2;
    setMultiplyIntResult!setFlags(registers, rd, res);
}

private void multiply(bool long_: false, bool notUnsigned: false, bool accumulate: true, bool setFlags)
        (Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MLA");
    mixin decodeOpMultiply;
    int op3 = registers.get(getBits(instruction, 12, 15));
    int res = op1 * op2 + op3;
    setMultiplyIntResult!setFlags(registers, rd, res);
}

private void multiply(bool long_: true, bool notUnsigned: false, bool accumulate: false, bool setFlags)
        (Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "UMULL");
    mixin decodeOpMultiply;
    int rn = getBits(instruction, 12, 15);
    ulong res = ucast(op1) * ucast(op2);
    setMultiplyLongResult!setFlags(registers, rd, rn, res);
}

private void multiply(bool long_: true, bool notUnsigned: false, bool accumulate: true, bool setFlags)
        (Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "UMLAL");
    mixin decodeOpMultiply;
    int rn = getBits(instruction, 12, 15);
    ulong op3 = ucast(registers.get(rd)) << 32 | ucast(registers.get(rn));
    ulong res = ucast(op1) * ucast(op2) + op3;
    setMultiplyLongResult!setFlags(registers, rd, rn, res);
}

private void multiply(bool long_: true, bool notUnsigned: true, bool accumulate: false, bool setFlags)
        (Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "SMULL");
    mixin decodeOpMultiply;
    int rn = getBits(instruction, 12, 15);
    long res = cast(long) op1 * cast(long) op2;
    setMultiplyLongResult!setFlags(registers, rd, rn, res);
}

private void multiply(bool long_: true, bool notUnsigned: true, bool accumulate: true, bool setFlags)
        (Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "SMLAL");
    mixin decodeOpMultiply;
    int rn = getBits(instruction, 12, 15);
    long op3 = ucast(registers.get(rd)) << 32 | ucast(registers.get(rn));
    long res = cast(long) op1 * cast(long) op2 + op3;
    setMultiplyLongResult!setFlags(registers, rd, rn, res);
}

@("unsupported")
private template multiply(bool long_, bool notUnsigned, bool accumulate, bool setFlags)
        if (!long_ && notUnsigned) {
    private alias multiply = unsupported;
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

private template singleDataSwap(int code) if (code.getBits(1, 31) == 0) {
    private alias singleDataSwap = singleDataSwap!(code.checkBit(0));
}

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

private template halfwordAndSignedDataTransfer_Reg(int code) if (code.getBits(6, 31) == 0) {
    private alias halfwordAndSignedDataTransfer_Reg = halfwordAndSignedDataTransfer!(
        code.checkBit(5), code.checkBit(4), false, code.checkBit(3),
        code.checkBit(2), code.getBit(1), code.getBit(0)
    );
}

private template halfwordAndSignedDataTransfer_Imm(int code) if (code.getBits(6, 31) == 0) {
    private alias halfwordAndSignedDataTransfer_Imm = halfwordAndSignedDataTransfer!(
        code.checkBit(5), code.checkBit(4), true, code.checkBit(3),
        code.checkBit(2), code.getBit(1), code.getBit(0)
    );
}

private void halfwordAndSignedDataTransfer(bool preIncr, bool upIncr, bool immediate,
        bool writeBack, bool load, bool signed, bool half)(Registers registers, Memory memory, int instruction)
        if ((!load || half || signed) && (load || half && !signed) && (preIncr || !writeBack)) {
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

@("unsupported")
private template halfwordAndSignedDataTransfer(bool preIncr, bool upIncr, bool immediate,
        bool writeBack, bool load, bool signed, bool half)
        if (load && !half && !signed ||
            !load && (!half || signed) ||
            !preIncr && writeBack) {
    private alias halfwordAndSignedDataTransfer = unsupported;
}

private template singleDataTransfer_Imm(int code) if (code.getBits(5, 31) == 0) {
    private alias singleDataTransfer_Imm = singleDataTransfer!(
        false, code.checkBit(4), code.checkBit(3), code.checkBit(2),
        code.checkBit(1), code.checkBit(0)
    );
}

private template singleDataTransfer_Reg(int code) if (code.getBits(5, 31) == 0) {
    private alias singleDataTransfer_Reg = singleDataTransfer!(
        true, code.checkBit(4), code.checkBit(3), code.checkBit(2),
        code.checkBit(1), code.checkBit(0)
    );
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
        int offset = registers.applyShift!false(shiftType, shift, registers.get(instruction & 0b1111), carry);
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

private template blockDataTransfer(int code) if (code.getBits(5, 31) == 0) {
    private alias blockDataTransfer = blockDataTransfer!(
        code.checkBit(4), code.checkBit(3), code.checkBit(2),
        code.checkBit(1), code.checkBit(0)
    );
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

private void branchAndBranchWithLink(int code: 0)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "B");
    int offset = instruction & 0xFFFFFF;
    // sign extend the offset
    offset <<= 8;
    offset >>= 8;
    int pc = registers.get(Register.PC);
    registers.set(Register.PC, pc + offset * 4);
}

private void branchAndBranchWithLink(int code: 1)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "BL");
    int offset = instruction & 0xFFFFFF;
    // sign extend the offset
    offset <<= 8;
    offset >>= 8;
    int pc = registers.get(Register.PC);
    registers.set(Register.LR, pc - 4);
    registers.set(Register.PC, pc + offset * 4);
}

private void softwareInterrupt()(Registers registers, Memory memory, int instruction) {
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
    throw new UnsupportedARMInstructionException(registers.getExecutedPC(), instruction);
}

public class UnsupportedARMInstructionException : Exception {
    private this(int address, int instruction) {
        super(format("This ARM instruction is unsupported by the implementation\n%08x: %08x", address, instruction));
    }
}
