module gbaid.arm;

import std.stdio;

import gbaid.memory;
import gbaid.util;

public class ARMProcessor {
	private Mode mode = Mode.USER;
	private Set set = Set.ARM;
	private int[37] registers = new int[37];
	private Memory memory;
	private int instruction;
	private int decoded;

	public void setMemory(Memory memory) {
		this.memory = memory;
	}

	public void run(uint entryPointAddress) {
		setRegister(Register.PC, entryPointAddress);
		// first tick
		instruction = fetch();
		incrementPC();
		// second tick
		int nextInstruction = fetch();
		decoded = decode(instruction);
		instruction = nextInstruction;
		incrementPC();
		// the rest of the ticks
		foreach (i; 0 .. 10) {
			tick();
		}
	}

	private void tick() {
		// fetch
		int nextInstruction = fetch();
		// decode
		int nextDecoded = decode(instruction);
		instruction = nextInstruction;
		// execute
		execute(decoded);
		decoded = nextDecoded;
		// increment the porgram counter
		incrementPC();
		// TODO: properly handle branching (flush the pipeline)
	}

	private int fetch() {
		int pc = getRegister(Register.PC);
		writefln("%X", pc);
		int instruction = memory.getInt(pc);
		return instruction;
	}

	private int decode(int instruction) {
		// Nothing to do
		return instruction;
	}

	private void execute(int instruction) {
		int category = getBits(instruction, 25, 27);
		/*
			0: DataProc, PSR Reg, BX, BLX, BKPT, CLZ, QALU, Multiply, MulLong, MulHalf, TransSwp12, TransReg10, TransImm10
			1: DataProc, PSR Imm
			2: TransImm9
			3: TransReg9, Undefined
			4: BlockTrans
			5: B, BL, BLX
			6: CoDataTrans, CoRR
			7: CoDataOp, CoRegTrans, SWI
		*/
		final switch (category) {
			case 0:
				if (getBits(instruction, 23, 24) == 0b10 && getBit(instruction, 20) == 0b0 && getBits(instruction, 4, 11) == 0b00000000) {
					writeln("PSR Reg");
					armPRSTransfer(instruction);
				} else if (getBits(instruction, 8, 24) == 0b00010010111111111111) {
					writeln("BX, BLX");
					armBranchAndExchange(instruction);
				} else if (getBits(instruction, 20, 24) == 0b10010 && getBits(instruction, 4, 7) == 0b0111) {
					writeln("BKPT");
				} else if (getBits(instruction, 16, 24) == 0b101101111 && getBits(instruction, 4, 11) == 0b11110001) {
					writeln("CLZ");
				} else if (getBits(instruction, 23, 24) == 0b10 && getBit(instruction, 20) == 0b0 && getBits(instruction, 4, 11) == 0b00000101) {
					writeln("QALU");
				} else if (getBits(instruction, 22, 24) == 0b000 && getBits(instruction, 4, 7) == 0b1001) {
					writeln("Multiply");
					armMultiplyAndMultiplyAccumulate(instruction);
				} else if (getBits(instruction, 23, 24) == 0b01 && getBits(instruction, 4, 7) == 0b1001) {
					writeln("MulLong");
					armMultiplyAndMultiplyAccumulate(instruction);
				} else if (getBits(instruction, 23, 24) == 0b10 && getBit(instruction, 20) == 0b0 && getBit(instruction, 7) == 0b1 && getBit(instruction, 4) == 0b0) {
					writeln("MulHalf");
				} else if (getBits(instruction, 23, 24) == 0b10 && getBits(instruction, 20, 21) == 0b00 && getBits(instruction, 4, 11) == 0b00001001) {
					writeln("TransSwp12");
				} else if (getBit(instruction, 22) == 0b0 && getBits(instruction, 7, 11) == 0b00001 && getBit(instruction, 4) == 0b1) {
					writeln("TransReg10");
				} else if (getBit(instruction, 22) == 0b1 && getBit(instruction, 7) == 0b1 && getBit(instruction, 4) == 0b1) {
					writeln("TransImm10");
				} else {
					writeln("DataProc");
					armDataProcessing(instruction);
				}
				break;
			case 1:
				if (getBits(instruction, 23, 24) == 0b10 && getBit(instruction, 20) == 0b0) {
					writeln("PSR Reg");
					armPRSTransfer(instruction);
				} else {
					writeln("DataProc");
					armDataProcessing(instruction);
				}
				break;
			case 2:
				writeln("TransImm9");
				break;
			case 3:
				if (getBit(instruction, 4) == 0b0) {
					writeln("TransReg9");
				} else {
					writeln("Undefined");
				}
				break;
			case 4:
				writeln("BlockTrans");
				break;
			case 5:
				writeln("B, BL, BLX");
				armBranchAndBranchWithLink(instruction);
				break;
			case 6:
				if (getBits(instruction, 21, 24) == 0b0010) {
					writeln("CoDataTrans");
				} else {
					writeln("CoRR");
				}
				break;
			case 7:
				if (getBit(instruction, 24) == 0b0 && getBit(instruction, 4) == 0b0) {
					writeln("CoDataOp");
				} else if (getBit(instruction, 24) == 0b0 && getBit(instruction, 4) == 0b1) {
					writeln("CoRegTrans");
				} else {
					writeln("SWI");
				}
				break;
		}
	}

