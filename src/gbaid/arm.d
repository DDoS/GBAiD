module gbaid.arm;

import std.stdio;

import gbaid.memory;
import gbaid.util;

public class ARM7TDMI {
	private int[37] registers = new int[37];
	private Mode mode;
	private Set set;
	private Memory memory;
	private int instruction;
	private int decoded;
	private bool branchSignal = false;

	public void setMemory(Memory memory) {
		this.memory = memory;
	}

	public void run(uint entryPointAddress) {
		// initialize to ARM in supervisor mode
		setFlag(CPSRFlag.T, Set.ARM);
		set = Set.ARM;
		setMode(Mode.SUPERVISOR);
		mode = Mode.SUPERVISOR;
		// set first instruction
		setRegister(Register.PC, entryPointAddress);
		// branch to instruction
		branch();
		// start ticking
		foreach (i; 0 .. 100) {
			tick();
			if (branchSignal) {
				branch();
			} else {
				incrementPC();
			}
		}
	}

	private void branch() {
		// fetch first instruction
		instruction = fetch();
		incrementPC();
		// fetch second and decode first
		int nextInstruction = fetch();
		decoded = decode(instruction);
		instruction = nextInstruction;
		incrementPC();
		// remove branch signal flag
		branchSignal = false;
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
	}

