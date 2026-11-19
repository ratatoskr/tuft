//! WNDPROC stub `Subclass` copies per window. Only the copies run.

const builtin = @import("builtin");

pub const Slot = enum(usize) { handler, context, original, forward, active };

const Template = struct { start: *const anyopaque, slots: *const anyopaque, end: *const anyopaque };

pub const template: Template = switch (builtin.cpu.arch) {
    .x86_64 => .{ .start = &x64.tuft_wndproc_x64_start, .slots = &x64.tuft_wndproc_x64_slots, .end = &x64.tuft_wndproc_x64_end },
    .x86 => .{ .start = &x86.tuft_wndproc_x86_start, .slots = &x86.tuft_wndproc_x86_slots, .end = &x86.tuft_wndproc_x86_end },
    else => @compileError("Unsupported architecture"),
};

// 0x58 frame keeps RSP aligned. Handler args 5-6 at 0x20/0x28, incoming args 0x30..0x48, result 0x50
const x64 = struct {
    comptime {
        if (builtin.cpu.arch == .x86_64) asm (
            \\.text
            \\.intel_syntax noprefix
            \\.global tuft_wndproc_x64_start
            \\.global tuft_wndproc_x64_slots
            \\.global tuft_wndproc_x64_end
            \\tuft_wndproc_x64_start:
            \\  sub rsp, 0x58
            \\  mov [rsp + 0x30], rcx
            \\  mov [rsp + 0x38], rdx
            \\  mov [rsp + 0x40], r8
            \\  mov [rsp + 0x48], r9
            \\  lock inc qword ptr [rip + .Ltuft_wndproc_x64_active]
            \\  mov rax, [rip + .Ltuft_wndproc_x64_handler]
            \\  test rax, rax
            \\  jz .Ltuft_wndproc_x64_skip
            \\  lea r10, [rsp + 0x50]
            \\  mov [rsp + 0x20], r10
            \\  mov r10, [rip + .Ltuft_wndproc_x64_context]
            \\  mov [rsp + 0x28], r10
            \\  call rax
            \\  lock dec qword ptr [rip + .Ltuft_wndproc_x64_active]
            \\  test al, al
            \\  jz .Ltuft_wndproc_x64_forward
            \\  mov rax, [rsp + 0x50]
            \\  add rsp, 0x58
            \\  ret
            \\.Ltuft_wndproc_x64_skip:
            \\  lock dec qword ptr [rip + .Ltuft_wndproc_x64_active]
            \\.Ltuft_wndproc_x64_forward:
            \\  mov rax, [rsp + 0x48]
            \\  mov [rsp + 0x20], rax
            \\  mov r9, [rsp + 0x40]
            \\  mov r8, [rsp + 0x38]
            \\  mov rdx, [rsp + 0x30]
            \\  mov rcx, [rip + .Ltuft_wndproc_x64_original]
            \\  call [rip + .Ltuft_wndproc_x64_forward_ptr]
            \\  add rsp, 0x58
            \\  ret
            \\.p2align 3
            \\tuft_wndproc_x64_slots:
            \\.Ltuft_wndproc_x64_handler: .quad 0
            \\.Ltuft_wndproc_x64_context: .quad 0
            \\.Ltuft_wndproc_x64_original: .quad 0
            \\.Ltuft_wndproc_x64_forward_ptr: .quad 0
            \\.Ltuft_wndproc_x64_active: .quad 0
            \\tuft_wndproc_x64_end:
            \\.att_syntax prefix
        );
    }
    extern const tuft_wndproc_x64_start: anyopaque;
    extern const tuft_wndproc_x64_slots: anyopaque;
    extern const tuft_wndproc_x64_end: anyopaque;
};

// stdcall args at [ebp+8..+20], result at [ebp-8]. Slots found by call/pop into EBX
const x86 = struct {
    // Label-difference operands still need AT&T.
    comptime {
        if (builtin.cpu.arch == .x86) asm (
            \\.text
            \\.intel_syntax noprefix
            \\.global _tuft_wndproc_x86_start
            \\.global _tuft_wndproc_x86_slots
            \\.global _tuft_wndproc_x86_end
            \\_tuft_wndproc_x86_start:
            \\  push ebp
            \\  mov ebp, esp
            \\  push ebx
            \\  sub esp, 4
            \\  call .Ltuft_wndproc_x86_pc
            \\.Ltuft_wndproc_x86_pc:
            \\  pop ebx
            \\.att_syntax prefix
            \\  lock incl (.Ltuft_wndproc_x86_active - .Ltuft_wndproc_x86_pc)(%ebx)
            \\  movl (.Ltuft_wndproc_x86_handler - .Ltuft_wndproc_x86_pc)(%ebx), %eax
            \\.intel_syntax noprefix
            \\  test eax, eax
            \\  jz .Ltuft_wndproc_x86_skip
            \\  lea ecx, [ebp - 8]
            \\.att_syntax prefix
            \\  pushl (.Ltuft_wndproc_x86_context - .Ltuft_wndproc_x86_pc)(%ebx)
            \\.intel_syntax noprefix
            \\  push ecx
            \\  push dword ptr [ebp + 20]
            \\  push dword ptr [ebp + 16]
            \\  push dword ptr [ebp + 12]
            \\  push dword ptr [ebp + 8]
            \\  call eax
            \\.att_syntax prefix
            \\  lock decl (.Ltuft_wndproc_x86_active - .Ltuft_wndproc_x86_pc)(%ebx)
            \\.intel_syntax noprefix
            \\  test al, al
            \\  jz .Ltuft_wndproc_x86_forward
            \\  mov eax, [ebp - 8]
            \\  jmp .Ltuft_wndproc_x86_return
            \\.Ltuft_wndproc_x86_skip:
            \\.att_syntax prefix
            \\  lock decl (.Ltuft_wndproc_x86_active - .Ltuft_wndproc_x86_pc)(%ebx)
            \\.intel_syntax noprefix
            \\.Ltuft_wndproc_x86_forward:
            \\  push dword ptr [ebp + 20]
            \\  push dword ptr [ebp + 16]
            \\  push dword ptr [ebp + 12]
            \\  push dword ptr [ebp + 8]
            \\.att_syntax prefix
            \\  pushl (.Ltuft_wndproc_x86_original - .Ltuft_wndproc_x86_pc)(%ebx)
            \\  calll *(.Ltuft_wndproc_x86_forward_ptr - .Ltuft_wndproc_x86_pc)(%ebx)
            \\.Ltuft_wndproc_x86_return:
            \\.intel_syntax noprefix
            \\  mov ebx, [ebp - 4]
            \\  mov esp, ebp
            \\  pop ebp
            \\  ret 16
            \\.p2align 2
            \\_tuft_wndproc_x86_slots:
            \\.Ltuft_wndproc_x86_handler: .long 0
            \\.Ltuft_wndproc_x86_context: .long 0
            \\.Ltuft_wndproc_x86_original: .long 0
            \\.Ltuft_wndproc_x86_forward_ptr: .long 0
            \\.Ltuft_wndproc_x86_active: .long 0
            \\_tuft_wndproc_x86_end:
            \\.att_syntax prefix
        );
    }
    extern const tuft_wndproc_x86_start: anyopaque;
    extern const tuft_wndproc_x86_slots: anyopaque;
    extern const tuft_wndproc_x86_end: anyopaque;
};
