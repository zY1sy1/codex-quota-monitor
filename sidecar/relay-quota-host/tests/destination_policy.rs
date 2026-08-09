use relay_quota_host::destination::validate_destination;
use relay_quota_host::protocol::SanitizedError;

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
fn generic_requires_exact_trusted_origin_and_allows_https_after_trust() {
    let error = validate_destination(
        "https://relay.example/usage",
        "https://relay.example/usage",
        None,
    )
    .expect_err("first generic destination must require trust");
    assert_eq!(error.category, "DestinationTrustRequired");
    assert_eq!(error.destination_host.as_deref(), Some("relay.example"));
    assert_eq!(
        error.destination_fingerprint.as_deref(),
        Some("https://relay.example:443")
    );

    let destination = expect_ok(validate_destination(
        "https://relay.example/usage",
        "https://relay.example/usage",
        Some("https://relay.example:443"),
    ));
    assert_eq!(destination.host(), "relay.example");
    assert_eq!(destination.fingerprint(), "https://relay.example:443");
}

#[test]
fn generic_rejects_a_path_that_changes_the_origin() {
    let error = validate_destination(
        "https://relay.example",
        "https://other.example/private",
        Some("https://relay.example:443"),
    )
    .expect_err("cross origin");
    assert_eq!(error.category, "DestinationValidation");
}

#[test]
fn http_is_allowed_only_for_loopback_and_still_requires_trust() {
    for (base_url, trusted) in [
        ("http://localhost:18080", "http://localhost:18080"),
        ("http://127.0.0.1:18080", "http://127.0.0.1:18080"),
        ("http://127.255.1.2:18080", "http://127.255.1.2:18080"),
        ("http://[::1]:18080", "http://[::1]:18080"),
    ] {
        let request_url = format!("{base_url}/usage");
        assert_eq!(
            category(validate_destination(base_url, &request_url, None)),
            "DestinationTrustRequired"
        );
        assert!(validate_destination(base_url, &request_url, Some(trusted)).is_ok());
    }

    for base_url in [
        "http://localhost.example:18080",
        "http://128.0.0.1:18080",
        "http://[::2]:18080",
    ] {
        let request_url = format!("{base_url}/usage");
        assert_eq!(
            category(validate_destination(base_url, &request_url, Some(base_url))),
            "DestinationValidation"
        );
    }
}

#[test]
fn fingerprints_include_effective_ports_and_bracket_ipv6() {
    let https = expect_ok(validate_destination(
        "https://Example.COM",
        "https://Example.COM/usage",
        Some("https://example.com:443"),
    ));
    assert_eq!(https.fingerprint(), "https://example.com:443");

    let ipv6 = expect_ok(validate_destination(
        "http://[::1]",
        "http://[::1]/usage",
        Some("http://[::1]:80"),
    ));
    assert_eq!(ipv6.host(), "::1");
    assert_eq!(ipv6.fingerprint(), "http://[::1]:80");
}

#[test]
fn trust_must_be_the_exact_canonical_request_fingerprint() {
    for trusted in [
        None,
        Some("http://other.example:8080"),
        Some("HTTP://relay.example:8080"),
        Some("http://relay.example"),
    ] {
        let error = validate_destination(
            "http://relay.example:8080",
            "http://relay.example:8080/usage",
            trusted,
        )
        .unwrap_err();
        assert_eq!(error.category, "DestinationValidation");
    }

    let error = validate_destination(
        "https://relay.example",
        "https://relay.example/usage",
        Some("https://other.example:443"),
    )
    .unwrap_err();
    assert_eq!(error.category, "DestinationTrustRequired");
    assert_eq!(error.destination_host.as_deref(), Some("relay.example"));
    assert_eq!(
        error.destination_fingerprint.as_deref(),
        Some("https://relay.example:443")
    );
}

#[test]
fn credentials_fragments_queries_and_non_http_schemes_are_rejected() {
    for request_url in [
        "https://user@example.com/usage",
        "https://@example.com/usage",
        "https://example.com/usage#secret-fragment",
        "ftp://example.com/usage",
        "not a url",
    ] {
        let error = validate_destination(
            "https://example.com",
            request_url,
            Some("https://example.com:443"),
        )
        .unwrap_err();
        assert_eq!(error.category, "DestinationValidation");
        assert!(error.destination_host.is_none());
        assert!(error.destination_fingerprint.is_none());
        assert!(!error.message.contains(request_url));
    }

    for base_url in [
        "https://user:password@base.example",
        "https://base.example/root#fragment",
        "https://base.example/root?query=secret",
        "file:///not-an-http-base",
    ] {
        assert_eq!(
            category(validate_destination(
                base_url,
                "https://base.example/usage",
                Some("https://base.example:443"),
            )),
            "DestinationValidation"
        );
    }
}

#[test]
fn validated_destination_debug_never_contains_the_request_path_or_query() {
    let destination = expect_ok(validate_destination(
        "https://example.com",
        "https://example.com/private/usage?apiKey=sentinel-secret",
        Some("https://example.com:443"),
    ));

    let debug = format!("{destination:?}");
    assert!(debug.contains("example.com"));
    assert!(!debug.contains("private/usage"));
    assert!(!debug.contains("sentinel-secret"));
}
