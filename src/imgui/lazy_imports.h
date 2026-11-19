// Force-included into C++ that calls D3D, OpenGL or DWM so those DLLs get looked up lazily, not imported.
// `TUFT_LAZY(dll, fn)` plus `#define fn tuft_lazy_call_fn` redirects calls. A missed one fails the link.

#pragma once

#include <windows.h>
#include <dwmapi.h>
#include <GL/gl.h>
#include <d3dcompiler.h>
#include <d3d12.h>
#include <dxgi.h>

namespace tuft_lazy {

inline void* resolve(const char* dll, const char* name) {
    HMODULE module = GetModuleHandleA(dll);
    if (!module) module = LoadLibraryExA(dll, nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    void* address = module ? reinterpret_cast<void*>(GetProcAddress(module, name)) : nullptr;
    // Only called with the API in use, so the DLL is loaded
    if (!address) __builtin_trap();
    return address;
}

template <auto Get>
struct Caller {
    template <typename... Args>
    auto operator()(Args... args) const {
        return Get()(args...);
    }
};

} // namespace tuft_lazy

#define TUFT_LAZY(dll, fn)                                                      \
    inline decltype(&::fn) tuft_lazy_##fn() {                                   \
        static void* volatile address = nullptr;                               \
        if (!address) address = tuft_lazy::resolve(dll, #fn);                  \
        return reinterpret_cast<decltype(&::fn)>(address);                      \
    }                                                                           \
    inline constexpr tuft_lazy::Caller<&tuft_lazy_##fn> tuft_lazy_call_##fn{};

// Not redirected, ImGui's DX12 backend looks it up itself
TUFT_LAZY("d3d12.dll", D3D12SerializeRootSignature)

TUFT_LAZY("dxgi.dll", CreateDXGIFactory1)
#define CreateDXGIFactory1 tuft_lazy_call_CreateDXGIFactory1

TUFT_LAZY("d3dcompiler_47.dll", D3DCompile)
#define D3DCompile tuft_lazy_call_D3DCompile

// For ImGui's Win32 alpha compositing helper, which we don't use
TUFT_LAZY("dwmapi.dll", DwmIsCompositionEnabled)
TUFT_LAZY("dwmapi.dll", DwmGetColorizationColor)
TUFT_LAZY("dwmapi.dll", DwmEnableBlurBehindWindow)
#define DwmIsCompositionEnabled tuft_lazy_call_DwmIsCompositionEnabled
#define DwmGetColorizationColor tuft_lazy_call_DwmGetColorizationColor
#define DwmEnableBlurBehindWindow tuft_lazy_call_DwmEnableBlurBehindWindow

// ImGui's OpenGL2 backend
#define TUFT_LAZY_GL(fn) TUFT_LAZY("opengl32.dll", fn)
TUFT_LAZY_GL(glBindTexture)
TUFT_LAZY_GL(glBlendFunc)
TUFT_LAZY_GL(glClear)
TUFT_LAZY_GL(glClearColor)
TUFT_LAZY_GL(glColorPointer)
TUFT_LAZY_GL(glDeleteTextures)
TUFT_LAZY_GL(glDisable)
TUFT_LAZY_GL(glDisableClientState)
TUFT_LAZY_GL(glDrawElements)
TUFT_LAZY_GL(glEnable)
TUFT_LAZY_GL(glEnableClientState)
TUFT_LAZY_GL(glGenTextures)
TUFT_LAZY_GL(glGetIntegerv)
TUFT_LAZY_GL(glGetTexEnviv)
TUFT_LAZY_GL(glLoadIdentity)
TUFT_LAZY_GL(glMatrixMode)
TUFT_LAZY_GL(glOrtho)
TUFT_LAZY_GL(glPixelStorei)
TUFT_LAZY_GL(glPolygonMode)
TUFT_LAZY_GL(glPopAttrib)
TUFT_LAZY_GL(glPopMatrix)
TUFT_LAZY_GL(glPushAttrib)
TUFT_LAZY_GL(glPushMatrix)
TUFT_LAZY_GL(glScissor)
TUFT_LAZY_GL(glShadeModel)
TUFT_LAZY_GL(glTexCoordPointer)
TUFT_LAZY_GL(glTexEnvi)
TUFT_LAZY_GL(glTexImage2D)
TUFT_LAZY_GL(glTexParameteri)
TUFT_LAZY_GL(glTexSubImage2D)
TUFT_LAZY_GL(glVertexPointer)
TUFT_LAZY_GL(glViewport)
#define glBindTexture tuft_lazy_call_glBindTexture
#define glBlendFunc tuft_lazy_call_glBlendFunc
#define glClear tuft_lazy_call_glClear
#define glClearColor tuft_lazy_call_glClearColor
#define glColorPointer tuft_lazy_call_glColorPointer
#define glDeleteTextures tuft_lazy_call_glDeleteTextures
#define glDisable tuft_lazy_call_glDisable
#define glDisableClientState tuft_lazy_call_glDisableClientState
#define glDrawElements tuft_lazy_call_glDrawElements
#define glEnable tuft_lazy_call_glEnable
#define glEnableClientState tuft_lazy_call_glEnableClientState
#define glGenTextures tuft_lazy_call_glGenTextures
#define glGetIntegerv tuft_lazy_call_glGetIntegerv
#define glGetTexEnviv tuft_lazy_call_glGetTexEnviv
#define glLoadIdentity tuft_lazy_call_glLoadIdentity
#define glMatrixMode tuft_lazy_call_glMatrixMode
#define glOrtho tuft_lazy_call_glOrtho
#define glPixelStorei tuft_lazy_call_glPixelStorei
#define glPolygonMode tuft_lazy_call_glPolygonMode
#define glPopAttrib tuft_lazy_call_glPopAttrib
#define glPopMatrix tuft_lazy_call_glPopMatrix
#define glPushAttrib tuft_lazy_call_glPushAttrib
#define glPushMatrix tuft_lazy_call_glPushMatrix
#define glScissor tuft_lazy_call_glScissor
#define glShadeModel tuft_lazy_call_glShadeModel
#define glTexCoordPointer tuft_lazy_call_glTexCoordPointer
#define glTexEnvi tuft_lazy_call_glTexEnvi
#define glTexImage2D tuft_lazy_call_glTexImage2D
#define glTexParameteri tuft_lazy_call_glTexParameteri
#define glTexSubImage2D tuft_lazy_call_glTexSubImage2D
#define glVertexPointer tuft_lazy_call_glVertexPointer
#define glViewport tuft_lazy_call_glViewport
