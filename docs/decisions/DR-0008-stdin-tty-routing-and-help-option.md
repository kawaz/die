# DR-0008: stdin routing は TTY 判定で行う / `--help` option を導入

- Status: Active
- Date: 2026-06-28
- Refines: DR-0001

## Context

DR-0001 で確定した spec の stdin 周りは次の 3 経路:

1. `--` あり → ARGS を stderr に echo
2. `--` なし + stdin pipe/redirect → stdin を stderr に forward
3. `--` なし + stdin TTY → help を stderr

しかし「pipe/redirect」と「TTY」の境界が DR-0001 では明文化されていなかった。Zig 実装は POSIX `isatty(3)` (= MSVCRT `_isatty()` on Windows) を判定軸として採用していたが、Git Bash 上で `</dev/null` を渡すと NUL device が `_isatty()` true を返し help 経路に入る (DR-0001 v1 期は test 側を Windows skip して逃げた)。

この機会に「`die </dev/null` は何をすべきか」「`die <file.txt` は何をすべきか」「Cygwin pty は TTY 扱いすべきか」を **stdin の type 軸で網羅的に決める**。同時に、DR-0001 で `--help` option が定義されていなかったため `die --help` のような自然な使い方が成立しない点を解消する。

## Decision

### stdin routing は「TTY か否か」で分岐する

`--` なし起動時、stdin の type 判定で以下に振り分ける:

| stdin の種類 | 例 | 経路 |
|---|---|---|
| TTY (= terminal) | 親 shell から継承、`</dev/tty` | help |
| FIFO / anonymous pipe | `cmd \| die` | forward |
| Named pipe (FIFO) | `die <mypipe` | forward |
| Regular file | `die <file.txt` | forward |
| Char device (non-TTY) | `die </dev/null`, `</dev/zero`, `</dev/urandom` | forward |
| Socket | `die <(printf X)` (bash process sub) | forward |
| Block device | `die </dev/disk0` | forward |

**ルール**: stdin が **TTY なら help、それ以外は全部 forward**。`cat </dev/null` がエラーや無限待ちにならず即 EOF を返すのと同じく、`die </dev/null` も空入力を受けて normalize ルールに従い `\n` を補完して exit 1。

### TTY 判定の実装

- **POSIX (Linux / macOS / BSD)**: 標準の `isatty(3)` (= 内部で `ioctl(fd, TCGETS)` or `TIOCGETA`) を使う
- **Windows native**: `GetConsoleMode(handle)` 成功で TTY 判定
  - **MSVCRT `_isatty()` を使ってはならない** — MSVCRT は `FILE_TYPE_CHAR` を返す fd を全て TTY 扱いし、NUL device も含めてしまう (= 仕様違反)
- **Cygwin / MSYS2 / Git Bash pty**: 内部実装が named pipe (`\msys-XXX-ptyN-from-master` パターン) なので `GetConsoleMode` では検出不可。`NtQueryObject` または `GetFileInformationByHandleEx` で pipe 名を取得し Cygwin pty 命名規則とマッチさせて TTY 扱いする (go-isatty の `IsCygwinTerminal` 相当)
- 判定対象 fd は **stdin (fd 0) のみ**。stderr (fd 2) や stdout (fd 1) は判定に使わない (= die の動作は stdin の forward 可否でのみ決まる)

詳細な背景と各 OS 実装の検証は [findings/2026-06-28-tty-detection-cross-os.md](../findings/2026-06-28-tty-detection-cross-os.md) を参照。

### `--help` option

- `--` の **前** にある `--help` は option として解釈、help を stderr に出して exit する
- `--` の **後** にある `--help` (= `die -- --help`) は ARGS として扱い、literal "--help" を stderr に echo (= DR-0001 の「`--` 以降は何でも safe に渡せる」property を維持)
- `--help` option は **stdin 状態に関わらず勝つ** (= `printf X | die --help` でも help)
- 出力先は **stderr** (= die invariant: 出力は常に stderr)
- exit code: 本 DR では exit 1 と定めた、後続の [DR-0009](./DR-0009-exit-code-policy-and-version-option.md) で **exit 0 に refine** (= meta query は success 扱い)。最新の挙動は DR-0009 を参照

