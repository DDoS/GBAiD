module gbaid.graphics;

import core.thread;
import core.time;

import gbaid.memory;
import gbaid.gl, gbaid.gl20;
import gbaid.util;

public class Display {
    private static immutable uint HORIZONTAL_RESOLUTION = 240;
    private static immutable uint VERTICAL_RESOLUTION = 160;
    private static immutable uint SCREEN_AREA = HORIZONTAL_RESOLUTION * VERTICAL_RESOLUTION;
    private static immutable uint BYTES_PER_PIXEL = 2;
    private static immutable uint COMPONENTS_PER_PIXEL = 3;
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
        uint i = 0x6000000, p = 0;
        for (ushort line = 0; line < VERTICAL_RESOLUTION; line++) {
            setVCOUNT(line);
            for (ushort column = 0; column < HORIZONTAL_RESOLUTION; column++) {
                short pixel = memory.getShort(i);
                frame[p] = cast(ubyte) (getBits(pixel, 0, 4) / 31f * 255);
                frame[p + 1] = cast(ubyte) (getBits(pixel, 5, 9) / 31f * 255);
                frame[p + 2] = cast(ubyte) (getBits(pixel, 10, 14) / 31f * 255);
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

    private void setVCOUNT(short vcount) {
        memory.setShort(0x4000006, vcount);
        int displayStatus = memory.getShort(0x4000004);
        bool vblank = vcount >= 160 && vcount < 227;
        setBit(displayStatus, 0, vblank);
        bool hblank = true;
        setBit(displayStatus, 1, hblank);
        bool vcounter = getBits(displayStatus, 8, 15) == vcount;
        setBit(displayStatus, 2, vcounter);
        memory.setShort(0x4000004, cast(short) displayStatus);
        int interrupts = memory.getShort(0x4000202);
        setBit(interrupts, 0, checkBit(displayStatus, 3) && vblank);
        setBit(interrupts, 1, checkBit(displayStatus, 4) && hblank);
        setBit(interrupts, 2, checkBit(displayStatus, 5) && vcounter);
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
    gl_FragColor = vec4(texture2D(color, textureCoords).rgb, 1);
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
