module gbaid.gl20;

import std.stdio;
import std.conv;
import std.string;
import std.container;
import std.variant;
import std.regex;
import std.algorithm;

import derelict.sdl2.sdl;
import derelict.opengl3.gl3;

import gbaid.gl;
import gbaid.util;

/**
 * An OpenGL 2.0 implementation of {@link org.spout.renderer.api.gl.Context}.
 *
 * @see org.spout.renderer.api.gl.Context
 */
public class GL20Context : Context {
    private string title;
    private uint width;
    private uint height;
    private SDL_Window* window;
    private SDL_GLContext glContext;

    public override void create() {
        checkNotCreated();
        // Load the bindings if needed
        if (!DerelictSDL2.isLoaded) {
            DerelictSDL2.load();
        }
        if (!DerelictGL3.isLoaded) {
            DerelictGL3.load();
        }
        // Initialize SDL video if needed
        if (!SDL_WasInit(SDL_INIT_VIDEO)) {
            if (SDL_InitSubSystem(SDL_INIT_VIDEO) < 0) {
                throw new Exception("Failed to initialize SDL: " ~ to!string(SDL_GetError()));
            }
        }
        // Configure the context
        setContextAttributes();
        if (msaa > 0) {
            SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 1);
            SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, msaa);
        }
        // Attempt to create the window
        window = SDL_CreateWindow(toStringz(title), SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, width, height, SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN);
        if (!window) {
            throw new Exception("Failed to create a SDL window: " ~ to!string(SDL_GetError()));
        }
        // Attempt to create the OpenGL context
        glContext = SDL_GL_CreateContext(window);
        if (glContext is null) {
            throw new Exception("Failed to create OpenGL context: " ~ to!string(SDL_GetError()));
        }
        // Set the swap interval to immediate
        SDL_GL_SetSwapInterval(0);
        // Load the GL1.1+ features if needed
        if (DerelictGL3.loadedVersion == derelict.opengl3.types.GLVersion.GL11) {
            DerelictGL3.reload();
        }
        // Check for errors
        checkForGLError();
        // Update the state
        super.create();
    }

    /**
     * Created new context attributes for the version.
     *
     * @return The context attributes
     */
    protected void setContextAttributes() {
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
    }

    public override void destroy() {
        checkCreated();
        // Display goes after else there's no context in which to check for an error
        checkForGLError();
        SDL_GL_DeleteContext(glContext);
        SDL_DestroyWindow(window);
        super.destroy();
    }

    public override FrameBuffer newFrameBuffer() {
        return new GL20FrameBuffer();
    }

    public override Program newProgram() {
        return new GL20Program();
    }

    public override RenderBuffer newRenderBuffer() {
        return new GL20RenderBuffer();
    }

    public override Shader newShader() {
        return new GL20Shader();
    }

    public override Texture newTexture() {
        return new GL20Texture();
    }

    public override VertexArray newVertexArray() {
        return new GL20VertexArray();
    }

    public override string getWindowTitle() {
        return title;
    }

    public override void setWindowTitle(string title) {
        this.title = title;
        if (isCreated()) {
            SDL_SetWindowTitle(window, toStringz(title));
        }
    }

    public override void setWindowSize(uint width, uint height) {
        this.width = width;
        this.height = height;
        if (isCreated()) {
            SDL_SetWindowSize(window, width, height);
        }
    }

    public override uint getWindowWidth() {
        return width;
    }

    public override uint getWindowHeight() {
        return height;
    }

    public override void updateDisplay() {
        checkCreated();
        SDL_GL_SwapWindow(window);
    }

    public override void setClearColor(float red, float green, float blue, float alpha) {
        checkCreated();
        glClearColor(red, green, blue, alpha);
        // Check for errors
        checkForGLError();
    }

    public override void clearCurrentBuffer() {
        checkCreated();
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        // Check for errors
        checkForGLError();
    }

    public override void enableCapability(Capability capability) {
        checkCreated();
        glEnable(capability.getGLConstant());
        // Check for errors
        checkForGLError();
    }

    public override void disableCapability(Capability capability) {
        checkCreated();
        glDisable(capability.getGLConstant());
        // Check for errors
        checkForGLError();
    }

    public override void setDepthMask(bool enabled) {
        checkCreated();
        glDepthMask(enabled);
        // Check for errors
        checkForGLError();
    }

    public override void setBlendingFunctions(int bufferIndex, BlendFunction source, BlendFunction destination) {
        checkCreated();
        glBlendFunc(source.getGLConstant(), destination.getGLConstant());
        // Check for errors
        checkForGLError();
    }

    public override void setViewPort(uint x, uint y, uint width, uint height) {
        checkCreated();
        glViewport(x, y, width, height);
        // Check for errors
        checkForGLError();
    }

    public override ubyte[] readFrame(uint x, uint y, uint width, uint height, InternalFormat format) {
        checkCreated();
        // Create the image buffer
        ubyte[] buffer = new ubyte[width * height * format.getBytes()];
        // Read from the front buffer
        glReadBuffer(GL_FRONT);
        // Use byte alignment
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        // Read the pixels
        glReadPixels(x, y, width, height, format.getFormat().getGLConstant(), format.getComponentType().getGLConstant(), buffer.ptr);
        // Check for errors
        checkForGLError();
        return buffer;
    }

    public override bool isWindowCloseRequested() {
        SDL_PumpEvents();
        SDL_Event event;
        SDL_PeepEvents(&event, 1, SDL_PEEKEVENT, SDL_QUIT, SDL_QUIT);
        return event.type == SDL_QUIT;
    }

    public gbaid.gl.GLVersion getGLVersion() {
        return GL20;
    }
}

