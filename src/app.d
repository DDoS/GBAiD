import std.stdio;
import std.getopt;
import std.string;
import std.file;
import std.path;

import gbaid.system;
import gbaid.util;

public void main(string[] args) {
	string bios = null, save = null;
	bool noLoad = false, noSave = false;
	getopt(args,
		"bios|b", &bios,
		"save|s", &save,
		"noload|n", &noLoad,
		"nosave|N", &noSave
	);

	if (bios is null) {
		writeln("Missing BIOS file path, sepcify with \"-b (path to bios)\"");
		return;
	}
	bios = expandPath(bios);

	string rom = getSafe!string(args, 1, null);
	if (rom is null) {
		writeln("Missing ROM file path, sepcify as last argument");
		return;
	}
	rom = expandPath(rom);

	if (save is null) {
		save = setExtension(rom, ".sav");
		writeln("Missing save file path, using \"" ~ save ~ "\". Specify with \"-s (path to save)\"");
	} else {
		save = expandPath(save);
	}

	GameBoyAdvance gba = new GameBoyAdvance(bios);

	gba.loadROM(rom);
	if (!noLoad) {
		if (exists(save)) {
			gba.loadSRAM(save);
			writeln("Loaded save \"" ~ save ~ "\"");
		} else {
			writeln("Using new save");
		}
	}

	gba.run();

	if (!noSave) {
		gba.saveSRAM(save);
		writeln("Saved save \"" ~ save ~ "\"");
	}

	// TODO:
	//       implement EEPROM and FLASH saves
	//       fix PKMN saves not working
	//       fix graphic glitch in LoZ intro (CPU glitch?)
	//       investigate PKMN crash (when entering random encounter)
	//       finish implementing bitmap modes in graphics
	//       rewrite more of the graphics in x64
}
