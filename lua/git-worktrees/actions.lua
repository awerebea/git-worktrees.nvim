---@class GitWorktrees.Snapshot
---@field wt_path string|nil
---@field display_path string
---@field branch string
---@field ref string
---@field is_remote boolean
---@field is_current? boolean

local M = {}

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
    vim.notify("git-worktrees: hook '" .. name .. "' error: " .. tostring(result), vim.log.levels.WARN)
    return nil
  end
  return result
end

---Open the file in `to_path` that corresponds to the currently open buffer in
---`from_path`, respecting the `swap_current_buffer` and `switch_file_command`
---config options. Falls back to a Snacks file picker when the file is absent.
---@param from_path string Absolute path of the old worktree root.
---@param to_path string Absolute path of the new worktree root.
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
  -- Guard against prefix-only matches (e.g. "/repo" must not match "/repo_other/...").
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

---Core switch implementation. If the item already has a worktree, cds into it.
---Otherwise delegates to `_create_worktree`.
---@param item GitWorktrees.Snapshot
---@param force_prompt boolean Always prompt for worktree path when true.
function M._do_switch(item, force_prompt)
  local from_path = vim.fn.getcwd()

  if item.wt_path then
    local to_path = item.wt_path
    if run_hook("before_switch", from_path, to_path) == false then
      return
    end
    vim.fn.chdir(to_path)
    vim.notify("Switched to worktree: " .. item.display_path, vim.log.levels.INFO)
    run_hook("on_switch", from_path, to_path)
    swap_current_buffer(from_path, to_path)
    return
  end

  M._create_worktree(item, force_prompt)
end

---Prompt for (or derive) a worktree path, run `git worktree add`, then switch.
---Returns the absolute path of the created worktree on success, nil on any failure or
---cancellation. Callers that fork a branch first must handle the nil case (clean up).
---@param item GitWorktrees.Snapshot
---@param force_prompt boolean
---@return string|nil wt_path Absolute path of the new worktree, or nil on failure.
function M._create_worktree(item, force_prompt)
  local git = require("git-worktrees.git")
  local config = require("git-worktrees").config
  local fmt = require("git-worktrees.format")
  local cwd = vim.fn.getcwd()

  local wt_data = git.get_worktree_data(cwd)
  if not wt_data then
    vim.notify("git-worktrees: not a git repo", vim.log.levels.ERROR)
    return nil
  end

  local tmpl = wt_data.is_bare and config.wt_base_path_bare or config.wt_base_path_regular
  local base_path = git.expand_wt_base(tmpl, wt_data.git_common_dir)

  local home = vim.env.HOME or ""
  local display_base = (home ~= "" and base_path:sub(1, #home) == home) and "~" .. base_path:sub(#home + 1) or base_path

  -- Replace slashes in the branch name so it is safe as a directory component.
  local branch_safe = item.branch:gsub("/", "-")

  local wt_path
  if config.auto_worktree_path and not force_prompt then
    wt_path = base_path .. "/" .. branch_safe
  else
    local input = vim.fn.input("Worktree path (relative to " .. display_base .. " or absolute): ", branch_safe)
    if input == "" then
      vim.notify("git-worktrees: cancelled", vim.log.levels.WARN)
      return nil
    end
    if input:sub(1, 1) == "/" then
      wt_path = input
    elseif input:sub(1, 1) == "~" then
      wt_path = vim.fn.expand(input)
    else
      wt_path = base_path .. "/" .. input
    end
  end

  -- Remote branch: derive a local name by stripping the remote prefix.
  local branch_name = item.branch
  if item.is_remote then
    branch_name = branch_name:match("[^/]+/(.+)") or branch_name
  end

  local from_path = vim.fn.getcwd()
  if run_hook("before_switch", from_path, wt_path) == false then
    return nil
  end

  local ok, err = git.worktree_add(wt_path, branch_name, cwd)
  if not ok then
    vim.notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
    return nil
  end

  vim.fn.chdir(wt_path)
  local display = fmt.format_path(wt_path, config.wt_path_display, wt_data.git_common_dir, base_path, wt_data.git_root)
  vim.notify("Created worktree: " .. display .. " for '" .. branch_name .. "'", vim.log.levels.INFO)
  run_hook("on_add", branch_name, wt_path)
  run_hook("on_switch", from_path, wt_path)
  swap_current_buffer(from_path, wt_path)
  return wt_path
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
    is_current = item.is_current,
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
    is_current = item.is_current,
  })
  picker:close()
  vim.schedule(function()
    M._do_worktree_delete_extended(snapshot)
  end)
