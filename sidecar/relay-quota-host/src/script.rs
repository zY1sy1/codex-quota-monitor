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

use ring::{
    aead::{Aad, LessSafeKey, Nonce, UnboundKey, AES_256_GCM},
    rand::{SecureRandom, SystemRandom},
};
use rquickjs::{
    allocator::{Allocator, RustAllocator},
    qjs, Array, Atom, Context, Ctx, Error as QuickJsError, Filter, Object, Runtime, Value,
};
use serde::{Deserialize, Serialize};

use crate::protocol::{RequestDefinition, SanitizedError, SecretSet, UsageResult};
use url::Url;

const MAX_SCRIPT_BYTES: usize = 256 * 1024;
const MAX_SUBSTITUTED_SCRIPT_BYTES: usize = 1024 * 1024;
const MAX_REQUEST_BYTES: usize = 64 * 1024;
const MAX_REQUEST_MAP_ENTRIES: usize = 128;
const MAX_REQUEST_NAME_BYTES: usize = 256;
const MAX_REQUEST_VALUE_BYTES: usize = 16 * 1024;
const MAX_REQUEST_WORKER_INPUT_BYTES: usize = 2 * 1024 * 1024;
const MAX_EXTRACTOR_RESPONSE_BYTES: usize = 1024 * 1024;
const MAX_EXTRACTOR_WORKER_INPUT_BYTES: usize = 8 * 1024 * 1024;
const MAX_NORMALIZED_RESULT_BYTES: usize = 256 * 1024;
const MAX_RESULT_STRING_BYTES: usize = 4096;
const WORKER_IPC_KEY_BYTES: usize = 32;
const WORKER_IPC_NONCE_BYTES: usize = 12;
const WORKER_IPC_TAG_BYTES: usize = 16;
const WORKER_IPC_HEADER_BYTES: usize = 4 + WORKER_IPC_NONCE_BYTES;
const WORKER_IPC_OVERHEAD: usize = WORKER_IPC_HEADER_BYTES + WORKER_IPC_TAG_BYTES;
const WORKER_IPC_MAGIC: &[u8; 4] = b"RQW1";
const MAX_REQUEST_WORKER_OUTPUT_BYTES: usize = 128 * 1024 + WORKER_IPC_OVERHEAD;
const MAX_EXTRACTOR_WORKER_OUTPUT_BYTES: usize =
    MAX_NORMALIZED_RESULT_BYTES + 1024 + WORKER_IPC_OVERHEAD;
// With the stable public field order, empty strings for all four string fields,
// zeroes for all three numeric fields, and `isValid:true`, one normalized
// UsageResult is at least 110 JSON bytes. A JSON array adds one comma per item
// after the first plus two brackets, so 2,362 minimum-sized items cannot fit
// within 256 KiB while 2,361 can.
const MIN_NORMALIZED_RESULT_BYTES: usize = 110;
const MAX_RESULT_COUNT: usize =
    (MAX_NORMALIZED_RESULT_BYTES - 1) / (MIN_NORMALIZED_RESULT_BYTES + 1);
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

/// Initial, synthetic-contract Wakaka preset. The extractor accepts either a
/// wallet record or a list of quota plans from the response's `data` object.
pub const WAKAKA_PRESET_SCRIPT: &str = r#"({
  request: {
    url: "{{baseUrl}}/v1/usage",
    method: "GET",
    headers: { Authorization: "Bearer {{apiKey}}" },
    body: undefined
  },
  extractor: response => {
    const data = response.data ?? response;
    if (Array.isArray(data.plans) && data.plans.length > 0) {
      return data.plans.map(plan => ({
        isValid: response.success ?? true,
        invalidMessage: response.message ?? null,
        remaining: plan.remaining,
        unit: plan.unit ?? null,
        planName: plan.name ?? null,
        total: plan.total ?? null,
        used: plan.used ?? null,
        extra: plan.reset ?? null
      }));
    }
    return {
      isValid: response.success ?? true,
      invalidMessage: response.message ?? null,
      remaining: data.balance,
      unit: data.currency ?? "USD",
      planName: "Wallet"
    };
  }
})"#;

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
    #[serde(default)]
    ipc_key: Option<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkerSecrets {
    api_key: String,
    access_token: String,
    user_id: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExtractorWorkerInput {
    script: String,
    response_json: String,
    base_url: String,
    secrets: WorkerSecrets,
    #[serde(default)]
    ipc_key: Option<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "camelCase", deny_unknown_fields)]
enum WorkerOutput {
    Request { request: WireRequest },
    Error { category: WorkerErrorCategory },
}

#[derive(Deserialize)]
#[serde(tag = "status", rename_all = "camelCase", deny_unknown_fields)]
enum ExtractorWorkerOutput {
    Results { results: Vec<WireUsageResult> },
    Error { category: WorkerErrorCategory },
}

