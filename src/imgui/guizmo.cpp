// C wrappers for ImGuizmo's C++. See guizmo.h.

#include "imgui.h"
#include "imgui_internal.h"

#include "GraphEditor.h"
#include "ImGuizmo.h"
#include "ImSequencer.h"
#include "ImVectorEditor.h"

#include <new>

#include "guizmo.h"

static ImGuizmo_Rect toC(const ImRect& r) { return {r.Min, r.Max}; }
static ImRect fromC(const ImGuizmo_Rect& r) { return ImRect(r.Min, r.Max); }

// ImGuizmo

static_assert(ImGuizmo::COLOR::COUNT == ImGuizmo_Color_COUNT, "ImGuizmo colours changed");
static_assert(sizeof(ImGuizmo_Style) == sizeof(ImGuizmo::Style), "ImGuizmo::Style changed");
static_assert(offsetof(ImGuizmo_Style, Colors) == offsetof(ImGuizmo::Style, Colors), "ImGuizmo::Style changed");
static_assert(ImGuizmo::SCALE_ZU == ImGuizmo_Operation_ScaleZU, "ImGuizmo operations changed");

static ImGuizmo::OPERATION op(unsigned int operation) { return static_cast<ImGuizmo::OPERATION>(operation); }
static ImGuizmo::MODE mode(int m) { return static_cast<ImGuizmo::MODE>(m); }

// ImGuizmo crashes on a null draw list before BeginFrame or SetDrawlist, so use the window's
static bool has_draw_list = false;

static void ensureDrawList() {
    if (has_draw_list) return;
    ImGuizmo::SetDrawlist();
    has_draw_list = true;
}

