import std.stdio;
import std.getopt;
import std.string : string;

import gbaid.system;
import gbaid.util;

public void main(string[] args) {
	string bios;
	string sram;
	getopt(args,
		"bios|b", &bios,
		"save|sram|s", &sram
	);
	string rom = getSafe!string(args, 1);
	GameBoyAdvance gba = new GameBoyAdvance(bios);
	if (rom !is null) {
		gba.loadROM(rom);
	}
	if (sram !is null) {
		gba.loadSRAM(sram);
	}
	gba.start();
}
