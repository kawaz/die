// die — write a message to stderr and exit 1.
//
// Spec: see ../../docs/DESIGN.md (and DR-0001 / DR-0002 / DR-0004).
//
// Uses raw POSIX extern calls for I/O to bypass Zig 0.16.0's new async Io API.
// Uses std.process.Init.Minimal for argv access (Zig 0.16.0 new main signature).

const std = @import("std");
const mem = std.mem;
const process = std.process;
const builtin = @import("builtin");

// ---- POSIX extern declarations -------------------------------------------

extern fn write(fd: i32, buf: [*]const u8, count: usize) isize;
extern fn read(fd: i32, buf: [*]u8, count: usize) isize;
extern fn isatty(fd: i32) c_int;
extern fn malloc(size: usize) ?*anyopaque;
extern fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;

// ---- Windows-only: binary-mode stdio -------------------------------------
// On Windows, CRT stdio defaults to text mode which translates \n to \r\n on
// write and strips \r on read. Force binary mode on fd 0/1/2 so that the raw
// byte content we write to stderr is not mangled.
const _O_BINARY: c_int = 0x8000;
extern "C" fn _setmode(fd: c_int, mode: c_int) c_int;

const STDIN: i32 = 0;
const STDOUT: i32 = 1;
const STDERR: i32 = 2;

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
    \\  --eol MODE      EOL for missing trailing newline: auto (default) | lf | crlf
    \\  -n              Disable trailing-LF normalization (stdin path)
    \\
    \\Behavior:
    \\  - Output is always stderr, exit code is always 1.
    \\  - "--" is required when ARGS are present.
    \\  - With no ARGS, stdin (pipe/redirect) is forwarded to stderr; a missing
    \\    trailing LF is appended unless -n is given.
    \\  - --eol auto uses CRLF on Windows targets, LF elsewhere.
    \\  - On a TTY with no ARGS, this help is printed and exit 1.
    \\
;

// ---- Tiny growable buffer (heap-backed via malloc/realloc) ---------------

const Buf = struct {
    ptr: [*]u8 = undefined,
    len: usize = 0,
    cap: usize = 0,

    fn deinit(self: *Buf) void {
        if (self.cap > 0) free(@ptrCast(self.ptr));
        self.* = .{};
    }

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

const Eol = enum { auto, lf, crlf };

fn parseEol(s: []const u8) ?Eol {
    if (mem.eql(u8, s, "auto")) return .auto;
    if (mem.eql(u8, s, "lf")) return .lf;
    if (mem.eql(u8, s, "crlf")) return .crlf;
    return null;
}

/// Resolve the EOL bytes to append when normalising a missing trailing newline.
fn resolveEol(eol: Eol) []const u8 {
    return switch (eol) {
        .lf => "\n",
        .crlf => "\r\n",
        .auto => if (builtin.target.os.tag == .windows) "\r\n" else "\n",
    };
}

// ---- Build output string for ARG path ------------------------------------

fn buildArgOutput(rest_args: []const [:0]const u8, sep: []const u8, trim: Trim, normalize: bool, eol: Eol) ?Buf {
    var buf: Buf = .{};

    switch (trim) {
        .each => {
            for (rest_args, 0..) |a, idx| {
                const s = trimSlice(a);
                if (!buf.appendSlice(s)) { buf.deinit(); return null; }
                if (idx + 1 < rest_args.len) {
                    if (!buf.appendSlice(sep)) { buf.deinit(); return null; }
                }
            }
        },
        .all => {
            for (rest_args, 0..) |a, idx| {
                if (!buf.appendSlice(a)) { buf.deinit(); return null; }
                if (idx + 1 < rest_args.len) {
                    if (!buf.appendSlice(sep)) { buf.deinit(); return null; }
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
                if (!buf.appendSlice(a)) { buf.deinit(); return null; }
                if (idx + 1 < rest_args.len) {
                    if (!buf.appendSlice(sep)) { buf.deinit(); return null; }
                }
            }
        },
    }

    if (normalize) {
        const s = buf.slice();
        if (s.len == 0 or s[s.len - 1] != '\n') {
            if (!buf.appendSlice(resolveEol(eol))) { buf.deinit(); return null; }
        }
    }

    return buf;
}

// ---- Main ----------------------------------------------------------------

pub fn main(init: process.Init.Minimal) noreturn {
    // On Windows, force binary mode on stdin/stdout/stderr so that CRT text-mode
    // translation (\n <-> \r\n) does not corrupt our raw byte output.
    if (builtin.target.os.tag == .windows) {
        _ = _setmode(STDIN, _O_BINARY);
        _ = _setmode(STDOUT, _O_BINARY);
        _ = _setmode(STDERR, _O_BINARY);
    }

    // Use page_allocator arena for argv slice conversion.
    // On POSIX, Args.toSlice with an arena is allocation-free (it borrows the
    // process's argv directly). On Windows it would allocate WTF-8 conversions.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv_all = init.args.toSlice(allocator) catch
        die("die: out of memory\n");

    // Skip argv[0] (program name)
    const args = if (argv_all.len > 0) argv_all[1..] else argv_all[0..0];

    var sep: []const u8 = " ";
    var trim: Trim = .each;
    var eol: Eol = .auto;
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
        } else if (mem.eql(u8, a, "--eol")) {
            if (i + 1 >= args.len) die("die: --eol requires a value\n");
            i += 1;
            eol = parseEol(args[i]) orelse
                die("die: --eol must be auto|lf|crlf\n");
            i += 1;
        } else if (mem.startsWith(u8, a, "--eol=")) {
            const v = a["--eol=".len..];
            eol = parseEol(v) orelse
                die("die: --eol must be auto|lf|crlf\n");
            i += 1;
        } else {
            writeAll(STDERR, "die: unknown option or missing -- before ARGS: \"");
            writeAll(STDERR, a);
            writeAll(STDERR, "\"\n");
            process.exit(1);
        }
    }

    if (saw_dash_dash) {
        const rest = args[rest_start..];
        var out = buildArgOutput(rest, sep, trim, normalize, eol) orelse
            die("die: out of memory\n");
        defer out.deinit();
        writeAll(STDERR, out.slice());
        process.exit(1);
    }

    // stdin path: TTY → help; pipe/redirect → forward
    if (isatty(STDIN) != 0) {
        writeAll(STDERR, HELP);
        process.exit(1);
    }

    var buf: Buf = .{};
    defer buf.deinit();
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
        writeAll(STDERR, resolveEol(eol));
    }
    process.exit(1);
}
