// die — print ARGS (or stdin) to stderr and exit 1.
//
// Usage:
//   die [opts] -- ARGS...
//   die [-n] <FILE
//
// Spec: see ../../docs/DESIGN.md and decisions/DR-0001 / DR-0002 / DR-0005.

// ---------------------------------------------------------------------------
// C FFI — native backend only
// ---------------------------------------------------------------------------

/// Exit the process with the given code.
extern "c" fn c_exit(code : Int) -> Unit = "exit"

/// Write bytes to a file descriptor. Returns bytes written or -1 on error.
#borrow(buf)
extern "c" fn c_write(fd : Int, buf : Bytes, count : Int) -> Int = "write"

/// Read bytes from a file descriptor into a mutable buffer.
/// Returns bytes read, 0 on EOF, or -1 on error.
#borrow(buf)
extern "c" fn c_read_into(fd : Int, buf : FixedArray[Byte], count : Int) -> Int = "read"

/// isatty(fd): returns 1 if fd refers to a terminal, 0 otherwise.
extern "c" fn c_isatty(fd : Int) -> Int = "isatty"

/// _setmode(fd, mode): set CRT text/binary mode on Windows.
/// On POSIX, stub.c provides a no-op so this resolves at link time.
/// _O_BINARY = 0x8000; suppresses \n -> \r\n CRT text-mode conversion.
extern "c" fn c_setmode(fd : Int, mode : Int) -> Int = "_setmode"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

let stdin_fd : Int = 0
let stderr_fd : Int = 2

let help_text : String =
  "die — print ARGS (or stdin) to stderr and exit 1.\n" +
  "\n" +
  "Usage:\n" +
  "  die [opts] -- ARGS...\n" +
  "  die [-n] <FILE\n" +
  "\n" +
  "Options:\n" +
  "  --sep STR       Joiner between ARGS, default \" \"\n" +
  "  --trim MODE     Whitespace handling: each (default) | all | none\n" +
  "  -n              Disable trailing-LF normalisation (stdin path)\n" +
  "\n" +
  "Behavior:\n" +
  "  - Output is always stderr, exit code is always 1.\n" +
  "  - \"--\" is required when ARGS are present.\n" +
  "  - With no ARGS, stdin (pipe/redirect) is forwarded to stderr; a missing\n" +
  "    trailing LF is appended unless -n is given.\n" +
  "  - On a TTY with no ARGS, this help is printed and exit 1.\n"

// ---------------------------------------------------------------------------
// Windows CRT binary mode (cat-equivalent for -n)
// ---------------------------------------------------------------------------

