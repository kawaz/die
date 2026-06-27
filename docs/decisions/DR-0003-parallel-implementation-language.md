# DR-0003: 実装言語の並行比較方針

- Status: Active
- Date: 2026-06-27

## Context

`die` は仕様が極めて小さい (= DR-0001 / DR-0002 で確定済み)。実装言語の差で性能 / 機能性に大きな差は出ない見込みだが、**小粒すぎる故にフットプリント (binary size) で差が出やすい**。`die` は homebrew tap 経由で全環境に install される想定で、配布コスト (= binary size、起動速度、cross compile の楽さ) は dogfood の毎回コストに直結する。

「どの言語が `die` 用途に最適か」を **観察 + 計測ベース** で判断するため、複数言語で並行実装して比較する。

## Decision

クロスコンパイル可能なモダン言語 4 つで並行実装し、計測軸を揃えて比較する:

### 対象言語

- **Go**: 配布実績 (kawaz/bump-semver 等)、homebrew tap 統合パターン確立、クロスコンパイル成熟、binary size 大きめ (= 数 MB)
- **Rust**: 小さい binary、release optimization 効きやすい、cross compile やや手間
- **MoonBit**: dogfood として MoonBit native backend 検証、エコシステム熟成度未確認
- **Zig**: 最小 binary 候補、クロスコンパイル最強、エコシステム小さい

### 計測軸

- **フットプリント**: release binary size (stripped、UPX 圧縮等は適用しない素の数値)、linux/darwin × amd64/arm64
- **起動速度**: cold start ms (= `die` は短時間で死ぬから cold start が重要)
- **クロスコンパイルの楽さ**: linux/darwin × amd64/arm64 matrix 構築の手数
- **homebrew tap 統合**: GitHub Actions release workflow 書きやすさ
- **ソースコード可読性 / メンテ容易性**: 主観評価

### 共通 test suite

仕様 (DR-0001 / DR-0002) に対する behavior test を **shell script で 1 つ用意**し、各実装の `bin/die` に同じ test を当てる。各言語側の test framework に依存しないので比較がフェアになる。

### 採用判断

dogfood (= kawaz/bump-semver / claude-cmux-msg 等で実際に `die` を使ってみる) を経た上で、上記計測軸 + 主観評価を統合して 1 実装を採用する。**並列メンテはコスト過大なので 1 実装に絞る方針**。他実装は git history に残して削除。

## Alternatives Considered

- **A: 最初から 1 言語に絞る (= Go か Rust の二者択一)**
  - 不採用理由: 「観察せず選ぶ」 = 推測ベースの判断、kawaz の `empirical-verification` 原則に反する。仕様が小さいので並行実装コストは許容範囲
- **B: 多言語並列メンテ (= 採用後も複数実装を維持)**
  - 不採用理由: メンテコスト過大、利用者側で「どれを install するか」迷う、bug fix の同期負担。`die` のような小道具では 1 binary に絞る方が筋
- **C: pure POSIX sh で実装 (= binary 不要)**
  - 不採用理由: shell 関数による `die()` 自前定義の代替を作るのが目的、sh script で配布すると **既存の関数定義との衝突問題が解決しない**。OS 単体 binary であることが必須要件

## Consequences

### Pros

- 観察ベースで採用言語を決定 (= 推測なし)
- 各言語の特性が `die` という具体的なユースケースで比較できる (= 一般論ではなく実測)
- dogfood で挙動を確認した上で配布できる

### Cons / Trade-offs

- 並行実装期間 (= 比較フェーズ) のコスト
- 採用後に却下言語の実装を git history に残すか完全削除するかの判断が残る (= 多分削除、判断は採用時に DR で別途)

## 関連

- [DR-0001](./DR-0001-spec-and-option-removal.md) — 仕様全体と option 撤廃の設計
- [DR-0002](./DR-0002-pipe-lf-normalization.md) — pipe 末尾改行 normalization の default on
- 並行実装 issue: [docs/issue/2026-06-27-parallel-impl-comparison.md](../issue/2026-06-27-parallel-impl-comparison.md)
