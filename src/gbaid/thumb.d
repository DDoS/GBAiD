module gbaid.thumb;

import std.conv;
import std.string;

import gbaid.memory;
import gbaid.cpu;
import gbaid.util;

public void function(Registers, Memory, int)[] genTHUMBTable() {
    // Bits are OpCode(2)
    void function(Registers, Memory, int)[] moveShiftedRegisterInstructions = [
        &moveShiftedRegisterLSL, &moveShiftedRegisterLSR, &moveShiftedRegisterASR, &unsupported,
    ];

    // Bits are I(1),S(1)
    // where I is immediate and S is subtract
    void function(Registers, Memory, int)[] addAndSubtractInstructions = [
        &addAndSubtract!(false, false), &addAndSubtract!(false, true),
        &addAndSubtract!(true, false),  &addAndSubtract!(true, true),
    ];

    // Bits are OpCode(2)
    void function(Registers, Memory, int)[] moveCompareAddAndSubtractImmediateInstructions = [
        &moveCompareAddAndSubtractImmediateMOV, &moveCompareAddAndSubtractImmediateCMP,
        &moveCompareAddAndSubtractImmediateADD, &moveCompareAddAndSubtractImmediateSUB,
    ];

    // Bits are OpCode(4)
    void function(Registers, Memory, int)[] aluOperationsInstructions = [
        &aluOperationsAND, &aluOperationsEOR, &aluOperationsLSL, &aluOperationsLSR,
        &aluOperationsASR, &aluOperationsADC, &aluOperationsSBC, &aluOperationsROR,
        &aluOperationsTST, &aluOperationsNEG, &aluOperationsCMP, &aluOperationsCMN,
        &aluOperationsORR, &aluOperationsMUL, &aluOperationsBIC, &aluOperationsMVN,
    ];


    // Bits are OpCode(2),HD(1),HS(1)
    // where HD is high destination and HS is high source
    void function(Registers, Memory, int)[] hiRegisterOperationsAndBranchExchangeInstructions = [
        &unsupported,                                            &hiRegisterOperationsAndBranchExchangeADD!(false, true),
        &hiRegisterOperationsAndBranchExchangeADD!(true, false), &hiRegisterOperationsAndBranchExchangeADD!(true, true),
        &unsupported,                                            &hiRegisterOperationsAndBranchExchangeCMP!(false, true),
        &hiRegisterOperationsAndBranchExchangeCMP!(true, false), &hiRegisterOperationsAndBranchExchangeCMP!(true, true),
        &unsupported,                                            &hiRegisterOperationsAndBranchExchangeMOV!(false, true),
        &hiRegisterOperationsAndBranchExchangeMOV!(true, false), &hiRegisterOperationsAndBranchExchangeMOV!(true, true),
        &hiRegisterOperationsAndBranchExchangeBX!(false, false), &hiRegisterOperationsAndBranchExchangeBX!(false, true),
        &unsupported,                                            &unsupported,
    ];

    // Bits are OpCode(2)
    void function(Registers, Memory, int)[] loadAndStoreWithRegisterOffsetInstructions = [
        &loadAndStoreWithRegisterOffsetSTR, &loadAndStoreWithRegisterOffsetSTRB,
        &loadAndStoreWithRegisterOffsetLDR, &loadAndStoreWithRegisterOffsetLDRB,
    ];

    // Bits are OpCode(2)
    void function(Registers, Memory, int)[] loadAndStoreSignExtentedByteAndHalfwordInstructions = [
        &loadAndStoreSignExtentedByteAndHalfwordSTRH, &loadAndStoreSignExtentedByteAndHalfwordLDSB,
        &loadAndStoreSignExtentedByteAndHalfwordLDRH, &loadAndStoreSignExtentedByteAndHalfwordLDSH,
    ];

    // Bits are OpCode(2)
    void function(Registers, Memory, int)[] loadAndStoreWithImmediateOffsetInstructions = [
        &loadAndStoreWithImmediateOffsetSTR,  &loadAndStoreWithImmediateOffsetLDR,
        &loadAndStoreWithImmediateOffsetSTRB, &loadAndStoreWithImmediateOffsetLDRB,
    ];

    // Bits are OpCode(1)
    void function(Registers, Memory, int)[] loadAndStoreHalfWordInstructions = [
        &loadAndStoreHalfWordSTRH, &loadAndStoreHalfWordLDRH,
    ];

    // Bits are OpCode(1)
    void function(Registers, Memory, int)[] loadAndStoreSPRelativeInstructions = [
        &loadAndStoreSPRelative!false, &loadAndStoreSPRelative!true,
    ];

    // Bits are OpCode(1)
    void function(Registers, Memory, int)[] getRelativeAddresssInstructions = [
        &getRelativeAddresss!false, &getRelativeAddresss!true,
    ];

    // Bits are S(1)
    // where S is subtract
    void function(Registers, Memory, int)[] addOffsetToStackPointerInstructions = [
        &addOffsetToStackPointer!false, &addOffsetToStackPointer!true,
    ];

    // Bits are Pop(1),R(1)
    // where Pop is pop of the stack and R is include PC or LR
    void function(Registers, Memory, int)[] pushAndPopRegistersInstructions = [
        &pushAndPopRegisters!(false, false), &pushAndPopRegisters!(false, true),
        &pushAndPopRegisters!(true, false),  &pushAndPopRegisters!(true, true),
    ];

    // Bits are L(1)
    // where L is load
    void function(Registers, Memory, int)[] multipleLoadAndStoreInstructions = [
        &multipleLoadAndStore!false, &multipleLoadAndStore!true,
    ];

    // Bits are C(4)
    // where C is condition code
    void function(Registers, Memory, int)[] conditionalBranchInstructions = [
        &conditionalBranch!0,  &conditionalBranch!1,  &conditionalBranch!2,  &conditionalBranch!3,
        &conditionalBranch!4,  &conditionalBranch!5,  &conditionalBranch!6,  &conditionalBranch!7,
        &conditionalBranch!8,  &conditionalBranch!9,  &conditionalBranch!10, &conditionalBranch!11,
        &conditionalBranch!12, &conditionalBranch!13, &unsupported,          &unsupported,
    ];

    // Bits are H(1)
    // where H is high
    void function(Registers, Memory, int)[] longBranchWithLinkInstructions = [
        &longBranchWithLink!false, &longBranchWithLink!true,
    ];

    /*

        The instruction encoding, modified from: http://problemkaputt.de/gbatek.htm#thumbinstructionsummary

        Form|_15|_14|_13|_12|_11|_10|_9_|_8_|_7_|_6_|_5_|_4_|_3_|_2_|_1_|_0_|
        __1_|_0___0___0_|__Op___|_______Offset______|____Rs_____|____Rd_____|Shifted
        __2_|_0___0___0___1___1_|_I,_Op_|___Rn/nn___|____Rs_____|____Rd_____|ADD/SUB
        __3_|_0___0___1_|__Op___|____Rd_____|_____________Offset____________|Immedi.
        __4_|_0___1___0___0___0___0_|______Op_______|____Rs_____|____Rd_____|AluOp
        __5_|_0___1___0___0___0___1_|__Op___|Hd_|Hs_|____Rs_____|____Rd_____|HiReg/BX
        __6_|_0___1___0___0___1_|____Rd_____|_____________Word______________|LDR PC
        __7_|_0___1___0___1_|__Op___|_0_|___Ro______|____Rb_____|____Rd_____|LDR/STR
        __8_|_0___1___0___1_|__Op___|_1_|___Ro______|____Rb_____|____Rd_____|LDR/STR{H/SB/SH}
        __9_|_0___1___1_|__Op___|_______Offset______|____Rb_____|____Rd_____|LDR/STR{B}
        _10_|_1___0___0___0_|Op_|_______Offset______|____Rb_____|____Rd_____|LDRH/STRH
        _11_|_1___0___0___1_|Op_|____Rd_____|_____________Word______________|LDR/STR SP
        _12_|_1___0___1___0_|Op_|____Rd_____|_____________Word______________|ADD PC/SP
        _13_|_1___0___1___1___0___0___0___0_|_S_|___________Word____________|ADD SP,nn
        _14_|_1___0___1___1_|Op_|_1___0_|_R_|____________Rlist______________|PUSH/POP
        _15_|_1___1___0___0_|Op_|____Rb_____|____________Rlist______________|STM/LDM
        _16_|_1___1___0___1_|_____Cond______|_________Signed_Offset_________|B{cond}
        _17_|_1___1___0___1___1___1___1___1_|___________User_Data___________|SWI
        _18_|_1___1___1___0___0_|________________Offset_____________________|B
        _19_|_1___1___1___1_|_H_|______________Offset_Low/High______________|BL,BLX

        The op code is bits 6 to 15
        For some instructions some of these bits are not used, hence the need for don't cares
        Anything not covered by the table must raise an UNDEFINED interrupt

    */

    auto merger = new TableMerger(10, &unsupported);
    merger.addSubTable("000ttddddd", moveShiftedRegisterInstructions);
    merger.addSubTable("00011ttddd", addAndSubtractInstructions);
    merger.addSubTable("001ttddddd", moveCompareAddAndSubtractImmediateInstructions);
    merger.addSubTable("010000tttt", aluOperationsInstructions);
    merger.addSubTable("010001tttt", hiRegisterOperationsAndBranchExchangeInstructions);
    merger.addSubTable("01001ddddd", &loadPCRelative);
    merger.addSubTable("0101tt0ddd", loadAndStoreWithRegisterOffsetInstructions);
    merger.addSubTable("0101tt1ddd", loadAndStoreSignExtentedByteAndHalfwordInstructions);
    merger.addSubTable("011ttddddd", loadAndStoreWithImmediateOffsetInstructions);
    merger.addSubTable("1000tddddd", loadAndStoreHalfWordInstructions);
    merger.addSubTable("1001tddddd", loadAndStoreSPRelativeInstructions);
    merger.addSubTable("1010tddddd", getRelativeAddresssInstructions);
    merger.addSubTable("10110000td", addOffsetToStackPointerInstructions);
    merger.addSubTable("1011t10tdd", pushAndPopRegistersInstructions);
    merger.addSubTable("1100tddddd", multipleLoadAndStoreInstructions);
    merger.addSubTable("1101ttttdd", conditionalBranchInstructions);
    merger.addSubTable("11011111dd", &softwareInterrupt);
    merger.addSubTable("11100ddddd", &unconditionalBranch);
    merger.addSubTable("1111tddddd", longBranchWithLinkInstructions);

    return merger.getTable();
}

