---@class GitWorktrees.WorktreeData
---@field git_root string Absolute path to the root worktree.
---@field git_common_dir string Absolute path to the git common directory (.git or bare root).
---@field is_bare boolean Whether the repository is a bare repo.
---@field wt_map table<string, string> Map of full-ref -> absolute worktree path.
---Worktrees with a detached HEAD are absent from wt_map: they have no branch ref for a
---picker item to be keyed by.

---@class GitWorktrees.Branch
---@field ref string Full ref name (e.g. "refs/heads/main" or "refs/remotes/origin/feat").
---@field name string Short branch name (e.g. "main" or "origin/feat").
---@field author string Committer name or email, depending on author_format.
---@field date string Formatted committer date.
---@field is_remote boolean True when the ref lives under refs/remotes.

---@class GitWorktrees.GetBranchesOpts
---@field sort_by? string Sort order for git for-each-ref --sort (default: "-committerdate").
---@field date_format? string committerdate format suffix (default: "relative").
---@field author_format? "name"|"email" Which git field to use for the author column (default: "name").

local M = {}

---@param args string[]
---@param cwd? string
---@return string|nil output
---@return string|nil error
local function run(args, cwd)
  local result = vim.system(args, { text = true, cwd = cwd }):wait()
  if result.code ~= 0 then
    return nil, result.stderr or ""
  end
  return result.stdout, nil
end

---Returns true when `cwd` is inside a git repository.
---@param cwd string
---@return boolean
function M.is_git_repo(cwd)
  local result = vim.system({ "git", "rev-parse", "--git-dir" }, { text = true, cwd = cwd }):wait()
  return result.code == 0
end

---Parse `git worktree list --porcelain` and return structured worktree data.
---@param cwd string
---@return GitWorktrees.WorktreeData|nil data
---@return string|nil error
function M.get_worktree_data(cwd)
  local out, err = run({ "git", "worktree", "list", "--porcelain" }, cwd)
  if not out or out == "" then
    return nil, err
  end

  -- Entries are separated by blank lines
  local entries = vim.split(out, "\n\n", { plain = true })
  if #entries == 0 then
    return nil, "no worktree entries"
  end

  local first_lines = vim.split(entries[1], "\n", { plain = true, trimempty = true })
  local git_root = (first_lines[1] or ""):match("^worktree (.+)")
  if not git_root then
    return nil, "could not parse git root"
  end

  local is_bare = false
  for _, line in ipairs(first_lines) do
    if line == "bare" then
      is_bare = true
      break
    end
  end

  local git_common_dir = is_bare and git_root or (git_root .. "/.git")

  ---@type table<string, string>
  local wt_map = {}

  ---@param lines string[]
  ---@param path string
  local function parse_entry(lines, path)
    for _, line in ipairs(lines) do
      local ref = line:match("^branch (.+)")
      if ref then
        wt_map[ref] = path
        return
      end
    end
  end

  -- Regular repos include the main worktree; bare repos do not have one.
  if not is_bare then
    parse_entry(first_lines, git_root)
  end

  for i = 2, #entries do
    local entry = entries[i]
    if entry and entry:match("%S") then
      local entry_lines = vim.split(entry, "\n", { plain = true, trimempty = true })
      local path = (entry_lines[1] or ""):match("^worktree (.+)")
      if path then
        parse_entry(entry_lines, path)
      end
    end
  end

  return {
    git_root = git_root,
    git_common_dir = git_common_dir,
    is_bare = is_bare,
    wt_map = wt_map,
  }
end

