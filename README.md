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
- Every destructive step confirms first, defaulting to "No"
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
    -- enable_default_keymaps = false by default, so no built-in keymaps are
    -- registered; the keys = {} table above covers all entry points.
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
  enable_default_keymaps = true, -- opt in to the built-in keymaps
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
  -- "absolute-gitdir"  - absolute path prefixed with the git common dir,
  --                      which for worktrees under it is just "absolute"
  -- "tilde-gitdir"     - absolute-gitdir with ~ substitution applied ("tilde")
  wt_path_display = "tilde",

  -- Base path template for new worktrees.
  -- A leading ~ and $ENV_VARS are expanded; relative paths are anchored to the
  -- git common directory.
  -- Supports {repo_name} and {repo_name_short} placeholders.
  -- See "Worktree Base Path Examples" below for concrete examples and how
  -- the resulting paths are shown in the picker.
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

  -- Buffer swap when switching worktrees via <CR>.
  --   false - leave the current buffer unchanged
  --   true  - automatically open the equivalent file in the new worktree
  --   "ask" - prompt before switching
  -- When the equivalent file does not exist, a file picker opens at the new
  -- worktree root instead. The <C-e>/<C-s>/<C-v>/<C-t> overrides always open a
  -- file (or fall back to the picker) regardless of this setting - see
  -- "In-picker Keybindings" below.
  swap_current_buffer = false,

  -- Vim command used to open the file when swap_current_buffer is true or "ask".
  -- false (or "") - only change cwd, do not open any file. Note that nil cannot be
  -- used for this: a nil value in the table passed to setup() leaves the default in
  -- place rather than clearing it.
  -- "edit" | "tabedit" | "vsplit" | "split" | false
  switch_file_command = "edit",

  -- Register the built-in keymaps when setup() is called.
  -- Defaults to false; set to true only when not managing keymaps via Lazy
  -- keys = {} or explicit vim.keymap.set calls.
  enable_default_keymaps = false,

  -- Timeout in ms for plugin notifications (vim.notify calls).
  -- nil means the notification handler uses its own default (e.g. 3 s in nvim-notify).
  notify_timeout = nil,

  -- Timeout in ms for the branch info popup opened by <C-o>.
  -- Set to 0 to keep it visible until dismissed.
  branch_info_timeout = 5000,

  -- Timeout in ms for the git-status popup shown before a force-delete confirm.
  -- 0 (default) keeps it visible until the confirm dialog is answered.
  status_win_timeout = 0,

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

## Worktree Base Path Examples

`wt_base_path_bare` and `wt_base_path_regular` control where `git worktree add`
creates new worktrees, and (via `wt_path_display`) how those paths are shown in the
picker. A new worktree is created at `<base_path>/<branch_name>` by default, so a
branch named `feat/foo` nests under `<base_path>/feat/foo`; `auto_worktree_path =
false` (the default) pre-fills this path into an editable prompt instead of using it
immediately.

All examples below use the same repo - a bare repo used as a worktree hub - and a
branch named `feat/foo`:

```text
~/Work/my-repo.git   (bare repo; git_common_dir == git_root)
```

Picker paths use the default `wt_path_display = "tilde"` unless noted otherwise.

**Absolute paths** are used as-is, regardless of where the repo lives:

| `wt_base_path_bare`       | New worktree path                  |
| ------------------------- | ---------------------------------- |
| `/Volumes/Work/worktrees` | `/Volumes/Work/worktrees/feat/foo` |

Picker (`tilde`): `/Volumes/Work/worktrees/feat/foo` - unchanged, since it is not
under `$HOME`.

**`~` and environment variables** are expanded before the path is classified, so a
template that starts with either is absolute too:

| `wt_base_path_bare`  | New worktree path             |
| -------------------- | ----------------------------- |
| `~/Work/worktrees`   | `~/Work/worktrees/feat/foo`   |
| `$WORKTREES/my-repo` | `$WORKTREES/my-repo/feat/foo` |

**Relative paths** are resolved against `git_common_dir`: the bare directory itself
for bare repos, or `<repo-root>/.git` for regular repos. The default `./wt` therefore
creates worktrees _inside_ the bare directory (bare repos) or inside `.git/` (regular
repos). For a regular clone of the same project at `~/Work/my-repo`:

| Config                          | Repo type | New worktree path                 |
| ------------------------------- | --------- | --------------------------------- |
| `wt_base_path_bare = "./wt"`    | bare      | `~/Work/my-repo.git/wt/feat/foo`  |
| `wt_base_path_regular = "./wt"` | regular   | `~/Work/my-repo/.git/wt/feat/foo` |

Picker (`tilde`): `~/Work/my-repo.git/wt/feat/foo` (bare) /
`~/Work/my-repo/.git/wt/feat/foo` (regular)