private void moveShiftedRegister(int shiftType)(Registers registers, Memory memory, int instruction) {
    int shift = getBits(instruction, 6, 10);
    int op = registers.get(getBits(instruction, 3, 5));
    int rd = instruction & 0b111;
    static if (shiftType == 0) {
        debug (outputInstructions) registers.logInstruction(instruction, "LSL");
    } else static if (shiftType == 1) {
        debug (outputInstructions) registers.logInstruction(instruction, "LSR");
    } else static if (shiftType == 2) {
        debug (outputInstructions) registers.logInstruction(instruction, "ASR");
    } else {
        static assert (0);
    }
    int carry;
    op = registers.applyShift(shiftType, shift, false, op, carry);
    registers.set(rd, op);
    registers.setAPSRFlags(op < 0, op == 0, carry);
}

private alias moveShiftedRegisterLSL = moveShiftedRegister!0;
private alias moveShiftedRegisterLSR = moveShiftedRegister!1;
private alias moveShiftedRegisterASR = moveShiftedRegister!2;

private void addAndSubtract(bool immediate, bool subtract)(Registers registers, Memory memory, int instruction) {
    int rn = getBits(instruction, 6, 8);
    static if (immediate) {
        // immediate
        int op2 = rn;
    } else {
        // register
        int op2 = registers.get(rn);
    }
    int op1 = registers.get(getBits(instruction, 3, 5));
    int rd = instruction & 0b111;
    static if (subtract) {
        // SUB
        debug (outputInstructions) registers.logInstruction(instruction, "SUB");
        int res = op1 - op2;
        int carry = !borrowedSub(op1, op2, res);
        int overflow = overflowedSub(op1, op2, res);
    } else {
        // ADD
        debug (outputInstructions) registers.logInstruction(instruction, "ADD");
        int res = op1 + op2;
        int carry = carriedAdd(op1, op2, res);
        int overflow = overflowedAdd(op1, op2, res);
    }
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0, carry, overflow);
}

