#!/usr/bin/env bash
#
# Shared behavioural test suite for `die`. Invoke with DIE_BIN pointing to a
# built binary:
#
#   DIE_BIN=/path/to/go/bin/die tests/run.sh
#
# Exits 0 if every case passes, 1 otherwise.
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
        echo "  SKIP  stdin/crlf-treated-as-lf  (Git Bash pipe strips \\r before child stdin)"
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

# Run cmd, capture stderr into FILE_PATH (caller-allocated tmp file).
# Usage: _run_raw_capture FILE_PATH STDIN_DATA -- CMD ARGS...
#   STDIN_DATA == '__NOSTDIN__' → redirect stdin from /dev/null
# bash 3.2 compatible — no `local -n` nameref (macOS ships bash 3.2).
_run_raw_capture() {
    local _out_tmp=$1
    local _stdin=$2
    shift 2
    if [ "${1:-}" != '--' ]; then
        echo "internal: _run_raw_capture missing --" >&2; return 2
    fi
    shift
    if [ "${_stdin}" != '__NOSTDIN__' ]; then
        printf '%s' "${_stdin}" | "$@" 2>"${_out_tmp}" >/dev/null
    else
        "$@" </dev/null 2>"${_out_tmp}" >/dev/null
    fi
}

# strict byte match — for -n cases
raw_byte_check() {
    local name=$1 stdin_data=$2 expected_stderr=$3
    shift 3
    if [ "${1:-}" != '--' ]; then
        echo "internal: raw_byte_check '${name}' missing --" >&2; return 2
    fi
    shift
    local tmp; tmp=$(mktemp)
    _run_raw_capture "$tmp" "${stdin_data}" -- "$@"
    local got; got=$(od -An -c "$tmp" | tr -d ' \n')
    local want; want=$(printf '%s' "${expected_stderr}" | od -An -c | tr -d ' \n')
    rm -f "$tmp"
    if [ "${got}" = "${want}" ]; then
        pass=$((pass + 1))
        printf '  PASS  raw/%s\n' "${name}"
    else
        fail=$((fail + 1))
        failures+=("raw/${name}")
        printf '  FAIL  raw/%s\n' "${name}"
        printf '        stderr bytes want=%s\n' "${want}"
        printf '        stderr bytes got =%s\n' "${got}"
    fi
}

# ends_with_newline FILE — true if last byte is \x0a OR last two bytes are \x0d\x0a
ends_with_newline() {
    local f=$1
    local sz; sz=$(wc -c <"$f" | tr -d ' ')
    [ "${sz}" -eq 0 ] && return 1
    # check last byte
    local last; last=$(tail -c 1 "$f" | od -An -tx1 | tr -d ' \n')
    [ "${last}" = "0a" ] && return 0
    # check last two bytes for \r\n
    if [ "${sz}" -ge 2 ]; then
        local last2; last2=$(tail -c 2 "$f" | od -An -tx1 | tr -d ' \n')
        [ "${last2}" = "0d0a" ] && return 0
    fi
    return 1
}

