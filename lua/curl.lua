local curl = {}
curl.config = {
  curl = nil, -- path to binary
  default_flags = { "-i" },
  open_cmd = "vsplit",
  map_execute = "<CR>", -- in query buffer
}

local H = {
  cache_dir = vim.fs.joinpath(vim.fn.stdpath "data", "curl_cache"),
  query_buf = nil,
  query_file = nil,
  query_buffers = {},
  query_autocmd_set = false,
  output_buf = nil,
  command_created = false,
  running_request = nil,
}

local function validate_config(config)
  vim.validate("curl.config", config, "table")
  vim.validate("curl.config.curl", config.curl, { "string", "nil" })
  vim.validate("curl.config.default_flags", config.default_flags, "table")
  vim.validate("curl.config.open_cmd", config.open_cmd, "string")
  vim.validate("curl.config.map_execute", config.map_execute, "string")
  for i, flag in ipairs(config.default_flags) do
    vim.validate("curl.config.default_flags[" .. i .. "]", flag, "string")
  end
end

local function is_valid_buf(buf)
  return type(buf) == "number" and buf > 0 and vim.api.nvim_buf_is_valid(buf)
end

local function is_valid_win(win)
  return type(win) == "number" and win > 0 and vim.api.nvim_win_is_valid(win)
end

local function set_buffer_option(buf, name, value)
  vim.api.nvim_set_option_value(name, value, { buf = buf })
end

local function configure_scratch_buffer(buf)
  set_buffer_option(buf, "buftype", "nofile")
  set_buffer_option(buf, "bufhidden", "hide")
  set_buffer_option(buf, "swapfile", false)
end

local function configure_query_buffer(buf)
  set_buffer_option(buf, "bufhidden", "hide")
  set_buffer_option(buf, "swapfile", false)
  set_buffer_option(buf, "modifiable", true)
end

local function trim_lines(lines)
  while #lines > 1 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

local function trim(s)
  local from = s:match "^%s*()"
  return from > #s and "" or s:match(".*%S", from)
end

local function is_query_start(line)
  if not line then return false end
  return line:match "^%s*curl%s" or line:match "^%s*curl$" or line:match "^%s*https?://"
end

local function is_curl_file(path)
  return type(path) == "string" and path ~= "" and path:sub(-5) == ".curl"
end

local function get_or_create_buffer(name)
  local existing = vim.fn.bufnr("^" .. name .. "$")
  if existing ~= -1 and is_valid_buf(existing) then return existing end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  configure_scratch_buffer(buf)
  return buf
end

local function ensure_dir(path)
  if vim.fn.isdirectory(path) == 1 then return true end
  return vim.fn.mkdir(path, "p") == 1
end

local function get_workspace_id()
  local cwd = vim.fn.getcwd()
  local base = vim.fn.fnamemodify(cwd, ":t")
  if base == "" then base = "root" end
  return base .. "_" .. vim.fn.sha256(cwd):sub(1, 8)
end

local function get_cache_file()
  if not ensure_dir(H.cache_dir) then
    vim.notify("[curl.nvim] failed to create cache dir: " .. H.cache_dir, vim.log.levels.ERROR)
    return nil
  end

  local cwd = vim.fn.getcwd()
  local hash = vim.fn.sha256(cwd)
  local new_file = vim.fs.joinpath(H.cache_dir, get_workspace_id() .. ".curl")
  local old_file = vim.fs.joinpath(H.cache_dir, hash)

  if vim.uv.fs_stat(old_file) then
    if not vim.uv.fs_stat(new_file) then
      vim.fn.rename(old_file, new_file)
    else
      vim.fn.rename(old_file, old_file .. ".archive")
    end
  end

  return new_file
end

local function save_query_buffer(buf, file)
  if not is_valid_buf(buf) then return end
  file = file or vim.api.nvim_buf_get_name(buf)
  if not is_curl_file(file) then return end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ok = pcall(vim.fn.writefile, lines, file, "b")
  if ok then
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })
  else
    vim.notify("[curl.nvim] failed to save request file: " .. file, vim.log.levels.ERROR)
  end
end

local function find_window_in_current_tab(bufnr)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == bufnr then return win end
  end
  return nil
end

local function is_json_start_line(line)
  return trim(line):match "^[%[%{]" ~= nil
end

local function schedule_output_write(text, is_json)
  vim.schedule(function()
    H.write_output(text, is_json)
  end)
end

