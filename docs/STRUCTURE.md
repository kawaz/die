# STRUCTURE

`die` リポの物理構造。

```
die/
├── README.md            # English entry point
├── README-ja.md         # 日本語 entry point (origin)
├── LICENSE              # MIT
└── docs/
    ├── DESIGN.md        # 仕様 + 設計判断 (英訳)
    ├── DESIGN-ja.md     # 仕様 + 設計判断 (origin)
    ├── STRUCTURE.md     # 本ファイル
    ├── ROADMAP.md       # 将来検討項目
    ├── decisions/       # DR (判断記録)
    │   ├── INDEX.md
    │   └── DR-NNNN-*.md
    └── issue/           # TODO / 依頼受付窓口
```

実装言語が決まった時点で、対応する build/source ディレクトリ (例: `go/`, `rust/`, `mbt/`, `zig/`) を追加する想定。並行実装期間中は複数同居の可能性あり。
