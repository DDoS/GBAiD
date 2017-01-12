module gbaid.gba.sound;

import gbaid.gba.memory;
import gbaid.gba.dma;

import gbaid.util;

public alias AudioReceiver = void delegate(short[]);

private enum uint SYSTEM_CLOCK_FREQUENCY = 2 ^^ 24;
private enum uint PSG_FREQUENCY = 2 ^^ 18;
public enum uint SOUND_OUTPUT_FREQUENCY = 2 ^^ 16;
private enum size_t CYCLES_PER_PSG_SAMPLE = SYSTEM_CLOCK_FREQUENCY / PSG_FREQUENCY;
private enum size_t PSG_PER_AUDIO_SAMPLE = PSG_FREQUENCY / SOUND_OUTPUT_FREQUENCY;
public enum size_t CYCLES_PER_AUDIO_SAMPLE = SYSTEM_CLOCK_FREQUENCY / SOUND_OUTPUT_FREQUENCY;
private enum int OUTPUT_AMPLITUDE_RESCALE = short.max / 2 ^^ 10;

public class SoundChip {
    private static enum uint SAMPLE_BATCH_SIZE = 256 * 2;
    private IoRegisters* ioRegisters;
    private AudioReceiver _receiver = null;
    private SquareWaveGenerator!true tone1;
    private SquareWaveGenerator!false tone2;
    private PatternWaveGenerator wave;
    private NoiseGenerator noise;
    private DirectSound!'A' directA;
    private DirectSound!'B' directB;
    private int psgRightVolumeMultiplier = 0;
    private int psgLeftVolumeMultiplier = 0;
    private int psgRightEnableFlags = 0;
    private int psgLeftEnableFlags = 0;
    private int psgGlobalVolumeDivider = 4;
    private int psgRightReSample = 0;
    private int psgLeftReSample = 0;
    private uint psgCount = 0;
    private short[SAMPLE_BATCH_SIZE] sampleBatch;
    private uint sampleBatchIndex = 0;

    public this(IoRegisters* ioRegisters, DMAs dmas) {
        this.ioRegisters = ioRegisters;
        directA = DirectSound!'A'(dmas);
        directB = DirectSound!'B'(dmas);

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
        ioRegisters.setPostWriteMonitor!0x78(&onNoiseLowPostWrite);
        ioRegisters.setPostWriteMonitor!0x7C(&onNoiseHighPostWrite);
        ioRegisters.setPostWriteMonitor!0xA0(&onDirectSoundQueuePostWrite!'A');
        ioRegisters.setPostWriteMonitor!0xA4(&onDirectSoundQueuePostWrite!'B');
        ioRegisters.setPostWriteMonitor!0x80(&onSoundControlPostWrite);
        ioRegisters.setReadMonitor!0x84(&onSoundStatusRead);
    }

    @property public void receiver(AudioReceiver receiver) {
        _receiver = receiver;
    }

    public void addTimerOverflows(int timer)(size_t overflows) if (timer == 0 || timer == 1) {
        if (directA.timerIndex == timer) {
            directA.timerOverflows += overflows;
        }
        if (directB.timerIndex == timer) {
            directB.timerOverflows += overflows;
        }
    }

