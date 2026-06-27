# DR-0002: pipe 末尾改行 normalization の default on

- Status: Active
- Date: 2026-06-27

## Context

`die` に stdin (= file redirect / pipe) で content を流し込む使い方 (`cat <file | die` 等) を想定したとき、末尾 LF の扱いをどう設計するか。設定ファイル等で「version 値が 1 行で改行なし」のような content を `cat` で見ると、ターミナルの次プロンプトが行頭で出ず崩れる (= 利用者がイラつくあるある)。

一方 `cat` は **バイナリ安全** が要件のため、末尾 LF を勝手に補わない。これは `cat` の正しい設計。

`die` をどう設計するか:
- A: `cat` と同じ振る舞い (= バイナリ安全、末尾 LF を補わない)
- B: 人が読む stderr 一級要件、末尾 LF を default で補う (= 内容に既に LF があれば触らない)

## Decision

**case B を採用、`-n` で off (= バイナリ安全モード) に切り替えられる**。

### 挙動の定義

`-n` を渡さない限り、入力末尾の char が LF でなければ 1 つ補う。重複改行 (= 末尾 `\n\n` 等) は維持。

| 入力 | default (= `-n` なし) | `-n` あり |
|---|---|---|
| `"X\n"` | `"X\n"` (touch せず) | `"X\n"` |
| `"X"` | `"X\n"` (1 LF 補う) | `"X"` (補わない) |
| `""` | `"\n"` | `""` |
| `"X\n\n"` | `"X\n\n"` (重複は維持) | `"X\n\n"` |
| `"X\r\n"` | `"X\r\n"` (`\n` で終わってる扱い) | `"X\r\n"` |

ARG 経路 (= `die -- "msg"`) の末尾 LF も同じ規則で normalize される (= 規則の対称性)。

## Alternatives Considered

- **A: `cat` と同じ default off (= バイナリ安全)**
  - 不採用理由: `die` は「人が読む stderr」が要件、`cat` の「バイナリ安全 streaming」とは目的が違う。default で「次プロンプトが行頭で出ない」状況を発生させると教育コスト払いっぱなしになる。`die` の存在意義 (= 「気軽に死ぬ」) を default 体験で損なう
- **opt-in で on (= `-N` で normalize)**
  - 不採用理由: default 体験を A 案と同じにしてしまう。`-n` (off) 方向にひっくり返す方が利用シーンに合う
- **常時 on (= `-n` も不採用)**
  - 不採用理由: 「内容そのまま出したい」場面 (= バイナリ / fixed-width output 等のレア用途) を救えなくなる。逃げ道を残すのは小コスト

## Consequences

### Pros

- default 体験が「ターミナル崩さない」 = die の役割 (= 人が読む stderr) と整合
- `-n` で `cat` 同等のバイナリ安全モードに切り替え可能、レアケースも救える
- ARG 経路と stdin 経路の規則が同じ (= 対称性、認知負荷低)

### Cons / Trade-offs

- `cat` と挙動が違うので利用者の認知が必要 → help / README で明示
- 末尾 LF の判定で `\r\n` (CRLF) 終端を `\n` 終端扱いにする (= 補完しない) のは Windows context で「CR が末尾」と誤解される余地、ただし pipe 出力で CRLF が混入するケースは限定的なので許容

## 関連

- [DR-0001](./DR-0001-spec-and-option-removal.md) — 仕様全体と option 撤廃の設計
- [DESIGN.md](../DESIGN.md) / [DESIGN-ja.md](../DESIGN-ja.md) — 仕様の本文
