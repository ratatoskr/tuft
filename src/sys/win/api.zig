//! Win32 bindings for tuft and wraith. Only what we use.

const std = @import("std");
const zwin = std.os.windows;

pub const DWORD = zwin.DWORD;
pub const BOOL = zwin.BOOL;
pub const HANDLE = zwin.HANDLE;
pub const HINSTANCE = zwin.HINSTANCE;
pub const FARPROC = zwin.FARPROC;
pub const MAX_PATH = zwin.MAX_PATH;
pub const CloseHandle = zwin.CloseHandle;
pub const GMEM_MOVEABLE: u32 = 0x0002;
pub const CF_DIBV5: u32 = 17;
pub const CF_UNICODETEXT: u32 = 13;
pub extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalSize(memory: HANDLE) callconv(.winapi) usize;
pub extern "user32" fn GetClipboardData(format: u32) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalFree(memory: HANDLE) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalLock(memory: HANDLE) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(memory: HANDLE) callconv(.winapi) BOOL;
pub extern "user32" fn OpenClipboard(owner: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn SetClipboardData(format: u32, memory: HANDLE) callconv(.winapi) ?HANDLE;
pub extern "shell32" fn SHGetKnownFolderPath(folder: *const zwin.GUID, flags: u32, token: ?HANDLE, path: *?[*:0]u16) callconv(.winapi) i32;
pub extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) callconv(.winapi) void;
pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GetModuleFileNameW(hModule: ?HINSTANCE, lpFilename: [*:0]u16, nSize: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetProcAddress(hModule: HINSTANCE, lpProcName: [*:0]const u8) callconv(.winapi) ?FARPROC;
pub extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn FreeLibrary(hLibModule: HINSTANCE) callconv(.winapi) BOOL;
pub const GET_MODULE_HANDLE_EX_FLAG_PIN: DWORD = 0x1;
pub const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: DWORD = 0x4;
pub extern "kernel32" fn GetModuleHandleExW(dwFlags: DWORD, lpModuleName: ?*const anyopaque, phModule: *?HINSTANCE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetSystemDirectoryW(lpBuffer: [*]u16, uSize: u32) callconv(.winapi) u32;
pub extern "kernel32" fn GetWindowsDirectoryW(lpBuffer: [*]u16, uSize: u32) callconv(.winapi) u32;
pub extern "kernel32" fn GetUserDefaultUILanguage() callconv(.winapi) u16;
pub extern "user32" fn GetKeyboardLayoutList(nBuff: i32, lpList: ?[*]?*anyopaque) callconv(.winapi) i32;
/// 0 on 32-bit Windows.
pub extern "kernel32" fn GetSystemWow64DirectoryW(lpBuffer: [*]u16, uSize: u32) callconv(.winapi) u32;
pub extern "kernel32" fn RtlPcToFileHeader(PcValue: ?*const anyopaque, BaseOfImage: *?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn VirtualAlloc(lpAddress: ?*anyopaque, dwSize: usize, flAllocationType: zwin.MEM.ALLOCATE, flProtect: zwin.PAGE) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn VirtualFree(lpAddress: ?*anyopaque, dwSize: usize, dwFreeType: zwin.MEM.FREE) callconv(.winapi) BOOL;
pub extern "kernel32" fn VirtualProtect(lpAddress: ?*anyopaque, dwSize: usize, flNewProtect: zwin.PAGE, lpflOldProtect: *zwin.PAGE) callconv(.winapi) BOOL;
pub extern "kernel32" fn FlushInstructionCache(hProcess: HANDLE, lpBaseAddress: ?*const anyopaque, dwSize: usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn VirtualQuery(lpAddress: ?*const anyopaque, lpBuffer: *MEMORY_BASIC_INFORMATION, dwLength: usize) callconv(.winapi) usize;
pub extern "kernel32" fn GetProcessHeap() callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn HeapLock(hHeap: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn HeapUnlock(hHeap: HANDLE) callconv(.winapi) BOOL;
pub const MEMORY_BASIC_INFORMATION = extern struct {
    BaseAddress: ?*anyopaque,
    AllocationBase: ?*anyopaque,
    AllocationProtect: u32,
    /// 64-bit layout only.
    PartitionId: if (@sizeOf(usize) == 8) u16 else void,
    RegionSize: usize,
    State: u32,
    Protect: u32,
    Type: u32,
};
pub const MEM_COMMIT: u32 = 0x1000;
pub const PAGE_NOACCESS: u32 = 0x01;
pub const PAGE_READWRITE: u32 = 0x04;
pub const PAGE_WRITECOPY: u32 = 0x08;
pub const PAGE_EXECUTE: u32 = 0x10;
pub const PAGE_EXECUTE_READ: u32 = 0x20;
pub const PAGE_EXECUTE_READWRITE: u32 = 0x40;
pub const PAGE_EXECUTE_WRITECOPY: u32 = 0x80;
pub const PAGE_GUARD: u32 = 0x100;
/// Always -1.
pub const current_process: HANDLE = @ptrFromInt(std.math.maxInt(usize));
/// Windows 10 1803+, looked up at runtime.
pub const PFN_VirtualAlloc2 = *const fn (
    Process: ?HANDLE,
    BaseAddress: ?*anyopaque,
    Size: usize,
    AllocationType: zwin.MEM.ALLOCATE,
    PageProtection: zwin.PAGE,
    ExtendedParameters: ?[*]MEM_EXTENDED_PARAMETER,
    ParameterCount: u32,
) callconv(.winapi) ?*anyopaque;
pub const MEM_EXTENDED_PARAMETER_TYPE = enum(u64) {
    MemExtendedParameterInvalidType = 0,
    MemExtendedParameterAddressRequirements = 1,
};
pub const MEM_ADDRESS_REQUIREMENTS = extern struct {
    LowestStartingAddress: ?*anyopaque,
    HighestEndingAddress: ?*anyopaque,
    Alignment: usize,
};
pub const MEM_EXTENDED_PARAMETER = extern struct {
    // Low 8 bits are the type
    Type: u64,
    Arg: extern union {
        ULong64: u64,
        Pointer: ?*anyopaque,
        Size: usize,
        Handle: HANDLE,
        ULong: u32,
    },
};
/// The first thread if `ThreadHandle` is null.
pub extern "ntdll" fn NtGetNextThread(ProcessHandle: HANDLE, ThreadHandle: ?HANDLE, DesiredAccess: DWORD, HandleAttributes: u32, Flags: u32, NewThreadHandle: *?HANDLE) callconv(.winapi) zwin.NTSTATUS;
pub extern "ntdll" fn NtQueryInformationThread(ThreadHandle: HANDLE, ThreadInformationClass: u32, ThreadInformation: *anyopaque, ThreadInformationLength: u32, ReturnLength: ?*u32) callconv(.winapi) zwin.NTSTATUS;
/// Gets the thread's start address.
pub const ThreadQuerySetWin32StartAddress: u32 = 9;
pub extern "kernel32" fn GetThreadId(Thread: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn SuspendThread(hThread: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn ResumeThread(hThread: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetThreadContext(hThread: HANDLE, lpContext: *zwin.CONTEXT) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetThreadContext(hThread: HANDLE, lpContext: *const zwin.CONTEXT) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCurrentThread() callconv(.winapi) HANDLE;
pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
pub extern "kernel32" fn GetCurrentThreadStackLimits(LowLimit: *usize, HighLimit: *usize) callconv(.winapi) void;
pub const INFINITE: DWORD = 0xFFFFFFFF;
/// `null` means no manifest redirection.
pub extern "kernel32" fn ActivateActCtx(hActCtx: ?HANDLE, lpCookie: *usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeactivateActCtx(dwFlags: DWORD, ulCookie: usize) callconv(.winapi) BOOL;
pub const THREAD_START_ROUTINE = fn (lpParameter: ?*anyopaque) callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateThread(lpThreadAttributes: ?*anyopaque, dwStackSize: usize, lpStartAddress: *const THREAD_START_ROUTINE, lpParameter: ?*anyopaque, dwCreationFlags: DWORD, lpThreadId: ?*DWORD) callconv(.winapi) ?HANDLE;
pub const GENERIC_READ: DWORD = 0x80000000;
pub const FILE_SHARE_READ: DWORD = 0x1;
pub const OPEN_EXISTING: DWORD = 3;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
pub extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?HANDLE) callconv(.winapi) HANDLE;
pub const FILE_APPEND_DATA: DWORD = 0x4;
pub const OPEN_ALWAYS: DWORD = 4;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub const SYSTEMTIME = extern struct {
    wYear: u16 = 0,
    wMonth: u16 = 0,
    wDayOfWeek: u16 = 0,
    wDay: u16 = 0,
    wHour: u16 = 0,
    wMinute: u16 = 0,
    wSecond: u16 = 0,
    wMilliseconds: u16 = 0,
};
pub extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;
pub extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateEventW(lpEventAttributes: ?*anyopaque, bManualReset: BOOL, bInitialState: BOOL, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;

pub const UNICODE_STRING = extern struct {
    /// In bytes.
    Length: u16,
    MaximumLength: u16,
    Buffer: ?[*]u16,

    pub fn slice(self: *const UNICODE_STRING) []const u16 {
        const b = self.Buffer orelse return &.{};
        return b[0 .. self.Length / 2];
    }
};
pub const LDR_DLL_NOTIFICATION_DATA = extern struct {
    Flags: u32,
    FullDllName: *const UNICODE_STRING,
    BaseDllName: *const UNICODE_STRING,
    DllBase: *anyopaque,
    SizeOfImage: u32,
};
pub const LDR_DLL_NOTIFICATION_FUNCTION = fn (NotificationReason: u32, NotificationData: *const LDR_DLL_NOTIFICATION_DATA, Context: ?*anyopaque) callconv(.winapi) void;
pub extern "ntdll" fn LdrRegisterDllNotification(Flags: u32, NotificationFunction: *const LDR_DLL_NOTIFICATION_FUNCTION, Context: ?*anyopaque, Cookie: *?*anyopaque) callconv(.winapi) zwin.NTSTATUS;
pub extern "ntdll" fn LdrUnregisterDllNotification(Cookie: *anyopaque) callconv(.winapi) zwin.NTSTATUS;
pub const THREAD_SUSPEND_RESUME: DWORD = 0x0002;
pub const THREAD_GET_CONTEXT: DWORD = 0x0008;
pub const THREAD_SET_CONTEXT: DWORD = 0x0010;
pub const THREAD_QUERY_LIMITED_INFORMATION: DWORD = 0x0800;
/// Needed for a thread's start address. The limited one won't do.
pub const THREAD_QUERY_INFORMATION: DWORD = 0x0040;
pub extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn AcquireSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn AcquireSRWLockShared(SRWLock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockShared(SRWLock: *SRWLOCK) callconv(.winapi) void;
/// Nonzero if it got it.
pub extern "kernel32" fn TryAcquireSRWLockShared(SRWLock: *SRWLOCK) callconv(.winapi) u8;
pub const SRWLOCK = extern struct {
    Ptr: ?*anyopaque = null,
};
pub const IMAGE_DOS_HEADER = extern struct {
    e_magic: u16 = 0,
    e_cblp: u16 = 0,
    e_cp: u16 = 0,
    e_crlc: u16 = 0,
    e_cparhdr: u16 = 0,
    e_minalloc: u16 = 0,
    e_maxalloc: u16 = 0,
    e_ss: u16 = 0,
    e_sp: u16 = 0,
    e_csum: u16 = 0,
    e_ip: u16 = 0,
    e_cs: u16 = 0,
    e_lfarlc: u16 = 0,
    e_ovno: u16 = 0,
    e_res: [4]u16 = @splat(0),
    e_oemid: u16 = 0,
    e_oeminfo: u16 = 0,
    e_res2: [10]u16 = @splat(0),
    e_lfanew: i32 = 0,
};
pub const IMAGE_DOS_SIGNATURE: u16 = 0x5A4D; // 'MZ'
pub const IMAGE_NT_SIGNATURE: u32 = 0x00004550; // 'PE\0\0'
pub const IMAGE_FILE_HEADER = extern struct {
    Machine: u16,
    NumberOfSections: u16,
    TimeDateStamp: u32,
    PointerToSymbolTable: u32,
    NumberOfSymbols: u32,
    SizeOfOptionalHeader: u16,
    Characteristics: u16,
};
/// `SizeOfImage` is at the same offset in PE32 and PE32+.
pub const IMAGE_NT_HEADERS_PREFIX = extern struct {
    Signature: u32,
    FileHeader: IMAGE_FILE_HEADER,
};
pub const optional_header_size_of_image_offset = 56;
pub const IMAGE_SECTION_HEADER = extern struct {
    Name: [8]u8 = @splat(0),
    Misc: extern union {
        PhysicalAddress: u32,
        VirtualSize: u32,
    } = .{ .PhysicalAddress = 0 },
    VirtualAddress: u32 = 0,
    SizeOfRawData: u32 = 0,
    PointerToRawData: u32 = 0,
    PointerToRelocations: u32 = 0,
    PointerToLinenumbers: u32 = 0,
    NumberOfRelocations: u16 = 0,
    NumberOfLinenumbers: u16 = 0,
    Characteristics: u32 = 0,
};
pub const IMAGE_SCN_MEM_EXECUTE: u32 = 0x2000_0000;
pub const IMAGE_SCN_MEM_READ: u32 = 0x4000_0000;
pub const IMAGE_SCN_MEM_WRITE: u32 = 0x8000_0000;
pub const EXCEPTION_POINTERS = zwin.EXCEPTION_POINTERS;
pub const EXCEPTION_RECORD = zwin.EXCEPTION_RECORD;
pub const CONTEXT = zwin.CONTEXT;
pub const EXCEPTION_CONTINUE_SEARCH: c_long = 0;
pub const EXCEPTION_CONTINUE_EXECUTION: c_long = -1;
pub const EXCEPTION_NONCONTINUABLE: u32 = 0x1;
/// Nonzero runs it before existing handlers.
pub extern "kernel32" fn AddVectoredExceptionHandler(First: u32, Handler: zwin.VECTORED_EXCEPTION_HANDLER) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn RemoveVectoredExceptionHandler(Handle: *anyopaque) callconv(.winapi) u32;
pub const TOP_LEVEL_EXCEPTION_FILTER = fn (info: *EXCEPTION_POINTERS) callconv(.winapi) c_long;
pub extern "kernel32" fn SetUnhandledExceptionFilter(lpTopLevelExceptionFilter: ?*const TOP_LEVEL_EXCEPTION_FILTER) callconv(.winapi) ?*const TOP_LEVEL_EXCEPTION_FILTER;
pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const CREATE_ALWAYS: DWORD = 2;
/// Packed to 4 in dbghelp.h, so on x64 the pointer's at 4, not 8.
pub const MINIDUMP_EXCEPTION_INFORMATION = extern struct {
    ThreadId: DWORD,
    ExceptionPointers: ?*const EXCEPTION_POINTERS align(4),
    /// TRUE when they're in the dumped process, not ours.
    ClientPointers: BOOL,
};
pub const MiniDumpWriteDumpFn = fn (hProcess: HANDLE, ProcessId: DWORD, hFile: HANDLE, DumpType: u32, ExceptionParam: ?*const MINIDUMP_EXCEPTION_INFORMATION, UserStreamParam: ?*const anyopaque, CallbackParam: ?*const anyopaque) callconv(.winapi) BOOL;
pub const MiniDumpWithUnloadedModules: u32 = 0x20;
pub const MiniDumpWithIndirectlyReferencedMemory: u32 = 0x40;
pub const MiniDumpWithThreadInfo: u32 = 0x1000;
comptime {
    std.debug.assert(@offsetOf(MINIDUMP_EXCEPTION_INFORMATION, "ExceptionPointers") == 4);
    std.debug.assert(@sizeOf(MINIDUMP_EXCEPTION_INFORMATION) == 8 + @sizeOf(usize));
}

const builtin = @import("builtin");
pub const HWND = *anyopaque;

pub const OPENFILENAMEW = extern struct {
    lStructSize: DWORD = @sizeOf(OPENFILENAMEW),
    hwndOwner: ?HWND = null,
    hInstance: ?HINSTANCE = null,
    lpstrFilter: ?[*:0]const u16 = null,
    lpstrCustomFilter: ?[*]u16 = null,
    nMaxCustFilter: DWORD = 0,
    nFilterIndex: DWORD = 0,
    lpstrFile: [*]u16,
    nMaxFile: DWORD,
    lpstrFileTitle: ?[*]u16 = null,
    nMaxFileTitle: DWORD = 0,
    lpstrInitialDir: ?[*:0]const u16 = null,
    lpstrTitle: ?[*:0]const u16 = null,
    Flags: DWORD = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?[*:0]const u16 = null,
    lCustData: isize = 0,
    lpfnHook: ?*const anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: DWORD = 0,
    FlagsEx: DWORD = 0,

    comptime {
        std.debug.assert(@sizeOf(OPENFILENAMEW) == if (@sizeOf(usize) == 8) 152 else 88);
    }
};
pub const OFN_OVERWRITEPROMPT: DWORD = 0x2;
pub const OFN_HIDEREADONLY: DWORD = 0x4;
pub const OFN_NOCHANGEDIR: DWORD = 0x8;
pub const OFN_PATHMUSTEXIST: DWORD = 0x800;
pub const OFN_FILEMUSTEXIST: DWORD = 0x1000;
pub const OFN_EXPLORER: DWORD = 0x80000;
pub extern "comdlg32" fn GetOpenFileNameW(ofn: *OPENFILENAMEW) callconv(.winapi) BOOL;
pub extern "comdlg32" fn GetSaveFileNameW(ofn: *OPENFILENAMEW) callconv(.winapi) BOOL;
/// 0 means the user cancelled.
pub extern "comdlg32" fn CommDlgExtendedError() callconv(.winapi) DWORD;

// COM, for the folder picker. Only the methods we call, in vtable order.
pub const HRESULT = i32;
pub const COINIT_APARTMENTTHREADED: DWORD = 0x2;
pub const COINIT_DISABLE_OLE1DDE: DWORD = 0x4;
pub const CLSCTX_INPROC_SERVER: DWORD = 0x1;
/// What `Show` gives when the user cancels.
pub const HRESULT_CANCELLED: HRESULT = @bitCast(@as(u32, 0x800704C7));
pub const FOS_NOCHANGEDIR: DWORD = 0x8;
pub const FOS_PICKFOLDERS: DWORD = 0x20;
pub const FOS_FORCEFILESYSTEM: DWORD = 0x40;
pub const FOS_PATHMUSTEXIST: DWORD = 0x800;
pub const SIGDN_FILESYSPATH: u32 = 0x80058000;
pub const CLSID_FileOpenDialog: zwin.GUID = .parse("{DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7}");
pub const IID_IFileDialog: zwin.GUID = .parse("{42f85136-db7e-439c-85f1-e4075d135fc8}");
pub const IID_IShellItem: zwin.GUID = .parse("{43826d1e-e718-42ee-bc55-a1e261c37bfe}");
pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoCreateInstance(clsid: *const zwin.GUID, outer: ?*anyopaque, context: DWORD, iid: *const zwin.GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;
pub extern "shell32" fn SHCreateItemFromParsingName(path: [*:0]const u16, bind: ?*anyopaque, iid: *const zwin.GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;

pub const IShellItem = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IShellItem) callconv(.winapi) u32,
        BindToHandler: *const anyopaque,
        GetParent: *const anyopaque,
        GetDisplayName: *const fn (*IShellItem, sigdn: u32, name: *?[*:0]u16) callconv(.winapi) HRESULT,
    };
};

pub const IFileDialog = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IFileDialog) callconv(.winapi) u32,
        Show: *const fn (*IFileDialog, owner: ?HWND) callconv(.winapi) HRESULT,
        SetFileTypes: *const anyopaque,
        SetFileTypeIndex: *const anyopaque,
        GetFileTypeIndex: *const anyopaque,
        Advise: *const anyopaque,
        Unadvise: *const anyopaque,
        SetOptions: *const fn (*IFileDialog, options: DWORD) callconv(.winapi) HRESULT,
        GetOptions: *const fn (*IFileDialog, options: *DWORD) callconv(.winapi) HRESULT,
        SetDefaultFolder: *const anyopaque,
        SetFolder: *const fn (*IFileDialog, folder: *IShellItem) callconv(.winapi) HRESULT,
        GetFolder: *const anyopaque,
        GetCurrentSelection: *const anyopaque,
        SetFileName: *const anyopaque,
        GetFileName: *const anyopaque,
        SetTitle: *const fn (*IFileDialog, title: [*:0]const u16) callconv(.winapi) HRESULT,
        SetOkButtonLabel: *const anyopaque,
        SetFileNameLabel: *const anyopaque,
        GetResult: *const fn (*IFileDialog, item: *?*IShellItem) callconv(.winapi) HRESULT,
    };
};
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: [*:0]const u16,
    lpWindowName: ?[*:0]const u16,
    dwStyle: DWORD,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?*anyopaque,
    hInstance: ?*anyopaque,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CallWindowProcW(lpPrevWndFunc: isize, hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize;
pub extern "user32" fn SendMessageW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize;
pub extern "user32" fn PostMessageW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowThreadProcessId(hWnd: HWND, lpdwProcessId: ?*DWORD) callconv(.winapi) DWORD;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn GetDpiForWindow(hWnd: HWND) callconv(.winapi) u32;
pub extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize;
pub extern "user32" fn RegisterWindowMessageW(lpString: [*:0]const u16) callconv(.winapi) u32;
pub extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: u32, wMsgFilterMax: u32, wRemoveMsg: u32) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) isize;
pub extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?HWND, X: i32, Y: i32, cx: i32, cy: i32, uFlags: u32) callconv(.winapi) BOOL;
pub const SWP_NOSIZE: u32 = 0x0001;
pub const SWP_NOMOVE: u32 = 0x0002;
pub const SWP_NOZORDER: u32 = 0x0004;
pub const SWP_NOACTIVATE: u32 = 0x0010;
const long_ptr = struct {
    extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.winapi) isize;
    extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
};
const long = struct {
    extern "user32" fn GetWindowLongW(hWnd: HWND, nIndex: i32) callconv(.winapi) isize;
    extern "user32" fn SetWindowLongW(hWnd: HWND, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
};
const is64 = builtin.cpu.arch == .x86_64;
pub const GetWindowLongPtrW = if (is64) long_ptr.GetWindowLongPtrW else long.GetWindowLongW;
pub const SetWindowLongPtrW = if (is64) long_ptr.SetWindowLongPtrW else long.SetWindowLongW;
pub const MSG = extern struct {
    hwnd: ?HWND = null,
    message: u32 = 0,
    wParam: usize = 0,
    lParam: isize = 0,
    time: u32 = 0,
    pt: POINT = .{},
    lPrivate: u32 = 0,
};
pub const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
pub const POINT = extern struct { x: i32 = 0, y: i32 = 0 };
pub const PM_REMOVE: u32 = 1;
pub const PM_NOREMOVE: u32 = 0;
pub const QS_SENDMESSAGE: u32 = 0x0040;
pub const PM_QS_SENDMESSAGE: u32 = QS_SENDMESSAGE << 16;
pub const WM_APP: u32 = 0x8000;
pub const HWND_MESSAGE: isize = -3;
pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(.winapi) BOOL;
pub extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;
pub extern "user32" fn MsgWaitForMultipleObjects(nCount: DWORD, pHandles: ?[*]const HANDLE, fWaitAll: BOOL, dwMilliseconds: DWORD, dwWakeMask: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetTickCount() callconv(.winapi) DWORD;
pub const GWLP_WNDPROC: i32 = -4;
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF_0000;
pub const WM_USER: u32 = 0x0400;

pub const GetLastError = zwin.GetLastError;
pub const INVALID_HANDLE_VALUE = zwin.INVALID_HANDLE_VALUE;
pub extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn IsWow64Process2(hProcess: HANDLE, pProcessMachine: *u16, pNativeMachine: ?*u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadProcessMemory(hProcess: HANDLE, lpBaseAddress: usize, lpBuffer: [*]u8, nSize: usize, lpNumberOfBytesRead: ?*usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteProcessMemory(hProcess: HANDLE, lpBaseAddress: usize, lpBuffer: [*]const u8, nSize: usize, lpNumberOfBytesWritten: ?*usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn VirtualAllocEx(hProcess: HANDLE, lpAddress: ?*anyopaque, dwSize: usize, flAllocationType: zwin.MEM.ALLOCATE, flProtect: zwin.PAGE) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn VirtualFreeEx(hProcess: HANDLE, lpAddress: *anyopaque, dwSize: usize, dwFreeType: zwin.MEM.FREE) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateRemoteThread(hProcess: HANDLE, lpThreadAttributes: ?*anyopaque, dwStackSize: usize, lpStartAddress: usize, lpParameter: usize, dwCreationFlags: DWORD, lpThreadId: ?*DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetExitCodeThread(hThread: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
pub extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
pub extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
pub extern "kernel32" fn Module32FirstW(hSnapshot: HANDLE, lpme: *MODULEENTRY32W) callconv(.winapi) BOOL;
pub extern "kernel32" fn Module32NextW(hSnapshot: HANDLE, lpme: *MODULEENTRY32W) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *zwin.STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) callconv(.winapi) BOOL;
pub const STARTUPINFOW = zwin.STARTUPINFOW;
pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};
pub const PROCESS_CREATE_THREAD: DWORD = 0x0002;
pub const PROCESS_SUSPEND_RESUME: DWORD = 0x0800;
/// Counted like `SuspendThread`.
pub extern "ntdll" fn NtSuspendProcess(ProcessHandle: HANDLE) callconv(.winapi) zwin.NTSTATUS;
pub extern "ntdll" fn NtResumeProcess(ProcessHandle: HANDLE) callconv(.winapi) zwin.NTSTATUS;
pub const PROCESS_VM_OPERATION: DWORD = 0x0008;
pub const PROCESS_VM_READ: DWORD = 0x0010;
pub const PROCESS_VM_WRITE: DWORD = 0x0020;
pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
pub const PROCESS_QUERY_INFORMATION: DWORD = 0x0400;
pub extern "kernel32" fn VirtualQueryEx(hProcess: HANDLE, lpAddress: usize, lpBuffer: *MEMORY_BASIC_INFORMATION, dwLength: usize) callconv(.winapi) usize;
pub const MEM_IMAGE: u32 = 0x0100_0000;
/// Gives the NT path, like `\Device\HarddiskVolume3\...`.
pub extern "kernel32" fn K32GetMappedFileNameW(hProcess: HANDLE, lpv: usize, lpFilename: [*]u16, nSize: DWORD) callconv(.winapi) DWORD;
pub const SYNCHRONIZE: DWORD = 0x0010_0000;
pub const READ_CONTROL: DWORD = 0x0002_0000;
pub const WRITE_DAC: DWORD = 0x0004_0000;
pub const SE_KERNEL_OBJECT: c_int = 6;
pub const DACL_SECURITY_INFORMATION: DWORD = 0x4;
pub const GRANT_ACCESS: c_int = 1;
/// Replaces deny entries too.
pub const SET_ACCESS: c_int = 2;
pub const TRUSTEE_IS_NAME: c_int = 1;
pub const TRUSTEE_IS_USER: c_int = 1;
pub const TRUSTEE_W = extern struct {
    pMultipleTrustee: ?*TRUSTEE_W = null,
    MultipleTrusteeOperation: c_int = 0,
    TrusteeForm: c_int,
    TrusteeType: c_int,
    ptstrName: ?*const anyopaque,
};
pub const EXPLICIT_ACCESS_W = extern struct {
    grfAccessPermissions: DWORD,
    grfAccessMode: c_int,
    grfInheritance: DWORD,
    Trustee: TRUSTEE_W,
};
pub extern "advapi32" fn GetSecurityInfo(handle: HANDLE, ObjectType: c_int, SecurityInfo: DWORD, ppsidOwner: ?*?*anyopaque, ppsidGroup: ?*?*anyopaque, ppDacl: ?*?*anyopaque, ppSacl: ?*?*anyopaque, ppSecurityDescriptor: *?*anyopaque) callconv(.winapi) DWORD;
pub extern "advapi32" fn SetSecurityInfo(handle: HANDLE, ObjectType: c_int, SecurityInfo: DWORD, psidOwner: ?*anyopaque, psidGroup: ?*anyopaque, pDacl: ?*anyopaque, pSacl: ?*anyopaque) callconv(.winapi) DWORD;
pub extern "advapi32" fn SetEntriesInAclW(cCountOfExplicitEntries: u32, pListOfExplicitEntries: [*]const EXPLICIT_ACCESS_W, OldAcl: ?*anyopaque, NewAcl: *?*anyopaque) callconv(.winapi) DWORD;
pub extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
pub const CREATE_SUSPENDED: DWORD = 0x0000_0004;
pub const CREATE_NO_WINDOW: DWORD = 0x0800_0000;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 0x102;
pub extern "kernel32" fn WaitForMultipleObjects(nCount: DWORD, lpHandles: [*]const HANDLE, bWaitAll: BOOL, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
pub const STILL_ACTIVE: DWORD = 259;
pub const TH32CS_SNAPPROCESS: DWORD = 0x02;
pub const TH32CS_SNAPMODULE: DWORD = 0x08;
pub const TH32CS_SNAPMODULE32: DWORD = 0x10;
/// NT path with `PROCESS_NAME_NATIVE`.
pub extern "kernel32" fn QueryFullProcessImageNameW(hProcess: HANDLE, dwFlags: DWORD, lpExeName: [*]u16, lpdwSize: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn ProcessIdToSessionId(dwProcessId: DWORD, pSessionId: *DWORD) callconv(.winapi) BOOL;

// Any user can list services, but `EnumDeviceDrivers` gives zeros when not elevated
pub const SC_HANDLE = *opaque {};
pub const SC_MANAGER_ENUMERATE_SERVICE: DWORD = 0x0004;
pub const SC_ENUM_PROCESS_INFO: u32 = 0;
pub const SERVICE_DRIVER: DWORD = 0x0000_000B;
pub const SERVICE_ACTIVE: DWORD = 0x0000_0001;
pub const ERROR_MORE_DATA: DWORD = 234;
pub const SERVICE_STATUS_PROCESS = extern struct {
    dwServiceType: DWORD,
    dwCurrentState: DWORD,
    dwControlsAccepted: DWORD,
    dwWin32ExitCode: DWORD,
    dwServiceSpecificExitCode: DWORD,
    dwCheckPoint: DWORD,
    dwWaitHint: DWORD,
    dwProcessId: DWORD,
    dwServiceFlags: DWORD,
};
pub const ENUM_SERVICE_STATUS_PROCESSW = extern struct {
    lpServiceName: [*:0]const u16,
    lpDisplayName: [*:0]const u16,
    ServiceStatusProcess: SERVICE_STATUS_PROCESS,
};
pub extern "advapi32" fn OpenSCManagerW(lpMachineName: ?[*:0]const u16, lpDatabaseName: ?[*:0]const u16, dwDesiredAccess: DWORD) callconv(.winapi) ?SC_HANDLE;
pub extern "advapi32" fn CloseServiceHandle(hSCObject: SC_HANDLE) callconv(.winapi) BOOL;
pub extern "advapi32" fn EnumServicesStatusExW(
    hSCManager: SC_HANDLE,
    InfoLevel: u32,
    dwServiceType: DWORD,
    dwServiceState: DWORD,
    lpServices: ?[*]u8,
    cbBufSize: DWORD,
    pcbBytesNeeded: *DWORD,
    lpServicesReturned: *DWORD,
    lpResumeHandle: ?*DWORD,
    pszGroupName: ?[*:0]const u16,
) callconv(.winapi) BOOL;
pub const HKEY = *opaque {};
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(0x80000002);
pub const KEY_READ: DWORD = 0x20019;
pub const KEY_WOW64_32KEY: DWORD = 0x0200;
pub const REG_SZ: DWORD = 1;
pub const REG_DWORD: DWORD = 4;
pub const REG_EXPAND_SZ: DWORD = 2;
pub const ERROR_SUCCESS: i32 = 0;
pub const ERROR_NO_MORE_ITEMS: i32 = 259;
pub extern "advapi32" fn RegOpenKeyExW(hKey: HKEY, lpSubKey: [*:0]const u16, ulOptions: DWORD, samDesired: DWORD, phkResult: *?HKEY) callconv(.winapi) i32;
pub extern "advapi32" fn RegQueryValueExW(hKey: HKEY, lpValueName: [*:0]const u16, lpReserved: ?*DWORD, lpType: ?*DWORD, lpData: ?[*]u8, lpcbData: ?*DWORD) callconv(.winapi) i32;
pub extern "advapi32" fn RegEnumKeyExW(hKey: HKEY, dwIndex: DWORD, lpName: [*]u16, lpcchName: *DWORD, lpReserved: ?*DWORD, lpClass: ?[*]u16, lpcchClass: ?*DWORD, lpftLastWriteTime: ?*anyopaque) callconv(.winapi) i32;
pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;
pub const IMAGE_FILE_MACHINE_UNKNOWN: u16 = 0;
pub const IMAGE_FILE_MACHINE_I386: u16 = 0x014C;
pub const IMAGE_FILE_MACHINE_AMD64: u16 = 0x8664;
pub const PROCESSENTRY32W = extern struct {
    dwSize: DWORD = @sizeOf(PROCESSENTRY32W),
    cntUsage: DWORD = 0,
    th32ProcessID: DWORD = 0,
    th32DefaultHeapID: usize = 0,
    th32ModuleID: DWORD = 0,
    cntThreads: DWORD = 0,
    th32ParentProcessID: DWORD = 0,
    pcPriClassBase: i32 = 0,
    dwFlags: DWORD = 0,
    szExeFile: [MAX_PATH]u16 = @splat(0),
};
pub const MODULEENTRY32W = extern struct {
    dwSize: DWORD = @sizeOf(MODULEENTRY32W),
    th32ModuleID: DWORD = 0,
    th32ProcessID: DWORD = 0,
    GlblcntUsage: DWORD = 0,
    ProccntUsage: DWORD = 0,
    modBaseAddr: usize = 0,
    modBaseSize: DWORD = 0,
    hModule: ?*anyopaque = null,
    szModule: [256]u16 = @splat(0),
    szExePath: [MAX_PATH]u16 = @splat(0),
};

pub extern "user32" fn SetCursor(hCursor: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub const HIMC = *opaque {};
pub const COMPOSITIONFORM = extern struct { dwStyle: u32 = 0, ptCurrentPos: POINT = .{}, rcArea: RECT = .{} };
pub const CANDIDATEFORM = extern struct { dwIndex: u32 = 0, dwStyle: u32 = 0, ptCurrentPos: POINT = .{}, rcArea: RECT = .{} };
pub const CFS_FORCE_POSITION: u32 = 0x20;
pub const CFS_EXCLUDE: u32 = 0x80;
pub const IACE_DEFAULT: u32 = 0x10;
pub extern "imm32" fn ImmGetContext(hWnd: HWND) callconv(.winapi) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(hWnd: HWND, hIMC: HIMC) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmAssociateContext(hWnd: HWND, hIMC: ?HIMC) callconv(.winapi) ?HIMC;
pub extern "imm32" fn ImmAssociateContextEx(hWnd: HWND, hIMC: ?HIMC, dwFlags: u32) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmSetCompositionWindow(hIMC: HIMC, lpCompForm: *const COMPOSITIONFORM) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(hIMC: HIMC, lpCandidate: *const CANDIDATEFORM) callconv(.winapi) BOOL;
pub extern "user32" fn GetAsyncKeyState(vKey: i32) callconv(.winapi) i16;
pub extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.winapi) i16;
pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorInfo(pci: *CURSORINFO) callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetKeyboardState(lpKeyState: *[256]u8) callconv(.winapi) BOOL;
pub extern "user32" fn SetKeyboardState(lpKeyState: *const [256]u8) callconv(.winapi) BOOL;
pub extern "user32" fn SetCursorPos(X: i32, Y: i32) callconv(.winapi) BOOL;
pub extern "user32" fn ClipCursor(lpRect: ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetClipCursor(lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetRawInputData(hRawInput: ?*anyopaque, uiCommand: u32, pData: ?*anyopaque, pcbSize: *u32, cbSizeHeader: u32) callconv(.winapi) u32;
pub extern "user32" fn MapVirtualKeyW(uCode: u32, uMapType: u32) callconv(.winapi) u32;
pub const MK_LBUTTON: usize = 0x0001;
pub const MK_RBUTTON: usize = 0x0002;
pub const MK_SHIFT: usize = 0x0004;
pub const MK_CONTROL: usize = 0x0008;
pub const MK_MBUTTON: usize = 0x0010;
pub const MK_XBUTTON1: usize = 0x0020;
pub const MK_XBUTTON2: usize = 0x0040;
pub const CURSORINFO = extern struct {
    cbSize: u32 = @sizeOf(CURSORINFO),
    flags: u32 = 0,
    hCursor: ?*anyopaque = null,
    ptScreenPos: POINT = .{},
};
pub const CURSOR_SHOWING: u32 = 0x1;
pub const WM_SETFOCUS: u32 = 0x0007;
pub const WM_KILLFOCUS: u32 = 0x0008;
pub const WM_SETCURSOR: u32 = 0x0020;
pub const WM_INPUT: u32 = 0x00FF;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_KEYUP: u32 = 0x0101;
pub const WM_CHAR: u32 = 0x0102;
pub const WM_DEADCHAR: u32 = 0x0103;
pub const WM_SYSKEYDOWN: u32 = 0x0104;
pub const WM_SYSKEYUP: u32 = 0x0105;
pub const WM_UNICHAR: u32 = 0x0109;
pub const WM_MOUSEMOVE: u32 = 0x0200;
pub const WM_LBUTTONDOWN: u32 = 0x0201;
pub const WM_LBUTTONUP: u32 = 0x0202;
pub const WM_LBUTTONDBLCLK: u32 = 0x0203;
pub const WM_RBUTTONDOWN: u32 = 0x0204;
pub const WM_RBUTTONUP: u32 = 0x0205;
pub const WM_RBUTTONDBLCLK: u32 = 0x0206;
pub const WM_MBUTTONDOWN: u32 = 0x0207;
pub const WM_MBUTTONUP: u32 = 0x0208;
pub const WM_MBUTTONDBLCLK: u32 = 0x0209;
pub const WM_MOUSEWHEEL: u32 = 0x020A;
pub const WM_XBUTTONDOWN: u32 = 0x020B;
pub const WM_XBUTTONUP: u32 = 0x020C;
pub const WM_XBUTTONDBLCLK: u32 = 0x020D;
pub const WM_MOUSEHWHEEL: u32 = 0x020E;
pub const WM_MOUSELEAVE: u32 = 0x02A3;

pub extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) u16;
pub extern "user32" fn GetClassInfoExW(hInstance: ?HINSTANCE, lpszClass: [*:0]const u16, lpwcx: *WNDCLASSEXW) callconv(.winapi) BOOL;
pub extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: usize) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn LoadImageW(hInst: ?HINSTANCE, name: [*:0]const u16, type: u32, cx: i32, cy: i32, fuLoad: u32) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn DestroyIcon(hIcon: *anyopaque) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetrics(nIndex: i32) callconv(.winapi) i32;
pub const IMAGE_ICON: u32 = 1;
pub const SM_CXICON: i32 = 11;
pub const SM_CYICON: i32 = 12;
pub const SM_CXSMICON: i32 = 49;
pub const SM_CYSMICON: i32 = 50;
pub const WM_GETICON: u32 = 0x007F;
pub const WM_SETICON: u32 = 0x0080;
pub const ICON_SMALL: usize = 0;
pub const ICON_BIG: usize = 1;
pub extern "user32" fn GetCapture() callconv(.winapi) ?HWND;
pub extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn TrackMouseEvent(lpEventTrack: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn ClientToScreen(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn WindowFromPoint(Point: POINT) callconv(.winapi) ?HWND;
pub extern "user32" fn IsChild(hWndParent: HWND, hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsIconic(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindowAsync(hWnd: HWND, nCmdShow: i32) callconv(.winapi) BOOL;
pub extern "user32" fn AdjustWindowRectEx(lpRect: *RECT, dwStyle: DWORD, bMenu: BOOL, dwExStyle: DWORD) callconv(.winapi) BOOL;
pub extern "user32" fn BringWindowToTop(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn AttachThreadInput(idAttach: DWORD, idAttachTo: DWORD, fAttach: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn SendMessageTimeoutW(hWnd: HWND, msg: u32, wParam: usize, lParam: isize, fuFlags: u32, uTimeout: u32, lpdwResult: ?*usize) callconv(.winapi) isize;
pub const SMTO_BLOCK: u32 = 0x1;
pub const SMTO_ABORTIFHUNG: u32 = 0x2;
pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetFocus(hWnd: ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, crKey: u32, bAlpha: u8, dwFlags: u32) callconv(.winapi) BOOL;
pub extern "user32" fn EnumDisplayMonitors(hdc: ?*anyopaque, lprcClip: ?*const RECT, lpfnEnum: *const MONITORENUMPROC, dwData: isize) callconv(.winapi) BOOL;
pub extern "user32" fn GetMonitorInfoW(hMonitor: HMONITOR, lpmi: *MONITORINFO) callconv(.winapi) BOOL;
pub extern "shcore" fn GetDpiForMonitor(hmonitor: HMONITOR, dpiType: u32, dpiX: *u32, dpiY: *u32) callconv(.winapi) i32;
pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub const WNDPROC = fn (hWnd: HWND, msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize;
pub const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: *const WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};
pub const TRACKMOUSEEVENT = extern struct {
    cbSize: u32 = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: u32 = 0,
    hwndTrack: ?HWND = null,
    dwHoverTime: u32 = 0,
};
pub const HMONITOR = *anyopaque;
pub const MONITORENUMPROC = fn (monitor: HMONITOR, hdc: ?*anyopaque, rect: ?*RECT, data: isize) callconv(.winapi) BOOL;
pub const MONITORINFO = extern struct {
    cbSize: u32 = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: u32 = 0,
};
pub const MONITORINFOF_PRIMARY: u32 = 0x1;
pub const MDT_EFFECTIVE_DPI: u32 = 0;
pub const ERROR_CLASS_ALREADY_EXISTS: u32 = 1410;
pub const GWL_STYLE: i32 = -16;
pub const GWL_EXSTYLE: i32 = -20;
pub const GWLP_USERDATA: i32 = -21;
pub const GWLP_HWNDPARENT: i32 = -8;
pub const WS_POPUP: DWORD = 0x8000_0000;
pub const WS_EX_TOPMOST: DWORD = 0x0000_0008;
pub const WS_EX_TOOLWINDOW: DWORD = 0x0000_0080;
pub const WS_EX_APPWINDOW: DWORD = 0x0004_0000;
pub const WS_EX_LAYERED: DWORD = 0x0008_0000;
pub const CS_HREDRAW: u32 = 0x0002;
pub const CS_OWNDC: u32 = 0x0020;
pub const CS_VREDRAW: u32 = 0x0001;
pub const SW_HIDE: i32 = 0;
pub const SW_SHOW: i32 = 5;
pub extern "shell32" fn ShellExecuteW(hwnd: ?HWND, lpOperation: ?[*:0]const u16, lpFile: [*:0]const u16, lpParameters: ?[*:0]const u16, lpDirectory: ?[*:0]const u16, nShowCmd: i32) callconv(.winapi) usize;
pub const SW_SHOWNA: i32 = 8;
pub const SWP_FRAMECHANGED: u32 = 0x0020;
/// HWND_TOP (0) is a null ?HWND.
pub const HWND_TOP: isize = 0;
pub const HWND_TOPMOST: isize = -1;
pub const HWND_NOTOPMOST: isize = -2;
pub const LWA_ALPHA: u32 = 0x2;
pub const TME_LEAVE: u32 = 0x2;
pub const HTTRANSPARENT: isize = -1;
pub const HTCLIENT: isize = 1;
pub const MA_NOACTIVATE: isize = 3;
/// Skips sent messages, which would run other windows' procs.
pub const PM_QS_INPUT: u32 = 0x0407 << 16;
pub const PM_QS_POSTMESSAGE: u32 = (0x0008 | 0x0080 | 0x0010) << 16;
pub const PM_QS_PAINT: u32 = 0x0020 << 16;
pub const IDC_ARROW: usize = 32512;
pub const IDC_IBEAM: usize = 32513;
pub const IDC_WAIT: usize = 32514;
pub const IDC_SIZENWSE: usize = 32642;
pub const IDC_SIZENESW: usize = 32643;
pub const IDC_SIZEWE: usize = 32644;
pub const IDC_SIZENS: usize = 32645;
pub const IDC_SIZEALL: usize = 32646;
pub const IDC_NO: usize = 32648;
pub const IDC_HAND: usize = 32649;
pub const IDC_APPSTARTING: usize = 32650;
pub const WM_DESTROY: u32 = 0x0002;
pub const WM_MOVE: u32 = 0x0003;
pub const WM_SIZE: u32 = 0x0005;
pub const WM_CLOSE: u32 = 0x0010;
pub const WM_MOUSEACTIVATE: u32 = 0x0021;
pub const WM_DISPLAYCHANGE: u32 = 0x007E;
pub const WM_NCHITTEST: u32 = 0x0084;
pub const WM_DPICHANGED: u32 = 0x02E0;
pub extern "user32" fn UnregisterClassW(lpClassName: [*:0]const u16, hInstance: ?HINSTANCE) callconv(.winapi) BOOL;
pub const WM_SYSCOMMAND: u32 = 0x0112;
/// Alt or F10 opening the window menu.
pub const SC_KEYMENU: usize = 0xF100;
pub const SC_CLOSE: usize = 0xF060;
pub const VK_F4: usize = 0x73;
pub const SW_RESTORE: i32 = 9;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x8000_0000));
/// Windows 10 1607+, look it up with `lazyFn`.
pub const SetThreadDpiAwarenessContextFn = fn (dpiContext: isize) callconv(.winapi) isize;
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
/// Waits for the compositor's next frame. Look it up with `lazyFn`.
pub const DwmFlushFn = fn () callconv(.winapi) i32;

pub extern "kernel32" fn AllocConsole() callconv(.winapi) BOOL;
pub extern "kernel32" fn AttachConsole(dwProcessId: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetStdHandle(nStdHandle: STD_HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleTitleA(lpConsoleTitle: [*:0]const u8) callconv(.winapi) BOOL;
pub const ATTACH_PARENT_PROCESS: DWORD = 0xFFFFFFFF;
pub const STD_HANDLE = enum(i32) {
    INPUT_HANDLE = -10,
    OUTPUT_HANDLE = -11,
    ERROR_HANDLE = -12,
};
pub const CONSOLE_INPUT_MODE = bitpack struct(DWORD) {
    ENABLE_PROCESSED_INPUT: bool = false,
    ENABLE_LINE_INPUT: bool = false,
    ENABLE_ECHO_INPUT: bool = false,
    ENABLE_WINDOW_INPUT: bool = false,
    ENABLE_MOUSE_INPUT: bool = false,
    ENABLE_INSERT_MODE: bool = false,
    ENABLE_QUICK_EDIT_MODE: bool = false,
    ENABLE_EXTENDED_FLAGS: bool = false,
    ENABLE_AUTO_POSITION: bool = false,
    ENABLE_VIRTUAL_TERMINAL_INPUT: bool = false,
    _pad: u22 = 0,
};
pub const CONSOLE_OUTPUT_MODE = bitpack struct(DWORD) {
    ENABLE_PROCESSED_OUTPUT: bool = false,
    ENABLE_WRAP_AT_EOL_OUTPUT: bool = false,
    ENABLE_VIRTUAL_TERMINAL_PROCESSING: bool = false,
    DISABLE_NEWLINE_AUTO_RETURN: bool = false,
    ENABLE_LVB_GRID_WORLDWIDE: bool = false,
    _pad: u27 = 0,
};
pub extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn SetEnvironmentVariableW(lpName: [*:0]const u16, lpValue: ?[*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetTempPathW(nBufferLength: DWORD, lpBuffer: *u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetLogicalDrives() callconv(.winapi) DWORD;
pub const DRIVE_FIXED: u32 = 3;
pub extern "kernel32" fn GetDriveTypeW(lpRootPathName: [*:0]const u16) callconv(.winapi) u32;
pub extern "user32" fn IsWindow(hWnd: ?HWND) callconv(.winapi) BOOL;
pub const PROCESS_MEMORY_COUNTERS_EX = extern struct {
    cb: DWORD = @sizeOf(PROCESS_MEMORY_COUNTERS_EX),
    PageFaultCount: DWORD = 0,
    PeakWorkingSetSize: usize = 0,
    WorkingSetSize: usize = 0,
    QuotaPeakPagedPoolUsage: usize = 0,
    QuotaPagedPoolUsage: usize = 0,
    QuotaPeakNonPagedPoolUsage: usize = 0,
    QuotaNonPagedPoolUsage: usize = 0,
    PagefileUsage: usize = 0,
    PeakPagefileUsage: usize = 0,
    PrivateUsage: usize = 0,
};
pub extern "kernel32" fn K32GetProcessMemoryInfo(Process: HANDLE, ppsmemCounters: *PROCESS_MEMORY_COUNTERS_EX, cb: DWORD) callconv(.winapi) BOOL;
pub const VS_FIXEDFILEINFO = extern struct {
    dwSignature: DWORD,
    dwStrucVersion: DWORD,
    dwFileVersionMS: DWORD,
    dwFileVersionLS: DWORD,
    dwProductVersionMS: DWORD,
    dwProductVersionLS: DWORD,
    dwFileFlagsMask: DWORD,
    dwFileFlags: DWORD,
    dwFileOS: DWORD,
    dwFileType: DWORD,
    dwFileSubtype: DWORD,
    dwFileDateMS: DWORD,
    dwFileDateLS: DWORD,
};
pub const VS_FFI_SIGNATURE: DWORD = 0xFEEF04BD;
pub extern "version" fn GetFileVersionInfoSizeW(lptstrFilename: [*:0]const u16, lpdwHandle: ?*DWORD) callconv(.winapi) DWORD;
pub extern "version" fn GetFileVersionInfoW(lptstrFilename: [*:0]const u16, dwHandle: DWORD, dwLen: DWORD, lpData: *anyopaque) callconv(.winapi) BOOL;
pub extern "version" fn VerQueryValueW(pBlock: *const anyopaque, lpSubBlock: [*:0]const u16, lplpBuffer: *?*anyopaque, puLen: *u32) callconv(.winapi) BOOL;

pub const WNDENUMPROC = fn (hWnd: HWND, lParam: isize) callconv(.winapi) BOOL;
pub extern "user32" fn EnumWindows(lpEnumFunc: *const WNDENUMPROC, lParam: isize) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindow(hWnd: HWND, uCmd: u32) callconv(.winapi) ?HWND;
pub const GW_OWNER: u32 = 4;
pub const HDC = *anyopaque;
pub extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) i32;
pub extern "user32" fn WindowFromDC(hDC: HDC) callconv(.winapi) ?HWND;

pub extern "user32" fn MonitorFromWindow(hwnd: HWND, dwFlags: u32) callconv(.winapi) ?HMONITOR;
pub const MONITOR_DEFAULTTONEAREST: u32 = 0x2;
/// `GetMonitorInfoW` fills the name if `cbSize` asks for it.
pub const MONITORINFOEXW = extern struct {
    cbSize: u32 = @sizeOf(MONITORINFOEXW),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: u32 = 0,
    szDevice: [32]u16 = @splat(0),
};

pub const LUID = extern struct { LowPart: u32 = 0, HighPart: i32 = 0 };
pub const DISPLAYCONFIG_PATH_SOURCE_INFO = extern struct { adapterId: LUID, id: u32, modeInfoIdx: u32, statusFlags: u32 };
pub const DISPLAYCONFIG_PATH_TARGET_INFO = extern struct {
    adapterId: LUID,
    id: u32,
    modeInfoIdx: u32,
    outputTechnology: u32,
    rotation: u32,
    scaling: u32,
    refreshRate: extern struct { Numerator: u32, Denominator: u32 },
    scanLineOrdering: u32,
    targetAvailable: BOOL,
    statusFlags: u32,
};
pub const DISPLAYCONFIG_PATH_INFO = extern struct { sourceInfo: DISPLAYCONFIG_PATH_SOURCE_INFO, targetInfo: DISPLAYCONFIG_PATH_TARGET_INFO, flags: u32 };
/// Just the size, nothing reads the modes.
pub const DISPLAYCONFIG_MODE_INFO = extern struct { bytes: [64]u8 align(8) };
pub const DISPLAYCONFIG_DEVICE_INFO_HEADER = extern struct { type: u32, size: u32, adapterId: LUID, id: u32 };
pub const DISPLAYCONFIG_SOURCE_DEVICE_NAME = extern struct { header: DISPLAYCONFIG_DEVICE_INFO_HEADER, viewGdiDeviceName: [32]u16 = @splat(0) };
pub const DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO = extern struct { header: DISPLAYCONFIG_DEVICE_INFO_HEADER, value: u32 = 0, colorEncoding: u32 = 0, bitsPerColorChannel: u32 = 0 };
pub const DISPLAYCONFIG_SDR_WHITE_LEVEL = extern struct { header: DISPLAYCONFIG_DEVICE_INFO_HEADER, SDRWhiteLevel: u32 = 0 };
pub const QDC_ONLY_ACTIVE_PATHS: u32 = 0x2;
pub const DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME: u32 = 1;
pub const DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO: u32 = 9;
pub const DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL: u32 = 11;
pub extern "user32" fn GetDisplayConfigBufferSizes(flags: u32, numPathArrayElements: *u32, numModeInfoArrayElements: *u32) callconv(.winapi) i32;
pub extern "user32" fn QueryDisplayConfig(flags: u32, numPathArrayElements: *u32, pathArray: [*]DISPLAYCONFIG_PATH_INFO, numModeInfoArrayElements: *u32, modeInfoArray: [*]DISPLAYCONFIG_MODE_INFO, currentTopologyId: ?*u32) callconv(.winapi) i32;
pub extern "user32" fn DisplayConfigGetDeviceInfo(requestPacket: *DISPLAYCONFIG_DEVICE_INFO_HEADER) callconv(.winapi) i32;

pub const SYSTEM_INFO = extern struct {
    wProcessorArchitecture: u16 = 0,
    wReserved: u16 = 0,
    dwPageSize: u32 = 0,
    lpMinimumApplicationAddress: usize = 0,
    /// Inclusive.
    lpMaximumApplicationAddress: usize = 0,
    dwActiveProcessorMask: usize = 0,
    dwNumberOfProcessors: u32 = 0,
    dwProcessorType: u32 = 0,
    dwAllocationGranularity: u32 = 0,
    wProcessorLevel: u16 = 0,
    wProcessorRevision: u16 = 0,
};
pub extern "kernel32" fn GetSystemInfo(lpSystemInfo: *SYSTEM_INFO) callconv(.winapi) void;
