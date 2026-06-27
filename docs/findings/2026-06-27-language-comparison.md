# Language comparison for `die` (Go / Rust / MoonBit / Zig)

- Date: 2026-06-27
- Context: DR-0003 — parallel implementations of the `die` CLI to pick one for distribution.
- Host: darwin/arm64 (Apple Silicon).
- Status: **全 4 言語の本実装完了 + tests/ 27/27 pass、計測結果まとめ**。最終採用判断は dogfood (DR-0003) 経過後。

## 判明した事実 (= 確定事実のみ)

| 項目 | Go | Rust | MoonBit | Zig |
|---|---|---|---|---|
| `tests/run.sh` 27 ケース | 27/27 pass | 27/27 pass | **27/27 pass** | **27/27 pass** |
| release binary size (darwin/arm64) | 1.6 MB (1,674,530 B) | 296 KB (302,736 B) | **311 KB** (311,560 B) | **51 KB** (50,912 B) |
| cold start (mean, ARG path, 200 runs `-N`) | 2.8 ms ± 0.2 ms | 1.9 ms ± 0.2 ms | **2.2 ms ± 0.3 ms** | **1.7 ms ± 0.2 ms** |
| cold start 順位 | 4位 (1.55x slower than zig) | 2位 (1.15x slower) | 3位 (1.29x slower) | **1位 (fastest)** |
| binary size 順位 | 4位 | 2位 (Rust ≈ MoonBit) | 3位 | **1位 (Go の 32 分の 1)** |
| cross compile (linux/amd64) | 1 環境変数で即成功、追加 toolchain 不要 | `rustup target add` が必要 | 困難 (native backend は host のみ、`moon` から cross が surface されてない) | 既定で全 target サポート (= zig の評判通り) |
| stdlib の coverage | 充実 (= ほぼ標準) | 充実 (isatty は extern "C" を選んだが libc クレートでも可) | 薄い (eprintln 無し、isatty 無し、extern "c" が要る) | 中 (`std.io`, `std.process`) |

## 実用的な示唆 / ベストプラクティス

### 候補絞り込みの観察

- **Zig が footprint / 速度の両軸で 1 位**: 51KB / 1.7ms。`die` のような小道具にとって配布コスト = 起動コスト直結。Zig の cross-compile 容易さも homebrew + 他 OS 配布で効く
- **Rust は 2 位、ただし mature な ecosystem**: 296KB / 1.9ms。Cargo + crates.io + Windows API 分岐 (`cfg(windows)`) が成熟していて kawaz の他リポでも実績がある
- **Go は size と速度で最下位、ただし最速の開発体験 + 既存 dogfood**: kawaz の他リポ (bump-semver / authsock-warden 等) で Go 配布 pattern 確立済み、release.yml / homebrew tap 統合の手数が最小
- **MoonBit は実装可能だが今のところ低レイヤー記述が多い**: native backend で binary 化はできるが eprintln / isatty / Bytes API が薄く、boilerplate が多い。エコシステム成熟は今後

### 採用判断の方向性 (= DR-0003 受け入れ条件として)

判断は 1 つの指標ではなく **「dogfood 経過後の総合主観評価」** で決める。現時点での候補順:

1. **Zig**: footprint と速度で文句なし、cross compile 最強 (= linux/gnu で 11KB は他言語の追随を許さない)。Cons は **0.16.0 の API breaking** — std を直接使うと 0.13→0.16 で全書き換え、現状は extern "C" で回避してるが将来 0.17 で再度書き直しが要る可能性。die のような小道具なら extern "C" 路線で凍結する余地もある
2. **Rust**: 安定の選択、Windows API 分岐コードを既に書いた、size/速度も悪くない。エコシステム成熟度では 1 位、API 安定 (edition 跨ぎでも互換)
3. **Go**: 配布慣れしているが size 不利、`die` のような超小粒では Zig/Rust に譲る方が筋。ただし kawaz の他リポ release pattern を最も寄せやすい (= release.yml 雛形流用即可)
4. **MoonBit**: 現時点は dogfood 言語として残すかは別判断。die の採用言語にするには boilerplate コストが高い、ただし MoonBit native backend が binary 化できる事実は確認できた (= 今回の dogfood の主たる成果)

**現時点の暫定推奨**: **Rust** (= stable API + Windows 対応容易 + 充分小さい binary)。Zig は将来の有力候補だが 0.16.0 の breaking change が決定的に大きい。kawaz の最終判断待ち。

### Windows サポート (DR-0004 → DR-0005 で方針変更)

