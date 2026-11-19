//! ntdll file calls and the structs they fill. Only what the VFS uses.

const std = @import("std");
const zwin = std.os.windows;

pub const NTSTATUS = zwin.NTSTATUS;
pub const HANDLE = zwin.HANDLE;
pub const BOOL = zwin.BOOL;
pub const IO_STATUS_BLOCK = zwin.IO_STATUS_BLOCK;

pub const UNICODE_STRING = extern struct {
    /// In bytes.
    Length: u16,
    MaximumLength: u16,
    Buffer: ?[*]u16,

    pub fn slice(self: *const UNICODE_STRING) []const u16 {
        const b = self.Buffer orelse return &.{};
        return b[0 .. self.Length / 2];
    }

    pub fn from(chars: []u16) UNICODE_STRING {
        const len: u16 = @intCast(chars.len * 2);
        return .{ .Length = len, .MaximumLength = len, .Buffer = chars.ptr };
    }
};

pub const OBJECT_ATTRIBUTES = extern struct {
    Length: u32,
    RootDirectory: ?HANDLE,
    ObjectName: ?*UNICODE_STRING,
    Attributes: u32,
    SecurityDescriptor: ?*anyopaque,
    SecurityQualityOfService: ?*anyopaque,
};

pub const IO_APC_ROUTINE = fn (ApcContext: ?*anyopaque, IoStatusBlock: *IO_STATUS_BLOCK, Reserved: u32) callconv(.winapi) void;
pub const PS_APC_ROUTINE = fn (a: ?*anyopaque, b: ?*anyopaque, c: ?*anyopaque) callconv(.winapi) void;

pub const NtCreateFileFn = fn (FileHandle: *HANDLE, DesiredAccess: u32, ObjectAttributes: *OBJECT_ATTRIBUTES, IoStatusBlock: *IO_STATUS_BLOCK, AllocationSize: ?*i64, FileAttributes: u32, ShareAccess: u32, CreateDisposition: u32, CreateOptions: u32, EaBuffer: ?*anyopaque, EaLength: u32) callconv(.winapi) NTSTATUS;
pub const NtOpenFileFn = fn (FileHandle: *HANDLE, DesiredAccess: u32, ObjectAttributes: *OBJECT_ATTRIBUTES, IoStatusBlock: *IO_STATUS_BLOCK, ShareAccess: u32, OpenOptions: u32) callconv(.winapi) NTSTATUS;
pub const NtReadFileFn = fn (FileHandle: HANDLE, Event: ?HANDLE, ApcRoutine: ?*const IO_APC_ROUTINE, ApcContext: ?*anyopaque, IoStatusBlock: *IO_STATUS_BLOCK, Buffer: [*]u8, Length: u32, ByteOffset: ?*const i64, Key: ?*const u32) callconv(.winapi) NTSTATUS;
pub const NtWriteFileFn = fn (FileHandle: HANDLE, Event: ?HANDLE, ApcRoutine: ?*const IO_APC_ROUTINE, ApcContext: ?*anyopaque, IoStatusBlock: *IO_STATUS_BLOCK, Buffer: [*]const u8, Length: u32, ByteOffset: ?*const i64, Key: ?*const u32) callconv(.winapi) NTSTATUS;
pub const NtCloseFn = fn (Handle: HANDLE) callconv(.winapi) NTSTATUS;
pub const NtQueryInformationFileFn = fn (FileHandle: HANDLE, IoStatusBlock: *IO_STATUS_BLOCK, FileInformation: [*]u8, Length: u32, FileInformationClass: u32) callconv(.winapi) NTSTATUS;
pub const NtSetInformationFileFn = fn (FileHandle: HANDLE, IoStatusBlock: *IO_STATUS_BLOCK, FileInformation: [*]const u8, Length: u32, FileInformationClass: u32) callconv(.winapi) NTSTATUS;
pub const NtQueryVolumeInformationFileFn = fn (FileHandle: HANDLE, IoStatusBlock: *IO_STATUS_BLOCK, FsInformation: [*]u8, Length: u32, FsInformationClass: u32) callconv(.winapi) NTSTATUS;
pub const NtQueryDirectoryFileFn = fn (FileHandle: HANDLE, Event: ?HANDLE, ApcRoutine: ?*const IO_APC_ROUTINE, ApcContext: ?*anyopaque, IoStatusBlock: *IO_STATUS_BLOCK, FileInformation: [*]u8, Length: u32, FileInformationClass: u32, ReturnSingleEntry: u8, FileName: ?*UNICODE_STRING, RestartScan: u8) callconv(.winapi) NTSTATUS;
pub const NtQueryDirectoryFileExFn = fn (FileHandle: HANDLE, Event: ?HANDLE, ApcRoutine: ?*const IO_APC_ROUTINE, ApcContext: ?*anyopaque, IoStatusBlock: *IO_STATUS_BLOCK, FileInformation: [*]u8, Length: u32, FileInformationClass: u32, QueryFlags: u32, FileName: ?*UNICODE_STRING) callconv(.winapi) NTSTATUS;
pub const NtQueryAttributesFileFn = fn (ObjectAttributes: *OBJECT_ATTRIBUTES, FileInformation: *FILE_BASIC_INFORMATION) callconv(.winapi) NTSTATUS;
pub const NtQueryFullAttributesFileFn = fn (ObjectAttributes: *OBJECT_ATTRIBUTES, FileInformation: *FILE_NETWORK_OPEN_INFORMATION) callconv(.winapi) NTSTATUS;
pub const NtDeleteFileFn = fn (ObjectAttributes: *OBJECT_ATTRIBUTES) callconv(.winapi) NTSTATUS;
pub const NtFlushBuffersFileFn = fn (FileHandle: HANDLE, IoStatusBlock: *IO_STATUS_BLOCK) callconv(.winapi) NTSTATUS;
pub const NtCreateSectionFn = fn (SectionHandle: *HANDLE, DesiredAccess: u32, ObjectAttributes: ?*OBJECT_ATTRIBUTES, MaximumSize: ?*i64, SectionPageProtection: u32, AllocationAttributes: u32, FileHandle: ?HANDLE) callconv(.winapi) NTSTATUS;
pub const NtDuplicateObjectFn = fn (SourceProcessHandle: HANDLE, SourceHandle: HANDLE, TargetProcessHandle: ?HANDLE, TargetHandle: ?*HANDLE, DesiredAccess: u32, HandleAttributes: u32, Options: u32) callconv(.winapi) NTSTATUS;

