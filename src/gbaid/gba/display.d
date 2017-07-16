module gbaid.gba.display;

import core.sync.mutex : Mutex;
import core.sync.condition : Condition;

import std.meta : Alias, AliasSeq;
import std.conv : to;
import std.algorithm.comparison : min;
import std.algorithm.mutation : swap;

import gbaid.util;

import gbaid.gba.io;
import gbaid.gba.memory;
import gbaid.gba.dma;
import gbaid.gba.interrupt;
import gbaid.gba.assembly;

public enum uint DISPLAY_WIDTH = 240;
public enum uint DISPLAY_HEIGHT = 160;
public enum size_t CYCLES_PER_FRAME = (DISPLAY_WIDTH + Display.BLANK_LENGTH)
        * (DISPLAY_HEIGHT + Display.BLANK_LENGTH) * Display.CYCLES_PER_DOT;

private struct DisplayControl {
    private byte bgMode = 0;
    private bool frameIndex = 0;
    private bool objMap1D = false;
    private bool forceBlank = false;
    private byte layerEnableFlags = 0;
    private byte windowEnableFlags = 0;
}

private struct DisplayStatus {
    private bool inVBlank = false;
    private bool inHBlank = false;
    private bool vCountMatch = false;
    private bool intVBlankEnabled = false;
    private bool intHBlankEnabled = false;
    private bool intVCounterEnabled = false;
    private ubyte vCountTarget = 0;
    private ubyte vCounter = 0;
}

private struct BackgroundControl  {
    private byte priority = 0;
    private byte tileBase = 0;
    private bool mosaicEnabled = false;
    private bool singlePalette = false;
    private byte mapBase = 0;
    private bool overflowWrapAround = false;
    private byte size = 0;
}

private struct BackgroundOffset {
    private short x = 0;
    private short y = 0;
}

private struct BackgroundTransform {
    private short a = 0;
    private short b = 0;
    private short c = 0;
    private short d = 0;
    private int x = 0;
    private int y = 0;
    private int cx = 0;
    private int cy = 0;
}

private struct WindowSize {
    private ubyte endX = 0;
    private ubyte startX = 0;
    private ubyte endY = 0;
    private ubyte startY = 0;
}

private struct WindowControl {
    private byte layerEnableFlags = 0;
    private bool specialEffectEnabled = false;
}

private struct MosaicSize {
    private byte x = 0;
    private byte y = 0;
}

private struct SpecialEffect {
    private byte firstTargetFlags = 0;
    private byte effectType = 0;
    private byte secondTargetFlags = 0;
}

private struct BlendCoefficients  {
    private byte eva = 0;
    private byte evb = 0;
    private byte evy = 0;
}

public class Display {
    private enum uint BLANK_LENGTH = 68;
    public static enum uint CYCLES_PER_DOT = 4;
    private static enum short TRANSPARENT = cast(short) 0x8000;
    private static enum uint TIMING_WIDTH = DISPLAY_WIDTH + BLANK_LENGTH;
    private static enum uint TIMING_HEIGTH = DISPLAY_HEIGHT + BLANK_LENGTH;
    private IoRegisters* ioRegisters;
    private Palette* palette;
    private Vram* vram;
    private Oam* oam;
    private InterruptHandler interruptHandler;
    private DMAs dmas;
    private FrameSwapper _frameSwapper;
    mixin declareFields!(short[DISPLAY_WIDTH], true, "linePixels", 0, 6);
    private alias objectLinePixels = linePixels!4;
    private alias infoLinePixels = linePixels!5;
    private DisplayControl control;
    private DisplayStatus status;
    mixin declareFields!(BackgroundControl, true, "bgControl", BackgroundControl.init, 4);
    mixin declareFields!(BackgroundOffset, true, "bgOffset", BackgroundOffset.init, 4);
    mixin declareFields!(BackgroundTransform, true, "bgTransform", BackgroundTransform.init, 2);
    mixin declareFields!(WindowSize, true, "windowSize", WindowSize.init, 2);
    mixin declareFields!(WindowControl, true, "windowControl", WindowControl.init, 4);
    private alias outWindowCtrl = windowControl!2;
    private alias objWindowCtrl = windowControl!3;
    private MosaicSize bgMosaicSize;
    private MosaicSize objMosaicSize;
    private SpecialEffect specialEffect;
    private BlendCoefficients blendCoefficients;
    private int line = 0;
    private int dot = 0;

