module gbaid.gba.thumb;

import std.string : format;

import gbaid.util;

import gbaid.gba.memory;
import gbaid.gba.cpu;

private enum THUMB_OPCODE_BIT_COUNT = 10;
// Using enum leads to a severe performance penalty for some reason...
private immutable Executor[1 << THUMB_OPCODE_BIT_COUNT] THUMB_EXECUTORS = createTHUMBTable();

public void executeTHUMBInstruction(Registers* registers, MemoryBus* memory, int instruction) {
    int code = instruction.getBits(6, 15);
    THUMB_EXECUTORS[code](registers, memory, instruction);
}

private Executor[] createTHUMBTable() {
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

    auto table = createTable!(unsupported)(THUMB_OPCODE_BIT_COUNT);

    // Bits are OpCode(2)
    addSubTable!("000ttddddd", moveShiftedRegister, unsupported)(table);

    // Bits are I(1),S(1)
    // where I is immediate and S is subtract
    addSubTable!("00011ttddd", addAndSubtract, unsupported)(table);

    // Bits are OpCode(2)
    addSubTable!("001ttddddd", moveCompareAddAndSubtractImmediate, unsupported)(table);

    // Bits are OpCode(4)
    addSubTable!("010000tttt", aluOperations, unsupported)(table);

    // Bits are OpCode(2),HD(1),HS(1)
    // where HD is high destination and HS is high source
    addSubTable!("010001tttt", hiRegisterOperationsAndBranchExchange, unsupported)(table);

    // No bits
    addSubTable!("01001ddddd", loadPCRelative, unsupported)(table);

    // Bits are OpCode(2)
    addSubTable!("0101tt0ddd", loadAndStoreWithRegisterOffset, unsupported)(table);

    // Bits are OpCode(2)
    addSubTable!("0101tt1ddd", loadAndStoreSignExtentedByteAndHalfword, unsupported)(table);

    // Bits are OpCode(2)
    addSubTable!("011ttddddd", loadAndStoreWithImmediateOffset, unsupported)(table);

    // Bits are OpCode(1)
    addSubTable!("1000tddddd", loadAndStoreHalfWord, unsupported)(table);

    // Bits are OpCode(1)
    addSubTable!("1001tddddd", loadAndStoreSPRelative, unsupported)(table);

    // Bits are OpCode(1)
    addSubTable!("1010tddddd", getRelativeAddresss, unsupported)(table);

    // Bits are S(1)
    // where S is subtract
    addSubTable!("10110000td", addOffsetToStackPointer, unsupported)(table);

    // Bits are Pop(1),R(1)
    // where Pop is pop of the stack and R is include PC or LR
    addSubTable!("1011t10tdd", pushAndPopRegisters, unsupported)(table);

    // Bits are L(1)
    // where L is load
    addSubTable!("1100tddddd", multipleLoadAndStore, unsupported)(table);

    // Bits are C(4)
    // where C is condition code
    addSubTable!("1101ttttdd", conditionalBranch, unsupported)(table);

    // No bits
    addSubTable!("11011111dd", softwareInterrupt, unsupported)(table);

    // No bits
    addSubTable!("11100ddddd", unconditionalBranch, unsupported)(table);

    // Bits are H(1)
    // where H is high
    addSubTable!("1111tddddd", longBranchWithLink, unsupported)(table);

    return table;
}

private void moveShiftedRegister(int code)(Registers* registers, MemoryBus* memory, int instruction)
        if (code >= 0 && code <= 2) {
    int shift = instruction.getBits(6, 10);
    int op = registers.get(instruction.getBits(3, 5));
    int rd = instruction & 0b111;
    static if (code == 0) {
        debug (outputInstructions) registers.logInstruction(instruction, "LSL");
    } else static if (code == 1) {
        debug (outputInstructions) registers.logInstruction(instruction, "LSR");
    } else {
        debug (outputInstructions) registers.logInstruction(instruction, "ASR");
    }
    int carry;
    op = registers.applyShift!false(code, shift, op, carry);
    registers.set(rd, op);
    registers.setAPSRFlags(op < 0, op == 0, carry);
}