pub extern "ntdll" fn NtQueryObject(Handle: ?HANDLE, ObjectInformationClass: u32, ObjectInformation: ?*anyopaque, ObjectInformationLength: u32, ReturnLength: ?*u32) callconv(.winapi) NTSTATUS;
pub extern "ntdll" fn NtSetIoCompletion(IoCompletionHandle: HANDLE, KeyContext: usize, ApcContext: ?*anyopaque, IoStatus: NTSTATUS, IoStatusInformation: usize) callconv(.winapi) NTSTATUS;
pub extern "ntdll" fn NtQueueApcThread(ThreadHandle: HANDLE, ApcRoutine: *const PS_APC_ROUTINE, ApcArgument1: ?*anyopaque, ApcArgument2: ?*anyopaque, ApcArgument3: ?*anyopaque) callconv(.winapi) NTSTATUS;
pub extern "ntdll" fn RtlIsNameInExpression(Expression: *const UNICODE_STRING, Name: *const UNICODE_STRING, IgnoreCase: u8, UpcaseTable: ?[*]const u16) callconv(.winapi) u8;
pub extern "ntdll" fn RtlUpcaseUnicodeChar(SourceCharacter: u16) callconv(.winapi) u16;
pub extern "ntdll" fn RtlIsCriticalSectionLockedByThread(CriticalSection: *anyopaque) callconv(.winapi) u32;
pub extern "kernel32" fn CreateEventW(lpEventAttributes: ?*anyopaque, bManualReset: BOOL, bInitialState: BOOL, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn MapViewOfFile(hFileMappingObject: HANDLE, dwDesiredAccess: u32, dwFileOffsetHigh: u32, dwFileOffsetLow: u32, dwNumberOfBytesToMap: usize) callconv(.winapi) ?[*]u8;
pub extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: *const anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *i64) callconv(.winapi) void;
pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
pub extern "kernel32" fn GetLogicalDrives() callconv(.winapi) u32;
pub extern "kernel32" fn QueryDosDeviceW(lpDeviceName: ?[*:0]const u16, lpTargetPath: [*]u16, ucchMax: u32) callconv(.winapi) u32;

pub const current_process: HANDLE = @ptrFromInt(std.math.maxInt(usize));
pub const current_thread: HANDLE = @ptrFromInt(std.math.maxInt(usize) - 1);

pub fn ok(s: NTSTATUS) bool {
    return @backingInt(s) < 0x80000000;
}

pub fn status(code: u32) NTSTATUS {
    return @fromBackingInt(@intCast(code));
}

// Statuses std doesn't name, or names differently
pub const STATUS_NOT_A_DIRECTORY = status(0xC0000103);
pub const STATUS_FILE_IS_A_DIRECTORY = status(0xC00000BA);
pub const STATUS_OBJECT_PATH_NOT_FOUND = status(0xC000003A);
pub const STATUS_NO_SUCH_FILE = status(0xC000000F);
pub const STATUS_INVALID_DEVICE_REQUEST = status(0xC0000010);
pub const STATUS_INSUFFICIENT_RESOURCES = status(0xC000009A);
pub const STATUS_SHARING_VIOLATION = status(0xC0000043);
pub const STATUS_MEDIA_WRITE_PROTECTED = status(0xC00000A2);
pub const STATUS_INVALID_IMAGE_FORMAT = status(0xC000007B);
pub const STATUS_MAPPED_FILE_SIZE_ZERO = status(0xC000011E);
pub const STATUS_HANDLE_NOT_CLOSABLE = status(0xC0000235);
pub const STATUS_DIRECTORY_NOT_EMPTY = status(0xC0000101);

