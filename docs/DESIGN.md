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
```

### Options

| option | behavior |
|---|---|
| `--sep STR` | Joiner between ARGS, default `" "` |
| `--trim MODE` | ASCII-whitespace handling (`each` / `all` / `none`), default `each` |
| `-n` | Disable LF normalization (= cat equivalent byte-transparent output) |

`--trim` MODE:

- `each`: strip ASCII whitespace around each ARG individually (e.g. `" foo "` → `"foo"`)
- `all`: strip ASCII whitespace around the joined string (after `--sep` concatenation)
- `none`: no trimming

`--trim` strips only the 6 ASCII whitespace bytes (SP, HT, LF, VT, FF, CR — POSIX `[[:space:]]`). Unicode whitespace such as NBSP or U+2028 is intentionally not stripped — the conventional shell view of whitespace is what we follow.

### Invariants

- **Output destination**: always stderr
- **Exit code**: always 1
- **`--` is required**: the separator between opts and ARGS. `die foo` (without `--`) is a syntax error
- **Environment variables**: none — all behavior is contained in argv

### stdin handling

- ARGS empty + stdin is a pipe / redirect → read stdin and forward to stderr
- ARGS supplied + stdin also supplied → ARGS take priority; stdin is ignored (tolerant default)
- ARGS empty + stdin is a TTY → emit help to stderr and exit 1

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

### Help

When `die` is invoked with no ARGS and stdin is a TTY, help is emitted to stderr (with exit 1). A separate `--help` is intentionally not provided: by removing option parsing entirely, the user can freely pass strings like `--help` as ARGs (e.g. in an error message that mentions "see --help for details") without conflict.

### Why explain "pipe-context LF appending differs from cat"

When users pipe content into `die` (`cat <file | die`), the trailing LF behavior differs from `cat`. This is an intentional design choice based on `die`'s purpose (human-readable stderr), and `-n` provides byte-safe behavior matching `cat`. Help and README will state this explicitly to avoid confusion.

## Distribution

Implemented in **Zig** (DR-0007). Distributed via `brew install kawaz/tap/die`. The parallel-implementation phase (Go / Rust / MoonBit / Zig comparison per DR-0003) is preserved on the `archive/multi-impl-comparison` bookmark; see `docs/findings/2026-06-27-language-comparison.md` for the measured-data justification.

## Related

- [DR-0001](./decisions/DR-0001-spec-and-option-removal.md) — Specification and the option-removal design
- [DR-0002](./decisions/DR-0002-pipe-lf-normalization.md) — Default-on trailing-LF normalization for pipe input
- [DR-0003](./decisions/DR-0003-parallel-implementation-language.md) — Parallel implementation language comparison
