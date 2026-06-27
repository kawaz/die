// Unit tests for die (MoonBit implementation).
//
// White-box tests: this file is part of the main package, so private
// functions (trim_space, join_args, append_lf_str, append_lf_bytes,
// parse_trim) are accessible directly.
//
// Run: cd mbt && moon test --target native

// ---------------------------------------------------------------------------
// trim_space — ASCII-only whitespace trimming
// ---------------------------------------------------------------------------

// Each of the 6 ASCII whitespace bytes trimmed from leading/trailing position.

///|
test "trim/sp_leading" {
  assert_eq(trim_space(" hello"), "hello")
}

///|
test "trim/sp_trailing" {
  assert_eq(trim_space("hello "), "hello")
}

///|
test "trim/ht_leading" {
  assert_eq(trim_space("\thello"), "hello")
}

///|
test "trim/ht_trailing" {
  assert_eq(trim_space("hello\t"), "hello")
}

///|
test "trim/lf_leading" {
  assert_eq(trim_space("\nhello"), "hello")
}

///|
test "trim/lf_trailing" {
  assert_eq(trim_space("hello\n"), "hello")
}

///|
test "trim/vt_leading" {
  assert_eq(trim_space("\u{000B}hello"), "hello")
}

///|
test "trim/vt_trailing" {
  assert_eq(trim_space("hello\u{000B}"), "hello")
}

///|
test "trim/ff_leading" {
  assert_eq(trim_space("\u{000C}hello"), "hello")
}

///|
test "trim/ff_trailing" {
  assert_eq(trim_space("hello\u{000C}"), "hello")
}

///|
test "trim/cr_leading" {
  assert_eq(trim_space("\rhello"), "hello")
}

///|
test "trim/cr_trailing" {
  assert_eq(trim_space("hello\r"), "hello")
}

// Combined leading + trailing mixed ASCII whitespace

///|
test "trim/combined_leading_trailing" {
  assert_eq(
    trim_space(" \t\r\n\u{000B}\u{000C} hello \t\r\n\u{000B}\u{000C} "),
    "hello",
  )
}

// All-whitespace input → empty string

///|
test "trim/all_whitespace_sp" {
  assert_eq(trim_space("   "), "")
}

///|
test "trim/all_whitespace_mixed" {
  assert_eq(trim_space(" \t\r\n\u{000B}\u{000C}"), "")
}

// Empty input → empty string

///|
test "trim/empty" {
  assert_eq(trim_space(""), "")
}

// Interior whitespace is preserved

///|
test "trim/interior_sp_preserved" {
  assert_eq(trim_space("foo bar"), "foo bar")
}

///|
test "trim/interior_ht_preserved" {
  assert_eq(trim_space("foo\tbar"), "foo\tbar")
}

///|
test "trim/interior_lf_preserved" {
  assert_eq(trim_space("foo\nbar"), "foo\nbar")
}

///|
test "trim/interior_mixed_preserved" {
  assert_eq(trim_space("  foo \t bar  "), "foo \t bar")
}

// Unicode whitespace — MUST NOT be trimmed (ASCII-only spec)

///|
test "trim/nbsp_not_trimmed_leading" {
  // U+00A0 NO-BREAK SPACE — encoded as UTF-8 0xC2 0xA0
  // In MoonBit string literal \u{00A0}
  let nbsp = "\u{00A0}"
  assert_eq(trim_space(nbsp + "hello"), nbsp + "hello")
}

///|
test "trim/nbsp_not_trimmed_trailing" {
  let nbsp = "\u{00A0}"
  assert_eq(trim_space("hello" + nbsp), "hello" + nbsp)
}

///|
test "trim/u2028_not_trimmed" {
  // U+2028 LINE SEPARATOR
  let ls = "\u{2028}"
  assert_eq(trim_space(ls + "hello" + ls), ls + "hello" + ls)
}

///|
test "trim/fullwidth_space_not_trimmed" {
  // U+3000 IDEOGRAPHIC SPACE
  let fw = "\u{3000}"
  assert_eq(trim_space(fw + "hello" + fw), fw + "hello" + fw)
}