    public this(IoRegisters* ioRegisters, Palette* palette, Vram* vram, Oam* oam,
            InterruptHandler interruptHandler, DMAs dmas) {
        this.ioRegisters = ioRegisters;
        this.palette = palette;
        this.vram = vram;
        this.oam = oam;
        this.interruptHandler = interruptHandler;
        this.dmas = dmas;

        _frameSwapper = new FrameSwapper();

        ioRegisters.mapAddress(0x0, &control.bgMode, 0b111, 0);
        ioRegisters.mapAddress(0x0, &control.frameIndex, 0b1, 4);
        ioRegisters.mapAddress(0x0, &control.objMap1D, 0b1, 6);
        ioRegisters.mapAddress(0x0, &control.forceBlank, 0b1, 7);
        ioRegisters.mapAddress(0x0, &control.layerEnableFlags, 0x1F, 8);
        ioRegisters.mapAddress(0x0, &control.windowEnableFlags, 0b111, 13);

        ioRegisters.mapAddress(0x4, &status.inVBlank, 0b1, 0, true, false);
        ioRegisters.mapAddress(0x4, &status.inHBlank, 0b1, 1, true, false);
        ioRegisters.mapAddress(0x4, &status.vCountMatch, 0b1, 2, true, false);
        ioRegisters.mapAddress(0x4, &status.intVBlankEnabled, 0b1, 3);
        ioRegisters.mapAddress(0x4, &status.intHBlankEnabled, 0b1, 4);
        ioRegisters.mapAddress(0x4, &status.intVCounterEnabled, 0b1, 5);
        ioRegisters.mapAddress(0x4, &status.vCountTarget, 0xFF, 8);
        ioRegisters.mapAddress(0x4, &status.vCounter, 0xFF, 16, true, false);

        foreach (i; AliasSeq!(0, 1, 2, 3)) {
            enum address = (i / 2) * 4 + 0x8;
            enum shift = (i % 2) * 16;
            ioRegisters.mapAddress(address, &bgControl!i.priority, 0b11, shift);
            ioRegisters.mapAddress(address, &bgControl!i.tileBase, 0b11, shift + 2);
            ioRegisters.mapAddress(address, &bgControl!i.mosaicEnabled, 0b1, shift + 6);
            ioRegisters.mapAddress(address, &bgControl!i.singlePalette, 0b1, shift + 7);
            ioRegisters.mapAddress(address, &bgControl!i.mapBase, 0x1F, shift + 8);
            ioRegisters.mapAddress(address, &bgControl!i.overflowWrapAround, 0b1, shift + 13);
            ioRegisters.mapAddress(address, &bgControl!i.size, 0b11, shift + 14);
        }

        foreach (i; AliasSeq!(0, 1, 2, 3)) {
            enum address = i * 4 + 0x10;
            ioRegisters.mapAddress(address, &bgOffset!i.x, 0x1FF, 0, false, true);
            ioRegisters.mapAddress(address, &bgOffset!i.y, 0x1FF, 16, false, true);
        }

        foreach (i; AliasSeq!(0, 1)) {
            enum address = i * 16 + 0x20;
            ioRegisters.mapAddress(address, &bgTransform!i.a, 0xFFFF, 0, false, true);
            ioRegisters.mapAddress(address, &bgTransform!i.b, 0xFFFF, 16, false, true);
            ioRegisters.mapAddress(address + 0x4, &bgTransform!i.c, 0xFFFF, 0, false, true);
            ioRegisters.mapAddress(address + 0x4, &bgTransform!i.d, 0xFFFF, 16, false, true);
            ioRegisters.mapAddress(address + 0x8, &bgTransform!i.x, 0xFFFFFFF, 0, false, true)
                    .preWriteMonitor(&onAffineReferencePointPreWrite!(i, false));
            ioRegisters.mapAddress(address + 0xC, &bgTransform!i.y, 0xFFFFFFF, 0, false, true)
                    .preWriteMonitor(&onAffineReferencePointPreWrite!(i, true));
        }

        ioRegisters.mapAddress(0x40, &windowSize!0.endX, 0xFF, 0, false, true);
        ioRegisters.mapAddress(0x40, &windowSize!0.startX, 0xFF, 8, false, true);
        ioRegisters.mapAddress(0x40, &windowSize!1.endX, 0xFF, 16, false, true);
        ioRegisters.mapAddress(0x40, &windowSize!1.startX, 0xFF, 24, false, true);
        ioRegisters.mapAddress(0x44, &windowSize!0.endY, 0xFF, 0, false, true);
        ioRegisters.mapAddress(0x44, &windowSize!0.startY, 0xFF, 8, false, true);
        ioRegisters.mapAddress(0x44, &windowSize!1.endY, 0xFF, 16, false, true);
        ioRegisters.mapAddress(0x44, &windowSize!1.startY, 0xFF, 24, false, true);

        foreach (i; AliasSeq!(0, 1, 2, 3)) {
            enum shift = i * 8;
            ioRegisters.mapAddress(0x48, &windowControl!i.layerEnableFlags, 0x1F, shift);
            ioRegisters.mapAddress(0x48, &windowControl!i.specialEffectEnabled, 0b1, shift + 5);
        }

        ioRegisters.mapAddress(0x4C, &bgMosaicSize.x, 0xF, 0, false, true);
        ioRegisters.mapAddress(0x4C, &bgMosaicSize.y, 0xF, 4, false, true);
        ioRegisters.mapAddress(0x4C, &objMosaicSize.x, 0xF, 8, false, true);
        ioRegisters.mapAddress(0x4C, &objMosaicSize.y, 0xF, 12, false, true);

        ioRegisters.mapAddress(0x50, &specialEffect.firstTargetFlags, 0x3F, 0);
        ioRegisters.mapAddress(0x50, &specialEffect.effectType, 0b11, 6);
        ioRegisters.mapAddress(0x50, &specialEffect.secondTargetFlags, 0x3F, 8);
        ioRegisters.mapAddress(0x50, &blendCoefficients.eva, 0x1F, 16, false, true);
        ioRegisters.mapAddress(0x50, &blendCoefficients.evb, 0x1F, 24, false, true);
        ioRegisters.mapAddress(0x54, &blendCoefficients.evy, 0x1F, 0, false, true);
    }

    private bool onAffineReferencePointPreWrite(int affineLayer, bool y)(int mask, ref int value) {
        alias referencePoint(bool y) = Alias!("bgTransform!affineLayer.c" ~ (y ? "y" : "x"));
        // Update the internal reference point
        mixin(referencePoint!y) = mixin(referencePoint!y) & ~mask | value;
        // Sign extend it
        mixin(referencePoint!y) = (mixin(referencePoint!y) << 4) >> 4;
        return true;
    }

    @property public FrameSwapper frameSwapper() {
        return _frameSwapper;
    }

    public size_t emulate(size_t cycles) {
        // Use up 4 cycles per dot
        while (cycles >= CYCLES_PER_DOT) {
            // Take the cycles
            cycles -= CYCLES_PER_DOT;
            // Do stuff for the first visible dot and first blanked dot
            if (dot == 0) {
                // Run the events for a line starting to be drawn
                startLineDrawEvents(line);
                // Draw the line if it is visible
                if (line < DISPLAY_HEIGHT) {
                    drawLine(line);
                }
            } else if (dot == DISPLAY_WIDTH) {
                // Swap out the frame if we are done drawing it
                if (line == DISPLAY_HEIGHT - 1) {
                    _frameSwapper.swapFrame();
                }
                // Run the events for a line drawing ending
                endLineDrawEvents(line);
            }
            // Increment the dot and line counts
            if (dot == TIMING_WIDTH - 1) {
                // Reset the dot count if it is the last one
                dot = 0;
                // Increment the line count
                if (line == TIMING_HEIGTH - 1) {
                    // Reset the line count back to zero if we reach the end
                    line = 0;
                } else {
                    // Else just increment the line count
                    line++;
                }
            } else {
                // If not the last, just increment it
                dot++;
            }
        }
        return cycles;
    }

