---@class GitWorktrees.Hooks
---@field before_switch? fun(from: string, to: string): boolean|nil Called before switching worktrees. Return false to abort.
---@field on_switch? fun(from: string, to: string) Called after the cwd has changed to the new worktree.
---@field on_add? fun(branch: string, path: string) Called after a new worktree is created.
---@field on_delete? fun(branch: string, path: string) Called after a worktree is deleted.

---@alias GitWorktrees.PathDisplay
---| "tilde"             # replace $HOME with ~ (default)
---| "absolute"          # full absolute path
---| "relative-cwd"      # relative to the current working directory
---| "relative-home"     # relative to cwd, with $HOME shown as ~
---| "relative-repo"     # relative to the repo working tree (bare: same as relative-gitdir)
---| "relative-wt-base"  # relative to the configured worktree base path
---| "relative-gitdir"   # relative to the git common directory (.git for non-bare)
---| "absolute-gitdir"   # absolute path prefixed with the git common dir (same as "absolute")
---| "tilde-gitdir"      # absolute-gitdir with ~ substitution applied (same as "tilde")

---@class GitWorktrees.Config
---@field wt_path_display? GitWorktrees.PathDisplay How worktree paths are displayed in the picker. (default: "tilde")
---@field wt_base_path_bare? string Base path template for new worktrees in bare repos. Supports {repo_name} and {repo_name_short}. (default: "./wt")
---@field wt_base_path_regular? string Base path template for new worktrees in regular repos. (default: "./wt")
---@field auto_worktree_path? boolean false: prompt; true: auto-apply <base_path>/<branch_name>. (default: false)
---@field branch_type? "local"|"remote"|"all" Default branch scope. Cycle with <M-g> inside the picker. (default: "local")
---@field sort_by? string Sort order passed to git for-each-ref --sort. (default: "-committerdate")
---@field date_format? string committerdate:<format> suffix for the date column. (default: "relative")
---@field author_format? "name"|"email" Author column field: "name" -> committername, "email" -> committeremail. (default: "name")
---@field swap_current_buffer? boolean|"ask" false: leave buffer; true: auto-swap; "ask": prompt. (default: false)
---@field switch_file_command? string|nil Vim command to open the swapped file. nil skips opening. (default: "edit")
---@field enable_default_keymaps? boolean Register the built-in keymaps when setup() is called. (default: false)
---@field notify_timeout? integer|nil Timeout in ms for plugin notifications. nil uses the notification handler's own default. (default: nil)
---@field branch_info_timeout? integer Timeout in ms for the branch info popup opened by <C-o>. (default: 5000)
---@field status_win_timeout? integer Timeout in ms for the git-status popup shown before a force-delete. 0 = close manually. (default: 0)
---@field hooks? GitWorktrees.Hooks Lifecycle hooks.
---@field filter? "no_worktree"|"has_worktree"|nil Internal: item filter for specialised pickers.
---@field _initial_pattern? string Internal: initial search pattern preserved across branch-type cycles.

---@class GitWorktrees
local M = {}

---@type GitWorktrees.Config
M.config = {
  wt_path_display = "tilde",
  wt_base_path_bare = "./wt",
  wt_base_path_regular = "./wt",
  auto_worktree_path = false,
  branch_type = "local",
  sort_by = "-committerdate",
  date_format = "relative",
  author_format = "name",
  swap_current_buffer = false,
  switch_file_command = "edit",
  enable_default_keymaps = false,
  notify_timeout = nil,
  branch_info_timeout = 5000,
  status_win_timeout = 0,
  hooks = {},
}

---Merge user options into the defaults and register commands and keymaps.
---@param opts? GitWorktrees.Config
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- User commands are always registered regardless of disable_default_keymaps.
  vim.api.nvim_create_user_command("GitWorktreeTotal", function()
    M.worktrees()
  end, { desc = "Open worktree total picker" })

  vim.api.nvim_create_user_command("GitWorktreeAdd", function()
    M.worktrees({ filter = "no_worktree" })
  end, { desc = "Add a new worktree (branches without worktrees)" })

  vim.api.nvim_create_user_command("GitWorktreeManage", function()
    M.worktrees({ filter = "has_worktree" })
  end, { desc = "Manage existing worktrees (branches with worktrees)" })

  vim.api.nvim_create_user_command("GitBranchManage", function()
    M.branches()
  end, { desc = "Open branch management picker" })

  if M.config.enable_default_keymaps then
    vim.keymap.set("n", "<leader>gwt", function()
      M.worktrees()
    end, { desc = "Worktree total" })

    vim.keymap.set("n", "<leader>gwa", function()
      M.worktrees({ filter = "no_worktree" })
    end, { desc = "Worktree add" })

    vim.keymap.set("n", "<leader>gwm", function()
      M.worktrees({ filter = "has_worktree" })
    end, { desc = "Worktree manage" })

    vim.keymap.set("n", "<leader>gbm", function()
      M.branches()
    end, { desc = "Branch management" })
  end
end

---Open the worktree total picker (equivalent to `fgb worktree total`).
---@param opts? GitWorktrees.Config Per-call config overrides merged on top of the global config.
function M.worktrees(opts)
  local cfg = vim.tbl_deep_extend("force", M.config, opts or {})
  require("git-worktrees.pickers").worktrees(cfg)
end

---Open the add-worktree picker pre-filtered to branches without a worktree.
---@param opts? GitWorktrees.Config Per-call config overrides.
function M.worktrees_add(opts)
  local cfg = vim.tbl_deep_extend("force", M.config, opts or {})
  cfg.filter = "no_worktree"
  require("git-worktrees.pickers").worktrees(cfg)
end

---Open the manage-worktrees picker pre-filtered to branches with a worktree.
---@param opts? GitWorktrees.Config Per-call config overrides.
function M.worktrees_manage(opts)
  local cfg = vim.tbl_deep_extend("force", M.config, opts or {})
  cfg.filter = "has_worktree"
  require("git-worktrees.pickers").worktrees(cfg)
end

---Open the branch management picker (equivalent to `fgb branch manage`).
---@param opts? GitWorktrees.Config Per-call config overrides.
function M.branches(opts)
  local cfg = vim.tbl_deep_extend("force", M.config, opts or {})
  require("git-worktrees.pickers").branches(cfg)
end

return M