---Return a list of branches sorted by the given sort order.
---@param branch_type "local"|"remote"|"all"
---@param cwd string
---@param opts? GitWorktrees.GetBranchesOpts
---@return GitWorktrees.Branch[]
function M.get_branches(branch_type, cwd, opts)
  opts = opts or {}
  local sort_by = opts.sort_by or "-committerdate"
  local date_fmt = opts.date_format or "relative"
  local author_key = (opts.author_format == "email") and "committeremail" or "committername"

  ---@type string[]
  local ref_patterns = {}
  if branch_type == "local" or branch_type == "all" then
    table.insert(ref_patterns, "refs/heads")
  end
  if branch_type == "remote" or branch_type == "all" then
    table.insert(ref_patterns, "refs/remotes")
  end

  -- Use ASCII unit-separator (0x1f) to delimit fields safely.
  local sep = "\x1f"
  local fmt_str = "%(refname)" .. sep .. "%(" .. author_key .. ")" .. sep .. "%(committerdate:" .. date_fmt .. ")"
  local args = { "git", "for-each-ref", "--sort=" .. sort_by, "--format=" .. fmt_str }
  for _, p in ipairs(ref_patterns) do
    table.insert(args, p)
  end

  local out = run(args, cwd)
  if not out then
    return {}
  end

  ---@type GitWorktrees.Branch[]
  local branches = {}
  for line in out:gmatch("[^\n]+") do
    local parts = vim.split(line, sep, { plain = true })
    if #parts >= 1 then
      local ref = parts[1]
      local author = parts[2] or ""
      local date = parts[3] or ""
      local is_remote = ref:sub(1, 12) == "refs/remotes"
      local name = ref:match("^refs/heads/(.+)") or ref:match("^refs/remotes/(.+)")
      if name and not (is_remote and name:match("/HEAD$")) then
        table.insert(branches, {
          ref = ref,
          name = name,
          author = author,
          date = date,
          is_remote = is_remote,
        })
      end
    end
  end

  return branches
end

---Return the absolute root of the worktree containing `cwd`.
---Returns nil when `cwd` has no working tree, e.g. a bare repository directory.
---@param cwd string
---@return string|nil
function M.get_worktree_root(cwd)
  local out = run({ "git", "rev-parse", "--show-toplevel" }, cwd)
  if not out then
    return nil
  end
  out = out:gsub("%s+$", "")
  return out ~= "" and out or nil
end

---Return the current HEAD ref (e.g. "refs/heads/main"), or nil for a detached HEAD.
---@param cwd string
---@return string|nil
function M.get_current_branch(cwd)
  local out = run({ "git", "symbolic-ref", "HEAD" }, cwd)
  if not out then
    return nil
  end
  return out:gsub("%s+$", "")
end

---Expand a worktree base path template.
---Supports {repo_name} and {repo_name_short} placeholders, derived from the repo's
---working-tree root (bare repos: the bare directory itself, e.g. "my-project.git").
---A leading "~" or an environment variable is expanded first; what remains is
---absolute when it starts with "/" and anchored to `git_common_dir` otherwise.
---@param tmpl string
---@param git_common_dir string
---@param git_root string
---@return string
function M.expand_wt_base(tmpl, git_common_dir, git_root)
  local repo_name = vim.fn.fnamemodify(git_root, ":t")
  local repo_name_short = repo_name:gsub("%.git$", "")
  -- Escape "%" in the substituted names: gsub treats it as an escape character in the
  -- replacement string, so a repo named "a%1b" would otherwise expand to the matched
  -- placeholder itself and "y%z" would lose the "%z" entirely.
  local function repl(s)
    return (s:gsub("%%", "%%%%"))
  end
  local path = tmpl:gsub("{repo_name}", repl(repo_name)):gsub("{repo_name_short}", repl(repo_name_short))
  -- Expand "~" and "$VAR" before deciding whether the template is absolute; without
  -- this a natural "~/worktrees" was treated as relative and anchored, producing a
  -- literal "~" directory under the git common dir. Unlike vim.fn.expand(), normalize
  -- leaves "%" alone, so it is safe to run after the placeholder substitution above.
  if path:sub(1, 1) == "~" or path:find("%$") then
    path = vim.fs.normalize(path)
  end
  if path:sub(1, 1) ~= "/" then
    path = git_common_dir .. "/" .. path:gsub("^%./", "")
  end
  return vim.fn.simplify(path)
end

---Run `git worktree add <wt_path> <branch_name>`.
---@param wt_path string Absolute or relative path for the new worktree.
---@param branch_name string Branch to check out.
---@param cwd string
---@return boolean ok
---@return string|nil error
function M.worktree_add(wt_path, branch_name, cwd)
  local result = vim.system({ "git", "worktree", "add", wt_path, branch_name }, { text = true, cwd = cwd }):wait()
  if result.code ~= 0 then
    return false, result.stderr or "failed"
  end
  return true, nil
