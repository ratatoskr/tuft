// HDR for ImGui's D3D10/11/12 backends.

// Must come first, the SDK refuses d3d10_1.h after d3d10.h
#include <d3d10_1.h>

#include "imgui.h"
#include "imgui_impl_dx10.h"
#include "imgui_impl_dx11.h"
#include "imgui_impl_dx12.h"
#include "hdr.h"

#include <d3d10.h>
#include <d3d11.h>
#include <d3d12.h>
#include <d3dcompiler.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

namespace {

int mode = 0;
float sdr_white = 200.0f;
// Bumped on every change so stuff made for old settings gets rebuilt
unsigned generation = 1;

// ImGui's shaders, copied from its backends. Pixel ones end with our conversion
const char* ps_dx10_11 =
    "struct PS_INPUT { float4 pos : SV_POSITION; float4 col : COLOR0; float2 uv : TEXCOORD0; };"
    "sampler sampler0; Texture2D texture0; " TUFT_IMGUI_HDR_HLSL
    "float4 main(PS_INPUT input) : SV_Target {"
    "  return tuft_output(input.col * texture0.Sample(sampler0, input.uv)); }";
const char* ps_dx12 =
    "struct PS_INPUT { float4 pos : SV_POSITION; float4 col : COLOR0; float2 uv : TEXCOORD0; };"
    "SamplerState sampler0 : register(s0); Texture2D texture0 : register(t0); " TUFT_IMGUI_HDR_HLSL
    "float4 main(PS_INPUT input) : SV_Target {"
    "  return tuft_output(input.col * texture0.Sample(sampler0, input.uv)); }";
const char* vs_dx12 =
    "cbuffer vertexBuffer : register(b0) { float4x4 ProjectionMatrix; };"
    "struct VS_INPUT { float2 pos : POSITION; float4 col : COLOR0; float2 uv : TEXCOORD0; };"
    "struct PS_INPUT { float4 pos : SV_POSITION; float4 col : COLOR0; float2 uv : TEXCOORD0; };"
    "PS_INPUT main(VS_INPUT input) {"
    "  PS_INPUT output;"
    "  output.pos = mul(ProjectionMatrix, float4(input.pos.xy, 0.0f, 1.0f));"
    "  output.col = input.col;"
    "  output.uv = input.uv;"
    "  return output; }";

ID3DBlob* compile(const char* source, const char* target) {
    char mode_text[16], white_text[32];
    snprintf(mode_text, sizeof(mode_text), "%d", mode);
    snprintf(white_text, sizeof(white_text), "%.3f", (double)sdr_white);
    const D3D_SHADER_MACRO defines[] = {{"TUFT_MODE", mode_text}, {"TUFT_SDR_WHITE", white_text}, {nullptr, nullptr}};
    ID3DBlob* blob = nullptr;
    if (FAILED(D3DCompile(source, strlen(source), nullptr, defines, nullptr, "main", target, 0, 0, &blob, nullptr))) return nullptr;
    return blob;
}

template <typename T>
void release(T*& p) {
    if (p) p->Release();
    p = nullptr;
}

template <typename Device, typename Shader>
struct HdrShader {
    Device* device = nullptr;
    Shader* shader = nullptr;
    unsigned made_for = 0;

    template <typename Create>
    Shader* get(Device* d, Create create) {
        if (d != device || made_for != generation) {
            release(shader);
            device = d;
            made_for = generation;
            if (ID3DBlob* blob = compile(ps_dx10_11, "ps_4_0")) {
                create(d, blob, &shader);
                blob->Release();
            }
        }
        return shader;
    }
};

HdrShader<ID3D10Device, ID3D10PixelShader> dx10;
HdrShader<ID3D11Device, ID3D11PixelShader> dx11;

// ImGui's D3D12 pipeline in the game's format with the HDR pixel shader
struct Dx12 {
    ID3D12Device* device = nullptr;
    DXGI_FORMAT format = DXGI_FORMAT_UNKNOWN;
    unsigned made_for = 0;
    ID3D12RootSignature* root = nullptr;
    ID3D12PipelineState* pso = nullptr;

    void release() {
        ::release(pso);
        ::release(root);
        device = nullptr;
    }