    private void drawLine(int line) {
        // If blanking is forced then we only draw a white line
        if (control.forceBlank) {
            lineBlank(line);
            return;
        }
        // Otherwise we start by drawing the background layers, which depend on the mode
        switch (control.bgMode) {
            case 0:
                layerBackgroundText!0(line);
                layerBackgroundText!1(line);
                layerBackgroundText!2(line);
                layerBackgroundText!3(line);
                break;
            case 1:
                layerBackgroundText!0(line);
                layerBackgroundText!1(line);
                layerBackgroundAffine!2(line);
                layerTransparent!3();
                break;
            case 2:
                layerTransparent!0();
                layerTransparent!1();
                layerBackgroundAffine!2(line);
                layerBackgroundAffine!3(line);
                break;
            case 3:
                layerTransparent!0();
                layerTransparent!1();
                lineBackgroundBitmap!("16Single", 2)(line);
                layerTransparent!3();
                break;
            case 4:
                layerTransparent!0();
                layerTransparent!1();
                lineBackgroundBitmap!("8Double", 2)(line);
                layerTransparent!3();
                break;
            case 5:
                layerTransparent!0();
                layerTransparent!1();
                lineBackgroundBitmap!("16Double", 2)(line);
                layerTransparent!3();
                break;
            default:
                break;
        }
        // We always draw the object layer
        layerObjects(line);
        // Finally we compose all the layers into the drawn line
        layerCompose(line);
    }

    private void lineBlank(int line) {
        // When blanking we just fill the line with white
        auto frame = _frameSwapper.workFrame;
        auto p = line * DISPLAY_WIDTH;
        frame[p .. p +  DISPLAY_WIDTH] = cast(short) 0xFFFF;
    }

    private void layerTransparent(int layer)() {
        // Bit 16 of a dots's color data is unused in the GBA, but we'll use it for transparency
        linePixels!layer[] = TRANSPARENT;
    }

    private void layerBackgroundText(int layer)(int line) {
        // Draw a transparent line if the layer is not enabled
        if (!control.layerEnableFlags.checkBit(layer)) {
            layerTransparent!layer();
            return;
        }
        // Tile palette data is 4 bit when using 16 palettes, or 8 bit when just using 1
        // We also calculate a shift so that: 1 << tileSizeShift = sizeOfTile = (8 * 8 * paletteDataSize)
        int tile4Bit = bgControl!layer.singlePalette ? 0 : 1;
        int tileSizeShift = 6 - tile4Bit;
        // In text mode, the screen size is 256 or 512 in each dimension (1 or 2 maps in each dimension)
        // Here we get this size as a bit mask (writable as 2^n - 1)
        int totalWidth = (256 << (bgControl!layer.size & 0b1)) - 1;
        int totalHeight = (256 << ((bgControl!layer.size & 0b10) >> 1)) - 1;
        // To get the tile y coordinate, we add the offet and apply the height mask (to wrap around)
        int y = (line + bgOffset!layer.y) & totalHeight;
        // If y is outside the first vertical tile map, we address into the second one instead
        int mapBase = bgControl!layer.mapBase << 11;
        if (y & ~255) {
            // Restrict y to the map size
            y &= 255;
            // if the width is also of two maps, then we address past the second horizontal map too
            mapBase += BYTES_PER_KIB << (totalWidth & ~255 ? 2 : 1);
        }
        // If the mosaic is enabled, then we round down to the next mosaic multiple
        if (bgControl!layer.mosaicEnabled) {
            y -= y % (bgMosaicSize.y + 1);
        }
        // Now we calculate the map line (row of tiles in a map), and the tile line (row of dots in a tile)
        int mapLine = y >> 3;
        int tileLine = y & 7;
        // Every row of tiles in a map has 32 of them, so we get the linear offset into the map by doing mapLine * 32
        int lineMapOffset = mapLine << 5;
        // The tile base is the start address for the tile data, it's in increments of 16KB
        int tileBase = bgControl!layer.tileBase << 14;
        // Use the optimized ASM implementation of the line drawing code if available
        static if (__traits(compiles, LINE_BACKGROUND_TEXT_ASM)) {
            // Place data used by the ASM on the stack
            int xOffset = bgOffset!layer.x;
            int singlePalette = bgControl!layer.singlePalette;
            int mosaicEnabled = bgControl!layer.mosaicEnabled;
            int mosaicSizeX = bgMosaicSize.x;
            // Also place the addresses for the memory
            auto lineAddress = cast(size_t) linePixels!layer.ptr;
            auto vramAddress = cast(size_t) vram.getPointer!byte(0x0);
            auto paletteAddress = cast(size_t) palette.getPointer!byte(0x0);
            mixin (LINE_BACKGROUND_TEXT_ASM);
        } else {
            foreach (column; 0 .. DISPLAY_WIDTH) {
                // For every column, we get the base x coordinate like we did for the y
                int x = (column + bgOffset!layer.x) & totalWidth;
                // Again, we address into the second horizontal map the if x is outside the first
                int map = mapBase;
                if (x & ~255) {
                    x &= 255;
                    map += BYTES_PER_KIB << 1;
                }
                // If the mosaic is enabled, then we round down to the next mosaic multiple
                if (bgControl!layer.mosaicEnabled) {
                    x -= x % (bgMosaicSize.x + 1);
                }
                // We calculate the map and tile columns just like we did for the y
                int mapColumn = x >> 3;
                int tileColumn = x & 7;
                // Now we can calculate address into the map: we add the line offset to the column,
                // multiply them by two because each tile is 2 bytes, then add the map base address
                int mapAddress = map + (lineMapOffset + mapColumn << 1);
                // Then we fetch the tile data from the map
                int tile = vram.get!short(mapAddress);
                // The tile number is taken from the lower bits
                int tileNumber = tile & 0x3FF;
                // The two middle bits are used to flip horizontally and vertically, respectively
                int sampleColumn = void, sampleLine = void;
                if (tile & 0x400) {
                    sampleColumn = ~tileColumn & 7;
                } else {
                    sampleColumn = tileColumn;
                }
                if (tile & 0x800) {
                    sampleLine = ~tileLine & 7;
                } else {
                    sampleLine = tileLine;
                }
                // Now we calculate the address into the tile data: we add the base tile address, tile number * tile size,
                // line into the tile * 8 dots, and the column into the tile (both divided by 2 if 4 bits per dots)
                int tileAddress = tileBase + (tileNumber << tileSizeShift) + ((sampleLine << 3) + sampleColumn >> tile4Bit);
                // By addressing into the tile, we get the palette index, but this depends on the palette mode: 1 or 16
                int paletteAddress = void;
                if (bgControl!layer.singlePalette) {
                    // For a single palette we address directly
                    int paletteIndex = vram.get!byte(tileAddress) & 0xFF;
                    // The first color of the palette is transparent
                    if (paletteIndex == 0) {
                        linePixels!layer[column] = TRANSPARENT;
                        continue;
                    }
                    // Every color is 2 bytes, so me multiply the index by 2
                    paletteAddress = paletteIndex << 1;
                } else {
                    // For multiple palettes we address the byte, then address the low or high nibble (4 bit index)
                    int paletteIndex = vram.get!byte(tileAddress) >> ((sampleColumn & 0b1) << 2) & 0xF;
                    // The first color of the palette is also transparent
                    if (paletteIndex == 0) {
                        linePixels!layer[column] = TRANSPARENT;
                        continue;
                    }
                    // The tile upper bits are the palette number. We multiply by 16 (colors per palette),
                    // then add the index into the palette, and also multiply by 2 because each color takes 2 bytes
                    paletteAddress = (tile >> 8 & 0xF0) + paletteIndex << 1;
                }
                // Finally we have the address into the palette, which yields the color for the layer dot
                short color = palette.get!short(paletteAddress) & 0x7FFF;
                linePixels!layer[column] = color;
            }
        }
    }