extern "C" {

void ImGuizmo_SetDrawlist(ImDrawList* draw_list) {
    ImGuizmo::SetDrawlist(draw_list);
    has_draw_list = true;
}
void ImGuizmo_BeginFrame(void) {
    ImGuizmo::BeginFrame();
    has_draw_list = true;
}
void ImGuizmo_SetImGuiContext(ImGuiContext* ctx) { ImGuizmo::SetImGuiContext(ctx); }
bool ImGuizmo_IsOver(void) {
    ensureDrawList();
    return ImGuizmo::IsOver();
}
bool ImGuizmo_IsOverOperation(unsigned int operation) {
    ensureDrawList();
    return ImGuizmo::IsOver(op(operation));
}
bool ImGuizmo_IsOverPoint(float* position, float pixel_radius) {
    ensureDrawList();
    return ImGuizmo::IsOver(position, pixel_radius);
}
bool ImGuizmo_IsUsing(void) { return ImGuizmo::IsUsing(); }
bool ImGuizmo_IsUsingViewManipulate(void) { return ImGuizmo::IsUsingViewManipulate(); }
bool ImGuizmo_IsViewManipulateHovered(void) { return ImGuizmo::IsViewManipulateHovered(); }
bool ImGuizmo_IsUsingAny(void) { return ImGuizmo::IsUsingAny(); }
void ImGuizmo_Enable(bool enable) { ImGuizmo::Enable(enable); }

void ImGuizmo_DecomposeMatrixToComponents(const float* matrix, float* translation, float* rotation, float* scale) {
    ImGuizmo::DecomposeMatrixToComponents(matrix, translation, rotation, scale);
}

void ImGuizmo_RecomposeMatrixFromComponents(const float* translation, const float* rotation, const float* scale, float* matrix) {
    ImGuizmo::RecomposeMatrixFromComponents(translation, rotation, scale, matrix);
}

void ImGuizmo_SetRect(float x, float y, float width, float height) { ImGuizmo::SetRect(x, y, width, height); }
void ImGuizmo_SetOrthographic(bool orthographic) { ImGuizmo::SetOrthographic(orthographic); }

void ImGuizmo_DrawAxes(const float* view, const float* projection, const float* matrices, int count) {
    ensureDrawList();
    ImGuizmo::DrawAxes(view, projection, matrices, count);
}

void ImGuizmo_DrawCubes(const float* view, const float* projection, const float* matrices, int count) {
    ensureDrawList();
    ImGuizmo::DrawCubes(view, projection, matrices, count);
}

void ImGuizmo_DrawGrid(const float* view, const float* projection, const float* matrix, float size) {
    ensureDrawList();
    ImGuizmo::DrawGrid(view, projection, matrix, size);
}

void ImGuizmo_DrawGridCustomColor(const float* view, const float* projection, const float* matrix, float size, float major_step, unsigned int subdivision, ImU32 major_col, ImU32 minor_col, ImU32 center_col) {
    ensureDrawList();
    ImGuizmo::DrawGridCustomColor(view, projection, matrix, size, major_step, subdivision, major_col, minor_col, center_col);
}

bool ImGuizmo_Manipulate(const float* view, const float* projection, unsigned int operation, int m, float* matrix, float* delta_matrix, const float* snap, const float* local_bounds, const float* bounds_snap) {
    ensureDrawList();
    return ImGuizmo::Manipulate(view, projection, op(operation), mode(m), matrix, delta_matrix, snap, local_bounds, bounds_snap);
}

void ImGuizmo_ViewManipulate(float* view, float length, ImVec2 position, ImVec2 size, ImU32 background) {
    ensureDrawList();
    ImGuizmo::ViewManipulate(view, length, position, size, background);
}

void ImGuizmo_ViewManipulateWithGizmo(float* view, const float* projection, unsigned int operation, int m, float* matrix, float length, ImVec2 position, ImVec2 size, ImU32 background) {
    ensureDrawList();
    ImGuizmo::ViewManipulate(view, projection, op(operation), mode(m), matrix, length, position, size, background);
}

void ImGuizmo_PushIDStr(const char* str_id) { ImGuizmo::PushID(str_id); }
void ImGuizmo_PushIDPtr(const void* ptr_id) { ImGuizmo::PushID(ptr_id); }
void ImGuizmo_PushIDInt(int int_id) { ImGuizmo::PushID(int_id); }
void ImGuizmo_PopID(void) { ImGuizmo::PopID(); }
ImGuiID ImGuizmo_GetIDStr(const char* str_id) { return ImGuizmo::GetID(str_id); }
ImGuiID ImGuizmo_GetIDPtr(const void* ptr_id) { return ImGuizmo::GetID(ptr_id); }
void ImGuizmo_SetGizmoSizeClipSpace(float value) { ImGuizmo::SetGizmoSizeClipSpace(value); }
int ImGuizmo_GetActiveMoveType(void) { return ImGuizmo::GetActiveMoveType(); }
int ImGuizmo_GetHoveredMoveType(void) { return ImGuizmo::GetHoveredMoveType(); }
void ImGuizmo_AllowAxisFlip(bool value) { ImGuizmo::AllowAxisFlip(value); }
void ImGuizmo_SetAxisLimit(float value) { ImGuizmo::SetAxisLimit(value); }
void ImGuizmo_SetAxisMask(bool x, bool y, bool z) { ImGuizmo::SetAxisMask(x, y, z); }
void ImGuizmo_SetPlaneLimit(float value) { ImGuizmo::SetPlaneLimit(value); }

void ImGuizmo_ComputeMouseRay(const float* view, const float* projection, ImVec2 mouse, ImVec2 rect_position, ImVec2 rect_size, float* ray_origin, float* ray_direction) {
    ImGuizmo::ComputeMouseRay(view, projection, mouse, rect_position, rect_size, ray_origin, ray_direction);
}

ImGuizmo_Style* ImGuizmo_GetStyle(void) { return reinterpret_cast<ImGuizmo_Style*>(&ImGuizmo::GetStyle()); }

} // extern "C"

// ImSequencer

namespace {

struct Sequence final : ImSequencer::SequenceInterface {
    const ImSequencer_Interface* c;

