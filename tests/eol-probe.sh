#!/usr/bin/env bash
# Windows EOL probe — observe how die's "\n" output gets mangled by the CRT
# text-mode layer for each impl on the Windows runner. Run from the repo root.
#
# Usage (called from CI): bash scratchpad/windows-eol-probe.sh /path/to/die.exe
set -uo pipefail
DIE_BIN="${1:?usage: $0 <path/to/die(.exe)>}"

probe() {
    local name=$1 stdin_data=$2
    shift 2
    local tmp; tmp=$(mktemp)
    if [ "${stdin_data}" = '__NOSTDIN__' ]; then
        "$@" </dev/null 2>"$tmp" >/dev/null
    else
        printf '%s' "${stdin_data}" | "$@" 2>"$tmp" >/dev/null
    fi
    local bytes; bytes=$(od -An -c "$tmp" | tr -s ' ' | sed 's/^ //;s/ $//')
    printf '  %-40s | bytes: %s\n' "${name}" "${bytes}"
    rm -f "$tmp"
}

echo "== EOL probe against ${DIE_BIN} =="
echo "-- default mode (no -n) --"
probe 'default arg "X"'        '__NOSTDIN__' "$DIE_BIN" -- 'X'
probe 'default arg "X\n"'      '__NOSTDIN__' "$DIE_BIN" -- $'X\n'
probe 'default arg "X\r\n"'    '__NOSTDIN__' "$DIE_BIN" -- $'X\r\n'
probe 'default arg "X\r"'      '__NOSTDIN__' "$DIE_BIN" -- $'X\r'
probe 'default arg "X\n\n"'    '__NOSTDIN__' "$DIE_BIN" -- $'X\n\n'

probe 'default stdin "X"'      'X'           "$DIE_BIN"
probe 'default stdin "X\n"'    $'X\n'        "$DIE_BIN"
probe 'default stdin "X\r\n"'  $'X\r\n'      "$DIE_BIN"
probe 'default stdin "X\r"'    $'X\r'        "$DIE_BIN"
probe 'default stdin "X\n\n"'  $'X\n\n'      "$DIE_BIN"
probe 'default stdin ""'       ''            "$DIE_BIN"

echo "-- -n mode (cat-equivalent, byte-transparent) --"
probe '-n stdin "X"'           'X'           "$DIE_BIN" -n
probe '-n stdin "X\n"'         $'X\n'        "$DIE_BIN" -n
probe '-n stdin "X\r\n"'       $'X\r\n'      "$DIE_BIN" -n
probe '-n stdin "X\r"'         $'X\r'        "$DIE_BIN" -n
probe '-n stdin "X\n\n"'       $'X\n\n'      "$DIE_BIN" -n
probe '-n stdin ""'            ''            "$DIE_BIN" -n
