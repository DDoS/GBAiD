import std.stdio;
import gbaid.arm;
import gbaid.memory;

public void main(string[] args) {
	if (args.length < 2) {
		throw new Exception("Missing ROM path as first argument");
	}
	ARMProcessor processor = new ARMProcessor();
	ROM rom = new ROM(args[1]);
	writeln(rom.getInt(0));
	processor.test();
}
