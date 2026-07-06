local M = {}

--- Default configuration.
--- @class GitWorktrees.Config
M.config = {
  -- How worktree paths are displayed in the picker.
  -- "tilde"       - $HOME replaced by ~ (default)
  -- "absolute"    - full absolute path
  -- "relative"    - relative to the current working directory
  -- "gitdir"      - git-common-dir prefix + relative path
  -- "gitdir-tilde"- same as gitdir with $HOME replaced by ~
  wt_path_display = "tilde",

  -- Template for the default new-worktree path in bare repos.
  -- Relative paths are anchored to the git common directory.
  -- Supports {repo_name} and {repo_name_short} placeholders.
  wt_base_path_bare = "./wt",

  -- Template for the default new-worktree path in regular repos.
  wt_base_path_regular = "./wt",

  -- When creating a worktree:
  --   false - show a pre-filled prompt so you can edit the path
  --   true  - silently use base_path/<branch_name> with no prompt
  confirm_path = false,

  -- Which branches to show by default.
  -- "local" | "remote" | "all"
  branch_type = "local",
}

--- Merge user options with the defaults.
--- @param opts? GitWorktrees.Config
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

--- Open the worktree total picker (equivalent to `fgb worktree total`).
--- @param opts? GitWorktrees.Config
function M.worktrees(opts)
  local cfg = vim.tbl_deep_extend("force", M.config, opts or {})
  require("git-worktrees.pickers").worktrees(cfg)
end

--- Open the branch management picker (equivalent to `fgb branch manage`).
--- @param opts? GitWorktrees.Config
function M.branches(opts)
  local cfg = vim.tbl_deep_extend("force", M.config, opts or {})
  require("git-worktrees.pickers").branches(cfg)
end

return M
