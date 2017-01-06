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
    private SquareWaveGenerator!true tone1;
    private SquareWaveGenerator!false tone2;
    private short[SAMPLE_BATCH_SIZE] sampleBatch;
    private uint sampleBatchIndex = 0;

    public this(IoRegisters* ioRegisters) {
        this.ioRegisters = ioRegisters;

        ioRegisters.setPostWriteMonitor!0x60(&onToneLowPostWrite!1);
        ioRegisters.setPostWriteMonitor!0x64(&onToneHighPostWrite!1);
        ioRegisters.setPostWriteMonitor!0x68(&onToneLowPostWrite!2);
        ioRegisters.setPostWriteMonitor!0x6C(&onToneHighPostWrite!2);
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

            short sample = cast(short) ((tone1.nextSample() + tone2.nextSample()) * 128);

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
            alias tone = tone1;
            tone.sweepShift = newSettings & 0b111;
            tone.decreasingShift = newSettings.checkBit(3);
            tone.sweepStep = newSettings.getBits(4, 6);
        } else {
            alias tone = tone2;
            newSettings <<= 16;
        }
        tone.duration = newSettings.getBits(16, 21);
        tone.duty = newSettings.getBits(22, 23);
        tone.envelopeStep = newSettings.getBits(24, 26);
        tone.increasingEnvelope = newSettings.checkBit(27);
        tone.initialVolume = newSettings.getBits(28, 31);
    }

    private void onToneHighPostWrite(int channel)
            (IoRegisters* ioRegisters, int address, int shift, int mask, int oldSettings, int newSettings) {
        static if (channel == 1) {
            alias tone = tone1;
        } else {
            alias tone = tone2;
        }
        tone.rate = newSettings & 0x7FF;
        tone.useDuration = newSettings.checkBit(14);
        if (newSettings.checkBit(15)) {
            tone.restart();
        }
    }
}

private struct SquareWaveGenerator(bool sweep) {
    private int rate = 0;
    private size_t _duty = 512;
    private size_t _envelopeStep = 0;
    private bool increasingEnvelope = false;
    private int initialVolume = 0;
    static if (sweep) {
        private int sweepShift = 0;
        private bool decreasingShift = false;
        private size_t _sweepStep = 0;
    }
    private size_t _duration = 0;
    private bool useDuration = false;
    private size_t tWave = 0;
    private size_t tStart = 0;
    private int envelope = 0;

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

    static if (sweep) {
        @property private void sweepStep(int step) {
            _sweepStep = step * (SYSTEM_CLOCK_FREQUENCY / 128) / CYCLES_PER_AUDIO_SAMPLE;
        }
    }

    @property private void duration(int duration) {
        // Convert the setting to the duration as the number of samples
        _duration = (64 - duration) * (SYSTEM_CLOCK_FREQUENCY / 256) / CYCLES_PER_AUDIO_SAMPLE;
    }

    private void restart() {
        tStart = tWave;
        envelope = initialVolume;
    }

    private short nextSample() {
        auto tElapsed = tWave - tStart;
        // Don't play if the duration expired
        // If the rate is above the output frequency then ignore it
        enum frequencyReductionRatio = 2 ^^ 17 / OUTPUT_FREQUENCY;
        if (useDuration && tElapsed >= _duration || rate >= 2048 - frequencyReductionRatio) {
            tWave += 1;
            return 0;
        }
        // Generate the sample
        auto period = (2048 - rate) / frequencyReductionRatio;
        auto amplitude = cast(short) (envelope * 8);
        auto sample = ((tWave % period) * 1024) / period >= _duty ? -amplitude : amplitude;
        // Increment the time value
        tWave += 1;
        // Update the envelope if enabled
        if (_envelopeStep > 0 && tElapsed % _envelopeStep == 0) {
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
        // Update the frequency sweep if enabled
        static if (sweep) {
            if (_sweepStep > 0 && tElapsed % _sweepStep == 0) {
                if (decreasingShift) {
                    rate -= rate >> sweepShift;
                } else {
                    rate += rate >> sweepShift;
                }
                if (rate < 0) {
                    rate = 0;
                } else if (rate >= 2048) {
                    rate = 2047;
                }
            }
        }
        return sample;
    }
}
