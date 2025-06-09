local Buffer = require("neogit.lib.buffer")
local git = require("neogit.lib.git")
local blame = require("neogit.lib.git.blame")
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
local M = {
  instance = nil,
}

-- Available highlight groups for different commits
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

---Creates a new BlameSplitBuffer
---@param file_path string Path to the file to blame
---@return BlameSplitBuffer
function M.new(file_path)
  if not file_path or file_path == "" then
    file_path = vim.fn.expand("%:p")
  end

  -- Make path relative to git root
  local git_root = git.repo.worktree_root
  if file_path:sub(1, #git_root) == git_root then
    file_path = file_path:sub(#git_root + 2) -- +2 to skip the trailing slash
  end

  local blame_entries = blame.blame_file(file_path)

  local instance = {
    file_path = file_path,
    blame_entries = blame_entries,
    file_buffer = nil,
    commit_colors = {},
    next_color_index = 1,
    buffer = nil,
  }

  setmetatable(instance, { __index = M })

  return instance
end

---Assign a unique color to each commit
---@param commit string Commit hash
---@return string Highlight group name
function M:get_commit_color(commit)
  if not self.commit_colors[commit] then
    local color_index = ((self.next_color_index - 1) % #COMMIT_COLORS) + 1
    self.commit_colors[commit] = COMMIT_COLORS[color_index]
    self.next_color_index = self.next_color_index + 1
  end
  return self.commit_colors[commit]
end

---Format a blame line according to the specification
---@param entry BlameEntry
---@param line_in_hunk number Line number within this blame entry (1-based)
---@return string, table[] Formatted line and highlight information
function M:format_blame_line(entry, line_in_hunk)
  local commit_short = blame.abbreviate_commit(entry.commit)
  local date = blame.format_date(entry.author_time)
  local author = entry.author

  -- Determine the line type and format accordingly
  local is_first_line = line_in_hunk == 1
  local is_second_line = line_in_hunk == 2
  local is_last_line = line_in_hunk == entry.line_count
  local is_single_line = entry.line_count == 1

  local line, highlights

  if is_single_line then
    -- Single line: show commit message after commit info, right-align date
    local summary = entry.summary
    local prefix = string.format("┍ %s %s ", commit_short, author)
    local available_width = 40 - #prefix - #date - 1 -- 1 for space before date

    if #summary > available_width then
      summary = summary:sub(1, available_width - 3) .. "..."
    end

    -- Ensure exact 40 character width with right-aligned date
    local content = prefix .. summary
    local total_content_length = #content + #date
    local padding = 40 - total_content_length
    if padding < 1 then
      -- If content is too long, truncate summary further
      local excess = total_content_length - 39 -- 39 to leave at least 1 space
      summary = summary:sub(1, #summary - excess)
      content = prefix .. summary
      padding = 1
    end

    line = content .. string.rep(" ", padding) .. date

    local message_start = #prefix
    local message_end = message_start + #summary

    highlights = {
      { 0, 2, self:get_commit_color(entry.commit) }, -- Symbol
      { 2, 2 + #commit_short, self:get_commit_color(entry.commit) }, -- Commit
      { 2 + #commit_short + 1, 2 + #commit_short + 1 + #author, "Normal" }, -- Author
      { message_start, message_end, "NeogitBlameMessage" }, -- Message
      { 40 - #date, 40, "NeogitBlameDate" }, -- Date (always at the end)
    }
  elseif is_first_line then
    -- First line of multi-line hunk: show commit info with right-aligned date
    local prefix = string.format("┍ %s %s", commit_short, author)
    local total_content_length = #prefix + #date
    local padding = 40 - total_content_length
    if padding < 1 then
      -- Truncate author name if necessary
      local excess = total_content_length - 39
      author = author:sub(1, #author - excess)
      prefix = string.format("┍ %s %s", commit_short, author)
      padding = 1
    end

    line = prefix .. string.rep(" ", padding) .. date

    highlights = {
      { 0, 2, self:get_commit_color(entry.commit) }, -- Symbol
      { 2, 2 + #commit_short, self:get_commit_color(entry.commit) }, -- Commit
      { 2 + #commit_short + 1, 2 + #commit_short + 1 + #author, "Normal" }, -- Author
      { 40 - #date, 40, "NeogitBlameDate" }, -- Date (always at the end)
    }
  elseif is_second_line then
    -- Second line: show commit message, pad to exactly 40 characters
    local summary = entry.summary
    local prefix = "┍ "
    local available_width = 40 - #prefix

    if #summary > available_width then
      summary = summary:sub(1, available_width - 3) .. "..."
    end

    line = prefix .. summary
    -- Pad to exactly 40 characters
    line = line .. string.rep(" ", 40 - #line)

    highlights = {
      { 0, 2, self:get_commit_color(entry.commit) }, -- Symbol
      { 2, 2 + #summary, "NeogitBlameMessage" }, -- Message
    }
  elseif is_last_line then
    -- Last line: just the symbol, pad to exactly 40 characters
    line = "┕" .. string.rep(" ", 39)

    highlights = {
      { 0, 1, self:get_commit_color(entry.commit) }, -- Symbol
    }
  else
    -- Middle line: pad to exactly 40 characters
    line = "│" .. string.rep(" ", 39)

    highlights = {
      { 0, 1, self:get_commit_color(entry.commit) }, -- Symbol
    }
  end

  return line, highlights
end

---Generate the blame content
---@return string[], table[] Lines and highlight information
function M:generate_blame_content()
  local lines = {}
  local all_highlights = {}

  -- Group consecutive lines by commit to create hunks
  local hunks = {}
  local current_hunk = nil

  for _, entry in ipairs(self.blame_entries) do
    if
      not current_hunk
      or current_hunk.commit ~= entry.commit
      or current_hunk.author ~= entry.author
      or current_hunk.summary ~= entry.summary
    then
      if current_hunk then
        table.insert(hunks, current_hunk)
      end
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

  if current_hunk then
    table.insert(hunks, current_hunk)
  end

  -- Generate blame lines from hunks
  for _, hunk in ipairs(hunks) do
    for i = 1, hunk.line_count do
      local line, highlights = self:format_blame_line(hunk, i)
      table.insert(lines, line)

      -- Adjust highlight positions for the current line
      for _, hl in ipairs(highlights) do
        table.insert(all_highlights, {
          #lines - 1, -- line number (0-based)
          hl[1], -- start col
          hl[2], -- end col
          hl[3], -- highlight group
        })
      end
    end
  end

  return lines, all_highlights
end

---Set up window width maintenance to ensure blame split stays at 40 columns
function M:setup_width_maintenance()
  if not self.buffer or not self.buffer.win_handle then
    return
  end

  local blame_win = self.buffer.win_handle

  -- Monitor window events to maintain width
  api.nvim_create_autocmd({ "WinResized", "WinNew", "WinClosed", "BufWinEnter", "BufWinLeave" }, {
    callback = function()
      -- Check if the blame window still exists and is valid
      if api.nvim_win_is_valid(blame_win) then
        local current_width = api.nvim_win_get_width(blame_win)
        if current_width ~= 40 then
          pcall(api.nvim_win_set_width, blame_win, 40)
        end
      end
    end,
    group = self.buffer.autocmd_group,
  })

  -- Also monitor when other buffers open/close to maintain width
  api.nvim_create_autocmd({ "BufEnter", "BufLeave" }, {
    callback = function()
      vim.defer_fn(function()
        if api.nvim_win_is_valid(blame_win) then
          local current_width = api.nvim_win_get_width(blame_win)
          if current_width ~= 40 then
            pcall(api.nvim_win_set_width, blame_win, 40)
          end
        end
      end, 10) -- Small delay to let window layout settle
    end,
    group = self.buffer.autocmd_group,
  })
end

---Set up scroll synchronization between blame and file buffers
function M:setup_scroll_sync()
  if not self.file_buffer or not api.nvim_buf_is_valid(self.file_buffer) then
    return
  end

  local blame_buf = self.buffer.handle
  local file_buf = self.file_buffer

  -- Flag to prevent infinite recursion during sync
  local syncing = false

  -- Helper function to sync scroll position
  local function sync_scroll_position(source_win, target_win)
    local source_view = api.nvim_win_call(source_win, fn.winsaveview)

    api.nvim_win_call(target_win, function()
      -- Get current view to preserve cursor position if needed
      local target_view = fn.winsaveview()

      -- Copy view parameters for scroll synchronization
      target_view.topline = source_view.topline
      target_view.lnum = source_view.lnum
      target_view.col = 0 -- Always set column to 0 for blame sync
      target_view.coladd = source_view.coladd or 0
      target_view.curswant = 0

      fn.winrestview(target_view)
    end)
  end

  -- Sync blame -> file (cursor movement)
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = blame_buf,
    callback = function()
      if syncing then
        return
      end

      local blame_line = api.nvim_win_get_cursor(0)[1]
      local file_wins = fn.win_findbuf(file_buf)

      if #file_wins > 0 then
        local file_win = file_wins[1]
        syncing = true
        -- Use win_call to set cursor in the file window without changing focus
        api.nvim_win_call(file_win, function()
          pcall(api.nvim_win_set_cursor, 0, { blame_line, 0 })
        end)
        syncing = false
      end
    end,
    group = self.buffer.autocmd_group,
  })

  -- Sync file -> blame (cursor movement)
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = file_buf,
    callback = function()
      if syncing then
        return
      end

      local file_line = api.nvim_win_get_cursor(0)[1]
      local blame_wins = fn.win_findbuf(blame_buf)

      if #blame_wins > 0 then
        local blame_win = blame_wins[1]
        syncing = true
        -- Use win_call to set cursor in the blame window without changing focus
        api.nvim_win_call(blame_win, function()
          pcall(api.nvim_win_set_cursor, 0, { file_line, 0 })
        end)
        syncing = false
      end
    end,
    group = self.buffer.autocmd_group,
  })

  -- Sync scrolling using WinScrolled event
  api.nvim_create_autocmd("WinScrolled", {
    callback = function(args)
      if syncing then
        return
      end

      local scrolled_win = tonumber(args.match)
      if not scrolled_win then
        return
      end

      local scrolled_buf = api.nvim_win_get_buf(scrolled_win)

      if scrolled_buf == blame_buf then
        -- Blame window scrolled, sync file window
        local file_wins = fn.win_findbuf(file_buf)
        if #file_wins > 0 then
          local file_win = file_wins[1]
          syncing = true
          sync_scroll_position(scrolled_win, file_win)
          syncing = false
        end
      elseif scrolled_buf == file_buf then
        -- File window scrolled, sync blame window
        local blame_wins = fn.win_findbuf(blame_buf)
        if #blame_wins > 0 then
          local blame_win = blame_wins[1]
          syncing = true
          sync_scroll_position(scrolled_win, blame_win)
          syncing = false
        end
      end
    end,
    group = self.buffer.autocmd_group,
  })
end

---Close the blame split
function M:close()
  if self.buffer then
    self.buffer:close()
    self.buffer = nil
  end

  -- Restore original wrap setting in file buffer
  if self.original_wrap ~= nil then
    vim.wo.wrap = self.original_wrap
  end

  M.instance = nil
end

---Check if blame split is open
---@return boolean
function M.is_open()
  return M.instance and M.instance.buffer and M.instance.buffer:is_visible()
end

---Open the blame split
function M:open()
  M.instance = self

  -- Find the current file buffer to sync with
  self.file_buffer = api.nvim_get_current_buf()

  -- Store original wrap setting and disable wrapping in file buffer
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
        ["s"] = function()
          -- Jump to commit view for the commit under cursor
          local line_nr = api.nvim_win_get_cursor(0)[1]
          local entry = self:get_blame_entry_for_line(line_nr)
          if entry then
            -- Store the current blame window to return focus to it later
            local blame_win = api.nvim_get_current_win()

            local CommitViewBuffer = require("neogit.buffers.commit_view")
            local commit_view = CommitViewBuffer.new(entry.commit)

            -- Override the commit view's close behavior to return focus to blame split
            local original_close = commit_view.close
            commit_view.close = function(cv)
              -- Call the original close function
              if original_close then
                original_close(cv)
              end

              -- Return focus to the blame window if it's still valid
              if api.nvim_win_is_valid(blame_win) then
                api.nvim_set_current_win(blame_win)
              end
            end

            commit_view:open()
          end
        end,
        ["q"] = function()
          self:close()
        end,
        ["<esc>"] = function()
          self:close()
        end,
      },
    },
    render = function()
      return self:render_blame_lines()
    end,
    after = function(buffer)
      -- Set window width to exactly 40 characters
      if buffer.win_handle then
        api.nvim_win_set_width(buffer.win_handle, 40)
        -- Disable line wrapping to prevent cursor synchronization issues
        api.nvim_win_set_option(buffer.win_handle, "wrap", false)
        -- Set window options to prevent resizing
        api.nvim_win_set_option(buffer.win_handle, "winfixwidth", true)
      end

      -- Assign the buffer to self so setup_scroll_sync can access it
      self.buffer = buffer

      -- Set up scroll synchronization
      self:setup_scroll_sync()

      -- Set up window width maintenance
      self:setup_width_maintenance()
    end,
  }
end

---Render blame lines using proper UI components with highlighting
---@return table[] UI components
function M:render_blame_lines()
  local text = Ui.text
  local row = Ui.row
  local components = {}

  -- Group consecutive lines by commit to create hunks
  local hunks = {}
  local current_hunk = nil

  for _, entry in ipairs(self.blame_entries) do
    if
      not current_hunk
      or current_hunk.commit ~= entry.commit
      or current_hunk.author ~= entry.author
      or current_hunk.summary ~= entry.summary
    then
      if current_hunk then
        table.insert(hunks, current_hunk)
      end
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

  if current_hunk then
    table.insert(hunks, current_hunk)
  end

  -- Generate blame lines from hunks
  for _, hunk in ipairs(hunks) do
    for i = 1, hunk.line_count do
      local commit_short = blame.abbreviate_commit(hunk.commit)
      local date = blame.format_date(hunk.author_time)
      local author = hunk.author
      local commit_color = self:get_commit_color(hunk.commit)

      local is_first_line = i == 1
      local is_second_line = i == 2
      local is_last_line = i == hunk.line_count
      local is_single_line = hunk.line_count == 1

      if is_single_line then
        -- Single line: show commit message after commit info, right-align date
        local summary = hunk.summary
        local prefix = string.format("┍ %s %s ", commit_short, author)
        local available_width = 40 - #prefix - #date - 1 -- 1 for space before date

        if #summary > available_width then
          summary = summary:sub(1, available_width - 3) .. "..."
        end

        -- Ensure exact 40 character width with right-aligned date
        local content = prefix .. summary
        local total_content_length = #content + #date
        local padding = 40 - total_content_length
        if padding < 1 then
          -- If content is too long, truncate summary further
          local excess = total_content_length - 39 -- 39 to leave at least 1 space
          summary = summary:sub(1, #summary - excess)
          content = prefix .. summary
          padding = 1
        end

        table.insert(
          components,
          row {
            text("┍ ", { highlight = commit_color }),
            text(commit_short, { highlight = commit_color }),
            text(" " .. author .. " "),
            text(summary, { highlight = "NeogitBlameMessage" }),
            text(string.rep(" ", padding)),
            text(date, { highlight = "NeogitBlameDate" }),
          }
        )
      elseif is_first_line then
        -- First line of multi-line hunk: show commit info with right-aligned date
        local prefix = string.format("┍ %s %s", commit_short, author)
        local total_content_length = #prefix + #date
        local padding = 40 - total_content_length
        if padding < 1 then
          -- Truncate author name if necessary
          local excess = total_content_length - 39
          author = author:sub(1, #author - excess)
          prefix = string.format("┍ %s %s", commit_short, author)
          padding = 1
        end

        table.insert(
          components,
          row {
            text("┍ ", { highlight = commit_color }),
            text(commit_short, { highlight = commit_color }),
            text(" " .. author),
            text(string.rep(" ", padding)),
            text(date, { highlight = "NeogitBlameDate" }),
          }
        )
      elseif is_second_line then
        -- Second line: show commit message, pad to exactly 40 characters
        local summary = hunk.summary
        local prefix = "┍ "
        local available_width = 40 - #prefix

        if #summary > available_width then
          summary = summary:sub(1, available_width - 3) .. "..."
        end

        local padding_needed = 40 - #prefix - #summary

        table.insert(
          components,
          row {
            text("┍ ", { highlight = commit_color }),
            text(summary, { highlight = "NeogitBlameMessage" }),
            text(string.rep(" ", padding_needed)),
          }
        )
      elseif is_last_line then
        -- Last line: just the symbol, pad to exactly 40 characters
        table.insert(
          components,
          row {
            text("┕", { highlight = commit_color }),
            text(string.rep(" ", 39)),
          }
        )
      else
        -- Middle line: pad to exactly 40 characters
        table.insert(
          components,
          row {
            text("│", { highlight = commit_color }),
            text(string.rep(" ", 39)),
          }
        )
      end
    end
  end

  return components
end

---Get the blame entry for a specific line number
---@param line_nr number Line number (1-based)
---@return BlameEntry|nil
function M:get_blame_entry_for_line(line_nr)
  -- Since we now group entries into hunks, we need to map back to the original entries
  -- For now, let's use a simple approach: return the entry at the corresponding index
  if line_nr > 0 and line_nr <= #self.blame_entries then
    return self.blame_entries[line_nr]
  end

  return nil
end

return M
