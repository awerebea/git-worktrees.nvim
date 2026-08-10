---@class GitWorktrees.Item
---@field text string Searchable text (branch name and display path concatenated).
---@field branch string Short branch name shown in the picker.
---@field ref string Full git ref (e.g. "refs/heads/main").
---@field wt_path string|nil Absolute path to the checked-out worktree, nil when none.
---@field display_path string Formatted worktree path for display; empty string when no worktree.
---@field is_remote boolean True for remote-tracking branches.
---@field is_current boolean True when this branch is the current HEAD.
---@field author string Committer name or email.
---@field date string Formatted committer date.

local M = {}

---Replace a leading `$HOME` in `abs_path` with `~`.
---The match is anchored to a path-component boundary, so with `HOME=/Users/andrei`
---the sibling `/Users/andreibulgakov/proj` is returned unchanged instead of becoming
---the nonsensical `~bulgakov/proj`.
---@param abs_path string
---@return string
function M.tilde_path(abs_path)
  local home = (vim.env.HOME or ""):gsub("/$", "")
  if home == "" then
    return abs_path
  end
  if abs_path == home then
    return "~"
  end
  if abs_path:sub(1, #home + 1) == home .. "/" then
    return "~" .. abs_path:sub(#home + 1)
  end
  return abs_path
end

---Compute the path of `abs_path` relative to `base`.
---Both arguments must be absolute paths.
---Returns paths with a "./" prefix (e.g. "./wt/branch") or ".." segments.
---Bare "." is returned as "./" and bare ".." as "../" for visual clarity.
---@param abs_path string
---@param base string
---@return string
local function relative_to(abs_path, base)
  abs_path = abs_path:gsub("/$", "")
  base = base:gsub("/$", "")

  ---@param p string
  ---@return string[]
  local function split(p)
    local parts = {}
    for seg in p:gmatch("[^/]+") do
      parts[#parts + 1] = seg
    end
    return parts
  end

  local tp = split(abs_path)
  local bp = split(base)

  local common = 0
  for i = 1, math.min(#tp, #bp) do
    if tp[i] == bp[i] then
      common = i
    else
      break
    end
  end

  local result = {}
  for _ = common + 1, #bp do
    result[#result + 1] = ".."
  end
  for i = common + 1, #tp do
    result[#result + 1] = tp[i]
  end

  if #result == 0 then
    return "./"
  end
  local rel = table.concat(result, "/")
  if result[1] ~= ".." then
    rel = "./" .. rel
  elseif rel == ".." then
    rel = "../"
  end
  return rel
end

---Format an absolute path for display according to the given mode.
---@param abs_path string|nil
---@param mode GitWorktrees.PathDisplay
---@param git_common_dir? string Required for relative-gitdir, absolute-gitdir, and tilde-gitdir modes.
---@param wt_base_path? string Required for relative-wt-base mode; the expanded worktree base directory.
---@param git_root? string Required for relative-repo mode; the root worktree path (equals git_common_dir for bare repos).
---@return string display path, or empty string when abs_path is nil/empty
function M.format_path(abs_path, mode, git_common_dir, wt_base_path, git_root)
  if not abs_path or abs_path == "" then
    return ""
  end
  mode = mode or "tilde"

  if mode == "absolute" then
    return abs_path
  elseif mode == "tilde" then
    return M.tilde_path(abs_path)
  elseif mode == "relative-cwd" then
    return vim.fn.fnamemodify(abs_path, ":.")
  elseif mode == "relative-home" then
    return vim.fn.fnamemodify(abs_path, ":~:.")
  elseif mode == "relative-repo" then
    return relative_to(abs_path, git_root or git_common_dir or abs_path)
  elseif mode == "relative-wt-base" then
    if not wt_base_path then
      return abs_path
    end
    return relative_to(abs_path, wt_base_path)
  elseif mode == "relative-gitdir" then
    if not git_common_dir then
      return abs_path
    end
    return relative_to(abs_path, git_common_dir)
  elseif mode == "absolute-gitdir" then
    if git_common_dir and abs_path:sub(1, #git_common_dir) == git_common_dir then
      return git_common_dir .. "/" .. abs_path:sub(#git_common_dir + 2)
    end
    return abs_path
  elseif mode == "tilde-gitdir" then
    if git_common_dir and abs_path:sub(1, #git_common_dir) == git_common_dir then
      return M.tilde_path(git_common_dir) .. "/" .. abs_path:sub(#git_common_dir + 2)
    end
    return M.tilde_path(abs_path)
  end

  -- fallback: tilde mode
  return M.tilde_path(abs_path)
end

---Build picker items by joining branch data with worktree data.
---The returned items are consumed by pickers and actions but never modified.
---@param branches GitWorktrees.Branch[]
---@param wt_data GitWorktrees.WorktreeData
---@param config GitWorktrees.Config
---@param current_ref string|nil Full ref of the current HEAD branch.
---@param wt_base_path? string Expanded worktree base path; required for relative-wt-base display mode.
---@return GitWorktrees.Item[]
function M.build_items(branches, wt_data, config, current_ref, wt_base_path)
  ---@type GitWorktrees.Item[]
  local items = {}
  for _, branch in ipairs(branches) do
    local wt_path = wt_data.wt_map[branch.ref]
    local display_path =
      M.format_path(wt_path, config.wt_path_display, wt_data.git_common_dir, wt_base_path, wt_data.git_root)

    table.insert(items, {
      -- Searchable text includes both branch name and path so both are filterable.
      text = branch.name .. (display_path ~= "" and ("  " .. display_path) or ""),
      branch = branch.name,
      ref = branch.ref,
      wt_path = wt_path,
      display_path = display_path,
      is_remote = branch.is_remote,
      is_current = branch.ref == current_ref,
      author = branch.author,
      date = branch.date,
    })
  end
  return items
end

return M
