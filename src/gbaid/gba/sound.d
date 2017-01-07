module gbaid.gba.sound;

import gbaid.gba.memory;

import gbaid.util;

public alias AudioReceiver = void delegate(short[]);

private enum uint SYSTEM_CLOCK_FREQUENCY = 2 ^^ 24;
private enum uint PSG_FREQUENCY = 2 ^^ 18;
private enum uint OUTPUT_FREQUENCY = 2 ^^ 16;
private enum size_t CYCLES_PER_PSG_SAMPLE = SYSTEM_CLOCK_FREQUENCY / PSG_FREQUENCY;
private enum size_t PSG_PER_AUDIO_SAMPLE = PSG_FREQUENCY / OUTPUT_FREQUENCY;
public enum size_t CYCLES_PER_AUDIO_SAMPLE = SYSTEM_CLOCK_FREQUENCY / OUTPUT_FREQUENCY;

public class SoundChip {
    private static enum uint SAMPLE_BATCH_SIZE = 256;
    private IoRegisters* ioRegisters;
    private AudioReceiver _receiver = null;
    private SquareWaveGenerator!true tone1;
    private SquareWaveGenerator!false tone2;
    private PatternWaveGenerator wave;
    private int psgReSample = 0;
    private uint psgCount = 0;
    private short[SAMPLE_BATCH_SIZE] sampleBatch;
    private uint sampleBatchIndex = 0;

    public this(IoRegisters* ioRegisters) {
        this.ioRegisters = ioRegisters;

        ioRegisters.setPostWriteMonitor!0x60(&onToneLowPostWrite!1);
        ioRegisters.setPostWriteMonitor!0x64(&onToneHighPostWrite!1);
        ioRegisters.setPostWriteMonitor!0x68(&onToneLowPostWrite!2);
        ioRegisters.setPostWriteMonitor!0x6C(&onToneHighPostWrite!2);
        ioRegisters.setPostWriteMonitor!0x70(&onWaveLowPostWrite);
        ioRegisters.setPostWriteMonitor!0x74(&onWaveHighPostWrite);
        ioRegisters.setPostWriteMonitor!0x90(&onWavePatternPostWrite!0);
        ioRegisters.setPostWriteMonitor!0x94(&onWavePatternPostWrite!1);
        ioRegisters.setPostWriteMonitor!0x98(&onWavePatternPostWrite!2);
        ioRegisters.setPostWriteMonitor!0x9C(&onWavePatternPostWrite!3);
    }

    @property public void receiver(AudioReceiver receiver) {
        _receiver = receiver;
    }

