// ImGui's C API for translate-c.
// We declare the few DX9/DX11 types needed since translating their headers is huge.
#pragma once

#include "dcimgui.h"

typedef struct ID3D11Device ID3D11Device;
typedef struct ID3D11DeviceContext ID3D11DeviceContext;
typedef struct ID3D11Buffer ID3D11Buffer;
typedef struct ID3D11SamplerState ID3D11SamplerState;
typedef struct ID3D11ShaderResourceView ID3D11ShaderResourceView;
#include "dcimgui_impl_dx11.h"

#include "dcimgui_impl_dx10.h"

#include "dcimgui_impl_dx12.h"

typedef struct IDirect3DDevice9 IDirect3DDevice9;
#include "dcimgui_impl_dx9.h"

#include "dcimgui_impl_opengl2.h"

// No prototypes, tuft loads the functions
#define IMGUI_IMPL_VULKAN_NO_PROTOTYPES
#include "dcimgui_impl_vulkan.h"

// Its wndproc handler needs <windows.h>, so it's declared in Zig
#include "dcimgui_impl_win32.h"

#include "guizmo.h"

#include "plot.h"