	private void incrementPC() {
		setRegister(Register.PC, getRegister(Register.PC) + 4);
	}

	private void armBranchAndExchange(int instruction) {
		if (!checkCondition(getConditionBits(instruction))) {
			return;
		}
		// BX and BLX
		int address = getRegister(instruction & 0b1111);
		int pc = getRegister(Register.PC) - 8;
		if (address & 0b1) {
			// switch to thumb
			setFlag(CPSRFlag.T, Set.THUMB);
			set = Set.THUMB;
			// discard the last bit in the address
			address -= 1;
		}
		setRegister(Register.PC, address);
		if (checkBit(instruction, 5)) {
			// BLX
			setRegister(Register.LR, pc + 4);
		}
	}

	private void armBranchAndBranchWithLink(int instruction) {
		int conditionBits = getConditionBits(instruction);
		bool blx = conditionBits == 0b1111;
		if (!blx && !checkCondition(conditionBits)) {
			return;
		}
		// B, BL and BLX
		int offset = instruction & 0xFFFFFF;
		// sign extend the offset
		offset <<= 8;
		offset >>= 8;
		int pc = getRegister(Register.PC) - 8;
		int newPC = pc + 8 + offset * 4;
		int opCode = getBit(instruction, 24);
		if (blx) {
			// BLX
			newPC += opCode * 2;
			setRegister(Register.LR, pc + 4);
			setFlag(CPSRFlag.T, Set.THUMB);
			set = Set.THUMB;
		} else {
			if (opCode) {
				// BL
				setRegister(Register.LR, pc + 4);
			}
		}
		setRegister(Register.PC, newPC);
	}