@("unsupported")
private template moveShiftedRegister(int code: 3) {
    private alias moveShiftedRegister = unsupported;
}

private template addAndSubtract(int code) if (code.getBits(2, 31) == 0) {
    private alias addAndSubtract = addAndSubtract!(code.checkBit(1), code.checkBit(0));
}

private void addAndSubtract(bool immediate, bool subtract)(Registers* registers, MemoryBus* memory, int instruction) {
    int rn = instruction.getBits(6, 8);
    static if (immediate) {
        // immediate
        int op2 = rn;
    } else {
        // register
        int op2 = registers.get(rn);
    }
    int op1 = registers.get(instruction.getBits(3, 5));
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
    int rd = instruction.getBits(8, 10);
    int op2 = instruction & 0xFF;
    static if (op1) {
        int op1 = registers.get(rd);
    }
}

private void moveCompareAddAndSubtractImmediate(int code: 0)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MOV");
    mixin decodeOpMoveCompareAddAndSubtractImmediate!false;
    registers.set(rd, op2);
    registers.setAPSRFlags(op2 < 0, op2 == 0);
}

private void moveCompareAddAndSubtractImmediate(int code: 1)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "CMP");
    mixin decodeOpMoveCompareAddAndSubtractImmediate!true;
    int v = op1 - op2;
    registers.setAPSRFlags(v < 0, v == 0, !borrowedSub(op1, op2, v), overflowedSub(op1, op2, v));
}

private void moveCompareAddAndSubtractImmediate(int code: 2)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "ADD");
    mixin decodeOpMoveCompareAddAndSubtractImmediate!true;
    int res = op1 + op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0, carriedAdd(op1, op2, res), overflowedAdd(op1, op2, res));
}

private void moveCompareAddAndSubtractImmediate(int code: 3)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "SUB");
    mixin decodeOpMoveCompareAddAndSubtractImmediate!true;
    int res = op1 - op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0, !borrowedSub(op1, op2, res), overflowedSub(op1, op2, res));
}

private mixin template decodeOpAluOperations() {
    int op2 = registers.get(instruction.getBits(3, 5));
    int rd = instruction & 0b111;
    int op1 = registers.get(rd);
}

private void aluOperations(int code: 0)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "AND");
    mixin decodeOpAluOperations;
    int res = op1 & op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0);
}

private void aluOperations(int code: 1)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "EOR");
    mixin decodeOpAluOperations;
    int res = op1 ^ op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0);
}

private void aluOperationsShift(int type)(Registers* registers, MemoryBus* memory, int instruction) {
    static if (type == 0) {
        debug (outputInstructions) registers.logInstruction(instruction, "LSL");
    } else static if (type == 1) {
        debug (outputInstructions) registers.logInstruction(instruction, "LSR");
    } else static if (type == 2) {
        debug (outputInstructions) registers.logInstruction(instruction, "ASR");
    } else static if (type == 3) {
        debug (outputInstructions) registers.logInstruction(instruction, "ROR");
    } else {
        static assert (0);
    }
    mixin decodeOpAluOperations;
    int carry;
    int res = registers.applyShift!true(type, op2 & 0xFF, op1, carry);
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0, carry);
}

// LSL
private alias aluOperations(int code: 2) = aluOperationsShift!0;

// LSR
private alias aluOperations(int code: 3) = aluOperationsShift!1;

// ASR
private alias aluOperations(int code: 4) = aluOperationsShift!2;

// ROR
private alias aluOperations(int code: 7) = aluOperationsShift!3;