    explicit Sequence(const ImSequencer_Interface* in) : c(in) {}

    int GetFrameMin() const override { return c->GetFrameMin(c->User); }
    int GetFrameMax() const override { return c->GetFrameMax(c->User); }
    int GetItemCount() const override { return c->GetItemCount(c->User); }
    void BeginEdit(int index) override {
        if (c->BeginEdit) c->BeginEdit(c->User, index);
    }
    void EndEdit() override {
        if (c->EndEdit) c->EndEdit(c->User);
    }
    int GetItemTypeCount() const override { return c->GetItemTypeCount ? c->GetItemTypeCount(c->User) : 0; }
    const char* GetItemTypeName(int index) const override { return c->GetItemTypeName ? c->GetItemTypeName(c->User, index) : ""; }
    const char* GetItemLabel(int index) const override { return c->GetItemLabel ? c->GetItemLabel(c->User, index) : ""; }
    void Get(int index, int** start, int** end, int* type, unsigned int* color) override { c->Get(c->User, index, start, end, type, color); }
    void Add(int type) override {
        if (c->Add) c->Add(c->User, type);
    }
    void Del(int index) override {
        if (c->Del) c->Del(c->User, index);
    }
    void Duplicate(int index) override {
        if (c->Duplicate) c->Duplicate(c->User, index);
    }
    void Copy() override {
        if (c->Copy) c->Copy(c->User);
    }
    void Paste() override {
        if (c->Paste) c->Paste(c->User);
    }
    size_t GetCustomHeight(int index) override { return c->GetCustomHeight ? c->GetCustomHeight(c->User, index) : 0; }
    void DoubleClick(int index) override {
        if (c->DoubleClick) c->DoubleClick(c->User, index);
    }
    void CustomDraw(int index, ImDrawList* draw_list, const ImRect& rc, const ImRect& legend, const ImRect& clip, const ImRect& legend_clip) override {
        if (c->CustomDraw) c->CustomDraw(c->User, index, draw_list, toC(rc), toC(legend), toC(clip), toC(legend_clip));
    }
    void CustomDrawCompact(int index, ImDrawList* draw_list, const ImRect& rc, const ImRect& clip) override {
        if (c->CustomDrawCompact) c->CustomDrawCompact(c->User, index, draw_list, toC(rc), toC(clip));
    }
};

} // namespace

extern "C" bool ImSequencer_Sequencer(const ImSequencer_Interface* sequence, bool* focused, int* current_frame, bool* expanded, int* selected_entry, int* first_frame, int options) {
    Sequence s(sequence);
    if (focused) s.focused = *focused;
    const bool picked = ImSequencer::Sequencer(&s, current_frame, expanded, selected_entry, first_frame, options);
    if (focused) *focused = s.focused;
    return picked;
}

// ImGraphEditor

static_assert(sizeof(ImGraphEditor_ViewState) == sizeof(GraphEditor::ViewState), "GraphEditor::ViewState changed");
static_assert(sizeof(ImGraphEditor_Link) == sizeof(GraphEditor::Link), "GraphEditor::Link changed");

static GraphEditor::Options fromC(const ImGraphEditor_Options& o) {
    GraphEditor::Options r;
    r.mMinimap = fromC(o.Minimap);
    r.mBackgroundColor = o.BackgroundColor;
    r.mGridColor = o.GridColor;
    r.mGridColor2 = o.GridColor2;
    r.mSelectedNodeBorderColor = o.SelectedNodeBorderColor;
    r.mNodeBorderColor = o.NodeBorderColor;
    r.mQuadSelection = o.QuadSelection;
    r.mQuadSelectionBorder = o.QuadSelectionBorder;
    r.mDefaultSlotColor = o.DefaultSlotColor;
    r.mFrameFocus = o.FrameFocus;
    r.mLineThickness = o.LineThickness;
    r.mGridSize = o.GridSize;
    r.mRounding = o.Rounding;
    r.mZoomRatio = o.ZoomRatio;
    r.mZoomLerpFactor = o.ZoomLerpFactor;
    r.mBorderSelectionThickness = o.BorderSelectionThickness;
    r.mBorderThickness = o.BorderThickness;
    r.mNodeSlotRadius = o.NodeSlotRadius;
    r.mNodeSlotHoverFactor = o.NodeSlotHoverFactor;
    r.mMinZoom = o.MinZoom;
    r.mMaxZoom = o.MaxZoom;
    r.mSnap = o.Snap;
    r.mDisplayLinksAsCurves = o.DisplayLinksAsCurves;
    r.mAllowQuadSelection = o.AllowQuadSelection;
    r.mRenderGrid = o.RenderGrid;
    r.mDrawIONameOnHover = o.DrawIONameOnHover;
    return r;
}

