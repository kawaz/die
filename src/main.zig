// die — write a message to stderr and exit 1.
//
// Spec: see ../../docs/DESIGN.md (and DR-0001 / DR-0002 / DR-0005 / DR-0008).
//
// Uses raw POSIX extern calls for I/O to bypass Zig 0.16.0's new async Io API.
// Uses std.process.Init.Minimal for argv access (Zig 0.16.0 new main signature).

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const process = std.process;

// Embed build.zig.zon's .version at compile time so `die --version` always
// reflects the canonical version source (single source of truth at repo root).
// The "zon" module is wired in build.zig (root_module.addAnonymousImport).
const VERSION: []const u8 = @import("zon").version;

// ---- POSIX extern declarations -------------------------------------------

extern fn write(fd: i32, buf: [*]const u8, count: usize) isize;
extern fn read(fd: i32, buf: [*]u8, count: usize) isize;
extern fn malloc(size: usize) ?*anyopaque;
extern fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;

// POSIX isatty(3): wraps ioctl(TCGETS) or ioctl(TIOCGETA). Returns nonzero if
// fd is a terminal. Linked from libc on POSIX targets only.
const posix_isatty = if (builtin.target.os.tag != .windows)
    struct {
        extern fn isatty(fd: i32) c_int;
    }.isatty
else {};

// ---- Windows _setmode for binary / cat-equivalent output under -n --------
//
// On Windows, MSVCRT's _write() performs text-mode LF→CRLF conversion.
// When -n is in effect (cat-equivalent, byte-transparent), we must suppress
// this for both stdin (fd 0) and stderr (fd 2).
// _O_BINARY = 0x8000 (MSVCRT constant).
//
// The extern declaration and call are fully compile-time gated so there is
// zero overhead and no linker reference on POSIX.

fn setModeBinary() void {
    if (comptime builtin.target.os.tag == .windows) {
        const _O_BINARY: c_int = 0x8000;
        const _setmode = struct {
            extern fn _setmode(fd: c_int, mode: c_int) c_int;
        }._setmode;
        _ = _setmode(STDIN, _O_BINARY);
        _ = _setmode(STDERR, _O_BINARY);
    }
}

const STDIN: i32 = 0;
const STDOUT: i32 = 1;
const STDERR: i32 = 2;

// ---- stdin TTY detection (DR-0008) ---------------------------------------
//
// Returns true if STDIN is connected to a real terminal.
//
// POSIX: standard isatty(3), which internally calls ioctl(fd, TCGETS) on
// Linux or TIOCGETA on BSD/macOS. /dev/null, regular files, pipes, and
// sockets all correctly return false.
//
// Windows: GetConsoleMode() on the underlying HANDLE; succeeds only for
// real console handles (cmd.exe / PowerShell / Windows Terminal).
// Critically, this returns false for the NUL device, unlike MSVCRT
// _isatty() which lies and reports NUL as a TTY (a long-standing MSVCRT
// design choice — every FILE_TYPE_CHAR is treated as terminal). Cygwin /
// MSYS2 / Git Bash pty implementations are named pipes with a specific
// naming pattern (\msys-…-ptyN-{from,to}-master / \cygwin-…-ptyN-…); we
// match that pattern via NtQueryObject to classify them as TTY too, so
// `die` typed bare at a Git Bash prompt shows help rather than waiting
// for Ctrl-D on stdin.
//
// See docs/findings/2026-06-28-tty-detection-cross-os.md for background.
fn isStdinTty() bool {
    if (comptime builtin.target.os.tag == .windows) {
        return windowsIsTty(STDIN) or windowsIsCygwinTty(STDIN);
    } else {
        return posix_isatty(STDIN) != 0;
    }
}

// Windows: map POSIX fd (0/1/2) to STD_INPUT/OUTPUT/ERROR_HANDLE constants.
// Returns null for any other fd (Windows GetStdHandle has no concept of
// arbitrary fd numbers). Shared between windowsIsTty and windowsIsCygwinTty.
fn stdHandleId(fd: i32) ?u32 {
    return switch (fd) {
        0 => @bitCast(@as(i32, -10)), // STD_INPUT_HANDLE
        1 => @bitCast(@as(i32, -11)), // STD_OUTPUT_HANDLE
        2 => @bitCast(@as(i32, -12)), // STD_ERROR_HANDLE
        else => null,
    };
}

