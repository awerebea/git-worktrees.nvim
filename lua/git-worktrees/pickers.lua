local M = {}

-- Compute column layout based on available window width.
-- has_path: true for the worktree picker (shows wt path or collapse flag).
-- Returns visibility flags, column widths, and a uniform column spacer.
local function compute_layout(items, win_w, has_path)
  -- Minimum widths matching fgb's column headers
  local bw, pw, aw, dw = 6, 2, 6, 4

  for _, item in ipairs(items) do
    local bo = item.is_remote and "(" or "["
    local bc = item.is_remote and ")" or "]"
    local bd = #(bo .. item.branch .. bc)
    if bd > bw then bw = bd end
    if has_path then
      local p = #item.display_path
      if p > pw then pw = p end
    end
    local a = #(item.author or "")
    if a > aw then aw = a end
    local d = #(item.date or "")
    if d > dw then dw = d end
  end

  bw = math.min(bw + 2, 60)
  pw = math.min(pw + 2, 60)
  aw = math.min(aw, 25)

  local indicator_w = 2
  local show_path = has_path
  local show_flag = false
  local show_author = true
  local show_date = true

  -- Progressive collapse: path -> author -> date (fgb order).
  -- +5 overhead matches fgb's spacer baseline.
  local total = indicator_w + bw + (has_path and pw or 0) + aw + dw + 5

  if has_path and total > win_w then
    show_path = false
    show_flag = true
    total = total - pw + 1
  end
  if total > win_w then
    show_author = false
    total = total - aw
  end
  if total > win_w then
    show_date = false
  end

  local used_w = indicator_w + bw
  if show_path then used_w = used_w + pw end
  if show_flag then used_w = used_w + 1 end
  if show_author then used_w = used_w + aw end
  if show_date then used_w = used_w + dw end

  local n_gaps = 0
  if show_path or show_flag then n_gaps = n_gaps + 1 end
  if show_author then n_gaps = n_gaps + 1 end
  if show_date then n_gaps = n_gaps + 1 end

  -- Distribute remaining space as uniform inter-column gaps, capped at 4 like fgb.
  local spacer = 2
  if n_gaps > 0 then
    spacer = math.floor((win_w - used_w) / n_gaps)
    spacer = math.max(1, math.min(4, spacer))
  end

  return {
    bw = bw,
    pw = pw,
    aw = aw,
    spacer = spacer,
    show_path = show_path,
    show_flag = show_flag,
    show_author = show_author,
    show_date = show_date,
  }
end

local function load_data(config)
  local git = require("git-worktrees.git")
  local cwd = vim.fn.getcwd()

  if not git.is_git_repo(cwd) then
    vim.notify("git-worktrees: not inside a git repository", vim.log.levels.ERROR)
    return nil, nil, nil
  end

  local wt_data, err = git.get_worktree_data(cwd)
  if not wt_data then
    vim.notify("git-worktrees: failed to read worktrees: " .. (err or ""), vim.log.levels.ERROR)
    return nil, nil, nil
  end

  local branch_type = config.branch_type or "local"
  local branches = git.get_branches(branch_type, cwd)
  local current_ref = git.get_current_branch(cwd)

  return branches, wt_data, current_ref
end

