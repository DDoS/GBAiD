module gbaid.gl;

import std.regex;
import std.file;
import std.string;
import std.conv;
import derelict.opengl3.gl3 : glGetError;

/**
 * Represents an object that has an OpenGL version associated to it.
 */
public interface GLVersioned {
    /**
     * Returns the lowest OpenGL version required by this object's implementation.
     *
     * @return The lowest required OpenGL version
     */
    public GLVersion getGLVersion();
}

public enum : GLVersion {
    GL11 = new GLVersion(1, 1, false, 0, 0),
    GL12 = new GLVersion(1, 2, false, 0, 0),
    GL13 = new GLVersion(1, 3, false, 0, 0),
    GL14 = new GLVersion(1, 4, false, 0, 0),
    GL15 = new GLVersion(1, 5, false, 0, 0),
    GL20 = new GLVersion(2, 0, false, 1, 1),
    GL21 = new GLVersion(2, 1, false, 1, 2),
    GL30 = new GLVersion(3, 0, false, 1, 3),
    GL31 = new GLVersion(3, 1, false, 1, 4),
    GL32 = new GLVersion(3, 2, false, 1, 5),
    GL33 = new GLVersion(3, 3, false, 3, 3),
    GL40 = new GLVersion(4, 0, false, 4, 0),
    GL41 = new GLVersion(4, 1, false, 4, 1),
    GL42 = new GLVersion(4, 2, false, 4, 2),
    GL43 = new GLVersion(4, 3, false, 4, 3),
    GL44 = new GLVersion(4, 4, false, 4, 4),
    GLES10 = new GLVersion(1, 0, true, 1, 0),
    GLES11 = new GLVersion(1, 1, true, 1, 0),
    GLES20 = new GLVersion(2, 0, true, 1, 0),
    GLES30 = new GLVersion(3, 0, true, 3, 0),
    GLES31 = new GLVersion(3, 1, true, 3, 0),
    SOFTWARE = new GLVersion(0, 0, false, 0, 0),
    OTHER = new GLVersion(0, 0, false, 0, 0)
}

/**
 * An enum of the existing OpenGL versions. Use this class to generate rendering objects compatible with the version.
 */
public final class GLVersion {
    private immutable uint major;
    private immutable uint minor;
    private immutable bool es;
    private immutable uint glslMajor;
    private immutable uint glslMinor;

    private this(uint major, uint minor, bool es, uint glslMajor, uint glslMinor) {
        this.major = major;
        this.minor = minor;
        this.es = es;
        this.glslMajor = glslMajor;
        this.glslMinor = glslMinor;
    }

    /**
     * Returns the full version number of the version.
     *
     * @return The full version number
     */
    public uint getFull() {
        return major * 10 + minor;
    }

    /**
     * Returns the major version number of the version.
     *
     * @return The major version number
     */
    public uint getMajor() {
        return major;
    }

    /**
     * Returns the minor version number of the version.
     *
     * @return The minor version number
     */
    public uint getMinor() {
        return minor;
    }

    /**
     * Returns true if the version is ES compatible, false if not.
     *
     * @return Whether or not this is an ES compatible version
     */
    public bool isES() {
        return es;
    }

    /**
     * Returns the full GLSL version available with the OpenGL version.
     *
     * @return The GLSL version
     */
    public uint getGLSLFull() {
        return glslMajor * 100 + glslMinor * 10;
    }

    /**
     * Returns the GLSL major version available with the OpenGL version. This version number is 0 if GLSL isn't supported.
     *
     * @return The GLSL major version, or 0 for unsupported
     */
    public uint getGLSLMajor() {
        return glslMajor;
    }

    /**
     * Returns the GLSL minor version available with the OpenGL version.
     *
     * @return The GLSL minor version
     */
    public uint getGLSLMinor() {
        return glslMinor;
    }

    /**
     * Returns true if this version supports GLSL, false if not.
     *
     * @return Whether or not this version supports GLSL
     */
    public bool supportsGLSL() {
        return glslMajor != 0;
    }
}

/**
 * Represents a resource that can be created and destroyed.
 */
public abstract class Creatable {
    private bool created = false;

    /**
     * Creates the resources. It can now be used.
     */
    public void create() {
        created = true;
    }

    /**
     * Releases the resource. It can not longer be used.
     */
    public void destroy() {
        created = false;
    }

    /**
     * Returns true if the resource was created and is ready for use, false if otherwise.
     *
     * @return Whether or not the resource has been created
     */
    public bool isCreated() {
        return created;
    }

    /**
     * Throws an exception if the resource hasn't been created yet.
     *
     * @throws IllegalStateException if the resource hasn't been created
     */
    public void checkCreated() {
        if (!isCreated()) {
            throw new Exception("Resource has not been created yet");
        }
    }

    /**
     * Throws an exception if the resource has been created already.
     *
     * @throws IllegalStateException if the resource has been created
     */
    public void checkNotCreated() {
        if (isCreated()) {
            throw new Exception("Resource has been created already");
        }
    }
}

/**
 * Represents an OpenGL context. Creating context must be done before any other OpenGL object.
 */
public abstract class Context : Creatable, GLVersioned {
    protected int msaa = -1;

    public override void destroy() {
        super.destroy();
    }

    /**
     * Creates a new frame buffer.
     *
     * @return A new frame buffer
     */
    public abstract FrameBuffer newFrameBuffer();

    /**
     * Creates a new program.
     *
     * @return A new program
     */
    public abstract Program newProgram();

    /**
     * Creates a new render buffer.
     *
     * @return A new render buffer
     */
    public abstract RenderBuffer newRenderBuffer();

    /**
     * Creates a new shader.
     *
     * @return A new shader
     */
    public abstract Shader newShader();

    /**
     * Creates a new texture.
     *
     * @return A new texture
     */
    public abstract Texture newTexture();

    /**
     * Creates a new vertex array.
     *
     * @return A new vertex array
     */
    public abstract VertexArray newVertexArray();

    /**
     * Returns the window title.
     *
     * @return The window title
     */
    public abstract string getWindowTitle();

    /**
     * Sets the window title to the desired one.
     *
     * @param title The window title
     */
    public abstract void setWindowTitle(string title);

    /**
     * Sets the window size.
     *
     * @param width The width
     * @param height The height
     */
    public abstract void setWindowSize(uint width, uint height);

    /**
     * Returns the window width.
     *
     * @return The window width
     */
    public abstract uint getWindowWidth();

    /**
     * Returns the window height.
     *
     * @return The window height
     */
    public abstract uint getWindowHeight();

    /**
     * Updates the display with the current front (screen) buffer.
     */
    public abstract void updateDisplay();

    /**
     * Sets the renderer buffer clear color. This can be interpreted as the background color.
     *
     * @param color The clear color
     */
    public abstract void setClearColor(float red, float green, float blue, float alpha);

    /**
     * Clears the currently bound buffer (either a frame buffer, or the front (screen) buffer if none are bound).
     */
    public abstract void clearCurrentBuffer();

    /**
     * Disables the capability.
     *
     * @param capability The capability to disable
     */
    public abstract void disableCapability(Capability capability);

    /**
     * Enables the capability.
     *
     * @param capability The capability to enable
     */
    public abstract void enableCapability(Capability capability);

    /**
     * Enables or disables writing into the depth buffer.
     *
     * @param enabled Whether or not to write into the depth buffer.
     */
    public abstract void setDepthMask(bool enabled);

    /**
     * Sets the blending functions for the source and destination buffers, for all buffers. Blending must be enabled with {@link #enableCapability(org.spout.renderer.api.gl.Context.Capability)}.
     *
     * @param source The source function
     * @param destination The destination function
     */
    public void setBlendingFunctions(BlendFunction source, BlendFunction destination) {
        setBlendingFunctions(-1, source, destination);
    }

