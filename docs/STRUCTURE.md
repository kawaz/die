# STRUCTURE

`die` リポの物理構造 (post-DR-0007: Zig 一本化)。

```
die/
├── README.md            # English entry point
├── README-ja.md         # 日本語 entry point (origin)
├── LICENSE              # MIT
├── VERSION              # SemVer, bump-semver-managed
├── justfile             # task runner (lint / unit / build / test / push)
├── build.zig            # Zig build script (executable + test step)
├── build.zig.zon        # Zig package manifest (name, version, minimum_zig)
├── src/
│   └── main.zig         # the impl + inline `test` blocks for unit tests
├── tests/
│   └── run.sh           # shared shell e2e suite (CLI invocation, EOL, invariants)
├── .github/workflows/
│   └── ci.yml           # 3-OS matrix: fmt + unit + build + e2e
└── docs/
    ├── DESIGN.md        # 仕様 + 設計判断 (英訳)
    ├── DESIGN-ja.md     # 仕様 + 設計判断 (origin)
    ├── STRUCTURE.md     # 本ファイル
    ├── ROADMAP.md       # 将来検討項目
    ├── decisions/       # DR (判断記録)
    │   ├── INDEX.md
    │   └── DR-NNNN-*.md
    ├── findings/        # 計測結果・調査 (DR と研究結果)
    ├── journal/         # 並列作業の journal
    └── issue/           # TODO / 依頼受付窓口
```

## 並行実装期間 (= Phase 0 〜 Phase 2) について

DR-0003 で 4 言語 (Go / Rust / MoonBit / Zig) の並行実装を経て、DR-0007 で Zig 採用を決定。並行実装の commit 系列は `archive/multi-impl-comparison` bookmark に保存されており、`jj log -r archive/multi-impl-comparison` で参照可能 (origin/`archive/multi-impl-comparison` にも push 済)。

## 慣習

- **Zig project layout**: `build.zig` + `build.zig.zon` + `src/` を repo root に配置 (= idiomatic Zig project の慣習に倣う)
- **unit test**: `src/main.zig` 末尾の `test "..." { }` block で `zig build test` から実行
- **e2e test**: `tests/run.sh` で built binary に対し shell 経由で検証
- **任意 binary 配置**: `bin/die` は `just build` で生成 (`.gitignore` 済)
