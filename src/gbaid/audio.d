module gbaid.audio;

import core.sync.mutex : Mutex;
import core.sync.condition : Condition;

import std.algorithm.comparison : min;

import derelict.sdl2.sdl;

import gbaid.util;

private enum uint DEVICE_SAMPLES = 1024;
private enum size_t SAMPLE_BUFFER_LENGTH = DEVICE_SAMPLES * 4;

public class Audio {
    private SDL_AudioDeviceID device = 0;
    private short[SAMPLE_BUFFER_LENGTH] samples;
    private size_t sampleIndex = 0;
    private size_t sampleCount = 0;
    private Condition sampleSignal;

    public this() {
        sampleSignal = new Condition(new Mutex());
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

    public void queueAudio(short[] newSamples) {
        synchronized (sampleSignal.mutex) {
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

    public size_t requiredSamples() {
        synchronized (sampleSignal.mutex) {
            size_t requiredSamples = void;
            while ((requiredSamples = SAMPLE_BUFFER_LENGTH - sampleCount) <= 0) {
                sampleSignal.wait();
            }
            return requiredSamples;
        }
    }
}

private extern(C) void callback(void* instance, ubyte* stream, int length) nothrow {
    auto audio = cast(Audio) instance;
    auto sampleBytes = cast(ubyte*) audio.samples.ptr;
    try {
        synchronized (audio.sampleSignal.mutex) {
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
            // Increment the index past what as consumed, with wrapping
            audio.sampleIndex = (audio.sampleIndex + length / short.sizeof) % SAMPLE_BUFFER_LENGTH;
            // Decrement the sample count by the copied length
            audio.sampleCount -= length / short.sizeof;
            // If the sample count is half of the buffer length, request more
            if (audio.sampleCount <= SAMPLE_BUFFER_LENGTH / 2) {
                audio.sampleSignal.notify();
            }
        }
    } catch (Throwable throwable) {
        import core.stdc.stdio : printf;
        import std.string : toStringz;
        printf("Error in audio callback: %s\n", throwable.msg.toStringz());
    }
}