    /**
     * Sets the blending functions for the source and destination buffer at the index. Blending must be enabled with {@link #enableCapability(org.spout.renderer.api.gl.Context.Capability)}.
     * <p/>
     * Support for specifying the buffer index is only available in GL40.
     *
     * @param bufferIndex The index of the target buffer
     * @param source The source function
     * @param destination The destination function
     */
    public abstract void setBlendingFunctions(int bufferIndex, BlendFunction source, BlendFunction destination);

    /**
     * Sets the render view port, which is the dimensions and position of the frame inside the window.
     *
     * @param x The x coordinate
     * @param y The y coordinate
     * @param width The width
     * @param height The height
     */
    public abstract void setViewPort(uint x, uint y, uint width, uint height);

    /**
     * Reads the current frame pixels and returns it as a byte buffer of the desired format. The size of the returned image data is the same as the current window dimensions.
     *
     * @param x The x coordinate
     * @param y The y coordinate
     * @param width The width
     * @param height The height
     * @param format The image format to return
     * @return The byte array containing the pixel data, according to the provided format
     */
    public abstract ubyte[] readFrame(uint x, uint y, uint width, uint height, InternalFormat format);

    /**
     * Returns true if an external process (such as the user) is requesting for the window to be closed. This value is reset once this method has been called.
     *
     * @return Whether or not the window is being requested to close
     */
    public abstract bool isWindowCloseRequested();

    /**
     * Sets the MSAA value. Must be greater or equal to zero. Zero means no MSAA.
     *
     * @param value The MSAA value, greater or equal to zero
     */
    public void setMSAA(int value) {
        if (value < 0) {
            throw new Exception("MSAA value must be greater or equal to zero");
        }
        this.msaa = value;
    }
}

public enum : Capability {
    BLEND = new Capability(0xBE2), // GL11.GL_BLEND
    CULL_FACE = new Capability(0xB44), // GL11.GL_CULL_FACE
    DEPTH_CLAMP = new Capability(0x864F), // GL32.GL_DEPTH_CLAMP
    DEPTH_TEST = new Capability(0xB71) // GL11.GL_DEPTH_TEST
}

/**
 * An enum of the renderer capabilities.
 */
public final class Capability {
    private immutable uint glConstant;

    private this(uint glConstant) {
        this.glConstant = glConstant;
    }

    /**
     * Returns the OpenGL constant associated to the capability.
     *
     * @return The OpenGL constant
     */
    public uint getGLConstant() {
        return glConstant;
    }
}

public enum : BlendFunction {
    GL_ZERO = new BlendFunction(0x0), // GL11.GL_ZERO
    GL_ONE = new BlendFunction(0x1), // GL11.GL_ONE
    GL_SRC_COLOR = new BlendFunction(0x300), // GL11.GL_SRC_COLOR
    GL_ONE_MINUS_SRC_COLOR = new BlendFunction(0x301), // GL11.GL_ONE_MINUS_SRC_COLOR
    GL_DST_COLOR = new BlendFunction(0x306), // GL11.GL_DST_COLOR
    GL_ONE_MINUS_DST_COLOR = new BlendFunction(0x307), // GL11.GL_ONE_MINUS_DST_COLOR
    GL_SRC_ALPHA = new BlendFunction(0x302), // GL11.GL_SRC_ALPHA
    GL_ONE_MINUS_SRC_ALPHA = new BlendFunction(0x303), // GL11.GL_ONE_MINUS_SRC_ALPHA
    GL_DST_ALPHA = new BlendFunction(0x304), // GL11.GL_DST_ALPHA
    GL_ONE_MINUS_DST_ALPHA = new BlendFunction(0x305), // GL11.GL_ONE_MINUS_DST_ALPHA
    GL_CONSTANT_COLOR = new BlendFunction(0x8001), // GL11.GL_CONSTANT_COLOR
    GL_ONE_MINUS_CONSTANT_COLOR = new BlendFunction(0x8002), // GL11.GL_ONE_MINUS_CONSTANT_COLOR
    GL_CONSTANT_ALPHA = new BlendFunction(0x8003), // GL11.GL_CONSTANT_ALPHA
    GL_ONE_MINUS_CONSTANT_ALPHA = new BlendFunction(0x8004), // GL11.GL_ONE_MINUS_CONSTANT_ALPHA
    GL_SRC_ALPHA_SATURATE = new BlendFunction(0x308), // GL11.GL_SRC_ALPHA_SATURATE
    GL_SRC1_COLOR = new BlendFunction(0x88F9), // GL33.GL_SRC1_COLOR
    GL_ONE_MINUS_SRC1_COLOR = new BlendFunction(0x88FA), // GL33.GL_ONE_MINUS_SRC1_COLOR
    GL_SRC1_ALPHA = new BlendFunction(0x8589), // GL33.GL_SRC1_ALPHA
    GL_ONE_MINUS_SRC1_ALPHA = new BlendFunction(0x88FB) // GL33.GL_ONE_MINUS_SRC1_ALPHA
}

/**
 * An enum of the blending functions.
 */
public final class BlendFunction {
    private immutable uint glConstant;

    private this(uint glConstant) {
        this.glConstant = glConstant;
    }

    /**
     * Returns the OpenGL constant associated to the blending function.
     *
     * @return The OpenGL constant
     */
    public uint getGLConstant() {
        return glConstant;
    }
}

/**
 * Represents an OpenGL frame buffer. A frame buffer can be bound before rendering to redirect the output to textures instead of the screen. This is meant for advanced rendering techniques such as
 * shadow mapping and screen space ambient occlusion (SSAO).
 */
public abstract class FrameBuffer : Creatable, GLVersioned {
    protected uint id;

    public override void destroy() {
        id = 0;
        super.destroy();
    }

    /**
     * Binds the frame buffer to the OpenGL context.
     */
    public abstract void bind();

    /**
     * Unbinds the frame buffer from the OpenGL context.
     */
    public abstract void unbind();

    /**
     * Attaches the texture to the frame buffer attachment point.
     *
     * @param point The attachment point
     * @param texture The texture to attach
     */
    public abstract void attach(AttachmentPoint point, Texture texture);

    /**
     * Attaches the render buffer to the attachment point
     *
     * @param point The attachment point
     * @param buffer The render buffer
     */
    public abstract void attach(AttachmentPoint point, RenderBuffer buffer);

    /**
     * Detaches the texture or render buffer from the attachment point
     *
     * @param point The attachment point
     */
    public abstract void detach(AttachmentPoint point);

    /**
     * Returns true if the frame buffer is complete, false if otherwise.
     *
     * @return Whether or not the frame buffer is complete
     */
    public abstract bool isComplete();

    /**
     * Gets the ID for this frame buffer as assigned by OpenGL.
     *
     * @return The ID
     */
    public uint getId() {
        return id;
    }
}

public enum : AttachmentPoint {
    COLOR_ATTACHMENT0 = new AttachmentPoint(0x8CE0, true), // GL30.GL_COLOR_ATTACHMENT0
    COLOR_ATTACHMENT1 = new AttachmentPoint(0x8CE1, true), // GL30.GL_COLOR_ATTACHMENT1
    COLOR_ATTACHMENT2 = new AttachmentPoint(0x8CE2, true), // GL30.GL_COLOR_ATTACHMENT2
    COLOR_ATTACHMENT3 = new AttachmentPoint(0x8CE3, true), // GL30.GL_COLOR_ATTACHMENT3
    COLOR_ATTACHMENT4 = new AttachmentPoint(0x8CE4, true), // GL30.GL_COLOR_ATTACHMENT4
    DEPTH_ATTACHMENT = new AttachmentPoint(0x8D00, false), // GL30.GL_DEPTH_ATTACHMENT
    STENCIL_ATTACHMENT = new AttachmentPoint(0x8D20, false), // GL30.GL_STENCIL_ATTACHMENT
    DEPTH_STENCIL_ATTACHMENT = new AttachmentPoint(0x821A, false) // GL30.GL_DEPTH_STENCIL_ATTACHMENT
}