### Option parser の優先順位

1. argv を左から走査
2. `--` を見つけたら parse 終了、以降を ARGS として収集
3. `--` 到達前に `--help` を見つけたら即 help を stderr に出して exit 1
4. その他の option (`--sep`, `--trim`, `-n`) は従来通り

## Alternatives Considered

### stdin routing

- **A: 「stdin が FIFO のみ」forward、regular file も char device も help**
  - 不採用: kawaz の「`cat </dev/null` がエラーにならない常識感覚」と整合しない。`die <file.txt` を help にされても困る
- **B: 現状維持 (= MSVCRT `_isatty()` をそのまま使う、Windows NUL 問題は OS 依存として test を skip)**
  - 不採用: 仕様を OS 依存にすると spec の意味が崩れる。「仕様 1 本、実装が揃える」が die のスタンス (DR-0006 の哲学と同じ)

### `--help` option

- **C: `--help` を導入しない (= TTY help 経路だけで十分)**
  - 不採用: scripts から `die --help` をパイプ経由で叩く需要は普通にある (= `die --help | less`)。help が TTY 限定だと習得性が低い
- **D: `--help` を exit 0 にする (= GNU 慣習)**
  - 不採用: DR-0001 の「exit code は常に 1」invariant を崩す。die は「失敗系ユーティリティ」なので help 表示も exit 1 で揃える方が一貫
- **E: `--help` が `--` 後ろにあっても option として勝つ**
  - 不採用: DR-0001 の「`--` 以降は何でも safe に渡せる」property を壊す。「`die -- --help`」が help を出してしまうと、shell script で動的に組み立てた ARGS に偶然 `--help` が混ざった時に意図と違う動作になる

## Consequences

### Pros

- `die </dev/null` 等の挙動が直感的 (= cat と揃う)
- Windows NUL 問題が **仕様レベル** で解決 (= MSVCRT `_isatty` 依存を捨てる)
- `die --help` が成立、習得性向上
- DR-0001 の `--` invariant が崩れない (= `die -- --help` は literal echo)

### Cons / Trade-offs

- Windows 向け実装が増える (= `GetConsoleMode` + Cygwin pty 名前判定)
- TTY 判定のコードパスが OS 別に分岐 (= POSIX vs Windows)
- 「Git Bash プロンプトで `die` 裸打ち」が Cygwin pty 判定経由になる (= `IsCygwinTerminal` 相当の追加実装を入れないと forward 経路に入って Ctrl-D 待ち)

## 移行手順

1. **tests/run.sh** を新仕様で書き直す:
   - `</dev/null` redirect を forward 経路として表現 (= 空 stdin 入力 → `\n` 補完)
   - TTY 時 help の case を `</dev/tty` で表現 (CI 環境では TTY 確保困難なので OS 依存 skip 可能性あり)
   - `--help` option case を追加 (`die --help`、`printf X | die --help`、`die --help -- foo`、`die -- --help`)
   - 前回 DR-0001 v1 期に入れた Windows OSTYPE skip (`no-dash-dash-empty-stdin`) を撤去
2. **src/main.zig** を新仕様に合わせる:
   - `isatty()` 呼び出しを POSIX/Windows 分岐に変更
   - Windows は `GetConsoleMode` + Cygwin pty 名前判定 (go-isatty 移植)
   - `--help` option を parse loop に追加
3. **docs/DESIGN.md / DESIGN-ja.md** の stdin section と option 表に反映
4. **findings/2026-06-28-tty-detection-cross-os.md** を起票し OS 別 TTY 判定の検証結果を残す

## 関連

- [DR-0001](./DR-0001-spec-and-option-removal.md) — 仕様確定 + option 撤廃 (本 DR で stdin routing と --help を refines)
- [findings/2026-06-28-tty-detection-cross-os.md](../findings/2026-06-28-tty-detection-cross-os.md) — OS 別 TTY 判定の調査結果
- [mattn/go-isatty](https://github.com/mattn/go-isatty) — 各 OS の TTY 判定実装の参考