DR-0004 で導入した `--eol auto|lf|crlf` は DR-0005 (2026-06-27) で廃止。Windows CRT の text-mode が `\n` → `\r\n` を自動変換する OS 慣習に乗ることで `--eol` option 自体が不要と判断。各実装から `--eol` parser / Windows `_setmode` 呼び出しが削除され、tests/run.sh の `raw_byte_check` が OSTYPE 分岐で Windows 側の期待値を CRLF に切替える形に簡素化された。詳細は [DR-0005](../decisions/DR-0005-drop-eol-option-respect-os-textmode.md) を参照。

## 検証の詳細

### 計測条件

- `hyperfine -i --warmup 50 --runs 200 -N`
- `-N` = `command-name` 直起動 (shell wrapper を介さない)
- `-i` = exit 1 を許容 (die は仕様上常に exit 1)

### Go 実装

- Module: `github.com/kawaz/die/go`
- Build: `go build -trimpath -ldflags "-s -w -X main.version=v$(cat ../VERSION)"`
- Binary size: 1,674,530 bytes (1.6 MB)
- ARG path: 2.8 ms ± 0.2 ms (range 2.4–3.5 ms, 200 runs)
- stdin path: 3.5 ms ± 0.4 ms
- Cross compile: `GOOS=linux GOARCH=amd64 go build ...` で即成功、追加 toolchain 不要。binary size は linux/amd64 で 1,691,810 B (≈ host と同等)

### Rust 実装

- Crate: `die` v0.0.1 edition 2021
- Profile: `[profile.release] opt-level = "z", lto = true, codegen-units = 1, strip = true, panic = "abort"`
- Build: `cargo build --release`
- Binary size: 302,736 bytes (296 KB) — Go の 5.5 分の 1
- ARG path: 1.9 ms ± 0.1 ms (range 1.8–2.9 ms, 200 runs)
- stdin path: 3.5 ms ± 0.3 ms
- Cross compile: host (aarch64-apple-darwin) のみ rustup でインストール済み。linux ターゲットを試すには `rustup target add x86_64-unknown-linux-gnu` + linker (= `cross` or `zig cc`) が要る。確認はまだ
- isatty(3) を `extern "C"` で直接呼ぶことで libc クレート依存を回避

### MoonBit 実装

- Module: `moon.mod.json` + `"source": "src"`, `mbt/src/main/{moon.pkg.json, main.mbt}`
- Build: `moon build --target native --release` → output が `_build/native/release/build/main/main.exe` (justfile も合わせて修正)
- Binary size: 311,560 bytes (304 KB) — Rust とほぼ同等
- ARG path: 2.2 ms ± 0.3 ms (Zig の 1.29x)
- Cross compile: 試していない (= native backend は TCC/Clang 経由で host のみ、`moon` CLI から cross が surface されない)
- subagent からの観察 (rough edges):
  - `Bytes` immutable、C read() は `FixedArray[Byte]` + `Bytes::from_array` 経由のボイラープレート
  - `String` slice (`s[N:]`) は `StringView` を返し `.to_owned()` が必要
  - stdlib に `eprintln` 無し → `extern "c" fn write(fd, buf, len)` を直接呼ぶ
  - stdlib に `isatty` 無し → `extern "c" fn isatty(fd) -> Int` を直接呼ぶ
  - build dir convention (`_build/` で `target/` 不使用、`source: src` の paths に注意) を事前に知らないとハマる

### Zig 実装

- Project: `zig/build.zig` + `zig/src/main.zig`、`zig version` 0.16.0
- Build: `zig build -Doptimize=ReleaseSmall` → `zig-out/bin/die`
- Binary size:
  - macOS arm64 (host): **50 KB** (Mach-O, stripped, system libc dynamic)
  - x86_64-linux-musl: **61 KB** (ELF, static, musl bundled)
  - x86_64-linux-gnu: **11 KB** (ELF, glibc dynamic) — Go の 152 分の 1
- ARG path: 1.7 ms ± 0.2 ms — **4 言語中最速**
- Cross compile: `zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall` で 1 コマンド成功。初回 musl libc ダウンロード (~22s)、以降キャッシュで即時
- subagent からの観察 (rough edges):
  - **Zig 0.16.0 は breaking-change release**: `std.io` / `std.os.argv` / `std.posix.isatty` / `GeneralPurposeAllocator` / `main()` 規約 が 0.13/0.14 から全部変わってる。新 I/O subsystem (`std.Io` vtable) は heavy なので、現実装は `extern "C"` で `write` / `read` / `isatty` / `malloc` 系を直接呼ぶ pragmatic な path を選択
  - 結果コードは "idiomatic Zig 0.16" ではない (= 新 std.Io を駆動するともっと重くなる)
  - `link_libc = true` が必要 (Linux は libc auto-link しない、macOS は自動)
  - 0.16.0 安定したら API 追従コストが将来発生する可能性
