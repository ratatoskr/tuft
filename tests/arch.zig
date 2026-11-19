//! Arch tests that run generated code. Apart from `arch` since it can't depend on `sys`.

const std = @import("std");

const arch = @import("tuft_arch");
const sys = @import("tuft_sys");
const memory = @import("tuft_mem");

const relocate = arch.relocate;

// Stubs

const stub_tests = struct {
    fn answer(x: u32) callconv(.c) u32 {
        return x + 1;
    }

    test "abs jump reaches target" {
        const page = try memory.pages.allocAny(64);
        defer memory.pages.free(page);
        page[0..arch.abs_jmp_len].* = arch.encodeAbsJmp(@intFromPtr(&answer));
        const f: *const fn (u32) callconv(.c) u32 = @ptrCast(page.ptr);
        try std.testing.expectEqual(42, f(41));
    }

    threadlocal var published: usize = 0;

    fn readPublished(x: u32) callconv(.c) usize {
        return published + x;
    }

    test "fn stub publishes value" {
        const page = try memory.pages.allocAny(arch.fn_stub_size);
        defer memory.pages.free(page);
        arch.writeFnStub(page[0..arch.fn_stub_size], 0x1000, try sys.tls.locate(&published), @intFromPtr(&readPublished));

        const f: *const fn (u32) callconv(.c) usize = @ptrCast(page.ptr);
        try std.testing.expectEqual(0x1007, f(7));
        try std.testing.expectEqual(0x1000, published);
    }

    fn route(context: usize, cpu: *arch.CpuContext) callconv(.c) usize {
        const resume_at: *const usize = @ptrFromInt(context);
        arch.testing.changeFirstArg(cpu);
        return resume_at.*;
    }

    test "mid stub saves registers" {
        const page = try memory.pages.allocAny(arch.midStubSize());
        defer memory.pages.free(page);
        const resume_at: usize = @intFromPtr(&arch.testing.returnFirstArg);
        arch.writeMidStub(page, @intFromPtr(&resume_at), &route);

        // Called like `returnFirstArg`. The router changes the arg before it runs
        const f: *const @TypeOf(arch.testing.returnFirstArg) = @ptrCast(page.ptr);
        try std.testing.expectEqual(arch.testing.changed_arg, f(5));
    }
};

// Relocation