// Windows: native console detection.
fn windowsIsTty(fd: i32) bool {
    if (comptime builtin.target.os.tag != .windows) return false;
    const W = struct {
        const HANDLE = *anyopaque;
        const DWORD = u32;
        const BOOL = c_int;
        extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.c) HANDLE;
        extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.c) BOOL;
    };
    const id = stdHandleId(fd) orelse return false;
    const h = W.GetStdHandle(id);
    var mode: W.DWORD = 0;
    return W.GetConsoleMode(h, &mode) != 0;
}

// Windows: Cygwin / MSYS2 pty detection. Cygwin ptys are named pipes whose
// name matches `\{cygwin,msys}-XXXX-ptyN-{from,to}-master[-suffix]`. We
// query the handle's name via NtQueryObject (ntdll) and pattern-match.
// Modelled after mattn/go-isatty's IsCygwinTerminal.
fn windowsIsCygwinTty(fd: i32) bool {
    if (comptime builtin.target.os.tag != .windows) return false;
    const W = struct {
        const HANDLE = *anyopaque;
        const DWORD = u32;
        const NTSTATUS = i32;
        const ULONG = u32;
        const FILE_TYPE_PIPE: DWORD = 0x0003;
        extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.c) HANDLE;
        extern "kernel32" fn GetFileType(hFile: HANDLE) callconv(.c) DWORD;
        // NtQueryObject(Handle, ObjectInformationClass, ObjectInformation,
        //   ObjectInformationLength, ReturnLength)
        // ObjectNameInformation = 1
        extern "ntdll" fn NtQueryObject(
            Handle: HANDLE,
            ObjectInformationClass: u32,
            ObjectInformation: ?*anyopaque,
            ObjectInformationLength: ULONG,
            ReturnLength: ?*ULONG,
        ) callconv(.c) NTSTATUS;
    };
    const id = stdHandleId(fd) orelse return false;
    const h = W.GetStdHandle(id);
    if (W.GetFileType(h) != W.FILE_TYPE_PIPE) return false;

    // OBJECT_NAME_INFORMATION layout:
    //   UNICODE_STRING Name;   // 16 bytes on x64 (USHORT Length, USHORT Max, PWSTR Buffer)
    //   WCHAR NameBuffer[];    // follows inline
    // We over-allocate a single byte buffer and reinterpret.
    var buf: [4096]u8 align(@alignOf(usize)) = undefined;
    var ret_len: u32 = 0;
    const status = W.NtQueryObject(h, 1, &buf, buf.len, &ret_len);
    if (status < 0) return false;

    // Decode UNICODE_STRING.Length (USHORT, bytes) and Buffer (PWSTR).
    const length_bytes: u16 = std.mem.readInt(u16, buf[0..2], .little);
    if (length_bytes == 0) return false;
    // Buffer pointer is at offset 8 on x64, 4 on x86. Use sizeof.
    const ptr_offset: usize = @sizeOf(usize);
    const buf_ptr_raw: usize = std.mem.readInt(usize, buf[ptr_offset..][0..@sizeOf(usize)], .little);
    if (buf_ptr_raw == 0) return false;
    // The buffer follows inline within `buf` for in-process query; pointer
    // refers back to this same allocation. Compute offset from buf base.
    const buf_base: usize = @intFromPtr(&buf);
    if (buf_ptr_raw < buf_base or buf_ptr_raw >= buf_base + buf.len) return false;
    const name_offset = buf_ptr_raw - buf_base;
    if (name_offset + @as(usize, length_bytes) > buf.len) return false;
    const name_wide: []const u16 = blk: {
        const wide_ptr: [*]const u16 = @ptrCast(@alignCast(&buf[name_offset]));
        break :blk wide_ptr[0 .. length_bytes / 2];
    };

    // Convert UTF-16 to ASCII (Cygwin pty names are pure ASCII). Bail out
    // on any non-ASCII codepoint — those names cannot match.
    var ascii_buf: [256]u8 = undefined;
    if (name_wide.len > ascii_buf.len) return false;
    for (name_wide, 0..) |w, idx| {
        if (w > 0x7F) return false;
        ascii_buf[idx] = @intCast(w);
    }
    const name = ascii_buf[0..name_wide.len];

    // Pattern: split by '-', require at least 5 parts:
    //   parts[0] in {\msys, \cygwin, \Device\NamedPipe\msys, \Device\NamedPipe\cygwin}
    //   parts[1] non-empty
    //   parts[2] starts with "pty"
    //   parts[3] in {from, to}
    //   parts[4] == "master"
    //   parts[5..] all non-empty (e.g. Win7 may append "-nat")
    var parts: [16][]const u8 = undefined;
    var nparts: usize = 0;
    var it = std.mem.splitScalar(u8, name, '-');
    while (it.next()) |p| {
        if (nparts >= parts.len) return false;
        parts[nparts] = p;
        nparts += 1;
    }
    if (nparts < 5) return false;
    const p0 = parts[0];
    const ok0 = std.mem.eql(u8, p0, "\\msys") or
        std.mem.eql(u8, p0, "\\cygwin") or
        std.mem.eql(u8, p0, "\\Device\\NamedPipe\\msys") or
        std.mem.eql(u8, p0, "\\Device\\NamedPipe\\cygwin");
    if (!ok0) return false;
    if (parts[1].len == 0) return false;
    if (!std.mem.startsWith(u8, parts[2], "pty")) return false;
    if (!(std.mem.eql(u8, parts[3], "from") or std.mem.eql(u8, parts[3], "to"))) return false;
    if (!std.mem.eql(u8, parts[4], "master")) return false;
    var k: usize = 5;
    while (k < nparts) : (k += 1) {
        if (parts[k].len == 0) return false;
    }
    return true;
}

