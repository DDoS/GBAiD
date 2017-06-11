module gbaid.audio;

import core.sync.mutex : Mutex;
import core.sync.condition : Condition;

import std.meta : aliasSeqOf;
import std.range : iota;
import std.algorithm.comparison : min;

import derelict.sdl2.sdl;

import gbaid.util;

public class AudioQueue(uint channelCount) {
    private enum uint DEVICE_SAMPLES = 1024 * channelCount;
    private enum size_t SAMPLE_BUFFER_LENGTH = DEVICE_SAMPLES * 4;
    private SDL_AudioDeviceID device = 0;
    private short[SAMPLE_BUFFER_LENGTH] samples;
    private size_t sampleIndex = 0;
    private size_t sampleCount = 0;
    mixin declareFields!(LowPassFilter, true, "filter", LowPassFilter.init, channelCount);
    private uint frequency;
    private Condition sampleSignal;

    public this(uint frequency) {
        this.frequency = frequency;
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
        spec.freq = frequency;
        spec.format = AUDIO_S16;
        spec.channels = channelCount;
        spec.samples = DEVICE_SAMPLES;
        spec.callback = &callback!channelCount;
        spec.userdata = cast(void*) this;
        device = SDL_OpenAudioDevice(null, 0, &spec, null, 0);
        if (!device) {
            throw new Exception("Failed to open audio device: " ~ toDString(SDL_GetError()));
        }
    }

    public void destroy() {
        if (device == 0) {
            return;
        }
        SDL_CloseAudioDevice(device);
    }

    public void pause() {
        SDL_PauseAudioDevice(device, true);
    }

    public void resume() {
        SDL_PauseAudioDevice(device, false);
    }

    public void queueAudio(short[] newSamples) {
        if (newSamples.length <= 0) {
            return;
        }
        synchronized (sampleSignal.mutex) {
            // Limit the length to copy to the free space
            auto length = min(SAMPLE_BUFFER_LENGTH - sampleCount, newSamples.length);
            if (length <= 0) {
                return;
            }
            // Filter the samples
            for (size_t i = 0; i < length; i += channelCount) {
                // Each channel has its own filter
                foreach (j; aliasSeqOf!(iota(0, channelCount))) {
                    newSamples[i + j] = filter!j.next(newSamples[i + j]);
                 }
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

    public size_t nextRequiredSamples() {
        synchronized (sampleSignal.mutex) {
            size_t requiredSamples = void;
            while ((requiredSamples = SAMPLE_BUFFER_LENGTH - sampleCount) <= 0) {
                sampleSignal.wait();
            }
            return requiredSamples / channelCount;
        }
    }
}

private struct LowPassFilter {
    private static enum GAIN = 2.131619135e2f;
    private float x0 = 0, x1 = 0, x2 = 0, x3 = 0, x4 = 0;
    private float y0 = 0, y1 = 0, y2 = 0, y3 = 0, y4 = 0;

    private short next(short sample) {
        // Low-pass fourth-order Butterworth filter with a 6.5kHz cutoff
        // Generated with: http://www-users.cs.york.ac.uk/~fisher/mkfilter/trad.html
        x0 = x1; x1 = x2; x2 = x3; x3 = x4;
        x4 = sample / GAIN;
        y0 = y1; y1 = y2; y2 = y3; y3 = y4;
        y4 = x0 + x4 + 4 * (x1 + x3) + 6 * x2 - 0.1900667337f * y0 + 1.0673121590f * y1
                - 2.3349929845f * y2 + 2.3826872459f * y3;
        return cast(short) (y4 + 0.5f);
    }
}

private extern(C) void callback(uint channelCount)(void* instance, ubyte* stream, int length) nothrow {
    alias Audio = AudioQueue!channelCount;
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
            auto end = min(start + length, Audio.SAMPLE_BUFFER_LENGTH * short.sizeof);
            auto copyLength = end - start;
            stream[0 .. copyLength] = sampleBytes[start .. end];
            // Copy the wrapped around part
            start = 0;
            end = length - copyLength;
            stream[copyLength .. length] = sampleBytes[start .. end];
            // Increment the index past what as consumed, with wrapping
            audio.sampleIndex = (audio.sampleIndex + length / short.sizeof) % Audio.SAMPLE_BUFFER_LENGTH;
            // Decrement the sample count by the copied length
            audio.sampleCount -= length / short.sizeof;
            // If the sample count is half of the buffer length, request more
            if (audio.sampleCount <= Audio.SAMPLE_BUFFER_LENGTH / 2) {
                audio.sampleSignal.notify();
            }
        }
    } catch (Throwable throwable) {
        import core.stdc.stdio : printf;
        import std.string : toStringz;
        printf("Error in audio callback: %s\n", throwable.msg.toStringz());
    }
}