    bool make(ID3D12Device* d, DXGI_FORMAT f) {
        release();
        device = d;
        format = f;
        made_for = generation;

        D3D12_DESCRIPTOR_RANGE range = {};
        range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
        range.NumDescriptors = 1;
        D3D12_ROOT_PARAMETER params[2] = {};
        params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
        params[0].Constants.Num32BitValues = 16;
        params[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX;
        params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        params[1].DescriptorTable.NumDescriptorRanges = 1;
        params[1].DescriptorTable.pDescriptorRanges = &range;
        params[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_STATIC_SAMPLER_DESC sampler = {};
        sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        sampler.ComparisonFunc = D3D12_COMPARISON_FUNC_ALWAYS;
        sampler.BorderColor = D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK;
        sampler.MaxLOD = D3D12_FLOAT32_MAX;
        sampler.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_ROOT_SIGNATURE_DESC root_desc = {};
        root_desc.NumParameters = 2;
        root_desc.pParameters = params;
        root_desc.NumStaticSamplers = 1;
        root_desc.pStaticSamplers = &sampler;
        root_desc.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT | D3D12_ROOT_SIGNATURE_FLAG_DENY_HULL_SHADER_ROOT_ACCESS |
                          D3D12_ROOT_SIGNATURE_FLAG_DENY_DOMAIN_SHADER_ROOT_ACCESS | D3D12_ROOT_SIGNATURE_FLAG_DENY_GEOMETRY_SHADER_ROOT_ACCESS;
        ID3DBlob* blob = nullptr;
        if (FAILED(tuft_lazy_D3D12SerializeRootSignature()(&root_desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, nullptr))) return false;
        HRESULT hr = d->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(), IID_PPV_ARGS(&root));
        blob->Release();
        if (FAILED(hr)) return false;

        ID3DBlob* vs = compile(vs_dx12, "vs_5_0");
        ID3DBlob* ps = compile(ps_dx12, "ps_5_0");
        if (vs && ps) {
            const D3D12_INPUT_ELEMENT_DESC layout[] = {
                {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, (UINT)offsetof(ImDrawVert, pos), D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
                {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, (UINT)offsetof(ImDrawVert, uv), D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
                {"COLOR", 0, DXGI_FORMAT_R8G8B8A8_UNORM, 0, (UINT)offsetof(ImDrawVert, col), D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
            };
            D3D12_GRAPHICS_PIPELINE_STATE_DESC desc = {};
            desc.NodeMask = 1;
            desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
            desc.pRootSignature = root;
            desc.SampleMask = UINT_MAX;
            desc.NumRenderTargets = 1;
            desc.RTVFormats[0] = f;
            desc.SampleDesc.Count = 1;
            desc.VS = {vs->GetBufferPointer(), vs->GetBufferSize()};
            desc.PS = {ps->GetBufferPointer(), ps->GetBufferSize()};
            desc.InputLayout = {layout, 3};
            D3D12_RENDER_TARGET_BLEND_DESC& blend = desc.BlendState.RenderTarget[0];
            blend.BlendEnable = true;
            blend.SrcBlend = D3D12_BLEND_SRC_ALPHA;
            blend.DestBlend = D3D12_BLEND_INV_SRC_ALPHA;
            blend.BlendOp = D3D12_BLEND_OP_ADD;
            blend.SrcBlendAlpha = D3D12_BLEND_ONE;
            blend.DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA;
            blend.BlendOpAlpha = D3D12_BLEND_OP_ADD;
            blend.RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
            desc.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
            desc.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
            desc.RasterizerState.DepthClipEnable = true;
            desc.DepthStencilState.DepthEnable = false;
            desc.DepthStencilState.StencilEnable = false;
            d->CreateGraphicsPipelineState(&desc, IID_PPV_ARGS(&pso));
        }
        if (vs) vs->Release();
        if (ps) ps->Release();
        return pso != nullptr;
    }
};

Dx12 dx12;

} // namespace

extern "C" void tuft_imgui_hdr_set(int m, float white) {
    if (m == mode && white == sdr_white) return;
    mode = m;
    sdr_white = white;
    generation++;
}

extern "C" void tuft_imgui_hdr_release(void) {
    release(dx10.shader);
    dx10.device = nullptr;
    release(dx11.shader);
    dx11.device = nullptr;
    dx12.release();
}

extern "C" void tuft_imgui_hdr_dx10_callback(const ImDrawList*, const ImDrawCmd*) {
    auto* rs = (ImGui_ImplDX10_RenderState*)ImGui::GetPlatformIO().Renderer_RenderState;
    if (!rs || mode == 0) return;
    ID3D10PixelShader* ps = dx10.get(rs->Device, [](ID3D10Device* d, ID3DBlob* blob, ID3D10PixelShader** out) {
        d->CreatePixelShader(blob->GetBufferPointer(), blob->GetBufferSize(), out);
    });
    if (ps) rs->Device->PSSetShader(ps);
}

extern "C" void tuft_imgui_hdr_dx11_callback(const ImDrawList*, const ImDrawCmd*) {
    auto* rs = (ImGui_ImplDX11_RenderState*)ImGui::GetPlatformIO().Renderer_RenderState;
    if (!rs || mode == 0) return;
    ID3D11PixelShader* ps = dx11.get(rs->Device, [](ID3D11Device* d, ID3DBlob* blob, ID3D11PixelShader** out) {
        d->CreatePixelShader(blob->GetBufferPointer(), blob->GetBufferSize(), nullptr, out);
    });
    if (ps) rs->DeviceContext->PSSetShader(ps, nullptr, 0);
}

extern "C" void tuft_imgui_hdr_dx12_callback(const ImDrawList*, const ImDrawCmd* cmd) {
    auto* rs = (ImGui_ImplDX12_RenderState*)ImGui::GetPlatformIO().Renderer_RenderState;
    if (!rs) return;
    const DXGI_FORMAT format = (DXGI_FORMAT)(uintptr_t)cmd->UserCallbackData;
    if (rs->Device != dx12.device || format != dx12.format || dx12.made_for != generation) dx12.make(rs->Device, format);
    if (!dx12.pso) return;

    // Switching root signature drops its arguments, so set the projection again
    const ImDrawData* dd = ImGui::GetMainViewport()->DrawData;
    const float L = dd->DisplayPos.x, R = dd->DisplayPos.x + dd->DisplaySize.x;
    const float T = dd->DisplayPos.y, B = dd->DisplayPos.y + dd->DisplaySize.y;
    const float mvp[4][4] = {
        {2.0f / (R - L), 0.0f, 0.0f, 0.0f},
        {0.0f, 2.0f / (T - B), 0.0f, 0.0f},
        {0.0f, 0.0f, 0.5f, 0.0f},
        {(R + L) / (L - R), (T + B) / (B - T), 0.5f, 1.0f},
    };
    rs->CommandList->SetGraphicsRootSignature(dx12.root);
    rs->CommandList->SetPipelineState(dx12.pso);
    rs->CommandList->SetGraphicsRoot32BitConstants(0, 16, mvp, 0);
}