    public size_t emulate(size_t cycles) {
        if (_receiver is null) {
            return 0;
        }

        while (cycles >= CYCLES_PER_PSG_SAMPLE) {
            cycles -= CYCLES_PER_PSG_SAMPLE;

            psgReSample += (tone1.nextSample() + tone2.nextSample() + wave.nextSample()) * 128;
            psgCount += 1;

            if (psgCount == PSG_PER_AUDIO_SAMPLE) {
                sampleBatch[sampleBatchIndex++] = cast(short) (psgReSample / cast(int) PSG_PER_AUDIO_SAMPLE);
                if (sampleBatchIndex >= SAMPLE_BATCH_SIZE) {
                    _receiver(sampleBatch);
                    sampleBatchIndex = 0;
                }
                psgCount = 0;
                psgReSample = 0;
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

    private void onWaveLowPostWrite(IoRegisters* ioRegisters, int address, int shift, int mask, int oldSettings,
            int newSettings) {
        wave.combineBanks = newSettings.checkBit(5);
        wave.selectedBank = newSettings.getBit(6);
        wave.enabled = newSettings.checkBit(7);
        wave.duration = newSettings.getBits(16, 23);
        wave.volume = newSettings.getBits(29, 31);
    }

    private void onWaveHighPostWrite(IoRegisters* ioRegisters, int address, int shift, int mask, int oldSettings,
            int newSettings) {
        wave.rate = newSettings & 0x7FF;
        wave.useDuration = newSettings.checkBit(14);
        if (newSettings.checkBit(15)) {
            wave.restart();
        }
    }

    private void onWavePatternPostWrite(int index)
            (IoRegisters* ioRegisters, int address, int shift, int mask, int oldPattern, int newPattern) {
        wave.pattern!index = newPattern;
    }
}

private struct SquareWaveGenerator(bool sweep) {
    private bool enabled = false;
    private int rate = 0;
    private size_t _duty = 125;
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
    private size_t tDuration = 0;
    private size_t tPeriod = 0;
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
        _envelopeStep = step * (SYSTEM_CLOCK_FREQUENCY / 64) / CYCLES_PER_PSG_SAMPLE;
    }

    static if (sweep) {
        @property private void sweepStep(int step) {
            _sweepStep = step * (SYSTEM_CLOCK_FREQUENCY / 128) / CYCLES_PER_PSG_SAMPLE;
        }
    }

    @property private void duration(int duration) {
        // Convert the setting to the duration as the number of samples
        _duration = (64 - duration) * (SYSTEM_CLOCK_FREQUENCY / 256) / CYCLES_PER_PSG_SAMPLE;
    }

    private void restart() {
        enabled = true;
        tDuration = 0;
        tPeriod = 0;
        envelope = initialVolume;
    }

    private short nextSample() {
        // Don't play if disabled
        if (!enabled) {
            return 0;
        }
        // Generate the sample
        auto period = (2048 - rate) * 2;
        auto amplitude = cast(short) (envelope * 8);
        auto sample = tPeriod >= (period * _duty) / 1024 ? -amplitude : amplitude;
        // Update the envelope if enabled
        if (_envelopeStep > 0 && tDuration % _envelopeStep == 0) {
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
            if (_sweepStep > 0 && tDuration % _sweepStep == 0) {
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
        // Increment the time values
        tPeriod += 1;
        if (tPeriod >= period) {
            tPeriod = 0;
        }
        // Disable for the next sample if the duration expired
        tDuration += 1;
        if (useDuration && tDuration >= _duration) {
            enabled = false;
        }
        return sample;
    }
}

private struct PatternWaveGenerator {
    private static enum WAVE_FREQUENCY = 2 ^^ 21;
    private static enum BYTES_PER_PATTERN = 4 * int.sizeof;
    private void[BYTES_PER_PATTERN * 2] patterns;
    private bool enabled = false;
    private bool combineBanks = false;
    private int selectedBank = 0;
    private int _volume = 0;
    private size_t _duration = 0;
    private bool useDuration = false;
    private int rate = 0;
    private size_t tDuration = 0;
    private size_t tPeriod = 0;
    private size_t pointer = 0;
    private size_t pointerEnd = 0;
    private short sample = 0;

    @property private void volume(int volume) {
        final switch (volume) {
            case 0b000:
                _volume = 0;
                break;
            case 0b001:
                _volume = 16;
                break;
            case 0b010:
                _volume = 8;
                break;
            case 0b011:
                _volume = 4;
                break;
            case 0b100:
            case 0b101:
            case 0b110:
            case 0b111:
                _volume = 12;
                break;
        }
    }

    @property private void duration(int duration) {
        // Convert the setting to the duration as the number of samples
        _duration = (256 - duration) * (SYSTEM_CLOCK_FREQUENCY / 256) / CYCLES_PER_PSG_SAMPLE;
    }

    @property private void pattern(int index)(int pattern) {
        (cast(int*) patterns.ptr)[(1 - selectedBank) * (BYTES_PER_PATTERN / int.sizeof) + index] = pattern;
    }

    private void restart() {
        tDuration = 0;
        tPeriod = 0;
        pointer = selectedBank * 2 * BYTES_PER_PATTERN;
        pointerEnd = combineBanks ? 2 * BYTES_PER_PATTERN * 2 : pointer + 2 * BYTES_PER_PATTERN;
    }

    private short nextSample() {
        // Don't play if disabled
        if (!enabled) {
            return 0;
        }
        // Disable for the next sample if the duration expired
        tDuration += 1;
        if (useDuration && tDuration >= _duration) {
            enabled = false;
        }
        // Check if we should generate a new sample
        auto period = (2048 - rate) * 2;
        int newSampleCount = cast(int) tPeriod / period;
        if (newSampleCount <= 0) {
            // Increment the period time value and return the pervious sample
            tPeriod += WAVE_FREQUENCY / PSG_FREQUENCY;
            return sample;
        }
        // Accumulate samples
        int newSample = 0;
        foreach (i; 0 .. newSampleCount) {
            // Get the byte at the pointer, the the upper nibble for the first sample and the lower for the second
            auto sampleByte = (cast(byte*) patterns.ptr)[pointer / 2];
            auto unsignedSample = (sampleByte >>> (1 - pointer % 2) * 4) & 0xF;
            newSample += unsignedSample * _volume - 120;
            // Increment the pointer and reset to the start on overflow
            pointer += 1;
            if (pointer >= pointerEnd) {
                pointer = selectedBank * 2 * BYTES_PER_PATTERN;
            }
        }
        // Set the new sample as the average of the accumulated ones
        sample = cast(short) (newSample / newSampleCount);
        // Leave the time period remainder
        tPeriod %= period;
        // Increment the period time value
        tPeriod += WAVE_FREQUENCY / PSG_FREQUENCY;
        return sample;
    }
}
