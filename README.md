# GBAiD #

GBAiD stands for <strong>G</strong>ame<strong>B</strong>oy <strong>A</strong>dvance
<strong>i</strong>n <strong>D</strong>. I've started this project
as an effort to learn the D programing language. The goal of this emulator
is light CPU usage.

This emulator is writen mostly in pure D, with some inline x86_64 assembly in the graphics
to help with performance.

I haven't tried compiling it on Windows or Linux yet, only on OS X, but it doesn't use any platform specific
features, so it should work.

## Current state ##

All of the GameBoy's built-in hardware has been implemented, with the exception of sound.

I've tested 4 games so far:
- Super Mario Advance
- Mario kart
- Pokemon Emerald
- Legend of Zelda: a link to the past

Mario Kart exhibits some light graphical glitches due problems with timings in the graphics
(this also affects the world map in LoZ).

Optimization isn't complete, but the emulator works fine at 60FPS on my 2.66GHz dual core i7 (4GB RAM), using
just under 50% CPU. Most of this usage comes from the graphics, which still need optimization.

Pokemon Emerald complains that the save file is corrupted, but that's a lie, it works just fine.

## Building ##

### Dependencies ###

GBAiD uses [SDL2](https://www.libsdl.org/) for input, OpenGL graphics, sound (eventually) and controller support (planned).  
Support for OpenGL 2.0 or greater is also required.

### DUB ###

First install the [DUB](http://code.dlang.org/download) package manager if you haven't already.
GBAiD is officially built using [LDC](http://wiki.dlang.org/LDC), which should also be installed.  

Then use:

    dub build --compiler=ldc2 --build=release

## Running ##

Use:

    dub run --compiler=ldc2 --build=release -- (arguments)

Or get the binary from the bin folder after building and use:

    ./gbaid (arguments)

### Arguments ###

At minimum, you must specify the path to the bios and rom images with

    -b (path to bios) (path to rom)

The following arguments are also recognized:

| Long form   | Short form | Argument               | Usage                                                                        |
|-------------|------------|------------------------|------------------------------------------------------------------------------|
| --bios      | -b         | path to bios           | Specify bios image                                                           |
| --save      | -s         | path to save           | Specify path for loading and saving saves                                    |
| --noload    | -n         | none                   | Don't load the save                                                          |
| --nosave    | -N         | none                   | Don't save the save                                                          |
| --scale     | -r         | scaling factor (float) | Draw the display at "factor" times the original resolution                   |
| --filtering | -f         | LINEAR or NEAREST      | What technique to use to filter the output texture to be drawn to the screen |

Note that these arguments are case sensitive and that bundling is only supported by the noload and nosave switches.

### Saves ###

Saves use a custom format and .sav extension that is not compatible with other emulators. If no save path is specified,
the same path as the ROM is used, but with the .sav extension instead of whatever the ROM image is using. If no save is
found matching either the given or default path, then a new save is created using that path. Saves are overwritten on exit,
unless the --nosave argument is used.

## Useful information ##

[This](http://problemkaputt.de/gbatek.htm) page for a whole lot of detailed information on the hardware.

[This](http://infocenter.arm.com/help/topic/com.arm.doc.ddi0210c/Cacbgice.html) and
[this](http://infocenter.arm.com/help/topic/com.arm.doc.ddi0210c/I1040101.html) for a list of all instructions
supported by the ARM7TDMI CPU.
