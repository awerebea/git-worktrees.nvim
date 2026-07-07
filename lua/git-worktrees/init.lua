local M = {}

--- @class GitWorktrees.Hooks
--- @field on_add? fun(branch: string, path: string)
--- @field on_before_switch? fun(from: string, to: string): boolean|nil
--- @field on_switch? fun(from: string, to: string)
--- @field on_remove? fun(branch: string, path: string)

--- @class GitWorktrees.Config
M.config = {
  -- How worktree paths are displayed in the picker.
  -- "tilde"           - $HOME replaced by ~
  -- "absolute"        - full absolute path
  -- "relative"        - relative to the current working directory
  -- "relative-gitdir" - relative to the git common directory (e.g. ./wt/my-branch)
  -- "gitdir"          - git-common-dir prefix + relative path
  -- "gitdir-tilde"    - same as gitdir with $HOME replaced by ~
  wt_path_display = "tilde",

  -- Template for the default new-worktree path in bare repos.
  -- Relative paths are anchored to the git common directory.
  -- Supports {repo_name} and {repo_name_short} placeholders.
  wt_base_path_bare = "./wt",

  -- Template for the default new-worktree path in regular repos.
  wt_base_path_regular = "./wt",

  -- New worktree path handling:
  --   false - show a pre-filled prompt for user to review/edit before creating
  --   true  - automatically apply <base_path>/<branch_name> without prompting
  auto_worktree_path = false,

  -- Which branches to show by default.
  -- "local" | "remote" | "all"
  -- Cycle between modes inside the picker with <C-g>.
  branch_type = "local",

  -- Sort order for git for-each-ref (any valid --sort value).
  -- "-committerdate" | "-authordate" | "refname" | "-version:refname"
  sort_by = "-committerdate",

  -- Date column format.
  -- Passed as committerdate:<format> to git for-each-ref.
  -- "relative" | "short" | "iso" | "human" | "format:STRFTIME"
  date_format = "relative",

  -- Author column field.
  -- "name" -> committername | "email" -> committeremail
  author_format = "name",

  -- Buffer swap when switching worktrees.
  --   false - do nothing (leave current buffer as-is)
  --   true  - automatically open the equivalent file in the new worktree
  --   "ask" - prompt the user before switching
  -- If the equivalent file does not exist in the new worktree, opens a file
  -- picker at the new worktree root instead.
  swap_current_buffer = false,

  -- Vim command used to open the file when swap_current_buffer is true/"ask".
  -- nil disables opening altogether (only the cwd is changed).
  -- "edit" | "tabedit" | "vsplit" | "split" | nil
  switch_file_command = "edit",

  -- Set to true to suppress the keymaps registered by setup().
  -- Use this when you manage keymaps yourself (e.g. via Lazy keys = {}).
  disable_default_keymaps = false,

  -- Lifecycle hooks. Each is an optional function.
  -- on_before_switch: return false to abort the switch.
  hooks = {},
}

--- Merge user options with the defaults.
--- @param opts? GitWorktrees.Config
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Register user commands (always available regardless of keymap setting)
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

  -- Register default keymaps unless opted out
  if not M.config.disable_default_keymaps then
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

--- Open the worktree total picker (equivalent to `fgb worktree total`).
--- @param opts? GitWorktrees.Config
function M.worktrees(opts)
  local cfg = vim.tbl_deep_extend("force", M.config, opts or {})
  require("git-worktrees.pickers").worktrees(cfg)
end

--- Open the add-worktree picker (branches without worktrees pre-filtered).
--- @param opts? GitWorktrees.Config
function M.worktrees_add(opts)
  local cfg = vim.tbl_deep_extend("force", M.config, opts or {})
  cfg.filter = "no_worktree"
  require("git-worktrees.pickers").worktrees(cfg)
end

--- Open the manage-worktrees picker (branches with worktrees pre-filtered).
--- @param opts? GitWorktrees.Config
function M.worktrees_manage(opts)
  local cfg = vim.tbl_deep_extend("force", M.config, opts or {})
  cfg.filter = "has_worktree"
  require("git-worktrees.pickers").worktrees(cfg)
end

--- Open the branch management picker (equivalent to `fgb branch manage`).
--- @param opts? GitWorktrees.Config
function M.branches(opts)
  local cfg = vim.tbl_deep_extend("force", M.config, opts or {})
  require("git-worktrees.pickers").branches(cfg)
end

return M
