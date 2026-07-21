#!/bin/bash
# Claude Code statusline: 5-hour session usage, 7-day weekly usage,
# and context window usage (Pro/Max subscription rate limits).
# Progress bars stretch to fill the available terminal width.

input=$(cat)

# --- Determine terminal width ---
# Claude Code's statusline JSON input does not include a terminal-width
# field (checked the documented schema), so fall back to $COLUMNS (if the
# environment provides it and non-zero), then `tput cols`, then a sane
# default of 80.
term_width="${COLUMNS:-}"
if [ -z "$term_width" ] || [ "$term_width" = "0" ]; then
  term_width=$(tput cols 2>/dev/null)
fi
if [ -z "$term_width" ] || ! [[ "$term_width" =~ ^[0-9]+$ ]] || [ "$term_width" = "0" ]; then
  term_width=80
fi

# When the panel gets tight, switch to a condensed layout: the reset column
# drops the absolute time and shows only the countdown (e.g. "37 min"), and
# the token figure collapses to the compact form ("163k / 1M", no "Tokens"
# word). This reclaims room for the bar on narrow windows. Tunable.
narrow_threshold=80
narrow=0
[ "$term_width" -lt "$narrow_threshold" ] && narrow=1

# Format a 0-100 value as "NN%", or "n/a" if empty.
format_pct() {
  local pct="$1"
  if [ -n "$pct" ]; then
    printf "%s%%" "$(printf "%.0f" "$pct")"
  else
    printf "n/a"
  fi
}

# Format a raw token count compactly: "734", "67k", "1M", "1.5M". Rounds to
# the nearest thousand once above 1k. Empty/non-numeric in → empty out.
format_tokens() {
  local n="$1"
  [[ "$n" =~ ^[0-9]+$ ]] || return
  if [ "$n" -ge 1000000 ]; then
    local whole=$(( n / 1000000 ))
    local frac=$(( (n % 1000000) / 100000 ))   # tenths of a million
    if [ "$frac" -eq 0 ]; then
      printf "%dM" "$whole"
    else
      printf "%d.%dM" "$whole" "$frac"
    fi
  elif [ "$n" -ge 1000 ]; then
    printf "%dk" "$(( (n + 500) / 1000 ))"
  else
    printf "%d" "$n"
  fi
}