end

---Run `git worktree remove [--force] <wt_path>`.
---@param wt_path string
---@param force boolean
---@return boolean ok
---@return string|nil error
function M.worktree_remove(wt_path, force)
  local args = { "git", "worktree", "remove" }
  if force then
    table.insert(args, "--force")
  end
  table.insert(args, wt_path)
  local result = vim.system(args, { text = true }):wait()
  if result.code ~= 0 then
    return false, result.stderr or "failed"
  end
  return true, nil
end

---Delete a local branch.
---Returns `false, "unmerged"` when the branch has unmerged commits and force is false.
---@param branch_name string
---@param force boolean Use -D instead of -d.
---@return boolean ok
---@return string|nil error
function M.branch_delete(branch_name, force)
  local flag = force and "-D" or "-d"
  local result = vim.system({ "git", "branch", flag, branch_name }, { text = true }):wait()
  if result.code ~= 0 then
    local err = result.stderr or ""
    if err:find("not fully merged") then
      return false, "unmerged"
    end
    return false, err
  end
  return true, nil
end

---Create a new branch from a base ref.
---@param new_name string
---@param base string Branch or ref to fork from.
---@return boolean ok
---@return string|nil error
function M.branch_create(new_name, base)
  local result = vim.system({ "git", "branch", new_name, base }, { text = true }):wait()
  if result.code ~= 0 then
    return false, result.stderr or "failed"
  end
  return true, nil
end

---Switch to a branch with `git switch`.
---@param branch_name string
---@param cwd string
---@return boolean ok
---@return string|nil error
function M.branch_switch(branch_name, cwd)
  local result = vim.system({ "git", "switch", branch_name }, { text = true, cwd = cwd }):wait()
  if result.code ~= 0 then
    return false, result.stderr or "failed"
  end
  return true, nil
end

---Delete a branch on a remote via `git push <remote> --delete <branch_name>`.
---@param remote string Remote name (e.g. "origin").
---@param branch_name string Branch name without the remote prefix.
---@param cwd string
---@return boolean ok
---@return string|nil error
function M.branch_delete_remote(remote, branch_name, cwd)
  local result = vim.system({ "git", "push", remote, "--delete", branch_name }, { text = true, cwd = cwd }):wait()
  if result.code ~= 0 then
    return false, result.stderr or "failed"
  end
  return true, nil
end

---Return the upstream tracking short ref for a local branch (e.g. "origin/main"),
---or nil when the branch has no configured upstream.
---@param branch_name string Local branch name (without refs/heads/ prefix).
---@param cwd string
---@return string|nil upstream e.g. "origin/main", nil if none
function M.get_branch_upstream(branch_name, cwd)
  local out = run({ "git", "for-each-ref", "--format=%(upstream:short)", "refs/heads/" .. branch_name }, cwd)
  if not out then
    return nil
  end
  out = out:gsub("%s+$", "")
  return out ~= "" and out or nil
end

---Return true when a local branch with the given name exists.
---@param branch_name string
---@param cwd string
---@return boolean
function M.local_branch_exists(branch_name, cwd)
  local out = run({ "git", "branch", "--list", branch_name }, cwd)
  return out ~= nil and out:match("%S") ~= nil
end

---Return true when the worktree at cwd has uncommitted changes in tracked files.
---Checks both the working tree (git diff) and the index (git diff --cached),
---matching fgb's `! git diff --quiet || ! git diff --cached --quiet` pattern.
---Untracked files are intentionally ignored (fgb -uno behaviour).
---@param cwd string
---@return boolean
function M.has_uncommitted_changes(cwd)
  local r = vim.system({ "git", "diff", "--quiet" }, { cwd = cwd }):wait()
  if r.code ~= 0 then
    return true
  end
  r = vim.system({ "git", "diff", "--cached", "--quiet" }, { cwd = cwd }):wait()
  return r.code ~= 0
end

---Return a short status listing of changed tracked files (no untracked, for display).
---@param cwd string
---@return string
function M.get_status_short(cwd)
  local out = run({ "git", "status", "--short", "-uno" }, cwd)
  return out and out:gsub("%s+$", "") or ""
