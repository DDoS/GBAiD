module gbaid.audio;

import core.sync.mutex : Mutex;

import std.algorithm.comparison : min;

import derelict.sdl2.sdl;

import gbaid.util;

private enum uint DEVICE_SAMPLES = 2048;
private enum size_t SAMPLE_BUFFER_LENGTH = DEVICE_SAMPLES * 8;

public class Audio {
    private SDL_AudioDeviceID device = 0;
    private short[SAMPLE_BUFFER_LENGTH] samples;
    private size_t sampleIndex = 0;
    private size_t sampleCount = 0;
    private Mutex sampleLock;

    public this() {
        sampleLock = new Mutex();
    }

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
        spec.samples = DEVICE_SAMPLES;
        spec.callback = &callback;
        spec.userdata = cast(void*) this;
        device = SDL_OpenAudioDevice(null, 0, &spec, null, 0);
        if (!device) {
            throw new Exception("Failed to open audio device: " ~ toDString(SDL_GetError()));
        }
        SDL_PauseAudioDevice(device, false);
    }

    public void destroy() {
        if (device == 0) {
            return;
        }
        SDL_CloseAudioDevice(device);
    }

    @property public size_t requiredSamples() {
        return SAMPLE_BUFFER_LENGTH - sampleCount;
    }

    public void queueAudio(short[] newSamples) {
        synchronized (sampleLock) {
            // Limit the length to copy to the free space
            auto length = min(SAMPLE_BUFFER_LENGTH - sampleCount, newSamples.length);
            if (length <= 0) {
                return;
            }
            // Copy the first part to the circular buffer
            auto start = (sampleIndex + sampleCount) % SAMPLE_BUFFER_LENGTH;
            auto end = min(start + length, SAMPLE_BUFFER_LENGTH);
            auto copyLength = end - start;
            samples[start .. end] = newSamples[0 .. copyLength];
            // Copy the wrapped around part
            start = 0;
            end = length - copyLength;
            samples[start .. end] = newSamples[copyLength .. length];
            // Increment the sample count by the copied length
            sampleCount += length;
        }
    }
}

private extern(C) void callback(void* instance, ubyte* stream, int length) nothrow {
    auto audio = cast(Audio) instance;
    auto sampleBytes = cast(ubyte*) audio.samples.ptr;
    try {
        synchronized (audio.sampleLock) {
            // Limit the length to copy to the available samples
            length = min(length, audio.sampleCount * short.sizeof);
            if (length <= 0) {
                return;
            }
            // Copy the first part of the circular buffer
            auto start = audio.sampleIndex * short.sizeof;
            auto end = min(start + length, SAMPLE_BUFFER_LENGTH * short.sizeof);
            auto copyLength = end - start;
            stream[0 .. copyLength] = sampleBytes[start .. end];
            // Copy the wrapped around part
            start = 0;
            end = length - copyLength;
            stream[copyLength .. length] = sampleBytes[start .. end];
            // Decrement the sample count by the copied length
            audio.sampleCount -= length / short.sizeof;
            // Increment the index past what as consumed, with wrapping
            audio.sampleIndex = (audio.sampleIndex + length / short.sizeof) % SAMPLE_BUFFER_LENGTH;
        }
    } catch (Throwable throwable) {
        import core.stdc.stdio : printf;
        import std.string : toStringz;
        printf("Error in audio callback: %s\n", throwable.msg.toStringz());
    }
}
