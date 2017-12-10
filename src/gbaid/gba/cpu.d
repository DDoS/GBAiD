module gbaid.gba.cpu;

import gbaid.util;

import gbaid.gba.register;
import gbaid.gba.memory;
import gbaid.gba.arm;
import gbaid.gba.thumb;

private enum uint AVERAGE_CPI = 2;

public class ARM7TDMI {
    private MemoryBus* memory;
    private Registers registers;
    private bool haltSignal = false;
    private bool irqSignal = false;
    private int instruction;
    private int decoded;

    public this(MemoryBus* memory, uint entryPointAddress = 0x0) {
        this.memory = memory;
        // Initialize to ARM in system mode
        registers.setFlag(CPSRFlag.T, Set.ARM);
        registers.setMode(Mode.SYSTEM);
        // Initialize the stack pointers
        registers.set(Mode.SUPERVISOR, Register.SP, 0x3007FE0);
        registers.set(Mode.IRQ, Register.SP, 0x3007FA0);
        registers.set(Mode.USER, Register.SP, 0x3007F00);
        // Set first instruction
        registers.setPC(entryPointAddress);
        // Branch to instruction
        branch();
    }

    public void halt(bool state) {
        haltSignal = state;
    }

    public void irq(bool state) {
        irqSignal = state;
    }

    public bool halted() {
        return irqSignal;
    }

    public bool inIRQ() {
        return irqSignal;
    }

    public int getProgramCounter() {
        return registers.getExecutedPC();
    }

    public int getPreFetch() {
        return instruction;
    }

    public int getNextInstruction() {
        return decoded;
    }

    public size_t emulate(size_t cycles) {
        debug (outputInstructions) {
            scope (failure) {
                registers.dumpInstructions();
            }
        }
        // Discard all the cycles if halted
        if (haltSignal) {
            return 0;
        }
        // Otherwise use up 2 cycles per instruction
        while (cycles >= AVERAGE_CPI) {
            // Take the cycles for the instruction
            cycles -= AVERAGE_CPI;
            // Check for an IRQ
            if (irqSignal && !registers.getFlag(CPSRFlag.I)) {
                // Branch to the handler
                branchIRQ();
                continue;
            }
            // Fetch the next instruction in the pipeline
            int nextInstruction = fetchInstruction();
            // "Decode" the second instruction in the pipeline (we don't need to actually do anything)
            int nextDecoded = instruction;
            instruction = nextInstruction;
            // Execute the last instruction in the pipeline
            final switch (registers.instructionSet) {
                case Set.ARM:
                    executeARMInstruction(&registers, memory, decoded);
                    break;
                case Set.THUMB:
                    executeTHUMBInstruction(&registers, memory, decoded);
                    break;
            }
            decoded = nextDecoded;
            // Then go to the next instruction
            if (registers.wasPCModified()) {
                branch();
            } else {
                registers.incrementPC();
            }
            // Discard all the cycles if the instruction caused a halt
            if (haltSignal) {
                return 0;
            }
        }
        return cycles;
    }

    private void branch() {
        // fetch first instruction
        int firstInstruction = fetchInstruction();
        registers.incrementPC();
        // fetch second
        instruction = fetchInstruction();
        registers.incrementPC();
        // "decode" first
        decoded = firstInstruction;
    }

    private int fetchInstruction() {
        final switch (registers.instructionSet) {
            case Set.ARM:
                return memory.get!int(registers.getPC());
            case Set.THUMB:
                return memory.get!short(registers.getPC()).mirror();
        }
    }

    private void branchIRQ() {
        registers.setSPSR(Mode.IRQ, registers.getCPSR());
        registers.set(Mode.IRQ, Register.LR, registers.getExecutedPC() + 4);
        registers.setPC(0x18);
        registers.setFlag(CPSRFlag.I, 1);
        registers.setFlag(CPSRFlag.T, Set.ARM);
        registers.setMode(Mode.IRQ);
        branch();
    }
}