// ---- Help text -----------------------------------------------------------

const HELP =
    \\die — print ARGS (or stdin) to stderr and exit 1.
    \\
    \\Usage:
    \\  die [opts] -- ARGS...
    \\  die [-n] <FILE
    \\
    \\Options:
    \\  --sep STR       Joiner between ARGS, default " "
    \\  --trim MODE     Whitespace handling: each (default) | all | none
    \\  -n              Disable trailing-LF normalization (stdin path)
    \\  --help          Show this help and exit 0 (must appear before --)
    \\  --version       Print "die <version>" and exit 0 (must appear before --)
    \\
    \\Behavior:
    \\  - Output is always stderr.
    \\  - Exit code is 1 for die's normal operation (ARG / stdin paths) and
    \\    for any usage error; 0 only for explicit --help / --version queries.
    \\  - "--" is required when ARGS are present.
    \\  - With no ARGS and stdin not a TTY (pipe / file / /dev/null / socket),
    \\    stdin is forwarded to stderr; a missing trailing LF is appended
    \\    unless -n is given.
    \\  - With no ARGS and stdin IS a TTY, this help is printed and exit 1
    \\    (usage error — distinct from the explicit --help query above).
    \\  - "--help" / "--version" before "--" trigger that option.
    \\    After "--" they are treated as ARGs (literal echo).
    \\
;

// ---- Tiny growable buffer (heap-backed via malloc/realloc) ---------------

const Buf = struct {
    ptr: [*]u8 = undefined,
    len: usize = 0,
    cap: usize = 0,

    fn appendSlice(self: *Buf, data: []const u8) bool {
        if (data.len == 0) return true;
        const need = self.len + data.len;
        if (need > self.cap) {
            var new_cap = if (self.cap == 0) @max(data.len, 4096) else self.cap;
            while (new_cap < need) new_cap *= 2;
            const p = if (self.cap == 0)
                malloc(new_cap)
            else
                realloc(@ptrCast(self.ptr), new_cap);
            if (p == null) return false;
            self.ptr = @ptrCast(@alignCast(p.?));
            self.cap = new_cap;
        }
        @memcpy(self.ptr[self.len..][0..data.len], data);
        self.len += data.len;
        return true;
    }

    fn appendByte(self: *Buf, b: u8) bool {
        return self.appendSlice(&[1]u8{b});
    }

    fn slice(self: *const Buf) []const u8 {
        if (self.cap == 0) return &[0]u8{};
        return self.ptr[0..self.len];
    }
};

// ---- Helpers --------------------------------------------------------------

fn writeAll(fd: i32, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = write(fd, data.ptr + off, data.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

fn die(msg: []const u8) noreturn {
    writeAll(STDERR, msg);
    process.exit(1);
}

fn isAsciiWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C or c == 0x0B;
}

fn trimSlice(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and isAsciiWhitespace(s[start])) start += 1;
    while (end > start and isAsciiWhitespace(s[end - 1])) end -= 1;
    return s[start..end];
}

