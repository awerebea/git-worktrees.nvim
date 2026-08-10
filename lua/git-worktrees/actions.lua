---@class GitWorktrees.Snapshot
---@field wt_path string|nil
---@field display_path string
---@field branch string
---@field ref string
---@field is_remote boolean

local M = {}

---Return true when the editor's cwd is inside the worktree at `wt_path`.
---
---Used to refuse deleting the worktree currently in use. `item.is_current` cannot
---answer this: it only means the branch is the repo's HEAD, which is also true for
---the branch a bare repo's HEAD points at while the cwd is the bare directory
---itself, and false for a worktree with a detached HEAD.
---@param wt_path string Absolute path of the worktree to test.
---@return boolean
local function is_cwd_inside(wt_path)
  local cwd = vim.fn.getcwd():gsub("/$", "")
  local root = wt_path:gsub("/$", "")
  -- Compare on a component boundary so "/repo/wt" does not match "/repo/wt_other".
  return cwd == root or cwd:sub(1, #root + 1) == root .. "/"
end

---Return the root of the worktree the editor is leaving.
---
---The buffer swap maps a path relative to the old worktree root onto the new one, and
---`to_path` is always a root, so the outgoing side has to be a root too. The cwd is not
---necessarily one: with nvim started in `<wt>/src`, measuring from the cwd would map
---`<wt>/src/foo.lua` to `<new_wt>/foo.lua` and would treat every buffer outside `src`
---as living outside the worktree. Falls back to `cwd` when it has no working tree,
---e.g. a bare repository directory.
---@param cwd string
---@return string
local function worktree_root_of(cwd)
  local git = require("git-worktrees.git")
  return git.get_worktree_root(cwd) or cwd
end

---Number of screen rows `lines` occupy when soft-wrapped into `width` cells.
---The popups set `wrap = true`, so a window sized to the number of logical lines cuts
---off everything the wrapping pushes past the last row.
---@param lines string[]
---@param width integer Text width of the window, excluding the border.
---@return integer
local function wrapped_height(lines, width)
  if width < 1 then
    return #lines
  end
  local rows = 0
  for _, line in ipairs(lines) do
    rows = rows + math.max(1, math.ceil(vim.api.nvim_strwidth(line) / width))
  end
  return rows
end

---Wrapper around vim.notify that applies the plugin-configured notification timeout.
---Pass an explicit timeout (ms) to override the global notify_timeout for that call.
---@param msg string
---@param level integer vim.log.levels constant.
---@param timeout? integer|nil Override timeout in ms; nil falls back to notify_timeout config.
local function notify(msg, level, timeout)
  local config = require("git-worktrees").config
  local t = timeout ~= nil and timeout or config.notify_timeout
  vim.notify(msg, level, t ~= nil and { timeout = t } or nil)
end

---Invoke a lifecycle hook by name, forwarding all extra arguments.
---Returns the hook's return value so callers can react (e.g. before_switch
---returning false aborts the operation).
---@param name "before_switch"|"on_switch"|"on_add"|"on_delete"
---@param ... any Arguments forwarded to the hook function.
---@return any
local function run_hook(name, ...)
  local config = require("git-worktrees").config
  local hook = config.hooks and config.hooks[name]
  if type(hook) ~= "function" then
    return nil
  end
  local ok, result = pcall(hook, ...)
  if not ok then
    notify("git-worktrees: hook '" .. name .. "' error: " .. tostring(result), vim.log.levels.WARN)
    return nil
  end
  return result
end