/**
 * An enum of the possible frame buffer attachment points.
 */
public final class AttachmentPoint {
    private immutable uint glConstant;
    private immutable bool color;

    private this(uint glConstant, bool color) {
        this.glConstant = glConstant;
        this.color = color;
    }

    /**
     * Gets the OpenGL constant for this attachment point.
     *
     * @return The OpenGL Constant
     */
    public uint getGLConstant() {
        return glConstant;
    }

    /**
     * Returns true if the attachment point is a color attachment.
     *
     * @return Whether or not the attachment is a color attachment
     */
    public bool isColor() {
        return color;
    }
}

/**
 * Represents an OpenGL program. A program holds the necessary shaders for the rendering pipeline. When using GL20, it is strongly recommended to set the attribute layout in the {@link
 * org.spout.renderer.api.gl.Shader}s with {@link org.spout.renderer.api.gl.Shader#setAttributeLayout(String, int)}}, which must be done before attaching it. The layout allows for association between
 * the attribute index in the vertex data and the name in the shaders. For GL30, it is recommended to do so in the shaders instead, using the "layout" keyword. Failing to do so might result in
 * partial, wrong or missing rendering, and affects models using multiple attributes. The texture layout should also be setup using {@link Shader#setTextureLayout(int, String)} in the same way.
 */
public abstract class Program : Creatable, GLVersioned {
    protected uint id;

    public override void destroy() {
        id = 0;
        super.destroy();
    }

    /**
     * Attaches a shader to the program.
     *
     * @param shader The shader to attach
     */
    public abstract void attachShader(Shader shader);

    /**
     * Detaches a shader from the shader.
     *
     * @param shader The shader to detach
     */
    public abstract void detachShader(Shader shader);

    /**
     * Links the shaders together in the program. This makes it usable.
     */
    public abstract void link();

    /**
     * Binds this program to the OpenGL context.
     */
    public abstract void use();

    /**
     * Binds the sampler to the texture unit. The binding is done according to the texture layout, which must be set in the program for the textures that will be used before any binding can be done.
     *
     * @param unit The unit to bind
     */
    public abstract void bindSampler(uint unit);

    /**
     * Sets a uniform boolean in the shader to the desired value.
     *
     * @param name The name of the uniform to set
     * @param b The boolean value
     */
    public abstract void setUniform(string name, bool b);

    /**
     * Sets a uniform integer in the shader to the desired value.
     *
     * @param name The name of the uniform to set
     * @param i The integer value
     */
    public abstract void setUniform(string name, int i);

    /**
     * Sets a uniform float in the shader to the desired value.
     *
     * @param name The name of the uniform to set
     * @param f The float value
     */
    public abstract void setUniform(string name, float f);

    /**
     * Sets a uniform float array in the shader to the desired value.
     *
     * @param name The name of the uniform to set
     * @param fs The float array value
     */
    public abstract void setUniform(string name, float[] fs);

    /**
     * Sets a uniform {@link com.flowpowered.math.vector.Vector2f} in the shader to the desired value.
     *
     * @param name The name of the uniform to set
     * @param v The vector value
     */
    public abstract void setUniform(string name, float x, float y);

    /**
     * Sets a uniform {@link com.flowpowered.math.vector.Vector3f} in the shader to the desired value.
     *
     * @param name The name of the uniform to set
     * @param v The vector value
     */
    public abstract void setUniform(string name, float x, float y, float z);

    /**
     * Sets a uniform {@link com.flowpowered.math.vector.Vector4f} in the shader to the desired value.
     *
     * @param name The name of the uniform to set
     * @param v The vector value
     */
    public abstract void setUniform(string name, float x, float y, float z, float w);

    /**
     * Sets a uniform {@link com.flowpowered.math.matrix.Matrix4f} in the shader to the desired value.
     *
     * @param name The name of the uniform to set
     * @param m The matrix value
     */
    public abstract void setUniform(string name, ref float[4] m);

    /**
     * Sets a uniform {@link com.flowpowered.math.matrix.Matrix4f} in the shader to the desired value.
     *
     * @param name The name of the uniform to set
     * @param m The matrix value
     */
    public abstract void setUniform(string name, ref float[9] m);

    /**
     * Sets a uniform {@link com.flowpowered.math.matrix.Matrix4f} in the shader to the desired value.
     *
     * @param name The name of the uniform to set
     * @param m The matrix value
     */
    public abstract void setUniform(string name, ref float[16] m);

    /**
     * Returns the shaders that have been attached to this program.
     *
     * @return The attached shaders
     */
    public abstract Shader[] getShaders();

    /**
     * Returns an set containing all of the uniform names for this program.
     *
     * @return A set of all the uniform names
     */
    public abstract string[] getUniformNames();

    /**
     * Gets the ID for this program as assigned by OpenGL.
     *
     * @return The ID
     */
    public uint getID() {
        return id;
    }
}

/**
 * Represents an OpenGL render buffer. A render buffer can be used as a faster alternative to a texture in a frame buffer when its rendering output doesn't need to be read. The storage format, width
 * and height dimensions need to be set with {@link #setStorage(org.spout.renderer.api.gl.Texture.InternalFormat, int, int)}, before the render buffer can be used.
 */
public abstract class RenderBuffer : Creatable, GLVersioned {
    protected uint id;

    public override void destroy() {
        id = 0;
        super.destroy();
    }

    /**
     * Sets the render buffer storage.
     *
     * @param format The format
     * @param width The width
     * @param height The height
     */
    public abstract void setStorage(InternalFormat format, uint width, uint height);

    /**
     * Returns the render buffer format.
     *
     * @return The format
     */
    public abstract InternalFormat getFormat();

    /**
     * Returns the render buffer width.
     *
     * @return The width
     */
    public abstract uint getWidth();

    /**
     * Returns the render buffer height.
     *
     * @return The height
     */
    public abstract uint getHeight();

    /**
     * Binds the render buffer to the OpenGL context.
     */
    public abstract void bind();

    /**
     * Unbinds the render buffer from the OpenGL context.
     */
    public abstract void unbind();

    /**
     * Gets the ID for this render buffer as assigned by OpenGL.
     *
     * @return The ID
     */
    public uint getID() {
        return id;
    }
}

/**
 * Represents an OpenGL shader. The shader source and type must be set with {@link #setSource(ShaderSource)}.
 */
public abstract class Shader : Creatable, GLVersioned {
    protected uint id;

    public override void destroy() {
        id = 0;
        // Update the state
        super.destroy();
    }

    /**
     * Sets the shader source.
     *
     * @param source The shader source
     */
    public abstract void setSource(ShaderSource source);

    /**
     * Compiles the shader.
     */
    public abstract void compile();

    /**
     * Gets the shader type.
     *
     * @return The shader type
     */
    public abstract ShaderType getType();

    /**
     * Returns the attribute layouts parsed from the tokens in the shader source.
     *
     * @return A map of the attribute name to the layout index.
     */
    public abstract uint[string] getAttributeLayouts();

    /**
     * Returns the texture layouts parsed from the tokens in the shader source.
     *
     * @return A map of the texture name to the layout index.
     */
    public abstract string[uint] getTextureLayouts();

