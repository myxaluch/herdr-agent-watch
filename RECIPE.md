# agent-watch

A thin strip at the bottom of the window lists the coding agents that a background watcher started when something happened. The watcher runs rules every few minutes; the shipped rules start a review for each pull request that asks for the person's review and a triage of new comments on the person's own pull requests, and a new rule is a few lines of shell. A click opens an agent in a floating window with a title bar that can end it.

![agent-watch](preview.png)

**What you see**

- A strip 24px high across the bottom, chrome background, 1px top border, 11.5px muted text, 14px side padding, 10px between items.
- Left: a 6px round dot and the word `agent-watch`. The dot has the theme's `done` color while the watcher terminal is live and the `blocked` color with the text `agent-watch: starting…` while it is not.
- Then one item per agent: a 6px status dot and its title, for example `review #15` or `replies #7`. With no agents, the dim text `no open jobs`.
- An agent window: 1100×720, a 30px title bar over the agent's terminal. The title bar has a 7px status dot, `<title> · <status>` in 12px text, an `End` button and a `✕` button.

**How it behaves**

- Status dots use the theme colors `working`, `blocked`, `done`, `idle`; any other status uses `unknown`. A live terminal that is not an agent shows `running` in the title bar, one that is gone shows `finished`.
- A click on an agent opens its window. A click on `agent-watch` opens the watcher's log in the same kind of window, without the `End` button.
- Items highlight with the theme's `hover` background under the pointer.
- `End` asks first: it turns into `End for sure?` in the `blocked` color for 3 seconds. A second click kills the agent's live child terminals, then the agent, then closes the window. While that runs it reads `Ending…`.
- `✕` closes the window and leaves the agent running.
- The command `agent-watch.close` (bound to `cmd-w` in `keys.json`) closes the agent window whose terminal has the keyboard; otherwise it runs `tab.close`.
- Every minute the strip checks that a live terminal named `agent-watch` exists and starts the watcher when it does not.
- A notification from the watcher shows as a Herdr toast and a macOS banner; a click on either opens the agent's window.
- While a program, the config or the GitHub login is missing, the watcher stays alive, says what is missing in its log once, and looks again every 30 seconds.
- Every 5 minutes the watcher runs the shipped GitHub rules, in this order:
  - The person approved a pull request that is under review: its reviewer and cross-check agents stop and the review worktree goes away.
  - A pull request that is not a draft asks for the person's review: a reviewer agent starts in a worktree at the PR head, at most 3 at a time; more wait for a free slot. The reviewer starts a second agent that cross-checks it, writes a report, and leaves a pending review on GitHub that only the person sees. A banner says the review started; the agent sends one when the pending review is ready.
  - Someone else commented on the person's open pull request: a triage agent starts in the branch's worktree and writes a decision and a reply draft per comment. When that agent already runs, the person gets a banner with the number of new comments instead.
  - The person's pull request merged: its triage agent stops, and the branch's worktree and the branch are removed.
  - The person's open pull request starts to conflict with its base: one banner. One more when the conflict is gone.
- A worktree with uncommitted changes, with local commits that are not in the pull request, or with a live terminal inside it is never removed. The person gets one banner that names the reason, once per worktree.
- The agents never post, submit, commit or push on their own. They act on the person's words in their terminal: `fix`, `commit`, `reply`, `check new`, `submit`.

**Built from**

*The mod*

- One mod folder, `mods/agent-watch`, used in two roles. Without props it is the strip (`mod.json`: `{ "place": "bottom", "size": 24 }`). With `props: { role: "titlebar", name, title }` it is the title bar of an agent window. `main.js` picks the role in `init`; `titlebar.js` holds the title bar and the constants `MOD` and `WATCHER`, both `agent-watch`.
- The agent window: `openOverlay({ kind: "window", key: "agent-watch:<name>", width: 1100, height: 720, layout: column[ block 30px { mod: "agent-watch", props: { role: "titlebar", name, title } }, block { terminal: <address> } ] })`. Its overlay id is kept in the shared value `agent-watch-window:<name>` so the title bar can close it.
- `herdr` functions: `terminals`, `theme`, `props`, `shared`, `setShared`, `openOverlay`, `closeOverlay`, `notify`, `nextCommand`, `focused`, `run`, `hc`, `appHome`, `checking`.
- Commands it answers through `nextCommand()`: `open:<terminal name>`, `say:<JSON {terminal, title, body, level}>`, `close`.
- Agents are the live terminals with the label `agent-watch=1`; the label `aw.title` is the title shown, the terminal name when it is absent.
- Programs: the strip runs `hc run --bg --no-parent --name agent-watch bash <appHome>/mods/agent-watch/engine.sh`; the title bar runs `hc kill <address>`.

