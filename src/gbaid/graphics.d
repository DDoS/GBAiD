module gbaid.graphics;

import core.thread;
import core.time;
import core.sync.condition;

import std.stdio;
import std.algorithm;

import gbaid.system;
import gbaid.memory;
import gbaid.gl, gbaid.gl20;
import gbaid.util;

private alias GameBoyAdvanceMemory = GameBoyAdvance.GameBoyAdvanceMemory;
private alias InterruptHandler = GameBoyAdvance.InterruptHandler;
private alias InterruptSource = GameBoyAdvance.InterruptSource;
private alias DMAs = GameBoyAdvance.DMAs;

public class GameBoyAdvanceDisplay {
    private alias LineType = void delegate(int);
    private static immutable uint HORIZONTAL_RESOLUTION = 240;
    private static immutable uint VERTICAL_RESOLUTION = 160;
    private static immutable uint LAYER_COUNT = 6;
    private static immutable uint FRAME_SIZE = HORIZONTAL_RESOLUTION * VERTICAL_RESOLUTION;
    private static immutable short TRANSPARENT = cast(short) 0x8000;
    private static immutable uint VERTICAL_TIMING_RESOLUTION = VERTICAL_RESOLUTION + 68;
    private static TickDuration H_VISIBLE_DURATION;
    private static TickDuration H_BLANK_DURATION;
    private static TickDuration TOTAL_DURATION;
    private GameBoyAdvanceMemory memory;
    private InterruptHandler interruptHandler;
    private DMAs dmas;
    private Context context;
    private int width = HORIZONTAL_RESOLUTION, height = VERTICAL_RESOLUTION;
    private UpscalingMode upscalingMode = UpscalingMode.NONE;
    private short[FRAME_SIZE] frame = new short[FRAME_SIZE];
    private short[HORIZONTAL_RESOLUTION][LAYER_COUNT] lines = new short[HORIZONTAL_RESOLUTION][LAYER_COUNT];
    private int[2] internalAffineReferenceX = new int[2];
    private int[2] internalAffineReferenceY = new int[2];
    private Condition frameSync;
    private shared bool drawRunning = false;
    private LineType[7] lineTypes;
    private Timer timer = new Timer();

    static this() {
        H_VISIBLE_DURATION = TickDuration.from!"nsecs"(57221);
        H_BLANK_DURATION = TickDuration.from!"nsecs"(16212);
        TOTAL_DURATION = (H_VISIBLE_DURATION + H_BLANK_DURATION) * VERTICAL_TIMING_RESOLUTION;
    }

    public this(GameBoyAdvanceMemory memory, InterruptHandler interruptHandler, DMAs dmas) {
        this.memory = memory;
        this.interruptHandler = interruptHandler;
        this.dmas = dmas;

        frameSync = new Condition(new Mutex());
        lineTypes = [
            &lineMode0,
            &lineMode1,
            &lineMode2,
            &lineMode3,
            &lineMode4,
            &lineBlank,
            &lineBlank
        ];
        context = new GL20Context();
        context.setWindowTitle("GBAiD");
        context.setResizable(true);

        MonitoredMemory ioRegisters = memory.getIORegisters();
        ioRegisters.addMonitor(&onAffineReferencePointPostWrite, 0x28, 8);
        ioRegisters.addMonitor(&onAffineReferencePointPostWrite, 0x38, 8);
    }

    public void setScale(float scale) {
        width = cast(int) (HORIZONTAL_RESOLUTION * scale + 0.5f);
        height = cast(int) (VERTICAL_RESOLUTION * scale + 0.5f);

        if (context.isCreated()) {
            context.setWindowSize(width, height);
        }
    }

    public void setUpscalingMode(UpscalingMode mode) {
        upscalingMode = mode;
    }

    public void run() {
        Thread.getThis().name = "Display";

        context.setWindowSize(width, height);
        context.create();
        context.enableCapability(CULL_FACE);

        Shader vertexShader = context.newShader();
        vertexShader.create();
        vertexShader.setSource(new ShaderSource(vertexShaderSource, true));
        vertexShader.compile();
        Shader fragmentShader = context.newShader();
        fragmentShader.create();
        fragmentShader.setSource(new ShaderSource(fragmentShaderSource, true));
        fragmentShader.compile();
        Program program = context.newProgram();
        program.create();
        program.attachShader(vertexShader);
        program.attachShader(fragmentShader);
        program.link();
        program.use();
        program.bindSampler(0);

        Texture texture = context.newTexture();
        texture.create();
        texture.setFormat(RGBA, RGB5_A1);
        texture.setWraps(CLAMP_TO_BORDER, CLAMP_TO_BORDER);
        texture.setBorderColor(0, 0, 0, 1);
        final switch (upscalingMode) {
            case UpscalingMode.NONE:
                texture.setFilters(NEAREST, NEAREST);
                break;
            case UpscalingMode.LINEAR:
                texture.setFilters(LINEAR, LINEAR);
                break;
        }

        VertexArray vertexArray = context.newVertexArray();
        vertexArray.create();
        vertexArray.setData(generatePlane(2, 2));

        Thread drawThread = new Thread(&drawRun);
        drawThread.name = "Draw";
        drawRunning = true;
        drawThread.start();

        //Timer fpsTimer = new Timer();
        while (!context.isWindowCloseRequested()) {
            //fpsTimer.start();
            synchronized (frameSync.mutex) {
                frameSync.wait();
            }
            context.setMaxViewPort();
            context.getWindowSize(&width, &height);
            texture.setImageData(cast(ubyte[]) frame, HORIZONTAL_RESOLUTION, VERTICAL_RESOLUTION);
            texture.bind(0);
            program.use();
            program.setUniform("size", width, height);
            vertexArray.draw();
            context.updateDisplay();
            //writefln("FPS: %.1f", 1 / (fpsTimer.getTime().msecs() / 1000f));
        }

        drawRunning = false;

        context.destroy();
    }

