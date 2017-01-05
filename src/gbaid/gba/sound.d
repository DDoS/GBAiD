module gbaid.gba.sound;

import gbaid.gba.memory;

import gbaid.util;

public alias AudioReceiver = void delegate(short[]);

private enum uint SYSTEM_CLOCK_FREQUENCY = 2 ^^ 24;
private enum uint OUTPUT_FREQUENCY = 2 ^^ 16;
public enum size_t CYCLES_PER_AUDIO_SAMPLE = SYSTEM_CLOCK_FREQUENCY / OUTPUT_FREQUENCY;

public class SoundChip {
    private enum uint SAMPLE_BATCH_SIZE = 256;
    private IoRegisters* ioRegisters;
    private AudioReceiver _receiver = null;
    mixin privateFields!(SquareWaveGenerator, "tone", SquareWaveGenerator.init, 2);
    private short[SAMPLE_BATCH_SIZE] sampleBatch;
    private uint sampleBatchIndex = 0;

    public this(IoRegisters* ioRegisters) {
        this.ioRegisters = ioRegisters;

        ioRegisters.setPostWriteMonitor!0x60(&onToneLowPostWrite!0);
        ioRegisters.setPostWriteMonitor!0x64(&onToneHighPostWrite!0);
        ioRegisters.setPostWriteMonitor!0x68(&onToneLowPostWrite!1);
        ioRegisters.setPostWriteMonitor!0x6C(&onToneHighPostWrite!1);
    }

    @property public void receiver(AudioReceiver receiver) {
        _receiver = receiver;
    }

    public size_t emulate(size_t cycles) {
        if (_receiver is null) {
            return 0;
        }

        while (cycles >= CYCLES_PER_AUDIO_SAMPLE) {
            cycles -= CYCLES_PER_AUDIO_SAMPLE;

            short sample = cast(short) ((tone!0.nextSample() + tone!1.nextSample()) * 128);

            sampleBatch[sampleBatchIndex++] = sample;
            if (sampleBatchIndex >= SAMPLE_BATCH_SIZE) {
                _receiver(sampleBatch);
                sampleBatchIndex = 0;
            }
        }

        return cycles;
    }

    private void onToneLowPostWrite(int channel)
            (IoRegisters* ioRegisters, int address, int shift, int mask, int oldSettings, int newSettings) {
        static if (channel == 1) {
            newSettings <<= 16;
        }
        tone!channel.duration = newSettings.getBits(16, 21);
        tone!channel.duty = newSettings.getBits(22, 23);
        tone!channel.envelopeStep = newSettings.getBits(24, 26);
        tone!channel.increasingEnvelope = newSettings.checkBit(27);
        tone!channel.initialVolume = newSettings.getBits(28, 31);
    }

    private void onToneHighPostWrite(int channel)
            (IoRegisters* ioRegisters, int address, int shift, int mask, int oldSettings, int newSettings) {
        tone!channel.frequency = newSettings & 0x7FF;
        tone!channel.useDuration = newSettings.checkBit(14);
        if (newSettings.checkBit(15)) {
            tone!channel.restart();
        }
    }
}

private struct SquareWaveGenerator {
    private size_t _period = 0;
    private size_t _duty = 512;
    private size_t _envelopeStep = 0;
    private bool increasingEnvelope = false;
    private size_t initialVolume = 0;
    private size_t _duration = 0;
    private bool useDuration = false;
    private size_t t = 0;
    private size_t envelope = 0;

    @property private void frequency(int frequency) {
        // Convert the rate to period of the output
        _period = (2048 - frequency) / 2;
    }

    @property private void duty(int duty) {
        // Convert the setting to fixed point at 1024
        final switch (duty) {
            case 0:
                _duty = 128;
                break;
            case 1:
                _duty = 256;
                break;
            case 2:
                _duty = 512;
                break;
            case 3:
                _duty = 768;
                break;
        }
    }

    @property private void envelopeStep(int step) {
        // Convert the setting to the step as the number of samples
        _envelopeStep = step * (SYSTEM_CLOCK_FREQUENCY / 64) / CYCLES_PER_AUDIO_SAMPLE;
    }

    @property private void duration(int duration) {
        // Convert the setting to the duration as the number of samples
        _duration = (64 - duration) * (SYSTEM_CLOCK_FREQUENCY / 256) / CYCLES_PER_AUDIO_SAMPLE;
    }

    private void restart() {
        t = 0;
        envelope = initialVolume;
    }

    private short nextSample() {
        // Check if the sound expired
        if (useDuration && t >= _duration) {
            return 0;
        }
        // If the period is 0, then the frequency is above the output frequency, so ignore it
        if (_period <= 0) {
            return 0;
        }
        // Generate the sample
        auto amplitude = cast(short) (envelope * 8);
        auto sample = ((t % _period) * 1024) / _period >= _duty ? -amplitude : amplitude;
        // Increment the time value
        t += 1;
        // Update the envelope if enabled
        if (_envelopeStep > 0 && t % _envelopeStep == 0) {
            if (increasingEnvelope) {
                if (envelope < 15) {
                    envelope += 1;
                }
            } else {
                if (envelope > 0) {
                    envelope -= 1;
                }
            }
        }
        return sample;
    }
}
