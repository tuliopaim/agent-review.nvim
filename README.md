# agent-review.nvim

Lightweight, in-editor code review for Neovim — leave inline comments on any file
in a repo, then hand them off to a coding agent (Pi, Claude Code, Codex, …) to act on.

Comments are written to `<repo>/.review/comments.json`. From an agent you then say
*"process my review comments"* and it walks through every unresolved entry.

Built on top of [diffview.nvim](https://github.com/sindrets/diffview.nvim) for reviewing
diffs, but Diffview is optional — `<leader>rc` works in **any** buffer whose file lives
under the repo root.

## Why

Agents produce a lot of code. Reviewing it in a web UI and copy-pasting feedback is slow.
This keeps the whole loop in the editor: open the diff, drop inline comments where you
want changes, save, and let the agent pick them up from a plain JSON file under the repo.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "tuliopaim/agent-review.nvim",
  dependencies = { "sindrets/diffview.nvim" }, -- optional
  cmd = { "ReviewDiff", "ReviewComment", "ReviewRefresh" },
  keys = {
    { "<leader>rR", function() require("agent-review").start({}) end, desc = "Open Diffview review" },
    { "<leader>rr", function() require("agent-review").refresh() end, desc = "Refresh review" },
    { "<leader>rc", function() require("agent-review").comment() end, desc = "Add review comment on current line" },
    { "<leader>rc", mode = "x", "<cmd>'<,'>ReviewComment<cr>", desc = "Add review comment on selection" },
  },
  config = function()
    require("agent-review").setup()
  end,
}
```

Developing locally (no GitHub remote needed):

```lua
{
  dir = "~/dev/personal/agent-review.nvim",
  name = "agent-review",
  -- ...same as above
}
```

## Usage

1. Start a review:
   - `:ReviewDiff` (or `<leader>rR`) — opens Diffview for the working tree. Accepts
     Diffview args, e.g. `:ReviewDiff origin/main...HEAD`.
   - `<leader>rc` in any normal buffer under the repo — bootstraps a session and opens the
     comment dialog on the current line, no Diffview needed.
2. Leave inline comments — on the current line, or **visually select a span of
   lines** and press `<leader>rc` (or `:'<,'>ReviewComment`) to comment on the
   whole range. In the comment popup, save with `<C-s>`, cancel with `q`.
3. Save / quit with `<leader>rq`. Comments persist to `<repo>/.review/comments.json`
   (auto-added to `.git/info/exclude`, so they never show in `git status`).
4. In any agent, say *"process my review comments"* — it reads the JSON and addresses
   each unresolved entry, flipping `resolved` to `true` as it goes.

### Commands

| Command          | Description                                  |
| ---------------- | -------------------------------------------- |
| `:ReviewDiff`    | Open the Diffview review UI (accepts args)   |
| `:ReviewComment` | Add/edit a comment on the current line (or selected range with `:'<,'>ReviewComment`) |
| `:ReviewRefresh` | Reload comments from disk and re-render       |
| `:ReviewDelete`  | Completely delete the review and saved comments |

### Keymaps

`<leader>rc` works globally in any buffer whose file is under the repo root, and inside
Diffview review buffers. The rest become available once a buffer is attached (Diffview
opens, or `<leader>rc` is pressed in a regular buffer):

| Key          | Action                                         |
| ------------ | ---------------------------------------------- |
| `<leader>rc` | Add / edit review comment on the current line (or visual selection) |
| `<leader>rd` | Delete review comment                          |
| `<leader>rx` | Toggle comment resolved                        |
| `<leader>rs` | Save review                                    |
| `<leader>rq` | Save review and quit                           |
| `<leader>rn` | Jump to next comment in buffer                 |
| `<leader>rp` | Jump to previous comment in buffer             |
| `<leader>rr` | Refresh review                                 |
| `<leader>rR` | Restart review (clear comments)                |
| `<leader>rD` | Delete review (remove from disk)               |

## Data format

`<repo>/.review/comments.json`:

```json
{
  "version": 2,
  "repo": "/abs/path/to/repo",
  "scope": "working tree",
  "createdAt": "2026-06-16T00:00:00Z",
  "updatedAt": "2026-06-16T00:00:00Z",
  "comments": [
    {
      "file": "src/foo.lua",
      "side": "new",
      "line": 42,
      "endLine": 50,
      "code": "local x = 1",
      "endCode": "end",
      "body": "rename this",
      "resolved": false
    }
  ]
}
```

- `side` is `new` (working tree) or `old` (base revision).
- `code` is the line's text at comment time — used to re-anchor a comment if the file
  drifted after the comment was left.
- `endLine` / `endCode` are present only for multi-line (range) comments; the comment
  covers `line`..`endLine`. Single-line comments omit them.

## How an agent should process comments

Point the agent at `<repo>/.review/comments.json`. For each entry with
`"resolved": false`:

1. `file` is repo-relative; `body` is the feedback to act on.
2. Treat `line`/`endLine` as **hints, not ground truth** — the file may have drifted
   since the comment was written. Use `code` (and `endCode` for ranges), which hold the
   exact line text at comment time, to re-locate the right spot before editing.
3. `side: "new"` refers to the working-tree file on disk; `side: "old"` refers to the
   **base revision** — read it with `git show <base>:<file>` rather than the current
   file. Resolve `<base>` from the top-level `scope`: `"working tree"` → `HEAD`; a
   diffview range like `"origin/main...HEAD"` → its merge-base.
4. Skip entries where `"resolved": true`. After addressing a comment, set its `resolved`
   to `true` so it won't be processed again, leaving the other entries untouched.

A prompt like *"process my review comments"* is enough; the agent reads the JSON and
walks every unresolved entry, flipping `resolved` as it goes.

### Agent skill

A ready-made skill describing this workflow ships in
[`skills/review-comments/`](skills/review-comments/SKILL.md). Point your agent at it
(e.g. copy it where your agent loads skills/instructions from) and *"process my review
comments"* works out of the box.

## License

MIT
