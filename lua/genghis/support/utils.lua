local M = {}
--------------------------------------------------------------------------------

---@param msg string
---@param level? "info"|"trace"|"debug"|"warn"|"error"
---@param opts? table
function M.notify(msg, level, opts)
	local successNotify = require("genghis.config").config.successNotifications
	if not level then level = "info" end
	if level == "info" and not successNotify then return end
	if not opts then opts = {} end

	opts.title = opts.title and "Genghis: " .. opts.title or "Genghis"
	vim.notify(msg, vim.log.levels[level:upper()], opts)
end

--------------------------------------------------------------------------------
return M