#[derive(Serialize)]
#[serde(tag = "status", rename_all = "camelCase")]
enum ExtractorWorkerResponse<'a> {
    Results { results: &'a [UsageResult] },
    Error { category: WorkerErrorCategory },
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireUsageResult {
    is_valid: bool,
    invalid_message: Option<String>,
    remaining: Option<f64>,
    unit: Option<String>,
    plan_name: Option<String>,
    total: Option<f64>,
    used: Option<f64>,
    extra: Option<String>,
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
    ExtractorExecution,
    ResultValidation,
    SidecarLifecycle,
}

#[derive(Clone, Copy)]
enum WorkerMode {
    Request,
    Extractor,
}

impl WorkerMode {
    const fn argument(self) -> &'static str {
        match self {
            Self::Request => "--request-worker",
            Self::Extractor => "--extractor-worker",
        }
    }

    const fn input_limit(self) -> usize {
        match self {
            Self::Request => MAX_REQUEST_WORKER_INPUT_BYTES,
            Self::Extractor => MAX_EXTRACTOR_WORKER_INPUT_BYTES,
        }
    }

    const fn output_limit(self) -> usize {
        match self {
            Self::Request => MAX_REQUEST_WORKER_OUTPUT_BYTES,
            Self::Extractor => MAX_EXTRACTOR_WORKER_OUTPUT_BYTES,
        }
    }
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

pub fn evaluate_generic_request(
    definition: &RequestDefinition,
    base_url: &str,
    secrets: &SecretSet,
) -> Result<ScriptRequest, SanitizedError> {
    let base = parse_generic_base_url(base_url)?;
    let method = definition.method.trim().to_ascii_uppercase();
    if !matches!(method.as_str(), "GET" | "POST" | "PUT") {
        return Err(request_validation_error());
    }

    let path = expand_generic_value(&definition.path, base_url, secrets)?;
    let request_url = build_generic_request_url(&base, &path)?;
    let headers = expand_generic_map(&definition.headers, base_url, secrets, true)?;
    let mut url = request_url;
    {
        let mut query_pairs = url.query_pairs_mut();
        if definition.query.len() > MAX_REQUEST_MAP_ENTRIES {
            return Err(request_too_large_error());
        }
        for (name, value) in &definition.query {
            validate_generic_map_name(name)?;
            let value = expand_generic_value(value, base_url, secrets)?;
            query_pairs.append_pair(name, &value);
        }
    }

    let body = definition
        .body
        .as_deref()
        .map(|body| expand_generic_value(body, base_url, secrets))
        .transpose()?;
    let request = ScriptRequest {
        url: url.into(),
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
    Ok(request)
}

fn parse_generic_base_url(base_url: &str) -> Result<Url, SanitizedError> {
    if base_url.is_empty() || base_url.chars().any(char::is_control) {
        return Err(request_validation_error());
    }
    let base = Url::parse(base_url).map_err(|_| request_validation_error())?;
    if !matches!(base.scheme(), "http" | "https")
        || base.host().is_none()
        || !base.username().is_empty()
        || base.password().is_some()
        || base.query().is_some()
        || base.fragment().is_some()
    {
        return Err(request_validation_error());
    }
    Ok(base)
}

fn build_generic_request_url(base: &Url, path: &str) -> Result<Url, SanitizedError> {
    if path.is_empty()
        || path.len() > 4096
        || path.starts_with("//")
        || path.contains('?')
        || path.contains('#')
        || path.chars().any(char::is_control)
    {
        return Err(request_validation_error());
    }
    if Url::parse(path).is_ok_and(|absolute| absolute.scheme() != "" || absolute.host().is_some()) {
        return Err(request_validation_error());
    }
    let url = base.join(path).map_err(|_| request_validation_error())?;
    if url.host().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || !same_url_origin(base, &url)
    {
        return Err(request_validation_error());
    }
    Ok(url)
}

fn same_url_origin(left: &Url, right: &Url) -> bool {
    left.scheme().eq_ignore_ascii_case(right.scheme())
        && left.host() == right.host()
        && left.port_or_known_default() == right.port_or_known_default()
}

fn expand_generic_map(
    values: &BTreeMap<String, String>,
    base_url: &str,
    secrets: &SecretSet,
    headers: bool,
) -> Result<BTreeMap<String, String>, SanitizedError> {
    if values.len() > MAX_REQUEST_MAP_ENTRIES {
        return Err(request_too_large_error());
    }
    let mut expanded = BTreeMap::new();
    for (name, value) in values {
        validate_generic_map_name(name)?;
        let value = expand_generic_value(value, base_url, secrets)?;
        if headers && (value.contains('\r') || value.contains('\n')) {
            return Err(request_validation_error());
        }
        expanded.insert(name.clone(), value);
    }
    Ok(expanded)
}

fn validate_generic_map_name(name: &str) -> Result<(), SanitizedError> {
    if name.is_empty() || name.len() > MAX_REQUEST_NAME_BYTES {
        return Err(request_validation_error());
    }
    if !name.bytes().all(is_http_token_byte) {
        return Err(request_validation_error());
    }
    Ok(())
}

fn is_http_token_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&byte)
}

