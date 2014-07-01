import std.stdio;
import gbaid.arm;
import gbaid.memory;

public void main() {
	ARMProcessor processor = new ARMProcessor();
	Memory ram = new RAM(1024);
	ram.setInt(10, 10);
	writeln(ram.getInt(10));
	processor.test();
}
