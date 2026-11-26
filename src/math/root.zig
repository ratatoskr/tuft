//! Vectors, quaternions and 4x4 matrices, C-layout so they cross into games and plugins as-is.
//! Row-major for row vectors like D3D: `p * m`, and `a.mul(b)` applies `a` then `b`. Angles in radians.

const std = @import("std");

pub const pi: f32 = std.math.pi;

pub fn degToRad(degrees: f32) f32 {
    return degrees * (pi / 180.0);
}

pub fn radToDeg(radians: f32) f32 {
    return radians * (180.0 / pi);
}

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn clamp(x: f32, lo: f32, hi: f32) f32 {
    return @min(@max(x, lo), hi);
}

/// Into -pi to pi, so turning the short way is easy.
pub fn wrapAngle(radians: f32) f32 {
    const turn = 2 * pi;
    return radians - turn * @floor((radians + pi) / turn);
}

/// What counts as nothing, for nearly-the-same checks.
pub const epsilon: f32 = 1e-5;

/// Which way `z` goes, for building views and projections.
pub const Hand = enum {
    /// Like D3D: x right, y up, z into the screen.
    left,
    /// Like OpenGL: x right, y up, z out of the screen.
    right,
};

/// What every vector has, over its `@Vector` form.
fn Ops(comptime Self: type, comptime n: comptime_int) type {
    return struct {
        pub const V = @Vector(n, f32);

        pub fn vec(self: Self) V {
            return @as(*const [n]f32, @ptrCast(&self)).*;
        }

        pub fn from(v: V) Self {
            var out: Self = undefined;
            @as(*[n]f32, @ptrCast(&out)).* = v;
            return out;
        }

        pub fn splat(x: f32) Self {
            return from(@splat(x));
        }

        pub fn add(a: Self, b: Self) Self {
            return from(a.vec() + b.vec());
        }

        pub fn sub(a: Self, b: Self) Self {
            return from(a.vec() - b.vec());
        }

        /// Each part by each part.
        pub fn mul(a: Self, b: Self) Self {
            return from(a.vec() * b.vec());
        }

        pub fn scale(a: Self, s: f32) Self {
            return from(a.vec() * @as(V, @splat(s)));
        }

        pub fn neg(a: Self) Self {
            return from(-a.vec());
        }

        pub fn dot(a: Self, b: Self) f32 {
            return @reduce(.Add, a.vec() * b.vec());
        }

        pub fn lengthSq(a: Self) f32 {
            return a.dot(a);
        }

        pub fn length(a: Self) f32 {
            return @sqrt(a.lengthSq());
        }

        /// Zero stays zero.
        pub fn normalize(a: Self) Self {
            const l = a.length();
            return if (l > 0) a.scale(1 / l) else a;
        }

        pub fn distance(a: Self, b: Self) f32 {
            return a.sub(b).length();
        }

        pub fn lerp(a: Self, b: Self, t: f32) Self {
            return a.add(b.sub(a).scale(t));
        }

        pub fn min(a: Self, b: Self) Self {
            return from(@min(a.vec(), b.vec()));
        }

        pub fn max(a: Self, b: Self) Self {
            return from(@max(a.vec(), b.vec()));
        }

        /// Within `tolerance` in every part.
        pub fn approxEql(a: Self, b: Self, tolerance: f32) bool {
            return @reduce(.And, @abs(a.vec() - b.vec()) <= @as(V, @splat(tolerance)));
        }
    };
}

pub const Vec2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,

    const O = Ops(Vec2, 2);
    pub const vec = O.vec;
    pub const from = O.from;
    pub const splat = O.splat;
    pub const add = O.add;
    pub const sub = O.sub;
    pub const mul = O.mul;
    pub const scale = O.scale;
    pub const neg = O.neg;
    pub const dot = O.dot;
    pub const lengthSq = O.lengthSq;
    pub const length = O.length;
    pub const normalize = O.normalize;
    pub const distance = O.distance;
    pub const lerp = O.lerp;
    pub const min = O.min;
    pub const max = O.max;
    pub const approxEql = O.approxEql;

    pub const zero: Vec2 = .{};
    pub const one: Vec2 = .{ .x = 1, .y = 1 };

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    /// Turned a quarter anticlockwise, with y up.
    pub fn perp(a: Vec2) Vec2 {
        return .{ .x = -a.y, .y = a.x };
    }

    /// From the x axis toward y.
    pub fn angle(a: Vec2) f32 {
        return std.math.atan2(a.y, a.x);
    }
};

