//! The runtime's own pointers. Both runtimes hand out the same kinds, so they share types.

pub const Domain = opaque {};
pub const Assembly = opaque {};
pub const Image = opaque {};
pub const Class = opaque {};
pub const Field = opaque {};
pub const Method = opaque {};
pub const Type = opaque {};
pub const Object = opaque {};
pub const String = opaque {};
pub const Thread = opaque {};

/// What a type is, from ECMA-335. Both runtimes use these numbers.
pub const ElementType = enum(u8) {
    end = 0x00,
    void = 0x01,
    boolean = 0x02,
    char = 0x03,
    i1 = 0x04,
    u1 = 0x05,
    i2 = 0x06,
    u2 = 0x07,
    i4 = 0x08,
    u4 = 0x09,
    i8 = 0x0a,
    u8 = 0x0b,
    r4 = 0x0c,
    r8 = 0x0d,
    string = 0x0e,
    ptr = 0x0f,
    byref = 0x10,
    valuetype = 0x11,
    class = 0x12,
    @"var" = 0x13,
    array = 0x14,
    genericinst = 0x15,
    typedbyref = 0x16,
    i = 0x18,
    u = 0x19,
    fnptr = 0x1b,
    object = 0x1c,
    szarray = 0x1d,
    mvar = 0x1e,
    _,
};

/// ECMA-335 attribute bits we look at.
pub const field_static = 0x10;
pub const field_literal = 0x40;
pub const method_static = 0x10;
pub const method_internal_call = 0x1000;
