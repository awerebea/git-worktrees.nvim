---Thin seam over the picker and window backend.
---
---Every call this plugin makes into snacks.nvim goes through here, so the backend is
---named in one place instead of being reached for as a global from two other files.
---Three things follow from that: the dependency is documented by this file's contents,
---a missing backend produces a message rather than an index-nil error, and a test can
---substitute this module instead of a global.
---
---This is deliberately not a general picker abstraction. It exposes only what the
---plugin uses, in the shape the plugin wants, and it encapsulates the details the
---backend happens to require - the split between the picker's input and list windows,
---the popup geometry, the auto-close timers. A second backend would have to satisfy
---`pick` (arbitrary items, per-row highlight chunks, the keys bound in both insert and
---normal mode, an action that can close the picker, an initial query) and `popup`;
---everything else here is trivially portable.

local M = {}

---Resolve the backend.
---Looked up per call rather than at require time, so loading this module never forces
---the picker to load, and so the error surfaces when a picker is opened rather than at
---startup.
---@return table
local function backend()
  if not _G.Snacks then
    error(
      "git-worktrees: snacks.nvim is not loaded.\n"
        .. "Install https://github.com/folke/snacks.nvim - it needs no configuration.\n"
        .. "If you load it lazily, list it in this plugin's dependencies so it loads first.",
      0
    )
  end
  return _G.Snacks
end

---Pad or truncate `str` to `width` display cells.
---@param str string
---@param width integer
---@param opts? { truncate?: boolean }
---@return string
function M.align(str, width, opts)
  return backend().picker.util.align(str, width, opts)
end

---@class GitWorktrees.ui.PickOpts
---@field title string Shown in the picker border.
---@field items GitWorktrees.Item[]
---@field pattern? string Initial query, used to carry it across a branch-type cycle.
---@field format fun(item: GitWorktrees.Item, picker: table): table[] Highlight chunks.
---@field actions table<string, fun(picker: table, item: GitWorktrees.Item)>
---@field confirm string Name of the action `<CR>` runs.
---@field keys table<string, string> Key -> action name.

---Open the list picker.
---
---`keys` is a flat map because every binding this plugin has behaves the same way. The
---backend wants them per window and per mode: the input window takes insert and normal,
---the list window only normal, since there is no insert mode there. Expanding that here
---keeps the two callers from repeating each binding four times.
---@param opts GitWorktrees.ui.PickOpts
function M.pick(opts)
  local input_keys, list_keys = {}, {}
  for lhs, action in pairs(opts.keys) do
    input_keys[lhs] = { action, mode = { "i", "n" } }
    list_keys[lhs] = { action, mode = { "n" } }
  end

  backend().picker.pick({
    title = opts.title,
    items = opts.items,
    layout = { preview = false },
    pattern = opts.pattern,
    format = opts.format,
    actions = opts.actions,
    confirm = opts.confirm,
    win = {
      input = { keys = input_keys },
      list = { keys = list_keys },
    },
  })
end

---Return the query currently typed into an open picker.
---Reaches into the backend's picker object, so it lives here rather than at the call site.
---@param picker table
---@return string
function M.query(picker)
  return (picker and picker.input and picker.input.filter and picker.input.filter.pattern) or ""
end

---Open a file browser rooted at `dir`.
---Used as the fallback when a buffer has no counterpart in the worktree being entered.
---@param dir string
function M.browse_files(dir)
  backend().picker.files({ cwd = dir })
end

---@class GitWorktrees.ui.PopupOpts
---@field text string[] Lines to display.
---@field title? string Shown in the border when set.
---@field width integer Text width, excluding the border.
---@field height integer Rows, excluding the border.

---Open a read-only popup in the top-right corner, positioned like a notification.
---Returns the backend's window object, which answers `win_valid()` and `close()`, and
---`redraw()` for the case where a blocking prompt follows immediately.
---@param opts GitWorktrees.ui.PopupOpts
---@return table
function M.popup(opts)
  -- Leave room for the tabline when one is showing, so the popup does not cover it.
  local has_tabline = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and vim.fn.tabpagenr("$") > 1)
  return backend().win({
    text = opts.text,
    title = opts.title,
    title_pos = opts.title and "left" or nil,
    relative = "editor",
    position = "float",
    -- wrap so long lines are visible rather than truncated; callers size height with
    -- that in mind.
    wo = { wrap = true },
    width = opts.width,
    height = opts.height,
    row = has_tabline and 1 or 0,
    col = -1,
    -- Above the picker (~52) and the snacks notifier (100).
    zindex = 300,
    enter = false,
    border = "rounded",
    noautocmd = true,
    backdrop = false,
    keys = { q = "close" },
  })
end

---Close `win` after `timeout` ms. A nil or non-positive timeout leaves it open until
---dismissed, which is what the 0 defaults in the config mean.
---@param win table
---@param timeout? integer
function M.close_after(win, timeout)
  if not timeout or timeout <= 0 then
    return
  end
  vim.defer_fn(function()
    if win:win_valid() then
      win:close()
    end
  end, timeout)
end

return M
