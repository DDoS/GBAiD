module gbaid.gba;

import core.time : TickDuration;

import gbaid.gba.display : CYCLES_PER_FRAME;

public import gbaid.gba.system : GameBoyAdvance;
public import gbaid.gba.memory : SaveConfiguration;
public import gbaid.gba.display : DISPLAY_WIDTH, DISPLAY_HEIGHT;
public import gbaid.gba.sound : AudioReceiver;

public static const TickDuration FRAME_DURATION;

public static this() {
    enum nsPerCycle = 2.0 ^^ -24 * 1e9;
    FRAME_DURATION = TickDuration.from!"nsecs"(cast(size_t) (CYCLES_PER_FRAME * nsPerCycle));
}