    private void reloadInternalAffineReferencePoint(int layer) {
        layer -= 2;
        int layerAddressOffset = layer << 4;
        int dx = memory.getInt(0x4000028 + layerAddressOffset) << 4;
        internalAffineReferenceX[layer] = dx >> 4;
        int dy = memory.getInt(0x400002C + layerAddressOffset) << 4;
        internalAffineReferenceY[layer] = dy >> 4;
    }

    private void onAffineReferencePointPostWrite(Memory ioRegisters, int address, int shift, int mask, int oldValue, int newValue) {
        int layer = (address >> 4) - 2;
        newValue <<= 4;
        newValue >>= 4;
        if (address & 0b100) {
            internalAffineReferenceY[layer] = newValue;
        } else {
            internalAffineReferenceX[layer] = newValue;
        }
    }

    private void drawRun() {
        while (drawRunning) {
            for (int line = 0; line < VERTICAL_TIMING_RESOLUTION; line++) {
                timer.start();
                if (line == VERTICAL_RESOLUTION + 1) {
                    signalVBLANK();
                }
                setVCOUNT(line);
                checkVCOUNTER(line);
                if (line < VERTICAL_RESOLUTION) {
                    lineTypes[getMode()](line);
                } else if (line == VERTICAL_RESOLUTION) {
                    synchronized (frameSync.mutex) {
                        frameSync.notify();
                    }
                    reloadInternalAffineReferencePoint(2);
                    reloadInternalAffineReferencePoint(3);
                }
                timer.waitUntil(H_VISIBLE_DURATION);
                timer.restart();
                setHBLANK(line, true);
                signalHBLANK(line);
                timer.waitUntil(H_BLANK_DURATION);
                setHBLANK(line, false);
            }
        }
    }

