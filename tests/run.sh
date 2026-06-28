#!/usr/bin/env bash
#
# Shared behavioural test suite for `die` (e2e / black-box).
# Invoke with DIE_BIN pointing to a built binary:
#
#   DIE_BIN=/path/to/go/bin/die tests/run.sh
#
# Exits 0 if every case passes, 1 otherwise.
#
# ============================================================================
# Test responsibility split (kawaz, 2026-06-27):
#   This suite covers what only e2e can measure:
#     - CLI invocation (argv parsing, --, --sep, --trim, -n recognition)
#     - stdin / stderr / exit-code wiring (pipe vs /dev/null vs file vs TTY)
#       * TTY-path cases (= stdin is a real terminal) require a pty allocator
#         and are split out into tests/tty.sh. This file covers everything that
#         can be exercised without a real terminal.
#     - DR-0001 invariants: exit == 1 AND stdout empty, on every case
#     - DR-0005 / DR-0006: OS-cross EOL behaviour
#         * default mode: die writes deterministic bytes; the host C runtime
#           text-mode layer may expand \n→\r\n (Windows MSVCRT). Both are
#           spec-compliant — see expect_die_output's two-variant assertion.
#         * -n mode: cat-equivalent, strict byte equality across all OSes.
#     - ARG / stdin priority (ARG wins when both supplied)
#     - error / usage paths (exit=1 + non-empty stderr + empty stdout)
#
#   Pure logic coverage is delegated to per-language unit tests:
#     - trim_ascii (SP HT LF VT FF CR; Unicode whitespace untouched; empty,
#       all-WS, interior-WS, multi-byte input boundaries)
#     - join_args (0/1/N ARGs, --sep variations, empty ARGs)
#     - append_lf  (\n/\r\n/\r/empty/no-tail input variants)
#   The reason: language-internal logic does not change when running on
#   different OSes or under different shells. e2e cases for it would just
#   duplicate what a `go test` / `cargo test` / `moon test` / `zig test` run
#   already verifies more precisely (and without quoting hazards).
# ============================================================================
set -uo pipefail

DIE_BIN="${DIE_BIN:-${1:-}}"
if [ -z "${DIE_BIN}" ]; then
    echo "usage: DIE_BIN=<path-to-die> $0   (or: $0 <path-to-die>)" >&2
    exit 2
fi
if [ ! -x "${DIE_BIN}" ]; then
    echo "DIE_BIN '${DIE_BIN}' is not executable" >&2
    exit 2
fi

pass=0
fail=0
failures=()

# Run one test case and compare actual vs expected for: exit code, stdout, stderr.
# Usage: run_case NAME EXPECTED_EXIT EXPECTED_STDOUT EXPECTED_STDERR -- CMD ARGS...
#
# If STDIN_DATA env is set, it is piped into the command; otherwise stdin is
# /dev/null. Use STDIN_DATA='' for "empty pipe", unset (with `unset STDIN_DATA`)
# for "no pipe at all (= /dev/null)".
run_case() {
    local name=$1 expect_exit=$2 expect_out=$3 expect_err=$4
    shift 4
    if [ "${1:-}" != "--" ]; then
        echo "internal: run_case '${name}' missing -- separator" >&2
        return 2
    fi
    shift

    local actual_out actual_err actual_exit
    local tmp_out tmp_err
    tmp_out=$(mktemp) tmp_err=$(mktemp)

    # Note on exit code capture across a pipe:
    #   In the STDIN_DATA branch we run `printf … | "$@"`. `$?` here is the
    #   exit code of the RIGHTMOST command in the pipeline (= die), which is
    #   exactly what we want — bash's default is rightmost-wins regardless of
    #   pipefail. Do NOT rewrite this to use `${PIPESTATUS[0]}` thinking it's
    #   "more correct": [0] would point at `printf`, not die. If you ever need
    #   a non-rightmost stage's exit, that's when `${PIPESTATUS[N]}` (bash) /
    #   `${pipestatus[N]}` (zsh, 1-origin) matters.
    if [ "${STDIN_DATA+set}" = "set" ]; then
        printf '%s' "${STDIN_DATA}" | "$@" >"$tmp_out" 2>"$tmp_err"
        actual_exit=$?
    else
        "$@" </dev/null >"$tmp_out" 2>"$tmp_err"
        actual_exit=$?
    fi
    actual_out=$(cat "$tmp_out")
    actual_err=$(cat "$tmp_err")
    rm -f "$tmp_out" "$tmp_err"

    local ok=1
    [ "${actual_exit}" = "${expect_exit}" ] || ok=0
    [ "${actual_out}" = "${expect_out}" ] || ok=0
    [ "${actual_err}" = "${expect_err}" ] || ok=0

    if [ "${ok}" = "1" ]; then
        pass=$((pass + 1))
        printf '  PASS  %s\n' "${name}"
    else
        fail=$((fail + 1))
        failures+=("${name}")
        printf '  FAIL  %s\n' "${name}"
        printf '        exit:    want=%s got=%s\n' "${expect_exit}" "${actual_exit}"
        printf '        stdout:  want=%q\n                 got=%q\n' "${expect_out}" "${actual_out}"
        printf '        stderr:  want=%q\n                 got=%q\n' "${expect_err}" "${actual_err}"
    fi
}

echo "== running tests against ${DIE_BIN} =="

# ---------- normal: ARG path ----------

unset STDIN_DATA
run_case 'arg/single'              1 '' 'msg'              -- "${DIE_BIN}" -- 'msg'
run_case 'arg/multi-default-sep'   1 '' 'a b c'            -- "${DIE_BIN}" -- a b c
run_case 'arg/sep-comma-space'     1 '' 'a, b, c'          -- "${DIE_BIN}" --sep ', ' -- a b c
run_case 'arg/sep-empty'           1 '' 'abc'              -- "${DIE_BIN}" --sep '' -- a b c

# --trim each (default): trim each ARG individually
run_case 'arg/trim-each-default'   1 '' 'foo bar'          -- "${DIE_BIN}" -- ' foo ' ' bar '
run_case 'arg/trim-each-explicit'  1 '' 'foo bar'          -- "${DIE_BIN}" --trim each -- ' foo ' ' bar '

