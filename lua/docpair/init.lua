local M = {}
M._opts = { info_filetype = "markdown" }

local function abs(path)
	return vim.fn.fnamemodify(path, ":p")
end

local function create_command()
	if vim.fn.exists(":Documented") == 2 then
		pcall(vim.api.nvim_del_user_command, "Documented")
	end

	vim.api.nvim_create_user_command("Documented", function(opts)
		local args = opts.fargs
		if #args > 2 then
			vim.api.nvim_echo({ { "Usage: :Documented [file] [infofile]", "ErrorMsg" } }, true, {})
			return
		end

    local f1
    if #args == 0 then
      f1 = vim.api.nvim_buf_get_name(0)  -- aktueller Buffer
    else
      f1 = abs(args[1])
    end

		local dir1 = vim.fn.fnamemodify(f1, ":h")
		local info_dir = dir1 .. "/.documented"
		if vim.fn.isdirectory(info_dir) == 0 then
			vim.fn.mkdir(info_dir, "p")
		end

		local info_name
		if #args == 2 then
			info_name = vim.fn.fnamemodify(args[2], ":t")
		else
			info_name = vim.fn.fnamemodify(f1, ":t") .. "_info"
		end
		local f2 = info_dir .. "/" .. info_name

		if vim.fn.filereadable(f2) == 0 then
			vim.fn.writefile({}, f2)
		end

		local src_lines = vim.fn.readfile(f1)
		local info_lines = vim.fn.readfile(f2)
		if #info_lines < #src_lines then
			for _ = 1, (#src_lines - #info_lines) do
				table.insert(info_lines, "")
			end
			vim.fn.writefile(info_lines, f2)
		end

		local esc1, esc2 = vim.fn.fnameescape(f1), vim.fn.fnameescape(f2)

		if opts.bang then
			vim.cmd("edit " .. esc1)
			vim.cmd("only")
			vim.cmd("vsplit " .. esc2)
		else
			vim.cmd("tabnew")
			vim.cmd("edit " .. esc1)
			vim.cmd("vsplit " .. esc2)
		end

		local win_right = vim.api.nvim_get_current_win()
		vim.cmd("wincmd h")
		local win_left = vim.api.nvim_get_current_win()
		local buf_right = vim.api.nvim_win_get_buf(win_right)

		local info_ft = (M._opts and M._opts.info_filetype) or "markdown"
		pcall(vim.api.nvim_buf_set_option, buf_right, "filetype", info_ft)

		local function prep_no_bind(win)
			vim.api.nvim_win_call(win, function()
				vim.cmd("setlocal nowrap nolinebreak nofoldenable conceallevel=0")
				vim.cmd("setlocal scrolloff=0 sidescrolloff=0")
				vim.cmd("normal! ggzt")
			end)
		end

		prep_no_bind(win_left)
		prep_no_bind(win_right)
		vim.o.scrollopt = "ver,hor,jump"
		vim.cmd("windo setlocal scrollbind cursorbind")
		vim.cmd("syncbind")
	end, { nargs = "*", bang = true, complete = "file", desc = "Open file + sidecar info in .documented" })
end

function M.setup(opts)
	M._opts = vim.tbl_deep_extend("force", M._opts, opts or {})
	create_command()
	local docs = vim.api.nvim_get_runtime_file("doc/docpair.txt", false)
	if #docs > 0 then
		local docdir = vim.fn.fnamemodify(docs[1], ":h")
		pcall(vim.cmd, "silent! helptags " .. docdir)
	end
end

return M
