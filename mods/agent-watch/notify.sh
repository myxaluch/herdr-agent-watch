#!/usr/bin/env bash
# Usage: notify.sh <terminal-name|""> <title> <body>
# Herdr toast plus a macOS banner. A click on either opens <terminal-name> in an agent-watch window.
#
# The banner uses terminal-notifier when it finds one: .notify.terminal_notifier in config.json,
# then the Homebrew paths. Version-manager shims are never used. Without it the banner comes
# from osascript and its click does nothing useful.
set -u
term=${1:-} title=${2:-agent-watch} body=${3:-}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mod=${AW_MOD:-$(basename "$here")}
config=${AW_CONFIG:-${AW_DATA:-$HOME/.config/herdr-core/agent-watch}/config.json}

herdr=$(command -v herdr-app 2>/dev/null || true)
[ -n "$herdr" ] || herdr=$HOME/.local/bin/herdr-app

payload=$(jq -cn --arg terminal "$term" --arg title "$title" --arg body "$body" '{terminal: $terminal, title: $title, body: $body}')
"$herdr" do "$mod.say:$payload" >/dev/null 2>&1 || true

notifier=""
if [ -f "$config" ]; then
  notifier=$(jq -r '.notify.terminal_notifier // empty' "$config" 2>/dev/null | sed "s|^~|$HOME|")
fi
for candidate in "$notifier" /opt/homebrew/bin/terminal-notifier /usr/local/bin/terminal-notifier; do
  [ -n "$candidate" ] && [ -x "$candidate" ] || continue
  args=(-title "$title" -message "$body" -group "$mod-${term:-log}" -activate dev.herdr.app)
  [ -n "$term" ] && args+=(-execute "'$herdr' do '$mod.open:$term'")
  "$candidate" "${args[@]}" >/dev/null 2>&1 && exit 0
done

osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' \
  "$title" "$body" >/dev/null 2>&1 || true
