// ImGui C++ and internal API bits exposed as plain C.

#include "imgui.h"
#include "imgui_internal.h"

#include <stdio.h>
#include <string.h>

thread_local ImGuiContext* tuft_imgui_current_context = nullptr;

extern "C" {

typedef void (*tuft_imgui_assert_handler_fn)(const char* expr, const char* file, int line);

tuft_imgui_assert_handler_fn tuft_imgui_assert_handler = nullptr;

void tuft_imgui_assert_failed(const char* expr, const char* file, int line) {
    if (tuft_imgui_assert_handler) {
        tuft_imgui_assert_handler(expr, file, line);
    } else {
        fprintf(stderr, "ImGui assertion failed: %s (%s:%d)\n", expr, file, line);
    }
}

// Unwinds ImGui's stacks if fn left them unbalanced so the next caller starts clean.
bool tuft_imgui_guarded(void (*fn)(void*), void* ctx) {
    ImGuiErrorRecoveryState before;
    ImGui::ErrorRecoveryStoreState(&before);
    fn(ctx);
    ImGuiErrorRecoveryState after;
    ImGui::ErrorRecoveryStoreState(&after);
    if (memcmp(&before, &after, sizeof before) == 0) return true;
    ImGui::ErrorRecoveryTryToRecoverState(&before);
    return false;
}

// Here because C can't resize an ImVector.
void tuft_imgui_set_monitors(const ImGuiPlatformMonitor* monitors, int count) {
    ImGuiPlatformIO& platform_io = ImGui::GetPlatformIO();
    platform_io.Monitors.resize(0);
    for (int i = 0; i < count; i++) platform_io.Monitors.push_back(monitors[i]);
}

// Skips the main viewport since the backend may still use it. DX12 would wait on a null queue.
void tuft_imgui_destroy_viewport_windows() {
    ImGuiContext& g = *GImGui;
    for (ImGuiViewportP* viewport : g.Viewports)
        if (viewport != g.Viewports[0]) ImGui::DestroyPlatformWindow(viewport);
}

bool tuft_imgui_dock_exists(ImGuiID id) {
    return ImGui::DockBuilderGetNode(id) != nullptr;
}

ImGuiID tuft_imgui_dock_of(const char* name) {
    ImGuiWindow* window = ImGui::FindWindowByName(name);
    if (window != nullptr) return window->DockId;
    ImGuiWindowSettings* settings = ImGui::FindWindowSettingsByID(ImHashStr(name));
    return settings != nullptr ? settings->DockId : 0;
}

ImGuiID tuft_imgui_dock_central(ImGuiID id) {
    ImGuiDockNode* node = ImGui::DockBuilderGetNode(id);
    if (node == nullptr || node->CentralNode == nullptr) return 0;
    return node->CentralNode->ID;
}

bool tuft_imgui_dock_in_front(const char* name) {
    ImGuiWindow* window = ImGui::FindWindowByName(name);
    if (window == nullptr || window->DockNode == nullptr) return false;
    return window->DockNode->SelectedTabId == window->TabId;
}

void tuft_imgui_dock_bring_to_front(const char* name) {
    ImGuiWindow* window = ImGui::FindWindowByName(name);
    if (window == nullptr || window->DockNode == nullptr) return;
    ImGuiDockNode* node = window->DockNode;
    node->SelectedTabId = window->TabId;
    if (node->TabBar != nullptr) node->TabBar->NextSelectedTabId = window->TabId;
}

void tuft_imgui_dock_reset(ImGuiID id, float width, float height) {
    ImGui::DockBuilderRemoveNode(id);
    ImGui::DockBuilderAddNode(id, ImGuiDockNodeFlags_DockSpace);
    ImGui::DockBuilderSetNodeSize(id, ImVec2(width, height));
}

ImGuiID tuft_imgui_dock_split(ImGuiID node, int dir, float ratio, ImGuiID* rest) {
    return ImGui::DockBuilderSplitNode(node, (ImGuiDir)dir, ratio, nullptr, rest);
}

void tuft_imgui_dock_window(const char* name, ImGuiID node) {
    ImGui::DockBuilderDockWindow(name, node);
}

void tuft_imgui_dock_finish(ImGuiID id) {
    ImGui::DockBuilderFinish(id);
}

// Draws the current window over every other one, without focusing it.
void tuft_imgui_bring_window_to_front() {
    ImGui::BringWindowToDisplayFront(ImGui::GetCurrentWindow());
}

// The atlas doesn't copy the data, so it must outlive the context.
ImFont* tuft_imgui_add_font(const void* data, int len, float size, const char* name, bool skip_private_use) {
    // Static, since the atlas keeps the pointer
    static const ImWchar private_use[] = { 0xE000, 0xF8FF, 0 };
    ImFontConfig config;
    config.FontDataOwnedByAtlas = false;
    if (skip_private_use) config.GlyphExcludeRanges = private_use;
    ImFormatString(config.Name, IM_ARRAYSIZE(config.Name), "%s", name);
    return ImGui::GetIO().Fonts->AddFontFromMemoryTTF(const_cast<void*>(data), len, size, &config);
}

// Its glyphs go into `into`, for the ones `into` doesn't have, like icons. Same lifetime as above.
bool tuft_imgui_merge_font(const void* data, int len, float size, ImFont* into, const char* name, float offset_y) {
    ImFontConfig config;
    config.FontDataOwnedByAtlas = false;
    config.MergeMode = true;
    config.GlyphOffset.y = offset_y;
    config.DstFont = into;
    ImFormatString(config.Name, IM_ARRAYSIZE(config.Name), "%s", name);
    return ImGui::GetIO().Fonts->AddFontFromMemoryTTF(const_cast<void*>(data), len, size, &config) != nullptr;
}

// Loading empty settings won't do it since windows only read settings when created.
void tuft_imgui_reset_layout() {
    ImGuiContext& g = *GImGui;
    ImGui::ClearIniSettings();
    for (ImGuiWindow* window : g.Windows) {
        if (window->Flags & ImGuiWindowFlags_ChildWindow) continue;
        // Back to 60,60 so its FirstUseEver size applies again
        ImGui::ClearWindowSettings(window->Name);
        window->Collapsed = false;
    }
    ImGui::MarkIniSettingsDirty();
}

// Marks every texture ready with a dummy id so frames run headless.
void tuft_imgui_headless_init() {
    ImGuiIO& io = ImGui::GetIO();
    io.BackendRendererName = "tuft_imgui_headless";
    io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures;
}

void tuft_imgui_headless_textures() {
    ImGuiPlatformIO& platform_io = ImGui::GetPlatformIO();
    for (ImTextureData* tex : platform_io.Textures) {
        if (tex->Status == ImTextureStatus_WantCreate || tex->Status == ImTextureStatus_WantUpdates) {
            tex->SetTexID((ImTextureID)1);
            tex->SetStatus(ImTextureStatus_OK);
        } else if (tex->Status == ImTextureStatus_WantDestroy) {
            tex->SetTexID(ImTextureID_Invalid);
            tex->SetStatus(ImTextureStatus_Destroyed);
        }
    }
}

// Textures for Texture.zig. The backend uploads `pixels`, which stay the caller's.
ImTextureData* tuft_imgui_texture_add(int width, int height, unsigned char* pixels) {
    ImTextureData* tex = IM_NEW(ImTextureData)();
    tex->Format = ImTextureFormat_RGBA32;
    tex->Width = width;
    tex->Height = height;
    tex->BytesPerPixel = 4;
    tex->Pixels = pixels;
    tex->UseColors = true;
    tex->UsedRect.x = tex->UsedRect.y = 0;
    tex->UsedRect.w = (unsigned short)width;
    tex->UsedRect.h = (unsigned short)height;
    tex->UpdateRect.x = tex->UpdateRect.y = (unsigned short)~0;
    tex->UpdateRect.w = tex->UpdateRect.h = 0;
    tex->Status = ImTextureStatus_WantCreate;
    ImGui::RegisterUserTexture(tex);
    return tex;
}

// Also out of last frame's list, since a backend can go through it before the next frame.
void tuft_imgui_texture_remove(ImTextureData* tex) {
    ImGui::UnregisterUserTexture(tex);
    ImGui::GetPlatformIO().Textures.find_erase(tex);
    tex->Pixels = nullptr;
    IM_DELETE(tex);
}

static void tuft_imgui_texture_hook(ImGuiContext*, ImGuiContextHook* hook) {
    ((void (*)(void))hook->UserData)();
}

// Calls `new_frame` at the start of each frame and `shutdown` when the current context goes.
void tuft_imgui_texture_hooks(void (*new_frame)(void), void (*shutdown)(void)) {
    ImGuiContextHook hook;
    hook.Callback = tuft_imgui_texture_hook;
    hook.Type = ImGuiContextHookType_NewFramePre;
    hook.UserData = (void*)new_frame;
    ImGui::AddContextHook(GImGui, &hook);
    hook.Type = ImGuiContextHookType_Shutdown;
    hook.UserData = (void*)shutdown;
    ImGui::AddContextHook(GImGui, &hook);
}

}
