// die — write a message to stderr and exit 1.
//
// Spec: see ../../docs/DESIGN.md (and DR-0001 / DR-0002 / DR-0004).

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
  --eol MODE      EOL appended when trailing newline is missing:
                    auto (default) — CRLF on Windows builds, LF elsewhere
                    lf             — always LF (\\n)
                    crlf           — always CRLF (\\r\\n)
  -n              Disable trailing-newline normalization (stdin path)

Behavior:
  - Output is always stderr, exit code is always 1.
  - \"--\" is required when ARGS are present.
  - With no ARGS, stdin (pipe/redirect) is forwarded to stderr; a missing
    trailing newline is appended unless -n is given.
  - On a TTY with no ARGS, this help is printed and exit 1.
  - --trim strips ASCII whitespace only (SP HT LF VT FF CR).
  - --eol has no effect when -n is given.
";

#[derive(Clone, Copy)]
enum Trim {
    Each,
    All,
    None,
}

#[derive(Clone, Copy)]
enum Eol {
    Auto,
    Lf,
    Crlf,
}

/// Resolve --eol auto at build time.
fn resolve_eol(eol: Eol) -> &'static [u8] {
    match eol {
        Eol::Lf => b"\n",
        Eol::Crlf => b"\r\n",
        Eol::Auto => {
            #[cfg(windows)]
            { b"\r\n" }
            #[cfg(not(windows))]
            { b"\n" }
        }
    }
}

fn parse_trim(s: &str) -> Option<Trim> {
    match s {
        "each" => Some(Trim::Each),
        "all" => Some(Trim::All),
        "none" => Some(Trim::None),
        _ => None,
    }
}

fn parse_eol(s: &str) -> Option<Eol> {
    match s {
        "auto" => Some(Eol::Auto),
        "lf" => Some(Eol::Lf),
        "crlf" => Some(Eol::Crlf),
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
    let _ = writeln!(io::stderr(), "die: {msg}");
    ExitCode::from(1)
}

fn join_args(args: &[String], sep: &str, trim: Trim) -> String {
    match trim {
        Trim::Each => {
            let parts: Vec<&str> = args.iter().map(|a| ascii_trim(a)).collect();
            parts.join(sep)
        }
        Trim::All => ascii_trim(&args.join(sep)).to_string(),
        Trim::None => args.join(sep),
    }
}

/// Append the resolved EOL terminator to a String if missing.
fn append_eol_str(mut s: String, normalize: bool, eol: Eol) -> String {
    if !normalize {
        return s;
    }
    // Already ends with LF or CRLF → leave alone (DR-0002 invariant).
    if s.ends_with('\n') {
        return s;
    }
    let term = resolve_eol(eol);
    // SAFETY: term is always valid UTF-8 ("\n" or "\r\n").
    s.push_str(std::str::from_utf8(term).unwrap());
    s
}

/// Append the resolved EOL terminator to bytes if missing.
fn append_eol_bytes(mut b: Vec<u8>, normalize: bool, eol: Eol) -> Vec<u8> {
    if !normalize {
        return b;
    }
    // Already ends with LF (covers CRLF too) → leave alone.
    if b.last() == Some(&b'\n') {
        return b;
    }
    b.extend_from_slice(resolve_eol(eol));
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

/// On Windows, switch stdin/stdout/stderr to binary mode so the C runtime
/// does not mangle CRLF sequences.
#[cfg(windows)]
fn set_binary_mode() {
    extern "C" {
        fn _setmode(fd: i32, mode: i32) -> i32;
    }
    const _O_BINARY: i32 = 0x8000;
    unsafe {
        _setmode(0, _O_BINARY); // stdin
        _setmode(1, _O_BINARY); // stdout
        _setmode(2, _O_BINARY); // stderr
    }
}

fn run(args: Vec<String>) -> ExitCode {
    let mut sep = String::from(" ");
    let mut trim = Trim::Each;
    let mut normalize = true;
    let mut eol = Eol::Auto;

    let mut saw_dash_dash = false;
    let mut rest: Vec<String> = Vec::new();

    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if a == "--" {
            saw_dash_dash = true;
            rest = args[i + 1..].to_vec();
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
                None => return usage_err(&format!("--trim must be each|all|none, got \"{}\"", args[i + 1])),
            }
        } else if let Some(v) = a.strip_prefix("--trim=") {
            match parse_trim(v) {
                Some(m) => {
                    trim = m;
                    i += 1;
                }
                None => return usage_err(&format!("--trim must be each|all|none, got \"{v}\"")),
            }
        } else if a == "--eol" {
            if i + 1 >= args.len() {
                return usage_err("--eol requires a value");
            }
            match parse_eol(&args[i + 1]) {
                Some(m) => {
                    eol = m;
                    i += 2;
                }
                None => return usage_err(&format!("--eol must be auto|lf|crlf, got \"{}\"", args[i + 1])),
            }
        } else if let Some(v) = a.strip_prefix("--eol=") {
            match parse_eol(v) {
                Some(m) => {
                    eol = m;
                    i += 1;
                }
                None => return usage_err(&format!("--eol must be auto|lf|crlf, got \"{v}\"")),
            }
        } else {
            return usage_err(&format!("unknown option or missing -- before ARGS: \"{a}\""));
        }
    }

    let mut stderr = io::stderr();

    if saw_dash_dash {
        let out = append_eol_str(join_args(&rest, &sep, trim), normalize, eol);
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
        let _ = writeln!(stderr, "die: reading stdin failed");
        return ExitCode::from(1);
    }
    let out = append_eol_bytes(buf, normalize, eol);
    let _ = stderr.write_all(&out);
    ExitCode::from(1)
}

fn main() -> ExitCode {
    #[cfg(windows)]
    set_binary_mode();

    let args: Vec<String> = std::env::args().skip(1).collect();
    run(args)
}