private void aluOperations(int code: 5)(Registers* registers, MemoryBus* memory, int instruction) {
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

private void aluOperations(int code: 6)(Registers* registers, MemoryBus* memory, int instruction) {
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

private void aluOperations(int code: 8)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "TST");
    mixin decodeOpAluOperations;
    int v = op1 & op2;
    registers.setAPSRFlags(v < 0, v == 0);
}

private void aluOperations(int code: 9)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "NEG");
    mixin decodeOpAluOperations;
    int res = 0 - op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0, !borrowedSub(0, op2, res), overflowedSub(0, op2, res));
}

private void aluOperations(int code: 10)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "CMP");
    mixin decodeOpAluOperations;
    int v = op1 - op2;
    registers.setAPSRFlags(v < 0, v == 0, !borrowedSub(op1, op2, v), overflowedSub(op1, op2, v));
}

private void aluOperations(int code: 11)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "CMN");
    mixin decodeOpAluOperations;
    int v = op1 + op2;
    registers.setAPSRFlags(v < 0, v == 0, carriedAdd(op1, op2, v), overflowedAdd(op1, op2, v));
}

private void aluOperations(int code: 12)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "ORR");
    mixin decodeOpAluOperations;
    int res = op1 | op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0);
}

private void aluOperations(int code: 13)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MUL");
    mixin decodeOpAluOperations;
    int res = op1 * op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0);
}

private void aluOperations(int code: 14)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "BIC");
    mixin decodeOpAluOperations;
    int res = op1 & ~op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0);
}

private void aluOperations(int code: 15)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "MNV");
    mixin decodeOpAluOperations;
    int res = ~op2;
    registers.set(rd, res);
    registers.setAPSRFlags(res < 0, res == 0);
}

private mixin template decodeOpHiRegisterOperationsAndBranchExchange(bool highDestination, bool highSource) {
    static if (highSource) {
        int rs = instruction.getBits(3, 5) | 0b1000;
    } else {
        int rs = instruction.getBits(3, 5);
    }
    static if (highDestination) {
        int rd = instruction & 0b111 | 0b1000;
    } else {
        int rd = instruction & 0b111;
    }
}

private template hiRegisterOperationsAndBranchExchange(int code) if (code.getBits(4, 31) == 0) {
    private alias hiRegisterOperationsAndBranchExchange =
        hiRegisterOperationsAndBranchExchange!(code.getBits(2, 3), code.checkBit(1), code.checkBit(0));
}

private void hiRegisterOperationsAndBranchExchange(int opCode, bool highDestination, bool highSource)
        (Registers* registers, MemoryBus* memory, int instruction)
        if (opCode == 0 && (highDestination || highSource)) {
    debug (outputInstructions) registers.logInstruction(instruction, "ADD");
    mixin decodeOpHiRegisterOperationsAndBranchExchange!(highDestination, highSource);
    registers.set(rd, registers.get(rd) + registers.get(rs));
}

private void hiRegisterOperationsAndBranchExchange(int opCode, bool highDestination, bool highSource)
        (Registers* registers, MemoryBus* memory, int instruction)
        if (opCode == 1 && (highDestination || highSource)) {
    debug (outputInstructions) registers.logInstruction(instruction, "CMP");
    mixin decodeOpHiRegisterOperationsAndBranchExchange!(highDestination, highSource);
    int op1 = registers.get(rd);
    int op2 = registers.get(rs);
    int v = op1 - op2;
    registers.setAPSRFlags(v < 0, v == 0, !borrowedSub(op1, op2, v), overflowedSub(op1, op2, v));
}

private void hiRegisterOperationsAndBranchExchange(int opCode, bool highDestination, bool highSource)
        (Registers* registers, MemoryBus* memory, int instruction)
        if (opCode == 2 && (highDestination || highSource)) {
    debug (outputInstructions) registers.logInstruction(instruction, "MOV");
    mixin decodeOpHiRegisterOperationsAndBranchExchange!(highDestination, highSource);
    registers.set(rd, registers.get(rs));
}