static ImGraphEditor_Options toC(const GraphEditor::Options& o) {
    ImGraphEditor_Options r;
    r.Minimap = toC(o.mMinimap);
    r.BackgroundColor = o.mBackgroundColor;
    r.GridColor = o.mGridColor;
    r.GridColor2 = o.mGridColor2;
    r.SelectedNodeBorderColor = o.mSelectedNodeBorderColor;
    r.NodeBorderColor = o.mNodeBorderColor;
    r.QuadSelection = o.mQuadSelection;
    r.QuadSelectionBorder = o.mQuadSelectionBorder;
    r.DefaultSlotColor = o.mDefaultSlotColor;
    r.FrameFocus = o.mFrameFocus;
    r.LineThickness = o.mLineThickness;
    r.GridSize = o.mGridSize;
    r.Rounding = o.mRounding;
    r.ZoomRatio = o.mZoomRatio;
    r.ZoomLerpFactor = o.mZoomLerpFactor;
    r.BorderSelectionThickness = o.mBorderSelectionThickness;
    r.BorderThickness = o.mBorderThickness;
    r.NodeSlotRadius = o.mNodeSlotRadius;
    r.NodeSlotHoverFactor = o.mNodeSlotHoverFactor;
    r.MinZoom = o.mMinZoom;
    r.MaxZoom = o.mMaxZoom;
    r.Snap = o.mSnap;
    r.DisplayLinksAsCurves = o.mDisplayLinksAsCurves;
    r.AllowQuadSelection = o.mAllowQuadSelection;
    r.RenderGrid = o.mRenderGrid;
    r.DrawIONameOnHover = o.mDrawIONameOnHover;
    return r;
}

namespace {

struct Graph final : GraphEditor::Delegate {
    const ImGraphEditor_Delegate* c;

    explicit Graph(const ImGraphEditor_Delegate* in) : c(in) {}