pub const Vec3 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    const O = Ops(Vec3, 3);
    pub const vec = O.vec;
    pub const from = O.from;
    pub const splat = O.splat;
    pub const add = O.add;
    pub const sub = O.sub;
    pub const mul = O.mul;
    pub const scale = O.scale;
    pub const neg = O.neg;
    pub const dot = O.dot;
    pub const lengthSq = O.lengthSq;
    pub const length = O.length;
    pub const normalize = O.normalize;
    pub const distance = O.distance;
    pub const lerp = O.lerp;
    pub const min = O.min;
    pub const max = O.max;
    pub const approxEql = O.approxEql;

    pub const zero: Vec3 = .{};
    pub const one: Vec3 = .{ .x = 1, .y = 1, .z = 1 };
    pub const unit_x: Vec3 = .{ .x = 1 };
    pub const unit_y: Vec3 = .{ .y = 1 };
    pub const unit_z: Vec3 = .{ .z = 1 };

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.y * b.z - a.z * b.y, .y = a.z * b.x - a.x * b.z, .z = a.x * b.y - a.y * b.x };
    }

    pub fn withW(a: Vec3, w: f32) Vec4 {
        return .{ .x = a.x, .y = a.y, .z = a.z, .w = w };
    }
};

pub const Vec4 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 0,

    const O = Ops(Vec4, 4);
    pub const vec = O.vec;
    pub const from = O.from;
    pub const splat = O.splat;
    pub const add = O.add;
    pub const sub = O.sub;
    pub const mul = O.mul;
    pub const scale = O.scale;
    pub const neg = O.neg;
    pub const dot = O.dot;
    pub const lengthSq = O.lengthSq;
    pub const length = O.length;
    pub const normalize = O.normalize;
    pub const distance = O.distance;
    pub const lerp = O.lerp;
    pub const min = O.min;
    pub const max = O.max;
    pub const approxEql = O.approxEql;

    pub const zero: Vec4 = .{};

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    pub fn xyz(a: Vec4) Vec3 {
        return .{ .x = a.x, .y = a.y, .z = a.z };
    }
};

/// A rotation. `w` is the real part.
pub const Quat = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,

    pub const identity: Quat = .{};

    pub fn init(x: f32, y: f32, z: f32, w: f32) Quat {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    fn v4(q: Quat) Vec4 {
        return .{ .x = q.x, .y = q.y, .z = q.z, .w = q.w };
    }

    fn of(v: Vec4) Quat {
        return .{ .x = v.x, .y = v.y, .z = v.z, .w = v.w };
    }

    /// Turning `radians` around `axis`, the way the right hand's fingers curl round it.
    pub fn fromAxisAngle(axis: Vec3, radians: f32) Quat {
        const a = axis.normalize().scale(@sin(radians / 2));
        return .{ .x = a.x, .y = a.y, .z = a.z, .w = @cos(radians / 2) };
    }

    /// Maps x, y, z onto `right`, `up`, `forward`, which must be orthonormal. Like a rotation matrix's rows.
    pub fn fromAxes(right: Vec3, up: Vec3, forward: Vec3) Quat {
        return Mat4.fromRows(right.withW(0), up.withW(0), forward.withW(0), .{ .w = 1 }).rotation();
    }

    /// The shortest turn from one direction to another.
    pub fn between(from_dir: Vec3, to_dir: Vec3) Quat {
        const a = from_dir.normalize();
        const b = to_dir.normalize();
        const d = a.dot(b);
        if (d < -1 + epsilon) {
            // Opposite, so any axis at right angles will do
            var axis = Vec3.unit_x.cross(a);
            if (axis.lengthSq() < epsilon) axis = Vec3.unit_y.cross(a);
            return fromAxisAngle(axis, pi);
        }
        const c = a.cross(b);
        return (Quat{ .x = c.x, .y = c.y, .z = c.z, .w = 1 + d }).normalize();
    }

    /// `a`, then `b`.
    pub fn mul(a: Quat, b: Quat) Quat {
        return .{
            .w = b.w * a.w - b.x * a.x - b.y * a.y - b.z * a.z,
            .x = b.w * a.x + b.x * a.w + b.y * a.z - b.z * a.y,
            .y = b.w * a.y - b.x * a.z + b.y * a.w + b.z * a.x,
            .z = b.w * a.z + b.x * a.y - b.y * a.x + b.z * a.w,
        };
    }

    pub fn conjugate(q: Quat) Quat {
        return .{ .x = -q.x, .y = -q.y, .z = -q.z, .w = q.w };
    }

    /// The opposite turn, for one that's unit length.
    pub const inverse = conjugate;

    pub fn dot(a: Quat, b: Quat) f32 {
        return a.v4().dot(b.v4());
    }

    pub fn length(q: Quat) f32 {
        return q.v4().length();
    }

    pub fn normalize(q: Quat) Quat {
        return of(q.v4().normalize());
    }

    /// `v` turned.
    pub fn rotate(q: Quat, v: Vec3) Vec3 {
        const u: Vec3 = .{ .x = q.x, .y = q.y, .z = q.z };
        const t = u.cross(v).scale(2);
        return v.add(t.scale(q.w)).add(u.cross(t));
    }

    /// Smoothly from `a` to `b`, the short way round.
    pub fn slerp(a: Quat, b_in: Quat, t: f32) Quat {
        var b = b_in;
        var d = a.dot(b);
        if (d < 0) {
            b = of(b.v4().neg());
            d = -d;
        }
        // Nearly the same, where slerp's division blows up
        if (d > 1 - epsilon) return of(a.v4().lerp(b.v4(), t)).normalize();
        const theta = std.math.acos(d);
        const s = @sin(theta);
        return of(a.v4().scale(@sin((1 - t) * theta) / s).add(b.v4().scale(@sin(t * theta) / s)));
    }

    pub fn approxEql(a: Quat, b: Quat, tolerance: f32) bool {
        return a.v4().approxEql(b.v4(), tolerance);
    }

    pub fn toMat4(q: Quat) Mat4 {
        return Mat4.fromRows(
            q.rotate(Vec3.unit_x).withW(0),
            q.rotate(Vec3.unit_y).withW(0),
            q.rotate(Vec3.unit_z).withW(0),
            .{ .w = 1 },
        );
    }
};

