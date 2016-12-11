module gbaid.graphics;

import gbaid.gl, gbaid.gl20;
import gbaid.shader;
import gbaid.util;

public class Graphics {
    private Context context = null;
    private Program program = null;
    private Texture texture = null;
    private Program upscaleProgram = null;
    private Texture upscaledTexture = null;
    private FrameBuffer upscaleFrameBuffer = null;
    private Texture outputTexture = null;
    private VertexArray vertexArray = null;
    private immutable uint frameWidth, frameHeight;
    private int windowWidth, windowHeight;
    private FilteringMode filteringMode = FilteringMode.NONE;
    private UpscalingMode upscalingMode = UpscalingMode.NONE;

    public this(uint frameWidth, uint frameHeight) {
        this.frameWidth = frameWidth;
        this.frameHeight = frameHeight;
    }

    public void setScale(float scale) {
        windowWidth = cast(uint) (frameWidth * scale + 0.5f);
        windowHeight = cast(uint) (frameHeight * scale + 0.5f);

        if (context !is null) {
            context.setWindowSize(windowWidth, windowHeight);
        }
    }

    public void setFilteringMode(FilteringMode mode) {
        filteringMode = mode;
    }

    public void setUpscalingMode(UpscalingMode mode) {
        upscalingMode = mode;
    }

    public void create() {
        if (context !is null) {
            return;
        }

        scope (failure) {
            destroy();
        }

        context = new GL20Context();
        context.setWindowTitle("GBAiD");
        context.setResizable(true);
        context.setWindowSize(windowWidth, windowHeight);
        context.create();
        context.enableCapability(CULL_FACE);

        program = makeProgram(TEXTURE_POST_PROCESS_VERTEX_SHADER_SOURCE, WINDOW_OUTPUT_FRAGMENT_SHADER_SOURCE);
        program.use();
        program.bindSampler(0);

        texture = makeTexture(RGBA, RGB5_A1, frameWidth, frameHeight);

        final switch (upscalingMode) with (UpscalingMode) {
            case NONE:
                upscaleProgram = null;
                upscaledTexture = null;
                upscaleFrameBuffer = null;
                break;
            case EPX:
                upscaleProgram = makeProgram(TEXTURE_POST_PROCESS_VERTEX_SHADER_SOURCE, EPX_UPSCALE_FRAGMENT_SHADER_SOURCE);
                upscaledTexture = makeTexture(RGBA, RGBA8, frameWidth * 2, frameHeight * 2);
                break;
            case XBR:
                upscaleProgram = makeProgram(TEXTURE_POST_PROCESS_VERTEX_SHADER_SOURCE, XBR_UPSCALE_FRAGMENT_SHADER_SOURCE);
                upscaledTexture = makeTexture(RGBA, RGBA8, frameWidth * 5, frameHeight * 5);
                break;
            case BICUBIC:
                upscaleProgram = makeProgram(TEXTURE_POST_PROCESS_VERTEX_SHADER_SOURCE, BICUBIC_UPSCALE_FRAGMENT_SHADER_SOURCE);
                upscaledTexture = makeTexture(RGBA, RGBA8, windowWidth, windowHeight);
                texture.setWraps(CLAMP_TO_EDGE, CLAMP_TO_EDGE);
                break;
        }
        if (upscaleProgram !is null) {
            upscaleFrameBuffer = context.newFrameBuffer();
            upscaleFrameBuffer.create();
            upscaleFrameBuffer.attach(COLOR_ATTACHMENT0, upscaledTexture);
            if (!upscaleFrameBuffer.isComplete()) {
                throw new GLException("Upscale framebuffer is incomplete");
            }

            upscaleProgram.use();
            upscaleProgram.bindSampler(0);
            upscaleProgram.setUniform("size", frameWidth, frameHeight);
        }

        outputTexture = upscaleProgram !is null ? upscaledTexture : texture;
        final switch (filteringMode) {
            case FilteringMode.NONE:
                outputTexture.setFilters(NEAREST, NEAREST);
                break;
            case FilteringMode.LINEAR:
                outputTexture.setFilters(LINEAR, LINEAR);
                break;
        }

        vertexArray = context.newVertexArray();
        vertexArray.create();
        vertexArray.setData(generatePlane(2, 2));
    }

    public void destroy() {
        if (context is null) {
            return;
        }
        context.destroy();
        context = null;
        program = null;
        texture = null;
        upscaleProgram = null;
        upscaledTexture = null;
        upscaleFrameBuffer = null;
        outputTexture = null;
        vertexArray = null;
    }

    public void draw(void[] frame) {
        if (!context.isCreated()) {
            create();
        }

        context.getWindowSize(&windowWidth, &windowHeight);
        texture.setImageData(cast(ubyte[]) frame, frameWidth, frameHeight);
        texture.bind(0);
        if (upscaleProgram !is null) {
            upscaleProgram.use();
            upscaleFrameBuffer.bind();
            context.setViewPort(0, 0, upscaledTexture.getWidth(), upscaledTexture.getHeight());
            vertexArray.draw();
            upscaleFrameBuffer.unbind();
            upscaledTexture.bind(0);
        }
        program.use();
        program.setUniform("size", windowWidth, windowHeight);
        context.setViewPort(0, 0, windowWidth, windowHeight);
        vertexArray.draw();
        context.updateDisplay();
    }

    public bool isCloseRequested() {
        return context.isWindowCloseRequested();
    }

    private Program makeProgram(string vertexShaderSource, string fragmentShaderSource) {
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
        return program;
    }

    private Texture makeTexture(Format format, InternalFormat internalFormat, int width, int height) {
        Texture texture = context.newTexture();
        texture.create();
        texture.setFormat(format, internalFormat);
        texture.setWraps(CLAMP_TO_BORDER, CLAMP_TO_BORDER);
        texture.setBorderColor(0, 0, 0, 1);
        texture.setFilters(NEAREST, NEAREST);
        texture.setImageData(null, width, height);
        return texture;
    }
}

public enum FilteringMode {
    NONE,
    LINEAR
}

public enum UpscalingMode {
    NONE,
    EPX,
    XBR,
    BICUBIC
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
