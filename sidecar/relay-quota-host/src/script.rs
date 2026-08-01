#[cfg(windows)]
use std::os::windows::process::CommandExt;
use std::{
    collections::BTreeMap,
    env,
    io::{self, Read, Write},
    path::PathBuf,
    process::{Child, Command, Stdio},
    ptr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};

use rquickjs::{
    allocator::{Allocator, RustAllocator},
    qjs, Atom, Context, Ctx, Error as QuickJsError, Filter, Object, Runtime, Value,
};
use serde::{Deserialize, Serialize};

use crate::protocol::{SanitizedError, SecretSet};

const MAX_SCRIPT_BYTES: usize = 256 * 1024;
const MAX_SUBSTITUTED_SCRIPT_BYTES: usize = 1024 * 1024;
const MAX_REQUEST_BYTES: usize = 64 * 1024;
const MAX_WORKER_INPUT_BYTES: usize = 2 * 1024 * 1024;
const MAX_WORKER_OUTPUT_BYTES: usize = 128 * 1024;
const SCRIPT_MEMORY_LIMIT_BYTES: usize = 16 * 1024 * 1024;
const ALLOCATION_ALIGNMENT: usize = std::mem::align_of::<u64>();
#[cfg(target_vendor = "apple")]
const QUICKJS_ALLOCATION_OVERHEAD: usize = 0;
#[cfg(not(target_vendor = "apple"))]
const QUICKJS_ALLOCATION_OVERHEAD: usize = 8;

