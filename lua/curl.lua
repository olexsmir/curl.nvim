local H = {
  cache_dir = vim.fs.joinpath(vim.fn.stdpath "data", "curl_cache"),
  query_buffers = {},
  query_autocmd_set = false,
  output_buf = nil,
  command_created = false,
  running_request = nil,
}

local curl = {}
curl.config = {
  curl = nil, -- path to binary
  default_flags = { "-i" },
  open_cmd = "vsplit",
  map_execute = "<CR>",
}

function curl.setup(opts)
  opts = opts or {}
  vim.validate("opts", opts, "table")
  curl.config = vim.tbl_deep_extend("force", curl.config, opts)
  vim.filetype.add { extension = { curl = "curl" } }

  if not H.command_created then
    vim.api.nvim_create_user_command("Curl", function()
      curl.open()
    end, { desc = "Open curl.nvim query buffer" })
    H.command_created = true
  end

  if not H.query_autocmd_set then
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter", "BufWinEnter", "BufFilePost" }, {
      group = vim.api.nvim_create_augroup("curl_nvim_query_files", { clear = true }),
      pattern = "*.curl",
      callback = function(args)
        H.attach_curl_buffer(args.buf)
      end,
    })
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      H.attach_curl_buffer(buf)
    end
    H.query_autocmd_set = true
  end
end

function curl.open()
  local query_buf = H.get_query_buffer()
  if not query_buf then return end
  local query_win = H.find_window(query_buf)
  if query_win and vim.api.nvim_win_is_valid(query_win) then
    vim.api.nvim_set_current_win(query_win)
  else
    vim.api.nvim_set_current_buf(query_buf)
  end
end

function curl.execute()
  local query_buf = vim.api.nvim_get_current_buf()
  local query_file = vim.api.nvim_buf_get_name(query_buf)
  if not H.is_curl_file(query_file) then
    vim.notify("[curl.nvim] execute from a .curl request buffer", vim.log.levels.WARN)
    return
  end
  H.query_buffers[query_file] = query_buf

  local lines = vim.api.nvim_buf_get_lines(query_buf, 0, -1, false)
  local start_line, end_line = H.find_query_block(lines, vim.api.nvim_win_get_cursor(0)[1])
  if not start_line then
    vim.notify("[curl.nvim] cursor is not on a query line", vim.log.levels.INFO)
    return
  end

  local command, err = H.build_command(vim.list_slice(lines, start_line, end_line))
  if not command then
    vim.notify("[curl.nvim] " .. (err or "invalid query"), vim.log.levels.WARN)
    return
  end

  H.save_query_buffer(query_buf, query_file)
  H.open_output_window(query_buf)

  if H.running_request then
    pcall(function()
      H.running_request:kill(15)
    end)
    H.running_request = nil
  end

  H.running_request = vim.system(command, { text = true }, function(result)
    H.running_request = nil
    local output = result.stdout or ""
    if result.stderr and result.stderr ~= "" then
      output = output == "" and result.stderr or (output .. "\n\n" .. result.stderr)
    end
    if output == "" then output = "curl exited with code " .. result.code end
    H.write_formatted_output(output)
  end)
end

function H.is_valid_buf(buf)
  return type(buf) == "number" and buf > 0 and vim.api.nvim_buf_is_valid(buf)
end

function H.is_curl_file(path)
  return type(path) == "string" and path ~= "" and path:sub(-5) == ".curl"
end

function H.is_query_start(line)
  if not line then return false end
  return line:match "^%s*curl%s" or line:match "^%s*curl$" or line:match "^%s*https?://"
end

function H.save_query_buffer(buf, file)
  if not H.is_valid_buf(buf) then return end
  file = file or vim.api.nvim_buf_get_name(buf)
  if not H.is_curl_file(file) then return end

  local ok = pcall(vim.fn.writefile, vim.api.nvim_buf_get_lines(buf, 0, -1, false), file, "b")
  if ok then
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })
  else
    vim.notify("[curl.nvim] failed to save request file: " .. file, vim.log.levels.ERROR)
  end
end

function H.query_cache_file()
  if vim.fn.isdirectory(H.cache_dir) ~= 1 and vim.fn.mkdir(H.cache_dir, "p") ~= 1 then
    vim.notify("[curl.nvim] failed to create cache dir: " .. H.cache_dir, vim.log.levels.ERROR)
    return nil
  end

  local cwd = vim.fn.getcwd()
  local base = vim.fn.fnamemodify(cwd, ":t")
  if base == "" then base = "root" end
  return vim.fs.joinpath(H.cache_dir, base .. "_" .. vim.fn.sha256(cwd):sub(1, 8) .. ".curl")
end

function H.attach_curl_buffer(buf)
  if not H.is_valid_buf(buf) then return false end
  local name = vim.api.nvim_buf_get_name(buf)
  if not H.is_curl_file(name) then return false end

  vim.api.nvim_set_option_value("filetype", "curl", { buf = buf })
  vim.api.nvim_set_option_value("syntax", "sh", { buf = buf })
  vim.api.nvim_set_option_value("commentstring", "# %s", { buf = buf })
  pcall(vim.treesitter.language.register, "bash", "curl")
  vim.keymap.set("n", curl.config.map_execute, curl.execute, {
    buffer = buf,
    noremap = true,
    silent = true,
    desc = "Execute curl query under cursor",
  })
  H.query_buffers[name] = buf
  return true
end

