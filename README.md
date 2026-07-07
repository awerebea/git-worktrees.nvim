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

- **Worktree total** - browse all branches; switch to existing worktree or create one on the fly
- **Worktree add** - pre-filtered to branches without worktrees
- **Worktree manage** - pre-filtered to branches with worktrees
- **Branch manage** - switch, delete, or fork any local/remote branch
- Adaptive column layout (branch | path/flag | author | date) that collapses gracefully on narrow screens
- Live branch-type cycling (`<M-g>`) between local / remote / all without leaving the picker
- Optional buffer swap when switching worktrees
- Lifecycle hooks: `on_add`, `on_before_switch`, `on_switch`, `on_remove`

## Requirements

- Neovim >= 0.10
- [snacks.nvim](https://github.com/folke/snacks.nvim) with the `picker` module enabled

## Installation

### lazy.nvim (recommended)

```lua
{
  "awerebea/git-worktrees.nvim",
  -- OR local install:
  -- dir = "~/Github/git-worktrees.nvim",

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
    -- Called after a new worktree is created.
    on_add = nil,           -- function(branch: string, path: string)

    -- Called before switching worktrees. Return false to abort.
    on_before_switch = nil, -- function(from: string, to: string): boolean|nil

    -- Called after the cwd has changed to the new worktree.
    on_switch = nil,        -- function(from: string, to: string)

    -- Called after a worktree is removed.
    on_remove = nil,        -- function(branch: string, path: string)
  },
})
```

## Default Keymaps (registered by setup when disable_default_keymaps = false)

| Key           | Action                                     |
| ------------- | ------------------------------------------ |
| `<leader>gwt` | Worktree total (all branches)              |
| `<leader>gwa` | Add worktree (branches without worktrees)  |
| `<leader>gwm` | Manage worktrees (branches with worktrees) |
| `<leader>gbm` | Branch management                          |

## User Commands

| Command              | Description                                   |
| -------------------- | --------------------------------------------- |
| `:GitWorktreeTotal`  | Worktree total picker                         |
| `:GitWorktreeAdd`    | Add-worktree picker (no worktree filter)      |
| `:GitWorktreeManage` | Manage-worktrees picker (has worktree filter) |
| `:GitBranchManage`   | Branch management picker                      |

## In-picker Keybindings

| Key     | Action                                                                               |
| ------- | ------------------------------------------------------------------------------------ |
| `<CR>`  | Switch to worktree / branch (create worktree if missing)                             |
| `<C-x>` | Delete worktree or branch                                                            |
| `<A-v>` | Force path prompt even when `auto_worktree_path = true`                              |
| `<C-o>` | Show branch info notification                                                        |
| `<A-n>` | Fork branch (worktree pickers: create branch + worktree; branch picker: branch only) |
| `<M-g>` | Cycle branch type: local -> remote -> all -> local                                   |

## Hook Examples

### Notify on switch

```lua
hooks = {
  on_switch = function(from, to)
    vim.notify("Switched: " .. from .. " -> " .. to)
  end,
}
```

### Abort switch when branch has certain prefix

```lua
hooks = {
  on_before_switch = function(from, to)
    -- Prevent accidentally switching to a WIP worktree
    if to:find("/wip/") then
      vim.notify("Switch aborted: WIP worktrees are protected", vim.log.levels.WARN)
      return false
    end
  end,
}
```

### Open a terminal in the new worktree after switching

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

### Log all worktree additions

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

### Switch all open windows to the equivalent file in the new worktree

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

### Using plenary.path for path operations (from Juksuu/worktrees.nvim example)

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