/// A short deadline bounds untrusted, synchronous script execution while still
/// leaving ample time for the small request-building expressions we accept.
const SCRIPT_DEADLINE: Duration = Duration::from_millis(500);
const SUPERVISOR_DEADLINE: Duration = Duration::from_millis(1000);
const SUPERVISOR_POLL_INTERVAL: Duration = Duration::from_millis(2);
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Clone, PartialEq)]
pub struct ScriptRequest {
    pub url: String,
    pub method: String,
    pub headers: BTreeMap<String, String>,
    pub body: Option<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkerInput {
    script: String,
    base_url: String,
    secrets: WorkerSecrets,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkerSecrets {
    api_key: String,
    access_token: String,
    user_id: String,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "camelCase", deny_unknown_fields)]
enum WorkerOutput {
    Request { request: WireRequest },
    Error { category: WorkerErrorCategory },
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireRequest {
    url: String,
    method: String,
    headers: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    body: Option<String>,
}

#[derive(Clone, Copy, Serialize, Deserialize)]
enum WorkerErrorCategory {
    ScriptSyntax,
    ScriptTimeout,
    ScriptMemory,
    RequestValidation,
    RequestTooLarge,
}

pub fn replace_tokens(script: &str, base_url: &str, secrets: &SecretSet) -> String {
    let replacements = token_replacements(base_url, secrets);
    let mut replaced = String::with_capacity(script.len());
    let _ = scan_replaced_tokens(script, &replacements, |piece| {
        replaced.push_str(piece);
        true
    });
    replaced
}

pub fn evaluate_request(
    script: &str,
    base_url: &str,
    secrets: &SecretSet,
) -> Result<ScriptRequest, SanitizedError> {
    let deadline = Instant::now() + SUPERVISOR_DEADLINE;
    if script.len() > MAX_SCRIPT_BYTES {
        return Err(sanitized_error(
            "RequestTooLarge",
            "Relay request script exceeds the allowed size.",
        ));
    }

    let worst_case_size = worker_input_worst_case_size(script, base_url, secrets)
        .ok_or_else(request_too_large_error)?;
    if worst_case_size > MAX_WORKER_INPUT_BYTES {
        return Err(request_too_large_error());
    }
    if Instant::now() >= deadline {
        return Err(script_timeout_error());
    }

    let input = WorkerInput {
        script: script.into(),
        base_url: base_url.into(),
        secrets: WorkerSecrets {
            api_key: secrets.api_key.clone(),
            access_token: secrets.access_token.clone(),
            user_id: secrets.user_id.clone(),
        },
    };
    let encoded = serde_json::to_vec(&input).map_err(|_| script_worker_error())?;
    if encoded.len() > MAX_WORKER_INPUT_BYTES {
        return Err(request_too_large_error());
    }
    if Instant::now() >= deadline {
        return Err(script_timeout_error());
    }

    match supervise_request_worker(encoded, deadline)? {
        WorkerOutput::Request { request } => Ok(ScriptRequest {
            url: request.url,
            method: request.method,
            headers: request.headers,
            body: request.body,
        }),
        WorkerOutput::Error { category } => Err(category.into_sanitized_error()),
    }
}

fn worker_input_worst_case_size(
    script: &str,
    base_url: &str,
    secrets: &SecretSet,
) -> Option<usize> {
    [
        script.len(),
        base_url.len(),
        secrets.api_key.len(),
        secrets.access_token.len(),
        secrets.user_id.len(),
    ]
    .into_iter()
    .try_fold(512usize, |size, field_size| {
        size.checked_add(field_size.checked_mul(6)?)
    })
}

fn supervise_request_worker(
    input: Vec<u8>,
    deadline: Instant,
) -> Result<WorkerOutput, SanitizedError> {
    let executable = request_worker_executable()?;
    if Instant::now() >= deadline {
        return Err(script_timeout_error());
    }

    let mut command = request_worker_command(executable);
    let mut child = command.spawn().map_err(|_| script_worker_error())?;
    let Some(mut stdin) = child.stdin.take() else {
        terminate_worker(&mut child);
        return Err(script_worker_error());
    };
    let Some(mut stdout) = child.stdout.take() else {
        terminate_worker(&mut child);
        return Err(script_worker_error());
    };

    let writer = match thread::Builder::new()
        .name("relay-request-worker-stdin".into())
        .spawn(move || stdin.write_all(&input))
    {
        Ok(writer) => writer,
        Err(_) => {
            terminate_worker(&mut child);
            return Err(script_worker_error());
        }
    };
    let reader = match thread::Builder::new()
        .name("relay-request-worker-stdout".into())
        .spawn(move || {
            let mut output = Vec::new();
            stdout
                .by_ref()
                .take((MAX_WORKER_OUTPUT_BYTES + 1) as u64)
                .read_to_end(&mut output)?;
            Ok::<Vec<u8>, io::Error>(output)
        }) {
        Ok(reader) => reader,
        Err(_) => {
            terminate_worker(&mut child);
            let _ = writer.join();
            return Err(script_worker_error());
        }
    };

    let status = loop {
        if Instant::now() >= deadline {
            terminate_worker(&mut child);
            let _ = writer.join();
            let _ = reader.join();
            return Err(script_timeout_error());
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {
                let remaining = deadline.saturating_duration_since(Instant::now());
                thread::sleep(SUPERVISOR_POLL_INTERVAL.min(remaining));
            }
            Err(_) => {
                terminate_worker(&mut child);
                let _ = writer.join();
                let _ = reader.join();
                return Err(script_worker_error());
            }
        }
    };

    let write_succeeded = writer.join().is_ok_and(|result| result.is_ok());
    let output = reader
        .join()
        .ok()
        .and_then(Result::ok)
        .ok_or_else(script_worker_error)?;
    if !status.success() || !write_succeeded || output.len() > MAX_WORKER_OUTPUT_BYTES {
        return Err(script_worker_error());
    }
    serde_json::from_slice(&output).map_err(|_| script_worker_error())
}

fn request_worker_command(executable: PathBuf) -> Command {
    let mut command = Command::new(executable);
    command
        .arg("--request-worker")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    command.creation_flags(request_worker_creation_flags());
    command
}

#[cfg(windows)]
const fn request_worker_creation_flags() -> u32 {
    CREATE_NO_WINDOW
}

fn request_worker_executable() -> Result<PathBuf, SanitizedError> {
    let current = env::current_exe().map_err(|_| script_worker_error())?;
    let expected_name = format!("relay-quota-host{}", env::consts::EXE_SUFFIX);
    if current.file_name().and_then(|name| name.to_str()) == Some(expected_name.as_str()) {
        return Ok(current);
    }

    if current
        .parent()
        .and_then(|parent| parent.file_name())
        .and_then(|name| name.to_str())
        == Some("deps")
    {
        if let Some(debug_directory) = current.parent().and_then(|parent| parent.parent()) {
            let candidate = debug_directory.join(expected_name);
            if candidate.is_file() {
                return Ok(candidate);
            }
        }
    }
    Err(script_worker_error())
}

fn terminate_worker(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

impl WorkerErrorCategory {
    fn from_sanitized_error(error: &SanitizedError) -> Self {
        match error.category.as_str() {
            "ScriptTimeout" => Self::ScriptTimeout,
            "ScriptMemory" => Self::ScriptMemory,
            "RequestValidation" => Self::RequestValidation,
            "RequestTooLarge" => Self::RequestTooLarge,
            _ => Self::ScriptSyntax,
        }
    }

    fn into_sanitized_error(self) -> SanitizedError {
        match self {
            Self::ScriptSyntax => script_syntax_error(),
            Self::ScriptTimeout => script_timeout_error(),
            Self::ScriptMemory => script_memory_error(),
            Self::RequestValidation => request_validation_error(),
            Self::RequestTooLarge => request_too_large_error(),
        }
    }
}

#[doc(hidden)]
pub fn run_request_worker_mode() -> i32 {
    let output = read_worker_input()
        .and_then(evaluate_request_in_worker)
        .map(|request| WorkerOutput::Request {
            request: WireRequest {
                url: request.url,
                method: request.method,
                headers: request.headers,
                body: request.body,
            },
        })
        .unwrap_or_else(|error| WorkerOutput::Error {
            category: WorkerErrorCategory::from_sanitized_error(&error),
        });

    let encoded = match serde_json::to_vec(&output) {
        Ok(encoded) if encoded.len() <= MAX_WORKER_OUTPUT_BYTES => encoded,
        _ => match serde_json::to_vec(&WorkerOutput::Error {
            category: WorkerErrorCategory::RequestTooLarge,
        }) {
            Ok(encoded) => encoded,
            Err(_) => return 1,
        },
    };
    if io::stdout().lock().write_all(&encoded).is_err() {
        return 1;
    }
    0
}

fn read_worker_input() -> Result<WorkerInput, SanitizedError> {
    let mut encoded = Vec::new();
    io::stdin()
        .lock()
        .take((MAX_WORKER_INPUT_BYTES + 1) as u64)
        .read_to_end(&mut encoded)
        .map_err(|_| script_worker_error())?;
    if encoded.len() > MAX_WORKER_INPUT_BYTES {
        return Err(request_too_large_error());
    }
    serde_json::from_slice(&encoded).map_err(|_| script_worker_error())
}

fn evaluate_request_in_worker(input: WorkerInput) -> Result<ScriptRequest, SanitizedError> {
    let secrets = SecretSet {
        api_key: input.secrets.api_key,
        access_token: input.secrets.access_token,
        user_id: input.secrets.user_id,
    };
    evaluate_request_with_quickjs(&input.script, &input.base_url, &secrets)
}

fn evaluate_request_with_quickjs(
    script: &str,
    base_url: &str,
    secrets: &SecretSet,
) -> Result<ScriptRequest, SanitizedError> {
    let deadline = Instant::now() + SCRIPT_DEADLINE;
    if script.len() > MAX_SCRIPT_BYTES {
        return Err(request_too_large_error());
    }

    let replaced = replace_tokens_for_evaluation(script, base_url, secrets)?;
    let source_len = replaced
        .len()
        .checked_add("(\n\n).request".len())
        .ok_or_else(request_too_large_error)?;
    let mut source = String::new();
    source
        .try_reserve_exact(source_len)
        .map_err(|_| script_memory_error())?;
    source.push_str("(\n");
    source.push_str(&replaced);
    source.push_str("\n).request");

    let interrupted = Arc::new(AtomicBool::new(false));
    let interrupt_signal = Arc::clone(&interrupted);
    let allocation_failed = Arc::new(AtomicBool::new(false));
    let allocator =
        LimitingAllocator::new(SCRIPT_MEMORY_LIMIT_BYTES, Arc::clone(&allocation_failed));
    let runtime = Runtime::new_with_alloc(allocator).map_err(|_| script_memory_error())?;
    runtime.set_interrupt_handler(Some(Box::new(move || {
        if Instant::now() >= deadline {
            interrupt_signal.store(true, Ordering::Relaxed);
            true
        } else {
            false
        }
    })));
    let context = Context::full(&runtime).map_err(|_| script_memory_error())?;
    let signals = RuntimeSignals {
        interrupted: &interrupted,
        allocation_failed: &allocation_failed,
    };

    context.with(|ctx| evaluate_and_validate_native_request(&ctx, source, &signals))
}

struct RuntimeSignals<'a> {
    interrupted: &'a AtomicBool,
    allocation_failed: &'a AtomicBool,
}

impl RuntimeSignals<'_> {
    fn terminal_error(&self) -> Option<SanitizedError> {
        if self.interrupted.load(Ordering::Relaxed) {
            Some(script_timeout_error())
        } else if self.allocation_failed.load(Ordering::Relaxed) {
            Some(script_memory_error())
        } else {
            None
        }
    }
}

fn checked_quickjs<'js, T>(
    ctx: &Ctx<'js>,
    result: rquickjs::Result<T>,
    signals: &RuntimeSignals<'_>,
) -> Result<T, SanitizedError> {
    match result {
        Ok(value) => signals.terminal_error().map_or(Ok(value), Err),
        Err(error) => {
            if matches!(error, QuickJsError::Exception) {
                let _ = ctx.catch();
            }
            if let Some(terminal) = signals.terminal_error() {
                Err(terminal)
            } else if matches!(error, QuickJsError::Allocation) {
                Err(script_memory_error())
            } else {
                Err(script_syntax_error())
            }
        }
    }
}