// No-op: already trimmed

///|
test "trim/already_clean" {
  assert_eq(trim_space("hello"), "hello")
}

// ---------------------------------------------------------------------------
// join_args — join with sep and trim mode
// ---------------------------------------------------------------------------

// 0 args

///|
test "join/zero_args_default_sep" {
  let args : Array[String] = []
  assert_eq(join_args(args[:], " ", "each"), "")
}

///|
test "join/zero_args_empty_sep" {
  let args : Array[String] = []
  assert_eq(join_args(args[:], "", "each"), "")
}

// 1 arg

///|
test "join/one_arg_no_trim" {
  assert_eq(join_args(["hello"][:], " ", "none"), "hello")
}

///|
test "join/one_arg_trim_each" {
  assert_eq(join_args(["  hello  "][:], " ", "each"), "hello")
}

///|
test "join/one_arg_trim_all" {
  assert_eq(join_args(["  hello  "][:], " ", "all"), "hello")
}

// 3 args with default sep

///|
test "join/three_args_default_sep_trim_each" {
  assert_eq(join_args(["foo", "bar", "baz"][:], " ", "each"), "foo bar baz")
}

///|
test "join/three_args_empty_sep_trim_each" {
  assert_eq(join_args(["foo", "bar", "baz"][:], "", "each"), "foobarbaz")
}

///|
test "join/three_args_multichar_sep" {
  assert_eq(join_args(["foo", "bar", "baz"][:], ", ", "none"), "foo, bar, baz")
}

// trim mode: each — trims each arg individually

///|
test "join/trim_each_trims_individually" {
  assert_eq(join_args(["  foo  ", "  bar  "][:], " ", "each"), "foo bar")
}

// trim mode: all — join first, then trim the whole string

///|
test "join/trim_all_trims_whole" {
  // join: "  foo  " + " " + "  bar  " = "  foo     bar  " then trim outer
  assert_eq(join_args(["  foo  ", "  bar  "][:], " ", "all"), "foo     bar")
}

///|
test "join/trim_all_outer_only" {
  // join: " a " + "|" + " b " = " a | b " then trim outer
  assert_eq(join_args([" a ", " b "][:], "|", "all"), "a | b")
}

// trim mode: none — no trimming at all

///|
test "join/trim_none_preserves_whitespace" {
  // sep=" " between "  foo  " and "  bar  " gives "  foo     bar  "
  assert_eq(join_args(["  foo  ", "  bar  "][:], " ", "none"), "  foo     bar  ")
}

// empty ARGs mixed in

///|
test "join/empty_arg_trim_each" {
  // empty string after trim is still empty; joined with sep
  assert_eq(join_args(["", "hello", ""][:], " ", "each"), " hello ")
}

///|
test "join/empty_arg_trim_none" {
  assert_eq(join_args(["", "hello", ""][:], "-", "none"), "-hello-")
}

///|
test "join/whitespace_only_arg_trim_each_becomes_empty" {
  // "  " after trim_each becomes "", joined with sep
  assert_eq(join_args(["  ", "hi", "  "][:], " ", "each"), " hi ")
}

///|
test "join/all_empty_args" {
  assert_eq(join_args(["", "", ""][:], ",", "none"), ",,")
}

// ---------------------------------------------------------------------------
// append_lf_str — ensure string ends with LF
// ---------------------------------------------------------------------------

// normalize = false: always no-op

///|
test "append_lf_str/no_normalize_no_lf" {
  assert_eq(append_lf_str("hello", false), "hello")
}

///|
test "append_lf_str/no_normalize_with_lf" {
  assert_eq(append_lf_str("hello\n", false), "hello\n")
}

///|
test "append_lf_str/no_normalize_empty" {
  assert_eq(append_lf_str("", false), "")
}

// normalize = true: append LF if not already ending with LF

///|
test "append_lf_str/normalize_no_lf_appends" {
  assert_eq(append_lf_str("hello", true), "hello\n")
}

///|
test "append_lf_str/normalize_already_lf_no_op" {
  assert_eq(append_lf_str("hello\n", true), "hello\n")
}

