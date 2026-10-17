//! moonfetch — non-blocking HTTP client for MoonLoader.
//!
//! Every request runs on its own worker thread; Lua gets a numeric id back
//! immediately and polls it from a lua_thread (`while moonfetch_poll(id) == 0 do wait(0) end`),
//! so the game never freezes. Results live in a global table until `moonfetch_free`.
//!
//! Pointers returned by `moonfetch_error` / `moonfetch_headers` / `moonfetch_url` / `moonfetch_body`
//! stay valid until `moonfetch_free(id)` is called for that id.

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::io::Read;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, Once, OnceLock};
use std::time::{Duration, Instant};

const MAX_BODY: u64 = 64 * 1024 * 1024;

struct Outcome {
    status: i32,
    url: CString,
    headers: CString,
    body: Vec<u8>,
    error: Option<CString>,
}

#[derive(Default)]
struct Slot {
    out: OnceLock<Outcome>,
    lock: Mutex<()>,
    cv: Condvar,
}

impl Slot {
    fn finish(&self, out: Outcome) {
        let _ = self.out.set(out);
        let _g = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        self.cv.notify_all();
    }
}

struct Req {
    method: String,
    url: String,
    headers: Vec<(String, String)>,
    body: Option<Vec<u8>>,
    timeout_ms: u32,
}

static NEXT_ID: AtomicU32 = AtomicU32::new(1);
static SLOTS: OnceLock<Mutex<HashMap<u32, Arc<Slot>>>> = OnceLock::new();
static AGENT: OnceLock<Result<ureq::Agent, String>> = OnceLock::new();

fn slots() -> MutexGuard<'static, HashMap<u32, Arc<Slot>>> {
    SLOTS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

fn slot(id: u32) -> Option<Arc<Slot>> {
    slots().get(&id).cloned()
}

fn agent() -> Result<&'static ureq::Agent, String> {
    AGENT
        .get_or_init(|| {
            let tls = native_tls::TlsConnector::new().map_err(|e| format!("tls init: {e}"))?;
            Ok(ureq::AgentBuilder::new()
                .tls_connector(Arc::new(tls))
                .user_agent(concat!("moonfetch/", env!("CARGO_PKG_VERSION")))
                .timeout_connect(Duration::from_secs(10))
                .max_idle_connections_per_host(4)
                .build())
        })
        .as_ref()
        .map_err(Clone::clone)
}

fn cstring(s: impl Into<Vec<u8>>) -> CString {
    let mut v = s.into();
    v.retain(|&b| b != 0);
    CString::new(v).unwrap_or_default()
}

unsafe fn lossy(p: *const c_char) -> Option<String> {
    (!p.is_null()).then(|| CStr::from_ptr(p).to_string_lossy().into_owned())
}

fn parse_headers(raw: &str) -> Vec<(String, String)> {
    raw.lines()
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim().to_owned(), v.trim().to_owned()))
        .filter(|(k, _)| !k.is_empty())
        .collect()
}

fn perform(req: Req) -> Result<Outcome, String> {
    let agent = agent()?;
    let mut r = agent.request(&req.method, &req.url);
    if req.timeout_ms > 0 {
        r = r.timeout(Duration::from_millis(req.timeout_ms.into()));
    }
    for (k, v) in &req.headers {
        r = r.set(k, v);
    }
    let res = match req.body {
        Some(b) => r.send_bytes(&b),
        None => r.call(),
    };
    // 4xx/5xx are still valid responses for the script
    let resp = match res {
        Ok(r) | Err(ureq::Error::Status(_, r)) => r,
        Err(e) => return Err(e.to_string()),
    };

    let status = resp.status() as i32;
    let url = resp.get_url().to_owned();
    let mut seen = Vec::<String>::new();
    let mut headers = String::new();
    for name in resp.headers_names() {
        let lower = name.to_ascii_lowercase();
        if seen.contains(&lower) {
            continue;
        }
        for v in resp.all(&lower) {
            headers.push_str(&lower);
            headers.push_str(": ");
            headers.push_str(v);
            headers.push('\n');
        }
        seen.push(lower);
    }

    let mut body = Vec::new();
    resp.into_reader()
        .take(MAX_BODY + 1)
        .read_to_end(&mut body)
        .map_err(|e| format!("read body: {e}"))?;
    if body.len() as u64 > MAX_BODY {
        return Err(format!("response body exceeds {} MiB", MAX_BODY / 1024 / 1024));
    }

    Ok(Outcome { status, url: cstring(url), headers: cstring(headers), body, error: None })
}

fn failed(msg: String) -> Outcome {
    Outcome {
        status: 0,
        url: CString::default(),
        headers: CString::default(),
        body: Vec::new(),
        error: Some(cstring(msg)),
    }
}