fn evaluate_and_validate_native_request<'js>(
    ctx: &Ctx<'js>,
    source: String,
    signals: &RuntimeSignals<'_>,
) -> Result<ScriptRequest, SanitizedError> {
    let plain_marker = checked_quickjs(ctx, Object::new(ctx.clone()), signals)?;
    let plain_class = unsafe { qjs::JS_GetClassID(plain_marker.as_raw()) };
    let plain_prototype = plain_marker
        .get_prototype()
        .ok_or_else(script_worker_error)?;

    let request_value = checked_quickjs(ctx, ctx.eval::<Value<'js>, _>(source), signals)?;
    let request = require_plain_object(&request_value, plain_class, &plain_prototype)?;
    let fields = own_enumerable_string_properties(ctx, &request, signals)?;

    let url = require_string_field(ctx, fields.get("url"), signals)?;
    let method = require_string_field(ctx, fields.get("method"), signals)?;
    let headers_value = fields.get("headers").ok_or_else(request_validation_error)?;
    let headers_object = require_plain_object(headers_value, plain_class, &plain_prototype)?;
    let header_values = own_enumerable_string_properties(ctx, &headers_object, signals)?;
    let mut headers = BTreeMap::new();
    for (name, value) in header_values {
        let Some(value) = value.as_string() else {
            return Err(request_validation_error());
        };
        let value = checked_quickjs(ctx, value.to_string(), signals)?;
        headers.insert(name, value);
    }

    let body = match fields.get("body") {
        None => None,
        Some(value) if value.is_null() || value.is_undefined() => None,
        Some(value) => {
            let Some(value) = value.as_string() else {
                return Err(request_validation_error());
            };
            Some(checked_quickjs(ctx, value.to_string(), signals)?)
        }
    };
    if url.is_empty() || method.is_empty() {
        return Err(request_validation_error());
    }
    if let Some(error) = signals.terminal_error() {
        return Err(error);
    }

    let request = ScriptRequest {
        url,
        method,
        headers,
        body,
    };
    let encoded = serde_json::to_vec(&WireRequest {
        url: request.url.clone(),
        method: request.method.clone(),
        headers: request.headers.clone(),
        body: request.body.clone(),
    })
    .map_err(|_| request_validation_error())?;
    if encoded.len() > MAX_REQUEST_BYTES {
        return Err(request_too_large_error());
    }
    signals.terminal_error().map_or(Ok(request), Err)
}

fn require_plain_object<'js>(
    value: &Value<'js>,
    plain_class: qjs::JSClassID,
    plain_prototype: &Object<'js>,
) -> Result<Object<'js>, SanitizedError> {
    let Some(object) = value.as_object().cloned() else {
        return Err(request_validation_error());
    };
    if unsafe { qjs::JS_GetClassID(value.as_raw()) } != plain_class {
        return Err(request_validation_error());
    }
    if object
        .get_prototype()
        .is_some_and(|prototype| prototype != *plain_prototype)
    {
        return Err(request_validation_error());
    }
    Ok(object)
}

