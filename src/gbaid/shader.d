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

const float EPS = 1e-5;

varying vec2 textureCoords;

uniform sampler2D color;
uniform vec2 size;

bool eq(vec3 a, vec3 b) {
    vec3 d = a - b;
    return dot(d, d) < EPS;
}

bool neq(vec3 a, vec3 b) {
    return !eq(a, b);
}

void main() {
    float sx = 1 / size.x;
    float sy = 1 / size.y;

    vec2 dx = vec2(sx, 0);
    vec2 dy = vec2(0, sy);

    vec2 fp = fract(textureCoords * size);

    vec3 p = texture2D(color, textureCoords).rgb;
    vec3 a = texture2D(color, textureCoords + dy).rgb;
    vec3 b = texture2D(color, textureCoords + dx).rgb;
    vec3 c = texture2D(color, textureCoords - dx).rgb;
    vec3 d = texture2D(color, textureCoords - dy).rgb;

    if (fp.x >= 0.5) {
        if (fp.y >= 0.5) {
            if (eq(a, b) && neq(a, c) && neq(b, d)) {
                gl_FragColor.rgb = b;
            } else {
                gl_FragColor.rgb = p;
            }
        } else {
            if (eq(b, d) && neq(b, a) && neq(d, c)) {
                gl_FragColor.rgb = d;
            } else {
                gl_FragColor.rgb = p;
            }
        }
    } else {
        if (fp.y >= 0.5) {
            if (eq(c, a) && neq(c, d) && neq(a, b)) {
                gl_FragColor.rgb = a;
            } else {
                gl_FragColor.rgb = p;
            }
        } else {
            if (eq(d, c) && neq(d, b) && neq(c, a)) {
                gl_FragColor.rgb = c;
            } else {
                gl_FragColor.rgb = p;
            }
        }
    }
}
`;

public enum string XBR_UPSCALE_FRAGMENT_SHADER_SOURCE =
`
// Based on code from: http://filthypants.blogspot.ca/2012/03/xbr-vs-hqx-interpolation-filter.html

// $shader_type: fragment

// $texture_layout: color = 0

#version 120

const float coefficient = 2;

const float threshold = 15;

const vec3 colorWeights = 48 * vec3(0.299, 0.587, 0.114);

const vec4 Ao = vec4(1.0, -1.0, -1.0,  1.0);
const vec4 Bo = vec4(1.0,  1.0, -1.0, -1.0);
const vec4 Co = vec4(1.5,  0.5, -0.5,  0.5);
const vec4 Ax = vec4(1.0, -1.0, -1.0,  1.0);
const vec4 Bx = vec4(0.5,  2.0, -0.5, -2.0);
const vec4 Cx = vec4(1.0,  1.0, -0.5,  0.0);
const vec4 Ay = vec4(1.0, -1.0, -1.0,  1.0);
const vec4 By = vec4(2.0,  0.5, -2.0, -0.5);
const vec4 Cy = vec4(2.0,  0.0, -1.0,  0.5);

varying vec2 textureCoords;

uniform sampler2D color;
uniform vec2 size;

vec4 weightedBlend(vec3 v0, vec3 v1, vec3 v2, vec3 v3) {
    return vec4(dot(colorWeights, v0), dot(colorWeights, v1), dot(colorWeights, v2), dot(colorWeights, v3));
}

bvec4 andAll(bvec4 A, bvec4 B) {
    return bvec4(A.x && B.x, A.y && B.y, A.z && B.z, A.w && B.w);
}

bvec4 orAll(bvec4 A, bvec4 B) {
    return bvec4(A.x || B.x, A.y || B.y, A.z || B.z, A.w || B.w);
}

vec4 absDiff(vec4 A, vec4 B) {
    return abs(A - B);
}

bvec4 equalEps(vec4 A, vec4 B) {
    return lessThan(absDiff(A, B), vec4(threshold));
}

vec4 weightedDistance(vec4 a, vec4 b, vec4 c, vec4 d, vec4 e, vec4 f, vec4 g, vec4 h) {
    return absDiff(a, b) + absDiff(a, c) + absDiff(d, e) + absDiff(d, f) + 4.0 * absDiff(g, h);
}