	private void armDataProcessing(int instruction) {
		if (!checkCondition(getConditionBits(instruction))) {
			return;
		}
		int op2Src = getBit(instruction, 25);
		int opCode = getBits(instruction, 21, 24);
		int setFlags = getBit(instruction, 20);
		int rn = getBits(instruction, 16, 19);
		int rd = getBits(instruction, 12, 15);
		int shift;
		int shiftType;
		int rm;
		int op2;
		if (op2Src) {
			// immediate
			shift = getBits(instruction, 8, 11) * 2;
			shiftType = 3;
			op2 = instruction & 0xFF;
		} else {
			// register
			int shiftSrc = getBit(instruction, 4);
			if (shiftSrc) {
				// register
				shift = getRegister(getBits(instruction, 8, 11)) & 0xFF;

			} else {
				// immediate
				shift = getBits(instruction, 7, 11);
			}
			shiftType = getBits(instruction, 5, 6);
			rm = instruction & 0b1111;
			op2 = getRegister(rm);
		}
		int carry = getFlag(CPSRFlag.C);
		int shiftCarry = carry;
		final switch (shiftType) {
			// LSL
			case 0:
				if (shift != 0) {
					shiftCarry = getBit(op2, 32 - shift);
					op2 <<= shift;
				}
				break;
			// LSR
			case 1:
				if (op2Src && shift == 0) {
					shiftCarry = getBit(op2, 31);
					op2 = 0;
				} else {
					shiftCarry = getBit(op2, shift - 1);
					op2 >>>= shift;
				}
				break;
			// ASR
			case 2:
				if (op2Src && shift == 0) {
					shiftCarry = getBit(op2, 31);
					op2 >>= 31;
				} else {
					shiftCarry = getBit(op2, shift - 1);
					op2 >>= shift;
				}
				break;
			// ROR
			case 3:
				if (op2Src && shift == 0) {
					// RRX
					int newCarry = getBit(op2, 0);
					asm {
						ror op2, 1;
					}
					setBit(op2, 31, carry);
					if (!op2Src) {
						setRegister(rm, op2);
					}
					carry = newCarry;
					setFlag(CPSRFlag.C, carry);
					shiftCarry = carry;
				} else {
					shiftCarry = getBit(op2, shift - 1);
					byte byteShift = cast(byte) shift;
					asm {
						mov CL, byteShift;
						ror op2, CL;
					}
				}
				break;
		}
		int op1 = getRegister(rn);
		int res;
		int negative, zero, overflow;
		final switch (opCode) {
			case 0x0:
				// AND
				writeln("AND");
				res = op1 & op2;
				if (setFlags) {
					overflow = getFlag(CPSRFlag.V);
					carry = shiftCarry;
					zero = res == 0;
					negative = res < 0;
				}
				break;
			case 0x1:
				// EOR
				writeln("EOR");
				res = op1 ^ op2;
				if (setFlags) {
					overflow = getFlag(CPSRFlag.V);
					carry = shiftCarry;
					zero = res == 0;
					negative = res < 0;
				}
				break;
			case 0x2:
				// SUB
				writeln("SUB");
				res = op1 - op2;
				if (setFlags) {
					overflow = overflowed(op1, -op2, res);
					carry = res >= 0;
					zero = res == 0;
					negative = res < 0;
				}
				break;
			case 0x3:
				// RSB
				writeln("RSB");
				res = op2 - op1;
				if (setFlags) {
					overflow = overflowed(op2, -op1, res);
					carry = res >= 0;
					zero = res == 0;
					negative = res < 0;
				}
				break;
			case 0x4:
				// ADD
				writeln("ADD");
				res = op1 + op2;
				if (setFlags) {
					overflow = overflowed(op1, op2, res);
					carry = carried(op1, op2, res);
					zero = res == 0;
					negative = res < 0;
				}
				break;
			case 0x5:
				// ADC
				writeln("ADC");
				res = op1 + op2 + carry;
				if (setFlags) {
					overflow = overflowed(op1, op2 + carry, res);
					carry = carried(op1, op2 + carry, res);
					zero = res == 0;
					negative = res < 0;
				}
				break;
			case 0x6:
				// SBC
				writeln("SBC");
				res = op1 - op2 + carry - 1;
				if (setFlags) {
					overflow = overflowed(op1, -op2 + carry - 1, res);
					carry = res >= 0;
					zero = res == 0;
					negative = res < 0;
				}
				break;
			case 0x7:
				// RSC
				writeln("RSC");
				res = op2 - op1 + carry - 1;
				if (setFlags) {
					overflow = overflowed(op2, -op1 + carry - 1, res);
					carry = res >= 0;
					zero = res == 0;
					negative = res < 0;
				}
				break;
			case 0x8:
				// TST
				writeln("TST");
				int v = op1 & op2;
				overflow = getFlag(CPSRFlag.V);
				carry = shiftCarry;
				zero = v == 0;
				negative = v < 0;
				break;
			case 0x9:
				// TEQ
				writeln("TEQ");
				int v = op1 ^ op2;
				overflow = getFlag(CPSRFlag.V);
				carry = shiftCarry;
				zero = v == 0;
				negative = v < 0;
				break;
			case 0xA:
				// CMP
				writeln("CMP");
				int v = op1 - op2;
				overflow = overflowed(op1, -op2, v);
				carry = v >= 0;
				zero = v == 0;
				negative = v < 0;
				break;
			case 0xB:
				// CMN
				writeln("CMN");
				int v = op1 + op2;
				overflow = overflowed(op1, op2, v);
				carry = carried(op1, op2, v);
				zero = v == 0;
				negative = v < 0;
				break;
			case 0xC:
				// ORR
				writeln("ORR");
				res = op1 | op2;
				if (setFlags) {
					overflow = getFlag(CPSRFlag.V);
					carry = shiftCarry;
					zero = res == 0;
					negative = res < 0;
				}
				break;
			case 0xD:
				// MOV
				writeln("MOV");
				res = op2;
				if (setFlags) {
					overflow = getFlag(CPSRFlag.V);
					carry = shiftCarry;
					zero = res == 0;
					negative = res < 0;
				}
				break;
			case 0xE:
				// BIC
				writeln("BIC");
				res = op1 & ~op2;
				if (setFlags) {
					overflow = getFlag(CPSRFlag.V);
					carry = shiftCarry;
					zero = res == 0;
					negative = res < 0;
				}
				break;
			case 0xF:
				// MVN
				writeln("MVN");
				res = ~op2;
				if (setFlags) {
					overflow = getFlag(CPSRFlag.V);
					carry = shiftCarry;
					zero = res == 0;
					negative = res < 0;
				}
				break;
		}
		if (setFlags) {
			if (rd == 15) {
				setRegister(Register.CPSR, getRegister(Register.SPSR));
			} else {
				setAPSRFlags(negative, zero, carry, overflow);
			}
		}
		setRegister(rd, res);
	}