/**
 * An OpenGL 2.0 implementation of {@link FrameBuffer} using EXT.
 *
 * @see FrameBuffer
 */
public class GL20FrameBuffer : FrameBuffer {
    private RedBlackTree!uint outputBuffers = make!(RedBlackTree!uint);

    /**
     * Constructs a new frame buffer for OpenGL 2.0. If no EXT extension for frame buffers is available, an exception is thrown.
     *
     * @throws UnsupportedOperationException If the hardware doesn't support EXT frame buffers
     */
    public this() {
        if (!isSupported("GL_EXT_framebuffer_object")) {
            throw new Exception("Frame buffers are not supported by this hardware");
        }
    }

    public override void create() {
        checkNotCreated();
        // Generate and bind the frame buffer
        glGenFramebuffersEXT(1, &id);
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, id);
        // Disable input buffers
        glReadBuffer(GL_NONE);
        // Unbind the frame buffer
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
        // Update the state
        super.create();
        // Check for errors
        checkForGLError();
    }

    public override void destroy() {
        checkCreated();
        // Delete the frame buffer
        glDeleteFramebuffersEXT(1, &id);
        // Clear output buffers
        outputBuffers.clear();
        // Update the state
        super.destroy();
        // Check for errors
        checkForGLError();
    }

    public override void attach(AttachmentPoint point, Texture texture) {
        checkCreated();
        texture.checkCreated();
        // Bind the frame buffer
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, id);
        // Attach the texture
        glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, point.getGLConstant(), GL_TEXTURE_2D, texture.getID(), 0);
        // Add it to the color outputs if it's a color type
        if (point.isColor()) {
            outputBuffers.insert(point.getGLConstant());
        }
        // Update the list of output buffers
        updateOutputBuffers();
        // Unbind the frame buffer
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
        // Check for errors
        checkForGLError();
    }

    public override void attach(AttachmentPoint point, RenderBuffer buffer) {
        checkCreated();
        buffer.checkCreated();
        // Bind the frame buffer
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, id);
        // Attach the render buffer
        glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, point.getGLConstant(), GL_RENDERBUFFER_EXT, buffer.getID());
        // Add it to the color outputs if it's a color type
        if (point.isColor()) {
            outputBuffers.insert(point.getGLConstant());
        }
        // Update the list of output buffers
        updateOutputBuffers();
        // Unbind the frame buffer
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
        // Check for errors
        checkForGLError();
    }

    public override void detach(AttachmentPoint point) {
        checkCreated();
        // Bind the frame buffer
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, id);
        // Detach the render buffer or texture
        glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, point.getGLConstant(), GL_RENDERBUFFER_EXT, 0);
        // Remove it from the color outputs if it's a color type
        if (point.isColor()) {
            outputBuffers.removeKey(point.getGLConstant());
        }
        // Update the list of output buffers
        updateOutputBuffers();
        // Unbind the frame buffer
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
        // Check for errors
        checkForGLError();
    }

    private void updateOutputBuffers() {
        // Set the output to the proper buffers
        uint[] outputBuffersArray;
        if (outputBuffers.empty) {
            outputBuffersArray = [GL_NONE];
        } else {
            // Keep track of the buffers to output
            outputBuffersArray = new uint[outputBuffers.length];
            uint i = 0;
            foreach (buffer; outputBuffers[]) {
                outputBuffersArray[i++] = buffer;
            }
            // Sorting the array ensures that attachments are in order n, n + 1, n + 2...
            // This is important!
            outputBuffersArray.sort;
        }
        glDrawBuffers(cast(uint) outputBuffersArray.length, outputBuffersArray.ptr);
    }

    public override bool isComplete() {
        checkCreated();
        // Bind the frame buffer
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, id);
        // Fetch the status and compare to the complete enum value
        bool complete = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT) == GL_FRAMEBUFFER_COMPLETE_EXT;
        // Unbind the frame buffer
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
        // Check for errors
        checkForGLError();
        return complete;
    }

    public override void bind() {
        checkCreated();
        // Bind the frame buffer
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, id);
        // Check for errors
        checkForGLError();
    }

    public override void unbind() {
        checkCreated();
        // Unbind the frame buffer
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
        // Check for errors
        checkForGLError();
    }

    public gbaid.gl.GLVersion getGLVersion() {
        return GL20;
    }
}

/**
 * An OpenGL 2.0 implementation of {@link Program}.
 *
 * @see Program
 */
public class GL20Program : Program {
    // Represents an unset value for a uniform
    private static immutable Object UNSET = new immutable(Object)();
    // Regex to remove the array notation from attribute names
    private static auto ATTRIBUTE_ARRAY_NOTATION_PATTERN = ctRegex!("\\[\\d+\\]", "g");
    // Set of all shaders in this program
    private bool[Shader] shaders;
    // Map of the attribute names to their vao index (optional for GL30 as they can be defined in the shader instead)
    private uint[string] attributeLayouts;
    // Map of the texture units to their names
    private string[uint] textureLayouts;
    // Map of the uniform names to their locations
    private uint[string] uniforms;
    // Map of the uniform names to their values
    private Variant[string] uniformValues;