function H.get_query_buffer()
  local file = H.query_cache_file()
  if not file then return nil end

  local buf = H.query_buffers[file]
  if not H.is_valid_buf(buf) then
    buf = vim.fn.bufadd(file)
    vim.fn.bufload(buf)
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufLeave", "VimLeavePre" }, {
      group = vim.api.nvim_create_augroup("curl_nvim_cache_" .. buf, { clear = true }),
      buffer = buf,
      callback = function()
        H.save_query_buffer(buf, file)
      end,
    })
  end

  H.attach_curl_buffer(buf)
  return buf
end

local function get_output_buffer()
  if H.is_valid_buf(H.output_buf) then return H.output_buf end

  local existing = vim.fn.bufnr "^Curl output$"
  if existing ~= -1 and H.is_valid_buf(existing) then
    H.output_buf = existing
  else
    H.output_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(H.output_buf, "Curl output")
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = H.output_buf })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = H.output_buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = H.output_buf })
  end

  vim.api.nvim_set_option_value("filetype", "json", { buf = H.output_buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = H.output_buf })
  return H.output_buf
end

function H.find_window(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then return win end
  end
end

function H.open_output_window(query_buf)
  local output_buf = get_output_buffer()
  local output_win = H.find_window(output_buf)
  if output_win and vim.api.nvim_win_is_valid(output_win) then return output_win end

  local query_win = H.find_window(query_buf) or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(query_win) then return nil end

  vim.api.nvim_set_current_win(query_win)
  vim.cmd(curl.config.open_cmd)
  vim.api.nvim_win_set_buf(0, output_buf)
  vim.api.nvim_set_current_win(query_win)
  return vim.api.nvim_get_current_win()
end

function H.find_query_block(lines, cursor_line)
  if not lines[cursor_line] or vim.trim(lines[cursor_line]) == "" then return nil end

  local start_line
  for i = cursor_line, 1, -1 do
    if H.is_query_start(lines[i]) then
      start_line = i
      break
    end
    if vim.trim(lines[i]) == "" then break end
  end
  if not start_line then return nil end

  local end_line = #lines
  for i = start_line + 1, #lines do
    if H.is_query_start(lines[i]) or vim.trim(lines[i]) == "" then
      end_line = i - 1
      break
    end
  end

  if cursor_line < start_line or cursor_line > end_line then return nil end
  return start_line, end_line
end

function H.shell_split(input)
  local args, current, quote = {}, {}, nil
  local i = 1
  while i <= #input do
    local ch = input:sub(i, i)
    if quote == "'" then
      if ch == "'" then
        quote = nil
      else
        table.insert(current, ch)
      end
    elseif quote == '"' then
      if ch == '"' then
        quote = nil
      elseif ch == "\\" and i < #input then
        i = i + 1
        table.insert(current, input:sub(i, i))
      else
        table.insert(current, ch)
      end
    else
      if ch == "'" or ch == '"' then
        quote = ch
      elseif ch:match "%s" then
        if #current > 0 then
          table.insert(args, table.concat(current))
          current = {}
        end
      elseif ch == "\\" and i < #input then
        i = i + 1
        table.insert(current, input:sub(i, i))
      else
        table.insert(current, ch)
      end
    end
    i = i + 1
  end

  if quote then return nil, "unterminated quote in query" end
  if #current > 0 then table.insert(args, table.concat(current)) end
  return args
end

function H.build_command(query_lines)
  local body_parts = {}
  for _, line in ipairs(query_lines) do
    local s = vim.trim(line)
    if s ~= "" and not s:match "^#" then table.insert(body_parts, s:gsub("\\%s*$", "")) end
  end

  local body = vim.trim(table.concat(body_parts, " "))
  if body == "" then return nil, "empty query" end

  local parsed, err = H.shell_split(body)
  if not parsed or #parsed == 0 then return nil, err end
  if parsed[1] == "curl" then table.remove(parsed, 1) end

  local cmd = { curl.config.curl or "curl", "--silent", "--show-error" }
  vim.list_extend(cmd, curl.config.default_flags or {})
  vim.list_extend(cmd, parsed)
  return cmd
end

function H.write_output(text, is_json)
  local buf = get_output_buffer()
  local lines = vim.split(text or "", "\n", { plain = true })
  while #lines > 1 and lines[#lines] == "" do
    table.remove(lines)
  end
  if #lines == 0 then lines = { "" } end

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", is_json and "json" or "text", { buf = buf })
end

function H.write_formatted_output(output)
  if output == "" or vim.fn.executable "jq" ~= 1 then
    vim.schedule(function()
      H.write_output(output, false)
    end)
    return
  end

  local lines = vim.split(output:gsub("\r\n", "\n"):gsub("\r", "\n"), "\n", { plain = true })
  local json_index
  for i, line in ipairs(lines) do
    if vim.trim(line):match "^[%[%{]" then
      json_index = i
      break
    end
  end
  if not json_index then
    vim.schedule(function()
      H.write_output(output, false)
    end)
    return
  end

  local headers = {}
  for i = 1, json_index - 1 do
    table.insert(headers, vim.trim(lines[i]))
  end
  local json_body = table.concat(vim.list_slice(lines, json_index, #lines), "\n")

  vim.system({ "jq", "." }, { text = true, stdin = json_body }, function(result)
    local text, is_json = output, false
    if result.code == 0 and result.stdout and result.stdout ~= "" then
      is_json = true
      text = #headers > 0 and (table.concat(headers, "\n") .. "\n" .. result.stdout) or result.stdout
    end
    vim.schedule(function()
      H.write_output(text, is_json)
    end)
  end)
end

return curl
