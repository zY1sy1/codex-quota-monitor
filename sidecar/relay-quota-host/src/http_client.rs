use std::{error::Error, fmt, io::Read, time::Duration};

use reqwest::{
    blocking::{Client, Response},
    header::{HeaderMap, HeaderName, HeaderValue, RETRY_AFTER},
    Method,
};

use crate::{destination::ValidatedDestination, protocol::SanitizedError, script::ScriptRequest};

const MAX_RESPONSE_BYTES: usize = 1_048_576;
const MIN_HTTP_TIMEOUT_MS: u64 = 1;
const MAX_HTTP_TIMEOUT_MS: u64 = 30_000;

#[derive(Clone, PartialEq)]
pub struct HttpResponse {
    pub status: u16,
    pub json: serde_json::Value,
}

impl fmt::Debug for HttpResponse {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HttpResponse")
            .field("status", &self.status)
            .field("json", &"<redacted>")
            .finish()
    }
}

pub fn execute_request(
    destination: &ValidatedDestination,
    request: &ScriptRequest,
    timeout_ms: u64,
) -> Result<HttpResponse, SanitizedError> {
    if !destination.matches_request_url(&request.url) {
        return Err(request_validation_error());
    }
    let timeout = validated_timeout(timeout_ms)?;
    let method =
        Method::from_bytes(request.method.as_bytes()).map_err(|_| request_validation_error())?;
    let headers = validated_headers(request)?;
    let mut client_builder = Client::builder()
        .connect_timeout(timeout)
        .timeout(timeout)
        .redirect(reqwest::redirect::Policy::none());
    if destination.is_loopback() {
        client_builder = client_builder.no_proxy();
    }
    let client = client_builder
        .build()
        .map_err(|_| sidecar_lifecycle_error())?;

    let mut builder = client
        .request(method, destination.url().clone())
        .headers(headers);
    if let Some(body) = &request.body {
        builder = builder.body(body.clone());
    }
    let response = builder.send().map_err(transport_error)?;
    consume_response(response)
}

fn validated_timeout(timeout_ms: u64) -> Result<Duration, SanitizedError> {
    if !(MIN_HTTP_TIMEOUT_MS..=MAX_HTTP_TIMEOUT_MS).contains(&timeout_ms) {
        return Err(request_validation_error());
    }
    Ok(Duration::from_millis(timeout_ms))
}

fn validated_headers(request: &ScriptRequest) -> Result<HeaderMap, SanitizedError> {
    let mut headers = HeaderMap::with_capacity(request.headers.len());
    for (name, value) in &request.headers {
        let name =
            HeaderName::from_bytes(name.as_bytes()).map_err(|_| request_validation_error())?;
        let mut value = HeaderValue::from_str(value).map_err(|_| request_validation_error())?;
        value.set_sensitive(true);
        headers.insert(name, value);
    }
    Ok(headers)
}

fn consume_response(mut response: Response) -> Result<HttpResponse, SanitizedError> {
    let status = response.status();
    if !status.is_success() {
        return Err(http_status_error(
            status.as_u16(),
            parse_retry_after(response.headers()),
        ));
    }

    if response
        .content_length()
        .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
    {
        return Err(response_too_large_error());
    }

    let mut body = Vec::new();
    response
        .by_ref()
        .take((MAX_RESPONSE_BYTES + 1) as u64)
        .read_to_end(&mut body)
        .map_err(transport_io_error)?;
    if body.len() > MAX_RESPONSE_BYTES {
        return Err(response_too_large_error());
    }
    let json = serde_json::from_slice(&body).map_err(|_| invalid_json_error())?;
    Ok(HttpResponse {
        status: status.as_u16(),
        json,
    })
}

fn parse_retry_after(headers: &HeaderMap) -> Option<u64> {
    headers
        .get(RETRY_AFTER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse().ok())
}

fn transport_error(error: reqwest::Error) -> SanitizedError {
    transport_category_error(classify_transport_source(&error))
}

