local Buffer = require("neogit.lib.buffer")
local git = require("neogit.lib.git")
local Ui = require("neogit.lib.ui")

local api = vim.api
local fn = vim.fn

---@class BlameSplitBuffer
---@field buffer Buffer
---@field file_path string
---@field blame_entries BlameEntry[]
---@field file_buffer number|nil
---@field commit_colors table<string, string>
---@field next_color_index number
---@field original_wrap boolean|nil
---@field saved_width number
---@field initial_cursor_line number
---@field original_buffer_content string[]|nil
---@field original_buffer_name string|nil
-- Removed: ---@field current_commit string|nil
---@field history_stack table[] Stack of {commit: string, type: "reblame"|"parent", line: number}
---@field history_index number Current position in history stack (1-based)
local M = {
  instance = nil,
}

local COMMIT_COLORS = {
  "NeogitBlameCommit1",
  "NeogitBlameCommit2",
  "NeogitBlameCommit3",
  "NeogitBlameCommit4",
  "NeogitBlameCommit5",
  "NeogitBlameCommit6",
  "NeogitBlameCommit7",
  "NeogitBlameCommit8",
}

--
-- Private Helper Functions (were previously methods on M)
--

---@param self BlameSplitBuffer
---@param commit string
---@return string
local function _get_commit_color(self, commit)
  if not self.commit_colors[commit] then
    local color_index = ((self.next_color_index - 1) % #COMMIT_COLORS) + 1
    self.commit_colors[commit] = COMMIT_COLORS[color_index]
    self.next_color_index = self.next_color_index + 1
  end
  return self.commit_colors[commit]
end

---@param self BlameSplitBuffer
---@return number
local function _get_current_width(self)
  if self.buffer and self.buffer.win_handle and api.nvim_win_is_valid(self.buffer.win_handle) then
    return api.nvim_win_get_width(self.buffer.win_handle)
  end
  return self.saved_width
end

---@param entries BlameEntry[]
---@return table[] hunks
local function _get_hunks(entries)
  local hunks = {}
  if #entries == 0 then
    return hunks
  end

  local current_hunk = {
    commit = entries[1].commit,
    author = entries[1].author,
    author_time = entries[1].author_time,
    summary = entries[1].summary,
    line_count = 0,
  }

  for _, entry in ipairs(entries) do
    if
      entry.commit ~= current_hunk.commit
      or entry.author ~= current_hunk.author
      or entry.summary ~= current_hunk.summary
    then
      table.insert(hunks, current_hunk)
      current_hunk = {
        commit = entry.commit,
        author = entry.author,
        author_time = entry.author_time,
        summary = entry.summary,
        line_count = 1,
      }
    else
      current_hunk.line_count = current_hunk.line_count + 1
    end
  end
  table.insert(hunks, current_hunk)

  return hunks
end

---Renders a line with left-aligned content and right-aligned date.
---@param hunk table
---@param commit_color string
---@param window_width number
---@return table UI component
local function _render_info_line(hunk, commit_color, window_width)
  local text, row = Ui.text, Ui.row
  local commit_short = git.blame.abbreviate_commit(hunk.commit)
  local date = git.blame.format_date(hunk.author_time)
  local author = hunk.author
  local date_width = fn.strdisplaywidth(date)

  local prefix_comps, prefix_len
  if hunk.line_count == 1 then
    -- Single line: - commit author summary
    local summary = hunk.summary
    local prefix_str = string.format("- %s %s ", commit_short, author)
    local prefix_width = fn.strdisplaywidth(prefix_str)
    local summary_width = fn.strdisplaywidth(summary)
    local available_width = window_width - prefix_width - date_width - 1

    if summary_width > available_width then
      summary = vim.fn.strcharpart(summary, 0, math.max(0, available_width - 3)) .. "..."
      summary_width = fn.strdisplaywidth(summary)
    end
    prefix_comps = {
      text("- ", { highlight = commit_color }),
      text(commit_short, { highlight = commit_color }),
      text(" " .. author .. " "),
      text(summary, { highlight = "NeogitBlameMessage" }),
    }
    prefix_len = prefix_width + summary_width
  else
    -- First line of multi-line: ┍ commit author
    local prefix_str = string.format("┍ %s %s", commit_short, author)
    local prefix_width = fn.strdisplaywidth(prefix_str)
    local available_width = window_width - date_width - 2

    if prefix_width > available_width then
      local overflow = prefix_width - available_width
      author = vim.fn.strcharpart(author, 0, fn.strchars(author) - overflow)
      prefix_str = string.format("┍ %s %s", commit_short, author)
      prefix_width = fn.strdisplaywidth(prefix_str)
    end
    prefix_comps = {
      text("┍ ", { highlight = commit_color }),
      text(commit_short, { highlight = commit_color }),
      text(" " .. author),
    }
    prefix_len = prefix_width
  end

  local padding = math.max(1, window_width - prefix_len - date_width)
  return row(vim.list_extend(prefix_comps, {
    text(string.rep(" ", padding)),
    text(date, { highlight = "NeogitBlameDate" }),
  }))
end

---Renders a line showing the commit summary.
---@param hunk table
---@param commit_color string
---@param window_width number
---@param is_last_line boolean
---@return table UI component
local function _render_summary_line(hunk, commit_color, window_width, is_last_line)
  local text, row = Ui.text, Ui.row
  local summary = hunk.summary
  local symbol = is_last_line and "┕ " or "│ "
  local symbol_width = fn.strdisplaywidth(symbol)
  local available_width = window_width - symbol_width
  local summary_width = fn.strdisplaywidth(summary)

  if summary_width > available_width then
    summary = vim.fn.strcharpart(summary, 0, math.max(0, available_width - 3)) .. "..."
    summary_width = fn.strdisplaywidth(summary)
  end

  local padding = window_width - symbol_width - summary_width
  return row {
    text(symbol, { highlight = commit_color }),
    text(summary, { highlight = "NeogitBlameMessage" }),
    text(string.rep(" ", padding)),
  }
end

---Renders a simple vertical line for middle/end of hunks.
---@param symbol string
---@param commit_color string
---@param window_width number
---@return table UI component
local function _render_filler_line(symbol, commit_color, window_width)
  local text, row = Ui.text, Ui.row
  local symbol_width = fn.strdisplaywidth(symbol)
  return row {
    text(symbol, { highlight = commit_color }),
    text(string.rep(" ", window_width - symbol_width)),
  }
end

--
-- History Management
--

--- Add a new entry to the history stack
---@param self BlameSplitBuffer
---@param commit string
---@param operation_type string "reblame" or "parent"
---@param line number
function M:push_history(commit, operation_type, line)
  -- Check if we're trying to add the same commit as the current one
  if self.history_index > 0 and self.history_index <= #self.history_stack then
    local current_entry = self.history_stack[self.history_index]
    if current_entry.commit == commit then
      -- Don't add duplicate commit to history, just update the line position
      current_entry.line = line
      return
    end
  end

  -- Remove any entries after current position (when going back and then taking a new path)
  for i = self.history_index + 1, #self.history_stack do
    self.history_stack[i] = nil
  end

  -- Add new entry
  table.insert(self.history_stack, {
    commit = commit,
    type = operation_type,
    line = line,
  })
  self.history_index = #self.history_stack
end

--- Check if we can go back in history
---@param self BlameSplitBuffer
---@return boolean
function M:can_go_back()
  return self.history_index > 1
end

--- Check if we can go forward in history
---@param self BlameSplitBuffer
---@return boolean
function M:can_go_forward()
  return self.history_index < #self.history_stack
end

--- Go back in history
---@param self BlameSplitBuffer
---@return boolean success
function M:go_back()
  if not self:can_go_back() then
    vim.notify("Already at the beginning of blame history", vim.log.levels.INFO, { title = "Blame" })
    return false
  end

  self.history_index = self.history_index - 1
  local entry = self.history_stack[self.history_index]
  self:reblame_without_history(entry.commit, entry.line)
  return true
end

--- Go forward in history
---@param self BlameSplitBuffer
---@return boolean success
function M:go_forward()
  if not self:can_go_forward() then
    vim.notify("Already at the end of blame history", vim.log.levels.INFO, { title = "Blame" })
    return false
  end

  self.history_index = self.history_index + 1
  local entry = self.history_stack[self.history_index]
  self:reblame_without_history(entry.commit, entry.line)
  return true
end

--- Navigate to parent commit of the current line
---@param self BlameSplitBuffer
---@param line_nr number
---@param add_to_history boolean
function M:goto_parent(line_nr, add_to_history)
  local entry = self:get_blame_entry_for_line(line_nr)
  if not entry then
    return
  end

  local parent_commit = entry.commit .. "^"

  if add_to_history then
    -- Update the current history entry's line position before adding new entry
    if self.history_index > 0 and self.history_index <= #self.history_stack then
      self.history_stack[self.history_index].line = line_nr
    end

    self:push_history(parent_commit, "parent", line_nr)
  end

  self:reblame_without_history(parent_commit, line_nr)
end

--
-- Public API
--

function M.new(file_path)
  file_path = file_path or fn.expand("%:p")
  local git_root = git.repo.worktree_root
  if file_path:find(git_root, 1, true) == 1 then
    file_path = file_path:sub(#git_root + 2)
  end

  local blame_entries, err = git.blame.blame_file(file_path)

  if not blame_entries then
    local error_message = "Neogit: Git blame failed for " .. file_path
    if err and err ~= "" then
      error_message = error_message .. ".\n\nDetails:\n" .. err
    end
    vim.notify(error_message, vim.log.levels.ERROR, { title = "Blame Error" })
    return nil
  end

  if #blame_entries == 0 then
    vim.notify(
      "Neogit: No blame information found for " .. file_path .. ". The file might be new or untracked.",
      vim.log.levels.INFO,
      { title = "Blame" }
    )
    return nil
  end

  local instance = {
    file_path = file_path,
    blame_entries = blame_entries,
    commit_colors = {},
    next_color_index = 1,
    saved_width = 60,
    history_stack = {}, -- Will be initialized in open() with correct cursor position
    history_index = 0,
  }
  setmetatable(instance, { __index = M })
  return instance
end

function M:render_blame_lines()
  local components = {}
  local window_width = _get_current_width(self)
  local hunks = _get_hunks(self.blame_entries)

  for _, hunk in ipairs(hunks) do
    local commit_color = _get_commit_color(self, hunk.commit)

    if hunk.line_count == 1 then
      table.insert(components, _render_info_line(hunk, commit_color, window_width))
    else
      for i = 1, hunk.line_count do
        if i == 1 then
          table.insert(components, _render_info_line(hunk, commit_color, window_width))
        elseif i == 2 then
          table.insert(
            components,
            _render_summary_line(hunk, commit_color, window_width, i == hunk.line_count)
          )
        else
          local symbol = (i == hunk.line_count) and "┕" or "│"
          table.insert(components, _render_filler_line(symbol, commit_color, window_width))
        end
      end
    end
  end

  return components
end

function M:get_blame_entry_for_line(line_nr)
  if line_nr > 0 and line_nr <= #self.blame_entries then
    return self.blame_entries[line_nr]
  end
  return nil
end

--- Store the original buffer content and name
---@param self BlameSplitBuffer
function M:store_original_buffer_state()
  if not self.file_buffer or not api.nvim_buf_is_valid(self.file_buffer) then
    return
  end

  -- Only store if we haven't already stored the original state
  if not self.original_buffer_content then
    self.original_buffer_content = api.nvim_buf_get_lines(self.file_buffer, 0, -1, false)
    self.original_buffer_name = api.nvim_buf_get_name(self.file_buffer)
  end
end

--- Update the file buffer with content from a specific commit
---@param self BlameSplitBuffer
---@param commit string The commit to show content from
function M:update_file_buffer_content(commit)
  if not self.file_buffer or not api.nvim_buf_is_valid(self.file_buffer) then
    return
  end

  -- Store original state if not already stored
  self:store_original_buffer_state()

  -- Get file content at the specified commit
  local ok, result = pcall(function()
    return git.cli.show.file(self.file_path, commit).call { hidden = true, trim = false }
  end)

  if not ok or result.code ~= 0 then
    vim.notify(
      "Failed to get file content at commit " .. git.blame.abbreviate_commit(commit),
      vim.log.levels.WARN,
      { title = "Blame" }
    )
    return
  end

  -- Update buffer content
  local content = result.stdout
  api.nvim_buf_set_option(self.file_buffer, "modifiable", true)
  api.nvim_buf_set_lines(self.file_buffer, 0, -1, false, content)
  api.nvim_buf_set_option(self.file_buffer, "modifiable", false)
  api.nvim_buf_set_option(self.file_buffer, "modified", false)

  -- Update buffer name to indicate the commit being viewed
  local git_root = git.repo.worktree_root
  local git_dir = git.repo.git_dir
  local new_name = string.format("neogit://%s//%s:%s", git_dir, commit, self.file_path)
  api.nvim_buf_set_name(self.file_buffer, new_name)

  -- Removed: self.current_commit = commit
end

--- Restore the original buffer content and name
---@param self BlameSplitBuffer
function M:restore_original_buffer_content()
  if not self.file_buffer or not api.nvim_buf_is_valid(self.file_buffer) then
    return
  end

  if not self.original_buffer_content or not self.original_buffer_name then
    return
  end

  -- Restore original content
  api.nvim_buf_set_option(self.file_buffer, "modifiable", true)
  api.nvim_buf_set_lines(self.file_buffer, 0, -1, false, self.original_buffer_content)
  -- Removed redundant: api.nvim_buf_set_option(self.file_buffer, "modifiable", true)
  api.nvim_buf_set_option(self.file_buffer, "modified", false)
  -- Note: Leaving modifiable as true, which is likely the desired state for the original user buffer.
  -- If it needed to be restored to its exact original modifiable state, that would need to be stored too.

  -- Restore original name
  api.nvim_buf_set_name(self.file_buffer, self.original_buffer_name)

  -- Clear stored state
  self.original_buffer_content = nil
  self.original_buffer_name = nil
  -- Removed: self.current_commit = nil
end

--- Re-runs the blame for the given file at a specific commit without adding to history.
---@param self BlameSplitBuffer
---@param commit string The commit SHA or revision string (e.g., "HEAD^") to blame at.
---@param original_line number The line number to try to restore the cursor to.
function M:reblame_without_history(commit, original_line)
  if not commit then
    return
  end

  local new_blame_entries, err = git.blame.blame_file(self.file_path, commit)

  if not new_blame_entries or #new_blame_entries == 0 then
    local short_commit_str = git.blame.abbreviate_commit(commit)
    local error_message = "Neogit: Re-blame failed for " .. self.file_path .. " at " .. short_commit_str
    if err and err ~= "" then
      error_message = error_message .. ".\n\nDetails:\n" .. err
    else
      error_message = error_message
        .. ". The commit might not exist or the file may not exist at that commit."
    end
    vim.notify(error_message, vim.log.levels.ERROR, { title = "Blame Error" })
    return
  end

  -- Update the file buffer with content from the commit
  self:update_file_buffer_content(commit)

  -- Update state
  self.blame_entries = new_blame_entries
  self.commit_colors = {}
  self.next_color_index = 1

  -- Rerender
  self.buffer.ui:render(unpack(self:render_blame_lines()))

  -- Clear any previous status messages on successful operation
  vim.cmd("echon ''")

  -- Restore cursor position
  vim.defer_fn(function()
    if self.buffer and api.nvim_buf_is_valid(self.buffer.handle) then
      local line_count = api.nvim_buf_line_count(self.buffer.handle)
      local target_line = math.min(original_line, line_count)
      pcall(api.nvim_win_set_cursor, 0, { math.max(1, target_line), 0 })
      -- Center the view on the new cursor position
      api.nvim_win_call(0, function()
        vim.cmd("normal! zz")
      end)
    end
  end, 10)
end

--- Re-runs the blame for the given file at a specific commit and adds to history.
---@param self BlameSplitBuffer
---@param commit string The commit SHA or revision string (e.g., "HEAD^") to blame at.
---@param original_line number The line number to try to restore the cursor to.
function M:reblame(commit, original_line)
  if not commit then
    return
  end

  -- Update the current history entry's line position before adding new entry
  if self.history_index > 0 and self.history_index <= #self.history_stack then
    self.history_stack[self.history_index].line = original_line
  end

  -- Add to history
  self:push_history(commit, "reblame", original_line)

  -- Perform the actual reblame
  self:reblame_without_history(commit, original_line)
end

function M:setup_scroll_sync()
  if not self.file_buffer or not api.nvim_buf_is_valid(self.file_buffer) then
    return
  end

  local blame_buf = self.buffer.handle
  local file_buf = self.file_buffer
  local syncing = false

  local function sync_cursor(target_buf)
    if syncing then
      return
    end
    syncing = true
    local source_line = api.nvim_win_get_cursor(0)[1]
    local target_win_id = fn.bufwinid(target_buf)
    if target_win_id > 0 and api.nvim_win_is_valid(target_win_id) then
      api.nvim_win_call(target_win_id, function()
        pcall(api.nvim_win_set_cursor, 0, { source_line, 0 })
      end)
    end
    syncing = false
  end

  api.nvim_create_autocmd("CursorMoved", {
    buffer = blame_buf,
    callback = function()
      sync_cursor(file_buf)
    end,
    group = self.buffer.autocmd_group,
  })

  api.nvim_create_autocmd("CursorMoved", {
    buffer = file_buf,
    callback = function()
      sync_cursor(blame_buf)
    end,
    group = self.buffer.autocmd_group,
  })

  api.nvim_create_autocmd("WinScrolled", {
    callback = function(args)
      if syncing then
        return
      end

      local scrolled_win = tonumber(args.match) -- args.match is the window-ID for WinScrolled
      if not (scrolled_win and api.nvim_win_is_valid(scrolled_win)) then
        return
      end

      syncing = true

      local scrolled_buf = api.nvim_win_get_buf(scrolled_win)
      local target_buf = (scrolled_buf == blame_buf) and file_buf or (scrolled_buf == file_buf) and blame_buf

      if target_buf then
        local target_win_id = fn.bufwinid(target_buf)
        if target_win_id > 0 and api.nvim_win_is_valid(target_win_id) then
          local view = api.nvim_win_call(scrolled_win, fn.winsaveview)
          api.nvim_win_call(target_win_id, function()
            fn.winrestview(view)
          end)
        end
      end

      syncing = false
    end,
    group = self.buffer.autocmd_group,
  })
end

function M:setup_resize_handling()
  api.nvim_create_autocmd("WinResized", {
    pattern = "*",
    callback = function()
      if self.buffer and self.buffer:is_visible() and fn.bufwinid(self.buffer.handle) > 0 then
        local current_width = _get_current_width(self)
        if current_width ~= self.saved_width then
          self.saved_width = current_width
          self.buffer.ui:render(unpack(self:render_blame_lines()))
        end
      end
    end,
    group = self.buffer.autocmd_group,
  })
end

function M:close()
  -- Restore original buffer content before closing
  self:restore_original_buffer_content()

  if self.buffer then
    self.buffer:close()
  end
  if self.original_wrap ~= nil then
    pcall(vim.api.nvim_set_option_value, "wrap", self.original_wrap, { scope = "local" })
  end
  M.instance = nil
end

function M.is_open()
  return M.instance and M.instance.buffer and M.instance.buffer:is_visible()
end

function M:open()
  M.instance = self

  self.file_buffer = api.nvim_get_current_buf()
  self.initial_cursor_line = api.nvim_win_get_cursor(0)[1]

  self.original_wrap = vim.wo.wrap
  vim.wo.wrap = false

  self.buffer = Buffer.create {
    name = "NeogitBlameSplit",
    filetype = "NeogitBlameSplit",
    kind = "vsplit_left",
    disable_line_numbers = true,
    disable_relative_line_numbers = true,
    disable_signs = true,
    modifiable = false,
    readonly = true,
    mappings = {
      n = {
        q = function()
          self:close()
        end,
        ["<esc>"] = function()
          self:close()
        end,
        s = function()
          local line_nr = api.nvim_win_get_cursor(0)[1]
          local entry = self:get_blame_entry_for_line(line_nr)
          if not entry then
            return
          end

          local blame_win = api.nvim_get_current_win()
          self.saved_width = api.nvim_win_get_width(blame_win)
          api.nvim_win_set_option(blame_win, "winfixwidth", true)

          local CommitViewBuffer = require("neogit.buffers.commit_view")
          local commit_view = CommitViewBuffer.new(entry.commit)

          local original_close = commit_view.close
          commit_view.close = function(cv)
            if original_close then
              original_close(cv)
            end

            if api.nvim_win_is_valid(blame_win) then
              api.nvim_set_current_win(blame_win)

              vim.defer_fn(function()
                if api.nvim_win_is_valid(blame_win) then
                  pcall(api.nvim_win_set_width, blame_win, self.saved_width)
                  api.nvim_win_set_option(blame_win, "winfixwidth", false)
                end
              end, 10)
            end
          end

          commit_view:open()
        end,
        -- Reblame operations (with history)
        r = function()
          local line_nr = api.nvim_win_get_cursor(0)[1]
          local entry = self:get_blame_entry_for_line(line_nr)
          if not entry then
            return
          end
          self:reblame(entry.commit, line_nr)
        end,
        -- Go back in history (alternative key)
        R = function()
          self:go_back()
        end,
        -- Parent operations (with history)
        p = function()
          local line_nr = api.nvim_win_get_cursor(0)[1]
          self:goto_parent(line_nr, true)
        end,
        -- Go back in history (alternative key)
        P = function()
          self:go_back()
        end,
        -- History navigation
        ["<C-o>"] = function()
          self:go_back()
        end,
        ["<C-i>"] = function()
          self:go_forward()
        end,
        -- Alternative history navigation
        ["["] = function()
          self:go_back()
        end,
        ["]"] = function()
          self:go_forward()
        end,
      },
    },
    render = function()
      return self:render_blame_lines()
    end,
    after = function(buffer)
      self.buffer = buffer
      api.nvim_win_set_width(buffer.win_handle, self.saved_width)
      api.nvim_win_set_option(buffer.win_handle, "wrap", false)

      self:setup_scroll_sync()
      self:setup_resize_handling()

      -- Initialize history stack with correct cursor position
      if #self.history_stack == 0 then
        self.history_stack = { { commit = "HEAD", type = "initial", line = self.initial_cursor_line } }
        self.history_index = 1
      end

      -- Restore cursor position
      vim.defer_fn(function()
        if api.nvim_win_is_valid(buffer.win_handle) then
          local line_count = api.nvim_buf_line_count(buffer.handle)
          local target_line = math.min(self.initial_cursor_line, line_count)
          pcall(api.nvim_win_set_cursor, buffer.win_handle, { math.max(1, target_line), 0 })
          api.nvim_win_call(buffer.win_handle, function()
            vim.cmd("normal! zz")
          end)
        end
      end, 10)
    end,
  }
end

return M
