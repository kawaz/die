# DR-0005: --eol オプションを廃止し OS の text-mode 慣習に乗る

- Status: Active
- Date: 2026-06-27
- Supersedes: DR-0004 (--eol option)

## Context

DR-0004 で `--eol auto|lf|crlf` を導入して Windows ターミナルの CRLF 期待に応えた。

CI で windows-latest runner の test が `\n` 期待で `\r\n` を返す現象 (= CRT の text-mode 自動変換) を観測。原因究明議論の中で kawaz から以下の指摘:

1. **Windows native CLI 文化**は CRT text-mode が `\n` → `\r\n` を自動変換する世界。CLI 側はそれに乗っかるのが慣習
2. `-n` は **byte 透過のためではない**。die は **「人が見るための表示ツール」** で byte 透過至上ではない。`-n` は単に「**末尾 LF を補完しない**」だけの opt-in (= pipe 入力時に余計な改行が増えないようにする用途)
3. 上を踏まえると **`--eol` option 自体不要** (= OS 慣習に乗ればよい、明示制御の必要性が薄い)

## Decision

### 1. `--eol` option を廃止

CLI から削除。`--eol` を渡すと unknown option エラー。die の内部論理は **常に `\n` 単独補完**とする。

### 2. EOL は OS の text-mode 慣習に従う

- Unix runtime: stderr に `\n` 書く → そのまま `\n` で出る
- Windows runtime: stderr に `\n` 書く → CRT の text-mode default が `\r\n` に自動変換 → 実際は CRLF 出力 (= Windows native の慣習通り)

die はこの変換に **介入しない** (= `_setmode binary` を呼ばない)。Windows での CRLF は OS / CRT の責任。

### 3. `-n` の意味は「補完しない」のみ

- `-n` 指定時: 末尾 LF が無くても補完しない (= pipe 入力時に余計な改行が増えないようにする opt-in)
- `-n` は **byte 透過機能ではない**。OS の text-mode 変換は引き続き効く

つまり Windows で `printf X | die -n` を実行した場合:
- die は `X` を `\n` 補完なしで stderr に書く
- 出力 byte は `X` (LF が無いので CRT の text-mode 変換も発火しない)
- 結果: stderr に `X` (LF なし、Windows でも同じ)

`printf 'X\n' | die -n` の場合:
- die は `X\n` を補完なしで stderr に書く
- CRT text-mode が `\n` → `\r\n` に変換
- 結果: stderr に `X\r\n` (Windows runtime)、`X\n` (Unix runtime)

これは **byte 透過ではない**が、die の用途 (= 人が読む stderr) には十分。

### 4. 動作マトリクス

| OS / runtime | `-n` | 内部書き込み | 実際の出力 (stderr) |
|---|---|---|---|
| Unix | なし | `\n` 補完 | `\n` で出る |
| Unix | あり | 補完なし | 入力そのまま (Unix では byte 透過に近い) |
| Windows | なし | `\n` 補完 | CRT が `\r\n` に変換 → `\r\n` で出る |
| Windows | あり | 補完なし | 入力に LF があれば CRT が `\r\n` に変換、なければ素通り |

## Alternatives Considered

- **A: DR-0004 維持 (= `--eol auto`/`lf`/`crlf` で明示制御)**
  - 不採用理由: kawaz が「OS 慣習に乗れば option 不要、CLI 文化に合わせるべき」と判断。option を増やす方が die のシンプル哲学に反する
- **B: `-n` を byte 透過機能化 (= Windows でも `_setmode binary` を呼ぶ)**
  - 不採用理由: kawaz が「die はバイト透過至上ではない、表示ツール。`-n` が pipe でオプトインも同じ判断」と明示。`-n` は補完制御だけが意味、byte 透過は副次的にすぎない
- **C: Windows でも常に LF (= bash/MSYS 文化に倣う)**
  - 不採用理由: Windows native cmd / PowerShell ユーザー体験を損ねる。OS 慣習に乗るのが筋

## Consequences

### Pros

- 仕様が **DR-0004 より単純** (= option 1 つ廃止、help が短くなる)
- Windows runtime での挙動が **OS native 慣習に合致**
- 各実装の `--eol` parser / `Eol` enum / Windows-specific `_setmode` 呼び出しが削減 (= binary size 微減 + コード単純化)
- MoonBit の runtime OS detection (`getenv("OS")`) も不要 (= MoonBit に compile-time OS 判定がないことが本 DR では不問になる)
- CI の Windows fail (= `\n` 期待で `\r\n` 来る) は「期待値が CRLF」となり自然解消

### Cons / Trade-offs

- DR-0004 で導入直後の `--eol` を廃止 → API 不安定の印象を与えうる (= 配布前なので実害なし)
- 「Unix でも CRLF 出したい」明示需要は救えなくなる (= 必要なら shell side で `tr` で対応可能、die 一級要件ではない)
- `-n` で Windows でも完全 byte 透過にはならない (= CRT が CRLF 変換する) — kawaz の意図通り (byte 透過は die の責任ではない)

## 移行手順

1. tests/run.sh: `--eol *` case 削除 (11 case)、`raw_byte_check` で OSTYPE 分岐 (Windows なら LF 期待を CRLF 期待に変える、`-n` の場合も同様 — `-n` は byte 透過ではないので CRT 変換が効く)
2. 各実装: `--eol` parser 削除、`appendEOL` → `appendLF` (固定 `\n`)、Windows binary mode 設定 (`_setmode binary`) は **完全削除** (= -n 時にも呼ばない、kawaz の意図に沿う)
3. docs: DESIGN / README / DR-0001 / DR-0004 を更新
4. DR-0004 を `Status: Superseded by DR-0005` に変更
5. DR-0005 land
6. CI 再走、Windows 含め全 cell green を期待

## 関連

- [DR-0001](./DR-0001-spec-and-option-removal.md) — 仕様全体 + option 撤廃の設計 (Options table から `--eol` を削除する)
- [DR-0002](./DR-0002-pipe-lf-normalization.md) — 末尾 LF normalisation の default on (維持)
- [DR-0004](./DR-0004-eol-option.md) — Superseded by 本 DR
- [DESIGN.md](../DESIGN.md) / [DESIGN-ja.md](../DESIGN-ja.md) — 仕様の本文 (本 DR 反映)
