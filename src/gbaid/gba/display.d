module gbaid.gba.display;

import core.sync.mutex : Mutex;
import core.sync.condition : Condition;

import std.meta : AliasSeq;
import std.algorithm.comparison : min;
import std.algorithm.mutation : swap;

import gbaid.util;

import gbaid.gba.memory;
import gbaid.gba.dma;
import gbaid.gba.interrupt;
import gbaid.gba.assembly;

public enum uint DISPLAY_WIDTH = 240;
public enum uint DISPLAY_HEIGHT = 160;
public enum size_t CYCLES_PER_FRAME = (DISPLAY_WIDTH + Display.BLANK_LENGTH)
        * (DISPLAY_HEIGHT + Display.BLANK_LENGTH) * Display.CYCLES_PER_DOT;

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
    mixin declareFields!(short[DISPLAY_WIDTH], true, "linePixels", 0, 6);
    private alias objectLinePixels = linePixels!4;
    private alias infoLinePixels = linePixels!5;
    mixin declareFields!(int, true, "internalAffineReferenceX", 0, 2);
    mixin declareFields!(int, true, "internalAffineReferenceY", 0, 2);
    private int line = 0;
    private int dot = 0;
    private FrameSwapper _frameSwapper;

    public this(IoRegisters* ioRegisters, Palette* palette, Vram* vram, Oam* oam,
            InterruptHandler interruptHandler, DMAs dmas) {
        this.ioRegisters = ioRegisters;
        this.palette = palette;
        this.vram = vram;
        this.oam = oam;
        this.interruptHandler = interruptHandler;
        this.dmas = dmas;

        _frameSwapper = new FrameSwapper();

        ioRegisters.setPostWriteMonitor!0x28(&onAffineReferencePointPostWrite!(2, false));
        ioRegisters.setPostWriteMonitor!0x2C(&onAffineReferencePointPostWrite!(2, true));
        ioRegisters.setPostWriteMonitor!0x38(&onAffineReferencePointPostWrite!(3, false));
        ioRegisters.setPostWriteMonitor!0x3C(&onAffineReferencePointPostWrite!(3, true));
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
        int displayControl = ioRegisters.getUnMonitored!short(0x0);
        // If the blanking bit is set then we only draw a white line
        if (displayControl.checkBit(7)) {
            lineBlank(line);
            return;
        }
        // Otherwise we start by drawing the background layers, which depend on the mode
        int displayMode = displayControl & 0b111;
        int bgEnables = displayControl.getBits(8, 12);
        switch (displayMode) {
            case 0:
                layerBackgroundText!0(line, bgEnables);
                layerBackgroundText!1(line, bgEnables);
                layerBackgroundText!2(line, bgEnables);
                layerBackgroundText!3(line, bgEnables);
                break;
            case 1:
                layerBackgroundText!0(line, bgEnables);
                layerBackgroundText!1(line, bgEnables);
                layerBackgroundAffine!2(line, bgEnables);
                layerTransparent!3();
                break;
            case 2:
                layerTransparent!0();
                layerTransparent!1();
                layerBackgroundAffine!2(line, bgEnables);
                layerBackgroundAffine!3(line, bgEnables);
                break;
            case 3:
                layerTransparent!0();
                layerTransparent!1();
                lineBackgroundBitmap16Single!2(line, bgEnables);
                layerTransparent!3();
                break;
            case 4:
                int frameIndex = displayControl.getBit(4);
                layerTransparent!0();
                layerTransparent!1();
                lineBackgroundBitmap8Double!2(line, bgEnables, frameIndex);
                layerTransparent!3();
                break;
            case 5:
                int frameIndex = displayControl.getBit(4);
                layerTransparent!0();
                layerTransparent!1();
                lineBackgroundBitmap16Double!2(line, bgEnables, frameIndex);
                layerTransparent!3();
                break;
            default:
                break;
        }
        // We always draw the object layer
        int tileMapping = displayControl.getBit(6);
        layerObjects(line, bgEnables, displayMode, tileMapping);
        // Finally we compose all the layers into the drawn line
        int windowEnables = displayControl.getBits(13, 15);
        int blendControl = ioRegisters.getUnMonitored!short(0x50);
        short backColor = palette.get!short(0x0) & 0x7FFF;
        layerCompose(line, windowEnables, blendControl, backColor);
    }

    private void lineBlank(int line) {
        // When blanking we just fill the line with white
        auto frame = _frameSwapper.workFrame;
        auto p = line * DISPLAY_WIDTH;
        frame[p .. p +  DISPLAY_WIDTH] = cast(short) 0xFFFF;
    }

    private void layerTransparent(int layer)() {
        // Bit 16 of a pixel's color data is unused in the GBA, but we'll use it for transparency
        linePixels!layer[] = TRANSPARENT;
    }

    private void layerBackgroundText(int layer)(int line, int bgEnables) {
        // Draw a transparent line if the layer is not enabled
        if (!bgEnables.checkBit(layer)) {
            layerTransparent!layer();
            return;
        }
        // Otherwise we fetch the background control register for the layer
        enum bgControlAddress = 0x8 + (layer << 1);
        int bgControl = ioRegisters.getUnMonitored!short(bgControlAddress);
        // From it we get the settings
        int tileBase = bgControl.getBits(2, 3) << 14;
        int mosaic = bgControl.getBit(6);
        int singlePalette = bgControl.getBit(7);
        int mapBase = bgControl.getBits(8, 12) << 11;
        int screenSize = bgControl.getBits(14, 15);
        // We also need the mosaic control
        int mosaicControl = ioRegisters.getUnMonitored!int(0x4C);
        int mosaicSizeX = (mosaicControl & 0b1111) + 1;
        int mosaicSizeY = mosaicControl.getBits(4, 7) + 1;
        // Tile palette data is 4 bit when using 16 palettes, or 8 bit when just using 1
        // We also calculate a shift so that: 1 << tileSizeShift = sizeOfTile = (8 * 8 * paletteDataSize)
        int tile4Bit = singlePalette ? 0 : 1;
        int tileSizeShift = 6 - tile4Bit;
        // In text mode, the screen size is 256 or 512 in each dimension (1 or 2 maps in each dimension)
        // Here we get this size as a bit mask (writable as 2^n - 1)
        int totalWidth = (256 << (screenSize & 0b1)) - 1;
        int totalHeight = (256 << ((screenSize & 0b10) >> 1)) - 1;
        // Finally we need the offset values for scrolling the backgroung
        enum layerAddressOffset = layer << 2;
        int xOffset = ioRegisters.getUnMonitored!short(0x10 + layerAddressOffset) & 0x1FF;
        int yOffset = ioRegisters.getUnMonitored!short(0x12 + layerAddressOffset) & 0x1FF;
        // To get the tile y coordinate, we add the offet and apply the height mask (to wrap around)
        int y = (line + yOffset) & totalHeight;
        // If y is outside the first vertical tile map, we address into the second one instead
        if (y & ~255) {
            // Restrict y to the map size
            y &= 255;
            // if the width is also of two maps, then we address past the second horizontal map too
            mapBase += BYTES_PER_KIB << (totalWidth & ~255 ? 2 : 1);
        }
        // If the mosaic is enabled, then we round down to the next mosaic multiple
        if (mosaic) {
            y -= y % mosaicSizeY;
        }
        // Now we calculate the map line (row of tiles in a map), and the tile line (row of pixels in a tile)
        int mapLine = y >> 3;
        int tileLine = y & 7;
        // Every row of tiles in a map has 32 of them, so we get the linear offset into the map by doing mapLine * 32
        int lineMapOffset = mapLine << 5;
        // Use the optimized ASM implementation of the line drawing code if available
        static if (__traits(compiles, LINE_BACKGROUND_TEXT_ASM)) {
            size_t lineAddress = cast(size_t) linePixels!layer.ptr;
            size_t vramAddress = cast(size_t) vram.getPointer!byte(0x0);
            size_t paletteAddress = cast(size_t) palette.getPointer!byte(0x0);
            mixin (LINE_BACKGROUND_TEXT_ASM);
        } else {
            foreach (column; 0 .. DISPLAY_WIDTH) {
                // For every column, we get the base x coordinate like we did for the y
                int x = (column + xOffset) & totalWidth;
                // Again, we address into the second horizontal map the if x is outside the first
                int map = mapBase;
                if (x & ~255) {
                    x &= 255;
                    map += BYTES_PER_KIB << 1;
                }
                // If the mosaic is enabled, then we round down to the next mosaic multiple
                if (mosaic) {
                    x -= x % mosaicSizeX;
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
                // Now we calculate the address into the tile: we add the base tile address, tile number * tile size,
                // line into the tile * 8 pixels, and the column into the tile (both divided by 2 if 4 bits per pixel)
                int tileAddress = tileBase + (tileNumber << tileSizeShift)
                        + ((sampleLine << 3) + sampleColumn >> tile4Bit);
                // By addressing into the tile, we get the palette index, but this depends on the palette mode: 1 or 16
                int paletteAddress = void;
                if (singlePalette) {
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

    private void layerBackgroundAffine(int layer)(int line, int bgEnables) {
        enum affineLayer = layer - 2;
        enum layerAddressOffset = affineLayer << 4;

        if (!bgEnables.checkBit(layer)) {
            layerTransparent!layer();

            int pb = ioRegisters.getUnMonitored!short(0x22 + layerAddressOffset);
            int pd = ioRegisters.getUnMonitored!short(0x26 + layerAddressOffset);
            internalAffineReferenceX!affineLayer += pb;
            internalAffineReferenceY!affineLayer += pd;
            return;
        }

        int bgControlAddress = 0x8 + (layer << 1);
        int bgControl = ioRegisters.getUnMonitored!short(bgControlAddress);

        int tileBase = bgControl.getBits(2, 3) << 14;
        int mosaic = bgControl.getBit(6);
        int mapBase = bgControl.getBits(8, 12) << 11;
        int displayOverflow = bgControl.getBit(13);
        int screenSize = bgControl.getBits(14, 15);

        int mosaicControl = ioRegisters.getUnMonitored!int(0x4C);
        int mosaicSizeX = (mosaicControl & 0b1111) + 1;
        int mosaicSizeY = mosaicControl.getBits(4, 7) + 1;

        int bgSize = (128 << screenSize) - 1;
        int bgSizeInv = ~bgSize;
        int mapLineShift = screenSize + 4;

        int pa = ioRegisters.getUnMonitored!short(0x20 + layerAddressOffset);
        int pb = ioRegisters.getUnMonitored!short(0x22 + layerAddressOffset);
        int pc = ioRegisters.getUnMonitored!short(0x24 + layerAddressOffset);
        int pd = ioRegisters.getUnMonitored!short(0x26 + layerAddressOffset);

        int dx = internalAffineReferenceX!affineLayer;
        int dy = internalAffineReferenceY!affineLayer;

        internalAffineReferenceX!affineLayer += pb;
        internalAffineReferenceY!affineLayer += pd;

        static if (__traits(compiles, LINE_BACKGROUND_AFFINE_ASM)) {
            size_t lineAddress = cast(size_t) linePixels!layer.ptr;
            size_t vramAddress = cast(size_t) vram.getPointer!byte(0x0);
            size_t paletteAddress = cast(size_t) palette.getPointer!byte(0x0);

            mixin (LINE_BACKGROUND_AFFINE_ASM);
        } else {
            for (int column = 0; column < DISPLAY_WIDTH; column++, dx += pa, dy += pc) {
                int x = dx >> 8;
                int y = dy >> 8;

                if (x & bgSizeInv) {
                    if (displayOverflow) {
                        x &= bgSize;
                    } else {
                        linePixels!layer[column] = TRANSPARENT;
                        continue;
                    }
                }
                if (y & bgSizeInv) {
                    if (displayOverflow) {
                        y &= bgSize;
                    } else {
                        linePixels!layer[column] = TRANSPARENT;
                        continue;
                    }
                }

                if (mosaic) {
                    x -= x % mosaicSizeX;
                    y -= y % mosaicSizeY;
                }

                int mapColumn = x >> 3;
                int mapLine = y >> 3;

                int tileColumn = x & 7;
                int tileLine = y & 7;

                int mapAddress = mapBase + (mapLine << mapLineShift) + mapColumn;

                int tileNumber = vram.get!byte(mapAddress) & 0xFF;

                int tileAddress = tileBase + (tileNumber << 6) + (tileLine << 3) + tileColumn;

                int paletteAddress = (vram.get!byte(tileAddress) & 0xFF) << 1;

                if (paletteAddress == 0) {
                    linePixels!layer[column] = TRANSPARENT;
                    continue;
                }

                short color = palette.get!short(paletteAddress) & 0x7FFF;

                linePixels!layer[column] = color;
            }
        }
    }

    private void lineBackgroundBitmap16Single(int layer)(int line, int bgEnables) {
        if (!bgEnables.checkBit(2)) {
            layerTransparent!layer();

            int pb = ioRegisters.getUnMonitored!short(0x22);
            int pd = ioRegisters.getUnMonitored!short(0x26);
            internalAffineReferenceX!0 += pb;
            internalAffineReferenceY!0 += pd;
            return;
        }

        int bgControl = ioRegisters.getUnMonitored!short(0xC);
        int mosaic = bgControl.getBit(6);

        int mosaicControl = ioRegisters.getUnMonitored!int(0x4C);
        int mosaicSizeX = (mosaicControl & 0b1111) + 1;
        int mosaicSizeY = mosaicControl.getBits(4, 7) + 1;

        int pa = ioRegisters.getUnMonitored!short(0x20);
        int pb = ioRegisters.getUnMonitored!short(0x22);
        int pc = ioRegisters.getUnMonitored!short(0x24);
        int pd = ioRegisters.getUnMonitored!short(0x26);

        int dx = internalAffineReferenceX!0;
        int dy = internalAffineReferenceY!0;

        for (int column = 0; column < DISPLAY_WIDTH; column++, dx += pa, dy += pc) {
            int x = dx >> 8;
            int y = dy >> 8;

            if (x < 0 || x >= DISPLAY_WIDTH || y < 0 || y >= DISPLAY_HEIGHT) {
                linePixels!layer[column] = TRANSPARENT;
                continue;
            }

            if (mosaic) {
                x -= x % mosaicSizeX;
                y -= y % mosaicSizeY;
            }

            int address = x + y * DISPLAY_WIDTH << 1;

            short color = vram.get!short(address) & 0x7FFF;
            linePixels!layer[column] = color;
        }

        internalAffineReferenceX!0 += pb;
        internalAffineReferenceY!0 += pd;
    }

    private void lineBackgroundBitmap8Double(int layer)(int line, int bgEnables, int frameIndex) {
        if (!bgEnables.checkBit(2)) {
            layerTransparent!layer();

            int pb = ioRegisters.getUnMonitored!short(0x22);
            int pd = ioRegisters.getUnMonitored!short(0x26);
            internalAffineReferenceX!0 += pb;
            internalAffineReferenceY!0 += pd;
            return;
        }

        int bgControl = ioRegisters.getUnMonitored!short(0xC);
        int mosaic = bgControl.getBit(6);

        int mosaicControl = ioRegisters.getUnMonitored!int(0x4C);
        int mosaicSizeX = (mosaicControl & 0b1111) + 1;
        int mosaicSizeY = mosaicControl.getBits(4, 7) + 1;

        int pa = ioRegisters.getUnMonitored!short(0x20);
        int pb = ioRegisters.getUnMonitored!short(0x22);
        int pc = ioRegisters.getUnMonitored!short(0x24);
        int pd = ioRegisters.getUnMonitored!short(0x26);

        int dx = internalAffineReferenceX!0;
        int dy = internalAffineReferenceY!0;

        int addressBase = frameIndex ? 0xA000 : 0x0;

        for (int column = 0; column < DISPLAY_WIDTH; column++, dx += pa, dy += pc) {
            int x = dx >> 8;
            int y = dy >> 8;

            if (x < 0 || x >= DISPLAY_WIDTH || y < 0 || y >= DISPLAY_HEIGHT) {
                linePixels!layer[column] = TRANSPARENT;
                continue;
            }

            if (mosaic) {
                x -= x % mosaicSizeX;
                y -= y % mosaicSizeY;
            }

            int address = x + y * DISPLAY_WIDTH + addressBase;

            int paletteIndex = vram.get!byte(address) & 0xFF;
            if (paletteIndex == 0) {
                linePixels!layer[column] = TRANSPARENT;
                continue;
            }
            int paletteAddress = paletteIndex << 1;

            short color = palette.get!short(paletteAddress) & 0x7FFF;
            linePixels!layer[column] = color;
        }

        internalAffineReferenceX!0 += pb;
        internalAffineReferenceY!0 += pd;
    }

    private void lineBackgroundBitmap16Double(int layer)(int line, int bgEnables, int frame) {
        if (!bgEnables.checkBit(2)) {
            layerTransparent!layer();

            int pb = ioRegisters.getUnMonitored!short(0x22);
            int pd = ioRegisters.getUnMonitored!short(0x26);
            internalAffineReferenceX!0 += pb;
            internalAffineReferenceY!0 += pd;
            return;
        }

        int bgControl = ioRegisters.getUnMonitored!short(0xC);
        int mosaic = bgControl.getBit(6);

        int mosaicControl = ioRegisters.getUnMonitored!int(0x4C);
        int mosaicSizeX = (mosaicControl & 0b1111) + 1;
        int mosaicSizeY = mosaicControl.getBits(4, 7) + 1;

        int pa = ioRegisters.getUnMonitored!short(0x20);
        int pb = ioRegisters.getUnMonitored!short(0x22);
        int pc = ioRegisters.getUnMonitored!short(0x24);
        int pd = ioRegisters.getUnMonitored!short(0x26);

        int dx = internalAffineReferenceX!0;
        int dy = internalAffineReferenceY!0;

        int addressBase = frame ? 0xA000 : 0x0;

        for (int column = 0; column < DISPLAY_WIDTH; column++, dx += pa, dy += pc) {
            int x = dx >> 8;
            int y = dy >> 8;

            if (x < 0 || x >= 160 || y < 0 || y >= 128) {
                linePixels!layer[column] = TRANSPARENT;
                continue;
            }

            if (mosaic) {
                x -= x % mosaicSizeX;
                y -= y % mosaicSizeY;
            }

            int address = x + y * 160 << 1;

            short color = vram.get!short(address) & 0x7FFF;
            linePixels!layer[column] = color;
        }

        internalAffineReferenceX!0 += pb;
        internalAffineReferenceY!0 += pd;
    }

    private void layerObjects(int line, int bgEnables, int displayMode, int tileMapping) {
        objectLinePixels[] = TRANSPARENT;
        infoLinePixels[] = 0b11;

        if (!bgEnables.checkBit(4)) {
            return;
        }

        int tileBase = 0x10000;
        if (displayMode >= 3) {
            tileBase += 0x4000;
        }

        int mosaicControl = ioRegisters.getUnMonitored!int(0x4C);
        int mosaicSizeX = (mosaicControl & 0b1111) + 1;
        int mosaicSizeY = mosaicControl.getBits(4, 7) + 1;

        foreach_reverse (i; 0 .. 128) {
            int attributeAddress = i << 3;

            int attribute0 = oam.get!short(attributeAddress);
            int rotAndScale = attribute0.getBit(8);
            int doubleSize = attribute0.getBit(9);

            if (!rotAndScale) {
                if (doubleSize) {
                    continue;
                }
            }

            int shape = attribute0.getBits(14, 15);

            int attribute1 = oam.get!short(attributeAddress + 2);
            int size = attribute1.getBits(14, 15);

            int y = attribute0 & 0xFF;
            if (y >= DISPLAY_HEIGHT) {
                y -= 256;
            }

            int horizontalSize = void, verticalSize = void, mapYShift = void;
            if (shape == 0) {
                horizontalSize = 8 << size;
                verticalSize = horizontalSize;
                mapYShift = size;
            } else {
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
                if (shape == 2) {
                    swap!int(horizontalSize, verticalSize);
                    swap!int(mapXShift, mapYShift);
                }
            }

            int sampleHorizontalSize = horizontalSize;
            int sampleVerticalSize = verticalSize;
            if (doubleSize) {
                horizontalSize <<= 1;
                verticalSize <<= 1;
            }

            int objectY = line - y;
            if (objectY < 0 || objectY >= verticalSize) {
                continue;
            }

            int horizontalSizeMask = void;
            int verticalSizeMask = void;
            if (rotAndScale) {
                horizontalSizeMask = ~(sampleHorizontalSize - 1);
                verticalSizeMask = ~(sampleVerticalSize - 1);
            } else {
                horizontalSizeMask = horizontalSize - 1;
                verticalSizeMask = verticalSize - 1;
            }

            int x = attribute1 & 0x1FF;
            if (x >= DISPLAY_WIDTH) {
                x -= 512;
            }

            int mode = attribute0.getBits(10, 11);
            int mosaic = attribute0.getBit(12);
            int singlePalette = attribute0.getBit(13);

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

            int attribute2 = oam.get!short(attributeAddress + 4);
            int tileNumber = attribute2 & 0x3FF;
            int priority = attribute2.getBits(10, 11);
            int paletteNumber = attribute2.getBits(12, 15);

            foreach (objectX; 0 .. horizontalSize) {

                int column = objectX + x;

                if (column >= DISPLAY_WIDTH) {
                    continue;
                }

                int previousInfo = infoLinePixels[column];

                int previousPriority = previousInfo & 0b11;
                if (priority > previousPriority) {
                    continue;
                }

                int sampleX = objectX, sampleY = objectY;

                if (rotAndScale) {
                    int tmpX = sampleX - (horizontalSize >> 1);
                    int tmpY = sampleY - (verticalSize >> 1);
                    sampleX = pa * tmpX + pb * tmpY >> 8;
                    sampleY = pc * tmpX + pd * tmpY >> 8;
                    sampleX += sampleHorizontalSize >> 1;
                    sampleY += sampleVerticalSize >> 1;
                    // this mask is inverted
                    if ((sampleX & horizontalSizeMask) || (sampleY & verticalSizeMask)) {
                        continue;
                    }
                } else {
                    if (horizontalFlip) {
                        sampleX = ~sampleX & horizontalSizeMask;
                    }
                    if (verticalFlip) {
                        sampleY = ~sampleY & verticalSizeMask;
                    }
                }

                if (mosaic) {
                    sampleX -= sampleX % mosaicSizeX;
                    sampleY -= sampleY % mosaicSizeY;
                }

                int mapX = sampleX >> 3;
                int mapY = sampleY >> 3;

                int tileX = sampleX & 7;
                int tileY = sampleY & 7;

                int tileAddress = tileNumber;

                if (tileMapping) {
                    // 1D
                    tileAddress += mapX + (mapY << mapYShift) << singlePalette;
                } else {
                    // 2D
                    tileAddress += (mapX << singlePalette) + (mapY << 5);
                }
                tileAddress <<= 5;

                tileAddress += tileX + (tileY << 3) >> (1 - singlePalette);

                tileAddress += tileBase;

                int paletteAddress = void;
                if (singlePalette) {
                    int paletteIndex = vram.get!byte(tileAddress) & 0xFF;
                    if (paletteIndex == 0) {
                        continue;
                    }
                    paletteAddress = paletteIndex << 1;
                } else {
                    int paletteIndex = vram.get!byte(tileAddress) >> ((tileX & 1) << 2) & 0xF;
                    if (paletteIndex == 0) {
                        continue;
                    }
                    paletteAddress = (paletteNumber << 4) + paletteIndex << 1;
                }

                short color = palette.get!short(0x200 + paletteAddress) & 0x7FFF;

                int modeFlags = mode << 2 | previousInfo & 0b1000;
                if (mode == 2) {
                    infoLinePixels[column] = cast(short) (modeFlags | previousPriority);
                } else {
                    objectLinePixels[column] = color;
                    infoLinePixels[column] = cast(short) (modeFlags | priority);
                }
            }
        }
    }

    private void layerCompose(int line, int windowEnables, int blendControl, short backColor) {
        int colorEffect = blendControl.getBits(6, 7);

        int[5] priorities = [
            ioRegisters.getUnMonitored!short(0x8) & 0b11,
            ioRegisters.getUnMonitored!short(0xA) & 0b11,
            ioRegisters.getUnMonitored!short(0xC) & 0b11,
            ioRegisters.getUnMonitored!short(0xE) & 0b11,
            0
        ];

        auto frame = _frameSwapper.workFrame;
        for (int column = 0, p = line * DISPLAY_WIDTH; column < DISPLAY_WIDTH; column++, p++) {

            int objInfo = infoLinePixels[column];
            int objPriority = objInfo & 0b11;
            int objMode = objInfo >> 2;

            bool specialEffectEnabled = void;
            int layerEnables = void;

            int window = getWindow(windowEnables, objMode, line, column);
            if (window != 0) {
                int windowControl = ioRegisters.getUnMonitored!byte(window);
                layerEnables = windowControl & 0b11111;
                specialEffectEnabled = windowControl.checkBit(5);
            } else {
                layerEnables = 0b11111;
                specialEffectEnabled = true;
            }

            priorities[4] = objPriority;

            short firstColor = backColor;
            short secondColor = backColor;

            int firstLayer = 5;
            int secondLayer = 5;

            int firstPriority = 3;
            int secondPriority = 3;

            foreach (layer; AliasSeq!(3, 2, 1, 0, 4)) {

                if (!layerEnables.checkBit(layer)) {
                    continue;
                }

                short layerColor = linePixels!layer[column];

                if (layerColor & TRANSPARENT) {
                    continue;
                }

                int layerPriority = priorities[layer];

                if (layerPriority <= firstPriority) {

                    secondColor = firstColor;
                    secondLayer = firstLayer;
                    secondPriority = firstPriority;

                    firstColor = layerColor;
                    firstLayer = layer;
                    firstPriority = layerPriority;

                } else if (layerPriority <= secondPriority) {

                    secondColor = layerColor;
                    secondLayer = layer;
                    secondPriority = layerPriority;
                }
            }

            if (firstLayer == 4 && (objMode & 0b1) && blendControl.checkBit(secondLayer + 8)) {
                firstColor = applyBlendEffect(firstColor, secondColor);
            } else if (specialEffectEnabled) {
                final switch (colorEffect) {
                    case 0:
                        break;
                    case 1:
                        if (blendControl.checkBit(firstLayer) && blendControl.checkBit(secondLayer + 8)) {
                            firstColor = applyBlendEffect(firstColor, secondColor);
                        }
                        break;
                    case 2:
                        if (blendControl.checkBit(firstLayer)) {
                            applyBrightnessIncreaseEffect(firstColor);
                        }
                        break;
                    case 3:
                        if (blendControl.checkBit(firstLayer)) {
                            applyBrightnessDecreaseEffect(firstColor);
                        }
                        break;
                }
            }

            frame[p] = firstColor;
        }
    }

    private int getWindow(int windowEnables, int objectMode, int line, int column) {
        if (windowEnables == 0) {
            return 0;
        }
        // If any window is enabled, then we check that the dot is inside, using the priority order
        if (windowEnables.checkBit(0) && insideWindow!0(line, column)) {
            return 0x48;
        }
        if (windowEnables.checkBit(1) && insideWindow!1(line, column)) {
            return 0x49;
        }
        if (windowEnables.checkBit(2) && objectMode.checkBit(1)) {
            return 0x4B;
        }
        return 0x4A;
    }

    private bool insideWindow(int index)(int line, int column) {
        // When the bounds are max < min, the window is in [0, max) and [min, size)
        int horizontalDimensions = ioRegisters.getUnMonitored!short(0x40 + index * 2);
        int x1 = horizontalDimensions.getBits(8, 15);
        int x2 = horizontalDimensions & 0xFF;
        if (x1 <= x2) {
            if (column < x1 || column >= x2) {
                return false;
            }
        } else {
            if (column >= x2 && column < x1) {
                return false;
            }
        }
        int verticalDimensions = ioRegisters.getUnMonitored!short(0x44 + index * 2);
        int y1 = verticalDimensions.getBits(8, 15);
        int y2 = verticalDimensions & 0xFF;
        if (y1 <= y2) {
            if (line < y1 || line >= y2) {
                return false;
            }
        } else {
            if (line >= y2 && line < y1) {
                return false;
            }
        }
        return true;
    }

    private void applyBrightnessIncreaseEffect(ref short first) {
        int firstRed = first & 0b11111;
        int firstGreen = first.getBits(5, 9);
        int firstBlue = first.getBits(10, 14);

        int evy = min(ioRegisters.getUnMonitored!int(0x54) & 0b11111, 16);
        firstRed += (31 - firstRed) * evy + 8 >> 4;
        firstGreen += (31 - firstGreen) * evy + 8 >> 4;
        firstBlue += (31 - firstBlue) * evy + 8 >> 4;

        first = (firstBlue & 31) << 10 | (firstGreen & 31) << 5 | firstRed & 31;
    }

    private void applyBrightnessDecreaseEffect(ref short first) {
        int firstRed = first & 0b11111;
        int firstGreen = first.getBits(5, 9);
        int firstBlue = first.getBits(10, 14);

        int evy = min(ioRegisters.getUnMonitored!int(0x54) & 0b11111, 16);
        firstRed -= firstRed * evy + 8 >> 4;
        firstGreen -= firstGreen * evy + 8 >> 4;
        firstBlue -= firstBlue * evy + 8 >> 4;

        first = (firstBlue & 31) << 10 | (firstGreen & 31) << 5 | firstRed & 31;
    }

    private short applyBlendEffect(short first, short second) {
        int firstRed = first & 0b11111;
        int firstGreen = first.getBits(5, 9);
        int firstBlue = first.getBits(10, 14);

        int secondRed = second & 0b11111;
        int secondGreen = second.getBits(5, 9);
        int secondBlue = second.getBits(10, 14);

        int blendAlpha = ioRegisters.getUnMonitored!short(0x52);

        int eva = min(blendAlpha & 0b11111, 16);
        firstRed = firstRed * eva + 8 >> 4;
        firstGreen = firstGreen * eva + 8 >> 4;
        firstBlue = firstBlue * eva + 8 >> 4;

        int evb = min(blendAlpha.getBits(8, 12), 16);
        secondRed = secondRed * evb + 8 >> 4;
        secondGreen = secondGreen * evb + 8 >> 4;
        secondBlue = secondBlue * evb + 8 >> 4;

        int blendRed = min(31, firstRed + secondRed);
        int blendGreen = min(31, firstGreen + secondGreen);
        int blendBlue = min(31, firstBlue + secondBlue);

        return (blendBlue & 31) << 10 | (blendGreen & 31) << 5 | blendRed & 31;
    }

    private void reloadInternalAffineReferencePoint(int layer)() {
        enum affineLayer = layer - 2;
        int layerAddressOffset = affineLayer << 4;
        int dx = ioRegisters.getUnMonitored!int(0x28 + layerAddressOffset) << 4;
        internalAffineReferenceX!affineLayer = dx >> 4;
        int dy = ioRegisters.getUnMonitored!int(0x2C + layerAddressOffset) << 4;
        internalAffineReferenceY!affineLayer = dy >> 4;
    }

    private void onAffineReferencePointPostWrite(int layer, bool y)
            (IoRegisters* ioRegisters, int address, int shift, int mask, int oldValue, int newValue) {
        enum affineLayer = layer - 2;
        newValue <<= 4;
        newValue >>= 4;
        static if (y) {
            internalAffineReferenceY!affineLayer = newValue;
        } else {
            internalAffineReferenceX!affineLayer = newValue;
        }
    }

    private void endLineDrawEvents(int line) {
        int displayStatus = ioRegisters.getUnMonitored!short(0x4);
        // Set the HBLANK bit in the display status
        displayStatus.setBit(1, true);
        // Run the DMAs if within the visible vertical lines
        if (line < DISPLAY_HEIGHT) {
            dmas.signalHBLANK();
        }
        // Trigger the HBLANK interrupt if enabled
        if (displayStatus.checkBit(4)) {
            interruptHandler.requestInterrupt(InterruptSource.LCD_HBLANK);
        }
        // Write back the modified display status
        ioRegisters.setUnMonitored!short(0x4, cast(short) displayStatus);
    }

    private void startLineDrawEvents(int line) {
        int displayStatus = ioRegisters.getUnMonitored!short(0x4);
        // Clear the HBLANK bit in the display status
        displayStatus.setBit(1, false);
        // Update the VCOUNT register
        ioRegisters.setUnMonitored!byte(0x6, cast(byte) line);
        // Update the VMATCH bit in the display status
        auto vmatch = displayStatus.getBits(8, 15) == line;
        displayStatus.setBit(2, vmatch);
        // Trigger the VMATCH interrupt if enabled
        if (vmatch && displayStatus.checkBit(5)) {
            interruptHandler.requestInterrupt(InterruptSource.LCD_VCOUNTER_MATCH);
        }
        // Check for VBLANK start or end
        switch (line) {
            case DISPLAY_HEIGHT: {
                // Set the VBLANK bit in the display status
                displayStatus.setBit(0, true);
                // Signal VBLANK to the DMAs
                dmas.signalVBLANK();
                // Trigger the VBLANK interrupt if enabled
                if (displayStatus.checkBit(3)) {
                    interruptHandler.requestInterrupt(InterruptSource.LCD_VBLANK);
                }
                break;
            }
            case TIMING_HEIGTH - 1: {
                // Clear the VBLANK bit
                displayStatus.setBit(0, false);
                // Reload the transformation data
                reloadInternalAffineReferencePoint!2();
                reloadInternalAffineReferencePoint!3();
                break;
            }
            default: {
                break;
            }
        }
        // Write back the modified display status
        ioRegisters.setUnMonitored!short(0x4, cast(short) displayStatus);
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
