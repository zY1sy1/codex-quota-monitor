use relay_quota_host::destination::validate_destination;
use relay_quota_host::protocol::{SanitizedError, TemplateType};

fn expect_ok<T>(result: Result<T, SanitizedError>) -> T {
    match result {
        Ok(value) => value,
        Err(error) => panic!("expected success, got category {}", error.category),
    }
}

fn category(
    result: Result<
        relay_quota_host::destination::ValidatedDestination,
        relay_quota_host::protocol::SanitizedError,
    >,
) -> String {
    result.unwrap_err().category
}

#[test]
fn built_in_requires_https_and_same_effective_origin() {
    let destination = expect_ok(validate_destination(
        TemplateType::Wakaka,
        "https://API.WKKAPI.COM",
        "https://api.wkkapi.com/v1/usage",
        None,
    ));
    assert_eq!(destination.host(), "api.wkkapi.com");
    assert_eq!(destination.fingerprint(), "https://api.wkkapi.com:443");

    assert_eq!(
        category(validate_destination(
            TemplateType::Wakaka,
            "https://api.wkkapi.com",
            "http://api.wkkapi.com/v1/usage",
            None,
        )),
        "DestinationValidation"
    );
    assert_eq!(
        category(validate_destination(
            TemplateType::General,
            "https://a.example",
            "https://b.example/user/balance",
            None,
        )),
        "DestinationValidation"
    );
    assert_eq!(
        category(validate_destination(
            TemplateType::NewApi,
            "https://a.example",
            "https://a.example:444/api/user/self",
            None,
        )),
        "DestinationValidation"
    );
}

#[test]
fn built_in_allows_only_exact_loopback_hosts_over_http() {
    for base_url in [
        "http://localhost:18080",
        "http://127.0.0.1:18080",
        "http://127.255.1.2:18080",
        "http://[::1]:18080",
    ] {
        let request_url = format!("{base_url}/user/balance");
        assert!(
            validate_destination(TemplateType::General, base_url, &request_url, None).is_ok(),
            "expected loopback origin {base_url} to be accepted"
        );
    }

    for host in ["localhost.example", "128.0.0.1", "[::2]"] {
        let base_url = format!("http://{host}:18080");
        let request_url = format!("{base_url}/user/balance");
        assert_eq!(
            category(validate_destination(
                TemplateType::General,
                &base_url,
                &request_url,
                None,
            )),
            "DestinationValidation"
        );
    }
}

#[test]
fn fingerprints_include_effective_ports_and_bracket_ipv6() {
    let https = expect_ok(validate_destination(
        TemplateType::Custom,
        "https://unused.example",
        "https://Example.COM/usage",
        Some("https://example.com:443"),
    ));
    assert_eq!(https.fingerprint(), "https://example.com:443");

    let ipv6 = expect_ok(validate_destination(
        TemplateType::Custom,
        "https://unused.example",
        "http://[::1]/usage",
        Some("http://[::1]:80"),
    ));
    assert_eq!(ipv6.host(), "::1");
    assert_eq!(ipv6.fingerprint(), "http://[::1]:80");
}

#[test]
fn custom_requires_the_exact_canonical_trusted_fingerprint() {
    let accepted = expect_ok(validate_destination(
        TemplateType::Custom,
        "https://a.example",
        "http://relay.example:8080/usage",
        Some("http://relay.example:8080"),
    ));
    assert_eq!(accepted.host(), "relay.example");

    for trusted in [
        None,
        Some("http://other.example:8080"),
        Some("HTTP://relay.example:8080"),
        Some("http://relay.example"),
    ] {
        let error = validate_destination(
            TemplateType::Custom,
            "https://a.example",
            "http://relay.example:8080/usage",
            trusted,
        )
        .unwrap_err();
        assert_eq!(error.category, "DestinationTrustRequired");
        assert_eq!(error.destination_host.as_deref(), Some("relay.example"));
        assert_eq!(
            error.destination_fingerprint.as_deref(),
            Some("http://relay.example:8080")
        );
        assert!(!error.message.contains("/usage"));
    }
}

#[test]
fn credentials_fragments_and_non_http_schemes_are_rejected() {
    for request_url in [
        "https://user@example.com/usage",
        "https://@example.com/usage",
        r"http:\\@example.com/usage",
        "https://example.com/usage#secret-fragment",
        "ftp://example.com/usage",
        "not a url",
    ] {
        let error = validate_destination(
            TemplateType::Custom,
            "https://base.example",
            request_url,
            Some("https://example.com:443"),
        )
        .unwrap_err();
        assert_eq!(error.category, "DestinationValidation");
        assert!(error.destination_host.is_none());
        assert!(error.destination_fingerprint.is_none());
        assert!(!error.message.contains(request_url));
    }

    assert_eq!(
        category(validate_destination(
            TemplateType::General,
            "https://user:password@example.com",
            "https://example.com/user/balance",
            None,
        )),
        "DestinationValidation"
    );

    for base_url in [
        "https://user:password@base.example",
        "https://base.example/root#fragment",
        "file:///not-an-http-base",
    ] {
        assert_eq!(
            category(validate_destination(
                TemplateType::Custom,
                base_url,
                "https://example.com/usage",
                Some("https://example.com:443"),
            )),
            "DestinationValidation"
        );
    }
}

#[test]
fn normal_urls_remain_valid_when_no_embedded_credentials_are_reported() {
    let destination = expect_ok(validate_destination(
        TemplateType::Custom,
        "https://base.example",
        "https://example.com/usage",
        Some("https://example.com:443"),
    ));
    assert_eq!(destination.host(), "example.com");

    let normalized = expect_ok(validate_destination(
        TemplateType::Custom,
        "https://base.example",
        r"http:\\example.com/usage",
        Some("http://example.com:80"),
    ));
    assert_eq!(normalized.fingerprint(), "http://example.com:80");
}

#[test]
fn validated_destination_debug_never_contains_the_request_path_or_query() {
    let destination = expect_ok(validate_destination(
        TemplateType::Custom,
        "https://base.example",
        "https://example.com/private/usage?apiKey=sentinel-secret",
        Some("https://example.com:443"),
    ));

    let debug = format!("{destination:?}");
    assert!(debug.contains("example.com"));
    assert!(!debug.contains("private/usage"));
    assert!(!debug.contains("sentinel-secret"));
}
