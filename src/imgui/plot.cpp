// C wrappers for ImPlot's C++. See plot.h.

#include "imgui.h"
#include "imgui_internal.h"

#include "implot.h"

#include <stddef.h>

#include "plot.h"

// Thread-local like GImGui, see tuft_imconfig.h
thread_local ImPlotContext* tuft_implot_current_context = nullptr;

static_assert(ImAxis_COUNT == ImPlot_Axis_COUNT, "ImPlot axes changed");
static_assert(ImPlotCol_COUNT == ImPlot_Col_COUNT, "ImPlot colours changed");
static_assert(ImPlotMarker_COUNT == ImPlot_Marker_COUNT, "ImPlot markers changed");

#define SAME_FIELD(a, b, field) static_assert(offsetof(a, field) == offsetof(b, field), #b " changed")

static_assert(sizeof(ImPlot_Spec) == sizeof(ImPlotSpec), "ImPlotSpec changed");
SAME_FIELD(ImPlot_Spec, ImPlotSpec, LineColors);
SAME_FIELD(ImPlot_Spec, ImPlotSpec, FillAlpha);
SAME_FIELD(ImPlot_Spec, ImPlotSpec, MarkerSizes);
SAME_FIELD(ImPlot_Spec, ImPlotSpec, MarkerFillColors);
SAME_FIELD(ImPlot_Spec, ImPlotSpec, Stride);
SAME_FIELD(ImPlot_Spec, ImPlotSpec, Flags);

static_assert(sizeof(ImPlot_Style) == sizeof(ImPlotStyle), "ImPlotStyle changed");
SAME_FIELD(ImPlot_Style, ImPlotStyle, DigitalSpacing);
SAME_FIELD(ImPlot_Style, ImPlotStyle, Colors);
SAME_FIELD(ImPlot_Style, ImPlotStyle, Colormap);
SAME_FIELD(ImPlot_Style, ImPlotStyle, Use24HourClock);

// Marks our hook among an ImGui context's
static const ImGuiID hook_owner = 0x746F6C50;

static void onShutdown(ImGuiContext*, ImGuiContextHook* hook) {
    ImPlot::DestroyContext(static_cast<ImPlotContext*>(hook->UserData));
}

// Points GImPlot at the current ImGui context's ImPlot context, made on first use and freed with it.
static void use() {
    ImGuiContext* g = ImGui::GetCurrentContext();
    if (g == nullptr) {
        GImPlot = nullptr;
        return;
    }
    for (const ImGuiContextHook& hook : g->Hooks) {
        if (hook.Owner == hook_owner && hook.Type == ImGuiContextHookType_Shutdown) {
            GImPlot = static_cast<ImPlotContext*>(hook.UserData);
            return;
        }
    }
    ImPlotContext* ctx = ImPlot::CreateContext();
    ImGuiContextHook hook;
    hook.Type = ImGuiContextHookType_Shutdown;
    hook.Owner = hook_owner;
    hook.Callback = onShutdown;
    hook.UserData = ctx;
    ImGui::AddContextHook(g, &hook);
    GImPlot = ctx;
}

static ImPlotSpec spec(const ImPlot_Spec* s) {
    return s ? *reinterpret_cast<const ImPlotSpec*>(s) : ImPlotSpec();
}

static ImPlot_Point toC(const ImPlotPoint& p) { return {p.x, p.y}; }
static ImPlot_Vec2 toC(const ImVec2& v) { return {v.x, v.y}; }
static ImPlot_Vec4 toC(const ImVec4& v) { return {v.x, v.y, v.z, v.w}; }
static ImPlot_Rect toC(const ImPlotRect& r) { return {{r.X.Min, r.X.Max}, {r.Y.Min, r.Y.Max}}; }

// For ys2 without xs, which ImPlot has no overload for
struct Spaced {
    const double* ys;
    double xscale;
    double xstart;
};