-- Worktree total: all branches + their worktrees in a single picker.
-- Selecting a branch with a worktree switches to it; without one, creates it.
-- Equivalent to `fgb worktree total`.
function M.worktrees(config)
  local branches, wt_data, current_ref = load_data(config)
  if not branches then
    return
  end

  local fmt = require("git-worktrees.format")
  local act = require("git-worktrees.actions")

  local items = fmt.build_items(branches, wt_data, config, current_ref)

  local layout = nil

  Snacks.picker.pick({
    title = "Git Worktrees",
    items = items,
    layout = { preview = false },
    format = function(item, picker)
      if not layout then
        local ok, w = pcall(vim.api.nvim_win_get_width, picker.list.win.win)
        local win_w = (ok and w > 0) and w or math.max(vim.o.columns - 10, 60)
        layout = compute_layout(items, win_w, true)
      end

      local a = Snacks.picker.util.align
      local sp = string.rep(" ", layout.spacer)
      local ret = {}

      if item.is_current then
        ret[#ret + 1] = { "* ", "SnacksPickerGitBranchCurrent" }
      else
        ret[#ret + 1] = { "  " }
      end

      local bo = item.is_remote and "(" or "["
      local bc = item.is_remote and ")" or "]"
      local bd = bo .. item.branch .. bc
      local bhl = item.is_remote and "SnacksPickerSpecial" or "SnacksPickerGitBranch"
      ret[#ret + 1] = { a(bd, layout.bw), bhl }

      if layout.show_path then
        ret[#ret + 1] = { sp }
        if item.display_path ~= "" then
          ret[#ret + 1] = { a(item.display_path, layout.pw), "SnacksPickerDir" }
        else
          ret[#ret + 1] = { a("", layout.pw) }
        end
      elseif layout.show_flag then
        ret[#ret + 1] = { sp }
        local flag = item.wt_path and "+" or " "
        ret[#ret + 1] = { flag, item.wt_path and "SnacksPickerDir" or nil }
      end

      if layout.show_author then
        ret[#ret + 1] = { sp }
        ret[#ret + 1] = { a(item.author or "", layout.aw, { truncate = true }), "SnacksPickerComment" }
      end

      if layout.show_date then
        ret[#ret + 1] = { sp }
        ret[#ret + 1] = { item.date or "", "SnacksPickerComment" }
      end

      return ret
    end,
    actions = {
      worktree_switch = function(p, it)
        act.worktree_switch(p, it)
      end,
      worktree_switch_verbose = function(p, it)
        act.worktree_switch_verbose(p, it)
      end,
      worktree_delete = function(p, it)
        act.worktree_delete(p, it)
      end,
      branch_info = function(p, it)
        act.branch_info(p, it)
      end,
      branch_fork = function(p, it)
        act.branch_fork(p, it)
      end,
    },
    confirm = "worktree_switch",
    win = {
      input = {
        keys = {
          ["<C-x>"] = { "worktree_delete", mode = { "i", "n" } },
          ["<C-o>"] = { "branch_info", mode = { "i", "n" } },
          ["<A-v>"] = { "worktree_switch_verbose", mode = { "i", "n" } },
          ["<A-n>"] = { "branch_fork", mode = { "i", "n" } },
        },
      },
      list = {
        keys = {
          ["<C-x>"] = { "worktree_delete", mode = { "n" } },
          ["<C-o>"] = { "branch_info", mode = { "n" } },
          ["<A-v>"] = { "worktree_switch_verbose", mode = { "n" } },
          ["<A-n>"] = { "branch_fork", mode = { "n" } },
        },
      },
    },
  })
end

-- Branch manager: all branches.
-- Selecting a branch runs `git switch`; extra bindings for delete and fork.
-- Equivalent to `fgb branch manage`.
function M.branches(config)
  local branches, wt_data, current_ref = load_data(config)
  if not branches then
    return
  end

  local fmt = require("git-worktrees.format")
  local act = require("git-worktrees.actions")

  local items = fmt.build_items(branches, wt_data, config, current_ref)

  local layout = nil

  Snacks.picker.pick({
    title = "Git Branches",
    items = items,
    layout = { preview = false },
    format = function(item, picker)
      if not layout then
        local ok, w = pcall(vim.api.nvim_win_get_width, picker.list.win.win)
        local win_w = (ok and w > 0) and w or math.max(vim.o.columns - 10, 60)
        layout = compute_layout(items, win_w, false)
      end

      local a = Snacks.picker.util.align
      local sp = string.rep(" ", layout.spacer)
      local ret = {}

      if item.is_current then
        ret[#ret + 1] = { "* ", "SnacksPickerGitBranchCurrent" }
      else
        ret[#ret + 1] = { "  " }
      end

      local bo = item.is_remote and "(" or "["
      local bc = item.is_remote and ")" or "]"
      local bd = bo .. item.branch .. bc
      local bhl = item.is_remote and "SnacksPickerSpecial" or "SnacksPickerGitBranch"
      ret[#ret + 1] = { a(bd, layout.bw), bhl }

      if layout.show_author then
        ret[#ret + 1] = { sp }
        ret[#ret + 1] = { a(item.author or "", layout.aw, { truncate = true }), "SnacksPickerComment" }
      end

      if layout.show_date then
        ret[#ret + 1] = { sp }
        ret[#ret + 1] = { item.date or "", "SnacksPickerDir" }
      end

      return ret
    end,
    actions = {
      branch_switch = function(p, it)
        act.branch_switch(p, it)
      end,
      branch_delete = function(p, it)
        act.branch_delete(p, it)
      end,
      branch_info = function(p, it)
        act.branch_info(p, it)
      end,
      branch_fork = function(p, it)
        act.branch_fork(p, it)
      end,
    },
    confirm = "branch_switch",
    win = {
      input = {
        keys = {
          ["<C-x>"] = { "branch_delete", mode = { "i", "n" } },
          ["<C-o>"] = { "branch_info", mode = { "i", "n" } },
          ["<A-n>"] = { "branch_fork", mode = { "i", "n" } },
        },
      },
      list = {
        keys = {
          ["<C-x>"] = { "branch_delete", mode = { "n" } },
          ["<C-o>"] = { "branch_info", mode = { "n" } },
          ["<A-n>"] = { "branch_fork", mode = { "n" } },
        },
      },
    },
  })
end

return M