private void hiRegisterOperationsAndBranchExchange(int opCode, bool highDestination, bool highSource)
        (Registers* registers, MemoryBus* memory, int instruction)
        if (opCode == 3 && !highDestination) {
    debug (outputInstructions) registers.logInstruction(instruction, "BX");
    mixin decodeOpHiRegisterOperationsAndBranchExchange!(highDestination, highSource);
    int address = registers.get(rs);
    if (!(address & 0b1)) {
        registers.setFlag(CPSRFlag.T, Set.ARM);
    }
    registers.setPC(address & ~1);
}

@("unsupported")
private template hiRegisterOperationsAndBranchExchange(int opCode, bool highDestination, bool highSource)
        if (opCode >= 0 && opCode <= 2 && !highDestination && !highSource ||
            opCode == 3 && highDestination) {
    private alias hiRegisterOperationsAndBranchExchange = unsupported;
}

private void loadPCRelative()(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDR");
    int rd = getBits(instruction, 8, 10);
    int offset = (instruction & 0xFF) * 4;
    int pc = registers.getPC();
    int address = (pc & ~3) + offset;
    registers.set(rd, address.rotateRead(memory.get!int(address)));
}

private mixin template decodeOpLoadAndStoreWithRegisterOffset() {
    int offset = registers.get(instruction.getBits(6, 8));
    int base = registers.get(instruction.getBits(3, 5));
    int rd = instruction & 0b111;
    int address = base + offset;
}

private void loadAndStoreWithRegisterOffset(int code: 0)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "STR");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    memory.set!int(address, registers.get(rd));
}

private void loadAndStoreWithRegisterOffset(int code: 1)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "STRB");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    memory.set!byte(address, cast(byte) registers.get(rd));
}

private void loadAndStoreWithRegisterOffset(int code: 2)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDR");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    registers.set(rd, address.rotateRead(memory.get!int(address)));
}

private void loadAndStoreWithRegisterOffset(int code: 3)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDRB");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    registers.set(rd, memory.get!byte(address) & 0xFF);
}

private void loadAndStoreSignExtentedByteAndHalfword(int code: 0)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "STRH");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    memory.set!short(address, cast(short) registers.get(rd));
}

private void loadAndStoreSignExtentedByteAndHalfword(int code: 1)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDSB");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    registers.set(rd, memory.get!byte(address));
}

private void loadAndStoreSignExtentedByteAndHalfword(int code: 2)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDRH");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    registers.set(rd, address.rotateRead(memory.get!short(address)));
}

private void loadAndStoreSignExtentedByteAndHalfword(int code: 3)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDSH");
    mixin decodeOpLoadAndStoreWithRegisterOffset;
    registers.set(rd, address.rotateReadSigned(memory.get!short(address)));
}

private mixin template decodeOpLoadAndStoreWithImmediateOffset() {
    int offset = instruction.getBits(6, 10);
    int base = registers.get(instruction.getBits(3, 5));
    int rd = instruction & 0b111;
}

private void loadAndStoreWithImmediateOffset(int code: 0)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "STR");
    mixin decodeOpLoadAndStoreWithImmediateOffset;
    int address = base + offset * 4;
    memory.set!int(address, registers.get(rd));
}

private void loadAndStoreWithImmediateOffset(int code: 1)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDR");
    mixin decodeOpLoadAndStoreWithImmediateOffset;
    int address = base + offset * 4;
    registers.set(rd, address.rotateRead(memory.get!int(address)));
}

private void loadAndStoreWithImmediateOffset(int code: 2)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "STRB");
    mixin decodeOpLoadAndStoreWithImmediateOffset;
    int address = base + offset;
    memory.set!byte(address, cast(byte) registers.get(rd));
}

private void loadAndStoreWithImmediateOffset(int code: 3)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDRB");
    mixin decodeOpLoadAndStoreWithImmediateOffset;
    int address = base + offset;
    registers.set(rd, memory.get!byte(address) & 0xFF);
}