// ---- Arg parsing types ---------------------------------------------------

const Trim = enum { each, all, none };

fn parseTrim(s: []const u8) ?Trim {
    if (mem.eql(u8, s, "each")) return .each;
    if (mem.eql(u8, s, "all")) return .all;
    if (mem.eql(u8, s, "none")) return .none;
    return null;
}

// ---- Build output string for ARG path ------------------------------------

fn buildArgOutput(rest_args: []const [:0]const u8, sep: []const u8, trim: Trim, normalize: bool) ?Buf {
    var buf: Buf = .{};

    switch (trim) {
        .each => {
            for (rest_args, 0..) |a, idx| {
                const s = trimSlice(a);
                if (!buf.appendSlice(s)) {
                    buf = .{};
                    return null;
                }
                if (idx + 1 < rest_args.len) {
                    if (!buf.appendSlice(sep)) {
                        buf = .{};
                        return null;
                    }
                }
            }
        },
        .all => {
            for (rest_args, 0..) |a, idx| {
                if (!buf.appendSlice(a)) {
                    buf = .{};
                    return null;
                }
                if (idx + 1 < rest_args.len) {
                    if (!buf.appendSlice(sep)) {
                        buf = .{};
                        return null;
                    }
                }
            }
            // Trim in-place
            const t = trimSlice(buf.slice());
            const start = @intFromPtr(t.ptr) - @intFromPtr(buf.ptr);
            const tlen = t.len;
            if (start > 0) {
                var k: usize = 0;
                while (k < tlen) : (k += 1) {
                    buf.ptr[k] = buf.ptr[start + k];
                }
            }
            buf.len = tlen;
        },
        .none => {
            for (rest_args, 0..) |a, idx| {
                if (!buf.appendSlice(a)) {
                    buf = .{};
                    return null;
                }
                if (idx + 1 < rest_args.len) {
                    if (!buf.appendSlice(sep)) {
                        buf = .{};
                        return null;
                    }
                }
            }
        },
    }

    if (normalize) {
        const s = buf.slice();
        if (s.len == 0 or s[s.len - 1] != '\n') {
            if (!buf.appendSlice("\n")) {
                buf = .{};
                return null;
            }
        }
    }

    return buf;
}

// ---- append_lf helper (testable) -----------------------------------------

/// Appends a trailing LF to `input` if normalize=true and the last byte is not '\n'.
/// Returns a newly allocated slice (caller owns). Uses std allocator for tests.
fn appendLfStr(allocator: std.mem.Allocator, input: []const u8, normalize: bool) ![]u8 {
    if (!normalize) {
        return allocator.dupe(u8, input);
    }
    if (input.len == 0 or input[input.len - 1] != '\n') {
        var out = try allocator.alloc(u8, input.len + 1);
        @memcpy(out[0..input.len], input);
        out[input.len] = '\n';
        return out;
    }
    return allocator.dupe(u8, input);
}

// ---- join helper (testable) -----------------------------------------------

/// Joins `args` (plain []const u8 slices) with `sep` under the given `trim` mode.
/// Does NOT append trailing LF. Returns a newly allocated slice (caller frees).
fn joinArgs(allocator: std.mem.Allocator, args: []const []const u8, sep: []const u8, trim: Trim) ![]u8 {
    // Use std.array_list.Managed which holds allocator internally (classic ArrayList API).
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    switch (trim) {
        .each => {
            for (args, 0..) |a, idx| {
                try buf.appendSlice(trimSlice(a));
                if (idx + 1 < args.len) try buf.appendSlice(sep);
            }
        },
        .all => {
            for (args, 0..) |a, idx| {
                try buf.appendSlice(a);
                if (idx + 1 < args.len) try buf.appendSlice(sep);
            }
            const t = trimSlice(buf.items);
            const start = @intFromPtr(t.ptr) - @intFromPtr(buf.items.ptr);
            const end = start + t.len;
            return allocator.dupe(u8, buf.items[start..end]);
        },
        .none => {
            for (args, 0..) |a, idx| {
                try buf.appendSlice(a);
                if (idx + 1 < args.len) try buf.appendSlice(sep);
            }
        },
    }
    return buf.toOwnedSlice();
}

// ---- Main ----------------------------------------------------------------