private mixin template decodeOpMoveCompareAddAndSubtractImmediate(bool op1) {
    int rd = getBits(instruction, 8, 10);
    int op2 = instruction & 0xFF;
    static if (op1) {
        int op1 = registers.get(rd);
    }
}

private void moveCompareAddAndSubtractImmediateMOV(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MOV");
    mixin decodeOpMoveCompareAddAndSubtractImmediate!false;
    registers.set(rd, op2);
    registers.setAPSRFlags(op2 < 0, op2 == 0);
}

private void moveCompareAddAndSubtractImmediateCMP(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "CMP");
    mixin decodeOpMoveCompareAddAndSubtractImmediate!true;
    int v = op1 - op2;
    registers.setAPSRFlags(v < 0, v == 0, !borrowedSub(op1, op2, v), overflowedSub(op1, op2, v));
}

private void moveCompareAddAndSubtractImmediateADD(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "ADD");
    mixin decodeOpMoveCompareAddAndSubtractImmediate!true;
    int res = op1 + op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0, carriedAdd(op1, op2, res), overflowedAdd(op1, op2, res));
}

private void moveCompareAddAndSubtractImmediateSUB(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "SUB");
    mixin decodeOpMoveCompareAddAndSubtractImmediate!true;
    int res = op1 - op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0, !borrowedSub(op1, op2, res), overflowedSub(op1, op2, res));
}

