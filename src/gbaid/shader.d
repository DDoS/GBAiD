module gbaid.shader;

public enum string TEXTURE_POST_PROCESS_VERTEX_SHADER_SOURCE =
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

public enum string WINDOW_OUTPUT_FRAGMENT_SHADER_SOURCE =
`
// $shader_type: fragment

// $texture_layout: color = 0

#version 120

const float RATIO = 1.5;
const float RATIO_INV = 1 / RATIO;
const vec2 ASPECT = vec2(RATIO, 1);

varying vec2 textureCoords;

uniform sampler2D color;
uniform vec2 size;

void main() {
    vec2 m = size / ASPECT;
    vec2 sampleCoords = textureCoords;

    if (m.x > m.y) {
        float margin = (size.x / size.y - RATIO) / 2;
        sampleCoords.x = mix(-margin, 1 + margin, sampleCoords.x);
    } else {
        float margin = (size.y / size.x - RATIO_INV) / 2;
        sampleCoords.y = mix(-margin, 1 + margin, sampleCoords.y);
    }

    sampleCoords.y = 1 - sampleCoords.y;

    gl_FragColor = vec4(texture2D(color, sampleCoords).rgb, 1);
}
`;

public enum string EPX_UPSCALE_FRAGMENT_SHADER_SOURCE =
`
// $shader_type: fragment

// $texture_layout: color = 0

#version 120

varying vec2 textureCoords;

uniform sampler2D color;
uniform vec2 size;

void main() {
    float px = 1 / size.x;
    float py = 1 / size.y;

    vec2 pos = floor(textureCoords * size) / size + vec2(px, py) / 2;

    vec2 dx = vec2(px, 0);
    vec2 dy = vec2(0, py);

    vec4 p = texture2D(color, pos);
    vec4 a = texture2D(color, pos + dy);
    vec4 b = texture2D(color, pos + dx);
    vec4 c = texture2D(color, pos - dx);
    vec4 d = texture2D(color, pos - dy);

    if (textureCoords.x > pos.x) {
        if (textureCoords.y > pos.y) {
            vec4 corner = texture2D(color, pos + dx + dy);
            if (p == corner) {
                gl_FragColor = p;
                return;
            }
            if (a == b && a != c && b != d) {
                gl_FragColor = b;
            } else {
                gl_FragColor = p;
            }
        } else {
            vec4 corner = texture2D(color, pos + dx - dy);
            if (p == corner) {
                gl_FragColor = p;
                return;
            }
            if (b == d && b != a && d != c) {
                gl_FragColor = d;
            } else {
                gl_FragColor = p;
            }
        }
    } else {
        if (textureCoords.y > pos.y) {
            vec4 corner = texture2D(color, pos - dx + dy);
            if (p == corner) {
                gl_FragColor = p;
                return;
            }
            if (c == a && c != d && a != b) {
                gl_FragColor = a;
            } else {
                gl_FragColor = p;
            }
        } else {
            vec4 corner = texture2D(color, pos - dx - dy);
            if (p == corner) {
                gl_FragColor = p;
                return;
            }
            if (d == c && d != b && c != a) {
                gl_FragColor = c;
            } else {
                gl_FragColor = p;
            }
        }
    }
}
`;