/// Row-major for row vectors, `m[row * 4 + column]`, with the translation in the last row.
pub const Mat4 = extern struct {
    m: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },

    pub const identity: Mat4 = .{};

    pub fn fromRows(r0: Vec4, r1: Vec4, r2: Vec4, r3: Vec4) Mat4 {
        var out: Mat4 = undefined;
        for ([_]Vec4{ r0, r1, r2, r3 }, 0..) |r, i| out.m[i * 4 ..][0..4].* = .{ r.x, r.y, r.z, r.w };
        return out;
    }

    pub fn at(self: Mat4, r: usize, c: usize) f32 {
        return self.m[r * 4 + c];
    }

    pub fn row(self: Mat4, r: usize) Vec4 {
        return .{ .x = self.m[r * 4], .y = self.m[r * 4 + 1], .z = self.m[r * 4 + 2], .w = self.m[r * 4 + 3] };
    }

    /// `a`, then `b`.
    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var out: Mat4 = undefined;
        for (0..4) |r| for (0..4) |c| {
            var sum: f32 = 0;
            for (0..4) |k| sum += a.at(r, k) * b.at(k, c);
            out.m[r * 4 + c] = sum;
        };
        return out;
    }

    pub fn transpose(a: Mat4) Mat4 {
        var out: Mat4 = undefined;
        for (0..4) |r| for (0..4) |c| {
            out.m[c * 4 + r] = a.at(r, c);
        };
        return out;
    }

    pub fn translation(v: Vec3) Mat4 {
        var out: Mat4 = .identity;
        out.m[12..15].* = .{ v.x, v.y, v.z };
        return out;
    }

    pub fn scaling(v: Vec3) Mat4 {
        var out: Mat4 = .identity;
        out.m[0] = v.x;
        out.m[5] = v.y;
        out.m[10] = v.z;
        return out;
    }

    /// Scaled, then turned, then moved, like most games' transforms.
    pub fn transform(position: Vec3, turn: Quat, size: Vec3) Mat4 {
        return scaling(size).mul(turn.toMat4()).mul(translation(position));
    }

    pub fn getTranslation(a: Mat4) Vec3 {
        return a.row(3).xyz();
    }

    /// Its turn, from the top left 3x3 with any scale taken out.
    pub fn rotation(a: Mat4) Quat {
        // Rows are where x, y and z go
        const r = [3]Vec3{ a.row(0).xyz().normalize(), a.row(1).xyz().normalize(), a.row(2).xyz().normalize() };
        const trace = r[0].x + r[1].y + r[2].z;
        var q: Quat = undefined;
        if (trace > 0) {
            const s = @sqrt(trace + 1) * 2;
            q = .{ .w = 0.25 * s, .x = (r[1].z - r[2].y) / s, .y = (r[2].x - r[0].z) / s, .z = (r[0].y - r[1].x) / s };
        } else if (r[0].x > r[1].y and r[0].x > r[2].z) {
            const s = @sqrt(1 + r[0].x - r[1].y - r[2].z) * 2;
            q = .{ .w = (r[1].z - r[2].y) / s, .x = 0.25 * s, .y = (r[1].x + r[0].y) / s, .z = (r[2].x + r[0].z) / s };
        } else if (r[1].y > r[2].z) {
            const s = @sqrt(1 + r[1].y - r[0].x - r[2].z) * 2;
            q = .{ .w = (r[2].x - r[0].z) / s, .x = (r[1].x + r[0].y) / s, .y = 0.25 * s, .z = (r[2].y + r[1].z) / s };
        } else {
            const s = @sqrt(1 + r[2].z - r[0].x - r[1].y) * 2;
            q = .{ .w = (r[0].y - r[1].x) / s, .x = (r[2].x + r[0].z) / s, .y = (r[2].y + r[1].z) / s, .z = 0.25 * s };
        }
        return q.normalize();
    }

    /// `p * m`, divided by w for projections.
    pub fn transformPoint(a: Mat4, p: Vec3) Vec3 {
        const v = a.transformVec4(p.withW(1));
        return if (v.w != 0 and v.w != 1) v.xyz().scale(1 / v.w) else v.xyz();
    }

    /// A direction, which moving doesn't change.
    pub fn transformDir(a: Mat4, d: Vec3) Vec3 {
        return a.transformVec4(d.withW(0)).xyz();
    }

    pub fn transformVec4(a: Mat4, v: Vec4) Vec4 {
        var out: [4]f32 = undefined;
        for (0..4) |c| out[c] = v.x * a.at(0, c) + v.y * a.at(1, c) + v.z * a.at(2, c) + v.w * a.at(3, c);
        return .{ .x = out[0], .y = out[1], .z = out[2], .w = out[3] };
    }

    /// Null if it can't be undone, like a scale of zero.
    pub fn inverse(a: Mat4) ?Mat4 {
        const m = a.m;
        var inv: [16]f32 = undefined;
        inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
        inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
        inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
        inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
        inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
        inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
        inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
        inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
        inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
        inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
        inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
        inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
        inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
        inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
        inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
        inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
        const det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
        if (@abs(det) < 1e-12) return null;
        var out: Mat4 = undefined;
        for (inv, 0..) |x, i| out.m[i] = x / det;
        return out;
    }

    /// A camera's view, from `eye` looking at `target`.
    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3, hand: Hand) Mat4 {
        // Where it looks is +z for left-handed views and -z for right-handed ones
        const toward = target.sub(eye).normalize();
        const z = if (hand == .left) toward else toward.neg();
        const x = up.cross(z).normalize();
        const y = z.cross(x);
        return fromRows(
            .{ .x = x.x, .y = y.x, .z = z.x },
            .{ .x = x.y, .y = y.y, .z = z.y },
            .{ .x = x.z, .y = y.z, .z = z.z },
            .{ .x = -x.dot(eye), .y = -y.dot(eye), .z = -z.dot(eye), .w = 1 },
        );
    }

    /// Depth 0 at `near` to 1 at `far`, like D3D and Vulkan. `fov_y` is the full vertical angle.
    pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32, hand: Hand) Mat4 {
        const y = 1 / @tan(fov_y / 2);
        const x = y / aspect;
        const range = far / (far - near);
        const s: f32 = if (hand == .left) 1 else -1;
        return fromRows(
            .{ .x = x },
            .{ .y = y },
            .{ .z = range * s, .w = s },
            .{ .z = -range * near },
        );
    }

    pub fn approxEql(a: Mat4, b: Mat4, tolerance: f32) bool {
        for (a.m, b.m) |x, y| if (@abs(x - y) > tolerance) return false;
        return true;
    }
};

