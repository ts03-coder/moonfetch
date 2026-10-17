-- moonfetch: non-blocking HTTP for MoonLoader (Rust DLL via LuaJIT FFI)
--
--   local http = require 'moonfetch'
--   -- inside main() or lua_thread: does not freeze the game
--   local r, err = http.get('https://api.ipify.org?format=json')
--   if r then print(r.status, r.body, r:json().ip) else print(err) end
--   -- from event handlers (onReceiveRpc, sampRegisterChatCommand callbacks, ...):
--   http.async('POST', url, { json = { a = 1 } }, function(r, err) ... end)

local ffi = require 'ffi'

pcall(ffi.cdef, [[
uint32_t moonfetch_request(const char *method, const char *url, const char *headers,
                       const char *body, size_t body_len, uint32_t timeout_ms);
int moonfetch_poll(uint32_t id);
int moonfetch_wait(uint32_t id, uint32_t timeout_ms);
int moonfetch_status(uint32_t id);
const char *moonfetch_error(uint32_t id);
const char *moonfetch_headers(uint32_t id);
const char *moonfetch_url(uint32_t id);
const char *moonfetch_body(uint32_t id, size_t *len);
void moonfetch_free(uint32_t id);
const char *moonfetch_version(void);
]])

local function load_lib()
  local candidates = {}
  if getWorkingDirectory then
    candidates[#candidates + 1] = getWorkingDirectory() .. '\\lib\\moonfetch.dll'
  end
  candidates[#candidates + 1] = 'moonfetch'
  local errs = {}
  for _, path in ipairs(candidates) do
    local ok, lib = pcall(ffi.load, path)
    if ok then return lib end
    errs[#errs + 1] = tostring(lib)
  end
  error('moonfetch: cannot load moonfetch.dll: ' .. table.concat(errs, '; '), 3)
end

local C = load_lib()

local M = {
  version = ffi.string(C.moonfetch_version()),
  default_timeout = 30000, -- ms, whole request
}

---------------------------------------------------------------- json

local json_encode, json_decode
if encodeJson and decodeJson then -- MoonLoader built-ins
  json_encode, json_decode = encodeJson, decodeJson
else
  local ok, cjson = pcall(require, 'cjson')
  if not ok then ok, cjson = pcall(require, 'dkjson') end
  if ok then json_encode, json_decode = cjson.encode, cjson.decode end
end

---------------------------------------------------------------- helpers

function M.urlencode(s)
  return (tostring(s):gsub('[^%w%-%._~]', function(c)
    return string.format('%%%02X', c:byte())
  end))
end

function M.encode_query(t)
  local parts = {}
  for k, v in pairs(t) do
    parts[#parts + 1] = M.urlencode(k) .. '=' .. M.urlencode(v)
  end
  return table.concat(parts, '&')
end

local function parse_headers(raw)
  local h = {}
  for name, value in raw:gmatch('([^:\n]+): ([^\n]*)') do
    h[name] = h[name] and (h[name] .. ', ' .. value) or value
  end
  return h
end

local Response = {}
Response.__index = Response

function Response:json()
  assert(json_decode, 'moonfetch: no JSON library available')
  return json_decode(self.body)
end

local function collect(id)
  local err = C.moonfetch_error(id)
  if err ~= nil then
    local msg = ffi.string(err)
    C.moonfetch_free(id)
    return nil, msg
  end
  local len = ffi.new('size_t[1]')
  local p = C.moonfetch_body(id, len)
  local status = C.moonfetch_status(id)
  local resp = setmetatable({
    status = status,
    ok = status >= 200 and status < 300,
    body = p ~= nil and ffi.string(p, len[0]) or '',
    headers = parse_headers(ffi.string(C.moonfetch_headers(id))),
    url = ffi.string(C.moonfetch_url(id)),
  }, Response)
  C.moonfetch_free(id)
  return resp
end

local function can_yield()
  return coroutine.running() ~= nil and type(wait) == 'function'
end

---------------------------------------------------------------- api

--- opts:
---   headers = { ['X-Key'] = 'v' }
---   body    = 'raw string'
---   json    = table              -> body + Content-Type: application/json
---   form    = table              -> body + Content-Type: application/x-www-form-urlencoded
---   query   = table              -> appended to url
---   timeout = ms (0 = none)
---   block   = true               -> block the game thread instead of wait(0) polling
--- Returns response {status, ok, body, headers, url, :json()} or nil, error.
--- HTTP 4xx/5xx are responses (check r.ok), only network errors return nil.
function M.request(method, url, opts)
  opts = opts or {}
  local headers = {}
  for k, v in pairs(opts.headers or {}) do headers[k] = v end

  local body = opts.body
  if opts.json ~= nil then
    assert(json_encode, 'moonfetch: no JSON library available')
    body = json_encode(opts.json)
    headers['Content-Type'] = headers['Content-Type'] or 'application/json'
  elseif opts.form then
    body = M.encode_query(opts.form)
    headers['Content-Type'] = headers['Content-Type'] or 'application/x-www-form-urlencoded'
  end
  if opts.query then
    url = url .. (url:find('?', 1, true) and '&' or '?') .. M.encode_query(opts.query)
  end

  local lines = {}
  for k, v in pairs(headers) do lines[#lines + 1] = k .. ': ' .. tostring(v) end
  local hstr = #lines > 0 and table.concat(lines, '\n') or nil

  local id = C.moonfetch_request(method, url, hstr, body, body and #body or 0,
                             opts.timeout or M.default_timeout)
  if id == 0 then return nil, 'moonfetch: invalid arguments' end

  if not opts.block and can_yield() then
    while C.moonfetch_poll(id) == 0 do wait(0) end
  else
    C.moonfetch_wait(id, 0)
  end
  return collect(id)
end

--- Runs the request in a new lua_thread and calls callback(response, err).
--- Safe to call from any MoonLoader event handler.
function M.async(method, url, opts, callback)
  if type(opts) == 'function' then opts, callback = nil, opts end
  return lua_thread.create(function()
    local r, err = M.request(method, url, opts)
    if callback then callback(r, err) end
  end)
end

function M.get(url, opts) return M.request('GET', url, opts) end
function M.head(url, opts) return M.request('HEAD', url, opts) end
function M.delete(url, opts) return M.request('DELETE', url, opts) end

local function with_body(method)
  return function(url, body, opts)
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    if type(body) == 'table' then o.json = body else o.body = body end
    return M.request(method, url, o)
  end
end
M.post, M.put, M.patch = with_body('POST'), with_body('PUT'), with_body('PATCH')

return M
