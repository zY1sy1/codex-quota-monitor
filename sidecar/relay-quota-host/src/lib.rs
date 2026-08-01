pub mod destination;
pub mod http_client;
pub mod protocol;
pub mod script;

use std::{
    io::{self, Read, Write},
    panic::{catch_unwind, AssertUnwindSafe},
    time::Instant,
};

use protocol::{HostResponse, QueryCommand, SanitizedError};

const MAX_COMMAND_LINE_BYTES: usize = 512 * 1024;
const MAX_RESPONSE_ID_BYTES: usize = 128;
const MIN_QUERY_TIMEOUT_MS: u64 = 2_000;
const MAX_QUERY_TIMEOUT_MS: u64 = 30_000;
const READ_BUFFER_BYTES: usize = 8 * 1024;

pub fn handle_line(line: &[u8]) -> HostResponse {
    let line = line.strip_suffix(b"\r").unwrap_or(line);
    if line.len() > MAX_COMMAND_LINE_BYTES {
        return protocol_failure();
    }
    let Ok(text) = std::str::from_utf8(line) else {
        return protocol_failure();
    };
    if text.is_empty() {
        return protocol_failure();
    }
    let Ok(command) = serde_json::from_str::<QueryCommand>(text) else {
        return protocol_failure();
    };
    let secrets = SecretMatcher::new(&command.secrets);
    let response = match validated_response_id(&command.id, &secrets) {
        Some(response_id) => execute_query(&command, response_id),
        None => protocol_failure(),
    };
    apply_output_security_boundary(response, &secrets)
}

pub fn run_jsonl<R: Read, W: Write>(reader: R, mut writer: W) -> io::Result<()> {
    let mut lines = BoundedLineReader::new(reader);
    loop {
        let frame = match lines.next_line() {
            Ok(Some(frame)) => frame,
            Ok(None) => return Ok(()),
            Err(_) => {
                write_response(&mut writer, &lifecycle_failure())?;
                return Err(io::Error::other("relay input failed"));
            }
        };
        let response = match frame {
            FramedLine::Overlong => protocol_failure(),
            FramedLine::Line(line) => match catch_unwind(AssertUnwindSafe(|| handle_line(&line))) {
                Ok(response) => response,
                Err(_) => lifecycle_failure(),
            },
        };
        write_response(&mut writer, &response)?;
    }
}

fn execute_query(command: &QueryCommand, response_id: &str) -> HostResponse {
    let started = Instant::now();
    let request =
        match script::evaluate_request(&command.script, &command.base_url, &command.secrets) {
            Ok(request) => request,
            Err(error) => return HostResponse::failure(response_id, error),
        };
    let destination = match destination::validate_destination(
        command.template_type,
        &command.base_url,
        &request.url,
        command.trusted_destination.as_deref(),
    ) {
        Ok(destination) => destination,
        Err(error) => return HostResponse::failure(response_id, error),
    };
    let timeout_ms = clamp_timeout_ms(command.timeout_ms);
    let response = match http_client::execute_request(&destination, &request, timeout_ms) {
        Ok(response) => response,
        Err(error) => return HostResponse::failure(response_id, error),
    };
    let results = match script::evaluate_extractor_with_context(
        &command.script,
        &response.json,
        &command.base_url,
        &command.secrets,
    ) {
        Ok(results) => results,
        Err(error) => return HostResponse::failure(response_id, error),
    };
    let duration_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    HostResponse::success(
        response_id,
        results,
        response.status,
        destination.host(),
        duration_ms,
    )
}

fn clamp_timeout_ms(timeout_ms: u64) -> u64 {
    timeout_ms.clamp(MIN_QUERY_TIMEOUT_MS, MAX_QUERY_TIMEOUT_MS)
}

fn validated_response_id<'a>(id: &'a str, secrets: &SecretMatcher<'_>) -> Option<&'a str> {
    (!id.is_empty()
        && id.len() <= MAX_RESPONSE_ID_BYTES
        && !id.chars().any(char::is_control)
        && !secrets.contains(id))
    .then_some(id)
}

/// Final JSONL composition boundary for command-derived strings.
///
/// Empty credentials are ignored. Every non-empty credential, including short
/// and overlapping values, is matched as an ASCII-case-insensitive substring
/// so URL host canonicalization cannot bypass the check. This intentionally
/// applies only to dynamic response values; stable protocol keys, categories,
/// and messages are constants rather than command-derived credential data.
struct SecretMatcher<'a> {
    values: [&'a str; 3],
}

impl<'a> SecretMatcher<'a> {
    fn new(secrets: &'a protocol::SecretSet) -> Self {
        Self {
            values: [
                secrets.api_key.as_str(),
                secrets.access_token.as_str(),
                secrets.user_id.as_str(),
            ],
        }
    }

    fn contains(&self, value: &str) -> bool {
        self.values
            .iter()
            .any(|secret| !secret.is_empty() && contains_ascii_case_insensitive(value, secret))
    }
}

fn contains_ascii_case_insensitive(value: &str, secret: &str) -> bool {
    secret.len() <= value.len()
        && value
            .as_bytes()
            .windows(secret.len())
            .any(|window| window.eq_ignore_ascii_case(secret.as_bytes()))
}