end

---Return a short status listing including untracked files (used before force-delete).
---@param cwd string
---@return string
function M.get_status_with_untracked(cwd)
  local out = run({ "git", "status", "--short" }, cwd)
  return out and out:gsub("%s+$", "") or ""
end

---Stash uncommitted changes with a descriptive message. The stash ID is captured
---immediately by position to avoid fragile message-based grep lookups (fgb fix).
---@param message string
---@param cwd string
---@return string|nil stash_id e.g. "stash@{0}"
---@return string|nil error
function M.stash_create(message, cwd)
  local result = vim.system({ "git", "stash", "push", "-m", message }, { text = true, cwd = cwd }):wait()
  if result.code ~= 0 then
    return nil, result.stderr or "failed"
  end
  local out = run({ "git", "stash", "list", "--format=%gd" }, cwd)
  if not out then
    return nil, "stash created but could not retrieve stash ID"
  end
  return out:match("^([^\n]+)") or "stash@{0}", nil
end

---Apply a stash to the working tree at cwd. Uses exit code as the authoritative
---signal (not output content) -- mirrors fgb commit 9b48f9c.
---@param stash_id string
---@param cwd string
---@return boolean ok
function M.stash_apply(stash_id, cwd)
  local result = vim.system({ "git", "stash", "apply", stash_id }, { text = true, cwd = cwd }):wait()
  return result.code == 0
end

---Drop a stash ref silently (best-effort cleanup).
---@param stash_id string
---@param cwd string
function M.stash_drop(stash_id, cwd)
  vim.system({ "git", "stash", "drop", stash_id }, { text = true, cwd = cwd }):wait()
end

---Hard-reset a worktree and remove untracked files. Used to clean a new worktree
---before attempting the stash-restore fallback -- mirrors fgb's reset --hard + clean -fd.
---@param cwd string
function M.worktree_reset_hard(cwd)
  vim.system({ "git", "reset", "--hard", "HEAD" }, { text = true, cwd = cwd }):wait()
  vim.system({ "git", "clean", "-fd" }, { text = true, cwd = cwd }):wait()
end

---@class GitWorktrees.CommitDetails
---@field hash string Full commit hash.
---@field author_name string Author name.
---@field author_email string Author email.
---@field author_date string Author date in ISO 8601 format with timezone (e.g. "2026-07-08 01:40:10 -0400").
---@field committer_name string Committer name.
---@field committer_email string Committer email.
---@field committer_date string Committer date in ISO 8601 format with timezone.
---@field message string Full commit message body (%B, trailing whitespace trimmed).

---Return rich commit details for the given ref (used by branch_info).
---Fields match fgb's __fgb_print_branch_info output.
---@param ref string Full or short ref (e.g. "refs/heads/main", "refs/remotes/origin/feat").
---@param cwd string
---@return GitWorktrees.CommitDetails|nil
function M.get_commit_details(ref, cwd)
  local sep = "\x1f"
  local fmt = "%H"
    .. sep
    .. "%an"
    .. sep
    .. "%ae"
    .. sep
    .. "%ai"
    .. sep
    .. "%cn"
    .. sep
    .. "%ce"
    .. sep
    .. "%ci"
    .. sep
    .. "%B"
  local out = run({ "git", "log", "-1", "--format=" .. fmt, ref }, cwd)
  if not out then
    return nil
  end
  -- Split on exactly 7 separators so that the 8th field (%B) is kept whole even
  -- if the commit message body contains the separator character.
  local parts = {}
  local rest = out
  for _ = 1, 7 do
    local pos = rest:find(sep, 1, true)
    if not pos then
      break
    end
    parts[#parts + 1] = rest:sub(1, pos - 1)
    rest = rest:sub(pos + 1)
  end
  if #parts < 7 then
    return nil
  end
  return {
    hash = parts[1],
    author_name = parts[2],
    author_email = parts[3],
    author_date = parts[4],
    committer_name = parts[5],
    committer_email = parts[6],
    committer_date = parts[7],
    message = rest:gsub("%s+$", ""),
  }
end

return M
