import core.thread : Thread;
import core.sync.mutex : Mutex;

import std.stdio : writeln;
import std.getopt: getopt, config;
import std.file : read, FileException;
import std.path : exists, setExtension;
import std.process : spawnProcess;

import derelict.sdl2.sdl;

import gbaid.util;
import gbaid.gba;
import gbaid.input;
import gbaid.audio;
import gbaid.comm;
import gbaid.render.renderer;
import gbaid.save;

private enum string SAVE_EXTENSION = ".gsf";

public int main(string[] args) {
    // Parse comand line arguments
    string biosFile = null, saveFile = null;
    bool noLoad = false, noSave = false;
    float scale = 2;
    bool fullScreen = false;
    FilteringMode filtering = FilteringMode.NONE;
    UpscalingMode upscaling = UpscalingMode.NONE;
    MainSaveConfig mainSaveConfig = MainSaveConfig.AUTO;
    EepromConfig eepromConfig = EepromConfig.AUTO;
    RtcConfig rtcConfig = RtcConfig.AUTO;
    bool controller = false;
    bool rawAudio = false;
    uint serialIndex = 0;
    getopt(args,
        config.caseSensitive,
        "bios|b", &biosFile,
        "save|s", &saveFile,
        config.bundling,
        "noload|n", &noLoad,
        "nosave|N", &noSave,
        config.noBundling,
        "scale|r", &scale,
        "fullscreen|R", &fullScreen,
        "filtering|f", &filtering,
        "upscaling|u", &upscaling,
        "save-memory", &mainSaveConfig,
        "eeprom", &eepromConfig,
        "rtc", &rtcConfig,
        "controller|c", &controller,
        "raw-audio", &rawAudio,
        "serial-index", &serialIndex
    );

    if (serialIndex >= 4) {
        writeln("Serial communication index must be between 0 and 3");
        return 1;
    }

    // Resolve BIOS
    if (biosFile is null) {
        writeln("Missing BIOS file path, sepcify with \"-b (path to bios)\"");
        return 1;
    }
    biosFile = expandPath(biosFile);
    if (!exists(biosFile)) {
        writeln("BIOS file doesn't exist");
        return 1;
    }

    // Load the BIOS
    void[] bios = void;
    try {
        bios = biosFile.read();
    } catch (FileException exception) {
        writeln("Could not read the BIOS file: ", exception.msg);
        return 1;
    }

    // Resolve ROM
    auto romFile = args.getSafe!string(1, null);
    if (romFile is null) {
        noSave = true;
        writeln("ROM file is missing; saving is disabled");
    } else {
        romFile = expandPath(romFile);
        if (!exists(romFile)) {
            writeln("ROM file doesn't exist");
            return 1;
        }
    }

    // Resolve save
    bool newSave = void;
    if (romFile is null) {
        newSave = true;
    } else {
        if (saveFile is null) {
            saveFile = setExtension(romFile, SAVE_EXTENSION);
            writeln("Save path not specified, using default \"", saveFile, "\"");
        } else {
            saveFile = expandPath(saveFile);
        }
        if (noLoad) {
            newSave = true;
            writeln("Using new save");
        } else {
            if (exists(saveFile)) {
                newSave = false;
                writeln("Found save \"", saveFile, "\"");
            } else {
                newSave = true;
                writeln("Save file not found, using new save");
            }
        }
    }

    // Create and configure GBA
    GamePakData gamePakData = void;
    if (newSave) {
        gamePakData = gamePakForNewRom(romFile, mainSaveConfig, eepromConfig, rtcConfig);
    } else {
        gamePakData = gamePakForExistingRom(romFile, saveFile, eepromConfig, rtcConfig);
    }
    auto gba = new GameBoyAdvance(bios, gamePakData);

    // Load and initialize SDL
    if (!DerelictSDL2.isLoaded) {
        DerelictSDL2.load();
    }
    SDL_Init(0);

    // Create the renderer, audio and input
    auto renderer = new FrameRenderer(DISPLAY_WIDTH, DISPLAY_HEIGHT);
    renderer.useVsync = true;
    renderer.fullScreen = fullScreen;
    renderer.setScale(scale);
    renderer.setFilteringMode(filtering);
    renderer.setUpscalingMode(upscaling);

    auto audio = new AudioQueue!2(SOUND_OUTPUT_FREQUENCY, !rawAudio);
    gba.audioReceiver = &audio.queueAudio;

    auto keyboardInput = new Keyboard();
    InputSource auxiliaryInput = null;
    if (controller) {
        auxiliaryInput = new Controller();
    }

    renderer.create();
    audio.create();
    keyboardInput.create();
    if (auxiliaryInput !is null) {
        auxiliaryInput.create();
    }
    scope (exit) {
        keyboardInput.destroy();
        if (auxiliaryInput !is null) {
            auxiliaryInput.destroy();
        }
        audio.destroy();
        renderer.destroy();
        SDL_Quit();
    }

    gba.serialCommunication = new MappedMemoryCommunication(serialIndex);
    gba.serialIndex = serialIndex;

    // Create a mutex for the main and GBA threads
    auto emulatorLock = new Mutex();

    // Declare a function for the GBA thread worker
    auto gbaRunning = true;
    void gbaRun() {
        while (gbaRunning) {
            scope (failure) {
                gbaRunning = false;
            }
            auto requiredSamples = audio.nextRequiredSamples();
            auto equivalentCycles = requiredSamples * CYCLES_PER_AUDIO_SAMPLE;
            synchronized (emulatorLock) {
                gba.emulate(equivalentCycles);
            }
        }
    }

    // Create the GBA worker
    auto gbaThread = new Thread(&gbaRun);
    gbaThread.name = "GBA";
    scope (failure) {
        gbaRunning = false;
    }

    // Start it
    gbaThread.start();
    audio.resume();

    // Update the input then draw the next frame, waiting for it if needed
    bool previousQuickSave = false;
    while (gbaRunning && !renderer.isCloseRequested()) {
        // Pass the keypad button state to the GBA
        keyboardInput.poll();
        auto keypadState = keyboardInput.keypadState;
        auto quickSave = keyboardInput.quickSave;
        if (auxiliaryInput !is null) {
            auxiliaryInput.poll();
            keypadState |= auxiliaryInput.keypadState;
            quickSave |= auxiliaryInput.quickSave;
        }
        gba.setKeypadState(keypadState);
        // Quick save if requested
        if (!previousQuickSave && quickSave) {
            if (noSave) {
                writeln("Saving is disabled");
            } else {
                audio.pause();
                synchronized (emulatorLock) {
                    gba.gamePakSaveData.saveGamePak(saveFile);
                }
                writeln("Quick saved \"", saveFile, "\"");
                audio.resume();
            }
        }
        previousQuickSave = quickSave;
        // Draw the lastest frame
        renderer.draw(gba.frameSwapper.nextFrame);
    }

    // Shutdown the worker
    gbaRunning = false;
    gbaThread.join();

    // Save Game Pak save
    if (noSave) {
        writeln("Saving is disabled");
    } else {
        gba.gamePakSaveData.saveGamePak(saveFile);
        writeln("Saved \"", saveFile, "\"");
    }

    return 0;
}