const relocate_tests = struct {
    const testing = std.testing;

    fn helperCallee() callconv(.c) u32 {
        return 0xCAFE;
    }

    /// Within rel32 reach of this module.
    fn place(code: []const u8) !memory.pages.Slice {
        const page = (try memory.pages.allocNear(@intFromPtr(&helperCallee), 64)) orelse return error.SkipZigTest;
        @memset(page, 0xCC);
        @memcpy(page[0..code.len], code);
        return page;
    }

    test "short Jcc promoted" {
        const page = try place(&.{
            0x31, 0xC0, // xor eax, eax (ZF = 1)
            0x74, 0x06, // jz +6 -> offset 10
            0xB8, 0x64, 0x00, 0x00, 0x00, // mov eax, 100
            0xC3, // ret
            0xB8, 0xC8, 0x00, 0x00, 0x00, // mov eax, 200
            0xC3, // ret
        });
        defer memory.pages.free(page);
        const tramp = try memory.pages.allocAny(128);
        defer memory.pages.free(tramp);

        const res = try relocate.buildTrampoline(@intFromPtr(page.ptr), 5, @intFromPtr(tramp.ptr), tramp);
        try testing.expectEqual(9, res.stolen_len);
        try testing.expectEqualSlices(u8, page[0..9], res.original_bytes[0..9]);

        const f: *const fn () callconv(.c) u32 = @ptrCast(tramp.ptr);
        try testing.expectEqual(200, f());
    }

    test "relative call retargeted" {
        const page = try place(&.{
            0xE8, 0, 0, 0, 0, // call helperCallee
            0x83, 0xC0, 0x01, // add eax, 1
            0xC3, // ret
        });
        defer memory.pages.free(page);
        page[1..5].* = arch.encodeNearJmp(@intFromPtr(page.ptr), @intFromPtr(&helperCallee)).?[1..5].*;
        const tramp = try memory.pages.allocAny(128);
        defer memory.pages.free(tramp);

        const res = try relocate.buildTrampoline(@intFromPtr(page.ptr), 5, @intFromPtr(tramp.ptr), tramp);
        try testing.expectEqual(5, res.stolen_len);

        const f: *const fn () callconv(.c) u32 = @ptrCast(tramp.ptr);
        try testing.expectEqual(0xCAFE + 1, f());
    }

    test "internal branch retargeted" {
        const page = try place(&.{
            0x31, 0xC0, // xor eax, eax (ZF = 1)
            0x74, 0x02, // jz +2 -> offset 6 (inside the stolen bytes)
            0x31, 0xC0, // xor eax, eax
            0x40, // inc eax (x86) / REX prefix of the next instruction (x64)
            0x90, 0x90, 0x90, // nops
            0xC3, // ret
        });
        defer memory.pages.free(page);
        const tramp = try memory.pages.allocAny(128);
        defer memory.pages.free(tramp);

        // jz rel8 grows to 0F 84 rel32, so the target shifts
        _ = try relocate.buildTrampoline(@intFromPtr(page.ptr), 7, @intFromPtr(tramp.ptr), tramp);
        try testing.expectEqualSlices(u8, &.{ 0x31, 0xC0, 0x0F, 0x84 }, tramp[0..4]);
        const rel = std.mem.readInt(i32, tramp[4..8], .little);
        const lands = @as(isize, 8) + rel;
        try testing.expectEqual(page[6], tramp[@intCast(lands)]);
    }

    test "stops at ret" {
        var buf: [128]u8 = undefined;
        const code = [_]u8{ 0x31, 0xC0, 0xC3, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC };
        try testing.expectError(error.FunctionTooSmall, relocate.buildTrampoline(@intFromPtr(&code), 5, @intFromPtr(&buf), &buf));
    }

    test "rejects LOOP and mid-insn branch" {
        var buf: [128]u8 = undefined;

        // loop $ ; nop x4
        const loop_code = [_]u8{ 0xE2, 0xFE, 0x90, 0x90, 0x90, 0x90, 0xC3 };
        try testing.expectError(error.UnsupportedInstruction, relocate.buildTrampoline(@intFromPtr(&loop_code), 5, @intFromPtr(&buf), &buf));

        // jz +1 (into the imm32 of the following mov) ; mov eax, imm32
        const mid_code = [_]u8{ 0x74, 0x01, 0xB8, 0x01, 0x02, 0x03, 0x04, 0xC3 };
        try testing.expectError(error.UnsupportedInstruction, relocate.buildTrampoline(@intFromPtr(&mid_code), 5, @intFromPtr(&buf), &buf));
    }
};

