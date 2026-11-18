# agent-watch primitives. Sourced by engine.sh; rules call only these and their own helpers.
# Needs: bash, jq, hc. AW_HOME, AW_CONFIG, AW_STATE, AW_RULE, AW_DRY_RUN are set by engine.sh.

log() { echo "[$(date '+%F %T')] ${AW_RULE:+$AW_RULE: }$*" >&2; }
dry() { [ -n "${AW_DRY_RUN:-}" ]; }

# act <what> <cmd...> — run cmd, or only log <what> in a dry run.
act() {
  local what=$1; shift
  if dry; then log "dry run: $what"; return 0; fi
  "$@"
}

# notify <title> <body> [terminal] — toast + macOS banner; a click opens <terminal>.
notify() {
  if dry; then log "dry run: notify [$1] $2"; return 0; fi
  "$AW_HOME/notify.sh" "${3:-}" "$1" "$2"
}

# ---------- config ----------

_expand() { sed "s|^~|$HOME|"; }
# var <name> — top-level .vars value; `~` expands to $HOME.
var() { jq -r --arg k "$1" '.vars[$k] // empty' "$AW_CONFIG" | _expand; }
# var_list <name> — one line per element of a .vars array.
var_list() { jq -r --arg k "$1" '.vars[$k][]? // empty' "$AW_CONFIG" | _expand; }
# rule_cfg <name> [default] — value from the current rule's .config.
rule_cfg() {
  local v
  v=$(jq -r --arg r "$AW_RULE" --arg k "$1" '.rules[] | select(.name == $r) | .config[$k] // empty' "$AW_CONFIG" | _expand)
  echo "${v:-${2:-}}"
}
# rule_state — this rule's private state directory.
rule_state() { local d="$AW_STATE/rules/$AW_RULE"; mkdir -p "$d"; echo "$d"; }

# ---------- terminals ----------

live_names() { hc ls --json | jq -r '.terminals[] | select(.state=="live") | .name // empty'; }
live_cwds() { hc ls --json | jq -r '.terminals[] | select(.state=="live") | .cwd // empty'; }
is_live() { live_names | grep -qx "$1"; }

# spawn <name> <cwd> <template> <task> [k=v label...] — start the agent and make sure its task arrived.
# Every agent gets the label agent-watch=1; pass aw.title=<text> to name it in the bar and its window.
spawn() {
  local name=$1 cwd=$2 template=$3 task=$4 l args=(--label agent-watch=1); shift 4
  for l in "$@"; do args+=(--label "$l"); done
  act "spawn $name ($template) in $cwd" \
    hc run --bg --no-parent --name "$name" --cwd "$cwd" "${args[@]}" "$template" "$task" >/dev/null || return 1
  dry || ensure_task "$name" "$task"
}

# ensure_task <name> <task> — resend the task when the agent sits idle before its first turn.
ensure_task() {
  local name=$1 task=$2 i st
  for i in 1 2 3 4 5 6; do
    sleep 10
    st=$(hc ls --json | jq -r --arg n "$name" '.terminals[] | select(.name == $n and .state == "live") | "\(.status) \(.turn // 0)"')
    case "$st" in
      "") log "$name: exited before its first turn"; return 1 ;;
      "idle 0") ;;
      "blocked 0")
        log "$name: blocked on a dialog before its first turn"
        notify "agent-watch" "$name waits on a dialog before its task, open it" "$name"
        return 0 ;;
      *) return 0 ;;
    esac
  done
  log "$name: still idle without its task after 60 s, sending it again"
  if hc send --if idle "$name" "$task" >/dev/null 2>&1; then return 0; fi
  log "$name: hc send failed"
  notify "agent-watch" "$name started without its task, open it and paste the task" "$name"
}

