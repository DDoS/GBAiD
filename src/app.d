import std.stdio;
import gbaid.arm;
import gbaid.ram;

public void main() {
	ARMProcessor processor = new ARMProcessor();
	RAM ram = new RAM(1024);
	processor.test();
}