private void loadAndStoreHalfWord(int code: 0)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "STRH");
    mixin decodeOpLoadAndStoreWithImmediateOffset;
    int address = base + offset * 2;
    memory.set!short(address, cast(short) registers.get(rd));
}

private void loadAndStoreHalfWord(int code: 1)(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "LDRH");
    mixin decodeOpLoadAndStoreWithImmediateOffset;
    int address = base + offset * 2;
    registers.set(rd, address.rotateRead(memory.get!short(address)));
}

private template loadAndStoreSPRelative(int code) if (code.getBits(1, 31) == 0) {
    private alias loadAndStoreSPRelative = loadAndStoreSPRelative!(code.checkBit(0));
}

private void loadAndStoreSPRelative(bool load)(Registers* registers, MemoryBus* memory, int instruction) {
    int rd = instruction.getBits(8, 10);
    int offset = (instruction & 0xFF) * 4;
    int sp = registers.get(Register.SP);
    int address = sp + offset;
    static if (load) {
        debug (outputInstructions) registers.logInstruction(instruction, "LDR");
        registers.set(rd, address.rotateRead(memory.get!int(address)));
    } else {
        debug (outputInstructions) registers.logInstruction(instruction, "STR");
        memory.set!int(address, registers.get(rd));
    }
}

private template getRelativeAddresss(int code) if (code.getBits(1, 31) == 0) {
    private alias getRelativeAddresss = getRelativeAddresss!(code.checkBit(0));
}

private void getRelativeAddresss(bool stackPointer)(Registers* registers, MemoryBus* memory, int instruction) {
    int rd = instruction.getBits(8, 10);
    int offset = (instruction & 0xFF) * 4;
    static if (stackPointer) {
        debug (outputInstructions) registers.logInstruction(instruction, "ADD");
        registers.set(rd, registers.get(Register.SP) + offset);
    } else {
        debug (outputInstructions) registers.logInstruction(instruction, "ADD");
        registers.set(rd, (registers.getPC() & ~3) + offset);
    }
}

private template addOffsetToStackPointer(int code) if (code.getBits(1, 31) == 0) {
    private alias addOffsetToStackPointer = addOffsetToStackPointer!(code.checkBit(0));
}

private void addOffsetToStackPointer(bool subtract)(Registers* registers, MemoryBus* memory, int instruction) {
    int offset = (instruction & 0x7F) * 4;
    static if (subtract) {
        debug (outputInstructions) registers.logInstruction(instruction, "ADD");
        registers.set(Register.SP, registers.get(Register.SP) - offset);
    } else {
        debug (outputInstructions) registers.logInstruction(instruction, "ADD");
        registers.set(Register.SP, registers.get(Register.SP) + offset);
    }
}

private template pushAndPopRegisters(int code) if (code.getBits(2, 31) == 0) {
    private alias pushAndPopRegisters = pushAndPopRegisters!(code.checkBit(1), code.checkBit(0));
}

private void pushAndPopRegisters(bool pop, bool pcAndLR)(Registers* registers, MemoryBus* memory, int instruction) {
    int registerList = instruction & 0xFF;
    int sp = registers.get(Register.SP);
    static if (pop) {
        debug (outputInstructions) registers.logInstruction(instruction, "POP");
        foreach (i; 0 .. 8) {
            if (registerList.checkBit(i)) {
                registers.set(i, memory.get!int(sp));
                sp += 4;
            }
        }
        static if (pcAndLR) {
            registers.setPC(memory.get!int(sp) & ~1);
            sp += 4;
        }
    } else {
        debug (outputInstructions) registers.logInstruction(instruction, "PUSH");
        sp -= 4 * (registerList.bitCount() + pcAndLR);
        int address = sp;
        foreach (i; 0 .. 8) {
            if (registerList.checkBit(i)) {
                memory.set!int(address, registers.get(i));
                address += 4;
            }
        }
        static if (pcAndLR) {
            memory.set!int(address, registers.get(Register.LR));
        }
    }
    registers.set(Register.SP, sp);
}

