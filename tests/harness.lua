-- Emulates the bits of MoonLoader the test needs (lua_thread, wait, getWorkingDirectory)
-- with a 60 fps frame loop: a frame lasts max(16.7 ms, time spent resuming script threads),
-- which is how a blocking call inside a script stalls the real game.
--   ML_DIR=<moonloader dir> luahost.exe <lua51.dll> harness.lua
local ffi = require 'ffi'
ffi.cdef [[
void Sleep(uint32_t ms);
unsigned timeBeginPeriod(unsigned ms);
int QueryPerformanceCounter(int64_t *c);
int QueryPerformanceFrequency(int64_t *f);
]]
ffi.load('winmm').timeBeginPeriod(1)
local qpc = ffi.new('int64_t[1]')
ffi.C.QueryPerformanceFrequency(qpc)
local FREQ = tonumber(qpc[0])
local function now()
  ffi.C.QueryPerformanceCounter(qpc)
  return tonumber(qpc[0]) * 1000 / FREQ
end

local ML = assert(os.getenv('ML_DIR'), 'set ML_DIR')
package.path = ML .. '\\lib\\?.lua;' .. ML .. '\\lib\\?\\init.lua;' .. package.path
package.cpath = ML .. '\\lib\\?.dll;' .. package.cpath
function getWorkingDirectory() return ML end
HARNESS = true

local FRAME = 1000 / 60
local threads = {}
local Thread = {}
Thread.__index = Thread
function Thread:status() return self.dead and 'dead' or coroutine.status(self.co) end
function Thread:terminate() self.dead = true end

lua_thread = {}
function lua_thread.create(f, ...)
  local t = setmetatable({ co = coroutine.create(f), args = { n = select('#', ...), ... }, wake = 0 }, Thread)
  threads[#threads + 1] = t
  return t
end
function wait(ms) coroutine.yield(ms or 0) end

local here = debug.getinfo(1, 'S').source:match('^@(.*[\\/])') or ''
dofile(os.getenv('TEST_SCRIPT') or (here .. 'moonfetch_vs_copas.lua'))
local main_thread = lua_thread.create(main)

while not main_thread.dead do
  local start = now()
  local snapshot = {}
  for i, t in ipairs(threads) do snapshot[i] = t end
  for _, t in ipairs(snapshot) do
    if not t.dead and t.wake <= start then
      local ok, ms
      if t.args then
        local a = t.args
        t.args = nil
        ok, ms = coroutine.resume(t.co, unpack(a, 1, a.n))
      else
        ok, ms = coroutine.resume(t.co)
      end
      if not ok then
        print('thread error: ' .. debug.traceback(t.co, tostring(ms)))
        t.dead = true
      elseif coroutine.status(t.co) == 'dead' then
        t.dead = true
      else
        t.wake = (ms < 0) and math.huge or (ms == 0 and 0 or now() + ms)
      end
    end
  end
  for i = #threads, 1, -1 do
    if threads[i].dead then table.remove(threads, i) end
  end
  local left = FRAME - (now() - start)
  if left >= 1 then ffi.C.Sleep(left) end
end