    private void layerBackgroundAffine(int layer)(int line) {
        // There are two affine layers, with indices 2 or 3
        enum affineLayer = layer - 2;
        // If the layer isn't enabled, we make it transparent
        if (!control.layerEnableFlags.checkBit(layer)) {
            layerTransparent!layer();
            // We also need to increment the current coordinates by the vertical transformation coefficients
            bgTransform!affineLayer.cx += bgTransform!affineLayer.b;
            bgTransform!affineLayer.cy += bgTransform!affineLayer.d;
            return;
        }
        // We calculate the size of the layer (square) and represent it as a bit mask (2^n -1)
        int bgSize = (128 << bgControl!layer.size) - 1;
        int bgSizeInv = ~bgSize;
        // This shift is an equivalent multiplier for the tile map size (1 << n = tilesPerLine)
        int mapLineShift = bgControl!layer.size + 4;
        // These are the current coordinates of the dots to be sampled in the layer, in fixed 20.8 format
        int cx = bgTransform!affineLayer.cx;
        int cy = bgTransform!affineLayer.cy;
        // We increment the stored values by the vertical coefficients
        bgTransform!affineLayer.cx += bgTransform!affineLayer.b;
        bgTransform!affineLayer.cy += bgTransform!affineLayer.d;
        // These are the horizontal transformation coefficients
        int pa = bgTransform!affineLayer.a;
        int pc = bgTransform!affineLayer.c;
        // The tile base is the start address for the background tile map, it's in increments of 2KB
        int mapBase = bgControl!layer.mapBase << 11;
        // The tile base is the start address for the tile data, it's in increments of 16KB
        int tileBase = bgControl!layer.tileBase << 14;
        // Use the optimized ASM implementation of the line drawing code if available
        static if (__traits(compiles, LINE_BACKGROUND_AFFINE_ASM)) {
            // Place data used by the ASM on the stack
            int overflowWrapAround = bgControl!layer.overflowWrapAround;
            int mosaicEnabled = bgControl!layer.mosaicEnabled;
            int mosaicSizeX = bgMosaicSize.x;
            int mosaicSizeY = bgMosaicSize.y;
            // Also place the addresses for the memory
            auto lineAddress = cast(size_t) linePixels!layer.ptr;
            auto vramAddress = cast(size_t) vram.getPointer!byte(0x0);
            auto paletteAddress = cast(size_t) palette.getPointer!byte(0x0);
            mixin (LINE_BACKGROUND_AFFINE_ASM);
        } else {
            // On every iteration we also increment the coordinates by the transform coefficients
            for (int column = 0; column < DISPLAY_WIDTH; column++, cx += pa, cy += pc) {
                // The coordinates have 8 fractional bits, so we get the integer part by shifting
                int x = cx >> 8;
                int y = cy >> 8;
                // Now we check if the coordinates are outside the layer by using the inverse mask
                if (x & bgSizeInv) {
                    // There are two modes for overflow: wrap around (apply mask) or make it transparent
                    if (bgControl!layer.overflowWrapAround) {
                        x &= bgSize;
                    } else {
                        linePixels!layer[column] = TRANSPARENT;
                        continue;
                    }
                }
                if (y & bgSizeInv) {
                    if (bgControl!layer.overflowWrapAround) {
                        y &= bgSize;
                    } else {
                        linePixels!layer[column] = TRANSPARENT;
                        continue;
                    }
                }
                // If the mosaic mode is enabled, we round the coordinates down to the nearest multiple
                if (bgControl!layer.mosaicEnabled) {
                    x -= x % (bgMosaicSize.x + 1);
                    y -= y % (bgMosaicSize.y + 1);
                }
                // Tiles are 8x8, so dividing the x and y dots coordinates by 8 gives us their coordinates in the map
                int mapColumn = x >> 3;
                int mapLine = y >> 3;
                // Similar idea here, but we use the modulo operation instead to get the coordinates in the tile
                int tileColumn = x & 7;
                int tileLine = y & 7;
                // To calculate the address in the map, we add the base address to line and column offsets
                // The line offset is multiplied by the number of tiles in a map line
                int mapAddress = mapBase + (mapLine << mapLineShift) + mapColumn;
                // Now we can fetch the tile number
                int tileNumber = vram.get!byte(mapAddress) & 0xFF;
                // To calculate the address in the tile data, we add the tile base to the number, line and column offsets
                // The tile number is multiplied by the tile size (64), and the line offset by the tile line size (8)
                int tileAddress = tileBase + (tileNumber << 6) + (tileLine << 3) + tileColumn;
                // By addressing into the tile, we get the palette index, which we multiply by 2 to get the address
                int paletteAddress = (vram.get!byte(tileAddress) & 0xFF) << 1;
                // The first color of the palette is transparent
                if (paletteAddress == 0) {
                    linePixels!layer[column] = TRANSPARENT;
                    continue;
                }
                // Finally we can fetch the dot color from the palette
                short color = palette.get!short(paletteAddress) & 0x7FFF;
                linePixels!layer[column] = color;
            }
        }
    }