private mixin template decodeOpAluOperations() {
    int op2 = registers.get(getBits(instruction, 3, 5));
    int rd = instruction & 0b111;
    int op1 = registers.get(rd);
}

private void aluOperationsAND(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "AND");
    mixin decodeOpAluOperations;
    int res = op1 & op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0);
}

private void aluOperationsEOR(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "EOR");
    mixin decodeOpAluOperations;
    int res = op1 ^ op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0);
}

private void aluOperationsShift(int type)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LSL");
    mixin decodeOpAluOperations;
    int carry;
    int res = registers.applyShift(type, op2 & 0xFF, true, op1, carry);
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0, carry);
}

private alias aluOperationsLSL = aluOperationsShift!0;
private alias aluOperationsLSR = aluOperationsShift!1;
private alias aluOperationsASR = aluOperationsShift!2;
private alias aluOperationsROR = aluOperationsShift!3;

private void aluOperationsADC(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "ADC");
    mixin decodeOpAluOperations;
    int carry = registers.getFlag(CPSRFlag.C);
    int tmp = op1 + op2;
    int res = tmp + carry;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0,
        carriedAdd(op1, op2, tmp) || carriedAdd(tmp, carry, res),
        overflowedAdd(op1, op2, tmp) || overflowedAdd(tmp, carry, res));
}

private void aluOperationsSBC(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "SBC");
    mixin decodeOpAluOperations;
    int carry = registers.getFlag(CPSRFlag.C);
    int tmp = op1 - op2;
    int res = tmp - !carry;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0,
        !borrowedSub(op1, op2, tmp) && !borrowedSub(tmp, !carry, res),
        overflowedSub(op1, op2, tmp) || overflowedSub(tmp, !carry, res));
}

private void aluOperationsTST(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "TST");
    mixin decodeOpAluOperations;
    int v = op1 & op2;
    registers.setAPSRFlags(v < 0, v == 0);
}

private void aluOperationsNEG(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "NEG");
    mixin decodeOpAluOperations;
    int res = 0 - op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0, !borrowedSub(0, op2, res), overflowedSub(0, op2, res));
}