# loose EOL check — for default cases (DR-0006: cursor-safe = ends with \n or \r\n)
# Usage: loose_eol_check NAME STDIN_DATA EXPECTED_PREFIX -- CMD ARGS...
#   EXPECTED_PREFIX: the output must start with these bytes (prefix match).
#   Pass '' to skip prefix check.
loose_eol_check() {
    local name=$1 stdin_data=$2 expected_prefix=$3
    shift 3
    if [ "${1:-}" != '--' ]; then
        echo "internal: loose_eol_check '${name}' missing --" >&2; return 2
    fi
    shift
    local tmp; tmp=$(mktemp)
    _run_raw_capture "$tmp" "${stdin_data}" -- "$@"
    local ok=1
    local detail=''
    # check ends with newline
    if ! ends_with_newline "$tmp"; then
        ok=0
        detail+=' [not ending with \\n or \\r\\n]'
    fi
    # check prefix if given
    if [ -n "${expected_prefix}" ]; then
        local prefix_len=${#expected_prefix}
        local got_prefix; got_prefix=$(head -c "${prefix_len}" "$tmp")
        if [ "${got_prefix}" != "${expected_prefix}" ]; then
            ok=0
            detail+=" [prefix mismatch: want=$(printf '%s' "${expected_prefix}" | od -An -c | tr -d ' \n') got=$(printf '%s' "${got_prefix}" | od -An -c | tr -d ' \n')]"
        fi
    fi
    rm -f "$tmp"
    if [ "${ok}" = "1" ]; then
        pass=$((pass + 1))
        printf '  PASS  raw/%s\n' "${name}"
    else
        fail=$((fail + 1))
        failures+=("raw/${name}")
        printf '  FAIL  raw/%s%s\n' "${name}" "${detail}"
    fi
}

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
# crt_expand BYTES → bytes with every \n that isn't already preceded by \r
# replaced with \r\n. Emulates Windows MSVCRT _write text-mode behaviour.
# Pure bash (no sed/awk) for portability across BSD/GNU/MSYS coreutils.
crt_expand() {
    local in=$1 out='' prev='' i ch
    for (( i = 0; i < ${#in}; i++ )); do
        ch=${in:i:1}
        if [ "$ch" = $'\n' ] && [ "$prev" != $'\r' ]; then
            out+=$'\r\n'
        else
            out+=$ch
        fi
        prev=$ch
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
    local tmp; tmp=$(mktemp)
    _run_raw_capture "$tmp" "${stdin_data}" -- "$@"
    local got; got=$(od -An -c "$tmp" | tr -d ' \n')
    local want_native; want_native=$(printf '%s' "${expected_die}" | od -An -c | tr -d ' \n')
    local want_crt; want_crt=$(crt_expand "${expected_die}" | od -An -c | tr -d ' \n')
    rm -f "$tmp"
    if [ "${got}" = "${want_native}" ] || [ "${got}" = "${want_crt}" ]; then
        pass=$((pass + 1))
        printf '  PASS  raw/%s\n' "${name}"
    else
        fail=$((fail + 1))
        failures+=("raw/${name}")
        printf '  FAIL  raw/%s\n' "${name}"
        printf '        observed bytes  = %s\n' "${got}"
        printf '        expected (die)  = %s\n' "${want_native}"
        printf '        expected (CRT)  = %s\n' "${want_crt}"
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
raw_byte_check  'stdin/-n-no-lf'                  'X'           'X'          -- "${DIE_BIN}" -n
raw_byte_check  'stdin/-n-keeps-lf'               $'X\n'        $'X\n'       -- "${DIE_BIN}" -n
raw_byte_check  'stdin/-n-keeps-crlf'             $'X\r\n'      $'X\r\n'     -- "${DIE_BIN}" -n
raw_byte_check  'stdin/-n-keeps-cr'               $'X\r'        $'X\r'       -- "${DIE_BIN}" -n
raw_byte_check  'stdin/-n-keeps-double-lf'        $'X\n\n'      $'X\n\n'     -- "${DIE_BIN}" -n
raw_byte_check  'stdin/-n-empty-stays-empty'      ''            ''           -- "${DIE_BIN}" -n

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
soft_err_check 'trim-invalid-value'     "${DIE_BIN}" --trim wrong -- foo
soft_err_check 'unknown-long-option'    "${DIE_BIN}" --bogus -- foo

# help on no-args + stdin redirected from /dev/null (== TTY-less but still
# "no piped data"): impls may treat /dev/null differently from a TTY. The spec
# says "ARGS empty + stdin TTY → help", so we cannot test the pure-TTY case
# from this script. We at least verify exit=1 + stderr non-empty for the
# "no args, /dev/null stdin" case as a reasonable proxy.
soft_err_check 'help-when-no-args'      "${DIE_BIN}"

# ---------- summary ----------
echo
echo "==== summary: pass=${pass} fail=${fail} ===="
if [ "${fail}" -gt 0 ]; then
    printf 'failures:\n'
    for f in "${failures[@]}"; do printf '  - %s\n' "${f}"; done
    exit 1
fi
exit 0