static ImPlotPoint spacedPoint(int i, void* data) {
    const Spaced* s = static_cast<const Spaced*>(data);
    return ImPlotPoint(s->xstart + i * s->xscale, s->ys[i]);
}

extern "C" {

// Plots

bool ImPlot_BeginPlot(const char* title_id, ImVec2 size, int flags) {
    use();
    return ImPlot::BeginPlot(title_id, size, flags);
}
void ImPlot_EndPlot(void) {
    use();
    ImPlot::EndPlot();
}
bool ImPlot_BeginSubplots(const char* title_id, int rows, int cols, ImVec2 size, int flags) {
    use();
    return ImPlot::BeginSubplots(title_id, rows, cols, size, flags);
}
void ImPlot_EndSubplots(void) {
    use();
    ImPlot::EndSubplots();
}
bool ImPlot_BeginAlignedPlots(const char* group_id, bool vertical) {
    use();
    return ImPlot::BeginAlignedPlots(group_id, vertical);
}
void ImPlot_EndAlignedPlots(void) {
    use();
    ImPlot::EndAlignedPlots();
}

// Setup

void ImPlot_SetupAxis(int axis, const char* label, int flags) {
    use();
    ImPlot::SetupAxis(axis, label, flags);
}
void ImPlot_SetupAxisLimits(int axis, double v_min, double v_max, int cond) {
    use();
    ImPlot::SetupAxisLimits(axis, v_min, v_max, cond);
}
void ImPlot_SetupAxisFormat(int axis, const char* fmt) {
    use();
    ImPlot::SetupAxisFormat(axis, fmt);
}
void ImPlot_SetupAxisTicks(int axis, const double* values, int n_ticks, const char* const* labels, bool keep_default) {
    use();
    ImPlot::SetupAxisTicks(axis, values, n_ticks, labels, keep_default);
}
void ImPlot_SetupAxisTicksRange(int axis, double v_min, double v_max, int n_ticks, const char* const* labels, bool keep_default) {
    use();
    ImPlot::SetupAxisTicks(axis, v_min, v_max, n_ticks, labels, keep_default);
}
void ImPlot_SetupAxisScale(int axis, int scale) {
    use();
    ImPlot::SetupAxisScale(axis, scale);
}
void ImPlot_SetupAxisLimitsConstraints(int axis, double v_min, double v_max) {
    use();
    ImPlot::SetupAxisLimitsConstraints(axis, v_min, v_max);
}
void ImPlot_SetupAxisZoomConstraints(int axis, double z_min, double z_max) {
    use();
    ImPlot::SetupAxisZoomConstraints(axis, z_min, z_max);
}
void ImPlot_SetupAxes(const char* x_label, const char* y_label, int x_flags, int y_flags) {
    use();
    ImPlot::SetupAxes(x_label, y_label, x_flags, y_flags);
}
void ImPlot_SetupAxesLimits(double x_min, double x_max, double y_min, double y_max, int cond) {
    use();
    ImPlot::SetupAxesLimits(x_min, x_max, y_min, y_max, cond);
}
void ImPlot_SetupLegend(int location, int flags) {
    use();
    ImPlot::SetupLegend(location, flags);
}
void ImPlot_SetupMouseText(int location, int flags) {
    use();
    ImPlot::SetupMouseText(location, flags);
}
void ImPlot_SetupFinish(void) {
    use();
    ImPlot::SetupFinish();
}

// SetNext

void ImPlot_SetNextAxisLimits(int axis, double v_min, double v_max, int cond) {
    use();
    ImPlot::SetNextAxisLimits(axis, v_min, v_max, cond);
}
void ImPlot_SetNextAxisToFit(int axis) {
    use();
    ImPlot::SetNextAxisToFit(axis);
}
void ImPlot_SetNextAxesLimits(double x_min, double x_max, double y_min, double y_max, int cond) {
    use();
    ImPlot::SetNextAxesLimits(x_min, x_max, y_min, y_max, cond);
}
void ImPlot_SetNextAxesToFit(void) {
    use();
    ImPlot::SetNextAxesToFit();
}

// Items

void ImPlot_PlotLine(const char* label_id, const double* xs, const double* ys, int count, double xscale, double xstart, const ImPlot_Spec* s) {
    use();
    if (xs) ImPlot::PlotLine(label_id, xs, ys, count, spec(s));
    else ImPlot::PlotLine(label_id, ys, count, xscale, xstart, spec(s));
}
void ImPlot_PlotScatter(const char* label_id, const double* xs, const double* ys, int count, double xscale, double xstart, const ImPlot_Spec* s) {
    use();
    if (xs) ImPlot::PlotScatter(label_id, xs, ys, count, spec(s));
    else ImPlot::PlotScatter(label_id, ys, count, xscale, xstart, spec(s));
}
void ImPlot_PlotBubbles(const char* label_id, const double* xs, const double* ys, const double* sizes, int count, double xscale, double xstart, const ImPlot_Spec* s) {
    use();
    if (xs) ImPlot::PlotBubbles(label_id, xs, ys, sizes, count, spec(s));
    else ImPlot::PlotBubbles(label_id, ys, sizes, count, xscale, xstart, spec(s));
}
void ImPlot_PlotPolygon(const char* label_id, const double* xs, const double* ys, int count, const ImPlot_Spec* s) {
    use();
    ImPlot::PlotPolygon(label_id, xs, ys, count, spec(s));
}
void ImPlot_PlotStairs(const char* label_id, const double* xs, const double* ys, int count, double xscale, double xstart, const ImPlot_Spec* s) {
    use();
    if (xs) ImPlot::PlotStairs(label_id, xs, ys, count, spec(s));
    else ImPlot::PlotStairs(label_id, ys, count, xscale, xstart, spec(s));
}
void ImPlot_PlotShaded(const char* label_id, const double* xs, const double* ys, const double* ys2, int count, double yref, double xscale, double xstart, const ImPlot_Spec* s) {
    use();
    if (ys2 == nullptr) {
        if (xs) ImPlot::PlotShaded(label_id, xs, ys, count, yref, spec(s));
        else ImPlot::PlotShaded(label_id, ys, count, yref, xscale, xstart, spec(s));
    } else if (xs) {
        ImPlot::PlotShaded(label_id, xs, ys, ys2, count, spec(s));
    } else {
        Spaced a = {ys, xscale, xstart};
        Spaced b = {ys2, xscale, xstart};
        ImPlot::PlotShadedG(label_id, spacedPoint, &a, spacedPoint, &b, count, spec(s));
    }
}
void ImPlot_PlotBars(const char* label_id, const double* xs, const double* ys, int count, double bar_size, double shift, const ImPlot_Spec* s) {
    use();
    if (xs) ImPlot::PlotBars(label_id, xs, ys, count, bar_size, spec(s));
    else ImPlot::PlotBars(label_id, ys, count, bar_size, shift, spec(s));
}
void ImPlot_PlotBarGroups(const char* const* label_ids, const double* values, int item_count, int group_count, double group_size, double shift, const ImPlot_Spec* s) {
    use();
    ImPlot::PlotBarGroups(label_ids, values, item_count, group_count, group_size, shift, spec(s));
}
void ImPlot_PlotErrorBars(const char* label_id, const double* xs, const double* ys, const double* neg, const double* pos, int count, const ImPlot_Spec* s) {
    use();
    if (pos) ImPlot::PlotErrorBars(label_id, xs, ys, neg, pos, count, spec(s));
    else ImPlot::PlotErrorBars(label_id, xs, ys, neg, count, spec(s));
}
void ImPlot_PlotStems(const char* label_id, const double* xs, const double* ys, int count, double ref, double xscale, double xstart, const ImPlot_Spec* s) {
    use();
    if (xs) ImPlot::PlotStems(label_id, xs, ys, count, ref, spec(s));
    else ImPlot::PlotStems(label_id, ys, count, ref, xscale, xstart, spec(s));
}
void ImPlot_PlotInfLines(const char* label_id, const double* values, int count, const ImPlot_Spec* s) {
    use();
    ImPlot::PlotInfLines(label_id, values, count, spec(s));
}
void ImPlot_PlotPieChart(const char* const* label_ids, const double* values, int count, double x, double y, double radius, const char* label_fmt, double angle0, const ImPlot_Spec* s) {
    use();
    ImPlot::PlotPieChart(label_ids, values, count, x, y, radius, label_fmt, angle0, spec(s));
}
void ImPlot_PlotHeatmap(const char* label_id, const double* values, int rows, int cols, double scale_min, double scale_max, const char* label_fmt, ImPlot_Point bounds_min, ImPlot_Point bounds_max, const ImPlot_Spec* s) {
    use();
    ImPlot::PlotHeatmap(label_id, values, rows, cols, scale_min, scale_max, label_fmt, ImPlotPoint(bounds_min.x, bounds_min.y), ImPlotPoint(bounds_max.x, bounds_max.y), spec(s));
}
double ImPlot_PlotHistogram(const char* label_id, const double* values, int count, int bins, double bar_scale, ImPlot_Range range, const ImPlot_Spec* s) {
    use();
    return ImPlot::PlotHistogram(label_id, values, count, bins, bar_scale, ImPlotRange(range.Min, range.Max), spec(s));
}
double ImPlot_PlotHistogram2D(const char* label_id, const double* xs, const double* ys, int count, int x_bins, int y_bins, ImPlot_Rect range, const ImPlot_Spec* s) {
    use();
    return ImPlot::PlotHistogram2D(label_id, xs, ys, count, x_bins, y_bins, ImPlotRect(range.X.Min, range.X.Max, range.Y.Min, range.Y.Max), spec(s));
}
void ImPlot_PlotDigital(const char* label_id, const double* xs, const double* ys, int count, const ImPlot_Spec* s) {
    use();
    ImPlot::PlotDigital(label_id, xs, ys, count, spec(s));
}
void ImPlot_PlotText(const char* text, double x, double y, ImVec2 pix_offset, const ImPlot_Spec* s) {
    use();
    ImPlot::PlotText(text, x, y, pix_offset, spec(s));
}
void ImPlot_PlotDummy(const char* label_id, const ImPlot_Spec* s) {
    use();
    ImPlot::PlotDummy(label_id, spec(s));
}

// Tools

bool ImPlot_DragPoint(int id, double* x, double* y, ImVec4 col, float size, int flags, bool* out_clicked, bool* out_hovered, bool* out_held) {
    use();
    return ImPlot::DragPoint(id, x, y, col, size, flags, out_clicked, out_hovered, out_held);
}
bool ImPlot_DragLineX(int id, double* x, ImVec4 col, float thickness, int flags, bool* out_clicked, bool* out_hovered, bool* out_held) {
    use();
    return ImPlot::DragLineX(id, x, col, thickness, flags, out_clicked, out_hovered, out_held);
}
bool ImPlot_DragLineY(int id, double* y, ImVec4 col, float thickness, int flags, bool* out_clicked, bool* out_hovered, bool* out_held) {
    use();
    return ImPlot::DragLineY(id, y, col, thickness, flags, out_clicked, out_hovered, out_held);
}
bool ImPlot_DragRect(int id, double* x1, double* y1, double* x2, double* y2, ImVec4 col, int flags, bool* out_clicked, bool* out_hovered, bool* out_held) {
    use();
    return ImPlot::DragRect(id, x1, y1, x2, y2, col, flags, out_clicked, out_hovered, out_held);
}
void ImPlot_Annotation(double x, double y, ImVec4 col, ImVec2 pix_offset, bool clamp, const char* text) {
    use();
    ImPlot::Annotation(x, y, col, pix_offset, clamp, "%s", text);
}
void ImPlot_TagX(double x, ImVec4 col, const char* text) {
    use();
    if (text) ImPlot::TagX(x, col, "%s", text);
    else ImPlot::TagX(x, col, false);
}
void ImPlot_TagY(double y, ImVec4 col, const char* text) {
    use();
    if (text) ImPlot::TagY(y, col, "%s", text);
    else ImPlot::TagY(y, col, false);
}

// Utils

void ImPlot_SetAxis(int axis) {
    use();
    ImPlot::SetAxis(axis);
}
void ImPlot_SetAxes(int x_axis, int y_axis) {
    use();
    ImPlot::SetAxes(x_axis, y_axis);
}
ImPlot_Point ImPlot_PixelsToPlot(ImVec2 pix, int x_axis, int y_axis) {
    use();
    return toC(ImPlot::PixelsToPlot(pix, x_axis, y_axis));
}
ImPlot_Vec2 ImPlot_PlotToPixels(ImPlot_Point plt, int x_axis, int y_axis) {
    use();
    return toC(ImPlot::PlotToPixels(plt.x, plt.y, x_axis, y_axis));
}
ImPlot_Vec2 ImPlot_GetPlotPos(void) {
    use();
    return toC(ImPlot::GetPlotPos());
}
ImPlot_Vec2 ImPlot_GetPlotSize(void) {
    use();
    return toC(ImPlot::GetPlotSize());
}
ImPlot_Point ImPlot_GetPlotMousePos(int x_axis, int y_axis) {
    use();
    return toC(ImPlot::GetPlotMousePos(x_axis, y_axis));
}
ImPlot_Rect ImPlot_GetPlotLimits(int x_axis, int y_axis) {
    use();
    return toC(ImPlot::GetPlotLimits(x_axis, y_axis));
}
bool ImPlot_IsPlotHovered(void) {
    use();
    return ImPlot::IsPlotHovered();
}
bool ImPlot_IsAxisHovered(int axis) {
    use();
    return ImPlot::IsAxisHovered(axis);
}
bool ImPlot_IsSubplotsHovered(void) {
    use();
    return ImPlot::IsSubplotsHovered();
}
bool ImPlot_IsPlotSelected(void) {
    use();
    return ImPlot::IsPlotSelected();
}
ImPlot_Rect ImPlot_GetPlotSelection(int x_axis, int y_axis) {
    use();
    return toC(ImPlot::GetPlotSelection(x_axis, y_axis));
}
void ImPlot_CancelPlotSelection(void) {
    use();
    ImPlot::CancelPlotSelection();
}
void ImPlot_HideNextItem(bool hidden, int cond) {
    use();
    ImPlot::HideNextItem(hidden, cond);
}
bool ImPlot_BeginLegendPopup(const char* label_id, int mouse_button) {
    use();
    return ImPlot::BeginLegendPopup(label_id, mouse_button);
}
void ImPlot_EndLegendPopup(void) {
    use();
    ImPlot::EndLegendPopup();
}
bool ImPlot_IsLegendEntryHovered(const char* label_id) {
    use();
    return ImPlot::IsLegendEntryHovered(label_id);
}
ImPlot_Vec4 ImPlot_GetLastItemColor(void) {
    use();
    return toC(ImPlot::GetLastItemColor());
}
ImDrawList* ImPlot_GetPlotDrawList(void) {
    use();
    return ImPlot::GetPlotDrawList();
}
void ImPlot_PushPlotClipRect(float expand) {
    use();
    ImPlot::PushPlotClipRect(expand);
}
void ImPlot_PopPlotClipRect(void) {
    use();
    ImPlot::PopPlotClipRect();
}
void ImPlot_ItemIcon(ImVec4 col) {
    use();
    ImPlot::ItemIcon(col);
}
void ImPlot_ColormapIcon(int cmap) {
    use();
    ImPlot::ColormapIcon(cmap);
}

// Style

ImPlot_Style* ImPlot_GetStyle(void) {
    use();
    return reinterpret_cast<ImPlot_Style*>(&ImPlot::GetStyle());
}
void ImPlot_StyleColorsAuto(void) {
    use();
    ImPlot::StyleColorsAuto();
}
void ImPlot_StyleColorsClassic(void) {
    use();
    ImPlot::StyleColorsClassic();
}
void ImPlot_StyleColorsDark(void) {
    use();
    ImPlot::StyleColorsDark();
}
void ImPlot_StyleColorsLight(void) {
    use();
    ImPlot::StyleColorsLight();
}
void ImPlot_PushStyleColor(int idx, ImVec4 col) {
    use();
    ImPlot::PushStyleColor(idx, col);
}
void ImPlot_PopStyleColor(int count) {
    use();
    ImPlot::PopStyleColor(count);
}

// Colormaps

int ImPlot_AddColormap(const char* name, const ImVec4* cols, int size, bool qual) {
    use();
    return ImPlot::AddColormap(name, cols, size, qual);
}
int ImPlot_GetColormapCount(void) {
    use();
    return ImPlot::GetColormapCount();
}
const char* ImPlot_GetColormapName(int cmap) {
    use();
    return ImPlot::GetColormapName(cmap);
}
int ImPlot_GetColormapIndex(const char* name) {
    use();
    return ImPlot::GetColormapIndex(name);
}
void ImPlot_PushColormap(int cmap) {
    use();
    ImPlot::PushColormap(cmap);
}
void ImPlot_PopColormap(int count) {
    use();
    ImPlot::PopColormap(count);
}
ImPlot_Vec4 ImPlot_NextColormapColor(void) {
    use();
    return toC(ImPlot::NextColormapColor());
}
int ImPlot_GetColormapSize(int cmap) {
    use();
    return ImPlot::GetColormapSize(cmap);
}
ImPlot_Vec4 ImPlot_GetColormapColor(int idx, int cmap) {
    use();
    return toC(ImPlot::GetColormapColor(idx, cmap));
}
ImPlot_Vec4 ImPlot_SampleColormap(float t, int cmap) {
    use();
    return toC(ImPlot::SampleColormap(t, cmap));
}
void ImPlot_ColormapScale(const char* label, double scale_min, double scale_max, ImVec2 size, const char* format, int flags, int cmap) {
    use();
    ImPlot::ColormapScale(label, scale_min, scale_max, size, format, flags, cmap);
}
bool ImPlot_ColormapSlider(const char* label, float* t, ImVec4* out, const char* format, int cmap) {
    use();
    return ImPlot::ColormapSlider(label, t, out, format, cmap);
}
bool ImPlot_ColormapButton(const char* label, ImVec2 size, int cmap) {
    use();
    return ImPlot::ColormapButton(label, size, cmap);
}
void ImPlot_BustColorCache(const char* plot_title_id) {
    use();
    ImPlot::BustColorCache(plot_title_id);
}

// Demo and tools

void ImPlot_ShowDemoWindow(bool* p_open) {
    use();
    ImPlot::ShowDemoWindow(p_open);
}
void ImPlot_ShowStyleEditor(void) {
    use();
    ImPlot::ShowStyleEditor();
}
void ImPlot_ShowUserGuide(void) {
    use();
    ImPlot::ShowUserGuide();
}
void ImPlot_ShowMetricsWindow(bool* p_open) {
    use();
    ImPlot::ShowMetricsWindow(p_open);
}
bool ImPlot_ShowStyleSelector(const char* label) {
    use();
    return ImPlot::ShowStyleSelector(label);
}
bool ImPlot_ShowColormapSelector(const char* label) {
    use();
    return ImPlot::ShowColormapSelector(label);
}
bool ImPlot_ShowInputMapSelector(const char* label) {
    use();
    return ImPlot::ShowInputMapSelector(label);
}

}  // extern "C"