    private void lineBackgroundBitmap(string mode, int layer)(int line)
                if (mode == "16Single" || mode == "8Double" || mode == "16Double") {
        // Bitmaps always use the first affine layer properties
        enum affineLayer = 0;
        // If the layer isn't enabled, we make it transparent
        if (!control.layerEnableFlags.checkBit(2)) {
            layerTransparent!layer();
            // We also need to increment the current coordinates by the vertical transformation coefficients
            bgTransform!affineLayer.cx += bgTransform!affineLayer.b;
            bgTransform!affineLayer.cy += bgTransform!affineLayer.d;
            return;
        }
        // These are the current coordinates of the dots to be sampled in the layer, in fixed 20.8 format
        int cx = bgTransform!affineLayer.cx;
        int cy = bgTransform!affineLayer.cy;
        // We increment the stored values by the vertical coefficients
        bgTransform!affineLayer.cx += bgTransform!affineLayer.b;
        bgTransform!affineLayer.cy += bgTransform!affineLayer.d;
        // These are the horizontal transformation coefficients
        int pa = bgTransform!affineLayer.a;
        int pc = bgTransform!affineLayer.c;
        // Calculate the frame base address from the index (not used for 16Single mode)
        int addressBase = control.frameIndex ? 0xA000 : 0x0;
        // On every iteration we also increment the coordinates by the transform coefficients
        for (int column = 0; column < DISPLAY_WIDTH; column++, cx += pa, cy += pc) {
            int x = cx >> 8;
            int y = cy >> 8;
            // The 16Double mode has a smaller layer, others use the display size
            static if (mode == "16Double") {
                enum layerWidth = 160;
                enum layerHeight = 128;
            } else {
                enum layerWidth = DISPLAY_WIDTH;
                enum layerHeight = DISPLAY_HEIGHT;
            }
            // Use transparent on overflow
            if (x < 0 || x >= layerWidth || y < 0 || y >= layerHeight) {
                linePixels!layer[column] = TRANSPARENT;
                continue;
            }
            // If the mosaic mode is enabled, we round the coordinates down to the nearest multiple
            if (bgControl!layer.mosaicEnabled) {
                x -= x % (bgMosaicSize.x + 1);
                y -= y % (bgMosaicSize.y + 1);
            }
            // The dot offet is just the x offset added to y multiplied by the number of dots in a layer line
            int dotOffset = x + y * layerWidth;
            // Both 16 bits modes are direct, but the 8 bit mode indexes the palette
            static if (mode == "16Single" || mode == "16Double") {
                // The dots are 2 bytes wide, so we multiply by 2 to get the color address, then add the frame base
                short color = vram.get!short((dotOffset << 1) + addressBase);
            } else {
                // The dots are only 1 byte wide, so we get the palette index directly
                int paletteIndex = vram.get!byte(dotOffset + addressBase) & 0xFF;
                // The first color of the palette is transparent
                if (paletteIndex == 0) {
                    linePixels!layer[column] = TRANSPARENT;
                    continue;
                }
                // The colors take 2 bytes, so we multiply by 2 to get the palette address
                short color = palette.get!short(paletteIndex << 1);
            }
            // Finally we set the color bits in the layer
            linePixels!layer[column] = color & 0x7FFF;
        }
    }

