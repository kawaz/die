# DR-0009: exit code は「meta query なら 0、それ以外は 1」/ `--version` option を導入

- Status: Active
- Date: 2026-06-28
- Refines: DR-0001, DR-0008

## Context

DR-0001 で「exit code は常に 1」を invariant として定めた。DR-0008 で `--help` option を追加したが、この invariant を維持して `--help` も exit 1 とした。

その後の利用観点から見ると、この strict 解釈には実害がある:

- script から `die --version >/dev/null 2>&1 && [ "$(die --version)" \> "die 0.1" ]` のように **die のバージョン確認** を行うとき、`die --version` が exit 1 を返すと `&&` chain が成立せず使いにくい
- GNU coreutils / git / gh / cargo / 99% の CLI が `--help` / `--version` を exit 0 で返している。die だけ違うと予測しにくい
- `Makefile` の rule で `die --help` を deps に置くとそこで make が abort する

論点を整理すると:

- DR-0001 の invariant は「die が **die としての動作** をするとき exit 1」と読むのが自然
- `--help` / `--version` は **die 自身に関する meta query** (= 「使い方を教えて」「version は何?」) であって、die 本来動作 (= 「メッセージを stderr に出して死ね」) ではない
- 両者を別カテゴリとして扱えば、invariant の精神は守りつつ慣習にも揃えられる

加えて `--version` option を導入する。`--help` と並行する `--version` は **どんな CLI でも持っている最低限の meta query**。`-V` short alias は CLI 設計慣習 ([[cli-design-preferences]] = ショートエイリアスは明示要望なしには追加しない) に従って付けない。

## Decision

### Exit-code policy (refined)

| ケース | exit |
|---|---|
| `--help` 明示 (option として) | **0** |
| `--version` 明示 (option として) | **0** |
| 引数なし + stdin TTY (bare-TTY help fallback) | 1 |
| `--` あり + ARGs (die 本来動作、stderr に echo) | 1 |
| 引数なし + non-TTY stdin (forward) | 1 |
| option parse error / unknown option / missing value | 1 |

判断軸: **「明示の meta query」(= ユーザが die 自身について問い合わせた) なら 0、それ以外は 1**。bare-TTY help fallback は「使い方が分からないユーザの誤起動への補助」なので usage error 扱い、exit 1。

### `--version` option の仕様

- option として `--` の **前** にあるとき有効、`die --version` → stderr に `die <version>\n` を出力、exit 0
- `--` の **後** (= `die -- --version`) は ARG として扱い、literal "--version" を stderr に echo、exit 1 (DR-0001 の "-- 以降は安全に渡せる" property を維持)
- `--version` option は **stdin 状態に関わらず勝つ** (= `printf X | die --version` でも version 出力、`--help` と同じ)
- バージョン文字列の出力形式は `die <X.Y.Z>` (= `<program-name> <version>`、GNU 慣習)
- 出力先は **stderr** (= die の全出力は stderr、これは DR-0001 invariant を維持)
- バージョン値の source: `build.zig.zon` の `.version` を build-time に `@import("zon").version` で取り込む (= single source of truth、release flow の version source と完全一致)

### Option parser の優先順位 (refined)

1. argv を左から走査
2. `--` を見つけたら parse 終了、以降を ARGS として収集
3. `--` 到達前に `--help` を見つけたら help を stderr に出して exit 0
4. `--` 到達前に `--version` を見つけたら `die <version>\n` を stderr に出して exit 0
5. `--help` と `--version` が両方ある場合、**先に現れた方が勝つ** (= 通常の左から右の評価順序通り)
6. その他の option (`--sep`, `--trim`, `-n`) は従来通り

## Alternatives Considered

### Exit-code policy

- **A: 全部 exit 1 のまま** (= DR-0001 / DR-0008 v1 の現状)
  - 不採用 (今回): GNU 慣習との非互換 + script 使い勝手の悪さが上回る。「DR-0001 invariant の精神は守りつつ refine する」整理で対応可能