fn own_enumerable_string_properties<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    signals: &RuntimeSignals<'_>,
) -> Result<BTreeMap<String, Value<'js>>, SanitizedError> {
    let symbol_filter = Filter::new().symbol().enum_only();
    let mut symbol_keys = object.own_keys::<Atom<'js>>(symbol_filter);
    if let Some(key) = symbol_keys.next() {
        let _ = checked_quickjs(ctx, key, signals)?;
        return Err(request_validation_error());
    }

    let mut properties = BTreeMap::new();
    for property in object.props::<String, Value<'js>>() {
        let (key, value) = checked_quickjs(ctx, property, signals)?;
        properties.insert(key, value);
    }
    Ok(properties)
}

fn require_string_field<'js>(
    ctx: &Ctx<'js>,
    value: Option<&Value<'js>>,
    signals: &RuntimeSignals<'_>,
) -> Result<String, SanitizedError> {
    let Some(value) = value.and_then(Value::as_string) else {
        return Err(request_validation_error());
    };
    checked_quickjs(ctx, value.to_string(), signals)
}

fn replace_tokens_for_evaluation(
    script: &str,
    base_url: &str,
    secrets: &SecretSet,
) -> Result<String, SanitizedError> {
    let replacements = token_replacements(base_url, secrets);
    let mut replaced_len = Some(0usize);
    if !scan_replaced_tokens(script, &replacements, |piece| {
        replaced_len = replaced_len.and_then(|length| length.checked_add(piece.len()));
        replaced_len.is_some()
    }) {
        return Err(request_too_large_error());
    }
    let Some(replaced_len) = replaced_len else {
        return Err(request_too_large_error());
    };
    if replaced_len > MAX_SUBSTITUTED_SCRIPT_BYTES {
        return Err(request_too_large_error());
    }

    let mut replaced = String::new();
    replaced
        .try_reserve_exact(replaced_len)
        .map_err(|_| script_memory_error())?;
    let completed = scan_replaced_tokens(script, &replacements, |piece| {
        replaced.push_str(piece);
        true
    });
    debug_assert!(completed);
    Ok(replaced)
}

