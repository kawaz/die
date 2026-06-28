# STRUCTURE

Physical layout of the `die` repo (post-DR-0007: single Zig implementation).

```
die/
├── README.md            # English entry point
├── README-ja.md         # 日本語 entry point (origin)
├── LICENSE              # MIT
├── justfile             # task runner (lint / unit / build / test / push)
├── build.zig            # Zig build script (executable + test step + zon import)
├── build.zig.zon        # Zig package manifest; version source of truth
├── src/
│   └── main.zig         # the impl + inline `test` blocks for unit tests
├── tests/
│   ├── run.sh           # non-TTY e2e suite (CLI invocation, EOL, invariants)
│   └── tty.sh           # TTY-path e2e suite (uses python pty allocator)
├── .github/workflows/
│   ├── ci.yml           # 3-OS matrix: fmt + unit + build + e2e
│   └── release.yml      # triggered by build.zig.zon `.version` changes
└── docs/
    ├── DESIGN.md        # specification + design rationale (translation)
    ├── DESIGN-ja.md     # specification + design rationale (origin)
    ├── STRUCTURE.md     # this file
    ├── decisions/       # DRs (decision records)
    │   ├── INDEX.md
    │   └── DR-NNNN-*.md
    ├── findings/        # measurements & investigations
    ├── journal/         # per-stream parallel-work journals
    └── issue/           # TODOs / inbound requests
```

## Parallel implementation phase (Phase 0 — Phase 2)

DR-0003 ran a parallel implementation across four languages (Go / Rust / MoonBit / Zig); DR-0007 chose Zig. The parallel-impl commits are preserved on the `archive/multi-impl-comparison` bookmark, reachable via `jj log -r archive/multi-impl-comparison` (also pushed to `origin/archive/multi-impl-comparison`).

## Conventions

- **Zig project layout**: `build.zig` + `build.zig.zon` + `src/` at the repo root (idiomatic Zig project convention).
- **Unit tests**: `test "..." { }` blocks at the end of `src/main.zig`, run via `zig build test`.
- **E2E tests**: `tests/run.sh` exercises the built binary over the shell (non-TTY paths); `tests/tty.sh` uses a python pty allocator for the TTY-path branches.
- **Optional binary location**: `bin/die` is produced by `just build` (gitignored).
- **Version source of truth**: `.version` in `build.zig.zon`. `src/main.zig` pulls it in at compile time via `@import("zon").version`.
- **Release artifacts**: 7 target binaries (darwin / linux-gnu / linux-musl × amd64 / arm64 + windows-amd64). `release.yml` is triggered by `.version` changes in `build.zig.zon`.
