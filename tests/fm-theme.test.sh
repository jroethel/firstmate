#!/usr/bin/env bash
# Behavior tests for bin/fm-theme.sh: the per-home theme selection
# (config/theme), lookup by name in the home's themes first and the shipped
# themes second, the refusal rules for theme stylesheets, and font inlining
# into the resolved stylesheet.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

THEME="$ROOT/bin/fm-theme.sh"
TMP_ROOT=$(fm_test_tmproot fm-theme)

make_home() {  # <name>: an empty home plus an empty shipped-themes folder
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config/themes" "$home/shipped"
  printf '%s\n' "$home"
}

run_theme() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_CONFIG_OVERRIDE='' FM_THEME_SHIPPED_DIR="$home/shipped" "$THEME" "$@"
}

# write_theme <themes-dir> <name> <css>: a theme folder with theme.css and one
# font file the stylesheet may reference as fonts/demo.woff2.
write_theme() {
  mkdir -p "$1/$2/fonts"
  printf '%s\n' "$3" > "$1/$2/theme.css"
  printf 'demo-font-bytes' > "$1/$2/fonts/demo.woff2"
}

select_theme() {  # <home> <config/theme text>
  printf '%s\n' "$2" > "$1/config/theme"
}

has_line() {  # <text> <exact line>
  printf '%s\n' "$1" | grep -qxF -- "$2"
}

test_no_selection_prints_nothing() {
  local home out
  home=$(make_home none)
  out=$(run_theme "$home" selection) || fail "selection failed with no config/theme"
  [ -z "$out" ] || fail "selection printed something with no config/theme: $out"
  pass "no config/theme means no selection"
}

test_selection_fills_defaults_and_finds_a_shipped_theme() {
  local home out
  home=$(make_home defaults)
  write_theme "$home/shipped" demo ':root { color-scheme: light dark; }'
  select_theme "$home" 'theme=demo'
  out=$(run_theme "$home" selection) || fail "a shipped theme selection failed"
  has_line "$out" 'theme=demo' || fail "selection lost the theme name: $out"
  has_line "$out" 'layout=compact' || fail "layout did not default to compact: $out"
  has_line "$out" 'mode=auto' || fail "mode did not default to auto: $out"
  has_line "$out" 'origin=shipped' || fail "a shipped theme was not reported as shipped: $out"
  has_line "$out" "dir=$home/shipped/demo" || fail "selection did not name the shipped folder: $out"
  has_line "$out" 'reply=Captain, shipshape.' || fail "a theme with no voice line lost the default reply: $out"
  pass "a selection fills layout, mode, and reply defaults and finds a shipped theme"
}

test_a_home_theme_wins_over_a_shipped_theme_of_the_same_name() {
  local home out
  home=$(make_home precedence)
  write_theme "$home/shipped" demo ':root { color-scheme: light; }'
  write_theme "$home/config/themes" demo ':root { color-scheme: dark; }'
  select_theme "$home" $'theme=demo\nlayout=full\nmode=dark'
  out=$(run_theme "$home" selection) || fail "a home theme selection failed"
  has_line "$out" 'origin=home' || fail "the home theme did not win: $out"
  has_line "$out" "dir=$home/config/themes/demo" || fail "selection did not name the home folder: $out"
  has_line "$out" 'layout=full' || fail "the selected layout was lost: $out"
  has_line "$out" 'mode=dark' || fail "the selected mode was lost: $out"
  pass "lookup finds the home theme before a shipped theme of the same name"
}

test_layout_and_mode_apply_without_a_theme() {
  local home out
  home=$(make_home layout-only)
  select_theme "$home" $'# laptop home\nlayout=full\n\nmode=light'
  out=$(run_theme "$home" selection) || fail "a layout-only selection failed"
  has_line "$out" 'theme=' || fail "a layout-only selection named a theme: $out"
  has_line "$out" 'layout=full' || fail "a layout-only selection lost its layout: $out"
  has_line "$out" 'mode=light' || fail "a layout-only selection lost its mode: $out"
  has_line "$out" 'origin=none' || fail "a layout-only selection reported a theme origin: $out"
  pass "layout and mode apply with no theme named, and comments and blank lines are ignored"
}

