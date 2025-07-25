local M = {}

local Rev = require("diffview.vcs.adapters.git.rev").GitRev
local RevType = require("diffview.vcs.rev").RevType
local CDiffView = require("diffview.api.views.diff.diff_view").CDiffView
local dv_lib = require("diffview.lib")
local dv_utils = require("diffview.utils")
local a = require("plenary.async")

local Watcher = require("neogit.watcher")
local git = require("neogit.lib.git")
local notification = require("neogit.lib.notification")

local function check_valid_item(item_name, section_type)
  if
    not item_name
    or (type(item_name) == "string" and item_name == "")
    or (type(item_name) == "table" and (#item_name == 0 or not item_name[1] or item_name[1] == ""))
  then
    notification.warn(
      "Cannot diff the " .. section_type .. " heading. Please select a specific " .. section_type .. " item."
    )
    return false
  end
  return true
end

vim.api.nvim_create_autocmd({ "FileType" }, {
  pattern = { "DiffviewFiles", "DiffviewFileHistory" },
  callback = function(event)
    vim.keymap.set("n", "q", function()
      vim.cmd("DiffviewClose")
    end, { buffer = event.buf, desc = "Close diffview" })
  end,
})

local function get_local_diff_view(section_name, item_name, opts)
  local left = Rev(RevType.STAGE)
  local right = Rev(RevType.LOCAL)

  if section_name == "unstaged" then
    section_name = "working"
  end

  local function update_files()
    local files = {}

    git.repo:dispatch_refresh {
      source = "diffview_update",
      callback = function() end,
    }

    local repo_state = git.repo.state

    local sections = {
      conflicting = {
        items = vim.tbl_filter(function(item)
          return item.mode and item.mode:sub(2, 2) == "U"
        end, repo_state.untracked and repo_state.untracked.items or {}),
      },
      working = repo_state.unstaged or { items = {} },
      staged = repo_state.staged or { items = {} },
    }

    for kind, section in pairs(sections) do
      files[kind] = {}

      for _, item in ipairs(section.items or {}) do
        local file = {
          path = item.name,
          status = item.mode and item.mode:sub(1, 1),
          stats = (item.diff and item.diff.stats) and {
            additions = item.diff.stats.additions or 0,
            deletions = item.diff.stats.deletions or 0,
          } or nil,
          left_null = vim.tbl_contains({ "A", "?" }, item.mode),
          right_null = false,
        }

        -- restrict diff to only a particular section
        if opts.only then
          if (item_name and item.name == item_name) or (not item_name and section_name == kind) then
            table.insert(files[kind], file)
          end
        else
          table.insert(files[kind], file)
        end
      end
    end

    return files
  end

  -- Get the initial file list
  local files = update_files()

  -- Apply the "selected" logic only to the initial list
  local file_was_selected = false
  if item_name then
    for _, section in pairs(files) do
      for _, file in ipairs(section) do
        if file.path == item_name then
          file.selected = true
          file_was_selected = true
          break
        end
      end
      if file_was_selected then
        break
      end
    end
  end

  -- If no specific file was requested or found, select the first file as a fallback.
  if not file_was_selected then
    for _, section_key in ipairs({ "conflicting", "working", "staged" }) do
      if files[section_key] and #files[section_key] > 0 then
        files[section_key][1].selected = true
        break
      end
    end
  end

  -- Pass the initial list (with `selected` flags) and the update callback (without them)
  local view = CDiffView {
    git_root = git.repo.worktree_root,
    left = left,
    right = right,
    files = files,
    update_files = update_files,
    get_file_data = function(kind, path, side)
      local args = { path }
      if kind == "staged" then
        if side == "left" then
          table.insert(args, "HEAD")
        end

        return git.cli.show.file(unpack(args)).call({ await = true, trim = false }).stdout
      elseif kind == "working" then
        local fdata = git.cli.show.file(path).call({ await = true, trim = false }).stdout
        return side == "left" and fdata
      end
    end,
  }

  view:on_files_staged(a.void(function(_)
    Watcher.instance():dispatch_refresh()
  end))
  dv_lib.add_view(view)

  return view
end

---@param section_name string
---@param item_name    string|string[]|nil
---@param opts         table|nil
function M.open(section_name, item_name, opts)
  opts = opts or {}

  -- Hack way to do an on-close callback
  if opts.on_close then
    vim.api.nvim_create_autocmd({ "BufEnter" }, {
      buffer = opts.on_close.handle,
      once = true,
      callback = opts.on_close.fn,
    })
  end

  local view
  -- selene: allow(if_same_then_else)
  if
    section_name == "recent"
    or section_name == "log"
    or (section_name and section_name:match("unmerged$"))
  then
    if not check_valid_item(item_name, "commit") then
      return
    end

    local range
    if type(item_name) == "table" then
      range = string.format("%s..%s", item_name[1], item_name[#item_name])
    else
      local commit_hash = item_name:match("[a-f0-9]+")
      if not commit_hash then
        notification.warn("Invalid commit hash format")
        return
      end
      range = string.format("%s^!", commit_hash)
    end

    view = dv_lib.diffview_open(dv_utils.tbl_pack(range))
  elseif section_name == "range" then
    local range = item_name
    view = dv_lib.diffview_open(dv_utils.tbl_pack(range))
  elseif section_name == "stashes" then
    if not check_valid_item(item_name, "stash") then
      return
    end

    local stash_id = item_name:match("stash@{%d+}") or item_name
    view = dv_lib.diffview_open(dv_utils.tbl_pack(stash_id .. "^!"))
  elseif section_name == "commit" then
    if not check_valid_item(item_name, "commit") then
      return
    end
    view = dv_lib.diffview_open(dv_utils.tbl_pack(item_name .. "^!"))
    if not check_valid_item(item_name, "commit") then
      return
    end
    local args = dv_utils.tbl_pack(item_name .. "^!")
    if opts.paths then
      for _, path in ipairs(opts.paths) do
        table.insert(args, "--selected-file=" .. path)
      end
    end
    view = dv_lib.diffview_open(args)
  elseif section_name == "conflict" and item_name then
    view = dv_lib.diffview_open(dv_utils.tbl_pack("--selected-file=" .. item_name))
  elseif (section_name == "conflict" or section_name == "worktree") and not item_name then
    view = dv_lib.diffview_open()
  elseif section_name ~= nil then
    view = get_local_diff_view(section_name, item_name, opts)
  elseif section_name == nil and item_name ~= nil then
    view = dv_lib.diffview_open(dv_utils.tbl_pack(item_name .. "^!"))
  else
    view = dv_lib.diffview_open()
  end

  if view then
    view:open()
  end
end

return M