    bool AllowedLink(GraphEditor::NodeIndex from, GraphEditor::NodeIndex to) override { return c->AllowedLink(c->User, from, to); }
    void SelectNode(GraphEditor::NodeIndex node, bool selected) override { c->SelectNode(c->User, node, selected); }
    void MoveSelectedNodes(const ImVec2 delta) override { c->MoveSelectedNodes(c->User, delta); }
    void AddLink(GraphEditor::NodeIndex in_node, GraphEditor::SlotIndex in_slot, GraphEditor::NodeIndex out_node, GraphEditor::SlotIndex out_slot) override {
        c->AddLink(c->User, in_node, in_slot, out_node, out_slot);
    }
    void DelLink(GraphEditor::LinkIndex link) override { c->DelLink(c->User, link); }
    void CustomDraw(ImDrawList* draw_list, ImRect rect, GraphEditor::NodeIndex node) override {
        if (c->CustomDraw) c->CustomDraw(c->User, draw_list, toC(rect), node);
    }
    void RightClick(GraphEditor::NodeIndex node, GraphEditor::SlotIndex in_slot, GraphEditor::SlotIndex out_slot) override {
        if (c->RightClick) c->RightClick(c->User, node, in_slot, out_slot);
    }
    const size_t GetTemplateCount() override { return c->GetTemplateCount(c->User); }
    const GraphEditor::Template GetTemplate(GraphEditor::TemplateIndex index) override {
        ImGraphEditor_Template t{};
        c->GetTemplate(c->User, index, &t);
        return {t.HeaderColor, t.BackgroundColor, t.BackgroundColorOver, t.InputCount, t.InputNames, t.InputColors, t.OutputCount, t.OutputNames, t.OutputColors};
    }
    const size_t GetNodeCount() override { return c->GetNodeCount(c->User); }
    const GraphEditor::Node GetNode(GraphEditor::NodeIndex index) override {
        ImGraphEditor_Node n{};
        c->GetNode(c->User, index, &n);
        return {n.Name, n.TemplateIndex, fromC(n.Rect), n.Selected};
    }
    const size_t GetLinkCount() override { return c->GetLinkCount(c->User); }
    const GraphEditor::Link GetLink(GraphEditor::LinkIndex index) override {
        ImGraphEditor_Link l{};
        c->GetLink(c->User, index, &l);
        return {l.InputNodeIndex, l.InputSlotIndex, l.OutputNodeIndex, l.OutputSlotIndex};
    }
};

} // namespace

extern "C" {

void ImGraphEditor_DefaultOptions(ImGraphEditor_Options* out) { *out = toC(GraphEditor::Options()); }

void ImGraphEditor_Show(const ImGraphEditor_Delegate* delegate, const ImGraphEditor_Options* options, ImGraphEditor_ViewState* view_state, bool enabled, int* fit) {
    Graph g(delegate);
    const GraphEditor::Options o = fromC(*options);
    GraphEditor::ViewState v;
    v.mPosition = view_state->Position;
    v.mFactor = view_state->Factor;
    v.mFactorTarget = view_state->FactorTarget;
    GraphEditor::FitOnScreen f = fit ? static_cast<GraphEditor::FitOnScreen>(*fit) : GraphEditor::Fit_None;
    GraphEditor::Show(g, o, v, enabled, fit ? &f : nullptr);
    view_state->Position = v.mPosition;
    view_state->Factor = v.mFactor;
    view_state->FactorTarget = v.mFactorTarget;
    if (fit) *fit = f;
}

void ImGraphEditor_Clear(void) { GraphEditor::GraphEditorClear(); }

bool ImGraphEditor_EditOptions(ImGraphEditor_Options* options) {
    GraphEditor::Options o = fromC(*options);
    const bool changed = GraphEditor::EditOptions(o);
    *options = toC(o);
    return changed;
}

} // extern "C"

// ImVectorEditor

static_assert(sizeof(ImVectorEditor_Anchor) == sizeof(ImVectorEditor::Anchor), "ImVectorEditor::Anchor changed");
static_assert(offsetof(ImVectorEditor_Anchor, HasHandleIn) == offsetof(ImVectorEditor::Anchor, hasHandleIn), "ImVectorEditor::Anchor changed");
static_assert(offsetof(ImVectorEditor_Anchor, HandleMode) == offsetof(ImVectorEditor::Anchor, handleMode), "ImVectorEditor::Anchor changed");
static_assert(sizeof(ImVectorEditor::HandleMode) == sizeof(int), "ImVectorEditor::HandleMode changed");

struct ImVectorEditor_Path {
    ImVectorEditor::Path path;
};

struct ImVectorEditor_Editor {
    ImVectorEditor::Editor editor;
};

static ImVectorEditor::Anchor* cpp(ImVectorEditor_Anchor* a) { return reinterpret_cast<ImVectorEditor::Anchor*>(a); }

static ImVectorEditor::Transform fromC(const ImVectorEditor_Transform& t) {
    ImVectorEditor::Transform r;
    r.pan = t.Pan;
    r.zoom = t.Zoom;
    r.objectPivot = t.ObjectPivot;
    r.objectTranslation = t.ObjectTranslation;
    r.objectRotationRadians = t.ObjectRotationRadians;
    r.objectScale = t.ObjectScale;
    return r;
}

