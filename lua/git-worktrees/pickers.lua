---@alias GitWorktrees.BranchType "local"|"remote"|"all"

---@class GitWorktrees.Layout
---@field bw integer Branch column display width (includes 2-char padding).
---@field pw integer Path column display width (includes 2-char padding).
---@field aw integer Author column display width (capped at 25).
---@field spacer integer Uniform inter-column gap in spaces (1-4).
---@field show_path boolean Show the full worktree path column.
---@field show_flag boolean Show a single-char worktree presence indicator instead of path.
---@field show_author boolean Show the author column.
---@field show_date boolean Show the date column.

local notify = require("git-worktrees.util").notify

local M = {}

---@type GitWorktrees.BranchType[]
local BRANCH_TYPES = { "local", "remote", "all" }

---Return the next branch type in the local -> remote -> all -> local cycle.
---@param current GitWorktrees.BranchType
---@return GitWorktrees.BranchType
local function next_branch_type(current)
  for i, bt in ipairs(BRANCH_TYPES) do
    if bt == current then
      return BRANCH_TYPES[(i % #BRANCH_TYPES) + 1]
    end
  end
  return BRANCH_TYPES[1]
end

---Compute adaptive column visibility and spacer from the item set and available width.
---Columns are hidden in fgb order: path (replaced by flag) -> author -> date.
---@param items GitWorktrees.Item[]
---@param win_w integer Available list-window width in columns.
---@param has_path boolean True for the worktree picker; false for the branch picker.
---@return GitWorktrees.Layout
local function compute_layout(items, win_w, has_path)
  local bw, pw, aw, dw = 6, 2, 6, 4

  -- Measure display cells, not bytes: a committer name like "Unal Ozturk" spelled with
  -- diacritics is wider in bytes than on screen, which would pad its column too far.
  local width = vim.api.nvim_strwidth

  for _, item in ipairs(items) do
    local bo = item.is_remote and "(" or "["
    local bc = item.is_remote and ")" or "]"
    local bd = width(bo .. item.branch .. bc)
    if bd > bw then
      bw = bd
    end
    if has_path then
      local p = width(item.display_path)
      if p > pw then
        pw = p
      end
    end
    local a = width(item.author or "")
    if a > aw then
      aw = a
    end
    local d = width(item.date or "")
    if d > dw then
      dw = d
    end
  end

  local indicator_w = 2
  bw = math.min(bw + 2, win_w - indicator_w)
  pw = math.min(pw + 2, math.max(10, win_w - indicator_w - bw))
  aw = math.min(aw, 25)
  local show_path = has_path
  local show_flag = false
  local show_author = true
  local show_date = true

  -- +5 overhead matches fgb's spacer baseline calculation.
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
  if show_path then
    used_w = used_w + pw
  end
  if show_flag then
    used_w = used_w + 1
  end
  if show_author then
    used_w = used_w + aw
  end
  if show_date then
    used_w = used_w + dw
  end

  local n_gaps = 0
  if show_path or show_flag then
    n_gaps = n_gaps + 1
  end
  if show_author then
    n_gaps = n_gaps + 1
  end
  if show_date then
    n_gaps = n_gaps + 1
  end

  -- Distribute remaining width as a uniform inter-column gap, capped at 4 (fgb behaviour).
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

---Load branches, worktree data, the current HEAD ref, and the expanded worktree base path.
---@param config GitWorktrees.Config
---@return GitWorktrees.Branch[]|nil branches
---@return GitWorktrees.WorktreeData|nil wt_data
---@return string|nil current_ref
---@return string|nil wt_base_path Expanded worktree base path for the current repo type.
local function load_data(config)
  local git = require("git-worktrees.git")
  local cwd = vim.fn.getcwd()

  if not git.is_git_repo(cwd) then
    notify("git-worktrees: not inside a git repository", vim.log.levels.ERROR)
    return nil, nil, nil, nil
  end

  local wt_data, err = git.get_worktree_data(cwd)
  if not wt_data then
    notify("git-worktrees: failed to read worktrees: " .. (err or ""), vim.log.levels.ERROR)
    return nil, nil, nil, nil
  end

  local tmpl = wt_data.is_bare and (config.wt_base_path_bare or "./wt") or (config.wt_base_path_regular or "./wt")
  local wt_base_path = git.expand_wt_base(tmpl, wt_data.git_common_dir, wt_data.git_root)

  local branch_type = config.branch_type or "local"
  local branches = git.get_branches(branch_type, cwd, config)
  local current_ref = git.get_current_branch(cwd)

  return branches, wt_data, current_ref, wt_base_path
end

---Open the worktree total picker (equivalent to `fgb worktree total`).
---Selecting a branch with a worktree switches to it; without one, creates it.
---
---`config.filter` controls pre-filtering:
--- - `nil` - all branches (default)
--- - `"no_worktree"` - branches without a checked-out worktree (:GitWorktreeAdd)
--- - `"has_worktree"` - branches with a checked-out worktree (:GitWorktreeManage)
---@param config GitWorktrees.Config
function M.worktrees(config)
  local branches, wt_data, current_ref, wt_base_path = load_data(config)
  if not branches then
    return
  end

  local fmt = require("git-worktrees.format")
  local act = require("git-worktrees.actions")

  local items = fmt.build_items(branches, wt_data, config, current_ref, wt_base_path)

  if config.filter == "no_worktree" then
    ---@type GitWorktrees.Item[]
    local filtered = {}
    for _, item in ipairs(items) do
      if not item.wt_path then
        filtered[#filtered + 1] = item
      end
    end
    items = filtered
  elseif config.filter == "has_worktree" then
    ---@type GitWorktrees.Item[]
    local filtered = {}
    for _, item in ipairs(items) do
      if item.wt_path then
        filtered[#filtered + 1] = item
      end
    end
    items = filtered
  end

  local active_branch_type = config.branch_type or "local" --[[@as GitWorktrees.BranchType]]
  ---@type GitWorktrees.Layout|nil
  local layout = nil

  local title = "Git Worktrees [" .. active_branch_type .. "]"
  if config.filter == "no_worktree" then
    title = "Add Worktree [" .. active_branch_type .. "]"
  elseif config.filter == "has_worktree" then
    title = "Manage Worktrees [" .. active_branch_type .. "]"
  end

  Snacks.picker.pick({
    title = title,
    items = items,
    layout = { preview = false },
    pattern = config._initial_pattern,
    format = function(item, picker)
      if not layout then
        local ok, w = pcall(vim.api.nvim_win_get_width, picker.list.win.win)
        local win_w = (ok and w > 0) and w or math.max(vim.o.columns - 10, 60)
        layout = compute_layout(items, win_w, true)
      end

      local a = Snacks.picker.util.align
      local sp = string.rep(" ", layout.spacer)
      ---@type snacks.picker.Highlight[]
      local ret = {}

      if item.is_current then
        ret[#ret + 1] = { "* ", "SnacksPickerGitBranchCurrent" }
      else
        ret[#ret + 1] = { "  " }
      end

      local bo = item.is_remote and "(" or "["
      local bc = item.is_remote and ")" or "]"
      local bhl = item.is_remote and "SnacksPickerSpecial" or "SnacksPickerGitBranch"
      ret[#ret + 1] = { a(bo .. item.branch .. bc, layout.bw, { truncate = true }), bhl }

      if layout.show_path then
        ret[#ret + 1] = { sp }
        if item.display_path ~= "" then
          ret[#ret + 1] = { a(item.display_path, layout.pw, { truncate = true }), "SnacksPickerDir" }
        else
          ret[#ret + 1] = { a("", layout.pw) }
        end
      elseif layout.show_flag then
        ret[#ret + 1] = { sp }
        ret[#ret + 1] = { item.wt_path and "+" or " ", item.wt_path and "SnacksPickerDir" or nil }
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
      worktree_switch_edit = function(p, it)
        act.worktree_switch_edit(p, it)
      end,
      worktree_switch_tabedit = function(p, it)
        act.worktree_switch_tabedit(p, it)
      end,
      worktree_switch_vsplit = function(p, it)
        act.worktree_switch_vsplit(p, it)
      end,
      worktree_switch_split = function(p, it)
        act.worktree_switch_split(p, it)
      end,
      worktree_delete = function(p, it)
        act.worktree_delete(p, it)
      end,
      worktree_delete_extended = function(p, it)
        act.worktree_delete_extended(p, it)
      end,
      branch_info = function(p, it)
        act.branch_info(p, it)
      end,
      worktree_fork = function(p, it)
        act.worktree_fork(p, it)
      end,
      cycle_branch_type = function(p, _)
        local q = (p.input and p.input.filter and p.input.filter.pattern) or ""
        local next_bt = next_branch_type(active_branch_type)
        p:close()
        vim.schedule(function()
          M.worktrees(vim.tbl_deep_extend("force", config, {
            branch_type = next_bt,
            _initial_pattern = q,
          }))
        end)
      end,
    },
    confirm = "worktree_switch",
    win = {
      input = {
        keys = {
          ["<C-x>"] = { "worktree_delete", mode = { "i", "n" } },
          ["<M-x>"] = { "worktree_delete_extended", mode = { "i", "n" } },
          ["<C-o>"] = { "branch_info", mode = { "i", "n" } },
          ["<M-v>"] = { "worktree_switch_verbose", mode = { "i", "n" } },
          ["<M-n>"] = { "worktree_fork", mode = { "i", "n" } },
          ["<M-g>"] = { "cycle_branch_type", mode = { "i", "n" } },
          ["<C-e>"] = { "worktree_switch_edit", mode = { "i", "n" } },
          ["<C-t>"] = { "worktree_switch_tabedit", mode = { "i", "n" } },
          ["<C-v>"] = { "worktree_switch_vsplit", mode = { "i", "n" } },
          ["<C-s>"] = { "worktree_switch_split", mode = { "i", "n" } },
        },
      },
      list = {
        keys = {
          ["<C-x>"] = { "worktree_delete", mode = { "n" } },
          ["<M-x>"] = { "worktree_delete_extended", mode = { "n" } },
          ["<C-o>"] = { "branch_info", mode = { "n" } },
          ["<M-v>"] = { "worktree_switch_verbose", mode = { "n" } },
          ["<M-n>"] = { "worktree_fork", mode = { "n" } },
          ["<M-g>"] = { "cycle_branch_type", mode = { "n" } },
          ["<C-e>"] = { "worktree_switch_edit", mode = { "n" } },
          ["<C-t>"] = { "worktree_switch_tabedit", mode = { "n" } },
          ["<C-v>"] = { "worktree_switch_vsplit", mode = { "n" } },
          ["<C-s>"] = { "worktree_switch_split", mode = { "n" } },
        },
      },
    },
  })
end

---Open the branch management picker (equivalent to `fgb branch manage`).
---Selecting a branch runs `git switch`; `<C-x>` deletes, `<M-n>` forks.
---@param config GitWorktrees.Config
function M.branches(config)
  local branches, wt_data, current_ref, wt_base_path = load_data(config)
  if not branches then
    return
  end

  local fmt = require("git-worktrees.format")
  local act = require("git-worktrees.actions")

  local items = fmt.build_items(branches, wt_data, config, current_ref, wt_base_path)

  local active_branch_type = config.branch_type or "local" --[[@as GitWorktrees.BranchType]]
  ---@type GitWorktrees.Layout|nil
  local layout = nil

  Snacks.picker.pick({
    title = "Git Branches [" .. active_branch_type .. "]",
    items = items,
    layout = { preview = false },
    pattern = config._initial_pattern,
    format = function(item, picker)
      if not layout then
        local ok, w = pcall(vim.api.nvim_win_get_width, picker.list.win.win)
        local win_w = (ok and w > 0) and w or math.max(vim.o.columns - 10, 60)
        layout = compute_layout(items, win_w, false)
      end

      local a = Snacks.picker.util.align
      local sp = string.rep(" ", layout.spacer)
      ---@type snacks.picker.Highlight[]
      local ret = {}

      if item.is_current then
        ret[#ret + 1] = { "* ", "SnacksPickerGitBranchCurrent" }
      else
        ret[#ret + 1] = { "  " }
      end

      local bo = item.is_remote and "(" or "["
      local bc = item.is_remote and ")" or "]"
      local bhl = item.is_remote and "SnacksPickerSpecial" or "SnacksPickerGitBranch"
      ret[#ret + 1] = { a(bo .. item.branch .. bc, layout.bw, { truncate = true }), bhl }

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
      branch_delete_extended = function(p, it)
        act.branch_delete_extended(p, it)
      end,
      branch_info = function(p, it)
        act.branch_info(p, it)
      end,
      branch_fork = function(p, it)
        act.branch_fork(p, it)
      end,
      cycle_branch_type = function(p, _)
        local q = (p.input and p.input.filter and p.input.filter.pattern) or ""
        local next_bt = next_branch_type(active_branch_type)
        p:close()
        vim.schedule(function()
          M.branches(vim.tbl_deep_extend("force", config, {
            branch_type = next_bt,
            _initial_pattern = q,
          }))
        end)
      end,
    },
    confirm = "branch_switch",
    win = {
      input = {
        keys = {
          ["<C-x>"] = { "branch_delete", mode = { "i", "n" } },
          ["<M-x>"] = { "branch_delete_extended", mode = { "i", "n" } },
          ["<C-o>"] = { "branch_info", mode = { "i", "n" } },
          ["<M-n>"] = { "branch_fork", mode = { "i", "n" } },
          ["<M-g>"] = { "cycle_branch_type", mode = { "i", "n" } },
        },
      },
      list = {
        keys = {
          ["<C-x>"] = { "branch_delete", mode = { "n" } },
          ["<M-x>"] = { "branch_delete_extended", mode = { "n" } },
          ["<C-o>"] = { "branch_info", mode = { "n" } },
          ["<M-n>"] = { "branch_fork", mode = { "n" } },
          ["<M-g>"] = { "cycle_branch_type", mode = { "n" } },
        },
      },
    },
  })
end

return M