pub fn main(init: process.Init.Minimal) noreturn {
    // FixedBufferAllocator on the stack replaces ArenaAllocator+page_allocator.
    // On POSIX, toSlice() only allocates a slice-of-pointers into the kernel argv;
    // a 4 KB stack buf is ample for any realistic argc (512 pointers = 4096 bytes).
    // This eliminates the ArenaAllocator vtable indirection and the page_allocator
    // from both the hot path and the binary.
    var fbuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbuf);
    const allocator = fba.allocator();

    const argv_all = init.args.toSlice(allocator) catch
        die("die: out of memory\n");

    // Skip argv[0] (program name)
    const args = if (argv_all.len > 0) argv_all[1..] else argv_all[0..0];

    var sep: []const u8 = " ";
    var trim: Trim = .each;
    var normalize: bool = true;
    var saw_dash_dash: bool = false;
    var rest_start: usize = 0;

    var i: usize = 0;
    while (i < args.len) {
        const a: []const u8 = args[i];
        if (mem.eql(u8, a, "--")) {
            saw_dash_dash = true;
            rest_start = i + 1;
            i += 1;
            break;
        } else if (mem.eql(u8, a, "--help")) {
            // Explicit meta query: user asked for help → success (exit 0).
            // Differs from the bare-TTY fallback below, which is a usage
            // error and stays exit 1. (DR-0008 refined.)
            writeAll(STDERR, HELP);
            process.exit(0);
        } else if (mem.eql(u8, a, "--version")) {
            writeAll(STDERR, "die ");
            writeAll(STDERR, VERSION);
            writeAll(STDERR, "\n");
            process.exit(0);
        } else if (mem.eql(u8, a, "-n")) {
            normalize = false;
            i += 1;
        } else if (mem.eql(u8, a, "--sep")) {
            if (i + 1 >= args.len) die("die: --sep requires a value\n");
            i += 1;
            sep = args[i];
            i += 1;
        } else if (mem.startsWith(u8, a, "--sep=")) {
            sep = a["--sep=".len..];
            i += 1;
        } else if (mem.eql(u8, a, "--trim")) {
            if (i + 1 >= args.len) die("die: --trim requires a value\n");
            i += 1;
            trim = parseTrim(args[i]) orelse
                die("die: --trim must be each|all|none\n");
            i += 1;
        } else if (mem.startsWith(u8, a, "--trim=")) {
            const v = a["--trim=".len..];
            trim = parseTrim(v) orelse
                die("die: --trim must be each|all|none\n");
            i += 1;
        } else {
            writeAll(STDERR, "die: unknown option or missing -- before ARGS: \"");
            writeAll(STDERR, a);
            writeAll(STDERR, "\"\n");
            process.exit(1);
        }
    }

    // -n is in effect: switch stdin + stderr to binary mode on Windows so that
    // output is byte-transparent (cat-equivalent). No-op on POSIX (compile-time).
    if (!normalize) {
        setModeBinary();
    }

    if (saw_dash_dash) {
        const rest = args[rest_start..];
        // OS reclaims memory on exit; no defer free needed.
        const out = buildArgOutput(rest, sep, trim, normalize) orelse
            die("die: out of memory\n");
        writeAll(STDERR, out.slice());
        process.exit(1);
    }

    // stdin path (DR-0008): TTY → help; everything else → forward.
    // "Everything else" = pipe, regular file, /dev/null and other char devices,
    // sockets (process substitution), block devices. /dev/null is forwarded
    // as an empty input and gets a single \n via the normalize rule.
    if (isStdinTty()) {
        writeAll(STDERR, HELP);
        process.exit(1);
    }

    var buf: Buf = .{};
    // No defer buf free: OS reclaims all memory on exit(1).
    {
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = read(STDIN, &tmp, tmp.len);
            if (n == 0) break;
            if (n < 0) die("die: reading stdin failed\n");
            if (!buf.appendSlice(tmp[0..@intCast(n)])) die("die: out of memory\n");
        }
    }

    const data = buf.slice();
    writeAll(STDERR, data);
    if (normalize and (data.len == 0 or data[data.len - 1] != '\n')) {
        writeAll(STDERR, "\n");
    }
    process.exit(1);
}

// ============================================================
// Unit tests
// ============================================================

const testing = std.testing;

// ---- isAsciiWhitespace -----------------------------------------------------