comptime {
    // These cross into games and plugins as they are
    std.debug.assert(@sizeOf(Vec2) == 8 and @sizeOf(Vec3) == 12 and @sizeOf(Vec4) == 16);
    std.debug.assert(@sizeOf(Quat) == 16 and @sizeOf(Mat4) == 64);
}

const testing = std.testing;

fn expectVec(want: Vec3, got: Vec3) !void {
    if (!want.approxEql(got, 1e-4)) {
        std.debug.print("want {any}, got {any}\n", .{ want, got });
        return error.TestUnexpectedResult;
    }
}

test "vectors" {
    const a: Vec3 = .init(1, 2, 3);
    try expectVec(.init(5, 7, 9), a.add(.init(4, 5, 6)));
    try testing.expectEqual(32, a.dot(.init(4, 5, 6)));
    try expectVec(.unit_z, Vec3.unit_x.cross(.unit_y));
    try testing.expectApproxEqAbs(1, a.normalize().length(), 1e-6);
    try expectVec(.zero, Vec3.zero.normalize());
    try expectVec(.init(2.5, 3.5, 4.5), a.lerp(.init(4, 5, 6), 0.5));
    try testing.expectEqual(5, Vec2.init(3, 4).length());
    try testing.expect(Vec4.init(1, 2, 3, 4).approxEql(.from(.{ 1, 2, 3, 4 }), 0));
}

