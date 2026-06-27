// die — write a message to stderr and exit 1.
//
// Spec: see ../../docs/DESIGN.md (and DR-0001 / DR-0002 / DR-0005).

use std::io::{self, Read, Write};
use std::process::ExitCode;

const HELP: &str = "\
die — print ARGS (or stdin) to stderr and exit 1.

Usage:
  die [opts] -- ARGS...
  die [-n] <FILE

Options:
  --sep STR       Joiner between ARGS, default \" \"
  --trim MODE     Whitespace (ASCII) handling: each (default) | all | none
  -n              Disable trailing-newline normalization (stdin path)

Behavior:
  - Output is always stderr, exit code is always 1.
  - \"--\" is required when ARGS are present.
  - With no ARGS, stdin (pipe/redirect) is forwarded to stderr; a missing
    trailing newline is appended unless -n is given.
  - On a TTY with no ARGS, this help is printed and exit 1.
  - --trim strips ASCII whitespace only (SP HT LF VT FF CR).
";

#[derive(Clone, Copy)]
enum Trim {
    Each,
    All,
    None,
}

fn parse_trim(s: &str) -> Option<Trim> {
    match s {
        "each" => Some(Trim::Each),
        "all" => Some(Trim::All),
        "none" => Some(Trim::None),
        _ => None,
    }
}

/// ASCII-only trim: strip bytes that are ASCII whitespace (SP HT LF VT FF CR).
fn ascii_trim(s: &str) -> &str {
    fn is_ascii_ws(b: u8) -> bool {
        matches!(b, b' ' | b'\t' | b'\n' | b'\x0B' | b'\x0C' | b'\r')
    }
    let bytes = s.as_bytes();
    let start = bytes.iter().position(|&b| !is_ascii_ws(b)).unwrap_or(bytes.len());
    let end = bytes.iter().rposition(|&b| !is_ascii_ws(b)).map(|i| i + 1).unwrap_or(0);
    if start >= end { "" } else { &s[start..end] }
}

fn usage_err(msg: &str) -> ExitCode {
    let mut e = io::stderr();
    let _ = e.write_all(b"die: ");
    let _ = e.write_all(msg.as_bytes());
    let _ = e.write_all(b"\n");
    ExitCode::from(1)
}

fn join_args(args: &[String], sep: &str, trim: Trim) -> String {
    match trim {
        Trim::Each => args.iter().map(|a| ascii_trim(a)).collect::<Vec<_>>().join(sep),
        Trim::All => ascii_trim(&args.join(sep)).to_string(),
        Trim::None => args.join(sep),
    }
}

/// Append LF to a String if trailing newline is missing (DR-0002 invariant).
fn append_lf_str(mut s: String, normalize: bool) -> String {
    if !normalize {
        return s;
    }
    // Already ends with LF or CRLF → leave alone (DR-0002 invariant).
    if s.ends_with('\n') {
        return s;
    }
    s.push('\n');
    s
}

/// Append LF to bytes if trailing newline is missing (DR-0002 invariant).
fn append_lf_bytes(mut b: Vec<u8>, normalize: bool) -> Vec<u8> {
    if !normalize {
        return b;
    }
    // Already ends with LF (covers CRLF too) → leave alone.
    if b.last() == Some(&b'\n') {
        return b;
    }
    b.push(b'\n');
    b
}

fn is_stdin_tty() -> bool {
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        let fd = io::stdin().as_raw_fd();
        // SAFETY: isatty(3) is signal-safe and side-effect-free.
        unsafe { unix_isatty(fd) }
    }
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        let h = io::stdin().as_raw_handle();
        // SAFETY: GetFileType is signal-safe and side-effect-free.
        unsafe { win_is_char_device(h) }
    }
    #[cfg(not(any(unix, windows)))]
    {
        false
    }
}

#[cfg(unix)]
unsafe fn unix_isatty(fd: i32) -> bool {
    // Avoid pulling in the `libc` crate dependency for one function.
    extern "C" {
        fn isatty(fd: i32) -> i32;
    }
    isatty(fd) != 0
}

#[cfg(windows)]
unsafe fn win_is_char_device(handle: *mut std::ffi::c_void) -> bool {
    // GetFileType on a console handle returns FILE_TYPE_CHAR (0x0002); pipes
    // and disk files report FILE_TYPE_PIPE / FILE_TYPE_DISK. This matches
    // isatty semantics closely enough for our "ARGS empty + stdin TTY → help"
    // branch on Windows.
    extern "system" {
        fn GetFileType(handle: *mut std::ffi::c_void) -> u32;
    }
    const FILE_TYPE_CHAR: u32 = 0x0002;
    GetFileType(handle) == FILE_TYPE_CHAR
}

fn run(mut args: Vec<String>) -> ExitCode {
    let mut sep = String::from(" ");
    let mut trim = Trim::Each;
    let mut normalize = true;

    let mut saw_dash_dash = false;
    let mut rest: Vec<String> = Vec::new();

    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if a == "--" {
            saw_dash_dash = true;
            rest = args.drain(i + 1..).collect();
            break;
        } else if a == "-n" {
            normalize = false;
            i += 1;
        } else if a == "--sep" {
            if i + 1 >= args.len() {
                return usage_err("--sep requires a value");
            }
            sep = args[i + 1].clone();
            i += 2;
        } else if let Some(v) = a.strip_prefix("--sep=") {
            sep = v.to_string();
            i += 1;
        } else if a == "--trim" {
            if i + 1 >= args.len() {
                return usage_err("--trim requires a value");
            }
            match parse_trim(&args[i + 1]) {
                Some(m) => {
                    trim = m;
                    i += 2;
                }
                None => return usage_err(&["--trim must be each|all|none, got \"", &args[i + 1], "\""].concat()),
            }
        } else if let Some(v) = a.strip_prefix("--trim=") {
            match parse_trim(v) {
                Some(m) => {
                    trim = m;
                    i += 1;
                }
                None => return usage_err(&["--trim must be each|all|none, got \"", v, "\""].concat()),
            }
        } else {
            return usage_err(&["unknown option or missing -- before ARGS: \"", a, "\""].concat());
        }
    }

    let mut stderr = io::stderr();

    if saw_dash_dash {
        let out = append_lf_str(join_args(&rest, &sep, trim), normalize);
        let _ = stderr.write_all(out.as_bytes());
        return ExitCode::from(1);
    }

    // stdin path: TTY → help; otherwise → forward.
    if is_stdin_tty() {
        let _ = stderr.write_all(HELP.as_bytes());
        return ExitCode::from(1);
    }
    let mut buf = Vec::new();
    if io::stdin().read_to_end(&mut buf).is_err() {
        let _ = stderr.write_all(b"die: reading stdin failed\n");
        return ExitCode::from(1);
    }
    let out = append_lf_bytes(buf, normalize);
    let _ = stderr.write_all(&out);
    ExitCode::from(1)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    run(args)
}
