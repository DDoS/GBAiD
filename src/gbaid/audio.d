module gbaid.audio;

import derelict.sdl2.sdl;

import gbaid.util;

public class Audio {
    private SDL_AudioDeviceID device = 0;

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
        spec.samples = 8192;
        device = SDL_OpenAudioDevice(null, 0, &spec, null, 0);
        if (!device) {
            throw new Exception("Failed to open audio device: " ~ toDString(SDL_GetError()));
        }
        play();
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

    public void queueAudio(short[] stereoSamples) {
        SDL_QueueAudio(device, stereoSamples.ptr, cast(uint) (stereoSamples.length * short.sizeof));
    }
}
