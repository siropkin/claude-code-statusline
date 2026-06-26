#!/bin/sh
# Claude Code statusline — custom 2-line layout (macOS & Linux)
#
# Output:
#   my-project on main · PR #123 merged
#   Opus 4.6 (high) · ctx ▰▰▰▱▱▱▱▱▱▱ 29% · session $12.50 · cost ▰▰▰▰▰▱▱▱▱▱ $2.5k/$5.0k
#
# How it works:
#   1. Receives JSON blob via stdin from Claude Code (model, context, workspace, cost)
#   2. Parses all fields in a single jq call
#   3. Line 1: project name + git branch + PR status (gh, cached 60s in background)
#   4. Line 2: model/effort + context bar + session cost + account spending bar
#   5. Org spending is fetched via OAuth API at api.anthropic.com/api/oauth/usage.
#      Token source: macOS Keychain or ~/.claude/.credentials.json (Linux).
#      Lock file prevents concurrent fetches. Cached to disk.
#
# Prerequisites:
#   - jq, git, gh CLI, curl
#
# Install:
#   1. cp ~/.claude/settings.json ~/.claude/settings.json.bak
#   2. cp statusline.sh ~/.claude/statusline.sh
#   3. Add to ~/.claude/settings.json:
#      "statusLine": { "type": "command", "command": "sh ~/.claude/statusline.sh", "padding": 0 }
#   4. Restart Claude Code.
#
# Receives JSON via stdin from Claude Code.

input=$(cat)

