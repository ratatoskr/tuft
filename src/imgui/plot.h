// ImPlot as C, in dear_bindings' types. Data is always double.
// Each ImGui context gets its own ImPlot context on first use, freed with it.
#pragma once

#ifndef __cplusplus
#include <stdbool.h>
#else
extern "C" {
#endif

enum { ImPlot_Axis_COUNT = 6, ImPlot_Col_COUNT = 16, ImPlot_Marker_COUNT = 12 };

typedef struct ImPlot_Point {
    double x;
    double y;
} ImPlot_Point;

// Returned instead of ImVec2 and ImVec4. Those are C++ classes in plot.cpp, and MSVC returns
// classes with constructors through a hidden pointer, which C callers don't pass
typedef struct ImPlot_Vec2 {
    float x;
    float y;
} ImPlot_Vec2;

typedef struct ImPlot_Vec4 {
    float x;
    float y;
    float z;
    float w;
} ImPlot_Vec4;

typedef struct ImPlot_Range {
    double Min;
    double Max;
} ImPlot_Range;

typedef struct ImPlot_Rect {
    ImPlot_Range X;
    ImPlot_Range Y;
} ImPlot_Rect;

// Same layout as ImPlotSpec. A null one means the defaults
typedef struct ImPlot_Spec {
    ImVec4 LineColor;
    ImU32* LineColors;
    float LineWeight;
    ImVec4 FillColor;
    ImU32* FillColors;
    float FillAlpha;
    int Marker;
    float MarkerSize;
    float* MarkerSizes;
    ImVec4 MarkerLineColor;
    ImU32* MarkerLineColors;
    ImVec4 MarkerFillColor;
    ImU32* MarkerFillColors;
    float Size;
    int Offset;
    int Stride;
    int Flags;
} ImPlot_Spec;

// Same layout as ImPlotStyle
typedef struct ImPlot_Style {
    ImVec2 PlotDefaultSize;
    ImVec2 PlotMinSize;
    float PlotBorderSize;
    float MinorAlpha;
    ImVec2 MajorTickLen;
    ImVec2 MinorTickLen;
    ImVec2 MajorTickSize;
    ImVec2 MinorTickSize;
    ImVec2 MajorGridSize;
    ImVec2 MinorGridSize;
    ImVec2 PlotPadding;
    ImVec2 LabelPadding;
    ImVec2 LegendPadding;
    ImVec2 LegendInnerPadding;
    ImVec2 LegendSpacing;
    ImVec2 MousePosPadding;
    ImVec2 AnnotationPadding;
    ImVec2 FitPadding;
    float DigitalPadding;
    float DigitalSpacing;
    ImVec4 Colors[ImPlot_Col_COUNT];
    int Colormap;
    bool UseLocalTime;
    bool UseISO8601;
    bool Use24HourClock;
} ImPlot_Style;

// Plots

bool ImPlot_BeginPlot(const char* title_id, ImVec2 size, int flags);
void ImPlot_EndPlot(void);
bool ImPlot_BeginSubplots(const char* title_id, int rows, int cols, ImVec2 size, int flags);
void ImPlot_EndSubplots(void);
bool ImPlot_BeginAlignedPlots(const char* group_id, bool vertical);
void ImPlot_EndAlignedPlots(void);

// Setup, right after BeginPlot

void ImPlot_SetupAxis(int axis, const char* label, int flags);
void ImPlot_SetupAxisLimits(int axis, double v_min, double v_max, int cond);
void ImPlot_SetupAxisFormat(int axis, const char* fmt);
void ImPlot_SetupAxisTicks(int axis, const double* values, int n_ticks, const char* const* labels, bool keep_default);
void ImPlot_SetupAxisTicksRange(int axis, double v_min, double v_max, int n_ticks, const char* const* labels, bool keep_default);
void ImPlot_SetupAxisScale(int axis, int scale);
void ImPlot_SetupAxisLimitsConstraints(int axis, double v_min, double v_max);
void ImPlot_SetupAxisZoomConstraints(int axis, double z_min, double z_max);
void ImPlot_SetupAxes(const char* x_label, const char* y_label, int x_flags, int y_flags);
void ImPlot_SetupAxesLimits(double x_min, double x_max, double y_min, double y_max, int cond);
void ImPlot_SetupLegend(int location, int flags);
void ImPlot_SetupMouseText(int location, int flags);
void ImPlot_SetupFinish(void);

// Before BeginPlot

void ImPlot_SetNextAxisLimits(int axis, double v_min, double v_max, int cond);
void ImPlot_SetNextAxisToFit(int axis);
void ImPlot_SetNextAxesLimits(double x_min, double x_max, double y_min, double y_max, int cond);
void ImPlot_SetNextAxesToFit(void);

// Items. A null xs spaces the points xscale apart from xstart

void ImPlot_PlotLine(const char* label_id, const double* xs, const double* ys, int count, double xscale, double xstart, const ImPlot_Spec* spec);
void ImPlot_PlotScatter(const char* label_id, const double* xs, const double* ys, int count, double xscale, double xstart, const ImPlot_Spec* spec);
void ImPlot_PlotBubbles(const char* label_id, const double* xs, const double* ys, const double* sizes, int count, double xscale, double xstart, const ImPlot_Spec* spec);
void ImPlot_PlotPolygon(const char* label_id, const double* xs, const double* ys, int count, const ImPlot_Spec* spec);
void ImPlot_PlotStairs(const char* label_id, const double* xs, const double* ys, int count, double xscale, double xstart, const ImPlot_Spec* spec);
// Between ys and yref, or ys and ys2 when that's not null
void ImPlot_PlotShaded(const char* label_id, const double* xs, const double* ys, const double* ys2, int count, double yref, double xscale, double xstart, const ImPlot_Spec* spec);
// Without xs, bars are at shift, shift + 1, ...
void ImPlot_PlotBars(const char* label_id, const double* xs, const double* ys, int count, double bar_size, double shift, const ImPlot_Spec* spec);
// values is item_count rows of group_count
void ImPlot_PlotBarGroups(const char* const* label_ids, const double* values, int item_count, int group_count, double group_size, double shift, const ImPlot_Spec* spec);
// A null pos makes neg both ways
void ImPlot_PlotErrorBars(const char* label_id, const double* xs, const double* ys, const double* neg, const double* pos, int count, const ImPlot_Spec* spec);
void ImPlot_PlotStems(const char* label_id, const double* xs, const double* ys, int count, double ref, double xscale, double xstart, const ImPlot_Spec* spec);
void ImPlot_PlotInfLines(const char* label_id, const double* values, int count, const ImPlot_Spec* spec);
void ImPlot_PlotPieChart(const char* const* label_ids, const double* values, int count, double x, double y, double radius, const char* label_fmt, double angle0, const ImPlot_Spec* spec);
void ImPlot_PlotHeatmap(const char* label_id, const double* values, int rows, int cols, double scale_min, double scale_max, const char* label_fmt, ImPlot_Point bounds_min, ImPlot_Point bounds_max, const ImPlot_Spec* spec);
double ImPlot_PlotHistogram(const char* label_id, const double* values, int count, int bins, double bar_scale, ImPlot_Range range, const ImPlot_Spec* spec);
double ImPlot_PlotHistogram2D(const char* label_id, const double* xs, const double* ys, int count, int x_bins, int y_bins, ImPlot_Rect range, const ImPlot_Spec* spec);
void ImPlot_PlotDigital(const char* label_id, const double* xs, const double* ys, int count, const ImPlot_Spec* spec);
void ImPlot_PlotText(const char* text, double x, double y, ImVec2 pix_offset, const ImPlot_Spec* spec);
void ImPlot_PlotDummy(const char* label_id, const ImPlot_Spec* spec);

// Tools. The out_ ones can be null

bool ImPlot_DragPoint(int id, double* x, double* y, ImVec4 col, float size, int flags, bool* out_clicked, bool* out_hovered, bool* out_held);
bool ImPlot_DragLineX(int id, double* x, ImVec4 col, float thickness, int flags, bool* out_clicked, bool* out_hovered, bool* out_held);
bool ImPlot_DragLineY(int id, double* y, ImVec4 col, float thickness, int flags, bool* out_clicked, bool* out_hovered, bool* out_held);
bool ImPlot_DragRect(int id, double* x1, double* y1, double* x2, double* y2, ImVec4 col, int flags, bool* out_clicked, bool* out_hovered, bool* out_held);
// Text as is, no formatting
void ImPlot_Annotation(double x, double y, ImVec4 col, ImVec2 pix_offset, bool clamp, const char* text);
// A null text shows the value
void ImPlot_TagX(double x, ImVec4 col, const char* text);
void ImPlot_TagY(double y, ImVec4 col, const char* text);

// Utils. Axis -1 means the current one

void ImPlot_SetAxis(int axis);
void ImPlot_SetAxes(int x_axis, int y_axis);
ImPlot_Point ImPlot_PixelsToPlot(ImVec2 pix, int x_axis, int y_axis);
ImPlot_Vec2 ImPlot_PlotToPixels(ImPlot_Point plt, int x_axis, int y_axis);
ImPlot_Vec2 ImPlot_GetPlotPos(void);
ImPlot_Vec2 ImPlot_GetPlotSize(void);
ImPlot_Point ImPlot_GetPlotMousePos(int x_axis, int y_axis);
ImPlot_Rect ImPlot_GetPlotLimits(int x_axis, int y_axis);
bool ImPlot_IsPlotHovered(void);
bool ImPlot_IsAxisHovered(int axis);
bool ImPlot_IsSubplotsHovered(void);
bool ImPlot_IsPlotSelected(void);
ImPlot_Rect ImPlot_GetPlotSelection(int x_axis, int y_axis);
void ImPlot_CancelPlotSelection(void);
void ImPlot_HideNextItem(bool hidden, int cond);
bool ImPlot_BeginLegendPopup(const char* label_id, int mouse_button);
void ImPlot_EndLegendPopup(void);
bool ImPlot_IsLegendEntryHovered(const char* label_id);
ImPlot_Vec4 ImPlot_GetLastItemColor(void);
ImDrawList* ImPlot_GetPlotDrawList(void);
void ImPlot_PushPlotClipRect(float expand);
void ImPlot_PopPlotClipRect(void);
void ImPlot_ItemIcon(ImVec4 col);
void ImPlot_ColormapIcon(int cmap);

// Style

ImPlot_Style* ImPlot_GetStyle(void);
void ImPlot_StyleColorsAuto(void);
void ImPlot_StyleColorsClassic(void);
void ImPlot_StyleColorsDark(void);
void ImPlot_StyleColorsLight(void);
void ImPlot_PushStyleColor(int idx, ImVec4 col);
void ImPlot_PopStyleColor(int count);

// Colormaps. cmap -1 means the current one

int ImPlot_AddColormap(const char* name, const ImVec4* cols, int size, bool qual);
int ImPlot_GetColormapCount(void);
const char* ImPlot_GetColormapName(int cmap);
// -1 if there's none by that name
int ImPlot_GetColormapIndex(const char* name);
void ImPlot_PushColormap(int cmap);
void ImPlot_PopColormap(int count);
ImPlot_Vec4 ImPlot_NextColormapColor(void);
int ImPlot_GetColormapSize(int cmap);
ImPlot_Vec4 ImPlot_GetColormapColor(int idx, int cmap);
ImPlot_Vec4 ImPlot_SampleColormap(float t, int cmap);
void ImPlot_ColormapScale(const char* label, double scale_min, double scale_max, ImVec2 size, const char* format, int flags, int cmap);
bool ImPlot_ColormapSlider(const char* label, float* t, ImVec4* out, const char* format, int cmap);
bool ImPlot_ColormapButton(const char* label, ImVec2 size, int cmap);
// Null for every plot
void ImPlot_BustColorCache(const char* plot_title_id);

// Demo and tools

void ImPlot_ShowDemoWindow(bool* p_open);
void ImPlot_ShowStyleEditor(void);
void ImPlot_ShowUserGuide(void);
void ImPlot_ShowMetricsWindow(bool* p_open);
bool ImPlot_ShowStyleSelector(const char* label);
bool ImPlot_ShowColormapSelector(const char* label);
bool ImPlot_ShowInputMapSelector(const char* label);

#ifdef __cplusplus
}
#endif
