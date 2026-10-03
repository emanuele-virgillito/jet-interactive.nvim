local config = require("jet-interactive.config")

local M = {}

local function platform()
  local uname = vim.uv.os_uname()
  local os = uname.sysname == "Linux" and "linux" or (uname.sysname == "Darwin" and "macos" or nil)
  local machine = uname.machine
  local arch = (machine == "x86_64" or machine == "amd64") and "x86_64"
    or ((machine == "aarch64" or machine == "arm64") and "aarch64" or nil)
  return os, arch
end

function M.path()
  return vim.fn.stdpath("data") .. "/jet-interactive/bin/jet-interactive"
end

---Download and verify a released bridge binary.
---@param callback fun(path?: string, error?: string)
function M.ensure(callback)
  if vim.fn.executable(M.path()) == 1 then
    callback(M.path())
    return
  end
  local os, arch = platform()
  if not (os and arch) then
    callback(nil, "piattaforma non supportata; compila il bridge con Cargo")
    return
  end
  if vim.fn.executable("curl") ~= 1 or vim.fn.executable("sha256sum") ~= 1 then
    callback(nil, "curl e sha256sum sono necessari per l'installazione automatica")
    return
  end

  local directory = vim.fs.dirname(M.path())
  vim.fn.mkdir(directory, "p", "0700")
  local asset = ("jet-interactive-%s-%s"):format(os, arch)
  local release = config.options.web.release
  local base = release == "latest"
      and ("https://github.com/%s/releases/latest/download"):format(config.options.web.repository)
    or ("https://github.com/%s/releases/download/%s"):format(config.options.web.repository, release)
  local temporary = M.path() .. ".download"
  local checksum = temporary .. ".sha256"

  vim.system({ "curl", "-fL", base .. "/" .. asset, "-o", temporary }, { text = true }, function(download)
    if download.code ~= 0 then
      callback(nil, vim.trim(download.stderr))
      return
    end
    vim.system({ "curl", "-fL", base .. "/" .. asset .. ".sha256", "-o", checksum }, { text = true }, function(sum)
      if sum.code ~= 0 then
        vim.uv.fs_unlink(temporary)
        callback(nil, vim.trim(sum.stderr))
        return
      end
      vim.system({ "sha256sum", temporary }, { text = true }, function(verified)
        local expected_file = io.open(checksum, "r")
        local expected = expected_file and expected_file:read("*l"):match("^(%x+)") or nil
        if expected_file then
          expected_file:close()
        end
        local actual = verified.stdout and verified.stdout:match("^(%x+)") or nil
        vim.uv.fs_unlink(checksum)
        if verified.code ~= 0 or not expected or actual ~= expected then
          vim.uv.fs_unlink(temporary)
          callback(nil, "checksum del bridge non valido")
          return
        end
        vim.uv.fs_chmod(temporary, 493) -- 0755
        vim.uv.fs_rename(temporary, M.path())
        callback(M.path())
      end)
    end)
  end)
end

return M
