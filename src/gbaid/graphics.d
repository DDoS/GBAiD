module gbaid.graphics;

import core.thread;
import core.time;

import std.stdio;
import std.algorithm;

import gbaid.memory;
import gbaid.gl, gbaid.gl20;
import gbaid.util;

public class Display {
    private static immutable uint HORIZONTAL_RESOLUTION = 240;
    private static immutable uint VERTICAL_RESOLUTION = 160;
    private static immutable uint SCREEN_AREA = HORIZONTAL_RESOLUTION * VERTICAL_RESOLUTION;
    private static immutable uint LAYER_COUNT = 6;
    private static immutable uint COMPONENTS_PER_PIXEL = 3;
    private static immutable uint LAYER_OFFSET = HORIZONTAL_RESOLUTION * COMPONENTS_PER_PIXEL;
    private static immutable uint FRAME_SIZE = SCREEN_AREA * COMPONENTS_PER_PIXEL;
    private Memory memory;
    private Context context;
    private Program program;
    private Texture texture;
    private VertexArray vertexArray;
    private ubyte[FRAME_SIZE] frame = new ubyte[FRAME_SIZE];
    private short[HORIZONTAL_RESOLUTION][LAYER_COUNT] lines = new short[HORIZONTAL_RESOLUTION][LAYER_COUNT];

    public void setMemory(Memory memory) {
        this.memory = memory;
    }

    public void run() {
        context = new GL20Context();
        context.setWindowSize(HORIZONTAL_RESOLUTION, VERTICAL_RESOLUTION);
        context.setWindowTitle("GBAiD");
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
        program = context.newProgram();
        program.create();
        program.attachShader(vertexShader);
        program.attachShader(fragmentShader);
        program.link();
        program.use();
        program.bindSampler(0);

        texture = context.newTexture();
        texture.create();
        texture.setFormat(RGB, RGB8);
        texture.setFilters(NEAREST, NEAREST);

        vertexArray = context.newVertexArray();
        vertexArray.create();
        vertexArray.setData(generatePlane(2, 2));

        while (!context.isWindowCloseRequested()) {
            update();
            Thread.sleep(dur!"msecs"(16));
        }

        context.destroy();
    }

    private void update() {
        if (checkBit(memory.getShort(0x4000000), 7)) {
            updateBlank();
        } else {
            final switch (getMode()) {
                case Mode.BACKGROUND_4:
                    update0();
                    break;
                case Mode.BACKGROUND_3:
                    update1();
                    break;
                case Mode.BACKGROUND_2:
                    update2();
                    break;
                case Mode.BITMAP_16_DIRECT_SINGLE:
                    update3();
                    break;
                case Mode.BITMAP_8_PALETTE_DOUBLE:
                    update4();
                    break;
                case Mode.BITMAP_16_DIRECT_DOUBLE:
                    update5();
                    break;
            }
        }
        setVCOUNT(160);
        texture.setImageData(frame, HORIZONTAL_RESOLUTION, VERTICAL_RESOLUTION);
        texture.bind(0);
        program.use();
        vertexArray.draw();
        context.updateDisplay();
        setVCOUNT(227);
    }