    public size_t emulate(size_t cycles) {
        if (_receiver is null) {
            return 0;
        }

        while (cycles >= CYCLES_PER_PSG_SAMPLE) {
            cycles -= CYCLES_PER_PSG_SAMPLE;
            // Accumulate the PSG channel value for the left and right samples
            int rightPsgSample = 0;
            int leftPsgSample = 0;
            // Add the tone 1 channel if enabled
            auto tone1Sample = tone1.nextSample();
            if (psgRightEnableFlags & 0b1) {
                rightPsgSample += tone1Sample;
            }
            if (psgLeftEnableFlags & 0b1) {
                leftPsgSample += tone1Sample;
            }
            // Add the tone 2 channel if enabled
            auto tone2Sample = tone2.nextSample();
            if (psgRightEnableFlags & 0b10) {
                rightPsgSample += tone2Sample;
            }
            if (psgLeftEnableFlags & 0b10) {
                leftPsgSample += tone2Sample;
            }
            // Add the wave channel if enabled
            auto waveSample = wave.nextSample();
            if (psgRightEnableFlags & 0b100) {
                rightPsgSample += waveSample;
            }
            if (psgLeftEnableFlags & 0b100) {
                leftPsgSample += waveSample;
            }
            // Add the noise channel if enabled
            auto noiseSample = noise.nextSample();
            if (psgRightEnableFlags & 0b1000) {
                rightPsgSample += noiseSample;
            }
            if (psgLeftEnableFlags & 0b1000) {
                leftPsgSample += noiseSample;
            }
            // Apply the final volume adjustement
            psgRightReSample += (rightPsgSample * psgRightVolumeMultiplier) / psgGlobalVolumeDivider;
            psgLeftReSample += (leftPsgSample * psgLeftVolumeMultiplier) / psgGlobalVolumeDivider;
            psgCount += 1;
            // Check if we have accumulated all the PSG samples for a single output sample
            if (psgCount == PSG_PER_AUDIO_SAMPLE) {
                // Average out the PSG samples to start forming the final output sample
                auto outputRight = psgRightReSample / cast(int) PSG_PER_AUDIO_SAMPLE;
                auto outputLeft = psgLeftReSample / cast(int) PSG_PER_AUDIO_SAMPLE;
                // Now get the samples for the direct sound
                auto directASample = directA.nextSample();
                auto directBSample = directB.nextSample();
                outputRight += directASample + directBSample;
                outputLeft += directASample + directBSample;
                // Copy the final left and right values of the sample to the output batch buffer
                sampleBatch[sampleBatchIndex++] = cast(short) (outputLeft * OUTPUT_AMPLITUDE_RESCALE);
                sampleBatch[sampleBatchIndex++] = cast(short) (outputRight * OUTPUT_AMPLITUDE_RESCALE);
                // If our output batch buffer is full, then send it to the audio receiver
                if (sampleBatchIndex >= SAMPLE_BATCH_SIZE) {
                    _receiver(sampleBatch);
                    sampleBatchIndex = 0;
                }
                // Finally we can reset the accumulator
                psgRightReSample = 0;
                psgLeftReSample = 0;
                psgCount = 0;
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

    private void onNoiseLowPostWrite(IoRegisters* ioRegisters, int address, int shift, int mask, int oldSettings,
            int newSettings) {
        noise.duration = newSettings & 0x3F;
        noise.envelopeStep = newSettings.getBits(8, 10);
        noise.increasingEnvelope = newSettings.checkBit(11);
        noise.initialVolume = newSettings.getBits(12, 15);
    }

    private void onNoiseHighPostWrite(IoRegisters* ioRegisters, int address, int shift, int mask, int oldSettings,
            int newSettings) {
        noise.divider = newSettings & 0x7;
        noise.use7Bits = newSettings.checkBit(3);
        noise.preScaler = newSettings.getBits(4, 7);
        noise.useDuration = newSettings.checkBit(14);
        if (newSettings.checkBit(15)) {
            noise.restart();
        }
    }

    private void onDirectSoundQueuePostWrite(char channel)(IoRegisters* ioRegisters, int address, int shift, int mask,
            int oldData, int newData) {
        alias Direct = DirectSound!channel;
        static if (channel == 'A') {
            alias direct = directA;
        } else {
            alias direct = directB;
        }
        // Write the bytes to the sound queue
        foreach (i; 0 .. 4) {
            // Only write the new bytes to the queue
            if (mask & 0xFF) {
                // Stop if the queue is full
                if (direct.queueSize >= Direct.QUEUE_BYTE_SIZE) {
                    break;
                }
                // Write the byte at the next index and increment the size
                direct.queue[(direct.queueIndex + direct.queueSize) % Direct.QUEUE_BYTE_SIZE] = cast(byte) newData;
                direct.queueSize += 1;
            }
            // Shift to the next byte (from least to most significant)
            mask >>= 8;
            newData >>= 8;
        }
    }

    private void onSoundControlPostWrite(IoRegisters* ioRegisters, int address, int shift, int mask, int oldSettings,
            int newSettings) {
        psgRightVolumeMultiplier = newSettings & 0b111;
        psgLeftVolumeMultiplier = newSettings.getBits(4, 6);
        psgRightEnableFlags = newSettings.getBits(8, 11);
        psgLeftEnableFlags = newSettings.getBits(12, 15);
        switch (newSettings.getBits(16, 17)) {
            case 0:
                psgGlobalVolumeDivider = 4;
                break;
            case 1:
                psgGlobalVolumeDivider = 2;
                break;
            case 2:
                psgGlobalVolumeDivider = 1;
                break;
            default:
        }
        directA.timerIndex = newSettings.getBit(26);
        if (newSettings.checkBit(27)) {
            directA.restart();
        }
        directB.timerIndex = newSettings.getBit(30);
        if (newSettings.checkBit(31)) {
            directB.restart();
        }
    }

    private void onSoundStatusRead(IoRegisters* ioRegisters, int address, int shift, int mask, ref int value) {
        // Ignore reads that aren't on the status flags
        if (!(mask & 0b1111)) {
            return;
        }
        // Write the enable flags to the value
        value.setBit(0, tone1.enabled);
        value.setBit(1, tone2.enabled);
        value.setBit(2, wave.enabled);
        value.setBit(3, noise.enabled);
        // TODO: master enable bit and reset all channels
    }
}

private struct SquareWaveGenerator(bool sweep) {
    private static enum size_t SQUARE_WAVE_FREQUENCY = 2 ^^ 17;
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
        auto period = (2048 - rate) * (PSG_FREQUENCY / SQUARE_WAVE_FREQUENCY);
        auto sample = cast(short) (tPeriod >= (period * _duty) / 1024 ? -envelope : envelope);
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
                if (rate < 0 || rate >= 2048) {
                    enabled = false;
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
    private static enum size_t PATTERN_FREQUENCY = 2 ^^ 21;
    private static enum size_t BYTES_PER_PATTERN = 4 * int.sizeof;
    private void[BYTES_PER_PATTERN * 2] patterns;
    private bool enabled = false;
    private bool combineBanks = false;
    private int selectedBank = 0;
    private int volume = 0;
    private size_t _duration = 0;
    private bool useDuration = false;
    private int rate = 0;
    private size_t tDuration = 0;
    private size_t tPeriod = 0;
    private size_t pointer = 0;
    private size_t pointerEnd = 0;
    private short sample = 0;

    @property private void duration(int duration) {
        // Convert the setting to the duration as the number of samples
        _duration = (256 - duration) * (SYSTEM_CLOCK_FREQUENCY / 256) / CYCLES_PER_PSG_SAMPLE;
    }

    @property private void pattern(int index)(int pattern) {
        (cast(int*) patterns.ptr)[(1 - selectedBank) * (BYTES_PER_PATTERN / int.sizeof) + index] = pattern;
    }

    private int calculatePeriod() {
        return 2048 - rate;
    }

    private void restart() {
        tDuration = 0;
        tPeriod = calculatePeriod();
        pointer = selectedBank * 2 * BYTES_PER_PATTERN;
        pointerEnd = combineBanks ? 2 * BYTES_PER_PATTERN * 2 : pointer + 2 * BYTES_PER_PATTERN;
    }

    private short nextSample() {
        // Don't play if disabled
        if (!enabled) {
            return 0;
        }
        // Check if we should generate a new sample
        auto period = calculatePeriod();
        int newSampleCount = cast(int) tPeriod / period;
        if (newSampleCount > 0) {
            // Accumulate samples
            int newSample = 0;
            foreach (i; 0 .. newSampleCount) {
                // Get the byte at the pointer, the the upper nibble for the first sample and the lower for the second
                auto sampleByte = (cast(byte*) patterns.ptr)[pointer / 2];
                auto unsignedSample = (sampleByte >>> (1 - pointer % 2) * 4) & 0xF;
                // Apply the volume setting and accumulate
                final switch (volume) {
                    case 0b000:
                        // 0%
                        break;
                    case 0b001:
                        // 100%
                        newSample += unsignedSample * 2 - 16;
                        break;
                    case 0b010:
                        // 50%
                        newSample += unsignedSample - 8;
                        break;
                    case 0b011:
                        // 25%
                        newSample += unsignedSample / 2 - 4;
                        break;
                    case 0b100:
                    case 0b101:
                    case 0b110:
                    case 0b111:
                        // 75%
                        newSample += (3 * unsignedSample) / 2 - 12;
                        break;
                }
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
        }
        // Disable for the next sample if the duration expired
        tDuration += 1;
        if (useDuration && tDuration >= _duration) {
            enabled = false;
        }
        // Increment the period time value
        tPeriod += PATTERN_FREQUENCY / PSG_FREQUENCY;
        return sample;
    }
}

private struct NoiseGenerator {
    private static enum size_t NOISE_FREQUENCY = 2 ^^ 19;
    private bool enabled = false;
    private bool use7Bits = false;
    private int divider = 0;
    private int preScaler = 0;
    private size_t _envelopeStep = 0;
    private bool increasingEnvelope = false;
    private int initialVolume = 0;
    private size_t _duration = 0;
    private bool useDuration = false;
    private size_t tDuration = 0;
    private size_t tPeriod = 0;
    private int shifter = 0x4000;
    private int envelope = 0;
    private short sample = 0;

    @property private void envelopeStep(int step) {
        // Convert the setting to the step as the number of samples
        _envelopeStep = step * (SYSTEM_CLOCK_FREQUENCY / 64) / CYCLES_PER_PSG_SAMPLE;
    }

    @property private void duration(int duration) {
        // Convert the setting to the duration as the number of samples
        _duration = (64 - duration) * (SYSTEM_CLOCK_FREQUENCY / 256) / CYCLES_PER_PSG_SAMPLE;
    }

    private int calculatePeriod() {
        // Calculate the period by applying the inverse of the divider and pre-scaler
        auto period = 1 << preScaler + 1;
        if (divider == 0) {
            return period / 2;
        }
        return period * divider;
    }

    private void restart() {
        enabled = true;
        tDuration = 0;
        tPeriod = calculatePeriod();
        envelope = initialVolume;
        shifter = use7Bits ? 0x40 : 0x4000;
    }

    private short nextSample() {
        // Don't play if disabled
        if (!enabled) {
            return 0;
        }
        // Check if we should generate a new sample
        auto period = calculatePeriod();
        int newSampleCount = cast(int) tPeriod / period;
        if (newSampleCount > 0) {
            // Accumulate samples
            int newSample = 0;
            foreach (i; 0 .. newSampleCount) {
                // Generate the new "random" bit and convert it to a sample
                auto outBit = shifter & 0b1;
                shifter >>= 1;
                if (outBit) {
                    newSample += envelope;
                    shifter ^= use7Bits ? 0x60 : 0x6000;
                } else {
                    newSample -= envelope;
                }
            }
            // Set the new sample as the average of the accumulated ones
            sample = cast(short) (newSample / newSampleCount);
            // Leave the time period remainder
            tPeriod %= period;
        }
        // Update the envelope if enabled (using the duration before it was incremented)
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
        // Disable for the next sample if the duration expired
        tDuration += 1;
        if (useDuration && tDuration >= _duration) {
            enabled = false;
        }
        // Increment the period time value
        tPeriod += NOISE_FREQUENCY / PSG_FREQUENCY;
        return sample;
    }
}

private struct DirectSound(char channel) {
    private static enum size_t QUEUE_BYTE_SIZE = 32;
    private byte[QUEUE_BYTE_SIZE] queue;
    private DMAs dmas;
    private int timerIndex = 0;
    private size_t timerOverflows = 0;
    private size_t queueIndex = 0;
    private size_t queueSize = 0;
    private int reSample = 0;
    private int reSampleCount = 0;

    private this(DMAs dmas) {
        this.dmas = dmas;
    }

    private void restart() {
        queueIndex = 0;
        queueSize = 0;
        reSampleCount = 0;
    }

    private short nextSample() {
        // Fetch some new samples if we have timer overflows
        if (timerOverflows > 0) {
            // Clear the re-sample and count
            reSample = 0;
            reSampleCount = 0;
            // Take one sample from the queue for each timer overflow
            foreach (i; 0 .. timerOverflows) {
                // Check that the queue isn't empty
                if (queueSize <= 0) {
                    break;
                }
                // Take the sample from the queue and accumulate it (after amplifying it)
                reSample += queue[queueIndex] * 4;
                reSampleCount += 1;
                // Update the queue index and size
                queueIndex = (queueIndex + 1) % QUEUE_BYTE_SIZE;
                queueSize -= 1;
            }
            // Clear the timer overflow count
            timerOverflows = 0;
            // If the queue is half empty them signal the DMAs to transfer more
            if (queueSize <= QUEUE_BYTE_SIZE / 2) {
                static if (channel == 'A') {
                    dmas.signalSoundQueueA();
                } else {
                    dmas.signalSoundQueueB();
                }
            }
        }
        // Return the sample, or 0 if we haven't gotten any yet
        return reSampleCount == 0 ? 0 : cast(short) (reSample / reSampleCount);
    }
}