# --trim all: trim the joined string at both ends only.
# " foo " + " " + " bar " = " foo   bar " (3 inner spaces) → trim both ends.
run_case 'arg/trim-all'            1 '' 'foo   bar'        -- "${DIE_BIN}" --trim all -- ' foo ' ' bar '

# --trim none: no trimming (LF still appended)
run_case 'arg/trim-none'           1 '' ' foo   bar '      -- "${DIE_BIN}" --trim none -- ' foo ' ' bar '

# Trailing LF normalisation on ARG path: the joined string always gets a LF
# appended unless it already ends in LF (DR-0002). run_case strips the final
# newline via $() — so the "expected stderr" string above represents the line
# content; the suite below checks raw bytes for LF behaviour.

# ---------- normal: stdin path (LF normalisation) ----------

STDIN_DATA='X'
run_case 'stdin/no-lf-normalised'       1 '' 'X'           -- "${DIE_BIN}"
STDIN_DATA=$'X\n'
run_case 'stdin/lf-preserved'           1 '' 'X'           -- "${DIE_BIN}"
STDIN_DATA=''
run_case 'stdin/empty-becomes-lf'       1 '' ''            -- "${DIE_BIN}"
# stdin/double-lf-preserved: bash $() strips ALL trailing LFs from cmd substitution
# so this case is verified via raw/stdin/double-lf below (raw byte comparison).
# stdin/crlf-treated-as-lf: on Windows runners (Git Bash) the pipe transport
# strips \r before it reaches the child stdin, so this case can only be
# validated on POSIX hosts. Skip with a recorded reason rather than papering
# over it with a soft assertion (see [[test-failure-no-tampering]]).
case "${OSTYPE:-}" in
    msys*|cygwin*|win32*)
        printf '  SKIP  stdin/crlf-treated-as-lf  (Git Bash pipe strips \\r before child stdin)\n'
        ;;
    *)
        STDIN_DATA=$'X\r\n'
        run_case 'stdin/crlf-treated-as-lf' 1 '' $'X\r'    -- "${DIE_BIN}"
        ;;
esac

# -n disables normalisation
STDIN_DATA='X'
run_case 'stdin/-n-no-lf-appended'      1 '' 'X'           -- "${DIE_BIN}" -n
STDIN_DATA=''
run_case 'stdin/-n-empty-stays-empty'   1 '' ''            -- "${DIE_BIN}" -n

# ARG + stdin supplied → ARG wins, stdin ignored
STDIN_DATA='YYYY'
run_case 'stdin+arg/arg-wins'           1 '' 'X'           -- "${DIE_BIN}" -- X

# ---------- invariants: stdout is always empty, exit is always 1 ----------
# (covered implicitly by the cases above — every expect_out is '' and every
# expect_exit is 1)

# ---------- raw-byte assertions ----------
#
# Model (DR-0002, DR-0005, DR-0006):
#   * `die` writes a deterministic byte string to stderr — this is the
#     "die-controlled byte string", computed from input + spec rules:
#       - ARG path: trim each ARG (ASCII whitespace only), join with --sep,
#         append \n if the result does not already end with \n.
#       - stdin path: forward stdin as-is, append \n if the input does not
#         already end with \n.
#       - With -n: never append, write exactly what would be joined / forwarded.
#   * The actual bytes observed on stderr may differ from the die-controlled
#     string for one reason only: the host C runtime's text-mode layer can
#     expand \n to \r\n on output (Windows MSVCRT _write). This only happens
#     for impls that go through MSVCRT (Zig today). Go and Rust use WriteFile
#     directly and bypass the conversion. Under -n, all impls call
#     _setmode(_O_BINARY) on stdin/stderr to suppress this — so -n is always
#     byte-exact.
#
# Check functions:
#   raw_byte_check    — strict byte equality (used for -n cases; cat-equivalent).
#   expect_die_output — die-controlled bytes must match exactly OR match after
#                       \n → \r\n expansion (Windows MSVCRT text-mode result).
#                       Used for default cases. Encodes the spec: kawaz wants
#                       "the right bytes leaving die, plus the runtime's natural
#                       text-mode behaviour, nothing more".
#   loose_eol_check   — legacy: only asserts a prefix + ends with \n or \r\n.
#                       Kept for cases where the full die-controlled byte
#                       string is hard to write (e.g. preserved-empty-line),
#                       but expect_die_output is preferred where possible.

# Run cmd, capture stderr into STDERR_FILE and stdout into STDOUT_FILE
# (both caller-allocated tmp files); the global LAST_EXIT holds the exit
# code. bash 3.2 compatible — no `local -n` nameref (macOS ships bash 3.2).
#
# Usage: _run_raw_capture STDERR_FILE STDOUT_FILE STDIN_DATA -- CMD ARGS...
#   STDIN_DATA == '__NOSTDIN__' → redirect stdin from /dev/null
LAST_EXIT=
_run_raw_capture() {
    local _err_tmp=$1
    local _out_tmp=$2
    local _stdin=$3
    shift 3
    if [ "${1:-}" != '--' ]; then
        echo "internal: _run_raw_capture missing --" >&2; return 2
    fi
    shift
    if [ "${_stdin}" != '__NOSTDIN__' ]; then
        printf '%s' "${_stdin}" | "$@" >"${_out_tmp}" 2>"${_err_tmp}"
    else
        "$@" </dev/null >"${_out_tmp}" 2>"${_err_tmp}"
    fi
    LAST_EXIT=$?
}

# _check_invariants STDOUT_FILE → 0 if stdout empty AND LAST_EXIT == 1, else 1
# Prints failure detail on stderr.
# These invariants come from DR-0001:
#   - exit code: always 1
#   - stdout:    always empty (output goes to stderr)
_check_invariants() {
    local _out_tmp=$1
    local _detail=''
    local _ok=1
    if [ "${LAST_EXIT}" != "1" ]; then
        _ok=0
        _detail+=" [exit=${LAST_EXIT}, want 1]"
    fi
    local _out_size; _out_size=$(wc -c <"$_out_tmp" | tr -d ' ')
    if [ "${_out_size}" != "0" ]; then
        _ok=0
        _detail+=" [stdout non-empty: ${_out_size} bytes]"
    fi
    INVARIANT_DETAIL=$_detail
    return $((1 - _ok))
}
INVARIANT_DETAIL=

