local M = {}

-- Safe hook invocation. Returns the hook's return value, or nil on error.
-- Returning false from on_before_switch cancels the operation.
local function run_hook(name, ...)
  local config = require("git-worktrees").config
  local hook = config.hooks and config.hooks[name]
  if type(hook) ~= "function" then
    return nil
  end
  local ok, result = pcall(hook, ...)
  if not ok then
    vim.notify(
      "git-worktrees: hook '" .. name .. "' error: " .. tostring(result),
      vim.log.levels.WARN
    )
    return nil
  end
  return result
end

-- Open the file equivalent to cur_file in to_path, using config.switch_file_command.
-- Falls back to a Snacks file picker in to_path when the file does not exist.
local function swap_current_buffer(from_path, to_path)
  local config = require("git-worktrees").config
  if config.swap_current_buffer == false then
    return
  end

  local cur_file = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  if cur_file == "" then
    return
  end

  local from_norm = from_path:gsub("/$", "")
  -- Ensure cur_file is actually inside from_path (not just a prefix match)
  if cur_file ~= from_norm and cur_file:sub(1, #from_norm + 1) ~= from_norm .. "/" then
    return
  end

  local rel = cur_file:sub(#from_norm + 2)
  local new_file = to_path:gsub("/$", "") .. "/" .. rel

  local function do_open()
    if vim.fn.filereadable(new_file) == 1 then
      local cmd = config.switch_file_command
      if cmd then
        vim.cmd(cmd .. " " .. vim.fn.fnameescape(new_file))
      end
    else
      Snacks.picker.files({ cwd = to_path })
    end
  end

  if config.swap_current_buffer == true then
    do_open()
  elseif config.swap_current_buffer == "ask" then
    local choice = vim.fn.confirm(
      "Open equivalent file in new worktree?\n" .. new_file,
      "&Yes\n&No",
      1
    )
    if choice == 1 then
      do_open()
    end
  end
end

-- Switch to an existing worktree or create a new one for the selected branch.
function M.worktree_switch(picker, item)
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

-- Same as worktree_switch but always prompts for path even when auto_worktree_path = true.
function M.worktree_switch_verbose(picker, item)
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

function M._do_switch(item, force_prompt)
  local from_path = vim.fn.getcwd()

  if item.wt_path then
    local to_path = item.wt_path
    local result = run_hook("on_before_switch", from_path, to_path)
    if result == false then
      return
    end
    vim.fn.chdir(to_path)
    vim.notify("Switched to worktree: " .. item.display_path, vim.log.levels.INFO)
    run_hook("on_switch", from_path, to_path)
    swap_current_buffer(from_path, to_path)
    return
  end

  -- No worktree yet: create one
  M._create_worktree(item, force_prompt)
end

function M._create_worktree(item, force_prompt)
  local git = require("git-worktrees.git")
  local config = require("git-worktrees").config
  local fmt = require("git-worktrees.format")
  local cwd = vim.fn.getcwd()

  local wt_data = git.get_worktree_data(cwd)
  if not wt_data then
    vim.notify("git-worktrees: not a git repo", vim.log.levels.ERROR)
    return
  end

  local tmpl = wt_data.is_bare and config.wt_base_path_bare or config.wt_base_path_regular
  local base_path = git.expand_wt_base(tmpl, wt_data.git_common_dir)
  local home = vim.env.HOME or ""
  local display_base = base_path
  if home ~= "" and display_base:sub(1, #home) == home then
    display_base = "~" .. display_base:sub(#home + 1)
  end

  -- safe subdir name: replace slashes
  local branch_safe = item.branch:gsub("/", "-")

  local wt_path
  if config.auto_worktree_path and not force_prompt then
    wt_path = base_path .. "/" .. branch_safe
  else
    local input = vim.fn.input(
      "Worktree path (relative to " .. display_base .. " or absolute): ",
      branch_safe
    )
    if input == "" then
      vim.notify("git-worktrees: cancelled", vim.log.levels.WARN)
      return
    end
    if input:sub(1, 1) == "/" then
      wt_path = input
    elseif input:sub(1, 1) == "~" then
      wt_path = vim.fn.expand(input)
    else
      wt_path = base_path .. "/" .. input
    end
  end

  -- For remote branches, use the short local name
  local branch_name = item.branch
  if item.is_remote then
    branch_name = branch_name:match("[^/]+/(.+)") or branch_name
  end

  local from_path = vim.fn.getcwd()
  local result = run_hook("on_before_switch", from_path, wt_path)
  if result == false then
    return
  end

  local ok, err_or_path = git.worktree_add(wt_path, branch_name, cwd)
  if not ok then
    vim.notify("git-worktrees: " .. (err_or_path or "failed"), vim.log.levels.ERROR)
    return
  end

  vim.fn.chdir(wt_path)
  local display = fmt.format_path(wt_path, config.wt_path_display, wt_data.git_common_dir)
  vim.notify(
    "Created worktree: " .. display .. " for '" .. branch_name .. "'",
    vim.log.levels.INFO
  )
  run_hook("on_add", branch_name, wt_path)
  run_hook("on_switch", from_path, wt_path)
  swap_current_buffer(from_path, wt_path)
end

-- Delete a worktree, then optionally its branch.
function M.worktree_delete(picker, item)
  local snapshot = vim.deepcopy({
    wt_path = item.wt_path,
    display_path = item.display_path,
    branch = item.branch,
    is_remote = item.is_remote,
    is_current = item.is_current,
  })
  picker:close()
  vim.schedule(function()
    M._do_worktree_delete(snapshot)
  end)
end

function M._do_worktree_delete(item)
  local git = require("git-worktrees.git")

  if not item.wt_path then
    -- No worktree: delete the branch directly
    M._do_branch_delete(item)
    return
  end

  if item.is_current then
    vim.notify("git-worktrees: cannot delete the current worktree", vim.log.levels.WARN)
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
      local fc = vim.fn.confirm(
        "Worktree has uncommitted changes!\nForce delete " .. item.display_path .. "?",
        "&Force Delete\n&Cancel",
        2
      )
      if fc ~= 1 then
        return
      end
      ok, err = git.worktree_remove(item.wt_path, true)
      if not ok then
        vim.notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
        return
      end
    else
      vim.notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
      return
    end
  end

  run_hook("on_remove", item.branch, item.wt_path)
  vim.notify("Deleted worktree: " .. item.display_path, vim.log.levels.INFO)

  if not item.is_remote then
    local bc = vim.fn.confirm(
      "Also delete branch '" .. item.branch .. "'?",
      "&Yes\n&No",
      2
    )
    if bc == 1 then
      M._do_branch_delete(item)
    end
  end
end

-- Delete a branch (internal, expects snapshot table with branch, is_remote).
function M._do_branch_delete(item)
  local git = require("git-worktrees.git")
  if item.is_remote then
    vim.notify("git-worktrees: remote branch deletion is not implemented yet", vim.log.levels.WARN)
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
          vim.notify("Force deleted branch: " .. item.branch, vim.log.levels.WARN)
        else
          vim.notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
        end
      end
    else
      vim.notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
    end
  else
    vim.notify("Deleted branch: " .. item.branch, vim.log.levels.INFO)
  end
end

-- Switch to a branch (changes HEAD, not CWD).
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
      vim.notify("Switched to branch: " .. branch, vim.log.levels.INFO)
    else
      vim.notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
    end
  end)
end

-- Delete a branch (picker action for branch picker).
function M.branch_delete(picker, item)
  local snapshot = vim.deepcopy({ branch = item.branch, is_remote = item.is_remote })
  picker:close()
  vim.schedule(function()
    M._do_branch_delete(snapshot)
  end)
end

-- Create a new branch forked from the selected one.
function M.branch_fork(picker, item)
  local snapshot = vim.deepcopy({ branch = item.branch, ref = item.ref, is_remote = item.is_remote })
  picker:close()
  vim.schedule(function()
    local git = require("git-worktrees.git")
    local base_name = snapshot.branch
    if snapshot.is_remote then
      base_name = base_name:match("[^/]+/(.+)") or base_name
    end
    local new_name = vim.fn.input("New branch name: ", base_name .. "_fork")
    if new_name == "" then
      vim.notify("git-worktrees: cancelled", vim.log.levels.WARN)
      return
    end
    local ok, err = git.branch_create(new_name, snapshot.branch)
    if ok then
      vim.notify("Created branch: " .. new_name .. " from '" .. snapshot.branch .. "'", vim.log.levels.INFO)
    else
      vim.notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
    end
  end)
end

-- Show branch metadata in a notification.
function M.branch_info(picker, item)
  local snapshot = vim.deepcopy({
    branch = item.branch,
    ref = item.ref,
    display_path = item.display_path,
    author = item.author,
    date = item.date,
    is_current = item.is_current,
  })
  -- Don't close the picker for info - just show the notification
  local lines = {
    "Branch:   " .. snapshot.branch,
    "Ref:      " .. snapshot.ref,
    "Worktree: " .. (snapshot.display_path ~= "" and snapshot.display_path or "(none)"),
    "Author:   " .. (snapshot.author or ""),
    "Date:     " .. (snapshot.date or ""),
    snapshot.is_current and "(current)" or "",
  }
  -- Remove trailing empty lines
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
