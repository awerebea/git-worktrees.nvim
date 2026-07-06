local M = {}

-- Format an absolute path according to the display mode.
-- mode: "tilde" | "absolute" | "relative" | "gitdir" | "gitdir-tilde"
function M.format_path(abs_path, mode, git_common_dir)
  if not abs_path or abs_path == "" then
    return ""
  end
  mode = mode or "tilde"
  local home = vim.env.HOME or ""

  if mode == "absolute" then
    return abs_path

  elseif mode == "tilde" then
    if home ~= "" and abs_path:sub(1, #home) == home then
      return "~" .. abs_path:sub(#home + 1)
    end
    return abs_path

  elseif mode == "relative" then
    -- Use Neovim's built-in path shortening: relative to CWD, then tilde
    return vim.fn.fnamemodify(abs_path, ":~:.")

  elseif mode == "gitdir" then
    if git_common_dir and abs_path:sub(1, #git_common_dir) == git_common_dir then
      return git_common_dir .. "/" .. abs_path:sub(#git_common_dir + 2)
    end
    return abs_path

  elseif mode == "gitdir-tilde" then
    if git_common_dir and abs_path:sub(1, #git_common_dir) == git_common_dir then
      local gcd = git_common_dir
      if home ~= "" and gcd:sub(1, #home) == home then
        gcd = "~" .. gcd:sub(#home + 1)
      end
      return gcd .. "/" .. abs_path:sub(#git_common_dir + 2)
    end
    if home ~= "" and abs_path:sub(1, #home) == home then
      return "~" .. abs_path:sub(#home + 1)
    end
    return abs_path
  end

  -- fallback: tilde
  if home ~= "" and abs_path:sub(1, #home) == home then
    return "~" .. abs_path:sub(#home + 1)
  end
  return abs_path
end

-- Build picker items combining branches with worktree data.
-- Each item: { text, branch, ref, wt_path, display_path, is_remote, is_detached,
--              is_current, author, date, bracket_open, bracket_close }
function M.build_items(branches, wt_data, config, current_ref)
  local items = {}
  for _, branch in ipairs(branches) do
    local wt_path = wt_data.wt_map[branch.ref]
    local display_path = M.format_path(wt_path, config.wt_path_display, wt_data.git_common_dir)

    local bracket_open, bracket_close
    if branch.is_remote then
      bracket_open, bracket_close = "(", ")"
    else
      bracket_open, bracket_close = "[", "]"
    end

    table.insert(items, {
      -- searchable text: branch name + path so both are filterable
      text = branch.name .. (display_path ~= "" and ("  " .. display_path) or ""),
      branch = branch.name,
      ref = branch.ref,
      wt_path = wt_path,
      display_path = display_path,
      is_remote = branch.is_remote,
      is_current = branch.ref == current_ref,
      author = branch.author,
      date = branch.date,
      bracket_open = bracket_open,
      bracket_close = bracket_close,
    })
  end
  return items
end

-- Compute display column widths from a list of items.
-- Returns { branch_w, path_w }
function M.column_widths(items, max_branch, max_path)
  local bw, pw = 0, 0
  for _, item in ipairs(items) do
    local bd = #(item.bracket_open .. item.branch .. item.bracket_close)
    if bd > bw then bw = bd end
    if #item.display_path > pw then pw = #item.display_path end
  end
  bw = math.min(bw + 2, max_branch or 50)
  pw = math.min(pw + 2, max_path or 60)
  return bw, pw
end

return M