private void aluOperationsCMP(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "CMP");
    mixin decodeOpAluOperations;
    int v = op1 - op2;
    registers.setAPSRFlags(v < 0, v == 0, !borrowedSub(op1, op2, v), overflowedSub(op1, op2, v));
}

private void aluOperationsCMN(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "CMN");
    mixin decodeOpAluOperations;
    int v = op1 + op2;
    registers.setAPSRFlags(v < 0, v == 0, carriedAdd(op1, op2, v), overflowedAdd(op1, op2, v));
}

private void aluOperationsORR(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "ORR");
    mixin decodeOpAluOperations;
    int res = op1 | op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0);
}

private void aluOperationsMUL(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MUL");
    mixin decodeOpAluOperations;
    int res = op1 * op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0);
}

private void aluOperationsBIC(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "BIC");
    mixin decodeOpAluOperations;
    int res = op1 & ~op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0);
}

private void aluOperationsMVN(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MNV");
    mixin decodeOpAluOperations;
    int res = ~op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0);
}

private mixin template decodeOpHiRegisterOperationsAndBranchExchange(bool highDestination, bool highSource) {
    static if (highSource) {
        int rs = getBits(instruction, 3, 5) | 0b1000;
    } else {
        int rs = getBits(instruction, 3, 5);
    }
    static if (highDestination) {
        int rd = instruction & 0b111 | 0b1000;
    } else {
        int rd = instruction & 0b111;
    }
}

private void hiRegisterOperationsAndBranchExchangeADD(bool highDestination, bool highSource)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "ADD");
    mixin decodeOpHiRegisterOperationsAndBranchExchange!(highDestination, highSource);
    registers.set(rd, registers.get(rd) + registers.get(rs));
}

private void hiRegisterOperationsAndBranchExchangeCMP(bool highDestination, bool highSource)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "CMP");
    mixin decodeOpHiRegisterOperationsAndBranchExchange!(highDestination, highSource);
    int op1 = registers.get(rd);
    int op2 = registers.get(rs);
    int v = op1 - op2;
    registers.setAPSRFlags(v < 0, v == 0, !borrowedSub(op1, op2, v), overflowedSub(op1, op2, v));
}

private void hiRegisterOperationsAndBranchExchangeMOV(bool highDestination, bool highSource)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MOV");
    mixin decodeOpHiRegisterOperationsAndBranchExchange!(highDestination, highSource);
    registers.set(rd, registers.get(rs));
}

private void hiRegisterOperationsAndBranchExchangeBX(bool highDestination, bool highSource)(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "BX");
    mixin decodeOpHiRegisterOperationsAndBranchExchange!(highDestination, highSource);
    int address = registers.get(rs);
    if (!(address & 0b1)) {
        registers.setFlag(CPSRFlag.T, Set.ARM);
    }
    registers.set(Register.PC, address & ~1);
}

private void loadPCRelative(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDR");
    int rd = getBits(instruction, 8, 10);
    int offset = (instruction & 0xFF) * 4;
    int pc = registers.get(Register.PC);
    int address = (pc & ~3) + offset;
    registers.set(rd, rotateRead(address, memory.getInt(address)));
}

private mixin template decodeOpLoadAndStoreWithRegisterOffset() {
    int offset = registers.get(getBits(instruction, 6, 8));
    int base = registers.get(getBits(instruction, 3, 5));
    int rd = instruction & 0b111;
    int address = base + offset;
}

private void loadAndStoreWithRegisterOffsetSTR(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "STR");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    memory.setInt(address, registers.get(rd));
}

private void loadAndStoreWithRegisterOffsetSTRB(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "STRB");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    memory.setByte(address, cast(byte) registers.get(rd));
}

private void loadAndStoreWithRegisterOffsetLDR(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDR");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    registers.set(rd, rotateRead(address, memory.getInt(address)));
}

private void loadAndStoreWithRegisterOffsetLDRB(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDRB");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    registers.set(rd, memory.getByte(address) & 0xFF);
}