    private void lineBlank(int line) {
        uint p = line * HORIZONTAL_RESOLUTION;
        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
            frame[p] = cast(short) 0xFFFF;
            p++;
        }
    }

    private void lineTransparent(short[] buffer) {
        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
            buffer[column] = TRANSPARENT;
        }
    }

    private void lineMode0(int line) {
        int displayControl = memory.getShort(0x4000000);
        int tileMapping = getBit(displayControl, 6);
        int bgEnables = getBits(displayControl, 8, 12);
        int windowEnables = getBits(displayControl, 13, 15);

        int blendControl = memory.getShort(0x4000050);

        short backColor = memory.getShort(0x5000000) & 0x7FFF;

        lineBackgroundText(line, lines[0], 0, bgEnables);
        lineBackgroundText(line, lines[1], 1, bgEnables);
        lineBackgroundText(line, lines[2], 2, bgEnables);
        lineBackgroundText(line, lines[3], 3, bgEnables);
        lineObjects(line, lines[4], lines[5], bgEnables, tileMapping);
        lineCompose(line, windowEnables, blendControl, backColor);
    }

    private void lineBackgroundText(int line, short[] buffer, int layer, int bgEnables) {
        if (!checkBit(bgEnables, layer)) {
            for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
                buffer[column] = TRANSPARENT;
            }
            return;
        }

        int bgControlAddress = 0x4000008 + (layer << 1);
        int bgControl = memory.getShort(bgControlAddress);

        int tileBase = getBits(bgControl, 2, 3) << 14;
        int mosaic = getBit(bgControl, 6);
        int singlePalette = getBit(bgControl, 7);
        int mapBase = getBits(bgControl, 8, 12) << 11;
        int screenSize = getBits(bgControl, 14, 15);

        int mosaicControl = memory.getInt(0x400004C);
        int mosaicSizeX = (mosaicControl & 0b1111) + 1;
        int mosaicSizeY = getBits(mosaicControl, 4, 7) + 1;

        int tile4Bit = singlePalette ? 0 : 1;
        int tileSizeShift = 6 - tile4Bit;

        int totalWidth = (256 << (screenSize & 0b1)) - 1;
        int totalHeight = (256 << ((screenSize & 0b10) >> 1)) - 1;

        int layerAddressOffset = layer << 2;
        int xOffset = memory.getShort(0x4000010 + layerAddressOffset) & 0x1FF;
        int yOffset = memory.getShort(0x4000012 + layerAddressOffset) & 0x1FF;

        int y = (line + yOffset) & totalHeight;

        if (y >= 256) {
            y -= 256;
            if (totalWidth > 256) {
                mapBase += BYTES_PER_KIB << 2;
            } else {
                mapBase += BYTES_PER_KIB << 1;
            }
        }

        if (mosaic) {
            y -= y % mosaicSizeY;
        }

        int mapLine = y >> 3;
        int tileLine = y & 7;

        int lineMapOffset = mapLine << 5;

        size_t bufferAddress = cast(size_t) buffer.ptr;
        size_t vramAddress = cast(size_t) memory.getPointer(0x6000000);
        size_t paletteAddress = cast(size_t) memory.getPointer(0x5000000);

        asm {
                push bufferAddress;
                mov EAX, 0;
                push RAX;
            loop:
                // calculate x for entire bg
                add EAX, xOffset;
                and EAX, totalWidth;
                // start calculating tile address
                mov EDX, mapBase;
                // calculate x for section
                test EAX, ~255;
                jz skip_overflow;
                and EAX, 255;
                add EDX, 2048;
            skip_overflow:
                test mosaic, 1;
                jz skip_mosaic;
                // apply horizontal mosaic
                push RDX;
                xor EDX, EDX;
                mov EBX, EAX;
                mov ECX, mosaicSizeX;
                div ECX;
                sub EBX, EDX;
                mov EAX, EBX;
                pop RDX;
            skip_mosaic:
                // EAX = x, RDX = map
                mov EBX, EAX;
                // calculate tile map and column
                shr EBX, 3;
                and EAX, 7;
                // calculate map address
                add EBX, lineMapOffset;
                shl EBX, 1;
                add EDX, EBX;
                add RDX, vramAddress;
                // get tile
                xor EBX, EBX;
                mov BX, [RDX];
                // EAX = tileColumn, EBX = tile
                mov ECX, EAX;
                // calculate sample column and line
                test EBX, 0x400;
                jz skip_hor_flip;
                not ECX;
                and ECX, 7;
            skip_hor_flip:
                mov EDX, tileLine;
                test EBX, 0x800;
                jz skip_ver_flip;
                not EDX;
                and EDX, 7;
            skip_ver_flip:
                // EBX = tile, ECX = sampleColumn, EDX = sampleLine
                push RCX;
                // calculate tile address
                shl EDX, 3;
                add EDX, ECX;
                mov ECX, tile4Bit;
                shr EDX, CL;
                mov EAX, EBX;
                and EAX, 0x3FF;
                mov ECX, tileSizeShift;
                shl EAX, CL;
                add EAX, EDX;
                add EAX, tileBase;
                add RAX, vramAddress;
                pop RCX;
                // EAX = tileAddress, EBX = tile, ECX = sampleColumn
                // calculate the palette address
                mov DL, [RAX];
                test singlePalette, 1;
                jz mult_palettes;
                and EDX, 0xFF;
                jnz skip_transparent1;
                mov CX, TRANSPARENT;
                jmp end_color;
            skip_transparent1:
                shl EDX, 1;
                jmp end_palettes;
            mult_palettes:
                and ECX, 1;
                shl ECX, 2;
                shr EDX, CL;
                and EDX, 0xF;
                jnz skip_transparent2;
                mov CX, TRANSPARENT;
                jmp end_color;
            skip_transparent2:
                shr EBX, 8;
                and EBX, 0xF0;
                add EDX, EBX;
                shl EDX, 1;
            end_palettes:
                // EDX = paletteAddress
                // get color from palette
                add RDX, paletteAddress;
                mov CX, [RDX];
                and ECX, 0x7FFF;
            end_color:
                // ECX = color
                pop RAX;
                pop RBX;
                // write color to line buffer
                mov [RBX], CX;
                // check loop condition
                cmp EAX, 239;
                jge end;
                // increment address and counter
                add RBX, 2;
                push RBX;
                add EAX, 1;
                push RAX;
                jmp loop;
            end:
                nop;
        }
    }

    private void lineMode1(int line) {
        int displayControl = memory.getShort(0x4000000);
        int tileMapping = getBit(displayControl, 6);
        int bgEnables = getBits(displayControl, 8, 12);
        int windowEnables = getBits(displayControl, 13, 15);

        int blendControl = memory.getShort(0x4000050);

        short backColor = memory.getShort(0x5000000)  & 0x7FFF;

        lineBackgroundText(line, lines[0], 0, bgEnables);
        lineBackgroundText(line, lines[1], 1, bgEnables);
        lineBackgroundAffine(line, lines[2], 2, bgEnables);
        lineTransparent(lines[3]);
        lineObjects(line, lines[4], lines[5], bgEnables, tileMapping);
        lineCompose(line, windowEnables, blendControl, backColor);
    }

    private void lineMode2(int line) {
        int displayControl = memory.getShort(0x4000000);
        int tileMapping = getBit(displayControl, 6);
        int bgEnables = getBits(displayControl, 8, 12);
        int windowEnables = getBits(displayControl, 13, 15);

        int blendControl = memory.getShort(0x4000050);

        short backColor = memory.getShort(0x5000000) & 0x7FFF;

        lineTransparent(lines[0]);
        lineTransparent(lines[1]);
        lineBackgroundAffine(line, lines[2], 2, bgEnables);
        lineBackgroundAffine(line, lines[3], 3, bgEnables);
        lineObjects(line, lines[4], lines[5], bgEnables, tileMapping);
        lineCompose(line, windowEnables, blendControl, backColor);
    }

    private void lineBackgroundAffine(int line, short[] buffer, int layer, int bgEnables) {
        if (!checkBit(bgEnables, layer)) {
            for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
                buffer[column] = TRANSPARENT;
            }

            int affineLayer = layer - 2;
            int layerAddressOffset = affineLayer << 4;
            int pb = memory.getShort(0x4000022 + layerAddressOffset);
            int pd = memory.getShort(0x4000026 + layerAddressOffset);

            internalAffineReferenceX[affineLayer] += pb;
            internalAffineReferenceY[affineLayer] += pd;
            return;
        }

        int bgControlAddress = 0x4000008 + (layer << 1);
        int bgControl = memory.getShort(bgControlAddress);

        int tileBase = getBits(bgControl, 2, 3) << 14;
        int mosaic = getBit(bgControl, 6);
        int mapBase = getBits(bgControl, 8, 12) << 11;
        int displayOverflow = getBit(bgControl, 13);
        int screenSize = getBits(bgControl, 14, 15);

        int mosaicControl = memory.getInt(0x400004C);
        int mosaicSizeX = (mosaicControl & 0b1111) + 1;
        int mosaicSizeY = getBits(mosaicControl, 4, 7) + 1;

        int bgSize = (128 << screenSize) - 1;
        int bgSizeInv = ~bgSize;
        int mapLineShift = screenSize + 4;

        int affineLayer = layer - 2;
        int layerAddressOffset = affineLayer << 4;
        int pa = memory.getShort(0x4000020 + layerAddressOffset);
        int pb = memory.getShort(0x4000022 + layerAddressOffset);
        int pc = memory.getShort(0x4000024 + layerAddressOffset);
        int pd = memory.getShort(0x4000026 + layerAddressOffset);

        int dx = internalAffineReferenceX[affineLayer];
        int dy = internalAffineReferenceY[affineLayer];

        internalAffineReferenceX[affineLayer] += pb;
        internalAffineReferenceY[affineLayer] += pd;

        size_t bufferAddress = cast(size_t) buffer.ptr;
        size_t vramAddress = cast(size_t) memory.getPointer(0x6000000);
        size_t paletteAddress = cast(size_t) memory.getPointer(0x5000000);

        asm {
                mov EAX, dx;
                push RAX;
                mov EBX, dy;
                push RBX;
                push bufferAddress;
                push 0;
            loop:
                // calculate x
                add EAX, 128;
                sar EAX, 8;
                // calculate y
                add EBX, 128;
                sar EBX, 8;
                // EAX = x, EBX = y
                // check and handle overflow
                test EAX, bgSizeInv;
                jz skip_x_overflow;
                test displayOverflow, 1;
                jnz skip_transparent1;
                mov CX, TRANSPARENT;
                jmp end_color;
            skip_transparent1:
                and EAX, bgSize;
            skip_x_overflow:
                test EBX, bgSizeInv;
                jz skip_y_overflow;
                test displayOverflow, 1;
                jnz skip_transparent2;
                mov CX, TRANSPARENT;
                jmp end_color;
            skip_transparent2:
                and EBX, bgSize;
            skip_y_overflow:
                // check and apply mosaic
                test mosaic, 1;
                jz skip_mosaic;
                push RBX;
                mov EBX, EAX;
                xor EDX, EDX;
                mov ECX, mosaicSizeX;
                div ECX;
                sub EBX, EDX;
                pop RAX;
                push RBX;
                mov EBX, EAX;
                xor EDX, EDX;
                mov ECX, mosaicSizeY;
                div ECX;
                sub EBX, EDX;
                pop RAX;
            skip_mosaic:
                // calculate the map address
                push RAX;
                push RBX;
                shr EAX, 3;
                shr EBX, 3;
                mov ECX, mapLineShift;
                shl EBX, CL;
                add EAX, EBX;
                add EAX, mapBase;
                add RAX, vramAddress;
                // get the tile number
                xor ECX, ECX;
                mov CL, [RAX];
                // calculate the tile address
                pop RBX;
                pop RAX;
                and EAX, 7;
                and EBX, 7;
                shl EBX, 3;
                add EAX, EBX;
                shl ECX, 6;
                add EAX, ECX;
                add EAX, tileBase;
                add RAX, vramAddress;
                // get the palette index
                xor EDX, EDX;
                mov DL, [RAX];
                // calculate the palette address
                shl EDX, 1;
                jnz end_palettes;
                mov CX, TRANSPARENT;
                jmp end_color;
            end_palettes:
                // ECX = paletteAddress
                // get color from palette
                add RDX, paletteAddress;
                mov CX, [RDX];
                and ECX, 0x7FFF;
            end_color:
                // ECX = color
                pop RAX;
                pop RBX;
                // EAX = index, EBX = buffer address
                // write color to line buffer
                mov [RBX], CX;
                pop RDX;
                pop RCX;
                // ECX = dx, EDX = dy
                // check loop condition
                cmp EAX, 239;
                jge end;
                // increment dx and dy
                add ECX, pa;
                push RCX;
                add EDX, pc;
                push RDX;
                // increment address and counter
                add RBX, 2;
                push RBX;
                add EAX, 1;
                push RAX;
                // prepare for next iteration
                mov EAX, ECX;
                mov EBX, EDX;
                jmp loop;
            end:
                nop;
        }
    }

    private void lineMode3(int line) {
        int displayControl = memory.getShort(0x4000000);
        int tileMapping = getBit(displayControl, 6);
        int bgEnables = getBits(displayControl, 8, 12);
        int windowEnables = getBits(displayControl, 13, 15);

        int blendControl = memory.getShort(0x4000050);

        short backColor = memory.getShort(0x5000000) & 0x7FFF;

        lineTransparent(lines[0]);
        lineTransparent(lines[1]);
        lineBackgroundBitmap16Single(line, lines[2]);
        lineTransparent(lines[3]);
        lineObjects(line, lines[4], lines[5], bgEnables, tileMapping);
        lineCompose(line, windowEnables, blendControl, backColor);
    }

    private void lineBackgroundBitmap16Single(int line, short[] colorBuffer) {
        int pa = memory.getShort(0x4000020);
        int pb = memory.getShort(0x4000022);
        int pc = memory.getShort(0x4000024);
        int pd = memory.getShort(0x4000026);

        int dx = internalAffineReferenceX[0];
        int dy = internalAffineReferenceY[0];

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++, dx += pa, dy += pc) {
            int x = dx + 128 >> 8;
            int y = dy + 128 >> 8;

            int address = (x + y * 240 << 1) + 0x6000000;

            short color = memory.getShort(address) & 0x7FFF;
            colorBuffer[column] = color;
        }

        internalAffineReferenceX[0] += pb;
        internalAffineReferenceY[0] += pd;
    }

    private void lineMode4(int line) {
        int displayControl = memory.getShort(0x4000000);
        int frame = getBit(displayControl, 4);
        int tileMapping = getBit(displayControl, 6);
        int bgEnables = getBits(displayControl, 8, 12);
        int windowEnables = getBits(displayControl, 13, 15);

        int blendControl = memory.getShort(0x4000050);

        short backColor = memory.getShort(0x5000000) & 0x7FFF;

        lineTransparent(lines[0]);
        lineTransparent(lines[1]);
        lineBackgroundBitmap8Double(line, lines[2], frame);
        lineTransparent(lines[3]);
        lineObjects(line, lines[4], lines[5], bgEnables, tileMapping);
        lineCompose(line, windowEnables, blendControl, backColor);
    }

    private void lineBackgroundBitmap8Double(int line, short[] colorBuffer, int frame) {
        int pa = memory.getShort(0x4000020);
        int pb = memory.getShort(0x4000022);
        int pc = memory.getShort(0x4000024);
        int pd = memory.getShort(0x4000026);

        int dx = internalAffineReferenceX[0];
        int dy = internalAffineReferenceY[0];

        int addressBase = frame ? 0x600A000 : 0x6000000;

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++, dx += pa, dy += pc) {
            int x = dx + 128 >> 8;
            int y = dy + 128 >> 8;

            int address = x + y * 240 + addressBase;

            int paletteIndex = memory.getByte(address) & 0xFF;
            if (paletteIndex == 0) {
                colorBuffer[column] = TRANSPARENT;
                continue;
            }
            int paletteAddress = paletteIndex << 1;

            short color = memory.getShort(0x5000000 + paletteAddress) & 0x7FFF;
            colorBuffer[column] = color;
        }

        internalAffineReferenceX[0] += pb;
        internalAffineReferenceY[0] += pd;
    }

    private void lineObjects(int line, short[] colorBuffer, short[] infoBuffer, int bgEnables, int tileMapping) {
        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
            colorBuffer[column] = TRANSPARENT;
            infoBuffer[column] = 3;
        }

        if (!checkBit(bgEnables, 4)) {
            return;
        }

        int tileBase = 0x6010000;
        if (getMode() >= 3) {
            tileBase += 0x4000;
        }

        int mosaicControl = memory.getInt(0x400004C);
        int mosaicSizeX = (mosaicControl & 0b1111) + 1;
        int mosaicSizeY = getBits(mosaicControl, 4, 7) + 1;

        for (int i = 127; i >= 0; i--) {
            int attributeAddress = 0x7000000 + (i << 3);

            int attribute0 = memory.getShort(attributeAddress);

            int rotAndScale = getBit(attribute0, 8);
            int doubleSize = getBit(attribute0, 9);
            if (!rotAndScale) {
                if (doubleSize) {
                    continue;
                }
            }
            int y = attribute0 & 0xFF;
            int mode = getBits(attribute0, 10, 11);
            int mosaic = getBit(attribute0, 12);
            int singlePalette = getBit(attribute0, 13);
            int shape = getBits(attribute0, 14, 15);

            int attribute1 = memory.getShort(attributeAddress + 2);

            int x = attribute1 & 0x1FF;
            int horizontalFlip = void, verticalFlip = void;
            int pa = void, pb = void, pc = void, pd = void;
            if (rotAndScale) {
                horizontalFlip = 0;
                verticalFlip = 0;
                int rotAndScaleParameters = getBits(attribute1, 9, 13);
                int parametersAddress = (rotAndScaleParameters << 5) + 0x7000006;
                pa = memory.getShort(parametersAddress);
                pb = memory.getShort(parametersAddress + 8);
                pc = memory.getShort(parametersAddress + 16);
                pd = memory.getShort(parametersAddress + 24);
            } else {
                horizontalFlip = getBit(attribute1, 12);
                verticalFlip = getBit(attribute1, 13);
                pa = 0;
                pb = 0;
                pc = 0;
                pd = 0;
            }
            int size = getBits(attribute1, 14, 15);

            int attribute2 = memory.getShort(attributeAddress + 4);

            int tileNumber = attribute2 & 0x3FF;
            int priority = getBits(attribute2, 10, 11);
            int paletteNumber = getBits(attribute2, 12, 15);

            if (x >= HORIZONTAL_RESOLUTION) {
                x -= 512;
            }
            if (y >= VERTICAL_RESOLUTION) {
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

            for (int objectX = 0; objectX < horizontalSize; objectX++) {

                int column = objectX + x;

                if (column >= HORIZONTAL_RESOLUTION) {
                    continue;
                }

                int previousInfo = infoBuffer[column];

                int previousPriority = previousInfo & 0b11;
                if (priority > previousPriority) {
                    continue;
                }

                int sampleX = objectX, sampleY = objectY;

                if (rotAndScale) {
                    int tmpX = sampleX - (horizontalSize >> 1);
                    int tmpY = sampleY - (verticalSize >> 1);
                    sampleX = pa * tmpX + pb * tmpY + 128 >> 8;
                    sampleY = pc * tmpX + pd * tmpY + 128 >> 8;
                    sampleX += sampleHorizontalSize >> 1;
                    sampleY += sampleVerticalSize >> 1;
                    if (sampleX < 0 || sampleX >= sampleHorizontalSize || sampleY < 0 || sampleY >= sampleVerticalSize) {
                        continue;
                    }
                } else {
                    if (verticalFlip) {
                        sampleY = verticalSize - sampleY - 1;
                    }
                    if (horizontalFlip) {
                        sampleX = horizontalSize - sampleX - 1;
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
                    int paletteIndex = memory.getByte(tileAddress) & 0xFF;
                    if (paletteIndex == 0) {
                        continue;
                    }
                    paletteAddress = paletteIndex << 1;
                } else {
                    int paletteIndex = memory.getByte(tileAddress) >> ((tileX & 1) << 2) & 0xF;
                    if (paletteIndex == 0) {
                        continue;
                    }
                    paletteAddress = (paletteNumber << 4) + paletteIndex << 1;
                }

                short color = memory.getShort(0x5000200 + paletteAddress) & 0x7FFF;

                if (mode != 2) {
                    colorBuffer[column] = color;
                }

                int modeFlags = mode << 2 | previousInfo & 0b1000;
                infoBuffer[column] = cast(short) (modeFlags | priority);
            }
        }
    }

    private int getWindow(int windowEnables, int objectMode, int line, int column) {
        if (!windowEnables) {
            return 0;
        }

        if (windowEnables & 0b1) {
            int horizontalDimensions = memory.getShort(0x4000040);

            int x1 = getBits(horizontalDimensions, 8, 15);
            int x2 = horizontalDimensions & 0xFF;

            int verticalDimensions = memory.getShort(0x4000044);

            int y1 = getBits(verticalDimensions, 8, 15);
            int y2 = verticalDimensions & 0xFF;

            if (column >= x1 && column < x2 && line >= y1 && line < y2) {
                return 0x4000048;
            }
        }

        if (windowEnables & 0b10) {
            int horizontalDimensions = memory.getShort(0x4000042);

            int x1 = getBits(horizontalDimensions, 8, 15);
            int x2 = horizontalDimensions & 0xFF;

            int verticalDimensions = memory.getShort(0x4000046);

            int y1 = getBits(verticalDimensions, 8, 15);
            int y2 = verticalDimensions & 0xFF;

            if (column >= x1 && column < x2 && line >= y1 && line < y2) {
                return 0x4000049;
            }
        }

        if (windowEnables & 0b100) {
            if (objectMode & 0b10) {
                return 0x400004B;
            }
        }

        return 0x400004A;
    }

    private void lineCompose(int line, int windowEnables, int blendControl, short backColor) {
        uint p = line * HORIZONTAL_RESOLUTION;

        int colorEffect = getBits(blendControl, 6, 7);

        int[5] priorities = [
            memory.getShort(0x4000008) & 0b11,
            memory.getShort(0x400000A) & 0b11,
            memory.getShort(0x400000C) & 0b11,
            memory.getShort(0x400000E) & 0b11,
            0
        ];

        int[5] layerMap = [3, 2, 1, 0, 4];

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {

            int objInfo = lines[5][column];
            int objPriority = objInfo & 0b11;
            int objMode = objInfo >> 2;

            bool specialEffectEnabled = void;
            int layerEnables = void;

            int window = getWindow(windowEnables, objMode, line, column);
            if (window != 0) {
                int windowControl = memory.getByte(window);
                layerEnables = windowControl & 0b11111;
                specialEffectEnabled = checkBit(windowControl, 5);
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

            foreach (int layer; layerMap) {

                if (!checkBit(layerEnables, layer)) {
                    continue;
                }

                short layerColor = lines[layer][column];

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

            if (specialEffectEnabled) {
                if ((objMode & 0b1) && checkBit(blendControl, secondLayer + 8)) {
                    firstColor = applyBlendEffect(firstColor, secondColor);
                } else {
                    final switch (colorEffect) {
                        case 0:
                            break;
                        case 1:
                            if (checkBit(blendControl, firstLayer) && checkBit(blendControl, secondLayer + 8)) {
                                firstColor = applyBlendEffect(firstColor, secondColor);
                            }
                            break;
                        case 2:
                            if (checkBit(blendControl, firstLayer)) {
                                applyBrightnessIncreaseEffect(firstColor);
                            }
                            break;
                        case 3:
                            if (checkBit(blendControl, firstLayer)) {
                                applyBrightnessDecreaseEffect(firstColor);
                            }
                            break;
                    }
                }
            }

            frame[p] = firstColor;

            p++;
        }
    }

    private void applyBrightnessIncreaseEffect(ref short first) {
        int firstRed = first & 0b11111;
        int firstGreen = getBits(first, 5, 9);
        int firstBlue = getBits(first, 10, 14);

        int evy = min(memory.getInt(0x4000054) & 0b11111, 16);
        firstRed += ((31 - firstRed << 4) * evy >> 4) + 8 >> 4;
        firstGreen += ((31 - firstGreen << 4) * evy >> 4) + 8 >> 4;
        firstBlue += ((31 - firstBlue << 4) * evy >> 4) + 8 >> 4;

        first = (firstBlue & 31) << 10 | (firstGreen & 31) << 5 | firstRed & 31;
    }

    private void applyBrightnessDecreaseEffect(ref short first) {
        int firstRed = first & 0b11111;
        int firstGreen = getBits(first, 5, 9);
        int firstBlue = getBits(first, 10, 14);

        int evy = min(memory.getInt(0x4000054) & 0b11111, 16);
        firstRed -= ((firstRed << 4) * evy >> 4) + 8 >> 4;
        firstGreen -= ((firstGreen << 4) * evy >> 4) + 8 >> 4;
        firstBlue -= ((firstBlue << 4) * evy >> 4) + 8 >> 4;

        first = (firstBlue & 31) << 10 | (firstGreen & 31) << 5 | firstRed & 31;
    }

    private short applyBlendEffect(short first, short second) {
        int firstRed = first & 0b11111;
        int firstGreen = getBits(first, 5, 9);
        int firstBlue = getBits(first, 10, 14);

        int secondRed = second & 0b11111;
        int secondGreen = getBits(second, 5, 9);
        int secondBlue = getBits(second, 10, 14);

        int blendAlpha = memory.getShort(0x4000052);

        int eva = min(blendAlpha & 0b11111, 16);
        firstRed = ((firstRed << 4) * eva >> 4) + 8 >> 4;
        firstGreen = ((firstGreen << 4) * eva >> 4) + 8 >> 4;
        firstBlue = ((firstBlue << 4) * eva >> 4) + 8 >> 4;

        int evb = min(getBits(blendAlpha, 8, 12), 16);
        secondRed = ((secondRed << 4) * evb >> 4) + 8 >> 4;
        secondGreen = ((secondGreen << 4) * evb >> 4) + 8 >> 4;
        secondBlue = ((secondBlue << 4) * evb >> 4) + 8 >> 4;

        int blendRed = min(31, firstRed + secondRed);
        int blendGreen = min(31, firstGreen + secondGreen);
        int blendBlue = min(31, firstBlue + secondBlue);

        return (blendBlue & 31) << 10 | (blendGreen & 31) << 5 | blendRed & 31;
    }

    private Mode getMode() {
        int displayControl = memory.getShort(0x4000000);
        if (checkBit(displayControl, 7)) {
            return Mode.BLANK;
        }
        return cast(Mode) (displayControl & 0b111);
    }

    private void setHBLANK(int line, bool state) {
        int oldDisplayStatus = void, newDisplayStatus = void;
        do {
            oldDisplayStatus = memory.getInt(0x4000004);
            newDisplayStatus = oldDisplayStatus;
            setBit(newDisplayStatus, 1, state);
        } while (!memory.compareAndSet(0x4000004, oldDisplayStatus, newDisplayStatus));
    }

    private void setVCOUNT(int line) {
        memory.setByte(0x4000006, cast(byte) line);
        int oldDisplayStatus = void, newDisplayStatus = void;
        do {
            oldDisplayStatus = memory.getInt(0x4000004);
            newDisplayStatus = oldDisplayStatus;
            setBit(newDisplayStatus, 0, line >= VERTICAL_RESOLUTION && line < VERTICAL_TIMING_RESOLUTION - 1);
            setBit(newDisplayStatus, 2, getBits(oldDisplayStatus, 8, 15) == line);
        } while (!memory.compareAndSet(0x4000004, oldDisplayStatus, newDisplayStatus));
    }

    private void signalHBLANK(int line) {
        int displayStatus = memory.getInt(0x4000004);
        if (line < VERTICAL_RESOLUTION) {
            dmas.signalHBLANK();
            if (checkBit(displayStatus, 4)) {
                interruptHandler.requestInterrupt(InterruptSource.LCD_H_BLANK);
            }
        }
    }

    private void signalVBLANK() {
        int displayStatus = memory.getInt(0x4000004);
        dmas.signalVBLANK();
        if (checkBit(displayStatus, 3)) {
            interruptHandler.requestInterrupt(InterruptSource.LCD_V_BLANK);
        }
    }

    private void checkVCOUNTER(int line) {
        int displayStatus = memory.getInt(0x4000004);
        if (getBits(displayStatus, 8, 15) == line && checkBit(displayStatus, 5)) {
            interruptHandler.requestInterrupt(InterruptSource.LCD_V_COUNTER_MATCH);
        }
    }

    private static enum Mode {
        TILED_TEXT = 0,
        TILED_MIXED = 1,
        TILED_AFFINE = 2,
        BITMAP_16_SINGLE = 3,
        BITMAP_8_DOUBLE = 4,
        BITMAP_16_DOUBLE = 5,
        BLANK = 6
    }
}

public enum UpscalingMode {
    NONE,
    LINEAR
}

private VertexData generatePlane(float width, float height) {
    width /= 2;
    height /= 2;
    VertexData vertexData = new VertexData();
    VertexAttribute positionsAttribute = new VertexAttribute("positions", FLOAT, 3);
    vertexData.addAttribute(0, positionsAttribute);
    float[] positions = [
        -width, -height, 0,
        width, -height, 0,
        -width, height, 0,
        width, height, 0
    ];
    positionsAttribute.setData(cast(ubyte[]) positions);
    uint[] indices = [0, 3, 2, 0, 1, 3];
    vertexData.setIndices(indices);
    return vertexData;
}

private immutable string vertexShaderSource =
`
// $shader_type: vertex

// $attrib_layout: position = 0

#version 120

attribute vec3 position;

varying vec2 textureCoords;

void main() {
    textureCoords = vec2(position.x + 1, 1 - position.y) / 2;
    gl_Position = vec4(position, 1);
}
`;
private immutable string fragmentShaderSource =
`
// $shader_type: fragment

// $texture_layout: color = 0

#version 120

const vec2 RES = vec2(240, 160);

varying vec2 textureCoords;

uniform sampler2D color;
uniform vec2 size;

void main() {
    vec2 m = size / RES;
    vec2 sampleCoords = textureCoords;

    if (m.x > m.y) {
        float margin = (size.x / size.y - RES.x / RES.y) / 2;
        sampleCoords.x = mix(-margin, 1 + margin, sampleCoords.x);
    } else {
        float margin = (size.y / size.x - RES.y / RES.x) / 2;
        sampleCoords.y = mix(-margin, 1 + margin, sampleCoords.y);
    }

    gl_FragColor = vec4(texture2D(color, sampleCoords).rgb, 1);
}
`;