	private void armPRSTransfer(int instruction) {
		if (!checkCondition(getConditionBits(instruction))) {
			return;
		}
		int psrSrc = getBit(instruction, 22);
		int opCode = getBit(instruction, 21);
		if (opCode) {
			// MSR
			int opSrc = getBit(instruction, 25);
			int writeFlags = getBit(instruction, 19);
			int writeControl = getBit(instruction, 16);
			int op;
			if (opSrc) {
				// immediate
				byte shift = cast(byte) (getBits(instruction, 8, 11) * 2);
				op = instruction & 0xFF;
				asm {
					mov CL, shift;
					ror op, CL;
				}
			} else {
				// register
				op = getRegister(instruction & 0xF);
			}
			int mask;
			if (writeFlags) {
				mask |= 0xFF000000;
			}
			if (writeControl) {
				// never write T
				mask |= 0b11011111;
			}
			if (psrSrc) {
				int spsr = getRegister(Register.SPSR);
				setRegister(Register.SPSR, spsr & ~mask | op & mask);
			} else {
				int cpsr = getRegister(Register.CPSR);
				setRegister(Register.CPSR, cpsr & ~mask | op & mask);
			}
		} else {
			// MRS
			int rd = getBits(instruction, 12, 15);
			if (psrSrc) {
				setRegister(rd, getRegister(Register.SPSR));
			} else {
				setRegister(rd, getRegister(Register.CPSR));
			}
		}
	}

	private void armMultiplyAndMultiplyAccumulate(int instruction) {
		if (!checkCondition(getConditionBits(instruction))) {
			return;
		}
		int opCode = getBits(instruction, 21, 24);
		int setFlags = getBit(instruction, 20);
		int rd = getBits(instruction, 16, 19);
		int op2 = getRegister(getBits(instruction, 8, 11));
		int op1 = getRegister(instruction & 0xF);
		final switch (opCode) {
			case 0x0:
				int res = op1 * op2;
				setRegister(rd, res);
				if (setFlags) {
					setAPSRFlags(res < 0, res == 0);
				}
				break;
			case 0x1:
				int op3 = getRegister(getBits(instruction, 12, 15));
				int res = op1 * op2 + op3;
				setRegister(rd, res);
				if (setFlags) {
					setAPSRFlags(res < 0, res == 0);
				}
				break;
			case 0x4:
				int rn = getBits(instruction, 12, 15);
				ulong res = ucast(op1) * ucast(op2);
				int resLo = cast(int) res;
				int resHi = cast(int) (res >> 32);
				setRegister(rn, resLo);
				setRegister(rd, resHi);
				if (setFlags) {
					setAPSRFlags(res < 0, res == 0);
				}
				break;
			case 0x5:
				int rn = getBits(instruction, 12, 15);
				ulong op3 = ucast(getRegister(rd)) << 32 | ucast(getRegister(rn));
				ulong res = ucast(op1) * ucast(op2) + op3;
				int resLo = cast(int) res;
				int resHi = cast(int) (res >> 32);
				setRegister(rn, resLo);
				setRegister(rd, resHi);
				if (setFlags) {
					setAPSRFlags(res < 0, res == 0);
				}
				break;
			case 0x6:
				int rn = getBits(instruction, 12, 15);
				long res = cast(long) op1 * cast(long) op2;
				int resLo = cast(int) res;
				int resHi = cast(int) (res >> 32);
				setRegister(rn, resLo);
				setRegister(rd, resHi);
				if (setFlags) {
					setAPSRFlags(res < 0, res == 0);
				}
				break;
			case 0x7:
				int rn = getBits(instruction, 12, 15);
				long op3 = ucast(getRegister(rd)) << 32 | ucast(getRegister(rn));
				long res = cast(long) op1 * cast(long) op2 + op3;
				int resLo = cast(int) res;
				int resHi = cast(int) (res >> 32);
				setRegister(rn, resLo);
				setRegister(rd, resHi);
				if (setFlags) {
					setAPSRFlags(res < 0, res == 0);
				}
				break;
		}
	}

