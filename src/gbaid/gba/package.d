module gbaid.gba;

import core.time : TickDuration;

public import gbaid.gba.system : GameBoyAdvance;
public import gbaid.gba.memory : SaveConfiguration;
public import gbaid.gba.display : DISPLAY_WIDTH, DISPLAY_HEIGHT, CYCLES_PER_FRAME, FrameSwapper;
public import gbaid.gba.sound : CYCLES_PER_AUDIO_SAMPLE, AudioReceiver;

public static const TickDuration FRAME_DURATION;

public static this() {
    enum nsPerCycle = 2.0 ^^ -24 * 1e9;
    FRAME_DURATION = TickDuration.from!"nsecs"(cast(size_t) (CYCLES_PER_FRAME * nsPerCycle));
}
