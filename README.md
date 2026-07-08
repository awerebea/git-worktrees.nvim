# git-worktrees.nvim

A Snacks-picker-based interface for Git worktrees and branch management inside Neovim.

Inspired by and built on the shoulders of:

- [fzf-git-branches](https://github.com/awerebea/fzf-git-branches) - a bash/zsh script
  that provides the same worktree and branch management workflow in the terminal via fzf.
  This plugin brings that functionality natively into Neovim using the
  [Snacks](https://github.com/folke/snacks.nvim) picker, with the same column layout,
  progressive column collapsing, and keyboard-driven workflow.
- [ThePrimeagen/git-worktree.nvim](https://github.com/ThePrimeagen/git-worktree.nvim) -
  the original Neovim git worktree plugin that popularised the workflow.
- [Juksuu/worktrees.nvim](https://github.com/Juksuu/worktrees.nvim) - a modern worktree
  plugin whose hook system and action patterns influenced this plugin's design.
- [afonsofrancof/worktrees.nvim](https://github.com/afonsofrancof/worktrees.nvim) - a
  clean, minimal worktrees implementation that informed several design decisions.

## Features

- **Worktree total** - browse all branches; switch to or create a worktree, delete it, or fork to a new branch + worktree
- **Worktree add** - pre-filtered to branches without worktrees; create, fork, or delete the selected branch
- **Worktree manage** - pre-filtered to branches with worktrees; jump between, delete, or fork
- **Branch manage** - switch, delete (local or remote), or fork any local/remote branch (no worktree operations)
- Simple delete (`<C-x>`): deletes only the selected branch type (local-only or remote-only)
- Extended delete (`<M-x>`): deletes the selected side first, then prompts to also remove the counterpart
- Adaptive column layout (branch | path/flag | author | date) that collapses gracefully on narrow screens
- Live branch-type cycling (`<M-g>`) between local / remote / all without leaving the picker
- Optional buffer swap when switching worktrees
- Lifecycle hooks: `before_switch`, `on_switch`, `on_add`, `on_delete`

## Requirements

- Neovim >= 0.10
- [snacks.nvim](https://github.com/folke/snacks.nvim) with the `picker` module enabled
- `git` available on `$PATH`

[plenary.nvim](https://github.com/nvim-lua/plenary.nvim) is **not** required by the plugin
itself, but one of the hook examples in this README uses it.

## Installation

### lazy.nvim (recommended)

```lua
{
  "awerebea/git-worktrees.nvim",
  dependencies = { "folke/snacks.nvim" },

  -- Lazy-load: plugin is loaded on first keymap press or command use.
  -- No need for event = "VeryLazy" - keys/cmd already cover both entry points.
  keys = {
    { "<leader>gwt", function() require("git-worktrees").worktrees() end,         desc = "Worktree total" },
    { "<leader>gwa", function() require("git-worktrees").worktrees_add() end,     desc = "Worktree add" },
    { "<leader>gwm", function() require("git-worktrees").worktrees_manage() end,  desc = "Worktree manage" },
    { "<leader>gbm", function() require("git-worktrees").branches() end,          desc = "Branch management" },
  },
  cmd = { "GitWorktreeTotal", "GitWorktreeAdd", "GitWorktreeManage", "GitBranchManage" },

  -- config = true also works here if you have no custom opts - lazy derives the
  -- module name ("git-worktrees") from the plugin dir name and calls .setup(opts).
  opts = {
    disable_default_keymaps = true,   -- we manage keymaps above via keys = {}
    -- ...other overrides...
  },
  config = function(_, opts)
    require("git-worktrees").setup(opts)
  end,
}
```

### Without lazy.nvim

```lua
require("git-worktrees").setup({
  -- disable_default_keymaps = false by default, so keymaps are registered here
})
```

## Default Configuration

All options and their defaults:

```lua
require("git-worktrees").setup({
  -- How worktree paths are displayed in the picker.
  -- "tilde"            - replace $HOME with ~ (default)
  -- "absolute"         - full absolute path
  -- "relative-cwd"     - relative to the current working directory
  -- "relative-home"    - relative to cwd, with $HOME shown as ~
  -- "relative-repo"    - relative to the repo working tree root
  --                      (bare repos: same as relative-gitdir)
  -- "relative-wt-base" - relative to the configured worktree base path
  -- "relative-gitdir"  - relative to the git common dir (.git for non-bare)
  -- "absolute-gitdir"  - absolute path prefixed with the git common dir
  -- "tilde-gitdir"     - absolute-gitdir with ~ substitution applied
  wt_path_display = "tilde",

  -- Base path template for new worktrees.
  -- Relative paths are anchored to the git common directory.
  -- Supports {repo_name} and {repo_name_short} placeholders.
  wt_base_path_bare    = "./wt",
  wt_base_path_regular = "./wt",

  -- New worktree path handling:
  --   false - show a pre-filled prompt (user can review/edit the path before creating)
  --   true  - automatically use <base_path>/<branch_name> without prompting
  auto_worktree_path = false,

  -- Default branch scope. Cycle interactively with <M-g> inside the picker.
  -- "local" | "remote" | "all"
  branch_type = "local",

  -- Sort order for branches (any value accepted by git for-each-ref --sort).
  -- "-committerdate" | "-authordate" | "refname" | "-version:refname"
  sort_by = "-committerdate",

  -- Date column format (used as committerdate:<format> in git for-each-ref).
  -- "relative" | "short" | "iso" | "human" | "format:STRFTIME"
  date_format = "relative",

  -- Author column field.
  -- "name"  -> committername
  -- "email" -> committeremail
  author_format = "name",

  -- Buffer swap when switching worktrees.
  --   false - leave the current buffer unchanged
  --   true  - automatically open the equivalent file in the new worktree
  --   "ask" - prompt before switching
  -- When the equivalent file does not exist, a file picker opens at the new
  -- worktree root instead.
  swap_current_buffer = false,

  -- Vim command used to open the file when swap_current_buffer is true or "ask".
  -- nil - only change cwd, do not open any file.
  -- "edit" | "tabedit" | "vsplit" | "split" | nil
  switch_file_command = "edit",

  -- Suppress the keymaps registered by setup().
  -- Set to true when you manage keymaps yourself (e.g. Lazy keys = {}).
  disable_default_keymaps = false,

  -- Lifecycle hooks. All are optional functions.
  hooks = {
    -- Called before switching worktrees. Return false to abort.
    before_switch = nil, -- function(from: string, to: string): boolean|nil

    -- Called after the cwd has changed to the new worktree.
    on_switch = nil,     -- function(from: string, to: string)

    -- Called after a new worktree is created.
    on_add = nil,        -- function(branch: string, path: string)

    -- Called after a worktree is deleted.
    on_delete = nil,     -- function(branch: string, path: string)
  },
})
```

## Default Keymaps (registered by setup when disable_default_keymaps = false)

| Key           | Action                                                        |
| ------------- | ------------------------------------------------------------- |
| `<leader>gwt` | All branches - switch to or create a worktree                 |
| `<leader>gwa` | Branches without a worktree - create one                      |
| `<leader>gwm` | Branches with a worktree - jump between or delete             |
| `<leader>gbm` | All branches - switch HEAD, delete, or fork (no worktree ops) |

## User Commands

| Command              | Description                                                                                                    |
| -------------------- | -------------------------------------------------------------------------------------------------------------- |
| `:GitWorktreeTotal`  | All branches regardless of worktree status. Switch to or create a worktree, delete it (simple or extended), or fork to a new branch + worktree. |
| `:GitWorktreeAdd`    | Only branches **without** a worktree. Create a worktree, fork the branch, or delete it (simple or extended).                                    |
| `:GitWorktreeManage` | Only branches **with** a worktree. Jump between worktrees, delete one (simple or extended), or fork to a new branch + worktree.                 |
| `:GitBranchManage`   | All branches. Switch HEAD, delete (local-only, remote-only, or full local+remote), or fork a branch.                                        |

## In-picker Keybindings

| Key     | Action                                                                               |
| ------- | ------------------------------------------------------------------------------------ |
| `<CR>`  | Switch to worktree / branch (create worktree if missing)                             |
| `<C-x>` | Simple delete: local branch -> delete local only; remote branch -> delete remote only |
| `<M-x>` | Extended delete: local -> delete local then prompt to also delete remote; remote -> delete remote then prompt to also delete local; worktree pickers: remove worktree first |
| `<M-v>` | Force path prompt even when `auto_worktree_path = true`                              |
| `<C-o>` | Show branch info notification (branch, ref, worktree, author, date, HEAD commit)     |
| `<M-n>` | Fork branch (worktree pickers: create branch + worktree; branch picker: branch only) |
| `<M-g>` | Cycle branch type: local -> remote -> all -> local                                   |

## Stash Transfer When Forking

When you press `<M-n>` to fork a branch from a worktree picker and the current worktree
has uncommitted changes (staged or unstaged tracked files), the plugin detects this and
offers three choices:

| Choice       | Behaviour                                                              |
| ------------ | ---------------------------------------------------------------------- |
| **Move**     | Stash changes, create branch + worktree, apply stash in the new worktree. If the apply fails, reset the new worktree and restore the stash to the original. If even that fails, display an actionable error with the stash ref and recovery command. |
| **Leave here** | Proceed with the fork without touching the current changes (default). |
| **Cancel**   | Abort the entire operation.                                            |

If worktree creation fails for any reason after the branch was already created (git error,
user cancelled the path prompt), the plugin automatically deletes the orphaned branch and
restores any pending stash to the original worktree.

This mirrors the behaviour of the companion
[fzf-git-branches](https://github.com/awerebea/fzf-git-branches) shell script and is
not present in most other Neovim worktree plugins.

## Hook Examples

### Abort switch when path matches a pattern (before_switch)

```lua
hooks = {
  before_switch = function(from, to)
    -- Prevent accidentally switching to a WIP worktree
    if to:find("/wip/") then
      vim.notify("Switch aborted: WIP worktrees are protected", vim.log.levels.WARN)
      return false
    end
  end,
}
```

### Notify on switch (on_switch)

```lua
hooks = {
  on_switch = function(from, to)
    vim.notify("Switched: " .. from .. " -> " .. to)
  end,
}
```

### Open a terminal in the new worktree after switching (on_switch)

```lua
hooks = {
  on_switch = function(from, to)
    vim.schedule(function()
      -- Open a floating terminal in the new worktree root
      Snacks.terminal(nil, { cwd = to })
    end)
  end,
}
```

### Log all worktree additions (on_add)

```lua
hooks = {
  on_add = function(branch, path)
    local log = io.open(vim.fn.expand("~/.local/share/nvim/worktree_log.txt"), "a")
    if log then
      log:write(os.date("%Y-%m-%d %H:%M:%S") .. "  ADD  " .. branch .. "  " .. path .. "\n")
      log:close()
    end
  end,
}
```

### Switch all open windows to the equivalent file in the new worktree (on_switch)

This is the most powerful hook pattern - mirrors every window to the corresponding
file in the new worktree, closing windows whose files do not exist there.

```lua
require("git-worktrees").setup({
  swap_current_buffer = false,   -- disable built-in swap; hook handles it
  hooks = {
    on_switch = function(from, to)
      local any_exist = false
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local bufnr = vim.api.nvim_win_get_buf(win)
        local buf_name = vim.api.nvim_buf_get_name(bufnr)
        if buf_name ~= "" and buf_name:sub(1, #from) == from then
          local rel = buf_name:sub(#from + 2)
          local new_path = to .. "/" .. rel
          if vim.fn.filereadable(new_path) == 1 then
            any_exist = true
            vim.schedule(function()
              local new_buf = vim.fn.bufnr(new_path, true)
              vim.api.nvim_win_set_buf(win, new_buf)
              vim.api.nvim_buf_delete(bufnr, { force = false })
            end)
          else
            vim.api.nvim_win_close(win, true)
          end
        end
      end
      if not any_exist then
        vim.schedule(function()
          Snacks.picker.files({ cwd = to })
        end)
      end
    end,
  },
})
```

### Using plenary.path for path operations - on_switch (from Juksuu/worktrees.nvim example)

```lua
hooks = {
  on_switch = function(from, to)
    local Path = require("plenary.path")
    local any_exist = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local bufnr = vim.api.nvim_win_get_buf(win)
      local buf_path = Path:new(vim.api.nvim_buf_get_name(bufnr))
      local rel_path = buf_path:make_relative(from)
      local path_in_new = Path:new(to .. "/" .. rel_path)
      if path_in_new:exists() then
        any_exist = true
        vim.schedule(function()
          local new_buf = vim.fn.bufnr(path_in_new:absolute(), true)
          vim.api.nvim_win_set_buf(win, new_buf)
          vim.api.nvim_buf_delete(bufnr, { force = false })
        end)
      else
        vim.api.nvim_win_close(win, true)
      end
    end
    if not any_exist then
      vim.schedule(function()
        local root_buf = vim.fn.bufnr(to)
        vim.api.nvim_set_current_buf(root_buf)
      end)
    end
  end,
}
```

## API

```lua
local gw = require("git-worktrees")

gw.setup(opts)          -- initialize with config
gw.worktrees(opts?)     -- open worktree total picker
gw.worktrees_add(opts?) -- open add-worktree picker (no_worktree filter)
gw.worktrees_manage(opts?) -- open manage-worktrees picker (has_worktree filter)
gw.branches(opts?)      -- open branch management picker
```

Each function accepts an optional `opts` table that overrides the global config for
that single invocation.
