import std.stdio;

import gbaid.system;

public void main(string[] args) {
	if (args.length < 2) {
		throw new Exception("Missing ROM path as first argument");
	}
	GameBoyAdvance gba = new GameBoyAdvance(args[1]);
	gba.start();
}