void main() {
    float sx = 1 / size.x;
    float sy = 1 / size.y;

    vec2 dx = vec2(sx, 0);
    vec2 dy = vec2(0, sy);

    vec2 fp = fract(textureCoords * size);

    vec3 A1 = texture2D(color, textureCoords - dx - 2 * dy).rgb;
    vec3 B1 = texture2D(color, textureCoords - 2 * dy).rgb;
    vec3 C1 = texture2D(color, textureCoords + dx - 2 * dy).rgb;

    vec3 A  = texture2D(color, textureCoords - dx - dy).rgb;
    vec3 B  = texture2D(color, textureCoords - dy).rgb;
    vec3 C  = texture2D(color, textureCoords + dx - dy).rgb;

    vec3 D  = texture2D(color, textureCoords - dx).rgb;
    vec3 E  = texture2D(color, textureCoords).rgb;
    vec3 F  = texture2D(color, textureCoords + dx).rgb;

    vec3 G  = texture2D(color, textureCoords - dx + dy).rgb;
    vec3 H  = texture2D(color, textureCoords + dy).rgb;
    vec3 I  = texture2D(color, textureCoords + dx + dy).rgb;

    vec3 G5 = texture2D(color, textureCoords - dx + 2 * dy).rgb;
    vec3 H5 = texture2D(color, textureCoords + 2 * dy).rgb;
    vec3 I5 = texture2D(color, textureCoords + dx + 2 * dy).rgb;

    vec3 A0 = texture2D(color, textureCoords - 2 * dx - dy).rgb;
    vec3 D0 = texture2D(color, textureCoords - 2 * dx).rgb;
    vec3 G0 = texture2D(color, textureCoords - 2 * dx + dy).rgb;

    vec3 C4 = texture2D(color, textureCoords + 2 * dx - dy).rgb;
    vec3 F4 = texture2D(color, textureCoords + 2 * dx).rgb;
    vec3 I4 = texture2D(color, textureCoords + 2 * dx + dy).rgb;

    vec4 b = weightedBlend(B, D, H, F);
    vec4 c = weightedBlend(C, A, G, I);
    vec4 e = weightedBlend(E, E, E, E);
    vec4 d = b.yzwx;
    vec4 f = b.wxyz;
    vec4 g = c.zwxy;
    vec4 h = b.zwxy;
    vec4 i = c.wxyz;

    vec4 i4 = weightedBlend(I4, C1, A0, G5);
    vec4 i5 = weightedBlend(I5, C4, A1, G0);
    vec4 h5 = weightedBlend(H5, F4, B1, D0);
    vec4 f4 = h5.yzwx;

    bvec4 fx = greaterThan(Ao * fp.y + Bo * fp.x, Co);
    bvec4 fxLeft = greaterThan(Ax * fp.y + Bx * fp.x, Cx);
    bvec4 fxUP = greaterThan(Ay * fp.y + By * fp.x, Cy);

    bvec4 t1 = andAll(notEqual(e, f), notEqual(e, h));
    bvec4 t2 = andAll(not(equalEps(f, b)), not(equalEps(h, d)));
    bvec4 t3 = andAll(andAll(equalEps(e, i), not(equalEps(f, i4))), not(equalEps(h, i5)));
    bvec4 t4 = orAll(equalEps(e, g), equalEps(e, c));
    bvec4 interpRestriction1 = andAll(t1, orAll(orAll(t2, t3), t4));

    bvec4 interpRestriction2Left = andAll(notEqual(e, g), notEqual(d, g));
    bvec4 interpRestriction2Up = andAll(notEqual(e, c), notEqual(b, c));

    bvec4 edr = andAll(lessThan(weightedDistance(e, c, g, i, h5, f4, h, f), weightedDistance(h, d, i5, f, i4, b, e, i)), interpRestriction1);
    bvec4 edrLeft = andAll(lessThanEqual(coefficient * absDiff(f, g), absDiff(h, c)), interpRestriction2Left);
    bvec4 edrUp = andAll(greaterThanEqual(absDiff(f, g), coefficient * absDiff(h, c)), interpRestriction2Up);

    bvec4 nc = andAll(edr, orAll(orAll(fx, andAll(edrLeft, fxLeft)), andAll(edrUp, fxUP)));

    bvec4 px = lessThanEqual(absDiff(e, f), absDiff(e, h));

    gl_FragColor.rgb =
        nc.x
            ? px.x
                ? F
                : H
            : nc.y
                ? px.y
                    ? B
                    : F
                : nc.z
                    ? px.z
                        ? D
                        : B
                    : nc.w
                        ? px.w
                            ? H
                            : D
                        : E;
}
`;

// TODO: this is slightly wrong
public enum string BICUBIC_UPSCALE_FRAGMENT_SHADER_SOURCE =
`
// See: http://www.paulinternet.nl/?page=bicubic

// $shader_type: fragment

// $texture_layout: color = 0

#version 120

varying vec2 textureCoords;

uniform sampler2D color;
uniform vec2 size;

vec4 cubic(vec4 s0, vec4 s1, vec4 s2, vec4 s3, float p) {
    return s1 + 0.5 * p * (s2 - s0 + p * (2 * s0 - 5 * s1 + 4 * s2 - s3 + p * (3 * (s1 - s2) + s3 - s0)));
}

void main() {
    float sx = 1 / size.x;
    float sy = 1 / size.y;

    vec2 dx = vec2(sx, 0);
    vec2 dy = vec2(0, sy);

    vec2 fp = fract(textureCoords * size);

    vec4 s00 = texture2D(color, textureCoords - dx - dy);
    vec4 s01 = texture2D(color, textureCoords - dy);
    vec4 s02 = texture2D(color, textureCoords + dx - dy);
    vec4 s03 = texture2D(color, textureCoords + 2 * dx - dy);

    vec4 s10 = texture2D(color, textureCoords - dx);
    vec4 s11 = texture2D(color, textureCoords);
    vec4 s12 = texture2D(color, textureCoords + dx);
    vec4 s13 = texture2D(color, textureCoords + 2 * dx);

    vec4 s20 = texture2D(color, textureCoords - dx + dy);
    vec4 s21 = texture2D(color, textureCoords + dy);
    vec4 s22 = texture2D(color, textureCoords + dx + dy);
    vec4 s23 = texture2D(color, textureCoords + 2 * dx + dy);

    vec4 s30 = texture2D(color, textureCoords - dx + 2 * dy);
    vec4 s31 = texture2D(color, textureCoords + 2 * dy);
    vec4 s32 = texture2D(color, textureCoords + dx + 2 * dy);
    vec4 s33 = texture2D(color, textureCoords + 2 * dx + 2 * dy);

    vec4 c0 = cubic(s00, s01, s02, s03, fp.x);
    vec4 c1 = cubic(s10, s11, s12, s13, fp.x);
    vec4 c2 = cubic(s20, s21, s22, s23, fp.x);
    vec4 c3 = cubic(s30, s31, s32, s33, fp.x);

    gl_FragColor = cubic(c0, c1, c2, c3, fp.y);
}
`;