/// On Windows, suppress CRT text-mode \n -> \r\n conversion on stdin (0) and
/// stderr (2) so that -n produces byte-transparent (cat-equivalent) output.
/// On POSIX, stub.c provides a _setmode no-op so this is harmless.
/// We gate on OS env var to avoid the overhead on POSIX builds that still
/// link the stub (MoonBit native has no compile-time OS detection).
///
/// _O_BINARY = 0x8000
fn enable_binary_mode() -> Unit {
  let os = @env.get_env_var("OS")
  match os {
    Some("Windows_NT") => {
      let _o_binary = 0x8000
      let _ = c_setmode(stdin_fd, _o_binary)
      let _ = c_setmode(stderr_fd, _o_binary)
    }
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Low-level I/O helpers
// ---------------------------------------------------------------------------

/// Convert a MoonBit String to a UTF-8 Bytes object (no null terminator).
fn string_to_utf8(str : String) -> Bytes {
  let res : Array[Byte] = []
  let len = str.length()
  let mut i = 0
  while i < len {
    let mut c = str.code_unit_at(i).to_int()
    if 0xD800 <= c && c <= 0xDBFF && i + 1 < len {
      let l = str.code_unit_at(i + 1).to_int() - 0xDC00
      c = ((c - 0xD800) << 10) + l + 0x10000
      i += 2
    } else {
      i += 1
    }
    if c < 0x80 {
      res.push(c.to_byte())
    } else if c < 0x800 {
      res.push((0xc0 | (c >> 6)).to_byte())
      res.push((0x80 | (c & 0x3f)).to_byte())
    } else if c < 0x10000 {
      res.push((0xe0 | (c >> 12)).to_byte())
      res.push((0x80 | ((c >> 6) & 0x3f)).to_byte())
      res.push((0x80 | (c & 0x3f)).to_byte())
    } else {
      res.push((0xf0 | (c >> 18)).to_byte())
      res.push((0x80 | ((c >> 12) & 0x3f)).to_byte())
      res.push((0x80 | ((c >> 6) & 0x3f)).to_byte())
      res.push((0x80 | (c & 0x3f)).to_byte())
    }
  }
  Bytes::from_array(res.view())
}

/// Write a Bytes object to stderr.
fn write_stderr(b : Bytes) -> Unit {
  let len = b.length()
  let mut written = 0
  while written < len {
    let n = c_write(stderr_fd, b, len - written)
    if n <= 0 {
      break
    }
    written += n
  }
}

/// Write a string to stderr (converts via UTF-8).
fn write_stderr_str(s : String) -> Unit {
  write_stderr(string_to_utf8(s))
}

/// Read all bytes from stdin, returning a Bytes object.
fn read_stdin_all() -> Array[Byte] {
  let chunk_size = 4096
  let result : Array[Byte] = []
  let buf : FixedArray[Byte] = FixedArray::make(chunk_size, 0)
  while true {
    let n = c_read_into(stdin_fd, buf, chunk_size)
    if n <= 0 {
      break
    }
    // Bulk-append all n bytes from the fixed buffer into result.
    // Array::from_fixed_array does a single blit internally (O(n) with
    // no per-element push overhead), then Array::append blits that into
    // result — avoiding the per-byte push loop.
    if n == chunk_size {
      result.append(Array::from_fixed_array(buf))
    } else {
      // Partial read: only n bytes are valid; slice the view.
      let slice = Array::from_fixed_array(buf)
      result.append(slice[:n])
    }
  }
  result
}

// ---------------------------------------------------------------------------
// Spec logic
// ---------------------------------------------------------------------------

/// Parse the --trim mode string. Returns Some(mode) or None if invalid.
fn parse_trim(v : String) -> String? {
  match v {
    "each" | "all" | "none" => Some(v)
    _ => None
  }
}

/// Check if a byte value is ASCII whitespace.
/// ASCII whitespace: SP (0x20), HT (0x09), LF (0x0A), VT (0x0B), FF (0x0C), CR (0x0D).
/// Does NOT include Unicode whitespace (U+00A0 NBSP etc.) — ASCII-only per spec.
fn is_ascii_whitespace_byte(c : Int) -> Bool {
  c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0b || c == 0x0c || c == 0x0d
}

/// Check if a UTF-16 code unit is ASCII whitespace.
/// Used for String (UTF-16) processing; only considers the 6 ASCII whitespace bytes.
fn is_ascii_whitespace(c : Int) -> Bool {
  // Only ASCII code points (< 0x80) can be ASCII whitespace.
  // All 6 ASCII whitespace values are < 0x80, so comparing the code unit directly is correct.
  c < 0x80 && is_ascii_whitespace_byte(c)
}

/// Trim leading and trailing ASCII whitespace from a string.
/// Strips exactly the 6 ASCII whitespace bytes: SP HT LF VT FF CR.
/// Does NOT strip Unicode whitespace (NBSP etc.).
fn trim_space(s : String) -> String {
  let len = s.length()
  let mut start = 0
  while start < len && is_ascii_whitespace(s.code_unit_at(start).to_int()) {
    start += 1
  }
  let mut end = len
  while end > start && is_ascii_whitespace(s.code_unit_at(end - 1).to_int()) {
    end -= 1
  }
  s[start:end].to_owned()
}

/// Join args with sep, applying trim mode.
fn join_args(args : ArrayView[String], sep : String, trim : String) -> String {
  match trim {
    "each" => args.map(trim_space).join(sep)
    "all" => trim_space(args.join(sep))
    _ => args.join(sep)
  }
}

/// Ensure the string ends with LF. No-op if normalize is false.
fn append_lf_str(s : String, normalize : Bool) -> String {
  if !normalize {
    return s
  }
  let len = s.length()
  if len == 0 {
    // Empty string: append LF
    s + "\n"
  } else {
    let last = s.code_unit_at(len - 1).to_int()
    if last == 0x0a {
      // Already ends with LF (covers both LF and CRLF endings)
      s
    } else {
      // Ends with bare CR or any other byte — treat as unterminated,
      // append LF. (bare CR and no-EOL are treated identically.)
      s + "\n"
    }
  }
}

/// Ensure the byte array ends with LF. No-op if normalize is false.
fn append_lf_bytes(b : Array[Byte], normalize : Bool) -> Array[Byte] {
  if !normalize {
    return b
  }
  let len = b.length()
  let needs_lf = if len == 0 {
    true
  } else {
    b[len - 1].to_int() != 0x0a
  }
  if needs_lf {
    b.push(0x0a)
  }
  b
}

/// Emit a usage error to stderr and exit 1.
fn usage_err(msg : String) -> Unit {
  write_stderr_str("die: ")
  write_stderr_str(msg)
  write_stderr_str("\n")
  c_exit(1)
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn main {
  let args = @env.args()
  // args[0] is the program name; skip it
  let args_len = args.length()

  let mut sep = " "
  let mut trim = "each"
  let mut normalize = true
  let mut saw_dash_dash = false
  let mut dash_dash_pos = args_len

  // Phase 1: parse opts (everything before "--")
  let mut i = 1 // skip program name at index 0
  while i < args_len {
    let a = args[i]
    if a == "--" {
      saw_dash_dash = true
      dash_dash_pos = i
      i = args_len // break
    } else if a == "-n" {
      normalize = false
      // DR-0006: -n means cat-equivalent byte-transparent output.
      // Suppress CRT text-mode \n -> \r\n conversion on Windows.
      enable_binary_mode()
      i += 1
    } else if a == "--sep" {
      if i + 1 >= args_len {
        usage_err("--sep requires a value")
        return
      }
      sep = args[i + 1]
      i += 2
    } else if a.has_prefix("--sep=") {
      sep = a[6:].to_owned()
      i += 1
    } else if a == "--trim" {
      if i + 1 >= args_len {
        usage_err("--trim requires a value")
        return
      }
      match parse_trim(args[i + 1]) {
        Some(m) => trim = m
        None => {
          usage_err("--trim must be each|all|none, got \"\{args[i + 1]}\"")
          return
        }
      }
      i += 2
    } else if a.has_prefix("--trim=") {
      let raw = a[7:].to_owned()
      match parse_trim(raw) {
        Some(m) => trim = m
        None => {
          usage_err("--trim must be each|all|none, got \"\{raw}\"")
          return
        }
      }
      i += 1
    } else {
      usage_err("unknown option or missing -- before ARGS: \"\{a}\"")
      return
    }
  }

  // ARG path: anything after "--", including zero args
  if saw_dash_dash {
    let rest = args.view(start=dash_dash_pos + 1)
    let out = join_args(rest, sep, trim)
    let out = append_lf_str(out, normalize)
    write_stderr_str(out)
    c_exit(1)
    return
  }

  // No "--": stdin path.
  // TTY check on stdin (fd 0)
  if c_isatty(stdin_fd) == 1 {
    write_stderr_str(help_text)
    c_exit(1)
    return
  }

  // Pipe/redirect: read stdin and forward to stderr
  let data = read_stdin_all()
  let data = append_lf_bytes(data, normalize)
  let bytes = Bytes::from_array(data.view())
  write_stderr(bytes)
  c_exit(1)
}
