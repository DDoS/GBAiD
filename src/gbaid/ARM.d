module gbaid.ARM;

public class ARMCPU {
	private Mode mode = Mode.USER;
	private Set set = Set.ARM;
	private int[37] registers = new int[37];

	public void test() {
		import std.stdio;
		int i = 0;
		setBits(i, 2, 4, 0b111);
		int j = getBits(i, 2, 4);
		writeln(j);
	}

	private void armBranchAndExchange(int instruction) {
		if (!checkCondition(getConditionBits(instruction))) {
			return;
		}
		// BX and BLX
		int address = getRegister(instruction & 0b1111);
		int pc = getRegister(Register.PC);
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
		int pc = getRegister(Register.PC);
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
		byte shift;
		int shiftType;
		int rm;
		int op2;
		if (op2Src) {
			// immediate
			shift = cast(byte) getBits(instruction, 8, 11);
			shiftType = 3;
			op2 = instruction & 0xFF;
		} else {
			// register
			int shiftSrc = getBit(instruction, 4);
			if (shiftSrc) {
				// register
				shift = cast(byte) (getRegister(getBits(instruction, 8, 11)) & 0xFF);

			} else {
				// immediate
				shift = cast(byte) getBits(instruction, 7, 11);
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
					setBit(op2, 31, shiftCarry);
					if (!op2Src) {
						setRegister(rm, op2);
					}
					carry = newCarry;
					shiftCarry = carry;
				} else {
					shiftCarry = getBit(op2, shift - 1);
					asm {
						mov CL, shift;
						ror op2, CL;
					}
				}
				break;
		}
		int op1 = getRegister(rn);
		int res;
		int negative, zero, overflow;
		final switch(opCode) {
			case 0x0:
				// AND
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
				int v = op1 & op2;
				overflow = getFlag(CPSRFlag.V);
				carry = shiftCarry;
				zero = v == 0;
				negative = v < 0;
				break;
			case 0x9:
				// TEQ
				int v = op1 ^ op2;
				overflow = getFlag(CPSRFlag.V);
				carry = shiftCarry;
				zero = v == 0;
				negative = v < 0;
				break;
			case 0xA:
				// CMP
				int v = op1 - op2;
				overflow = overflowed(op1, -op2, v);
				carry = v >= 0;
				zero = v == 0;
				negative = v < 0;
				break;
			case 0xB:
				// CMN
				int v = op1 + op2;
				overflow = overflowed(op1, op2, v);
				carry = carried(op1, op2, v);
				zero = v == 0;
				negative = v < 0;
				break;
			case 0xC:
				// ORR
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

	private int getFlag(CPSRFlag flag) {
		return getBit(getRegister(Register.CPSR), flag);
	}

	private void setFlag(CPSRFlag flag, int b) {
		int flagValue = getRegister(Register.CPSR);
		setBit(flagValue, flag, b);
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
	return instruction >> 28 & 0b1111;
}

private bool checkBit(int i, int b) {
	return cast(bool) getBit(i, b);
}

private int getBit(int i, int b) {
	return i & 1 << b;
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