fn transport_io_error(error: std::io::Error) -> SanitizedError {
    transport_category_error(classify_transport_source(&error))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TransportCategory {
    Timeout,
    Dns,
    Tls,
    Connectivity,
}

fn classify_transport_source(root: &(dyn Error + 'static)) -> TransportCategory {
    let mut pending = vec![root];
    let mut saw_timeout = false;
    let mut saw_dns = false;
    let mut saw_tls = false;

    // Transport chains are short, but cap traversal so an unexpected cyclic
    // third-party Error implementation can never stall the sidecar. io::Error
    // keeps its boxed typed cause behind get_ref(), which Error::source() does
    // not consistently expose on all supported toolchains.
    for _ in 0..64 {
        let Some(error) = pending.pop() else {
            break;
        };
        if error
            .downcast_ref::<reqwest::Error>()
            .is_some_and(reqwest::Error::is_timeout)
        {
            saw_timeout = true;
        }
        if let Some(error) = error.downcast_ref::<std::io::Error>() {
            saw_timeout |= matches!(
                error.kind(),
                std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
            );
            saw_dns |= is_dns_resolver_error(error);
            if let Some(inner) = error.get_ref() {
                pending.push(inner);
            }
        }
        saw_tls |= error.downcast_ref::<rustls::Error>().is_some();
        if let Some(source) = error.source() {
            pending.push(source);
        }
    }

    if saw_timeout {
        TransportCategory::Timeout
    } else if saw_dns {
        TransportCategory::Dns
    } else if saw_tls {
        TransportCategory::Tls
    } else {
        TransportCategory::Connectivity
    }
}

#[cfg(windows)]
fn is_dns_resolver_error(error: &std::io::Error) -> bool {
    // Winsock getaddrinfo resolver failures. These numeric codes are stable
    // platform API values, unlike localized error strings.
    matches!(error.raw_os_error(), Some(11_001..=11_004))
}

#[cfg(not(windows))]
fn is_dns_resolver_error(_error: &std::io::Error) -> bool {
    false
}

fn transport_category_error(category: TransportCategory) -> SanitizedError {
    match category {
        TransportCategory::Timeout => timeout_error(),
        TransportCategory::Dns => dns_error(),
        TransportCategory::Tls => tls_error(),
        TransportCategory::Connectivity => connectivity_error(),
    }
}

fn request_validation_error() -> SanitizedError {
    sanitized_error("RequestValidation", "Relay request is invalid.")
}

fn sidecar_lifecycle_error() -> SanitizedError {
    sanitized_error(
        "SidecarLifecycle",
        "Relay HTTP client could not be initialized.",
    )
}

fn connectivity_error() -> SanitizedError {
    sanitized_error(
        "Connectivity",
        "Relay request could not reach its destination.",
    )
}

fn dns_error() -> SanitizedError {
    sanitized_error("Dns", "Relay destination name could not be resolved.")
}

fn tls_error() -> SanitizedError {
    sanitized_error("Tls", "Relay TLS negotiation failed.")
}

fn timeout_error() -> SanitizedError {
    sanitized_error("Timeout", "Relay request exceeded its timeout.")
}

fn response_too_large_error() -> SanitizedError {
    sanitized_error(
        "ResponseTooLarge",
        "Relay response exceeds the allowed size.",
    )
}

fn invalid_json_error() -> SanitizedError {
    sanitized_error("InvalidJson", "Relay response is not valid JSON.")
}

fn http_status_error(status: u16, retry_after_seconds: Option<u64>) -> SanitizedError {
    let mut error = sanitized_error(
        "HttpStatus",
        "Relay destination returned an unsuccessful HTTP status.",
    );
    error.http_status = Some(status);
    error.retry_after_seconds = retry_after_seconds;
    error
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

#[cfg(test)]
mod classification_tests {
    use std::{collections::BTreeMap, error::Error, fmt, io};

    use super::*;

    #[derive(Debug)]
    struct ErrorWrapper(io::Error);

    impl fmt::Display for ErrorWrapper {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.write_str("opaque transport wrapper")
        }
    }

    impl Error for ErrorWrapper {
        fn source(&self) -> Option<&(dyn Error + 'static)> {
            Some(&self.0)
        }
    }

    #[cfg(windows)]
    #[test]
    fn windows_resolver_error_codes_are_dns_without_message_matching() {
        for code in [11_001, 11_002, 11_003, 11_004] {
            let error = ErrorWrapper(io::Error::from_raw_os_error(code));
            let category = classify_transport_source(&error);
            assert_eq!(category, TransportCategory::Dns);
            let sanitized = transport_category_error(category);
            assert_eq!(sanitized.category, "Dns");
            assert_eq!(
                sanitized.message,
                "Relay destination name could not be resolved."
            );
            assert!(sanitized.http_status.is_none());
            assert!(sanitized.destination_host.is_none());
        }
    }

    #[test]
    fn ordinary_io_failures_remain_connectivity() {
        let error = ErrorWrapper(io::Error::from(io::ErrorKind::ConnectionRefused));
        assert_eq!(
            classify_transport_source(&error),
            TransportCategory::Connectivity
        );
    }

    #[test]
    fn timeout_has_priority_over_a_nested_tls_error() {
        let error = ErrorWrapper(io::Error::new(
            io::ErrorKind::TimedOut,
            rustls::Error::General("test-only TLS marker".into()),
        ));
        assert_eq!(
            classify_transport_source(&error),
            TransportCategory::Timeout
        );
    }

    #[test]
    fn script_origin_headers_are_marked_sensitive() {
        let mut headers = BTreeMap::new();
        headers.insert("Authorization".into(), "Bearer sentinel-secret".into());
        let request = ScriptRequest {
            url: "https://example.com/usage".into(),
            method: "GET".into(),
            headers,
            body: None,
        };

        let validated = match validated_headers(&request) {
            Ok(headers) => headers,
            Err(error) => panic!("header validation failed: {}", error.category),
        };
        assert!(validated["authorization"].is_sensitive());
        assert!(!format!("{validated:?}").contains("sentinel-secret"));
    }

    #[test]
    fn http_response_debug_redacts_raw_json() {
        let response = HttpResponse {
            status: 200,
            json: serde_json::json!({"secret":"sentinel-secret"}),
        };

        let debug = format!("{response:?}");
        assert!(debug.contains("200"));
        assert!(!debug.contains("sentinel-secret"));
    }
}
