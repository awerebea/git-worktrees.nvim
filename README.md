# git-worktrees.nvim

A Snacks-picker-based interface for Git worktrees and branch management inside Neovim.

Browse branches in a picker, switch to or create a worktree for any of them, delete
worktrees and branches (local, remote, or both), and fork a branch into a new worktree -
all without leaving Neovim.

<details>
<summary>Inspired by and built on the shoulders of</summary>

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

</details>

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Commands](#commands)
- [Keymaps](#keymaps)
- [Configuration](#configuration)
- [Configuration Examples](#configuration-examples)
- [Worktree Base Paths](#worktree-base-paths)
- [Behaviour in Detail](#behaviour-in-detail)
- [Hooks](#hooks)
- [API](#api)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)

The same reference is available offline as `:help git-worktrees`, with a tag for every
configuration option (e.g. `:help git-worktrees-enable_default_keymaps`).

## Features

- **Worktree total** - browse all branches; switch to or create a worktree, delete it, or
  fork to a new branch + worktree
- **Worktree add** - pre-filtered to branches without worktrees; create, fork, or delete
  the selected branch
- **Worktree manage** - pre-filtered to branches with worktrees; jump between, delete, or
  fork
- **Branch manage** - switch, delete (local or remote), or fork any local/remote branch
  (no worktree operations)
- Simple delete (`<C-x>`) removes only the selected branch type; extended delete (`<M-x>`)
  removes the selected side first, then offers the counterpart
- Every destructive step confirms first, defaulting to `No`
- Adaptive column layout (branch | path/flag | author | date) that collapses gracefully on
  narrow screens
- Live branch-type cycling (`<M-g>`) between local / remote / all without leaving the
  picker
- Remote branches resolve to their local counterpart's worktree, with a warning when that
  worktree is behind the remote
- Optional buffer swap when switching worktrees
- Lifecycle hooks: `before_switch`, `on_switch`, `on_add`, `on_delete`
- Works in bare repos, regular repos, and linked worktrees

## Requirements

- Neovim >= 0.10
- [snacks.nvim](https://github.com/folke/snacks.nvim) - installing it is enough; see the
  note below
- `git` available on `$PATH`

[plenary.nvim](https://github.com/nvim-lua/plenary.nvim) is **not** required by the plugin
itself; one optional hook example in this README uses it.

> [!NOTE]
> You do **not** have to configure snacks.nvim or enable its `picker` module. snacks.nvim
> ships a `plugin/snacks.lua` that runs `require("snacks")`, which defines the `Snacks`
> global, and `Snacks.picker` is resolved on first access through a metatable. The picker
> API therefore works even with <code>picker&nbsp;=&nbsp;{&nbsp;enabled&nbsp;=&nbsp;false&nbsp;}</code> in `Snacks.setup()` - that
> flag only controls whether snacks takes over `vim.ui.select`. Listing snacks.nvim in
> `dependencies` is all that is needed, and lazy.nvim loads a dependency before the plugin
> that declares it.

## Installation

`setup()` must run for the user commands and the built-in keymaps to exist. Every example
below calls it.

### lazy.nvim (recommended)

```lua
{
  "awerebea/git-worktrees.nvim",
  dependencies = { "folke/snacks.nvim" },

  -- Lazy-load on first keypress or command. No event = "VeryLazy" needed:
  -- keys/cmd already cover both entry points.
  keys = {
    {
      "<leader>gwt",
      function()
        require("git-worktrees").worktrees()
      end,
      desc = "Worktree total",
    },
    {
      "<leader>gwa",
      function()
        require("git-worktrees").worktrees_add()
      end,
      desc = "Worktree add",
    },
    {
      "<leader>gwm",
      function()
        require("git-worktrees").worktrees_manage()
      end,
      desc = "Worktree manage",
    },
    {
      "<leader>gbm",
      function()
        require("git-worktrees").branches()
      end,
      desc = "Branch management",
    },
  },
  cmd = { "GitWorktreeTotal", "GitWorktreeAdd", "GitWorktreeManage", "GitBranchManage" },
  opts = {
    -- The keys = {} table above already defines the mappings,
    -- so leave the plugin's built-in ones off.
    -- This is the default, and is spelled out here only to make the interaction explicit.
    enable_default_keymaps = false,
  },
}
```

`opts` is enough - lazy.nvim derives the module name from the plugin directory and calls
`require("git-worktrees").setup(opts)` for you. An explicit `config` function works too:

```lua
  config = function(_, opts)
    require("git-worktrees").setup(opts)
  end,
```

> [!IMPORTANT]
> `keys = {}` and `enable_default_keymaps` are independent mechanisms. Setting the option
> to `true` while also defining `keys` entries registers **both** sets. Where the two use
> the same left-hand side, whichever is registered last wins, which depends on load order
>
> - so pick one mechanism rather than mixing them. See
>   [Configuration Examples](#configuration-examples).

<details>
<summary>lazy.nvim using the built-in keymaps instead</summary>

Drop `keys = {}` and opt into the plugin's own mappings. The plugin must then be loaded
before those mappings exist, so give lazy another trigger - `cmd` alone will not fire when
you press `<leader>gwt`:

```lua
{
  "awerebea/git-worktrees.nvim",
  dependencies = { "folke/snacks.nvim" },
  event = "VeryLazy",
  cmd = { "GitWorktreeTotal", "GitWorktreeAdd", "GitWorktreeManage", "GitBranchManage" },
  opts = { enable_default_keymaps = true },
}
```

See [Default Keymaps](#default-keymaps) for what they are.

</details>

<details>
<summary>Other plugin managers</summary>

**Without a plugin manager** (or from your `init.lua`):

```lua
require("git-worktrees").setup({
  enable_default_keymaps = true, -- opt in to the built-in keymaps
})
```

**packer.nvim:**

```lua
use({
  "awerebea/git-worktrees.nvim",
  requires = { "folke/snacks.nvim" },
  config = function()
    require("git-worktrees").setup({
      enable_default_keymaps = true,
    })
  end,
})
```

**vim-plug** (plugin declaration in Vimscript, configuration in Lua):

```vim
Plug 'folke/snacks.nvim'
Plug 'awerebea/git-worktrees.nvim'
```

```lua
require("git-worktrees").setup({
  enable_default_keymaps = true,
})
```

</details>

## Quick Start

1. Install the plugin and ensure `setup()` runs (see [Installation](#installation)).
2. Open Neovim inside a git repository and run `:GitWorktreeTotal`.
3. Pick a branch and press `<CR>`:
   - the branch already has a worktree → Neovim's cwd changes to it
   - it does not → you are prompted for a path, then the worktree is created and entered
4. Press `<M-g>` to cycle `local` → `remote` → `all` and reveal remote-only branches.
5. Press `<C-o>` on any row for branch details, `<C-x>` to delete, `<M-n>` to fork.

By default new worktrees are created under the repository's git directory
(`<repo>/.git/wt/<branch>`, or `<repo>.git/wt/<branch>` for bare repos). See
[Worktree Base Paths](#worktree-base-paths) to change that.

## Commands

Registered by `setup()`, always - independently of `enable_default_keymaps`.

| Command              | Description                                                                                                                                     |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `:GitWorktreeTotal`  | All branches regardless of worktree status. Switch to or create a worktree, delete it (simple or extended), or fork to a new branch + worktree. |
| `:GitWorktreeAdd`    | Only branches **without** a worktree. Create a worktree, fork the branch, or delete it (simple or extended).                                    |
| `:GitWorktreeManage` | Only branches **with** a worktree. Jump between worktrees, delete one (simple or extended), or fork to a new branch + worktree.                 |
| `:GitBranchManage`   | All branches. Switch HEAD, delete (local-only, remote-only, or full local+remote), or fork a branch. Performs no worktree operations.           |

Each command has a matching Lua function - see [API](#api).

## Keymaps

### Default Keymaps

Registered by `setup()` **only** when `enable_default_keymaps = true`. The default is
`false`, so out of the box this plugin sets no keymaps at all.

| Key           | Runs                                                   |
| ------------- | ------------------------------------------------------ |
| `<leader>gwt` | **G**it **W**orktree **T**otal - `:GitWorktreeTotal`   |
| `<leader>gwa` | **G**it **W**orktree **A**dd - `:GitWorktreeAdd`       |
| `<leader>gwm` | **G**it **W**orktree **M**anage - `:GitWorktreeManage` |
| `<leader>gbm` | **G**it **B**ranch **M**anage - `:GitBranchManage`     |

All four are normal-mode mappings.

### In-picker Keybindings

Active while a picker is open. These are **not** configurable.

| &nbsp;&nbsp;&nbsp;Key&nbsp;&nbsp;&nbsp;&nbsp; | Pickers               | Action                                                                                                                                               |
| --------------------------------------------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `<CR>`                                        | worktree,&nbsp;branch | Switch to worktree / branch (create the worktree if missing); respects `swap_current_buffer` and `switch_file_command`                               |
| `<C-e>`                                       | worktree&nbsp;only    | Switch and open the current file with `edit`, ignoring `switch_file_command`                                                                         |
| `<C-s>`                                       | worktree&nbsp;only    | Switch and open the current file in a horizontal split, ignoring `switch_file_command`                                                               |
| `<C-v>`                                       | worktree&nbsp;only    | Switch and open the current file in a vertical split, ignoring `switch_file_command`                                                                 |
| `<C-t>`                                       | worktree&nbsp;only    | Switch and open the current file in a new tab, ignoring `switch_file_command`                                                                        |
| `<C-x>`                                       | worktree,&nbsp;branch | Simple delete: local branch → delete local only; remote branch → delete remote only                                                                  |
| `<M-x>`                                       | worktree,&nbsp;branch | Extended delete: local → delete local then offer the remote; remote → delete remote then offer the local; worktree pickers remove the worktree first |
| `<M-v>`                                       | worktree&nbsp;only    | Force the path prompt even when `auto_worktree_path = true`                                                                                          |
| `<C-o>`                                       | worktree,&nbsp;branch | Show a branch info popup (branch, worktree, author, dates, `HEAD`&nbsp;commit, message) without closing the picker                                   |
| `<M-n>`                                       | worktree,&nbsp;branch | Fork branch (worktree pickers: create branch + worktree; branch picker: branch only)                                                                 |
| `<M-g>`                                       | worktree,&nbsp;branch | Cycle branch type: local → remote → all → local, to reveal remote-only branches                                                                      |

The four file-open overrides (`<C-e>`, `<C-s>`, `<C-v>`, `<C-t>`) always switch to (or
create) the worktree and then try to open a file, regardless of `swap_current_buffer` -
pressing one of them is itself an explicit request to open something, so they ignore
`swap_current_buffer` entirely (no `"ask"` prompt either) and always use their own command
instead of `switch_file_command`. If there is no current buffer, the current buffer is
outside the worktree being left, or the equivalent file does not exist in the new worktree,
they fall back to a file picker at the new worktree root instead of doing nothing. `<CR>`
is the one key that respects `swap_current_buffer` as configured.

Every step that removes something asks first, and each prompt defaults to `No`, so a stray
`<C-x>` cannot destroy anything. Deleting a worktree and deleting its branch are separate
questions, which is what makes `<C-x>` and `<M-x>` distinguishable in the worktree pickers:
`<C-x>` asks about the worktree and then offers the branch, while `<M-x>` asks about the
worktree, the local branch and the remote branch in turn. You can answer `No` at any point
and everything after it is skipped; anything already removed stays removed.

## Configuration

Pass any subset of these to `setup()`. Unspecified options keep their defaults.

| Option                   | Type                       | Default            | Description                                                                                                                       |
| ------------------------ | -------------------------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| `wt_path_display`        | `string`                   | `"tilde"`          | How worktree paths are shown in the picker. See [Path display modes](#path-display-modes).                                        |
| `wt_base_path_bare`      | `string`                   | `"./wt"`           | Where new worktrees are created in **bare** repos. See [Worktree Base Paths](#worktree-base-paths).                               |
| `wt_base_path_regular`   | `string`                   | `"./wt"`           | Where new worktrees are created in **regular** repos. See [Worktree Base Paths](#worktree-base-paths).                            |
| `auto_worktree_path`     | `boolean`                  | `false`            | `false` pre-fills the path into an editable prompt; `true` uses `<base_path>/<branch>` without asking.                            |
| `branch_type`            | `"local"\|"remote"\|"all"` | `"local"`          | Branch scope a picker opens with. Cycle live with `<M-g>`.                                                                        |
| `sort_by`                | `string`                   | `"-committerdate"` | Sort key passed to `git for-each-ref --sort`. Prefix with `-` for descending.                                                     |
| `date_format`            | `string`                   | `"relative"`       | Date column format, used as `committerdate:<value>`. E.g. `"short"`, `"iso"`, `"format:%Y-%m-%d"`.                                |
| `author_format`          | `"name"\|"email"`          | `"name"`           | Author column source: `committername` or `committeremail`.                                                                        |
| `swap_current_buffer`    | `boolean\|"ask"`           | `false`            | On `<CR>`: `false` leaves the buffer, `true` opens the equivalent file in the new worktree, `"ask"` prompts first.                |
| `switch_file_command`    | `string\|false`            | `"edit"`           | Vim command used to open that file. `false` or `""` changes cwd only. See the note below.                                         |
| `enable_default_keymaps` | `boolean`                  | `false`            | Registers the [built-in keymaps](#default-keymaps) when `setup()` runs. Leave `false` if you define your own mappings.            |
| `notify_timeout`         | `integer\|nil`             | `nil`              | Timeout in ms for this plugin's notifications. `nil` lets the notification handler use its own default.                           |
| `branch_info_timeout`    | `integer`                  | `5000`             | Timeout in ms for the `<C-o>` branch info popup. `0` keeps it until dismissed.                                                    |
| `status_win_timeout`     | `integer`                  | `0`                | Timeout in ms for the <code>git&nbsp;status</code> popup shown before a force-delete. `0` keeps it until the confirm is answered. |
| `hooks`                  | `table`                    | `{}`               | Lifecycle callbacks. See [Hooks](#hooks).                                                                                         |

By area: `enable_default_keymaps` is the only option that affects **keymaps**; the user
commands are always registered and are not configurable. `wt_path_display`,
`branch_info_timeout`, `status_win_timeout` and `notify_timeout` affect **UI** only.
`wt_base_path_*`, `auto_worktree_path`, `branch_type`, `sort_by`, `date_format` and
`author_format` affect **git operations and listing**. `swap_current_buffer` and
`switch_file_command` affect **buffer handling**. `hooks` is the **integration** point.

> [!NOTE]
> `switch_file_command` cannot be disabled with `nil`. A `nil` value in the table passed to
> `setup()` leaves the default in place rather than clearing it, because that is how table
> merging works in Lua. Use `false` (or `""`) to change cwd without opening a file.

<details>
<summary>The same reference as an annotated <code>setup()</code> call</summary>

```lua
require("git-worktrees").setup({
  -- How worktree paths are displayed in the picker.
  wt_path_display = "tilde",

  -- Base path template for new worktrees.
  -- A leading ~ and $ENV_VARS are expanded; relative paths are anchored to the
  -- git common directory. Supports {repo_name} and {repo_name_short}.
  wt_base_path_bare    = "./wt",
  wt_base_path_regular = "./wt",

  -- false - show a pre-filled, editable prompt
  -- true  - use <base_path>/<branch_name> without prompting
  auto_worktree_path = false,

  -- Branch scope a picker opens with; cycle live with <M-g>.
  -- "local" | "remote" | "all"
  branch_type = "local",

  -- Any value accepted by git for-each-ref --sort.
  -- "-committerdate" | "-authordate" | "refname" | "-version:refname"
  sort_by = "-committerdate",

  -- Date column format, used as committerdate:<value>.
  -- "relative" | "short" | "iso" | "human" | "format:STRFTIME"
  date_format = "relative",

  -- Author column field: "name" -> committername, "email" -> committeremail
  author_format = "name",

  -- Buffer swap when switching worktrees via <CR>.
  --   false - leave the current buffer unchanged
  --   true  - open the equivalent file in the new worktree
  --   "ask" - prompt before opening
  -- When the equivalent file does not exist, a file picker opens at the new
  -- worktree root instead. The <C-e>/<C-s>/<C-v>/<C-t> overrides always open a
  -- file (or fall back to the picker) regardless of this setting.
  swap_current_buffer = false,

  -- Vim command used to open the file when swap_current_buffer is true or
  -- "ask".
  -- "edit" | "tabedit" | "vsplit" | "split" | false
  -- false (or "") changes cwd only. nil does NOT disable it - see the note
  -- above.
  switch_file_command = "edit",

  -- Register the built-in keymaps. Leave false when you define your own.
  enable_default_keymaps = false,

  -- Timeout in ms for this plugin's notifications.
  -- nil means the notification handler uses its own default
  -- (e.g. 3 s in nvim-notify).
  notify_timeout = nil,

  -- Timeout in ms for the branch info popup opened by <C-o>.
  -- 0 = until dismissed.
  branch_info_timeout = 5000,

  -- Timeout in ms for the git-status popup shown before a force-delete confirm.
  -- 0 keeps it visible until the confirm dialog is answered.
  status_win_timeout = 0,

  -- Lifecycle hooks. All optional.
  hooks = {
    -- Return false to abort the switch.
    before_switch = nil, -- function(from: string, to: string): boolean|nil
    on_switch     = nil, -- function(from: string, to: string)
    on_add        = nil, -- function(branch: string, path: string)
    on_delete     = nil, -- function(branch: string, path: string)
  },
})
```

</details>

### Path display modes

Values for `wt_path_display`:

| Mode                 | Shows                                                                      |
| -------------------- | -------------------------------------------------------------------------- |
| `"tilde"` (default)  | Absolute path with `$HOME` collapsed to `~`                                |
| `"absolute"`         | Full absolute path                                                         |
| `"relative-cwd"`     | Relative to Neovim's current working directory                             |
| `"relative-home"`    | Relative to cwd, with `$HOME` shown as `~`                                 |
| `"relative-repo"`    | Relative to the repo's working-tree root (bare repos: the bare directory)  |
| `"relative-wt-base"` | Relative to the configured worktree base path - often just the branch name |
| `"relative-gitdir"`  | Relative to the git common directory (`.git` for non-bare repos)           |
| `"absolute-gitdir"`  | Same result as `"absolute"`, kept for compatibility                        |
| `"tilde-gitdir"`     | Same result as `"tilde"`, kept for compatibility                           |

A path made only of parent segments gets a trailing slash, so `.`, `..` and `../..`
display as `./`, `../` and `../../`.

## Configuration Examples

### Use the built-in keymaps

```lua
require("git-worktrees").setup({
  enable_default_keymaps = true,
})
```

### Define your own keymaps instead

Leave `enable_default_keymaps` at its default of `false` and map the
[API functions](#api) yourself:

```lua
local gw = require("git-worktrees")

gw.setup({}) -- or setup() with your other options

vim.keymap.set("n", "<leader>wt", function() gw.worktrees() end,
  { desc = "Worktree total" })
vim.keymap.set("n", "<leader>wa", function() gw.worktrees_add() end,
  { desc = "Worktree add" })
```

With lazy.nvim, prefer its `keys = {}` table so the plugin stays lazy-loaded - see
[Installation](#installation).

### Override a single option

Everything you do not mention keeps its default:

```lua
require("git-worktrees").setup({
  auto_worktree_path = true, -- stop asking for the path
})
```

### Keep worktrees outside the repository

```lua
require("git-worktrees").setup({
  wt_base_path_bare    = "../worktrees/{repo_name_short}",
  wt_base_path_regular = "../../worktrees/{repo_name}",
  wt_path_display      = "relative-wt-base",
})
```

<details>
<summary>Fully customised configuration</summary>

```lua
require("git-worktrees").setup({
  -- Worktrees live in one shared directory, one subdirectory per repo,
  -- and are shown relative to it so rows stay short.
  wt_base_path_bare    = "~/Work/worktrees/{repo_name_short}",
  wt_base_path_regular = "~/Work/worktrees/{repo_name}",
  wt_path_display      = "relative-wt-base",
  auto_worktree_path   = true,

  -- Show every branch, newest authored first, with dates as ISO and
  -- authors as email addresses.
  branch_type   = "all",
  sort_by       = "-authordate",
  date_format   = "iso",
  author_format = "email",

  -- Follow the current file into the new worktree, opening it in a
  -- vertical split.
  swap_current_buffer = true,
  switch_file_command = "vsplit",

  -- Own keymaps, so leave the built-ins off.
  enable_default_keymaps = false,

  -- Keep popups on screen a little longer.
  notify_timeout      = 5000,
  branch_info_timeout = 0,
  status_win_timeout  = 0,

  hooks = {
    on_switch = function(from, to)
      vim.notify("Switched: " .. from .. " -> " .. to)
    end,
  },
})
```

</details>

### Per-invocation overrides

Every API function takes an optional table that overrides the global config for that call
only:

```lua
-- Open the total picker showing all branches this once, without changing
-- the stored default
require("git-worktrees").worktrees({ branch_type = "all" })
```

## Worktree Base Paths

`wt_base_path_bare` and `wt_base_path_regular` control where `git worktree add` creates new
worktrees, and (via `wt_path_display`) how those paths are shown in the picker. A new
worktree is created at `<base_path>/<branch_name>`, so a branch named `feat/foo` nests
under `<base_path>/feat/foo`. With `auto_worktree_path = false` (the default) that path is
pre-filled into an editable prompt rather than used immediately.

How a template is resolved:

1. `{repo_name}` and `{repo_name_short}` are substituted.
2. A leading `~` and any `$VAR` references are expanded.
3. What remains is used as-is if it starts with `/`, and anchored to the repo's **git
   common directory** otherwise.
4. `.` and `..` segments are collapsed, so an escaping template leaves none behind.

<details>
<summary>Worked examples, all for a branch named <code>feat/foo</code></summary>

All examples use the same repo - a bare repo used as a worktree hub:

```text
~/Work/my-repo.git   (bare repo; git_common_dir == git_root)
```

Picker paths use the default `wt_path_display = "tilde"` unless noted otherwise.

**Absolute paths** are used as-is, regardless of where the repo lives:

| `wt_base_path_bare`       | New worktree path                  |
| ------------------------- | ---------------------------------- |
| `/Volumes/Work/worktrees` | `/Volumes/Work/worktrees/feat/foo` |

Picker (`tilde`): `/Volumes/Work/worktrees/feat/foo` - unchanged, since it is not under
`$HOME`.

**`~` and environment variables** are expanded before the path is classified, so a template
that starts with either is absolute too:

| `wt_base_path_bare`  | New worktree path             |
| -------------------- | ----------------------------- |
| `~/Work/worktrees`   | `~/Work/worktrees/feat/foo`   |
| `$WORKTREES/my-repo` | `$WORKTREES/my-repo/feat/foo` |

**Relative paths** are resolved against `git_common_dir`: the bare directory itself for
bare repos, or `<repo-root>/.git` for regular repos. The default `./wt` therefore creates
worktrees _inside_ the bare directory (bare repos) or inside `.git/` (regular repos). For a
regular clone of the same project at `~/Work/my-repo`:

| Config                          | Repo type | New worktree path                 |
| ------------------------------- | --------- | --------------------------------- |
| `wt_base_path_bare = "./wt"`    | bare      | `~/Work/my-repo.git/wt/feat/foo`  |
| `wt_base_path_regular = "./wt"` | regular   | `~/Work/my-repo/.git/wt/feat/foo` |

For regular repos, keeping worktrees under `.git/` (the default) is safe: `.git` is never
scanned by `git status` in the main worktree, so nested worktrees do not show up as
untracked files there. If you would rather keep worktrees outside `.git/` entirely - to
group several repos' worktrees under one shared directory, or to make them visible to tools
that do not expect a worktree inside another repo's `.git` - anchor them next to the repo
instead:

```lua
wt_base_path_regular = "../../worktrees/{repo_name}",
```

`git_common_dir` for a regular repo is one level deeper than for a bare repo (it is `.git`
_inside_ the working tree), so it takes two `..` to reach the same parent directory a bare
repo's `..` reaches in one step.

**Relative paths outside the repository** use `..` segments to escape the anchor directory;
the resulting path is simplified, so no leftover `..` segments appear:

| Config                               | New worktree path           |
| ------------------------------------ | --------------------------- |
| `wt_base_path_bare = "../worktrees"` | `~/Work/worktrees/feat/foo` |

Picker (`tilde`): `~/Work/worktrees/feat/foo`
Picker (`relative-wt-base`): `./feat/foo`

`relative-wt-base` is often the more readable choice once worktrees live outside the repo:
every entry is shown relative to the shared base directory instead of repeating the full
path.

**`{repo_name}`** expands to the tail of the repo's working-tree root directory name (for
bare repos, the bare directory's own name, e.g. `my-repo.git`):

| Config                                           | New worktree path                       |
| ------------------------------------------------ | --------------------------------------- |
| `wt_base_path_bare = "../worktrees/{repo_name}"` | `~/Work/worktrees/my-repo.git/feat/foo` |

**`{repo_name_short}`** is `{repo_name}` with a trailing `.git` stripped:

| Config                                                 | New worktree path                   |
| ------------------------------------------------------ | ----------------------------------- |
| `wt_base_path_bare = "../worktrees/{repo_name_short}"` | `~/Work/worktrees/my-repo/feat/foo` |

For bare repos named `<name>.git`, `{repo_name}` keeps the `.git` suffix and
`{repo_name_short}` drops it. Regular repos' working-tree directories rarely end in `.git`,
so the two placeholders are usually identical there.

</details>

## Behaviour in Detail

### Remote branches

`branch_type` defaults to `"local"`, so remote-tracking branches (e.g. `origin/feat/foo`)
are hidden until you press `<M-g>` to switch to `"remote"` or `"all"`. Once visible,
selecting a remote-only branch creates a worktree for it exactly like a local branch would

- `git worktree add` recognises that `feat/foo` only exists as `origin/feat/foo` and
  automatically creates a new local branch tracking it. This is the fastest way to start on a
  colleague's branch: cycle to `"remote"` or `"all"`, find the branch, press `<CR>`.

A remote branch whose local counterpart already exists behaves differently, because
`git worktree add` resolves a branch name to the existing local branch:

- **The counterpart already has a worktree.** The remote row points at that worktree, so
  `<CR>` switches to it instead of failing with
  `fatal: 'x' is already used by worktree at ...`. Such rows are therefore listed by
  `:GitWorktreeManage` and left out of `:GitWorktreeAdd`. If that worktree is behind the
  remote branch, the plugin says so and offers to reset it first, defaulting to no; the
  branch is checked out there, so the reset is a `git reset --hard` in that worktree and
  any uncommitted changes are listed in the prompt before you answer.
- **The counterpart exists, has no worktree, and is behind the remote.** The new worktree
  would check out the older local state. The plugin says how far behind it is and offers to
  reset the local branch to the remote branch first, defaulting to no; declining creates
  the worktree from the local branch as before. If the local branch also has commits the
  remote does not, the prompt says how many would be discarded.

The link between a remote branch and its local counterpart comes from the branch's
configured upstream, so it holds even when the local branch is named differently from the
branch it tracks. If several local branches track one remote branch and more than one has a
worktree, the one named like the remote branch wins, and otherwise the alphabetically first

- branch names are unique, so the choice never depends on ordering. Both rows show that
  worktree in the path column, since that is where `<CR>` goes from either; `<C-o>` on the
  remote row names the local branch that owns it whenever that is not simply the remote
  branch's own name.

`<remote>/HEAD` is not listed: it is a symbolic ref pointing at another branch rather than a
branch of its own.

### Submodules

Worktrees are not supported for git submodules. When the repository you are working in is a
submodule of another repository, the worktree pickers warn and do nothing:

```text
git-worktrees: this repository is a submodule of
/Users/me/Work/my-project
Worktrees are not supported for submodules - skipping.
Clone the submodule as a standalone repository to use worktrees with it.
```

A submodule's git directory lives inside the superproject's, at
`<super>/.git/modules/<name>`. Since worktree base paths are anchored to the git common
directory, worktrees created from a submodule would land under the superproject's `.git`,
where normal tooling will not see them and `git submodule deinit` will delete them.

The repository is determined from the current buffer's file rather than from the cwd, so
opening `<super>/sub/file.lua` while the cwd is at `<super>` is recognised as the submodule
`sub`, not as the superproject. Working in the superproject itself is unaffected, and so are
ordinary and bare repositories. `:GitBranchManage` performs no worktree operations and keeps
working everywhere.

### Stash transfer when forking

When you press `<M-n>` to fork a branch from a worktree picker and the current worktree has
uncommitted changes (staged or unstaged tracked files), the plugin offers three choices:

| Choice              | Behaviour                                                                                                                                                                                                                    |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Move**            | Stash changes, create branch + worktree, apply stash in the new worktree. If the apply fails, reset the new worktree and restore the stash to the original. If even that fails, report the stash ref and a recovery command. |
| **Leave&nbsp;here** | Proceed with the fork without touching the current changes (default).                                                                                                                                                        |
| **Cancel**          | Abort the entire operation.                                                                                                                                                                                                  |

If worktree creation fails after the branch was already created (git error, or you cancel
the path prompt), the plugin deletes the orphaned branch and restores any pending stash to
the original worktree.

This mirrors the companion [fzf-git-branches](https://github.com/awerebea/fzf-git-branches)
shell script.

## Hooks

All four are optional functions passed under `hooks`:

| Hook            | Signature                          | When                                          |
| --------------- | ---------------------------------- | --------------------------------------------- |
| `before_switch` | `function(from, to): boolean\|nil` | Before switching. Return `false` to abort.    |
| `on_switch`     | `function(from, to)`               | After the cwd has changed to the new worktree |
| `on_add`        | `function(branch, path)`           | After a new worktree is created               |
| `on_delete`     | `function(branch, path)`           | After a worktree is deleted                   |

`from` and `to` are absolute paths. An error thrown inside a hook is caught and reported as
a warning rather than aborting the operation.

<details>
<summary>Abort a switch when the path matches a pattern (before_switch)</summary>

```lua
hooks = {
  before_switch = function(from, to)
    -- Prevent accidentally switching to a WIP worktree
    if to:find("/wip/") then
      vim.notify("Switch aborted: WIP worktrees are protected",
        vim.log.levels.WARN)
      return false
    end
  end,
}
```

</details>

<details>
<summary>Notify on switch (on_switch)</summary>

```lua
hooks = {
  on_switch = function(from, to)
    vim.notify("Switched: " .. from .. " -> " .. to)
  end,
}
```

</details>

<details>
<summary>Open a terminal in the new worktree after switching (on_switch)</summary>

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

</details>

<details>
<summary>Log all worktree additions (on_add)</summary>

```lua
hooks = {
  on_add = function(branch, path)
    local file = vim.fn.expand("~/.local/share/nvim/worktree_log.txt")
    local log = io.open(file, "a")
    if log then
      log:write(os.date("%Y-%m-%d %H:%M:%S") .. "  ADD  " ..
        branch .. "  " .. path .. "\n")
      log:close()
    end
  end,
}
```

</details>

<details>
<summary>Switch all open windows to the equivalent file in the new worktree (on_switch)</summary>

Mirrors every window to the corresponding file in the new worktree, closing windows whose
files do not exist there.

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

</details>

<details>
<summary>The same with <code>plenary.path</code> (from the <a href="https://github.com/Juksuu/worktrees.nvim">Juksuu/worktrees.nvim</a> example)</summary>

Requires [plenary.nvim](https://github.com/nvim-lua/plenary.nvim).

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

</details>

## API

```lua
local gw = require("git-worktrees")

gw.setup(opts)              -- initialize; creates the user commands
gw.worktrees(opts?)         -- same as :GitWorktreeTotal
gw.worktrees_add(opts?)     -- same as :GitWorktreeAdd
gw.worktrees_manage(opts?)  -- same as :GitWorktreeManage
gw.branches(opts?)          -- same as :GitBranchManage
```

`setup()` also creates the built-in keymaps when `enable_default_keymaps` is true. The
four picker functions accept an optional `opts` table that overrides the global config for
that single invocation, and `gw.config` holds the merged configuration afterwards.

## Troubleshooting

**`:GitWorktreeTotal` is not a command.** `setup()` has not run. The commands are created
inside it, so a plugin spec without `opts`, `config = true` or an explicit `config` function
never registers them.

**The plugin sets keymaps I did not ask for.** `enable_default_keymaps` is `true` somewhere
in your config. It defaults to `false`; see
[Configuration Examples](#configuration-examples).

**My own mapping and a built-in one both point at the same key.** They are separate
mechanisms and both get registered - the later one wins, which depends on load order. Use
either `keys = {}` / `vim.keymap.set` or `enable_default_keymaps = true`, not both.

**"not inside a git repository".** The picker uses Neovim's current working directory. Check
`:pwd`.

**"this repository is a submodule of ...".** Working by design; see
[Submodules](#submodules).

**New worktrees appear inside `.git/`.** That is the default anchor. See
[Worktree Base Paths](#worktree-base-paths) to move them.

**`switch_file_command = nil` did not disable file opening.** Use `false`. A `nil` in the
table passed to `setup()` cannot clear a default.

**`attempt to index global 'Snacks' (a nil value)`.** snacks.nvim is not installed, or is
not loaded yet. It does not need configuring - see the note under
[Requirements](#requirements) - but it does need to be on the runtimepath. If you load it
lazily yourself, make sure it is listed in this plugin's `dependencies` so your plugin
manager loads it first. There is no fallback picker.

**I want different in-picker keys.** They are not configurable; see
[In-picker Keybindings](#in-picker-keybindings).

## FAQ

**Does it work with bare repositories?**
Yes - that is the primary workflow. `wt_base_path_bare` controls where worktrees go, and
the bare directory itself is treated as the repo root.

**Where are worktrees created by default?**
`<repo>/.git/wt/<branch>` for regular repos, `<repo>.git/wt/<branch>` for bare ones. Both
come from the `"./wt"` default anchored to the git common directory.

**Why is a remote branch missing from the picker?**
`branch_type` defaults to `"local"`. Press `<M-g>` to cycle to `"remote"` or `"all"`, or set
`branch_type = "all"`.

**Why does deleting ask more than once?**
Removing a worktree and deleting its branch are separate actions, and each confirms
separately. Answering `No` skips everything after it. See
[In-picker Keybindings](#in-picker-keybindings).

**Do I need plenary.nvim?**
No. Only one optional hook example uses it.

**Can I use a different picker?**
No - the plugin is built on the Snacks picker.

**Does it change my global cwd?**
Yes. Switching to a worktree calls `chdir`, which is what makes the switch visible to
terminals, LSP roots and file pickers. Use the `on_switch` hook if you need to react to it.