local function extract_headers_and_json(output)
  local normalized = output:gsub("\r\n", "\n"):gsub("\r", "\n")
  if is_json_start_line(normalized) then return {}, normalized end

  local lines = vim.split(normalized, "\n", { plain = true })
  local json_index = nil
  for i, line in ipairs(lines) do
    if is_json_start_line(line) then
      json_index = i
      break
    end
  end

  if not json_index then return nil, nil end

  local headers = {}
  for i = 1, json_index - 1 do
    table.insert(headers, trim(lines[i]))
  end

  local json_lines = {}
  for i = json_index, #lines do
    table.insert(json_lines, lines[i])
  end

  return headers, table.concat(json_lines, "\n")
end

local function merge_headers_and_json(headers, json)
  if not headers or #headers == 0 then return json end
  local merged = vim.deepcopy(headers)
  vim.list_extend(merged, vim.split(json, "\n", { plain = true }))
  return table.concat(merged, "\n")
end

local function shell_split(input)
  local args = {}
  local current = {}
  local quote = nil
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

local function resolve_query_buffer()
  if is_valid_buf(H.query_buf) then return H.query_buf end

  local current = vim.api.nvim_get_current_buf()
  local current_name = vim.api.nvim_buf_get_name(current)
  if is_curl_file(current_name) then
    H.set_query_context(current, current_name)
    return current
  end

  return H.get_query_buffer()
end

local function stop_running_request()
  if not H.running_request then return end
  pcall(function()
    H.running_request:kill(15)
  end)
  H.running_request = nil
end

local function result_to_output(result)
  local chunks = {}
  if result.stdout and result.stdout ~= "" then table.insert(chunks, result.stdout) end
  if result.stderr and result.stderr ~= "" then table.insert(chunks, result.stderr) end

  if #chunks == 0 then return "curl exited with code " .. result.code end

  return table.concat(chunks, "\n\n")
end

function H.set_query_mapping(buf)
  if not is_valid_buf(buf) then return end

  vim.keymap.set("n", curl.config.map_execute, curl.execute, {
    buffer = buf,
    noremap = true,
    silent = true,
    desc = "Execute curl query under cursor",
  })
end

function H.attach_curl_buffer(buf)
  if not is_valid_buf(buf) then return false end
  local name = vim.api.nvim_buf_get_name(buf)
  if not is_curl_file(name) then return false end

  set_buffer_option(buf, "filetype", "curl")
  set_buffer_option(buf, "syntax", "sh")
  set_buffer_option(buf, "commentstring", "# %s")
  pcall(vim.treesitter.language.register, "bash", "curl")
  H.set_query_mapping(buf)
  H.query_buffers[name] = buf
  return true
end

local function create_query_buffer(file)
  local buf = vim.fn.bufadd(file)
  vim.fn.bufload(buf)
  configure_query_buffer(buf)
  H.attach_curl_buffer(buf)

  local group = vim.api.nvim_create_augroup("curl_nvim_cache_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufLeave", "VimLeavePre" }, {
    group = group,
    buffer = buf,
    callback = function()
      save_query_buffer(buf, file)
    end,
  })

  return buf
end

function H.set_query_context(buf, file)
  if not is_valid_buf(buf) then return false end
  file = file or vim.api.nvim_buf_get_name(buf)
  if not is_curl_file(file) then return false end

  H.query_buf = buf
  H.query_file = file
  H.query_buffers[file] = buf
  return true
end

function H.setup_filetype()
  vim.filetype.add {
    extension = { curl = "curl" },
  }
end

function H.setup_command()
  if H.command_created then return end

  vim.api.nvim_create_user_command("Curl", function()
    curl.open()
  end, { desc = "Open curl.nvim query buffer" })
  H.command_created = true
end

function H.get_query_buffer()
  local file = get_cache_file()
  if not file then return nil end

  local existing = H.query_buffers[file]
  if not is_valid_buf(existing) then existing = create_query_buffer(file) end

  H.query_buffers[file] = existing
  H.set_query_context(existing, file)
  H.set_query_mapping(existing)
  return existing
end

function H.setup_query_file_autocmd()
  if H.query_autocmd_set then return end

  local group = vim.api.nvim_create_augroup("curl_nvim_query_files", { clear = true })
  vim.api.nvim_create_autocmd(
    { "BufReadPost", "BufNewFile", "BufEnter", "BufWinEnter", "BufFilePost" },
    {
      group = group,
      pattern = "*.curl",
      callback = function(args)
        H.attach_curl_buffer(args.buf)
      end,
    }
  )

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    H.attach_curl_buffer(buf)
  end

  H.query_autocmd_set = true
end

function H.get_output_buffer()
  if is_valid_buf(H.output_buf) then return H.output_buf end

  H.output_buf = get_or_create_buffer "Curl output"
  set_buffer_option(H.output_buf, "filetype", "json")
  set_buffer_option(H.output_buf, "modifiable", false)
  return H.output_buf
end