    private void updateBlank() {
        uint p = 0;
        for (int line = 0; line < VERTICAL_RESOLUTION; line++) {
            setVCOUNT(line);
            for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
                frame[p] = 255;
                frame[p + 1] = 255;
                frame[p + 2] = 255;
                p += 3;
            }
        }
    }

    private void update0() {
        for (int line = 0; line < VERTICAL_RESOLUTION; line++) {

            setVCOUNT(line);

            line0(line);
        }
    }

    private void update1() {
        for (int line = 0; line < VERTICAL_RESOLUTION; line++) {

            setVCOUNT(line);

            line1(line);
        }
    }

    private void update2() {
        for (int line = 0; line < VERTICAL_RESOLUTION; line++) {

            setVCOUNT(line);

            line2(line);
        }
    }

    private void update3() {
        uint i = 0x6000000, p = 0;
        for (int line = 0; line < VERTICAL_RESOLUTION; line++) {
            setVCOUNT(line);
            for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
                int pixel = memory.getShort(i);
                frame[p] = cast(ubyte) (getBits(pixel, 0, 4) / 31f * 255);
                frame[p + 1] = cast(ubyte) (getBits(pixel, 5, 9) / 31f * 255);
                frame[p + 2] = cast(ubyte) (getBits(pixel, 10, 14) / 31f * 255);
                i += 2;
                p += 3;
            }
        }
    }

    private void update4() {
        int displayControl = memory.getShort(0x4000000);
        uint i = checkBit(displayControl, 4) ? 0x0600A000 : 0x6000000;
        uint p = 0;
        for (int line = 0; line < VERTICAL_RESOLUTION; line++) {
            setVCOUNT(line);
            for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
                int paletteAddress = (memory.getByte(i) & 0xFF) * 2;
                if (paletteAddress == 0) {
                    // obj
                } else {
                    int color = memory.getShort(0x5000000 + paletteAddress);
                    frame[p] = cast(ubyte) (getBits(color, 0, 4) / 31f * 255);
                    frame[p + 1] = cast(ubyte) (getBits(color, 5, 9) / 31f * 255);
                    frame[p + 2] = cast(ubyte) (getBits(color, 10, 14) / 31f * 255);
                }
                i += 1;
                p += 3;
            }
        }
    }

    private void update5() {
        int displayControl = memory.getShort(0x4000000);
        uint i = checkBit(displayControl, 4) ? 0x0600A000 : 0x6000000;
        uint p = 0;
        for (int line = 0; line < 128; line++) {
            setVCOUNT(line);
            for (int column = 0; column < 160; column++) {
                int pixel = memory.getShort(i);
                frame[p] = cast(ubyte) (getBits(pixel, 0, 4) / 31f * 255);
                frame[p + 1] = cast(ubyte) (getBits(pixel, 5, 9) / 31f * 255);
                frame[p + 2] = cast(ubyte) (getBits(pixel, 10, 14) / 31f * 255);
                i += 2;
                p += 3;
            }
        }
    }

    private void line0(int line) {
        int displayControl = memory.getShort(0x4000000);

        int bgEnables = getBits(displayControl, 8, 11);
        int windowEnables = getBits(displayControl, 13, 14);

        int blendControl = memory.getShort(0x4000050);

        short backColor = memory.getShort(0x5000000);

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
            layer0(line, column, 0, lines[0], bgEnables, backColor);
        }

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
            layer0(line, column, 1, lines[1], bgEnables, backColor);
        }

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
            layer0(line, column, 2, lines[2], bgEnables, backColor);
        }

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
            layer0(line, column, 3, lines[3], bgEnables, backColor);
        }

        lineCompose(line, windowEnables, blendControl, backColor);
    }

    private void layer0(int line, int column, int layer, short[] buffer, int bgEnables, short backColor) {
        if (!checkBit(bgEnables, layer)) {
            buffer[column] = backColor;
            return;
        }

        int bgControlAddress = 0x4000008 + layer * 2;
        int bgControl = memory.getShort(bgControlAddress);

        int tileBase = getBits(bgControl, 2, 3) * 16 * BYTES_PER_KIB + 0x6000000;
        int mosaic = getBit(bgControl, 6);
        int singlePalette = getBit(bgControl, 7);
        int mapBase = getBits(bgControl, 8, 12) * 2 * BYTES_PER_KIB + 0x6000000;
        int screenSize = getBits(bgControl, 14, 15);

        int tileLength = 8;
        int tile4Bit = singlePalette ? 1 : 2;
        int tileSize = tileLength * tileLength / tile4Bit;

        int tileCount = 32;
        int bgSize = tileCount * tileLength;

        int layerAddressOffset = layer * 4;
        int xOffset = memory.getShort(0x4000010 + layerAddressOffset) & 0x1FF;
        int yOffset = memory.getShort(0x4000012 + layerAddressOffset) & 0x1FF;

        int x = column + xOffset;
        int y = line + yOffset;

        if (x > bgSize) {
            x %= bgSize;
            if (screenSize == 1 || screenSize == 3) {
                mapBase += 2 * BYTES_PER_KIB;
            }
        }

        if (y > bgSize) {
            y %= bgSize;
            if (screenSize == 2) {
                mapBase += 2 * BYTES_PER_KIB;
            } else if (screenSize == 3) {
                mapBase += 4 * BYTES_PER_KIB;
            }
        }

        if (mosaic) {
            applyMosaic(x, y);
        }

        int mapColumn = x / tileLength;
        int mapLine = y / tileLength;

        int tileColumn = x % tileLength;
        int tileLine = y % tileLength;

        int mapAddress = mapBase + (mapLine * tileCount + mapColumn) * 2;

        int tile = memory.getShort(mapAddress);

        int tileNumber = tile & 0x3FF;
        int horizontalFlip = getBit(tile, 10);
        int verticalFlip = getBit(tile, 11);

        if (horizontalFlip) {
            tileLine = tileLength - tileLine - 1;
        }
        if (verticalFlip) {
            tileColumn = tileLength - tileColumn - 1;
        }

        int tileAddress = tileBase + tileNumber * tileSize + (tileLine * tileLength + tileColumn) / tile4Bit;

        int paletteAddress;
        if (singlePalette) {
            paletteAddress = (memory.getByte(tileAddress) & 0xFF) * 2;
        } else {
            int paletteNumber = getBits(tile, 12, 15);
            paletteAddress = (paletteNumber * 16 + (memory.getByte(tileAddress) & 0xF << tileColumn % 2 * 4)) * 2;
        }

        if (paletteAddress == 0) {
            buffer[column] = backColor;
            return;
        }

        short color = memory.getShort(0x5000000 + paletteAddress);

        buffer[column] = color;
    }

    private void line1(int line) {
        int displayControl = memory.getShort(0x4000000);

        int bgEnables = getBits(displayControl, 8, 11);
        int windowEnables = getBits(displayControl, 13, 14);

        int blendControl = memory.getShort(0x4000050);

        short backColor = memory.getShort(0x5000000);

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
            lines[0][column] = backColor;
        }

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
            layer0(line, column, 1, lines[1], bgEnables, backColor);
        }

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
            layer0(line, column, 2, lines[2], bgEnables, backColor);
        }

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
            layer2(line, column, 3, lines[3], bgEnables, backColor);
        }

        lineCompose(line, windowEnables, blendControl, backColor);
    }

    private void line2(int line) {
        int displayControl = memory.getShort(0x4000000);

        int bgEnables = getBits(displayControl, 8, 11);
        int windowEnables = getBits(displayControl, 13, 14);

        int blendControl = memory.getShort(0x4000050);

        short backColor = memory.getShort(0x5000000);

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
            lines[0][column] = backColor;
        }

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
            lines[1][column] = backColor;
        }

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
            layer2(line, column, 2, lines[2], bgEnables, backColor);
        }

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
            layer2(line, column, 3, lines[3], bgEnables, backColor);
        }

        lineCompose(line, windowEnables, blendControl, backColor);
    }

    private void layer2(int line, int column, int layer, short[] buffer, int bgEnables, short backColor) {
        if (!checkBit(bgEnables, layer)) {
            buffer[column] = backColor;
            return;
        }

        int bgControlAddress = 0x4000008 + layer * 2;
        int bgControl = memory.getShort(bgControlAddress);

        int tileBase = getBits(bgControl, 2, 3) * 16 * BYTES_PER_KIB + 0x6000000;
        int mosaic = getBit(bgControl, 6);
        int mapBase = getBits(bgControl, 8, 12) * 2 * BYTES_PER_KIB + 0x6000000;
        int displayOverflow = getBit(bgControl, 13);
        int screenSize = getBits(bgControl, 14, 15);

        int tileLength = 8;
        int tileSize = tileLength * tileLength;

        int tileCount = 16 * (1 << screenSize);
        int bgSize = tileCount * tileLength;

        int layerAddressOffset = (layer - 2) * 16;
        int pa = memory.getShort(0x4000020 + layerAddressOffset);
        int pc = memory.getShort(0x4000022 + layerAddressOffset);
        int pb = memory.getShort(0x4000024 + layerAddressOffset);
        int pd = memory.getShort(0x4000026 + layerAddressOffset);
        int dx = memory.getInt(0x4000028 + layerAddressOffset) & 0xFFFFFFF;
        dx <<= 4;
        dx >>= 4;
        int dy = memory.getInt(0x400002C + layerAddressOffset) & 0xFFFFFFF;
        dy <<= 4;
        dy >>= 4;

        int x = (pa * ((column << 8) + dx) >> 8) + (pc * ((line << 8) + dy) >> 8);
        int y = (pc * ((column << 8) + dx) >> 8) + (pd * ((line << 8) + dy) >> 8);

        x = x + 128 >> 8;
        y = y + 128 >> 8;

        if (x < 0 || x > bgSize) {
            if (displayOverflow) {
                x %= bgSize;
                if (x < 0) {
                    x += bgSize;
                }
            } else {
                buffer[column] = backColor;
                return;
            }
        }

        if (y < 0 || y > bgSize) {
            if (displayOverflow) {
                y %= bgSize;
                if (y < 0) {
                    y += bgSize;
                }
            } else {
                buffer[column] = backColor;
                return;
            }
        }

        if (mosaic) {
            applyMosaic(x, y);
        }

        int mapColumn = x / tileLength;
        int mapLine = y / tileLength;

        int tileColumn = x % tileLength;
        int tileLine = y % tileLength;

        int mapAddress = mapBase + (mapLine * tileCount + mapColumn);

        int tileNumber = memory.getByte(mapAddress) & 0xFF;

        int tileAddress = tileBase + tileNumber * tileSize + (tileLine * tileLength + tileColumn);

        int paletteAddress = (memory.getByte(tileAddress) & 0xFF) * 2;

        if (paletteAddress == 0) {
            buffer[column] = backColor;
            return;
        }

        short color = memory.getShort(0x5000000 + paletteAddress);

        buffer[column] = color;
    }

    private int getWindow(int windowEnables, int line, int column) {
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

        return 0x400004A;
    }

    private void applyMosaic(ref int x, ref int y) {
        int mosaicControl = memory.getInt(0x400004C);
        int hSize = (mosaicControl & 0b1111) + 1;
        int vSize = getBits(mosaicControl, 4, 7) + 1;

        x /= hSize;
        x *= hSize;

        y /= vSize;
        y *= vSize;
    }

    private void lineCompose(int line, int windowEnables, int blendControl, short backColor) {
        uint p = line * HORIZONTAL_RESOLUTION * COMPONENTS_PER_PIXEL;

        int colorEffect = getBits(blendControl, 6, 7);

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {

            bool specialEffectEnabled;
            int layerEnables;

            int window = getWindow(windowEnables, line, column);
            if (window != 0) {
                int windowControl = memory.getByte(window);
                layerEnables = windowControl & 0b11111;
                specialEffectEnabled = checkBit(windowControl, 5);
            } else {
                layerEnables = 0b11111;
                specialEffectEnabled = true;
            }

            short color = lines[3][column];
            int previousPriority = memory.getShort(0x400000E) & 0b11;
            if (checkBit(blendControl, 3)) {
                applyBrightnessEffect(colorEffect, color);
            }

            for (int layer = 2; layer >= 0; layer--) {
                int currentPriority = memory.getShort(0x4000008 + layer * 2) & 0b11;
                if (currentPriority <= previousPriority) {
                    if (checkBit(layerEnables, layer)) {
                        short layerColor = lines[layer][column];
                        if (layerColor != backColor) {
                            color = layerColor;
                            previousPriority = currentPriority;
                            if (checkBit(blendControl, layer)) {
                                applyBrightnessEffect(colorEffect, color);
                            }
                        }
                    }
                }
            }

            frame[p] = cast(ubyte) ((color & 0b11111) / 31f * 255);
            frame[p + 1] = cast(ubyte) (getBits(color, 5, 9) / 31f * 255);
            frame[p + 2] = cast(ubyte) (getBits(color, 10, 14) / 31f * 255);

            p += COMPONENTS_PER_PIXEL;
        }
    }

    private void applyBrightnessEffect(int colorEffect, ref short first) {
        if (!(colorEffect & 0b10)) {
            return;
        }

        int firstRed = first & 0b11111;
        int firstGreen = getBits(first, 5, 9);
        int firstBlue = getBits(first, 10, 14);

        final switch (colorEffect) {
            case 2:
                int evy = memory.getInt(0x4000054) & 0b11111;
                firstRed += ((31 - firstRed << 4) * evy >> 4) + 8 >> 4;
                firstGreen += ((31 - firstGreen << 4) * evy >> 4) + 8 >> 4;
                firstBlue += ((31 - firstBlue << 4) * evy >> 4) + 8 >> 4;
                break;
            case 3:
                int evy = memory.getInt(0x4000054) & 0b11111;
                firstRed -= ((firstRed << 4) * evy >> 4) + 8 >> 4;
                firstGreen -= ((firstGreen << 4) * evy >> 4) + 8 >> 4;
                firstBlue -= ((firstBlue << 4) * evy >> 4) + 8 >> 4;
                break;
        }

        first = (firstBlue & 31) << 10 | (firstGreen & 31) << 5 | firstRed & 31;
    }

    private short applyBlendEffect(int colorEffect, short first, short second) {
        if (colorEffect != 1) {
            return first;
        }

        int firstRed = first & 0b11111;
        int firstGreen = getBits(first, 5, 9);
        int firstBlue = getBits(first, 10, 14);

        int secondRed = second & 0b11111;
        int secondGreen = getBits(second, 5, 9);
        int secondBlue = getBits(second, 10, 14);

        int blendAlpha = memory.getShort(0x4000052);

        int eva = blendAlpha & 0b11111;
        firstRed = ((firstRed << 4) * eva >> 4) + 8 >> 4;
        firstGreen = ((firstGreen << 4) * eva >> 4) + 8 >> 4;
        firstBlue = ((firstBlue << 4) * eva >> 4) + 8 >> 4;

        int evb = getBits(blendAlpha, 8, 12);
        secondRed = ((secondRed << 4) * evb >> 4) + 8 >> 4;
        secondGreen = ((secondGreen << 4) * evb >> 4) + 8 >> 4;
        secondBlue = ((secondBlue << 4) * evb >> 4) + 8 >> 4;

        int blendRed = min(31, firstRed + secondRed);
        int blendGreen = min(31, firstGreen + secondGreen);
        int blendBlue = min(31, firstBlue + secondBlue);

        return (blendBlue & 31) << 10 | (blendGreen & 31) << 5 | blendRed & 31;
    }

    private Mode getMode() {
        return cast(Mode) (memory.getShort(0x4000000) & 0b111);
    }

    private void setVCOUNT(int vcount) {
        memory.setShort(0x4000006, cast(short) vcount);
        int displayStatus = memory.getShort(0x4000004);
        bool vblank = vcount >= 160 && vcount < 227;
        setBit(displayStatus, 0, vblank);
        bool hblank = true;
        setBit(displayStatus, 1, hblank);
        bool vcounter = getBits(displayStatus, 8, 15) == vcount;
        setBit(displayStatus, 2, vcounter);
        memory.setShort(0x4000004, cast(short) displayStatus);
        int interrupts = memory.getShort(0x4000202);
        if (checkBit(displayStatus, 3) && vblank) {
            setBit(interrupts, 0, 1);
        }
        if (checkBit(displayStatus, 4) && hblank) {
            setBit(interrupts, 1, 1);
        }
        if (checkBit(displayStatus, 5) && vcounter) {
            setBit(interrupts, 2, 1);
        }
        memory.setShort(0x4000202, cast(short) interrupts);
    }
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
    positionsAttribute.setData(cast(ubyte[]) cast(void[]) positions);
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
    textureCoords = (position.xy + 1) / 2;
    gl_Position = vec4(position, 1);
}
`;
private immutable string fragmentShaderSource =
`
// $shader_type: fragment

// $texture_layout: color = 0

#version 120

varying vec2 textureCoords;

uniform sampler2D color;

void main() {
    gl_FragColor = texture2D(color, textureCoords);
}
`;

private enum Mode {
    BACKGROUND_4 = 0,
    BACKGROUND_3 = 1,
    BACKGROUND_2 = 2,
    BITMAP_16_DIRECT_SINGLE = 3,
    BITMAP_8_PALETTE_DOUBLE = 4,
    BITMAP_16_DIRECT_DOUBLE = 5
}
