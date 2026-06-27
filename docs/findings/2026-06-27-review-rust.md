# rust expert review

## Cold-start findings

- **finding-1: `std::env::args()` UTF-16 decode on non-Windows**
  On macOS/Linux, `args()` iterates OsStrings and validates UTF-8 per argument, allocating a `Vec<String>`. For a zero-arg TTY call this touches allocator + UTF-8 scanner unnecessarily. Using `std::env::args_os()` and comparing raw OsStr slices avoids the UTF-8 validation; for the hot path (ARG after `--`) only one String decode is needed.
  - magnitude: sub-ms
  - confidence: probably
  - cost: low
  - patch sketch: parse with `args_os()`, convert to `&OsStr` for option matching, only `.to_string_lossy()` / `.into_string()` for values after `--`

- **finding-2: `Vec<String>` clone at `--` split (line 207)**
  `rest = args[i + 1..].to_vec()` clones every post-`--` String. Since `run()` already owns the `args` Vec, draining or splitting in-place would avoid all clones.
  - magnitude: sub-ms
  - confidence: definitely
  - cost: low
  - patch sketch: `let rest = args.drain(i + 1..).collect::<Vec<_>>()` (args already `mut`); or pass a slice reference

- **finding-3: buffered stderr flush overhead**
  `io::stderr()` returns a `StderrLock`-backed type. Each `write_all` goes through a `LineWriter` on some platforms. A single `write(2)` syscall for the whole output (already assembled in `out`) should flush in one call, but verify with `strace` on Linux.
  - magnitude: sub-ms
  - confidence: speculative
  - cost: low
  - patch sketch: no code change needed if `write_all` already issues one syscall; confirm with `strace -e trace=write ./die -- msg`

## Binary-size findings

- **finding-1: Rust stdlib panic + format machinery**
  Even with `panic = "abort"`, the release binary carries format trait implementations for the `writeln!` macro (lines 92, 279). These pull in `core::fmt` infrastructure. Replace `writeln!(io::stderr(), "die: {msg}")` with a sequence of `write_all` calls on byte slices — avoids `fmt::Display` dispatch and trims the format vtable.
  - magnitude: medium (5-15%)
  - confidence: probably
  - cost: low
  - patch sketch: `let _ = stderr.write_all(b"die: "); let _ = stderr.write_all(msg.as_bytes()); let _ = stderr.write_all(b"\n");`

- **finding-2: `String::from(" ")` default sep (line 194)**
  Allocates a heap String for a one-byte constant. Use `&str` throughout `join_args` / option parsing; only allocate when `--sep=VALUE` is actually provided.
  - magnitude: small (<2%, allocation path only)
  - confidence: definitely
  - cost: low
  - patch sketch: `let mut sep: &str = " ";` for the default; heap-allocate only when a custom `--sep` is parsed

- **finding-3: `#![no_std]` not viable here**
  `io::stdin`, `io::stderr`, `Vec`, `String` all require `std`. Switching to `no_std` would require reimplementing all I/O via `extern "C"` (like the Zig impl). Given the 296 KB vs 51 KB gap with Zig, the entire stdlib carry-along is the dominant cost, not any single flag. No partial flag can close this gap.
  - magnitude: large (>50% if viable, but not viable without full rewrite)
  - confidence: speculative
  - cost: high (portability: Windows path would require extensive reimplementation)

## Code quality

- **finding-1: `Trim::All` double-allocates (line 102)**
  `ascii_trim(&args.join(sep))` calls `.to_string()` on an already-trimmed `&str`, then `.join()` itself allocates. Could trim each argument pointer then join once: same semantic but one fewer allocation.

- **finding-2: `append_eol_str` + `from_utf8(term).unwrap()` (line 118)**
  `term` is always `b"\n"` or `b"\r\n"` — the `unwrap()` is infallible but adds a branch that the optimiser may not eliminate at `opt-level="z"`. Prefer `s.push('\n')` / `s.push_str("\r\n")` directly from a `match` on `eol`, removing the `resolve_eol` indirection in this hot-ish call.

- **finding-3: duplicate option-parsing branches (lines 212-261)**
  `--sep ARG` and `--sep=VAL` are handled as separate branches doubling the code size. A small helper `fn next_val<'a>(args, i, flag) -> Result<&'a str, ExitCode>` plus one `strip_prefix` call per option halves the match arms, aiding `opt-level="z"` inlining decisions.

## Risks / blockers

- The `Vec<String>` / `String` changes are safe; no test-observable behaviour changes.
- `args_os()` path requires verifying that non-UTF-8 argument handling remains consistent with current behaviour (currently `std::env::args()` panics on invalid UTF-8; `args_os()` would silently forward garbage — confirm desired behaviour per spec).
- Format removal (`finding BS-1`) must be tested across all `usage_err` call sites; the message must still appear on stderr with correct content.

## TL;DR

- **Cold-start**: eliminate `args[i+1..].to_vec()` clone at `--` split (line 207) — zero-cost refactor, definitely faster on the ARG path (currently the measured hot path at 1.9 ms).
- **Binary-size**: replace `writeln!` format machinery with chained `write_all` byte-slice calls (lines 92, 279/230/238/249/257/260) — removes `core::fmt` dispatch vtable, estimated 5-15% size reduction.
- **Code quality**: the fundamental 296 KB floor is stdlib carry-along; no flag closes the gap to Zig's 51 KB without a full `extern "C"` I/O rewrite. Given spec stability and Windows support, current approach is the right tradeoff; incremental wins above are low-cost polish.
