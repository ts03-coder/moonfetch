-- moonfetch vs copas.http: correctness + performance + frame-stall comparison.
--
-- In game:   copy this file into moonloader/, start `python server.py`, type /httptest
--            (/httptest noremote — skip internet tests). Report: moonloader/moonfetch_vs_copas.txt
-- Outside:   see run.sh (runs the same file on the game's lua51.dll with emulated 60 fps frames)
if script_name then script_name('moonfetch_vs_copas') end

local ffi = require 'ffi'
local moonfetch = require 'moonfetch'
local copas = require 'copas'
local http = require 'copas.http'
local ltn12 = require 'ltn12'
local json_decode = decodeJson or require('cjson').decode

pcall(ffi.cdef, [[
int QueryPerformanceCounter(int64_t *c);
int QueryPerformanceFrequency(int64_t *f);
]])
local qpc = ffi.new('int64_t[1]')
ffi.C.QueryPerformanceFrequency(qpc)
local FREQ = tonumber(qpc[0])
local function now()
  ffi.C.QueryPerformanceCounter(qpc)
  return tonumber(qpc[0]) * 1000 / FREQ
end

local CFG = {
  base = os.getenv('MOONFETCH_TEST_BASE') or 'http://127.0.0.1:8765',
  https_url = 'https://www.google.com/',     -- works without SNI
  https_sni_url = 'https://example.com/',  -- CDN host, needs SNI
  report = getWorkingDirectory() .. '\\moonfetch_vs_copas.txt',
  hitch_ms = 50,
}
local B = CFG.base

------------------------------------------------------------------ copas variant (as given)

function httpRequest(request, body, handler) -- copas.http
    -- start polling task
    if not copas.running then
        copas.running = true
        lua_thread.create(function()
            wait(0)
            while not copas.finished() do
                local ok, err = copas.step(0)
                if ok == nil then error(err) end
                wait(0)
            end
            copas.running = false
        end)
    end
    -- do request
    if handler then
        return copas.addthread(function(r, b, h)
            copas.setErrorHandler(function(err) h(nil, err) end)
            h(http.request(r, b))
        end, request, body, handler)
    else
        local results
        local thread = copas.addthread(function(r, b)
            copas.setErrorHandler(function(err) results = {nil, err} end)
            results = table.pack(http.request(r, b))
        end, request, body)
        while coroutine.status(thread) ~= 'dead' do wait(0) end
        return table.unpack(results)
    end
end

------------------------------------------------------------------ clients, same interface
-- request(method, url, {headers, body, timeout}) -> {status, body, headers} | nil, err

local clients = {
  {
    name = 'moonfetch',
    request = function(method, url, o)
      o = o or {}
      local r, err = moonfetch.request(method, url, { headers = o.headers, body = o.body, timeout = o.timeout })
      if not r then return nil, err end
      return { status = r.status, body = r.body, headers = r.headers }
    end,
  },
  {
    name = 'copas',
    request = function(method, url, o)
      o = o or {}
      local chunks, hdrs = {}, {}
      for k, v in pairs(o.headers or {}) do hdrs[k:lower()] = v end
      local req = { url = url, method = method, headers = hdrs, sink = ltn12.sink.table(chunks) }
      if o.body then
        req.source = ltn12.source.string(o.body)
        hdrs['content-length'] = tostring(#o.body)
      end
      if o.timeout then http.TIMEOUT = o.timeout / 1000 end
      local ok, code, headers = httpRequest(req)
      http.TIMEOUT = 60
      if not ok or type(code) ~= 'number' then return nil, tostring(code) end
      return { status = code, body = table.concat(chunks), headers = headers or {} }
    end,
  },
}

------------------------------------------------------------------ helpers

local BLOCK = {}
for i = 0, 250 do BLOCK[#BLOCK + 1] = string.char(i) end
BLOCK = table.concat(BLOCK)
local function pattern(n) return string.rep(BLOCK, math.floor(n / 251) + 1):sub(1, n) end

local RANDOM_256K
do
  math.randomseed(42)
  local t = {}
  for i = 1, 256 * 1024 do t[i] = string.char(math.random(0, 255)) end
  RANDOM_256K = table.concat(t)
end

local function check(cond, msg, ...)
  if not cond then error(string.format(msg, ...), 0) end
end

local function must(r, err)
  check(r, 'error: %s', tostring(err))
  return r
end

local function json(r)
  local ok, j = pcall(json_decode, r.body)
  check(ok and type(j) == 'table', 'body is not JSON (%d bytes)', #r.body)
  return j
end

local function parallel(n, fn)
  local done, errs = 0, {}
  for i = 1, n do
    lua_thread.create(function()
      local ok, e = pcall(fn, i)
      if not ok then errs[#errs + 1] = tostring(e) end
      done = done + 1
    end)
  end
  while done < n do wait(0) end
  check(#errs == 0, '%d/%d failed: %s', #errs, n, errs[1])
end

------------------------------------------------------------------ frame monitor
-- Every wait(0) resumes once per frame, so the gap between resumes is the frame time.
-- Anything that blocks the game thread (DNS, TLS handshake, big string work) shows up here.

local mon = { active = false }
local function mon_start() mon.active, mon.n, mon.max, mon.hitch = true, 0, 0, 0 end
local function mon_stop()
  wait(0); wait(0) -- let the monitor record the last frame
  mon.active = false
  return mon
end
local function monitor()
  local last = now()
  while true do
    wait(0)
    local t = now()
    if mon.active then
      local g = t - last
      mon.n = mon.n + 1
      if g > mon.max then mon.max = g end
      if g > CFG.hitch_ms then mon.hitch = mon.hitch + 1 end
    end
    last = t
  end
end

------------------------------------------------------------------ correctness

local TESTS = {
  { 'GET + query (UTF-8)', function(c)
    local r = must(c.request('GET', B .. '/get?x=1&y=%D0%AF'))
    check(r.status == 200, 'status %s', r.status)
    local j = json(r)
    check(j.args.x == '1' and j.args.y == 'Я', 'args %s/%s', j.args.x, j.args.y)
  end },
  { 'custom request headers', function(c)
    local j = json(must(c.request('GET', B .. '/headers', { headers = { ['X-Test'] = 'abc', ['User-Agent'] = 'bench/1' } })))
    check(j.headers['x-test'] == 'abc', 'x-test=%s', j.headers['x-test'])
    check(j.headers['user-agent'] == 'bench/1', 'user-agent=%s', j.headers['user-agent'])
  end },
  { 'response headers', function(c)
    local r = must(c.request('GET', B .. '/get'))
    check(r.headers['content-type'] == 'application/json', 'content-type=%s', r.headers['content-type'])
  end },
  { 'POST 256KB binary echo', function(c)
    local r = must(c.request('POST', B .. '/echo', { body = RANDOM_256K }))
    check(#r.body == #RANDOM_256K, 'len %d', #r.body)
    check(r.body == RANDOM_256K, 'body differs')
  end },
  { 'PUT / DELETE / PATCH', function(c)
    for _, m in ipairs({ 'PUT', 'DELETE', 'PATCH' }) do
      local j = json(must(c.request(m, B .. '/anything', { body = m ~= 'DELETE' and 'x' or nil })))
      check(j.method == m, 'method %s', j.method)
    end
  end },
  { 'HTTP 404 is a response', function(c)
    local r = must(c.request('GET', B .. '/status/404'))
    check(r.status == 404, 'status %s', r.status)
  end },
  { 'HTTP 500 is a response', function(c)
    local r = must(c.request('GET', B .. '/status/500'))
    check(r.status == 500, 'status %s', r.status)
  end },
  { 'follows 302 redirect', function(c)
    local r = must(c.request('GET', B .. '/redirect'))
    check(r.status == 200, 'status %s', r.status)
    check(json(r).args.redirected == '1', 'not redirected')
  end },
  { 'gzip (server forces it)', function(c)
    check(json(must(c.request('GET', B .. '/gzip'))).gzipped == true, 'not gzipped json')
  end },
  { 'download 1MB integrity', function(c)
    local r = must(c.request('GET', B .. '/bytes/1048576'))
    check(r.body == pattern(1048576), 'body differs (len %d)', #r.body)
  end },
  { 'UTF-8 text body', function(c)
    check(must(c.request('GET', B .. '/utf8')).body == 'Привет, мир! ✓', 'text differs')
  end },
  { 'timeout 1s on 3s delay', function(c)
    local t = now()
    local r, err = c.request('GET', B .. '/delay/3000', { timeout = 1000 })
    local dt = now() - t
    check(not r, 'got response %s', r and r.status)
    check(dt < 2500, 'took %d ms', dt)
  end },
  { 'connection refused', function(c)
    local r, err = c.request('GET', 'http://127.0.0.1:1/')
    check(not r and err, 'no error')
  end },
  { 'DNS failure', function(c)
    local r, err = c.request('GET', 'http://nonexistent.invalid/')
    check(not r and err, 'no error')
  end },
  { 'HTTPS (google.com)', function(c)
    local r = must(c.request('GET', CFG.https_url))
    check(r.status == 200 and #r.body > 0, 'status %s', r.status)
  end, remote = true },
  { 'HTTPS + SNI (example.com)', function(c)
    local r = must(c.request('GET', CFG.https_sni_url))
    check(r.status == 200 and #r.body > 0, 'status %s', r.status)
  end, remote = true },
}

------------------------------------------------------------------ performance

local MB = 1024 * 1024
local PERF = {
  { 'seq 50x GET', function(c)
    for _ = 1, 50 do check(must(c.request('GET', B .. '/get')).status == 200, 'bad status') end
  end, rate = function(ms) return string.format('%.1f ms/req', ms / 50) end },
  { 'parallel 50x 200ms delay', function(c)
    parallel(50, function() check(must(c.request('GET', B .. '/delay/200')).status == 200, 'bad status') end)
  end, rate = function(ms) return string.format('%.0f%% of ideal', 200 / ms * 100) end },
  { 'download 20MB', function(c)
    check(#must(c.request('GET', B .. '/bytes/' .. 20 * MB)).body == 20 * MB, 'short body')
  end, rate = function(ms) return string.format('%.0f MB/s', 20 / (ms / 1000)) end },
  { 'upload 5MB', function(c)
    local body = pattern(5 * MB)
    check(json(must(c.request('POST', B .. '/anything', { body = body }))).len == 5 * MB, 'len differs')
  end, rate = function(ms) return string.format('%.0f MB/s', 5 / (ms / 1000)) end },
  { 'parallel 10x HTTPS', function(c)
    parallel(10, function() check(must(c.request('GET', CFG.https_url)).status == 200, 'bad status') end)
  end, rate = function(ms) return string.format('%.0f ms/batch', ms) end, remote = true },
  { 'seq 5x DNS failure', function(c)
    for i = 1, 5 do check(not c.request('GET', 'http://nonexistent' .. i .. '.invalid/'), 'no error') end
  end, rate = function(ms) return string.format('%.0f ms/req', ms / 5) end },
}

------------------------------------------------------------------ runner

local out = {}
local function log(fmt, ...)
  local s = select('#', ...) > 0 and string.format(fmt, ...) or fmt
  out[#out + 1] = s
  print(s)
end

local function measure(fn, c)
  collectgarbage()
  wait(0); wait(0) -- keep the GC pause out of the measured frames
  mon_start()
  local t = now()
  local ok, err = pcall(fn, c)
  local ms = now() - t
  local f = mon_stop()
  return { ok = ok, err = err, ms = ms, fmax = f.max, hitch = f.hitch }
end

local function row(name, a, b) log('%-26s | %-30s | %-30s', name, a, b) end

local function run_all(arg)
  local remote = not (arg and tostring(arg):find('noremote'))
  out = {}
  local mt = lua_thread.create(monitor)

  local probe = moonfetch.request('GET', B .. '/get', { timeout = 2000 })
  if not probe then
    log('test server %s is not reachable - start `python server.py` first', B)
    mt:terminate()
    return false
  end

  log('moonfetch %s vs %s + %s, %s, server %s', moonfetch.version, copas._VERSION, require('socket')._VERSION,
      jit.version, B)
  local idle = measure(function() wait(2000) end)
  log('baseline: idle worst frame %.0f ms, %d hitches (noise floor)', idle.fmax, idle.hitch)
  log('cell: result, time, worst frame; hitch = frame > %d ms', CFG.hitch_ms)
  log('')
  row('CORRECTNESS', 'moonfetch', 'copas')
  log(string.rep('-', 92))
  local fails, score = {}, { 0, 0 }
  for _, t in ipairs(TESTS) do
    if remote or not t.remote then
      local cells = {}
      for i, c in ipairs(clients) do
        local r = measure(t[2], c)
        if r.ok then score[i] = score[i] + 1 else fails[#fails + 1] = string.format('  %s / %s: %s', c.name, t[1], tostring(r.err)) end
        cells[i] = string.format('%s %6.0fms  frame %4.0fms', r.ok and 'PASS' or 'FAIL', r.ms, r.fmax)
      end
      row(t[1], cells[1], cells[2])
    end
  end
  row('passed', tostring(score[1]), tostring(score[2]))
  if #fails > 0 then log(''); log('failures:'); for _, f in ipairs(fails) do log(f) end end

  log('')
  row('PERFORMANCE', 'moonfetch', 'copas')
  log(string.rep('-', 92))
  for _, p in ipairs(PERF) do
    if remote or not p.remote then
      local cells = {}
      for i, c in ipairs(clients) do
        local r = measure(p[2], c)
        cells[i] = r.ok
          and string.format('%6.0fms %-13s', r.ms, p.rate(r.ms))
          or ('FAIL ' .. tostring(r.err):sub(1, 25))
        cells[i + 2] = string.format('worst %4.0fms, %d hitches', r.fmax, r.hitch)
      end
      row(p[1], cells[1], cells[2])
      row('', cells[3], cells[4])
    end
  end

  mt:terminate()
  local f = io.open(CFG.report, 'w')
  if f then f:write(table.concat(out, '\n'), '\n'); f:close() end
  return true
end

function main()
  if HARNESS or not sampRegisterChatCommand then
    run_all(os.getenv('MOONFETCH_TEST_ARGS'))
    return
  end
  while not isSampAvailable() do wait(100) end
  local busy = false
  sampRegisterChatCommand('httptest', function(arg)
    if busy then return end
    busy = true
    sampAddChatMessage('[moonfetch_vs_copas] running, the game may stutter during copas tests...', -1)
    lua_thread.create(function()
      run_all(arg)
      busy = false
      sampAddChatMessage('[moonfetch_vs_copas] done: ' .. CFG.report, -1)
    end)
  end)
  wait(-1)
end