const x64_tests = if (arch.bits != 64) struct {} else struct {
    const testing = std.testing;

    var test_global_value: u64 = 0x1122334455667788;

    fn stubTargetWithRipRead() callconv(.naked) void {
        asm volatile (
            \\.intel_syntax noprefix
            \\mov rax, [rip + %[val:P]]
            \\add rax, 10
            \\ret
            :
            : [val] "s" (&test_global_value),
        );
    }

    fn stubTargetWithShortBranch() callconv(.naked) void {
        asm volatile (
            \\.intel_syntax noprefix
            \\test ecx, ecx
            \\jz is_zero
            \\mov eax, 100
            \\ret
            \\is_zero:
            \\mov eax, 200
            \\ret
        );
    }

    fn helperCallee() callconv(.c) u64 {
        return 0xCAFEBABE;
    }

    fn stubTargetWithCall() callconv(.naked) void {
        asm volatile (
            \\.intel_syntax noprefix
            \\sub rsp, 40
            \\call %[callee:P]
            \\add rsp, 40
            \\add rax, 1
            \\ret
            :
            : [callee] "s" (&helperCallee),
        );
    }

    test "x64 near RIP-relative read" {
        const target_addr = @intFromPtr(&stubTargetWithRipRead);
        const near_page = (try memory.pages.allocNear(target_addr, 256)) orelse return error.ExpectedNearAlloc;
        defer memory.pages.free(near_page);

        const res = try relocate.buildTrampoline(target_addr, 5, @intFromPtr(near_page.ptr), near_page);
        try testing.expect(res.stolen_len >= 5);
        try testing.expect(res.trampoline_len > res.stolen_len);

        const tramp_fn: *const fn () callconv(.c) u64 = @ptrCast(near_page.ptr);
        try testing.expectEqual(0x1122334455667788 + 10, tramp_fn());
    }

    test "x64 far movabs and abs jump" {
        const target_addr = @intFromPtr(&stubTargetWithRipRead);
        var buf: [128]u8 = undefined;

        // 16GB away to force the >2GB path
        const far_base = target_addr + 0x4_0000_0000;
        const res = try relocate.buildTrampoline(target_addr, 5, far_base, &buf);
        try testing.expect(res.stolen_len >= 5);

        // `mov rax, [rip+val]` uses RAX, so expect push rcx then movabs rcx
        try testing.expectEqual(0x51, buf[0]);
        try testing.expectEqual(0x48, buf[1]);
        try testing.expectEqual(0xB9, buf[2]);

        // Ends with `FF 25 00 00 00 00 <stolen_end>`
        const tail = buf[res.trampoline_len - 14 .. res.trampoline_len];
        try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0x25, 0x00, 0x00, 0x00, 0x00 }, tail[0..6]);
        try testing.expectEqual(@as(u64, target_addr + res.stolen_len), std.mem.readInt(u64, tail[6..14], .little));
    }

    fn detourStandIn() callconv(.c) u64 {
        return 0xDEAD;
    }

    /// Skips the test if there's none.
    fn allocFar(addr: usize) !memory.pages.Slice {
        const page = (try memory.pages.allocNear(addr + 0x4_0000_0000, 256)) orelse return error.SkipZigTest;
        if (arch.encodeNearJmp(@intFromPtr(page.ptr), addr) != null) {
            memory.pages.free(page);
            return error.SkipZigTest;
        }
        return page;
    }

    test "x64 already hooked target" {
        const stub = try memory.pages.allocAny(64);
        defer memory.pages.free(stub);
        @memset(stub, 0xCC);
        @memcpy(stub[0..14], &arch.encodeAbsJmp(@intFromPtr(&helperCallee)));

        const tramp = try memory.pages.allocAny(256);
        defer memory.pages.free(tramp);
        const res = try relocate.buildTrampoline(@intFromPtr(stub.ptr), 14, @intFromPtr(tramp.ptr), tramp);
        try testing.expectEqual(14, res.stolen_len);

        // Pretend the hook wrote our jump over the prologue and its literal
        @memcpy(stub[0..14], &arch.encodeAbsJmp(@intFromPtr(&detourStandIn)));

        const tramp_fn: *const fn () callconv(.c) u64 = @ptrCast(tramp.ptr);
        try testing.expectEqual(0xCAFEBABE, tramp_fn());
    }

    test "x64 far jmp rip" {
        const stub = try memory.pages.allocAny(64);
        defer memory.pages.free(stub);
        @memset(stub, 0xCC);
        // jmp [rip+26] -> cell at +32
        @memcpy(stub[0..6], &[_]u8{ 0xFF, 0x25, 0x1A, 0x00, 0x00, 0x00 });
        std.mem.writeInt(u64, stub[32..40], @intFromPtr(&helperCallee), .little);

        const tramp = try allocFar(@intFromPtr(stub.ptr));
        defer memory.pages.free(tramp);
        _ = try relocate.buildTrampoline(@intFromPtr(stub.ptr), 6, @intFromPtr(tramp.ptr), tramp);

        const tramp_fn: *const fn () callconv(.c) u64 = @ptrCast(tramp.ptr);
        try testing.expectEqual(0xCAFEBABE, tramp_fn());
    }

    test "x64 far call rip" {
        const stub = try memory.pages.allocAny(64);
        defer memory.pages.free(stub);
        @memset(stub, 0xCC);
        @memcpy(stub[0..19], &[_]u8{
            0x48, 0x83, 0xEC, 0x28, // sub rsp, 40
            0xFF, 0x15, 0x16, 0x00, 0x00, 0x00, // call [rip+22] -> cell at +32
            0x48, 0x83, 0xC4, 0x28, // add rsp, 40
            0x48, 0x83, 0xC0, 0x01, // add rax, 1
            0xC3, // ret
        });
        std.mem.writeInt(u64, stub[32..40], @intFromPtr(&helperCallee), .little);

        const tramp = try allocFar(@intFromPtr(stub.ptr));
        defer memory.pages.free(tramp);
        const res = try relocate.buildTrampoline(@intFromPtr(stub.ptr), 14, @intFromPtr(tramp.ptr), tramp);
        try testing.expectEqual(14, res.stolen_len);

        const tramp_fn: *const fn () callconv(.c) u64 = @ptrCast(tramp.ptr);
        try testing.expectEqual(0xCAFEBABE + 1, tramp_fn());
    }

    test "x64 branch after RIP growth" {
        const stub = try memory.pages.allocAny(64);
        defer memory.pages.free(stub);
        @memset(stub, 0xCC);
        @memcpy(stub[0..18], &[_]u8{
            0x31, 0xC0, // xor eax, eax
            0x85, 0xC9, // test ecx, ecx
            0x74, 0x07, // jz +7 -> offset 13
            0x48, 0x8B, 0x05, 0x13, 0x00, 0x00, 0x00, // mov rax, [rip+19] -> cell at +32 (grows when far)
            0x48, 0x83, 0xC0, 0x01, // add rax, 1
            0xC3, // ret
        });
        std.mem.writeInt(u64, stub[32..40], 100, .little);

        const tramp = try allocFar(@intFromPtr(stub.ptr));
        defer memory.pages.free(tramp);
        const res = try relocate.buildTrampoline(@intFromPtr(stub.ptr), 14, @intFromPtr(tramp.ptr), tramp);
        try testing.expectEqual(17, res.stolen_len);

        const tramp_fn: *const fn (u32) callconv(.c) u64 = @ptrCast(tramp.ptr);
        try testing.expectEqual(1, tramp_fn(0));
        try testing.expectEqual(101, tramp_fn(1));
    }

    test "x64 far RIP scratch register" {
        const stub = try memory.pages.allocAny(64);
        defer memory.pages.free(stub);
        @memset(stub, 0xCC);
        @memcpy(stub[0..17], &[_]u8{
            0xB8, 0x06, 0x00, 0x00, 0x00, // mov eax, 6
            0x48, 0xF7, 0x25, 0x14, 0x00, 0x00, 0x00, // mul qword [rip+20] -> cell at +32 (implicit RDX:RAX)
            0x48, 0x83, 0xC0, 0x00, // add rax, 0
            0xC3, // ret
        });
        std.mem.writeInt(u64, stub[32..40], 7, .little);

        const tramp = try allocFar(@intFromPtr(stub.ptr));
        defer memory.pages.free(tramp);
        _ = try relocate.buildTrampoline(@intFromPtr(stub.ptr), 14, @intFromPtr(tramp.ptr), tramp);

        const tramp_fn: *const fn () callconv(.c) u64 = @ptrCast(tramp.ptr);
        try testing.expectEqual(42, tramp_fn());
    }

    test "x64 far Jcc" {
        const target_addr = @intFromPtr(&stubTargetWithShortBranch);
        const tramp = try allocFar(target_addr);
        defer memory.pages.free(tramp);

        _ = try relocate.buildTrampoline(target_addr, 5, @intFromPtr(tramp.ptr), tramp);

        const tramp_fn: *const fn (u32) callconv(.c) u32 = @ptrCast(tramp.ptr);
        try testing.expectEqual(200, tramp_fn(0));
        try testing.expectEqual(100, tramp_fn(1));
    }

    test "x64 far CALL" {
        const target_addr = @intFromPtr(&stubTargetWithCall);
        const tramp = try allocFar(target_addr);
        defer memory.pages.free(tramp);

        _ = try relocate.buildTrampoline(target_addr, 5, @intFromPtr(tramp.ptr), tramp);

        const tramp_fn: *const fn () callconv(.c) u64 = @ptrCast(tramp.ptr);
        try testing.expectEqual(0xCAFEBABE + 1, tramp_fn());
    }

    test "x64 far JMP" {
        const stub = (try memory.pages.allocNear(@intFromPtr(&helperCallee), 64)) orelse return error.SkipZigTest;
        defer memory.pages.free(stub);
        @memset(stub, 0xCC);
        stub[0..5].* = arch.encodeNearJmp(@intFromPtr(stub.ptr), @intFromPtr(&helperCallee)).?;

        const tramp = try allocFar(@intFromPtr(stub.ptr));
        defer memory.pages.free(tramp);
        _ = try relocate.buildTrampoline(@intFromPtr(stub.ptr), 5, @intFromPtr(tramp.ptr), tramp);

        const tramp_fn: *const fn () callconv(.c) u64 = @ptrCast(tramp.ptr);
        try testing.expectEqual(0xCAFEBABE, tramp_fn());
    }

    test "x64 far rejects VEX" {
        var code: [32]u8 = @splat(0xCC);
        // vmovaps xmm0, [rip+0x10]
        code[0..8].* = .{ 0xC5, 0xF8, 0x28, 0x05, 0x10, 0x00, 0x00, 0x00 };
        var buf: [128]u8 = undefined;

        const far_base = @intFromPtr(&code) + 0x4_0000_0000;
        try testing.expectError(error.UnsupportedInstruction, relocate.buildTrampoline(@intFromPtr(&code), 5, far_base, &buf));
    }
};

test {
    _ = stub_tests;
    _ = relocate_tests;
    _ = x64_tests;
}