    private void layerObjects(int line) {
        // Sprites only covert part of the line, so we start by clearing the layer with transparency
        objectLinePixels[] = TRANSPARENT;
        // The info line is the top object priority (0 and 1) and mode bits (2 and 3). Fill with the lowest priority
        infoLinePixels[] = 0b11;
        // Skip if objects aren't enabled
        if (!control.layerEnableFlags.checkBit(4)) {
            return;
        }
        // Objects start a higher address with bitmaped display modes
        int tileBase = 0x10000;
        if (control.bgMode >= 3) {
            tileBase += 0x4000;
        }
        // Higher index objects have lower priority, and we traverse in increasing priority
        foreach_reverse (i; 0 .. 128) {
            // Attributes are 8 bytes long (6 used, 2 for padding), and consecutive in memory
            int attributeAddress = i << 3;
            int attribute0 = oam.get!short(attributeAddress);
            // Get the flag that controls if rotation and scale is enabled
            int rotAndScale = attribute0.getBit(8);
            // The function of this bit depends on the previous one
            int doubleSize = attribute0.getBit(9);
            // If rotation and scale is not enabled, it is used to disable the object
            if (!rotAndScale) {
                if (doubleSize) {
                    continue;
                }
            }
            // The shape bits decide if the object is square or rectangular (vertical or horizontal)
            int shape = attribute0.getBits(14, 15);
            // Next we get the second attribute and the size parameter
            int attribute1 = oam.get!short(attributeAddress + 2);
            int size = attribute1.getBits(14, 15);
            // We'll calculate the final dimensions, and a multiplier shift: horizontalSize = 2 ^^ (mapYShift + 3)
            int horizontalSize = void, verticalSize = void, mapYShift = void;
            if (shape == 0) {
                // For a square it simple: sizes grow by a factor of 2 on all dimensions
                horizontalSize = 8 << size;
                verticalSize = horizontalSize;
                mapYShift = size;
            } else {
                // For a rectangle, we assume it is a horizontal one
                int mapXShift = void;
                final switch (size) {
                    case 0:
                        horizontalSize = 16;
                        verticalSize = 8;
                        mapXShift = 0;
                        mapYShift = 1;
                        break;
                    case 1:
                        horizontalSize = 32;
                        verticalSize = 8;
                        mapXShift = 0;
                        mapYShift = 2;
                        break;
                    case 2:
                        horizontalSize = 32;
                        verticalSize = 16;
                        mapXShift = 1;
                        mapYShift = 2;
                        break;
                    case 3:
                        horizontalSize = 64;
                        verticalSize = 32;
                        mapXShift = 2;
                        mapYShift = 3;
                        break;
                }
                // If it is actually vertical, we just have to swap the dimensions
                if (shape == 2) {
                    swap!int(horizontalSize, verticalSize);
                    swap!int(mapXShift, mapYShift);
                }
            }
            // We have two different sizes: the size of the original object, and the one after transformation
            // The sample one is the original size (in memory), the other is the area in which we draw the object
            int sampleHorizontalSize = horizontalSize;
            int sampleVerticalSize = verticalSize;
            // If double size is enabled, we must double the drawn area
            if (doubleSize) {
                horizontalSize <<= 1;
                verticalSize <<= 1;
            }
            // Now we fetch the y coordinate. If it is too large, we subtract the arbitrary 256 value
            int y = attribute0 & 0xFF;
            if (y >= DISPLAY_HEIGHT) {
                y -= 256;
            }
            // We subtract the y coordinate from the line to get the y relative to the object
            int objectY = line - y;
            // If we are outside the area to draw, then the object isn't in this line (skip it)
            if (objectY < 0 || objectY >= verticalSize) {
                continue;
            }
            // Now we calculate masks for the size, which depends on the kind of drawing
            int horizontalSizeMask = void;
            int verticalSizeMask = void;
            if (rotAndScale) {
                // When transformation is enabled, we calculate inverse masks for the original object
                horizontalSizeMask = ~(sampleHorizontalSize - 1);
                verticalSizeMask = ~(sampleVerticalSize - 1);
            } else {
                // When transformation is disabled, we calculate ordinary masks
                horizontalSizeMask = horizontalSize - 1;
                verticalSizeMask = verticalSize - 1;
            }
            // Now we fetch the x coordinate. If it is too large, we subtract the arbitrary 512 value
            int x = attribute1 & 0x1FF;
            if (x >= DISPLAY_WIDTH) {
                x -= 512;
            }
            // If the object is has rotation and scale we fetch the matrix, otherwise it's just a few flip parameters
            int horizontalFlip = void, verticalFlip = void;
            int pa = void, pb = void, pc = void, pd = void;
            if (rotAndScale) {
                horizontalFlip = 0;
                verticalFlip = 0;
                int rotAndScaleParameters = attribute1.getBits(9, 13);
                int parametersAddress = (rotAndScaleParameters << 5) + 0x6;
                pa = oam.get!short(parametersAddress);
                pb = oam.get!short(parametersAddress + 8);
                pc = oam.get!short(parametersAddress + 16);
                pd = oam.get!short(parametersAddress + 24);
            } else {
                horizontalFlip = attribute1.getBit(12);
                verticalFlip = attribute1.getBit(13);
                pa = 0;
                pb = 0;
                pc = 0;
                pd = 0;
            }
            // Finally we get the rest of the attribute data
            int mode = attribute0.getBits(10, 11);
            int mosaic = attribute0.getBit(12);
            int singlePalette = attribute0.getBit(13);
            int attribute2 = oam.get!short(attributeAddress + 4);
            int tileNumber = attribute2 & 0x3FF;
            int priority = attribute2.getBits(10, 11);
            int paletteNumber = attribute2.getBits(12, 15);
            // We're ready to draw the object, one dot at a time
            foreach (objectX; 0 .. horizontalSize) {
                // We calculate the column in the line from the x cooordinate, and skip if outside the line
                int column = objectX + x;
                if (column >= DISPLAY_WIDTH) {
                    continue;
                }
                // We fetch the priority of the previous object, and skip if the current one is lower
                int previousInfo = infoLinePixels[column];
                int previousPriority = previousInfo & 0b11;
                // Lower priority numbers are actually higher priority
                if (priority > previousPriority) {
                    continue;
                }
                // Next we transform the draw coordinates into the sampling coordinates
                int sampleX = objectX, sampleY = objectY;
                if (rotAndScale) {
                    // We offset the draw area to center it, apply the transformation, then offset back
                    int tmpX = sampleX - (horizontalSize >> 1);
                    int tmpY = sampleY - (verticalSize >> 1);
                    sampleX = pa * tmpX + pb * tmpY >> 8;
                    sampleY = pc * tmpX + pd * tmpY >> 8;
                    sampleX += sampleHorizontalSize >> 1;
                    sampleY += sampleVerticalSize >> 1;
                    // We check against the inverted mask for out-of-bounds (skip in that case)
                    if ((sampleX & horizontalSizeMask) || (sampleY & verticalSizeMask)) {
                        continue;
                    }
                } else {
                    // When not using rotation and scale, we only apply flips
                    if (horizontalFlip) {
                        sampleX = ~sampleX & horizontalSizeMask;
                    }
                    if (verticalFlip) {
                        sampleY = ~sampleY & verticalSizeMask;
                    }
                }
                // Now that we have the coordinates to sample in memory, we can apply the mosaic effect
                if (mosaic) {
                    sampleX -= sampleX % (objMosaicSize.x);
                    sampleY -= sampleY % (objMosaicSize.y);
                }
                // We divide the coordinates by 8 to get coordinates of the tile to draw
                int mapX = sampleX >> 3;
                int mapY = sampleY >> 3;
                // We get the divide by 8 remainder to get coordinates of the dots in the tile to draw
                int tileX = sampleX & 7;
                int tileY = sampleY & 7;
                // Now we calculate the tile address, which starts with the number
                int tileAddress = tileNumber;
                // To which we add the tile coordinate offsets, depending on the layout
                if (control.objMap1D) {
                    // For a 1D layout we add: the y offset * the number of tiles in an object line, and the x offset
                    // We then multiply by 2 if we're using a single palette, since that means the tile are 2x size
                    tileAddress += mapX + (mapY << mapYShift) << singlePalette;
                } else {
                    // A 2D layout is similar, but we always have 32 tiles horizontally, regardless of the tile size
                    tileAddress += (mapX << singlePalette) + (mapY << 5);
                }
                // Tiles are at least 32B, so that the base multiplier. For 64B, we multiplied by two earlier
                tileAddress <<= 5;
                // Now we add the offsets into the tile, starting with the base address
                tileAddress += tileBase;
                // Tiles are always 8 dots wide, so that's the y offet multiplier
                // Since multiple palettes use half a byte per dot, we must divide by 2 when in that mode
                tileAddress += tileX + (tileY << 3) >> (1 - singlePalette);
                // Now we can calculate the palette address to get the final dot color
                int paletteAddress = void;
                if (singlePalette) {
                    // For a single palette, we address directly to get the palette index
                    int paletteIndex = vram.get!byte(tileAddress) & 0xFF;
                    // The first palette color is transparent
                    if (paletteIndex == 0) {
                        continue;
                    }
                    // Colors are 2 bytes wide, so we multiply the index by 2
                    paletteAddress = paletteIndex << 1;
                } else {
                    // For multiple palettes we address the byte, then address the low or high nibble (4 bit index)
                    int paletteIndex = vram.get!byte(tileAddress) >> ((tileX & 1) << 2) & 0xF;
                    // The first palette color is transparent
                    if (paletteIndex == 0) {
                        continue;
                    }
                    // We multiply the palette number by 16 (colors per palette), then add the index into the palette,
                    // and also multiply by 2 because each color takes 2 bytes
                    paletteAddress = (paletteNumber << 4) + paletteIndex << 1;
                }
                // We get the color from the palette, which is a different one to the backgrounds, hence the offset
                short color = palette.get!short(0x200 + paletteAddress) & 0x7FFF;
                // The mode for the info flags is the current mode, but we keep the window flag from the object below
                int modeFlags = mode << 2 | previousInfo & 0b1000;
                if (mode == 2) {
                    // In windows mode nothing is drawn, but we must keep the window flag since that will be used later
                    infoLinePixels[column] = cast(short) (modeFlags | previousPriority);
                } else {
                    // Otherwise we update the color, and write the current priority as the top one
                    objectLinePixels[column] = color;
                    infoLinePixels[column] = cast(short) (modeFlags | priority);
                }
            }
        }
    }