///|
test "append_lf_str/normalize_crlf_no_op" {
  // ends with \n (the \n of \r\n) — treated as already having LF
  assert_eq(append_lf_str("hello\r\n", true), "hello\r\n")
}

///|
test "append_lf_str/normalize_bare_cr_appends" {
  // bare CR at end — not a LF terminator, append LF
  assert_eq(append_lf_str("hello\r", true), "hello\r\n")
}

///|
test "append_lf_str/normalize_double_lf_preserved" {
  // already ends with \n — no extra appended
  assert_eq(append_lf_str("hello\n\n", true), "hello\n\n")
}

///|
test "append_lf_str/normalize_empty_appends_lf" {
  assert_eq(append_lf_str("", true), "\n")
}

// ---------------------------------------------------------------------------
// append_lf_bytes — ensure byte array ends with LF
// ---------------------------------------------------------------------------

// normalize = false: always no-op

///|
test "append_lf_bytes/no_normalize_no_lf" {
  let b = [b'h', b'i']
  let out = append_lf_bytes(b, false)
  assert_eq(out.length(), 2)
  assert_eq(out[1].to_int(), 0x69) // 'i'
}

///|
test "append_lf_bytes/no_normalize_with_lf" {
  let b = [b'h', b'i', b'\n']
  let out = append_lf_bytes(b, false)
  assert_eq(out.length(), 3)
}

///|
test "append_lf_bytes/no_normalize_empty" {
  let b : Array[Byte] = []
  let out = append_lf_bytes(b, false)
  assert_eq(out.length(), 0)
}

// normalize = true

///|
test "append_lf_bytes/normalize_no_lf_appends" {
  let b = [b'h', b'i']
  let out = append_lf_bytes(b, true)
  assert_eq(out.length(), 3)
  assert_eq(out[2].to_int(), 0x0a)
}

///|
test "append_lf_bytes/normalize_already_lf_no_op" {
  let b = [b'h', b'i', b'\n']
  let out = append_lf_bytes(b, true)
  assert_eq(out.length(), 3)
}

///|
test "append_lf_bytes/normalize_crlf_no_op" {
  // ends with 0x0A — the LF of CRLF
  let b = [b'h', 0x0d, 0x0a]
  let out = append_lf_bytes(b, true)
  assert_eq(out.length(), 3)
}

///|
test "append_lf_bytes/normalize_bare_cr_appends" {
  let b = [b'h', 0x0d]
  let out = append_lf_bytes(b, true)
  assert_eq(out.length(), 3)
  assert_eq(out[2].to_int(), 0x0a)
}

///|
test "append_lf_bytes/normalize_double_lf_preserved" {
  let b = [b'x', b'\n', b'\n']
  let out = append_lf_bytes(b, true)
  assert_eq(out.length(), 3)
}

///|
test "append_lf_bytes/normalize_empty_appends_lf" {
  let b : Array[Byte] = []
  let out = append_lf_bytes(b, true)
  assert_eq(out.length(), 1)
  assert_eq(out[0].to_int(), 0x0a)
}

// ---------------------------------------------------------------------------
// parse_trim — accepts each/all/none, rejects everything else
// ---------------------------------------------------------------------------

// Use assert_true(x == ...) for String? to avoid Show-deprecation warnings.

///|
test "parse_trim/each" {
  assert_true(parse_trim("each") == Some("each"))
}

///|
test "parse_trim/all" {
  assert_true(parse_trim("all") == Some("all"))
}

///|
test "parse_trim/none" {
  assert_true(parse_trim("none") == Some("none"))
}

///|
test "parse_trim/empty_rejected" {
  assert_true(parse_trim("") == None)
}

///|
test "parse_trim/uppercase_rejected" {
  assert_true(parse_trim("Each") == None)
}

///|
test "parse_trim/ALL_rejected" {
  assert_true(parse_trim("ALL") == None)
}

///|
test "parse_trim/unknown_rejected" {
  assert_true(parse_trim("trim") == None)
}

///|
test "parse_trim/with_spaces_rejected" {
  assert_true(parse_trim(" each") == None)
}
