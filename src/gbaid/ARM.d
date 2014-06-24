module gbaid.ARM;

public class ARMCPU {
	private Mode mode = Mode.USER;
	private Set set = Set.ARM;
	private int[37] registers = new int[37];

	public void test() {
		import std.stdio;
		int i = 0xFFFFFF;
		i <<= 8;
		i >>= 8;
		writeln(i);
	}

	private void armBranchAndExchange(int instruction) {
		if (!checkCondition(getConditionBits(instruction))) {
			return;
		}
		// BX and BLX
		int address = getRegister(instruction & 0b111);
		int pc = getRegister(Register.PC);
		if (getBit(address, 0)) {
			// switch to thumb
			int flagValue = getRegister(Register.CPSR);
			setBit(flagValue, CPSRFlag.T, Set.THUMB);
			setRegister(Register.CPSR, flagValue);
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
		int opcode = getBit(instruction, 24);
		if (blx) {
			// BLX
			newPC += opcode * 2;
			setRegister(Register.LR, pc + 4);
			int flagValue = getRegister(Register.CPSR);
			setBit(flagValue, CPSRFlag.T, Set.THUMB);
			setRegister(Register.CPSR, flagValue);
		} else {
			if (opcode) {
				// BL
				setRegister(Register.LR, pc + 4);
			}
		}
		setRegister(Register.PC, newPC);
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
