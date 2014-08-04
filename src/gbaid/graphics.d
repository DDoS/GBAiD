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
    private static immutable uint BYTES_PER_PIXEL = 2;
    private static immutable uint COMPONENTS_PER_PIXEL = 4;
    private static immutable uint BYTES_PER_COMPONENT = 1;
    private static immutable uint FRAME_SIZE = SCREEN_AREA * COMPONENTS_PER_PIXEL * BYTES_PER_COMPONENT;
    private Memory memory;
    private Context context;
    private Program program;
    private Texture texture;
    private VertexArray vertexArray;
    private ubyte[FRAME_SIZE] frame = new ubyte[FRAME_SIZE];

    public void setMemory(Memory memory) {
        this.memory = memory;
    }

    public void run() {
        context = new GL20Context();
        context.setWindowSize(HORIZONTAL_RESOLUTION, VERTICAL_RESOLUTION);
        context.setWindowTitle("GBAiD");
        context.create();
        context.enableCapability(CULL_FACE);
        context.enableCapability(BLEND);
        context.setBlendingFunctions(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

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
        texture.setFormat(RGBA, RGBA8);
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
                    update0();
                    break;
                case Mode.BACKGROUND_2:
                    update2();
                    break;
                case Mode.BITMAP_16_DIRECT_SINGLE:
                    update3();
                    break;
                case Mode.BITMAP_8_PALETTE_DOUBLE:
                    update3();
                    break;
                case Mode.BITMAP_16_DIRECT_DOUBLE:
                    update3();
                    break;
            }
        }
    }

    private void updateBlank() {
        uint p = 0;
        for (int line = 0; line < VERTICAL_RESOLUTION; line++) {
            setVCOUNT(line);
            for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
                frame[p] = 255;
                frame[p + 1] = 255;
                frame[p + 2] = 255;
                frame[p + 3] = 255;
                p += COMPONENTS_PER_PIXEL;
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

    private void update0() {
        int backColor = memory.getShort(0x5000000);
        float backRed = getBits(backColor, 0, 4) / 31f;
        float backGreen = getBits(backColor, 5, 9) / 31f;
        float backBlue = getBits(backColor, 10, 14) / 31f;

        context.setClearColor(backRed, backGreen, backBlue, 0);
        context.clearCurrentBuffer();

        int[] bgControlAddresses = [0x4000008, 0x400000A, 0x400000C, 0x400000E];

        auto lessThan = &bgLessThan;
        sort!lessThan(bgControlAddresses);

        int bgEnables = getBits(memory.getShort(0x4000000), 8, 11);

        immutable uint tileCount = 32;
        immutable uint tileLength = 8;
        immutable uint bgSize = tileCount * tileLength;

        uint p = 0;

        for (int line = 0; line < VERTICAL_RESOLUTION; line++) {

            setVCOUNT(line);

            for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {

                for (int layer = 0; layer < 4; layer++) {

                    if (!(bgEnables & 1 << layer)) {
                        continue;
                    }

                    int bgControl = memory.getShort(bgControlAddresses[layer]);

                    int tileBase = getBits(bgControl, 2, 3) * 16 * BYTES_PER_KIB + 0x6000000;
                    int mosaic = getBit(bgControl, 6);
                    int singlePalette = getBit(bgControl, 7);
                    int mapBase = getBits(bgControl, 8, 12) * 2 * BYTES_PER_KIB + 0x6000000;
                    int screenSize = getBits(bgControl, 14, 15);

                    int tile4Bit = singlePalette ? 1 : 2;
                    int tileSize = tileLength * tileLength / tile4Bit;

                    int layerAddressOffset = layer * 4;
                    int xOffset = memory.getShort(0x4000010 + layerAddressOffset) & 0x1FF;
                    int yOffset = memory.getShort(0x4000012 + layerAddressOffset) & 0x1FF;

                    int x = column + xOffset;
                    int y = line + yOffset;

                    if (mosaic) {
                        int mosaicControl = memory.getInt(0x400004C);
                        int hSize = (mosaicControl & 0b1111) + 1;
                        int vSize = getBits(mosaicControl, 4, 7) + 1;

                        x /= hSize;
                        x *= hSize;

                        y /= vSize;
                        y *= vSize;
                    }

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

                    if (paletteAddress != 0) {
                        int color = memory.getShort(0x5000000 + paletteAddress);
                        frame[p] = cast(ubyte) (getBits(color, 0, 4) / 31f * 255);
                        frame[p + 1] = cast(ubyte) (getBits(color, 5, 9) / 31f * 255);
                        frame[p + 2] = cast(ubyte) (getBits(color, 10, 14) / 31f * 255);
                        frame[p + 3] = 255;
                    }
                }

                p += 4;
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

    private void update2() {
        int backColor = memory.getShort(0x5000000);
        float backRed = getBits(backColor, 0, 4) / 31f;
        float backGreen = getBits(backColor, 5, 9) / 31f;
        float backBlue = getBits(backColor, 10, 14) / 31f;

        context.setClearColor(backRed, backGreen, backBlue, 0);
        context.clearCurrentBuffer();

        int[] bgControlAddresses = [0x400000C, 0x400000E];

        auto lessThan = &bgLessThan;
        sort!lessThan(bgControlAddresses);

        int bgEnables = getBits(memory.getShort(0x4000000), 10, 11);

        immutable uint tileLength = 8;
        immutable uint tileSize = tileLength * tileLength;

        uint p = 0;

        for (int line = 0; line < VERTICAL_RESOLUTION; line++) {

            setVCOUNT(line);

            for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {

                for (int layer = 0; layer < 2; layer++) {

                    if (!(bgEnables & 1 << layer)) {
                        continue;
                    }

                    int bgControl = memory.getShort(bgControlAddresses[layer]);

                    int tileBase = getBits(bgControl, 2, 3) * 16 * BYTES_PER_KIB + 0x6000000;
                    int mosaic = getBit(bgControl, 6);
                    int mapBase = getBits(bgControl, 8, 12) * 2 * BYTES_PER_KIB + 0x6000000;
                    int displayOverflow = getBit(bgControl, 13);
                    int screenSize = getBits(bgControl, 14, 15);

                    uint tileCount = 16 * (1 << screenSize);
                    uint bgSize = tileCount * tileLength;

                    int layerAddressOffset = layer * 16;
                    int pa = memory.getShort(0x4000020 + layerAddressOffset);
                    int pc = memory.getShort(0x4000022 + layerAddressOffset);
                    int pb = memory.getShort(0x4000024 + layerAddressOffset);
                    int pd = memory.getShort(0x4000026 + layerAddressOffset);
                    int refX = memory.getInt(0x4000028 + layerAddressOffset) & 0xFFFFFFF;
                    refX <<= 4;
                    refX >>= 4;
                    int refY = memory.getInt(0x400002C + layerAddressOffset) & 0xFFFFFFF;
                    refY <<= 4;
                    refY >>= 4;

                    int x = (pa * ((column << 8) - refX) >> 8) + (pc * ((line << 8) - refY) >> 8) + refX;
                    int y = (pc * ((column << 8) - refX) >> 8) + (pd * ((line << 8) - refY) >> 8) + refY;

                    x = x + 128 >> 8;
                    y = y + 128 >> 8;

                    if (mosaic) {
                        int mosaicControl = memory.getInt(0x400004C);
                        int hSize = (mosaicControl & 0b1111) + 1;
                        int vSize = getBits(mosaicControl, 4, 7) + 1;

                        x /= hSize;
                        x *= hSize;

                        y /= vSize;
                        y *= vSize;
                    }

                    if (x > bgSize) {
                        if (displayOverflow) {
                            x %= bgSize;
                        } else {
                            continue;
                        }
                    }

                    if (y > bgSize) {
                        if (displayOverflow) {
                            y %= bgSize;
                        } else {
                            continue;
                        }
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
                        continue;
                    }

                    int color = memory.getShort(0x5000000 + paletteAddress);
                    frame[p] = cast(ubyte) (getBits(color, 0, 4) / 31f * 255);
                    frame[p + 1] = cast(ubyte) (getBits(color, 5, 9) / 31f * 255);
                    frame[p + 2] = cast(ubyte) (getBits(color, 10, 14) / 31f * 255);
                    frame[p + 3] = 255;
                }

                p += 4;
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

    private void update3() {
        uint i = 0x6000000, p = 0;
        for (int line = 0; line < VERTICAL_RESOLUTION; line++) {
            setVCOUNT(line);
            for (int column = 0; column < HORIZONTAL_RESOLUTION; column++) {
                int pixel = memory.getShort(i);
                frame[p] = cast(ubyte) (getBits(pixel, 0, 4) / 31f * 255);
                frame[p + 1] = cast(ubyte) (getBits(pixel, 5, 9) / 31f * 255);
                frame[p + 2] = cast(ubyte) (getBits(pixel, 10, 14) / 31f * 255);
                frame[p + 3] = 255;
                i += BYTES_PER_PIXEL;
                p += COMPONENTS_PER_PIXEL;
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

    protected bool bgLessThan(int bgA, int bgB) {
        int bgAPriority = memory.getShort(bgA) & 0b11;
        int bgBPriority = memory.getShort(bgB) & 0b11;
        if (bgAPriority == bgBPriority) {
            return bgA < bgB;
        }
        return bgAPriority < bgBPriority;
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
