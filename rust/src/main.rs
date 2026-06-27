// die — write a message to stderr and exit 1.
//
// Spec: see ../../docs/DESIGN.md (and DR-0001 / DR-0002 / DR-0005 / DR-0006).

use std::io::{self, Read, Write};
use std::process::ExitCode;

/// Switch stdin (fd 0) and stderr (fd 2) to binary mode on Windows.
/// Called only under -n (cat-equivalent byte-transparent mode, DR-0006).
/// On Unix this is a no-op; the CRT text-mode conversion does not exist.
#[cfg(windows)]
fn set_binary_mode() {
    extern "C" {
        fn _setmode(fd: i32, mode: i32) -> i32;
    }
    const _O_BINARY: i32 = 0x8000;
    unsafe {
        _setmode(0, _O_BINARY); // stdin
        _setmode(2, _O_BINARY); // stderr
    }
}

#[cfg(not(windows))]
fn set_binary_mode() {
    // No-op on non-Windows: no CRT text-mode conversion to suppress.
}

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

    // DR-0006: under -n, switch to binary mode on Windows to suppress CRT
    // text-mode \n → \r\n conversion and achieve byte-transparent cat-equivalent.
    if !normalize {
        set_binary_mode();
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

#[cfg(test)]
mod tests {
    use super::*;

    // ── ascii_trim ───────────────────────────────────────────────────────────

    #[test]
    fn trim_empty_string() {
        assert_eq!(ascii_trim(""), "");
    }

    #[test]
    fn trim_all_whitespace_only() {
        assert_eq!(ascii_trim("   \t\n\x0B\x0C\r   "), "");
    }

    #[test]
    fn trim_leading_sp() {
        assert_eq!(ascii_trim(" hello"), "hello");
    }

    #[test]
    fn trim_trailing_sp() {
        assert_eq!(ascii_trim("hello "), "hello");
    }

    #[test]
    fn trim_leading_ht() {
        assert_eq!(ascii_trim("\thello"), "hello");
    }

    #[test]
    fn trim_trailing_ht() {
        assert_eq!(ascii_trim("hello\t"), "hello");
    }

    #[test]
    fn trim_leading_lf() {
        assert_eq!(ascii_trim("\nhello"), "hello");
    }

    #[test]
    fn trim_trailing_lf() {
        assert_eq!(ascii_trim("hello\n"), "hello");
    }

    #[test]
    fn trim_leading_vt() {
        assert_eq!(ascii_trim("\x0Bhello"), "hello");
    }

    #[test]
    fn trim_trailing_vt() {
        assert_eq!(ascii_trim("hello\x0B"), "hello");
    }

    #[test]
    fn trim_leading_ff() {
        assert_eq!(ascii_trim("\x0Chello"), "hello");
    }

    #[test]
    fn trim_trailing_ff() {
        assert_eq!(ascii_trim("hello\x0C"), "hello");
    }

    #[test]
    fn trim_leading_cr() {
        assert_eq!(ascii_trim("\rhello"), "hello");
    }

    #[test]
    fn trim_trailing_cr() {
        assert_eq!(ascii_trim("hello\r"), "hello");
    }

    #[test]
    fn trim_combined_leading_trailing() {
        assert_eq!(ascii_trim(" \t\r\n hello world \n\r\t "), "hello world");
    }

    #[test]
    fn trim_preserves_interior_whitespace() {
        assert_eq!(ascii_trim("  hello   world  "), "hello   world");
    }

    #[test]
    fn trim_preserves_interior_tab_lf() {
        assert_eq!(ascii_trim("\tfoo\tbar\n"), "foo\tbar");
    }

    #[test]
    fn trim_no_whitespace() {
        assert_eq!(ascii_trim("hello"), "hello");
    }

    // Unicode whitespace MUST NOT be trimmed (DR-0001: ASCII-only).
    #[test]
    fn trim_nbsp_u00a0_not_trimmed() {
        // NBSP (U+00A0) — leading and trailing
        let s = "\u{00A0}hello\u{00A0}";
        assert_eq!(ascii_trim(s), s);
    }

    #[test]
    fn trim_line_sep_u2028_not_trimmed() {
        // LINE SEPARATOR (U+2028)
        let s = "\u{2028}hello\u{2028}";
        assert_eq!(ascii_trim(s), s);
    }

    #[test]
    fn trim_fullwidth_sp_u3000_not_trimmed() {
        // IDEOGRAPHIC SPACE (U+3000)
        let s = "\u{3000}hello\u{3000}";
        assert_eq!(ascii_trim(s), s);
    }

    // ── parse_trim ───────────────────────────────────────────────────────────

    #[test]
    fn parse_trim_each() {
        assert!(matches!(parse_trim("each"), Some(Trim::Each)));
    }

    #[test]
    fn parse_trim_all() {
        assert!(matches!(parse_trim("all"), Some(Trim::All)));
    }

    #[test]
    fn parse_trim_none() {
        assert!(matches!(parse_trim("none"), Some(Trim::None)));
    }

    #[test]
    fn parse_trim_rejects_empty() {
        assert!(parse_trim("").is_none());
    }

    #[test]
    fn parse_trim_rejects_unknown() {
        assert!(parse_trim("EACH").is_none());
        assert!(parse_trim("Both").is_none());
        assert!(parse_trim("trim").is_none());
        assert!(parse_trim(" each").is_none());
        assert!(parse_trim("each ").is_none());
    }

    // ── join_args ────────────────────────────────────────────────────────────

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    // 0-arg cases
    #[test]
    fn join_zero_args_each() {
        assert_eq!(join_args(&s(&[]), " ", Trim::Each), "");
    }

    #[test]
    fn join_zero_args_all() {
        assert_eq!(join_args(&s(&[]), " ", Trim::All), "");
    }

    #[test]
    fn join_zero_args_none() {
        assert_eq!(join_args(&s(&[]), " ", Trim::None), "");
    }

    // 1-arg cases
    #[test]
    fn join_one_arg_each_trims() {
        assert_eq!(join_args(&s(&[" hello "]), " ", Trim::Each), "hello");
    }

    #[test]
    fn join_one_arg_all_trims() {
        assert_eq!(join_args(&s(&[" hello "]), " ", Trim::All), "hello");
    }

    #[test]
    fn join_one_arg_none_preserves() {
        assert_eq!(join_args(&s(&[" hello "]), " ", Trim::None), " hello ");
    }

    // 3-arg default sep
    #[test]
    fn join_three_args_each_default_sep() {
        assert_eq!(join_args(&s(&[" a ", " b ", " c "]), " ", Trim::Each), "a b c");
    }

    #[test]
    fn join_three_args_all_default_sep() {
        // Trim::All joins first then strips outer whitespace
        assert_eq!(join_args(&s(&[" a ", " b ", " c "]), " ", Trim::All), "a   b   c");
    }

    #[test]
    fn join_three_args_none_default_sep() {
        assert_eq!(join_args(&s(&[" a ", " b ", " c "]), " ", Trim::None), " a   b   c ");
    }

    // Empty sep
    #[test]
    fn join_three_args_each_empty_sep() {
        assert_eq!(join_args(&s(&[" a ", " b ", " c "]), "", Trim::Each), "abc");
    }

    #[test]
    fn join_three_args_none_empty_sep() {
        assert_eq!(join_args(&s(&[" a ", " b ", " c "]), "", Trim::None), " a  b  c ");
    }

    // Multi-char sep
    #[test]
    fn join_three_args_each_multichar_sep() {
        assert_eq!(join_args(&s(&[" a ", " b ", " c "]), " | ", Trim::Each), "a | b | c");
    }

    // Empty ARG mixed in
    #[test]
    fn join_with_empty_arg_each() {
        // Empty ARG stays empty after trim
        assert_eq!(join_args(&s(&["a", "", "b"]), " ", Trim::Each), "a  b");
    }

    #[test]
    fn join_with_empty_arg_all() {
        assert_eq!(join_args(&s(&["a", "", "b"]), " ", Trim::All), "a  b");
    }

    #[test]
    fn join_with_empty_arg_none() {
        assert_eq!(join_args(&s(&["a", "", "b"]), " ", Trim::None), "a  b");
    }

    #[test]
    fn join_with_whitespace_only_arg_each() {
        // Trim::Each trims each ARG; whitespace-only becomes ""
        assert_eq!(join_args(&s(&["a", "  ", "b"]), "-", Trim::Each), "a--b");
    }

    #[test]
    fn join_with_whitespace_only_arg_none() {
        assert_eq!(join_args(&s(&["a", "  ", "b"]), "-", Trim::None), "a-  -b");
    }

    // Trim::All strips only leading/trailing of concatenated result
    #[test]
    fn join_all_strips_outer_only() {
        assert_eq!(join_args(&s(&[" a ", " b "]), ",", Trim::All), "a , b");
    }

    // ── append_lf_str ────────────────────────────────────────────────────────

    #[test]
    fn append_lf_str_normalize_false_passes_through() {
        let cases = ["", "X", "X\n", "X\r\n", "X\r", "X\n\n"];
        for &c in &cases {
            assert_eq!(append_lf_str(c.to_string(), false), c);
        }
    }

    #[test]
    fn append_lf_str_empty_gets_lf() {
        // DR-0002: "" → "\n"
        assert_eq!(append_lf_str("".to_string(), true), "\n");
    }

    #[test]
    fn append_lf_str_no_trailing_lf_gets_lf() {
        assert_eq!(append_lf_str("X".to_string(), true), "X\n");
    }

    #[test]
    fn append_lf_str_trailing_lf_untouched() {
        assert_eq!(append_lf_str("X\n".to_string(), true), "X\n");
    }

    #[test]
    fn append_lf_str_trailing_crlf_untouched() {
        // CRLF ends with \n → already ends with LF → no extra LF
        assert_eq!(append_lf_str("X\r\n".to_string(), true), "X\r\n");
    }

    #[test]
    fn append_lf_str_trailing_cr_gets_lf() {
        // CR alone does NOT end with \n
        assert_eq!(append_lf_str("X\r".to_string(), true), "X\r\n");
    }

    #[test]
    fn append_lf_str_double_lf_preserved() {
        assert_eq!(append_lf_str("X\n\n".to_string(), true), "X\n\n");
    }

    // ── append_lf_bytes ──────────────────────────────────────────────────────

    #[test]
    fn append_lf_bytes_normalize_false_passes_through() {
        let cases: &[&[u8]] = &[b"", b"X", b"X\n", b"X\r\n", b"X\r", b"X\n\n"];
        for &c in cases {
            assert_eq!(append_lf_bytes(c.to_vec(), false), c);
        }
    }

    #[test]
    fn append_lf_bytes_empty_gets_lf() {
        assert_eq!(append_lf_bytes(vec![], true), b"\n");
    }

    #[test]
    fn append_lf_bytes_no_trailing_lf_gets_lf() {
        assert_eq!(append_lf_bytes(b"X".to_vec(), true), b"X\n");
    }

    #[test]
    fn append_lf_bytes_trailing_lf_untouched() {
        assert_eq!(append_lf_bytes(b"X\n".to_vec(), true), b"X\n");
    }

    #[test]
    fn append_lf_bytes_trailing_crlf_untouched() {
        assert_eq!(append_lf_bytes(b"X\r\n".to_vec(), true), b"X\r\n");
    }

    #[test]
    fn append_lf_bytes_trailing_cr_gets_lf() {
        assert_eq!(append_lf_bytes(b"X\r".to_vec(), true), b"X\r\n");
    }

    #[test]
    fn append_lf_bytes_double_lf_preserved() {
        assert_eq!(append_lf_bytes(b"X\n\n".to_vec(), true), b"X\n\n");
    }

    #[test]
    fn append_lf_bytes_arbitrary_binary_gets_lf() {
        // Binary payload not ending in 0x0A
        let input = vec![0xDE, 0xAD, 0xBE, 0xEF];
        let mut expected = input.clone();
        expected.push(b'\n');
        assert_eq!(append_lf_bytes(input, true), expected);
    }
}
