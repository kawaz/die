# DR-0006: `-n` は cat 同等 byte 透過 / default 動作は「カーソル崩れない」だけが要件

- Status: Active
- Date: 2026-06-27
- Refines: DR-0002, DR-0005

## Context

DR-0005 で `--eol` option を廃止し「OS text-mode 慣習に乗る」方針を確定。CI で Zig 実装が Windows で `\r\n` 出力する (= extern "C" write → MSVCRT _write → text-mode 変換) こと、Go / Rust は WriteFile 直叩きで Windows でも `\n` 出力することが観測された。

「同じ仕様の実装が言語別に違う byte 出すのは仕様一貫性を損なうのでは?」と議論した結果、kawaz から仕様定義の整理:

> 要は -n の要件は指定時は cat と同じでシンプル。指定なしのデフォルト動作が中身によってターミナルが改行せずカーソル位置が崩れる問題が起きないことが要件。それが実現されているなら最後のバイトが何かは問う必要性がない。

これは DR-0002 / DR-0005 を refines する仕様明文化。

## Decision

### `-n` の意味 = `cat` と同じ

- 入力 (= stdin or ARG joined) をそのまま stderr に出す
- 末尾 LF の補完なし
- **byte 透過** = OS 跨ぎで同一 byte 列を保証
- Windows runtime では CRT text-mode 変換を **抑止する必要あり**:
  - Rust / MoonBit / Zig は `-n` 時に `_setmode(0, _O_BINARY)` + `_setmode(2, _O_BINARY)` を呼ぶ
  - Go は os.Stderr / os.Stdin が元から WriteFile / ReadFile 直叩きで binary 透過 = 何もしなくて良い

### default 動作 (= `-n` 無し) の要件

- **「ターミナルでカーソル位置が崩れない」だけ** が要件
- 末尾の具体的な byte は **問わない** (= `\n` でも `\r\n` でも OK、実装依存)
- 内部論理は引き続き「末尾が `\n` でなければ `\n` を補完」(= DR-0002 維持)
- Windows での CRT text-mode 変換 (= `\n` → `\r\n`) は **介入しない** (= DR-0005 維持)

### 言語実装間の許容差分

同じ仕様でも実装間で末尾 byte が違って良い:

- Go (WriteFile 直叩き): Windows でも `\n` 出る
- Rust (std::io::stderr → WriteFile): Windows でも `\n` 出る
- MoonBit (extern "c" write → MSVCRT _write → text-mode): Windows で `\r\n` 出る (CI 観測予定)
- Zig (extern "C" write → MSVCRT _write → text-mode): Windows で `\r\n` 出る (CI 観測済)

いずれも **「ターミナルでカーソル崩れない」を満たす**ので die の仕様準拠。

### tests/run.sh の構造

- **default cases** (= `-n` 無し): raw_byte_check は「末尾が `\n` か `\r\n` で終わってる」を判定 (= byte 厳密一致ではなく、末尾改行存在を確認)
- **`-n` cases**: raw_byte_check は **厳密 byte 一致** (= cat 同等の byte 透過を担保)

## Alternatives Considered

- **A: 全 4 言語を Windows でも `\n` 固定** (= Rust/MoonBit/Zig も WriteFile 直叩き or `_setmode binary` を常時)
  - 不採用理由: 「default 動作は表示崩れなければ OK」を緩和できるので、impl 側に余計な仕掛けを入れる必要なし。kawaz の「byte は問わない」整理に沿う
- **B: 言語実装ごとに spec を分ける**
  - 不採用理由: 仕様は 1 つ、それを満たす実装が複数存在する形に整理した方がクリーン
- **C: default 動作の byte を `\n` で厳密固定 (= 私が最初に書いた仕様)**
  - 不採用理由: kawaz が明示的に「byte は問わない」と整理。仕様シンプル化の方向で揃える

## Consequences

### Pros

- 仕様 1 本化、`-n` ありなしの要件が明確 (= cat 同等 vs カーソル崩れない)
- 各実装 (特に Zig / MoonBit) で extern "C" 経由の自然な挙動を許容できる (= 不要な `_setmode` 仕掛けを入れない)
- tests の default cases が言語実装に対して loose になり、CI が言語別の natural behaviour を許容する
- `-n` ありの cat 同等性は厳密に担保 (= byte 透過が必要な場面で安心)

### Cons / Trade-offs

- 「Windows で die を叩くと Go と Zig で末尾 byte が違う」 = 採用言語決定後はこの差は消える (= 1 つの実装に絞るため)
- 採用前 (= 並行実装フェーズ) は tests を loose / strict 二段構成にする実装コスト

## 移行手順

1. **tests/run.sh 再修正**:
   - default cases (`raw/arg/lf-appended`, `raw/stdin/lf-appended` 等): 末尾改行存在チェックに変更 (= `tail -c 2` で `\r\n` or `tail -c 1` で `\n` を判定)
   - `-n` cases: byte 厳密一致のまま維持
2. **Rust / MoonBit / Zig: `-n` 時のみ `_setmode(0/2, _O_BINARY)` を呼ぶ**:
   - 元 DR-0005 v1 で書いた挙動に戻る (= Workflow v1 の方向性が正しかった、v2 で過剰削除した)
   - 但し `-n` 時のみ。default 時 (= `-n` なし) は呼ばない (= OS text-mode に乗っかる)
3. **Go**: 何もしない (= os.Stderr が元から binary 透過)
4. **docs**:
   - DR-0006 起票 + INDEX 反映
   - DR-0002 の Decision section に「`-n` 時は cat 同等 byte 透過 (DR-0006 参照)」を追記
   - DR-0005 は維持 (= --eol 廃止 + OS text-mode 慣習に乗る、本 DR は その上で `-n` を refines)
   - DESIGN / DESIGN-ja / README / README-ja: `-n` 説明に「cat 同等 byte 透過」を明示

## 関連

- [DR-0002](./DR-0002-pipe-lf-normalization.md) — 末尾 LF normalisation default on (本 DR で `-n` の意味を refines)
- [DR-0005](./DR-0005-drop-eol-option-respect-os-textmode.md) — --eol 廃止 + OS text-mode 慣習 (本 DR と整合、`-n` 関連のみ refines)
- [DESIGN.md](../DESIGN.md) / [DESIGN-ja.md](../DESIGN-ja.md) — 仕様の本文 (本 DR 反映)
