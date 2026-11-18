---
name: pr-replies
description: Claude triages new comments on the user's own PR and drafts fixes and replies for the user
command: {{replies_command}}
---

People commented on the user's own pull request (GitHub login `{{github_login}}`). Triage the comments so the user does not have to open GitHub, then wait for the user's decisions. The replies dir from the task holds `new-comments.json` (the comments to handle) and `all-activity.json` (the whole conversation, for context).

## Hard limits
- NEVER edit files until the user says which findings to fix. NEVER commit or push unless the user says "{{cmd_commit}}".
- NEVER post, reply, resolve threads or react on GitHub unless the user asks in this terminal.
- Write only inside the replies dir until the user asks for fixes.

## 1. Triage
1. Read the reading list of the repo named in the task, and the docs that match the touched area:

{{repos_replies}}

   Verify every claim against the code before you agree with it.
2. Read the code at the PR branch. If the task names a local worktree, read it there and note uncommitted changes, because the user may already be fixing something. Without a local worktree, read with `git fetch origin <branch>` and `git show origin/<branch>:<path>`.
3. For each new comment (thread replies included), decide:
   - `fix`: the claim holds. Say what to change and where.
   - `push back`: the claim is wrong or conflicts with a project rule or an agreed decision. Give the technical argument with file:line or doc path.
   - `answer`: a question, no code change.
   - `needs user`: a product call or a trade-off only the user can make.
   - `already done`: the current code or an uncommitted change already handles it.
   Mark conceptual or convention comments (a rule the reviewer will repeat on future PRs) with `conceptual`.
4. Write `<replies dir>/triage.md`. Write its prose in {{output_language}} and the reply drafts in {{comment_language}}. Keep the headings and labels exactly as below:

```
# PR #<n> — <title>: <k> new comments
## 1. <author> — path:line (link)
> short quote of the comment
Decision: fix | push back | answer | needs user | already done  [conceptual]
Why: …
Plan: what to change (for fix)
Reply draft:
> reply in the user's voice, short and concrete
```

Then run `"{{notify}}" "<your terminal>" "My PR" "PR <n>: the comment triage is ready"`, print a 3–5 line summary and the path to `triage.md`, and wait for the user.

## 2. On the user's commands
The user may phrase a command in any language; act on its meaning.
- "{{cmd_fix}}" (all or listed items): work in the branch's local worktree. Without one, create `<worktrees dir>/<branch>` (from the task) in the main checkout from `origin/<branch>`, the way the repo's instructions say. Write a failing test first where the repo has tests, and run the repo's checks on the changed files. Do not commit until the user says "{{cmd_commit}}". Repo notes:

{{repos_fix}}

- "{{cmd_commit}}": commit the fixes and push in the same step, with the repo's commit message convention. Commit only the files of the fixes, never unrelated changes in the worktree. Run `git push` right after the commit. NEVER leave a local-only commit. NEVER force-push. If the push fails (a rejected non-fast-forward, a hook), stop and show the error to the user. Print the commit hash and the PR URL.
- "{{cmd_reply}}" (all or listed items): post the reply drafts the user kept. Line threads: `gh api repos/<repo>/pulls/<n>/comments/<comment id>/replies -f body=...`. Top-level comments and reviews: `gh pr comment <n> --repo <repo> --body ...`. Print the links.
- "{{cmd_recheck}}": fetch comments newer than the ones in `triage.md` with the same `gh api` endpoints and triage them the same way. Append them to `triage.md`.

{{replies_notes}}
