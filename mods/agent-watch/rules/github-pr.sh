# GitHub PR rules for agent-watch, run once per entry of .vars.repos.
# Terminal names: <prefix>pr-<n> (+ <prefix>pr-<n>-codex) review, <prefix>pr-replies-<n> my PR.

GH_REPO=""

gh_me() { gh api user --jq .login; }

# rv <field> — field of the current repo entry; arrays print one element per line.
rv() {
  jq -r --arg r "$GH_REPO" --arg k "$1" \
    '.vars.repos[] | select(.name == $r) | .[$k] // empty | if type == "array" then .[] else . end' "$AW_CONFIG" | _expand
}
# term <suffix> — terminal name with the repo prefix, e.g. `term pr-15` → mob-pr-15.
term() { echo "$(rv terminal_prefix)$1"; }
# job_title <kind> <n> — label for the bar and the window, e.g. "review #15", "mobile replies #7".
job_title() { echo "$(rv title_prefix)$1 #$2"; }
# repo_state — this rule's state directory for the current repo.
repo_state() { local d; d="$(rule_state)/$GH_REPO"; mkdir -p "$d"; echo "$d"; }

# for_each_repo <fn> — run <fn> once per repo; a failing repo does not stop the others.
for_each_repo() {
  local fn=$1 r rc=0
  for r in $(jq -r '.vars.repos[].name' "$AW_CONFIG"); do
    ( GH_REPO=$r; "$fn" ) || { log "$r: failed (exit $?)"; rc=1; }
  done
  return $rc
}

# gh_my_verdict_since <n> <me> <since ISO> — state of my last non-comment review after <since>.
gh_my_verdict_since() {
  gh api "repos/$(rv repo)/pulls/$1/reviews" --paginate \
    --jq ".[] | select(.user.login == \"$2\" and .state != \"COMMENTED\" and .state != \"PENDING\" and .submitted_at > \"$3\") | .state" \
    | tail -1
}

gh_pr_activity() {
  local n=$1 repo; repo=$(rv repo)
  {
    gh api "repos/$repo/issues/$n/comments" --paginate \
      --jq '.[] | {kind: "issue", id, user: .user.login, at: .created_at, body, url: .html_url}'
    gh api "repos/$repo/pulls/$n/reviews" --paginate \
      --jq '.[] | select(.body != "" or .state != "COMMENTED") | {kind: "review", id, user: .user.login, at: .submitted_at, state, body, url: .html_url}'
    gh api "repos/$repo/pulls/$n/comments" --paginate \
      --jq '.[] | {kind: "line", id, user: .user.login, at: .created_at, path, line, in_reply_to_id, body, url: .html_url}'
  } | jq -s 'sort_by(.at)'
}

# clone_worktrees — "clone\tworktree\tbranch" for every branch worktree of the current repo's clones.
clone_worktrees() {
  local clone
  while IFS= read -r clone; do
    [ -d "$clone/.git" ] || continue
    git -C "$clone" worktree list --porcelain \
      | awk -v r="$clone" '/^worktree /{wt=substr($0,10)} /^branch refs\/heads\//{print r "\t" wt "\t" substr($0,19)}'
  done < <(rv clone_dirs)
}

# ---------- github-review-approved ----------

_review_approved() {
  local me repo_dir pool i n owner started wt reason
  me=$(gh_me) || { log "gh api user failed"; return 1; }
  repo_dir=$(rv repo_dir); pool=$(rv slot_pool)
  while IFS=$'\t' read -r i n owner started; do
    [ -n "$n" ] || continue
    [ "$(gh_my_verdict_since "$n" "$me" "$started")" = "APPROVED" ] || continue

    stop_terminals "PR $n" "$(term "pr-$n")" "$(term "pr-$n-codex")"
    wt="$repo_dir/$(rv worktrees_dir)/pr-review-$i"
    if [ -d "$wt" ]; then
      reason=$(wt_busy_reason "$wt")
      if [ -n "$reason" ]; then
        warn_once "$wt" "PR review" "$GH_REPO PR $n approved: agents stopped, kept $(basename "$wt"): $reason"
        continue
      fi
      wt_remove "$repo_dir" "$wt" || continue
    fi
    act "drop refs/pr-review/$n" git -C "$repo_dir" update-ref -d "refs/pr-review/$n" || true
    slot_release "$pool" "$i"
    log "$GH_REPO PR $n approved: stopped $(term "pr-$n"), removed $wt, freed slot $i"
    notify "PR review" "$GH_REPO PR $n approved: agents stopped, $(basename "$wt") removed"
  done < <(slot_list "$pool")
}
rule_github_review_approved() { for_each_repo _review_approved; }

