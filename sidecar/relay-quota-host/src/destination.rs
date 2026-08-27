use std::{cell::Cell, fmt, net::IpAddr};

use url::{Host, SyntaxViolation, Url};

use crate::protocol::SanitizedError;

#[derive(Clone)]
pub struct ValidatedDestination {
    url: Url,
    host: String,
    fingerprint: String,
    loopback: bool,
}

impl ValidatedDestination {
    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn fingerprint(&self) -> &str {
        &self.fingerprint
    }

    pub(crate) fn url(&self) -> &Url {
        &self.url
    }

    pub(crate) fn is_loopback(&self) -> bool {
        self.loopback
    }

    pub(crate) fn matches_request_url(&self, request_url: &str) -> bool {
        parse_http_origin(request_url).is_ok_and(|(request_url, _)| request_url == self.url)
    }
}

impl fmt::Debug for ValidatedDestination {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ValidatedDestination")
            .field("host", &self.host)
            .field("fingerprint", &self.fingerprint)
            .field("loopback", &self.loopback)
            .finish()
    }
}

#[derive(PartialEq, Eq)]
struct EffectiveOrigin {
    scheme: String,
    host: String,
    port: u16,
    fingerprint: String,
    loopback: bool,
}

pub fn validate_destination(
    base_url: &str,
    request_url: &str,
    trusted_destination: Option<&str>,
) -> Result<ValidatedDestination, SanitizedError> {
    let (base, base_origin) = parse_http_origin(base_url)?;
    let (url, request_origin) = parse_http_origin(request_url)?;

    if base.query().is_some()
        || request_origin != base_origin
        || (request_origin.scheme != "https" && !request_origin.loopback)
    {
        return Err(destination_validation_error());
    }
    if trusted_destination != Some(request_origin.fingerprint.as_str()) {
        return Err(destination_trust_required(
            &request_origin.host,
            &request_origin.fingerprint,
        ));
    }

    Ok(ValidatedDestination {
        url,
        host: request_origin.host,
        fingerprint: request_origin.fingerprint,
        loopback: request_origin.loopback,
    })
}

fn parse_http_origin(value: &str) -> Result<(Url, EffectiveOrigin), SanitizedError> {
    let embedded_credentials = Cell::new(false);
    let record_violation = |violation| {
        if violation == SyntaxViolation::EmbeddedCredentials {
            embedded_credentials.set(true);
        }
    };
    let parsed = Url::options()
        .syntax_violation_callback(Some(&record_violation))
        .parse(value);
    if embedded_credentials.get() {
        return Err(destination_validation_error());
    }
    let url = parsed.map_err(|_| destination_validation_error())?;
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return Err(destination_validation_error());
    }

    let host = url.host().ok_or_else(destination_validation_error)?;
    let (canonical_host, display_host, loopback) = canonical_host(host);
    let port = url
        .port_or_known_default()
        .ok_or_else(destination_validation_error)?;
    let scheme = url.scheme().to_ascii_lowercase();
    let fingerprint = format!("{scheme}://{display_host}:{port}");

    Ok((
        url,
        EffectiveOrigin {
            scheme,
            host: canonical_host,
            port,
            fingerprint,
            loopback,
        },
    ))
}

fn canonical_host(host: Host<&str>) -> (String, String, bool) {
    match host {
        Host::Domain(domain) => {
            let host = domain.to_ascii_lowercase();
            let loopback = host == "localhost";
            (host.clone(), host, loopback)
        }
        Host::Ipv4(address) => {
            let host = address.to_string();
            (host.clone(), host, IpAddr::V4(address).is_loopback())
        }
        Host::Ipv6(address) => {
            let host = address.to_string();
            (
                host.clone(),
                format!("[{host}]"),
                IpAddr::V6(address).is_loopback(),
            )
        }
    }
}

fn destination_validation_error() -> SanitizedError {
    sanitized_error(
        "DestinationValidation",
        "Relay request destination is not allowed.",
    )
}

fn destination_trust_required(host: &str, fingerprint: &str) -> SanitizedError {
    let mut error = sanitized_error(
        "DestinationTrustRequired",
        "Relay request destination requires explicit trust.",
    );
    error.destination_host = Some(host.into());
    error.destination_fingerprint = Some(fingerprint.into());
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