test_a_missing_theme_names_both_folders_searched() {
  local home out rc
  home=$(make_home missing)
  select_theme "$home" 'theme=nowhere'
  set +e; out=$(run_theme "$home" selection 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a selection naming no existing theme was accepted"
  assert_contains "$out" 'nowhere' "the refusal did not name the theme"
  assert_contains "$out" "$home/config/themes" "the refusal did not name the home themes folder"
  assert_contains "$out" "$home/shipped" "the refusal did not name the shipped themes folder"
  pass "a missing theme is refused with the name and both folders searched"
}

test_a_malformed_selection_is_refused() {
  local home bad rc out
  home=$(make_home malformed)
  write_theme "$home/shipped" demo ':root { color-scheme: light; }'
  for bad in 'colour=red' 'layout=wide' 'mode=dim' 'theme=../demo' 'theme=Demo' $'theme=demo\ntheme=demo' 'theme demo'; do
    select_theme "$home" "$bad"
    set +e; out=$(run_theme "$home" selection 2>&1); rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "a malformed selection was accepted: $bad"
    assert_contains "$out" 'config/theme' "the refusal for '$bad' did not name the selection file"
  done
  pass "unknown keys, bad values, bad names, and repeated keys are refused"
}

test_a_voice_line_sets_the_reply_and_a_bad_one_is_refused() {
  local home out rc bad
  home=$(make_home voice)
  write_theme "$home/shipped" demo ':root { color-scheme: light; }'
  printf 'Captain, steady as she goes.\n' > "$home/shipped/demo/noop-reply"
  select_theme "$home" 'theme=demo'
  out=$(run_theme "$home" selection) || fail "a theme with a voice line failed"
  has_line "$out" 'reply=Captain, steady as she goes.' || fail "the voice line did not set the reply: $out"
  # The backtick below is a literal voice-line input that must never expand.
  # shellcheck disable=SC2016
  for bad in 'All quiet.' $'Captain, one.\nCaptain, two.' '' 'Captain, done; rm -rf ~' 'Captain, `whoami`' \
    "Captain, $(printf 'a%.0s' $(seq 1 112))"; do
    printf '%s\n' "$bad" > "$home/shipped/demo/noop-reply"
    set +e; out=$(run_theme "$home" selection 2>&1); rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "an invalid voice line was accepted: '$bad'"
    assert_contains "$out" 'noop-reply' "the refusal for '$bad' did not name the voice file"
  done
  pass "a voice line sets the no-op reply, and one outside the single safe Captain line is refused"
}

test_css_inlines_every_local_font_reference() {
  local home out encoded
  home=$(make_home inline)
  write_theme "$home/config/themes" demo ''
  cat > "$home/config/themes/demo/theme.css" <<'CSS'
@font-face { font-family: "Demo"; src: url("fonts/demo.woff2") format("woff2"); }
@font-face { font-family: "Demo2"; src: url('fonts/demo.woff2'); }
@font-face { font-family: "Demo3"; src: URL( fonts/demo.woff2 ); }
CSS
  select_theme "$home" 'theme=demo'
  out=$(run_theme "$home" css) || fail "a theme with local fonts did not resolve"
  encoded=$(printf 'demo-font-bytes' | base64 | tr -d '\n')
  [ "$(printf '%s\n' "$out" | grep -oF "url(\"data:font/woff2;base64,$encoded\")" | wc -l)" -eq 3 ] \
    || fail "not every font reference was inlined as a data URL: $out"
  assert_not_contains "$out" 'fonts/demo.woff2' "a font file path survived inlining"
  pass "css inlines quoted, single-quoted, and bare local font references as data URLs"
}

test_unsafe_home_themes_are_refused() {
  local home bad rc out
  home=$(make_home unsafe)
  select_theme "$home" 'theme=demo'
  while IFS= read -r bad; do
    write_theme "$home/config/themes" demo "$bad"
    set +e; out=$(run_theme "$home" css 2>&1); rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "an unsafe home theme was accepted: $bad"
    assert_contains "$out" 'demo' "the refusal did not name the theme: $bad"
  done <<'CASES'
</style><script>alert(1)</script>
/* a < b */ body { color: red; }
@import "https://example.invalid/x.css";
@IMPORT url(fonts/demo.woff2);
body { background: url(https://example.invalid/x.png); }
body { background: url("fonts/../theme.css"); }
body { background: url(fonts/absent.woff2); }
body { background: url("data:image/png;base64,AAAA"); }
body { background: image-set("https://example.invalid/x.png" 1x); }
body { background: -webkit-image-set("https://example.invalid/x.png" 1x); }
body { background: src("https://example.invalid/x.png"); }
a { b: \75 rl(https://example.invalid/x); }
/* url(https://example.invalid/x) */ body { color: red; }
CASES
  write_theme "$home/config/themes" demo 'body { background: url(fonts/linked.woff2); }'
  ln -s /etc/hostname "$home/config/themes/demo/fonts/linked.woff2"
  set +e; out=$(run_theme "$home" css 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a home theme referencing a symlinked font was accepted"
  pass "home themes that could escape the page or fetch anything are refused"
}

test_symlinked_or_oversized_themes_are_refused() {
  local home out rc
  home=$(make_home location)
  select_theme "$home" 'theme=demo'
  write_theme "$TMP_ROOT/elsewhere" demo 'body { color: red; }'
  ln -s "$TMP_ROOT/elsewhere/demo" "$home/config/themes/demo"
  set +e; out=$(run_theme "$home" css 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a symlinked home theme folder was accepted"
  rm -f "$home/config/themes/demo"
  mkdir -p "$home/config/themes/demo"
  ln -s "$TMP_ROOT/elsewhere/demo/theme.css" "$home/config/themes/demo/theme.css"
  set +e; out=$(run_theme "$home" css 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a symlinked theme.css was accepted"
  rm -rf "$home/config/themes/demo"
  write_theme "$home/config/themes" demo '@font-face { font-family: "Demo"; src: url(fonts/big.woff2); }'
  head -c 524289 /dev/zero > "$home/config/themes/demo/fonts/big.woff2"
  set +e; out=$(run_theme "$home" css 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a theme over the 512 KiB cap was accepted"
  assert_contains "$out" 'demo' "the size refusal did not name the theme"
  pass "a symlinked theme folder or stylesheet and a theme over the size cap are refused"
}

test_no_selection_needs_no_shipped_folder() {
  local home out
  home="$TMP_ROOT/bare-home"
  mkdir -p "$home"
  out=$(env -u FM_THEME_SHIPPED_DIR FM_HOME="$home" FM_CONFIG_OVERRIDE='' "$THEME" selection) \
    || fail "selection failed in a home with no config/theme and the default shipped folder"
  [ -z "$out" ] || fail "selection printed something with no config/theme: $out"
  pass "with no config/theme the resolver prints nothing and never needs the shipped folder"
}

test_a_shipped_theme_is_exempt_from_the_markup_check_only() {
  local home out rc bad
  home=$(make_home shipped-exempt)
  select_theme "$home" 'theme=demo'
  write_theme "$home/shipped" demo '/* a < b */ body { color: red; }'
  out=$(run_theme "$home" css) || fail "a shipped theme with a < in a comment was refused"
  for bad in '@import "https://example.invalid/x.css";' 'body { background: url(https://example.invalid/x.png); }' 'a { b: \75 rl(https://example.invalid/x); }'; do
    write_theme "$home/shipped" demo "$bad"
    set +e; out=$(run_theme "$home" css 2>&1); rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "a shipped theme passed the no-remote check: $bad"
  done
  pass "shipped themes skip the markup check but still pass the no-remote check"
}

test_digest_line_is_absent_without_a_named_theme() {
  local home out
  home=$(make_home digest-none)
  out=$(run_theme "$home" digest-line) || fail "digest-line failed with no selection"
  [ -z "$out" ] || fail "digest-line printed with no selection: $out"
  select_theme "$home" 'layout=full'
  out=$(run_theme "$home" digest-line) || fail "digest-line failed for a layout-only selection"
  [ -z "$out" ] || fail "digest-line printed for a selection naming no theme: $out"
  assert_absent "$home/.lavish/fleet-theme.css" "digest-line wrote a stylesheet with no theme named"
  pass "the digest has no theme line unless a theme is named"
}

test_digest_line_names_the_reply_and_writes_the_fleet_stylesheet() {
  local home out
  home=$(make_home digest-voice)
  write_theme "$home/config/themes" demo 'body { color: red; }'
  printf 'Captain, steady as she goes.\n' > "$home/config/themes/demo/noop-reply"
  select_theme "$home" 'theme=demo'
  out=$(run_theme "$home" digest-line) || fail "digest-line failed for a named theme"
  [ "$out" = "THEME: demo; no-op reply: Captain, steady as she goes.; fleet-page stylesheet: $home/.lavish/fleet-theme.css" ] \
    || fail "the theme line is not the contracted line: $out"
  [ "$(cat "$home/.lavish/fleet-theme.css")" = "$(run_theme "$home" css)" ] \
    || fail "the fleet-page stylesheet is not the resolved stylesheet"
  rm -f "$home/config/themes/demo/noop-reply"
  out=$(run_theme "$home" digest-line) || fail "digest-line failed for a theme with no voice line"
  assert_contains "$out" 'no-op reply: Captain, shipshape.;' "a theme with no voice line did not keep the default reply"
  pass "the theme line names the theme, its no-op reply, and the resolved fleet-page stylesheet"
}

test_digest_line_reports_an_unloadable_theme_and_keeps_the_default_reply() {
  local home out
  home=$(make_home digest-broken)
  select_theme "$home" 'theme=nowhere'
  out=$(run_theme "$home" digest-line) || fail "digest-line must never fail the digest"
  assert_contains "$out" 'THEME: nowhere could not be loaded' "an unloadable theme was not reported"
  assert_contains "$out" 'the no-op reply stays Captain, shipshape.' "an unloadable theme did not keep the default reply"
  assert_absent "$home/.lavish/fleet-theme.css" "an unloadable theme still wrote a stylesheet"
  pass "an unloadable theme is reported on the theme line and the default reply stands"
}

test_digest_line_read_only_never_writes_the_stylesheet() {
  local home out
  home=$(make_home digest-read-only)
  write_theme "$home/config/themes" demo 'body { color: red; }'
  select_theme "$home" 'theme=demo'
  out=$(run_theme "$home" digest-line --read-only) || fail "digest-line --read-only failed"
  [ "$out" = "THEME: demo; no-op reply: Captain, shipshape.; fleet-page stylesheet: $home/.lavish/fleet-theme.css" ] \
    || fail "the read-only theme line is not the contracted line: $out"
  assert_absent "$home/.lavish/fleet-theme.css" "a read-only digest wrote the fleet-page stylesheet"
  mkdir -p "$home/.lavish"
  printf 'previous\n' > "$home/.lavish/fleet-theme.css"
  run_theme "$home" digest-line --read-only >/dev/null || fail "digest-line --read-only failed with a stylesheet present"
  [ "$(cat "$home/.lavish/fleet-theme.css")" = previous ] || fail "a read-only digest rewrote the fleet-page stylesheet"
  pass "a read-only digest prints the theme line and leaves the fleet-page stylesheet alone"
}

test_every_shipped_theme_resolves_with_no_remote_reference() {
  local shipped="$ROOT/.agents/skills/bearings/assets/themes" dir name home out count=0
  for dir in "$shipped"/*/; do
    [ -f "$dir/theme.css" ] || continue
    name=$(basename "$dir")
    count=$((count + 1))
    home="$TMP_ROOT/shipped-$name"
    mkdir -p "$home/config"
    printf 'theme=%s\n' "$name" > "$home/config/theme"
    out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE='' "$THEME" css) || fail "shipped theme $name did not resolve"
    printf '%s' "$out" | grep -qi '@import' && fail "shipped theme $name carries an @import"
    printf '%s' "$out" | grep -oi 'url([^)]*' | grep -v '^url("data:font/woff2;base64,' \
      && fail "shipped theme $name references something other than an inlined font"
    if [ -d "$dir/fonts" ]; then
      assert_present "$dir/fonts/LICENSE" "shipped theme $name ships fonts without their license"
    fi
    FM_HOME="$home" FM_CONFIG_OVERRIDE='' "$THEME" selection >/dev/null \
      || fail "shipped theme $name has an invalid selection or voice line"
  done
  [ "$count" -ge 1 ] || fail "no shipped theme was found under $shipped"
  pass "every shipped theme resolves to a stylesheet that fetches nothing remote"
}

test_no_selection_prints_nothing
test_selection_fills_defaults_and_finds_a_shipped_theme
test_a_home_theme_wins_over_a_shipped_theme_of_the_same_name
test_layout_and_mode_apply_without_a_theme
test_a_missing_theme_names_both_folders_searched
test_a_malformed_selection_is_refused
test_a_voice_line_sets_the_reply_and_a_bad_one_is_refused
test_css_inlines_every_local_font_reference
test_unsafe_home_themes_are_refused
test_a_shipped_theme_is_exempt_from_the_markup_check_only
test_symlinked_or_oversized_themes_are_refused
test_no_selection_needs_no_shipped_folder
test_digest_line_is_absent_without_a_named_theme
test_digest_line_names_the_reply_and_writes_the_fleet_stylesheet
test_digest_line_reports_an_unloadable_theme_and_keeps_the_default_reply
test_digest_line_read_only_never_writes_the_stylesheet
test_every_shipped_theme_resolves_with_no_remote_reference
