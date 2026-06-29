#!/bin/sh
# Claude Code statusline — custom 2-line layout (macOS & Linux)
#
# Output:
#   my-project on main · PR #123 (merged)
#   Opus 4.6 (high) · ctx ▰▰▰▱▱▱▱▱▱▱ 29% · session $12.50 · cost ▰▰▰▰▰▱▱▱▱▱ $2.5k/$5.0k
#
# How it works:
#   1. Receives JSON blob via stdin from Claude Code (model, context, workspace, cost)
#   2. Parses all fields in a single jq call
#   3. Line 1: project name + git branch + PR status (gh, cached 60s in background)
#   4. Line 2: model/effort + context bar + session cost + account spending bar
#   5. Org spending is fetched via Anthropic usage API (cached 5m, backoff on errors).
#      Token source: macOS Keychain or ~/.claude/.credentials.json (Linux).
#      Atomic mkdir lock prevents concurrent fetches.
#   6. Security: per-user tmp paths, token passed via stdin (not in ps), input validation.
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

# ── Configuration ───────────────────────────────────────────────────────
PR_POLL_INTERVAL=60                      # seconds between PR status refreshes
BRANCH_MAX_LEN=60                        # truncate branch names beyond this

USAGE_POLL_INTERVAL=300                    # seconds between usage API refreshes
USAGE_RETRY_INTERVAL=30                    # seconds between retries when no data
USAGE_API_TIMEOUT=10                           # curl max-time for usage API
USAGE_API_URL="https://api.anthropic.com/api/oauth/usage"
USAGE_API_BETA="oauth-2025-04-20"              # anthropic-beta header value

BAR_WIDTH=10                             # character width of progress bars
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
stat_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

file_age() {
  [ -e "$1" ] && echo $(( $(date +%s) - $(stat_mtime "$1") )) || echo 999
}

is_numeric() {
  case "$1" in ''|*[!0-9.]*) return 1 ;; esac
}

fmt_dollars() {
  awk -v v="$1" 'BEGIN{v=v/100; if(v>=1000) printf "%.1fk",v/1000; else printf "%.0f",v}'
}

secure_dir() { mkdir -p -m 700 "$1" 2>/dev/null; }

claude_token() {
  if command -v security >/dev/null 2>&1; then
    security find-generic-password -s "Claude Code-credentials" -a "$USER" -w 2>/dev/null \
      | jq -r '.claudeAiOauth.accessToken // empty'
  else
    jq -r '.claudeAiOauth.accessToken // empty' \
      "${HOME}/.claude/.credentials.json" 2>/dev/null
  fi
}