# ---------- github-review-requested ----------

_checkout_slot() {
  local repo_dir=$1 slot=$2 sha=$3 wt
  wt="$1/$(rv worktrees_dir)/pr-review-$2"
  if [ -d "$wt" ]; then
    act "checkout $sha in $wt" git -C "$wt" checkout --quiet --detach "$sha" || return 1
  else
    act "git worktree add $wt $sha" git -C "$repo_dir" worktree add --quiet --detach "$wt" "$sha" || return 1
  fi
  echo "$wt"
}

_start_review() {
  local n=$1 title=$2 url=$3 repo repo_dir pool slot sha wt dir name
  repo=$(rv repo); repo_dir=$(rv repo_dir); pool=$(rv slot_pool); name=$(term "pr-$n")
  slot=$(slot_free "$pool" "$(var review_slots)")
  [ -n "$slot" ] || { log "$GH_REPO PR $n queued: all review slots busy"; return 1; }

  act "fetch PR $n" git -C "$repo_dir" fetch --quiet origin "+refs/heads/$(rv base):refs/remotes/origin/$(rv base)" "+pull/$n/head:refs/pr-review/$n" || return 1
  sha=$(git -C "$repo_dir" rev-parse --verify --quiet "refs/pr-review/$n" || echo "pull/$n/head")
  wt=$(_checkout_slot "$repo_dir" "$slot" "$sha") || { log "$GH_REPO PR $n: worktree checkout failed"; return 1; }

  dir="$(var reviews_dir)/$(rv terminal_prefix)PR-$n-$(date +%Y%m%d-%H%M%S)"
  if ! dry; then
    mkdir -p "$dir"
    gh pr view "$n" --repo "$repo" --json number,title,url,author,body,baseRefName,headRefName,headRefOid,files,labels,comments,reviews > "$dir/pr.json"
    gh api "repos/$repo/pulls/$n/comments" --paginate > "$dir/inline-comments.json"
    gh pr diff "$n" --repo "$repo" > "$dir/diff.patch" 2>/dev/null \
      || git -C "$repo_dir" diff "refs/remotes/origin/$(rv base)...$sha" > "$dir/diff.patch" \
      || { log "$GH_REPO PR $n: no diff from GitHub or git"; return 1; }
  fi

  spawn "$name" "$wt" "$(rule_cfg template pr-reviewer)" \
    "PR #$n \"$title\" ($url). Repo $repo, head $sha. Your terminal: $name. Review dir: $dir" "pr=$n" "repo=$GH_REPO" "review_dir=$dir" "aw.title=$(job_title review "$n")" \
    || { log "$GH_REPO PR $n: hc run failed"; return 1; }

  slot_take "$pool" "$slot" "$n" "$name"
  log "$GH_REPO PR $n: reviewer $name started in slot $slot, dir $dir"
  notify "PR review" "$GH_REPO PR $n: Claude started the review" "$name"
}

_review_requested() {
  local seen prs requested live n title url skip name
  seen="$(repo_state)/seen.txt"; touch "$seen"
  skip=$(rule_cfg skip_authors '^$')
  prs=$(gh search prs --repo "$(rv repo)" --state open --review-requested=@me \
          --json number,title,url,isDraft,author \
          --jq ".[] | select(.isDraft | not) | select(.author.login | test(\"$(sed 's/\\/\\\\/g' <<<"$skip")\") | not) | [.number, .title, .url] | @tsv") \
    || { log "gh search (reviews) failed"; return 1; }
  requested=$(cut -f1 <<<"$prs" | sed '/^$/d')

  grep -Fxf <(printf '%s\n' "$requested") "$seen" > "$seen.tmp" || true
  mv "$seen.tmp" "$seen"

  live=$(live_names)
  while IFS=$'\t' read -r n title url; do
    [ -n "$n" ] || continue
    grep -qx "$n" "$seen" && continue
    name=$(term "pr-$n")
    if grep -qx "$name" <<<"$live"; then
      log "$GH_REPO PR $n re-requested, $name is still open: skip"
      notify "PR review" "$GH_REPO PR $n review requested again, close $name to rerun" "$name"
      echo "$n" >> "$seen"
      continue
    fi
    _start_review "$n" "$title" "$url" && echo "$n" >> "$seen"
  done <<<"$prs"
}
rule_github_review_requested() { for_each_repo _review_requested; }

