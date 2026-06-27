# mbt expert review

## Cold-start findings

- **C1: `getenv("OS")` called on every startup via `is_windows_host()`** (main.mbt:301, stub.c:20).
  On non-Windows the result is always `false` but is computed at runtime via a libc `getenv`+`strcmp`. The MoonBit native backend has no compile-time OS constant, so this is a real syscall-adjacent cost. The result is queried twice: once at the top of `main` (line 301) for `_setmode`, once inside `resolve_eol` (line 187) if `--eol auto`. Two calls instead of one.
  - magnitude: sub-ms (getenv is fast, but the redundant call wastes a string comparison)
  - confidence: definitely
  - cost: low
  - patch sketch: cache `is_windows_host()` result into a `let is_win = is_windows_host()` at start of `main`, pass it down or store in a module-level lazy val. Eliminates the second `getenv` in `resolve_eol`.

- **C2: `@env.args()` allocates a MoonBit Array at startup** (main.mbt:306).
  The stdlib `env` package likely copies `argv` into a managed `Array[String]`, allocating per-arg strings. For `die -- msg`, this creates at minimum 2 heap-allocated strings (program name + arg) before any work. With TCC-compiled runtime, the allocator overhead is non-trivial.
  - magnitude: sub-ms
  - confidence: probably
  - cost: medium (would require bypassing `moonbitlang/core/env` with a direct `extern "c"` argv read)
  - patch sketch: expose `argc/argv` via `extern "c"` and parse them as raw C strings; avoid MoonBit Array allocation for the arg vector entirely.

- **C3: `string_to_utf8` uses a growable `Array[Byte]` (main.mbt:93)**.
  For the ARG path, the joined output string is converted to UTF-8 via repeated `Array.push` calls, then `Bytes::from_array`. This is two heap allocations plus O(n) copy. For small ASCII messages (the common case), the growth loop adds unnecessary overhead.
  - magnitude: sub-ms
  - confidence: probably
  - cost: medium
  - patch sketch: pre-allocate with capacity hint (`Array::new(capacity=str.length())`) since UTF-8 output is at most 4x the UTF-16 length; avoids reallocation on short ASCII strings.

## Binary-size findings

- **B1: MoonBit stdlib bulk — `moonbitlang/core/env` import** (moon.pkg.json:4).
  Importing even one package from `moonbitlang/core` pulls in the entire core stdlib object because MoonBit native currently links object files, not tree-shaken bitcode. The `env` package is the sole import; it adds the MoonBit runtime harness (GC metadata, panic infrastructure, string interning tables).
  - magnitude: large (>20%) — estimated 60–120 KB of runtime overhead for a program that only needs ~3 KB of actual logic
  - confidence: probably
  - cost: high (would require replacing `@env.args()` with a direct `extern "c"` argc/argv bridge, then dropping the `moonbitlang/core/env` import entirely)
  - patch sketch: add `extern "c" fn c_argc() -> Int` and `extern "c" fn c_argv_at(i: Int) -> Bytes` stubs in `stub.c`, implement argv access without the stdlib package. Remove `"import"` from `moon.pkg.json`.

- **B2: No explicit strip / LTO flags for native build**.
  `moon build --target native --release` uses the default TCC backend which emits C then compiles with Clang. The Clang invocation may not include `-flto`, `-Os`/`-Oz`, or `-dead_strip` (macOS linker flag). Current binary is 311 KB vs Rust's 302 KB despite simpler logic — residual debug sections likely present.
  - magnitude: medium (5–20%) — `strip -x` on the current binary saves ~10–20 KB typically
  - confidence: definitely
  - cost: low
  - patch sketch: run `strip -x _build/native/release/build/main/main.exe` as a post-build step in the justfile. Investigate whether `moon build` accepts pass-through Clang flags for `-Oz -flto`.

- **B3: No-op `_setmode` stub compiled into every non-Windows binary** (stub.c:28–33).
  The `_setmode` stub is dead code on POSIX. It occupies minimal space itself but its presence keeps the `c_setmode` extern declaration and the guarded call site in the binary.
  - magnitude: small (<5%)
  - confidence: definitely
  - cost: low
  - patch sketch: already correctly `#ifndef _WIN32` guarded; no code change needed. Impact is negligible.

## Code quality

- **Q1: `help_text` built by string concatenation at compile time but stored as a String constant** (main.mbt:48–67). MoonBit will likely fold this at compile time, but it results in a UTF-16 heap String; converting to bytes on every TTY-path invocation via `string_to_utf8` allocates. For a `--help`-like path this is acceptable, but the constant would be better as a `Bytes` literal if the language supports it.

- **Q2: `append_eol_str` branches on `last == 0x0d` but both branches do `s + eol_str`** (main.mbt:252–255). Dead branch — bare CR and no-EOL are treated identically. Simplify to a single `else` arm.

- **Q3: `read_stdin_all` copies byte-by-byte from `FixedArray[Byte]` into `Array[Byte]`** (main.mbt:152–155). The inner `for` loop calling `result.push(buf[i])` is O(n) with per-element overhead. A bulk `Array.append` or `blit`-style copy would be faster and may reduce binary size by eliminating the loop monomorphisation.

- **Q4: `is_windows_host()` is a non-`pub` fn called from two callsites** (main.mbt:80, 187, 301). Not inlined by TCC; add `#[inline]` hint or merge into a single cached call.

## Risks / blockers

- MoonBit native backend cross-compilation is not surfaced in `moon` CLI (confirmed in findings). Stripping `moonbitlang/core/env` (B1) would be the highest-ROI change but requires significant boilerplate in stub.c; risk of breaking argument parsing correctness on edge cases (null bytes, multi-byte paths).
- TCC backend limits optimization: even with `-Oz` pass-through, TCC-compiled intermediary C limits what Clang can eliminate. Binary size floor is higher than Rust/Zig until MoonBit adopts LLVM IR output as its release path.
- `moon build` flag pass-through to Clang is undocumented; may require patching the justfile with a manual `clang` re-link step instead of relying on `moon`.

## TL;DR

- **Cold-start**: Cache `is_windows_host()` result (C1) — definitely saves a redundant `getenv`+`strcmp`; replace `@env.args()` with direct argc/argv C bridge (C2) to eliminate stdlib arg-array allocation (probably sub-ms, medium cost).
- **Binary size**: Drop `moonbitlang/core/env` import by bridging argv directly in stub.c (B1, large impact >20%, high cost); add `strip -x` post-build step immediately (B2, medium impact, low cost).
- **Code quality**: Fix dead branch in `append_eol_str` (Q2, zero cost); bulk-copy in `read_stdin_all` instead of per-byte push (Q3, low cost, measurable throughput win on large stdin).
