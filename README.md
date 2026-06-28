# die

> English | [日本語](./README-ja.md)

A tiny CLI that prints a message to stderr and exits 1.

## Motivation

Provide a generic `die` for shell scripts and justfiles (`cmd || die "context"`) as a **standalone OS binary**, not as a re-defined shell function. Brings the Perl/Ruby-style `die` to the command line.

## Installation

### Homebrew (macOS / Linuxbrew)

```sh
brew install kawaz/tap/die
```

### Direct download (Docker / scratch / Alpine / distroless)

Pick the artifact that matches your environment from the latest [release](https://github.com/kawaz/die/releases):

| target | use it when |
|---|---|
| `die-linux-amd64-musl` / `die-linux-arm64-musl` | statically linked. drop into `FROM scratch`, `FROM alpine`, `FROM gcr.io/distroless/static` — no glibc needed |
| `die-linux-amd64` / `die-linux-arm64` | dynamically linked against glibc. for `FROM ubuntu` / `FROM debian` / `FROM gcr.io/distroless/base` |
| `die-darwin-amd64` / `die-darwin-arm64` | macOS native binaries (`brew` covers this on local machines) |
| `die-windows-amd64.exe` | Windows native |

Example Dockerfile snippet (scratch + arm64):

```dockerfile
FROM scratch
ADD https://github.com/kawaz/die/releases/latest/download/die-linux-arm64-musl /usr/local/bin/die
```

Implemented in Zig (see [DR-0007](./docs/decisions/DR-0007-adopt-zig-archive-others.md) for the rationale).

## Usage

```sh
die [opts] -- ARGS...
die [-n] <FILE
```

### Options

| option | behavior |
|---|---|
| `--sep STR` | Joiner between ARGS, default `" "` |
| `--trim MODE` | ASCII-whitespace handling (each / all / none), default `each` |
| `-n` | Disable LF normalization (= cat equivalent byte-transparent output) |

### Examples

```sh
die -- "config error: missing token"
die --sep ', ' -- "stale build" "no manifest"
some-cmd | die
cmd_with_lf | die -n
```

### Behavior

- Output always goes to **stderr**
- Exit code is **always 1** (cannot be changed via option / env)
- Options come before `--`, ARGS after. `--` is **required**
- For stdin input (file redirect / pipe), the trailing LF is normalized by default (= one LF is appended if the content does not end with LF). Unlike `cat`, `die` is for human-readable stderr, not byte-safe streaming
- ARGS take priority; when both stdin and ARGS are supplied, stdin is ignored

## Documentation

- [DESIGN.md](./docs/DESIGN.md) — Specification and design rationale
- [STRUCTURE.md](./docs/STRUCTURE.md) — Repository structure
- [ROADMAP.md](./docs/ROADMAP.md) — Future considerations

## License

MIT License, Yoshiaki Kawazu (@kawaz)