    public override void create() {
        checkNotCreated();
        // Create program
        id = glCreateProgram();
        // Update the state
        super.create();
    }

    public override void destroy() {
        checkCreated();
        // Delete the program
        glDeleteProgram(id);
        // Check for errors
        checkForGLError();
        // Clear the data
        shaders = null;
        attributeLayouts = null;
        textureLayouts = null;
        uniforms = null;
        uniformValues = null;
        // Update the state
        super.destroy();
    }

    public override void attachShader(Shader shader) {
        checkCreated();
        // Attach the shader
        glAttachShader(id, shader.getID());
        // Check for errors
        checkForGLError();
        // Add the shader to the set
        shaders[shader] = true;
        // Add all attribute and texture layouts
        addAll!(string, uint)(attributeLayouts, shader.getAttributeLayouts());
        addAll!(uint, string)(textureLayouts, shader.getTextureLayouts());
    }

    public override void detachShader(Shader shader) {
        checkCreated();
        // Attach the shader
        glDetachShader(id, shader.getID());
        // Check for errors
        checkForGLError();
        // Remove the shader from the set
        shaders.remove(shader);
        // Remove all attribute and texture layouts
        removeAll!(string, uint)(attributeLayouts, shader.getAttributeLayouts());
        removeAll!(uint, string)(textureLayouts, shader.getTextureLayouts());
    }

    public override void link() {
        checkCreated();
        // Add the attribute layouts to the program state
        foreach (layout; attributeLayouts.byKey()) {
            // Bind the index to the name
            glBindAttribLocation(id, attributeLayouts[layout], toStringz(layout));
        }
        // Link program
        glLinkProgram(id);
        // Check program link status
        int status;
        glGetProgramiv(id, GL_LINK_STATUS, &status);
        if (status == GL_FALSE) {
            throw new Exception("Program could not be linked\n" ~ getInfoLog());
        }
        if (DEBUG_ENABLED) {
            // Validate program
            glValidateProgram(id);
            // Check program validation status
            glGetProgramiv(id, GL_VALIDATE_STATUS, &status);
            if (status == GL_FALSE) {
                writeln("Program validation failed. This doesn't mean it won't work, so you maybe able to ignore it\n" ~ getInfoLog());
            }
        }
        // Load uniforms
        uniforms = null;
        int uniformCount;
        glGetProgramiv(id, GL_ACTIVE_UNIFORMS, &uniformCount);
        int maxLength;
        glGetProgramiv(id, GL_ACTIVE_UNIFORM_MAX_LENGTH, &maxLength);
        int length;
        int size;
        uint type;
        char[] name = new char[maxLength];
        foreach (uint i; 0 .. uniformCount) {
            glGetActiveUniform(id, i, maxLength, &length, &size, &type, name.ptr);
            // Simplify array names
            string nameString = gbaid.util.toString(name);
            replaceFirst(nameString, ATTRIBUTE_ARRAY_NOTATION_PATTERN, "");
            uniforms[nameString] = glGetUniformLocation(id, name.ptr);
            uniformValues[nameString] = UNSET;
        }
        // Check for errors
        checkForGLError();
    }

    private string getInfoLog() {
        static immutable uint maxLength = 1024;
        int length;
        char[maxLength] log = new char[maxLength];
        glGetProgramInfoLog(id, cast(uint) maxLength, &length, log.ptr);
        return gbaid.util.toString(log);
    }

    public override void use() {
        checkCreated();
        // Bind the program
        glUseProgram(id);
        // Check for errors
        checkForGLError();
    }

    public override void bindSampler(uint unit) {
        if (unit !in textureLayouts) {
            throw new Exception("No texture layout has been set for the unit: " ~ to!string(unit));
        }
        setUniform(textureLayouts[unit], unit);
    }

    public override void setUniform(string name, bool b) {
        checkCreated();
        Variant var = b;
        if (!isDirty(name, var)) {
            return;
        }
        glUniform1i(uniforms[name], b ? 1 : 0);
        uniformValues[name] = var;
        checkForGLError();
    }

    public override void setUniform(string name, int i) {
        checkCreated();
        Variant var = i;
        if (!isDirty(name, var)) {
            return;
        }
        glUniform1i(uniforms[name], i);
        uniformValues[name] = var;
        checkForGLError();
    }

    public override void setUniform(string name, float f) {
        checkCreated();
        Variant var = f;
        if (!isDirty(name, var)) {
            return;
        }
        glUniform1f(uniforms[name], f);
        uniformValues[name] = var;
        checkForGLError();
    }

    public override void setUniform(string name, float[] fs) {
        checkCreated();
        Variant var = fs;
        if (!isDirty(name, var)) {
            return;
        }
        glUniform1fv(uniforms[name], cast(uint) fs.length, fs.ptr);
        uniformValues[name] = var;
        checkForGLError();
    }

