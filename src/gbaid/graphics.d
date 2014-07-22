module gbaid.graphics;

import gbaid.memory;
import gbaid.gl, gbaid.gl20;

public class Display {
    private static immutable uint HORIZONTAL_RESOLUTION = 240;
    private static immutable uint VERTICAL_RESOLUTION = 160;
    private static immutable uint AREA = HORIZONTAL_RESOLUTION * VERTICAL_RESOLUTION;
    private static immutable uint BYTES_PER_PIXEL = 2;
    private static immutable uint FRAME_SIZE = AREA * BYTES_PER_PIXEL;
    private Memory memory;
    private Context context;
    private Program program;
    private Texture texture;
    private VertexArray vertexArray;
    private ubyte[FRAME_SIZE] frame = new ubyte[FRAME_SIZE];

    public this() {
        context = new GL20Context();
        context.create();

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
        program.bindSampler(0);

        texture = context.newTexture();
        texture.setFormat(RGB, RGB8);

        vertexArray = context.newVertexArray();
        vertexArray.create();
        vertexArray.setData(generatePlane(2, 2));
    }

    public ~this() {
        program.destroy();
        texture.destroy();
        vertexArray.destroy();
        context.destroy();
    }

    public void setMemory(Memory memory) {
        this.memory = memory;
    }

    public void run() {
        
    }

    private void update() {
        uint i = 0x6000000, p = 0;
        for (ushort line = 0; line <= VERTICAL_RESOLUTION; line++) {
            memory.setShort(0x4000006, line);
            for (ushort column = 0; column <= HORIZONTAL_RESOLUTION; column++) {
                short pixel = memory.getShort(i);
                frame[p] = pixel & 0xFF;
                frame[p + 1] = pixel >> 8 & 0xFF;
                i += 2;
                p += 2;
            }
        }
        memory.setShort(0x4000006, 161);
        texture.setImageData(frame, HORIZONTAL_RESOLUTION, VERTICAL_RESOLUTION);
        texture.bind(0);
        program.use();
        vertexArray.draw();
        context.updateDisplay();
        memory.setShort(0x4000006, 227);
    }
}

private VertexData generatePlane(uint width, uint height) {
    width /= 2;
    height /=2;
    VertexData vertexData = new VertexData();
    VertexAttribute positionsAttribute = new VertexAttribute("positions", FLOAT, 3);
    vertexData.addAttribute(0, positionsAttribute);
    float[] positions = [
        width, height, 0,
        -width, height, 0,
        width, -height, 0,
        -width, -height, 0
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

attribute vec2 position;

varying vec2 textureCoords;

void main() {
    textureCoords = (position + 1) / 2;
    gl_Position = vec4(position, 0, 1);
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
