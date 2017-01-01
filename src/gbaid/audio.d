module gbaid.audio;

import std.algorithm.comparison : min;

import derelict.sdl2.sdl;

import gbaid.util;

public class Audio {
    private enum uint SAMPLE_BUFFER_LENGTH = 2048;
    private SDL_AudioDeviceID device = 0;
    private short[SAMPLE_BUFFER_LENGTH] samples;
    private size_t index = 0;

    public void create() {
        if (device != 0) {
            return;
        }

        if (!SDL_WasInit(SDL_INIT_AUDIO)) {
            if (SDL_InitSubSystem(SDL_INIT_AUDIO) < 0) {
                throw new Exception("Failed to initialize SDL audio sytem: " ~ toDString(SDL_GetError()));
            }
        }

        SDL_AudioSpec spec;
        spec.freq = 2 ^^ 16;
        spec.format = AUDIO_S16;
        spec.channels = 1;
        spec.samples = SAMPLE_BUFFER_LENGTH;
        spec.callback = &callback;
        spec.userdata = samples.ptr;
        device = SDL_OpenAudioDevice(null, 0, &spec, null, 0);
        if (!device) {
            throw new Exception("Failed to open audio device: " ~ toDString(SDL_GetError()));
        }
        play();
    }

    private static extern(C) void callback(void* samples, ubyte* stream, int length) nothrow {
        stream[0 .. length] = (cast(ubyte*) samples)[0 .. length];
    }

    public void destroy() {
        if (device == 0) {
            return;
        }
        SDL_CloseAudioDevice(device);
    }

    public void play() {
        SDL_PauseAudioDevice(device, false);
    }

    public void pause() {
        SDL_PauseAudioDevice(device, true);
    }

    public void queueAudio(short[] newSamples) {
        auto newIndex = index + newSamples.length;
        auto maxIndex = samples.length;
        auto endIndex = min(newIndex, maxIndex);
        samples[index .. endIndex] = newSamples[];
        index = endIndex >= maxIndex ? 0 : endIndex;
    }
}
