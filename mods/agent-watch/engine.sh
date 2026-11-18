#!/usr/bin/env bash
# agent-watch: runs the enabled rules from config.json every .interval seconds.
# Started by the agent-watch Herdr mod as terminal `agent-watch`.
#
#   bash engine.sh                         loop forever
#   bash engine.sh --once [rule...]        one tick of all (or the named) rules
#   bash engine.sh --dry-run --once [...]  log every action instead of doing it, on a copy of the state
#
# A rule is a function `rule_<name with - as _>` in rules/<file>, listed in config.json:
#   {"name": "github-my-pr-merged", "file": "github-pr.sh", "enabled": true, "config": {...}}
# Rules use only lib.sh primitives (spawn, stop_terminals, slot_*, wt_*, notify, act, var, rule_cfg, rule_state).
#
# Config and state live outside the mod folder, because Herdr reloads a mod when a file in it changes:
#   AW_DATA (default ~/.config/herdr-core/agent-watch) holds config.json, state/ and optional templates/.
set -uo pipefail

AW_HOME="${AW_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
AW_DATA="${AW_DATA:-$HOME/.config/herdr-core/agent-watch}"
AW_CONFIG="${AW_CONFIG:-$AW_DATA/config.json}"
AW_STATE="${AW_STATE:-$AW_DATA/state}"
AW_DRY_RUN="${AW_DRY_RUN:-}"
AW_RULE=""
export AW_HOME AW_DATA AW_CONFIG AW_STATE AW_DRY_RUN

source "$AW_HOME/lib.sh"

once=""
only=()
while [ $# -gt 0 ]; do
  case "$1" in
    --once) once=1 ;;
    --dry-run) AW_DRY_RUN=1 ;;
    *) only+=("$1") ;;
  esac
  shift
done

# github_rules_enabled — true when an enabled rule comes from a rules/github*.sh file.
github_rules_enabled() {
  jq -e '[.rules[]? | select(.enabled != false) | .file // "" | select(startswith("github"))] | length > 0' "$AW_CONFIG" >/dev/null 2>&1
}

# setup_problem — why the engine cannot run yet, or nothing.
setup_problem() {
  local c f
  for c in jq hc git; do
    command -v "$c" >/dev/null 2>&1 || { echo "$c is not installed or not on PATH"; return; }
  done
  [ -f "$AW_CONFIG" ] || { echo "no config: copy $AW_HOME/config.example.json to $AW_CONFIG and edit it"; return; }
  jq -e . "$AW_CONFIG" >/dev/null 2>&1 || { echo "$AW_CONFIG is not valid JSON"; return; }
  if github_rules_enabled; then
    command -v gh >/dev/null 2>&1 || { echo "gh is not installed or not on PATH, and a GitHub rule is enabled"; return; }
    gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: run gh auth login"; return; }
  fi
  for f in $(jq -r '[.rules[] | select(.enabled != false) | .file] | unique[]' "$AW_CONFIG"); do
    [ -f "$AW_HOME/rules/$f" ] || { echo "config names rules/$f, which does not exist"; return; }
  done
}

problem=$(setup_problem)
if [ -n "$problem" ] && [ -n "$once" ]; then echo "agent-watch: $problem" >&2; exit 1; fi
last=""
while [ -n "$problem" ]; do
  [ "$problem" = "$last" ] || log "waiting: $problem"
  last=$problem
  sleep 30
  problem=$(setup_problem)
done

if dry; then
  tmp=$(mktemp -d)
  mkdir -p "$AW_STATE" && cp -pR "$AW_STATE/." "$tmp/"
  AW_STATE=$tmp
  AW_TEMPLATES_OUT="$tmp/.templates"
  export AW_TEMPLATES_OUT
  trap 'rm -rf "$tmp"' EXIT
fi

if github_rules_enabled && ! bash "$AW_HOME/render-templates.sh"; then
  log "templates were not rendered: agents may start from stale or missing templates"
  [ -z "$once" ] && notify "agent-watch" "Templates were not rendered, open the agent-watch log"
fi

for f in $(jq -r '[.rules[] | select(.enabled != false) | .file] | unique[]' "$AW_CONFIG"); do
  source "$AW_HOME/rules/$f" || { echo "agent-watch: cannot load rules/$f" >&2; exit 1; }
done

enabled_rules() {
  local r
  for r in $(jq -r '.rules[] | select(.enabled != false) | .name' "$AW_CONFIG"); do
    if [ ${#only[@]} -eq 0 ] || printf '%s\n' "${only[@]}" | grep -qx "$r"; then echo "$r"; fi
  done
}

tick() {
  local r fn
  for r in $(enabled_rules); do
    fn="rule_${r//-/_}"
    if ! declare -F "$fn" >/dev/null; then AW_RULE="" log "rule $r: no function $fn"; continue; fi
    ( AW_RULE=$r; "$fn" ) || AW_RULE="" log "rule $r failed (exit $?)"
  done
}

if [ -n "$once" ]; then tick; exit 0; fi

interval=$(jq -r '.interval // 300' "$AW_CONFIG")
log "watching every ${interval}s, rules: $(enabled_rules | paste -sd, -)"
while true; do
  tick
  sleep "$interval"
done
