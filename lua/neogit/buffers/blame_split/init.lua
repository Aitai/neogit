local Buffer = require("neogit.lib.buffer")
local git = require("neogit.lib.git")
local Ui = require("neogit.lib.ui")

local api = vim.api
local fn = vim.fn

---@class BlameSplitBuffer
---@field buffer Buffer
---@field file_path string
---@field blame_entries BlameEntry[]
---@field original_file_buffer number The buffer the user was editing, potentially with unsaved changes.
---@field view_file_buffer number The buffer used to display file content, might be the original or a temp buffer.
---@field commit_colors table<string, number>
---@field next_color_index number
---@field original_wrap boolean|nil
---@field saved_width number
---@field initial_cursor_line number
---@field original_buffer_name string|nil
---@field history_stack table[] Stack of {commit: string, type: "reblame"|"parent", line: number}
---@field history_index number Current position in history stack (1-based)
---@field highlight_ns number Namespace for dynamic hunk highlighting
---@field last_highlighted_commit string|nil The commit SHA of the last highlighted hunk
---@field history_buffer_names table<string, boolean>|nil Set of buffer names created for history views
---@field was_originally_modified boolean Whether the original buffer had unsaved changes.
---@field view_win_id number|nil The window ID for the file content view.
---@field temp_history_buffer number|nil A reusable buffer for showing historical file content.
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
  "NeogitBlameCommit9",
  "NeogitBlameCommit10",
  "NeogitBlameCommit11",
  "NeogitBlameCommit12",
  "NeogitBlameCommit13",
  "NeogitBlameCommit14",
  "NeogitBlameCommit15",
  "NeogitBlameCommit16",
}

local COMMIT_COLORS_BOLD = {
  "NeogitBlameCommit1Bold",
  "NeogitBlameCommit2Bold",
  "NeogitBlameCommit3Bold",
  "NeogitBlameCommit4Bold",
  "NeogitBlameCommit5Bold",
  "NeogitBlameCommit6Bold",
  "NeogitBlameCommit7Bold",
  "NeogitBlameCommit8Bold",
  "NeogitBlameCommit9Bold",
  "NeogitBlameCommit10Bold",
  "NeogitBlameCommit11Bold",
  "NeogitBlameCommit12Bold",
  "NeogitBlameCommit13Bold",
  "NeogitBlameCommit14Bold",
  "NeogitBlameCommit15Bold",
  "NeogitBlameCommit16Bold",
}

--
-- Private Helper Functions
--