    /**
     * Sets an attribute layout.
     *
     * @param attribute The name of the attribute
     * @param layout The layout for the attribute
     */
    public abstract void setAttributeLayout(string attribute, uint layout);

    /**
     * Sets a texture layout.
     *
     * @param unit The unit for the sampler
     * @param sampler The sampler name
     */
    public abstract void setTextureLayout(uint unit, string sampler);

    /**
     * Gets the ID for this shader as assigned by OpenGL.
     *
     * @return The ID
     */
    public uint getID() {
        return id;
    }
}

public enum : ShaderType {
    FRAGMENT = new ShaderType(0x8B30), // GL20.GL_FRAGMENT_SHADER
    VERTEX = new ShaderType(0x8B31), // GL20.GL_VERTEX_SHADER
    GEOMETRY = new ShaderType(0x8DD9), // GL32.GL_GEOMETRY_SHADER
    TESS_EVALUATION = new ShaderType(0x8E87), // GL40.GL_TESS_EVALUATION_SHADER
    TESS_CONTROL = new ShaderType(0x8E88), // GL40.GL_TESS_CONTROL_SHADER
    COMPUTE = new ShaderType(0x91B9) // GL43.GL_COMPUTE_SHADER
}

/**
 * Represents a shader type.
 */
public final class ShaderType {
    private static ShaderType[string] NAME_TO_ENUM_MAP;
    private immutable uint glConstant;

    static this() {
        NAME_TO_ENUM_MAP["FRAGMENT"] = FRAGMENT;
        NAME_TO_ENUM_MAP["VERTEX"] = VERTEX;
        NAME_TO_ENUM_MAP["GEOMETRY"] = GEOMETRY;
        NAME_TO_ENUM_MAP["TESS_EVALUATION"] = TESS_EVALUATION;
        NAME_TO_ENUM_MAP["TESS_CONTROL"] = TESS_CONTROL;
        NAME_TO_ENUM_MAP["COMPUTE"] = COMPUTE;
    }

    private this(uint glConstant) {
        this.glConstant = glConstant;
    }

    /**
     * Returns the OpenGL constant associated to the shader type.
     *
     * @return The OpenGL constant
     */
    public uint getGLConstant() {
        return glConstant;
    }

    public static ShaderType valueOf(string name) {
        return NAME_TO_ENUM_MAP.get(name, null);
    }
}

/**
 * Represents the source of a shader. This class can be used to load a source from an input stream, and provides pre-compilation functionality such as parsing shader type, attribute layout and texture
 * layout tokens. These tokens can be used to declare various parameters directly in the shader code instead of in the software code, which simplifies loading.
 */
public class ShaderSource {
    private static immutable string TOKEN_SYMBOL = "$";
    private static immutable string SHADER_TYPE_TOKEN = "shader_type";
    private static auto SHADER_TYPE_TOKEN_PATTERN = ctRegex!("\\" ~ TOKEN_SYMBOL ~ SHADER_TYPE_TOKEN ~ " *: *(\\w+)", "g");
    private static immutable string ATTRIBUTE_LAYOUT_TOKEN = "attrib_layout";
    private static immutable string TEXTURE_LAYOUT_TOKEN = "texture_layout";
    private static auto LAYOUT_TOKEN_PATTERN = ctRegex!("\\" ~ TOKEN_SYMBOL ~ "(" ~ ATTRIBUTE_LAYOUT_TOKEN ~ "|" ~ TEXTURE_LAYOUT_TOKEN ~ ") *: *(\\w+) *= *(\\d+)", "g");
    private string source;
    private ShaderType type;
    private uint[string] attributeLayouts;
    private string[uint] textureLayouts;

    /**
     * Constructs a new shader source from the input stream.
     *
     * @param source The source input stream
     */
    public this(string source, bool directSource) {
        if (source is null) {
            throw new Exception("Source cannot be null");
        }
        if (directSource) {
            this.source = source;
        } else {
            this.source = readText(source);
        }
        parse();
    }

    private void parse() {
        // Look for layout tokens
        // Used for setting the shader type automatically.
        // Also replaces the GL30 "layout(location = x)" and GL42 "layout(binding = x) features missing from GL20 and/or GL30
        string[] lines = splitLines(source);
        foreach (string line; lines) {
            foreach (match; matchAll(line, SHADER_TYPE_TOKEN_PATTERN)) {
                try {
                    type = cast(ShaderType) ShaderType.valueOf(match.captures[1].toUpper());
                } catch (Exception ex) {
                    throw new Exception("Unknown shader type token value", ex);
                }
            }
            foreach (match; matchAll(line, LAYOUT_TOKEN_PATTERN)) {
                string token = match.captures[1];
                final switch (token) {
                    case "attrib_layout":
                        attributeLayouts[match.captures[2]] = to!uint(match.captures[3]);
                        break;
                    case "texture_layout":
                        textureLayouts[to!uint(match.captures[3])] = match.captures[2];
                        break;
                }
            }
        }
    }

    /**
     * Returns true if the shader source is complete and ready to be used in a {@link org.spout.renderer.api.gl.Shader} object, false if otherwise. If this method returns false, than information such
     * as the type is missing.
     *
     * @return Whether or not the shader source is complete
     */
    public bool isComplete() {
        return type !is null;
    }

    /**
     * Returns the raw character sequence source of this shader source.
     *
     * @return The raw source
     */
    public string getSource() {
        return source;
    }

    /**
     * Returns the type of this shader. If the type was declared in the source using a shader type token, it will have been loaded from it. Else this returns null and it must be set manually using
     * {@link #setType(org.spout.renderer.api.gl.Shader.ShaderType)}.
     *
     * @return The shader type, or null if not set
     */
    public ShaderType getType() {
        return cast(ShaderType) type;
    }

    /**
     * Sets the shader type. It's not necessary to do this manually if it was declared in the source using a shader type token.
     *
     * @param type The shader type
     */
    public void setType(ShaderType type) {
        this.type = cast(ShaderType) type;
    }

    /**
     * Returns the attribute layouts, either parsed from the source or set manually using {@link #setAttributeLayout(String, int)}.
     *
     * @return The attribute layouts
     */
    public uint[string] getAttributeLayouts() {
        return attributeLayouts.dup;
    }

    /**
     * Returns the texture layouts, either parsed from the source or set manually using {@link #setTextureLayout(int, String)}.
     *
     * @return The texture layouts
     */
    public string[uint] getTextureLayouts() {
        return textureLayouts.dup;
    }

    /**
     * Sets an attribute layout.
     *
     * @param attribute The name of the attribute
     * @param layout The layout for the attribute
     */
    public void setAttributeLayout(string attribute, uint layout) {
        attributeLayouts[attribute] = layout;
    }

    /**
     * Sets a texture layout.
     *
     * @param unit The unit for the sampler
     * @param sampler The sampler name
     */
    public void setTextureLayout(uint unit, string sampler) {
        textureLayouts[unit] = sampler;
    }
}

/**
 * Represents a texture for OpenGL. Image data and various parameters can be set after creation. Image data should be set last.
 */
public abstract class Texture : Creatable, GLVersioned {
    protected uint id = 0;

    public override void destroy() {
        id = 0;
        super.destroy();
    }

    /**
     * Binds the texture to the OpenGL context.
     *
     * @param unit The unit to bind the texture to, or -1 to just bind the texture
     */
    public abstract void bind(int unit);

    /**
     * Unbinds the texture from the OpenGL context.
     */
    public abstract void unbind();

    /**
     * Gets the ID for this texture as assigned by OpenGL.
     *
     * @return The ID
     */
    public uint getID() {
        return id;
    }

    /**
     * Sets the texture's format.
     *
     * @param format The format
     */
    public void setFormat(Format format) {
        setFormat(format, null);
    }

