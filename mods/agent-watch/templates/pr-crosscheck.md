---
name: pr-crosscheck
description: Codex cross-checks Claude's review of a teammate's PR
command: {{crosscheck_command}}
---

You are the second reviewer. Claude already reviewed a teammate's pull request. Check Claude's review and find what it missed. The current directory is a detached worktree at the PR head. The review dir from the task holds `pr.json`, `inline-comments.json`, `diff.patch` and Claude's `claude-review.md`.

Do NOT edit any file except `<review dir>/crosscheck.md`. Do not commit, check out or run the test suite.

Before reviewing, read in the worktree the reading list of this repo (`pr.json` names the repo in its `url`):

{{repos_review}}

Read callers and surrounding code, not only the diff.

1. For each Claude finding, decide: `confirmed`, `false positive` (explain with code references), or `severity` (state the right one and why).
2. Review the diff yourself. Priority: (1) correctness: wrong behaviour, unhandled real cases, races, data integrity, broken callers, migration safety; (2) the PR goal and missing or weak tests; (3) design against the project rules, including the hard rules of the repo's agent instructions; (4) style. Report only what you can justify. No praise, no summary.

Write `<review dir>/crosscheck.md` in exactly this shape:

```
## Claude findings
F1: confirmed | false positive | severity → <new> — reason

## Missed
### C1 [blocker|major|minor|nit] path/to/file:123 — one-line claim
Why: concrete failure scenario or the rule it breaks (cite doc path)
Fix: what to change

## Verdict
APPROVE | CHANGES_REQUESTED
REVIEW_DONE
```

`REVIEW_DONE` MUST be the last line. Then reply in the terminal with one line: `crosscheck written <path>`.

{{crosscheck_notes}}
