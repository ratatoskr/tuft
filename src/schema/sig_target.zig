/// What test.zon's signatures find. Never runs.
pub fn sigTarget() callconv(.naked) void {
    if (@sizeOf(usize) == 8) asm volatile (
        \\.intel_syntax noprefix
        \\mov eax, 0x1A70F00D
        \\call 1f
        \\1: jmp 2f
        \\nop
        \\2: lea rax, [rip + 3f]
        \\ret
        \\3: .long 0x0BADC0DE
        \\.att_syntax prefix
    ) else asm volatile (
        \\.intel_syntax noprefix
        \\mov eax, 0x1A70F00D
        \\call 1f
        \\1: jmp 2f
        \\nop
        \\2: lea eax, [3f]
        \\ret
        \\3: .long 0x0BADC0DE
        \\.att_syntax prefix
    );
}