    /**
     * Sets the texture's format.
     *
     * @param format The format
     */
    public void setFormat(InternalFormat format) {
        setFormat(format.getFormat(), format);
    }

    /**
     * Sets the texture's format and internal format.
     *
     * @param format The format
     * @param internalFormat The internal format
     */
    public abstract void setFormat(Format format, InternalFormat internalFormat);

    /**
     * Returns the texture's format
     *
     * @return the format
     */
    public abstract Format getFormat();

    /**
     * Returns the texture's internal format.
     *
     * @return The internal format
     */
    public abstract InternalFormat getInternalFormat();

    /**
     * Sets the value for anisotropic filtering. Must be greater than zero. Note that this is EXT based and might not be supported on all hardware.
     *
     * @param value The anisotropic filtering value
     */
    public abstract void setAnisotropicFiltering(float value);

    /**
     * Sets the horizontal and vertical texture wraps.
     *
     * @param horizontalWrap The horizontal wrap
     * @param verticalWrap The vertical wrap
     */
    public abstract void setWraps(WrapMode horizontalWrap, WrapMode verticalWrap);

    /**
     * Sets the texture's min and mag filters. The mag filter cannot require mipmap generation.
     *
     * @param minFilter The min filter
     * @param magFilter The mag filter
     */
    public abstract void setFilters(FilterMode minFilter, FilterMode magFilter);

    /**
     * Sets the compare mode.
     *
     * @param compareMode The compare mode
     */
    public abstract void setCompareMode(CompareMode compareMode);

    /**
     * Sets the border color.
     *
     * @param borderColor The border color
     */
    public abstract void setBorderColor(float red, float green, float blue, float alpha);

    /**
     * Sets the texture's image data.
     *
     * @param imageData The image data
     * @param width The width of the image
     * @param height the height of the image
     */
    public abstract void setImageData(ubyte[] imageData, uint width, uint height);

    /**
     * Returns the image data in the internal format.
     *
     * @return The image data in the internal format.
     */
    public ubyte[] getImageData() {
        return getImageData(getInternalFormat());
    }

    /**
     * Returns the image data in the desired format.
     *
     * @param format The format to return the data in
     * @return The image data in the desired format
     */
    public abstract ubyte[] getImageData(InternalFormat format);

    /**
     * Returns the width of the image.
     *
     * @return The image width
     */
    public abstract uint getWidth();

    /**
     * Returns the height of the image.
     *
     * @return The image height
     */
    public abstract uint getHeight();
}

public enum : Format {
    RED = new Format(0x1903, 1, true, false, false, false, false, false), // GL11.GL_RED
    RGB = new Format(0x1907, 3, true, true, true, false, false, false), // GL11.GL_RGB
    RGBA = new Format(0x1908, 4, true, true, true, true, false, false), // GL11.GL_RGBA
    DEPTH = new Format(0x1902, 1, false, false, false, false, true, false), // GL11.GL_DEPTH_COMPONENT
    RG = new Format(0x8227, 2, true, true, false, false, false, false), // GL30.GL_RG
    DEPTH_STENCIL = new Format(0x84F9, 1, false, false, false, false, false, true) // GL30.GL_DEPTH_STENCIL
}

/**
 * An enum of texture component formats.
 */
public final class Format {
    private immutable uint glConstant;
    private immutable uint components;
    private immutable bool red;
    private immutable bool green;
    private immutable bool blue;
    private immutable bool alpha;
    private immutable bool depth;
    private immutable bool stencil;

    private this(uint glConstant, uint components, bool red, bool hasGreen, bool blue, bool alpha, bool depth, bool stencil) {
        this.glConstant = glConstant;
        this.components = components;
        this.red = red;
        this.green = green;
        this.blue = blue;
        this.alpha = alpha;
        this.depth = depth;
        this.stencil = stencil;
    }

    /**
     * Gets the OpenGL constant for this format.
     *
     * @return The OpenGL Constant
     */
    public uint getGLConstant() {
        return glConstant;
    }

    /**
     * Returns the number of components in the format.
     *
     * @return The number of components
     */
    public uint getComponentCount() {
        return components;
    }

    /**
     * Returns true if this format has a red component.
     *
     * @return True if a red component is present
     */
    public bool hasRed() {
        return hasRed;
    }

    /**
     * Returns true if this format has a green component.
     *
     * @return True if a green component is present
     */
    public bool hasGreen() {
        return hasGreen;
    }

    /**
     * Returns true if this format has a blue component.
     *
     * @return True if a blue component is present
     */
    public bool hasBlue() {
        return hasBlue;
    }

    /**
     * Returns true if this format has an alpha component.
     *
     * @return True if an alpha component is present
     */
    public bool hasAlpha() {
        return hasAlpha;
    }

    /**
     * Returns true if this format has a depth component.
     *
     * @return True if a depth component is present
     */
    public bool hasDepth() {
        return hasDepth;
    }

    /**
     * Returns true if this format has a stencil component.
     *
     * @return True if a stencil component is present
     */
    public bool hasStencil() {
        return hasStencil;
    }
}

public enum : InternalFormat {
    RGB8 = new InternalFormat(0x8051, RGB, UNSIGNED_BYTE), // GL11.GL_RGB8
    RGBA8 = new InternalFormat(0x8058, RGBA, UNSIGNED_BYTE), // GL11.GL_RGBA8
    RGB16 = new InternalFormat(32852, RGB, UNSIGNED_SHORT), // GL11.GL_RGB16
    RGBA16 = new InternalFormat(0x805B, RGBA, UNSIGNED_SHORT), // GL11.GL_RGBA16
    DEPTH_COMPONENT16 = new InternalFormat(0x81A5, DEPTH, UNSIGNED_SHORT), // GL14.GL_DEPTH_COMPONENT16
    DEPTH_COMPONENT24 = new InternalFormat(0x81A6, DEPTH, UNSIGNED_INT), // GL14.GL_DEPTH_COMPONENT24
    DEPTH_COMPONENT32 = new InternalFormat(0x81A7, DEPTH, UNSIGNED_INT), // GL14.GL_DEPTH_COMPONENT32
    R8 = new InternalFormat(0x8229, RED, UNSIGNED_BYTE), // GL30.GL_R8
    R16 = new InternalFormat(0x822A, RED, UNSIGNED_SHORT), // GL30.GL_R16
    RG8 = new InternalFormat(0x822B, RG, UNSIGNED_BYTE), // GL30.GL_RG8
    RG16 = new InternalFormat(0x822C, RG, UNSIGNED_SHORT), // GL30.GL_RG16
    R16F = new InternalFormat(0x822D, RED, HALF_FLOAT), // GL30.GL_R16F
    R32F = new InternalFormat(0x822E, RED, FLOAT), // GL30.GL_R32F
    RG16F = new InternalFormat(0x822F, RG, HALF_FLOAT), // GL30.GL_RG16F
    RG32F = new InternalFormat(0x8230, RGB, FLOAT), // GL30.GL_RG32F
    RGBA32F = new InternalFormat(0x8814, RGBA, FLOAT), // GL30.GL_RGBA32F
    RGB32F = new InternalFormat(0x8815, RGB, FLOAT), // GL30.GL_RGB32F
    RGBA16F = new InternalFormat(0x881A, RGBA, HALF_FLOAT), // GL30.GL_RGBA16F
    RGB16F = new InternalFormat(0x881B, RGB, HALF_FLOAT) // GL30.GL_RGB16F
}

/**
 * An enum of sized texture component formats.
 */
public final class InternalFormat {
    private immutable uint glConstant;
    private Format format;
    private immutable uint bytes;
    private DataType componentType;

