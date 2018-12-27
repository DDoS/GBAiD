import core.thread : Thread;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.sync.barrier : Barrier;

import std.algorithm.searching : count;
import std.stdio : writeln, writefln;
import std.getopt: getopt, config;
import std.file : exists, read, FileException;
import std.path : extension, setExtension, stripExtension, baseName;
import std.conv : to;

import derelict.sdl2.sdl;

import gbaid.util;
import gbaid.gba;
import gbaid.input;
import gbaid.audio;
import gbaid.render.renderer;
import gbaid.comm;
import gbaid.save;

private enum string SAVE_EXTENSION = ".gsf";

public int main(string[] args) {
    // Parse comand line arguments
    string biosFile = null;
    bool noLoad = false;
    float scale = 2;
    bool fullScreen = false;
    FilteringMode filtering = FilteringMode.NONE;
    UpscalingMode upscaling = UpscalingMode.NONE;
    bool controller = false;
    bool rawAudio = false;
    uint multiplayer = 1;
    GbaConfig sharedConfig;
    getopt(args,
        config.caseSensitive,
        "bios|b", &biosFile,
        "save|s", &sharedConfig.saveFile,
        config.bundling,
        "noload|n", &noLoad,
        "nosave|N", &sharedConfig.noSave,
        config.noBundling,
        "scale|r", &scale,
        "fullscreen|R", &fullScreen,
        "filtering|f", &filtering,
        "upscaling|u", &upscaling,
        "save-memory", &sharedConfig.mainSaveConfig,
        "eeprom", &sharedConfig.eepromConfig,
        "rtc", &sharedConfig.rtcConfig,
        "controller|c", &controller,
        "raw-audio", &rawAudio,
        "multiplayer|m", &multiplayer
    );

    if (multiplayer < 1 || multiplayer > 4) {
        writeln("The multiplayer number must be between 1 and 4");
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

    auto gbaConfigs = new GbaConfig[multiplayer];
    foreach (uint index, ref config; gbaConfigs) {
        config = sharedConfig;

        // Resolve ROM
        config.romFile = args.getSafe!string(index + 1, null);
        if (config.romFile is null) {
            config.noSave = true;
            writeln("ROM file %s is missing; saving is disabled", index + 1);
        } else {
            config.romFile = config.romFile.expandPath();
            if (!config.romFile.exists()) {
                writefln("ROM file %s doesn't exist", config.romFile);
                return 1;
            }
        }

        // Resolve save
        if (config.romFile is null) {
            config.newSave = true;
        } else {
            if (config.saveFile is null) {
                config.saveFile = config.romFile.setExtension(SAVE_EXTENSION);
            } else {
                config.saveFile = config.saveFile.expandPath();
            }

            // Add multiplayer index to save file if it conflicts with another
            auto count = gbaConfigs.count!((GbaConfig config, string saveFile) => config.saveFile == saveFile)(config.saveFile);
            if (count > 1) {
                config.saveFile = config.saveFile.stripExtension() ~ count.to!string() ~ config.saveFile.extension();
            }

            if (noLoad) {
                config.newSave = true;
                writeln("Using new save \"", config.saveFile, "\"");
            } else {
                if (config.saveFile.exists()) {
                    config.newSave = false;
                    writeln("Found save \"", config.saveFile, "\"");
                } else {
                    config.newSave = true;
                    writeln("Save file \"", config.saveFile, "\" not found, using new save");
                }
            }
        }
    }

    // Load and initialize SDL
    if (!DerelictSDL2.isLoaded) {
        DerelictSDL2.load();
    }
    SDL_Init(0);

    // Create the renderer, audio and input
    auto totalWidth = multiplayer > 1 ? DISPLAY_WIDTH * 2 : DISPLAY_WIDTH;
    auto totalHeight = multiplayer > 2 ? DISPLAY_HEIGHT * 2 : DISPLAY_HEIGHT;
    auto renderer = new FrameRenderer(totalWidth, totalHeight);
    renderer.useVsync = true;
    renderer.fullScreen = fullScreen;
    renderer.setScale(scale);
    renderer.setFilteringMode(filtering);
    renderer.setUpscalingMode(upscaling);

    auto audio = new AudioQueue!2(SOUND_OUTPUT_FREQUENCY, !rawAudio);

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

    // Create the GBAs
    auto gbas = new GbaMultiplexer(audio, gbaConfigs, bios);
    scope (exit) {
        gbas.stop();
        gbas.join();
    }
    gbas.start();

    // Update the input then draw the next frame, waiting for it if needed
    bool previousQuickSave = false;
    uint activeGbaIndex = 0;
    while (gbas.running && !renderer.isCloseRequested()) {
        // Pass the keypad button state to the GBA
        keyboardInput.poll();
        auto keypadState = keyboardInput.keypadState;
        auto quickSave = keyboardInput.quickSave;
        if (auxiliaryInput !is null) {
            auxiliaryInput.poll();
            keypadState |= auxiliaryInput.keypadState;
            quickSave |= auxiliaryInput.quickSave;
        }
        gbas.setKeypadState(activeGbaIndex, keypadState);
        // Quick save if requested
        if (!previousQuickSave && quickSave) {
            if (sharedConfig.noSave) {
                writeln("Saving is disabled");
            } else {
                audio.pause();
                gbas.saveAllGamePaks();
                audio.resume();
            }
        }
        previousQuickSave = quickSave;
        // Switch active GBA using number inputs
        auto lastDigit = keyboardInput.lastDigit;
        if (lastDigit >= 1 && lastDigit <= multiplayer && activeGbaIndex != lastDigit - 1) {
            activeGbaIndex = lastDigit - 1;
            audio.pause();
            gbas.attachAudio(activeGbaIndex);
            audio.resume();
        }
        // Draw the next frame
        renderer.draw(gbas.nextFrame());
    }

    return 0;
}

private struct GbaConfig {
    private string romFile = null, saveFile = null;
    private bool noSave = false, newSave = false;
    private MainSaveConfig mainSaveConfig = MainSaveConfig.AUTO;
    private EepromConfig eepromConfig = EepromConfig.AUTO;
    private RtcConfig rtcConfig = RtcConfig.AUTO;
}

private class GbaMultiplexer : Thread {
    private AudioQueue!2 audio;
    private GbaInstance[] gbaThreads;
    private short[] combinedFrames;
    private bool _running = true;

    public this(AudioQueue!2 audio, GbaConfig[] gbaConfigs, void[] bios) {
        super(&run);
        this.audio = audio;

        gbaThreads.length = gbaConfigs.length;
        auto serialData = gbaThreads.length > 1 ? new SharedSerialData() : null;
        foreach (uint index, ref thread; gbaThreads) {
            thread = new GbaInstance(index, gbaConfigs[index], bios);
            thread.shareSerialData(serialData);
        }

        attachAudio(0);

        if (gbaThreads.length == 2) {
            combinedFrames.length = (DISPLAY_WIDTH * DISPLAY_HEIGHT) * 2;
        } else if (gbaThreads.length > 2) {
            combinedFrames.length = (DISPLAY_WIDTH * DISPLAY_HEIGHT) * 4;
        }
    }

    public void stop() {
        _running = false;
    }

    public @property bool running() {
        return _running;
    }

    public void setKeypadState(uint index, KeypadState state) {
        gbaThreads[index].setKeypadState(state);
    }

    public void attachAudio(uint index) {
        foreach (i, gba; gbaThreads) {
            gba.attachAudio(i == index ? &audio.queueAudio : null);
        }
    }

    public short[] nextFrame() {
        auto frameCount = gbaThreads.length;

        auto frame1 = gbaThreads[0].nextFrame();
        if (frameCount == 1) {
            return frame1;
        }

        auto frame2 = gbaThreads[1].currentFrame();
        auto frame3 = frameCount > 2 ? gbaThreads[2].currentFrame() : null;
        auto frame4 = frameCount > 3 ? gbaThreads[3].currentFrame() : null;
        foreach (y; 0 .. DISPLAY_HEIGHT) {
            auto line = y * DISPLAY_WIDTH;
            foreach (x; 0 .. DISPLAY_WIDTH) {
                combinedFrames[y * (DISPLAY_WIDTH * 2) + x] = frame1[line + x];
                combinedFrames[y * (DISPLAY_WIDTH * 2) + (x + DISPLAY_WIDTH)] = frame2[line + x];
                if (frame3) {
                    auto xOffset = frame4 ? 0 : DISPLAY_WIDTH / 2;
                    combinedFrames[(y + DISPLAY_HEIGHT) * (DISPLAY_WIDTH * 2) + (x + xOffset)] = frame3[line + x];
                }
                if (frame4) {
                    combinedFrames[(y + DISPLAY_HEIGHT) * (DISPLAY_WIDTH * 2) + (x + DISPLAY_WIDTH)] = frame4[line + x];
                }
            }
        }

        return combinedFrames;
    }

    public void saveAllGamePaks() {
        foreach (thread; gbaThreads) {
            thread.saveGamePak();
        }
    }

    private void run() {
        scope (exit) {
            _running = false;
            foreach (thread; gbaThreads) {
                thread.saveGamePak();
            }
        }

        audio.resume();

        while (_running) {
            auto requiredSamples = audio.nextRequiredSamples();
            auto equivalentCycles = requiredSamples * CYCLES_PER_AUDIO_SAMPLE;

            enum batch = TIMING_WIDTH * CYCLES_PER_DOT;
            for (size_t c = 0; c < equivalentCycles; c += batch) {
                foreach (thread; gbaThreads) {
                    thread.receiveCycles(batch);
                }
            }
            foreach (thread; gbaThreads) {
                thread.receiveCycles(equivalentCycles % batch);
            }
        }
    }
}

private class GbaInstance {
    private GbaConfig config;
    private void[] bios;
    private uint index;
    private GameBoyAdvance gba;
    private bool _running = true;

    public this(uint index, GbaConfig config, void[] bios) {
        this.config = config;
        this.bios = bios;
        this.index = index;

        GamePakData gamePakData = void;
        if (config.newSave) {
            gamePakData = gamePakForNewRom(config.romFile, config.mainSaveConfig, config.eepromConfig, config.rtcConfig);
        } else {
            gamePakData = gamePakForExistingRom(config.romFile, config.saveFile, config.eepromConfig, config.rtcConfig);
        }
        gba = new GameBoyAdvance(bios, gamePakData, index);
    }

    public void stop() {
        _running = false;
    }

    public void receiveCycles(size_t cycles) {
        gba.emulate(cycles);
    }

    public void shareSerialData(SharedSerialData data) {
        if (data) {
            gba.serialCommunication = new MappedMemoryCommunication(index, data);
        }
    }

    public void setKeypadState(KeypadState state) {
        gba.setKeypadState(state);
    }

    public short[] nextFrame() {
        return gba.frameSwapper.nextFrame();
    }

    public short[] currentFrame() {
        return gba.frameSwapper.currentFrame();
    }

    public void attachAudio(AudioReceiver audioReceiver) {
        gba.audioReceiver = audioReceiver;
    }

    public void saveGamePak() {
        // Save Game Pak save
        if (config.noSave) {
            writeln("Saving is disabled");
        } else {
            gba.gamePakSaveData.saveGamePak(config.saveFile);
            writeln("Saved \"", config.saveFile, "\"");
        }
    }
}