    public override void setUniform(string name, float x, float y) {
        checkCreated();
        Vector2f v;
        v.x = x;
        v.y = y;
        Variant var = v;
        if (!isDirty(name, var)) {
            return;
        }
        glUniform2f(uniforms[name], x, y);
        uniformValues[name] = var;
        checkForGLError();
    }

    private struct Vector2f {
        float x, y;
    }

    public override void setUniform(string name, float x, float y, float z) {
        checkCreated();
        Vector3f v;
        v.x = x;
        v.y = y;
        v.z = z;
        Variant var = v;
        if (!isDirty(name, var)) {
            return;
        }
        glUniform3f(uniforms[name], x, y, z);
        uniformValues[name] = var;
        checkForGLError();
    }

    private struct Vector3f {
        float x, y, z;
    }

    public override void setUniform(string name, float x, float y, float z, float w) {
        checkCreated();
        Vector4f v;
        v.x = x;
        v.y = y;
        v.z = z;
        v.w = w;
        Variant var = v;
        if (!isDirty(name, var)) {
            return;
        }
        glUniform4f(uniforms[name], x, y, z, w);
        uniformValues[name] = var;
        checkForGLError();
    }

    private struct Vector4f {
        float x, y, z, w;
    }

    public override void setUniform(string name, ref float[4] m) {
        checkCreated();
        Variant var = m.dup;
        if (!isDirty(name, var)) {
            return;
        }
        glUniformMatrix2fv(uniforms[name], 1, false, m.ptr);
        uniformValues[name] = var;
        checkForGLError();
    }

    public override void setUniform(string name, ref float[9] m) {
        checkCreated();
        Variant var = m.dup;
        if (!isDirty(name, var)) {
            return;
        }
        glUniformMatrix3fv(uniforms[name], 1, false, m.ptr);
        uniformValues[name] = var;
        checkForGLError();
    }

    public override void setUniform(string name, ref float[16] m) {
        checkCreated();
        Variant var = m.dup;
        if (!isDirty(name, var)) {
            return;
        }
        glUniformMatrix4fv(uniforms[name], 1, false, m.ptr);
        uniformValues[name] = var;
        checkForGLError();
    }

    private bool isDirty(string name, Variant newValue) {
        return name in uniformValues && uniformValues[name] != newValue;
    }

    public override Shader[] getShaders() {
        return shaders.keys;
    }

    public override string[] getUniformNames() {
        return uniforms.keys;
    }

    public gbaid.gl.GLVersion getGLVersion() {
        return GL20;
    }
}

/**
 * An OpenGL 2.0 implementation of {@link RenderBuffer} using EXT.
 *
 * @see RenderBuffer
 */
public class GL20RenderBuffer : RenderBuffer {
    // The render buffer storage format
    private InternalFormat format;
    // The storage dimensions
    private uint width = 1;
    private uint height = 1;

    /**
     * Constructs a new render buffer for OpenGL 2.0. If no EXT extension for render buffers is available, an exception is thrown.
     *
     * @throws UnsupportedOperationException If the hardware doesn't support EXT render buffers.
     */
    public this() {
        if (!isSupported("GL_EXT_framebuffer_object")) {
            throw new Exception("Render buffers are not supported by this hardware");
        }
    }

    public override void create() {
        checkNotCreated();
        // Generate the render buffer
        glGenRenderbuffersEXT(1, &id);
        // Update the state
        super.create();
        // Check for errors
        checkForGLError();
    }

    public override void destroy() {
        checkCreated();
        // Delete the render buffer
        glDeleteRenderbuffersEXT(1, &id);
        // Update state
        super.destroy();
        // Check for errors
        checkForGLError();
    }

    public override void setStorage(InternalFormat format, uint width, uint height) {
        checkCreated();
        if (format is null) {
            throw new Exception("Format cannot be null");
        }
        this.format = format;
        this.width = width;
        this.height = height;
        // Bind the render buffer
        glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, id);
        // Set the storage format and size
        glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, format.getGLConstant(), width, height);
        // Unbind the render buffer
        glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, 0);
        // Check for errors
        checkForGLError();
    }

    public override InternalFormat getFormat() {
        return format;
    }

    public override uint getWidth() {
        return width;
    }

    public override uint getHeight() {
        return height;
    }

    public override void bind() {
        checkCreated();
        // Unbind the render buffer
        glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, id);
        // Check for errors
        checkForGLError();
    }

    public override void unbind() {
        checkCreated();
        // Bind the render buffer
        glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, 0);
        // Check for errors
        checkForGLError();
    }

    public gbaid.gl.GLVersion getGLVersion() {
        return GL20;
    }
}

/**
 * An OpenGL 2.0 implementation of {@link Shader}.
 *
 * @see Shader
 */
public class GL20Shader : Shader {
    private ShaderType type;
    // Map of the attribute names to their vao index (optional for GL30 as they can be defined in the shader instead)
    private uint[string] attributeLayouts;
    // Map of the texture units to their names
    private string[uint] textureLayouts;

    public override void create() {
        checkNotCreated();
        // Update the state
        super.create();
    }

    public override void destroy() {
        checkCreated();
        // Delete the shader
        glDeleteShader(id);
        // Clear the data
        type = null;
        attributeLayouts = null;
        textureLayouts = null;
        // Update the state
        super.destroy();
        // Check for errors
        checkForGLError();
    }