test "isAsciiWhitespace: SP (0x20)" {
    try testing.expect(isAsciiWhitespace(' '));
}
test "isAsciiWhitespace: HT (0x09)" {
    try testing.expect(isAsciiWhitespace('\t'));
}
test "isAsciiWhitespace: LF (0x0A)" {
    try testing.expect(isAsciiWhitespace('\n'));
}
test "isAsciiWhitespace: VT (0x0B)" {
    try testing.expect(isAsciiWhitespace(0x0B));
}
test "isAsciiWhitespace: FF (0x0C)" {
    try testing.expect(isAsciiWhitespace(0x0C));
}
test "isAsciiWhitespace: CR (0x0D)" {
    try testing.expect(isAsciiWhitespace('\r'));
}
test "isAsciiWhitespace: regular chars are not whitespace" {
    try testing.expect(!isAsciiWhitespace('a'));
    try testing.expect(!isAsciiWhitespace('0'));
    try testing.expect(!isAsciiWhitespace('!'));
    try testing.expect(!isAsciiWhitespace(0x00));
    try testing.expect(!isAsciiWhitespace(0x1F));
}

// ---- trimSlice (ASCII-only) ------------------------------------------------

test "trimSlice: empty string" {
    try testing.expectEqualStrings("", trimSlice(""));
}
test "trimSlice: no whitespace" {
    try testing.expectEqualStrings("hello", trimSlice("hello"));
}
test "trimSlice: leading SP" {
    try testing.expectEqualStrings("x", trimSlice("  x"));
}
test "trimSlice: trailing SP" {
    try testing.expectEqualStrings("x", trimSlice("x  "));
}
test "trimSlice: leading HT" {
    try testing.expectEqualStrings("x", trimSlice("\tx"));
}
test "trimSlice: trailing HT" {
    try testing.expectEqualStrings("x", trimSlice("x\t"));
}
test "trimSlice: leading LF" {
    try testing.expectEqualStrings("x", trimSlice("\nx"));
}
test "trimSlice: trailing LF" {
    try testing.expectEqualStrings("x", trimSlice("x\n"));
}
test "trimSlice: leading VT (0x0B)" {
    try testing.expectEqualStrings("x", trimSlice("\x0Bx"));
}
test "trimSlice: trailing VT (0x0B)" {
    try testing.expectEqualStrings("x", trimSlice("x\x0B"));
}
test "trimSlice: leading FF (0x0C)" {
    try testing.expectEqualStrings("x", trimSlice("\x0Cx"));
}
test "trimSlice: trailing FF (0x0C)" {
    try testing.expectEqualStrings("x", trimSlice("x\x0C"));
}
test "trimSlice: leading CR" {
    try testing.expectEqualStrings("x", trimSlice("\rx"));
}
test "trimSlice: trailing CR" {
    try testing.expectEqualStrings("x", trimSlice("x\r"));
}
test "trimSlice: combined leading whitespace all 6 kinds" {
    try testing.expectEqualStrings("x", trimSlice(" \t\n\x0B\x0C\rx"));
}
test "trimSlice: combined trailing whitespace all 6 kinds" {
    try testing.expectEqualStrings("x", trimSlice("x \t\n\x0B\x0C\r"));
}
test "trimSlice: both leading and trailing" {
    try testing.expectEqualStrings("foo", trimSlice("  foo  "));
}
test "trimSlice: all whitespace returns empty" {
    try testing.expectEqualStrings("", trimSlice("   \t\n\r"));
}
test "trimSlice: interior whitespace preserved" {
    try testing.expectEqualStrings("a b", trimSlice("  a b  "));
}
test "trimSlice: interior tabs and newlines preserved" {
    try testing.expectEqualStrings("a\tb\nc", trimSlice("  a\tb\nc  "));
}
// Unicode: NBSP (U+00A0) = 0xC2 0xA0 in UTF-8 — must NOT be trimmed
test "trimSlice: NBSP (U+00A0) not trimmed as leading" {
    const nbsp = "\xC2\xA0x";
    try testing.expectEqualStrings(nbsp, trimSlice(nbsp));
}
test "trimSlice: NBSP (U+00A0) not trimmed as trailing" {
    const nbsp = "x\xC2\xA0";
    try testing.expectEqualStrings(nbsp, trimSlice(nbsp));
}
// U+2028 LINE SEPARATOR = 0xE2 0x80 0xA8 in UTF-8 — must NOT be trimmed
test "trimSlice: U+2028 not trimmed" {
    const ls = "\xE2\x80\xA8x";
    try testing.expectEqualStrings(ls, trimSlice(ls));
}
// U+3000 IDEOGRAPHIC SPACE = 0xE3 0x80 0x80 in UTF-8 — must NOT be trimmed
test "trimSlice: U+3000 fullwidth space not trimmed" {
    const fsp = "\xE3\x80\x80x";
    try testing.expectEqualStrings(fsp, trimSlice(fsp));
}

