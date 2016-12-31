module gbaid.gba.sound;

public alias AudioReceiver = void delegate(short[]);

public class SoundChip {
    private enum uint OUTPUT_FREQUENCY = 2 ^^ 16;
    private enum uint SYSTEM_CLOCK_FREQUENCY = 2 ^^ 24;
    private enum uint PSG_FREQUENCY = 2 ^^ 18;
    private enum uint CYCLES_PER_PSG_PERIOD = SYSTEM_CLOCK_FREQUENCY / PSG_FREQUENCY;
    private AudioReceiver _receiver = null;
    private short[] sampleBatch;
    private uint sampleBatchIndex = 0;
    private uint timeValue = 0;

    @property public void receiver(AudioReceiver receiver, uint sampleBatchLength) {
        _receiver = receiver;
        sampleBatch.length = sampleBatchLength;
    }

    public size_t emulate(size_t cycles) {
        if (_receiver is null) {
            return 0;
        }

        enum cyclesPerSample = SYSTEM_CLOCK_FREQUENCY / OUTPUT_FREQUENCY;
        enum note = 440;
        enum functionPeriodLength = OUTPUT_FREQUENCY / note;

        while (cycles >= cyclesPerSample) {
            cycles -= cyclesPerSample;

            short sample = void;
            if (timeValue < functionPeriodLength / 2) {
                sample = short.max;
            } else {
                sample = short.min;
            }

            timeValue += 1;
            if (timeValue >= functionPeriodLength) {
                timeValue = 0;
            }

            sampleBatch[sampleBatchIndex] = sample;
            sampleBatchIndex += 1;

            if (sampleBatchIndex >= sampleBatch.length) {
                _receiver(sampleBatch);
                sampleBatchIndex = 0;
            }
        }

        return cycles;
    }
}
