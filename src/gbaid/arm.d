module gbaid.arm;

import std.stdio;
import core.atomic;
import core.thread;

import gbaid.memory;
import gbaid.util;

public class ARM7TDMI {
	private Memory memory;
	private shared uint entryPointAddress;
	private Thread thread;
	private shared bool running = false;
	private int[37] registers = new int[37];
	private Mode mode;
	private Pipeline armPipeline;
	private Pipeline thumbPipeline;
	private Pipeline pipeline;
	private int instruction;
	private int decoded;
	private bool branchSignal;
	private bool exchangeSignal;
	private shared bool irqSignal;

	public void setMemory(Memory memory) {
		this.memory = memory;
	}

	public void setEntryPointAddress(uint entryPointAddress) {
		atomicStore(this.entryPointAddress, entryPointAddress);
	}

	public void start() {
		if (thread is null) {
			thread = new Thread(&run);
			thread.start();
		}
	}

	public void stop() {
		if (thread !is null) {
			atomicStore(running, false);
			thread.join();
			thread = null;
		}
	}

	private void run() {
		armPipeline = new ARMPipeline();
		thumbPipeline = new THUMBPipeline();
		// initialize the stack pointers
		setRegister(Mode.SUPERVISOR, Register.SP, 0x3007FE0);
		setRegister(Mode.IRQ, Register.SP, 0x3007FA0);
		setRegister(Mode.USER, Register.SP, 0x3007F00);
		// initialize to ARM in system mode
		setFlag(CPSRFlag.T, Set.ARM);
		setMode(Mode.SYSTEM);
		exchangeSignal = true;
		updateModeAndSet();
		// set first instruction
		setRegister(Register.PC, entryPointAddress);
		// branch to instruction
		branch();
		// start ticking
		running = true;
		while (running) {
			if (irqSignal && !getFlag(CPSRFlag.I)) {
				processIRQ();
			} else {
				tick();
			}
			updateModeAndSet();
			if (branchSignal) {
				branch();
			} else {
				pipeline.incrementPC();
			}
		}
	}

	public void signalIRQ() {
		atomicStore(irqSignal, true);
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
		// remove branch signal flag
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
		if (exchangeSignal) {
			if (getFlag(CPSRFlag.T)) {
				pipeline = thumbPipeline;
			} else {
				pipeline = armPipeline;
			}
			exchangeSignal = false;
		}
	}

	private void processIRQ() {
		debug(outputInstructions) writeln("IRQ");
		setMode(Mode.IRQ);
		setRegister(Mode.IRQ, Register.SPSR, Register.CPSR);
		setFlag(CPSRFlag.I, 1);
		int oldT = getFlag(CPSRFlag.T);
		setFlag(CPSRFlag.T, Set.ARM);
		setRegister(Mode.IRQ, Register.LR, getRegister(Register.PC) - (oldT ? 2 : 4));
		setRegister(Register.PC, 0x18);
		branchSignal = true;
		exchangeSignal = true;
		irqSignal = false;
	}

	private interface Pipeline {
		protected int fetch();
		protected int decode(int instruction);
		protected void execute(int instruction);
		protected void incrementPC();
	}

	private class ARMPipeline : Pipeline {
		protected override int fetch() {
			return memory.getInt(getRegister(Register.PC));
		}

		protected override int decode(int instruction) {
			// Nothing to do
			return instruction;
		}

