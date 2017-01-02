module gbaid.gba.sound;

public alias AudioReceiver = void delegate(short[]);

private enum uint SYSTEM_CLOCK_FREQUENCY = 2 ^^ 24;
private enum uint OUTPUT_FREQUENCY = 2 ^^ 16;
public enum size_t CYCLES_PER_AUDIO_SAMPLE = SYSTEM_CLOCK_FREQUENCY / OUTPUT_FREQUENCY;

public class SoundChip {
    private enum uint PSG_FREQUENCY = 2 ^^ 18;
    private enum uint CYCLES_PER_PSG_PERIOD = SYSTEM_CLOCK_FREQUENCY / PSG_FREQUENCY;
    private enum uint SAMPLE_BATCH_SIZE = 256;
    private AudioReceiver _receiver = null;
    private short[SAMPLE_BATCH_SIZE] sampleBatch;
    private uint sampleBatchIndex = 0;
    private uint timeValue = 0;

    @property public void receiver(AudioReceiver receiver) {
        _receiver = receiver;
    }

    public size_t emulate(size_t cycles) {
        if (_receiver is null) {
            return 0;
        }

        enum note = 440;
        enum functionPeriodLength = OUTPUT_FREQUENCY / note;

        while (cycles >= CYCLES_PER_AUDIO_SAMPLE) {
            cycles -= CYCLES_PER_AUDIO_SAMPLE;

            short sample = void;
            if (timeValue < functionPeriodLength / 2) {
                sample = short.max / 4;
            } else {
                sample = short.min / 4;
            }

            timeValue += 1;
            if (timeValue >= functionPeriodLength) {
                timeValue = 0;
            }

            sampleBatch[sampleBatchIndex] = sample;
            sampleBatchIndex += 1;

            if (sampleBatchIndex >= SAMPLE_BATCH_SIZE) {
                _receiver(sampleBatch);
                sampleBatchIndex = 0;
            }
        }

        return cycles;
    }
}
