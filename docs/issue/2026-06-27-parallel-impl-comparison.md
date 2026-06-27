---
title: 並行実装 + 比較検討 (Go / Rust / MoonBit / Zig)
status: open
category: task
created: 2026-06-27T11:19:13+09:00
last_read:
open_entered: 2026-06-27T11:19:13+09:00
wip_entered:
blocked_entered:
pending_entered:
discarded_entered:
resolved_entered:
discard_reason:
pending_reason:
close_reason:
blocked_by:
origin: 自リポ TODO
---

# 並行実装 + 比較検討 (Go / Rust / MoonBit / Zig)

## 概要

DR-0001 で仕様確定済み。実装言語は **クロスコンパイル可能なモダン言語** で並行実装して比較検討する方針。

## 背景

DR-0001 で仕様確定済み。実装言語は **クロスコンパイル可能なモダン言語** で並行実装して比較検討する方針。

## 対象言語

- **Go**: 配布実績、homebrew tap 統合パターン確立、クロスコンパイル成熟、binary size 大きめ
- **Rust**: 小さい binary、release optimization 効きやすい、cross compile やや手間
- **MoonBit**: dogfood として MoonBit native backend 検証、エコシステム熟成度未確認
- **Zig**: 最小 binary 候補、クロスコンパイル最強、エコシステム小さい

## 各実装で測る軸

- フットプリント (= release binary size、stripped、linux/darwin x amd64/arm64)
- 起動速度 (= cold start ms、`die` は短時間で死ぬから重要)
- クロスコンパイルの楽さ (= matrix 構築の手数)
- homebrew tap 統合 (= GitHub Actions release workflow 書きやすさ)
- ソースコード可読性 / メンテ容易性

## 共通 test suite

仕様 (DR-0001) に対する behavior test を 1 つ用意し、各実装に同じ test を当てる:

- argv 経由: `die -- "msg"` / `die --sep ", " -- a b c` / `die --trim each -- "  x  "` / etc.
- stdin 経路: `echo X | die` / `printf X | die` (LF normalize on default) / `printf X | die -n` (off) / etc.
- 不変条件: exit code が常に 1、stdout は空、stderr に出る
- error: `--` なし、`--sep` に値なし、`--trim` に不正値、等

test runner は **shell script で完結** (= 各言語側で test framework を持たず、`./die` binary に対する behavior 検証で揃える) 想定。

## ディレクトリ構成案

```
die/
├── tests/                # 共通 behavior test (shell)
├── go/                   # Go 実装
├── rust/                 # Rust 実装
├── mbt/                  # MoonBit 実装
└── zig/                  # Zig 実装
```

各実装は `bin/die` を出力、tests/ 配下の shell から呼ぶ。

## 受け入れ条件

- [ ] 採用言語を 1 つに絞り、他実装を削除している
- [ ] homebrew tap に formula が追加されている

## TODO

- [ ] 共通 test suite (tests/) を書く
- [ ] Go 実装
- [ ] Rust 実装
- [ ] MoonBit 実装 (= native backend で binary 出せるか確認)
- [ ] Zig 実装
- [ ] 各実装で `make bench` / `make size` などで軸を計測
- [ ] 比較結果を docs/findings/YYYY-MM-DD-language-comparison.md にまとめ
- [ ] 採用言語決定 + 他実装を削除 (= 維持コスト回避)
- [ ] homebrew tap 統合 (= kawaz/homebrew-tap に formula 追加)

## 採用判断後

並列メンテはコスト過大なので **1 実装に絞る** 方針。他実装は git history に残して削除。