    public override void setSource(ShaderSource source) {
        checkCreated();
        if (source is null) {
            throw new Exception("Shader source cannot be null");
        }
        if (!source.isComplete()) {
            throw new Exception("Shader source isn't complete");
        }
        // If we don't have a previous shader or the type isn't the same, we need to create a new one
        ShaderType type = source.getType();
        if (id == 0 || this.type != type) {
            // Delete the old shader
            glDeleteShader(id);
            // Create a shader of the correct type
            id = glCreateShader(type.getGLConstant());
            // Store the current type
            this.type = type;
        }
        // Upload the new source
        immutable(char)* src = toStringz(source.getSource());
        glShaderSource(id, 1, &src, null);
        // Set the layouts from the source
        attributeLayouts = source.getAttributeLayouts().dup;
        textureLayouts = source.getTextureLayouts().dup;
        // Check for errors
        checkForGLError();
    }

    public override void compile() {
        checkCreated();
        // Compile the shader
        glCompileShader(id);
        // Get the shader compile status property, check it's false and fail if that's the case
        int status;
        glGetShaderiv(id, GL_COMPILE_STATUS, &status);
        if (status == GL_FALSE) {
            throw new Exception("OPEN GL ERROR: Could not compile shader\n" ~ getInfoLog());
        }
        // Check for errors
        checkForGLError();
    }

    private string getInfoLog() {
        static immutable uint maxLength = 1024;
        int length;
        char[maxLength] log = new char[maxLength];
        glGetShaderInfoLog(id, cast(uint) maxLength, &length, log.ptr);
        return gbaid.util.toString(log);
    }

    public override ShaderType getType() {
        return type;
    }

    public override uint[string] getAttributeLayouts() {
        return attributeLayouts;
    }

    public override string[uint] getTextureLayouts() {
        return textureLayouts;
    }

    public override void setAttributeLayout(string attribute, uint layout) {
        attributeLayouts[attribute] = layout;
    }

    public override void setTextureLayout(uint unit, string sampler) {
        textureLayouts[unit] = sampler;
    }

    public gbaid.gl.GLVersion getGLVersion() {
        return GL20;
    }
}

/**
 * An OpenGL 2.0 implementation of {@link Texture}.
 *
 * @see Texture
 */
public class GL20Texture : Texture {
    // The format
    protected Format format = RGB;
    protected InternalFormat internalFormat = null;
    // The min filter, to check if we need mip maps
    protected FilterMode minFilter = NEAREST_MIPMAP_LINEAR;
    // Texture image dimensions
    protected uint width = 1;
    protected uint height = 1;

    public override void create() {
        checkNotCreated();
        // Generate the texture
        glGenTextures(1, &id);
        // Update the state
        super.create();
        // Check for errors
        checkForGLError();
    }

    public override void destroy() {
        checkCreated();
        // Delete the texture
        glDeleteTextures(1, &id);
        // Reset the data
        super.destroy();
        // Check for errors
        checkForGLError();
    }

    public override void setFormat(Format format, InternalFormat internalFormat) {
        if (format is null) {
            throw new Exception("Format cannot be null");
        }
        this.format = format;
        this.internalFormat = internalFormat;
    }

    public override Format getFormat() {
        return format;
    }

    public override InternalFormat getInternalFormat() {
        return internalFormat;
    }