// ---- parseTrim -------------------------------------------------------------

test "parseTrim: each" {
    try testing.expectEqual(Trim.each, parseTrim("each").?);
}
test "parseTrim: all" {
    try testing.expectEqual(Trim.all, parseTrim("all").?);
}
test "parseTrim: none" {
    try testing.expectEqual(Trim.none, parseTrim("none").?);
}
test "parseTrim: empty string returns null" {
    try testing.expectEqual(@as(?Trim, null), parseTrim(""));
}
test "parseTrim: unknown value returns null" {
    try testing.expectEqual(@as(?Trim, null), parseTrim("EACH"));
}
test "parseTrim: partial match returns null" {
    try testing.expectEqual(@as(?Trim, null), parseTrim("eac"));
}
test "parseTrim: trailing space returns null" {
    try testing.expectEqual(@as(?Trim, null), parseTrim("each "));
}
test "parseTrim: leading space returns null" {
    try testing.expectEqual(@as(?Trim, null), parseTrim(" each"));
}
test "parseTrim: mixed case returns null" {
    try testing.expectEqual(@as(?Trim, null), parseTrim("Each"));
}
test "parseTrim: unrelated word returns null" {
    try testing.expectEqual(@as(?Trim, null), parseTrim("trim"));
}

// ---- joinArgs --------------------------------------------------------------

test "joinArgs: 0 args default sep each" {
    const allocator = testing.allocator;
    const result = try joinArgs(allocator, &.{}, " ", .each);
    defer allocator.free(result);
    try testing.expectEqualStrings("", result);
}
test "joinArgs: 1 arg default sep each" {
    const allocator = testing.allocator;
    const result = try joinArgs(allocator, &.{"hello"}, " ", .each);
    defer allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}
test "joinArgs: 3 args default sep each" {
    const allocator = testing.allocator;
    const result = try joinArgs(allocator, &.{ "a", "b", "c" }, " ", .each);
    defer allocator.free(result);
    try testing.expectEqualStrings("a b c", result);
}
test "joinArgs: 3 args empty sep each" {
    const allocator = testing.allocator;
    const result = try joinArgs(allocator, &.{ "a", "b", "c" }, "", .each);
    defer allocator.free(result);
    try testing.expectEqualStrings("abc", result);
}
test "joinArgs: 3 args multi-char sep each" {
    const allocator = testing.allocator;
    const result = try joinArgs(allocator, &.{ "a", "b", "c" }, ", ", .each);
    defer allocator.free(result);
    try testing.expectEqualStrings("a, b, c", result);
}
test "joinArgs: trim each trims each arg individually" {
    const allocator = testing.allocator;
    const result = try joinArgs(allocator, &.{ "  foo  ", "  bar  " }, " ", .each);
    defer allocator.free(result);
    try testing.expectEqualStrings("foo bar", result);
}
test "joinArgs: trim each preserves empty after trim" {
    const allocator = testing.allocator;
    const result = try joinArgs(allocator, &.{ "  ", "x" }, " ", .each);
    defer allocator.free(result);
    try testing.expectEqualStrings(" x", result);
}
test "joinArgs: trim all trims joined result" {
    const allocator = testing.allocator;
    const result = try joinArgs(allocator, &.{ "  foo", "bar  " }, " ", .all);
    defer allocator.free(result);
    try testing.expectEqualStrings("foo bar", result);
}
test "joinArgs: trim all interior whitespace preserved" {
    const allocator = testing.allocator;
    // "  a b  " ++ " " ++ "  c d  " = "  a b     c d  ", trimmed = "a b     c d" (5 spaces: 2 trailing + sep + 2 leading)
    const result = try joinArgs(allocator, &.{ "  a b  ", "  c d  " }, " ", .all);
    defer allocator.free(result);
    try testing.expectEqualStrings("a b     c d", result);
}
test "joinArgs: trim none no trimming" {
    const allocator = testing.allocator;
    const result = try joinArgs(allocator, &.{ "  foo  ", "  bar  " }, " ", .none);
    defer allocator.free(result);
    try testing.expectEqualStrings("  foo     bar  ", result);
}
test "joinArgs: trim none preserves all whitespace" {
    const allocator = testing.allocator;
    const result = try joinArgs(allocator, &.{ "\tfoo\n", "\rbar\r\n" }, "|", .none);
    defer allocator.free(result);
    try testing.expectEqualStrings("\tfoo\n|\rbar\r\n", result);
}
test "joinArgs: 0 args trim all" {
    const allocator = testing.allocator;
    const result = try joinArgs(allocator, &.{}, " ", .all);
    defer allocator.free(result);
    try testing.expectEqualStrings("", result);
}
test "joinArgs: 0 args trim none" {
    const allocator = testing.allocator;
    const result = try joinArgs(allocator, &.{}, " ", .none);
    defer allocator.free(result);
    try testing.expectEqualStrings("", result);
}
test "joinArgs: empty arg in middle trim each" {
    const allocator = testing.allocator;
    const result = try joinArgs(allocator, &.{ "a", "", "b" }, "-", .each);
    defer allocator.free(result);
    try testing.expectEqualStrings("a--b", result);
}
test "joinArgs: all empty args trim each" {
    const allocator = testing.allocator;
    const result = try joinArgs(allocator, &.{ "", "" }, "-", .each);
    defer allocator.free(result);
    try testing.expectEqualStrings("-", result);
}
test "joinArgs: all whitespace args trim all becomes empty" {
    const allocator = testing.allocator;
    const result = try joinArgs(allocator, &.{ "   ", "   " }, " ", .all);
    defer allocator.free(result);
    try testing.expectEqualStrings("", result);
}