private void loadAndStoreSignExtentedByteAndHalfwordSTRH(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "STRH");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    memory.setShort(address, cast(short) registers.get(rd));
}

private void loadAndStoreSignExtentedByteAndHalfwordLDSB(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDSB");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    registers.set(rd, memory.getByte(address));
}

private void loadAndStoreSignExtentedByteAndHalfwordLDRH(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDRH");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    registers.set(rd, rotateRead(address, memory.getShort(address)));
}

private void loadAndStoreSignExtentedByteAndHalfwordLDSH(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDSH");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    registers.set(rd, rotateReadSigned(address, memory.getShort(address)));
}

private mixin template decodeOpLoadAndStoreWithImmediateOffset() {
    int offset = getBits(instruction, 6, 10);
    int base = registers.get(getBits(instruction, 3, 5));
    int rd = instruction & 0b111;
}

private void loadAndStoreWithImmediateOffsetSTR(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "STR");
    mixin decodeOpLoadAndStoreWithImmediateOffset;
    int address = base + offset * 4;
    memory.setInt(address, registers.get(rd));
}

private void loadAndStoreWithImmediateOffsetLDR(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDR");
    mixin decodeOpLoadAndStoreWithImmediateOffset;
    int address = base + offset * 4;
    registers.set(rd, rotateRead(address, memory.getInt(address)));
}

private void loadAndStoreWithImmediateOffsetSTRB(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "STRB");
    mixin decodeOpLoadAndStoreWithImmediateOffset;
    int address = base + offset;
    memory.setByte(address, cast(byte) registers.get(rd));
}

private void loadAndStoreWithImmediateOffsetLDRB(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDRB");
    mixin decodeOpLoadAndStoreWithImmediateOffset;
    int address = base + offset;
    registers.set(rd, memory.getByte(address) & 0xFF);
}

private void loadAndStoreHalfWordLDRH(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDRH");
    mixin decodeOpLoadAndStoreWithImmediateOffset;
    int address = base + offset * 2;
    registers.set(rd, rotateRead(address, memory.getShort(address)));
}

private void loadAndStoreHalfWordSTRH(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "STRH");
    mixin decodeOpLoadAndStoreWithImmediateOffset;
    int address = base + offset * 2;
    memory.setShort(address, cast(short) registers.get(rd));
}

private void loadAndStoreSPRelative(bool load)(Registers registers, Memory memory, int instruction) {
    int rd = getBits(instruction, 8, 10);
    int offset = (instruction & 0xFF) * 4;
    int sp = registers.get(Register.SP);
    int address = sp + offset;
    static if (load) {
        debug (outputInstructions) registers.logInstruction(instruction, "LDR");
        registers.set(rd, rotateRead(address, memory.getInt(address)));
    } else {
        debug (outputInstructions) registers.logInstruction(instruction, "STR");
        memory.setInt(address, registers.get(rd));
    }
}

private void getRelativeAddresss(bool stackPointer)(Registers registers, Memory memory, int instruction) {
    int rd = getBits(instruction, 8, 10);
    int offset = (instruction & 0xFF) * 4;
    static if (stackPointer) {
        debug (outputInstructions) registers.logInstruction(instruction, "ADD");
        registers.set(rd, registers.get(Register.SP) + offset);
    } else {
        debug (outputInstructions) registers.logInstruction(instruction, "ADD");
        registers.set(rd, (registers.get(Register.PC) & ~3) + offset);
    }
}

private void addOffsetToStackPointer(bool subtract)(Registers registers, Memory memory, int instruction) {
    int offset = (instruction & 0x7F) * 4;
    static if (subtract) {
        debug (outputInstructions) registers.logInstruction(instruction, "ADD");
        registers.set(Register.SP, registers.get(Register.SP) - offset);
    } else {
        debug (outputInstructions) registers.logInstruction(instruction, "ADD");
        registers.set(Register.SP, registers.get(Register.SP) + offset);
    }
}

