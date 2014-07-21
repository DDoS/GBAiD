import std.stdio;
import std.getopt;
import std.string;

import gbaid.system;
import gbaid.util;
import gbaid.graphics;
import gbaid.gl;
import gbaid.gl20;

public void main(string[] args) {
	/*
	string bios;
	string sram;
	getopt(args,
		"bios|b", &bios,
		"save|sram|s", &sram
	);
	string rom = getSafe!string(args, 1);
	GameBoyAdvance gba = new GameBoyAdvance(bios);
	if (rom !is null) {
		gba.loadROM(rom);
	}
	if (sram !is null) {
		gba.loadSRAM(sram);
	}
	gba.start();
	*/
	import std.math;
	import std.algorithm;
	import core.time;
	import core.thread;
	string vertexShaderSource =
	`
	// $shader_type: vertex

	// $attrib_layout: position = 0

	#version 120

	attribute vec2 position;

	void main() {
	    gl_Position = vec4(position, 0, 1);
	}
	`;
	string fragmentShaderSource =
	`
	// $shader_type: fragment

	#version 120

	void main() {
    	gl_FragColor = vec4(1, 0, 0, 1);
	}
	`;
	// Context
    Context context = new GL20Context();
    context.setWindowSize(640, 480);
    context.setWindowTitle("Test");
    context.create();
    context.enableCapability(CULL_FACE);
    context.enableCapability(DEPTH_TEST);
    context.enableCapability(DEPTH_CLAMP);
    // Vertex shader
    Shader vertex = context.newShader();
    vertex.create();
    vertex.setSource(new ShaderSource(vertexShaderSource, true));
    vertex.compile();
    // Fragment shader
    Shader fragment = context.newShader();
    fragment.create();
    fragment.setSource(new ShaderSource(fragmentShaderSource, true));
    fragment.compile();
    // Program
    Program program = context.newProgram();
    program.create();
    program.attachShader(vertex);
    program.attachShader(fragment);
    program.link();
	// Vertex data
	VertexData vertexData = new VertexData();
    VertexAttribute positionsAttribute = new VertexAttribute("positions", FLOAT, 2);
    vertexData.addAttribute(0, positionsAttribute);
    float[] positions = [-1, -1, 1, 1, -1, 1];
    positionsAttribute.setData(cast(ubyte[]) cast(void[]) positions);
	uint[] indices = [0, 1, 2];
	vertexData.setIndices(indices);
    // Vertex array
    VertexArray vertexArray = context.newVertexArray();
    vertexArray.create();
    vertexArray.setData(vertexData);
	// Render loop
    long sleepTime = lround(1f / 60 * 1e9);
	program.use();
    try {
        while (!context.isWindowCloseRequested()) {
            long start = TickDuration.currSystemTick().nsecs();
			context.clearCurrentBuffer();
			vertexArray.draw();
			context.updateDisplay();
            long delta = TickDuration.currSystemTick().nsecs() - start;
            Thread.sleep(dur!"nsecs"(max(sleepTime - delta, 0)));
        }
    } catch (Exception ex) {
        writeln(ex);
    }
    // Destroy the context to properly exit
    context.destroy();
}
