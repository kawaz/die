# DR-0004: --eol option (auto/lf/crlf) で末尾改行の方言を切替

- Status: Superseded by DR-0005 (2026-06-27)
- Date: 2026-06-27

## Context

DR-0002 で「末尾 LF が無ければ 1 つ補う」「`-n` で off」「CRLF 終端は LF 終端扱い (= 補完しない)」を確定した。これは Unix 一級要件の設計で、kawaz の使用環境にマッチしていた。

並行実装 (DR-0003) で Windows 配布も検討対象になり、Windows ターミナル (cmd.exe / PowerShell / Windows Terminal) で `\n` だけだとプロンプトが行頭に出ない事象が発生する。die の存在意義 (= 人が読む stderr、ターミナル崩さない) を Windows でも一級要件として満たすには、補完する EOL の方言切替が必要。

## Decision

`--eol <MODE>` オプションを追加。`MODE` は `auto`/`lf`/`crlf`:

| MODE | 補完する EOL |
|---|---|
| `auto` (default) | Windows runtime なら `\r\n`、それ以外 `\n` |
| `lf` | 常に `\n` |
| `crlf` | 常に `\r\n` |

### 影響範囲 (= 「補う EOL」だけ、既存内容は触らない)

- **ARG path**: joined 文字列の末尾が `\n` でも `\r\n` でもない場合に EOL を 1 つ補う
- **stdin path**: 末尾が `\n` でも `\r\n` でもない場合に EOL を 1 つ補う
- **既に LF / CRLF で終わっている入力**: 触らない (= 重複させない)
- **重複改行** (`\n\n` 等): 維持 (DR-0002 と一貫)
- **`-n`** との関係: `-n` なら何も補わない (= --eol は無効化される)

### "auto" 判定の境界

「Windows runtime」の判定は **build-time target** で決める (= Windows binary はネイティブで CRLF default、Unix binary は LF default)。実行時の OS detection や TERM 環境変数による判定はしない (= 単純さを優先、cross-OS で予測可能)。

### 実装固有の例外: MoonBit native backend

MoonBit native backend は **compile-time OS 定数 / `#ifdef` 相当の機能を提供していない** (確認: 2026-06-27, moon 0.1.20260618)。die の MoonBit 実装ではやむなく **runtime detection** (`getenv("OS") == "Windows_NT"` を見る、Windows で必ず set される env) で代用。

実用上の差分:
- Native `darwin`/`linux` ホストで Windows binary を作って Windows 上で動かすと、build-time 設計では LF (= build target 由来) になるが、MoonBit 実装では Windows runtime 検知で CRLF になる
- 逆も同様 (= Windows でクロス build した Unix binary は build-time 設計では CRLF だが、MoonBit では Unix で getenv("OS") が unset なので LF になる)
- どちらの差分も「**runtime 環境にとって望ましい EOL を出す**」結果になるので実害は少ない、ただし「build-time で決まる」原則からはずれる

将来 MoonBit が `#ifdef` 等の compile-time OS 定数を提供したら build-time 化に揃える。それまでは `--eol lf` / `--eol crlf` を明示すれば挙動を完全に固定できる (= auto の差異を回避できる)。

### `--sep` 等の "内部" 改行とは独立

`--sep $'\n' -- a b` のような内部に `\n` を含む joined 文字列でも、`--eol crlf` は **末尾だけ** `\r\n` を補う (= 中身は触らない)。これは「補完規則」であって「変換規則」ではない。

## Alternatives Considered

- **A: 何もしない (DR-0002 維持)**
  - 不採用理由: Windows での体験を default で損なう。die の存在意義 (= ターミナルを崩さない default) と矛盾
- **B: `--crlf` フラグだけ追加 (binary フラグ)**
  - 不採用理由: `auto` が必要 (= cross-OS で配布する binary に対し 1 つの recipe で適切な default を出したい)。MODE 3 値 enum の方が拡張性も高い
- **C: stdin の CRLF を内部で LF に正規化してから --eol で出力**
  - 不採用理由: die は **バイト安全に近い透過 path** が哲学 (= 入力をいじらない、補完だけ)。内部正規化は予期しない byte 改変につながり、`-n` (透過) との対称性が崩れる
- **D: 環境変数 (`DIE_EOL=...`) で制御**
  - 不採用理由: DR-0001 で「環境変数は採用しない」を確定済み。argv に閉じる原則を覆さない

## Consequences

### Pros

- Windows ターミナルで default で崩れない (= auto の効果)
- `lf` / `crlf` 明示で reproducibility が必要な script でも使える (= ログ統一等)
- 既存 Unix 動作は default `auto` でも維持 (= Unix runtime なら lf 相当)
- DR-0002 の「補完しない透過 path」 (`-n`) も影響なし

### Cons / Trade-offs

- **--trim と並んで MODE 値 option が増える** (= help が膨らむ)。だが Windows サポート要件として正当
- **"auto" は build-time target で決まる** ので、cross-compiled binary を別 OS で動かしたケースは予測と違う動きをする (= まれ、`--eol` 明示で逃げられる)
- DR-0002 の「CRLF 終端 = LF 終端扱い、補完しない」は維持。`--eol crlf` でも `\r\n` 終端の入力には何も足さない (= 既に CRLF 終わってる)

## 関連

- [DR-0001](./DR-0001-spec-and-option-removal.md) — 仕様全体と option 撤廃の設計 (env 不採用の原則はここから継承)
- [DR-0002](./DR-0002-pipe-lf-normalization.md) — 末尾改行 normalization の default on
- [DR-0003](./DR-0003-parallel-implementation-language.md) — 並行実装比較で Windows サポートが要件化された経緯
- [DESIGN.md](../DESIGN.md) / [DESIGN-ja.md](../DESIGN-ja.md) — 仕様の本文 (DR-0004 反映)