- **B: --help だけ exit 0 (--version は exit 1)** (= 半分)
  - 不採用: 一貫しない。`--help` と `--version` は同じ「meta query」カテゴリ、片方だけ 0 にする根拠が薄い
- **C (今回採用): meta query (= --help / --version) なら 0、それ以外 1**
  - DR-0001 の精神を「die が die としての動作をするとき」に refine、meta query は別カテゴリと整理
- **D: bare-TTY help fallback も exit 0**
  - 不採用: bare 起動は「使い方が分かってない誤起動」のシグナル、success 扱いだと shell script で `die` 単独打ちが noop で成功になり予期せぬ挙動。明示 `--help` 要求と区別する

### `--version` option

- **E: --version を導入しない** (= 既存 `just version` recipe 等で済ます)
  - 不採用: `die --version` は CLI として最低限の meta query、利用者が自然に試す。これがないと「die はそもそも version 持ってない奇妙な CLI」に見える
- **F: -V short alias を一緒に追加**
  - 不採用: [[cli-design-preferences]] 「ショートオプションエイリアスを指示なく追加しない」に従う。kawaz 明示要望なしでは long のみ
- **G: build.zig.zon でなく別 VERSION file を作る**
  - 不採用: DR-0007 で「zon を version source of truth にする」を決めた、それを横紙破りで別 file 作るのは矛盾

## Consequences

### Pros

- GNU 慣習と整合、script からの利用性向上 (= `die --version` で version 取得が自然)
- `--help` / `--version` を deps に置いた `Makefile` 等が abort しない
- DR-0001 の invariant 精神は維持 (= die 本来動作は依然 exit 1)
- `--version` 追加で `die --version` が他 CLI と同じ感覚で使える

### Cons / Trade-offs

- DR-0001 の「exit 1 で固定」strict 解釈を緩める = 「die は何しても 1 を返す」というシンプルな mental model から「meta query は 0」という分岐が増える
- 既存利用者で `die --help` の exit を 1 と仮定した script があれば壊れる (= 実害は薄い、`die --help` を script で叩く用途自体が稀)

### 互換性

- v0.2.0 → v0.3.0 で minor bump 相当。`--version` 追加 (新機能 = minor) + exit code refine (= 仕様 refine だが script 互換性は通常向上方向)
- `die -- --help` / `die -- --version` の literal echo は変わらない (= DR-0001 の `--` invariant 維持)

## 移行手順

1. src/main.zig: `--version` option を option parser に追加、`--help` と `--version` の exit を `process.exit(0)` に変更、HELP テキストの説明を refine 済
2. build.zig: `addAnonymousImport("zon", ...)` で zon を src 側に渡す経路を確立済 (src/main.zig の `@import("zon").version` 経路)
3. tests/run.sh: `help_text_check` helper に `EXPECT_EXIT` 引数を追加し全 help/version case を 0 期待に。`--version` 関連の新 case 6 件追加 (no-stdin / with-stdin-pipe / with-trailing-args / literal-via-dash-dash / option-order 両方向)
4. tests/tty.sh: `tty/help-option-under-tty` を 0 期待に
5. docs/DESIGN.md / DESIGN-ja.md: Options 表 / Help section / Invariants の exit code 記述を新マトリクスに反映 (= 本 DR と同 commit で)
6. justfile: `version` recipe を bin --version 出力併記に改善、`run *ARGS` recipe 新規追加 (= 別 commit `chore(justfile): canonical version recipe + add run recipe`)

## 関連

- [DR-0001](./DR-0001-spec-and-option-removal.md) — 仕様確定 (本 DR で exit code invariant を refine、meta query 例外を新設)
- [DR-0008](./DR-0008-stdin-tty-routing-and-help-option.md) — stdin TTY routing + `--help` 導入 (本 DR で `--help` の exit を 0 に refine、`--version` を追加)
- [DR-0007](./DR-0007-adopt-zig-archive-others.md) — Zig 採用 (`@import("zon")` のための前提)
