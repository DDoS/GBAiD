import std.stdio;
import std.getopt;
import std.string;

import gbaid.system;
import gbaid.util;

public void main(string[] args) {
	string bios;
	string sram;
	getopt(args,
		"bios|b", &bios,
		"save|sram|s", &sram
	);
	string rom = getSafe!string(args, 1, "");
	bios = expandPath(bios);
	sram = expandPath(sram);
	rom = expandPath(rom);
	GameBoyAdvance gba = new GameBoyAdvance(bios);
	if (rom !is null) {
		gba.loadROM(rom);
	}
	if (sram !is null) {
		gba.loadSRAM(sram);
	}
	gba.run();

	// TODO:
	//       fix graphic glitch in LoZ intro
	//       finish input (move to new module, read in IO registers, IRQs)
	//       implement basic saves (needed to quicken debugging)
	//       investigate PKMN crash (when entering random encounter)
	//       finish implementing bitmap modes in graphics
	//       rewrite more of the graphics in x64
}