fn token_replacements<'a>(
    base_url: &'a str,
    secrets: &'a SecretSet,
) -> [(&'static str, &'a str); 4] {
    [
        ("{{apiKey}}", secrets.api_key.as_str()),
        ("{{baseUrl}}", base_url.trim_end_matches('/')),
        ("{{accessToken}}", secrets.access_token.as_str()),
        ("{{userId}}", secrets.user_id.as_str()),
    ]
}

fn scan_replaced_tokens(
    script: &str,
    replacements: &[(&str, &str); 4],
    mut emit: impl FnMut(&str) -> bool,
) -> bool {
    let mut cursor = 0;
    while let Some(relative_offset) = script[cursor..].find("{{") {
        let offset = cursor + relative_offset;
        if !emit(&script[cursor..offset]) {
            return false;
        }
        let remaining = &script[offset..];
        let replacement = replacements
            .iter()
            .find(|(token, _)| remaining.starts_with(token));
        if let Some((token, value)) = replacement {
            if !emit(value) {
                return false;
            }
            cursor = offset + token.len();
        } else {
            if !emit("{{") {
                return false;
            }
            cursor = offset + 2;
        };
    }
    emit(&script[cursor..])
}

/// Tracks every QuickJS allocation and refuses growth past exactly 16 MiB.
/// The failure flag is native host state, so a script cannot forge an OOM by
/// choosing an exception name or message.
struct LimitingAllocator {
    inner: RustAllocator,
    used: usize,
    limit: usize,
    allocation_failed: Arc<AtomicBool>,
}