		protected override void execute(int instruction) {
			debug(outputInstructions) writef("%x ", getRegister(Register.PC) - 8);
			int category = getBits(instruction, 25, 27);
			final switch (category) {
				case 0:
					if (getBits(instruction, 23, 24) == 0b10 && getBit(instruction, 20) == 0b0 && getBits(instruction, 4, 11) == 0b00000000) {
						// PSR Reg
						psrTransfer(instruction);
					} else if (getBits(instruction, 8, 24) == 0b00010010111111111111) {
						// BX, BLX
						branchAndExchange(instruction);
					} else if (getBits(instruction, 20, 24) == 0b10010 && getBits(instruction, 4, 7) == 0b0111) {
						// BKPT
						unsupported(instruction);
					} else if (getBits(instruction, 16, 24) == 0b101101111 && getBits(instruction, 4, 11) == 0b11110001) {
						// CLZ
						unsupported(instruction);
					} else if (getBits(instruction, 23, 24) == 0b10 && getBit(instruction, 20) == 0b0 && getBits(instruction, 4, 11) == 0b00000101) {
						// QALU
						unsupported(instruction);
					} else if (getBits(instruction, 22, 24) == 0b000 && getBits(instruction, 4, 7) == 0b1001) {
						// Multiply
						multiplyAndMultiplyAccumulate(instruction);
					} else if (getBits(instruction, 23, 24) == 0b01 && getBits(instruction, 4, 7) == 0b1001) {
						// MulLong
						multiplyAndMultiplyAccumulate(instruction);
					} else if (getBits(instruction, 23, 24) == 0b10 && getBit(instruction, 20) == 0b0 && getBit(instruction, 7) == 0b1 && getBit(instruction, 4) == 0b0) {
						// MulHalf
						unsupported(instruction);
					} else if (getBits(instruction, 23, 24) == 0b10 && getBits(instruction, 20, 21) == 0b00 && getBits(instruction, 4, 11) == 0b00001001) {
						// TransSwp12
						singeDataSwap(instruction);
					} else if (getBit(instruction, 22) == 0b0 && getBits(instruction, 7, 11) == 0b00001 && getBit(instruction, 4) == 0b1) {
						// TransReg10
						halfwordAndSignedDataTransfer(instruction);
					} else if (getBit(instruction, 22) == 0b1 && getBit(instruction, 7) == 0b1 && getBit(instruction, 4) == 0b1) {
						// TransImm10
						halfwordAndSignedDataTransfer(instruction);
					} else {
						// DataProc
						dataProcessing(instruction);
					}
					break;
				case 1:
					if (getBits(instruction, 23, 24) == 0b10 && getBit(instruction, 20) == 0b0) {
						// PSR Reg
						psrTransfer(instruction);
					} else {
						// DataProc
						dataProcessing(instruction);
					}
					break;
				case 2:
					// TransImm9
					singleDataTransfer(instruction);
					break;
				case 3:
					if (getBit(instruction, 4) == 0b0) {
						// TransReg9
						singleDataTransfer(instruction);
					} else {
						// Undefined
						undefined(instruction);
					}
					break;
				case 4:
					// BlockTrans
					blockDataTransfer(instruction);
					break;
				case 5:
					// B, BL, BLX
					branchAndBranchWithLink(instruction);
					break;
				case 6:
					if (getBits(instruction, 21, 24) == 0b0010) {
						// CoDataTrans
						unsupported(instruction);
					} else {
						// CoRR
						unsupported(instruction);
					}
					break;
				case 7:
					if (getBit(instruction, 24) == 0b0 && getBit(instruction, 4) == 0b0) {
						// CoDataOp
						unsupported(instruction);
					} else if (getBit(instruction, 24) == 0b0 && getBit(instruction, 4) == 0b1) {
						// CoRegTrans
						unsupported(instruction);
					} else {
						// SWI
						softwareInterrupt(instruction);
					}
					break;
			}
		}

		protected override void incrementPC() {
			setRegister(Register.PC, getRegister(Register.PC) + 4);
		}

		private void branchAndExchange(int instruction) {
			if (!checkCondition(getConditionBits(instruction))) {
				return;
			}
			debug(outputInstructions) writeln("BX");
			int address = getRegister(instruction & 0xF);
			if (address & 0b1) {
				// switch to THUMB
				setFlag(CPSRFlag.T, Set.THUMB);
				// discard the last bit in the address
				address -= 1;
			}
			setRegister(Register.PC, address);
			branchSignal = true;
			exchangeSignal = true;
		}