end

---@param item GitWorktrees.Snapshot
function M._do_worktree_delete(item)
  local git = require("git-worktrees.git")

  if not item.wt_path then
    M._do_branch_delete(item)
    return
  end

  if item.is_current then
    vim.notify("git-worktrees: cannot delete the current worktree", vim.log.levels.WARN)
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

  run_hook("on_delete", item.branch, item.wt_path)
  vim.notify("Deleted worktree: " .. item.display_path, vim.log.levels.INFO)

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

  if item.is_current then
    vim.notify("git-worktrees: cannot delete the current worktree", vim.log.levels.WARN)
    return
  end

  if item.wt_path then
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
    run_hook("on_delete", item.branch, item.wt_path)
    vim.notify("Deleted worktree: " .. item.display_path, vim.log.levels.INFO)
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
      vim.notify("git-worktrees: cannot parse remote branch: " .. item.branch, vim.log.levels.ERROR)
      return
    end
    local choice = vim.fn.confirm(
      "Delete remote branch '" .. branch_name .. "' from '" .. remote .. "'?",
      "&Yes\n&No",
      2
    )
    if choice ~= 1 then
      return
    end
    local ok, err = git.branch_delete_remote(remote, branch_name, cwd)
    if ok then
      vim.notify("Deleted remote branch: " .. item.branch, vim.log.levels.INFO)
    else
      vim.notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
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
      vim.notify("git-worktrees: cannot parse remote branch: " .. item.branch, vim.log.levels.ERROR)
      return
    end
    local choice = vim.fn.confirm(
      "Delete remote branch '" .. branch_name .. "' from '" .. remote .. "'?",
      "&Yes\n&No",
      2
    )
    if choice ~= 1 then
      return
    end
    local ok, err = git.branch_delete_remote(remote, branch_name, cwd)
    if not ok then
      vim.notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
      return
    end
    vim.notify("Deleted remote branch: " .. item.branch, vim.log.levels.INFO)
    if git.local_branch_exists(branch_name, cwd) then
      local lc = vim.fn.confirm("Also delete local branch '" .. branch_name .. "'?", "&Yes\n&No", 2)
      if lc == 1 then
        M._do_branch_delete({ branch = branch_name, is_remote = false })
      end
    end
    return
  end

  -- Local branch: delete first (force fallback if unmerged), then offer remote.
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
        vim.notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
        return
      end
      vim.notify("Force deleted branch: " .. item.branch, vim.log.levels.WARN)
    else
      vim.notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
      return
    end
  else
    vim.notify("Deleted branch: " .. item.branch, vim.log.levels.INFO)
  end

  local upstream = git.get_branch_upstream(item.branch, cwd)
  if upstream then
    local remote = upstream:match("^([^/]+)/")
    local branch_name = upstream:match("[^/]+/(.+)")
    if remote and branch_name then
      local rc = vim.fn.confirm(
        "Also delete remote branch '" .. branch_name .. "' from '" .. remote .. "'?",
        "&Yes\n&No",
        2
      )
      if rc == 1 then
        local rok, rerr = git.branch_delete_remote(remote, branch_name, cwd)
        if rok then
          vim.notify("Deleted remote branch: " .. upstream, vim.log.levels.INFO)
        else
          vim.notify("git-worktrees: " .. (rerr or "failed"), vim.log.levels.ERROR)
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
      vim.notify("Switched to branch: " .. branch, vim.log.levels.INFO)
    else
      vim.notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
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
    local base_name = snapshot.branch
    if snapshot.is_remote then
      base_name = base_name:match("[^/]+/(.+)") or base_name
    end
    local new_name = vim.fn.input("New branch name: ", base_name .. "-fork")
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
      vim.notify("Changes moved to new worktree.", vim.log.levels.INFO)
      return
    end
    vim.notify(
      "git-worktrees: stash apply failed in new worktree; restoring to original worktree.",
      vim.log.levels.WARN
    )
    git.worktree_reset_hard(new_wt_path)
  end

  if git.stash_apply(stash_id, init_wt_path) then
    git.stash_drop(stash_id, init_wt_path)
    vim.notify("Changes restored to original worktree.", vim.log.levels.INFO)
  else
    vim.notify(
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
    local new_name = vim.fn.input("New branch name: ", base_name .. "-fork")
    if new_name == "" then
      vim.notify("git-worktrees: cancelled", vim.log.levels.WARN)
      return
    end

    -- Detect uncommitted changes and offer stash-transfer to the new worktree.
    local stash_id = nil
    if git.has_uncommitted_changes(init_wt_path) then
      local status = git.get_status_short(init_wt_path)
      local choice = vim.fn.confirm(
        "Uncommitted changes in current worktree:\n\n" .. status .. "\n\n"
          .. "Move them to the new worktree '"
          .. new_name
          .. "'?",
        "&Move\n&Leave here\n&Cancel",
        2
      )
      if choice == 3 then
        vim.notify("git-worktrees: cancelled", vim.log.levels.WARN)
        return
      end
      if choice == 1 then
        local sid, err = git.stash_create(
          "Stash to restore in new worktree for branch '" .. new_name .. "'",
          init_wt_path
        )
        if not sid then
          vim.notify("git-worktrees: failed to stash changes: " .. (err or "unknown"), vim.log.levels.ERROR)
          return
        end
        stash_id = sid
      end
    end

    -- Create the new branch. On failure, restore any stash and abort.
    local ok, err = git.branch_create(new_name, snapshot.branch)
    if not ok then
      vim.notify("git-worktrees: " .. (err or "failed"), vim.log.levels.ERROR)
      if stash_id then
        restore_stash(stash_id, init_wt_path, nil)
      end
      return
    end
    vim.notify("Created branch: " .. new_name .. " from '" .. snapshot.branch .. "'", vim.log.levels.INFO)

    -- Create the worktree. On failure, delete the orphaned branch and restore any stash.
    local new_wt_path = M._create_worktree({
      branch = new_name,
      ref = "refs/heads/" .. new_name,
      is_remote = false,
      wt_path = nil,
      display_path = "",
    }, false)

    if not new_wt_path then
      git.branch_delete(new_name, true)
      vim.notify(
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
  end)
end

---Show branch metadata as a vim.notify without closing the picker.
---@param picker snacks.Picker
---@param item GitWorktrees.Item
function M.branch_info(picker, item) --luacheck: ignore picker
  local git = require("git-worktrees.git")
  local snapshot = vim.deepcopy({
    branch = item.branch,
    ref = item.ref,
    display_path = item.display_path,
    author = item.author,
    date = item.date,
    is_current = item.is_current,
  })
  local hash, subject = git.get_commit_info(snapshot.ref, vim.fn.getcwd())
  local lines = {
    "Branch:   " .. snapshot.branch,
    "Ref:      " .. snapshot.ref,
    "Worktree: " .. (snapshot.display_path ~= "" and snapshot.display_path or "(none)"),
    "Author:   " .. (snapshot.author or ""),
    "Date:     " .. (snapshot.date or ""),
    hash and ("Commit:   " .. hash .. "  " .. (subject or "")) or "",
    snapshot.is_current and "(current)" or "",
  }
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
