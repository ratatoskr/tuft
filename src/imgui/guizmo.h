// ImGuizmo's widgets as C, in dear_bindings' types.
// State is global, not per ImGui context, so use them from one thread at a time.
#pragma once

#ifndef __cplusplus
#include <stdbool.h>
#include <stddef.h>
#else
#include <cstddef>
extern "C" {
#endif

typedef struct ImGuizmo_Rect {
    ImVec2 Min;
    ImVec2 Max;
} ImGuizmo_Rect;

// ImGuizmo

enum {
    ImGuizmo_Operation_TranslateX = 1u << 0,
    ImGuizmo_Operation_TranslateY = 1u << 1,
    ImGuizmo_Operation_TranslateZ = 1u << 2,
    ImGuizmo_Operation_RotateX = 1u << 3,
    ImGuizmo_Operation_RotateY = 1u << 4,
    ImGuizmo_Operation_RotateZ = 1u << 5,
    ImGuizmo_Operation_RotateScreen = 1u << 6,
    ImGuizmo_Operation_ScaleX = 1u << 7,
    ImGuizmo_Operation_ScaleY = 1u << 8,
    ImGuizmo_Operation_ScaleZ = 1u << 9,
    ImGuizmo_Operation_Bounds = 1u << 10,
    ImGuizmo_Operation_ScaleXU = 1u << 11,
    ImGuizmo_Operation_ScaleYU = 1u << 12,
    ImGuizmo_Operation_ScaleZU = 1u << 13,
};

enum { ImGuizmo_Mode_Local, ImGuizmo_Mode_World };

enum { ImGuizmo_Color_COUNT = 15 };

typedef struct ImGuizmo_Style {
    float TranslationLineThickness;
    float TranslationLineArrowSize;
    float RotationLineThickness;
    float RotationOuterLineThickness;
    float ScaleLineThickness;
    float ScaleLineCircleSize;
    float HatchedAxisLineThickness;
    float CenterCircleSize;
    ImVec4 Colors[ImGuizmo_Color_COUNT];
} ImGuizmo_Style;

void ImGuizmo_SetDrawlist(ImDrawList* draw_list);
void ImGuizmo_BeginFrame(void);
void ImGuizmo_SetImGuiContext(ImGuiContext* ctx);
bool ImGuizmo_IsOver(void);
bool ImGuizmo_IsOverOperation(unsigned int operation);
bool ImGuizmo_IsOverPoint(float* position, float pixel_radius);
bool ImGuizmo_IsUsing(void);
bool ImGuizmo_IsUsingViewManipulate(void);
bool ImGuizmo_IsViewManipulateHovered(void);
bool ImGuizmo_IsUsingAny(void);
void ImGuizmo_Enable(bool enable);
void ImGuizmo_DecomposeMatrixToComponents(const float* matrix, float* translation, float* rotation, float* scale);
void ImGuizmo_RecomposeMatrixFromComponents(const float* translation, const float* rotation, const float* scale, float* matrix);
void ImGuizmo_SetRect(float x, float y, float width, float height);
void ImGuizmo_SetOrthographic(bool orthographic);
void ImGuizmo_DrawAxes(const float* view, const float* projection, const float* matrices, int count);
void ImGuizmo_DrawCubes(const float* view, const float* projection, const float* matrices, int count);
void ImGuizmo_DrawGrid(const float* view, const float* projection, const float* matrix, float size);
void ImGuizmo_DrawGridCustomColor(const float* view, const float* projection, const float* matrix, float size, float major_step, unsigned int subdivision, ImU32 major_col, ImU32 minor_col, ImU32 center_col);
bool ImGuizmo_Manipulate(const float* view, const float* projection, unsigned int operation, int mode, float* matrix, float* delta_matrix, const float* snap, const float* local_bounds, const float* bounds_snap);
void ImGuizmo_ViewManipulate(float* view, float length, ImVec2 position, ImVec2 size, ImU32 background);
void ImGuizmo_ViewManipulateWithGizmo(float* view, const float* projection, unsigned int operation, int mode, float* matrix, float length, ImVec2 position, ImVec2 size, ImU32 background);
void ImGuizmo_PushIDStr(const char* str_id);
void ImGuizmo_PushIDPtr(const void* ptr_id);
void ImGuizmo_PushIDInt(int int_id);
void ImGuizmo_PopID(void);
ImGuiID ImGuizmo_GetIDStr(const char* str_id);
ImGuiID ImGuizmo_GetIDPtr(const void* ptr_id);
void ImGuizmo_SetGizmoSizeClipSpace(float value);
int ImGuizmo_GetActiveMoveType(void);
int ImGuizmo_GetHoveredMoveType(void);
void ImGuizmo_AllowAxisFlip(bool value);
void ImGuizmo_SetAxisLimit(float value);
void ImGuizmo_SetAxisMask(bool x, bool y, bool z);
void ImGuizmo_SetPlaneLimit(float value);
void ImGuizmo_ComputeMouseRay(const float* view, const float* projection, ImVec2 mouse, ImVec2 rect_position, ImVec2 rect_size, float* ray_origin, float* ray_direction);
ImGuizmo_Style* ImGuizmo_GetStyle(void);

// ImSequencer

enum {
    ImSequencer_Options_EditStartEnd = 1 << 1,
    ImSequencer_Options_ChangeFrame = 1 << 3,
    ImSequencer_Options_Add = 1 << 4,
    ImSequencer_Options_Del = 1 << 5,
    ImSequencer_Options_CopyPaste = 1 << 6,
};

// GetFrameMin, GetFrameMax, GetItemCount and Get are required. Strings live until the call ends.
typedef struct ImSequencer_Interface {
    void* User;
    int (*GetFrameMin)(void* user);
    int (*GetFrameMax)(void* user);
    int (*GetItemCount)(void* user);
    void (*BeginEdit)(void* user, int index);
    void (*EndEdit)(void* user);
    int (*GetItemTypeCount)(void* user);
    const char* (*GetItemTypeName)(void* user, int type_index);
    const char* (*GetItemLabel)(void* user, int index);
    void (*Get)(void* user, int index, int** start, int** end, int* type, unsigned int* color);
    void (*Add)(void* user, int type);
    void (*Del)(void* user, int index);
    void (*Duplicate)(void* user, int index);
    void (*Copy)(void* user);
    void (*Paste)(void* user);
    size_t (*GetCustomHeight)(void* user, int index);
    void (*DoubleClick)(void* user, int index);
    void (*CustomDraw)(void* user, int index, ImDrawList* draw_list, ImGuizmo_Rect rect, ImGuizmo_Rect legend_rect, ImGuizmo_Rect clipping_rect, ImGuizmo_Rect legend_clipping_rect);
    void (*CustomDrawCompact)(void* user, int index, ImDrawList* draw_list, ImGuizmo_Rect rect, ImGuizmo_Rect clipping_rect);
} ImSequencer_Interface;

// `focused` gets whether its window has focus.
bool ImSequencer_Sequencer(const ImSequencer_Interface* sequence, bool* focused, int* current_frame, bool* expanded, int* selected_entry, int* first_frame, int options);

// ImGraphEditor

enum { ImGraphEditor_Fit_None, ImGraphEditor_Fit_AllNodes, ImGraphEditor_Fit_SelectedNodes };

typedef struct ImGraphEditor_Options {
    ImGuizmo_Rect Minimap;
    ImU32 BackgroundColor;
    ImU32 GridColor;
    ImU32 GridColor2;
    ImU32 SelectedNodeBorderColor;
    ImU32 NodeBorderColor;
    ImU32 QuadSelection;
    ImU32 QuadSelectionBorder;
    ImU32 DefaultSlotColor;
    ImU32 FrameFocus;
    float LineThickness;
    float GridSize;
    float Rounding;
    float ZoomRatio;
    float ZoomLerpFactor;
    float BorderSelectionThickness;
    float BorderThickness;
    float NodeSlotRadius;
    float NodeSlotHoverFactor;
    float MinZoom;
    float MaxZoom;
    float Snap;
    bool DisplayLinksAsCurves;
    bool AllowQuadSelection;
    bool RenderGrid;
    bool DrawIONameOnHover;
} ImGraphEditor_Options;

typedef struct ImGraphEditor_ViewState {
    ImVec2 Position;
    float Factor;
    float FactorTarget;
} ImGraphEditor_ViewState;

typedef struct ImGraphEditor_Template {
    ImU32 HeaderColor;
    ImU32 BackgroundColor;
    ImU32 BackgroundColorOver;
    ImU8 InputCount;
    const char** InputNames;
    ImU32* InputColors;
    ImU8 OutputCount;
    const char** OutputNames;
    ImU32* OutputColors;
} ImGraphEditor_Template;

typedef struct ImGraphEditor_Node {
    const char* Name;
    size_t TemplateIndex;
    ImGuizmo_Rect Rect;
    bool Selected;
} ImGraphEditor_Node;

typedef struct ImGraphEditor_Link {
    size_t InputNodeIndex;
    size_t InputSlotIndex;
    size_t OutputNodeIndex;
    size_t OutputSlotIndex;
} ImGraphEditor_Link;

// All required but CustomDraw and RightClick. RightClick gets (size_t)-1 for nothing there.
typedef struct ImGraphEditor_Delegate {
    void* User;
    bool (*AllowedLink)(void* user, size_t from, size_t to);
    void (*SelectNode)(void* user, size_t node, bool selected);
    void (*MoveSelectedNodes)(void* user, ImVec2 delta);
    void (*AddLink)(void* user, size_t input_node, size_t input_slot, size_t output_node, size_t output_slot);
    void (*DelLink)(void* user, size_t link);
    void (*CustomDraw)(void* user, ImDrawList* draw_list, ImGuizmo_Rect rect, size_t node);
    void (*RightClick)(void* user, size_t node, size_t input_slot, size_t output_slot);
    size_t (*GetTemplateCount)(void* user);
    void (*GetTemplate)(void* user, size_t index, ImGraphEditor_Template* out);
    size_t (*GetNodeCount)(void* user);
    void (*GetNode)(void* user, size_t index, ImGraphEditor_Node* out);
    size_t (*GetLinkCount)(void* user);
    void (*GetLink)(void* user, size_t index, ImGraphEditor_Link* out);
} ImGraphEditor_Delegate;

void ImGraphEditor_DefaultOptions(ImGraphEditor_Options* out);
// `fit` is one of ImGraphEditor_Fit_* or null, reset to None once done.
void ImGraphEditor_Show(const ImGraphEditor_Delegate* delegate, const ImGraphEditor_Options* options, ImGraphEditor_ViewState* view_state, bool enabled, int* fit);
void ImGraphEditor_Clear(void);
bool ImGraphEditor_EditOptions(ImGraphEditor_Options* options);

// ImVectorEditor

enum { ImVectorEditor_Tool_Select, ImVectorEditor_Tool_Pen };
enum { ImVectorEditor_HitPart_None, ImVectorEditor_HitPart_Anchor, ImVectorEditor_HitPart_HandleIn, ImVectorEditor_HitPart_HandleOut };
enum { ImVectorEditor_HandleMode_Corner, ImVectorEditor_HandleMode_Mirrored, ImVectorEditor_HandleMode_Aligned, ImVectorEditor_HandleMode_Free };
enum { ImVectorEditor_Shape_Circle, ImVectorEditor_Shape_Square, ImVectorEditor_Shape_Diamond };

typedef struct ImVectorEditor_Anchor {
    ImVec2 Position;
    ImVec2 HandleIn;
    ImVec2 HandleOut;
    bool HasHandleIn;
    bool HasHandleOut;
    int HandleMode;
} ImVectorEditor_Anchor;

typedef struct ImVectorEditor_Transform {
    ImVec2 Pan;
    float Zoom;
    ImVec2 ObjectPivot;
    ImVec2 ObjectTranslation;
    float ObjectRotationRadians;
    ImVec2 ObjectScale;
} ImVectorEditor_Transform;

typedef struct ImVectorEditor_Style {
    ImU32 BackgroundColor;
    ImU32 GridColor;
    ImU32 PathColor;
    ImU32 PreviewColor;
    ImU32 AnchorColor;
    ImU32 AnchorSelectedColor;
    ImU32 HandleColor;
    ImU32 HandleLineColor;
    ImU32 CloseTargetColor;
    float PathThickness;
    float HandleLineThickness;
    float AnchorRadius;
    float HandleRadius;
    int AnchorShape;
    int HandleShape;
    float HitRadius;
    float GridStep;
} ImVectorEditor_Style;

typedef struct ImVectorEditor_Delegate {
    void* User;
    void (*BeginEdit)(void* user, int kind, int anchor);
    void (*EndEdit)(void* user);
} ImVectorEditor_Delegate;

typedef struct ImVectorEditor_Config {
    ImVec2 CanvasSize;
    int Tool;
    ImVectorEditor_Transform Transform;
    ImVectorEditor_Style Style;
    const ImVectorEditor_Delegate* Delegate;
    bool ShowGrid;
    bool AllowKeyboardShortcuts;
    bool ReadOnly;
} ImVectorEditor_Config;

typedef struct ImVectorEditor_Result {
    bool Changed;
    bool Committed;
    bool Canceled;
    bool PathClosed;
    bool Hovered;
    bool Active;
    bool WantsMouseCapture;
    bool WantsKeyboardCapture;
    ImVec2 ViewPanDelta;
    ImVec2 ViewZoomCenterCanvas;
    float ViewZoomFactor;
} ImVectorEditor_Result;

typedef struct ImVectorEditor_Path ImVectorEditor_Path;
typedef struct ImVectorEditor_Editor ImVectorEditor_Editor;

void ImVectorEditor_DefaultConfig(ImVectorEditor_Config* out);

// Null if out of memory
ImVectorEditor_Path* ImVectorEditor_Path_Create(void);
void ImVectorEditor_Path_Destroy(ImVectorEditor_Path* path);
size_t ImVectorEditor_Path_Len(const ImVectorEditor_Path* path);
// Good until the path next changes
ImVectorEditor_Anchor* ImVectorEditor_Path_Anchors(ImVectorEditor_Path* path);
// False if out of memory, path left as it was
bool ImVectorEditor_Path_Set(ImVectorEditor_Path* path, const ImVectorEditor_Anchor* anchors, size_t len);
bool ImVectorEditor_Path_IsClosed(const ImVectorEditor_Path* path);
void ImVectorEditor_Path_SetClosed(ImVectorEditor_Path* path, bool closed);
void ImVectorEditor_Path_Clear(ImVectorEditor_Path* path);
void ImVectorEditor_Path_Reverse(ImVectorEditor_Path* path);

ImVectorEditor_Editor* ImVectorEditor_Editor_Create(void);
void ImVectorEditor_Editor_Destroy(ImVectorEditor_Editor* editor);
void ImVectorEditor_Editor_Draw(ImVectorEditor_Editor* editor, const char* id, ImVectorEditor_Path* path, const ImVectorEditor_Config* config, ImVectorEditor_Result* out);
void ImVectorEditor_Editor_ClearSelection(ImVectorEditor_Editor* editor);
int ImVectorEditor_Editor_GetSelectedAnchor(const ImVectorEditor_Editor* editor);
int ImVectorEditor_Editor_GetSelectedAnchorCount(const ImVectorEditor_Editor* editor);
int ImVectorEditor_Editor_GetSelectedPart(const ImVectorEditor_Editor* editor);

bool ImVectorEditor_MakeCorner(ImVectorEditor_Anchor* anchor);
bool ImVectorEditor_MakeAligned(ImVectorEditor_Anchor* anchor);
bool ImVectorEditor_MakeMirrored(ImVectorEditor_Anchor* anchor);
bool ImVectorEditor_AddHandles(ImVectorEditor_Anchor* anchor, float length);
bool ImVectorEditor_DeleteHandles(ImVectorEditor_Anchor* anchor);
void ImVectorEditor_LocalToCanvas(const ImVectorEditor_Transform* transform, ImVec2 local, ImVec2* out);
void ImVectorEditor_CanvasToLocal(const ImVectorEditor_Transform* transform, ImVec2 canvas, ImVec2* out);

#ifdef __cplusplus
}
#endif
