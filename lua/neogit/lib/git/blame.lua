local git = require("neogit.lib.git")

---@class NeogitGitBlame
local M = {}

---@class BlameEntry
---@field commit string Full commit hash
---@field author string Author name
---@field author_time number Unix timestamp
---@field author_tz string Timezone
---@field committer string Committer name
---@field committer_time number Unix timestamp
---@field committer_tz string Timezone
---@field summary string Commit message summary
---@field previous string|nil Previous commit hash
---@field filename string Filename
---@field line_start number Starting line number in original file
---@field line_count number Number of lines in this hunk
---@field line_end number Ending line number in original file
---@field content string[] Lines of content

---Parse git blame porcelain output
---@param output string[] Lines from git blame --porcelain
---@return BlameEntry[]
function M.parse_blame_porcelain(output)
  local entries = {}
  local commit_info = {} -- Cache commit info by commit hash
  local i = 1

  while i <= #output do
    local line = output[i]

    -- Check if this is a commit line (starts with commit hash)
    local commit, orig_line, final_line = line:match("^([a-f0-9]+) (%d+) (%d+)")
    if commit then
      local final_line_num = tonumber(final_line)

      -- Initialize commit info if not seen before
      if not commit_info[commit] then
        commit_info[commit] = {
          commit = commit,
          author = "",
          author_time = 0,
          author_tz = "",
          committer = "",
          committer_time = 0,
          committer_tz = "",
          summary = "",
          filename = "",
          previous = nil,
        }
      end

      -- Create entry for this line
      local entry = {
        commit = commit,
        line_start = tonumber(orig_line),
        line_end = final_line_num,
        line_count = 1, -- Each entry represents one line
        content = {},
        author = commit_info[commit].author,
        author_time = commit_info[commit].author_time,
        author_tz = commit_info[commit].author_tz,
        committer = commit_info[commit].committer,
        committer_time = commit_info[commit].committer_time,
        committer_tz = commit_info[commit].committer_tz,
        summary = commit_info[commit].summary,
        filename = commit_info[commit].filename,
        previous = commit_info[commit].previous,
      }

      -- Parse metadata for this commit (if not already parsed)
      local j = i + 1
      while j <= #output and not output[j]:match("^[a-f0-9]+ %d+ %d+") and not output[j]:match("^\t") do
        local metadata_line = output[j]

        local author = metadata_line:match("^author (.+)")
        if author then
          commit_info[commit].author = author
          entry.author = author
        end

        local author_time = metadata_line:match("^author%-time (%d+)")
        if author_time then
          commit_info[commit].author_time = tonumber(author_time)
          entry.author_time = tonumber(author_time)
        end

        local author_tz = metadata_line:match("^author%-tz (.+)")
        if author_tz then
          commit_info[commit].author_tz = author_tz
          entry.author_tz = author_tz
        end

        local committer = metadata_line:match("^committer (.+)")
        if committer then
          commit_info[commit].committer = committer
          entry.committer = committer
        end

        local committer_time = metadata_line:match("^committer%-time (%d+)")
        if committer_time then
          commit_info[commit].committer_time = tonumber(committer_time)
          entry.committer_time = tonumber(committer_time)
        end

        local committer_tz = metadata_line:match("^committer%-tz (.+)")
        if committer_tz then
          commit_info[commit].committer_tz = committer_tz
          entry.committer_tz = committer_tz
        end

        local summary = metadata_line:match("^summary (.+)")
        if summary then
          commit_info[commit].summary = summary
          entry.summary = summary
        end

        local previous = metadata_line:match("^previous ([a-f0-9]+)")
        if previous then
          commit_info[commit].previous = previous
          entry.previous = previous
        end

        local filename = metadata_line:match("^filename (.+)")
        if filename then
          commit_info[commit].filename = filename
          entry.filename = filename
        end

        j = j + 1
      end

      -- Skip to content line (starts with tab)
      while j <= #output and not output[j]:match("^\t") do
        j = j + 1
      end

      if j <= #output and output[j]:match("^\t") then
        table.insert(entry.content, output[j]:sub(2)) -- Remove leading tab
        j = j + 1
      end

      table.insert(entries, entry)
      i = j
    else
      i = i + 1
    end
  end

  return entries
end

---Get blame information for a file on disk.
---@param file string Path to file
---@param commit string|nil Commit to blame from (defaults to working tree)
---@return BlameEntry[]|nil, string|nil err
function M.blame_file(file, commit)
  local ok, result = pcall(function()
    local cmd = git.cli.blame.porcelain
    if commit then
      cmd = cmd.args(commit)
    end
    return cmd.files(file).call { hidden = true, trim = false }
  end)

  if not ok then
    return nil, "Error calling git blame: " .. tostring(result)
  end

  if result.code ~= 0 then
    local err_msg = "Git blame failed"
    if result.stderr and #result.stderr > 0 and result.stderr[1] ~= "" then
      err_msg = err_msg .. ":\n" .. table.concat(result.stderr, "\n")
    end
    return nil, err_msg
  end

  return M.parse_blame_porcelain(result.stdout)
end

---Get blame information for a buffer's content.
---@param file string Path to file (for history lookup)
---@param content string[] Buffer content
---@return BlameEntry[]|nil, string|nil err
function M.blame_buffer(file, content)
  local ok, result = pcall(function()
    return git.cli.blame.porcelain
      .args("--contents", "-")
      .files(file)
      .input(table.concat(content, "\n") .. "\n") -- Git often needs a trailing newline
      .call { hidden = true, trim = false }
  end)

  if not ok then
    return nil, "Error calling git blame with buffer contents: " .. tostring(result)
  end

  if result.code ~= 0 then
    local err_msg = "Git blame with buffer contents failed"
    if result.stderr and #result.stderr > 0 and result.stderr[1] ~= "" then
      err_msg = err_msg .. ":\n" .. table.concat(result.stderr, "\n")
    end
    return nil, err_msg
  end

  return M.parse_blame_porcelain(result.stdout)
end

---Format a timestamp as a date string
---@param timestamp number Unix timestamp
---@return string Formatted date (YYYY-MM-DD)
function M.format_date(timestamp)
  return os.date("%Y-%m-%d", timestamp)
end

---Get abbreviated commit hash
---@param commit string Full commit hash
---@return string Abbreviated hash (8 characters)
function M.abbreviate_commit(commit)
  if commit:match("^0+$") then
    return "Uncommitted"
  end
  return commit:sub(1, 8)
end

return M
