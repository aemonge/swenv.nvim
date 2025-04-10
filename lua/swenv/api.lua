local M = {}

local Path = require('plenary.path')
local scan_dir = require('plenary.scandir').scan_dir
local best_match = require('swenv.match').best_match
local read_venv_name_in_project = require('swenv.project').read_venv_name_in_project
local read_venv_name_common_dir = require('swenv.project').read_venv_name_common_dir
local get_local_venv_path = require('swenv.project').get_local_venv_path

local settings = require('swenv.config').settings
local create = require('swenv.create')

local ORIGINAL_PATH = vim.fn.getenv('PATH')
local IS_WINDOWS = vim.uv.os_uname().sysname == 'Windows_NT'
local ORIGINAL_VIRTUAL_ENV = vim.fn.getenv('VIRTUAL_ENV')
local ORIGINAL_CONDA_PREFIX = vim.fn.getenv('CONDA_PREFIX')
local ORIGINAL_CONDA_DEFAULT_ENV = vim.fn.getenv('CONDA_DEFAULT_ENV')

local update_path = function(path)
  local sep
  local dir
  if IS_WINDOWS then
    sep = ';'
    dir = 'Scripts'
  else
    sep = ':'
    dir = 'bin'
  end
  vim.fn.setenv('PATH', Path:new(path) / dir .. sep .. ORIGINAL_PATH)
end

M.set_venv_path = function(venv)
  if venv.source == 'conda' or venv.source == 'micromamba' then
    vim.fn.setenv('CONDA_PREFIX', venv.path)
    vim.fn.setenv('CONDA_DEFAULT_ENV', venv.name)
    vim.fn.setenv('CONDA_PROMPT_MODIFIER', '(' .. venv.name .. ')')
  else
    vim.fn.setenv('VIRTUAL_ENV', venv.path)
    vim.fn.setenv('VIRTUAL_ENV_PROMPT', '(' .. venv.name .. ')')
  end

  current_venv = venv
  update_path(venv.path)

  if settings.post_set_venv then
    settings.post_set_venv(venv)
  end
end

---
---Checks who appears first in PATH. Returns `true` if `first` appears first and `false` otherwise
---
---@param first string|nil
---@param second string|nil
---@return boolean
local has_high_priority_in_path = function(first, second)
  if first == nil or first == vim.NIL then
    return false
  end

  if second == nil or second == vim.NIL then
    return true
  end

  return string.find(ORIGINAL_PATH, first) < string.find(ORIGINAL_PATH, second)
end

M.init = function()
  local venv

  local venv_env = vim.fn.getenv('VIRTUAL_ENV')
  if venv_env ~= vim.NIL then
    venv = {
      name = Path:new(venv_env):make_relative(settings.venvs_path),
      path = venv_env,
      source = 'venv',
    }
  end

  local conda_env = vim.fn.getenv('CONDA_DEFAULT_ENV')
  if conda_env ~= vim.NIL and has_high_priority_in_path(conda_env, venv_env) then
    venv = {
      name = conda_env,
      path = vim.fn.getenv('CONDA_PREFIX'),
      source = 'conda',
    }
  end

  if venv then
    current_venv = venv
  end
end

M.get_current_venv = function()
  return current_venv
end

local get_venvs_for = function(base_path, source, opts)
  local venvs = {}
  if base_path == nil then
    return venvs
  end
  local success, paths = pcall(
    scan_dir,
    tostring(base_path), -- Ensure path is a string
    vim.tbl_extend('force', { depth = 1, only_dirs = true, silent = true }, opts or {})
  )

  if not success then
    return venvs
  end

  if paths and #paths > 0 then
    for _, path in ipairs(paths) do
      table.insert(venvs, {
        name = Path:new(path):make_relative(tostring(base_path)),
        path = path,
        source = source,
      })
    end
  end
  return venvs
end

local get_pixi_base_path = function()
  local current_dir = vim.fn.getcwd()
  local pixi_root = Path:new(current_dir) / '.pixi'

  if not pixi_root:exists() then
    return nil
  else
    return pixi_root / 'envs'
  end
end

local get_conda_base_path = function()
  local conda_exe = vim.fn.getenv('CONDA_EXE')
  if conda_exe == vim.NIL then
    return nil
  else
    return Path:new(conda_exe):parent():parent() / 'envs'
  end
end

local get_conda_base_env = function()
  local venvs = {}
  local path = os.getenv('CONDA_EXE')
  if path then
    table.insert(venvs, {
      name = 'base',
      path = vim.fn.fnamemodify(path, ':p:h:h'),
      source = 'conda',
    })
  end
  return venvs
end

local get_micromamba_base_path = function()
  local micromamba_root_prefix = vim.fn.getenv('MAMBA_ROOT_PREFIX')
  if micromamba_root_prefix == vim.NIL then
    return nil
  else
    return Path:new(micromamba_root_prefix) / 'envs'
  end
end

