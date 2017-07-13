module gbaid.gba.sound;

import std.meta : AliasSeq;

import gbaid.gba.io;
import gbaid.gba.dma;

import gbaid.util;

public alias AudioReceiver = void delegate(short[]);

private enum uint SYSTEM_CLOCK_FREQUENCY = 2 ^^ 24;
private enum uint PSG_FREQUENCY = 2 ^^ 18;
public enum uint SOUND_OUTPUT_FREQUENCY = 2 ^^ 16;
private enum size_t CYCLES_PER_PSG_SAMPLE = SYSTEM_CLOCK_FREQUENCY / PSG_FREQUENCY;
private enum size_t PSG_PER_AUDIO_SAMPLE = PSG_FREQUENCY / SOUND_OUTPUT_FREQUENCY;
public enum size_t CYCLES_PER_AUDIO_SAMPLE = SYSTEM_CLOCK_FREQUENCY / SOUND_OUTPUT_FREQUENCY;
private enum int OUTPUT_AMPLITUDE_RESCALE = (short.max + 1) / 2 ^^ 9;

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
    private bool masterEnable = false;
    private int psgRightVolume = 0;
    private int psgLeftVolume = 0;
    private int psgRightEnableFlags = 0;
    private int psgLeftEnableFlags = 0;
    private int psgGlobalVolume = 0;
    private int directAVolume = 0;
    private int directBVolume = 0;
    private int directAEnableFlags = 0;
    private int directBEnableFlags = 0;
    private int biasLevel = 0x200;
    private int amplitudeResolution = 0;
    private int psgRightReSample = 0;
    private int psgLeftReSample = 0;
    private uint psgCount = 0;
    private short[SAMPLE_BATCH_SIZE] sampleBatch;
    private uint sampleBatchIndex = 0;

    public this(IoRegisters* ioRegisters, DMAs dmas) {
        this.ioRegisters = ioRegisters;
        directA = DirectSound!'A'(dmas);
        directB = DirectSound!'B'(dmas);

        ioRegisters.mapAddress(0x60, &tone1.sweepShift, 0b111, 0);
        ioRegisters.mapAddress(0x60, &tone1.decreasingShift, 0b1, 3);
        ioRegisters.mapAddress(0x60, &tone1.sweepStep, 0b111, 4);
        ioRegisters.mapAddress(0x60, &tone1.duration, 0x3F, 16, false, true);
        ioRegisters.mapAddress(0x60, &tone1.duty, 0b11, 22);
        ioRegisters.mapAddress(0x60, &tone1.envelopeStep, 0b111, 24);
        ioRegisters.mapAddress(0x60, &tone1.increasingEnvelope, 0b1, 27);
        ioRegisters.mapAddress(0x60, &tone1.initialVolume, 0b1111, 28);
        ioRegisters.mapAddress(0x64, &tone1.rate, 0x7FF, 0, false, true);
        ioRegisters.mapAddress(0x64, &tone1.useDuration, 0b1, 14);
        ioRegisters.mapAddress(0x64, null, 0b1, 15, false, true).preWriteMonitor(&onToneEnablePreWrite!1);

        ioRegisters.mapAddress(0x68, &tone2.duration, 0x3F, 0, false, true);
        ioRegisters.mapAddress(0x68, &tone2.duty, 0b11, 6);
        ioRegisters.mapAddress(0x68, &tone2.envelopeStep, 0b111, 8);
        ioRegisters.mapAddress(0x68, &tone2.increasingEnvelope, 0b1, 11);
        ioRegisters.mapAddress(0x68, &tone2.initialVolume, 0b1111, 12);
        ioRegisters.mapAddress(0x6C, &tone2.rate, 0x7FF, 0, false, true);
        ioRegisters.mapAddress(0x6C, &tone2.useDuration, 0b1, 14);
        ioRegisters.mapAddress(0x6C, null, 0b1, 15, false, true).preWriteMonitor(&onToneEnablePreWrite!2);

        ioRegisters.mapAddress(0x70, &wave.combineBanks, 0b1, 5);
        ioRegisters.mapAddress(0x70, &wave.selectedBank, 0b1, 6);
        ioRegisters.mapAddress(0x70, &wave.enabled, 0b1, 7);
        ioRegisters.mapAddress(0x70, &wave.duration, 0xFF, 16, false, true);
        ioRegisters.mapAddress(0x70, &wave.volume, 0b111, 29);
        ioRegisters.mapAddress(0x74, &wave.rate, 0x7FF, 0, false, true);
        ioRegisters.mapAddress(0x74, &wave.useDuration, 0b1, 14);
        ioRegisters.mapAddress(0x74, null, 0b1, 15, false, true).preWriteMonitor(&onWaveEnablePreWrite);

        foreach (i; AliasSeq!(0, 1, 2, 3)) {
            ioRegisters.mapAddress(0x90 + i * 4, null, 0xFFFFFFFF, 0)
                    .readMonitor(&onWavePatternRead!i)
                    .preWriteMonitor(&onWavePatternPreWrite!i);
        }

        ioRegisters.mapAddress(0x78, &noise.duration, 0x3F, 0, false, true);
        ioRegisters.mapAddress(0x78, &noise.envelopeStep, 0b111, 8);
        ioRegisters.mapAddress(0x78, &noise.increasingEnvelope, 0b1, 11);
        ioRegisters.mapAddress(0x78, &noise.initialVolume, 0b1111, 12);
        ioRegisters.mapAddress(0x7C, &noise.divider, 0b111, 0);
        ioRegisters.mapAddress(0x7C, &noise.use7Bits, 0b1, 3);
        ioRegisters.mapAddress(0x7C, &noise.preScaler, 0b1111, 4);
        ioRegisters.mapAddress(0x7C, &noise.useDuration, 0b1, 14);
        ioRegisters.mapAddress(0x7C, null, 0b1, 15, false, true).preWriteMonitor(&onNoiseEnablePreWrite);

        ioRegisters.mapAddress(0xA0, null, 0xFFFFFFFF, 0).preWriteMonitor(&onDirectSoundQueuePreWrite!'A');
        ioRegisters.mapAddress(0xA4, null, 0xFFFFFFFF, 0).preWriteMonitor(&onDirectSoundQueuePreWrite!'B');

        ioRegisters.mapAddress(0x80, &psgRightVolume, 0b111, 0);
        ioRegisters.mapAddress(0x80, &psgLeftVolume, 0b111, 4);
        ioRegisters.mapAddress(0x80, &psgRightEnableFlags, 0b1111, 8);
        ioRegisters.mapAddress(0x80, &psgLeftEnableFlags, 0b1111, 12);
        ioRegisters.mapAddress(0x80, &psgGlobalVolume, 0b11, 16);
        ioRegisters.mapAddress(0x80, &directAVolume, 0b1, 18);
        ioRegisters.mapAddress(0x80, &directBVolume, 0b1, 19);
        ioRegisters.mapAddress(0x80, &directAEnableFlags, 0b11, 24);
        ioRegisters.mapAddress(0x80, &directA.timerIndex, 0b1, 26);
        ioRegisters.mapAddress(0x80, null, 0b1, 27, false, true).preWriteMonitor(&onDirectSoundClearPreWrite!'A');
        ioRegisters.mapAddress(0x80, &directBEnableFlags, 0b11, 28);
        ioRegisters.mapAddress(0x80, &directB.timerIndex, 0b1, 30);
        ioRegisters.mapAddress(0x80, null, 0b1, 31, false, true).preWriteMonitor(&onDirectSoundClearPreWrite!'B');

        ioRegisters.mapAddress(0x84, &tone1.enabled, 0b1, 0, true, false);
        ioRegisters.mapAddress(0x84, &tone2.enabled, 0b1, 1, true, false);
        ioRegisters.mapAddress(0x84, &wave.enabled, 0b1, 2, true, false);
        ioRegisters.mapAddress(0x84, &noise.enabled, 0b1, 3, true, false);
        ioRegisters.mapAddress(0x84, &masterEnable, 0b1, 7).preWriteMonitor(&onMasterEnablePreWrite);

        ioRegisters.mapAddress(0x88, &biasLevel, 0x3FF, 0);
        ioRegisters.mapAddress(0x88, &amplitudeResolution, 0b11, 14);

        // TODO: unmap all the addresses when the masterEnable is 0, and remap when 1
    }

    @property public void receiver(AudioReceiver receiver) {
        _receiver = receiver;
    }

    public void addTimerOverflows(int timer)(size_t overflows) if (timer == 0 || timer == 1) {
        if (directA.enabled && directA.timerIndex == timer) {
            directA.timerOverflows += overflows;
        }
        if (directB.enabled && directB.timerIndex == timer) {
            directB.timerOverflows += overflows;
        }
    }

    public size_t emulate(size_t cycles) {
        if (_receiver is null) {
            return 0;
        }
        // Update the direct sound channels
        directA.updateSample();
        directB.updateSample();
        // Compute the PSG cycles
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
            // Apply the final volume adjustements and accumulate the samples
            psgRightReSample += rightPsgSample * psgRightVolume >> 2 - psgGlobalVolume;
            psgLeftReSample += leftPsgSample * psgLeftVolume >> 2 - psgGlobalVolume;
            psgCount += 1;
            // Check if we have accumulated all the PSG samples for a single output sample
            if (psgCount == PSG_PER_AUDIO_SAMPLE) {
                // Average out the PSG samples to start forming the final output sample
                auto outputRight = psgRightReSample / cast(int) PSG_PER_AUDIO_SAMPLE;
                auto outputLeft = psgLeftReSample / cast(int) PSG_PER_AUDIO_SAMPLE;
                // Now get the samples for the direct sound
                auto directASample = directA.nextSample() >> 1 - directAVolume;
                if (directAEnableFlags & 0b1) {
                    outputRight += directASample;
                }
                if (directAEnableFlags & 0b10) {
                    outputLeft += directASample;
                }
                auto directBSample = directB.nextSample() >> 1 - directBVolume;
                if (directBEnableFlags & 0b1) {
                    outputRight += directBSample;
                }
                if (directBEnableFlags & 0b10) {
                    outputLeft += directBSample;
                }
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

    private bool onToneEnablePreWrite(int channel)(int mask, ref int enable) {
        if (enable) {
            static if (channel == 1) {
                tone1.restart();
            } else {
                tone2.restart();
            }
        }
        return false;
    }

    private bool onWaveEnablePreWrite(int mask, ref int enable) {
        if (enable) {
            wave.restart();
        }
        return false;
    }

    private void onWavePatternRead(int index)(int mask, ref int pattern) {
        pattern = *wave.patternData!index;
    }

    private bool onWavePatternPreWrite(int index)(int mask, ref int pattern) {
        *wave.patternData!index = *wave.patternData!index & ~mask | pattern;
        return false;
    }

    private bool onNoiseEnablePreWrite(int mask, ref int enable) {
        if (enable) {
            noise.restart();
        }
        return false;
    }

    private bool onDirectSoundQueuePreWrite(char channel)(int mask, ref int newData) {
        alias Direct = DirectSound!channel;
        static if (channel == 'A') {
            alias direct = directA;
        } else static if (channel == 'B') {
            alias direct = directB;
        }
        // Write the bytes to the sound queue
        foreach (i; 0 .. int.sizeof) {
            // Only write the new bytes to the queue
            if (mask & 0xFF) {
                // Flush out a sample if the queue is full
                if (direct.queueSize >= Direct.QUEUE_BYTE_SIZE) {
                    direct.queueIndex += 1;
                    direct.queueSize--;
                }
                // Write the byte at the next index and increment the size
                direct.queue[(direct.queueIndex + direct.queueSize) % Direct.QUEUE_BYTE_SIZE] = cast(byte) newData;
                direct.queueSize += 1;
            }
            // Shift to the next byte (from least to most significant)
            mask >>>= 8;
            newData >>>= 8;
        }
        return false;
    }

    private bool onDirectSoundClearPreWrite(char channel)(int mask, ref int clear) {
        if (clear) {
            static if (channel == 'A') {
                directA.clearQueue();
            } else {
                directB.clearQueue();
            }
        }
        return false;
    }

    private bool onMasterEnablePreWrite(int mask, ref int masterEnable) {
        directA.enabled = cast(bool) masterEnable;
        directB.enabled = cast(bool) masterEnable;
        // Clear the PSG sound channels on disable
        if (!masterEnable) {
            tone1 = SquareWaveGenerator!true.init;
            tone2 = SquareWaveGenerator!false.init;
            wave = PatternWaveGenerator.init;
            noise = NoiseGenerator.init;
            // Also reset PSG output control
            psgRightVolume = 0;
            psgLeftVolume = 0;
            psgRightEnableFlags = 0;
            psgLeftEnableFlags = 0;
        }
        return false;
    }
}

private struct SquareWaveGenerator(bool sweep) {
    private static enum size_t SQUARE_WAVE_FREQUENCY = 2 ^^ 17;
    private bool enabled = false;
    private int rate = 0;
    private int duty = 0;
    private int envelopeStep = 0;
    private bool increasingEnvelope = false;
    private int initialVolume = 0;
    static if (sweep) {
        private int sweepShift = 0;
        private bool decreasingShift = false;
        private int sweepStep = 0;
    }
    private int duration = 0;
    private bool useDuration = false;
    private size_t tDuration = 0;
    private size_t tPeriod = 0;
    private int envelope = 0;

    private void restart() {
        enabled = true;
        tDuration = 0;
        tPeriod = 0;
        envelope = initialVolume;
    }

    private int nextSample() {
        // Don't play if disabled
        if (!enabled) {
            return 0;
        }
        // Find the period and the edge (in ticks)
        auto period = (2048 - rate) * (PSG_FREQUENCY / SQUARE_WAVE_FREQUENCY);
        size_t edge = void;
        final switch (duty) {
            case 0:
                edge = period / 8;
                break;
            case 1:
                edge = period / 4;
                break;
            case 2:
                edge = period / 2;
                break;
            case 3:
                edge = 3 * (period / 4);
                break;
        }
        // Generate the sample
        auto sample = tPeriod >= edge ? -envelope : envelope;
        // Increment the period time value
        tPeriod += 1;
        if (tPeriod >= period) {
            tPeriod = 0;
        }
        // Disable for the next sample if the duration expired
        tDuration += 1;
        if (useDuration && tDuration >= (64 - duration) * (PSG_FREQUENCY / 256)) {
            enabled = false;
        }
        // Update the envelope if enabled
        if (envelopeStep > 0 && tDuration % (envelopeStep * (PSG_FREQUENCY / 64)) == 0) {
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
            if (sweepStep > 0 && tDuration % (sweepStep * (PSG_FREQUENCY / 128)) == 0) {
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
        return sample;
    }
}

// TODO: use a shift register
private struct PatternWaveGenerator {
    private static enum size_t PATTERN_FREQUENCY = 2 ^^ 21;
    private static enum size_t BYTES_PER_PATTERN = 4 * int.sizeof;
    private void[BYTES_PER_PATTERN * 2] patterns;
    private bool enabled = false;
    private bool combineBanks = false;
    private int selectedBank = 0;
    private int volume = 0;
    private int duration = 0;
    private bool useDuration = false;
    private int rate = 0;
    private size_t tDuration = 0;
    private size_t tPeriod = 0;
    private size_t pointer = 0;
    private size_t pointerEnd = 0;
    private int sample = 0;

    @property private int* patternData(int index)() {
        return cast(int*) patterns.ptr + ((1 - selectedBank) * (BYTES_PER_PATTERN / int.sizeof) + index);
    }

    private void restart() {
        tDuration = 0;
        tPeriod = 0;
        pointer = selectedBank * 2 * BYTES_PER_PATTERN;
        pointerEnd = combineBanks ? 2 * BYTES_PER_PATTERN * 2 : pointer + 2 * BYTES_PER_PATTERN;
    }

    private int nextSample() {
        // Don't play if disabled
        if (!enabled) {
            return 0;
        }
        // Check if we should generate a new sample
        auto period = 2048 - rate;
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
            sample = newSample / newSampleCount;
            // Leave the time period remainder
            tPeriod %= period;
        }
        // Increment the period time value
        tPeriod += PATTERN_FREQUENCY / PSG_FREQUENCY;
        // Disable for the next sample if the duration expired
        tDuration += 1;
        if (useDuration && tDuration >= (256 - duration) * (PSG_FREQUENCY / 256)) {
            enabled = false;
        }
        return sample;
    }
}

private struct NoiseGenerator {
    private static enum size_t NOISE_FREQUENCY = 2 ^^ 19;
    private bool enabled = false;
    private bool use7Bits = false;
    private int divider = 0;
    private int preScaler = 0;
    private int envelopeStep = 0;
    private bool increasingEnvelope = false;
    private int initialVolume = 0;
    private int duration = 0;
    private bool useDuration = false;
    private size_t tDuration = 0;
    private size_t tPeriod = 0;
    private int shifter = 0x4000;
    private int envelope = 0;
    private int sample = 0;

    private void restart() {
        enabled = true;
        tDuration = 0;
        tPeriod = 0;
        envelope = initialVolume;
        shifter = use7Bits ? 0x40 : 0x4000;
    }

    private int nextSample() {
        // Don't play if disabled
        if (!enabled) {
            return 0;
        }
        // Calculate the period by applying the inverse of the divider and pre-scaler
        auto period = 1 << preScaler + 1;
        if (divider == 0) {
            period /= 2;
        } else {
            period *= divider;
        }
        // Check if we should generate a new sample
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
            sample = newSample / newSampleCount;
            // Leave the time period remainder
            tPeriod %= period;
        }
        // Increment the period time value
        tPeriod += NOISE_FREQUENCY / PSG_FREQUENCY;
        // Disable for the next sample if the duration expired
        tDuration += 1;
        if (useDuration && tDuration >= (64 - duration) * (PSG_FREQUENCY / 256)) {
            enabled = false;
        }
        // Update the envelope if enabled (using the duration before it was incremented)
        if (envelopeStep > 0 && tDuration % (envelopeStep * (PSG_FREQUENCY / 64)) == 0) {
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

private struct DirectSound(char channel) {
    private static enum size_t QUEUE_BYTE_SIZE = 32;
    private byte[QUEUE_BYTE_SIZE] queue;
    private DMAs dmas;
    private bool enabled = false;
    private int timerIndex = 0;
    private size_t timerOverflows = 0;
    private size_t queueIndex = 0;
    private size_t queueSize = 0;
    private int reSample = 0;
    private int reSampleCount = 0;
    private short sample = 0;

    private this(DMAs dmas) {
        this.dmas = dmas;
    }

    private void clearQueue() {
        queueIndex = 0;
        queueSize = 0;
        reSample = 0;
        reSampleCount = 0;
        sample = 0;
    }

    private void updateSample() {
        if (timerOverflows <= 0) {
            return;
        }
        // Take one sample from the queue for each timer overflow
        while (timerOverflows > 0 && queueSize > 0) {
            timerOverflows -= 1;
            // Take the sample from the queue and accumulate it (after amplifying it)
            reSample += queue[queueIndex] * 4;
            reSampleCount += 1;
            // Update the queue index and size
            queueIndex = (queueIndex + 1) % QUEUE_BYTE_SIZE;
            queueSize -= 1;
        }
        // Clear the timer overflow count
        timerOverflows = 0;
        // If the queue is half empty then signal the DMAs to transfer more
        if (queueSize <= QUEUE_BYTE_SIZE / 2) {
            mixin ("dmas.signalSoundQueue" ~ channel ~ "();");
        }
    }

    private short nextSample() {
        // Generate a new sample if we have any
        if (reSampleCount > 0) {
            // Average the samples
            sample = cast(short) (reSample / reSampleCount);
            // Clear the re-sample and count
            reSample = 0;
            reSampleCount = 0;
        }
        return sample;
    }
}