    private void layerCompose(int line) {
        short backColor = palette.get!short(0x0) & 0x7FFF;
        // We fill the line in the frame with the composed layer
        auto frame = _frameSwapper.workFrame;
        // Layers are composed into the final line by resolving priorities and applying special effects
        for (int column = 0, p = line * DISPLAY_WIDTH; column < DISPLAY_WIDTH; column++, p++) {
            // From the object info line, we get the object priority and mode
            int objInfo = infoLinePixels[column];
            int objPriority = objInfo & 0b11;
            int objMode = objInfo >> 2;
            // Now we find in which window we are (if any; they could be disabled)
            WindowControl window = void;
            getWindow(objMode, line, column, window);
            // Now we do the actual composition: we find the top most dot color, and the one just below
            // We also need to save the dots' layers and priorities to apply special effects later
            // We start on the backdrop: layer 5, with priority 3, and a constant color
            short firstColor = backColor;
            short secondColor = backColor;
            int firstLayer = 5;
            int secondLayer = 5;
            int firstPriority = 3;
            int secondPriority = 3;
            // Every layer has an assigned priority. Ties for backgrounds are broken by the layer number
            // (lower is higher priority). A tied object layer is higher priority then all backgrounds
            // Now we traverse the layers in the natural order of priorities (the tie breaking order)
            foreach (layer; AliasSeq!(3, 2, 1, 0, 4)) {
                // We skip disabled layers
                if (!window.layerEnableFlags.checkBit(layer)) {
                    continue;
                }
                // We skip transparent colors
                short layerColor = linePixels!layer[column];
                if (layerColor & TRANSPARENT) {
                    continue;
                }
                // We check if this layer has a higher priority (smaller value) than the current one
                // We use <= so that ties will result in the naturally higher priority layer being used
                static if (layer == 4) {
                    int layerPriority = objPriority;
                } else {
                    int layerPriority = bgControl!layer.priority;
                }
                if (layerPriority <= firstPriority) {
                    // The first layer is now the second
                    secondColor = firstColor;
                    secondLayer = firstLayer;
                    secondPriority = firstPriority;
                    // Update the first layer data
                    firstColor = layerColor;
                    firstLayer = layer;
                    firstPriority = layerPriority;
                } else if (layerPriority <= secondPriority) {
                    // If it's not higher than the first, we check the second, and update it in the same way
                    secondColor = layerColor;
                    secondLayer = layer;
                    secondPriority = layerPriority;
                }
            }
            // Now that we have the data for the top two layers, we combine them in to the final dot
            if ((objMode & 0b1) && firstLayer == 4 && specialEffect.secondTargetFlags.checkBit(secondLayer)) {
                // If the object is in alpha-blend mode and on the top layer, and blending is enabled
                // for the second layer, then we must blend the two, regardless of the special effects mode
                firstColor = applyBlendEffect(firstColor, secondColor);
            } else if (window.specialEffectEnabled) {
                // Othwerwise we might apply a special effect
                final switch (specialEffect.effectType) {
                    case 0:
                        // No effect, just use the top color as is
                        break;
                    case 1:
                        // If both layers have blending enabled, then we blend the two
                        if (specialEffect.firstTargetFlags.checkBit(firstLayer)
                                && specialEffect.secondTargetFlags.checkBit(secondLayer)) {
                            firstColor = applyBlendEffect(firstColor, secondColor);
                        }
                        break;
                    case 2:
                        // If the first layer has blending enabled, then we increase its brightness
                        if (specialEffect.firstTargetFlags.checkBit(firstLayer)) {
                            firstColor = applyBrightnessEffect!false(firstColor);
                        }
                        break;
                    case 3:
                        // If the second layer has blending enabled, then we decrease its brightness
                        if (specialEffect.firstTargetFlags.checkBit(firstLayer)) {
                            firstColor = applyBrightnessEffect!true(firstColor);
                        }
                        break;
                }
            }
            // The final color is that of the first layer
            frame[p] = firstColor;
        }
    }

    private void getWindow(int objectMode, int line, int column, ref WindowControl window) {
        // Enable everything if windows are not in use
        if (control.windowEnableFlags == 0) {
            window.layerEnableFlags = 0b11111;
            window.specialEffectEnabled = true;
            return;
        }
        // If any window is enabled, then we check that the dot is inside, using the priority order
        foreach (i; AliasSeq!(0, 1)) {
            if (control.windowEnableFlags.checkBit(i) && insideWindow!i(line, column)) {
                window = windowControl!i;
                return;
            }
        }
        if (control.windowEnableFlags.checkBit(2) && objectMode.checkBit(1)) {
            window = objWindowCtrl;
            return;
        }
        window = outWindowCtrl;
    }

