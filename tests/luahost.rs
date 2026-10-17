// Minimal 32-bit host: runs a Lua file on the game's own lua51.dll (LuaJIT 2.1.0-beta3),
// so libs from moonloader/lib (socket, ssl, ...) load exactly like in MoonLoader.
//   rustc --target i686-pc-windows-msvc -O luahost.rs
//   luahost.exe <path\to\lua51.dll> <script.lua>
use std::ffi::{c_char, c_int, c_void, CStr, CString};

#[link(name = "kernel32")]
extern "system" {
    fn LoadLibraryA(name: *const c_char) -> *mut c_void;
    fn GetProcAddress(h: *mut c_void, name: *const c_char) -> *mut c_void;
}

type L = *mut c_void;

unsafe fn sym<T>(h: *mut c_void, name: &str) -> T {
    let n = CString::new(name).unwrap();
    let p = GetProcAddress(h, n.as_ptr());
    assert!(!p.is_null(), "missing export {name}");
    std::mem::transmute_copy(&p)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: luahost <lua51.dll> <script.lua>");
        std::process::exit(2);
    }
    unsafe {
        let dll = CString::new(args[1].as_str()).unwrap();
        let h = LoadLibraryA(dll.as_ptr());
        assert!(!h.is_null(), "cannot load {}", args[1]);
        let newstate: extern "C" fn() -> L = sym(h, "luaL_newstate");
        let openlibs: extern "C" fn(L) = sym(h, "luaL_openlibs");
        let loadfile: extern "C" fn(L, *const c_char) -> c_int = sym(h, "luaL_loadfile");
        let pcall: extern "C" fn(L, c_int, c_int, c_int) -> c_int = sym(h, "lua_pcall");
        let tostr: extern "C" fn(L, c_int, *mut usize) -> *const c_char = sym(h, "lua_tolstring");

        let l = newstate();
        openlibs(l);
        let script = CString::new(args[2].as_str()).unwrap();
        if loadfile(l, script.as_ptr()) != 0 || pcall(l, 0, 0, 0) != 0 {
            let msg = tostr(l, -1, std::ptr::null_mut());
            eprintln!("lua error: {}", CStr::from_ptr(msg).to_string_lossy());
            std::process::exit(1);
        }
    }
}
