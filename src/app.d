import core.thread : Thread;

import std.stdio;
import std.getopt;
import std.string;
import std.file;
import std.path;

import derelict.sdl2.sdl;

import gbaid.util;
import gbaid.gba;
import gbaid.input;
import gbaid.audio;
import gbaid.render.renderer;

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

    // Create the renderer, audio and input
    auto renderer = new FrameRenderer(DISPLAY_WIDTH, DISPLAY_HEIGHT);
    renderer.useVsync = true;
    renderer.setScale(scale);
    renderer.setFilteringMode(filtering);
    renderer.setUpscalingMode(upscaling);

    auto audio = new Audio();
    gba.setAudioReceiver(&audio.queueAudio, 128);

    auto input = cast(InputSource) (controller ? new Controller() : new Keyboard());

    renderer.create();
    audio.create();
    input.create();
    scope (exit) {
        input.destroy();
        audio.destroy();
        renderer.destroy();
        SDL_Quit();
    }

    // Declare a function for the GBA thread worker
    auto gbaRunning = true;
    void gbaRun() {
        auto timer = new Timer();
        while (gbaRunning) {
            timer.start();
            gba.emulate(CYCLES_PER_FRAME);
            timer.waitUntil(FRAME_DURATION);
        }
    }

    // Start the GBA worker
    auto gbaThread = new Thread(&gbaRun);
    gbaThread.name = "GBA";
    gbaThread.start();

    // Update the input then draw the next frame, waiting for it if needed
    while (!renderer.isCloseRequested()) {
        // Pass the keypad button state to the GBA
        gba.setKeypadState(input.pollKeypad());
        // Draw the lastest frame
        renderer.draw(gba.frameSwapper.nextFrame);
    }

    // Shutdown the worker
    gbaRunning = false;
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
    //       fix flash save memory
    //       possible bug in pokemon emerald at 00000364
    //       implement optional RTC
}
