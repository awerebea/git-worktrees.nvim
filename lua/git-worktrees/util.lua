local M = {}

---Wrapper around vim.notify that applies the plugin-configured notification timeout.
---Pass an explicit timeout (ms) to override the global notify_timeout for that call.
---@param msg string
---@param level integer vim.log.levels constant.
---@param timeout? integer|nil Override timeout in ms; nil falls back to notify_timeout config.
function M.notify(msg, level, timeout)
  local config = require("git-worktrees").config
  local t = timeout ~= nil and timeout or config.notify_timeout
  vim.notify(msg, level, t ~= nil and { timeout = t } or nil)
end

return M