For regular repos, keeping worktrees under `.git/` (the default) is safe: `.git` is
never scanned by `git status` in the main worktree, so nested worktrees do not show up
as untracked files there. If you would rather keep worktrees outside `.git/` entirely,
e.g. to group several repos' worktrees under one shared directory, or to make them
visible to tools that do not expect a worktree inside another repo's `.git`, anchor
them next to the repo instead:

```lua
wt_base_path_regular = "../../worktrees/{repo_name}",
```

`git_common_dir` for a regular repo is one level deeper than for a bare repo (it is
`.git` _inside_ the working tree), so it takes two `..` to reach the same parent
directory a bare repo's `..` would reach in one step. `{repo_name}` (see below) here
expands to `my-repo`, keeping every repo's worktrees grouped under
`worktrees/<repo_name>`, alongside (not inside) the repo:

Picker (`tilde`): `~/Work/worktrees/my-repo/feat/foo`

**Relative paths outside the repository** use `..` segments to escape the anchor
directory; the resulting path is simplified, so no leftover `..` segments appear:

| Config                               | New worktree path           |
| ------------------------------------ | --------------------------- |
| `wt_base_path_bare = "../worktrees"` | `~/Work/worktrees/feat/foo` |

Picker (`tilde`): `~/Work/worktrees/feat/foo`
Picker (`relative-wt-base`): `./feat/foo`

`relative-wt-base` is often the more readable choice once worktrees live outside the
repo: every entry is shown relative to the shared base directory instead of repeating
the full path.

