#![cfg_attr(windows, windows_subsystem = "windows")]

use std::{
    env,
    ffi::OsStr,
    io::{self, Write},
    panic::{catch_unwind, AssertUnwindSafe},
    process,
};

fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let exit_code = catch_unwind(AssertUnwindSafe(run)).map_or(1, std::convert::identity);
    process::exit(exit_code);
}

fn run() -> i32 {
    let arguments: Vec<_> = env::args_os().skip(1).collect();
    match arguments.as_slice() {
        [] => {
            let stdin = io::stdin();
            let stdout = io::stdout();
            if relay_quota_host::run_jsonl(stdin.lock(), stdout.lock()).is_ok() {
                0
            } else {
                1
            }
        }
        [mode] if mode == OsStr::new("--self-test") => write_self_test(),
        [mode] if mode == OsStr::new("--request-worker") => {
            relay_quota_host::script::run_request_worker_mode()
        }
        [mode] if mode == OsStr::new("--extractor-worker") => {
            relay_quota_host::script::run_extractor_worker_mode()
        }
        [mode, path] if mode == OsStr::new("--inspect-cc-switch") => {
            relay_quota_host::cc_switch::run_inspector_mode(std::path::Path::new(path))
        }
        _ => 2,
    }
}

fn write_self_test() -> i32 {
    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    if stdout
        .write_all(b"relay-quota-host: ok\n")
        .and_then(|()| stdout.flush())
        .is_ok()
    {
        0
    } else {
        1
    }
}
