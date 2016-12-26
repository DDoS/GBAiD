import core.thread : Thread;
import core.sync.barrier : Barrier;

import std.stdio;
import std.getopt;
import std.string;
import std.file;
import std.path;

import derelict.sdl2.sdl;

import gbaid.system;
import gbaid.memory;
import gbaid.display;
import gbaid.keypad;
import gbaid.input;
import gbaid.graphics;
import gbaid.util;

private enum string SAVE_EXTENSION = ".gsf";

public void main(string[] args) {
    // Parse comand line arguments
    string bios = null, save = null;
    bool noLoad = false, noSave = false;
    float scale = 2;
    FilteringMode filtering = FilteringMode.NONE;
    UpscalingMode upscaling = UpscalingMode.NONE;
    SaveConfiguration memory = SaveConfiguration.AUTO;
    bool controller = false;
    getopt(args,
        config.caseSensitive,
        "bios|b", &bios,
        "save|s", &save,
        config.bundling,
        "noload|n", &noLoad,
        "nosave|N", &noSave,
        config.noBundling,
        "scale|r", &scale,
        "filtering|f", &filtering,
        "upscaling|u", &upscaling,
        "controller|c", &controller,
        "memory|m", &memory
    );

    // Resolve BIOS
    if (bios is null) {
        writeln("Missing BIOS file path, sepcify with \"-b (path to bios)\"");
        return;
    }
    bios = expandPath(bios);
    if (!exists(bios)) {
        writeln("BIOS file doesn't exist");
        return;
    }

    // Resolve ROM
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

    // Resolve save
    if (noLoad) {
        save = null;
        writeln("Using new save");
    } else {
        if (save is null) {
            save = setExtension(rom, SAVE_EXTENSION);
            writeln("Save path not specified, using default \"", save, "\"");
        } else {
            save = expandPath(save);
        }
        if (exists(save)) {
            writeln("Using save \"", save, "\"");
        } else {
            save = null;
            writeln("Save file not found, using new save");
            // TODO: save under the given name
        }
    }

    // Create and configure GBA
    GameBoyAdvance gba = void;
    if (save is null) {
        gba = new GameBoyAdvance(bios, rom, memory);
    } else {
        gba = new GameBoyAdvance(bios, rom, save);
    }

    // Load and initialize SDL
    if (!DerelictSDL2.isLoaded) {
        DerelictSDL2.load();
    }
    SDL_Init(0);

    // Create the graphics and input
    auto graphics = new Graphics(Display.HORIZONTAL_RESOLUTION, Display.VERTICAL_RESOLUTION);
    graphics.setScale(scale);
    graphics.setFilteringMode(filtering);
    graphics.setUpscalingMode(upscaling);

    auto input = cast(InputSource) (controller ? new Controller() : new Keyboard());

    graphics.create();
    input.create();
    scope (exit) {
        input.destroy();
        graphics.destroy();
        SDL_Quit();
    }

    // Synchronization for the worker and main thread
    auto frameBarrier = new Barrier(2);

    // Declare a function for the GBA thread worker
    auto gbaRunning = true;
    void gbaRun() {
        while (gbaRunning) {
            gba.emulate();
            frameBarrier.wait();
        }
    }

    // Start the GBA worker
    auto gbaThread = new Thread(&gbaRun);
    gbaThread.name = "GBA";
    gbaThread.start();

    // Every frame interval, signal the worker to emulate a frame, then draw it
    auto timer = new Timer();
    short[Display.FRAME_SIZE] frame;
    while (!graphics.isCloseRequested()) {
        timer.start();
        // Pass the keypad button state to the GBA
        gba.setKeypadState(input.pollKeypad());
        // Display the frame once drawn
        frameBarrier.wait();
        gba.getFrame(frame);
        graphics.draw(frame);
        // Wait for the actual duration of a frame
        timer.waitUntil(GameBoyAdvance.FRAME_DURATION);
    }

    // Shutdown the worker
    gbaRunning = false;
    frameBarrier.wait();
    gbaThread.join();

    // Save Game Pak save
    if (!noSave) {
        if (save is null) {
            save = setExtension(rom, SAVE_EXTENSION);
        }
        gba.saveSave(save);
        writeln("Saved save \"", save, "\"");
    }

    // TODO:
    //       possible bug in pokemon emerald at 00000364
    //       sound
    //       implement optional RTC
}