# ---------- github-my-pr-comments ----------

_start_replies() {
  local n=$1 title=$2 url=$3 items=$4 repo branch wt dir name
  repo=$(rv repo); name=$(term "pr-replies-$n")
  branch=$(gh pr view "$n" --repo "$repo" --json headRefName --jq .headRefName) || return 1
  wt=$(clone_worktrees | awk -F'\t' -v b="$branch" '$3 == b {print $2; exit}')
  dir="$(var replies_dir)/$(rv terminal_prefix)PR-$n-$(date +%Y%m%d-%H%M%S)"
  if ! dry; then
    mkdir -p "$dir"
    printf '%s\n' "$items" > "$dir/new-comments.json"
    gh_pr_activity "$n" > "$dir/all-activity.json"
  fi
  spawn "$name" "${wt:-$(rv repo_dir)}" "$(rule_cfg template pr-replies)" \
    "My PR #$n \"$title\" ($url), branch $branch, local worktree: ${wt:-none}. Repo $repo, worktrees dir $(rv worktrees_dir). Your terminal: $name. Replies dir: $dir" \
    "pr=$n" "repo=$GH_REPO" "replies_dir=$dir" "aw.title=$(job_title replies "$n")" \
    || { log "$GH_REPO PR $n: hc run $name failed"; return 1; }
  log "$GH_REPO PR $n: $name started, dir $dir"
}

_my_pr_comments() {
  local me prs live n title url activity since latest new count sdir name
  me=$(gh_me) || { log "gh api user failed"; return 1; }
  sdir="$(repo_state)/since"; mkdir -p "$sdir"
  prs=$(gh search prs --repo "$(rv repo)" --state open --author @me --json number,title,url \
          --jq '.[] | [.number, .title, .url] | @tsv') \
    || { log "gh search (my PRs) failed"; return 1; }

  live=$(live_names)
  while IFS=$'\t' read -r n title url; do
    [ -n "$n" ] || continue
    name=$(term "pr-replies-$n")
    activity=$(gh_pr_activity "$n") || continue
    since=$(cat "$sdir/$n" 2>/dev/null || jq -r --arg me "$me" '[.[] | select(.user == $me) | .at] | max // "1970-01-01T00:00:00Z"' <<<"$activity")
    latest=$(jq -r '[.[].at] | max // empty' <<<"$activity")
    new=$(jq -c --arg me "$me" --arg since "$since" '[.[] | select(.user != $me and .at > $since)]' <<<"$activity")
    count=$(jq length <<<"$new")

    if [ "$count" -gt 0 ]; then
      if grep -qx "$name" <<<"$live"; then
        notify "My PR $n" "$count new comments, tell $name to check new comments" "$name"
        log "$GH_REPO PR $n: $count new comments, $name is open: notified"
      else
        _start_replies "$n" "$title" "$url" "$new" || continue
        notify "My PR $n" "$GH_REPO: $count new comments, Claude is triaging them" "$name"
      fi
    fi
    [ -n "$latest" ] && echo "$latest" > "$sdir/$n"
  done <<<"$prs"
}
rule_github_my_pr_comments() { for_each_repo _my_pr_comments; }

# ---------- github-my-pr-merged ----------