# ── Parse all JSON fields in one jq call ─────────────────────────────────
eval "$(echo "$input" | jq -r '
  "proj_dir="      + (.workspace.project_dir // .workspace.current_dir // .cwd // "" | @sh) + " " +
  "resolved_dir="  + (.workspace.current_dir // .cwd // "" | @sh) + " " +
  "model="         + (.model.display_name // "" | @sh) + " " +
  "effort="        + (.effort.level // "" | @sh) + " " +
  "ctx_raw="       + (.context_window.remaining_percentage // 100 | tostring | @sh) + " " +
  "session_cost="  + (.cost.total_cost_usd // 0 | tostring | @sh) + " " +
  "repo_url="      + (if .workspace.repo then "https://" + .workspace.repo.host + "/" + .workspace.repo.owner + "/" + .workspace.repo.name else "" end | @sh)
')"

# ── Portability helpers ──────────────────────────────────────────────────
stat_mtime() {
  # Linux: stat -c %Y; macOS/BSD: stat -f %m
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

claude_token() {
  # macOS: Keychain; Linux/fallback: credentials file
  if command -v security >/dev/null 2>&1; then
    security find-generic-password -s "Claude Code-credentials" -a "$USER" -w 2>/dev/null \
      | jq -r '.claudeAiOauth.accessToken // empty'
  else
    jq -r '.claudeAiOauth.accessToken // empty' \
      "${HOME}/.claude/.credentials.json" 2>/dev/null
  fi
}

# ── Colors (One Dark) ───────────────────────────────────────────────────
ESC=$(printf '\033')
RESET="${ESC}[0m"
C_CYAN="${ESC}[38;2;86;182;194m"         # project name
C_GREEN="${ESC}[38;2;152;195;121m"       # branch, open PR, healthy bar
C_PURPLE="${ESC}[38;2;198;120;221m"      # model, merged PR
C_DIM="${ESC}[38;2;92;99;112m"           # separators, labels
C_RED="${ESC}[38;2;224;108;117m"          # closed PR, critical bar
C_AMBER="${ESC}[38;2;229;192;123m"       # warning bar

SEP="${C_DIM} · ${RESET}"

# ── Helpers ──────────────────────────────────────────────────────────────
render_bar() {
  pct=$1; color=$2; width=${3:-10}
  filled=$(( (pct * width + 50) / 100 ))
  [ "$filled" -gt "$width" ] && filled="$width"
  [ "$filled" -lt 0 ] && filled=0
  empty=$(( width - filled ))
  bar=""; i=0
  while [ "$i" -lt "$filled" ]; do bar="${bar}▰"; i=$((i+1)); done
  i=0; ebar=""
  while [ "$i" -lt "$empty" ]; do ebar="${ebar}▱"; i=$((i+1)); done
  printf '%s' "${color}${bar}${C_DIM}${ebar}${RESET}"
}

bar_color() { # invert=1: high % is bad (usage)
  pct=$1; invert=${2:-0}
  if [ "$invert" -eq 1 ]; then
    [ "$pct" -ge 80 ] && printf '%s' "$C_RED" && return
    [ "$pct" -ge 50 ] && printf '%s' "$C_AMBER" && return
    printf '%s' "$C_GREEN"
  else
    [ "$pct" -ge 50 ] && printf '%s' "$C_GREEN" && return
    [ "$pct" -ge 20 ] && printf '%s' "$C_AMBER" && return
    printf '%s' "$C_RED"
  fi
}

# ── LINE 1: project on branch · PR #N state ─────────────────────────────
line1=""

[ -n "$proj_dir" ] && line1="${C_CYAN}$(basename "$proj_dir")${RESET}"

branch=""
[ -n "$resolved_dir" ] && command -v git >/dev/null 2>&1 \
  && branch=$(git -C "$resolved_dir" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)

if [ -n "$branch" ]; then
  disp_branch="$branch"
  [ "${#disp_branch}" -gt 60 ] && disp_branch="$(printf '%.59s' "$disp_branch")…"
  [ -n "$line1" ] \
    && line1="${line1} ${C_DIM}on${RESET} ${C_GREEN}${disp_branch}${RESET}" \
    || line1="${C_GREEN}${disp_branch}${RESET}"
fi

# PR status (background-refreshed, cached 60s)
if [ -n "$branch" ] && [ -n "$resolved_dir" ] && command -v gh >/dev/null 2>&1; then
  pr_cache="${TMPDIR:-/tmp}/claude-sl-pr"
  mkdir -p "$pr_cache" 2>/dev/null
  pr_file="${pr_cache}/$(printf '%s' "$branch" | tr '/ ' '__')"

  now=$(date +%s)
  pr_age=$(stat_mtime "$pr_file")
  if [ ! -f "$pr_file" ] || [ $(( now - pr_age )) -gt 60 ]; then
    ( cd "$resolved_dir" 2>/dev/null \
        && gh pr view --json number,state,isDraft -q '[.number,.state,.isDraft]|@tsv' \
             > "${pr_file}.tmp" 2>/dev/null \
        && [ -s "${pr_file}.tmp" ] \
        && mv "${pr_file}.tmp" "$pr_file" 2>/dev/null \
        || rm -f "${pr_file}.tmp" ) >/dev/null 2>&1 &
  fi

  if [ -f "$pr_file" ] && [ -s "$pr_file" ]; then
    pr_num=$(cut -f1 < "$pr_file")
    pr_state=$(cut -f2 < "$pr_file")
    pr_draft=$(cut -f3 < "$pr_file")
    pr_seg=""
    # OSC 8 hyperlink: \e]8;;URL\e\\LABEL\e]8;;\e\\
    pr_link=""
    [ -n "$repo_url" ] && [ -n "$pr_num" ] \
      && pr_link="${ESC}]8;;${repo_url}/pull/${pr_num}${ESC}\\"
    pr_link_end=""
    [ -n "$pr_link" ] && pr_link_end="${ESC}]8;;${ESC}\\"
    case "$pr_state" in
      OPEN)  [ "$pr_draft" = "true" ] \
               && pr_seg="${C_DIM}${pr_link}PR #${pr_num} draft${pr_link_end}${RESET}" \
               || pr_seg="${C_GREEN}${pr_link}PR #${pr_num}${pr_link_end}${RESET}" ;;
      MERGED) pr_seg="${C_PURPLE}${pr_link}PR #${pr_num} merged${pr_link_end}${RESET}" ;;
      CLOSED) pr_seg="${C_RED}${pr_link}PR #${pr_num} closed${pr_link_end}${RESET}" ;;
    esac
    [ -n "$pr_seg" ] && line1="${line1}${SEP}${pr_seg}"
  fi
fi

# ── LINE 2: model (effort) · ctx bar · use bar ──────────────────────────
line2=""
append2() { [ -n "$line2" ] && line2="${line2}${SEP}$1" || line2="$1"; }

if [ -n "$model" ]; then
  seg="${C_PURPLE}${model}${RESET}"
  [ -n "$effort" ] && seg="${seg} ${C_DIM}(${effort})${RESET}"
  append2 "$seg"
fi

ctx_remaining=$(printf '%.0f' "$ctx_raw" 2>/dev/null)
if [ "$ctx_remaining" -ge 0 ] 2>/dev/null; then
  ctx_used=$(( 100 - ctx_remaining ))
  cc=$(bar_color "$ctx_used" 1)
  append2 "${C_DIM}ctx${RESET} $(render_bar "$ctx_used" "$cc") ${cc}${ctx_used}%${RESET}"
fi

if [ -n "$session_cost" ]; then
  sc_fmt=$(awk "BEGIN{v=${session_cost}+0; if(v>=1000) printf \"%.1fk\",v/1000; else printf \"%.2f\",v}")
  append2 "${C_DIM}session${RESET} ${C_AMBER}\$${sc_fmt}${RESET}"
fi

# Org usage — fetched via OAuth usage API (background, lock-guarded)
usage_dir="${TMPDIR:-/tmp}/claude-sl-usage"
usage_cache="${usage_dir}/data"
usage_lock="${usage_dir}/lock"
mkdir -p "$usage_dir" 2>/dev/null

# Only spawn if lock is absent or stale (>60s = timed out)
lock_age=999
[ -f "$usage_lock" ] && lock_age=$(( $(date +%s) - $(stat_mtime "$usage_lock") ))

if [ "$lock_age" -gt 60 ]; then
  touch "$usage_lock" 2>/dev/null
  ( token=$(claude_token)
    [ -z "$token" ] && rm -f "$usage_lock" && exit 0
    json=$(curl -s --max-time 10 "https://api.anthropic.com/api/oauth/usage" \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "Content-Type: application/json" 2>/dev/null)
    # Try extra_usage first, fall back to spend object
    result=$(printf '%s' "$json" | jq -r '
      if .extra_usage.used_credits then
        [.extra_usage.used_credits, .extra_usage.monthly_limit, .extra_usage.utilization] | @tsv
      elif .spend.used.amount_minor then
        [.spend.used.amount_minor, .spend.limit.amount_minor, .spend.percent] | @tsv
      else empty end' 2>/dev/null)
    if [ -n "$result" ] && printf '%s' "$result" | grep -q '	'; then
      printf '%s' "$result" > "${usage_cache}.tmp" && mv "${usage_cache}.tmp" "$usage_cache"
    fi
    rm -f "$usage_lock"
  ) >/dev/null 2>&1 &
fi

if [ -f "$usage_cache" ] && [ -s "$usage_cache" ]; then
  used_cents=$(cut -f1 < "$usage_cache")
  limit_cents=$(cut -f2 < "$usage_cache")
  util_raw=$(cut -f3 < "$usage_cache")
  util_int=$(printf '%.0f' "$util_raw" 2>/dev/null)
  if [ "$util_int" -gt 0 ] 2>/dev/null; then
    fmt_dollars() { awk "BEGIN{v=$1/100; if(v>=1000) printf \"%.1fk\",v/1000; else printf \"%.0f\",v}"; }
    used_fmt=$(fmt_dollars "$used_cents")
    limit_fmt=$(fmt_dollars "$limit_cents")
    uc=$(bar_color "$util_int" 1)
    append2 "${C_DIM}cost${RESET} $(render_bar "$util_int" "$uc") ${uc}\$${used_fmt}${C_DIM}/${RESET}${uc}\$${limit_fmt}${RESET}"
  else
    append2 "${C_DIM}cost${RESET} $(render_bar 0 "$C_DIM") ${C_DIM}-${C_DIM}/${C_DIM}-${RESET}"
  fi
else
  append2 "${C_DIM}cost${RESET} $(render_bar 0 "$C_DIM") ${C_DIM}-${C_DIM}/${C_DIM}-${RESET}"
fi

# ── Output ───────────────────────────────────────────────────────────────
out=""
for seg in "$line1" "$line2"; do
  [ -n "$seg" ] && { [ -n "$out" ] && out="${out}
${seg}" || out="$seg"; }
done
printf '%s' "$out"
