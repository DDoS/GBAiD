# GBAiD #

GBAiD stands for <strong>G</strong>ame<strong>B</strong>oy <strong>A</strong>dvance
<strong>i</strong>n <strong>D</strong>. I'm starting this project
as an effort to learn the D programing language. The goal of this emulator
is light CPU usage.

## Building ##

First install the [DUB](http://code.dlang.org/download) package manager if you haven't already.
GBAiD is officially built using [LDC](http://wiki.dlang.org/LDC), which should also be installed.  

Then use:

    dub build --build=release --compiler=ldc2

## Running ##

Use:

    dub run --build=release --compiler=ldc2 -- (arguments)

Or get the binary from the bin folder after building and use:

    ./gbaid (arguments)

### Arguments ###

Specify the path to the bios and rom images with

    -b (path to bios) (path to rom)

## Useful information ##

[This](http://problemkaputt.de/gbatek.htm) page for a whole lot of detailed information on the hardware.

[This](http://infocenter.arm.com/help/topic/com.arm.doc.ddi0210c/Cacbgice.html) and
[this](http://infocenter.arm.com/help/topic/com.arm.doc.ddi0210c/I1040101.html) for a list of all instructions
supported by the ARM7TDMI CPU.
