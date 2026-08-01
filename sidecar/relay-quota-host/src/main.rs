use std::{env, ffi::OsStr, process};

fn main() {
    let mut arguments = env::args_os();
    let _program = arguments.next();
    let worker_mode = arguments.next();
    let has_more_arguments = arguments.next().is_some();

    let exit_code = match (worker_mode.as_deref(), has_more_arguments) {
        (Some(mode), false) if mode == OsStr::new("--request-worker") => {
            relay_quota_host::script::run_request_worker_mode()
        }
        (Some(mode), false) if mode == OsStr::new("--extractor-worker") => {
            relay_quota_host::script::run_extractor_worker_mode()
        }
        _ => 2,
    };
    process::exit(exit_code);
}
