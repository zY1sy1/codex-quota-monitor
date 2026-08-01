use std::{env, ffi::OsStr, process};

fn main() {
    let mut arguments = env::args_os();
    let _program = arguments.next();
    let worker_mode = arguments.next().as_deref() == Some(OsStr::new("--request-worker"));
    let has_more_arguments = arguments.next().is_some();

    let exit_code = if worker_mode && !has_more_arguments {
        relay_quota_host::script::run_request_worker_mode()
    } else {
        2
    };
    process::exit(exit_code);
}
