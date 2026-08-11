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
