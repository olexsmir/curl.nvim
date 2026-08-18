if vim.g.loaded_curl_plugin ~= nil then return end
vim.g.loaded_curl_plugin = true

---@class curl.Config
vim.g.curl_config = {
  execute_map = "<cr>",
  curl_bin = "curl",
  ---@type string[]
  flags = { "-i" },
}

local output_buf, running_request

local function is_query_start(line)
  local first = line and line:match "^%s*([%w:]+)"
  return first ~= nil and (first == "curl" or first:match "^https?:$" ~= nil)
end

local function find_query_block(lines, curline)
  if vim.trim(lines[curline] or "") == "" then return nil end

  local start_line = curline
  while start_line > 1 and not is_query_start(lines[start_line]) do
    start_line = start_line - 1
  end
  if not is_query_start(lines[start_line]) then return nil end

  local end_line = #lines
  for i = start_line + 1, #lines do
    if is_query_start(lines[i]) then
      end_line = i - 1
      break
    end
  end
  return start_line, end_line
end

local function count_char(s, ch) return select(2, s:gsub("%" .. ch, "")) end
local function quote_json_bodies(qlines)
  local res, open, depth = {}, nil, 0
  for _, line in ipairs(qlines) do
    local t = vim.trim(line)
    if not open and t:match "^[%[%{]" then
      open = t:sub(1, 1)
      line = "'" .. line
    end
    if open then
      local close = open == "{" and "}" or "]"
      depth = depth + count_char(line, open) - count_char(line, close)
      if depth == 0 then
        line = line .. "'"
        open = nil
      end
    end
    res[#res + 1] = line
  end
  return res
end

local function build_command(lines)
  local parts = {}
  for _, line in ipairs(quote_json_bodies(lines)) do
    local s = vim.trim(line)
    if s ~= "" and not s:match "^#" then parts[#parts + 1] = s:gsub("\\%s*$", "") end
  end

  local body = vim.trim(table.concat(parts, " "))
  if body == "" then return nil, "empty query" end

  return vim.g.curl_config.curl_bin
    .. " "
    .. table.concat(vim.g.curl_config.flags, " ")
    .. " -sSL "
    .. body:gsub("^curl%s+", "", 1)
end

local function get_output_buf()
  if not (output_buf and vim.api.nvim_buf_is_valid(output_buf)) then
    output_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(output_buf, "Curl output")
    vim.bo[output_buf].buftype = "nofile"
    vim.bo[output_buf].filetype = "json"
    vim.bo[output_buf].bufhidden = "hide"
    vim.bo[output_buf].swapfile = false
    vim.bo[output_buf].modifiable = false
  end
  return output_buf
end

local function open_output_window(qbuf)
  local buf = get_output_buf()
  if vim.fn.win_findbuf(buf)[1] then return end

  local query_win = vim.fn.win_findbuf(qbuf)[1] or vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(query_win)
  vim.cmd.vsplit()
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_set_current_win(query_win)
end

local function write_formatted_output(qbuf, output)
  local function show()
    vim.schedule(function()
      open_output_window(qbuf)
      local buf = get_output_buf()
      local lines = vim.split(output, "\n", { plain = true })
      while lines[#lines] == "" do
        lines[#lines] = nil
      end
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
    end)
  end

  local lines = vim.split(output:gsub("\r\n?", "\n"), "\n", { plain = true })
  local json_index
  for i, line in ipairs(lines) do
    if vim.trim(line):match "^[%[%{]" then
      json_index = i
      break
    end
  end
  if not json_index then return show() end

  local headers = vim
    .iter(vim.list_slice(lines, 1, json_index - 1))
    :filter(function(line) return vim.trim(line) ~= "" end)
    :totable()
  local json_body = table.concat(vim.list_slice(lines, json_index), "\n")

  vim.system({ "jq", "." }, { text = true, stdin = json_body }, function(result)
    if result.code == 0 and result.stdout and result.stdout ~= "" then
      output = #headers > 0 and (table.concat(headers, "\n") .. "\n\n" .. result.stdout) or result.stdout
    end
    show()
  end)
end

local function curl_execute()
  local qbuf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(qbuf, 0, -1, false)
  local sline, eline = find_query_block(lines, vim.api.nvim_win_get_cursor(0)[1])
  if not sline then
    vim.notify("[curl] cursor is not on a query line", vim.log.levels.ERROR)
    return
  end

  local command, err = build_command(vim.list_slice(lines, sline, eline))
  if not command then
    vim.notify("[curl] " .. (err or "invalid query"), vim.log.levels.ERROR)
    return
  end

  if running_request then running_request:kill(15) end

  local req
  req = vim.system({ vim.o.shell, "-c", command }, { text = true }, function(result)
    if req ~= running_request then return end
    running_request = nil
    local output = vim.iter({ result.stdout, result.stderr }):filter(function(s) return s and s ~= "" end):join "\n\n"
    if output == "" then output = "curl exited with code " .. result.code end
    write_formatted_output(qbuf, output)
  end)
  running_request = req
end

vim.filetype.add { extension = { curl = "curl" } }
vim.treesitter.language.register("bash", "curl")
vim.api.nvim_create_autocmd("FileType", {
  pattern = "curl",
  callback = function(ev)
    vim.bo[ev.buf].syntax = "sh"
    vim.bo[ev.buf].commentstring = "# %s"
    vim.keymap.set("n", vim.g.curl_config.execute_map, curl_execute, {
      buffer = ev.buf,
      noremap = true,
      silent = true,
      desc = "Execute curl query under cursor",
    })
  end,
})