    public override void setAnisotropicFiltering(float value) {
        checkCreated();
        if (value <= 0) {
            throw new Exception("Anisotropic filtering value must be greater than zero");
        }
        // Bind the texture
        glBindTexture(GL_TEXTURE_2D, id);
        // Set the anisotropic filtering value
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY_EXT, value);
        // Unbind the texture
        glBindTexture(GL_TEXTURE_2D, 0);
        // Check for errors
        checkForGLError();
    }

    public override void setWraps(WrapMode horizontalWrap, WrapMode verticalWrap) {
        checkCreated();
        if (horizontalWrap is null) {
            throw new Exception("Horizontal wrap cannot be null");
        }
        if (verticalWrap is null) {
            throw new Exception("Vertical wrap cannot be null");
        }
        // Bind the texture
        glBindTexture(GL_TEXTURE_2D, id);
        // Set the vertical and horizontal texture wraps
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, horizontalWrap.getGLConstant());
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, verticalWrap.getGLConstant());
        // Unbind the texture
        glBindTexture(GL_TEXTURE_2D, 0);
        // Check for errors
        checkForGLError();
    }

    public override void setFilters(FilterMode minFilter, FilterMode magFilter) {
        checkCreated();
        if (minFilter is null) {
            throw new Exception("Min filter cannot be null");
        }
        if (magFilter is null) {
            throw new Exception("Mag filter cannot be null");
        }
        if (magFilter.needsMipMaps()) {
            throw new Exception("Mag filter cannot require mipmaps");
        }
        this.minFilter = minFilter;
        // Bind the texture
        glBindTexture(GL_TEXTURE_2D, id);
        // Set the min and max texture filters
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, minFilter.getGLConstant());
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, magFilter.getGLConstant());
        // Unbind the texture
        glBindTexture(GL_TEXTURE_2D, 0);
        // Check for errors
        checkForGLError();
    }

    public override void setCompareMode(CompareMode compareMode) {
        checkCreated();
        if (compareMode is null) {
            throw new Exception("Compare mode cannot be null");
        }
        // Bind the texture
        glBindTexture(GL_TEXTURE_2D, id);
        // Note: GL14.GL_COMPARE_R_TO_TEXTURE and GL30.GL_COMPARE_REF_TO_TEXTURE are the same, just a different name
        // No need for a different call in the GL30 implementation
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE);
        // Set the compare mode
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_FUNC, compareMode.getGLConstant());
        // Unbind the texture
        glBindTexture(GL_TEXTURE_2D, 0);
        // Check for errors
        checkForGLError();
    }

    public override void setBorderColor(float red, float green, float blue, float alpha) {
        checkCreated();
        // Bind the texture
        glBindTexture(GL_TEXTURE_2D, id);
        // Set the border color
        float[4] color = [red, green, blue, alpha];
        glTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_BORDER_COLOR, color.ptr);
        // Unbind the texture
        glBindTexture(GL_TEXTURE_2D, 0);
        // Check for errors
        checkForGLError();
    }

    public override void setImageData(ubyte[] imageData, uint width, uint height) {
        checkCreated();
        // Use byte alignment
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        // Bind the texture
        glBindTexture(GL_TEXTURE_2D, id);
        // back up the old values
        uint oldWidth = this.width;
        uint oldHeight = this.height;
        // update the texture width and height
        this.width = width;
        this.height = height;
        // check if we can only upload without reallocating
        bool hasInternalFormat = internalFormat !is null;
        if (width == oldWidth && height == oldHeight) {
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, format.getGLConstant(),
                    hasInternalFormat ? internalFormat.getComponentType().getGLConstant() : UNSIGNED_BYTE.getGLConstant(), imageData.ptr);
        } else {
            // reallocate and upload the texture to the GPU
            //if (minFilter.needsMipMaps() && imageData !is null) {
                // Build mipmaps if using mip mapped filters
                //gluBuild2DMipmaps(GL_TEXTURE_2D, hasInternalFormat ? internalFormat.getGLConstant() : format.getGLConstant(), width, height, format.getGLConstant(),
                //        hasInternalFormat ? internalFormat.getComponentType().getGLConstant() : DataType.UNSIGNED_BYTE.getGLConstant(), imageData);
                //} else {
                // Else just make it a normal texture
                // Upload the image
            glTexImage2D(GL_TEXTURE_2D, 0, hasInternalFormat ? internalFormat.getGLConstant() : format.getGLConstant(), width, height, 0, format.getGLConstant(),
                    hasInternalFormat ? internalFormat.getComponentType().getGLConstant() : UNSIGNED_BYTE.getGLConstant(), imageData.ptr);
            //}
        }
        // Unbind the texture
        glBindTexture(GL_TEXTURE_2D, 0);
        // Check for errors
        checkForGLError();
    }

    public override ubyte[] getImageData(InternalFormat format) {
        checkCreated();
        // Bind the texture
        glBindTexture(GL_TEXTURE_2D, id);
        // Create the image buffer
        bool formatNotNull = format !is null;
        ubyte[] imageData = new ubyte[width * height * (formatNotNull ? format.getBytes() : this.format.getComponentCount() * UNSIGNED_BYTE.getByteSize())];
        // Use byte alignment
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        // Get the image data
        glGetTexImage(GL_TEXTURE_2D, 0, formatNotNull ? format.getFormat().getGLConstant() : this.format.getGLConstant(),
                formatNotNull ? format.getComponentType().getGLConstant() : UNSIGNED_BYTE.getGLConstant(), imageData.ptr);
        // Unbind the texture
        glBindTexture(GL_TEXTURE_2D, 0);
        // Check for errors
        checkForGLError();
        return imageData;
    }

    public override uint getWidth() {
        return width;
    }

    public override uint getHeight() {
        return height;
    }

    public override void bind(int unit) {
        checkCreated();
        if (unit != -1) {
            // Activate the texture unit
            glActiveTexture(GL_TEXTURE0 + unit);
        }
        // Bind the texture
        glBindTexture(GL_TEXTURE_2D, id);
        // Check for errors
        checkForGLError();
    }

    public override void unbind() {
        checkCreated();
        // Unbind the texture
        glBindTexture(GL_TEXTURE_2D, 0);
        // Check for errors
        checkForGLError();
    }

    public gbaid.gl.GLVersion getGLVersion() {
        return GL20;
    }
}

/**
 * An OpenGL 2.0 implementation of {@link VertexArray}.
 * <p/>
 * Vertex arrays will be used if the ARB or APPLE extension is supported by the hardware. Else, since core OpenGL doesn't support them until 3.0, the vertex attributes will have to be redefined on
 * each render call.
 *
 * @see VertexArray
 */
public class GL20VertexArray : VertexArray {
    private static immutable uint[0] EMPTY_ARRAY = [];
    // Buffers IDs
    private uint indicesBufferID = 0;
    private uint[] attributeBufferIDs = EMPTY_ARRAY;
    // Size of the attribute buffers
    private uint[] attributeBufferSizes = EMPTY_ARRAY;
    // Amount of indices to render
    private uint indicesCount = 0;
    private uint indicesDrawCount = 0;
    // First and last index to render
    private uint indicesOffset = 0;
    // Drawing mode
    private DrawingMode drawingMode = TRIANGLES;
    // Polygon mode
    private PolygonMode polygonMode = FILL;
    // The available vao extension
    private VertexArrayExtension extension = new NoneVertexArrayExtension();
    // Attribute properties for when we don't have a vao extension
    private uint[] attributeSizes;
    private uint[] attributeTypes;
    private bool[] attributeNormalizing;

