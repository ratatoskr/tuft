#version 450 core
// ImGui's Vulkan fragment shader with HDR output conversion.
// Build with glslangValidator -V -o hdr.frag.spv hdr.frag

layout(location = 0) out vec4 fColor;
layout(set = 0, binding = 0) uniform texture2D _Texture;
layout(set = 1, binding = 0) uniform sampler _Sampler;
layout(location = 0) in struct { vec4 Color; vec2 UV; } In;

// 0 SDR, 1 scRGB, 2 HDR10
layout(constant_id = 0) const int TUFT_MODE = 0;
// Nits Windows shows SDR content at
layout(constant_id = 1) const float TUFT_SDR_WHITE = 200.0;

vec3 tuft_linear(vec3 c) {
    return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThanEqual(c, vec3(0.04045)));
}

vec3 tuft_pq(vec3 n) {
    vec3 y = pow(max(n, vec3(0.0)), vec3(0.1593017578125));
    return pow((0.8359375 + 18.8515625 * y) / (1.0 + 18.6875 * y), vec3(78.84375));
}

vec4 tuft_output(vec4 c) {
    if (TUFT_MODE == 0) return c;
    vec3 l = tuft_linear(clamp(c.rgb, 0.0, 1.0)) * (TUFT_SDR_WHITE / 80.0);
    if (TUFT_MODE == 1) return vec4(l, c.a);
    // Column-major, so these columns are the rows of the Rec.709 to Rec.2020 matrix
    mat3 to2020 = mat3(
        0.627404, 0.069097, 0.016391,
        0.329283, 0.919540, 0.088013,
        0.043313, 0.011362, 0.895595);
    return vec4(tuft_pq(to2020 * l * (80.0 / 10000.0)), c.a);
}

void main() {
    fColor = tuft_output(In.Color * texture(sampler2D(_Texture, _Sampler), In.UV.st));
}