fn expand_generic_value(
    value: &str,
    base_url: &str,
    secrets: &SecretSet,
) -> Result<String, SanitizedError> {
    let replacements = token_replacements(base_url, secrets);
    let mut size = Some(0usize);
    if !scan_replaced_tokens(value, &replacements, |piece| {
        size = size.and_then(|size| size.checked_add(piece.len()));
        size.is_some_and(|size| size <= MAX_REQUEST_VALUE_BYTES)
    }) {
        return Err(request_too_large_error());
    }
    let size = size.ok_or_else(request_too_large_error)?;
    let mut expanded = String::new();
    expanded
        .try_reserve_exact(size)
        .map_err(|_| script_memory_error())?;
    let completed = scan_replaced_tokens(value, &replacements, |piece| {
        expanded.push_str(piece);
        true
    });
    debug_assert!(completed);
    Ok(expanded)
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
    if worst_case_size > MAX_REQUEST_WORKER_INPUT_BYTES {
        return Err(request_too_large_error());
    }
    if Instant::now() >= deadline {
        return Err(script_timeout_error());
    }

    let ipc_key = new_worker_ipc_key()?;
    let input = WorkerInput {
        script: script.into(),
        base_url: base_url.into(),
        secrets: WorkerSecrets {
            api_key: secrets.api_key.clone(),
            access_token: secrets.access_token.clone(),
            user_id: secrets.user_id.clone(),
        },
        ipc_key: Some(ipc_key.clone()),
    };
    let encoded = serde_json::to_vec(&input).map_err(|_| script_worker_error())?;
    if encoded.len() > MAX_REQUEST_WORKER_INPUT_BYTES {
        return Err(request_too_large_error());
    }
    if Instant::now() >= deadline {
        return Err(script_timeout_error());
    }

    let output = supervise_script_worker(encoded, deadline, WorkerMode::Request)?;
    let output = open_worker_output(&output, &ipc_key).ok_or_else(script_worker_error)?;
    match serde_json::from_slice(&output).map_err(|_| script_worker_error())? {
        WorkerOutput::Request { request } => Ok(ScriptRequest {
            url: request.url,
            method: request.method,
            headers: request.headers,
            body: request.body,
        }),
        WorkerOutput::Error { category } => Err(category.into_sanitized_error()),
    }
}

pub fn evaluate_extractor(
    script: &str,
    response: &serde_json::Value,
) -> Result<Vec<UsageResult>, SanitizedError> {
    evaluate_extractor_with_context(script, response, "", &SecretSet::default())
}

pub fn evaluate_extractor_with_context(
    script: &str,
    response: &serde_json::Value,
    base_url: &str,
    secrets: &SecretSet,
) -> Result<Vec<UsageResult>, SanitizedError> {
    let deadline = Instant::now() + SUPERVISOR_DEADLINE;
    if script.len() > MAX_SCRIPT_BYTES {
        return Err(request_too_large_error());
    }

    let response_json = serde_json::to_string(response).map_err(|_| result_validation_error())?;
    if response_json.len() > MAX_EXTRACTOR_RESPONSE_BYTES {
        return Err(result_validation_error());
    }
    if Instant::now() >= deadline {
        return Err(script_timeout_error());
    }

    let ipc_key = new_worker_ipc_key()?;
    let worst_case_size =
        extractor_worker_input_worst_case_size(script, &response_json, base_url, secrets)
            .ok_or_else(request_too_large_error)?;
    if worst_case_size > MAX_EXTRACTOR_WORKER_INPUT_BYTES {
        return Err(request_too_large_error());
    }

    let input = ExtractorWorkerInput {
        script: script.into(),
        response_json,
        base_url: base_url.into(),
        secrets: WorkerSecrets {
            api_key: secrets.api_key.clone(),
            access_token: secrets.access_token.clone(),
            user_id: secrets.user_id.clone(),
        },
        ipc_key: Some(ipc_key.clone()),
    };
    let encoded = serde_json::to_vec(&input).map_err(|_| script_worker_error())?;
    if encoded.len() > MAX_EXTRACTOR_WORKER_INPUT_BYTES {
        return Err(request_too_large_error());
    }
    if Instant::now() >= deadline {
        return Err(script_timeout_error());
    }

    let output = supervise_script_worker(encoded, deadline, WorkerMode::Extractor)?;
    let output = open_worker_output(&output, &ipc_key).ok_or_else(script_worker_error)?;
    match serde_json::from_slice(&output).map_err(|_| script_worker_error())? {
        ExtractorWorkerOutput::Results { results } => validate_wire_results(results),
        ExtractorWorkerOutput::Error { category } => Err(category.into_sanitized_error()),
    }
}

fn extractor_worker_input_worst_case_size(
    script: &str,
    response_json: &str,
    base_url: &str,
    secrets: &SecretSet,
) -> Option<usize> {
    [
        script.len(),
        response_json.len(),
        base_url.len(),
        secrets.api_key.len(),
        secrets.access_token.len(),
        secrets.user_id.len(),
    ]
    .into_iter()
    .try_fold(1024usize, |size, field_size| {
        size.checked_add(field_size.checked_mul(6)?)
    })
}

fn validate_wire_results(
    wire_results: Vec<WireUsageResult>,
) -> Result<Vec<UsageResult>, SanitizedError> {
    if wire_results.is_empty() || wire_results.len() > MAX_RESULT_COUNT {
        return Err(result_validation_error());
    }
    let mut results = Vec::new();
    results
        .try_reserve_exact(wire_results.len())
        .map_err(|_| result_validation_error())?;
    let mut encoded_size = 2usize;
    for wire in wire_results {
        let result = validate_wire_result(wire)?;
        push_normalized_result(&mut results, result, &mut encoded_size)?;
    }
    Ok(results)
}

fn validate_wire_result(wire: WireUsageResult) -> Result<UsageResult, SanitizedError> {
    Ok(UsageResult {
        is_valid: wire.is_valid,
        invalid_message: validate_wire_string(wire.invalid_message)?,
        remaining: validate_wire_number(wire.remaining)?,
        unit: validate_wire_string(wire.unit)?,
        plan_name: validate_wire_string(wire.plan_name)?,
        total: validate_wire_number(wire.total)?,
        used: validate_wire_number(wire.used)?,
        extra: validate_wire_string(wire.extra)?,
    })
}

fn validate_wire_string(value: Option<String>) -> Result<Option<String>, SanitizedError> {
    if value
        .as_ref()
        .is_some_and(|value| value.len() > MAX_RESULT_STRING_BYTES)
    {
        Err(result_validation_error())
    } else {
        Ok(value)
    }
}