    public this() {
        if (isSupported("GL_ARB_vertex_array_object")) {
            extension = new ARBVertexArrayExtension();
        } else {
            extension = new NoneVertexArrayExtension();
        }
    }

    public override void create() {
        checkNotCreated();
        if (extension.has()) {
            // Generate the vao
            extension.genVertexArrays(1, &id);
        }
        // Update state
        super.create();
        // Check for errors
        checkForGLError();
    }

    public override void destroy() {
        checkCreated();
        // Delete the indices buffer
        glDeleteBuffers(1, &indicesBufferID);
        // Delete the attribute buffers
        glDeleteBuffers(cast(uint) attributeBufferIDs.length, attributeBufferIDs.ptr);
        if (extension.has()) {
            // Delete the vao
            extension.deleteVertexArrays(1, &id);
        } else {
            // Else delete the attribute properties
            attributeSizes = null;
            attributeTypes = null;
            attributeNormalizing = null;
        }
        // Reset the IDs and data
        indicesBufferID = 0;
        attributeBufferIDs = EMPTY_ARRAY.dup;
        attributeBufferSizes = EMPTY_ARRAY.dup;
        // Update the state
        super.destroy();
        // Check for errors
        checkForGLError();
    }

    public override void setData(VertexData vertexData) {
        checkCreated();
        // Generate a new indices buffer if we don't have one yet
        if (indicesBufferID == 0) {
            glGenBuffers(1, &indicesBufferID);
        }
        // Bind the indices buffer
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, indicesBufferID);
        // Get the new count of indices
        uint newIndicesCount = vertexData.getIndicesCount();
        // If the new count is greater than or 50% smaller than the old one, we'll reallocate the memory
        // In the first case because we need more space, in the other to save space
        ubyte[] indicesBuffer = vertexData.getIndicesBuffer();
        if (newIndicesCount > indicesCount || newIndicesCount <= indicesCount * 0.5) {
            glBufferData(GL_ELEMENT_ARRAY_BUFFER, indicesBuffer.length, indicesBuffer.ptr, GL_STATIC_DRAW);
        } else {
            // Else, we replace the data with the new one, but we don't resize, so some old data might be left trailing in the buffer
            glBufferSubData(GL_ELEMENT_ARRAY_BUFFER, 0, indicesBuffer.length, indicesBuffer.ptr);
        }
        // Unbind the indices buffer
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
        // Update the count to the new one
        indicesCount = newIndicesCount;
        indicesDrawCount = indicesCount;
        // Ensure that the indices offset and count fits inside the valid part of the buffer
        indicesOffset = min(indicesOffset, indicesCount - 1);
        indicesDrawCount = indicesDrawCount - indicesOffset;
        // Bind the vao
        if (extension.has()) {
            extension.bindVertexArray(id);
        }
        // Create a new array of attribute buffers ID of the correct size
        uint attributeCount = vertexData.getAttributeCount();
        uint[] newAttributeBufferIDs = new uint[attributeCount];
        // Copy all the old buffer IDs that will fit in the new array so we can reuse them
        ulong length = cast(uint) min(attributeBufferIDs.length, newAttributeBufferIDs.length);
        newAttributeBufferIDs[0 .. length] = attributeBufferIDs[0 .. length];
        // Delete any buffers that we don't need (new array is smaller than the previous one)
        int difference = cast(uint) (attributeBufferIDs.length - newAttributeBufferIDs.length);
        if (difference > 0) {
            glDeleteBuffers(difference, attributeBufferIDs[newAttributeBufferIDs.length .. attributeBufferIDs.length].ptr);
        } else if (difference < 0) {
            glGenBuffers(-difference, newAttributeBufferIDs[attributeBufferIDs.length .. newAttributeBufferIDs.length].ptr);
        }
        // Copy the old valid attribute buffer sizes
        uint[] newAttributeBufferSizes = new uint[attributeCount];
        length = cast(uint) min(attributeBufferSizes.length, newAttributeBufferSizes.length);
        newAttributeBufferSizes[0 .. length] = attributeBufferSizes[0 .. length];
        // If we don't have a vao, we have to save the properties manually
        if (!extension.has()) {
            attributeSizes = new uint[attributeCount];
            attributeTypes = new uint[attributeCount];
            attributeNormalizing = new bool[attributeCount];
        }
        // Upload the new vertex data
        foreach (uint i; 0 .. attributeCount) {
            VertexAttribute attribute = vertexData.getAttribute(i);
            ubyte[] attributeData = attribute.getData();
            // Get the current buffer size
            uint bufferSize = newAttributeBufferSizes[i];
            // Get the new buffer size
            uint newBufferSize = cast(uint) attributeData.length;
            // Bind the target buffer
            glBindBuffer(GL_ARRAY_BUFFER, newAttributeBufferIDs[i]);
            // If the new count is greater than or 50% smaller than the old one, we'll reallocate the memory
            if (newBufferSize > bufferSize || newBufferSize <= bufferSize * 0.5) {
                glBufferData(GL_ARRAY_BUFFER, attributeData.length, attributeData.ptr, GL_STATIC_DRAW);
            } else {
                // Else, we replace the data with the new one, but we don't resize, so some old data might be left trailing in the buffer
                glBufferSubData(GL_ARRAY_BUFFER, 0, attributeData.length, attributeData.ptr);
            }
            // Update the buffer size to the new one
            newAttributeBufferSizes[i] = newBufferSize;
            // Next, we add the pointer to the data in the vao
            if (extension.has()) {
                // As a float, normalized or not
                glVertexAttribPointer(i, attribute.getSize(), attribute.getType().getGLConstant(), attribute.getUploadMode().normalize(), 0, null);
                // Enable the attribute
                glEnableVertexAttribArray(i);
            } else {
                // Else we save the properties for rendering
                attributeSizes[i] = attribute.getSize();
                attributeTypes[i] = attribute.getType().getGLConstant();
                attributeNormalizing[i] = attribute.getUploadMode().normalize();
            }
        }
        // Unbind the last vbo
        glBindBuffer(GL_ARRAY_BUFFER, 0);
        // Unbind the vao
        if (extension.has()) {
            extension.bindVertexArray(0);
        }
        // Update the attribute buffer IDs to the new ones
        attributeBufferIDs = newAttributeBufferIDs;
        // Update the attribute buffer sizes to the new ones
        attributeBufferSizes = newAttributeBufferSizes;
        // Check for errors
        checkForGLError();
    }

    public override void setDrawingMode(DrawingMode mode) {
        if (mode is null) {
            throw new Exception("Drawing mode cannot be null");
        }
        this.drawingMode = mode;
    }

    public override void setPolygonMode(PolygonMode mode) {
        if (mode is null) {
            throw new Exception("Polygon mode cannot be null");
        }
        polygonMode = mode;
    }

    public override void setIndicesOffset(uint offset) {
        indicesOffset = min(offset, indicesCount - 1);
        indicesDrawCount = min(indicesDrawCount, indicesCount - indicesOffset);
    }

    public override void setIndicesCount(uint count) {
        if (count < 0) {
            indicesDrawCount = indicesCount;
        } else {
            indicesDrawCount = count;
        }
        indicesDrawCount = min(indicesDrawCount, indicesCount - indicesOffset);
    }

    public override void draw() {
        checkCreated();
        if (extension.has()) {
            // Bind the vao
            extension.bindVertexArray(id);
        } else {
            // Enable the vertex attributes
            foreach (uint i; 0 .. cast(uint) attributeBufferIDs.length) {
                // Bind the buffer
                glBindBuffer(GL_ARRAY_BUFFER, attributeBufferIDs[i]);
                // Define the attribute
                glVertexAttribPointer(i, attributeSizes[i], attributeTypes[i], attributeNormalizing[i], 0, null);
                // Enable it
                glEnableVertexAttribArray(i);
            }
            // Unbind the last buffer
            glBindBuffer(GL_ARRAY_BUFFER, 0);
        }
        // Bind the index buffer
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, indicesBufferID);
        // Set the polygon mode
        glPolygonMode(GL_FRONT_AND_BACK, polygonMode.getGLConstant());
        // Draw all indices with the provided mode
        glDrawElements(drawingMode.getGLConstant(), indicesDrawCount, GL_UNSIGNED_INT, cast(void*) (indicesOffset * INT.getByteSize()));
        // Unbind the indices buffer
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
        // Check for errors
        checkForGLError();
    }

    public gbaid.gl.GLVersion getGLVersion() {
        return GL20;
    }

    private static interface VertexArrayExtension {
        protected bool has();
        protected void genVertexArrays(uint n, uint* arrays);
        protected void bindVertexArray(uint array);
        protected void deleteVertexArrays(uint n, uint* arrays);
    }

    private static class NoneVertexArrayExtension : VertexArrayExtension {
        protected bool has() {
            return false;
        }

        protected void genVertexArrays(uint n, uint* arrays) {
        }

        protected void bindVertexArray(uint array) {
        }

        protected void deleteVertexArrays(uint n, uint* arrays) {
        }
    }

    private static class ARBVertexArrayExtension : VertexArrayExtension {
        protected bool has() {
            return true;
        }

        protected void genVertexArrays(uint n, uint* arrays) {
            glGenVertexArrays(n, arrays);
        }

        protected void bindVertexArray(uint array) {
            glBindVertexArray(array);
        }

        protected void deleteVertexArrays(uint n, uint* arrays) {
            glDeleteVertexArrays(n, arrays);
        }
    }
}

private bool[string] supportedExtensions;
private bool extensionsInit = false;

private bool isSupported(string ext) {
    if (!extensionsInit) {
        const(char*) raw = glGetString(GL_EXTENSIONS);
        if (raw == null) {
            throw new Exception("Fail to retrieve supported extensions");
        }
        string extensions = to!string(raw);
        foreach (extension; extensions.split(" ")) {
            supportedExtensions[extension] = true;
        }
        extensionsInit = true;
    }
    return cast(bool) (ext in supportedExtensions);
}