	private int getFlag(CPSRFlag flag) {
		return getBit(getRegister(Register.CPSR), flag);
	}

	private void setFlag(CPSRFlag flag, int b) {
		int flagValue = getRegister(Register.CPSR);
		setBit(flagValue, flag, b);
		setRegister(Register.CPSR, flagValue);
	}

	private void setAPSRFlags(int n, int z) {
		int flagValue = getRegister(Register.CPSR);
		int apsr =  z | n << 1;
		setBits(flagValue, 30, 31, apsr);
		setRegister(Register.CPSR, flagValue);
	}

	private void setAPSRFlags(int n, int z, int c, int v) {
		int flagValue = getRegister(Register.CPSR);
		int apsr =  v | c << 1 | z << 2 | n << 3;
		setBits(flagValue, 28, 31, apsr);
		setRegister(Register.CPSR, flagValue);
	}

	private bool checkCondition(int condition) {
		int flags = registers[Register.CPSR];
		final switch (condition) {
			case 0x0:
				return checkBit(flags, CPSRFlag.Z);
			case 0x1:
				return !checkBit(flags, CPSRFlag.Z);
			case 0x2:
				return checkBit(flags, CPSRFlag.C);
			case 0x3:
				return !checkBit(flags, CPSRFlag.C);
			case 0x4:
				return checkBit(flags, CPSRFlag.N);
			case 0x5:
				return !checkBit(flags, CPSRFlag.N);
			case 0x6:
				return checkBit(flags, CPSRFlag.V);
			case 0x7:
				return !checkBit(flags, CPSRFlag.V);
			case 0x8:
				return checkBit(flags, CPSRFlag.C) && !checkBit(flags, CPSRFlag.Z);
			case 0x9:
				return !checkBit(flags, CPSRFlag.C) || checkBit(flags, CPSRFlag.Z);
			case 0xA:
				return checkBit(flags, CPSRFlag.N) == checkBit(flags, CPSRFlag.V);
			case 0xB:
				return checkBit(flags, CPSRFlag.N) != checkBit(flags, CPSRFlag.V);
			case 0xC:
				return !checkBit(flags, CPSRFlag.Z) && checkBit(flags, CPSRFlag.N) == checkBit(flags, CPSRFlag.V);
			case 0xD:
				return checkBit(flags, CPSRFlag.Z) || checkBit(flags, CPSRFlag.N) != checkBit(flags, CPSRFlag.V);
			case 0xE:
				return true;
			case 0xF:
				return false;
		}
	}

	private int getRegister(int register) {
		return registers[getRegisterIndex(register)];
	}

	private void setRegister(int register, int value) {
		registers[getRegisterIndex(register)] = value;
	}

	private int getRegisterIndex(int register) {
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
		final switch (mode) {
			case Mode.USER:
			case Mode.SYSTEM:
				return register;
			case Mode.FIQ:
				switch (register) {
					case 8: .. case 14:
						return register + 9;
					case 17:
						return register + 7;
					default:
						return register;
				}
			case Mode.SUPERVISOR:
				switch (register) {
					case 13: .. case 14:
						return register + 12;
					case 17:
						return register + 10;
					default:
						return register;
				}
			case Mode.ABORT:
				switch (register) {
					case 13: .. case 14:
						return register + 15;
					case 17:
						return register + 13;
					default:
						return register;
				}
			case Mode.IRQ:
				switch (register) {
					case 13: .. case 14:
						return register + 18;
					case 17:
						return register + 16;
					default:
						return register;
				}
			case Mode.UNDEFINED:
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
}

private bool carried(int a, int b, int r) {
	return cast(uint) r < cast(uint) a;
}

private bool overflowed(int a, int b, int r) {
	int rn = getBit(r, 31);
	return getBit(a, 31) != rn && getBit(b, 31) != rn;
}

private int getConditionBits(int instruction) {
	return instruction >> 28 & 0xF;
}

private bool checkBit(int i, int b) {
	return cast(bool) getBit(i, b);
}

private int getBit(int i, int b) {
	return i >> b & 1;
}

private void setBit(ref int i, int b, int n) {
	i = i & ~(1 << b) | (n & 1) << b;
}

private int getBits(int i, int a, int b) {
	return i >> a & (1 << b - a + 1) - 1;
}

private void setBits(ref int i, int a, int b, int n) {
	int mask = (1 << b - a + 1) - 1 << a;
	i = i & ~mask | n << a & mask;
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
	M0 = 0
}