static ImVectorEditor_Transform toC(const ImVectorEditor::Transform& t) {
    return {t.pan, t.zoom, t.objectPivot, t.objectTranslation, t.objectRotationRadians, t.objectScale};
}

static ImVectorEditor::Style fromC(const ImVectorEditor_Style& s) {
    ImVectorEditor::Style r;
    r.backgroundColor = s.BackgroundColor;
    r.gridColor = s.GridColor;
    r.pathColor = s.PathColor;
    r.previewColor = s.PreviewColor;
    r.anchorColor = s.AnchorColor;
    r.anchorSelectedColor = s.AnchorSelectedColor;
    r.handleColor = s.HandleColor;
    r.handleLineColor = s.HandleLineColor;
    r.closeTargetColor = s.CloseTargetColor;
    r.pathThickness = s.PathThickness;
    r.handleLineThickness = s.HandleLineThickness;
    r.anchorRadius = s.AnchorRadius;
    r.handleRadius = s.HandleRadius;
    r.anchorShape = static_cast<ImVectorEditor::ControlPointShape>(s.AnchorShape);
    r.handleShape = static_cast<ImVectorEditor::ControlPointShape>(s.HandleShape);
    r.hitRadius = s.HitRadius;
    r.gridStep = s.GridStep;
    return r;
}

static ImVectorEditor_Style toC(const ImVectorEditor::Style& s) {
    return {s.backgroundColor, s.gridColor, s.pathColor, s.previewColor, s.anchorColor, s.anchorSelectedColor, s.handleColor, s.handleLineColor, s.closeTargetColor, s.pathThickness, s.handleLineThickness, s.anchorRadius, s.handleRadius, static_cast<int>(s.anchorShape), static_cast<int>(s.handleShape), s.hitRadius, s.gridStep};
}

namespace {

struct VectorDelegate final : ImVectorEditor::Delegate {
    const ImVectorEditor_Delegate* c;

    explicit VectorDelegate(const ImVectorEditor_Delegate* in) : c(in) {}

    void BeginEdit(ImVectorEditor::EditKind kind, int anchor) override {
        if (c->BeginEdit) c->BeginEdit(c->User, static_cast<int>(kind), anchor);
    }
    void EndEdit() override {
        if (c->EndEdit) c->EndEdit(c->User);
    }
};

} // namespace

