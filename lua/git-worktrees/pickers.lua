local M = {}

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
  local bw, pw = fmt.column_widths(items, 50, 60)

  Snacks.picker.pick({
    title = "Git Worktrees",
    items = items,
    format = function(item, _)
      local a = Snacks.picker.util.align
      local ret = {}

      -- Current indicator
      if item.is_current then
        ret[#ret + 1] = { "* ", "SnacksPickerGitBranchCurrent" }
      else
        ret[#ret + 1] = { "  " }
      end

      -- Branch column
      local bd = item.bracket_open .. item.branch .. item.bracket_close
      local bhl = item.is_remote and "SnacksPickerSpecial" or "SnacksPickerGitBranch"
      ret[#ret + 1] = { a(bd, bw), bhl }

      -- Worktree path column
      if item.display_path ~= "" then
        ret[#ret + 1] = { a(item.display_path, pw), "SnacksPickerDir" }
      else
        ret[#ret + 1] = { a("", pw), "Comment" }
      end

      -- Date column
      if item.date and item.date ~= "" then
        ret[#ret + 1] = { "  " .. item.date, "SnacksPickerComment" }
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
          ["<C-d>"] = { "worktree_delete", mode = { "i", "n" } },
          ["<C-o>"] = { "branch_info", mode = { "i", "n" } },
          ["<C-v>"] = { "worktree_switch_verbose", mode = { "i", "n" } },
          ["<A-n>"] = { "branch_fork", mode = { "i", "n" } },
        },
      },
      list = {
        keys = {
          ["<C-d>"] = { "worktree_delete", mode = { "n" } },
          ["<C-o>"] = { "branch_info", mode = { "n" } },
          ["<C-v>"] = { "worktree_switch_verbose", mode = { "n" } },
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
  local bw, _ = fmt.column_widths(items, 50, 0)
  local author_w = 20

  Snacks.picker.pick({
    title = "Git Branches",
    items = items,
    format = function(item, _)
      local a = Snacks.picker.util.align
      local ret = {}

      -- Current indicator
      if item.is_current then
        ret[#ret + 1] = { "* ", "SnacksPickerGitBranchCurrent" }
      else
        ret[#ret + 1] = { "  " }
      end

      -- Branch column
      local bd = item.bracket_open .. item.branch .. item.bracket_close
      local bhl = item.is_remote and "SnacksPickerSpecial" or "SnacksPickerGitBranch"
      ret[#ret + 1] = { a(bd, bw), bhl }

      -- Author column
      if item.author and item.author ~= "" then
        ret[#ret + 1] = { "  " .. a(item.author, author_w, { truncate = true }), "SnacksPickerComment" }
      end

      -- Date column
      if item.date and item.date ~= "" then
        ret[#ret + 1] = { "  " .. item.date, "SnacksPickerDir" }
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
          ["<C-d>"] = { "branch_delete", mode = { "i", "n" } },
          ["<C-o>"] = { "branch_info", mode = { "i", "n" } },
          ["<A-n>"] = { "branch_fork", mode = { "i", "n" } },
        },
      },
      list = {
        keys = {
          ["<C-d>"] = { "branch_delete", mode = { "n" } },
          ["<C-o>"] = { "branch_info", mode = { "n" } },
          ["<A-n>"] = { "branch_fork", mode = { "n" } },
        },
      },
    },
  })
end

return M