    private this(uint glConstant, Format format, DataType componentType) {
        this.glConstant = glConstant;
        this.format = format;
        this.componentType = componentType;
        bytes = format.getComponentCount() * componentType.getByteSize();
    }

    /**
     * Gets the OpenGL constant for this internal format.
     *
     * @return The OpenGL Constant
     */
    public uint getGLConstant() {
        return glConstant;
    }

    /**
     * Returns the format associated to this internal format
     *
     * @return The associated format
     */
    public Format getFormat() {
        return format;
    }

    /**
     * Returns the number of components in the format.
     *
     * @return The number of components
     */
    public uint getComponentCount() {
        return format.getComponentCount();
    }

    /**
     * Returns the data type of the components.
     *
     * @return The component type
     */
    public DataType getComponentType() {
        return componentType;
    }

    /**
     * Returns the number of bytes used by a single pixel in the format.
     *
     * @return The number of bytes for a pixel
     */
    public uint getBytes() {
        return bytes;
    }

    /**
     * Returns the number of bytes used by a single pixel component in the format.
     *
     * @return The number of bytes for a pixel component
     */
    public uint getBytesPerComponent() {
        return componentType.getByteSize();
    }

    /**
     * Returns true if this format has a red component.
     *
     * @return True if a red component is present
     */
    public bool hasRed() {
        return format.hasRed();
    }

    /**
     * Returns true if this format has a green component.
     *
     * @return True if a green component is present
     */
    public bool hasGreen() {
        return format.hasGreen();
    }

    /**
     * Returns true if this format has a blue component.
     *
     * @return True if a blue component is present
     */
    public bool hasBlue() {
        return format.hasBlue();
    }

    /**
     * Returns true if this format has an alpha component.
     *
     * @return True if an alpha component is present
     */
    public bool hasAlpha() {
        return format.hasAlpha();
    }

    /**
     * Returns true if this format has a depth component.
     *
     * @return True if a depth component is present
     */
    public bool hasDepth() {
        return format.hasDepth();
    }
}

public enum : WrapMode {
    REPEAT = new WrapMode(0x2901), // GL11.GL_REPEAT
    CLAMP_TO_EDGE = new WrapMode(0x812F), // GL12.GL_CLAMP_TO_EDGE
    CLAMP_TO_BORDER = new WrapMode(0x812D), // GL13.GL_CLAMP_TO_BORDER
    MIRRORED_REPEAT = new WrapMode(0x8370) // GL14.GL_MIRRORED_REPEAT
}

/**
 * An enum for the texture wrapping modes.
 */
public final class WrapMode {
    private immutable uint glConstant;

    private this(uint glConstant) {
        this.glConstant = glConstant;
    }

    /**
     * Gets the OpenGL constant for this texture wrap.
     *
     * @return The OpenGL Constant
     */
    public uint getGLConstant() {
        return glConstant;
    }
}

public enum : FilterMode {
    LINEAR = new FilterMode(0x2601, false), // GL11.GL_LINEAR
    NEAREST = new FilterMode(0x2600, false), // GL11.GL_NEAREST
    NEAREST_MIPMAP_NEAREST = new FilterMode(0x2700, true), // GL11.GL_NEAREST_MIPMAP_NEAREST
    LINEAR_MIPMAP_NEAREST = new FilterMode(0x2701, true), //GL11.GL_LINEAR_MIPMAP_NEAREST
    NEAREST_MIPMAP_LINEAR = new FilterMode(0x2702, true), // GL11.GL_NEAREST_MIPMAP_LINEAR
    LINEAR_MIPMAP_LINEAR = new FilterMode(0x2703, true) // GL11.GL_LINEAR_MIPMAP_LINEAR
}

/**
 * An enum for the texture filtering modes.
 */
public final class FilterMode {
    private immutable uint glConstant;
    private immutable bool mimpaps;

    private this(uint glConstant, bool mimpaps) {
        this.glConstant = glConstant;
        this.mimpaps = mimpaps;
    }

    /**
     * Gets the OpenGL constant for this texture filter.
     *
     * @return The OpenGL Constant
     */
    public uint getGLConstant() {
        return glConstant;
    }

    /**
     * Returns true if the filtering mode required generation of mipmaps.
     *
     * @return Whether or not mipmaps are required
     */
    public bool needsMipMaps() {
        return mimpaps;
    }
}

public enum : CompareMode {
    LEQUAL = new CompareMode(0x203), // GL11.GL_LEQUAL
    GEQUAL = new CompareMode(0x206), // GL11.GL_GEQUAL
    LESS = new CompareMode(0x201), // GL11.GL_LESS
    GREATER = new CompareMode(0x204), // GL11.GL_GREATER
    EQUAL = new CompareMode(0x202), // GL11.GL_EQUAL
    NOTEQUAL = new CompareMode(0x205), // GL11.GL_NOTEQUAL
    ALWAYS = new CompareMode(0x206), // GL11.GL_ALWAYS
    NEVER = new CompareMode(0x200) // GL11.GL_NEVER
}

public final class CompareMode {
    private immutable uint glConstant;

    private this(uint glConstant) {
        this.glConstant = glConstant;
    }

    /**
     * Gets the OpenGL constant for this texture filter.
     *
     * @return The OpenGL Constant
     */
    public uint getGLConstant() {
        return glConstant;
    }
}

/**
 * Represent an OpenGL vertex array. The vertex data must be set with {@link #setData(org.spout.renderer.api.data.VertexData)} before it can be created.
 */
public abstract class VertexArray : Creatable, GLVersioned {
    protected uint id = 0;

    public override void destroy() {
        id = 0;
        super.destroy();
    }

    /**
     * Sets the vertex data source to use. The indices offset is kept but maybe reduced if it doesn't fit inside the new data. The count is set to the size from the offset to the end of the data.
     *
     * @param vertexData The vertex data source
     */
    public abstract void setData(VertexData vertexData);

    /**
     * Sets the vertex array's drawing mode.
     *
     * @param mode The drawing mode to use
     */
    public abstract void setDrawingMode(DrawingMode mode);

    /**
     * Sets the vertex array's polygon mode. This describes how to rasterize each primitive. The default is {@link org.spout.renderer.api.gl.VertexArray.PolygonMode#FILL}. This can be used to draw
     * only the wireframes of the polygons.
     *
     * @param mode The polygon mode
     */
    public abstract void setPolygonMode(PolygonMode mode);

    /**
     * Sets the starting offset in the indices buffer. Defaults to 0.
     *
     * @param offset The offset in the indices buffer
     */
    public abstract void setIndicesOffset(uint offset);

    /**
     * Sets the number of indices to render during each draw call, starting at the offset set by {@link #setIndicesOffset(int)}. Setting this to a value smaller than zero results in rendering of the
     * whole list. If the value is larger than the list (starting at the offset), it will be maxed to that value.
     *
     * @param count The number of indices
     */
    public abstract void setIndicesCount(uint count);

    /**
     * Draws the primitives defined by the vertex data.
     */
    public abstract void draw();

    /**
     * Gets the ID for this vertex array as assigned by OpenGL.
     *
     * @return The ID
     */
    public uint getID() {
        return id;
    }
}