# strict byte match — for -n cases (cat-equivalent)
# Always asserts the invariants too (exit=1 + stdout empty).
raw_byte_check() {
    local name=$1 stdin_data=$2 expected_stderr=$3
    shift 3
    if [ "${1:-}" != '--' ]; then
        echo "internal: raw_byte_check '${name}' missing --" >&2; return 2
    fi
    shift
    local err_tmp; err_tmp=$(mktemp)
    local out_tmp; out_tmp=$(mktemp)
    _run_raw_capture "$err_tmp" "$out_tmp" "${stdin_data}" -- "$@"
    local got; got=$(od -An -c "$err_tmp" | tr -d ' \n')
    local want; want=$(printf '%s' "${expected_stderr}" | od -An -c | tr -d ' \n')
    local invariant_ok=1
    _check_invariants "$out_tmp" || invariant_ok=0
    rm -f "$err_tmp" "$out_tmp"
    if [ "${got}" = "${want}" ] && [ "${invariant_ok}" = "1" ]; then
        pass=$((pass + 1))
        printf '  PASS  raw/%s\n' "${name}"
    else
        fail=$((fail + 1))
        failures+=("raw/${name}")
        printf '  FAIL  raw/%s%s\n' "${name}" "${INVARIANT_DETAIL}"
        if [ "${got}" != "${want}" ]; then
            printf '        stderr bytes want=%s\n' "${want}"
            printf '        stderr bytes got =%s\n' "${got}"
        fi
    fi
}

# (loose_eol_check removed — expect_die_output covers its use cases with
# stricter byte-string assertion.)

