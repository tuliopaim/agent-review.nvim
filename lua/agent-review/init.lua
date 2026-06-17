local M = {}

local did_save = false

local state = {
  ns = vim.api.nvim_create_namespace("review"),
  root = nil,
  json_path = nil,
  scope = nil,
  diffview_args = {},
  attached_buffers = {},
  comments = {},
  hidden_comments = {},
  created_at = nil,
  active = false,
}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "review" })
end

local function force_redraw()
  pcall(vim.cmd, "mode")
  pcall(vim.cmd, "redraw!")
end

local function iso_now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function json_read(path)
  if not path or vim.fn.filereadable(path) ~= 1 then return nil end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return nil end
  local ok_decode, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if ok_decode and type(decoded) == "table" then return decoded end
  return nil
end

local function write_file(path, text)
  if not path or path == "" then error("write_file: path is nil or empty") end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ret = vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
  if ret ~= 0 then error("write_file failed for " .. path) end
end

local function git_repo_root()
  local cwd = vim.fn.getcwd()
  local out = vim.fn.system({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 then return nil end
  return (out:gsub("\n$", ""))
end

local function add_to_git_info_exclude(repo_root)
  local exclude = repo_root .. "/.git/info/exclude"
  if vim.fn.filereadable(exclude) ~= 1 then return false end
  local ok, content = pcall(vim.fn.readfile, exclude)
  if not ok then return false end
  for _, line in ipairs(content) do
    if line == ".review/" then return false end
  end
  table.insert(content, ".review/")
  local ok2 = pcall(vim.fn.writefile, content, exclude)
  return ok2
end

local function canonical_line(comment)
  if comment.line then return comment.line end
  if comment.side == "old" then return comment.oldLine end
  if comment.side == "new" then return comment.newLine end
  return comment.newLine or comment.oldLine
end

local function comment_key(comment)
  return table.concat({ comment.file or "", comment.side or "", tostring(canonical_line(comment) or 0) }, ":")
end

local function comment_sort_key(comment)
  return string.format("%s:%09d", comment.file or "", comment.line or comment.newLine or comment.oldLine or 0)
end

local function sorted_comments(opts)
  opts = opts or {}
  local out = {}
  for _, comment in pairs(state.comments) do
    if opts.include_resolved or not comment.resolved then table.insert(out, comment) end
  end
  table.sort(out, function(a, b) return comment_sort_key(a) < comment_sort_key(b) end)
  return out
end

local function buf_under_root(name)
  return state.root and name ~= "" and name:sub(1, #state.root + 1) == state.root .. "/"
end

local function diffview_file_from_buf(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if buf_under_root(name) then
    return name:sub(#state.root + 2)
  end
  return name:match("[ab]/(.+)$") or name:match("::(.+)$") or name:match("/(.+)$")
end

local function diffview_side_from_buf(bufnr)
  local winbar = vim.wo.winbar or ""
  local name = vim.api.nvim_buf_get_name(bufnr)
  if buf_under_root(name) or winbar:match("WORKING TREE") then
    return "new"
  end
  return "old"
end

local function current_anchor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local bufnr = vim.api.nvim_get_current_buf()
  local file = diffview_file_from_buf(bufnr)
  if not file or file == "" then return lnum, nil end
  local code = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local side = diffview_side_from_buf(bufnr)
  return lnum, { file = file, side = side, line = lnum, kind = "diffview", code = code, bufnr = bufnr }
end

-- Selection line range, read while still in visual mode ('v' = start, '.' = cursor).
local function visual_range()
  local s, e = vim.fn.getpos("v")[2], vim.fn.getpos(".")[2]
  if s > e then s, e = e, s end
  return s, e
end

local function range_anchor(bufnr, start_line, end_line)
  if start_line > end_line then start_line, end_line = end_line, start_line end
  local file = diffview_file_from_buf(bufnr)
  if not file or file == "" then return nil end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  return {
    file = file,
    side = diffview_side_from_buf(bufnr),
    line = start_line,
    endLine = end_line > start_line and end_line or nil,
    code = lines[1] or "",
    endCode = end_line > start_line and (lines[#lines] or "") or nil,
    kind = "diffview",
    bufnr = bufnr,
  }
end

-- Find the unresolved comment whose [line, endLine] range covers lnum in bufnr.
local function comment_covering(bufnr, lnum)
  for key, c in pairs(state.comments) do
    if c.bufnr == bufnr and c.line then
      local last = c.endLine or c.line
      if lnum >= c.line and lnum <= last then return key, c end
    end
  end
end

local function comment_from_anchor(anchor, body)
  return {
    file = anchor.file,
    side = anchor.side,
    line = anchor.line,
    endLine = anchor.endLine,
    code = anchor.code,
    endCode = anchor.endCode,
    bufnr = anchor.bufnr,
    resolved = false,
    body = body,
  }
end

local function render()
  for bufnr in pairs(state.attached_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, state.ns, 0, -1)
    end
  end
  local current_buf = vim.api.nvim_get_current_buf()
  if not state.attached_buffers[current_buf] and vim.api.nvim_buf_is_valid(current_buf) then
    vim.api.nvim_buf_clear_namespace(current_buf, state.ns, 0, -1)
  end
  for _, comment in pairs(state.comments) do
    if not comment.resolved then
      local bufnr = comment.bufnr
      local lnum = comment.line
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) and lnum then
        local line_count = vim.api.nvim_buf_line_count(bufnr)
        if lnum >= 1 and lnum <= line_count then
          local last = math.min(comment.endLine or lnum, line_count)
          -- Shade every line of a multi-line range.
          if last > lnum then
            for l = lnum, last do
              pcall(vim.api.nvim_buf_set_extmark, bufnr, state.ns, l - 1, 0, {
                line_hl_group = "ReviewRange",
              })
            end
          end
          local body_lines = vim.split(comment.body or "", "\n", { plain = true })
          local virt = {}
          for i, body_line in ipairs(body_lines) do
            local prefix = i == 1 and "  💬 " or "     "
            table.insert(virt, { { prefix .. body_line, "Comment" } })
          end
          local hint = last > lnum and string.format("     [lines %d-%d] [resolve: <leader>rx]", lnum, last)
            or "     [resolve: <leader>rx]"
          table.insert(virt, { { hint, "Comment" } })
          -- Anchor the bubble below the last line of the range.
          pcall(vim.api.nvim_buf_set_extmark, bufnr, state.ns, last - 1, 0, {
            virt_lines = virt,
            virt_lines_above = false,
          })
        end
      end
    end
  end
end

local function load_comments()
  state.comments = {}
  state.hidden_comments = {}
  local data = json_read(state.json_path)
  state.created_at = (data and data.createdAt) or iso_now()
  if not data or type(data.comments) ~= "table" then return end
  for _, comment in ipairs(data.comments) do
    if comment.resolved then
      state.hidden_comments[comment_key(comment)] = comment
    elseif comment.file and (comment.line or comment.newLine or comment.oldLine) then
      comment.line = comment.line or comment.newLine or comment.oldLine
      state.comments[comment_key(comment)] = comment
    end
  end
end

local function serializable_comments()
  local out_by_key = {}
  for key, c in pairs(state.hidden_comments) do out_by_key[key] = c end
  for key, c in pairs(state.comments) do out_by_key[key] = c end
  local out = {}
  for _, c in pairs(out_by_key) do
    local copy = vim.deepcopy(c)
    copy.bufnr = nil
    copy.id = nil -- derived from file:side:line, never read back
    copy.updatedAt = nil -- per-comment edit time is noise for consumers
    table.insert(out, copy)
  end
  table.sort(out, function(a, b) return comment_sort_key(a) < comment_sort_key(b) end)
  return out
end

local function save(opts)
  opts = opts or {}
  if not state.json_path then return end
  local doc = {
    scope = state.scope or "working tree",
    createdAt = state.created_at or iso_now(),
    updatedAt = iso_now(),
    comments = serializable_comments(),
  }
  write_file(state.json_path, vim.json.encode(doc))
  did_save = true
  if not opts.silent then
    notify("Saved review to " .. state.json_path)
  end
end

local function setup_autosave_autocmd()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("review_autosave", { clear = true }),
    callback = function()
      if state.json_path and not did_save then save({ silent = true }) end
    end,
  })
end

local function edit_multiline(default, done)
  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.min(90, math.max(40, vim.o.columns - 10))
  local height = math.min(16, math.max(5, vim.o.lines - 8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Review comment (save: <C-s>, cancel: q) ",
  })
  vim.bo[buf].filetype = "markdown"
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:Visual"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(default or "", "\n", { plain = true }))
  local function close_with(value)
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    done(value)
  end
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    close_with(table.concat(lines, "\n"):gsub("%s+$", ""))
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", function() close_with(nil) end, { buffer = buf, silent = true })
  vim.cmd("startinsert")
end

-- Open the editor for `anchor`, then upsert/remove the comment under `key`.
local function edit_comment_for(anchor, key)
  local existing = state.comments[key] or state.hidden_comments[key]
  edit_multiline(existing and existing.body or "", function(input)
    if input == nil then return end
    if input == "" then
      state.comments[key] = nil
      state.hidden_comments[key] = nil
    else
      local updated = vim.tbl_extend("force", existing or {}, comment_from_anchor(anchor, input))
      updated.body = input
      updated.resolved = existing and existing.resolved or false
      updated.bufnr = anchor.bufnr
      state.hidden_comments[key] = nil
      state.comments[key] = updated
    end
    render()
    save({ silent = true })
  end)
end

local function add_or_edit_comment()
  local lnum, anchor = current_anchor()
  if not anchor then
    notify("Not a commentable diff body line", vim.log.levels.WARN)
    return
  end
  -- If the cursor sits inside an existing range comment, edit that comment.
  local covering_key, covering = comment_covering(anchor.bufnr, lnum)
  if covering and comment_key(anchor) ~= covering_key then
    edit_comment_for(covering, covering_key)
    return
  end
  edit_comment_for(anchor, comment_key(anchor))
end

local function add_or_edit_range_comment(start_line, end_line)
  local bufnr = vim.api.nvim_get_current_buf()
  local anchor = range_anchor(bufnr, start_line, end_line)
  if not anchor then
    notify("Not a commentable diff body line", vim.log.levels.WARN)
    return
  end
  anchor.bufnr = bufnr
  edit_comment_for(anchor, comment_key(anchor))
end

local function delete_comment()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local _, anchor = current_anchor()
  local key = anchor and comment_key(anchor) or tostring(lnum)
  if not (state.comments[key] or state.hidden_comments[key]) then
    key = comment_covering(vim.api.nvim_get_current_buf(), lnum) or key
  end
  if state.comments[key] or state.hidden_comments[key] then
    state.comments[key] = nil
    state.hidden_comments[key] = nil
    render()
    save({ silent = true })
    notify("Deleted comment")
  else
    notify("No comment on this line", vim.log.levels.WARN)
  end
end

local function toggle_resolved()
  local lnum, anchor = current_anchor()
  local key = anchor and comment_key(anchor) or tostring(lnum)
  if not state.comments[key] then
    key = comment_covering(vim.api.nvim_get_current_buf(), lnum) or key
  end
  local comment = state.comments[key]
  if not comment then
    notify("No comment on this line", vim.log.levels.WARN)
    return
  end
  comment.resolved = not comment.resolved
  if comment.resolved then
    state.comments[key] = nil
    state.hidden_comments[key] = comment
  else
    state.hidden_comments[key] = nil
    state.comments[key] = comment
  end
  render()
  save({ silent = true })
  notify(comment.resolved and "Marked comment resolved" or "Marked comment unresolved")
end

local function jump_comment(direction)
  local current_buf = vim.api.nvim_get_current_buf()
  local targetable = {}
  for _, c in ipairs(sorted_comments()) do
    if c.line and c.bufnr == current_buf then table.insert(targetable, c) end
  end
  if #targetable == 0 then
    notify("No comments in current buffer", vim.log.levels.WARN)
    return
  end
  local current = vim.api.nvim_win_get_cursor(0)[1]
  local target = nil
  if direction > 0 then
    for _, c in ipairs(targetable) do if c.line > current then target = c; break end end
    target = target or targetable[1]
  else
    for i = #targetable, 1, -1 do if targetable[i].line < current then target = targetable[i]; break end end
    target = target or targetable[#targetable]
  end
  vim.api.nvim_win_set_cursor(0, { target.line, 0 })
end

local function clear_rendered_comments()
  for bufnr in pairs(state.attached_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, state.ns, 0, -1)
    end
  end
end

function M.delete()
  if not state.active and not state.json_path then
    notify("No review to delete", vim.log.levels.WARN)
    return
  end
  local choice = vim.fn.confirm("Completely delete this review and its saved comments?", "&Cancel\n&Delete", 1)
  if choice ~= 2 then return end

  local json_path = state.json_path
  if json_path and vim.fn.filereadable(json_path) == 1 then
    local ok = pcall(vim.fn.delete, json_path)
    if not ok then
      notify("Failed to delete " .. json_path, vim.log.levels.ERROR)
      return
    end
  end
  -- Remove the .review/ directory if it is now empty.
  local dir = json_path and vim.fn.fnamemodify(json_path, ":h")
  if dir and vim.fn.isdirectory(dir) == 1 then
    local entries = vim.fn.readdir(dir)
    if type(entries) == "table" and #entries == 0 then
      pcall(vim.fn.delete, dir, "d")
    end
  end

  clear_rendered_comments()
  state.comments = {}
  state.hidden_comments = {}
  state.attached_buffers = {}
  state.json_path = nil
  state.created_at = nil
  state.active = false
  did_save = true
  force_redraw()
  notify("Review deleted")
end

local function reset_review()
  local choice = vim.fn.confirm("Restart review and delete all saved comments?", "&Cancel\n&Restart", 1)
  if choice ~= 2 then return end
  state.comments = {}
  state.hidden_comments = {}
  render()
  save({ silent = true })
  load_comments()
  render()
  local remaining = 0
  for _ in pairs(state.comments) do remaining = remaining + 1 end
  for _ in pairs(state.hidden_comments) do remaining = remaining + 1 end
  if remaining > 0 then
    notify("Reset saved but comments re-appeared from disk", vim.log.levels.WARN)
  else
    notify("Restarted review; all comments cleared")
  end
end

local function map_review_keys(bufnr)
  local opts = { buffer = bufnr, silent = true, noremap = true }
  vim.keymap.set("n", "<leader>rc", add_or_edit_comment, vim.tbl_extend("force", opts, { desc = "Add/edit review comment" }))
  vim.keymap.set("x", "<leader>rc", function()
    local s, e = visual_range()
    vim.cmd("normal! \27") -- leave visual mode
    M.comment({ line1 = s, line2 = e })
  end, vim.tbl_extend("force", opts, { desc = "Add/edit review comment on selection" }))
  vim.keymap.set("n", "<leader>rd", delete_comment, vim.tbl_extend("force", opts, { desc = "Delete review comment" }))
  vim.keymap.set("n", "<leader>rx", toggle_resolved, vim.tbl_extend("force", opts, { desc = "Toggle review comment resolved" }))
  vim.keymap.set("n", "<leader>rs", save, vim.tbl_extend("force", opts, { desc = "Save review" }))
  vim.keymap.set("n", "<leader>rq", function()
    save()
    pcall(vim.cmd, "DiffviewClose")
    vim.cmd("qa")
  end, vim.tbl_extend("force", opts, { desc = "Save review and quit" }))
  vim.keymap.set("n", "<leader>rn", function() jump_comment(1) end, vim.tbl_extend("force", opts, { desc = "Next review comment" }))
  vim.keymap.set("n", "<leader>rp", function() jump_comment(-1) end, vim.tbl_extend("force", opts, { desc = "Previous review comment" }))
  vim.keymap.set("n", "<leader>rR", reset_review, vim.tbl_extend("force", opts, { desc = "Restart review (clear comments)" }))
  vim.keymap.set("n", "<leader>rD", function() M.delete() end, vim.tbl_extend("force", opts, { desc = "Delete review (remove from disk)" }))
  vim.keymap.set("n", "<leader>rr", function() M.refresh() end, vim.tbl_extend("force", opts, { desc = "Refresh review" }))
end

local function attach_diffview_buffer(bufnr)
  state.attached_buffers[bufnr] = true
  vim.wo.number = true
  vim.wo.cursorline = true
  vim.wo.cursorcolumn = false
  map_review_keys(bufnr)
  local file = diffview_file_from_buf(bufnr)
  local side = diffview_side_from_buf(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, c in pairs(state.comments) do
    if c.file == file and c.side == side and c.line and c.line >= 1 and c.line <= line_count then
      c.bufnr = bufnr
    elseif c.bufnr == bufnr then
      c.bufnr = nil
    end
  end
  render()
end

local function setup_autocmds()
  local group = vim.api.nvim_create_augroup("review_diffview", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "DiffviewDiffBufRead", "DiffviewDiffBufWinEnter" },
    callback = function() attach_diffview_buffer(vim.api.nvim_get_current_buf()) end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewViewClosed",
    callback = function() save({ silent = true }) end,
  })
  vim.api.nvim_create_autocmd({ "FocusGained", "VimResized", "WinEnter", "TabEnter" }, {
    group = group,
    callback = function() vim.schedule(force_redraw) end,
  })
end

local function open_diffview()
  if vim.fn.exists(":DiffviewOpen") == 0 then
    pcall(function() require("lazy").load({ plugins = { "diffview.nvim" } }) end)
  end
  if vim.fn.exists(":DiffviewOpen") == 0 then
    notify("DiffviewOpen unavailable; install diffview.nvim", vim.log.levels.ERROR)
    return false
  end
  local cmd = "DiffviewOpen"
  if #state.diffview_args > 0 then
    cmd = cmd .. " " .. table.concat(vim.tbl_map(vim.fn.fnameescape, state.diffview_args), " ")
  end
  vim.cmd(cmd)
  return true
end

local function bootstrap(args)
  args = args or {}
  local root = git_repo_root()
  if not root then
    notify("Not inside a git repo", vim.log.levels.ERROR)
    return false
  end
  state.root = root
  state.json_path = root .. "/.review/comments.json"
  state.diffview_args = args
  state.scope = #args > 0 and table.concat(args, " ") or "working tree"
  state.attached_buffers = {}
  state.comments = {}
  state.hidden_comments = {}
  did_save = false

  if add_to_git_info_exclude(root) then
    notify("Added .review/ to .git/info/exclude")
  end

  load_comments()
  setup_autocmds()
  setup_autosave_autocmd()
  state.active = true
  return true
end

function M.start(args)
  if state.active then
    M.refresh()
    return
  end
  if not bootstrap(args) then return end
  if not open_diffview() then
    state.active = false
    return
  end
  save({ silent = true })
  notify("Review ready: <leader>rc edit, <leader>rd delete, <leader>rx resolve, <leader>rq save+quit")
end

function M.comment(range)
  if not state.active and not bootstrap({}) then return end
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not buf_under_root(name) then
    notify("Buffer is not a file inside " .. (state.root or "the repo"), vim.log.levels.WARN)
    return
  end
  if not state.attached_buffers[bufnr] then
    attach_diffview_buffer(bufnr)
  end
  if range and range.line1 and range.line2 and range.line1 ~= range.line2 then
    add_or_edit_range_comment(range.line1, range.line2)
  else
    add_or_edit_comment()
  end
end

function M.refresh()
  if not state.active or not state.json_path then
    notify("No active review", vim.log.levels.WARN)
    return
  end

  load_comments()

  for bufnr in pairs(state.attached_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      attach_diffview_buffer(bufnr)
    else
      state.attached_buffers[bufnr] = nil
    end
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(current_buf)
  if buf_under_root(name) and not state.attached_buffers[current_buf] then
    attach_diffview_buffer(current_buf)
  end

  render()
  force_redraw()
  notify("Review refreshed")
end

-- Reserved for future options (keymap prefix, json path, ...). No behavior yet.
function M.setup(_)
  vim.api.nvim_set_hl(0, "ReviewRange", { link = "CursorLine", default = true })

  vim.api.nvim_create_user_command("ReviewDiff", function(opts)
    M.start(opts.fargs)
  end, { nargs = "*", desc = "Open Diffview review UI" })

  vim.api.nvim_create_user_command("ReviewComment", function(opts)
    if opts.range > 0 then
      M.comment({ line1 = opts.line1, line2 = opts.line2 })
    else
      M.comment()
    end
  end, { range = true, desc = "Add/edit review comment on current line or selection" })

  vim.api.nvim_create_user_command("ReviewRefresh", function()
    M.refresh()
  end, { desc = "Refresh review" })

  vim.api.nvim_create_user_command("ReviewDelete", function()
    M.delete()
  end, { desc = "Completely delete review and saved comments" })
end

return M