public enum : DrawingMode {
    POINTS = new DrawingMode(0x0), // GL11.GL_POINTS
    LINES = new DrawingMode(0x1), // GL11.GL_LINES
    LINE_LOOP = new DrawingMode(0x2), // GL11.GL_LINE_LOOP
    LINE_STRIP = new DrawingMode(0x3), // GL11.GL_LINE_STRIP
    TRIANGLES = new DrawingMode(0x4), // GL11.GL_TRIANGLES
    TRIANGLES_STRIP = new DrawingMode(0x5), // GL11.GL_TRIANGLE_STRIP
    TRIANGLE_FAN = new DrawingMode(0x7), // GL11.GL_TRIANGLE_FAN
    LINES_ADJACENCY = new DrawingMode(0xA), // GL32.GL_LINES_ADJACENCY
    LINE_STRIP_ADJACENCY = new DrawingMode(0xB), // GL32.GL_LINE_STRIP_ADJACENCY
    TRIANGLES_ADJACENCY = new DrawingMode(0xC), // GL32.GL_TRIANGLES_ADJACENCY
    TRIANGLE_STRIP_ADJACENCY = new DrawingMode(0xD), // GL32.GL_TRIANGLE_STRIP_ADJACENCY
    PATCHES = new DrawingMode(0xE) // GL40.GL_PATCHES
}

/**
 * Represents the different drawing modes for the vertex array
 */
public final class DrawingMode {
    private immutable uint glConstant;

    private this(uint glConstant) {
        this.glConstant = glConstant;
    }

    /**
     * Returns the OpenGL constant associated to the drawing mode
     *
     * @return The OpenGL constant
     */
    public uint getGLConstant() {
        return glConstant;
    }
}

public enum : PolygonMode {
    POINT = new PolygonMode(0x1B00), // GL11.GL_POINT
    LINE = new PolygonMode(0x1B01), // GL11.GL_LINE
    FILL = new PolygonMode(0x1B02) // GL11.GL_FILL
}

/**
 * Represents the different polygon modes for the vertex array
 */
public final class PolygonMode {
    private immutable uint glConstant;

    private this(uint glConstant) {
        this.glConstant = glConstant;
    }

    /**
     * Returns the OpenGL constant associated to the polygon mode
     *
     * @return The OpenGL constant
     */
    public uint getGLConstant() {
        return glConstant;
    }
}

/**
 * Represents a vertex attribute. It has a name, a data type, a size (the number of components) and data.
 */
public class VertexAttribute {
    protected string name;
    protected DataType type;
    protected uint size;
    protected UploadMode uploadMode;
    private ubyte[] buffer;

    /**
     * Creates a new vertex attribute from the name, the data type and the size. The upload mode will be {@link UploadMode#TO_FLOAT}.
     *
     * @param name The name
     * @param type The type
     * @param size The size
     */
    public this(string name, DataType type, uint size) {
        this(name, type, size, TO_FLOAT);
    }

    /**
     * Creates a new vertex attribute from the name, the data type, the size and the upload mode.
     *
     * @param name The name
     * @param type The type
     * @param size The size
     * @param uploadMode the upload mode
     */
    public this(string name, DataType type, uint size, UploadMode uploadMode) {
        this.name = name;
        this.type = type;
        this.size = size;
        this.uploadMode = uploadMode;
    }

    /**
     * Returns the name of the attribute.
     *
     * @return The name
     */
    public string getName() {
        return name;
    }

    /**
     * Returns the data type of the attribute.
     *
     * @return The data type
     */
    public DataType getType() {
        return type;
    }

    /**
     * Return the size of the attribute.
     *
     * @return The size
     */
    public uint getSize() {
        return size;
    }

    /**
     * Returns the upload mode for this attribute.
     *
     * @return The upload mode
     */
    public UploadMode getUploadMode() {
        return uploadMode;
    }

    /**
     * Returns a new byte buffer filled and ready to read, containing the attribute data. This method will {@link java.nio.ByteBuffer#flip()} the buffer before returning it.
     *
     * @return The buffer
     */
    public ubyte[] getData() {
        if (buffer is null) {
            throw new Exception("ByteBuffer must have data before it is ready for use.");
        }
        return buffer.dup;
    }

    /**
     * Replaces the current buffer data with a copy of the given {@link java.nio.ByteBuffer} This method arbitrarily creates data for the ByteBuffer regardless of the data type of the vertex
     * attribute.
     *
     * @param buffer to set
     */
    public void setData(ubyte[] buffer) {
        this.buffer = buffer.dup;
    }

    /**
     * Clears all of the buffer data.
     */
    public void clearData() {
        buffer = null;
    }

    public VertexAttribute clone() {
        VertexAttribute clone = new VertexAttribute(name, type, size, uploadMode);
        clone.setData(this.buffer);
        return clone;
    }
}

public enum : DataType {
    BYTE = new DataType(0x1400, 1, true, true), // GL11.GL_BYTE
    UNSIGNED_BYTE = new DataType(0x1401, 1, true, false), // GL11.GL_UNSIGNED_BYTE
    SHORT = new DataType(0x1402, 2, true, true), // GL11.GL_SHORT
    UNSIGNED_SHORT = new DataType(0x1403, 2, true, false), // GL11.GL_UNSIGNED_SHORT
    INT = new DataType(0x1404, 4, true, true), // GL11.GL_INT
    UNSIGNED_INT = new DataType(0x1405, 4, true, false), // GL11.GL_UNSIGNED_INT
    HALF_FLOAT = new DataType(0x140B, 2, false, true), // GL30.GL_HALF_FLOAT
    FLOAT = new DataType(0x1406, 4, false, true), // GL11.GL_FLOAT
    DOUBLE = new DataType(0x140A, 8, false, true) // GL11.GL_DOUBLE
}

/**
 * Represents an attribute data type.
 */
public final class DataType {
    private immutable uint glConstant;
    private immutable uint byteSize;
    private immutable bool integer;
    private immutable bool signed;
    private immutable uint multiplyShift;

    private this(uint glConstant, uint byteSize, bool integer, bool signed) {
        this.glConstant = glConstant;
        this.byteSize = byteSize;
        this.integer = integer;
        this.signed = signed;
        uint result = 0;
        while (byteSize >>= 1) {
            result++;
        }
        multiplyShift = result;
    }

    /**
     * Returns the OpenGL constant for the data type.
     *
     * @return The OpenGL constant
     */
    public uint getGLConstant() {
        return glConstant;
    }

    /**
     * Returns the size in bytes of the data type.
     *
     * @return The size in bytes
     */
    public uint getByteSize() {
        return byteSize;
    }

    /**
     * Returns true if the data type is an integer number ({@link DataType#BYTE}, {@link DataType#SHORT} or {@link DataType#INT}).
     *
     * @return Whether or not the data type is an integer
     */
    public bool isInteger() {
        return integer;
    }

    /**
     * Returns true if this data type supports signed numbers, false if not.
     *
     * @return Whether or not this data type supports signed numbers
     */
    public bool isSigned() {
        return signed;
    }

    /**
     * Returns the shift amount equivalent to multiplying by the number of bytes in this data type.
     *
     * @return The shift amount corresponding to the multiplication by the byte size
     */
    public uint getMultiplyShift() {
        return multiplyShift;
    }
}

public enum : UploadMode {
    TO_FLOAT = new UploadMode(),
    TO_FLOAT_NORMALIZE = new UploadMode(),
    /**
     * Only supported in OpenGL 3.0 and after.
     */
    KEEP_INT = new UploadMode()
}

/**
 * The uploading mode. When uploading attribute data to OpenGL, integer data can be either converted to float or not (the later is only possible with version 3.0+). When converting to float, the
 * data can be normalized or not. By default, {@link UploadMode#TO_FLOAT} is used as it provides the best compatibility.
 */
public final class UploadMode {
    /**
     * Returns true if this upload mode converts integer data to normalized floats.
     *
     * @return Whether or not this upload mode converts integer data to normalized floats
     */
    public bool normalize() {
        return this == TO_FLOAT_NORMALIZE;
    }

    /**
     * Returns true if this upload mode converts the data to floats.
     *
     * @return Whether or not this upload mode converts the data to floats
     */
    public bool toFloat() {
        return this == TO_FLOAT || this == TO_FLOAT_NORMALIZE;
    }
}

