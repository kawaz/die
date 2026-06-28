# Cross-OS な TTY 判定 / stdin 種類の見分け

Date: 2026-06-28.
Source: POSIX manpages (`isatty(3)`, `ioctl(2)`, `stat(2)`), MSDN (`_isatty`, `GetConsoleMode`, `GetFileType`), [mattn/go-isatty](https://github.com/mattn/go-isatty) のソース実装。

> die のような「stdin が何か」で動作を分岐する CLI を書くときに、OS 跨ぎで正しく TTY を判定する方法をまとめる。`isatty(3)` を素直に呼ぶだけでは Windows で意図と違う挙動になるので注意。

---

## 判明した事実

### `<X` で渡される stdin に来る fd の種類 (POSIX `fstat` の `st_mode` 分類)

`fstat()` の file type マクロで分類できる。shell から発生し得る代表例:

| マクロ | 種類 | 発生例 |
|---|---|---|
| `S_ISREG` | regular file | `die <file.txt` |
| `S_ISDIR` | directory | `die <somedir` (大抵 open でエラー、稀に通る) |
| `S_ISCHR` | char device | `die </dev/null`, `</dev/tty`, `</dev/zero`, `</dev/random`, `</dev/urandom` |
| `S_ISBLK` | block device | `die </dev/disk0` (要 root) |
| `S_ISFIFO` | FIFO / pipe | `printf X \| die` (anonymous pipe), `die <named.fifo` |
| `S_ISSOCK` | socket | `die <(printf X)` (bash process substitution、実体は `/dev/fd/N` → pipe or socket), unix socket fd 継承 |

加えて、何も redirect しない時の stdin (= 親 shell から継承) は **TTY (`/dev/tty` 系の char device + `isatty` true)**。

### TTY 判定の本質

「char device か否か」(= `S_ISCHR`) よりも **「terminal driver に紐づく fd か」** の方が strict な判定。POSIX `isatty(3)` がこれを行う:

```c
int isatty(int fd) {
    struct termios t;
    return tcgetattr(fd, &t) == 0;
    // 内部的には ioctl(fd, TCGETS, &t) (Linux) or ioctl(fd, TIOCGETA, &t) (BSD/macOS)
}
```

- `</dev/null` (char device, terminal でない) → `ioctl(TCGETS)` 失敗 → `isatty` false ✓
- `</dev/tty` (char device, terminal) → `ioctl(TCGETS)` 成功 → `isatty` true ✓
- pipe / regular file / block device → 同じく false ✓

POSIX 側はこれで完璧。

### Windows の罠

Windows で `<command> </dev/null` と書くと、shell が **NUL device** (= `\Device\Null`) に置き換える。これに対する各 API の挙動が分岐する:

| API | NUL device に対する挙動 | terminal を正しく検出するか |
|---|---|---|
| MSVCRT `_isatty(fd)` | **true** を返す (= バグじみた既知挙動) | × NUL を terminal と誤判定 |
| `GetFileType(handle)` | `FILE_TYPE_CHAR` を返す | × MSVCRT `_isatty` が↑これを根拠に true 返す |
| `GetConsoleMode(handle)` | **失敗** (= NUL は console ではない) | ◯ 正しく false 判定可能 |

MSDN の MSVCRT `_isatty` ドキュメントには「char device なら true」と書かれていて、これが NUL device を含めてしまう設計。`isatty` を素直に C runtime 経由で呼ぶと Windows で NUL を terminal と誤判定する。

→ **Windows では `GetConsoleMode` ベースで判定すべし**。

### Cygwin / MSYS2 / Git Bash の pty

Cygwin / MSYS2 / Git Bash の bash プロンプトは **Windows native console ではない**。これらの pty は内部的に **named pipe** で実装されており、pipe 名が以下のパターンを取る:

```
\msys-XXXXXXXXXXXXXXXX-ptyN-{from,to}-master
\cygwin-XXXXXXXXXXXXXXXX-ptyN-{from,to}-master
```

(`\Device\NamedPipe\` prefix 付きのパターンもあり)

`GetConsoleMode` は失敗する (pipe なので)、`_isatty` も `GetFileType` が `FILE_TYPE_PIPE` を返すので false。**素直に `_isatty` / `GetConsoleMode` を使うと Cygwin pty は TTY 検出できない**。

go-isatty は別 API `IsCygwinTerminal(fd)` を用意して、`NtQueryObject` または `GetFileInformationByHandleEx` で pipe 名を取得し、上記命名規則とマッチさせて判定する。

### Recommended detection 戦略 (cross-OS)

| OS | 推奨 API |
|---|---|
| Linux | `isatty(3)` (= `ioctl(TCGETS)`) |
| macOS / BSD | `isatty(3)` (= `ioctl(TIOCGETA)`) |
| Solaris | `isatty(3)` |
| Windows native console (cmd.exe / PowerShell / Windows Terminal) | `GetConsoleMode(handle)` |
| Windows + Cygwin/MSYS2/Git Bash pty | pipe 名取得 → `\msys-...-pty` / `\cygwin-...-pty` パターン照合 |

**MSVCRT `_isatty` は cross-OS code では使わない**こと。Windows NUL を terminal 誤判定する。

---

## 実用的な示唆 / ベストプラクティス

### TTY 判定 fd の選び方

「TTY か否か」で何を切り替えるかによって判定対象 fd が変わる:

| 用途 | 見る fd |
|---|---|
| stdin に何か流れてくるか (= forward 可否) | **stdin** |
| ANSI escape / カラーを出すか (= 出力先が terminal か) | **stdout** (または stderr の出力先) |
| プログレスバーを表示するか | **stdout** (または stderr) |
| 対話モード/REPL 起動か | **stdin と stdout 両方** が TTY (片方だけ TTY だと表示崩れ) |

die では stdin だけ見れば十分 (= forward 可否判定のみ)。stdout は die 未使用、stderr は出力先として使うだけで動作には影響しない。

### `</dev/null` の振る舞い基準

`cat </dev/null` がエラーや無限待ちにならず即 EOF を返すように、`</dev/null` を渡された CLI は「空入力を受けた」として扱うのが POSIX 慣習。die もこれに従い `</dev/null` は forward 経路 (空入力 → normalize ルールで `\n` 補完)。

### Git Bash で `</dev/null` を渡したい場合

Git Bash の bash は `</dev/null` を内部で Windows NUL に変換する。MSVCRT `_isatty` だと TTY 誤判定するが、`GetConsoleMode` ベース判定なら正しく non-TTY と判定できる (NUL は console ではない)。

### 「stdin redirect で空になる」を意図的に作るテスト方法

e2e テストで「stdin が non-TTY だけど空入力」を確実に表現したい場合:

```bash
# 確実に空 pipe
printf '' | mycmd

# /dev/null redirect (= char device、空、POSIX/Windows 共通で non-TTY 判定)
mycmd </dev/null
```

逆に「stdin が TTY」を CI 環境でテストするのは難しい (= 多くの CI runner は TTY を持たない)。`script -q /dev/null` や `expect` で pty を作る手があるが、依存追加になる。実用上は「TTY 経路の有無は手動確認 + ローカル test で網羅」が落としどころ。

---

## 検証の詳細

### go-isatty の API 構造

```go
// POSIX (Linux / macOS / BSD)
func IsTerminal(fd uintptr) bool {
    _, err := unix.IoctlGetTermios(int(fd), unix.TCGETS)  // or TIOCGETA on BSD
    return err == nil
}

// Windows
func IsTerminal(fd uintptr) bool {
    var st uint32
    r, _, e := syscall.Syscall(procGetConsoleMode.Addr(), 2, fd, uintptr(unsafe.Pointer(&st)), 0)
    return r != 0 && e == 0
}

// Windows + Cygwin/MSYS2 pty 専用 (別 API)
func IsCygwinTerminal(fd uintptr) bool {
    // GetFileType が FILE_TYPE_PIPE を返す
    // → GetFileInformationByHandleEx (or NtQueryObject) で pipe 名取得
    // → \msys-XXX-ptyN-{from,to}-master パターンとマッチさせる
}
```

### MSVCRT `_isatty` の挙動

Microsoft Learn の `_isatty` ドキュメントには `Returns a nonzero value if the descriptor is associated with a character device. Otherwise, _isatty returns 0.` とある。
**NUL は character device に分類される**ため `_isatty(STDIN)` で `</dev/null` が true を返す既知挙動。`GetFileType` が `FILE_TYPE_CHAR` を返す fd を全て char device 扱いするのが MSVCRT の仕様。

### 言語別実装の selection

| 言語 | POSIX TTY 判定 | Windows TTY 判定 |
|---|---|---|
| Zig | `std.posix.isatty` (extern `isatty`) or `std.os.windows.kernel32.GetConsoleMode` | `GetConsoleMode` extern を自前で declare |
| Rust | `std::io::IsTerminal::is_terminal` (Rust 1.70+) または `is-terminal` crate | 同上 (内部で `GetConsoleMode`) |
| Go | `golang.org/x/term.IsTerminal` または `mattn/go-isatty` | 同上 |
| MoonBit | (要調査、現状 isatty 直 wrapper なし) | (同上) |

Rust の `IsTerminal` は Cygwin pty を **検出しない** (= `GetConsoleMode` ベースのみ)。go-isatty の `IsCygwinTerminal` は別途実装されている。Cygwin pty も TTY 扱いしたければ自分で pipe 名判定を入れる必要がある。

### die 実装での影響 (DR-0008 参照)

DR-0001 期の Zig 実装は `extern fn isatty(fd: i32) c_int` を素直に呼んでおり、これが Windows で MSVCRT `_isatty` にバインドされ NUL device を TTY 判定していた。DR-0008 で `GetConsoleMode` ベース + Cygwin pty 名前判定の実装に切り替える。
