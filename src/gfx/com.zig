//! COM calls by vtable index.

pub const HRESULT = i32;

pub const Guid = extern struct { data1: u32, data2: u16, data3: u16, data4: [8]u8 };

pub fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

pub fn vtableEntry(object: *const anyopaque, index: usize) usize {
    return @as(*const [*]const usize, @ptrCast(@alignCast(object))).*[index];
}

pub fn method(object: *const anyopaque, comptime index: usize, comptime F: type) *const F {
    return @ptrFromInt(vtableEntry(object, index));
}

/// Returns `object` as `iid` with a ref taken, or null.
pub fn query(object: *anyopaque, iid: *const Guid) ?*anyopaque {
    var out: ?*anyopaque = null;
    const hr = method(object, 0, fn (*anyopaque, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT)(object, iid, &out);
    return if (succeeded(hr)) out else null;
}

pub fn addRef(object: anytype) void {
    _ = method(object, 1, fn (*anyopaque) callconv(.winapi) u32)(@ptrCast(object));
}

pub fn release(object: anytype) void {
    _ = method(object, 2, fn (*anyopaque) callconv(.winapi) u32)(@ptrCast(object));
}
