// HDR output for ImGui's D3D10/11/12 backends, game window only.
// mode 0 SDR, 1 scRGB, 2 HDR10
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

struct ImDrawList;
struct ImDrawCmd;

void tuft_imgui_hdr_set(int mode, float sdr_white_nits);
// Call before the device goes away. On D3D12 wait for the GPU first.
void tuft_imgui_hdr_release(void);

// ImDrawCallbacks. D3D12's user data is the game's back buffer format.
void tuft_imgui_hdr_dx10_callback(const struct ImDrawList* list, const struct ImDrawCmd* cmd);
void tuft_imgui_hdr_dx11_callback(const struct ImDrawList* list, const struct ImDrawCmd* cmd);
void tuft_imgui_hdr_dx12_callback(const struct ImDrawList* list, const struct ImDrawCmd* cmd);

#ifdef __cplusplus
}
#endif

#define TUFT_IMGUI_HDR_HLSL \
    "float3 tuft_linear(float3 c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); } " \
    "float3 tuft_pq(float3 n) { " \
    "  float3 y = pow(max(n, 0.0), 0.1593017578125); " \
    "  return pow((0.8359375 + 18.8515625 * y) / (1.0 + 18.6875 * y), 78.84375); } " \
    "float4 tuft_output(float4 c) { " \
    "  if (TUFT_MODE == 0) return c; " \
    "  float3 l = tuft_linear(saturate(c.rgb)) * (TUFT_SDR_WHITE / 80.0); " \
    "  if (TUFT_MODE == 1) return float4(l, c.a); " \
    "  float3 r = mul(float3x3(0.627404, 0.329283, 0.043313, 0.069097, 0.919540, 0.011362, 0.016391, 0.088013, 0.895595), l); " \
    "  return float4(tuft_pq(r * (80.0 / 10000.0)), c.a); } "