# stop_terminals <label> <name...> — kill the named live terminals and their live children.
stop_terminals() {
  local label=$1 addr; shift
  hc ls --json | jq -r --args '
      ($ARGS.positional) as $names
      | (.terminals | map(select(.name as $x | $names | index($x))) | map(.address)) as $own
      | .terminals[]
      | select(.state == "live")
      | select((.name as $x | $names | index($x)) or ((.parent // "") as $p | $own | index($p)))
      | .address' "$@" \
    | sort -u \
    | while read -r addr; do
        [ -n "$addr" ] || continue
        if dry; then log "dry run: hc kill $addr ($label)"; continue; fi
        hc kill "$addr" >/dev/null 2>&1 || log "$label: hc kill $addr failed"
      done
}

# ---------- slot pools: a fixed number of parallel jobs ----------
# state/slots/<pool>/<i> holds "<key>\t<owner terminal>"; its mtime is when the job started.

_slot_dir() { local d="$AW_STATE/slots/$1"; mkdir -p "$d"; echo "$d"; }

# slot_free <pool> <size> — first slot that is empty or whose owner terminal is gone.
slot_free() {
  local d i owner live
  d=$(_slot_dir "$1"); live=$(live_names)
  for i in $(seq 1 "$2"); do
    owner=$(cut -f2 "$d/$i" 2>/dev/null || true)
    if [ -z "$owner" ] || ! grep -qx "$owner" <<<"$live"; then echo "$i"; return; fi
  done
}
slot_take() { printf '%s\t%s\n' "$3" "$4" > "$(_slot_dir "$1")/$2"; }
slot_release() { rm -f "$(_slot_dir "$1")/$2"; }
# slot_list <pool> — lines "i\tkey\towner\tstarted (UTC ISO)".
slot_list() {
  local d f
  d=$(_slot_dir "$1")
  for f in "$d"/*; do
    [ -s "$f" ] || continue
    printf '%s\t%s\t%s\n' "$(basename "$f")" "$(head -1 "$f")" "$(date -u -r "$(stat -f %m "$f")" +%Y-%m-%dT%H:%M:%SZ)"
  done
}

# ---------- warn once ----------

# warn_once <key> <title> <body> — notify the first time only; warn_forget_missing drops keys whose path is gone.
warn_once() {
  local f="$AW_STATE/warned.txt"
  touch "$f"
  grep -qxF "$1" "$f" && return 0
  log "$3"
  notify "$2" "$3"
  echo "$1" >> "$f"
}
warn_forget_missing() {
  local f="$AW_STATE/warned.txt" k
  touch "$f"
  while IFS= read -r k; do [ -e "$k" ] && echo "$k"; done < "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
}

# ---------- worktrees ----------

# wt_busy_reason <wt> [live cwds] — why the worktree must stay, or nothing.
wt_busy_reason() {
  local wt=$1 cwds=${2-}
  [ -n "${2+x}" ] || cwds=$(live_cwds)
  if [ -n "$(git -C "$wt" status --porcelain)" ]; then
    echo "uncommitted changes"
  elif ! dry && grep -q -e "^$wt\$" -e "^$wt/" <<<"$cwds"; then
    echo "a live terminal works in it"
  fi
}

# wt_remove <repo> <wt> — run the configured pre_remove hook, then `git worktree remove`.
wt_remove() {
  local repo=$1 wt=$2 if_file run path
  if_file=$(jq -r '.worktree.pre_remove.if_file // empty' "$AW_CONFIG")
  run=$(jq -r '.worktree.pre_remove.run // empty' "$AW_CONFIG")
  path=$(jq -r '[.worktree.pre_remove.path_prepend[]? | sub("^~"; env.HOME)] | join(":")' "$AW_CONFIG")
  if [ -n "$run" ] && { [ -z "$if_file" ] || [ -e "$wt/$if_file" ]; }; then
    act "($run) in $wt" bash -c "cd \"\$1\" && PATH=\"$path:\$PATH\" $run >/dev/null 2>&1" _ "$wt" \
      || { log "$run failed in $wt, kept it"; return 1; }
  fi
  act "git worktree remove $wt" git -C "$repo" worktree remove "$wt" \
    || { log "git worktree remove failed for $wt"; return 1; }
}