---@param self BlameSplitBuffer
---@param commit string
---@return number color_index
local function _get_commit_color_index(self, commit)
  if not self.commit_colors[commit] then
    local color_index = ((self.next_color_index - 1) % #COMMIT_COLORS) + 1
    self.commit_colors[commit] = color_index
    self.next_color_index = self.next_color_index + 1
  end
  return self.commit_colors[commit]
end

---@param self BlameSplitBuffer
---@param commit string
---@return string
local function _get_commit_color(self, commit)
  return COMMIT_COLORS[_get_commit_color_index(self, commit)]
end

---@param self BlameSplitBuffer
---@param commit string
---@return string
local function _get_commit_color_bold(self, commit)
  return COMMIT_COLORS_BOLD[_get_commit_color_index(self, commit)]
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
  local message_highlight = "NeogitBlameMessage"

  local prefix_comps, prefix_len
  if hunk.line_count == 1 then
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
      text(" "),
      text(author),
      text(" "),
      text(summary, { highlight = message_highlight }),
    }
    prefix_len = prefix_width + summary_width
  else
    -- First line of multi-line: ┍ commit author
    local prefix_str = string.format("┍ %s %s", commit_short, author)
    local prefix_width = fn.strdisplaywidth(prefix_str)
    local available_width = window_width - date_width - 2

    if prefix_width > available_width then
      local overflow = prefix_width - available_width
      author = vim.fn.strcharpart(author, 0, math.max(0, fn.strchars(author) - overflow))
      prefix_str = string.format("┍ %s %s", commit_short, author)
      prefix_width = fn.strdisplaywidth(prefix_str)
    end
    prefix_comps = {
      text("┍ ", { highlight = commit_color }),
      text(commit_short, { highlight = commit_color }),
      text(" "),
      text(author),
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

  local message_highlight = "NeogitBlameMessage"

  local padding = window_width - symbol_width - summary_width
  return row {
    text(symbol, { highlight = commit_color }),
    text(summary, { highlight = message_highlight }),
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
-- Highlighting Logic
--

---Updates the highlighting for the currently selected commit across the entire buffer.
---This is called on CursorMoved and highlights all related hunks.
---@param self BlameSplitBuffer
function M:update_hunk_highlight()
  if not (self.buffer and self.buffer.handle and api.nvim_buf_is_valid(self.buffer.handle)) then
    return
  end
  local blame_buf = self.buffer.handle
  local current_line = api.nvim_win_get_cursor(0)[1]
  local entry = self:get_blame_entry_for_line(current_line)

  if not entry then
    return
  end

  if self.last_highlighted_commit and self.last_highlighted_commit == entry.commit then
    return
  end

  -- Clear all previous "bold" highlights from our namespace
  api.nvim_buf_clear_namespace(blame_buf, self.highlight_ns, 0, -1)
  self.last_highlighted_commit = entry.commit

  local target_commit_sha = entry.commit
  local bold_commit_color = _get_commit_color_bold(self, target_commit_sha)
  local hunks = _get_hunks(self.blame_entries)
  local line_nr_in_buffer = 1

  for _, hunk in ipairs(hunks) do
    if hunk.commit == target_commit_sha then
      -- This whole hunk needs to be highlighted boldly.
      for i = 1, hunk.line_count do
        local current_line_idx = line_nr_in_buffer + i - 2 -- 0-indexed line in buffer

        if i == 1 then
          local line_content = api.nvim_buf_get_lines(
            blame_buf,
            current_line_idx,
            current_line_idx + 1,
            false
          )[1] or ""
          local commit_short = git.blame.abbreviate_commit(hunk.commit)
          local date_str = git.blame.format_date(hunk.author_time)
          local date_start_byte, _ = line_content:find(date_str, 1, true)

          if hunk.line_count == 1 then
            -- Single-line hunk: "- commit author summary"
            local prefix_commit = "- " .. commit_short
            local author_start_byte = #prefix_commit + 1 -- for the space

            -- Highlight "- commit" part
            api.nvim_buf_add_highlight(
              blame_buf,
              self.highlight_ns,
              bold_commit_color,
              current_line_idx,
              0,
              #prefix_commit
            )
            -- Highlight author part
            api.nvim_buf_add_highlight(
              blame_buf,
              self.highlight_ns,
              bold_commit_color,
              current_line_idx,
              author_start_byte,
              author_start_byte + #hunk.author
            )

            -- Highlight summary part
            if date_start_byte then
              local summary_start_byte = author_start_byte + #hunk.author + 1 -- for the space
              local summary_end_byte = date_start_byte - 2 -- account for padding
              if summary_end_byte >= summary_start_byte then
                api.nvim_buf_add_highlight(
                  blame_buf,
                  self.highlight_ns,
                  "NeogitBlameMessageBold",
                  current_line_idx,
                  summary_start_byte,
                  summary_end_byte
                )
              end
            end
          else
            -- Multi-line hunk first line: "┍ commit author"
            local prefix_commit = "┍ " .. commit_short
            local author_start_byte = #prefix_commit + 1 -- for the space

            -- Highlight "┍ commit" part
            api.nvim_buf_add_highlight(
              blame_buf,
              self.highlight_ns,
              bold_commit_color,
              current_line_idx,
              0,
              #prefix_commit
            )
            -- Highlight author part (find end by looking for date)
            if date_start_byte then
              local author_end_byte = date_start_byte - 2 -- account for padding
              if author_end_byte >= author_start_byte then
                api.nvim_buf_add_highlight(
                  blame_buf,
                  self.highlight_ns,
                  bold_commit_color,
                  current_line_idx,
                  author_start_byte,
                  author_end_byte
                )
              end
            end
          end
        else
          local is_last_line = (i == hunk.line_count)
          if i == 2 then -- Summary line
            local symbol = is_last_line and "┕ " or "│ "
            api.nvim_buf_add_highlight(
              blame_buf,
              self.highlight_ns,
              bold_commit_color,
              current_line_idx,
              0,
              #symbol
            )
            api.nvim_buf_add_highlight(
              blame_buf,
              self.highlight_ns,
              "NeogitBlameMessageBold",
              current_line_idx,
              #symbol,
              -1
            )
          else -- Filler line (i > 2)
            local symbol = is_last_line and "┕" or "│"
            api.nvim_buf_add_highlight(
              blame_buf,
              self.highlight_ns,
              bold_commit_color,
              current_line_idx,
              0,
              #symbol
            )
          end
        end
      end
    end
    line_nr_in_buffer = line_nr_in_buffer + hunk.line_count
  end
end

--
-- History Management
--
function M:push_history(commit, operation_type, line)
  -- Normalize commit: convert all-zero commits to nil (working tree)
  if commit and commit:match("^0+$") then
    commit = nil
  end

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

  local old_index = self.history_index
  self.history_index = self.history_index - 1
  local entry = self.history_stack[self.history_index]
  local success = self:reblame_without_history(entry.commit, entry.line)

  if not success then
    -- Restore the previous index if blame failed
    self.history_index = old_index
    return false
  end

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

  local old_index = self.history_index
  self.history_index = self.history_index + 1
  local entry = self.history_stack[self.history_index]
  local success = self:reblame_without_history(entry.commit, entry.line)

  if not success then
    -- Restore the previous index if blame failed
    self.history_index = old_index
    return false
  end

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

  -- Don't try to get parent of uncommitted changes
  if entry.commit:match("^0+$") then
    vim.notify(
      "Cannot navigate to parent of uncommitted changes.",
      vim.log.levels.INFO,
      { title = "Blame" }
    )
    return
  end

  local parent_commit = entry.commit .. "^"

  if add_to_history then
    -- Update the current history entry's line position before adding new entry
    if self.history_index > 0 and self.history_index <= #self.history_stack then
      self.history_stack[self.history_index].line = line_nr
    end

    -- Only add to history if the reblame succeeds
    local success = self:reblame_without_history(parent_commit, line_nr)
    if success then
      self:push_history(parent_commit, "parent", line_nr)
    end
  else
    self:reblame_without_history(parent_commit, line_nr)
  end
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

  local blame_entries, err
  local current_buf = fn.bufnr("%")

  if api.nvim_buf_is_valid(current_buf) and api.nvim_get_option_value("modified", { buf = current_buf }) then
    local content = api.nvim_buf_get_lines(current_buf, 0, -1, false)
    blame_entries, err = git.blame.blame_buffer(file_path, content)
  else
    blame_entries, err = git.blame.blame_file(file_path)
  end

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
    highlight_ns = api.nvim_create_namespace("neogit_blame_hunk"),
    last_highlighted_commit = nil,
    history_buffer_names = {},
  }
  setmetatable(instance, { __index = M })
  return instance
end

--- This function renders only the static content.
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

--- Update the file buffer with content from a specific commit.
--- This function is now non-destructive to the original user buffer.
---@param self BlameSplitBuffer
---@param commit string|nil The commit to show content from (nil for working tree)
function M:update_file_buffer_content(commit)
  local file_win = self.view_win_id
  if not (file_win and api.nvim_win_is_valid(file_win)) then
    return
  end

  -- If not a specific commit, we are viewing the working tree.
  -- Restore the original buffer to the window.
  if not commit then
    if self.view_file_buffer ~= self.original_file_buffer then
      api.nvim_win_set_buf(file_win, self.original_file_buffer)
      self.view_file_buffer = self.original_file_buffer
    end
    -- The original buffer is now back in view, with its content and modified status intact.
    -- No further action needed for its content.
    return
  end

  -- For a specific commit, we need to show historical content.
  -- We use a single temporary buffer to avoid creating many buffers.
  if not self.temp_history_buffer or not api.nvim_buf_is_valid(self.temp_history_buffer) then
    self.temp_history_buffer = api.nvim_create_buf(false, true) -- not listed, scratch
    api.nvim_buf_set_option(self.temp_history_buffer, "bufhidden", "wipe")
  end

  -- Make sure the temporary buffer is being shown.
  if self.view_file_buffer ~= self.temp_history_buffer then
    api.nvim_win_set_buf(file_win, self.temp_history_buffer)
    self.view_file_buffer = self.temp_history_buffer
  end

  local content, err
  local ok, result = pcall(function()
    return git.cli.show.file(self.file_path, commit).call { hidden = true, trim = false }
  end)

  if not ok or result.code ~= 0 then
    err = result and result.stderr or "pcall failed"
    local msg = "Failed to get file content at commit " .. git.blame.abbreviate_commit(commit) .. "\n\n" .. err
    vim.notify(msg, vim.log.levels.WARN, { title = "Blame" })
    -- Put some error message in the buffer to indicate failure
    content = { "Error: Could not load file content for this commit." }
  else
    content = result.stdout
  end

  local git_dir = git.repo.git_dir
  local new_name = string.format("neogit://%s//%s:%s", git_dir, commit, self.file_path)

  -- Atomically update the temporary buffer's content.
  api.nvim_buf_call(self.view_file_buffer, function()
  api.nvim_buf_set_option(self.view_file_buffer, "modifiable", true)
  api.nvim_buf_set_lines(self.view_file_buffer, 0, -1, false, content)
  api.nvim_buf_set_option(self.view_file_buffer, "modifiable", false)
  api.nvim_buf_set_option(self.view_file_buffer, "modified", false)
  pcall(api.nvim_buf_set_name, self.view_file_buffer, new_name)
end)

-- Now that the buffer is in a stable state, set the filetype.
local original_ft = api.nvim_get_option_value("filetype", { buf = self.original_file_buffer })
api.nvim_buf_set_option(self.view_file_buffer, "filetype", original_ft)
end

--- Re-runs the blame for the given file at a specific commit and adds to history.
---@param self BlameSplitBuffer
---@param commit string|nil The commit SHA or revision string (e.g., "HEAD^") to blame at.
---@param original_line number The line number to try to restore the cursor to.
function M:reblame(commit, original_line)
  -- Normalize commit: convert all-zero commits to nil (working tree)
  if commit and commit:match("^0+$") then
    commit = nil
  end

  if self.history_index > 0 and self.history_index <= #self.history_stack then
    self.history_stack[self.history_index].line = original_line
  end
  self:push_history(commit, "reblame", original_line)
  self:reblame_without_history(commit, original_line)
end

function M:reblame_without_history(commit, original_line)
  local new_blame_entries, err

  if commit then
    -- Blame against a specific commit
    new_blame_entries, err = git.blame.blame_file(self.file_path, commit)
  else
    -- Blame against working tree (check for unsaved changes)
    if self.was_originally_modified then
      local content = api.nvim_buf_get_lines(self.original_file_buffer, 0, -1, false)
      new_blame_entries, err = git.blame.blame_buffer(self.file_path, content)
    else
      new_blame_entries, err = git.blame.blame_file(self.file_path)
    end
  end

  if not new_blame_entries then
    local error_message = "Neogit: No blame information found for " .. self.file_path
    if commit then
      error_message = error_message .. " at commit " .. git.blame.abbreviate_commit(commit)
    end
    if err and err ~= "" then
      error_message = error_message .. ".\n\nDetails:\n" .. err
    end
    vim.notify(error_message, vim.log.levels.WARN, { title = "Blame" })

    -- Don't update the buffer state if blame failed - this prevents the navigation from breaking
    return false
  end

  if #new_blame_entries == 0 then
    local info_message = "Neogit: No blame information found for " .. self.file_path
    if commit then
      info_message = info_message .. " at commit " .. git.blame.abbreviate_commit(commit)
    end
    vim.notify(info_message, vim.log.levels.INFO, { title = "Blame" })
    return false
  end

  -- Only update file buffer content if blame was successful
  self:update_file_buffer_content(commit)

  -- Update state only after successful blame
  self.blame_entries = new_blame_entries
  self.commit_colors = {}
  self.next_color_index = 1
  self.last_highlighted_commit = nil

  local components = self:render_blame_lines()
  self.buffer.ui:render(Ui.col(components))

  -- Clear any previous status messages on successful operation
  vim.cmd("echon ''")

  -- Restore cursor position and update highlights
  vim.defer_fn(function()
    if self.buffer and api.nvim_buf_is_valid(self.buffer.handle) then
      local line_count = api.nvim_buf_line_count(self.buffer.handle)
      local target_line = math.min(original_line, line_count)
      local win_handle = self.buffer.win_handle
      if win_handle and api.nvim_win_is_valid(win_handle) then
        pcall(api.nvim_win_set_cursor, win_handle, { math.max(1, target_line), 0 })
        api.nvim_win_call(win_handle, function()
          vim.cmd("normal! zz")
          self:update_hunk_highlight() -- Initial highlight after re-blame
        end)
      end
    end
  end, 10)

  return true
end

function M:setup_scroll_sync()
  local blame_buf = self.buffer.handle
  local syncing = false

  local function sync_cursor(source_bufnr, target_win_id)
    if syncing or not api.nvim_win_is_valid(target_win_id) then
      return
    end
    syncing = true
    local source_win_id = fn.bufwinid(source_bufnr)
    if source_win_id > 0 then
      local source_line = api.nvim_win_get_cursor(source_win_id)[1]
      pcall(api.nvim_win_set_cursor, target_win_id, { source_line, 0 })
    end
    syncing = false
  end

  api.nvim_create_autocmd("CursorMoved", {
    buffer = blame_buf,
    callback = function()
      if self.view_win_id then
        sync_cursor(blame_buf, self.view_win_id)
        self:update_hunk_highlight()
      end
    end,
    group = self.buffer.autocmd_group,
  })

  api.nvim_create_autocmd("CursorMoved", {
    pattern = "*", -- Needs to be generic as file buffer can change
    callback = function(args)
      if args.buf == self.view_file_buffer then
        local blame_win_id = fn.bufwinid(blame_buf)
        if blame_win_id > 0 then
          sync_cursor(args.buf, blame_win_id)
        end
      end
    end,
    group = self.buffer.autocmd_group,
  })

  api.nvim_create_autocmd("WinScrolled", {
    callback = function(args)
      if syncing then
        return
      end
      local scrolled_win = tonumber(args.match)
      if not (scrolled_win and api.nvim_win_is_valid(scrolled_win)) then
        return
      end

      syncing = true
      local scrolled_buf = api.nvim_win_get_buf(scrolled_win)
      local target_win_id

      if scrolled_buf == blame_buf then
        target_win_id = self.view_win_id
      elseif scrolled_buf == self.view_file_buffer then
        target_win_id = fn.bufwinid(blame_buf)
      end

      if target_win_id and api.nvim_win_is_valid(target_win_id) then
        local view = api.nvim_win_call(scrolled_win, fn.winsaveview)
        api.nvim_win_call(target_win_id, function()
          fn.winrestview(view)
        end)
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
          -- A resize requires a full re-render
          local components = self:render_blame_lines()
          self.buffer.ui:render(Ui.col(components))
          -- Re-apply highlights after render
          self:update_hunk_highlight()
        end
      end
    end,
    group = self.buffer.autocmd_group,
  })
end

function M:close()
  -- If we used a temporary buffer for history, restore the original buffer to the window.
  if self.view_win_id and api.nvim_win_is_valid(self.view_win_id) then
    if self.view_file_buffer ~= self.original_file_buffer then
      api.nvim_win_set_buf(self.view_win_id, self.original_file_buffer)
    end
    -- Restore cursor position in the original window
    api.nvim_win_call(self.view_win_id, function()
      if self.initial_cursor_line then
        local line_count = api.nvim_buf_line_count(0)
        local target_line = math.min(self.initial_cursor_line, line_count)
        pcall(api.nvim_win_set_cursor, 0, { math.max(1, target_line), 0 })
      end
    end)
  end

  -- Clean up the temporary history buffer if it was created
  if self.temp_history_buffer and api.nvim_buf_is_valid(self.temp_history_buffer) then
    pcall(api.nvim_buf_delete, self.temp_history_buffer, { force = true })
  end

  -- Close the main blame split buffer.
  if self.buffer then
    self.buffer:close()
  end

  -- Restore settings on the original window.
  if self.original_wrap ~= nil and self.view_win_id and api.nvim_win_is_valid(self.view_win_id) then
    pcall(api.nvim_win_set_option, self.view_win_id, "wrap", self.original_wrap)
  end

  -- Finally, clear the singleton instance.
  M.instance = nil
end

function M.is_open()
  return M.instance and M.instance.buffer and M.instance.buffer:is_visible()
end

function M:open()
  M.instance = self

  -- Setup initial state from the user's buffer
  self.original_file_buffer = api.nvim_get_current_buf()
  self.view_file_buffer = self.original_file_buffer
  self.view_win_id = api.nvim_get_current_win()
  self.initial_cursor_line = api.nvim_win_get_cursor(0)[1]
  self.was_originally_modified = api.nvim_get_option_value("modified", { buf = self.original_file_buffer })
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
          if entry.commit:match("^0+$") ~= nil then
            vim.notify(
              "Cannot show commit view for uncommitted changes.",
              vim.log.levels.INFO,
              { title = "Blame" }
            )
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
        r = function()
          local line_nr = api.nvim_win_get_cursor(0)[1]
          local entry = self:get_blame_entry_for_line(line_nr)
          if not entry then
            return
          end
          if entry.commit:match("^0+$") then
            vim.notify("Cannot re-blame at an uncommitted change.", vim.log.levels.INFO, { title = "Blame" })
            return
          end
          self:reblame(entry.commit, line_nr)
        end,
        R = function()
          self:go_back()
        end,
        p = function()
          local line_nr = api.nvim_win_get_cursor(0)[1]
          self:goto_parent(line_nr, true)
        end,
        P = function()
          self:go_back()
        end,
        ["<C-o>"] = function()
          self:go_back()
        end,
        ["<C-i>"] = function()
          self:go_forward()
        end,
        ["["] = function()
          self:go_back()
        end,
        ["]"] = function()
          self:go_forward()
        end,
        d = function()
          local line_nr = api.nvim_win_get_cursor(0)[1]
          local entry = self:get_blame_entry_for_line(line_nr)
          if not entry then
            return
          end
          if entry.commit:match("^0+$") then
            vim.notify("Cannot diff uncommitted changes.", vim.log.levels.INFO, { title = "Blame" })
            return
          end
          local diffview = require("neogit.integrations.diffview")
          diffview.open("commit", entry.commit, { paths = { self.file_path }, new_tab = true })
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

      if #self.history_stack == 0 then
        self.history_stack = { { commit = nil, type = "initial", line = self.initial_cursor_line } }
        self.history_index = 1
      end

      -- Restore cursor position and trigger initial highlight
      vim.defer_fn(function()
        if api.nvim_win_is_valid(buffer.win_handle) then
          local line_count = api.nvim_buf_line_count(buffer.handle)
          local target_line = math.min(self.initial_cursor_line, line_count)
          pcall(api.nvim_win_set_cursor, buffer.win_handle, { math.max(1, target_line), 0 })
          api.nvim_win_call(buffer.win_handle, function()
            vim.cmd("normal! zz")
            self:update_hunk_highlight()
          end)
        end
      end, 10)
    end,
  }
end

return M
