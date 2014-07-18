module gbaid.gl20;

import std.conv;
import std.string;

import derelict.sdl2.sdl;
import derelict.opengl3.gl3;

import gbaid.gl;

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
        // Load the bindings
        DerelictSDL2.load();
        DerelictGL3.load();
        // Initialize SDL video
        if (SDL_Init(SDL_INIT_VIDEO) < 0) {
            throw new Exception("Failed to initialize SDL: " ~ to!string(SDL_GetError()));
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
        // Load the GL1.1+ features
        DerelictGL3.reload();
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
        //return new GL20FrameBuffer();
        return null;
    }

    public override Program newProgram() {
        //return new GL20Program();
        return null;
    }

    public override RenderBuffer newRenderBuffer() {
        //return new GL20RenderBuffer();
        return null;
    }

    public override Shader newShader() {
        //return new GL20Shader();
        return null;
    }

    public override Texture newTexture() {
        //return new GL20Texture();
        return null;
    }

    public override VertexArray newVertexArray() {
        //return new GL20VertexArray();
        return null;
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

    public override void enableCapability(immutable Capability capability) {
        checkCreated();
        glEnable(capability.getGLConstant());
        // Check for errors
        checkForGLError();
    }

    public override void disableCapability(immutable Capability capability) {
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

    public override void setBlendingFunctions(int bufferIndex, immutable BlendFunction source, immutable BlendFunction destination) {
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

    public override ubyte[] readFrame(uint x, uint y, uint width, uint height, immutable InternalFormat format) {
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
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT) {
                return true;
            }
        }
        return false;
    }

    public immutable(gbaid.gl.GLVersion) getGLVersion() {
        return gbaid.gl.GLVersion.GL20;
    }
}