---Open the file in `to_path` that corresponds to the currently open buffer in
---`from_path`, respecting the `swap_current_buffer` and `switch_file_command`
---config options. Falls back to a Snacks file picker when the equivalent file is
---absent, there is no current buffer, or the current buffer is outside `from_path`.
---
---When `cmd_override` is set (the `<C-e>`/`<C-s>`/`<C-v>`/`<C-t>` overrides), the
---open-or-fallback-to-picker behaviour always applies, ignoring `swap_current_buffer`
---and skipping the `"ask"` confirmation: pressing one of those keys is itself an
---explicit request to open something in the new worktree.
---@param from_path string Absolute path of the old worktree root.
---@param to_path string Absolute path of the new worktree root.
---@param cmd_override? string Vim command to use instead of `switch_file_command`.
local function swap_current_buffer(from_path, to_path, cmd_override)
  local config = require("git-worktrees").config
  local explicit = cmd_override ~= nil

  if not explicit and config.swap_current_buffer == false then
    return
  end

  local function open_picker()
    Snacks.picker.files({ cwd = to_path })
  end

  -- Used when there is a current file but it has no counterpart in the new
  -- worktree (as opposed to no current file at all, which needs no explanation).
  local function open_picker_no_match()
    notify("git-worktrees: no matching file in new worktree; browsing it instead", vim.log.levels.INFO)
    open_picker()
  end

  local cur_file = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  if cur_file == "" then
    if explicit then
      open_picker()
    end
    return
  end

  local from_norm = from_path:gsub("/$", "")
  -- Guard against prefix-only matches (e.g. "/repo" must not match "/repo_other/...").
  if cur_file ~= from_norm and cur_file:sub(1, #from_norm + 1) ~= from_norm .. "/" then
    if explicit then
      open_picker_no_match()
    end
    return
  end

  local rel = cur_file:sub(#from_norm + 2)
  local new_file = to_path:gsub("/$", "") .. "/" .. rel

  local function do_open()
    if vim.fn.filereadable(new_file) == 1 then
      local cmd = cmd_override or config.switch_file_command
      if cmd then
        vim.cmd(cmd .. " " .. vim.fn.fnameescape(new_file))
      end
    else
      open_picker_no_match()
    end
  end

  if explicit then
    do_open()
  elseif config.swap_current_buffer == true then
    do_open()
  elseif config.swap_current_buffer == "ask" then
    local choice = vim.fn.confirm("Open equivalent file in new worktree?\n" .. new_file, "&Yes\n&No", 1)
    if choice == 1 then
      do_open()
    end
  end
end

---Switch to an existing worktree or create a new one for the selected branch.
---@param picker snacks.Picker
---@param item GitWorktrees.Item
function M.worktree_switch(picker, item)
  ---@type GitWorktrees.Snapshot
  local snapshot = vim.deepcopy({
    wt_path = item.wt_path,
    display_path = item.display_path,
    branch = item.branch,
    ref = item.ref,
    is_remote = item.is_remote,
  })
  picker:close()
  vim.schedule(function()
    M._do_switch(snapshot, false)
  end)
end

---Like `worktree_switch` but always prompts for the path regardless of
---`auto_worktree_path`.
---@param picker snacks.Picker
---@param item GitWorktrees.Item
function M.worktree_switch_verbose(picker, item)
  ---@type GitWorktrees.Snapshot
  local snapshot = vim.deepcopy({
    wt_path = item.wt_path,
    display_path = item.display_path,
    branch = item.branch,
    ref = item.ref,
    is_remote = item.is_remote,
  })
  picker:close()
  vim.schedule(function()
    M._do_switch(snapshot, true)
  end)
end

---Switch and open the current file with `edit` (ignores `switch_file_command`).
---@param picker snacks.Picker
---@param item GitWorktrees.Item
function M.worktree_switch_edit(picker, item)
  local snapshot = vim.deepcopy({
    wt_path = item.wt_path,
    display_path = item.display_path,
    branch = item.branch,
    ref = item.ref,
    is_remote = item.is_remote,
  })
  picker:close()
  vim.schedule(function()
    M._do_switch(snapshot, false, "edit")
  end)
end

---Switch and open the current file in a new tab (ignores `switch_file_command`).
---@param picker snacks.Picker
---@param item GitWorktrees.Item
function M.worktree_switch_tabedit(picker, item)
  local snapshot = vim.deepcopy({
    wt_path = item.wt_path,
    display_path = item.display_path,
    branch = item.branch,
    ref = item.ref,
    is_remote = item.is_remote,
  })
  picker:close()
  vim.schedule(function()
    M._do_switch(snapshot, false, "tabedit")
  end)
end

---Switch and open the current file in a vertical split (ignores `switch_file_command`).
---@param picker snacks.Picker
---@param item GitWorktrees.Item
function M.worktree_switch_vsplit(picker, item)
  local snapshot = vim.deepcopy({
    wt_path = item.wt_path,
    display_path = item.display_path,
    branch = item.branch,
    ref = item.ref,
    is_remote = item.is_remote,
  })
  picker:close()
  vim.schedule(function()
    M._do_switch(snapshot, false, "vsplit")
  end)
end

---Switch and open the current file in a horizontal split (ignores `switch_file_command`).
---@param picker snacks.Picker
---@param item GitWorktrees.Item
function M.worktree_switch_split(picker, item)
  local snapshot = vim.deepcopy({
    wt_path = item.wt_path,
    display_path = item.display_path,
    branch = item.branch,
    ref = item.ref,
    is_remote = item.is_remote,
  })
  picker:close()
  vim.schedule(function()
    M._do_switch(snapshot, false, "split")
  end)
end

---Core switch implementation. If the item already has a worktree, cds into it.
---Otherwise delegates to `_create_worktree`.
---@param item GitWorktrees.Snapshot
---@param force_prompt boolean Always prompt for worktree path when true.
---@param cmd_override? string Override for the file-open command (e.g. "vsplit").
function M._do_switch(item, force_prompt, cmd_override)
  local from_path = vim.fn.getcwd()

  if item.wt_path then
    local to_path = item.wt_path
    if run_hook("before_switch", from_path, to_path) == false then
      return
    end
    vim.fn.chdir(to_path)
    vim.cmd("redrawstatus!")
    notify("Switched to worktree: " .. item.display_path, vim.log.levels.INFO)
    run_hook("on_switch", from_path, to_path)
    swap_current_buffer(worktree_root_of(from_path), to_path, cmd_override)
    return
  end

  M._create_worktree(item, force_prompt, function() end, cmd_override)
end

---Prompt for (or derive) a worktree path, run `git worktree add`, then switch.
---Calls on_done with the created worktree path on success, or nil on failure/cancellation.
---Callers that fork a branch first must handle the nil case in on_done (clean up orphans).
---@param item GitWorktrees.Snapshot
---@param force_prompt boolean
---@param on_done fun(wt_path: string|nil)
---@param cmd_override? string Override for the file-open command (e.g. "vsplit").
function M._create_worktree(item, force_prompt, on_done, cmd_override)
  local git = require("git-worktrees.git")
  local config = require("git-worktrees").config
  local fmt = require("git-worktrees.format")
  local cwd = vim.fn.getcwd()

  local wt_data = git.get_worktree_data(cwd)
  if not wt_data then
    notify("git-worktrees: not a git repo", vim.log.levels.ERROR)
    on_done(nil)
    return
  end

  local tmpl = wt_data.is_bare and config.wt_base_path_bare or config.wt_base_path_regular
  local base_path = git.expand_wt_base(tmpl, wt_data.git_common_dir, wt_data.git_root)

  local display_base = fmt.tilde_path(base_path)

  -- Remote branch: derive a local name by stripping the remote prefix.
  -- Slashes in the branch name (e.g. "feat/foo") are kept, so the default
  -- worktree path nests under <base_path> the same way the branch name does.
  local branch_name = item.branch
  if item.is_remote then
    branch_name = branch_name:match("[^/]+/(.+)") or branch_name
  end
  local branch_safe = branch_name

  local function _finish(wt_path)
    -- Simplify before doing anything with the path: a prompt entry such as "../foo"
    -- otherwise keeps its literal ".." segments, and since git resolves them when it
    -- reports worktree paths, the creation notice and the picker afterwards would
    -- disagree about where the worktree is.
    wt_path = vim.fn.simplify(wt_path)

    local from_path = vim.fn.getcwd()
    if run_hook("before_switch", from_path, wt_path) == false then
      on_done(nil)
      return
    end

    local ok, err = git.worktree_add(wt_path, branch_name, cwd)
    if not ok then
      notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
      on_done(nil)
      return
    end

    vim.fn.chdir(wt_path)
    vim.cmd("redrawstatus!")
    local display =
      fmt.format_path(wt_path, config.wt_path_display, wt_data.git_common_dir, base_path, wt_data.git_root)
    notify("Created worktree: " .. display .. " for '" .. branch_name .. "'", vim.log.levels.INFO)
    run_hook("on_add", branch_name, wt_path)
    run_hook("on_switch", from_path, wt_path)
    swap_current_buffer(worktree_root_of(from_path), wt_path, cmd_override)
    on_done(wt_path)
  end

  if config.auto_worktree_path and not force_prompt then
    _finish(base_path .. "/" .. branch_safe)
  else
    local prompt = "Worktree path (relative to " .. display_base .. " or absolute): "
    local win_width = math.min(vim.api.nvim_strwidth(prompt) + 4, math.floor(vim.o.columns * 0.9))
    vim.ui.input({ prompt = prompt, default = branch_safe, win = { width = win_width } }, function(input)
      if input == nil or input == "" then
        notify("git-worktrees: cancelled", vim.log.levels.WARN)
        on_done(nil)
        return
      end
      local wt_path
      if input:sub(1, 1) == "/" then
        wt_path = input
      elseif input:sub(1, 1) == "~" then
        wt_path = vim.fn.expand(input)
      else
        wt_path = base_path .. "/" .. input
      end
      _finish(wt_path)
    end)
  end
end

---Delete the worktree for the selected branch, then optionally the branch itself.
---@param picker snacks.Picker
---@param item GitWorktrees.Item
function M.worktree_delete(picker, item)
  ---@type GitWorktrees.Snapshot
  local snapshot = vim.deepcopy({
    wt_path = item.wt_path,
    display_path = item.display_path,
    branch = item.branch,
    is_remote = item.is_remote,
  })
  picker:close()
  vim.schedule(function()
    M._do_worktree_delete(snapshot)
  end)
end

---Extended delete: remove worktree (if any) then extended delete the branch.
---@param picker snacks.Picker
---@param item GitWorktrees.Item
function M.worktree_delete_extended(picker, item)
  ---@type GitWorktrees.Snapshot
  local snapshot = vim.deepcopy({
    wt_path = item.wt_path,
    display_path = item.display_path,
    branch = item.branch,
    is_remote = item.is_remote,
  })
  picker:close()
  vim.schedule(function()
    M._do_worktree_delete_extended(snapshot)
  end)
end

---Open a top-right floating window showing `git status` for a worktree.
---Returns the window object so the caller can close it after a confirm prompt.
---Timeout is controlled by config.status_win_timeout (default 0 = manual close).
---@param wt_path string Absolute path of the worktree to inspect.
---@param title string Title shown in the window border.
---@return snacks.win
local function show_status_win(wt_path, title)
  local git = require("git-worktrees.git")
  local config = require("git-worktrees").config
  local status = git.get_status_with_untracked(wt_path)
  local lines = vim.split(status ~= "" and status or "(no changes)", "\n", { plain = true })
  local max_line = 0
  for _, line in ipairs(lines) do
    local w = vim.api.nvim_strwidth(line)
    if w > max_line then
      max_line = w
    end
  end
  local title_w = vim.api.nvim_strwidth(title)
  local win_width = math.min(math.max(max_line + 4, title_w + 6), math.floor(vim.o.columns * 0.85))
  local has_tabline = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and vim.fn.tabpagenr("$") > 1)
  local t = config.status_win_timeout ~= nil and config.status_win_timeout or 0
  local win = Snacks.win({
    text = lines,
    title = title,
    title_pos = "left",
    relative = "editor",
    position = "float",
    wo = { wrap = true },
    width = win_width,
    height = math.min(wrapped_height(lines, win_width), math.floor(vim.o.lines * 0.5)),
    row = has_tabline and 1 or 0,
    col = -1,
    zindex = 300,
    enter = false,
    border = "rounded",
    noautocmd = true,
    backdrop = false,
    keys = { q = "close" },
  })
  if t > 0 then
    vim.defer_fn(function()
      if win:win_valid() then
        win:close()
      end
    end, t)
  end
  return win
end

---@param item GitWorktrees.Snapshot
function M._do_worktree_delete(item)
  local git = require("git-worktrees.git")

  if not item.wt_path then
    M._do_branch_delete(item)
    return
  end

  if is_cwd_inside(item.wt_path) then
    notify("git-worktrees: cannot delete the worktree you are in", vim.log.levels.WARN)
    return
  end

  local choice =
    vim.fn.confirm("Delete worktree: " .. item.display_path .. "\nfor branch '" .. item.branch .. "'?", "&Yes\n&No", 2)
  if choice ~= 1 then
    return
  end

  local ok, err = git.worktree_remove(item.wt_path, false)
  if not ok then
    if err and err:find("modified or untracked") then
      local sw = show_status_win(item.wt_path, " Uncommitted changes: " .. item.branch .. " ")
      sw:redraw()
      local fc = vim.fn.confirm(
        "Worktree has uncommitted changes!\nForce delete " .. item.display_path .. "?",
        "&Force Delete\n&Cancel",
        2
      )
      sw:close()
      if fc ~= 1 then
        return
      end
      ok, err = git.worktree_remove(item.wt_path, true)
      if not ok then
        notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
        return
      end
    else
      notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
      return
    end
  end

  run_hook("on_delete", item.branch, item.wt_path)
  notify("Deleted worktree: " .. item.display_path, vim.log.levels.INFO)

  if not item.is_remote then
    local bc = vim.fn.confirm("Also delete branch '" .. item.branch .. "'?", "&Yes\n&No", 2)
    if bc == 1 then
      M._do_branch_delete(item)
    end
  end
end

---Extended delete: remove the worktree (if any), then run extended delete on the branch.
---@param item GitWorktrees.Snapshot
function M._do_worktree_delete_extended(item)
  local git = require("git-worktrees.git")

  if item.wt_path then
    if is_cwd_inside(item.wt_path) then
      notify("git-worktrees: cannot delete the worktree you are in", vim.log.levels.WARN)
      return
    end

    local choice = vim.fn.confirm(
      "Delete worktree: " .. item.display_path .. "\nfor branch '" .. item.branch .. "'?",
      "&Yes\n&No",
      2
    )
    if choice ~= 1 then
      return
    end
    local ok, err = git.worktree_remove(item.wt_path, false)
    if not ok then
      if err and err:find("modified or untracked") then
        local sw = show_status_win(item.wt_path, " Uncommitted changes: " .. item.branch .. " ")
        sw:redraw()
        local fc = vim.fn.confirm(
          "Worktree has uncommitted changes!\nForce delete " .. item.display_path .. "?",
          "&Force Delete\n&Cancel",
          2
        )
        sw:close()
        if fc ~= 1 then
          return
        end
        ok, err = git.worktree_remove(item.wt_path, true)
        if not ok then
          notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
          return
        end
      else
        notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
        return
      end
    end
    run_hook("on_delete", item.branch, item.wt_path)
    notify("Deleted worktree: " .. item.display_path, vim.log.levels.INFO)
  end

  M._do_branch_delete_extended(item)
end

---Delete a branch. Remote: `git push <remote> --delete <branch>`. Local: `git branch -d/-D`.
---@param item GitWorktrees.Snapshot
function M._do_branch_delete(item)
  local git = require("git-worktrees.git")
  local cwd = vim.fn.getcwd()

  if item.is_remote then
    local remote = item.branch:match("^([^/]+)/")
    local branch_name = item.branch:match("[^/]+/(.+)")
    if not remote or not branch_name then
      notify("git-worktrees: cannot parse remote branch: " .. item.branch, vim.log.levels.ERROR)
      return
    end
    local choice =
      vim.fn.confirm("Delete remote branch '" .. branch_name .. "' from '" .. remote .. "'?", "&Yes\n&No", 2)
    if choice ~= 1 then
      return
    end
    local ok, err = git.branch_delete_remote(remote, branch_name, cwd)
    if ok then
      notify("Deleted remote branch: " .. item.branch, vim.log.levels.INFO)
    else
      notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
    end
    return
  end

  local ok, err = git.branch_delete(item.branch, false)
  if not ok then
    if err == "unmerged" then
      local fc = vim.fn.confirm(
        "Branch '" .. item.branch .. "' is not fully merged.\nForce delete?",
        "&Force Delete\n&Cancel",
        2
      )
      if fc == 1 then
        ok, err = git.branch_delete(item.branch, true)
        if ok then
          notify("Force deleted branch: " .. item.branch, vim.log.levels.WARN)
        else
          notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
        end
      end
    else
      notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
    end
  else
    notify("Deleted branch: " .. item.branch, vim.log.levels.INFO)
  end
end

---Extended delete mirroring fgb ctrl-alt-d behaviour:
--- - Remote selected: delete remote first, then prompt to delete local counterpart.
--- - Local selected: delete local first (force fallback for unmerged), then prompt to delete remote.
---@param item GitWorktrees.Snapshot
function M._do_branch_delete_extended(item)
  local git = require("git-worktrees.git")
  local cwd = vim.fn.getcwd()

  if item.is_remote then
    local remote = item.branch:match("^([^/]+)/")
    local branch_name = item.branch:match("[^/]+/(.+)")
    if not remote or not branch_name then
      notify("git-worktrees: cannot parse remote branch: " .. item.branch, vim.log.levels.ERROR)
      return
    end
    local choice =
      vim.fn.confirm("Delete remote branch '" .. branch_name .. "' from '" .. remote .. "'?", "&Yes\n&No", 2)
    if choice ~= 1 then
      return
    end
    local ok, err = git.branch_delete_remote(remote, branch_name, cwd)
    if not ok then
      notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
      return
    end
    notify("Deleted remote branch: " .. item.branch, vim.log.levels.INFO)
    if git.local_branch_exists(branch_name, cwd) then
      local lc = vim.fn.confirm("Also delete local branch '" .. branch_name .. "'?", "&Yes\n&No", 2)
      if lc == 1 then
        M._do_branch_delete({ branch = branch_name, is_remote = false })
      end
    end
    return
  end

  -- Local branch: delete first (force fallback if unmerged), then offer remote.
  -- The upstream must be read before the delete: once refs/heads/<branch> is gone,
  -- `git for-each-ref` reports no upstream and the remote prompt would never appear.
  local upstream = git.get_branch_upstream(item.branch, cwd)

  local ok, err = git.branch_delete(item.branch, false)
  if not ok then
    if err == "unmerged" then
      local fc = vim.fn.confirm(
        "Branch '" .. item.branch .. "' is not fully merged.\nForce delete?",
        "&Force Delete\n&Cancel",
        2
      )
      if fc ~= 1 then
        return
      end
      ok, err = git.branch_delete(item.branch, true)
      if not ok then
        notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
        return
      end
      notify("Force deleted branch: " .. item.branch, vim.log.levels.WARN)
    else
      notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
      return
    end
  else
    notify("Deleted branch: " .. item.branch, vim.log.levels.INFO)
  end

  if upstream then
    local remote = upstream:match("^([^/]+)/")
    local branch_name = upstream:match("[^/]+/(.+)")
    if remote and branch_name then
      local rc =
        vim.fn.confirm("Also delete remote branch '" .. branch_name .. "' from '" .. remote .. "'?", "&Yes\n&No", 2)
      if rc == 1 then
        local rok, rerr = git.branch_delete_remote(remote, branch_name, cwd)
        if rok then
          notify("Deleted remote branch: " .. upstream, vim.log.levels.INFO)
        else
          notify("git-worktrees: " .. (rerr or "failed"), vim.log.levels.ERROR)
        end
      end
    end
  end
end

---Switch to a branch with `git switch` (changes HEAD in the current worktree).
---@param picker snacks.Picker
---@param item GitWorktrees.Item
function M.branch_switch(picker, item)
  local snapshot = vim.deepcopy({ branch = item.branch, is_remote = item.is_remote })
  picker:close()
  vim.schedule(function()
    local git = require("git-worktrees.git")
    local branch = snapshot.branch
    if snapshot.is_remote then
      branch = branch:match("[^/]+/(.+)") or branch
    end
    local ok, err = git.branch_switch(branch, vim.fn.getcwd())
    if ok then
      notify("Switched to branch: " .. branch, vim.log.levels.INFO)
    else
      notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
    end
  end)
end

---Delete the selected branch from the branch management picker.
---@param picker snacks.Picker
---@param item GitWorktrees.Item
function M.branch_delete(picker, item)
  local snapshot = vim.deepcopy({ branch = item.branch, is_remote = item.is_remote })
  picker:close()
  vim.schedule(function()
    M._do_branch_delete(snapshot)
  end)
end

---Extended delete: delete local then offer remote, or delete remote then offer local.
---@param picker snacks.Picker
---@param item GitWorktrees.Item
function M.branch_delete_extended(picker, item)
  local snapshot = vim.deepcopy({ branch = item.branch, is_remote = item.is_remote })
  picker:close()
  vim.schedule(function()
    M._do_branch_delete_extended(snapshot)
  end)
end

---Fork the selected branch: prompt for a new name and run `git branch`.
---Used by the branch management picker where no worktree is involved.
---@param picker snacks.Picker
---@param item GitWorktrees.Item
function M.branch_fork(picker, item)
  local snapshot = vim.deepcopy({ branch = item.branch, ref = item.ref, is_remote = item.is_remote })
  picker:close()
  vim.schedule(function()
    local git = require("git-worktrees.git")
    local cwd = vim.fn.getcwd()
    local base_name = snapshot.branch
    if snapshot.is_remote then
      base_name = base_name:match("[^/]+/(.+)") or base_name
    end
    vim.ui.input({ prompt = "New branch name: ", default = base_name .. "-fork" }, function(new_name)
      if new_name == nil or new_name == "" then
        notify("git-worktrees: cancelled", vim.log.levels.WARN)
        return
      end
      local ok, err = git.branch_create(new_name, snapshot.branch)
      if not ok then
        notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
        return
      end
      notify("Created branch: " .. new_name .. " from '" .. snapshot.branch .. "'", vim.log.levels.INFO)
      local sw_ok, sw_err = git.branch_switch(new_name, cwd)
      if sw_ok then
        notify("Switched to branch: " .. new_name, vim.log.levels.INFO)
      else
        notify("git-worktrees: could not switch to '" .. new_name .. "': " .. (sw_err or "failed"), vim.log.levels.WARN)
      end
    end)
  end)
end

---Apply a stash to a worktree, with automatic fallback to the original worktree on failure.
---Mirrors fgb's __fgb_git_worktree_restore_stash error-handling pattern, including the
---fgb fix to use exit code (not output grep) as the authoritative success signal.
---
---When new_wt_path is provided, attempts to apply there first; on failure, resets the new
---worktree (reset --hard + clean -fd) and falls back to init_wt_path. When new_wt_path is
---nil, applies directly to init_wt_path (used when worktree creation never succeeded).
---If both attempts fail, logs an actionable error message with the stash ref and recovery
---command so the user can manually recover their changes.
---@param stash_id string Stash ref (e.g. "stash@{0}") captured at push time.
---@param init_wt_path string Original worktree absolute path used as fallback destination.
---@param new_wt_path string|nil New worktree absolute path; nil for direct restore.
local function restore_stash(stash_id, init_wt_path, new_wt_path)
  local git = require("git-worktrees.git")

  if new_wt_path then
    if git.stash_apply(stash_id, new_wt_path) then
      git.stash_drop(stash_id, new_wt_path)
      notify("Changes moved to new worktree.", vim.log.levels.INFO)
      return
    end
    notify("git-worktrees: stash apply failed in new worktree; restoring to original worktree.", vim.log.levels.WARN)
    git.worktree_reset_hard(new_wt_path)
  end

  if git.stash_apply(stash_id, init_wt_path) then
    git.stash_drop(stash_id, init_wt_path)
    notify("Changes restored to original worktree.", vim.log.levels.INFO)
  else
    notify(
      "git-worktrees: failed to restore stash to original worktree.\n"
        .. "Your changes are saved as: "
        .. stash_id
        .. "\n"
        .. "Recover with: git -C "
        .. init_wt_path
        .. " stash apply "
        .. stash_id,
      vim.log.levels.ERROR
    )
  end
end

---Fork the selected branch and immediately create + switch to a worktree for it.
---
---If the current worktree has uncommitted changes (tracked files only), the user is offered
---three choices:
---  Move       - stash changes, create branch + worktree, apply stash there. On stash-apply
---               failure the new worktree is reset and the stash is restored to the original.
---  Leave here - proceed with the fork without touching the current changes (default).
---  Cancel     - abort the entire operation.
---
---On any error after the branch is created (worktree creation failure, user cancellation of
---the path prompt) the orphaned branch is automatically deleted and any pending stash is
---restored to the original worktree.
---@param picker snacks.Picker
---@param item GitWorktrees.Item
function M.worktree_fork(picker, item)
  local snapshot = vim.deepcopy({ branch = item.branch, ref = item.ref, is_remote = item.is_remote })
  picker:close()
  vim.schedule(function()
    local git = require("git-worktrees.git")
    local init_wt_path = vim.fn.getcwd()

    local base_name = snapshot.branch
    if snapshot.is_remote then
      base_name = base_name:match("[^/]+/(.+)") or base_name
    end
    vim.ui.input({ prompt = "New branch name: ", default = base_name .. "-fork" }, function(new_name)
      if new_name == nil or new_name == "" then
        notify("git-worktrees: cancelled", vim.log.levels.WARN)
        return
      end

      -- Detect uncommitted changes and offer stash-transfer to the new worktree.
      local stash_id = nil
      if git.has_uncommitted_changes(init_wt_path) then
        local status = git.get_status_short(init_wt_path)
        local choice = vim.fn.confirm(
          "Uncommitted changes in current worktree:\n\n"
            .. status
            .. "\n\n"
            .. "Move them to the new worktree '"
            .. new_name
            .. "'?",
          "&Move\n&Leave here\n&Cancel",
          2
        )
        if choice == 3 then
          notify("git-worktrees: cancelled", vim.log.levels.WARN)
          return
        end
        if choice == 1 then
          local sid, err =
            git.stash_create("Stash to restore in new worktree for branch '" .. new_name .. "'", init_wt_path)
          if not sid then
            notify("git-worktrees: failed to stash changes: " .. (err or "unknown"), vim.log.levels.ERROR)
            return
          end
          stash_id = sid
        end
      end

      -- Create the new branch. On failure, restore any stash and abort.
      local ok, err = git.branch_create(new_name, snapshot.branch)
      if not ok then
        notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
        if stash_id then
          restore_stash(stash_id, init_wt_path, nil)
        end
        return
      end
      notify("Created branch: " .. new_name .. " from '" .. snapshot.branch .. "'", vim.log.levels.INFO)

      -- Create the worktree. On failure, delete the orphaned branch and restore any stash.
      M._create_worktree(
        {
          branch = new_name,
          ref = "refs/heads/" .. new_name,
          is_remote = false,
          wt_path = nil,
          display_path = "",
        },
        false,
        function(new_wt_path)
          if not new_wt_path then
            git.branch_delete(new_name, true)
            notify(
              "git-worktrees: deleted orphaned branch '" .. new_name .. "' (worktree creation aborted).",
              vim.log.levels.WARN
            )
            if stash_id then
              restore_stash(stash_id, init_wt_path, nil)
            end
            return
          end

          -- Apply stash to the new worktree (falls back to original on failure).
          if stash_id then
            restore_stash(stash_id, init_wt_path, new_wt_path)
          end
        end
      )
    end)
  end)
end

---Show branch metadata as a notification without closing the picker.
---Format matches fgb's __fgb_print_branch_info output.
---Timeout is controlled by config.branch_info_timeout (default 5000 ms).
---@param picker snacks.Picker
---@param item GitWorktrees.Item
function M.branch_info(picker, item) --luacheck: ignore picker
  local git = require("git-worktrees.git")
  local config = require("git-worktrees").config
  local snapshot = vim.deepcopy({
    branch = item.branch,
    ref = item.ref,
    display_path = item.display_path,
    is_remote = item.is_remote,
  })

  -- Right-pad label to 13 chars then append " : " (total prefix = 16 chars).
  -- "committerdate" is the longest label at 13 chars; all others are padded to match.
  local function field(label, value)
    return label .. string.rep(" ", 13 - #label) .. " : " .. value
  end

  local lines = { field("branch", snapshot.branch) }
  if not snapshot.is_remote and snapshot.display_path ~= "" then
    lines[#lines + 1] = field("worktree", snapshot.display_path)
  end

  local details = git.get_commit_details(snapshot.ref, vim.fn.getcwd())
  if details then
    lines[#lines + 1] = field("author", details.author_name .. " <" .. details.author_email .. ">")
    lines[#lines + 1] = field("authordate", details.author_date)
    lines[#lines + 1] = field("committer", details.committer_name .. " <" .. details.committer_email .. ">")
    lines[#lines + 1] = field("committerdate", details.committer_date)
    lines[#lines + 1] = field("HEAD", details.hash)

    -- Format message: first line on the same row as the label; continuation lines
    -- indented by 16 spaces (= prefix width) to align content under the first line.
    local msg_lines = vim.split(details.message, "\n", { plain = true })
    while #msg_lines > 0 and msg_lines[#msg_lines]:match("^%s*$") do
      table.remove(msg_lines)
    end
    if #msg_lines > 0 then
      local indent = string.rep(" ", 16)
      lines[#lines + 1] = field("message", msg_lines[1])
      for i = 2, #msg_lines do
        lines[#lines + 1] = msg_lines[i] == "" and "" or (indent .. msg_lines[i])
      end
    end
  end

  -- Use a floating window positioned like a Snacks notification (top-right corner).
  -- zindex 300 places it above the picker (~52) and the Snacks notifier (100).
  -- wo.wrap=true ensures long lines wrap rather than being truncated.
  -- auto-closes after branch_info_timeout ms (0 = stay until dismissed).
  local max_line = 0
  for _, line in ipairs(lines) do
    local w = vim.api.nvim_strwidth(line)
    if w > max_line then
      max_line = w
    end
  end
  local t = config.branch_info_timeout ~= nil and config.branch_info_timeout or 5000
  local win_width = math.min(max_line + 4, math.floor(vim.o.columns * 0.85))
  local has_tabline = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and vim.fn.tabpagenr("$") > 1)
  local info_win = Snacks.win({
    text = lines,
    relative = "editor",
    position = "float",
    wo = { wrap = true },
    width = win_width,
    height = math.min(wrapped_height(lines, win_width), math.floor(vim.o.lines * 0.5)),
    row = has_tabline and 1 or 0,
    col = -1,
    zindex = 300,
    enter = false,
    border = "rounded",
    noautocmd = true,
    backdrop = false,
    keys = { q = "close" },
  })
  if t > 0 then
    vim.defer_fn(function()
      if info_win:win_valid() then
        info_win:close()
      end
    end, t)
  end
end

return M