fn apply_output_security_boundary(
    response: HostResponse,
    secrets: &SecretMatcher<'_>,
) -> HostResponse {
    match response {
        HostResponse::Success(success) => {
            if secrets.contains(&success.id) {
                return protocol_failure();
            }
            if secrets.contains(&success.meta.destination_host)
                || success
                    .results
                    .iter()
                    .any(|result| result_contains_secret(result, secrets))
            {
                HostResponse::failure(success.id, result_validation_error())
            } else {
                HostResponse::Success(success)
            }
        }
        HostResponse::Failure(mut failure) => {
            if secrets.contains(&failure.id) {
                return protocol_failure();
            }
            if failure
                .error
                .destination_host
                .as_deref()
                .is_some_and(|host| secrets.contains(host))
            {
                failure.error.destination_host = None;
            }
            if failure
                .error
                .destination_fingerprint
                .as_deref()
                .is_some_and(|fingerprint| secrets.contains(fingerprint))
            {
                failure.error.destination_fingerprint = None;
            }
            HostResponse::Failure(failure)
        }
    }
}

fn result_contains_secret(result: &protocol::UsageResult, secrets: &SecretMatcher<'_>) -> bool {
    [
        result.invalid_message.as_deref(),
        result.unit.as_deref(),
        result.plan_name.as_deref(),
        result.extra.as_deref(),
    ]
    .into_iter()
    .flatten()
    .any(|value| secrets.contains(value))
}

fn write_response(writer: &mut impl Write, response: &HostResponse) -> io::Result<()> {
    serde_json::to_writer(&mut *writer, response).map_err(io::Error::other)?;
    writer.write_all(b"\n")?;
    writer.flush()
}

fn protocol_failure() -> HostResponse {
    HostResponse::failure("", protocol_error())
}

fn lifecycle_failure() -> HostResponse {
    HostResponse::failure("", lifecycle_error())
}

fn protocol_error() -> SanitizedError {
    sanitized_error("Protocol", "Relay command is invalid.")
}

fn lifecycle_error() -> SanitizedError {
    sanitized_error(
        "SidecarLifecycle",
        "Relay sidecar could not complete the command.",
    )
}

fn result_validation_error() -> SanitizedError {
    sanitized_error(
        "ResultValidation",
        "Relay usage extractor did not produce a valid result.",
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

enum FramedLine {
    Line(Vec<u8>),
    Overlong,
}

struct BoundedLineReader<R> {
    reader: R,
    buffer: [u8; READ_BUFFER_BYTES],
    cursor: usize,
    buffered: usize,
    eof: bool,
}

impl<R: Read> BoundedLineReader<R> {
    fn new(reader: R) -> Self {
        Self {
            reader,
            buffer: [0; READ_BUFFER_BYTES],
            cursor: 0,
            buffered: 0,
            eof: false,
        }
    }

    fn next_line(&mut self) -> io::Result<Option<FramedLine>> {
        let mut line = Vec::new();
        let mut overlong = false;
        let mut saw_data = false;
        loop {
            if self.cursor == self.buffered {
                if self.eof {
                    if !saw_data {
                        return Ok(None);
                    }
                    return Ok(Some(finish_frame(line, overlong)));
                }
                self.buffered = self.reader.read(&mut self.buffer)?;
                self.cursor = 0;
                if self.buffered == 0 {
                    self.eof = true;
                    continue;
                }
            }

            let byte = self.buffer[self.cursor];
            self.cursor += 1;
            saw_data = true;
            if byte == b'\n' {
                return Ok(Some(finish_frame(line, overlong)));
            }
            if overlong {
                continue;
            }
            if line.len() <= MAX_COMMAND_LINE_BYTES {
                line.push(byte);
            } else {
                overlong = true;
            }
        }
    }
}

fn finish_frame(mut line: Vec<u8>, overlong: bool) -> FramedLine {
    if overlong {
        return FramedLine::Overlong;
    }
    if line.last() == Some(&b'\r') {
        line.pop();
    }
    if line.len() > MAX_COMMAND_LINE_BYTES {
        FramedLine::Overlong
    } else {
        FramedLine::Line(line)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timeout_is_clamped_at_both_public_limits() {
        assert_eq!(clamp_timeout_ms(0), 2_000);
        assert_eq!(clamp_timeout_ms(2_001), 2_001);
        assert_eq!(clamp_timeout_ms(u64::MAX), 30_000);
    }

    #[test]
    fn final_boundary_never_preserves_a_secret_bearing_success_id() {
        let secrets = protocol::SecretSet {
            api_key: "boundary-secret".into(),
            access_token: String::new(),
            user_id: String::new(),
        };
        let matcher = SecretMatcher::new(&secrets);
        let response = HostResponse::success(
            "prefix-BOUNDARY-SECRET-suffix",
            vec![protocol::UsageResult {
                is_valid: true,
                invalid_message: None,
                remaining: Some(1.0),
                unit: None,
                plan_name: None,
                total: None,
                used: None,
                extra: None,
            }],
            200,
            "safe.example",
            1,
        );

        let encoded = serde_json::to_value(apply_output_security_boundary(response, &matcher))
            .expect("serialize boundary response");
        assert!(encoded["id"].as_str().is_some_and(str::is_empty));
        assert_eq!(encoded["error"]["category"], "Protocol");
    }
}