function H.open_output_window()
  local output_buf = H.get_output_buffer()
  local query_buf = resolve_query_buffer()
  if not query_buf then return nil end

  local query_win = find_window_in_current_tab(query_buf) or vim.api.nvim_get_current_win()
  local output_win = find_window_in_current_tab(output_buf)

  if is_valid_win(output_win) then return output_win end

  vim.api.nvim_set_current_win(query_win)
  vim.cmd(curl.config.open_cmd)
  output_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(output_win, output_buf)
  vim.api.nvim_set_current_win(query_win)
  return output_win
end

function H.find_query_block(lines, cursor_line)
  if not lines[cursor_line] or vim.trim(lines[cursor_line]) == "" then return nil end

  local start_line = nil
  for line_no = cursor_line, 1, -1 do
    local line = lines[line_no]
    if is_query_start(line) then
      start_line = line_no
      break
    end
    if vim.trim(line) == "" then break end
  end
  if not start_line then return nil end

  local end_line = #lines
  for line_no = start_line + 1, #lines do
    local line = lines[line_no]
    if is_query_start(line) or vim.trim(line) == "" then
      end_line = line_no - 1
      break
    end
  end

  if cursor_line < start_line or cursor_line > end_line then return nil end
  return start_line, end_line
end

function H.build_command(query_lines)
  local binary = curl.config.curl or "curl"
  local body_parts = {}

  for _, line in ipairs(query_lines) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not trimmed:match "^#" then
      table.insert(body_parts, trimmed:gsub("\\%s*$", ""))
    end
  end

  local body = vim.trim(table.concat(body_parts, " "))
  if body == "" then return nil, "empty query" end

  local parsed, parse_err = shell_split(body)
  if not parsed or #parsed == 0 then return nil, parse_err end
  if parsed[1] == "curl" then table.remove(parsed, 1) end

  local command = { binary, "--silent", "--show-error" }
  vim.list_extend(command, curl.config.default_flags)
  vim.list_extend(command, parsed)
  return command, nil
end

function H.write_formatted_output(output)
  if output == "" or vim.fn.executable "jq" ~= 1 then
    schedule_output_write(output, false)
    return
  end

  local headers, json_candidate = extract_headers_and_json(output)
  if not json_candidate or json_candidate == "" then
    schedule_output_write(output, false)
    return
  end

  vim.system({ "jq", "." }, {
    text = true,
    stdin = json_candidate,
  }, function(result)
    local text = output
    local is_json = false

    if result.code == 0 and result.stdout and result.stdout ~= "" then
      is_json = true
      text = merge_headers_and_json(headers, result.stdout)
    end

    schedule_output_write(text, is_json)
  end)
end

function H.write_output(text, is_json)
  local output_buf = H.get_output_buffer()
  local lines = trim_lines(vim.split(text, "\n", { plain = true }))
  if #lines == 0 then lines = { "" } end

  set_buffer_option(output_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, lines)
  set_buffer_option(output_buf, "modifiable", false)
  set_buffer_option(output_buf, "filetype", is_json and "json" or "text")
end

function curl.setup(opts)
  local config = vim.tbl_deep_extend("force", curl.config, opts or {})
  validate_config(config)
  curl.config = config

  H.setup_filetype()
  H.setup_command()
  H.setup_query_file_autocmd()
end

function curl.open()
  local query_buf = H.get_query_buffer()
  if not query_buf then return end

  local query_win = find_window_in_current_tab(query_buf)
  if is_valid_win(query_win) then
    vim.api.nvim_set_current_win(query_win)
  else
    vim.api.nvim_set_current_buf(query_buf)
  end
end

function curl.execute()
  local query_buf = vim.api.nvim_get_current_buf()
  local query_file = vim.api.nvim_buf_get_name(query_buf)
  if not is_curl_file(query_file) then
    vim.notify("[curl.nvim] execute from a .curl request buffer", vim.log.levels.WARN)
    return
  end
  H.set_query_context(query_buf, query_file)

  local lines = vim.api.nvim_buf_get_lines(query_buf, 0, -1, false)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local start_line, end_line = H.find_query_block(lines, cursor_line)
  if not start_line then
    vim.notify("[curl.nvim] cursor is not on a query line", vim.log.levels.INFO)
    return
  end

  local query_lines = vim.list_slice(lines, start_line, end_line)
  local command, command_err = H.build_command(query_lines)
  if not command then
    vim.notify("[curl.nvim] " .. (command_err or "invalid query"), vim.log.levels.WARN)
    return
  end

  save_query_buffer(query_buf, query_file)
  H.open_output_window()
  stop_running_request()

  H.running_request = vim.system(command, { text = true }, function(result)
    H.running_request = nil
    H.write_formatted_output(result_to_output(result))
  end)
end

return curl