**`{repo_name}` placeholder** expands to the tail of the repo's working-tree root
directory name (for bare repos, the bare directory's own name, e.g. `my-repo.git`):

| Config                                           | New worktree path                       |
| ------------------------------------------------ | --------------------------------------- |
| `wt_base_path_bare = "../worktrees/{repo_name}"` | `~/Work/worktrees/my-repo.git/feat/foo` |

Picker (`tilde`): `~/Work/worktrees/my-repo.git/feat/foo`

This is useful when several repos share one `worktrees` directory: each repo gets its
own subdirectory named after it.

**`{repo_name_short}` placeholder** is `{repo_name}` with a trailing `.git` suffix
stripped:

| Config                                                 | New worktree path                   |
| ------------------------------------------------------ | ----------------------------------- |
| `wt_base_path_bare = "../worktrees/{repo_name_short}"` | `~/Work/worktrees/my-repo/feat/foo` |

Picker (`tilde`): `~/Work/worktrees/my-repo/feat/foo`

For bare repos named `<name>.git`, `{repo_name}` keeps the `.git` suffix and
`{repo_name_short}` drops it. Regular repos' working-tree directories rarely end in
`.git`, so the two placeholders are usually identical there.

## Default Keymaps (registered by setup when enable_default_keymaps = true)

| Key           | Action                                                        |
| ------------- | ------------------------------------------------------------- |
| `<leader>gwt` | All branches - switch to or create a worktree                 |
| `<leader>gwa` | Branches without a worktree - create one                      |
| `<leader>gwm` | Branches with a worktree - jump between or delete             |
| `<leader>gbm` | All branches - switch HEAD, delete, or fork (no worktree ops) |

## User Commands

| Command              | Description                                                                                                                                     |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `:GitWorktreeTotal`  | All branches regardless of worktree status. Switch to or create a worktree, delete it (simple or extended), or fork to a new branch + worktree. |
| `:GitWorktreeAdd`    | Only branches **without** a worktree. Create a worktree, fork the branch, or delete it (simple or extended).                                    |
| `:GitWorktreeManage` | Only branches **with** a worktree. Jump between worktrees, delete one (simple or extended), or fork to a new branch + worktree.                 |
| `:GitBranchManage`   | All branches. Switch HEAD, delete (local-only, remote-only, or full local+remote), or fork a branch.                                            |

## In-picker Keybindings

| Key                            | Pickers               | Action                                                                                                                                                                    |
| ------------------------------ | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `<CR>`                         | worktree,&nbsp;branch | Switch to worktree / branch (create worktree if missing); respects `switch_file_command`                                                                                  |
| <code>&lt;C&#8209;e&gt;</code> | worktree&nbsp;only    | Switch and open the current file with `edit`, ignoring `switch_file_command`                                                                                              |
| <code>&lt;C&#8209;s&gt;</code> | worktree&nbsp;only    | Switch and open the current file in a horizontal split, ignoring `switch_file_command`                                                                                    |
| <code>&lt;C&#8209;v&gt;</code> | worktree&nbsp;only    | Switch and open the current file in a vertical split, ignoring `switch_file_command`                                                                                      |
| <code>&lt;C&#8209;t&gt;</code> | worktree&nbsp;only    | Switch and open the current file in a new tab, ignoring `switch_file_command`                                                                                             |
| <code>&lt;C&#8209;x&gt;</code> | worktree,&nbsp;branch | Simple delete: local branch → delete local only; remote branch → delete remote only                                                                                       |
| <code>&lt;M&#8209;x&gt;</code> | worktree,&nbsp;branch | Extended delete: local → delete local then prompt to also delete remote; remote → delete remote then prompt to also delete local; worktree pickers: remove worktree first |
| <code>&lt;M&#8209;v&gt;</code> | worktree&nbsp;only    | Force path prompt even when `auto_worktree_path = true`                                                                                                                   |
| <code>&lt;C&#8209;o&gt;</code> | worktree,&nbsp;branch | Show branch info notification (branch, ref, worktree, author, date, `HEAD`&nbsp;commit)                                                                                   |
| <code>&lt;M&#8209;n&gt;</code> | worktree,branch       | Fork branch (worktree pickers: create branch + worktree; branch picker: branch only)                                                                                      |
| <code>&lt;M&#8209;g&gt;</code> | worktree,branch       | Cycle branch type: local → remote → all → local, to reveal remote-only branches                                                                                           |

The four file-open overrides (`<C-e>`, `<C-s>`, `<C-v>`, `<C-t>`) always switch to (or
create) the worktree and then try to open a file, regardless of `swap_current_buffer` -
pressing one of them is itself an explicit request to open something, so they ignore
`swap_current_buffer` entirely (no `"ask"` prompt either) and always use their own
command instead of `switch_file_command`. If there is no current buffer, the current
buffer is outside the worktree being left, or the equivalent file does not exist in the
new worktree, they fall back to a file picker at the new worktree root instead of doing
nothing. `<CR>` is the one key that respects `swap_current_buffer` (and, when it is
`true` or `"ask"`, `switch_file_command`) as configured.

Every step that removes something asks first, and each prompt defaults to `No`, so a
stray `<C-x>` cannot destroy anything. Deleting a worktree and deleting its branch are
separate questions, which is what makes `<C-x>` and `<M-x>` distinguishable in the
worktree pickers: `<C-x>` asks about the worktree and then offers the branch, while
`<M-x>` asks about the worktree, the local branch and the remote branch in turn. You can
answer `No` at any point and everything after it is skipped; anything already removed
stays removed.

`branch_type` defaults to `"local"`, so remote-tracking branches (e.g.
`origin/feat/foo`) are hidden until you press `<M-g>` to switch to `"remote"` or
`"all"`. Once visible, selecting a remote-only branch (`<CR>` or one of the file-open
overrides) creates a worktree for it exactly like a local branch would - `git worktree
add` recognises that `feat/foo` only exists as `origin/feat/foo` and automatically
creates a new local branch tracking it, checked out into the new worktree. This is the
fastest way to start working on a colleague's branch: cycle to `"remote"` or `"all"`,
find the branch, press `<CR>`.

## Submodules

Worktrees are not supported for git submodules. When the repository you are working in is
a submodule of another repository, the worktree pickers warn and do nothing:

```text
git-worktrees: this repository is a submodule of
/Users/me/Work/my-project
Worktrees are not supported for submodules - skipping.
Clone the submodule as a standalone repository to use worktrees with it.
```

The reason is that a submodule's git directory lives inside the superproject's, at
`<super>/.git/modules/<name>`. Since worktree base paths are anchored to the git common
directory, worktrees created from a submodule would land under the superproject's `.git`,
where normal tooling will not see them and `git submodule deinit` will delete them.

If you need worktrees for a repository that is used as a submodule somewhere, clone it on
its own and work in that standalone clone.

The repository is determined from the current buffer's file rather than from the cwd, so
opening `<super>/sub/file.lua` while the cwd is at `<super>` is recognised as the
submodule `sub`, not as the superproject. Working in the superproject itself is
unaffected, and so are ordinary and bare repositories. `:GitBranchManage` performs no
worktree operations and keeps working everywhere.

## Stash Transfer When Forking

When you press `<M-n>` to fork a branch from a worktree picker and the current worktree
has uncommitted changes (staged or unstaged tracked files), the plugin detects this and
offers three choices:

| Choice         | Behaviour                                                                                                                                                                                                                                            |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Move**       | Stash changes, create branch + worktree, apply stash in the new worktree. If the apply fails, reset the new worktree and restore the stash to the original. If even that fails, display an actionable error with the stash ref and recovery command. |
| **Leave here** | Proceed with the fork without touching the current changes (default).                                                                                                                                                                                |
| **Cancel**     | Abort the entire operation.                                                                                                                                                                                                                          |

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

gw.setup(opts)              -- initialize with config
gw.worktrees(opts?)         -- open worktree total picker
gw.worktrees_add(opts?)     -- open add-worktree picker (no_worktree filter)
gw.worktrees_manage(opts?)  -- open manage-worktrees picker (has_worktree filter)
gw.branches(opts?)          -- open branch management picker
```

Each function accepts an optional `opts` table that overrides the global config for
that single invocation.
