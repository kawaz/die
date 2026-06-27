# DR-0007: Zig を採用、他言語実装は archive bookmark に保存

- Status: Active
- Date: 2026-06-27
- Closes: DR-0003 (parallel implementation comparison)

## Context

DR-0003 で die の実装言語を Go / Rust / MoonBit / Zig の 4 並行で実装し、計測軸 (= binary size / cold start / cross compile / API 安定性 / kawaz の release pattern 親和性 / 開発体験) で比較する方針を確定。並行実装 + 最適化 + 専門家レビュー + DR-0005 / DR-0006 の仕様 refine を経て、4 言語すべて 27/27 e2e + 60+ unit tests 通過の状態に到達。

最終計測 (darwin/arm64 host, ReleaseSmall + opt):

| | binary size | cold start (ARG, 200 runs `-N`) | cross compile | API 安定性 |
|---|---|---|---|---|
| Go | 1.47 MB | 2.8 ms | `GOOS=...` 即可 | 高 (Go 1 互換) |
| Rust | 296 KB | 1.9 ms | `rustup target add` + linker | 高 (edition 跨ぎ互換) |
| MoonBit | 282 KB | 2.2 ms | 困難 (native は host のみ) | 低 (0.1.x, breaking 頻繁) |
| **Zig** | **50 KB** (host), **11 KB** (linux-gnu), **61 KB** (linux-musl static) | **1.7 ms** | **`-Dtarget=...` 1 コマンド** | 低 (0.x breaking 頻繁) |

詳細は `docs/findings/2026-06-27-language-comparison.md` および `docs/findings/2026-06-27-final-recommendation.md`。

## Decision

**Zig** を die の正式実装言語として採用。Go / Rust / MoonBit の実装は main から削除し、`archive/multi-impl-comparison` bookmark に保存して将来参照可能にする。

### Zig 採用の根拠 (= 軸別)

1. **footprint 最強**: 50 KB (darwin/arm64), 11 KB (linux-gnu), 61 KB (linux-musl)。die のような「頻繁に呼ばれる小道具」では配布サイズ = 起動コスト直結
2. **cold start 最速**: 1.7 ms ARG path。Rust 1.9 ms / MoonBit 2.2 ms / Go 2.8 ms を上回る
3. **cross compile 最強**: `zig build -Dtarget=x86_64-linux-musl` 等で 1 コマンド、musl libc も bundled。homebrew tap 配布で複数 target を生成する CI workflow が単純になる
4. **テスト網羅性 OK**: 67 unit tests + 39 e2e tests を全 OS で pass

### Cons の受容

Zig 0.x の API breaking change が頻繁 (= 0.13 → 0.14 → 0.16 で std.io / argv / isatty / GeneralPurposeAllocator が全部変わった) という不安定性。これに対しては:

- `build.zig.zon` で `minimum_zig_version = "0.16.0"` を pin
- CI の setup-zig も `version: 0.16.0` で固定 (= 上流の意図しない更新で CI が壊れない)
- die の impl は `extern "C"` で std.io 新 vtable 系を回避する pragmatic な path を採用しており、std API 変動の影響を最小化

## Alternatives Considered

- **Rust**: footprint / 速度で Zig に劣るが API 安定性は最高ランク。バランス選択として 2 位
  - 不採用理由: die の用途 (= 頻繁実行される小道具) では footprint / cold start の軽さが直結利益。Rust の安定性は魅力だが、Zig の `extern "C"` 凍結戦略で std 変動を抑止できるなら die の用途では Zig 優位
- **Go**: 配布慣れ最強 (= kawaz の他リポで release pattern 確立)、ただし size 1.47 MB は die の超小粒性質では不利
  - 不採用理由: die のように bash script で繰返し呼ばれる場面で 1.47 MB は重い (= linux/gnu Zig 11 KB の 130 倍)
- **MoonBit**: 並行実装の dogfood 成果として「MoonBit native backend で binary 化できる」事実は確認。ただし採用言語としては boilerplate (extern "c" 多用、Bytes 不変ハマり、build-time OS detection なし) が重い
  - 不採用理由: MoonBit 0.1.x は今後の成熟待ち。die の即配布要件には合わない

## Consequences

### Pros

- 仕様が小さい die にとって理想的な footprint / 速度
- cross compile が `-Dtarget=...` 1 行で済むため、release.yml の matrix がシンプル
- homebrew tap formula は `bin/die` 1 file をターゲット OS / arch 別に配布するだけで済む
- 採用後の dogfood (= bump-semver / claude-cmux-msg の justfile で die を使う) で `die` 起動が高速 = justfile / shell script 全体の応答性向上

### Cons / Trade-offs

- Zig 0.x の breaking change で将来 std API 追従コストが発生する可能性 (= `extern "C"` で部分回避済、ただし完全回避ではない)
- Rust / Go の方が kawaz の他 dev 環境との親和性は高い (= 既存 Rust / Go プロジェクトの経験値が直接活きる)
- MoonBit dogfood の成果は archive 経由でしか参照できない (= main からは見えない)

## archive 保存方針

並行実装の 4 言語 commit 系列は **`archive/multi-impl-comparison` bookmark** (= jj) に保存。`origin/archive/multi-impl-comparison` にも push 済。

再参照したい場合:
```
jj log -r archive/multi-impl-comparison
jj edit archive/multi-impl-comparison   # 一時的に working copy をその状態に
jj edit main                              # 戻す
```

将来 dogfood で die の挙動に問題が見つかり Zig が問題の根本と判明した場合は、archive bookmark から該当実装を main に復活させて再評価する DR を新規起票する。

## DR-0003 受け入れ条件への対応

- [x] 採用言語を 1 つに絞り、他実装を削除している (= Zig 採用、go/rust/mbt は archive)
- [x] homebrew tap に formula が追加されている → **本 DR 完了後の作業** (Phase 5 / 6 で実施)

DR-0003 を **Status: Resolved by DR-0007** に更新する。

## 関連

- [DR-0003](./DR-0003-parallel-implementation-language.md) — 並行実装方針 (本 DR で resolved)
- [DR-0001](./DR-0001-spec-and-option-removal.md) — 仕様確定 + option 撤廃
- [DR-0005](./DR-0005-drop-eol-option-respect-os-textmode.md) — --eol 廃止
- [DR-0006](./DR-0006-n-is-cat-equivalent-default-is-cursor-safe.md) — `-n` は cat 同等
- `docs/findings/2026-06-27-language-comparison.md` — 計測詳細
- `docs/findings/2026-06-27-final-recommendation.md` — 採用判断材料整理
- `docs/findings/2026-06-27-optimisation-synthesis.md` — 専門家レビュー ROI ランク