*The watcher, `engine.sh`*

- Bash, `set -uo pipefail`. `bash engine.sh` loops forever; `--once [rule...]` runs one tick of all or the named rules; `--dry-run` logs every action instead of doing it.
- Paths, each from an environment variable with a default: `AW_HOME` (the script's folder), `AW_DATA` (`~/.config/herdr-core/agent-watch`), `AW_CONFIG` (`$AW_DATA/config.json`), `AW_STATE` (`$AW_DATA/state`).
- Start-up check, in order: `jq`, `hc`, `git` on `PATH`; the config exists and is valid JSON; when a GitHub rule is enabled, `gh` on `PATH` and `gh auth status` succeeds; every enabled rule's file exists in `rules/`. A GitHub rule is an enabled rule whose `file` starts with `github`. With `--once` a problem prints `agent-watch: <problem>` and exits 1; in the loop it is logged when it changes and checked again after 30 seconds.
- A dry run copies the state folder to a temporary folder, uses the copy, renders templates into it, and deletes it on exit.
- When a GitHub rule is enabled it runs `render-templates.sh`; a failure is logged and, in the loop, sent as a notification.
- It sources every file that an enabled rule names, then on each tick runs the enabled rules in config order. Rule `a-b-c` is the function `rule_a_b_c`. Each runs in a subshell with `AW_RULE` set to its name; a non-zero exit is logged and the next rule still runs. Between ticks it sleeps `.interval` seconds, 300 by default.

*The primitives, `lib.sh`*

- `log <text>`: to stderr, `[YYYY-MM-DD HH:MM:SS] <rule>: <text>`.
- `act <what> <cmd...>`: runs the command; in a dry run only logs `dry run: <what>`.
- `notify <title> <body> [terminal]`: calls `notify.sh <terminal> <title> <body>`; logged in a dry run.
- `var <name>`, `var_list <name>`: a value or the elements of `.vars`; `rule_cfg <name> [default]`: a value of the current rule's `.config`. A leading `~` becomes the home folder. `rule_state`: the folder `state/rules/<rule>`, created on demand.
- `live_names`, `live_cwds`, `is_live <name>`: from `hc ls --json`, terminals whose `state` is `live`.
- `spawn <name> <cwd> <template> <task> [k=v...]`: `hc run --bg --no-parent --name <name> --cwd <cwd> --label agent-watch=1 [--label k=v...] <template> <task>`. Then it looks at the terminal up to 6 times, 10 seconds apart: gone means failure; `blocked` at turn 0 sends a notification that it waits on a dialog; `idle` at turn 0 keeps waiting; anything else is success. Still idle at turn 0 after 60 seconds: `hc send --if idle <name> <task>`, and a notification when that fails.
- `stop_terminals <label> <name...>`: `hc kill` for each named live terminal and each live terminal whose `parent` is one of them.
- Slot pools limit parallel jobs. The file `state/slots/<pool>/<i>` holds `<key>\t<owner terminal>` and its modification time is the job's start. `slot_free <pool> <size>`: the first `i` in 1..size whose file is empty or whose owner is not live. `slot_take <pool> <i> <key> <owner>`, `slot_release <pool> <i>`. `slot_list <pool>`: lines `i\tkey\towner\tstart` with the start in UTC ISO 8601.
- `warn_once <key> <title> <body>`: notifies and appends the key to `state/warned.txt` unless it is there. `warn_forget_missing`: drops keys that are paths which no longer exist.
- `wt_busy_reason <worktree> [live cwds]`: `uncommitted changes` when `git status --porcelain` prints anything, `a live terminal works in it` when a live terminal's folder is the worktree or inside it, else nothing.
- `wt_remove <repo> <worktree>`: when `.worktree.pre_remove.run` is set and `.worktree.pre_remove.if_file` is unset or exists in the worktree, runs that command in the worktree with `.worktree.pre_remove.path_prepend` in front of `PATH`; a failure keeps the worktree. Then `git -C <repo> worktree remove <worktree>`.

*The GitHub rules, `rules/github-pr.sh`*

- Every rule runs once per entry of `.vars.repos`; a failing repo does not stop the others. Per-repo state is in `state/rules/<rule>/<repo name>/`. Terminal names are `<terminal_prefix>pr-<n>`, `<terminal_prefix>pr-<n>-codex` and `<terminal_prefix>pr-replies-<n>`; titles are `<title_prefix>review #<n>` and `<title_prefix>replies #<n>`. The person's login is `gh api user --jq .login`.
- `github-review-requested`:
  1. `gh search prs --repo <repo> --state open --review-requested=@me --json number,title,url,isDraft,author`; drop drafts and authors that match the regex `config.skip_authors`.
  2. `seen.txt` holds one PR number per line; first drop the numbers that are no longer requested, so a second request counts as new.
  3. For each number not in `seen.txt`: when its reviewer terminal is live, notify `review requested again, close <name> to rerun` and add it. Otherwise start the review and add it only on success, so a PR that found no free slot is tried again on the next tick.
  4. To start: take `slot_free <slot_pool> <review_slots>`; `git fetch origin +refs/heads/<base>:refs/remotes/origin/<base> +pull/<n>/head:refs/pr-review/<n>`; in `<repo_dir>/<worktrees_dir>/pr-review-<slot>` run `git checkout --detach <sha>`, or `git worktree add --detach` when the folder is new.
  5. Make `<reviews_dir>/<terminal_prefix>PR-<n>-<YYYYMMDD-HHMMSS>` with `pr.json` (`gh pr view --json number,title,url,author,body,baseRefName,headRefName,headRefOid,files,labels,comments,reviews`), `inline-comments.json` (`gh api repos/<repo>/pulls/<n>/comments --paginate`) and `diff.patch` (`gh pr diff`, else `git diff refs/remotes/origin/<base>...<sha>`).
  6. `spawn` the template `config.template` (default `pr-reviewer`) in the worktree with the task `PR #<n> "<title>" (<url>). Repo <repo>, head <sha>. Your terminal: <name>. Review dir: <dir>` and the labels `pr`, `repo`, `review_dir`, `aw.title`. Then `slot_take` with the PR number as key, and notify.
- `github-review-approved`: for each line of `slot_list`, read the person's reviews of that PR (`gh api repos/<repo>/pulls/<n>/reviews --paginate`), keep those that are not `COMMENTED` or `PENDING` and were submitted after the slot's start, take the last. When it is `APPROVED`: `stop_terminals` the reviewer and its `-codex`; when `wt_busy_reason` gives a reason, `warn_once` and keep everything; otherwise `wt_remove`, `git update-ref -d refs/pr-review/<n>`, `slot_release`, notify.
- `github-my-pr-comments`:
  1. `gh search prs --repo <repo> --state open --author @me --json number,title,url`.
  2. Activity of a PR is its issue comments, its reviews that have a body or a state other than `COMMENTED`, and its line comments, sorted by time.
  3. The watermark is the file `since/<n>`; without it, the time of the person's own latest activity, or 1970 when there is none. New comments are activity by others after the watermark.
  4. With new comments and a live triage terminal: notify `<count> new comments, tell <name> to check new comments`. With no such terminal: find the branch (`gh pr view --json headRefName`) and its worktree among `clone_dirs` (`git worktree list --porcelain`), write `new-comments.json` and `all-activity.json` into `<replies_dir>/<terminal_prefix>PR-<n>-<YYYYMMDD-HHMMSS>`, and `spawn` the template `config.template` (default `pr-replies`) in the worktree, or in `repo_dir` without one, with the task `My PR #<n> "<title>" (<url>), branch <branch>, local worktree: <path or none>. Repo <repo>, worktrees dir <worktrees_dir>. Your terminal: <name>. Replies dir: <dir>`.
  5. Write the time of the latest activity to `since/<n>`.
- `github-my-pr-merged`: `gh pr list --repo <repo> --author @me --state merged --limit 100 --json number,headRefName`. Stop every live triage terminal of a merged PR. Then for each branch worktree inside `<clone>/<worktrees_dir>/` of every clone whose branch is the head of a merged PR: keep it and `warn_once` when `wt_busy_reason` gives a reason, when `git fetch origin +pull/<n>/head:refs/pr-cleanup/<n>` fails, or when `HEAD` is not an ancestor of that ref; delete the ref either way. Otherwise `wt_remove`, `git branch -D <branch>`, notify. The main checkout and detached worktrees are never touched.
- `github-my-pr-conflicts`: `gh pr list --repo <repo> --author @me --state open --limit 100 --json number,mergeable,title`. `conflicting.txt` holds the numbers that conflicted last time. `CONFLICTING` and not in the file: notify. `MERGEABLE` and in the file: notify that it is resolved. Any other value keeps the last state. It starts no agent.

*The templates*

- `templates/pr-reviewer.md`, `pr-replies.md`, `pr-crosscheck.md`: `hc` templates, a front matter with `name`, `description` and `command`, then the agent's standing instructions in English with `{{parameters}}`.
- `pr-reviewer`: never edits the worktree, never submits or posts on its own, writes only in the review dir. It reads the repo's reading list, reviews the diff with its callers, and writes `claude-review.md` (`## Findings` with `### F1 [blocker|major|minor|nit] path:line — claim`, `Why:`, `Fix:`; `## Verdict`). It runs `hc run --bg --name <its terminal>-codex --cwd "$PWD" pr-crosscheck "Review dir: <dir>"` and waits with `hc wait` until `crosscheck.md` ends with `REVIEW_DONE`, going on without it after 3 waits. It checks every objection against the code and writes `final.md` (`Verdict:`, `## Findings` with `Found by:`, `Why:`, `Comment draft:`, then `## Disputed` and `## Dropped`). It posts the drafts of `## Findings` as a review without an `event`, so it stays pending, with comments only on lines inside the diff; a comment on another line goes into the review body. It calls `notify.sh` and waits. On the person's word it edits the pending review or submits it with the event the person names.
- `pr-replies`: never edits, commits, pushes or posts until told. For each new comment it decides `fix`, `push back`, `answer`, `needs user` or `already done`, marks convention comments `conceptual`, and writes `triage.md` with `Decision:`, `Why:`, `Plan:` and `Reply draft:` per comment. It calls `notify.sh` and waits. Then `fix` makes the changes test-first in the branch's worktree, `commit` commits and pushes in one step and never force-pushes, `reply` posts the kept drafts, `check new` triages newer comments.
- `pr-crosscheck`: edits nothing but `crosscheck.md`, which has `## Claude findings` (each `confirmed`, `false positive` or `severity → <new>`), `## Missed`, `## Verdict`, and `REVIEW_DONE` as its last line.
- `render-templates.sh` fills the parameters from the config and writes the result to `~/.config/herdr-core/templates/<name>.md` through a temporary file, ending with the marker line `<!-- generated by agent-watch: … -->`. Parameters: `reviewer_command`, `replies_command`, `crosscheck_command` (`.vars.agents.*`), `reviews_dir`, `github_login` (`.vars.github_login`, else `gh api user`), `output_language`, `comment_language`, `cmd_fix`, `cmd_commit`, `cmd_reply`, `cmd_recheck`, `cmd_submit` (`.vars.commands.*`), `repos_review`, `repos_replies`, `repos_fix` (one line ``- `<repo>`: <text>`` per repo from `review_docs`, `replies_docs`, `fix_notes`), `reviewer_notes`, `replies_notes`, `crosscheck_notes` (`.vars.notes.*` under the heading `## Extra instructions`, empty when unset), `notify` (the path of `notify.sh`). The defaults are in `config.example.json`. A file `<AW_DATA>/templates/<name>.md` replaces the shipped template. It leaves a target without the marker alone, and writes nothing for a template that still holds a `{{name}}`; both make it exit 1.

*Notifications, `notify.sh <terminal|""> <title> <body>`*

- Toast: `herdr-app do <mod>.say:<JSON {terminal, title, body}>`, where `<mod>` is the name of the script's folder.
- Banner: the first executable of `.notify.terminal_notifier` from the config, `/opt/homebrew/bin/terminal-notifier`, `/usr/local/bin/terminal-notifier`, called with `-title`, `-message`, `-group <mod>-<terminal or log>`, `-activate dev.herdr.app` and, with a terminal, `-execute "'<herdr-app>' do '<mod>.open:<terminal>'"`. Without one: `osascript` with the title and body passed as arguments.

*Config and state*

- `~/.config/herdr-core/agent-watch/config.json`, shaped as `config.example.json`: `interval`, `vars` (`repos[]` with `name`, `repo`, `base`, `repo_dir`, `clone_dirs`, `worktrees_dir`, `terminal_prefix`, `title_prefix`, `slot_pool`, `review_docs`, `replies_docs`, `fix_notes`; `review_slots`; `reviews_dir`; `replies_dir`; `github_login`; `output_language`; `comment_language`; `commands`; `agents`; `notes`), `notify.terminal_notifier`, `worktree.pre_remove` and the ordered `rules[]` with `name`, `file`, `enabled`, `config`.
- State is plain files in `~/.config/herdr-core/agent-watch/state/`: `slots/<pool>/<i>`, `rules/<rule>/<repo>/…`, `warned.txt`.

**Watch out**

- Herdr reloads a mod when a file in its folder is saved. State or a config inside the folder would reload the strip on every tick, so both live outside.
- `herdr-app check` runs `init` for real. Starting the watcher is behind `checking()`, or every check would start one.
- Copying the mod folder into `mods/` makes Herdr dock it by itself, once. A layout that already has the block then shows two strips: remove one.
- `hc` reads templates only from `~/.config/herdr-core/templates/` and substitutes nothing; the render step is required before the first agent starts. It runs only while a rule from a `rules/github*.sh` file is enabled, and only then does the watcher ask for `gh`.
- A banner must come from a real `terminal-notifier` binary. A version-manager shim fails outside a project folder, and an `osascript` banner opens Script Editor on click.
- A mod sees `terminal.labels`, but `herdr-app check` gets an empty `terminals()`, and `hc ls --json` does not print labels: verify the strip against a live labelled terminal (`hc run --bg --label agent-watch=1 --label aw.title=test sleep 600`).
- A terminal started a moment ago is not in the mod's `terminals()` yet: `open:<name>` right after `hc run` answers `<name> is not running`.
- The watcher that ends at once would be restarted every minute and leave a pile of finished terminals. On a setup problem `engine.sh` stays alive, logs the problem and retries every 30 seconds.
- An agent can start without its task: the terminal sits `idle` at turn 0. `spawn` sends the task again after 60 seconds.
- `gh pr diff` refuses a pull request with more than 300 files, hence the `git diff` fallback; `gh pr view --json files` lists at most 100.
- GitHub answers `UNKNOWN` for `mergeable` while it recomputes; treating it as a change would send a banner on every tick.
- A dry run of `github-my-pr-merged` still runs `git fetch` for the PR head in the worktrees it looks at.
- A rule's own log line in a dry run goes to stderr through `act`: redirecting the stderr of an `act` call hides it.
- GitHub allows one pending review per person per pull request; the reviewer never deletes one it did not make.
- The scripts use BSD `stat -f` and `date -r`: macOS only.
- Codex under `hc` needs `--no-daemon`.
- An overlay window of a killed agent stays open until it is closed.
- Rules are polled; an event is seen up to `interval` seconds late.

**Done when**

- `herdr-app check mods/agent-watch` passes and starts no terminal.
- With the block in the layout, a live terminal `agent-watch` appears within a minute and the strip's dot turns to the `done` color.
- `hc run --bg --label agent-watch=1 --label aw.title=test sleep 600` adds `test` to the strip; a click opens its window, titled `test · running`; `End` twice ends it and closes the window.
- `bash engine.sh --dry-run --once` logs what each rule would do and changes nothing in the state folder.
- `bash engine.sh --once` with no config prints `agent-watch: no config: …` and exits 1.
- With only a rule from a file that does not start with `github`, and no `gh` on `PATH`, `bash engine.sh --dry-run --once` runs that rule.
- `bash notify.sh <terminal> Title Body` shows a toast and a banner, and a click opens that terminal's window.
- `~/.config/herdr-core/templates/pr-reviewer.md` exists after the watcher starts and contains no `{{`.
- `render-templates.sh` exits 1 and leaves the file alone when a template of the same name without the marker is already there.
- A new comment by someone else on the person's open pull request starts `pr-replies-<n>` within one interval, and `triage.md` appears in its replies dir.