	private int fetch() {
		int pc = getRegister(Register.PC);
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
					// PSR Reg
					armPRSTransfer(instruction);
				} else if (getBits(instruction, 8, 24) == 0b00010010111111111111) {
					// BX, BLX
					armBranchAndExchange(instruction);
				} else if (getBits(instruction, 20, 24) == 0b10010 && getBits(instruction, 4, 7) == 0b0111) {
					// BKPT
					armUnsupported(instruction);
				} else if (getBits(instruction, 16, 24) == 0b101101111 && getBits(instruction, 4, 11) == 0b11110001) {
					// CLZ
					armUnsupported(instruction);
				} else if (getBits(instruction, 23, 24) == 0b10 && getBit(instruction, 20) == 0b0 && getBits(instruction, 4, 11) == 0b00000101) {
					// QALU
					armUnsupported(instruction);
				} else if (getBits(instruction, 22, 24) == 0b000 && getBits(instruction, 4, 7) == 0b1001) {
					// Multiply
					armMultiplyAndMultiplyAccumulate(instruction);
				} else if (getBits(instruction, 23, 24) == 0b01 && getBits(instruction, 4, 7) == 0b1001) {
					// MulLong
					armMultiplyAndMultiplyAccumulate(instruction);
				} else if (getBits(instruction, 23, 24) == 0b10 && getBit(instruction, 20) == 0b0 && getBit(instruction, 7) == 0b1 && getBit(instruction, 4) == 0b0) {
					// MulHalf
					armUnsupported(instruction);
				} else if (getBits(instruction, 23, 24) == 0b10 && getBits(instruction, 20, 21) == 0b00 && getBits(instruction, 4, 11) == 0b00001001) {
					// TransSwp12
					armSingeDataSwap(instruction);
				} else if (getBit(instruction, 22) == 0b0 && getBits(instruction, 7, 11) == 0b00001 && getBit(instruction, 4) == 0b1) {
					// TransReg10
					armHalfwordAndSignedDataTransfer(instruction);
				} else if (getBit(instruction, 22) == 0b1 && getBit(instruction, 7) == 0b1 && getBit(instruction, 4) == 0b1) {
					// TransImm10
					armHalfwordAndSignedDataTransfer(instruction);
				} else {
					// DataProc
					armDataProcessing(instruction);
				}
				break;
			case 1:
				if (getBits(instruction, 23, 24) == 0b10 && getBit(instruction, 20) == 0b0) {
					// PSR Reg
					armPRSTransfer(instruction);
				} else {
					// DataProc
					armDataProcessing(instruction);
				}
				break;
			case 2:
				// TransImm9
				armSingleDataTransfer(instruction);
				break;
			case 3:
				if (getBit(instruction, 4) == 0b0) {
					// TransReg9
					armSingleDataTransfer(instruction);
				} else {
					// Undefined
					armUndefined(instruction);
				}
				break;
			case 4:
				// BlockTrans
				armBlockDataTransfer(instruction);
				break;
			case 5:
				// B, BL, BLX
				armBranchAndBranchWithLink(instruction);
				break;
			case 6:
				if (getBits(instruction, 21, 24) == 0b0010) {
					// CoDataTrans
					armUnsupported(instruction);
				} else {
					// CoRR
					armUnsupported(instruction);
				}
				break;
			case 7:
				if (getBit(instruction, 24) == 0b0 && getBit(instruction, 4) == 0b0) {
					// CoDataOp
					armUnsupported(instruction);
				} else if (getBit(instruction, 24) == 0b0 && getBit(instruction, 4) == 0b1) {
					// CoRegTrans
					armUnsupported(instruction);
				} else {
					// SWI
					armSoftwareInterrupt(instruction);
				}
				break;
		}
		// Update the mode and set variables
		mode = getMode();
		set = cast(Set) getFlag(CPSRFlag.T);
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
			// discard the last bit in the address
			address -= 1;
		}
		setRegister(Register.PC, address);
		if (checkBit(instruction, 5)) {
			// BLX
			writeln("BLX");
			setRegister(Register.LR, pc + 4);
		} else {
			writeln("BX");
		}
		// signal a branch
		branchSignal = true;
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
			writeln("BLX");
			newPC += opCode * 2;
			setRegister(Register.LR, pc + 4);
			setFlag(CPSRFlag.T, Set.THUMB);
		} else {
			if (opCode) {
				// BL
				writeln("BL");
				setRegister(Register.LR, pc + 4);
			} else {
				writeln("B");
			}
		}
		setRegister(Register.PC, newPC);
		// signal a branch
		branchSignal = true;
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
		int shiftSrc;
		int shift;
		int shiftType;
		int op2;
		if (op2Src) {
			// immediate
			shiftSrc = 1;
			shift = getBits(instruction, 8, 11) * 2;
			shiftType = 3;
			op2 = instruction & 0xFF;
		} else {
			// register
			shiftSrc = getBit(instruction, 4);
			if (shiftSrc) {
				// register
				shift = getRegister(getBits(instruction, 8, 11)) & 0xFF;

			} else {
				// immediate
				shift = getBits(instruction, 7, 11);
			}
			shiftType = getBits(instruction, 5, 6);
			op2 = getRegister(instruction & 0b1111);
		}
		int carry;
		op2 = applyShift(shiftType, !shiftSrc, shift, op2, carry);
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
					zero = res == 0;
					negative = res < 0;
				}
				setRegister(rd, res);
				break;
			case 0x1:
				// EOR
				writeln("EOR");
				res = op1 ^ op2;
				if (setFlags) {
					overflow = getFlag(CPSRFlag.V);
					zero = res == 0;
					negative = res < 0;
				}
				setRegister(rd, res);
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
				setRegister(rd, res);
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
				setRegister(rd, res);
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
				setRegister(rd, res);
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
				setRegister(rd, res);
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
				setRegister(rd, res);
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
				setRegister(rd, res);
				break;
			case 0x8:
				// TST
				writeln("TST");
				int v = op1 & op2;
				overflow = getFlag(CPSRFlag.V);
				zero = v == 0;
				negative = v < 0;
				break;
			case 0x9:
				// TEQ
				writeln("TEQ");
				int v = op1 ^ op2;
				overflow = getFlag(CPSRFlag.V);
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
					zero = res == 0;
					negative = res < 0;
				}
				setRegister(rd, res);
				break;
			case 0xD:
				// MOV
				writeln("MOV");
				res = op2;
				if (setFlags) {
					overflow = getFlag(CPSRFlag.V);
					zero = res == 0;
					negative = res < 0;
				}
				setRegister(rd, res);
				break;
			case 0xE:
				// BIC
				writeln("BIC");
				res = op1 & ~op2;
				if (setFlags) {
					overflow = getFlag(CPSRFlag.V);
					zero = res == 0;
					negative = res < 0;
				}
				setRegister(rd, res);
				break;
			case 0xF:
				// MVN
				writeln("MVN");
				res = ~op2;
				if (setFlags) {
					overflow = getFlag(CPSRFlag.V);
					zero = res == 0;
					negative = res < 0;
				}
				setRegister(rd, res);
				break;
		}
		if (setFlags) {
			if (rd == 15) {
				setRegister(Register.CPSR, getRegister(Register.SPSR));
			} else {
				setAPSRFlags(negative, zero, carry, overflow);
			}
		}
	}

	private void armPRSTransfer(int instruction) {
		if (!checkCondition(getConditionBits(instruction))) {
			return;
		}
		int psrSrc = getBit(instruction, 22);
		int opCode = getBit(instruction, 21);
		if (opCode) {
			writeln("MSR");
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
			writeln("MRS");
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
			case 0:
				writeln("MUL");
				int res = op1 * op2;
				setRegister(rd, res);
				if (setFlags) {
					setAPSRFlags(res < 0, res == 0);
				}
				break;
			case 1:
				writeln("MLA");
				int op3 = getRegister(getBits(instruction, 12, 15));
				int res = op1 * op2 + op3;
				setRegister(rd, res);
				if (setFlags) {
					setAPSRFlags(res < 0, res == 0);
				}
				break;
			case 4:
				writeln("UMULL");
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
			case 5:
				writeln("UMLAL");
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
			case 6:
				writeln("SMULL");
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
			case 7:
				writeln("SMLAL");
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

	private void armSingleDataTransfer(int instruction) {
		if (!checkCondition(getConditionBits(instruction))) {
			return;
		}
		int offsetSrc = getBit(instruction, 25);
		int preIncr = getBit(instruction, 24);
		int upIncr = getBit(instruction, 23);
		int byteQuantity = getBit(instruction, 22);
		int load = getBit(instruction, 20);
		int rn = getBits(instruction, 16, 19);
		int rd = getBits(instruction, 12, 15);
		int offset;
		if (offsetSrc) {
			// register
			int shift = getBits(instruction, 7, 11);
			int shiftType = getBits(instruction, 5, 6);
			offset = getRegister(instruction & 0xF);
			int carry;
			offset = applyShift(shiftType, true, shift, offset, carry);
		} else {
			// immediate
			offset = instruction & 0xFFF;
		}
		int address = getRegister(rn);
		if (preIncr) {
			int writeBack = getBit(instruction, 21);
			if (upIncr) {
				address += offset;
			} else {
				address -= offset;
			}
			if (load) {
				if (byteQuantity) {
					writeln("LDRB");
					int b = memory.getByte(address) & 0xFF;
					setRegister(rd, b);
				} else {
					writeln("LDR");
					int w = memory.getInt(address);
					if (address & 0b10) {
						w >>>= 16;
					}
					setRegister(rd, w);
				}
			} else {
				if (byteQuantity) {
					writeln("STRB");
					byte b = cast(byte) getRegister(rd);
					memory.setByte(address, b);
				} else {
					writeln("STR");
					int w = getRegister(rd);
					memory.setInt(address, w);
				}
			}
			if (writeBack) {
				setRegister(rn, address);
			}
		} else {
			if (load) {
				if (byteQuantity) {
					writeln("LDRB");
					int b = memory.getByte(address) & 0xFF;
					setRegister(rd, b);
				} else {
					writeln("LDR");
					int w = memory.getInt(address);
					if (address & 0b10) {
						w >>>= 16;
					}
					setRegister(rd, w);
				}
			} else {
				if (byteQuantity) {
					writeln("STRB");
					byte b = cast(byte) getRegister(rd);
					memory.setByte(address, b);
				} else {
					writeln("STR");
					int w = getRegister(rd);
					memory.setInt(address, w);
				}
			}
			if (upIncr) {
				address += offset;
			} else {
				address -= offset;
			}
			setRegister(rn, address);
		}
	}

	private void armHalfwordAndSignedDataTransfer(int instruction) {
		if (!checkCondition(getConditionBits(instruction))) {
			return;
		}
		int preIncr = getBit(instruction, 24);
		int upIncr = getBit(instruction, 23);
		int offsetSrc = getBit(instruction, 22);
		int load = getBit(instruction, 20);
		int rn = getBits(instruction, 16, 19);
		int rd = getBits(instruction, 12, 15);
		int offset;
		if (offsetSrc) {
			// immediate
			int upperOffset = getBits(instruction, 8, 11);
			int lowerOffset = instruction & 0xF;
			offset = upperOffset << 4 | lowerOffset;
		} else {
			// register
			offset = getRegister(instruction & 0xF);
		}
		int address = getRegister(rn);
		if (preIncr) {
			if (upIncr) {
				address += offset;
			} else {
				address -= offset;
			}
		}
		int opCode = getBits(instruction, 5, 6);
		if (load) {
			final switch (opCode) {
				case 1:
					writeln("LDRH");
					int hw = memory.getShort(address) & 0xFFFF;
					setRegister(rd, hw);
					break;
				case 2:
					writeln("LDRSB");
					int b = memory.getByte(address);
					setRegister(rd, b);
					break;
				case 3:
					writeln("LDRSH");
					int hw = memory.getShort(address);
					setRegister(rd, hw);
					break;
			}
		} else {
			final switch (opCode) {
				case 1:
					writeln("STRH");
					short hw = cast(short) getRegister(rd);
					memory.setShort(address, hw);
					break;
			}
		}
		if (preIncr) {
			int writeBack = getBit(instruction, 21);
			if (writeBack) {
				setRegister(rn, address);
			}
		} else {
			if (upIncr) {
				address += offset;
			} else {
				address -= offset;
			}
			setRegister(rn, address);
		}
	}

	private void armBlockDataTransfer(int instruction) {
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
			writeln("LDM");
		} else {
			writeln("STM");
		}
		Mode mode = this.mode;
		if (loadPSR) {
			if (load && checkBit(registerList, 15)) {
				setRegister(Register.CPSR, getRegister(Register.SPSR));
			} else {
				mode = Mode.USER;
			}
		}
		if (upIncr) {
			for (int i = 0; i <= 15; i++) {
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
			for (int i = 15; i >= 0; i--) {
				if (checkBit(registerList, i)) {
					if (preIncr) {
						address -= 4;
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
						address -= 4;
					}
				}
			}
		}
		if (writeBack) {
			setRegister(mode, rn, address);
		}
	}

	private void armSingeDataSwap(int instruction) {
		if (!checkCondition(getConditionBits(instruction))) {
			return;
		}
		int byteQuantity = getBit(instruction, 22);
		int rn = getBits(instruction, 16, 19);
		int rd = getBits(instruction, 12, 15);
		int rm = instruction & 0xF;
		int address = getRegister(rn);
		if (byteQuantity) {
			int b = memory.getByte(address) & 0xFF;
			memory.setByte(address, cast(byte) getRegister(rm));
			setRegister(rd, b);
		} else {
			int w = memory.getInt(address);
			if (address & 0b10) {
				w >>>= 16;
			}
			memory.setInt(address, getRegister(rm));
			setRegister(rd, w);
		}
	}

	private void armSoftwareInterrupt(int instruction) {
		if (!checkCondition(getConditionBits(instruction))) {
			return;
		}
		setMode(Mode.SUPERVISOR);
		setFlag(CPSRFlag.I, 1);
		setRegister(Register.LR, getRegister(Register.PC) - 4);
		setRegister(Register.SPSR, Register.CPSR);
		setRegister(Register.PC, 0x8);
		branchSignal = true;
	}

	private void armUndefined(int instruction) {
		if (!checkCondition(getConditionBits(instruction))) {
			return;
		}
		setMode(Mode.UNDEFINED);
		setFlag(CPSRFlag.I, 1);
		setRegister(Register.LR, getRegister(Register.PC) - 4);
		setRegister(Register.SPSR, Register.CPSR);
		setRegister(Register.PC, 0x4);
		branchSignal = true;
	}

	private void armUnsupported(int instruction) {
		throw new UnsupportedARMInstructionException();
	}

	private void thumbMoveShiftedRegister(int instruction) {
		int shiftType = getBits(instruction, 12, 15);
		int shift = getBits(instruction, 6, 10);
		int op = getRegister(getBits(instruction, 3, 5));
		int rd = instruction & 0b111;
		final switch (shiftType) {
			case 0:
				writeln("LSL");
				break;
			case 1:
				writeln("LSR");
				break;
			case 2:
				writeln("ASR");
				break;
			case 3:
				writeln("ROR");
				break;
		}
		int carry;
		op = applyShift(shiftType, true, shift, op, carry);
		setAPSRFlags(op < 0, op == 0, carry);
		setRegister(rd, op);
	}

	private void thumbAddAndSubtract(int instruction) {
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
		int negative, zero, carry, overflow;
		if (opCode) {
			// SUB
			writeln("SUB");
			res = op1 - op2;
			carry = res >= 0;
			overflow = overflowed(op1, -op2, res);
		} else {
			// ADD
			writeln("ADD");
			res = op1 + op2;
			carry = carried(op1, op2, res);
			overflow = overflowed(op1, op2, res);
		}
		negative = res < 0;
		zero = res == 0;
		setRegister(rd, res);
		setAPSRFlags(negative, zero, carry, overflow);
	}

	private void thumbMoveCompareAddAndSubtractImmediate(int instruction) {
		int opCode = getBits(instruction, 11, 12);
		int rd = getBits(instruction, 8, 10);
		int op2 = instruction & 0xFF;
		final switch (opCode) {
			case 0:
				// MOV
				writeln("MOV");
				setRegister(rd, op2);
				setAPSRFlags(op2 < 0, op2 == 0);
				break;
			case 1:
				// CMP
				writeln("CMP");
				int op1 = getRegister(rd);
				int v = op1 - op2;
				setAPSRFlags(v < 0, v == 0, v >= 0, overflowed(op1, -op2, v));
				break;
			case 2:
				// ADD
				writeln("ADD");
				int op1 = getRegister(rd);
				int res = op1 + op2;
				setRegister(rd, res);
				setAPSRFlags(res < 0, res == 0, carried(op1, op2, res), overflowed(op1, op2, res));
				break;
			case 3:
				// SUB
				writeln("SUB");
				int op1 = getRegister(rd);
				int res = op1 - op2;
				setRegister(rd, res);
				setAPSRFlags(res < 0, res == 0, res >= 0, overflowed(op1, -op2, res));
				break;
		}
	}

	private void thumbALUOperations(int instruction) {
		int opCode = getBits(instruction, 6, 9);
		int op2 = getRegister(getBits(instruction, 3, 5));
		int rd = instruction & 0b111;
		int op1 = getRegister(rd);
		final switch (opCode) {
			case 0x0:
				// AND
				writeln("AND");
				int res = op1 & op2;
				setRegister(rd, res);
				setAPSRFlags(res < 0, res == 0);
				break;
			case 0x1:
				// EOR
				writeln("EOR");
				int res = op1 ^ op2;
				setRegister(rd, res);
				setAPSRFlags(res < 0, res == 0);
				break;
			case 0x2:
				// LSL
				writeln("LSL");
				int shift = op2 & 0xFF;
				int res = op1 << shift;
				setRegister(rd, res);
				if (shift == 0) {
					setAPSRFlags(res < 0, res == 0);
				} else {
					setAPSRFlags(res < 0, res == 0, getBit(op1, 32 - shift));
				}
				break;
			case 0x3:
				// LSR
				writeln("LSR");
				int shift = op2 & 0xFF;
				int res = op1 >>> shift;
				setRegister(rd, res);
				if (shift == 0) {
					setAPSRFlags(res < 0, res == 0);
				} else {
					setAPSRFlags(res < 0, res == 0, getBit(op1, shift - 1));
				}
				break;
			case 0x4:
				// ASR
				writeln("ASR");
				int shift = op2 & 0xFF;
				int res = op1 >> shift;
				setRegister(rd, res);
				if (shift == 0) {
					setAPSRFlags(res < 0, res == 0);
				} else {
					setAPSRFlags(res < 0, res == 0, getBit(op1, shift - 1));
				}
				break;
			case 0x5:
				// ADC
				writeln("ADC");
				int carry = getFlag(CPSRFlag.C);
				int res = op1 + op2 + carry;
				setRegister(rd, res);
				setAPSRFlags(res < 0, res == 0, carried(op1, op2 + carry, res), overflowed(op1, op2 + carry, res));
				break;
			case 0x6:
				// SBC
				writeln("SBC");
				int carry = getFlag(CPSRFlag.C);
				int res = op1 - op2 + carry - 1;
				setRegister(rd, res);
				setAPSRFlags(res < 0, res == 0, res >= 0, overflowed(op1, -op2 + carry - 1, res));
				break;
			case 0x7:
				// ROR
				writeln("ROR");
				byte shift = cast(byte) op2;
				asm {
					mov CL, shift;
					ror op1, CL;
				}
				int res = op1;
				setRegister(rd, res);
				if (shift == 0) {
					setAPSRFlags(res < 0, res == 0);
				} else {
					setAPSRFlags(res < 0, res == 0, getBit(op1, shift - 1));
				}
				break;
			case 0x8:
				// TST
				writeln("TST");
				int v = op1 & op2;
				setAPSRFlags(v < 0, v == 0);
				break;
			case 0x9:
				// NEG
				writeln("NEG");
				int res = 0 - op2;
				setRegister(rd, res);
				setAPSRFlags(res < 0, res == 0, res >= 0, overflowed(0, -op2, res));
				break;
			case 0xA:
				// CMP
				writeln("CMP");
				int v = op1 - op2;
				setAPSRFlags(v < 0, v == 0, v >= 0, overflowed(op1, -op2, v));
				break;
			case 0xB:
				// CMN
				writeln("CMN");
				int v = op1 + op2;
				setAPSRFlags(v < 0, v == 0, carried(op1, op2, v), overflowed(op1, op2, v));
				break;
			case 0xC:
				// ORR
				writeln("ORR");
				int res = op1 | op2;
				setRegister(rd, res);
				setAPSRFlags(res < 0, res == 0);
				break;
			case 0xD:
				// MUL
				writeln("MUL");
				int res = op1 * op2;
				setRegister(rd, res);
				setAPSRFlags(res < 0, res == 0);
				break;
			case 0xE:
				// BIC
				writeln("BIC");
				int res = op1 & ~op2;
				setRegister(rd, res);
				setAPSRFlags(res < 0, res == 0);
				break;
			case 0xF:
				// MNV
				writeln("MNV");
				int res = ~op2;
				setRegister(rd, res);
				setAPSRFlags(res < 0, res == 0);
				break;
		}
	}

	private void thumbHiRegisterOperationsAndBranchExchange(int instruction) {
		int opCode = getBits(instruction, 8, 9);
		int rs = getBits(instruction, 3, 6);
		int rd = instruction & 0b111 | getBit(instruction, 7) << 3;
		final switch (opCode) {
			case 0:
				// ADD
				writeln("ADD");
				setRegister(rd, getRegister(rd) + getRegister(rs));
				break;
			case 1:
				// CMP
				writeln("CMP");
				int op1 = getRegister(rd);
				int op2 = getRegister(rs);
				int v = op1 - op2;
				setAPSRFlags(v < 0, v == 0, v >= 0, overflowed(op1, -op2, v));
				break;
			case 2:
				// MOV
				writeln("MOV");
				setRegister(rd, getRegister(rs));
				break;
			case 3:
				// BX
				writeln("BX");
				int address = getRegister(rs);
				if (address & 0b1) {
					address -= 1;
				} else {
					setFlag(CPSRFlag.T, Set.ARM);
				}
				setRegister(Register.PC, address);
				break;
		}
	}

	private void thumbLoadPCRelative(int instruction) {
		int rd = getBits(instruction, 8, 10);
		int offset = (instruction & 0xFF) * 4;
		int pc = getRegister(Register.PC);
		writeln("LDR");
		setRegister(rd, memory.getInt(pc + offset));
	}

	private void thumbLoadAndStoreWithRegisterOffset(int instruction) {
		int opCode = getBits(instruction, 10, 11);
		int offset = getRegister(getBits(instruction, 6, 8));
		int base = getRegister(getBits(instruction, 3, 5));
		int rd = instruction & 0b111;
		int address = base + offset;
		final switch (opCode) {
			case 0:
				writeln("STR");
				memory.setInt(address, getRegister(rd));
				break;
			case 1:
				writeln("STRB");
				memory.setByte(address, cast(byte) getRegister(rd));
				break;
			case 2:
				writeln("LDR");
				setRegister(rd, memory.getInt(address));
				break;
			case 3:
				writeln("LDRB");
				setRegister(rd, memory.getByte(address) & 0xFF);
				break;
		}
	}

	private void thumbLoadAndStoreSignExtentedByteAndHalfword(int instruction) {
		int opCode = getBits(instruction, 10, 11);
		int offset = getRegister(getBits(instruction, 6, 8));
		int base = getRegister(getBits(instruction, 3, 5));
		int rd = instruction & 0b111;
		int address = base + offset;
		final switch (opCode) {
			case 0:
				writeln("STRH");
				memory.setShort(address, cast(short) getRegister(rd));
				break;
			case 1:
				writeln("LDSB");
				setRegister(rd, memory.getByte(address));
				break;
			case 2:
				writeln("LDRH");
				setRegister(rd, memory.getShort(address) & 0xFFFF);
				break;
			case 3:
				writeln("LDSH");
				setRegister(rd, memory.getShort(address));
				break;
		}
	}

	private void thumbLoadAndStoreWithImmediateOffset(int instruction) {
		int opCode = getBits(instruction, 11, 12);
		int offset = getBits(instruction, 6, 10);
		int base = getRegister(getBits(instruction, 3, 5));
		int rd = instruction & 0b111;
		final switch (opCode) {
			case 0:
				writeln("STR");
				memory.setInt(base + offset * 4, getRegister(rd));
				break;
			case 1:
				writeln("LDR");
				setRegister(rd, memory.getInt(base + offset * 4));
				break;
			case 2:
				writeln("STRB");
				memory.setByte(base + offset, cast(byte) getRegister(rd));
				break;
			case 3:
				writeln("LDRB");
				setRegister(rd, memory.getByte(base + offset) & 0xFF);
		}
	}

	private void thumbLoadAndStoreHalfWord(int instruction) {
		int opCode = getBit(instruction, 11);
		int offset = getBits(instruction, 6, 10) * 2;
		int base = getRegister(getBits(instruction, 3, 5));
		int rd = instruction & 0b111;
		int address = base + offset;
		if (opCode) {
			writeln("LDRH");
			setRegister(rd, memory.getShort(address) & 0xFFFF);
		} else {
			writeln("STRH");
			memory.setShort(address, cast(short) getRegister(rd));
		}
	}

	private int applyShift(int shiftType, bool specialZeroShift, int shift, int op, out int carry) {
		if (!specialZeroShift && shift == 0) {
			carry = getFlag(CPSRFlag.C);
			return op;
		}
		final switch (shiftType) {
			// LSL
			case 0:
				if (shift == 0) {
					carry = getFlag(CPSRFlag.C);
					return op;
				} else {
					carry = getBit(op, 32 - shift);
					return op << shift;
				}
			// LSR
			case 1:
				if (shift == 0) {
					carry = getBit(op, 31);
					return 0;
				} else {
					carry = getBit(op, shift - 1);
					return op >>> shift;
				}
			// ASR
			case 2:
				if (shift == 0) {
					carry = getBit(op, 31);
					return op >> 31;
				} else {
					carry = getBit(op, shift - 1);
					return op >> shift;
				}
			// ROR
			case 3:
				if (shift == 0) {
					// RRX
					carry = getBit(op, 0);
					asm {
						ror op, 1;
					}
					setBit(op, 31, getFlag(CPSRFlag.C));
					setFlag(CPSRFlag.C, carry);
					return op;
				} else {
					carry = getBit(op, shift - 1);
					byte byteShift = cast(byte) shift;
					asm {
						mov CL, byteShift;
						ror op, CL;
					}
					return op;
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
		setBits(registers[Register.CPSR], 29, 31, c << 1 | z << 2 | n << 3);
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
		return getRegister(mode, register);
	}

	private int getRegister(Mode mode, int register) {
		return registers[getRegisterIndex(mode, register)];
	}

	private void setRegister(int register, int value) {
		setRegister(mode, register, value);
	}

	private void setRegister(Mode mode, int register, int value) {
		registers[getRegisterIndex(mode, register)] = value;
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

public class UnsupportedARMInstructionException : Exception {
	protected this() {
		super("This ARM instruction is unsupported by the implementation");
	}
}