local get_pyenv_base_path = function()
  local pyenv_root = vim.fn.getenv('PYENV_ROOT')
  if pyenv_root == vim.NIL then
    return nil
  else
    return Path:new(pyenv_root) / 'versions'
  end
end

local get_project_venv_path = function(project_dir)
  local venv_path = Path:new(project_dir) / '.venv'
  if venv_path:exists() then
    return venv_path
  end
  return nil
end

-- Function to get project virtual environment
local get_project_venv = function()
  local venvs = {}
  local current_dir = vim.fn.getcwd()
  local project_venv_path = get_project_venv_path(current_dir)

  if project_venv_path then
    -- Get the project name from the directory
    local project_name = vim.fn.fnamemodify(current_dir, ':t')
    table.insert(venvs, {
      name = project_name,
      path = tostring(project_venv_path),
      source = 'venv',
    })
  end

  return venvs
end

M.get_venvs = function(venvs_path)
  local venvs = {}
  vim.list_extend(venvs, get_venvs_for(venvs_path, 'venv'))
  vim.list_extend(venvs, get_venvs_for(get_pixi_base_path(), 'pixi'))
  vim.list_extend(venvs, get_venvs_for(get_conda_base_path(), 'conda'))
  vim.list_extend(venvs, get_conda_base_env())
  vim.list_extend(venvs, get_project_venv()) -- Add project venv
  vim.list_extend(venvs, get_venvs_for(get_micromamba_base_path(), 'micromamba'))
  vim.list_extend(venvs, get_venvs_for(get_pyenv_base_path(), 'pyenv'))
  vim.list_extend(
    venvs,
    get_venvs_for(get_pyenv_base_path(), 'pyenv', { only_dirs = false })
  )
  return venvs
end

M.pick_venv = function()
  vim.ui.select(settings.get_venvs(settings.venvs_path), {
    prompt = 'Select python venv',
    format_item = function(item)
      return string.format('%s (%s) [%s]', item.name, item.path, item.source)
    end,
  }, function(choice)
    if not choice then
      return
    end
    M.set_venv_path(choice)
  end)
end

M.reset_venv = function()
  -- Reset PATH to original value
  vim.fn.setenv('PATH', ORIGINAL_PATH)

  -- Reset virtual environment variables
  if ORIGINAL_VIRTUAL_ENV ~= vim.NIL then
    vim.fn.setenv('VIRTUAL_ENV', ORIGINAL_VIRTUAL_ENV)
  else
    vim.fn.setenv('VIRTUAL_ENV', nil)
  end

  -- Reset Conda environment variables
  if ORIGINAL_CONDA_PREFIX ~= vim.NIL then
    vim.fn.setenv('CONDA_PREFIX', ORIGINAL_CONDA_PREFIX)
  else
    vim.fn.setenv('CONDA_PREFIX', nil)
  end

  if ORIGINAL_CONDA_DEFAULT_ENV ~= vim.NIL then
    vim.fn.setenv('CONDA_DEFAULT_ENV', ORIGINAL_CONDA_DEFAULT_ENV)
  else
    vim.fn.setenv('CONDA_DEFAULT_ENV', nil)
  end

  -- Reset current_venv
  current_venv = nil

  if settings.post_reset_venv then
    settings.post_reset_venv()
  end
end

M.set_venv = function(name)
  local venvs = settings.get_venvs(settings.venvs_path)
  local closest_match = best_match(venvs, name)
  if not closest_match then
    return
  end
  M.set_venv_path(closest_match)
end

---
---@param project_nvim function project_nvim.project function
---@param venvs table list of venvs
local auto_venv_project_nvim = function(project_nvim, venvs)
  local project_dir, _ = project_nvim.get_project_root()
  if project_dir then -- project_nvim.get_project_root might not always return a project path
    local venv_name = read_venv_name_in_project(project_dir)
    if venv_name then
      local venv = { path = get_local_venv_path(project_dir), name = venv_name }
      M.set_venv_path(venv)
      return
    end
    venv_name = read_venv_name_common_dir(project_dir)
    if venv_name then
      local venv = best_match(venvs, venv_name)
      if venv then
        M.set_venv_path(venv)
        return
      end
    end
    -- Check for .venv directory in the project
    local project_venv_path = get_project_venv_path(project_dir)
    if project_venv_path then
      local venv = {
        name = 'project_venv',
        path = project_venv_path,
        source = 'venv',
      }
      M.set_venv_path(venv)
      return
    end
  end
end

M.auto_venv = function()
  -- If enabled then attempt to create and set a new venv directory
  if settings.auto_create_venv then
    create.auto_create_set_python_venv()
    return
  end

  -- activate in-project venvs via project_nvim if present.
  -- Otherwise it tries to activate a venv in venvs folder
  -- which best matches the project name.
  local project_nvim_loaded, project_nvim = pcall(require, 'project_nvim.project')
  local venvs = settings.get_venvs(settings.venvs_path)
  if project_nvim_loaded then
    auto_venv_project_nvim(project_nvim, venvs)
    return
  end
end

return M
