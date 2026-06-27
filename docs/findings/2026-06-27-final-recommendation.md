# 採用言語決定のための最終 recommendation

- Date: 2026-06-27
- 並行実装 (DR-0003) のフェーズ「採用言語決定」のための判断材料整理。**決定権は kawaz**、本ドキュメントは比較データ + 評価軸別の総評を提示するだけ。

## 計測結果 (DR-0005 + optimisation 適用後、darwin/arm64 host、commit 574c29e)

| 軸 | Go | Rust | MoonBit | Zig |
|---|---|---|---|---|
| 本体 binary size (darwin/arm64) | 1.47 MB | 296 KB | 282 KB | **50 KB** |
| 本体 binary size (x86_64-linux-gnu) | 1.61 MB | 未測定 | 未測定 | **11 KB** |
| 本体 binary size (x86_64-linux-musl) | — | 未測定 | 未測定 | 61 KB (static) |
| cold start (ARG path, mean, 200 runs `-N`) | 2.8 ms | 1.9 ms | 2.2 ms | **1.7 ms** |
| cold start (stdin path) | 3.5 ms | 3.5 ms | 未測定 | 未測定 |
| host tests (27 ケース) | 27/27 ✅ | 27/27 ✅ | 27/27 ✅ | 27/27 ✅ |
| cross-compile linux | `GOOS=linux` 一発 | rustup target add + linker | 不可 (host のみ) | `-Dtarget=` 一発 |
| cross-compile windows | `GOOS=windows` 一発 | rustup target add | 不可 | `-Dtarget=` 一発 |
| Windows binary 動作 | CI で OK (LF 出力) | CI で OK (LF 出力) | CI で OK (LF 出力) | CI で OK (LF 出力) |
| stdlib coverage | 充実 (= ほぼ標準) | 充実 | 薄い (eprintln/isatty 無し、extern "c") | 中 (= 0.16 で I/O 再構築中) |
| API 安定性 | ✅ Go 1 後方互換 | ✅ edition 跨ぎ互換 | ⚠️ 0.1.x、変更頻繁 | ⚠️ 0.x、breaking change が頻繁 (0.13→0.14→0.16) |
| kawaz 既存 release pattern との整合 | ✅ bump-semver / authsock-warden 等で実績 | △ 個別整備 | △ 個別整備 | △ 個別整備 |
| 開発体験 (= 仕様変更時のメンテ) | ✅ 高い | ✅ 高い | △ boilerplate 多い | △ extern "c" 経由が多い |

## 評価軸別の総評

### A. footprint 重視 (= binary size / cold start)

**Zig が圧倒的に最強**。
- darwin/arm64 で 50 KB は Go の **32 分の 1**、Rust/MoonBit の **6 分の 1**
- linux/gnu で 11 KB は Go の **152 分の 1**
- cold start も最速 (= 1.7 ms)
- cross-compile も最強 (musl bundled / 1 コマンド)

cons: Zig 0.x の API 不安定。0.16 → 0.17 で std.io 等が再変更される可能性。die のように **extern "C" で凍結する戦略** なら影響少。

### B. 配布 / 運用慣れ重視

**Go が最強**。
- kawaz の他リポ (bump-semver, authsock-warden, stable-which, ...) で release.yml / homebrew tap 統合の pattern が完全に確立
- GitHub Actions の matrix build がスムーズ
- 仕様変更時のメンテ容易性も高い

cons: binary size が大きい (1.47 MB)、cold start も最遅 (2.8 ms)。`die` のような **頻繁に呼ばれる小道具** には不利。

### C. バランス重視

**Rust が安定の選択**。
- size/速度: 2 位
- API 安定性: 高い
- Windows 対応: 既に組み込み済み (= `cfg(windows)` 分岐の経験あり)
- cargo + crates.io エコシステム成熟

cons: cross-compile が rustup target add + linker 設定で手数多い。`zig cc` + `cross` で回避可能だが workflow 設定追加が要る。

### D. 実験的 / dogfood 価値

**MoonBit は不採用 (= die の本実装には不適)**。
- 本実装可能なことは確認できた (= dogfood の主成果)
- ただし boilerplate (extern "c", FixedArray バリエーション) が他言語より多い
- エコシステム成熟は今後
- cross-compile 不可は配布上致命的

## 暫定推奨

**Zig** を **第一候補**として提案する。

理由:
- die は人が読む stderr の小道具 = **頻繁に呼ばれる** + **何百回も実行される**。footprint と cold start の両方が利益直結 (= 例えば justfile の各 recipe で `cmd || die "msg"` を 10 回呼ぶなら 1 ms x 10 = 10 ms 短縮)
- Linux glibc で 11 KB は die の用途 (= 配布 + sourcing 容易) に完璧マッチ
- Zig 0.x の API 不安定は extern "C" 路線で凍結する設計を既に取ったので影響少

**第二候補**: **Rust**。
- size/速度で Zig に劣るが、kawaz の release pattern との親和性は Go に次ぐ
- API 安定性は最高ランク (= 5 年後も同じコードが動く)
- die のような小道具で十年単位のメンテを考えるなら Rust が手堅い

**Go は第三**。配布慣れは最強だが、`die` の超小粒性質では size/速度の不利が目立つ。kawaz の他リポでは Go が最適、ただし die はこの用途に Go を選ぶ価値が薄い。

## 受け入れ条件への進捗

DR-0003 の受け入れ条件:
- [ ] 採用言語を 1 つに絞り、他実装を削除している ← **kawaz 判断待ち**
- [ ] homebrew tap に formula が追加されている ← 採用言語決定後 (= release.yml + tap formula)

## kawaz 判断待ち項目

1. **採用言語**: 推奨 Zig (footprint 重視) / 推奨 Rust (バランス) / それとも Go / MoonBit?
2. **dogfood**: 採用言語決定後、kawaz/bump-semver 等の他リポで実際に `die` を使って体験する期間を設けるか
3. **不採用言語の削除**: いつ削除するか (= 採用決定直後 vs dogfood 完了後)
4. **homebrew tap formula**: 採用後の release.yml 雛形は kawaz/bump-semver パターンに沿わせるか、Zig 採用なら別パターン (= GoReleaser-equivalent for Zig 不在で工夫要)

## 関連

- DR-0001: 仕様確定 + option 撤廃の設計
- DR-0002: 末尾 LF normalisation default on
- DR-0003: 並行実装方針 (本ドキュメントが受け入れ条件の判断材料)
- DR-0005: --eol 廃止 + OS text-mode 慣習に乗る (Superseded DR-0004)
- docs/findings/2026-06-27-language-comparison.md: 各実装の詳細計測
- docs/findings/2026-06-27-optimisation-synthesis.md: 専門家レビューの ROI ランク
- docs/findings/2026-06-27-review-{go,rust,mbt,zig}.md: 各言語の専門家レビュー本文