# expect_die_output NAME STDIN_DATA EXPECTED_DIE_BYTES -- CMD ARGS...
#
# Asserts the observed stderr equals either:
#   (a) EXPECTED_DIE_BYTES exactly                 — no CRT text-mode expansion
#   (b) EXPECTED_DIE_BYTES with every isolated \n  — MSVCRT text-mode expansion
#       expanded to \r\n (a \n preceded             active (Windows; only Zig today)
#       by \r is left alone)
#
# Either is spec-compliant per DR-0005 / DR-0006: die only commits to the
# die-controlled byte string; the host runtime's text-mode layer may expand
# \n to \r\n on Windows, and that is allowed.
# crt_expand BYTES → bytes with every \n replaced by \r\n. Emulates Windows
# MSVCRT _write text-mode behaviour, which expands EVERY \n unconditionally
# (even if the \n is already preceded by \r — empirically observed on the
# windows-latest runner: zig 'X\r' input → die write "X\r\n" → MSVCRT emits
# "X\r\r\n").
# Pure bash (no sed/awk) for portability across BSD/GNU/MSYS coreutils.
crt_expand() {
    local in=$1 out='' i ch
    for (( i = 0; i < ${#in}; i++ )); do
        ch=${in:i:1}
        if [ "$ch" = $'\n' ]; then
            out+=$'\r\n'
        else
            out+=$ch
        fi
    done
    printf '%s' "$out"
}

expect_die_output() {
    local name=$1 stdin_data=$2 expected_die=$3
    shift 3
    if [ "${1:-}" != '--' ]; then
        echo "internal: expect_die_output '${name}' missing --" >&2; return 2
    fi
    shift
    local err_tmp; err_tmp=$(mktemp)
    local out_tmp; out_tmp=$(mktemp)
    _run_raw_capture "$err_tmp" "$out_tmp" "${stdin_data}" -- "$@"
    local got; got=$(od -An -c "$err_tmp" | tr -d ' \n')
    local want_native; want_native=$(printf '%s' "${expected_die}" | od -An -c | tr -d ' \n')
    local want_crt; want_crt=$(crt_expand "${expected_die}" | od -An -c | tr -d ' \n')
    local invariant_ok=1
    _check_invariants "$out_tmp" || invariant_ok=0
    rm -f "$err_tmp" "$out_tmp"
    local byte_ok=0
    if [ "${got}" = "${want_native}" ] || [ "${got}" = "${want_crt}" ]; then
        byte_ok=1
    fi
    if [ "${byte_ok}" = "1" ] && [ "${invariant_ok}" = "1" ]; then
        pass=$((pass + 1))
        printf '  PASS  raw/%s\n' "${name}"
    else
        fail=$((fail + 1))
        failures+=("raw/${name}")
        printf '  FAIL  raw/%s%s\n' "${name}" "${INVARIANT_DETAIL}"
        if [ "${byte_ok}" = "0" ]; then
            printf '        observed bytes  = %s\n' "${got}"
            printf '        expected (die)  = %s\n' "${want_native}"
            printf '        expected (CRT)  = %s\n' "${want_crt}"
        fi
    fi
}

# ---- Default-mode cases (no -n) — die-controlled byte string fully specified ----
#
# Spec: ARG path applies --trim each (default), which strips ASCII whitespace
# (SP HT LF VT FF CR) from each ARG; the result is joined with --sep (" " default)
# and \n is appended if missing. stdin path forwards as-is and appends \n if
# missing. Observed stderr may have \n → \r\n expansion (Windows MSVCRT).

# ARG path:
expect_die_output 'arg/single'                    '__NOSTDIN__' $'msg\n'     -- "${DIE_BIN}" -- 'msg'
expect_die_output 'arg/preserves-internal-cr'     '__NOSTDIN__' $'a\rb\n'    -- "${DIE_BIN}" -- $'a\rb'
expect_die_output 'arg/trim-strips-lf-tail'       '__NOSTDIN__' $'msg\n'     -- "${DIE_BIN}" -- $'msg\n'
expect_die_output 'arg/trim-strips-crlf-tail'     '__NOSTDIN__' $'msg\n'     -- "${DIE_BIN}" -- $'msg\r\n'
expect_die_output 'arg/trim-strips-cr-tail'       '__NOSTDIN__' $'msg\n'     -- "${DIE_BIN}" -- $'msg\r'
expect_die_output 'arg/trim-strips-double-lf'     '__NOSTDIN__' $'msg\n'     -- "${DIE_BIN}" -- $'msg\n\n'
expect_die_output 'arg/trim-none-keeps-tail'      '__NOSTDIN__' $'msg\r\n'   -- "${DIE_BIN}" --trim none -- $'msg\r\n'

# stdin path (no trim):
expect_die_output 'stdin/no-lf-then-append'       'X'           $'X\n'       -- "${DIE_BIN}"
expect_die_output 'stdin/lf-tail-no-append'       $'X\n'        $'X\n'       -- "${DIE_BIN}"
expect_die_output 'stdin/crlf-tail-no-append'     $'X\r\n'      $'X\r\n'     -- "${DIE_BIN}"
expect_die_output 'stdin/cr-tail-gets-append'     $'X\r'        $'X\r\n'     -- "${DIE_BIN}"
expect_die_output 'stdin/double-lf-preserved'     $'X\n\n'      $'X\n\n'     -- "${DIE_BIN}"
expect_die_output 'stdin/empty-becomes-lf-raw'    ''            $'\n'        -- "${DIE_BIN}"

# ---- -n cases — cat-equivalent, strict byte match (no CRT expansion under -n) ----
expect_die_output  'stdin/-n-no-lf'                  'X'           'X'          -- "${DIE_BIN}" -n
expect_die_output  'stdin/-n-keeps-lf'               $'X\n'        $'X\n'       -- "${DIE_BIN}" -n
expect_die_output  'stdin/-n-keeps-crlf'             $'X\r\n'      $'X\r\n'     -- "${DIE_BIN}" -n
expect_die_output  'stdin/-n-keeps-cr'               $'X\r'        $'X\r'       -- "${DIE_BIN}" -n
expect_die_output  'stdin/-n-keeps-double-lf'        $'X\n\n'      $'X\n\n'     -- "${DIE_BIN}" -n
expect_die_output  'stdin/-n-empty-stays-empty'      ''            ''           -- "${DIE_BIN}" -n

# ---- -n on the ARG path (DR-0002 + DR-0006): -n suppresses LF append ----
# Spec contour: -n means "do not append \n" regardless of the input path.
# The ARG path normally appends \n to the joined string; with -n, it must not.
raw_byte_check  'arg/-n-no-lf-appended'           '__NOSTDIN__' 'X'          -- "${DIE_BIN}" -n -- 'X'
raw_byte_check  'arg/-n-multi-no-lf'              '__NOSTDIN__' 'a b c'      -- "${DIE_BIN}" -n -- a b c
raw_byte_check  'arg/-n-empty-arg-list'           '__NOSTDIN__' ''           -- "${DIE_BIN}" -n --

# ---- -n is idempotent — repeated -n is the same as a single -n ----
raw_byte_check  'arg/-n-n-idempotent'             '__NOSTDIN__' 'X'          -- "${DIE_BIN}" -n -n -- 'X'
raw_byte_check  'stdin/-n-n-idempotent'           'X'           'X'          -- "${DIE_BIN}" -n -n

# ---- Anything after `--` is a literal ARG, even an option-looking token ----
# Spec contour: -n placed after `--` is not parsed as an option. This is the
# core "you can pass anything safely" property (DR-0001: `--` 必須化).
expect_die_output  'arg/dash-dash-then-literal-n'    '__NOSTDIN__' $'-n\n'      -- "${DIE_BIN}" -- -n
expect_die_output  'arg/dash-dash-then-literal-help' '__NOSTDIN__' $'--help\n'  -- "${DIE_BIN}" -- --help
expect_die_output  'arg/dash-dash-then-literal-trim' '__NOSTDIN__' $'--trim each\n' -- "${DIE_BIN}" -- '--trim each'

# ---- The interaction surface that -n actually sits on ----
# Spec contour clarification (kawaz, 2026-06-28): -n only changes whether the
# final "\n append if missing" step fires. But what that final byte IS depends
# on --sep and --trim and the last ARG's tail, not on -n itself. Pin that:
#
#   - With --trim none, the joined string's last byte = (last ARG's last byte)
#     OR (sep's last byte) if the last ARG is empty.
#   - The append decision then looks at that byte: if \n, no append. Otherwise,
#     append \n unless -n is in effect.
#   - With --trim each / all, the joined string's tail bytes can be stripped
#     before the append decision runs, so a tail of e.g. "\n" or "\r\n" in the
#     last ARG vanishes and \n always gets re-appended.
#
# These cases nail down each branch of that decision tree:

# trim none + sep ending in \n + non-empty last ARG → tail is the ARG's last
# byte, not \n → append. -n suppresses the append.
expect_die_output  'trim-none/sep-lf/non-empty-last'         '__NOSTDIN__' $'a\nb\n'   -- "${DIE_BIN}" --trim none --sep $'\n' -- a b
raw_byte_check  '-n/trim-none/sep-lf/non-empty-last'      '__NOSTDIN__' $'a\nb'     -- "${DIE_BIN}" -n --trim none --sep $'\n' -- a b

# trim none + sep ending in \n + EMPTY last ARG → joined ends in \n already
# → no append. -n changes nothing because there is nothing to suppress.
expect_die_output  'trim-none/sep-lf/empty-last-no-append'   '__NOSTDIN__' $'a\n'      -- "${DIE_BIN}" --trim none --sep $'\n' -- a ''
raw_byte_check  '-n/trim-none/sep-lf/empty-last-same'     '__NOSTDIN__' $'a\n'      -- "${DIE_BIN}" -n --trim none --sep $'\n' -- a ''

# trim none + sep CR + last ARG 'n' → joined "a\rn" → tail 'n' is not \n
# → append. (kawaz example: sep \r, last ARG n)
expect_die_output  'trim-none/sep-cr/last-letter-n'          '__NOSTDIN__' $'a\rn\n'   -- "${DIE_BIN}" --trim none --sep $'\r' -- a n
raw_byte_check  '-n/trim-none/sep-cr/last-letter-n'       '__NOSTDIN__' $'a\rn'     -- "${DIE_BIN}" -n --trim none --sep $'\r' -- a n

# trim none + sep CR + EMPTY last ARG → joined "a\r" → tail \r is not \n
# → append \n → output "a\r\n". -n → "a\r" (no append).
expect_die_output  'trim-none/sep-cr/empty-last-cr-tail'     '__NOSTDIN__' $'a\r\n'    -- "${DIE_BIN}" --trim none --sep $'\r' -- a ''
raw_byte_check  '-n/trim-none/sep-cr/empty-last-cr-tail'  '__NOSTDIN__' $'a\r'      -- "${DIE_BIN}" -n --trim none --sep $'\r' -- a ''

# trim none + last ARG already ends in \n → no append regardless of -n.
expect_die_output  'trim-none/last-arg-lf-tail'              '__NOSTDIN__' $'a b X\n'  -- "${DIE_BIN}" --trim none -- 'a' 'b' $'X\n'
raw_byte_check  '-n/trim-none/last-arg-lf-tail-same'      '__NOSTDIN__' $'a b X\n'  -- "${DIE_BIN}" -n --trim none -- 'a' 'b' $'X\n'

# trim each strips the last ARG's tail \n BEFORE the append decision → \n
# always gets re-appended; -n suppresses the re-append.
expect_die_output  'trim-each/last-arg-lf-tail-stripped'     '__NOSTDIN__' $'a b X\n'  -- "${DIE_BIN}" --trim each -- 'a' 'b' $'X\n'
raw_byte_check  '-n/trim-each/last-arg-lf-tail-stripped'  '__NOSTDIN__' 'a b X'     -- "${DIE_BIN}" -n --trim each -- 'a' 'b' $'X\n'

# Plain orthogonal sanity check: -n on the simple --sep+ARG path drops only
# the final \n, nothing else.
raw_byte_check  '-n/sep-pipe/simple'                      '__NOSTDIN__' 'a|b|c'     -- "${DIE_BIN}" -n --sep '|' -- a b c

# ---- stdin × ARG-path boundary (DR-0001 + DR-0008 stdin handling) ----
# Spec contour (DR-0008 supersedes the DR-0001-era wording):
#   - presence of `--` switches to ARG path UNCONDITIONALLY. After `--`, the
#     ARGS (even if zero of them) are the input; stdin is ignored.
#   - absence of `--` AND stdin is a TTY (= real terminal) → help to stderr.
#     This branch needs a pty allocator and lives in tests/tty.sh.
#   - absence of `--` AND stdin is NOT a TTY → forward stdin to stderr.
#     "Not a TTY" covers every fstat type other than a real terminal:
#     anonymous pipes, named FIFOs, regular files, char devices (/dev/null,
#     /dev/zero, …), sockets (process substitution), and block devices.
#     /dev/null specifically is forwarded as an empty input → normalize rule
#     appends \n.
#
# What's surprising and worth pinning:
#   * `die --` with zero ARGs IS still the ARG path. The joined string is the
#     empty string, append \n → output is just "\n". stdin is ignored even if
#     piped.
#   * `die </dev/null` (no `--`, /dev/null as stdin) takes the stdin path with
#     empty input, producing the same single "\n". Looks identical to the
#     ARG-zero case but reaches it through a different branch — pin both to
#     make the path explicit.
#   * Windows NUL (= what Git Bash maps /dev/null to) must ALSO be classified
#     as non-TTY (DR-0008). MSVCRT `_isatty()` famously lies about NUL; the
#     die impl is required to use `GetConsoleMode` instead and so this case
#     runs unconditionally — no OS-specific skip.

# ARG path wins when both ARGS and stdin are supplied.
expect_die_output  'boundary/arg-vs-stdin-arg-wins'        'STDIN_IGNORED' $'ARG\n' -- "${DIE_BIN}" -- ARG

# `die --` (zero ARG) + stdin pipe → ARG path (empty join + append \n).
# stdin content is dropped.
expect_die_output  'boundary/dash-dash-zero-arg-stdin-ignored' 'STDIN_DROPPED' $'\n' -- "${DIE_BIN}" --

# `die --` (zero ARG) + stdin /dev/null → identical to the pipe case.
expect_die_output  'boundary/dash-dash-zero-arg-no-stdin'  '__NOSTDIN__' $'\n'      -- "${DIE_BIN}" --

# No `--` + stdin pipe → stdin path forwards bytes (append \n if missing).
expect_die_output  'boundary/no-dash-dash-stdin-forwards'  'X'             $'X\n'   -- "${DIE_BIN}"

# No `--` + stdin /dev/null → stdin path forwards an empty input → single \n.
# /dev/null is a char device but NOT a TTY (POSIX `isatty(3)` returns false;
# Windows `GetConsoleMode` fails for NUL). Runs unconditionally on all OSes
# under DR-0008.
expect_die_output  'boundary/no-dash-dash-empty-stdin'     '__NOSTDIN__' $'\n'      -- "${DIE_BIN}"

# No `--` + stdin from a regular file → stdin path forwards file contents.
# Verifies that `die <file.txt` is classified as forward, not help.
_tmp_file=$(mktemp); printf 'FILE_DATA' >"$_tmp_file"
expect_die_output  'boundary/no-dash-dash-regfile-forwards' '__NOSTDIN__' $'FILE_DATA\n' -- bash -c "${DIE_BIN} <\"${_tmp_file}\""
rm -f "$_tmp_file"

# No `--` + stdin from process substitution (`< <(...)`, opens /dev/fd/N for
# read which is a socket on Linux / pipe on macOS) → stdin path forwards.
expect_die_output  'boundary/no-dash-dash-procsub-forwards' '__NOSTDIN__' $'PROCSUB\n' -- bash -c "${DIE_BIN} < <(printf PROCSUB)"

# `die -n --` (zero ARG + -n) → ARG path empty, -n suppresses append → "".
raw_byte_check  'boundary/-n-dash-dash-zero-arg-empty'  '__NOSTDIN__' ''         -- "${DIE_BIN}" -n --

# ---- Empty sep edge cases ----
# Spec contour: --sep '' joins ARGs with nothing between them. The append
# decision still looks at the joined string's last byte exactly as above.
expect_die_output  'trim-none/sep-empty/last-letter'         '__NOSTDIN__' $'an\n'     -- "${DIE_BIN}" --trim none --sep '' -- a n
expect_die_output  'trim-none/sep-empty/last-lf'             '__NOSTDIN__' $'ab\n'     -- "${DIE_BIN}" --trim none --sep '' -- a $'b\n'
expect_die_output  'trim-none/sep-empty/last-cr'             '__NOSTDIN__' $'ab\r\n'   -- "${DIE_BIN}" --trim none --sep '' -- a $'b\r'
expect_die_output  'trim-none/sep-empty/last-empty'          '__NOSTDIN__' $'a\n'      -- "${DIE_BIN}" --trim none --sep '' -- a ''
expect_die_output  'trim-none/sep-empty/all-empty'           '__NOSTDIN__' $'\n'       -- "${DIE_BIN}" --trim none --sep '' -- '' ''
raw_byte_check  '-n/trim-none/sep-empty/last-letter'      '__NOSTDIN__' 'an'        -- "${DIE_BIN}" -n --trim none --sep '' -- a n
raw_byte_check  '-n/trim-none/sep-empty/last-lf-no-suppress' '__NOSTDIN__' $'ab\n'  -- "${DIE_BIN}" -n --trim none --sep '' -- a $'b\n'
raw_byte_check  '-n/trim-none/sep-empty/last-empty-no-lf' '__NOSTDIN__' 'a'         -- "${DIE_BIN}" -n --trim none --sep '' -- a ''

# ---- sep "" with trailing empty ARGs exposes the previous ARG's last byte ----
# Spec contour: with --sep '' and a chain of trailing empty ARGs, the joined
# string's last byte is the last byte of the last non-empty ARG, because
# empty ARGs contribute nothing and the empty separator inserts nothing.
# The append decision then evaluates that exposed byte, NOT something
# attributable to the empty trailing ARGs.

# Letter-tail of the last non-empty ARG is exposed → append \n.
expect_die_output  'sep-empty/expose-letter-tail'           '__NOSTDIN__' $'ab\n'    -- "${DIE_BIN}" --trim none --sep '' -- a b '' '' ''
expect_die_output  'sep-empty/expose-letter-mid-empty'      '__NOSTDIN__' $'ab\n'    -- "${DIE_BIN}" --trim none --sep '' -- a '' b ''

# \n-tail of the last non-empty ARG is exposed → no append.
expect_die_output  'sep-empty/expose-lf-tail'               '__NOSTDIN__' $'ab\n'    -- "${DIE_BIN}" --trim none --sep '' -- a $'b\n' '' ''
expect_die_output  'sep-empty/expose-lf-tail-first-arg'     '__NOSTDIN__' $'a\n'     -- "${DIE_BIN}" --trim none --sep '' -- $'a\n' '' '' ''

# \r-tail of the last non-empty ARG is exposed → append \n → "...\r\n".
expect_die_output  'sep-empty/expose-cr-tail'               '__NOSTDIN__' $'a\r\n'   -- "${DIE_BIN}" --trim none --sep '' -- $'a\r' ''

# ---- Non-empty sep + trailing empty ARG: sep's last byte is exposed ----
# Spec contour: when the last ARG is empty (and ARGs >= 2), the joined
# string ends with the separator. The append decision then looks at the
# sep's last byte, NOT the last ARG's content.

# sep = "\r" → joined ends with \r → not \n → append \n → "...\r\n"
expect_die_output  'sep-cr/last-empty-cr-exposed'           '__NOSTDIN__' $'a\r\n'   -- "${DIE_BIN}" --trim none --sep $'\r' -- a ''
# sep = "\n" → joined ends with \n → no append
expect_die_output  'sep-lf/last-empty-lf-exposed'           '__NOSTDIN__' $'a\n'     -- "${DIE_BIN}" --trim none --sep $'\n' -- a ''
# sep = "XYZ" → joined ends with Z → not \n → append
expect_die_output  'sep-multichar/last-empty-Z-exposed'     '__NOSTDIN__' $'aXYZ\n'  -- "${DIE_BIN}" --trim none --sep 'XYZ' -- a ''

# Two empty trailing ARGs duplicate the sep at the tail.
# sep = "\r" twice → "\r\r" → not \n → append → "\r\r\n"
expect_die_output  'sep-cr/two-empty-trailing'              '__NOSTDIN__' $'a\r\r\n' -- "${DIE_BIN}" --trim none --sep $'\r' -- a '' ''
# sep = "\n" twice → "\n\n" → ends in \n → no append (empty line preserved
# in the spirit of DR-0002).
expect_die_output  'sep-lf/two-empty-trailing'              '__NOSTDIN__' $'a\n\n'   -- "${DIE_BIN}" --trim none --sep $'\n' -- a '' ''

# All-empty ARGs with non-empty sep: the sep appears between adjacent empties.
# Two empties → one sep slot in the middle → just the sep.
expect_die_output  'sep-X/two-empty-args'                   '__NOSTDIN__' $'X\n'     -- "${DIE_BIN}" --trim none --sep 'X' -- '' ''
# Single empty ARG → no sep slot (no neighbour) → empty joined → just \n.
expect_die_output  'sep-X/one-empty-arg'                    '__NOSTDIN__' $'\n'      -- "${DIE_BIN}" --trim none --sep 'X' -- ''

# -n suppresses the append even when sep alone is exposed.
raw_byte_check  '-n/sep-cr/last-empty-no-append'         '__NOSTDIN__' $'a\r'     -- "${DIE_BIN}" -n --trim none --sep $'\r' -- a ''
raw_byte_check  '-n/sep-lf/last-empty-already-lf'        '__NOSTDIN__' $'a\n'     -- "${DIE_BIN}" -n --trim none --sep $'\n' -- a ''

# ---- trim each + whitespace-only ARG = effectively empty ----
# Spec contour: --trim each strips ASCII whitespace around each ARG. A
# whitespace-only ARG (e.g. '   ', '\t', '\n\v\f\r ') trims to ''. So with
# --trim each (the default), even a non-empty ARG list can effectively
# leave the joined string ending with the separator — same as the
# trim-none + empty-last-ARG case above.

# trim each + whitespace-only last ARG → effectively empty → sep tail exposed
expect_die_output  'trim-each/sep-cr/whitespace-last'       '__NOSTDIN__' $'a\r\n'   -- "${DIE_BIN}" --trim each --sep $'\r' -- a '   '
expect_die_output  'trim-each/sep-lf/whitespace-last'       '__NOSTDIN__' $'a\n'     -- "${DIE_BIN}" --trim each --sep $'\n' -- a $'\t'
expect_die_output  'trim-each/sep-cr/single-space-last'     '__NOSTDIN__' $'a\r\n'   -- "${DIE_BIN}" --trim each --sep $'\r' -- a ' '
expect_die_output  'trim-each/sep-multichar/whitespace-last' '__NOSTDIN__' $'aXYZ\n' -- "${DIE_BIN}" --trim each --sep 'XYZ' -- a '   '

# All-whitespace ARGs with --trim each → all become empty → joined is just
# the separators between them.
expect_die_output  'trim-each/sep-cr/all-whitespace'        '__NOSTDIN__' $'\r\n'    -- "${DIE_BIN}" --trim each --sep $'\r' -- '   ' '   '
expect_die_output  'trim-each/sep-lf/all-whitespace'        '__NOSTDIN__' $'\n'      -- "${DIE_BIN}" --trim each --sep $'\n' -- '   ' '   '
expect_die_output  'trim-each/sep-X/all-whitespace'         '__NOSTDIN__' $'X\n'     -- "${DIE_BIN}" --trim each --sep 'X' -- '   ' '   '

# -n + trim each + whitespace-last → sep tail exposed, no append
raw_byte_check  '-n/trim-each/sep-cr/whitespace-last'    '__NOSTDIN__' $'a\r'     -- "${DIE_BIN}" -n --trim each --sep $'\r' -- a '   '
raw_byte_check  '-n/trim-each/sep-lf/whitespace-last'    '__NOSTDIN__' $'a\n'     -- "${DIE_BIN}" -n --trim each --sep $'\n' -- a $'\t'

# ---- sep is an arbitrary byte sequence: multi-char and multi-byte (non-ASCII) ----
# Spec contour: --sep takes an arbitrary byte sequence (no length or charset
# restriction). The append decision only cares about the joined string's
# LAST BYTE, so for a multi-byte sep what matters is the trailing byte of
# the sep — which for any well-formed UTF-8 non-ASCII char is a
# continuation byte (0x80-0xBF), never \n or \r, so append always fires.

# Multi-char ASCII sep, normal join.
# Other multi-char patterns (`<br>`, `, `, `\n\t`, `\033[0m`, etc.) are
# all the same semantic class — an arbitrary byte sequence between ARGs —
# so they don't need separate cases; the join logic doesn't inspect the
# sep's content beyond its last byte (covered by sep-*/last-empty-*).
expect_die_output  'sep-multichar/comma-space'              '__NOSTDIN__' $'a, b, c\n' -- "${DIE_BIN}" --trim none --sep ', ' -- a b c
expect_die_output  'sep-multichar/double-space'             '__NOSTDIN__' $'a  b\n'    -- "${DIE_BIN}" --trim none --sep '  ' -- a b
expect_die_output  'sep-multichar/long-string'              '__NOSTDIN__' $'a<<-->>b\n' -- "${DIE_BIN}" --trim none --sep '<<-->>' -- a b

# Multi-byte UTF-8 sep (zenkaku / hiragana / emoji): last byte is a
# continuation byte, never \n, so append fires unconditionally.
expect_die_output  'sep-zenkaku-comma'                      '__NOSTDIN__' $'a\xe3\x80\x81b\n'  -- "${DIE_BIN}" --trim none --sep $'\xe3\x80\x81' -- a b
expect_die_output  'sep-hiragana'                           '__NOSTDIN__' $'a\xe3\x81\x82b\n'  -- "${DIE_BIN}" --trim none --sep $'\xe3\x81\x82' -- a b
expect_die_output  'sep-emoji-beer'                         '__NOSTDIN__' $'a\xf0\x9f\x8d\xbab\n' -- "${DIE_BIN}" --trim none --sep $'\xf0\x9f\x8d\xba' -- a b

# Multi-byte sep + trim-each + whitespace-last → sep tail (continuation
# byte) exposed → not \n → append.
expect_die_output  'sep-hiragana/trim-each/ws-last'         '__NOSTDIN__' $'a\xe3\x81\x82\n' -- "${DIE_BIN}" --trim each --sep $'\xe3\x81\x82' -- a '   '

# sep with embedded \n in the middle vs at the end
# - sep "X\n" → last byte \n → no append (joined ends with \n)
# - sep "\nX" → last byte X → append
expect_die_output  'sep-trailing-lf'                        '__NOSTDIN__' $'aX\nb\n'  -- "${DIE_BIN}" --trim none --sep $'X\n' -- a b
expect_die_output  'sep-trailing-lf/last-empty-no-append'   '__NOSTDIN__' $'aX\n'     -- "${DIE_BIN}" --trim none --sep $'X\n' -- a ''
expect_die_output  'sep-leading-lf'                         '__NOSTDIN__' $'a\nXb\n'  -- "${DIE_BIN}" --trim none --sep $'\nX' -- a b
expect_die_output  'sep-leading-lf/last-empty-append'       '__NOSTDIN__' $'a\nX\n'   -- "${DIE_BIN}" --trim none --sep $'\nX' -- a ''

# ---------- error / usage ----------
# Error message text is implementation-detail. We only assert: exit=1, stdout
# empty, stderr non-empty.
soft_err_check() {
    local name=$1; shift
    local tmp_out tmp_err exit_code
    tmp_out=$(mktemp); tmp_err=$(mktemp)
    "$@" </dev/null >"$tmp_out" 2>"$tmp_err"
    exit_code=$?
    local out_size; out_size=$(wc -c <"$tmp_out" | tr -d ' ')
    local err_size; err_size=$(wc -c <"$tmp_err" | tr -d ' ')
    rm -f "$tmp_out" "$tmp_err"
    if [ "${exit_code}" = "1" ] && [ "${out_size}" = "0" ] && [ "${err_size}" -gt 0 ]; then
        pass=$((pass + 1))
        printf '  PASS  err/%s\n' "${name}"
    else
        fail=$((fail + 1))
        failures+=("err/${name}")
        printf '  FAIL  err/%s  exit=%s stdout_size=%s stderr_size=%s\n' \
            "${name}" "${exit_code}" "${out_size}" "${err_size}"
    fi
}

soft_err_check 'missing-dash-dash'      "${DIE_BIN}" foo
soft_err_check 'sep-without-value'      "${DIE_BIN}" --sep
soft_err_check 'trim-missing-value'     "${DIE_BIN}" --trim
soft_err_check 'trim-invalid-value'     "${DIE_BIN}" --trim wrong -- foo
soft_err_check 'trim-equals-empty-value' "${DIE_BIN}" --trim= -- foo
soft_err_check 'unknown-long-option'    "${DIE_BIN}" --bogus -- foo
soft_err_check 'unknown-short-option'   "${DIE_BIN}" -x -- foo
soft_err_check 'leading-dash-non-option' "${DIE_BIN}" -X
soft_err_check 'option-like-arg-without-dashdash' "${DIE_BIN}" --foo

# NOTE on help-when-no-args (DR-0008): under the new spec, `die </dev/null`
# is the forward path (not help), so the old `help-when-no-args` proxy is
# removed. The genuine TTY-help branch is exercised in tests/tty.sh under
# a real pty.

# ---- --help option (DR-0008) ----
# Spec contour: `--help` placed BEFORE `--` is an option and emits the full
# help text (not just an error line) to stderr with exit 1, regardless of
# stdin state. `--help` placed AFTER `--` is treated as an ARG (= literal
# "--help") to preserve the DR-0001 "after `--` anything passes safely"
# property.
#
# These checks assert that stderr CONTAINS the literal "Usage:" string —
# the help text starts with "die — print …" and includes a "Usage:" line.
# This is what distinguishes the help branch from an "unknown option" error
# (which has neither "Usage:" nor multiple lines).

# Validates: exit==1, stdout empty, stderr non-empty AND contains MUST_SUBSTR.
# Usage: help_text_check NAME MUST_SUBSTR -- CMD ARGS...
# STDIN_DATA env behaves the same as run_case.
help_text_check() {
    local name=$1 must_substr=$2
    shift 2
    if [ "${1:-}" != "--" ]; then
        echo "internal: help_text_check '${name}' missing -- separator" >&2
        return 2
    fi
    shift
    local _tmp_out _tmp_err _exit
    _tmp_out=$(mktemp); _tmp_err=$(mktemp)
    if [ "${STDIN_DATA+set}" = "set" ]; then
        printf '%s' "${STDIN_DATA}" | "$@" >"${_tmp_out}" 2>"${_tmp_err}"
        _exit=$?
    else
        "$@" </dev/null >"${_tmp_out}" 2>"${_tmp_err}"
        _exit=$?
    fi
    local _out_size _err_size _err_text
    _out_size=$(wc -c <"${_tmp_out}" | tr -d ' ')
    _err_size=$(wc -c <"${_tmp_err}" | tr -d ' ')
    _err_text=$(cat "${_tmp_err}")
    rm -f "${_tmp_out}" "${_tmp_err}"
    local ok=1
    [ "${_exit}" = "1" ] || ok=0
    [ "${_out_size}" = "0" ] || ok=0
    [ "${_err_size}" -gt 0 ] || ok=0
    case "${_err_text}" in *"${must_substr}"*) ;; *) ok=0 ;; esac
    if [ "${ok}" = "1" ]; then
        pass=$((pass + 1))
        printf '  PASS  help/%s\n' "${name}"
    else
        fail=$((fail + 1))
        failures+=("help/${name}")
        printf '  FAIL  help/%s  exit=%s stdout_size=%s stderr_size=%s contains_%q=%s\n' \
            "${name}" "${_exit}" "${_out_size}" "${_err_size}" "${must_substr}" \
            "$(case "${_err_text}" in *"${must_substr}"*) echo yes ;; *) echo no ;; esac)"
    fi
}

# --help with no stdin → full help text (contains "Usage:") to stderr, exit 1.
help_text_check 'help-option/no-stdin'           'Usage:' -- "${DIE_BIN}" --help

# --help with a pipe on stdin → help wins over forward; stdin is ignored.
STDIN_DATA='STDIN_IGNORED_BY_HELP'
help_text_check 'help-option/with-stdin-pipe'    'Usage:' -- "${DIE_BIN}" --help
unset STDIN_DATA

# --help with ARGS following → help wins (option parsed before `--`).
help_text_check 'help-option/with-trailing-args' 'Usage:' -- "${DIE_BIN}" --help -- foo bar

# `die -- --help` is the ARG path; "--help" is treated as a literal ARG.
# Already covered above by `arg/dash-dash-then-literal-help`; not duplicated.

# ---- Option parsing edge cases that are NOT errors ----
# Spec contour: --sep accepts both '--sep VALUE' and '--sep=VALUE' forms;
# empty VALUE is allowed (joins ARGs with no separator). Duplicate options
# are accepted with last-wins semantics. Option order before `--` does not
# matter — they all parse independently into separate flags.

# --sep accepts the --sep=VALUE form (long-with-equals).
expect_die_output  'sep-equals-form'                 '__NOSTDIN__' $'a,b,c\n'   -- "${DIE_BIN}" --sep=',' -- a b c

# --sep= (empty value) is a valid empty separator, not an error.
expect_die_output  'sep-equals-empty-value'          '__NOSTDIN__' $'abc\n'     -- "${DIE_BIN}" --sep= -- a b c

# --trim=VALUE accepts the long-with-equals form too.
expect_die_output  'trim-equals-valid-value'         '__NOSTDIN__' $'foo bar\n' -- "${DIE_BIN}" --trim=each -- ' foo ' ' bar '

# Duplicate options: last wins (NOT an error).
expect_die_output  'duplicate-sep-last-wins'         '__NOSTDIN__' $'a;b\n'     -- "${DIE_BIN}" --sep ',' --sep ';' -- a b
expect_die_output  'duplicate-trim-last-wins'        '__NOSTDIN__' $' foo bar \n' -- "${DIE_BIN}" --trim each --trim none -- ' foo ' ' bar '

# Option order before `--` is irrelevant.
raw_byte_check  'option-order/-n-then-sep'        '__NOSTDIN__' 'a,b'        -- "${DIE_BIN}" -n --sep ',' -- a b
raw_byte_check  'option-order/sep-then--n'        '__NOSTDIN__' 'a,b'        -- "${DIE_BIN}" --sep ',' -n -- a b
raw_byte_check  'option-order/all-three-ways'     '__NOSTDIN__' 'a,b'        -- "${DIE_BIN}" --trim each -n --sep ',' -- ' a ' ' b '

# ---------- summary ----------
echo
echo "==== summary: pass=${pass} fail=${fail} ===="
if [ "${fail}" -gt 0 ]; then
    printf 'failures:\n'
    for f in "${failures[@]}"; do printf '  - %s\n' "${f}"; done
    exit 1
fi
exit 0
