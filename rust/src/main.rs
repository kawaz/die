// die — write a message to stderr and exit 1.
//
// Spec: see ../../docs/DESIGN.md (and DR-0001 / DR-0002).

use std::io::{self, Read, Write};
use std::process::ExitCode;

const HELP: &str = "\
die — print ARGS (or stdin) to stderr and exit 1.

Usage:
  die [opts] -- ARGS...
  die [-n] <FILE

Options:
  --sep STR       Joiner between ARGS, default \" \"
  --trim MODE     Whitespace handling: each (default) | all | none
  -n              Disable trailing-LF normalization (stdin path)

Behavior:
  - Output is always stderr, exit code is always 1.
  - \"--\" is required when ARGS are present.
  - With no ARGS, stdin (pipe/redirect) is forwarded to stderr; a missing
    trailing LF is appended unless -n is given.
  - On a TTY with no ARGS, this help is printed and exit 1.
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

fn usage_err(msg: &str) -> ExitCode {
    let _ = writeln!(io::stderr(), "die: {msg}");
    ExitCode::from(1)
}

fn join_args(args: &[String], sep: &str, trim: Trim) -> String {
    match trim {
        Trim::Each => {
            let parts: Vec<&str> = args.iter().map(|a| a.trim()).collect();
            parts.join(sep)
        }
        Trim::All => args.join(sep).trim().to_string(),
        Trim::None => args.join(sep),
    }
}

fn append_lf_str(mut s: String, normalize: bool) -> String {
    if !normalize {
        return s;
    }
    if !s.ends_with('\n') {
        s.push('\n');
    }
    s
}

fn append_lf_bytes(mut b: Vec<u8>, normalize: bool) -> Vec<u8> {
    if !normalize {
        return b;
    }
    if b.last() != Some(&b'\n') {
        b.push(b'\n');
    }
    b
}

fn is_stdin_tty() -> bool {
    // unix-only; die ships for posix-like targets.
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        let fd = io::stdin().as_raw_fd();
        // SAFETY: isatty(3) is signal-safe and side-effect-free.
        unsafe { libc_isatty(fd) }
    }
    #[cfg(not(unix))]
    {
        false
    }
}

#[cfg(unix)]
unsafe fn libc_isatty(fd: i32) -> bool {
    // Avoid pulling in the `libc` crate dependency for one function.
    extern "C" {
        fn isatty(fd: i32) -> i32;
    }
    isatty(fd) != 0
}

fn run(args: Vec<String>) -> ExitCode {
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
        } else {
            return usage_err(&format!("unknown option or missing -- before ARGS: \"{a}\""));
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
        let _ = writeln!(stderr, "die: reading stdin failed");
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