# Format a raw token count with thousands separators, e.g. "999,999". Used
# for the live "tokens used" figure so it's readable as it ticks up.
# Empty/non-numeric in → empty out.
format_tokens_comma() {
  local n="$1"
  [[ "$n" =~ ^[0-9]+$ ]] || return
  local out=""
  while [ ${#n} -gt 3 ]; do
    out=",${n: -3}${out}"
    n=${n:0:${#n}-3}
  done
  printf "%s%s" "$n" "$out"
}

# Format the seconds remaining until an epoch as a compact countdown, e.g.
# "20 mins", "2h 05m", or "4d 05h" for spans of a day or more (the weekly
# reset can be up to 7 days out, where "101h 33m" stops being readable).
# Prints nothing if epoch is absent/unparseable or already in the past.
format_countdown() {
  local epoch="$1"
  [ -z "$epoch" ] && return

  local now remaining
  now=$(date "+%s")
  remaining=$(( epoch - now ))
  [ "$remaining" -le 0 ] && return

  local days hours mins
  days=$(( remaining / 86400 ))
  hours=$(( (remaining % 86400) / 3600 ))
  mins=$(( (remaining % 3600) / 60 ))

  if [ "$days" -gt 0 ]; then
    printf "%dd %02dh" "$days" "$hours"
  elif [ "$hours" -gt 0 ]; then
    printf "%dh %02dm" "$hours" "$mins"
  elif [ "$mins" -gt 0 ]; then
    printf "%d min" "$mins"
  else
    printf "<1 min"
  fi
}

# Parse a resets_at value into separate fields — RP_WEEKDAY, RP_TIME (e.g.
# "10:28", no am/pm), RP_AMPM ("am"/"pm"), RP_COUNTDOWN — instead of one
# formatted string. Kept separate so callers can pad each field to a common
# width and get the am/pm across rows to line up, which isn't possible once
# everything is flattened into a single string of varying length (a leading
# weekday, and single- vs double-digit hours, shift where am/pm would land).
# Claude Code passes resets_at as a Unix epoch (seconds), though we also
# accept an ISO 8601 string defensively. RP_WEEKDAY is left empty for a
# same-day reset (e.g. "1:31pm") and set for a later day (e.g. "Wed 2:17pm").
# All fields are left empty if resets_at is absent or unparseable.
format_reset_parts() {
  RP_WEEKDAY=""
  RP_TIME=""
  RP_AMPM=""
  RP_COUNTDOWN=""

  local val="$1"
  [ -z "$val" ] && return

  local epoch
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    # Already a Unix epoch (seconds).
    epoch="$val"
  else
    # Fall back to parsing an ISO 8601 string.
    local clean="${val%%.*}"
    clean="${clean%Z}"
    epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$clean" "+%s" 2>/dev/null)
    if [ -z "$epoch" ]; then
      epoch=$(date -d "$val" "+%s" 2>/dev/null)
    fi
  fi
  [ -z "$epoch" ] && return

  # Compare calendar days in local time to decide whether to show "Hoy" or
  # the weekday abbreviation.
  local reset_day today
  reset_day=$(date -r "$epoch" "+%Y-%m-%d" 2>/dev/null || date -d "@$epoch" "+%Y-%m-%d" 2>/dev/null)
  today=$(date "+%Y-%m-%d")
  if [ "$reset_day" = "$today" ]; then
    RP_WEEKDAY="Hoy"
  else
    RP_WEEKDAY=$(date -r "$epoch" "+%a" 2>/dev/null || date -d "@$epoch" "+%a" 2>/dev/null)
  fi

  # %I gives a zero-padded 12-hour clock (e.g. "03:12"); %p is AM/PM which we
  # lowercase for compactness.
  RP_TIME=$(date -r "$epoch" "+%I:%M" 2>/dev/null || date -d "@$epoch" "+%I:%M" 2>/dev/null)
  local ap
  ap=$(date -r "$epoch" "+%p" 2>/dev/null || date -d "@$epoch" "+%p" 2>/dev/null)
  RP_AMPM=$(printf "%s" "$ap" | tr 'A-Z' 'a-z')

  RP_COUNTDOWN=$(format_countdown "$epoch")
}

# --- Gather raw values ---
five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
context_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

five_hour_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

context_tokens_used=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
context_tokens_total=$(echo "$input" | jq -r '.context_window.context_window_size // empty')

session_pct_str=$(format_pct "$five_hour_pct")
weekly_pct_str=$(format_pct "$seven_day_pct")
context_pct_str=$(format_pct "$context_pct")

# The context window has no reset; show the raw token budget behind its
# percentage instead, e.g. "67k / 1M". Left blank if the token fields are
# absent.
context_tokens_str=""
if [ -n "$context_tokens_used" ] && [ -n "$context_tokens_total" ]; then
  if [ "$narrow" -eq 1 ]; then
    # Just the compact used count, no total or "Tokens" word: "163k".
    context_tokens_str="$(format_tokens "$context_tokens_used")"
  else
    # Full used count with commas so it's readable as it ticks up.
    context_tokens_str="$(format_tokens_comma "$context_tokens_used") / $(format_tokens "$context_tokens_total") Tokens"
  fi
fi

format_reset_parts "$five_hour_reset"
session_weekday="$RP_WEEKDAY"; session_time="$RP_TIME"; session_ampm="$RP_AMPM"; session_countdown="$RP_COUNTDOWN"

format_reset_parts "$seven_day_reset"
weekly_weekday="$RP_WEEKDAY"; weekly_time="$RP_TIME"; weekly_ampm="$RP_AMPM"; weekly_countdown="$RP_COUNTDOWN"

# Pad weekday and time to the widest value seen across both rows, so the
# am/pm that immediately follows lands in the same column on every row
# regardless of whether a weekday prefix is present or the hour is one vs.
# two digits. The trailing "(countdown)" is appended after and left ragged —
# only am/pm alignment is worth the fixed-width treatment.
weekday_w=0
[ ${#session_weekday} -gt $weekday_w ] && weekday_w=${#session_weekday}
[ ${#weekly_weekday} -gt $weekday_w ] && weekday_w=${#weekly_weekday}

time_w=0
[ ${#session_time} -gt $time_w ] && time_w=${#session_time}
[ ${#weekly_time} -gt $time_w ] && time_w=${#weekly_time}

build_reset_str() {
  local weekday="$1" time="$2" ampm="$3" countdown="$4"
  [ -z "$time" ] && return
  local out
  out=$(printf "%-*s %*s%s" "$weekday_w" "$weekday" "$time_w" "$time" "$ampm")
  [ -n "$countdown" ] && out="$out ($countdown)"
  printf "%s" "$out"
}

# In narrow mode show only the time remaining (the countdown); otherwise show
# the absolute reset time with the countdown in parentheses. Fall back to the
# absolute time if a countdown isn't available (e.g. resets_at absent).
if [ "$narrow" -eq 1 ]; then
  session_reset_str="$session_countdown"
  weekly_reset_str="$weekly_countdown"
  [ -z "$session_reset_str" ] && session_reset_str=$(build_reset_str "$session_weekday" "$session_time" "$session_ampm" "")
  [ -z "$weekly_reset_str" ] && weekly_reset_str=$(build_reset_str "$weekly_weekday" "$weekly_time" "$weekly_ampm" "")
else
  session_reset_str=$(build_reset_str "$session_weekday" "$session_time" "$session_ampm" "$session_countdown")
  weekly_reset_str=$(build_reset_str "$weekly_weekday" "$weekly_time" "$weekly_ampm" "$weekly_countdown")
fi

# --- Colors (truecolor) and bar glyphs ---
C_LABEL=$'\033[38;2;198;220;198m'   # pale green-white labels
C_FILL=$'\033[38;2;104;231;114m'    # bright green filled portion
C_EMPTY=$'\033[38;2;46;92;50m'      # dim green empty (checker) portion
C_BRACKET=$'\033[38;2;140;168;140m' # muted brackets
C_PCT=$'\033[1;38;2;120;240;130m'   # bright green, bold percentage
C_TIME=$'\033[38;2;178;204;178m'    # pale green reset time
C_OFF=$'\033[0m'
# Dark shade for the fill: a full-cell 75% stipple. Like the medium-shade
# empty glyph it fills the whole cell but its dither leaves gaps at the top
# and bottom edges, so stacked filled bars don't bleed together vertically
# the way a solid full block █ would.
GLYPH_FILL=$'▓'                 # ▓ dark shade (75%)
GLYPH_EMPTY=$'▒'                # ▒ medium shade (50%)

# --- Column widths for the stacked, one-metric-per-row layout ---
label_w=16              # fits "CURRENT SESSION:"
pct_w=4                 # right-aligned, fits "100%"

# reset_col_w: widest fully-built reset string (weekday+time+ampm+countdown),
# used only to size the bar so the longer of the two rows doesn't overflow
# the terminal. Unlike time_w above, it does NOT get used to pad the printed
# strings — that would reintroduce the am/pm misalignment build_reset_str
# just fixed, since the two rows' countdown text differs in length.
reset_col_w=0
[ ${#session_reset_str} -gt $reset_col_w ] && reset_col_w=${#session_reset_str}
[ ${#weekly_reset_str} -gt $reset_col_w ] && reset_col_w=${#weekly_reset_str}
[ ${#context_tokens_str} -gt $reset_col_w ] && reset_col_w=${#context_tokens_str}

# Right-justify the token string within the reset column so it hugs the right
# edge (the reset column is the rightmost element on every row). The reset
# strings stay left-aligned — only the context tokens get this treatment.
if [ -n "$context_tokens_str" ]; then
  context_tokens_str=$(printf "%*s" "$reset_col_w" "$context_tokens_str")
fi

# Per-row fixed overhead (matches what print_row actually emits): label +
# " [" + "] " + percentage + "  " + reset column. The bar fills the rest.
row_overhead=$(( label_w + 2 + 2 + pct_w + 2 + reset_col_w ))

# The statusline panel doesn't render across the full terminal width — it
# reserves a handful of columns for its own padding/border. Empirically the
# usable area is roughly COLUMNS minus ~4, so reserve a margin a touch larger
# than that to avoid Claude Code truncating the line ends with "…".
safety_margin=4
bar_width=$(( term_width - row_overhead - safety_margin ))
[ "$bar_width" -lt 8 ] && bar_width=8

# Renders a colored progress bar of the given width for a 0-100 value:
# bright-green filled glyphs followed by dim checker glyphs. An empty or
# absent value renders as an all-checker bar.
render_bar() {
  local pct="$1"
  local width="$2"
  local filled=0

  if [ -n "$pct" ]; then
    local int
    int=$(printf "%.0f" "$pct")
    [ "$int" -gt 100 ] && int=100
    [ "$int" -lt 0 ] && int=0
    filled=$(( int * width / 100 ))
  fi
  [ "$filled" -gt "$width" ] && filled="$width"

  local empty=$(( width - filled ))
  local fbar="" ebar="" i=0
  while [ "$i" -lt "$filled" ]; do fbar="${fbar}${GLYPH_FILL}"; i=$((i + 1)); done
  i=0
  while [ "$i" -lt "$empty" ]; do ebar="${ebar}${GLYPH_EMPTY}"; i=$((i + 1)); done

  printf "%s%s%s%s" "$C_FILL" "$fbar" "$C_EMPTY" "$ebar"
}

# Renders one stacked row: LABEL [bar] pct  reset-time
print_row() {
  local label="$1" pctval="$2" pct_str="$3" time_str="$4"
  local bar
  bar=$(render_bar "$pctval" "$bar_width")

  # Pale label (left-justified), bracketed colored bar, bright percentage.
  printf "%s%-*s%s %s[%s%s]%s %s%*s%s" \
    "$C_LABEL" "$label_w" "$label" "$C_OFF" \
    "$C_BRACKET" "$bar" "$C_BRACKET" "$C_OFF" \
    "$C_PCT" "$pct_w" "$pct_str" "$C_OFF"

  # Reset time, left-aligned (am/pm alignment across rows is already baked
  # into time_str by build_reset_str; the trailing countdown is left ragged).
  if [ -n "$time_str" ]; then
    printf "  %s%s%s" "$C_TIME" "$time_str" "$C_OFF"
  fi
}

print_row "CURRENT SESSION:" "$five_hour_pct" "$session_pct_str" "$session_reset_str"
printf "\n"
print_row "WEEKLY SESSION:"  "$seven_day_pct" "$weekly_pct_str"  "$weekly_reset_str"
printf "\n"
print_row "CONTEXT WINDOW:"  "$context_pct"   "$context_pct_str" "$context_tokens_str"
