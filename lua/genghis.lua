local M = {}

local expand = vim.fn.expand
local fn = vim.fn
local cmd = vim.cmd
--------------------------------------------------------------------------------

---@param bufnr? number|"#"|"$"
local function bwipeout(bufnr)
	bufnr = bufnr and fn.bufnr(bufnr) or 0 ---@diagnostic disable-line: param-type-mismatch
	vim.api.nvim_buf_delete(bufnr, { force = true })
end

--- Requests a 'workspace/willRenameFiles' on any running LSP client, that supports it
--- stolen from https://github.com/LazyVim/LazyVim/blob/fecc5faca25c209ed62e3658dd63731e26c0c643/lua/lazyvim/util/init.lua#L304
---@param fromName string
---@param toName string
local function onRename(fromName, toName)
	local clients = vim.lsp.get_active_clients { bufnr = 0 }
	for _, client in ipairs(clients) do
		if client:supports_method("workspace/willRenameFiles") then
			local resp = client.request_sync("workspace/willRenameFiles", {
				files = {
					{ oldUri = vim.uri_from_fname(fromName), newUri = vim.uri_from_fname(toName) },
				},
			}, 1000)
			if resp and resp.result ~= nil then
				vim.lsp.util.apply_workspace_edit(resp.result, client.offset_encoding)
			end
		end
	end
end

---@nodiscard
---@return boolean
local function lspSupportsRenaming()
	-- INFO `client:supports_method()` seems to always return true, whatever is 
	-- supplied as argument. This does not affect `onRename`, but here we need to
	-- check for the server_capabilities to properly identify whether our LSP
	-- supports renaming or not.
	-- TODO investigate if `client:supports_method()` works in nvim 0.10 or later
	local clients = vim.lsp.get_active_clients { bufnr = 0 }
	for _, client in ipairs(clients) do
		local workspaceCap = client.server_capabilities.workspace
		local supports = workspaceCap and workspaceCap.fileOperations and workspaceCap.fileOperations.willRename
		if supports then return true end
	end
	return false
end

-- https://github.com/neovim/neovim/issues/17735#issuecomment-1068525617
local function leaveVisualMode()
	local escKey = vim.api.nvim_replace_termcodes("<Esc>", false, true, true)
	vim.api.nvim_feedkeys(escKey, "nx", false)
end

---send notification
---@param msg string
---@param level? "info"|"trace"|"debug"|"warn"|"error"
local function notify(msg, level)
	if not level then level = "info" end
	vim.notify(msg, vim.log.levels[level:upper()], { title = "nvim-genghis" })
end

---@param filepath string
---@return boolean
local function fileExists(filepath) return vim.loop.fs_stat(filepath) ~= nil end

---move file
---use instead of fs_rename to support moving across partitions
---@param oldFilePath string
---@param newFilePath string
local function moveFile(oldFilePath, newFilePath)
	local copied, copiedError = vim.loop.fs_copyfile(oldFilePath, newFilePath)
	if copied then
		local deleted, deletedError = vim.loop.fs_unlink(oldFilePath)
		if deleted then
			return true
		else
			notify(("Failed to delete %q: %q"):format(oldFilePath, deletedError), "error")
			return false
		end
	else
		notify(("Failed to move %q to %q: %q"):format(oldFilePath, newFilePath, copiedError), "error")
		return false
	end
end

--------------------------------------------------------------------------------