fn validate_wire_number(value: Option<f64>) -> Result<Option<f64>, SanitizedError> {
    if value.is_some_and(|value| !value.is_finite()) {
        Err(result_validation_error())
    } else {
        Ok(value)
    }
}

fn push_normalized_result(
    results: &mut Vec<UsageResult>,
    result: UsageResult,
    encoded_size: &mut usize,
) -> Result<(), SanitizedError> {
    let result_size = serde_json::to_vec(&result)
        .map_err(|_| result_validation_error())?
        .len();
    let separator = usize::from(!results.is_empty());
    let next_size = encoded_size
        .checked_add(separator)
        .and_then(|size| size.checked_add(result_size))
        .ok_or_else(result_validation_error)?;
    if next_size > MAX_NORMALIZED_RESULT_BYTES {
        return Err(result_validation_error());
    }
    results
        .try_reserve(1)
        .map_err(|_| result_validation_error())?;
    results.push(result);
    *encoded_size = next_size;
    Ok(())
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

fn supervise_script_worker(
    input: Vec<u8>,
    deadline: Instant,
    mode: WorkerMode,
) -> Result<Vec<u8>, SanitizedError> {
    let executable = request_worker_executable()?;
    if Instant::now() >= deadline {
        return Err(script_timeout_error());
    }

    let mut command = script_worker_command(executable, mode);
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
        .name("relay-script-worker-stdin".into())
        .spawn(move || stdin.write_all(&input))
    {
        Ok(writer) => writer,
        Err(_) => {
            terminate_worker(&mut child);
            return Err(script_worker_error());
        }
    };
    let reader = match thread::Builder::new()
        .name("relay-script-worker-stdout".into())
        .spawn(move || {
            let mut output = Vec::new();
            stdout
                .by_ref()
                .take((mode.output_limit() + 1) as u64)
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
    if !status.success() || !write_succeeded || output.len() > mode.output_limit() {
        return Err(script_worker_error());
    }
    Ok(output)
}

fn script_worker_command(executable: PathBuf, mode: WorkerMode) -> Command {
    let mut command = Command::new(executable);
    command
        .arg(mode.argument())
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

fn new_worker_ipc_key() -> Result<String, SanitizedError> {
    let mut key = [0_u8; WORKER_IPC_KEY_BYTES];
    SystemRandom::new()
        .fill(&mut key)
        .map_err(|_| script_worker_error())?;
    Ok(hex_encode(&key))
}

fn parse_worker_ipc_key(encoded: &str) -> Option<[u8; WORKER_IPC_KEY_BYTES]> {
    if encoded.len() != WORKER_IPC_KEY_BYTES * 2 {
        return None;
    }
    let mut key = [0_u8; WORKER_IPC_KEY_BYTES];
    let bytes = encoded.as_bytes();
    for (index, value) in key.iter_mut().enumerate() {
        let high = hex_value(bytes[index * 2])?;
        let low = hex_value(bytes[index * 2 + 1])?;
        *value = (high << 4) | low;
    }
    Some(key)
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(char::from(HEX[(byte >> 4) as usize]));
        encoded.push(char::from(HEX[(byte & 0x0f) as usize]));
    }
    encoded
}

fn hex_value(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

/// Worker stdout is an authenticated opaque channel. Raw request fields and
/// extractor values never cross the public stdout/stderr boundary.
fn seal_worker_output(plaintext: &[u8], key: &[u8; WORKER_IPC_KEY_BYTES]) -> Option<Vec<u8>> {
    let unbound = UnboundKey::new(&AES_256_GCM, key).ok()?;
    let sealing_key = LessSafeKey::new(unbound);
    let mut nonce = [0_u8; WORKER_IPC_NONCE_BYTES];
    SystemRandom::new().fill(&mut nonce).ok()?;
    let mut ciphertext = plaintext.to_vec();
    sealing_key
        .seal_in_place_append_tag(
            Nonce::assume_unique_for_key(nonce),
            Aad::from(WORKER_IPC_MAGIC.as_slice()),
            &mut ciphertext,
        )
        .ok()?;

    let mut output = Vec::with_capacity(WORKER_IPC_HEADER_BYTES + ciphertext.len());
    output.extend_from_slice(WORKER_IPC_MAGIC);
    output.extend_from_slice(&nonce);
    output.extend_from_slice(&ciphertext);
    Some(output)
}

fn open_worker_output(encoded: &[u8], key: &str) -> Option<Vec<u8>> {
    let key = parse_worker_ipc_key(key)?;
    if encoded.len() < WORKER_IPC_OVERHEAD || !encoded.starts_with(WORKER_IPC_MAGIC) {
        return None;
    }
    let nonce: [u8; WORKER_IPC_NONCE_BYTES] =
        encoded[4..WORKER_IPC_HEADER_BYTES].try_into().ok()?;
    let mut ciphertext = encoded[WORKER_IPC_HEADER_BYTES..].to_vec();
    let unbound = UnboundKey::new(&AES_256_GCM, &key).ok()?;
    let opening_key = LessSafeKey::new(unbound);
    let plaintext = opening_key
        .open_in_place(
            Nonce::assume_unique_for_key(nonce),
            Aad::from(WORKER_IPC_MAGIC.as_slice()),
            &mut ciphertext,
        )
        .ok()?;
    Some(plaintext.to_vec())
}

fn write_worker_output(
    encoded: Vec<u8>,
    fallback: Vec<u8>,
    key: Option<[u8; WORKER_IPC_KEY_BYTES]>,
    max_bytes: usize,
) -> i32 {
    let output = key
        .as_ref()
        .and_then(|key| seal_worker_output(&encoded, key))
        .filter(|output| output.len() <= max_bytes)
        .unwrap_or(fallback);
    if output.len() > max_bytes || io::stdout().lock().write_all(&output).is_err() {
        return 1;
    }
    0
}

impl WorkerErrorCategory {
    fn from_sanitized_error(error: &SanitizedError) -> Self {
        match error.category.as_str() {
            "ScriptSyntax" => Self::ScriptSyntax,
            "ScriptTimeout" => Self::ScriptTimeout,
            "ScriptMemory" => Self::ScriptMemory,
            "RequestValidation" => Self::RequestValidation,
            "RequestTooLarge" => Self::RequestTooLarge,
            "ExtractorExecution" => Self::ExtractorExecution,
            "ResultValidation" => Self::ResultValidation,
            "SidecarLifecycle" => Self::SidecarLifecycle,
            _ => Self::SidecarLifecycle,
        }
    }

    fn into_sanitized_error(self) -> SanitizedError {
        match self {
            Self::ScriptSyntax => script_syntax_error(),
            Self::ScriptTimeout => script_timeout_error(),
            Self::ScriptMemory => script_memory_error(),
            Self::RequestValidation => request_validation_error(),
            Self::RequestTooLarge => request_too_large_error(),
            Self::ExtractorExecution => extractor_execution_error(),
            Self::ResultValidation => result_validation_error(),
            Self::SidecarLifecycle => sidecar_lifecycle_error(),
        }
    }
}

#[doc(hidden)]
pub fn run_request_worker_mode() -> i32 {
    let (output, key) = match read_worker_input::<WorkerInput>(WorkerMode::Request) {
        Ok(input) => {
            let key = input.ipc_key.as_deref().and_then(parse_worker_ipc_key);
            let output = key
                .as_ref()
                .map(|_| evaluate_request_in_worker(input))
                .unwrap_or_else(|| Err(script_worker_error()))
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
            (output, key)
        }
        Err(error) => (
            WorkerOutput::Error {
                category: WorkerErrorCategory::from_sanitized_error(&error),
            },
            None,
        ),
    };

    let encoded = match serde_json::to_vec(&output) {
        Ok(encoded) => encoded,
        Err(_) => return 1,
    };
    let fallback = match serde_json::to_vec(&WorkerOutput::Error {
        category: WorkerErrorCategory::SidecarLifecycle,
    }) {
        Ok(encoded) => encoded,
        Err(_) => return 1,
    };
    write_worker_output(encoded, fallback, key, MAX_REQUEST_WORKER_OUTPUT_BYTES)
}

#[doc(hidden)]
pub fn run_extractor_worker_mode() -> i32 {
    let (encoded, key) = match read_worker_input::<ExtractorWorkerInput>(WorkerMode::Extractor) {
        Ok(input) => {
            let key = input.ipc_key.as_deref().and_then(parse_worker_ipc_key);
            let evaluated = key
                .as_ref()
                .map(|_| evaluate_extractor_in_worker(input))
                .unwrap_or_else(|| Err(script_worker_error()));
            let output = match &evaluated {
                Ok(results) => ExtractorWorkerResponse::Results { results },
                Err(error) => ExtractorWorkerResponse::Error {
                    category: WorkerErrorCategory::from_sanitized_error(error),
                },
            };
            let encoded = match serde_json::to_vec(&output) {
                Ok(encoded) => encoded,
                Err(_) => return 1,
            };
            (encoded, key)
        }
        Err(error) => (
            match serde_json::to_vec(&ExtractorWorkerResponse::Error {
                category: WorkerErrorCategory::from_sanitized_error(&error),
            }) {
                Ok(encoded) => encoded,
                Err(_) => return 1,
            },
            None,
        ),
    };

    let fallback = match serde_json::to_vec(&ExtractorWorkerResponse::Error {
        category: WorkerErrorCategory::SidecarLifecycle,
    }) {
        Ok(encoded) => encoded,
        Err(_) => return 1,
    };
    write_worker_output(encoded, fallback, key, MAX_EXTRACTOR_WORKER_OUTPUT_BYTES)
}

fn read_worker_input<T>(mode: WorkerMode) -> Result<T, SanitizedError>
where
    T: for<'de> Deserialize<'de>,
{
    let mut encoded = Vec::new();
    io::stdin()
        .lock()
        .take((mode.input_limit() + 1) as u64)
        .read_to_end(&mut encoded)
        .map_err(|_| script_worker_error())?;
    if encoded.len() > mode.input_limit() {
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

fn evaluate_extractor_in_worker(
    input: ExtractorWorkerInput,
) -> Result<Vec<UsageResult>, SanitizedError> {
    let secrets = SecretSet {
        api_key: input.secrets.api_key,
        access_token: input.secrets.access_token,
        user_id: input.secrets.user_id,
    };
    evaluate_extractor_with_quickjs(
        &input.script,
        &input.response_json,
        &input.base_url,
        &secrets,
    )
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
    let replaced = trim_legacy_expression_terminator(&replaced);
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

fn evaluate_extractor_with_quickjs(
    script: &str,
    response_json: &str,
    base_url: &str,
    secrets: &SecretSet,
) -> Result<Vec<UsageResult>, SanitizedError> {
    let deadline = Instant::now() + SCRIPT_DEADLINE;
    if script.len() > MAX_SCRIPT_BYTES {
        return Err(request_too_large_error());
    }
    if response_json.len() > MAX_EXTRACTOR_RESPONSE_BYTES {
        return Err(result_validation_error());
    }

    let replaced = replace_tokens_for_evaluation(script, base_url, secrets)?;
    let wrapped = wrap_extractor_source(trim_legacy_expression_terminator(&replaced));
    let source_len = wrapped
        .len()
        .checked_add("(\n\n)".len())
        .ok_or_else(request_too_large_error)?;
    let mut source = String::new();
    source
        .try_reserve_exact(source_len)
        .map_err(|_| script_memory_error())?;
    source.push_str("(\n");
    source.push_str(&wrapped);
    source.push_str("\n)");

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

    context
        .with(|ctx| evaluate_and_normalize_native_extractor(&ctx, source, response_json, &signals))
}

fn wrap_extractor_source(source: &str) -> String {
    let trimmed = source.trim_start();
    let extractor_field = trimmed.find("extractor:");
    let first_arrow = trimmed.find("=>");
    let is_legacy_object = (trimmed.starts_with("({") || trimmed.starts_with("{"))
        && extractor_field.is_some_and(|field| first_arrow.is_none_or(|arrow| field < arrow));
    if is_legacy_object {
        source.into()
    } else {
        format!("{{extractor: ({source})}}")
    }
}

/// Legacy CC Switch scripts often end with a statement terminator, but the
/// evaluator wraps them in parentheses and needs a pure expression.
fn trim_legacy_expression_terminator(mut source: &str) -> &str {
    loop {
        source = source.trim_end_matches(|character: char| character.is_whitespace());
        let Some(stripped) = source.strip_suffix(';') else {
            return source;
        };
        source = stripped;
    }
}

fn evaluate_and_normalize_native_extractor<'js>(
    ctx: &Ctx<'js>,
    source: String,
    response_json: &str,
    signals: &RuntimeSignals<'_>,
) -> Result<Vec<UsageResult>, SanitizedError> {
    let plain_marker = checked_extractor_quickjs(
        ctx,
        Object::new(ctx.clone()),
        signals,
        extractor_execution_error,
    )?;
    let plain_class = unsafe { qjs::JS_GetClassID(plain_marker.as_raw()) };
    let plain_prototype = plain_marker
        .get_prototype()
        .ok_or_else(extractor_execution_error)?;
    let array_marker = checked_extractor_quickjs(
        ctx,
        Array::new(ctx.clone()),
        signals,
        extractor_execution_error,
    )?;
    let array_class = unsafe { qjs::JS_GetClassID(array_marker.as_object().as_raw()) };
    let array_prototype = array_marker
        .as_object()
        .get_prototype()
        .ok_or_else(extractor_execution_error)?;

    let script_value = checked_quickjs(ctx, ctx.eval::<Value<'js>, _>(source), signals)?;
    let script_object = require_plain_object(
        &script_value,
        plain_class,
        &plain_prototype,
        extractor_execution_error,
    )?;
    let extractor_value = get_own_enumerable_field(
        ctx,
        &script_object,
        "extractor",
        signals,
        extractor_execution_error,
    )?
    .ok_or_else(extractor_execution_error)?;
    let extractor = extractor_value
        .as_function()
        .cloned()
        .ok_or_else(extractor_execution_error)?;

    let response = checked_extractor_quickjs(
        ctx,
        ctx.json_parse(response_json),
        signals,
        extractor_execution_error,
    )?;
    let extracted = checked_extractor_quickjs(
        ctx,
        extractor.call::<_, Value<'js>>((response,)),
        signals,
        extractor_execution_error,
    )?;

    let mut results = Vec::new();
    let mut encoded_size = 2usize;
    if let Some(array) = extracted.as_array() {
        if unsafe { qjs::JS_GetClassID(extracted.as_raw()) } != array_class
            || array
                .as_object()
                .get_prototype()
                .is_none_or(|prototype| prototype != array_prototype)
        {
            return Err(result_validation_error());
        }
        let result_count = array.len();
        if result_count == 0 || result_count > MAX_RESULT_COUNT {
            return Err(result_validation_error());
        }
        results
            .try_reserve_exact(result_count)
            .map_err(|_| result_validation_error())?;
        for value in array.iter::<Value<'js>>() {
            let value = checked_extractor_quickjs(ctx, value, signals, extractor_execution_error)?;
            let result =
                normalize_usage_result(ctx, &value, plain_class, &plain_prototype, signals)?;
            push_normalized_result(&mut results, result, &mut encoded_size)?;
        }
    } else {
        results
            .try_reserve_exact(1)
            .map_err(|_| result_validation_error())?;
        let result =
            normalize_usage_result(ctx, &extracted, plain_class, &plain_prototype, signals)?;
        push_normalized_result(&mut results, result, &mut encoded_size)?;
    }
    if let Some(error) = signals.terminal_error() {
        return Err(error);
    }
    signals.terminal_error().map_or(Ok(results), Err)
}

fn normalize_usage_result<'js>(
    ctx: &Ctx<'js>,
    value: &Value<'js>,
    plain_class: qjs::JSClassID,
    plain_prototype: &Object<'js>,
    signals: &RuntimeSignals<'_>,
) -> Result<UsageResult, SanitizedError> {
    let object =
        require_plain_object(value, plain_class, plain_prototype, result_validation_error)?;
    reject_enumerable_symbol_properties(ctx, &object, signals)?;

    let is_valid = optional_boolean_field(ctx, &object, "isValid", signals)?.unwrap_or(true);
    Ok(UsageResult {
        is_valid,
        invalid_message: optional_string_field(ctx, &object, "invalidMessage", signals)?,
        remaining: optional_number_field(ctx, &object, "remaining", signals)?,
        unit: optional_string_field(ctx, &object, "unit", signals)?,
        plan_name: optional_string_field(ctx, &object, "planName", signals)?,
        total: optional_number_field(ctx, &object, "total", signals)?,
        used: optional_number_field(ctx, &object, "used", signals)?,
        extra: optional_string_field(ctx, &object, "extra", signals)?,
    })
}

fn reject_enumerable_symbol_properties<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    signals: &RuntimeSignals<'_>,
) -> Result<(), SanitizedError> {
    let mut keys = object.own_keys::<Atom<'js>>(Filter::new().symbol().enum_only());
    if let Some(key) = keys.next() {
        let _ = checked_extractor_quickjs(ctx, key, signals, extractor_execution_error)?;
        return Err(result_validation_error());
    }
    Ok(())
}

fn get_own_enumerable_field<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    field: &str,
    signals: &RuntimeSignals<'_>,
    error: fn() -> SanitizedError,
) -> Result<Option<Value<'js>>, SanitizedError> {
    let mut found = false;
    for key in object.own_keys::<String>(Filter::new().string().enum_only()) {
        let key = checked_extractor_quickjs(ctx, key, signals, error)?;
        if key == field {
            found = true;
            break;
        }
    }
    if !found {
        return Ok(None);
    }
    checked_extractor_quickjs(ctx, object.get::<_, Value<'js>>(field), signals, error).map(Some)
}

fn optional_boolean_field<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    field: &str,
    signals: &RuntimeSignals<'_>,
) -> Result<Option<bool>, SanitizedError> {
    match get_own_enumerable_field(ctx, object, field, signals, extractor_execution_error)? {
        None => Ok(None),
        Some(value) if value.is_null() || value.is_undefined() => Ok(None),
        Some(value) => value
            .as_bool()
            .map(Some)
            .ok_or_else(result_validation_error),
    }
}

fn optional_number_field<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    field: &str,
    signals: &RuntimeSignals<'_>,
) -> Result<Option<f64>, SanitizedError> {
    match get_own_enumerable_field(ctx, object, field, signals, extractor_execution_error)? {
        None => Ok(None),
        Some(value) if value.is_null() || value.is_undefined() => Ok(None),
        Some(value) => value
            .as_number()
            .filter(|number| number.is_finite())
            .map(Some)
            .ok_or_else(result_validation_error),
    }
}

fn optional_string_field<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    field: &str,
    signals: &RuntimeSignals<'_>,
) -> Result<Option<String>, SanitizedError> {
    match get_own_enumerable_field(ctx, object, field, signals, extractor_execution_error)? {
        None => Ok(None),
        Some(value) if value.is_null() || value.is_undefined() => Ok(None),
        Some(value) => {
            let value = value.as_string().ok_or_else(result_validation_error)?;
            let value = checked_extractor_quickjs(
                ctx,
                value.to_string(),
                signals,
                extractor_execution_error,
            )?;
            if value.len() > MAX_RESULT_STRING_BYTES {
                Err(result_validation_error())
            } else {
                Ok(Some(value))
            }
        }
    }
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

fn checked_extractor_quickjs<'js, T>(
    ctx: &Ctx<'js>,
    result: rquickjs::Result<T>,
    signals: &RuntimeSignals<'_>,
    error: fn() -> SanitizedError,
) -> Result<T, SanitizedError> {
    match result {
        Ok(value) => signals.terminal_error().map_or(Ok(value), Err),
        Err(quickjs_error) => {
            if matches!(quickjs_error, QuickJsError::Exception) {
                let _ = ctx.catch();
            }
            if let Some(terminal) = signals.terminal_error() {
                Err(terminal)
            } else if matches!(quickjs_error, QuickJsError::Allocation) {
                Err(script_memory_error())
            } else {
                Err(error())
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
    let request = require_plain_object(
        &request_value,
        plain_class,
        &plain_prototype,
        request_validation_error,
    )?;
    let fields = own_enumerable_string_properties(ctx, &request, signals)?;

    let url = require_string_field(ctx, fields.get("url"), signals)?;
    let method = require_string_field(ctx, fields.get("method"), signals)?;
    let headers_value = fields.get("headers").ok_or_else(request_validation_error)?;
    let headers_object = require_plain_object(
        headers_value,
        plain_class,
        &plain_prototype,
        request_validation_error,
    )?;
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
    error: fn() -> SanitizedError,
) -> Result<Object<'js>, SanitizedError> {
    let Some(object) = value.as_object().cloned() else {
        return Err(error());
    };
    if unsafe { qjs::JS_GetClassID(value.as_raw()) } != plain_class {
        return Err(error());
    }
    if object
        .get_prototype()
        .is_some_and(|prototype| prototype != *plain_prototype)
    {
        return Err(error());
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
    sidecar_lifecycle_error()
}

fn request_validation_error() -> SanitizedError {
    sanitized_error(
        "RequestValidation",
        "Relay request script did not produce a valid request.",
    )
}

fn extractor_execution_error() -> SanitizedError {
    sanitized_error(
        "ExtractorExecution",
        "Relay usage extractor could not be executed.",
    )
}

fn result_validation_error() -> SanitizedError {
    sanitized_error(
        "ResultValidation",
        "Relay usage extractor did not produce a valid result.",
    )
}

fn sidecar_lifecycle_error() -> SanitizedError {
    sanitized_error(
        "SidecarLifecycle",
        "Relay script worker could not complete evaluation.",
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

#[cfg(test)]
mod wire_result_validation_tests {
    use super::*;

    fn minimal_wire_result() -> WireUsageResult {
        WireUsageResult {
            is_valid: true,
            invalid_message: None,
            remaining: None,
            unit: None,
            plan_name: None,
            total: None,
            used: None,
            extra: None,
        }
    }

    fn wire_error(results: Vec<WireUsageResult>) -> SanitizedError {
        match validate_wire_results(results) {
            Ok(_) => panic!("wire results unexpectedly validated"),
            Err(error) => error,
        }
    }

    #[test]
    fn parent_rejects_wire_count_above_derived_cap() {
        let results = (0..=MAX_RESULT_COUNT)
            .map(|_| minimal_wire_result())
            .collect();
        assert_eq!(wire_error(results).category, "ResultValidation");
    }

    #[test]
    fn result_count_cap_matches_the_minimum_normalized_wire_shape() {
        fn array_size(count: usize, item_size: usize) -> usize {
            count * item_size + count.saturating_sub(1) + 2
        }

        let minimal = UsageResult {
            is_valid: true,
            invalid_message: Some(String::new()),
            remaining: Some(0.0),
            unit: Some(String::new()),
            plan_name: Some(String::new()),
            total: Some(0.0),
            used: Some(0.0),
            extra: Some(String::new()),
        };
        assert_eq!(
            serde_json::to_vec(&minimal).unwrap().len(),
            MIN_NORMALIZED_RESULT_BYTES
        );
        assert_eq!(MAX_RESULT_COUNT, 2361);
        assert!(
            array_size(MAX_RESULT_COUNT, MIN_NORMALIZED_RESULT_BYTES)
                <= MAX_NORMALIZED_RESULT_BYTES
        );
        assert!(
            array_size(MAX_RESULT_COUNT + 1, MIN_NORMALIZED_RESULT_BYTES)
                > MAX_NORMALIZED_RESULT_BYTES
        );
    }

    #[test]
    fn parent_rejects_oversized_wire_strings_and_cumulative_size() {
        let mut oversized_string = minimal_wire_result();
        oversized_string.unit = Some("a".repeat(MAX_RESULT_STRING_BYTES + 1));
        assert_eq!(
            wire_error(vec![oversized_string]).category,
            "ResultValidation"
        );

        let results = (0..100)
            .map(|_| {
                let mut result = minimal_wire_result();
                result.extra = Some("x".repeat(MAX_RESULT_STRING_BYTES));
                result
            })
            .collect();
        assert_eq!(wire_error(results).category, "ResultValidation");
    }

    #[test]
    fn parent_rejects_nonfinite_wire_numbers() {
        for number in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let mut result = minimal_wire_result();
            result.remaining = Some(number);
            assert_eq!(wire_error(vec![result]).category, "ResultValidation");
        }
    }

    #[test]
    fn worker_protocol_rejects_unknown_fields_and_has_lifecycle_category() {
        let malformed = serde_json::json!({
            "status": "results",
            "results": [{
                "isValid": true,
                "invalidMessage": null,
                "remaining": null,
                "unit": null,
                "planName": null,
                "total": null,
                "used": null,
                "extra": null,
                "unexpected": "field"
            }]
        });
        assert!(serde_json::from_value::<ExtractorWorkerOutput>(malformed).is_err());
        assert_eq!(
            WorkerErrorCategory::SidecarLifecycle
                .into_sanitized_error()
                .category,
            "SidecarLifecycle"
        );
    }
}

#[cfg(test)]
mod legacy_expression_tests {
    use super::*;

    #[test]
    fn strips_trailing_semicolons_and_whitespace_only() {
        assert_eq!(trim_legacy_expression_terminator("({x: 1});"), "({x: 1})");
        assert_eq!(
            trim_legacy_expression_terminator("({x: 1});   \n"),
            "({x: 1})"
        );
        assert_eq!(trim_legacy_expression_terminator("({x: 1});;;"), "({x: 1})");
    }

    #[test]
    fn leaves_internal_semicolons_and_non_terminated_scripts_untouched() {
        assert_eq!(
            trim_legacy_expression_terminator("({x: 1; y: 2})"),
            "({x: 1; y: 2})"
        );
        assert_eq!(
            trim_legacy_expression_terminator("({x: 1});\n  ({y: 2})"),
            "({x: 1});\n  ({y: 2})"
        );
        assert_eq!(
            trim_legacy_expression_terminator("function (r) { return r; }"),
            "function (r) { return r; }"
        );
    }

    #[test]
    fn legacy_object_with_terminator_wraps_to_a_pure_expression() {
        let script = "({ request: { url: \"{{baseUrl}}/v1/usage\", method: \"GET\", headers: {} }, extractor: function (r) { return { isValid: true }; } });";
        let replaced =
            replace_tokens_for_evaluation(script, "https://example.com", &SecretSet::default())
                .unwrap();
        let wrapped = wrap_extractor_source(trim_legacy_expression_terminator(&replaced));
        assert!(!wrapped.trim_end().ends_with(';'));
        assert!(wrapped.trim_start().starts_with("({"));
    }

    #[test]
    fn function_style_script_with_terminator_still_wraps() {
        let script = "function (r) { return { isValid: true, remaining: 1, unit: \"%\" }; };";
        let replaced = replace_tokens_for_evaluation(script, "", &SecretSet::default()).unwrap();
        let wrapped = wrap_extractor_source(trim_legacy_expression_terminator(&replaced));
        assert!(wrapped.starts_with("{extractor: (function"));
        assert!(!wrapped.trim_end().ends_with(';'));
    }
}
