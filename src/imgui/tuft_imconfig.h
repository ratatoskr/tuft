// ImGui build config.
#pragma once

// tuft loads Vulkan itself
#define IMGUI_IMPL_VULKAN_NO_PROTOTYPES

// No gamepads. XInput could wait on a stopped thread holding the loader lock
#define IMGUI_IMPL_WIN32_DISABLE_GAMEPAD

#ifdef __cplusplus
// Failed asserts go to `setAssertHandler` instead of killing the game.
extern "C" void tuft_imgui_assert_failed(const char* expr, const char* file, int line);
#define IM_ASSERT(_EXPR) ((_EXPR) ? (void)0 : tuft_imgui_assert_failed(#_EXPR, __FILE__, __LINE__))

// Per-thread context so our threads can run while the render thread is stuck mid-frame
struct ImGuiContext;
extern thread_local ImGuiContext* tuft_imgui_current_context;
#define GImGui tuft_imgui_current_context

// ImPlot's too, one per ImGui context. See plot.cpp
struct ImPlotContext;
extern thread_local ImPlotContext* tuft_implot_current_context;
#define GImPlot tuft_implot_current_context
#endif