# _merged_keep_reason <wt> <n> <live cwds> — busy, or holds commits that are not in the PR.
_merged_keep_reason() {
  local wt=$1 n=$2 ref="refs/pr-cleanup/$2" reason
  reason=$(wt_busy_reason "$wt" "$3")
  if [ -z "$reason" ]; then
    if ! git -C "$wt" fetch --quiet origin "+pull/$n/head:$ref"; then
      reason="cannot fetch the PR head"
    elif ! git -C "$wt" merge-base --is-ancestor HEAD "$ref"; then
      reason="local commits that are not in the PR"
    fi
  fi
  git -C "$wt" update-ref -d "$ref" 2>/dev/null || true
  echo "$reason"
}

_my_pr_merged() {
  local merged live n cwds clone wt branch reason wdir name
  merged=$(gh pr list --repo "$(rv repo)" --author @me --state merged --limit 100 \
             --json number,headRefName --jq '.[] | [.headRefName, .number] | @tsv') \
    || { log "gh pr list (merged) failed"; return 1; }
  [ -n "$merged" ] || return 0

  live=$(live_names)
  while IFS=$'\t' read -r _ n; do
    [ -n "$n" ] || continue
    name=$(term "pr-replies-$n")
    grep -qx "$name" <<<"$live" || continue
    stop_terminals "PR $n" "$name"
    dry && continue
    log "$GH_REPO PR $n merged: stopped $name"
    notify "My PR $n" "$GH_REPO PR $n merged: $name stopped"
  done <<<"$merged"

  warn_forget_missing
  cwds=$(live_cwds)
  wdir=$(rv worktrees_dir)
  while IFS=$'\t' read -r clone wt branch; do
    case "$wt" in "$clone/$wdir/"*) ;; *) continue ;; esac
    n=$(awk -F'\t' -v b="$branch" '$1 == b {print $2; exit}' <<<"$merged")
    [ -n "$n" ] || continue
    reason=$(_merged_keep_reason "$wt" "$n" "$cwds")
    if [ -n "$reason" ]; then
      warn_once "$wt" "Worktree" "$GH_REPO PR $n merged, kept $(basename "$wt"): $reason"
      continue
    fi
    wt_remove "$clone" "$wt" || { warn_once "$wt" "Worktree" "$GH_REPO PR $n merged, could not remove $(basename "$wt")"; continue; }
    act "git branch -D $branch" git -C "$clone" branch -D "$branch" >/dev/null || true
    dry && continue
    log "$GH_REPO PR $n merged: removed $wt and branch $branch"
    notify "Worktree" "$GH_REPO PR $n merged: removed $(basename "$wt")"
  done < <(clone_worktrees)
}
rule_github_my_pr_merged() { for_each_repo _my_pr_merged; }

# ---------- github-my-pr-conflicts ----------

# One banner when my open PR starts to conflict with its base, one when the conflict is gone.
# GitHub answers UNKNOWN while it recomputes: such a PR keeps its last known state.
_my_pr_conflicts() {
  local f prs n state title name
  f="$(repo_state)/conflicting.txt"; touch "$f"
  prs=$(gh pr list --repo "$(rv repo)" --author @me --state open --limit 100 \
          --json number,mergeable,title --jq '.[] | [.number, .mergeable, .title] | @tsv') \
    || { log "gh pr list (mergeable) failed"; return 1; }

  : > "$f.tmp"
  while IFS=$'\t' read -r n state title; do
    [ -n "$n" ] || continue
    name=$(term "pr-replies-$n")
    is_live "$name" || name=""
    case "$state" in
      CONFLICTING)
        echo "$n" >> "$f.tmp"
        grep -qx "$n" "$f" && continue
        log "$GH_REPO PR $n conflicts with $(rv base)"
        notify "My PR $n" "$GH_REPO: conflicts with $(rv base) — $title" "$name"
        ;;
      MERGEABLE)
        grep -qx "$n" "$f" || continue
        log "$GH_REPO PR $n: conflict resolved"
        notify "My PR $n" "$GH_REPO: conflict with $(rv base) is resolved" "$name"
        ;;
      *)
        grep -qx "$n" "$f" && echo "$n" >> "$f.tmp"
        ;;
    esac
  done <<<"$prs"
  mv "$f.tmp" "$f"
}
rule_github_my_pr_conflicts() { for_each_repo _my_pr_conflicts; }