impl LimitingAllocator {
    fn new(limit: usize, allocation_failed: Arc<AtomicBool>) -> Self {
        Self {
            inner: RustAllocator,
            used: 0,
            limit,
            allocation_failed,
        }
    }

    fn rounded_size(size: usize) -> Option<usize> {
        size.checked_add(ALLOCATION_ALIGNMENT - 1)
            .map(|size| size / ALLOCATION_ALIGNMENT * ALLOCATION_ALIGNMENT)
    }

    fn deny_allocation(&self) -> *mut u8 {
        self.allocation_failed.store(true, Ordering::Relaxed);
        ptr::null_mut()
    }

    fn can_hold(&self, replacing: usize, requested: usize) -> bool {
        self.used
            .checked_sub(replacing)
            .and_then(|used| used.checked_add(requested))
            .is_some_and(|used| used <= self.limit)
    }
}

unsafe impl Allocator for LimitingAllocator {
    fn alloc(&mut self, size: usize) -> *mut u8 {
        let Some(size) = Self::rounded_size(size) else {
            return self.deny_allocation();
        };
        let Some(accounted_size) = size.checked_add(QUICKJS_ALLOCATION_OVERHEAD) else {
            return self.deny_allocation();
        };
        if !self.can_hold(0, accounted_size) {
            return self.deny_allocation();
        }
        let pointer = self.inner.alloc(size);
        if pointer.is_null() {
            return self.deny_allocation();
        }
        self.used += accounted_size;
        pointer
    }

    fn calloc(&mut self, count: usize, size: usize) -> *mut u8 {
        if count == 0 || size == 0 {
            return self.inner.calloc(count, size);
        }
        let Some(total) = count.checked_mul(size).and_then(Self::rounded_size) else {
            return self.deny_allocation();
        };
        let Some(accounted_size) = total.checked_add(QUICKJS_ALLOCATION_OVERHEAD) else {
            return self.deny_allocation();
        };
        if !self.can_hold(0, accounted_size) {
            return self.deny_allocation();
        }
        let pointer = self.inner.calloc(1, total);
        if pointer.is_null() {
            return self.deny_allocation();
        }
        self.used += accounted_size;
        pointer
    }

    unsafe fn dealloc(&mut self, pointer: *mut u8) {
        let size = RustAllocator::usable_size(pointer) + QUICKJS_ALLOCATION_OVERHEAD;
        self.used = self.used.saturating_sub(size);
        self.inner.dealloc(pointer);
    }

    unsafe fn realloc(&mut self, pointer: *mut u8, new_size: usize) -> *mut u8 {
        if pointer.is_null() {
            return self.alloc(new_size);
        }
        if new_size == 0 {
            self.dealloc(pointer);
            return ptr::null_mut();
        }

        let old_size = RustAllocator::usable_size(pointer);
        let Some(new_size) = Self::rounded_size(new_size) else {
            return self.deny_allocation();
        };
        if !self.can_hold(old_size, new_size) {
            return self.deny_allocation();
        }
        let new_pointer = self.inner.realloc(pointer, new_size);
        if new_pointer.is_null() {
            return self.deny_allocation();
        }
        self.used = self.used - old_size + new_size;
        new_pointer
    }

    unsafe fn usable_size(pointer: *mut u8) -> usize
    where
        Self: Sized,
    {
        RustAllocator::usable_size(pointer)
    }
}

fn request_too_large_error() -> SanitizedError {
    sanitized_error(
        "RequestTooLarge",
        "Relay request data exceeds the allowed size.",
    )
}

fn sanitized_error(category: &str, message: &str) -> SanitizedError {
    SanitizedError {
        category: category.into(),
        message: message.into(),
        http_status: None,
        retry_after_seconds: None,
        destination_host: None,
        destination_fingerprint: None,
    }
}

fn script_memory_error() -> SanitizedError {
    sanitized_error(
        "ScriptMemory",
        "Relay request script exceeded its memory limit.",
    )
}

fn script_timeout_error() -> SanitizedError {
    sanitized_error(
        "ScriptTimeout",
        "Relay request script exceeded its execution deadline.",
    )
}

fn script_syntax_error() -> SanitizedError {
    sanitized_error(
        "ScriptSyntax",
        "Relay request script could not be evaluated.",
    )
}

