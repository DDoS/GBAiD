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
    private SquareWaveGenerator tone1;
    private short[SAMPLE_BATCH_SIZE] sampleBatch;
    private uint sampleBatchIndex = 0;

    public this(IoRegisters* ioRegisters) {
        this.ioRegisters = ioRegisters;

        ioRegisters.setPostWriteMonitor!0x60(&onToneLowPostWrite);
        ioRegisters.setPostWriteMonitor!0x64(&onToneHighPostWrite);
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

            short sample = tone1.nextSample();

            sampleBatch[sampleBatchIndex] = sample;
            sampleBatchIndex += 1;

            if (sampleBatchIndex >= SAMPLE_BATCH_SIZE) {
                _receiver(sampleBatch);
                sampleBatchIndex = 0;
            }
        }

        return cycles;
    }

    private void onToneLowPostWrite(IoRegisters* ioRegisters, int address, int shift, int mask, int oldSettings,
            int newSettings) {
        tone1.duration = newSettings.getBits(32, 37);
    }

    private void onToneHighPostWrite(IoRegisters* ioRegisters, int address, int shift, int mask, int oldSettings,
            int newSettings) {
        tone1.frequency = newSettings & 0x7FF;
        tone1.ignoreDuration = newSettings.checkBit(14);
        if (newSettings.checkBit(15)) {
            tone1.restart();
        }
    }
}

private struct SquareWaveGenerator {
    private size_t _period = 0;
    private size_t _duration = 0;
    private bool ignoreDuration = false;
    private size_t t = 0;

    @property private void frequency(int frequency) {
        // Convert the rate to period of the output
        _period = (2048 - frequency) / 2;
    }

    @property private void duration(int duration) {
        // Convert the setting to number of samples
        _duration = (64 - duration) * (SYSTEM_CLOCK_FREQUENCY / 256);
    }

    private void restart() {
        t = 0;
    }

    private short nextSample() {
        // Check if the sound expired
        if (!ignoreDuration && t >= _duration) {
            return 0;
        }
        // Generate the sample and increment t
        return t++ % _period < _period / 2 ? short.max : short.min;
    }
}