// Access
pub const FILE_READ_DATA: u32 = 0x1;
pub const FILE_WRITE_DATA: u32 = 0x2;
pub const FILE_APPEND_DATA: u32 = 0x4;
pub const FILE_EXECUTE: u32 = 0x20;
pub const DELETE: u32 = 0x10000;
pub const MAXIMUM_ALLOWED: u32 = 0x02000000;
pub const GENERIC_ALL: u32 = 0x10000000;
pub const GENERIC_EXECUTE: u32 = 0x20000000;
pub const GENERIC_WRITE: u32 = 0x40000000;
pub const GENERIC_READ: u32 = 0x80000000;

// Create options
pub const FILE_DIRECTORY_FILE: u32 = 0x1;
pub const FILE_SYNCHRONOUS_IO_ALERT: u32 = 0x10;
pub const FILE_SYNCHRONOUS_IO_NONALERT: u32 = 0x20;
pub const FILE_NON_DIRECTORY_FILE: u32 = 0x40;
pub const FILE_DELETE_ON_CLOSE: u32 = 0x1000;
pub const FILE_OPEN_BY_FILE_ID: u32 = 0x2000;

// What an open did, in `Information`
pub const FILE_SUPERSEDED: usize = 0;
pub const FILE_OPENED: usize = 1;
pub const FILE_CREATED: usize = 2;
pub const FILE_OVERWRITTEN: usize = 3;

pub const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
pub const FILE_ATTRIBUTE_ARCHIVE: u32 = 0x20;

pub const DUPLICATE_CLOSE_SOURCE: u32 = 0x1;
pub const SEC_IMAGE: u32 = 0x1000000;
pub const SEC_COMMIT: u32 = 0x8000000;
pub const SECTION_ALL_ACCESS: u32 = 0xF001F;
pub const FILE_MAP_WRITE: u32 = 0x2;
pub const PAGE_READWRITE: u32 = 0x04;
pub const PAGE_EXECUTE_READWRITE: u32 = 0x40;
pub const FILE_DEVICE_DISK: u32 = 0x7;

pub const SL_RESTART_SCAN: u32 = 0x1;
pub const SL_RETURN_SINGLE_ENTRY: u32 = 0x2;

/// `FILE_USE_FILE_POINTER_POSITION` as a byte offset.
pub const use_position: i64 = -2;
/// `FILE_WRITE_TO_END_OF_FILE` as a byte offset.
pub const write_to_end: i64 = -1;

pub const FILE_BASIC_INFORMATION = extern struct {
    CreationTime: i64,
    LastAccessTime: i64,
    LastWriteTime: i64,
    ChangeTime: i64,
    FileAttributes: u32,
};

pub const FILE_STANDARD_INFORMATION = extern struct {
    AllocationSize: i64,
    EndOfFile: i64,
    NumberOfLinks: u32,
    DeletePending: u8,
    Directory: u8,
};

pub const FILE_NETWORK_OPEN_INFORMATION = extern struct {
    CreationTime: i64,
    LastAccessTime: i64,
    LastWriteTime: i64,
    ChangeTime: i64,
    AllocationSize: i64,
    EndOfFile: i64,
    FileAttributes: u32,
};

pub const FILE_RENAME_INFORMATION = extern struct {
    /// `ReplaceIfExists` in its low byte for the old class.
    Flags: u32,
    RootDirectory: ?HANDLE,
    FileNameLength: u32,
    FileName: [1]u16,
};

pub const FILE_COMPLETION_INFORMATION = extern struct {
    Port: ?HANDLE,
    Key: usize,
};

pub const FileInfoClass = struct {
    pub const basic = 4;
    pub const standard = 5;
    pub const internal = 6;
    pub const ea = 7;
    pub const access = 8;
    pub const name = 9;
    pub const rename = 10;
    pub const disposition = 13;
    pub const position = 14;
    pub const mode = 16;
    pub const alignment = 17;
    pub const all = 18;
    pub const allocation = 19;
    pub const end_of_file = 20;
    pub const completion = 30;
    pub const network_open = 34;
    pub const attribute_tag = 35;
    pub const io_completion_notification = 41;
    pub const normalized_name = 48;
    pub const id = 59;
    pub const disposition_ex = 64;
    pub const rename_ex = 65;
};

pub const FsInfoClass = struct {
    pub const volume = 1;
    pub const size = 3;
    pub const device = 4;
    pub const attribute = 5;
    pub const full_size = 7;
};

pub const FILE_SKIP_COMPLETION_PORT_ON_SUCCESS: u32 = 0x1;
pub const FILE_DISPOSITION_DELETE: u32 = 0x1;
pub const FILE_DISPOSITION_POSIX_SEMANTICS: u32 = 0x2;
pub const FILE_RENAME_REPLACE_IF_EXISTS: u32 = 0x1;
pub const ObjectNameInformation: u32 = 1;