/**
 * Represents a vertex data. A vertex is a collection of attributes, most often attached to a point in space. This class is a data structure which groups together collections of primitives to
 * represent a list of vertices.
 */
public class VertexData {
    // Rendering indices
    private uint[] indices;
    // Attributes by index
    private VertexAttribute[uint] attributes;
    // Index from name lookup
    private uint[string] nameToIndex;

    /**
     * Returns the list of indices used by OpenGL to pick the vertices to draw the object with in the correct order.
     *
     * @return The indices list
     */
    public uint[] getIndices() {
        return indices.dup;
    }

    /**
     * Sets the list of indices used by OpenGL to pick the vertices to draw the object with in the correct order.
     *
     * @param indices The indices list
     */
    public void setIndices(uint[] indices) {
        this.indices = indices.dup;
    }

    /**
     * Returns the index count.
     *
     * @return The number of indices
     */
    public uint getIndicesCount() {
        return cast(uint) indices.length;
    }

    /**
     * Returns a byte buffer containing all the current indices.
     *
     * @return A buffer of the indices
     */
    public ubyte[] getIndicesBuffer() {
        return cast(ubyte[]) cast(void[]) indices.dup;
    }

    /**
     * Adds an attribute.
     *
     * @param index The attribute index
     * @param attribute The attribute to add
     */
    public void addAttribute(uint index, VertexAttribute attribute) {
        attributes[index] = attribute;
        nameToIndex[attribute.getName()] = index;
    }

    /**
     * Returns the {@link VertexAttribute} associated to the name, or null if none can be found.
     *
     * @param name The name to lookup
     * @return The attribute, or null if none is associated to the index.
     */
    public VertexAttribute getAttribute(string name) {
        return getAttribute(getAttributeIndex(name));
    }

    /**
     * Returns the {@link VertexAttribute} at the desired index, or null if none is associated to the index.
     *
     * @param index The index to lookup
     * @return The attribute, or null if none is associated to the index.
     */
    public VertexAttribute getAttribute(uint index) {
        return attributes.get(index, null);
    }

    /**
     * Returns the index associated to the attribute name, or -1 if no attribute has the name.
     *
     * @param name The name to lookup
     * @return The index, or -1 if no attribute has the name
     */
    public int getAttributeIndex(string name) {
        return nameToIndex.get(name, -1);
    }

    /**
     * Returns true if an attribute has the provided name.
     *
     * @param name The name to lookup
     * @return Whether or not an attribute possesses the name
     */
    public bool hasAttribute(string name) {
        return cast(bool) (name in nameToIndex);
    }

    /**
     * Returns true in an attribute can be found at the provided index.
     *
     * @param index The index to lookup
     * @return Whether or not an attribute is at the index
     */
    public bool hasAttribute(uint index) {
        return cast(bool) (index in attributes);
    }

    /**
     * Removes the attribute associated to the provided name. If no attribute is found, nothing will be removed.
     *
     * @param name The name of the attribute to remove
     */
    public void removeAttribute(string name) {
        removeAttribute(getAttributeIndex(name));
    }

    /**
     * Removes the attribute at the provided index. If no attribute is found, nothing will be removed.
     *
     * @param index The index of the attribute to remove
     */
    public void removeAttribute(uint index) {
        attributes.remove(index);
        nameToIndex.remove(getAttributeName(index));
    }

    /**
     * Returns the size of the attribute associated to the provided name.
     *
     * @param name The name to lookup
     * @return The size of the attribute
     */
    public int getAttributeSize(string name) {
        return getAttributeSize(getAttributeIndex(name));
    }

    /**
     * Returns the size of the attribute at the provided index, or -1 if none can be found.
     *
     * @param index The index to lookup
     * @return The size of the attribute, or -1 if none can be found
     */
    public int getAttributeSize(uint index) {
        VertexAttribute attribute = getAttribute(index);
        if (attribute is null) {
            return -1;
        }
        return attribute.getSize();
    }

    /**
     * Returns the type of the attribute associated to the provided name, or null if none can be found.
     *
     * @param name The name to lookup
     * @return The type of the attribute, or null if none can be found
     */
    public DataType getAttributeType(string name) {
        return getAttributeType(getAttributeIndex(name));
    }

    /**
     * Returns the type of the attribute at the provided index, or null if none can be found.
     *
     * @param index The index to lookup
     * @return The type of the attribute, or null if none can be found
     */
    public DataType getAttributeType(uint index) {
        VertexAttribute attribute = getAttribute(index);
        if (attribute is null) {
            return null;
        }
        return attribute.getType();
    }

    /**
     * Returns the name of the attribute at the provided index, or null if none can be found.
     *
     * @param index The index to lookup
     * @return The name of the attribute, or null if none can be found
     */
    public string getAttributeName(uint index) {
        VertexAttribute attribute = getAttribute(index);
        if (attribute is null) {
            return null;
        }
        return attribute.getName();
    }

    /**
     * Returns the attribute count.
     *
     * @return The number of attributes
     */
    public uint getAttributeCount() {
        return cast(uint) attributes.length;
    }

    /**
     * Returns an unmodifiable set of all the attribute names.
     *
     * @return A set of all the attribute names
     */
    public string[] getAttributeNames() {
        return nameToIndex.keys;
    }

    /**
     * Returns the buffer for the attribute associated to the provided name, or null if none can be found. The buffer is returned filled and ready for reading.
     *
     * @param name The name to lookup
     * @return The attribute buffer, filled and flipped
     */
    public ubyte[] getAttributeBuffer(string name) {
        return getAttributeBuffer(getAttributeIndex(name));
    }

    /**
     * Returns the buffer for the attribute at the provided index, or null if none can be found. The buffer is returned filled and ready for reading.
     *
     * @param index The index to lookup
     * @return The attribute buffer, filled and flipped
     */
    public ubyte[] getAttributeBuffer(uint index) {
        VertexAttribute attribute = getAttribute(index);
        if (attribute is null) {
            return null;
        }
        return attribute.getData();
    }

    /**
     * Clears all the vertex data.
     */
    public void clear() {
        indices = null;
        attributes = null;
        nameToIndex = null;
    }

    /**
     * Replaces the contents of this vertex data by the provided one. This is a deep copy. The vertex attribute are each individually cloned.
     *
     * @param data The data to copy.
     */
    public void copy(VertexData data) {
        indices = data.indices.dup;
        attributes = data.attributes.dup;
        nameToIndex = data.nameToIndex.dup;
    }
}

public immutable bool DEBUG_ENABLED = true;

/**
 * Throws an exception if OpenGL reports an error.
 *
 * @throws GLException If OpenGL reports an error
 */
public void checkForGLError() {
    if (DEBUG_ENABLED) {
        final switch (glGetError()) {
            case 0x0:
                return;
            case 0x500:
                throw new GLException("GL ERROR: INVALID ENUM");
            case 0x501:
                throw new GLException("GL ERROR: INVALID VALUE");
            case 0x502:
                throw new GLException("GL ERROR: INVALID OPERATION");
            case 0x503:
                throw new GLException("GL ERROR: STACK OVERFLOW");
            case 0x504:
                throw new GLException("GL ERROR: STACK UNDERFLOW");
            case 0x505:
                throw new GLException("GL ERROR: OUT OF MEMORY");
            case 0x506:
                throw new GLException("GL ERROR: INVALID FRAMEBUFFER OPERATION");
        }
    }
}

/**
 * An exception throw when a GL exception occurs.
 */
public class GLException : Exception {

    /**
     * Constructs a new GL exception from the message.
     *
     * @param message The error message
     */
    public this(string message) {
        super(message);
    }
}