test "angles" {
    try testing.expectApproxEqAbs(pi, degToRad(180), 1e-6);
    try testing.expectApproxEqAbs(90, radToDeg(pi / 2), 1e-4);
    try testing.expectApproxEqAbs(-pi / 2, wrapAngle(3 * pi / 2), 1e-5);
    try testing.expectApproxEqAbs(0.5, wrapAngle(0.5 + 4 * pi), 1e-5);
}

test "quaternions turn the way the right hand curls" {
    const quarter = Quat.fromAxisAngle(.unit_y, pi / 2);
    // Round y, x goes to -z
    try expectVec(.init(0, 0, -1), quarter.rotate(.unit_x));
    // `a`, then `b`
    const turned_x = Quat.fromAxisAngle(.unit_x, pi / 2);
    try expectVec(turned_x.rotate(quarter.rotate(.unit_z)), quarter.mul(turned_x).rotate(.unit_z));
    try expectVec(.unit_x, quarter.inverse().rotate(quarter.rotate(.unit_x)));
    try expectVec(.init(0, 0, -1), Quat.between(.unit_x, .init(0, 0, -1)).rotate(.unit_x));
    try expectVec(.init(-1, 0, 0), Quat.between(.unit_x, .init(-1, 0, 0)).rotate(.unit_x));
    const half = Quat.identity.slerp(quarter, 0.5);
    try testing.expect(half.approxEql(.fromAxisAngle(.unit_y, pi / 4), 1e-5));
}

test "matrices and quaternions agree" {
    const q = Quat.fromAxisAngle(Vec3.init(1, 2, 3).normalize(), 0.7);
    const m = q.toMat4();
    for ([_]Vec3{ .unit_x, .unit_y, .unit_z, .init(1, -2, 0.5) }) |v| try expectVec(q.rotate(v), m.transformDir(v));
    const back = m.rotation();
    try testing.expect(back.approxEql(q, 1e-5) or back.approxEql(.init(-q.x, -q.y, -q.z, -q.w), 1e-5));
    try expectVec(q.rotate(.unit_x), Quat.fromAxes(m.row(0).xyz(), m.row(1).xyz(), m.row(2).xyz()).rotate(.unit_x));

    const t = Mat4.transform(.init(1, 2, 3), q, .init(2, 2, 2));
    try expectVec(q.rotate(.init(2, 0, 0)).add(.init(1, 2, 3)), t.transformPoint(.unit_x));
    try expectVec(.init(1, 2, 3), t.getTranslation());
    try testing.expect(t.mul(t.inverse().?).approxEql(.identity, 1e-5));
    try testing.expectEqual(null, Mat4.scaling(.zero).inverse());
    try testing.expect(t.transpose().transpose().approxEql(t, 0));
}

test "views and projections" {
    for ([_]Hand{ .left, .right }) |hand| {
        const view = Mat4.lookAt(.init(0, 0, -5), .zero, .unit_y, hand);
        const ahead = view.transformPoint(.zero);
        // In front is +z for left-handed views and -z for right-handed ones
        try testing.expectApproxEqAbs(@as(f32, if (hand == .left) 5 else -5), ahead.z, 1e-5);
        try testing.expectApproxEqAbs(0, ahead.x, 1e-5);
        const proj = Mat4.perspective(degToRad(60), 16.0 / 9.0, 0.1, 100, hand);
        const near = proj.transformPoint(.init(0, 0, if (hand == .left) 0.1 else -0.1));
        const far = proj.transformPoint(.init(0, 0, if (hand == .left) 100 else -100));
        try testing.expectApproxEqAbs(0, near.z, 1e-4);
        try testing.expectApproxEqAbs(1, far.z, 1e-4);
    }
}
