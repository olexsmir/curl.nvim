local function check_binary(bin, msg, optional)
  if vim.fn.executable(bin) == 1 then
    vim.health.ok(bin .. " found on PATH: `" .. vim.fn.exepath(bin) .. "`")
    return
  end

  if optional then
    vim.health.warn(bin .. " not found on PATH, " .. msg)
  else
    vim.health.error(bin .. " not found on PATH, " .. msg)
  end
end

return {
  check = function()
    vim.health.start "Neovim version"
    if vim.fn.has "nvim-0.12" == 1 then
      vim.health.ok "Neovim version is compatible"
    else
      vim.health.error "nvim-0.12 or newer is required"
    end

    vim.health.start "Required dependencies"
    check_binary("curl", "required to run requests", false)

    vim.health.start "Optional dependencies"
    check_binary("jq", "used for JSON formatting in output buffers", true)
  end,
}