private void pushAndPopRegisters(bool pop, bool pcAndLR)(Registers registers, Memory memory, int instruction) {
    int registerList = instruction & 0xFF;
    int sp = registers.get(Register.SP);
    static if (pop) {
        debug (outputInstructions) registers.logInstruction(instruction, "POP");
        foreach (i; 0 .. 8) {
            if (checkBit(registerList, i)) {
                registers.set(i, memory.getInt(sp));
                sp += 4;
            }
        }
        static if (pcAndLR) {
            registers.set(Register.PC, memory.getInt(sp));
            sp += 4;
        }
    } else {
        debug (outputInstructions) registers.logInstruction(instruction, "PUSH");
        sp -= 4 * (bitCount(registerList) + pcAndLR);
        int address = sp;
        foreach (i; 0 .. 8) {
            if (checkBit(registerList, i)) {
                memory.setInt(address, registers.get(i));
                address += 4;
            }
        }
        static if (pcAndLR) {
            memory.setInt(address, registers.get(Register.LR));
        }
    }
    registers.set(Register.SP, sp);
}

private void multipleLoadAndStore(bool load)(Registers registers, Memory memory, int instruction) {
    int rb = getBits(instruction, 8, 10);
    int registerList = instruction & 0xFF;
    int address = registers.get(rb);
    static if (load) {
        debug (outputInstructions) registers.logInstruction(instruction, "LDMIA");
        foreach (i; 0 .. 8) {
            if (checkBit(registerList, i)) {
                registers.set(i, memory.getInt(address));
                address += 4;
            }
        }
    } else {
        debug (outputInstructions) registers.logInstruction(instruction, "STMIA");
        foreach (i; 0 .. 8) {
            if (checkBit(registerList, i)) {
                memory.setInt(address, registers.get(i));
                address += 4;
            }
        }
    }
    registers.set(rb, address);
}

private void conditionalBranch(byte condition)(Registers registers, Memory memory, int instruction) {
    if (!registers.checkCondition(condition)) {
        return;
    }
    debug (outputInstructions) registers.logInstruction(instruction, "B");
    int offset = instruction & 0xFF;
    // sign extend the offset
    offset <<= 24;
    offset >>= 24;
    registers.set(Register.PC, registers.get(Register.PC) + offset * 2);
}

private void softwareInterrupt(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "SWI");
    registers.set(Mode.SUPERVISOR, Register.SPSR, registers.get(Register.CPSR));
    registers.setFlag(CPSRFlag.I, 1);
    registers.setFlag(CPSRFlag.T, Set.ARM);
    registers.set(Mode.SUPERVISOR, Register.LR, registers.get(Register.PC) - 2);
    registers.set(Register.PC, 0x8);
    registers.setMode(Mode.SUPERVISOR);
}

private void unconditionalBranch(Registers registers, Memory memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "B");
    int offset = instruction & 0x7FF;
    // sign extend the offset
    offset <<= 21;
    offset >>= 21;
    registers.set(Register.PC, registers.get(Register.PC) + offset * 2);
}

private void longBranchWithLink(bool high)(Registers registers, Memory memory, int instruction) {
    int offset = instruction & 0x7FF;
    static if (high) {
        debug (outputInstructions) registers.logInstruction(instruction, "BL");
        int address = registers.get(Register.LR) + (offset << 1);
        registers.set(Register.LR, registers.get(Register.PC) - 2 | 1);
        registers.set(Register.PC, address);
    } else {
        debug (outputInstructions) registers.logInstruction(instruction, "BL_");
        // sign extend the offset
        offset <<= 21;
        offset >>= 21;
        registers.set(Register.LR, registers.get(Register.PC) + (offset << 12));
    }
}

private void unsupported(Registers registers, Memory memory, int instruction) {
    throw new UnsupportedTHUMBInstructionException(registers.get(Register.PC) - 4, instruction);
}

public class UnsupportedTHUMBInstructionException : Exception {
    private this(int address, int instruction) {
        super(format("This THUMB instruction is unsupported by the implementation\n%08x: %04x", address, instruction & 0xFFFF));
    }
}