// ---- appendLfStr -----------------------------------------------------------

test "appendLf: normalize=true input ending with LF unchanged" {
    const allocator = testing.allocator;
    const result = try appendLfStr(allocator, "X\n", true);
    defer allocator.free(result);
    try testing.expectEqualStrings("X\n", result);
}
test "appendLf: normalize=true input not ending with LF gets LF appended" {
    const allocator = testing.allocator;
    const result = try appendLfStr(allocator, "X", true);
    defer allocator.free(result);
    try testing.expectEqualStrings("X\n", result);
}
test "appendLf: normalize=true empty input gets LF appended" {
    const allocator = testing.allocator;
    const result = try appendLfStr(allocator, "", true);
    defer allocator.free(result);
    try testing.expectEqualStrings("\n", result);
}
test "appendLf: normalize=true CRLF ending counts as LF-terminated (no extra LF)" {
    const allocator = testing.allocator;
    const result = try appendLfStr(allocator, "X\r\n", true);
    defer allocator.free(result);
    try testing.expectEqualStrings("X\r\n", result);
}
test "appendLf: normalize=true double LF preserved (no dedup)" {
    const allocator = testing.allocator;
    const result = try appendLfStr(allocator, "X\n\n", true);
    defer allocator.free(result);
    try testing.expectEqualStrings("X\n\n", result);
}
test "appendLf: normalize=true lone CR gets LF appended" {
    const allocator = testing.allocator;
    const result = try appendLfStr(allocator, "X\r", true);
    defer allocator.free(result);
    try testing.expectEqualStrings("X\r\n", result);
}
test "appendLf: normalize=false input ending with LF unchanged" {
    const allocator = testing.allocator;
    const result = try appendLfStr(allocator, "X\n", false);
    defer allocator.free(result);
    try testing.expectEqualStrings("X\n", result);
}
test "appendLf: normalize=false input not ending with LF unchanged" {
    const allocator = testing.allocator;
    const result = try appendLfStr(allocator, "X", false);
    defer allocator.free(result);
    try testing.expectEqualStrings("X", result);
}
test "appendLf: normalize=false empty input unchanged" {
    const allocator = testing.allocator;
    const result = try appendLfStr(allocator, "", false);
    defer allocator.free(result);
    try testing.expectEqualStrings("", result);
}
test "appendLf: normalize=false CRLF unchanged" {
    const allocator = testing.allocator;
    const result = try appendLfStr(allocator, "X\r\n", false);
    defer allocator.free(result);
    try testing.expectEqualStrings("X\r\n", result);
}
