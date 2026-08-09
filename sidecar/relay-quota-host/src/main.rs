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
    let mut arguments = env::args_os();
    let _program = arguments.next();
    let mode = arguments.next();
    let has_more_arguments = arguments.next().is_some();

    match (mode.as_deref(), has_more_arguments) {
        (None, false) => {
            let stdin = io::stdin();
            let stdout = io::stdout();
            if relay_quota_host::run_jsonl(stdin.lock(), stdout.lock()).is_ok() {
                0
            } else {
                1
            }
        }
        (Some(mode), false) if mode == OsStr::new("--self-test") => {
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
        (Some(mode), false) if mode == OsStr::new("--request-worker") => {
            relay_quota_host::script::run_request_worker_mode()
        }
        (Some(mode), false) if mode == OsStr::new("--extractor-worker") => {
            relay_quota_host::script::run_extractor_worker_mode()
        }
        _ => 2,
    }
}