render_bar() {
  pct=$1; color=$2; width=${3:-$BAR_WIDTH}
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

bar_color() {
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

# ── Parse input ──────────────────────────────────────────────────────────
input=$(cat)
eval "$(echo "$input" | jq -r '
  "proj_dir="      + (.workspace.project_dir // .workspace.current_dir // .cwd // "" | @sh) + " " +
  "resolved_dir="  + (.workspace.current_dir // .cwd // "" | @sh) + " " +
  "model="         + (.model.display_name // "" | @sh) + " " +
  "effort="        + (.effort.level // "" | @sh) + " " +
  "ctx_raw="       + (.context_window.remaining_percentage // 100 | tostring | @sh) + " " +
  "session_cost="  + (.cost.total_cost_usd // 0 | tostring | @sh) + " " +
  "repo_url="      + (if .workspace.repo then "https://" + .workspace.repo.host + "/" + .workspace.repo.owner + "/" + .workspace.repo.name else "" end | @sh)
')"

# ── LINE 1: project on branch · PR #N state ─────────────────────────────
line1=""

[ -n "$proj_dir" ] && line1="${C_CYAN}$(basename "$proj_dir")${RESET}"

branch=""
[ -n "$resolved_dir" ] && command -v git >/dev/null 2>&1 \
  && branch=$(git -C "$resolved_dir" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)

if [ -n "$branch" ]; then
  disp_branch="$branch"
  [ "${#disp_branch}" -gt "$BRANCH_MAX_LEN" ] && disp_branch="$(printf "%.$(( BRANCH_MAX_LEN - 1 ))s" "$disp_branch")…"
  [ -n "$line1" ] \
    && line1="${line1} ${C_DIM}on${RESET} ${C_GREEN}${disp_branch}${RESET}" \
    || line1="${C_GREEN}${disp_branch}${RESET}"
fi

# PR status (background-refreshed, cached 60s)
if [ -n "$branch" ] && [ -n "$resolved_dir" ] && command -v gh >/dev/null 2>&1; then
  pr_cache="${TMPDIR:-/tmp}/claude-sl-pr-$(id -u)"
  secure_dir "$pr_cache"
  pr_file="${pr_cache}/$(printf '%s' "$branch" | tr '/ ' '__')"

  if [ ! -f "$pr_file" ] || [ "$(file_age "$pr_file")" -gt "$PR_POLL_INTERVAL" ]; then
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
    pr_id="${ESC}[4m${pr_link}#${pr_num}${pr_link_end}${ESC}[24m"
    case "$pr_state" in
      OPEN)  [ "$pr_draft" = "true" ] \
               && pr_seg="${C_DIM}PR ${pr_id} (draft)${RESET}" \
               || pr_seg="${C_GREEN}PR ${pr_id} (open)${RESET}" ;;
      MERGED) pr_seg="${C_PURPLE}PR ${pr_id} (merged)${RESET}" ;;
      CLOSED) pr_seg="${C_RED}PR ${pr_id} (closed)${RESET}" ;;
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
  sc_fmt=$(awk -v v="$session_cost" 'BEGIN{v=v+0; if(v>=1000) printf "%.1fk",v/1000; else printf "%.2f",v}')
  append2 "${C_DIM}session${RESET} ${C_AMBER}\$${sc_fmt}${RESET}"
fi

# Org usage — fetched via OAuth usage API (background, lock-guarded)
usage_dir="${TMPDIR:-/tmp}/claude-sl-usage-$(id -u)"
usage_cache="${usage_dir}/data"
usage_lock="${usage_dir}/lock"
usage_backoff="${usage_dir}/backoff"
secure_dir "$usage_dir"

poll_interval="$USAGE_POLL_INTERVAL"
if [ -f "$usage_backoff" ]; then
  bo=$(cat "$usage_backoff" 2>/dev/null)
  is_numeric "$bo" && [ "$bo" -gt "$USAGE_POLL_INTERVAL" ] 2>/dev/null && poll_interval="$bo"
fi
if [ ! -f "$usage_cache" ] || [ ! -s "$usage_cache" ]; then
  poll_interval="$USAGE_RETRY_INTERVAL"
fi

if [ "$(file_age "$usage_cache")" -gt "$poll_interval" ] && [ "$(file_age "$usage_lock")" -gt "$poll_interval" ]; then
  rm -rf "$usage_lock" 2>/dev/null
  if mkdir "$usage_lock" 2>/dev/null; then
    ( token=$(claude_token)
      if [ -z "$token" ]; then
        printf '' > "$usage_cache"
        rm -rf "$usage_lock"
        exit 0
      fi
      http_code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
        | curl -s -w '%{http_code}' --max-time "$USAGE_API_TIMEOUT" --config - \
            -o "${usage_cache}.raw" \
            "$USAGE_API_URL" \
            -H "anthropic-beta: $USAGE_API_BETA" \
            -H "Content-Type: application/json" \
            -H "User-Agent: claude-code-statusline/1.0" 2>/dev/null)
      if [ "$http_code" = "429" ] || [ "$http_code" = "500" ] || [ "$http_code" = "503" ]; then
        cur=$(cat "$usage_backoff" 2>/dev/null)
        is_numeric "$cur" || cur="$USAGE_POLL_INTERVAL"
        next=$(( cur * 2 ))
        [ "$next" -gt 3600 ] && next=3600
        printf '%s' "$next" > "$usage_backoff"
        touch "$usage_cache"
        rm -rf "$usage_lock"
        rm -f "${usage_cache}.raw"
        exit 0
      fi
      rm -f "$usage_backoff"
      result=$(jq -r '
        if .extra_usage.used_credits then
          [.extra_usage.used_credits, .extra_usage.monthly_limit, .extra_usage.utilization] | @tsv
        elif .spend.used.amount_minor then
          [.spend.used.amount_minor, .spend.limit.amount_minor, .spend.percent] | @tsv
        else empty end' "${usage_cache}.raw" 2>/dev/null)
      if [ -n "$result" ] && printf '%s' "$result" | grep -q '	'; then
        printf '%s' "$result" > "${usage_cache}.tmp" && mv "${usage_cache}.tmp" "$usage_cache"
      fi
      rm -f "${usage_cache}.raw"
      rm -rf "$usage_lock"
    ) >/dev/null 2>&1 &
  fi
fi

if [ -f "$usage_cache" ] && [ -s "$usage_cache" ]; then
  used_cents=$(cut -f1 < "$usage_cache")
  limit_cents=$(cut -f2 < "$usage_cache")
  util_raw=$(cut -f3 < "$usage_cache")
  is_numeric "$used_cents" || used_cents=""
  is_numeric "$limit_cents" || limit_cents=""
  is_numeric "$util_raw" || util_raw=""
  util_int=$(printf '%.0f' "$util_raw" 2>/dev/null)
  if [ "$util_int" -eq 0 ] 2>/dev/null; then
    scaled=$(awk -v v="$util_raw" 'BEGIN{v=v+0; if(v>0 && v<=1) printf "%.0f", v*100; else print 0}')
    util_int="$scaled"
  fi
  if [ "$util_int" -gt 0 ] 2>/dev/null; then
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