fn script_worker_error() -> SanitizedError {
    sanitized_error(
        "ScriptSyntax",
        "Relay request worker could not complete evaluation.",
    )
}

fn request_validation_error() -> SanitizedError {
    sanitized_error(
        "RequestValidation",
        "Relay request script did not produce a valid request.",
    )
}

#[cfg(test)]
mod allocator_tests {
    use super::*;

    fn allocator(limit: usize) -> (LimitingAllocator, Arc<AtomicBool>) {
        let failed = Arc::new(AtomicBool::new(false));
        (LimitingAllocator::new(limit, Arc::clone(&failed)), failed)
    }

    #[test]
    fn allocation_at_exact_limit_succeeds_and_one_byte_over_fails() {
        let requested = 64;
        let limit = requested + QUICKJS_ALLOCATION_OVERHEAD;
        let (mut allocator, failed) = allocator(limit);
        let pointer = allocator.alloc(requested);
        assert!(!pointer.is_null());
        assert_eq!(allocator.used, limit);

        assert!(allocator.alloc(1).is_null());
        assert!(failed.load(Ordering::Relaxed));

        unsafe { allocator.dealloc(pointer) };
        assert_eq!(allocator.used, 0);
    }

    #[test]
    fn first_allocation_one_byte_over_limit_fails() {
        let requested = 65;
        let rounded = LimitingAllocator::rounded_size(requested).unwrap();
        let (mut allocator, failed) = allocator(rounded + QUICKJS_ALLOCATION_OVERHEAD - 1);

        assert!(allocator.alloc(requested).is_null());
        assert!(failed.load(Ordering::Relaxed));
        assert_eq!(allocator.used, 0);
    }

    #[test]
    fn calloc_overflow_fails_without_allocating() {
        let (mut allocator, failed) = allocator(usize::MAX);

        assert!(allocator.calloc(usize::MAX, 2).is_null());
        assert!(failed.load(Ordering::Relaxed));
        assert_eq!(allocator.used, 0);
    }

    #[test]
    fn zero_sized_calloc_is_not_an_allocation_failure() {
        let (mut allocator, failed) = allocator(64);

        assert!(allocator.calloc(0, 8).is_null());
        assert!(!failed.load(Ordering::Relaxed));
        assert_eq!(allocator.used, 0);
    }

    #[test]
    fn realloc_grows_shrinks_and_failed_growth_preserves_old_allocation() {
        let (mut allocator, failed) = allocator(128 + QUICKJS_ALLOCATION_OVERHEAD);
        let mut pointer = allocator.alloc(16);
        assert!(!pointer.is_null());
        unsafe {
            for index in 0..16 {
                pointer.add(index).write(index as u8);
            }

            pointer = allocator.realloc(pointer, 32);
            assert!(!pointer.is_null());
            for index in 0..16 {
                assert_eq!(pointer.add(index).read(), index as u8);
            }

            pointer = allocator.realloc(pointer, 8);
            assert!(!pointer.is_null());
            for index in 0..8 {
                assert_eq!(pointer.add(index).read(), index as u8);
            }

            assert!(allocator.realloc(pointer, 1024).is_null());
            assert!(failed.load(Ordering::Relaxed));
            for index in 0..8 {
                assert_eq!(pointer.add(index).read(), index as u8);
            }

            allocator.dealloc(pointer);
        }
        assert_eq!(allocator.used, 0);
    }

    #[test]
    fn realloc_to_zero_deallocates_and_resets_accounting() {
        let (mut allocator, failed) = allocator(64 + QUICKJS_ALLOCATION_OVERHEAD);
        let pointer = allocator.alloc(16);
        assert!(!pointer.is_null());

        let result = unsafe { allocator.realloc(pointer, 0) };
        assert!(result.is_null());
        assert!(!failed.load(Ordering::Relaxed));
        assert_eq!(allocator.used, 0);
    }
}

#[cfg(all(test, windows))]
mod windows_process_tests {
    use super::*;

    #[test]
    fn worker_process_uses_create_no_window() {
        assert_eq!(request_worker_creation_flags(), 0x0800_0000);
    }
}