		private void branchAndBranchWithLink(int instruction) {
			if (!checkCondition(getConditionBits(instruction))) {
				return;
			}
			int opCode = getBit(instruction, 24);
			int offset = instruction & 0xFFFFFF;
			// sign extend the offset
			offset <<= 8;
			offset >>= 8;
			int pc = getRegister(Register.PC);
			if (opCode) {
				debug(outputInstructions) writeln("BL");
				setRegister(Register.LR, pc - 4);
			} else {
				debug(outputInstructions) writeln("B");
			}
			setRegister(Register.PC, pc + offset * 4);
			branchSignal = true;
		}

		private void dataProcessing(int instruction) {
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
					debug(outputInstructions) writeln("AND");
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
					debug(outputInstructions) writeln("EOR");
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
					debug(outputInstructions) writeln("SUB");
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
					debug(outputInstructions) writeln("RSB");
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
					debug(outputInstructions) writeln("ADD");
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
					debug(outputInstructions) writeln("ADC");
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
					debug(outputInstructions) writeln("SBC");
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
					debug(outputInstructions) writeln("RSC");
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
					debug(outputInstructions) writeln("TST");
					int v = op1 & op2;
					overflow = getFlag(CPSRFlag.V);
					zero = v == 0;
					negative = v < 0;
					break;
				case 0x9:
					// TEQ
					debug(outputInstructions) writeln("TEQ");
					int v = op1 ^ op2;
					overflow = getFlag(CPSRFlag.V);
					zero = v == 0;
					negative = v < 0;
					break;
				case 0xA:
					// CMP
					debug(outputInstructions) writeln("CMP");
					int v = op1 - op2;
					overflow = overflowed(op1, -op2, v);
					carry = v >= 0;
					zero = v == 0;
					negative = v < 0;
					break;
				case 0xB:
					// CMN
					debug(outputInstructions) writeln("CMN");
					int v = op1 + op2;
					overflow = overflowed(op1, op2, v);
					carry = carried(op1, op2, v);
					zero = v == 0;
					negative = v < 0;
					break;
				case 0xC:
					// ORR
					debug(outputInstructions) writeln("ORR");
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
					debug(outputInstructions) writeln("MOV");
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
					debug(outputInstructions) writeln("BIC");
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
					debug(outputInstructions) writeln("MVN");
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

		private void psrTransfer(int instruction) {
			if (!checkCondition(getConditionBits(instruction))) {
				return;
			}
			int psrSrc = getBit(instruction, 22);
			int opCode = getBit(instruction, 21);
			if (opCode) {
				debug(outputInstructions) writeln("MSR");
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
				debug(outputInstructions) writeln("MRS");
				int rd = getBits(instruction, 12, 15);
				if (psrSrc) {
					setRegister(rd, getRegister(Register.SPSR));
				} else {
					setRegister(rd, getRegister(Register.CPSR));
				}
			}
		}

		private void multiplyAndMultiplyAccumulate(int instruction) {
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
					debug(outputInstructions) writeln("MUL");
					int res = op1 * op2;
					setRegister(rd, res);
					if (setFlags) {
						setAPSRFlags(res < 0, res == 0);
					}
					break;
				case 1:
					debug(outputInstructions) writeln("MLA");
					int op3 = getRegister(getBits(instruction, 12, 15));
					int res = op1 * op2 + op3;
					setRegister(rd, res);
					if (setFlags) {
						setAPSRFlags(res < 0, res == 0);
					}
					break;
				case 4:
					debug(outputInstructions) writeln("UMULL");
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
					debug(outputInstructions) writeln("UMLAL");
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
					debug(outputInstructions) writeln("SMULL");
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
					debug(outputInstructions) writeln("SMLAL");
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

		private void singleDataTransfer(int instruction) {
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
						debug(outputInstructions) writeln("LDRB");
						int b = memory.getByte(address) & 0xFF;
						setRegister(rd, b);
					} else {
						debug(outputInstructions) writeln("LDR");
						int w = memory.getInt(address);
						if (address & 0b10) {
							w >>>= 16;
						}
						setRegister(rd, w);
					}
				} else {
					if (byteQuantity) {
						debug(outputInstructions) writeln("STRB");
						byte b = cast(byte) getRegister(rd);
						memory.setByte(address, b);
					} else {
						debug(outputInstructions) writeln("STR");
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
						debug(outputInstructions) writeln("LDRB");
						int b = memory.getByte(address) & 0xFF;
						setRegister(rd, b);
					} else {
						debug(outputInstructions) writeln("LDR");
						int w = memory.getInt(address);
						if (address & 0b10) {
							w >>>= 16;
						}
						setRegister(rd, w);
					}
				} else {
					if (byteQuantity) {
						debug(outputInstructions) writeln("STRB");
						byte b = cast(byte) getRegister(rd);
						memory.setByte(address, b);
					} else {
						debug(outputInstructions) writeln("STR");
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

		private void halfwordAndSignedDataTransfer(int instruction) {
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
						debug(outputInstructions) writeln("LDRH");
						int hw = memory.getShort(address) & 0xFFFF;
						setRegister(rd, hw);
						break;
					case 2:
						debug(outputInstructions) writeln("LDRSB");
						int b = memory.getByte(address);
						setRegister(rd, b);
						break;
					case 3:
						debug(outputInstructions) writeln("LDRSH");
						int hw = memory.getShort(address);
						setRegister(rd, hw);
						break;
				}
			} else {
				final switch (opCode) {
					case 1:
						debug(outputInstructions) writeln("STRH");
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
				debug(outputInstructions) writeln("LDM");
			} else {
				debug(outputInstructions) writeln("STM");
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

		private void singeDataSwap(int instruction) {
			if (!checkCondition(getConditionBits(instruction))) {
				return;
			}
			int byteQuantity = getBit(instruction, 22);
			int rn = getBits(instruction, 16, 19);
			int rd = getBits(instruction, 12, 15);
			int rm = instruction & 0xF;
			int address = getRegister(rn);
			debug(outputInstructions) writeln("SWP");
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

		private void softwareInterrupt(int instruction) {
			if (!checkCondition(getConditionBits(instruction))) {
				return;
			}
			debug(outputInstructions) writeln("SWI");
			setMode(Mode.SUPERVISOR);
			setRegister(Mode.SUPERVISOR, Register.SPSR, Register.CPSR);
			setFlag(CPSRFlag.I, 1);
			setRegister(Mode.SUPERVISOR, Register.LR, getRegister(Register.PC) - 4);
			setRegister(Register.PC, 0x8);
			branchSignal = true;
		}

		private void undefined(int instruction) {
			if (!checkCondition(getConditionBits(instruction))) {
				return;
			}
			debug(outputInstructions) writeln("Undefined");
			setMode(Mode.UNDEFINED);
			setRegister(Mode.UNDEFINED, Register.SPSR, Register.CPSR);
			setFlag(CPSRFlag.I, 1);
			setRegister(Mode.UNDEFINED, Register.LR, getRegister(Register.PC) - 4);
			setRegister(Register.PC, 0x4);
			branchSignal = true;
		}

		private void unsupported(int instruction) {
			throw new UnsupportedARMInstructionException();
		}
	}

	private class THUMBPipeline : Pipeline {
		protected override int fetch() {
			return memory.getShort(getRegister(Register.PC));
		}

		protected override int decode(int instruction) {
			// Nothing to do
			return instruction;
		}

		protected override void execute(int instruction) {
			debug(outputInstructions) writef("%x ", getRegister(Register.PC) - 4);
			int category = getBits(instruction, 13, 15);
			final switch (category) {
				case 0:
					if (getBits(instruction, 11, 12) == 0b11) {
						// ADD/SUB
						addAndSubtract(instruction);
					} else {
						// Shifted
						moveShiftedRegister(instruction);
					}
					break;
				case 1:
					// Immedi.
					moveCompareAddAndSubtractImmediate(instruction);
					break;
				case 2:
					if (getBits(instruction, 10, 12) == 0b000) {
						// AluOp
						aluOperations(instruction);
					} else if (getBits(instruction, 10, 12) == 0b001) {
						// HiReg/BX
						hiRegisterOperationsAndBranchExchange(instruction);
					} else if (getBits(instruction, 11, 12) == 0b01) {
						// LDR PC
						loadPCRelative(instruction);
					} else if (getBit(instruction, 12) == 0b1 && getBit(instruction, 9) == 0b0) {
						// LDR/STR
						loadAndStoreWithRegisterOffset(instruction);
					} else if (getBit(instruction, 12) == 0b1 && getBit(instruction, 9) == 0b1) {
						// LDR/STR H/SB/SH
						loadAndStoreSignExtentedByteAndHalfword(instruction);
					}
					break;
				case 3:
					// LDR/STR {B}
					loadAndStoreWithImmediateOffset(instruction);
					break;
				case 4:
					if (getBit(instruction, 12) == 0b0) {
						// LDR/STR H
						loadAndStoreHalfWord(instruction);
					} else if (getBit(instruction, 12) == 0b1) {
						// LDR/STR SP
						loadAndStoreSPRelative(instruction);
					}
					break;
				case 5:
					if (getBit(instruction, 12) == 0b0) {
						// ADD PC/SP
						getRelativeAddresss(instruction);
					} else if (getBits(instruction, 8, 12) == 0b10000) {
						// ADD SP,nn
						addOffsetToStackPointer(instruction);
					} else if (getBit(instruction, 12) == 0b1 && getBits(instruction, 9, 10) == 0b10) {
						// PUSH/POP
						pushAndPopRegisters(instruction);
					} else if (getBits(instruction, 8, 12) == 0b11110) {
						// BKPT
						unsupported(instruction);
					}
					break;
				case 6:
					if (getBit(instruction, 12) == 0b0) {
						// LDM/STM
						multipleLoadAndStore(instruction);
					} else if (getBits(instruction, 8, 12) == 0b11111) {
						// SWI
						softwareInterrupt(instruction);
					} else if (getBits(instruction, 8, 12) == 0b11110) {
						// UNDEF
						undefined(instruction);
					} else {
						// B{cond}
						conditionalBranch(instruction);
					}
					break;
				case 7:
					if (getBits(instruction, 11, 12) == 0b00) {
						// B
						unconditionalBranch(instruction);
					} else if (getBits(instruction, 11, 12) == 0b01 && getBit(instruction, 0) == 0b0) {
						// BLXsuf
						unsupported(instruction);
					} else if (getBits(instruction, 11, 12) == 0b01 && getBit(instruction, 0) == 0b1) {
						// UNDEF
						undefined(instruction);
					} else if (getBit(instruction, 12) == 0b1) {
						// BL
						longBranchWithLink(instruction);
					}
					break;
			}
		}

		protected override void incrementPC() {
			setRegister(Register.PC, getRegister(Register.PC) + 2);
		}

		private void moveShiftedRegister(int instruction) {
			int shiftType = getBits(instruction, 12, 15);
			int shift = getBits(instruction, 6, 10);
			int op = getRegister(getBits(instruction, 3, 5));
			int rd = instruction & 0b111;
			final switch (shiftType) {
				case 0:
					debug(outputInstructions) writeln("LSL");
					break;
				case 1:
					debug(outputInstructions) writeln("LSR");
					break;
				case 2:
					debug(outputInstructions) writeln("ASR");
					break;
				case 3:
					debug(outputInstructions) writeln("ROR");
					break;
			}
			int carry;
			op = applyShift(shiftType, true, shift, op, carry);
			setAPSRFlags(op < 0, op == 0, carry);
			setRegister(rd, op);
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
			int negative, zero, carry, overflow;
			if (opCode) {
				// SUB
				debug(outputInstructions) writeln("SUB");
				res = op1 - op2;
				carry = res >= 0;
				overflow = overflowed(op1, -op2, res);
			} else {
				// ADD
				debug(outputInstructions) writeln("ADD");
				res = op1 + op2;
				carry = carried(op1, op2, res);
				overflow = overflowed(op1, op2, res);
			}
			negative = res < 0;
			zero = res == 0;
			setRegister(rd, res);
			setAPSRFlags(negative, zero, carry, overflow);
		}

		private void moveCompareAddAndSubtractImmediate(int instruction) {
			int opCode = getBits(instruction, 11, 12);
			int rd = getBits(instruction, 8, 10);
			int op2 = instruction & 0xFF;
			final switch (opCode) {
				case 0:
					// MOV
					debug(outputInstructions) writeln("MOV");
					setRegister(rd, op2);
					setAPSRFlags(op2 < 0, op2 == 0);
					break;
				case 1:
					// CMP
					debug(outputInstructions) writeln("CMP");
					int op1 = getRegister(rd);
					int v = op1 - op2;
					setAPSRFlags(v < 0, v == 0, v >= 0, overflowed(op1, -op2, v));
					break;
				case 2:
					// ADD
					debug(outputInstructions) writeln("ADD");
					int op1 = getRegister(rd);
					int res = op1 + op2;
					setRegister(rd, res);
					setAPSRFlags(res < 0, res == 0, carried(op1, op2, res), overflowed(op1, op2, res));
					break;
				case 3:
					// SUB
					debug(outputInstructions) writeln("SUB");
					int op1 = getRegister(rd);
					int res = op1 - op2;
					setRegister(rd, res);
					setAPSRFlags(res < 0, res == 0, res >= 0, overflowed(op1, -op2, res));
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
					debug(outputInstructions) writeln("AND");
					int res = op1 & op2;
					setRegister(rd, res);
					setAPSRFlags(res < 0, res == 0);
					break;
				case 0x1:
					// EOR
					debug(outputInstructions) writeln("EOR");
					int res = op1 ^ op2;
					setRegister(rd, res);
					setAPSRFlags(res < 0, res == 0);
					break;
				case 0x2:
					// LSL
					debug(outputInstructions) writeln("LSL");
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
					debug(outputInstructions) writeln("LSR");
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
					debug(outputInstructions) writeln("ASR");
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
					debug(outputInstructions) writeln("ADC");
					int carry = getFlag(CPSRFlag.C);
					int res = op1 + op2 + carry;
					setRegister(rd, res);
					setAPSRFlags(res < 0, res == 0, carried(op1, op2 + carry, res), overflowed(op1, op2 + carry, res));
					break;
				case 0x6:
					// SBC
					debug(outputInstructions) writeln("SBC");
					int carry = getFlag(CPSRFlag.C);
					int res = op1 - op2 + carry - 1;
					setRegister(rd, res);
					setAPSRFlags(res < 0, res == 0, res >= 0, overflowed(op1, -op2 + carry - 1, res));
					break;
				case 0x7:
					// ROR
					debug(outputInstructions) writeln("ROR");
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
					debug(outputInstructions) writeln("TST");
					int v = op1 & op2;
					setAPSRFlags(v < 0, v == 0);
					break;
				case 0x9:
					// NEG
					debug(outputInstructions) writeln("NEG");
					int res = 0 - op2;
					setRegister(rd, res);
					setAPSRFlags(res < 0, res == 0, res >= 0, overflowed(0, -op2, res));
					break;
				case 0xA:
					// CMP
					debug(outputInstructions) writeln("CMP");
					int v = op1 - op2;
					setAPSRFlags(v < 0, v == 0, v >= 0, overflowed(op1, -op2, v));
					break;
				case 0xB:
					// CMN
					debug(outputInstructions) writeln("CMN");
					int v = op1 + op2;
					setAPSRFlags(v < 0, v == 0, carried(op1, op2, v), overflowed(op1, op2, v));
					break;
				case 0xC:
					// ORR
					debug(outputInstructions) writeln("ORR");
					int res = op1 | op2;
					setRegister(rd, res);
					setAPSRFlags(res < 0, res == 0);
					break;
				case 0xD:
					// MUL
					debug(outputInstructions) writeln("MUL");
					int res = op1 * op2;
					setRegister(rd, res);
					setAPSRFlags(res < 0, res == 0);
					break;
				case 0xE:
					// BIC
					debug(outputInstructions) writeln("BIC");
					int res = op1 & ~op2;
					setRegister(rd, res);
					setAPSRFlags(res < 0, res == 0);
					break;
				case 0xF:
					// MNV
					debug(outputInstructions) writeln("MNV");
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
					debug(outputInstructions) writeln("ADD");
					setRegister(rd, getRegister(rd) + getRegister(rs));
					break;
				case 1:
					// CMP
					debug(outputInstructions) writeln("CMP");
					int op1 = getRegister(rd);
					int op2 = getRegister(rs);
					int v = op1 - op2;
					setAPSRFlags(v < 0, v == 0, v >= 0, overflowed(op1, -op2, v));
					break;
				case 2:
					// MOV
					debug(outputInstructions) writeln("MOV");
					setRegister(rd, getRegister(rs));
					break;
				case 3:
					// BX
					debug(outputInstructions) writeln("BX");
					int address = getRegister(rs);
					if (address & 0b1) {
						address -= 1;
					} else {
						setFlag(CPSRFlag.T, Set.ARM);
					}
					setRegister(Register.PC, address);
					branchSignal = true;
					exchangeSignal = true;
					break;
			}
		}

		private void loadPCRelative(int instruction) {
			int rd = getBits(instruction, 8, 10);
			int offset = (instruction & 0xFF) * 4;
			int pc = getRegister(Register.PC);
			debug(outputInstructions) writeln("LDR");
			setRegister(rd, memory.getInt(pc + offset));
		}

		private void loadAndStoreWithRegisterOffset(int instruction) {
			int opCode = getBits(instruction, 10, 11);
			int offset = getRegister(getBits(instruction, 6, 8));
			int base = getRegister(getBits(instruction, 3, 5));
			int rd = instruction & 0b111;
			int address = base + offset;
			final switch (opCode) {
				case 0:
					debug(outputInstructions) writeln("STR");
					memory.setInt(address, getRegister(rd));
					break;
				case 1:
					debug(outputInstructions) writeln("STRB");
					memory.setByte(address, cast(byte) getRegister(rd));
					break;
				case 2:
					debug(outputInstructions) writeln("LDR");
					setRegister(rd, memory.getInt(address));
					break;
				case 3:
					debug(outputInstructions) writeln("LDRB");
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
					debug(outputInstructions) writeln("STRH");
					memory.setShort(address, cast(short) getRegister(rd));
					break;
				case 1:
					debug(outputInstructions) writeln("LDSB");
					setRegister(rd, memory.getByte(address));
					break;
				case 2:
					debug(outputInstructions) writeln("LDRH");
					setRegister(rd, memory.getShort(address) & 0xFFFF);
					break;
				case 3:
					debug(outputInstructions) writeln("LDSH");
					setRegister(rd, memory.getShort(address));
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
					debug(outputInstructions) writeln("STR");
					memory.setInt(base + offset * 4, getRegister(rd));
					break;
				case 1:
					debug(outputInstructions) writeln("LDR");
					setRegister(rd, memory.getInt(base + offset * 4));
					break;
				case 2:
					debug(outputInstructions) writeln("STRB");
					memory.setByte(base + offset, cast(byte) getRegister(rd));
					break;
				case 3:
					debug(outputInstructions) writeln("LDRB");
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
				debug(outputInstructions) writeln("LDRH");
				setRegister(rd, memory.getShort(address) & 0xFFFF);
			} else {
				debug(outputInstructions) writeln("STRH");
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
				debug(outputInstructions) writeln("LDR");
				setRegister(rd, memory.getInt(address));
			} else {
				debug(outputInstructions) writeln("STR");
				memory.setInt(address, getRegister(rd));
			}
		}

		private void getRelativeAddresss(int instruction) {
			int opCode = getBit(instruction, 11);
			int rd = getBits(instruction, 8, 10);
			int offset = (instruction & 0xFF) * 4;
			if (opCode) {
				debug(outputInstructions) writeln("ADD");
				setRegister(rd, getRegister(Register.SP) + offset);
			} else {
				debug(outputInstructions) writeln("ADD");
				setRegister(rd, (getRegister(Register.PC) & 0xFFFFFFFD) + offset);
			}
		}

		private void addOffsetToStackPointer(int instruction) {
			int opCode = getBit(instruction, 7);
			int offset = (instruction & 0b111111) * 4;
			if (opCode) {
				debug(outputInstructions) writeln("ADD");
				setRegister(Register.SP, getRegister(Register.SP) - offset);
			} else {
				debug(outputInstructions) writeln("ADD");
				setRegister(Register.SP, getRegister(Register.SP) + offset);
			}
		}

		private void pushAndPopRegisters(int instruction) {
			int opCode = getBit(instruction, 11);
			int pcAndLR = getBit(instruction, 8);
			int registerList = instruction & 0xFF;
			int sp = getRegister(Register.SP);
			if (opCode) {
				debug(outputInstructions) writeln("POP");
				for (int i = 0; i <= 7; i++) {
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
				debug(outputInstructions) writeln("PUSH");
				if (pcAndLR) {
					sp -= 4;
					memory.setInt(sp, getRegister(Register.LR));
				}
				for (int i = 7; i >= 0; i--) {
					if (checkBit(registerList, i)) {
						sp -= 4;
						memory.setInt(sp, getRegister(i));
					}
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
				debug(outputInstructions) writeln("LDMIA");
				for (int i = 0; i <= 7; i++) {
					if (checkBit(registerList, i)) {
						setRegister(i, memory.getInt(address));
						address += 4;
					}
				}
			} else {
				debug(outputInstructions) writeln("STMIA");
				for (int i = 0; i <= 7; i++) {
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
			debug(outputInstructions) writeln("B");
			int offset = instruction & 0xFF;
			// sign extend the offset
			offset <<= 24;
			offset >>= 24;
			setRegister(Register.PC, getRegister(Register.PC) + offset * 2);
			branchSignal = true;
		}

		private void softwareInterrupt(int instruction) {
			debug(outputInstructions) writeln("SWI");
			setMode(Mode.SUPERVISOR);
			setRegister(Mode.SUPERVISOR, Register.SPSR, Register.CPSR);
			setFlag(CPSRFlag.I, 1);
			setFlag(CPSRFlag.T, Set.ARM);
			setRegister(Mode.SUPERVISOR, Register.LR, getRegister(Register.PC) - 2);
			setRegister(Register.PC, 0x8);
			branchSignal = true;
			exchangeSignal = true;
		}

		private void unconditionalBranch(int instruction) {
			debug(outputInstructions) writeln("B");
			int offset = instruction & 0x7FF;
			// sign extend the offset
			offset <<= 21;
			offset >>= 21;
			setRegister(Register.PC, getRegister(Register.PC) + offset * 2);
			branchSignal = true;
		}

		private void longBranchWithLink(int instruction) {
			int opCode = getBit(instruction, 11);
			int offset = instruction & 0x7FF;
			if (opCode) {
				debug(outputInstructions) writeln("BL");
				int address = getRegister(Register.LR) + (offset << 1);
				setRegister(Register.LR, getRegister(Register.PC) - 2 | 1);
				setRegister(Register.PC, address);
				branchSignal = true;
			} else {
				setRegister(Register.LR, getRegister(Register.PC) + (offset << 12));
			}
		}

		private void undefined(int instruction) {
			debug(outputInstructions) writeln("Undefined");
			setMode(Mode.UNDEFINED);
			setRegister(Mode.UNDEFINED, Register.SPSR, Register.CPSR);
			setFlag(CPSRFlag.I, 1);
			setFlag(CPSRFlag.T, Set.ARM);
			setRegister(Mode.UNDEFINED, Register.LR, getRegister(Register.PC) - 2);
			setRegister(Register.PC, 0x4);
			branchSignal = true;
			exchangeSignal = true;
		}

		private void unsupported(int instruction) {
			throw new UnsupportedTHUMBInstructionException();
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
		registers[getRegisterIndex(mode, register)] = value;
	}
}

private int getConditionBits(int instruction) {
	return instruction >> 28 & 0xF;
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

public class UnsupportedTHUMBInstructionException : Exception {
	protected this() {
		super("This THUMB instruction is unsupported by the implementation");
	}
}