/// LuaJIT's ffi.load handle is FreeLibrary'd on GC / script reload. Worker threads
/// may still be running our code at that point, so pin the DLL for the process lifetime.
fn pin_self() {
    #[link(name = "kernel32")]
    extern "system" {
        fn GetModuleHandleExW(flags: u32, name: *const u16, module: *mut *mut c_void) -> i32;
    }
    const FROM_ADDRESS: u32 = 0x4;
    const PIN: u32 = 0x1;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| unsafe {
        let mut h = ptr::null_mut();
        GetModuleHandleExW(FROM_ADDRESS | PIN, pin_self as *const () as *const u16, &mut h);
    });
}

/// Starts a request. `headers` is "Name: value\n"-separated (may be NULL),
/// `body` may be NULL for no body. `timeout_ms` = 0 disables the overall timeout.
/// Returns a request id, or 0 if method/url is NULL.
#[no_mangle]
pub unsafe extern "C" fn moonfetch_request(
    method: *const c_char,
    url: *const c_char,
    headers: *const c_char,
    body: *const c_char,
    body_len: usize,
    timeout_ms: u32,
) -> u32 {
    pin_self();
    let (Some(method), Some(url)) = (lossy(method), lossy(url)) else {
        return 0;
    };
    let req = Req {
        method: method.to_ascii_uppercase(),
        url,
        headers: lossy(headers).map(|h| parse_headers(&h)).unwrap_or_default(),
        body: (!body.is_null()).then(|| std::slice::from_raw_parts(body as *const u8, body_len).to_vec()),
        timeout_ms,
    };

    let mut id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    if id == 0 {
        id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    }
    let s = Arc::new(Slot::default());
    slots().insert(id, s.clone());

    let worker = s.clone();
    let spawned = std::thread::Builder::new()
        .name(format!("moonfetch-{id}"))
        .stack_size(512 * 1024)
        .spawn(move || {
            let out = catch_unwind(AssertUnwindSafe(|| perform(req)))
                .unwrap_or_else(|_| Err("internal panic".into()))
                .unwrap_or_else(failed);
            worker.finish(out);
        });
    if let Err(e) = spawned {
        s.finish(failed(format!("cannot spawn thread: {e}")));
    }
    id
}

/// 1 = finished, 0 = pending, -1 = unknown id.
#[no_mangle]
pub extern "C" fn moonfetch_poll(id: u32) -> i32 {
    match slot(id) {
        Some(s) => s.out.get().is_some() as i32,
        None => -1,
    }
}

/// Blocks the calling thread. `timeout_ms` = 0 waits forever.
/// 1 = finished, 0 = timed out, -1 = unknown id.
#[no_mangle]
pub extern "C" fn moonfetch_wait(id: u32, timeout_ms: u32) -> i32 {
    let Some(s) = slot(id) else { return -1 };
    let deadline = (timeout_ms > 0).then(|| Instant::now() + Duration::from_millis(timeout_ms.into()));
    let mut g = s.lock.lock().unwrap_or_else(|e| e.into_inner());
    loop {
        if s.out.get().is_some() {
            return 1;
        }
        g = match deadline {
            None => s.cv.wait(g).unwrap_or_else(|e| e.into_inner()),
            Some(d) => {
                let left = d.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    return 0;
                }
                s.cv.wait_timeout(g, left).unwrap_or_else(|e| e.into_inner()).0
            }
        };
    }
}

fn with_out<T>(id: u32, default: T, f: impl FnOnce(&Outcome) -> T) -> T {
    slot(id).and_then(|s| s.out.get().map(f)).unwrap_or(default)
}

/// HTTP status; 0 on transport error, -1 if unknown or still pending.
#[no_mangle]
pub extern "C" fn moonfetch_status(id: u32) -> i32 {
    with_out(id, -1, |o| o.status)
}

/// Transport error message, or NULL if the request got an HTTP response.
#[no_mangle]
pub extern "C" fn moonfetch_error(id: u32) -> *const c_char {
    match slot(id) {
        None => c"unknown request id".as_ptr(),
        Some(s) => match s.out.get() {
            None => c"request is still pending".as_ptr(),
            Some(o) => o.error.as_ref().map_or(ptr::null(), |e| e.as_ptr()),
        },
    }
}

/// Response headers as "name: value\n" lines (names lowercased).
#[no_mangle]
pub extern "C" fn moonfetch_headers(id: u32) -> *const c_char {
    with_out(id, c"".as_ptr(), |o| o.headers.as_ptr())
}

/// Final URL after redirects.
#[no_mangle]
pub extern "C" fn moonfetch_url(id: u32) -> *const c_char {
    with_out(id, c"".as_ptr(), |o| o.url.as_ptr())
}

/// Raw response body bytes; length is written to `*len`.
#[no_mangle]
pub unsafe extern "C" fn moonfetch_body(id: u32, len: *mut usize) -> *const c_char {
    let (p, n) = with_out(id, (ptr::null(), 0), |o| (o.body.as_ptr() as *const c_char, o.body.len()));
    if !len.is_null() {
        *len = n;
    }
    p
}

/// Releases the result. Safe on pending requests: the result is discarded when it arrives.
#[no_mangle]
pub extern "C" fn moonfetch_free(id: u32) {
    slots().remove(&id);
}

#[no_mangle]
pub extern "C" fn moonfetch_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}
