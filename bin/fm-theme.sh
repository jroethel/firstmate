#!/usr/bin/env bash
# fm-theme.sh - resolve this home's board theme selection into a self-contained stylesheet.
#
# Usage:
#   fm-theme.sh selection
#   fm-theme.sh css
#   fm-theme.sh digest-line [--read-only]
#   fm-theme.sh -h | --help | help
#
# selection    Print the resolved selection, or nothing (exit 0) when CONFIG/theme is absent.
# css          Print the resolved, self-contained stylesheet on stdout.
# digest-line  Print the session digest's theme line, always exit 0; see DIGEST LINE below.
#
# This header is the single owner of the selection format, defaults, lookup
# order, folder format, refusal rule, size cap, and inlining form.
#
# Environment:
#   FM_HOME                 The home; defaults to FM_ROOT_OVERRIDE, else the repo root.
#   FM_CONFIG_OVERRIDE      The config directory; unset or empty means $FM_HOME/config (CONFIG below).
#   FM_THEME_SHIPPED_DIR    Tests only; the shipped themes folder.
#                           Unset or empty means .agents/skills/bearings/assets/themes in this repo.
#                           It never derives from FM_ROOT_OVERRIDE and is not required until a lookup needs it.
#
# SELECTION FILE. CONFIG/theme is a text file of key=value lines.
# Blank lines and lines starting with # are ignored.
# Keys: theme (a name matching ^[a-z0-9][a-z0-9-]{0,39}$), layout (full or compact), mode (light, dark, or auto).
# An unknown key, a bad value, a line without =, or a repeated key is refused with
# `fm-theme: <CONFIG>/theme line <n>: <problem>` on stderr and exit 1.
#
# selection output. Exactly these six lines in this order, with defaults layout=compact, mode=auto,
# and reply=Captain, shipshape.:
#   theme=<name, or empty when no theme is named>
#   layout=<full|compact>
#   mode=<light|dark|auto>
#   origin=<home|shipped|none>
#   dir=<absolute theme folder, or empty>
#   reply=<no-op reply>
#
# LOOKUP. CONFIG/themes/<name>/theme.css first (origin home), then <shipped>/<name>/theme.css (origin shipped).
# When neither exists the script exits 1 with
# `fm-theme: theme "<name>" was not found in <CONFIG>/themes or <shipped>`.
#
# THEME FOLDER. <root>/<name>/ holds theme.css (required), optional fonts/*.woff2 plus fonts/LICENSE,
# and an optional noop-reply holding exactly one line matching ^Captain, [A-Za-z0-9 ,.!?'()-]{1,111}$,
# so at most 120 characters and never a ;, a backtick, a control character, or any other character a digest line
# or a chat reply could misread.
# Anything else is refused with `fm-theme: <dir>/noop-reply must hold one line starting "Captain, " in letters,
# digits, spaces, and , . ! ? ' ( ) -`.
#
# REFUSAL RULE for css. It is applied to the raw bytes of theme.css with no CSS parsing,
# so comments are not exempt, and every token match is ASCII case-insensitive.
# A refusal is `fm-theme: theme "<name>" (<path to theme.css>) refused: <reason>` on stderr and exit 1.
# With no theme named, css exits 1 with `fm-theme: no theme is selected in <CONFIG>/theme`.
#   Markup rule (home themes only): any < character is refused.
#     This covers </style, <!--, and <script, and also media-query range syntax such as (width < 600px),
#     which a home theme writes as max-width instead.
#   Escape rule (every theme): any backslash is refused, because a CSS escape can spell a refused token.
#     A theme writes the literal UTF-8 character instead of an escape.
#   Fetch rule (every theme): any @import, image-set( (which also covers -webkit-image-set( ), image(, or src( is refused.
#   Location rule (every theme): the theme folder, its theme.css, and its fonts folder must not be symlinks,
#     and theme.css must be a regular file.
#   Size rule (every theme): theme.css plus every font file it references must total at most 524288 bytes
#     (512 KiB) before encoding, each distinct font file counted once however often it is referenced.
#   Font rule (every theme): every url( must match
#     url\(\s*(["']?)fonts/([A-Za-z0-9][A-Za-z0-9._-]*\.woff2)\1\s*\) (perl, case-insensitive),
#     and fonts/<file> must be a regular file that is not a symlink inside that theme folder.
#     Any other url(, including data: and remote addresses, is refused.
#
# INLINING. Every allowed font reference, whatever its case, quoting, and inner spacing, becomes exactly
# url("data:font/woff2;base64,<unwrapped base64 of the file>").
#
# DIGEST LINE. digest-line is what bin/fm-session-start.sh prints as its THEME section.
# With no CONFIG/theme, or no theme named, it prints nothing and writes nothing.
# With a loadable theme it writes the css output to $FM_HOME/.lavish/fleet-theme.css
# (directory mode 0700, file mode 0600, written to a temp file in that directory and renamed into place)
# and prints exactly `THEME: <name>; no-op reply: <reply>; fleet-page stylesheet: <FM_HOME>/.lavish/fleet-theme.css`.
# With a theme that cannot be loaded, or a stylesheet that cannot be written, it writes nothing and prints exactly
# `THEME: <name> could not be loaded (<first line of the error>); the no-op reply stays Captain, shipshape.`.
# A selection file that cannot be read at all is reported under the name config/theme when it names no theme.
# With --read-only it prints the same line but never creates, rewrites, or removes the stylesheet.
# A Firstmate-authored fleet page adopts the theme by inlining or linking that stylesheet;
# docs/configuration.md owns what such a page must do to adopt it.
set -eu
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'fm-theme: %s\n' "$*" >&2
  exit 1
}

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$REPO_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
case "$CONFIG" in /*) ;; *) CONFIG="$PWD/$CONFIG" ;; esac
SHIPPED="${FM_THEME_SHIPPED_DIR:-$REPO_ROOT/.agents/skills/bearings/assets/themes}"
case "$SHIPPED" in /*) ;; *) SHIPPED="$PWD/$SHIPPED" ;; esac

THEME_NAME=''
LAYOUT=compact
MODE=auto
ORIGIN=none
DIR=''
REPLY='Captain, shipshape.'

parse_selection() {
  local file="$CONFIG/theme" n=0 line key val seen_theme='' seen_layout='' seen_mode=''
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in *=*) ;; *) die "$file line $n: expected key=value" ;; esac
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
      theme)
        [ -z "$seen_theme" ] || die "$file line $n: repeated key theme"
        seen_theme=1
        [[ $val =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || die "$file line $n: bad theme name \"$val\""
        THEME_NAME=$val
        ;;
      layout)
        [ -z "$seen_layout" ] || die "$file line $n: repeated key layout"
        seen_layout=1
        case "$val" in full | compact) LAYOUT=$val ;; *) die "$file line $n: layout must be full or compact" ;; esac
        ;;
      mode)
        [ -z "$seen_mode" ] || die "$file line $n: repeated key mode"
        seen_mode=1
        case "$val" in light | dark | auto) MODE=$val ;; *) die "$file line $n: mode must be light, dark, or auto" ;; esac
        ;;
      *) die "$file line $n: unknown key \"$key\"" ;;
    esac
  done < "$file"
}

lookup_theme() {
  if [ -f "$CONFIG/themes/$THEME_NAME/theme.css" ]; then
    ORIGIN=home
    DIR="$CONFIG/themes/$THEME_NAME"
  elif [ -f "$SHIPPED/$THEME_NAME/theme.css" ]; then
    ORIGIN=shipped
    DIR="$SHIPPED/$THEME_NAME"
  else
    die "theme \"$THEME_NAME\" was not found in $CONFIG/themes or $SHIPPED"
  fi
}

read_voice() {
  local f="$DIR/noop-reply" line
  if [ -e "$f" ] || [ -L "$f" ]; then
    line=$(cat "$f" 2>/dev/null) || line=''
    if [ ! -f "$f" ] || [ "$(awk 'END { print NR }' "$f")" != 1 ] \
      || ! printf '%s\n' "$line" | grep -Eq "^Captain, [A-Za-z0-9 ,.!?'()-]{1,111}\$"; then
      die "$f must hold one line starting \"Captain, \" in letters, digits, spaces, and , . ! ? ' ( ) -"
    fi
    REPLY=$line
  fi
}

resolve() {
  parse_selection
  [ -z "$THEME_NAME" ] || { lookup_theme; read_voice; }
}

# perl does the byte-level refusal checks and the font inlining in one pass,
# printing the stylesheet only when every rule holds.
read -r -d '' PERL_CSS <<'PERL' || true
use strict;
use warnings;
use MIME::Base64 qw(encode_base64);
my ($mode, $name, $css, $dir) = @ARGV;
sub refuse { print STDERR qq{fm-theme: theme "$name" ($css) refused: $_[0]\n}; exit 1 }
open my $fh, '<:raw', $css or refuse('theme.css cannot be read');
my $s = do { local $/; <$fh> };
close $fh;
refuse('markup character "<" is not allowed in a home theme') if $mode eq 'home' && index($s, '<') >= 0;
refuse('a backslash is not allowed') if index($s, '\\') >= 0;
refuse("$1 is not allowed") if $s =~ /(\@import|image-set\(|image\(|src\()/i;
my $re = qr/url\(\s*(["']?)fonts\/([A-Za-z0-9][A-Za-z0-9._-]*\.woff2)\1\s*\)/i;
my ($all, $ok) = (0, 0);
$all++ while $s =~ /url\(/gi;
$ok++ while $s =~ /$re/g;
refuse('url( may only reference a local fonts/<file>.woff2') if $all != $ok;
my $total = -s $css;
my (%seen, %enc);
refuse('the fonts folder must not be a symlink') if -l "$dir/fonts";
$s =~ s{$re}{
  my $file = $2;
  my $f = "$dir/fonts/$file";
  refuse("fonts/$file is not a regular file in the theme folder") if -l $f || !-f $f;
  if (!$seen{$file}++) {
    $total += -s $f;
    open my $ff, '<:raw', $f or refuse("fonts/$file cannot be read");
    $enc{$file} = encode_base64(do { local $/; <$ff> }, '');
    close $ff;
  }
  qq{url("data:font/woff2;base64,$enc{$file}")}
}gie;
refuse("theme.css plus its fonts total $total bytes, over the 524288 byte cap") if $total > 524288;
print $s;
PERL

emit_css() {
  local file="$CONFIG/theme" css mode
  if [ -f "$file" ]; then resolve; fi
  [ -n "$THEME_NAME" ] || die "no theme is selected in $file"
  css="$DIR/theme.css"
  if [ -L "$DIR" ] || [ -L "$css" ] || [ ! -f "$css" ]; then
    die "theme \"$THEME_NAME\" ($css) refused: the theme folder and theme.css must be real, not symlinks"
  fi
  mode=$ORIGIN
  perl -e "$PERL_CSS" "$mode" "$THEME_NAME" "$css" "$DIR"
}

digest_line() {
  local ro="${1:-}" sel name='' reply out dir sheet tmp
  [ -f "$CONFIG/theme" ] || return 0
  name=$(sed -n 's/^theme=//p' "$CONFIG/theme" | head -n 1)
  if ! sel=$("$0" selection 2>&1); then
    printf 'THEME: %s could not be loaded (%s); the no-op reply stays Captain, shipshape.\n' \
      "${name:-config/theme}" "$(printf '%s\n' "$sel" | head -n 1)"
    return 0
  fi
  name=$(printf '%s\n' "$sel" | sed -n 's/^theme=//p')
  [ -n "$name" ] || return 0
  reply=$(printf '%s\n' "$sel" | sed -n 's/^reply=//p')
  dir="$FM_HOME/.lavish"
  sheet="$dir/fleet-theme.css"
  if ! out=$("$0" css 2>&1); then
    printf 'THEME: %s could not be loaded (%s); the no-op reply stays Captain, shipshape.\n' \
      "$name" "$(printf '%s\n' "$out" | head -n 1)"
    return 0
  fi
  if [ "$ro" != --read-only ]; then
    if ! { (umask 077; mkdir -p "$dir") && chmod 700 "$dir" \
      && tmp=$(mktemp "$dir/.fleet-theme.XXXXXX") && chmod 600 "$tmp" \
      && printf '%s\n' "$out" > "$tmp" && mv -f "$tmp" "$sheet"; } 2>/dev/null; then
      [ -z "${tmp:-}" ] || rm -f "$tmp"
      printf 'THEME: %s could not be loaded (the fleet-page stylesheet cannot be written to %s); the no-op reply stays Captain, shipshape.\n' \
        "$name" "$sheet"
      return 0
    fi
  fi
  printf 'THEME: %s; no-op reply: %s; fleet-page stylesheet: %s\n' "$name" "$reply" "$sheet"
}

case "${1:-}" in
  selection)
    [ -f "$CONFIG/theme" ] || exit 0
    resolve
    printf 'theme=%s\nlayout=%s\nmode=%s\norigin=%s\ndir=%s\nreply=%s\n' \
      "$THEME_NAME" "$LAYOUT" "$MODE" "$ORIGIN" "$DIR" "$REPLY"
    ;;
  css) emit_css ;;
  digest-line) shift; digest_line "${1:-}" ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 2 ;;
esac
