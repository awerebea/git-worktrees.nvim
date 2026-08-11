-- Test suite for git-worktrees.nvim.
--
-- Run from the repository root with:
--   nvim --headless -l tests/run.lua
--
-- Self-contained: builds throwaway git repositories in a temp directory and stubs the
-- Snacks picker, so it needs nothing beyond nvim and git. Exits non-zero on failure.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:append(root)

--------------------------------------------------------------------------------
-- Tiny assertion harness
--------------------------------------------------------------------------------

local passed, failures = 0, {}
local group = ""

local function describe(name)
  group = name
  print("")
  print("# " .. name)
end

local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failures[#failures + 1] = group .. " / " .. name .. (detail and ("\n       " .. detail) or "")
    print("  FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
  end
end

local function eq(name, got, want)
  check(name, got == want, string.format("got %s, want %s", vim.inspect(got), vim.inspect(want)))
end

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

local TMP = vim.fn.tempname()
vim.fn.mkdir(TMP, "p")

local function git(args, cwd)
  local res = vim.system(vim.list_extend({ "git" }, args), { text = true, cwd = cwd }):wait()
  if res.code ~= 0 then
    error("git " .. table.concat(args, " ") .. " failed in " .. tostring(cwd) .. ": " .. tostring(res.stderr))
  end
  return (res.stdout or ""):gsub("%s+$", "")
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fh = assert(io.open(path, "w"))
  fh:write(text)
  fh:close()
end

--- Repository layout used by every test below:
---
---   ordinary/         ordinary repo, with a src/ subdirectory
---   ordinary-linked/  linked worktree of ordinary
---   bare.git/         bare repo
---   super/            superproject
---     lib/            ordinary directory belonging to super
---     sub/            submodule (a clone of ordinary), with a src/ subdirectory
---
---   remote.git/       bare origin for the clone below
---   clone/            clone of remote.git, used for the remote-branch tests:
---     linked-remote     local branch with a worktree at clone-wt/, tracks origin/linked-remote
---     stale             local branch tracking origin/stale, one commit behind it
---     twin-a, twin-b    two local branches both tracking origin/twin-a
---     (origin/orphan)   remote branch with no local counterpart
local function build_fixtures()
  local function init(path)
    vim.fn.mkdir(path, "p")
    git({ "init", "-q", path })
    git({ "config", "user.email", "test@example.com" }, path)
    git({ "config", "user.name", "test" }, path)
  end

  init(TMP .. "/ordinary")
  write(TMP .. "/ordinary/file.txt", "a\n")
  write(TMP .. "/ordinary/src/nested.txt", "b\n")
  git({ "add", "-A" }, TMP .. "/ordinary")
  git({ "commit", "-qm", "init" }, TMP .. "/ordinary")
  git({ "branch", "-q", "linked" }, TMP .. "/ordinary")
  git({ "worktree", "add", "-q", TMP .. "/ordinary-linked", "linked" }, TMP .. "/ordinary")

  git({ "init", "-q", "--bare", TMP .. "/bare.git" })
  git({ "config", "user.email", "test@example.com" }, TMP .. "/bare.git")
  git({ "config", "user.name", "test" }, TMP .. "/bare.git")

  init(TMP .. "/super")
  write(TMP .. "/super/lib/note.txt", "c\n")
  git({ "add", "-A" }, TMP .. "/super")
  git({ "commit", "-qm", "init" }, TMP .. "/super")
  git({ "-c", "protocol.file.allow=always", "submodule", "add", "-q", TMP .. "/ordinary", "sub" }, TMP .. "/super")
  git({ "commit", "-qm", "add submodule" }, TMP .. "/super")

  -- A clone with remote-tracking branches, for the remote-row tests.
  git({ "init", "-q", "--bare", TMP .. "/remote.git" })
  init(TMP .. "/seed")
  write(TMP .. "/seed/base.txt", "base\n")
  git({ "add", "-A" }, TMP .. "/seed")
  git({ "commit", "-qm", "init" }, TMP .. "/seed")
  git({ "remote", "add", "origin", TMP .. "/remote.git" }, TMP .. "/seed")
  git({ "push", "-q", "-u", "origin", "main" }, TMP .. "/seed")
  for _, branch in ipairs({ "linked-remote", "stale", "twin-a", "orphan" }) do
    git({ "checkout", "-q", "-b", branch, "main" }, TMP .. "/seed")
    write(TMP .. "/seed/" .. branch .. ".txt", branch .. "\n")
    git({ "add", "-A" }, TMP .. "/seed")
    git({ "commit", "-qm", "work on " .. branch }, TMP .. "/seed")
    git({ "push", "-q", "-u", "origin", branch }, TMP .. "/seed")
  end

  git({ "clone", "-q", TMP .. "/remote.git", TMP .. "/clone" })
  git({ "config", "user.email", "test@example.com" }, TMP .. "/clone")
  git({ "config", "user.name", "test" }, TMP .. "/clone")

  -- Local counterpart that owns a worktree.
  git({ "branch", "-q", "linked-remote", "origin/linked-remote" }, TMP .. "/clone")
  git({ "worktree", "add", "-q", TMP .. "/clone-wt", "linked-remote" }, TMP .. "/clone")
  -- Local counterpart with no worktree, deliberately one commit behind its remote.
  git({ "branch", "-q", "stale", "origin/stale~1" }, TMP .. "/clone")
  git({ "branch", "-q", "--set-upstream-to=origin/stale", "stale" }, TMP .. "/clone")
  -- Two local branches tracking one remote branch, both with worktrees.
  git({ "branch", "-q", "twin-a", "origin/twin-a" }, TMP .. "/clone")
  git({ "branch", "-q", "twin-b", "origin/twin-a" }, TMP .. "/clone")
  git({ "branch", "-q", "--set-upstream-to=origin/twin-a", "twin-b" }, TMP .. "/clone")
  git({ "worktree", "add", "-q", TMP .. "/clone-wt-a", "twin-a" }, TMP .. "/clone")
  git({ "worktree", "add", "-q", TMP .. "/clone-wt-b", "twin-b" }, TMP .. "/clone")
end

--------------------------------------------------------------------------------
-- Harness for driving the pickers
--------------------------------------------------------------------------------

local opened, notifications

-- The pickers only ever reach Snacks after they decide to proceed, so recording the
-- pick() call is exactly the "did the operation run?" signal the tests need.
_G.Snacks = {
  picker = {
    pick = function(opts)
      opened = opts.title or "picker"
    end,
    files = function() end,
    util = {
      align = function(str)
        return str
      end,
    },
  },
}

vim.notify = function(msg)
  notifications[#notifications + 1] = tostring(msg)
end

--- Put the editor in a known state, then run `fn`.
---@param cwd string Directory to cd into.
---@param file string|nil File to open in the current buffer; nil for an unnamed buffer.
---@param fn fun()
local function in_context(cwd, file, fn)
  opened, notifications = nil, {}
  vim.cmd("silent! %bwipeout!")
  vim.fn.chdir(cwd)
  if file then
    vim.cmd("silent edit " .. vim.fn.fnameescape(file))
  else
    vim.cmd("silent enew")
  end
  fn()
end

local function warned_about_submodule()
  for _, msg in ipairs(notifications) do
    if msg:find("submodule", 1, true) then
      return true
    end
  end
  return false
end

--- Open the worktree picker and report what happened.
---@return boolean opened_picker
---@return boolean warned
local function worktree_picker()
  local gw = require("git-worktrees")
  require("git-worktrees.pickers").worktrees(vim.deepcopy(gw.config))
  return opened ~= nil, warned_about_submodule()
end

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

build_fixtures()
require("git-worktrees").setup({})
local gitmod = require("git-worktrees.git")

describe("submodule detection attributes a path to its owning repository")
do
  eq(
    "a file's directory inside the submodule resolves to the submodule",
    gitmod.get_superproject_root(TMP .. "/super/sub/src"),
    vim.uv.fs_realpath(TMP .. "/super")
  )
  eq(
    "the submodule root resolves to the superproject",
    gitmod.get_superproject_root(TMP .. "/super/sub"),
    vim.uv.fs_realpath(TMP .. "/super")
  )
  eq("the superproject itself is not a submodule", gitmod.get_superproject_root(TMP .. "/super"), nil)
  eq("a plain directory in the superproject is not a submodule", gitmod.get_superproject_root(TMP .. "/super/lib"), nil)
  eq("an ordinary repository is not a submodule", gitmod.get_superproject_root(TMP .. "/ordinary"), nil)
  eq("a bare repository is not a submodule", gitmod.get_superproject_root(TMP .. "/bare.git"), nil)
end

describe("1. ordinary repository keeps worktree functionality")
do
  in_context(TMP .. "/ordinary", nil, function()
    local ok, warned = worktree_picker()
    eq("picker opens from the repository root", ok, true)
    eq("no submodule warning", warned, false)
  end)
  in_context(TMP .. "/ordinary/src", nil, function()
    eq("picker opens from a subdirectory", (worktree_picker()), true)
  end)
  in_context(TMP .. "/ordinary", TMP .. "/ordinary/src/nested.txt", function()
    eq("picker opens with a buffer visiting a file in the repo", (worktree_picker()), true)
  end)
  in_context(TMP .. "/ordinary-linked", nil, function()
    eq("picker opens from a linked worktree", (worktree_picker()), true)
  end)
end

describe("2. submodule repository warns and exits")
do
  in_context(TMP .. "/super/sub", nil, function()
    local ok, warned = worktree_picker()
    eq("picker does not open from the submodule root", ok, false)
    eq("warns about the submodule", warned, true)
    check(
      "warning says worktrees are unsupported",
      (notifications[1] or ""):find("not supported for submodules", 1, true) ~= nil,
      vim.inspect(notifications[1])
    )
    check(
      "warning points at a standalone clone",
      (notifications[1] or ""):find("standalone", 1, true) ~= nil,
      vim.inspect(notifications[1])
    )
  end)
  in_context(TMP .. "/super/sub/src", nil, function()
    local ok, warned = worktree_picker()
    eq("picker does not open from a submodule subdirectory", ok, false)
    eq("warns from a submodule subdirectory", warned, true)
  end)
  in_context(TMP .. "/super/sub", TMP .. "/super/sub/file.txt", function()
    eq("picker does not open with a submodule buffer", (worktree_picker()), false)
  end)
end

describe("3. superproject keeps worktree functionality")
do
  in_context(TMP .. "/super", nil, function()
    local ok, warned = worktree_picker()
    eq("picker opens from the superproject root", ok, true)
    eq("no submodule warning", warned, false)
  end)
  in_context(TMP .. "/super", TMP .. "/super/lib/note.txt", function()
    local ok, warned = worktree_picker()
    eq("picker opens with a buffer visiting a superproject file", ok, true)
    eq("no submodule warning", warned, false)
  end)
  in_context(TMP .. "/super/lib", nil, function()
    eq("picker opens from a superproject subdirectory", (worktree_picker()), true)
  end)
end

describe("4. a file inside a submodule belongs to the submodule, not the parent")
do
  -- The cwd is the superproject, so a cwd-only guard would let this through.
  in_context(TMP .. "/super", TMP .. "/super/sub/file.txt", function()
    local ok, warned = worktree_picker()
    eq("picker does not open", ok, false)
    eq("warns about the submodule", warned, true)
  end)
  in_context(TMP .. "/super", TMP .. "/super/sub/src/nested.txt", function()
    eq("also for a file nested deeper in the submodule", (worktree_picker()), false)
  end)
  -- The mirror image: cwd inside the submodule while the buffer shows a superproject
  -- file. The pickers operate on the cwd, so this must be refused too.
  in_context(TMP .. "/super/sub", TMP .. "/super/lib/note.txt", function()
    eq("cwd in the submodule is refused whatever the buffer shows", (worktree_picker()), false)
  end)
end

describe("5. non-submodule behaviour is not regressed")
do
  in_context(TMP .. "/bare.git", nil, function()
    local ok, warned = worktree_picker()
    eq("bare repository still opens the picker", ok, true)
    eq("no submodule warning for a bare repository", warned, false)
  end)

  in_context(TMP .. "/ordinary", nil, function()
    local data = gitmod.get_worktree_data(vim.fn.getcwd())
    check("worktree data is returned", data ~= nil)
    if data then
      eq(
        "main worktree maps to the working tree",
        data.wt_map["refs/heads/main"],
        vim.uv.fs_realpath(TMP .. "/ordinary")
      )
      eq(
        "linked worktree maps to its own path",
        data.wt_map["refs/heads/linked"],
        vim.uv.fs_realpath(TMP .. "/ordinary-linked")
      )
      eq("main worktree is known", data.main_worktree_unknown, false)
      eq("not detected as bare", data.is_bare, false)
    end
  end)

  in_context(TMP .. "/bare.git", nil, function()
    local data = gitmod.get_worktree_data(vim.fn.getcwd())
    check("bare worktree data is returned", data ~= nil)
    if data then
      eq("bare repository is detected as bare", data.is_bare, true)
      eq("git_root is the bare directory", data.git_root, vim.uv.fs_realpath(TMP .. "/bare.git"))
    end
  end)

  -- The branch picker performs no worktree operations, so it is not gated.
  in_context(TMP .. "/super/sub", nil, function()
    opened, notifications = nil, {}
    require("git-worktrees.pickers").branches(vim.deepcopy(require("git-worktrees").config))
    eq("branch picker still opens inside a submodule", opened ~= nil, true)
  end)

  -- A buffer with no file on disk must not break the guard.
  in_context(TMP .. "/ordinary", nil, function()
    vim.bo.buftype = "nofile"
    eq("special buffers fall back to the cwd", (worktree_picker()), true)
  end)
end

describe("6. remote rows resolve to their local counterpart's worktree")
do
  local fmt = require("git-worktrees.format")

  --- Build the picker rows for the clone, keyed by branch name.
  ---@return table<string, GitWorktrees.Item>
  local function rows()
    local cwd = TMP .. "/clone"
    local wt = gitmod.get_worktree_data(cwd)
    local items = fmt.build_items(
      gitmod.get_branches("all", cwd, {}),
      wt,
      { wt_path_display = "absolute" },
      gitmod.get_current_branch(cwd),
      nil,
      gitmod.get_local_upstreams(cwd)
    )
    local by_name = {}
    for _, item in ipairs(items) do
      by_name[item.branch] = item
    end
    return by_name
  end

  local by_name = rows()

  eq(
    "a remote row points at its counterpart's worktree",
    by_name["origin/linked-remote"].wt_path,
    vim.uv.fs_realpath(TMP .. "/clone-wt")
  )
  eq("and records the local branch that owns it", by_name["origin/linked-remote"].wt_branch, "linked-remote")
  eq(
    "the local row still points at the same worktree",
    by_name["linked-remote"].wt_path,
    vim.uv.fs_realpath(TMP .. "/clone-wt")
  )
  eq("a remote row whose counterpart has no worktree stays empty", by_name["origin/stale"].wt_path, nil)
  eq("a remote row with no local counterpart stays empty", by_name["origin/orphan"].wt_path, nil)
  eq("a local row is its own worktree owner", by_name["twin-a"].wt_branch, "twin-a")

  -- Many-to-one: twin-a and twin-b both track origin/twin-a and both have worktrees.
  eq("the name-matching counterpart wins a tie", by_name["origin/twin-a"].wt_branch, "twin-a")
  eq("and its worktree is the one reported", by_name["origin/twin-a"].wt_path, vim.uv.fs_realpath(TMP .. "/clone-wt-a"))

  -- Drop the name-matching branch's worktree; the alphabetical fallback takes over.
  git({ "worktree", "remove", "--force", TMP .. "/clone-wt-a" }, TMP .. "/clone")
  local after = rows()
  eq("falls back when the name match has no worktree", after["origin/twin-a"].wt_branch, "twin-b")
  eq("reporting the fallback's worktree", after["origin/twin-a"].wt_path, vim.uv.fs_realpath(TMP .. "/clone-wt-b"))
  git({ "worktree", "add", "-q", TMP .. "/clone-wt-a", "twin-a" }, TMP .. "/clone")
end

describe("7. filters follow the resolved worktree")
do
  local pickers_items
  _G.Snacks.picker.pick = function(opts)
    opened = opts.title or "picker"
    pickers_items = opts.items
  end

  ---@return table<string, boolean>
  local function branches_in(filter)
    pickers_items = nil
    in_context(TMP .. "/clone", nil, function()
      local cfg = vim.tbl_deep_extend("force", require("git-worktrees").config, {
        branch_type = "all",
        filter = filter,
      })
      require("git-worktrees.pickers").worktrees(cfg)
    end)
    local present = {}
    for _, item in ipairs(pickers_items or {}) do
      present[item.branch] = true
    end
    return present
  end

  local add = branches_in("no_worktree")
  eq("remote row with a worktree is not offered in Add", add["origin/linked-remote"], nil)
  eq("remote row without a worktree is still offered in Add", add["origin/stale"], true)
  eq("remote row with no counterpart is still offered in Add", add["origin/orphan"], true)

  local manage = branches_in("has_worktree")
  eq("remote row with a worktree appears in Manage", manage["origin/linked-remote"], true)
  eq("remote row without a worktree stays out of Manage", manage["origin/stale"], nil)
  eq("local rows with worktrees still appear in Manage", manage["linked-remote"], true)
end

describe("8. a stale local counterpart is reported before the worktree is created")
do
  local act = require("git-worktrees.actions")
  local asked, answer

  local real_confirm = vim.fn.confirm
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.confirm = function(msg)
    asked[#asked + 1] = msg
    return answer
  end
  local real_input = vim.ui.input
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.input = function(opts, on_confirm)
    on_confirm(opts.default)
  end

  --- Select a remote row and create its worktree, answering the reset prompt with `reply`.
  ---@param branch string Remote branch name, e.g. "origin/stale".
  ---@param reply integer 1 = yes, 2 = no.
  ---@return string[] prompts
  local function create_from_remote(branch, reply)
    asked, answer = {}, reply
    local cwd = TMP .. "/clone"
    vim.fn.chdir(cwd)
    local wt = gitmod.get_worktree_data(cwd)
    local items = require("git-worktrees.format").build_items(
      gitmod.get_branches("all", cwd, {}),
      wt,
      {},
      gitmod.get_current_branch(cwd),
      nil,
      gitmod.get_local_upstreams(cwd)
    )
    local item
    for _, candidate in ipairs(items) do
      if candidate.branch == branch then
        item = candidate
      end
    end
    -- Absolute, so the created path does not depend on where the git common dir is.
    require("git-worktrees").setup({ auto_worktree_path = true, wt_base_path_regular = TMP .. "/made" })
    act._do_switch({
      wt_path = item.wt_path,
      wt_branch = item.wt_branch,
      display_path = item.display_path,
      branch = item.branch,
      ref = item.ref,
      is_remote = item.is_remote,
    }, false)
    return asked
  end

  local function head_of(path)
    return git({ "log", "-1", "--format=%s" }, path)
  end

  local function reset_stale()
    vim.fn.chdir(TMP .. "/clone")
    pcall(git, { "worktree", "remove", "--force", TMP .. "/made/stale" }, TMP .. "/clone")
    vim.fn.delete(TMP .. "/made", "rf")
    git({ "worktree", "prune" }, TMP .. "/clone")
    git({ "branch", "-f", "stale", "origin/stale~1" }, TMP .. "/clone")
  end

  reset_stale()
  local prompts = create_from_remote("origin/stale", 2)
  check("declining still creates the worktree", vim.fn.isdirectory(TMP .. "/made/stale") == 1)
  check(
    "the prompt reports how far behind the local branch is",
    (prompts[1] or ""):find("1 commit behind origin/stale", 1, true) ~= nil,
    vim.inspect(prompts[1])
  )
  eq("declining keeps the local branch's state", head_of(TMP .. "/made/stale"), "init")

  reset_stale()
  create_from_remote("origin/stale", 1)
  eq("accepting resets the branch to the remote", head_of(TMP .. "/made/stale"), "work on stale")

  -- No local counterpart: git creates a tracking branch at the remote tip, no prompt.
  vim.fn.chdir(TMP .. "/clone")
  pcall(git, { "worktree", "remove", "--force", TMP .. "/made/orphan" }, TMP .. "/clone")
  local orphan_prompts = create_from_remote("origin/orphan", 2)
  eq("no prompt when there is no local counterpart", #orphan_prompts, 0)
  eq("the worktree gets the remote state", head_of(TMP .. "/made/orphan"), "work on orphan")

  -- Up-to-date counterpart: nothing stale to report. The worktree has to go first, since
  -- git refuses to force-update a branch that is checked out somewhere.
  vim.fn.chdir(TMP .. "/clone")
  pcall(git, { "worktree", "remove", "--force", TMP .. "/made/stale" }, TMP .. "/clone")
  git({ "worktree", "prune" }, TMP .. "/clone")
  git({ "branch", "-f", "stale", "origin/stale" }, TMP .. "/clone")
  local fresh_prompts = create_from_remote("origin/stale", 2)
  eq("no prompt when the counterpart is up to date", #fresh_prompts, 0)

  -- These tests create worktrees and a tracking branch as a side effect. Put the clone
  -- back as it was so later sections do not inherit them.
  vim.fn.chdir(TMP .. "/clone")
  for _, name in ipairs({ "stale", "orphan" }) do
    pcall(git, { "worktree", "remove", "--force", TMP .. "/made/" .. name }, TMP .. "/clone")
  end
  vim.fn.delete(TMP .. "/made", "rf")
  git({ "worktree", "prune" }, TMP .. "/clone")
  pcall(git, { "branch", "-D", "orphan" }, TMP .. "/clone")
  git({ "branch", "-f", "stale", "origin/stale~1" }, TMP .. "/clone")

  vim.fn.confirm = real_confirm
  vim.ui.input = real_input
end

describe("9. jumping to a counterpart's worktree reports it being stale")
do
  local act = require("git-worktrees.actions")
  local fmt = require("git-worktrees.format")
  local asked, answer

  local real_confirm = vim.fn.confirm
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.confirm = function(msg)
    asked[#asked + 1] = msg
    return answer
  end

  --- Select a remote row that resolves to an existing worktree.
  ---@param branch string
  ---@param reply integer 1 = yes, 2 = no
  ---@return string[] prompts
  local function switch_to(branch, reply)
    asked, answer = {}, reply
    local cwd = TMP .. "/clone"
    vim.fn.chdir(cwd)
    local items = fmt.build_items(
      gitmod.get_branches("all", cwd, {}),
      gitmod.get_worktree_data(cwd),
      {},
      gitmod.get_current_branch(cwd),
      nil,
      gitmod.get_local_upstreams(cwd)
    )
    for _, item in ipairs(items) do
      if item.branch == branch then
        act._do_switch({
          wt_path = item.wt_path,
          wt_branch = item.wt_branch,
          display_path = item.display_path,
          branch = item.branch,
          ref = item.ref,
          is_remote = item.is_remote,
        }, false)
      end
    end
    return asked
  end

  local function head_of(path)
    return git({ "log", "-1", "--format=%s" }, path)
  end

  -- linked-remote holds a worktree; put it one commit behind its remote.
  git({ "reset", "--hard", "origin/linked-remote~1" }, TMP .. "/clone-wt")

  local prompts = switch_to("origin/linked-remote", 2)
  check(
    "the prompt says how far behind the worktree is",
    (prompts[1] or ""):find("1 commit behind", 1, true) ~= nil,
    vim.inspect(prompts[1])
  )
  check(
    "and names the worktree holding it",
    (prompts[1] or ""):find("has it checked out", 1, true) ~= nil,
    vim.inspect(prompts[1])
  )
  eq("declining leaves the worktree stale", head_of(TMP .. "/clone-wt"), "init")
  eq("but still switches to it", vim.fn.getcwd(), vim.uv.fs_realpath(TMP .. "/clone-wt"))

  switch_to("origin/linked-remote", 1)
  eq("accepting brings it up to the remote", head_of(TMP .. "/clone-wt"), "work on linked-remote")

  prompts = switch_to("origin/linked-remote", 2)
  eq("no prompt once it is up to date", #prompts, 0)

  -- Uncommitted work there would be lost, so it is listed before asking.
  git({ "reset", "--hard", "origin/linked-remote~1" }, TMP .. "/clone-wt")
  write(TMP .. "/clone-wt/dirty.txt", "x\n")
  prompts = switch_to("origin/linked-remote", 2)
  check(
    "the prompt lists uncommitted changes",
    (prompts[1] or ""):find("uncommitted changes", 1, true) ~= nil,
    vim.inspect(prompts[1])
  )
  check("naming the untracked file", (prompts[1] or ""):find("dirty.txt", 1, true) ~= nil, vim.inspect(prompts[1]))
  eq("declining keeps it", vim.fn.filereadable(TMP .. "/clone-wt/dirty.txt"), 1)
  vim.fn.delete(TMP .. "/clone-wt/dirty.txt")

  -- A local row carries no remote to compare against.
  prompts = switch_to("linked-remote", 2)
  eq("no prompt for a local selection", #prompts, 0)

  git({ "reset", "--hard", "origin/linked-remote" }, TMP .. "/clone-wt")
  vim.fn.confirm = real_confirm
end

describe("10. branch info reports the worktree a row resolves to")
do
  local act = require("git-worktrees.actions")
  local fmt = require("git-worktrees.format")

  local shown
  local real_win = _G.Snacks.win
  _G.Snacks.win = function(opts)
    shown = opts.text
    return {
      win_valid = function()
        return false
      end,
      close = function() end,
    }
  end

  --- Return the "worktree" line of the <C-o> popup for `branch`, or nil when absent.
  ---@param branch string
  ---@return string|nil
  local function worktree_line(branch)
    local cwd = TMP .. "/clone"
    vim.fn.chdir(cwd)
    local items = fmt.build_items(
      gitmod.get_branches("all", cwd, {}),
      gitmod.get_worktree_data(cwd),
      { wt_path_display = "absolute" },
      gitmod.get_current_branch(cwd),
      nil,
      gitmod.get_local_upstreams(cwd)
    )
    for _, item in ipairs(items) do
      if item.branch == branch then
        shown = nil
        act.branch_info(nil, item)
        for _, line in ipairs(shown or {}) do
          local value = line:match("^worktree%s+:%s+(.+)$")
          if value then
            return value
          end
        end
        return nil
      end
    end
    error("no row for " .. branch)
  end

  local wt = vim.uv.fs_realpath(TMP .. "/clone-wt")
  eq("a local row reports its own worktree, unqualified", worktree_line("linked-remote"), wt)
  eq("a remote row now reports one at all", worktree_line("origin/linked-remote"), wt)
  eq("a remote row with no resolved worktree reports none", worktree_line("origin/stale"), nil)

  -- A local branch tracking a differently named remote branch: the owner is not obvious
  -- from the row, so it is named.
  git({ "branch", "-q", "alias", "origin/orphan" }, TMP .. "/clone")
  git({ "branch", "-q", "--set-upstream-to=origin/orphan", "alias" }, TMP .. "/clone")
  git({ "worktree", "add", "-q", TMP .. "/clone-wt-alias", "alias" }, TMP .. "/clone")
  eq(
    "a borrowed worktree names the branch that owns it",
    worktree_line("origin/orphan"),
    vim.uv.fs_realpath(TMP .. "/clone-wt-alias") .. " (alias)"
  )

  -- Many-to-one where the name match wins: nothing to disambiguate.
  eq(
    "the name-matching owner is not spelled out",
    worktree_line("origin/twin-a"),
    vim.uv.fs_realpath(TMP .. "/clone-wt-a")
  )
  -- ...and when the fallback wins, it is.
  git({ "worktree", "remove", "--force", TMP .. "/clone-wt-a" }, TMP .. "/clone")
  eq(
    "a fallback owner is spelled out",
    worktree_line("origin/twin-a"),
    vim.uv.fs_realpath(TMP .. "/clone-wt-b") .. " (twin-b)"
  )
  git({ "worktree", "add", "-q", TMP .. "/clone-wt-a", "twin-a" }, TMP .. "/clone")

  _G.Snacks.win = real_win
end

--------------------------------------------------------------------------------
-- Report
--------------------------------------------------------------------------------

vim.fn.delete(TMP, "rf")

print("")
if #failures == 0 then
  print(string.format("All %d checks passed.", passed))
  vim.cmd("qa!")
else
  print(string.format("%d passed, %d FAILED:", passed, #failures))
  for _, f in ipairs(failures) do
    print("  - " .. f)
  end
  vim.cmd("cq!")
end
