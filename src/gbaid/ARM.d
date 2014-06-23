module gbaid.ARM;

public class ARMCPU {
	private Mode mode = Mode.SYSTEM_AND_USER;
	private Set set = Set.ARM;
	private int[37] registers = new int[37];

	public void test() {
		import std.stdio;
		setRegister(Register.CPSR, 1 << 31);
		writeln(checkCondition(4));
	}

	private void armBranchAndExchange(int instruction) {
		if (!checkCondition(getConditionBits(instruction))) {
			return;
		}
		// BX and BLX
		int register = instruction & 0b111;
		int value = getRegister(register);
		if (set == Set.ARM) {
			setBit(value, 0);
			setRegister(register, value);
			set = Set.THUMB;
		} else {
			set = Set.ARM;
		}
		setRegister(Register.PC, value);
		int flagValue = getRegister(Register.CPSR);
		setBit(flagValue, 5, getBit(value, 0));
		setRegister(Register.CPSR, flagValue);
		// BLX
		if (checkBit(instruction, 5)) {
			setRegister(Register.LR, value + 4);
		}
	}

	private bool checkCondition(int condition) {
		int flags = registers[Register.CPSR];
		final switch (condition) {
			case 0x0:
				return checkBit(flags, 30);
			case 0x1:
				return !checkBit(flags, 30);
			case 0x2:
				return checkBit(flags, 29);
			case 0x3:
				return !checkBit(flags, 29);
			case 0x4:
				return checkBit(flags, 31);
			case 0x5:
				return !checkBit(flags, 31);
			case 0x6:
				return checkBit(flags, 28);
			case 0x7:
				return !checkBit(flags, 28);
			case 0x8:
				return checkBit(flags, 29) && !checkBit(flags, 30);
			case 0x9:
				return !checkBit(flags, 29) || checkBit(flags, 30);
			case 0xA:
				return checkBit(flags, 31) == checkBit(flags, 28);
			case 0xB:
				return checkBit(flags, 31) != checkBit(flags, 28);
			case 0xC:
				return !checkBit(flags, 30) && checkBit(flags, 31) == checkBit(flags, 28);
			case 0xD:
				return checkBit(flags, 30) || checkBit(flags, 31) != checkBit(flags, 28);
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
			case Mode.SYSTEM_AND_USER:
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

private void setBit(ref int i, int b) {
	i |= 1 << b;
}

private void unsetBit(ref int i, int b) {
	i &= ~(1 << b);
}

private void setBit(ref int i, int b, int n) {
	if (n) {
		setBit(i, b);
	} else {
		unsetBit(i, b);
	}
}

private enum Set {
	ARM, THUMB
}

private enum Mode {
	SYSTEM_AND_USER, FIQ, SUPERVISOR, ABORT, IRQ, UNDEFINED
}

private enum Register {
	R0 = 0,
	SP = 13,
	LR = 14,
	PC = 15,
	CPSR = 16,
	SPSR = 17,
}
