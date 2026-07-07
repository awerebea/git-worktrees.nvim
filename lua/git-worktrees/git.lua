local M = {}

local function run(args, cwd)
  local result = vim.system(args, { text = true, cwd = cwd }):wait()
  if result.code ~= 0 then
    return nil, result.stderr or ""
  end
  return result.stdout, nil
end

function M.is_git_repo(cwd)
  local result = vim.system({ "git", "rev-parse", "--git-dir" }, { text = true, cwd = cwd }):wait()
  return result.code == 0
end

-- Parse `git worktree list --porcelain` output.
-- Returns: { git_root, git_common_dir, is_bare, wt_map={ref->path}, wt_branches={ref,...} }
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

  local wt_map = {}
  local wt_branches = {}

  local function parse_entry(lines, path)
    local head_hash, ref, is_detached
    for _, line in ipairs(lines) do
      local h = line:match("^HEAD (.+)")
      if h then head_hash = h end
      local b = line:match("^branch (.+)")
      if b then ref = b end
      if line == "detached" then is_detached = true end
    end
    if ref then
      wt_map[ref] = path
      table.insert(wt_branches, ref)
    elseif is_detached and head_hash then
      local dref = "detached/heads/" .. head_hash:sub(1, 7)
      wt_map[dref] = path
      table.insert(wt_branches, dref)
    end
  end

  -- Regular repos: include the main worktree
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
    wt_branches = wt_branches,
  }
end

-- Returns a list of { ref, name, author, date, is_remote }
-- branch_type: "local" | "remote" | "all"
-- opts: { sort_by, date_format, author_format }
function M.get_branches(branch_type, cwd, opts)
  branch_type = branch_type or "local"
  opts = opts or {}

  local sort_by = opts.sort_by or "-committerdate"
  local date_fmt = opts.date_format or "relative"
  local author_key = (opts.author_format == "email") and "committeremail" or "committername"

  local ref_patterns = {}
  if branch_type == "local" or branch_type == "all" then
    table.insert(ref_patterns, "refs/heads")
  end
  if branch_type == "remote" or branch_type == "all" then
    table.insert(ref_patterns, "refs/remotes")
  end

  -- Use ASCII unit-separator (0x1f) to delimit fields
  local sep = "\x1f"
  local fmt_str = "%(refname)" .. sep .. "%(" .. author_key .. ")" .. sep .. "%(committerdate:" .. date_fmt .. ")"
  local args = { "git", "for-each-ref", "--sort=" .. sort_by, "--format=" .. fmt_str }
  for _, p in ipairs(ref_patterns) do
    table.insert(args, p)
  end

  local out, _ = run(args, cwd)
  if not out then
    return {}
  end

  local branches = {}
  for line in out:gmatch("[^\n]+") do
    local parts = vim.split(line, sep, { plain = true })
    if #parts >= 1 then
      local ref = parts[1]
      local author = parts[2] or ""
      local date = parts[3] or ""
      local is_remote = ref:sub(1, 12) == "refs/remotes"
      local name = ref:match("^refs/heads/(.+)") or ref:match("^refs/remotes/(.+)")
      if name then
        -- Skip remote HEAD pointers
        if not (is_remote and name:match("/HEAD$")) then
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
  end

  return branches
end

-- Returns the current HEAD ref (e.g. "refs/heads/main") or nil for detached HEAD
function M.get_current_branch(cwd)
  local out, _ = run({ "git", "symbolic-ref", "HEAD" }, cwd)
  if not out then
    return nil
  end
  return out:gsub("%s+$", "")
end

-- Expand a worktree base path template.
-- Supports {repo_name} and {repo_name_short} placeholders.
-- Relative paths are anchored to git_common_dir.
function M.expand_wt_base(tmpl, git_common_dir)
  local repo_name = vim.fn.fnamemodify(git_common_dir, ":t")
  local repo_name_short = repo_name:gsub("%.git$", "")
  local path = tmpl
    :gsub("{repo_name}", repo_name)
    :gsub("{repo_name_short}", repo_name_short)
  if path:sub(1, 1) ~= "/" then
    path = git_common_dir .. "/" .. path:gsub("^%./", "")
  end
  return path
end

-- Run `git worktree add <path> <branch>` synchronously.
-- Returns true + path on success, false + error on failure.
function M.worktree_add(wt_path, branch_name, cwd)
  local result = vim.system(
    { "git", "worktree", "add", wt_path, branch_name },
    { text = true, cwd = cwd }
  ):wait()
  if result.code ~= 0 then
    return false, result.stderr or "failed"
  end
  return true, wt_path
end

-- Run `git worktree remove [--force] <path>` synchronously.
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

-- Delete a local branch (-d, then optionally -D on unmerged).
-- Returns true on success, false + error on failure, "unmerged" if branch is not merged.
function M.branch_delete(branch_name, force)
  local flag = force and "-D" or "-d"
  local result = vim.system(
    { "git", "branch", flag, branch_name },
    { text = true }
  ):wait()
  if result.code ~= 0 then
    local err = result.stderr or ""
    if err:find("not fully merged") then
      return false, "unmerged"
    end
    return false, err
  end
  return true, nil
end

-- Create a new branch from a base branch.
function M.branch_create(new_name, base)
  local result = vim.system(
    { "git", "branch", new_name, base },
    { text = true }
  ):wait()
  if result.code ~= 0 then
    return false, result.stderr or "failed"
  end
  return true, nil
end

-- Switch to a branch (git switch).
function M.branch_switch(branch_name, cwd)
  local result = vim.system(
    { "git", "switch", branch_name },
    { text = true, cwd = cwd }
  ):wait()
  if result.code ~= 0 then
    return false, result.stderr or "failed"
  end
  return true, nil
end

return M
