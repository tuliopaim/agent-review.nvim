---
name: review-comments
description: >
  Process code review comments left in `.review/comments.json` by the
  agent-review.nvim plugin. Triggered when the user says "process my
  review comments", "address review comments", "/review-comments", or any time
  the repo contains a `.review/comments.json` with unresolved entries.
---

# Review

The user reviews agent-produced code in Neovim (agent-review.nvim, Diffview optional) and saves inline comments to `<repo>/.review/comments.json`. Each entry has `file`, `side` (`new` or `old`), `line`, `code` (the line's text at comment time), `body`, and `resolved`. Range comments also carry `endLine` and `endCode` and cover `line`..`endLine`. Your job is to go through the unresolved ones.

## Your job

Read `<repo>/.review/comments.json` and walk through every entry where `resolved` is `false`.

For each unresolved comment, use your judgment:

- If the comment clearly asks for a specific fix, implement it.
- If it's a question, suggestion, or feels ambiguous, discuss it with the user before changing anything.
- If you disagree or see a better approach, say so and explain why.
- If a comment is now obsolete (code changed, file moved), remove it from the JSON array.
- After you address a comment — by fixing it or resolving the discussion — set its `resolved` to `true`.
- Preserve `file`, `side`, `line`, `endLine`, and other metadata for comments that remain unresolved.

Start by summarizing your read of each comment — fix, discuss, or obsolete — then proceed.

## Notes

- Side `new` is a line in the working tree; `old` is a line in the base revision (read it with `git show`).
- **Line drift:** `line`/`endLine` are anchors from save time and may have moved if the user edited afterwards. Treat them as hints. Compare `code` to the current text at `file:line` (and `endCode` at `endLine` for ranges) — if they don't match, search a few lines above and below for the matching `code` and use that location. Only consider a comment obsolete when `code` is nowhere nearby.
- Range comments apply to the whole `line`..`endLine` span, not just the first line.
- The repo's `.review/` directory is git-ignored via `.git/info/exclude`, so JSON edits don't show in `git status`.
- If `.review/comments.json` doesn't exist, tell the user there's nothing to review — they probably haven't run `:ReviewDiff` or left any comments.