private template multipleLoadAndStore(int code) if (code.getBits(1, 31) == 0) {
    private alias multipleLoadAndStore = multipleLoadAndStore!(code.checkBit(0));
}

private void multipleLoadAndStore(bool load)(Registers* registers, MemoryBus* memory, int instruction) {
    int rb = instruction.getBits(8, 10);
    int registerList = instruction & 0xFF;
    int address = registers.get(rb);
    static if (load) {
        debug (outputInstructions) registers.logInstruction(instruction, "LDMIA");
        foreach (i; 0 .. 8) {
            if (registerList.checkBit(i)) {
                registers.set(i, memory.get!int(address));
                address += 4;
            }
        }
    } else {
        debug (outputInstructions) registers.logInstruction(instruction, "STMIA");
        foreach (i; 0 .. 8) {
            if (registerList.checkBit(i)) {
                memory.set!int(address, registers.get(i));
                address += 4;
            }
        }
    }
    // Don't writeback if the address register was loaded
    static if (load) {
        if (!registerList.checkBit(rb)) {
            registers.set(rb, address);
        }
    } else {
        registers.set(rb, address);
    }
}

private void conditionalBranch(int code)(Registers* registers, MemoryBus* memory, int instruction)
        if (code >= 0 && code <= 13 ) {
    if (!registers.checkCondition(code)) {
        return;
    }
    debug (outputInstructions) registers.logInstruction(instruction, "B");
    int offset = instruction & 0xFF;
    // sign extend the offset
    offset <<= 24;
    offset >>= 24;
    registers.setPC(registers.getPC() + offset * 2);
}

@("unsupported")
private template conditionalBranch(int code) if (code == 14 || code == 15) {
    private alias conditionalBranch = unsupported;
}

private void softwareInterrupt()(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "SWI");
    registers.set(Mode.SUPERVISOR, Register.SPSR, registers.getCPSR());
    registers.set(Mode.SUPERVISOR, Register.LR, registers.getPC() - 2);
    registers.setPC(0x8);
    registers.setFlag(CPSRFlag.I, 1);
    registers.setFlag(CPSRFlag.T, Set.ARM);
    registers.setMode(Mode.SUPERVISOR);
}

private void unconditionalBranch()(Registers* registers, MemoryBus* memory, int instruction) {
    debug (outputInstructions) registers.logInstruction(instruction, "B");
    int offset = instruction & 0x7FF;
    // sign extend the offset
    offset <<= 21;
    offset >>= 21;
    registers.setPC(registers.getPC() + offset * 2);
}

private template longBranchWithLink(int code) if (code.getBits(1, 31) == 0) {
    private alias longBranchWithLink = longBranchWithLink!(code.checkBit(0));
}

private void longBranchWithLink(bool high)(Registers* registers, MemoryBus* memory, int instruction) {
    int offset = instruction & 0x7FF;
    static if (high) {
        debug (outputInstructions) registers.logInstruction(instruction, "BL");
        int address = registers.get(Register.LR) + (offset << 1);
        registers.set(Register.LR, registers.getPC() - 2 | 1);
        registers.setPC(address);
    } else {
        debug (outputInstructions) registers.logInstruction(instruction, "BL_");
        // sign extend the offset
        offset <<= 21;
        offset >>= 21;
        registers.set(Register.LR, registers.getPC() + (offset << 12));
    }
}

private void unsupported(Registers* registers, MemoryBus* memory, int instruction) {
    throw new UnsupportedTHUMBInstructionException(registers.getExecutedPC(), instruction);
}

public class UnsupportedTHUMBInstructionException : Exception {
    private this(int address, int instruction) {
        super(format("This THUMB instruction is unsupported by the implementation\n%08x: %04x", address, instruction & 0xFFFF));
    }
}
