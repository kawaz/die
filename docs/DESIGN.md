# DESIGN

> English | [日本語](./DESIGN-ja.md)

Specification and design rationale for `die`.

## Domain

In shell scripts and justfiles, the pattern "print a message to stderr and exit with failure" appears constantly. The bash idiom `die() { echo "$*" >&2; exit 1; }` is long-established but has problems:

- Boilerplate re-declared in every script
- A shell function, so it cannot be distributed across OS environments uniformly
- justfiles / docker images / other shells each end up with separate implementations

By shipping it as a **single OS binary**, `brew install die` makes it available everywhere. This is in the same neighborhood as `/usr/bin/yes` and `/usr/bin/false` — a tiny base utility.

## Specification

### Usage

```
die [opts] -- ARGS...
die [-n] <FILE
die --help
die --version
```

### Options

| option | behavior |
|---|---|
| `--sep STR` | Joiner between ARGS, default `" "` |
| `--trim MODE` | ASCII-whitespace handling (`each` / `all` / `none`), default `each` |
| `-n` | Disable LF normalization (= cat equivalent byte-transparent output) |
| `--help` | Show help to stderr and exit **0** (meta query). Must appear before `--`; after `--` it is treated as an ARG (literal `--help`). |
| `--version` | Print `die <version>` to stderr and exit **0** (meta query). Must appear before `--`; after `--` it is treated as an ARG. |

`--trim` MODE:

- `each`: strip ASCII whitespace around each ARG individually (e.g. `" foo "` → `"foo"`)
- `all`: strip ASCII whitespace around the joined string (after `--sep` concatenation)
- `none`: no trimming

`--trim` strips only the 6 ASCII whitespace bytes (SP, HT, LF, VT, FF, CR — POSIX `[[:space:]]`). Unicode whitespace such as NBSP or U+2028 is intentionally not stripped — the conventional shell view of whitespace is what we follow.

### Invariants

- **Output destination**: always stderr
- **Exit code**: 1 for die's actual operation (ARG / stdin paths, bare-TTY help fallback, any usage error). **0 only for explicit meta queries** — `--help` and `--version` (= the user asking die about itself, not asking die to die). See [DR-0009](./decisions/DR-0009-exit-code-policy-and-version-option.md).
- **`--` is required**: the separator between opts and ARGS. `die foo` (without `--`) is a syntax error
- **Environment variables**: none — all behavior is contained in argv

### stdin handling

Branch is decided by `--` presence and (when no `--`) by stdin TTY classification:

- ARGS supplied (= `--` present) → ARG path. stdin is ignored even if piped.
- ARGS empty (= no `--`) + stdin is NOT a TTY → forward stdin to stderr. "Not a TTY" covers anonymous pipes, named FIFOs, regular files, char devices (`/dev/null`, `/dev/zero`, …), sockets (process substitution), and block devices. `/dev/null` is forwarded as empty input and gets a single `\n` via the normalize rule.
- ARGS empty (= no `--`) + stdin IS a TTY → emit help to stderr and exit 1 (= bare-TTY help fallback, usage error category — distinct from the explicit `--help` query which exits 0).

TTY detection (see [DR-0008](./decisions/DR-0008-stdin-tty-routing-and-help-option.md) and [findings/2026-06-28-tty-detection-cross-os.md](./findings/2026-06-28-tty-detection-cross-os.md)):

- POSIX: `isatty(3)` (= `ioctl(TCGETS)` / `TIOCGETA`).
- Windows: `GetConsoleMode()` on the std handle. MSVCRT `_isatty()` is intentionally NOT used — it lies about NUL device (reports it as a terminal).
- Cygwin / MSYS2 / Git Bash pty: named-pipe name pattern match (`\msys-…-ptyN-…`) via `NtQueryObject`, so `die` typed bare at a Git Bash prompt also shows help.

### Trailing LF normalization

Unless `-n` is passed, if the content does not end with LF, one is appended. Pre-existing duplicate newlines (e.g. `\n\n`) are preserved.

- ARG path: if the trailing char of the joined string is not LF, append one
- stdin path: same

This is intentionally different from `cat`, which is byte-safe. `die` is a first-class tool for human-readable stderr, so it defaults to preventing the case where the next shell prompt does not start on a new line.

On Windows, default mode lets the CRT text-mode convert `\n` to `\r\n`; die does not intervene. With `-n`, the CRT conversion is suppressed for true byte-transparency (Rust / MoonBit / Zig call `_setmode(_O_BINARY)` on stderr; Go's WriteFile is already binary-transparent).

## Design Decisions

### Why `--` is required

To guarantee the "you can pass anything safely" property. With free-form options (e.g. `die -e 2 "msg"`), ARGs starting with `-` risk being misinterpreted as flags. Enforcing `die -- "$@"` completely insulates ARG contents from option parsing.

### Why no environment variables

Behavior controlled via env (e.g. `DIE_SEP`) leaks across subshells unless you wrap calls in subshells, which becomes an accident source. Keeping everything in argv makes each invocation atomically predictable.

### Why no `--code` / `DIE_CODE`

`die` has the single responsibility of "fail and exit". When you need a different exit code, express it through another path (`cmd; exit 2`). Exit 1 is enough.

### Why no `-N` (explicit on)

Defaults don't need explicit forms — not writing the option is the same. Adding `-N` would only bloat help with boilerplate. `-n` (off) alone suffices.

### Why no long form `--trailing-newline=on/off` for `-n`

`-n` is `die`'s only short option. Short forms are reserved for frequent usage; the long form would only add API surface without value.

### Help & version meta queries

Two paths emit the same help text:

1. `die` with no ARGS and stdin is a TTY → help to stderr, **exit 1** (bare-TTY fallback, usage error — user didn't know what to feed).
2. `--help` option placed before `--` → same help, regardless of stdin state, **exit 0** (explicit meta query — user asked, die answered).

`--version` mirrors the explicit-`--help` shape: `die --version` → `die <X.Y.Z>\n` to stderr, exit 0.

DR-0001's "after `--` anything passes safely" property is preserved: `die -- --help` and `die -- --version` echo the literal strings to stderr (= treated as ARGs, exit 1). See [DR-0008](./decisions/DR-0008-stdin-tty-routing-and-help-option.md) and [DR-0009](./decisions/DR-0009-exit-code-policy-and-version-option.md).

### Why explain "pipe-context LF appending differs from cat"

When users pipe content into `die` (`cat <file | die`), the trailing LF behavior differs from `cat`. This is an intentional design choice based on `die`'s purpose (human-readable stderr), and `-n` provides byte-safe behavior matching `cat`. Help and README will state this explicitly to avoid confusion.

## Distribution

Implemented in **Zig** (DR-0007). Distributed via `brew install kawaz/tap/die`. The parallel-implementation phase (Go / Rust / MoonBit / Zig comparison per DR-0003) is preserved on the `archive/multi-impl-comparison` bookmark; see `docs/findings/2026-06-27-language-comparison.md` for the measured-data justification.

## Related

- [DR-0001](./decisions/DR-0001-spec-and-option-removal.md) — Specification and the option-removal design
- [DR-0002](./decisions/DR-0002-pipe-lf-normalization.md) — Default-on trailing-LF normalization for pipe input
- [DR-0003](./decisions/DR-0003-parallel-implementation-language.md) — Parallel implementation language comparison
