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
  cmd = { "ReviewStart", "ReviewComment", "ReviewRefresh" },
  keys = {
    { "<leader>rR", function() require("agent-review").start({}) end, desc = "Open Diffview review" },
    { "<leader>rr", function() require("agent-review").refresh() end, desc = "Refresh review" },
    { "<leader>rc", function() require("agent-review").comment() end, desc = "Add review comment on current line" },
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
   - `:ReviewStart` (or `<leader>rR`) — opens Diffview for the working tree. Accepts
     Diffview args, e.g. `:ReviewStart origin/main...HEAD`.
   - `<leader>rc` in any normal buffer under the repo — bootstraps a session and opens the
     comment dialog on the current line, no Diffview needed.
2. Leave inline comments. In the comment popup, save with `<C-s>`, cancel with `q`.
3. Save / quit with `<leader>rq`. Comments persist to `<repo>/.review/comments.json`
   (auto-added to `.git/info/exclude`, so they never show in `git status`).
4. In any agent, say *"process my review comments"* — it reads the JSON and addresses
   each unresolved entry, flipping `resolved` to `true` as it goes.

### Commands

| Command          | Description                                  |
| ---------------- | -------------------------------------------- |
| `:ReviewStart`   | Open the Diffview review UI (accepts args)   |
| `:ReviewComment` | Add/edit a comment on the current line       |
| `:ReviewRefresh` | Reload comments from disk and re-render       |

### Keymaps

`<leader>rc` works globally in any buffer whose file is under the repo root, and inside
Diffview review buffers. The rest become available once a buffer is attached (Diffview
opens, or `<leader>rc` is pressed in a regular buffer):

| Key          | Action                                         |
| ------------ | ---------------------------------------------- |
| `<leader>rc` | Add / edit review comment on the current line  |
| `<leader>rd` | Delete review comment                          |
| `<leader>rx` | Toggle comment resolved                        |
| `<leader>rs` | Save review                                    |
| `<leader>rq` | Save review and quit                           |
| `<leader>rn` | Jump to next comment in buffer                 |
| `<leader>rp` | Jump to previous comment in buffer             |
| `<leader>rr` | Refresh review                                 |
| `<leader>rR` | Start / restart the Diffview review            |

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
      "code": "local x = 1",
      "body": "rename this",
      "resolved": false
    }
  ]
}
```

- `side` is `new` (working tree) or `old` (base revision).
- `code` is the line's text at comment time — used to re-anchor a comment if the file
  drifted after the comment was left.

## License

MIT