    private bool insideWindow(int i)(int line, int column) {
        // When the bounds are max < min, the window is in [0, max) and [min, size)
        // Start by checking the horizontal bounds
        if (windowSize!i.startX <= windowSize!i.endX) {
            if (column < windowSize!i.startX || column >= windowSize!i.endX) {
                return false;
            }
        } else {
            if (column >= windowSize!i.endX && column < windowSize!i.startX) {
                return false;
            }
        }
        // Then check the vertical bounds
        if (windowSize!i.startY <= windowSize!i.endY) {
            if (line < windowSize!i.startY || line >= windowSize!i.endY) {
                return false;
            }
        } else {
            if (line >= windowSize!i.endY && line < windowSize!i.startY) {
                return false;
            }
        }
        return true;
    }

    private short applyBrightnessEffect(bool decrease)(short color) {
        // Get the individual colour components
        int red = color & 0b11111;
        int green = color.getBits(5, 9);
        int blue = color.getBits(10, 14);
        // Get the scaling factor, which is in 0.4 fixed format
        int evy = min(blendCoefficients.evy, 16);
        // Apply the effect
        static if (decrease) {
            // For decrease, we subtract the rounded percentage from each component
            red -= red * evy + 8 >> 4;
            green -= green * evy + 8 >> 4;
            blue -= blue * evy + 8 >> 4;
        } else {
            // For increase, we add the rounded percentage from the inverse of each component
            red += (31 - red) * evy + 8 >> 4;
            green += (31 - green) * evy + 8 >> 4;
            blue += (31 - blue) * evy + 8 >> 4;
        }
        // Recombine the components into the colour data
        return (blue & 0x1F) << 10 | (green & 0x1F) << 5 | red & 0x1F;
    }

    private short applyBlendEffect(short first, short second) {
        // Get the individual colour components of both colors
        int firstRed = first & 0b11111;
        int firstGreen = first.getBits(5, 9);
        int firstBlue = first.getBits(10, 14);
        int secondRed = second & 0b11111;
        int secondGreen = second.getBits(5, 9);
        int secondBlue = second.getBits(10, 14);
        // Get the blending coefficients for both colors, which are in 0.4 fixed format
        int eva = min(blendCoefficients.eva, 16);
        int evb = min(blendCoefficients.evb, 16);
        // Get the fraction from each component of each colour
        firstRed = firstRed * eva + 8 >> 4;
        firstGreen = firstGreen * eva + 8 >> 4;
        firstBlue = firstBlue * eva + 8 >> 4;
        secondRed = secondRed * evb + 8 >> 4;
        secondGreen = secondGreen * evb + 8 >> 4;
        secondBlue = secondBlue * evb + 8 >> 4;
        // Add the fractions and clamp to 31 (max component value)
        int blendRed = min(31, firstRed + secondRed);
        int blendGreen = min(31, firstGreen + secondGreen);
        int blendBlue = min(31, firstBlue + secondBlue);
        // Recombine the components into the colour data
        return (blendBlue & 0x1F) << 10 | (blendGreen & 0x1F) << 5 | blendRed & 0x1F;
    }

    private void endLineDrawEvents(int line) {
        // Set the HBLANK flag in the display status
        status.inHBlank = true;
        // Run the DMAs if within the visible vertical lines
        if (line < DISPLAY_HEIGHT) {
            dmas.signalHBLANK();
        }
        // Trigger the HBLANK interrupt if enabled
        if (status.intHBlankEnabled) {
            interruptHandler.requestInterrupt(InterruptSource.LCD_HBLANK);
        }
    }

    private void startLineDrawEvents(int line) {
        // Clear the HBLANK bit in the display status
        status.inHBlank = false;
        // Update the VCOUNT register
        status.vCounter = cast(ubyte) line;
        // Update the VMATCH bit in the display status
        status.vCountMatch = status.vCounter == status.vCountTarget;
        // Trigger the VMATCH interrupt if enabled
        if (status.vCountMatch && status.intVCounterEnabled) {
            interruptHandler.requestInterrupt(InterruptSource.LCD_VCOUNTER_MATCH);
        }
        // Check for VBLANK start or end
        switch (line) {
            case DISPLAY_HEIGHT: {
                // Set the VBLANK bit in the display status
                status.inVBlank = true;
                // Signal VBLANK to the DMAs
                dmas.signalVBLANK();
                // Trigger the VBLANK interrupt if enabled
                if (status.intVBlankEnabled) {
                    interruptHandler.requestInterrupt(InterruptSource.LCD_VBLANK);
                }
                break;
            }
            case TIMING_HEIGTH - 1: {
                // Clear the VBLANK bit
                status.inVBlank = false;
                // Reload the transformation data
                foreach (i; AliasSeq!(0, 1)) {
                    bgTransform!i.cx = (bgTransform!i.x << 4) >> 4;
                    bgTransform!i.cy = (bgTransform!i.y << 4) >> 4;
                }
                break;
            }
            default: {
                break;
            }
        }
    }
}

public class FrameSwapper {
    private enum FRAME_SIZE = DISPLAY_WIDTH * DISPLAY_HEIGHT;
    private short[FRAME_SIZE] frame0;
    private short[FRAME_SIZE] frame1;
    private bool workFrameIndex = false;
    private bool newFrameReady = false;
    private Condition frameReadySignal;

    private this() {
        frameReadySignal = new Condition(new Mutex());
    }

    @property private short[] workFrame() {
        if (workFrameIndex) {
            return frame1;
        }
        return frame0;
    }

    public void swapFrame() {
        synchronized (frameReadySignal.mutex) {
            workFrameIndex = !workFrameIndex;
            newFrameReady = true;
            frameReadySignal.notify();
        }
    }

    public short[] nextFrame() {
        synchronized (frameReadySignal.mutex) {
            while (!newFrameReady) {
                frameReadySignal.wait();
            }
            newFrameReady = false;
            if (workFrameIndex) {
                return frame0;
            }
            return frame1;
        }
    }
}