extern "C" {

void ImVectorEditor_DefaultConfig(ImVectorEditor_Config* out) {
    const ImVectorEditor::Config c;
    out->CanvasSize = c.canvasSize;
    out->Tool = static_cast<int>(c.tool);
    out->Transform = toC(c.transform);
    out->Style = toC(c.style);
    out->Delegate = nullptr;
    out->ShowGrid = c.showGrid;
    out->AllowKeyboardShortcuts = c.allowKeyboardShortcuts;
    out->ReadOnly = c.readOnly;
}

ImVectorEditor_Path* ImVectorEditor_Path_Create(void) { return new (std::nothrow) ImVectorEditor_Path(); }
void ImVectorEditor_Path_Destroy(ImVectorEditor_Path* path) { delete path; }
size_t ImVectorEditor_Path_Len(const ImVectorEditor_Path* path) { return path->path.anchors.size(); }

ImVectorEditor_Anchor* ImVectorEditor_Path_Anchors(ImVectorEditor_Path* path) {
    return reinterpret_cast<ImVectorEditor_Anchor*>(path->path.anchors.data());
}

bool ImVectorEditor_Path_Set(ImVectorEditor_Path* path, const ImVectorEditor_Anchor* anchors, size_t len) {
    try {
        const auto* first = reinterpret_cast<const ImVectorEditor::Anchor*>(anchors);
        std::vector<ImVectorEditor::Anchor> next(first, first + len);
        path->path.anchors.swap(next);
        return true;
    } catch (...) {
        return false;
    }
}

bool ImVectorEditor_Path_IsClosed(const ImVectorEditor_Path* path) { return path->path.closed; }
void ImVectorEditor_Path_SetClosed(ImVectorEditor_Path* path, bool closed) { path->path.closed = closed; }
void ImVectorEditor_Path_Clear(ImVectorEditor_Path* path) { path->path.clear(); }
void ImVectorEditor_Path_Reverse(ImVectorEditor_Path* path) { ImVectorEditor::ReversePath(path->path); }

ImVectorEditor_Editor* ImVectorEditor_Editor_Create(void) { return new (std::nothrow) ImVectorEditor_Editor(); }
void ImVectorEditor_Editor_Destroy(ImVectorEditor_Editor* editor) { delete editor; }

void ImVectorEditor_Editor_Draw(ImVectorEditor_Editor* editor, const char* id, ImVectorEditor_Path* path, const ImVectorEditor_Config* config, ImVectorEditor_Result* out) {
    ImVectorEditor::Config c;
    c.canvasSize = config->CanvasSize;
    c.tool = static_cast<ImVectorEditor::Tool>(config->Tool);
    c.transform = fromC(config->Transform);
    c.style = fromC(config->Style);
    VectorDelegate delegate(config->Delegate);
    c.delegate = config->Delegate ? &delegate : nullptr;
    c.showGrid = config->ShowGrid;
    c.allowKeyboardShortcuts = config->AllowKeyboardShortcuts;
    c.readOnly = config->ReadOnly;
    // Out of memory loses this frame's edit, not the game
    ImVectorEditor::Result r;
    try {
        r = editor->editor.Draw(id, path->path, c);
    } catch (...) {
    }
    *out = {r.changed, r.committed, r.canceled, r.pathClosed, r.hovered, r.active, r.wantsMouseCapture, r.wantsKeyboardCapture, r.viewPanDelta, r.viewZoomCenterCanvas, r.viewZoomFactor};
}

void ImVectorEditor_Editor_ClearSelection(ImVectorEditor_Editor* editor) { editor->editor.ClearSelection(); }
int ImVectorEditor_Editor_GetSelectedAnchor(const ImVectorEditor_Editor* editor) { return editor->editor.GetSelectedAnchor(); }
int ImVectorEditor_Editor_GetSelectedAnchorCount(const ImVectorEditor_Editor* editor) { return editor->editor.GetSelectedAnchorCount(); }
int ImVectorEditor_Editor_GetSelectedPart(const ImVectorEditor_Editor* editor) { return static_cast<int>(editor->editor.GetSelectedPart()); }

bool ImVectorEditor_MakeCorner(ImVectorEditor_Anchor* anchor) { return ImVectorEditor::MakeCorner(*cpp(anchor)); }
bool ImVectorEditor_MakeAligned(ImVectorEditor_Anchor* anchor) { return ImVectorEditor::MakeAligned(*cpp(anchor)); }
bool ImVectorEditor_MakeMirrored(ImVectorEditor_Anchor* anchor) { return ImVectorEditor::MakeMirrored(*cpp(anchor)); }
bool ImVectorEditor_AddHandles(ImVectorEditor_Anchor* anchor, float length) { return ImVectorEditor::AddHandles(*cpp(anchor), length); }
bool ImVectorEditor_DeleteHandles(ImVectorEditor_Anchor* anchor) { return ImVectorEditor::DeleteHandles(*cpp(anchor)); }

void ImVectorEditor_LocalToCanvas(const ImVectorEditor_Transform* transform, ImVec2 local, ImVec2* out) { *out = fromC(*transform).LocalToCanvas(local); }
void ImVectorEditor_CanvasToLocal(const ImVectorEditor_Transform* transform, ImVec2 canvas, ImVec2* out) { *out = fromC(*transform).CanvasToLocal(canvas); }

} // extern "C"
