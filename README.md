# GBAiD #

GBAiD stands for <strong>G</strong>ame<strong>B</strong>oy <strong>A</strong>dvance
<strong>i</strong>n <strong>D</strong>. I've started this project
as an effort to learn the D programming language.

This emulator is written mostly in pure D, with some inline x86 (32 and 64 bit) assembly in the graphics
to help with performance.

Compiling works on OS X and Windows (and likely on Linux), but due to bugs with DMD, it won't
compile in release mode and linking is broken on Windows.

## Current state ##

All of the GameBoy's built-in hardware has been implemented, with the exception of sound.

I've tested 4 games so far:
- Super Mario Advance
- Mario kart
- Pokemon Emerald
- Legend of Zelda: a link to the past
- Legend of Zelda: Minish Cap
- Doom
- Classic NES Series: Super Mario Bros.

Mario Kart exhibits some light graphical glitches due problems with timings (this also affects the world map in LoZ).

The Classic NES Series games load, but are very glitchy. Considering the anti-emulation features implemented in them,
just the fact that they load is a good thing.

The emulator uses just under 50% CPU on my 2.66GHz dual core i7 (4GB RAM), at 60 FPS.

## Building ##

### Dependencies ###

GBAiD uses [SDL2](https://www.libsdl.org/) for input, OpenGL graphics, sound (eventually) and controller support.  

- SDL 2.0.3 or greater is required
- OpenGL 2.0 or greater is required

### DUB ###

First install the [DUB](http://code.dlang.org/download) package manager if you haven't already.
GBAiD is officially built using [LDC](http://wiki.dlang.org/LDC), which should also be installed.  

Then use:

    dub build --compiler ldc2 --build release

## Running ##

Use:

    dub run --compiler ldc2 --build release -- (arguments)

Or get the binary from the bin folder after building and use:

    ./gbaid (arguments)

### Arguments ###

At minimum, you must specify the path to the bios and rom images with

    -b (path to bios) (path to rom)

The following arguments are also recognized:

| Long form   | Short form | Argument               | Usage                                                                        |
|-------------|------------|------------------------|------------------------------------------------------------------------------|
| --bios      | -b         | Path to bios           | Specify bios image                                                           |
| --save      | -s         | Path to save           | Specify path for loading and saving saves                                    |
| --noload    | -n         | None                   | Don't load the save                                                          |
| --nosave    | -N         | None                   | Don't save the save                                                          |
| --scale     | -r         | Scaling factor (float) | Draw the display at "factor" times the original resolution                   |
| --filtering | -f         | LINEAR or NONE         | What technique to use to filter the output texture to be drawn to the screen |
| --upscaling | -u         | EPX, XBR or NONE       | What technique to use to increase the resolution of the drawn texture        |
| --controller| -c         | None                   | Disable keyboard input and use a controller instead                          |
| --memory    | -m         | See saves section      | What memory configuration to use for the save format                         |

Note that these arguments are case sensitive and that bundling is only supported by the noload and nosave switches.

### Saves ###

Saves use a custom format and .gsf extension that is not compatible with other emulators. If no save path is specified,
the same path as the ROM is used, but with the .gsf extension instead of whatever the ROM image is using. If no save is
found matching either the given or default path, then a new save is created using that path. Saves are overwritten on exit,
unless the --nosave argument is used.

The emulator can almost always auto-detect the save type, but for some games, such as the Classic NES Series, this will not work.
Instead, the --memory flag should be used, with one of the arguments from below.

| Argument         | Description                     |
|------------------|---------------------------------|
| SRAM             | 64K of static RAM               |
| SRAM_EEPROM      | 64K of static RAM and an EEPROM |
| FLASH64K         | 64K of Flash                    |
| FLASH64K_EEPROM  | 64K of Flash and an EEPROM      |
| FLASH128K        | 128K of Flash                   |
| FLASH128K_EEPROM | 128K of Flash and an EEPROM     |
| EEPROM           | Only an EEPROM                  |
| AUTO             | Auto-detect, default            |

For Classic NES Series games, use EEPROM

These flags are only needed when creating a new save, after that the format is saved in the save file.

### Controls ###

These will be re-mapable soon.

| Gamepad | Keyboard | Controller       |
|---------|----------|------------------|
| A       | P        | A                |
| B       | O        | B                |
| Up      | W        | D-pad or L-stick |
| Down    | S        | D-pad or L-stick |
| Right   | D        | D-pad or L-stick |
| Left    | A        | D-pad or L-stick |
| R       | E        | RB or RT         |
| L       | Q        | LB or LT         |
| Start   | Enter    | Start            |
| Select  | Tab      | Select           |

### Upscaling ###

All upscaling is implemented as OpenGL shaders. EPX is a simple but fast 2x upscaler. XBR is the 5x implementation,
it gives better results, but is slower. When you use the --upscaling switch you should also use the --scale switch
with the appropriate factor for the selected algorithm.

## License ##

GBAiD is licensed under [MIT](LICENSE.txt)

## Useful information ##

[This](http://problemkaputt.de/gbatek.htm) page for a whole lot of detailed information on the hardware.

[This](http://infocenter.arm.com/help/topic/com.arm.doc.ddi0210c/Cacbgice.html) and
[this](http://infocenter.arm.com/help/topic/com.arm.doc.ddi0210c/I1040101.html) for a list of all instructions
supported by the ARM7TDMI CPU.
