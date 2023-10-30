local utils = require('hurl.utils')

local M = {}

local response = {}

--- Output handler
---@class Output
local on_output = function(code, data, event)
  local head_state
  if data[1] == '' then
    table.remove(data, 1)
  end
  if not data[1] then
    return
  end

  if event == 'stderr' and #data > 1 then
    response.body = data
    utils.log_error(vim.inspect(data))
    response.raw = data
    response.headers = {}
    return
  end

  local status = tonumber(string.match(data[1], '([%w+]%d+)'))
  head_state = 'start'
  if status then
    response.status = status
    response.headers = { status = data[1] }
    response.headers_str = data[1] .. '\r\n'
  end

  for i = 2, #data do
    local line = data[i]
    if line == '' or line == nil then
      head_state = 'body'
    elseif head_state == 'start' then
      local key, value = string.match(line, '([%w-]+):%s*(.+)')
      if key and value then
        response.headers[key] = value
        response.headers_str = response.headers_str .. line .. '\r\n'
      end
    elseif head_state == 'body' then
      response.body = response.body or ''
      response.body = response.body .. line
    end
  end
  response.raw = data

  utils.log_info('hurl: response status ' .. response.status)
  utils.log_info('hurl: response headers ' .. vim.inspect(response.headers))
  utils.log_info('hurl: response body ' .. response.body)
end

--- Call hurl command
---@param opts table The options
---@param callback? function The callback function
local function request(opts, callback)
  vim.notify('hurl: running request', vim.log.levels.INFO)
  local cmd = vim.list_extend({ 'hurl', '-i', '--no-color' }, opts)
  response = {}

  if _HURL_GLOBAL_CONFIG.debug then
    vim.fn.setqflist({ { filename = vim.inspect(cmd), text = vim.inspect(opts) } })
  end

  vim.fn.jobstart(cmd, {
    on_stdout = on_output,
    on_stderr = on_output,
    on_exit = function(i, code)
      utils.log_info('exit at ' .. i .. ' , code ' .. code)
      if code ~= 0 then
        -- Send error code and response to quickfix and open it
        vim.fn.setqflist({ { filename = vim.inspect(cmd), text = vim.inspect(response.body) } })
        vim.cmd('copen')
      end

      vim.notify('hurl: request finished', vim.log.levels.INFO)

      if callback then
        return callback(response)
      else
        -- show messages
        local lines = response.raw or response.body
        if #lines == 0 then
          return
        end

        local container = require('hurl.' .. _HURL_GLOBAL_CONFIG.mode)
        local content_type = response.headers['content-type']
          or response.headers['Content-Type']
          or ''

        utils.log_info('Detected content type: ' .. content_type)

        if utils.is_json_response(content_type) then
          container.show(response, 'json')
        else
          if utils.is_html_response(content_type) then
            container.show(response, 'html')
          else
            container.show(response, 'text')
          end
        end
      end
    end,
  })
end

--- Run current file
--- It will throw an error if that is not valid hurl file
---@param opts table The options
local function run_current_file(opts)
  opts = opts or {}
  table.insert(opts, vim.fn.expand('%:p'))
  request(opts)
end

--- Run selection
---@param opts table The options
local function run_selection(opts)
  opts = opts or {}
  local lines = utils.get_visual_selection()
  if not lines then
    return
  end
  local fname = utils.create_tmp_file(lines)

  if not fname then
    vim.notify('hurl: create tmp file failed. Please try again!', vim.log.levels.WARN)
    return
  end

  table.insert(opts, fname)
  request(opts)

  -- Clean tmp file after 1s
  local timeout = 1000
  vim.defer_fn(function()
    local success = os.remove(fname)
    if not success then
      vim.notify('hurl: remove file failed', vim.log.levels.WARN)
    else
      utils.log_info('hurl: remove file success ' .. fname)
    end
  end, timeout)
end

local function find_http_verb(line, current_line_number)
  if not line then
    return nil
  end

  -- TODO: Support other HTTP verbs
  local verb_start, verb_end = line:find('GET')
  if not verb_start then
    verb_start, verb_end = line:find('POST')
  end

  if verb_start then
    return { line_number = current_line_number, start_pos = verb_start, end_pos = verb_end }
  else
    return nil
  end
end

local function find_http_verb_positions_in_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local total_lines = vim.api.nvim_buf_line_count(buf)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line_number = cursor[1]

  local total = 0
  local current = 0

  for i = 1, total_lines do
    local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    local result = find_http_verb(line)
    if result ~= nil then
      total = total + 1
      if i == current_line_number then
        current = total
      end
    end
  end

  return {
    total = total,
    current = current,
  }
end

function M.setup()
  utils.create_cmd('HurlRunner', function(opts)
    if opts.range ~= 0 then
      run_selection(opts.fargs)
    else
      run_current_file(opts.fargs)
    end
  end, { nargs = '*', range = true })

  utils.create_cmd('HurlRunnerAt', function(opts)
    local result = find_http_verb_positions_in_buffer()
    if result.current > 0 then
      opts.fargs = opts.fargs or {}
      opts.fargs = vim.list_extend(opts.fargs, { '--to-entry', result.current })
      run_current_file(opts.fargs)
    else
      vim.notify('No GET/POST found in the current line')
    end
  end, { nargs = '*', range = true })
end

-- Add unit tests for the `request` function
function M.test_request()
  -- Test successful request
  local opts = { 'http://example.com' }
  request(opts, function(response)
    assert(response.status == 200, 'Expected status code 200')
    assert(response.headers['content-type'] == 'text/html', 'Expected content-type to be text/html')
    assert(response.body:find('<html>') ~= nil, 'Expected response body to contain <html>')
  end)

  -- Test failed request
  local opts = { 'http://nonexistent' }
  request(opts, function(response)
    assert(response.status == 404, 'Expected status code 404')
    assert(response.headers['content-type'] == 'text/plain', 'Expected content-type to be text/plain')
    assert(response.body == 'Not Found', 'Expected response body to be "Not Found"')
  end)

  -- Test JSON response
  local opts = { 'http://api.example.com/data' }
  request(opts, function(response)
    assert(response.status == 200, 'Expected status code 200')
    assert(response.headers['content-type'] == 'application/json', 'Expected content-type to be application/json')
    local json = vim.fn.json_decode(response.body)
    assert(json ~= nil, 'Failed to decode JSON response')
    assert(json.name == 'John Doe', 'Expected name to be "John Doe"')
  end)

  -- Test HTML response
  local opts = { 'http://example.com' }
  request(opts, function(response)
    assert(response.status == 200, 'Expected status code 200')
    assert(response.headers['content-type'] == 'text/html', 'Expected content-type to be text/html')
    assert(response.body:find('<html>') ~= nil, 'Expected response body to contain <html>')
  end)
end

return M

function M.setup()
  util.create_cmd('HurlRunner', function(opts)
    if opts.range ~= 0 then
      run_selection(opts.fargs)
    else
      run_current_file(opts.fargs)
    end
  end, { nargs = '*', range = true })
end

return M