---Performing common file operation tasks
---@param op "rename"|"duplicate"|"new"|"newFromSel"|"move-rename"
local function fileOp(op)
	local dir = expand("%:p:h") -- same directory, *not* pwd
	local oldName = expand("%:t")
	local oldFilePath = expand("%:p")
	local oldNameNoExt = oldName:gsub("%.%w+$", "")
	local oldExt = expand("%:e")
	if oldExt ~= "" then oldExt = "." .. oldExt end

	local prevReg
	if op == "newFromSel" then
		prevReg = fn.getreg("z")
		leaveVisualMode()
		cmd([['<,'>delete z]])
	end

	local promptStr, prefill
	if op == "duplicate" then
		promptStr = "Duplicate File as: "
		prefill = oldNameNoExt .. "-1"
	elseif op == "rename" then
		promptStr = lspSupportsRenaming() and "Rename File & Update Imports:" or "Rename File to:"
		prefill = oldNameNoExt
	elseif op == "move-rename" then
		promptStr = lspSupportsRenaming() and "Move-Rename File & Update Imports:" or "Move & Rename File to:"
		prefill = dir .. "/"
	elseif op == "new" or op == "newFromSel" then
		promptStr = "Name for New File: "
		prefill = ""
	end

	-- INFO completion = "dir" allows for completion via cmp-omni
	vim.ui.input({ prompt = promptStr, default = prefill, completion = "dir" }, function(newName)
		cmd.redraw() -- Clear message area from ui.input prompt

		-- VALIDATION OF FILENAME
		if not newName then return end -- input has been canceled

		if newName:find("/$") then
			newName = newName .. oldName -- use the new directory with the old name
		end

		local invalidName = newName:find("^%s+$")
			or newName:find("[\\:]")
			or (newName:find("^/") and not op == "move-rename")
		local sameName = newName == oldName
		local emptyInput = newName == ""

		if invalidName or sameName or (emptyInput and op ~= "new") then
			if op == "newFromSel" then
				cmd.undo() -- undo deletion
				fn.setreg("z", prevReg) -- restore register content
			end
			if invalidName or emptyInput then
				notify("Invalid filename.", "error")
			elseif sameName then
				notify("Cannot use the same filename.", "error")
			end
			return
		end

		-- exception: new file creaton allows for empty input
		if emptyInput and op == "new" then newName = "Untitled" end

		-- DETERMINE PATH AND EXTENSION
		local hasPath = newName:find("/")
		if hasPath then
			local newFolder = vim.fs.dirname(newName)
			fn.mkdir(newFolder, "p") -- create folders if necessary
		end

		local extProvided = newName:find(".%.[^/]*$") -- non-leading dot to not include dotfiles without extension
		if not extProvided then newName = newName .. oldExt end
		local newFilePath = (op == "move-rename") and newName or dir .. "/" .. newName

		if fileExists(newFilePath) then
			notify(("File with name %q already exists."):format(newFilePath), "error")
			return
		end

		-- EXECUTE FILE OPERATION
		cmd.update() -- save current file; needed for users with `vim.opt.hidden=false`
		if op == "duplicate" then
			local success = vim.loop.fs_copyfile(oldFilePath, newFilePath)
			if success then
				cmd.edit(newFilePath)
				notify(("Duplicated %q as %q."):format(oldName, newName))
			end
		elseif op == "rename" or op == "move-rename" then
			onRename(oldFilePath, newFilePath)
			local success = moveFile(oldFilePath, newFilePath)
			if success then
				cmd.edit(newFilePath)
				bwipeout("#")
				notify(("Renamed %q to %q."):format(oldName, newName))
			end
		elseif op == "new" or op == "newFromSel" then
			cmd.edit(newFilePath)
			if op == "newFromSel" then
				cmd("put z") -- cmd.put("z") does not work
				fn.setreg("z", prevReg) -- restore register content
			end
			cmd.write(newFilePath)
		end
	end)
end

function M.renameFile() fileOp("rename") end
function M.moveAndRenameFile() fileOp("move-rename") end
function M.duplicateFile() fileOp("duplicate") end
function M.createNewFile() fileOp("new") end
function M.moveSelectionToNewFile() fileOp("newFromSel") end

--------------------------------------------------------------------------------

---copying file information
---@param expandOperation string
local function copyOp(expandOperation)
	local reg = '"'
	local clipboardOpt = vim.opt.clipboard:get()
	local useSystemClipb = vim.g.genghis_use_systemclipboard
		or (#clipboardOpt > 0 and clipboardOpt[1]:find("unnamed"))
	if useSystemClipb then reg = "+" end

	local toCopy = expand(expandOperation)
	fn.setreg(reg, toCopy)
	vim.notify(toCopy, vim.log.levels.INFO, { title = "Copied" })
end

function M.copyFilepath() copyOp("%:p") end
function M.copyFilename() copyOp("%:t") end
function M.copyRelativePath() copyOp("%:~:.") end
function M.copyDirectoryPath() copyOp("%:p:h") end
function M.copyRelativeDirectoryPath() copyOp("%:~:.:h") end

--------------------------------------------------------------------------------

---Makes current file executable
function M.chmodx()
	local filename = expand("%")
	local perm = fn.getfperm(filename)
	perm = perm:gsub("r(.)%-", "r%1x") -- add x to every group that has r
	fn.setfperm(filename, perm)
	notify("Execution Permission granted.")
	cmd.edit()
end

---@param opts? table
function M.trashFile(opts)
	cmd.update { bang = true }
	local trash
	local home = os.getenv("HOME")
	local oldName = expand("%:t")
	local oldFilePath = expand("%:p")

	-- Default trash locations
	if fn.has("linux") == 1 then
		local xdg_data = os.getenv("XDG_DATA_HOME")
		trash = xdg_data and xdg_data .. "/Trash/" or home .. "/.local/share/Trash/"
	elseif fn.has("macunix") == 1 then
		-- INFO macOS moves files to the icloud trash, if they are deleted from
		-- icloud folder, otherwise they go the user trash folder
		local iCloudPath = home .. "/Library/Mobile Documents/com~apple~CloudDocs"
		local isInICloud = fn.expand("%:p:h"):sub(1, #iCloudPath) == iCloudPath
		trash = isInICloud and iCloudPath .. "/.Trash/" or home .. "/.Trash/"
	else
		-- TODO better support for windows
		trash = home .. "/.Trash/"
	end

	-- overwrite trash location, if specified by user
	if opts and opts.trashLocation then
		trash = opts.trashLocation
		if not (trash:find("/$")) then trash = trash .. "/" end 
	end

	fn.mkdir(trash, "p")
	if fileExists(trash .. oldName) then oldName = oldName .. "~" end

	if moveFile(oldFilePath, trash .. oldName) then
		bwipeout()
		notify(("%q deleted"):format(oldName))
	end
end

--------------------------------------------------------------------------------
return M
