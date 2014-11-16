import std.stdio;
import std.getopt;
import std.string;
import std.file;
import std.path;

import gbaid.system;
import gbaid.graphics;
import gbaid.util;

public void main(string[] args) {
	string bios = null, save = null;
	bool noLoad = false, noSave = false;
	float scale = 2;
	UpscalingMode upscaling = UpscalingMode.NONE;
	getopt(args,
		config.caseSensitive,
		"bios|b", &bios,
		"save|s", &save,
		config.bundling,
		"noload|n", &noLoad,
		"nosave|N", &noSave,
		config.noBundling,
		"scale|r", &scale,
		"upscaling|u", &upscaling
	);

	if (bios is null) {
		writeln("Missing BIOS file path, sepcify with \"-b (path to bios)\"");
		return;
	}
	bios = expandPath(bios);
	if (!exists(bios)) {
		writeln("BIOS file doesn't exist");
		return;
	}

	string rom = getSafe!string(args, 1, null);
	if (rom is null) {
		writeln("Missing ROM file path, sepcify as last argument");
		return;
	}
	rom = expandPath(rom);
	if (!exists(rom)) {
		writeln("ROM file doesn't exist");
		return;
	}

	if (save is null) {
		save = setExtension(rom, ".sav");
		writeln("Missing save file path, using \"" ~ save ~ "\". Specify with \"-s (path to save)\"");
	} else {
		save = expandPath(save);
	}

	GameBoyAdvance gba = new GameBoyAdvance(bios);

	gba.loadROM(rom);
	if (!noLoad && exists(save)) {
		gba.loadSave(save);
		writeln("Loaded save \"" ~ save ~ "\"");
	} else {
		gba.loadNewSave();
		writeln("Using new save");
	}

	gba.setDisplayScale(scale);
	gba.setDisplayUpscalingMode(upscaling);

	gba.run();

	if (!noSave) {
		gba.saveSave(save);
		writeln("Saved save \"" ~ save ~ "\"");
	}

	// TODO:
	//       fix DMA priorities
	//       fix PKMN missing stat change graphics
	//       update performance of getRegisterIndex and memory mapping
	//       figure out why PKMN says the save file is corrupt when it isn't
	//       investigate super mario advance glitches
	//       rewrite more of the graphics in x64
	//       finish implementing bitmap modes in graphics
	//       implement optional RTC
}
