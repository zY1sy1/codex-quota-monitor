use std::{
    collections::BTreeMap,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{mpsc, Arc, Barrier},
    thread,
    time::{Duration, Instant},
};

use relay_quota_host::{
    destination::validate_destination,
    http_client::execute_request,
    protocol::{SanitizedError, TemplateType},
    script::ScriptRequest,
};

const MAX_RESPONSE_BYTES: usize = 1_048_576;

fn expect_ok<T>(result: Result<T, SanitizedError>) -> T {
    match result {
        Ok(value) => value,
        Err(error) => panic!("expected success, got category {}", error.category),
    }
}

struct TestServer {
    origin: String,
    request: mpsc::Receiver<Vec<u8>>,
    handle: thread::JoinHandle<()>,
}

impl TestServer {
    fn respond(response: Vec<u8>, delay: Duration) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (sender, request) = mpsc::channel();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let captured = read_request(&mut stream);
            sender.send(captured).unwrap();
            if !delay.is_zero() {
                thread::sleep(delay);
            }
            let _ = stream.write_all(&response);
        });
        Self {
            origin: format!("http://{address}"),
            request,
            handle,
        }
    }

    fn finish(self) -> Vec<u8> {
        let request = self.request.recv_timeout(Duration::from_secs(2)).unwrap();
        self.handle.join().unwrap();
        request
    }
}

fn read_request(stream: &mut TcpStream) -> Vec<u8> {
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let mut captured = Vec::new();
    let mut buffer = [0_u8; 4096];
    let mut expected_length = None;
    loop {
        let read = stream.read(&mut buffer).unwrap();
        if read == 0 {
            break;
        }
        captured.extend_from_slice(&buffer[..read]);
        if let Some(header_end) = find_bytes(&captured, b"\r\n\r\n") {
            let body_start = header_end + 4;
            let content_length = expected_length.get_or_insert_with(|| {
                let headers = String::from_utf8_lossy(&captured[..header_end]);
                headers
                    .lines()
                    .find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        name.eq_ignore_ascii_case("content-length")
                            .then(|| value.trim().parse::<usize>().unwrap())
                    })
                    .unwrap_or(0)
            });
            if captured.len() >= body_start + *content_length {
                break;
            }
        }
    }
    captured
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn response(status: &str, headers: &[(&str, String)], body: &[u8]) -> Vec<u8> {
    let mut bytes = format!("HTTP/1.1 {status}\r\nConnection: close\r\n").into_bytes();
    for (name, value) in headers {
        bytes.extend_from_slice(format!("{name}: {value}\r\n").as_bytes());
    }
    bytes.extend_from_slice(format!("Content-Length: {}\r\n\r\n", body.len()).as_bytes());
    bytes.extend_from_slice(body);
    bytes
}

fn request(url: String) -> ScriptRequest {
    ScriptRequest {
        url,
        method: "GET".into(),
        headers: BTreeMap::new(),
        body: None,
    }
}

fn run(
    server: &TestServer,
    request: &ScriptRequest,
    timeout_ms: u64,
) -> Result<relay_quota_host::http_client::HttpResponse, relay_quota_host::protocol::SanitizedError>
{
    let destination = expect_ok(validate_destination(
        TemplateType::General,
        &server.origin,
        &request.url,
        None,
    ));
    execute_request(&destination, request, timeout_ms)
}

#[test]
fn sends_arbitrary_valid_method_headers_and_string_body() {
    let server = TestServer::respond(
        response(
            "200 OK",
            &[("Content-Type", "application/json".into())],
            br#"{"balance":18.42}"#,
        ),
        Duration::ZERO,
    );
    let mut headers = BTreeMap::new();
    headers.insert("Authorization".into(), "Bearer sentinel-secret".into());
    headers.insert("X-User".into(), "42".into());
    let scripted_request = ScriptRequest {
        url: format!("{}/v1/usage", server.origin),
        method: "PATCH".into(),
        headers,
        body: Some("request-body".into()),
    };

    let received = expect_ok(run(&server, &scripted_request, 2_000));
    assert_eq!(received.status, 200);
    assert_eq!(received.json["balance"], 18.42);

    let request = String::from_utf8(server.finish()).unwrap();
    assert!(request.starts_with("PATCH /v1/usage HTTP/1.1\r\n"));
    assert!(request.contains("authorization: Bearer sentinel-secret\r\n"));
    assert!(request.contains("x-user: 42\r\n"));
    assert!(request.ends_with("\r\n\r\nrequest-body"));
}

#[test]
fn rejects_invalid_methods_and_headers_without_contacting_the_server() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let destination = expect_ok(validate_destination(
        TemplateType::General,
        &origin,
        &format!("{origin}/usage"),
        None,
    ));

    let invalid_method = ScriptRequest {
        url: format!("{origin}/usage"),
        method: "BAD METHOD".into(),
        headers: BTreeMap::new(),
        body: None,
    };
    let error = execute_request(&destination, &invalid_method, 250).unwrap_err();
    assert_eq!(error.category, "RequestValidation");
    assert!(listener.accept().is_err());

    let mut invalid_headers = BTreeMap::new();
    invalid_headers.insert(
        "Authorization".into(),
        "Bearer sentinel\r\nInjected: yes".into(),
    );
    let invalid_header = ScriptRequest {
        url: format!("{origin}/usage"),
        method: "GET".into(),
        headers: invalid_headers,
        body: None,
    };
    let error = execute_request(&destination, &invalid_header, 250).unwrap_err();
    assert_eq!(error.category, "RequestValidation");
    assert!(!error.message.contains("sentinel"));
    assert!(listener.accept().is_err());
}

#[test]
fn rejects_a_request_url_that_differs_from_the_validated_url_without_contact() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let validated_url = format!("{origin}/validated");
    let destination = expect_ok(validate_destination(
        TemplateType::General,
        &origin,
        &validated_url,
        None,
    ));
    let mismatched = request(format!("{origin}/different"));

    let error = execute_request(&destination, &mismatched, 50).unwrap_err();
    assert_eq!(error.category, "RequestValidation");
    assert_eq!(error.message, "Relay request is invalid.");
    assert!(listener.accept().is_err());
}

#[test]
fn rejects_zero_and_extreme_timeouts_without_contact() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let scripted_request = request(format!("{origin}/usage"));
    let destination = expect_ok(validate_destination(
        TemplateType::General,
        &origin,
        &scripted_request.url,
        None,
    ));

    for timeout_ms in [0, u64::MAX] {
        let error = execute_request(&destination, &scripted_request, timeout_ms).unwrap_err();
        assert_eq!(error.category, "RequestValidation");
    }
    assert!(listener.accept().is_err());
}

#[test]
fn enforces_the_command_timeout_without_exposing_transport_details() {
    let server = TestServer::respond(
        response("200 OK", &[], br#"{}"#),
        Duration::from_millis(300),
    );
    let scripted_request = request(format!("{}/slow", server.origin));
    let started = Instant::now();
    let error = run(&server, &scripted_request, 50).unwrap_err();
    assert_eq!(error.category, "Timeout");
    assert!(started.elapsed() < Duration::from_secs(2));
    assert!(!error.message.contains(&server.origin));
    let _ = server.finish();
}

#[test]
fn classifies_a_timeout_while_streaming_the_response_body() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let _ = read_request(&mut stream);
        stream
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n")
            .unwrap();
        stream.flush().unwrap();
        thread::sleep(Duration::from_millis(300));
        let _ = stream.write_all(b"{}");
    });
    let origin = format!("http://{address}");
    let scripted_request = request(format!("{origin}/slow-body"));
    let destination = expect_ok(validate_destination(
        TemplateType::General,
        &origin,
        &scripted_request.url,
        None,
    ));

    let started = Instant::now();
    let error = execute_request(&destination, &scripted_request, 50).unwrap_err();
    assert_eq!(error.category, "Timeout");
    assert!(started.elapsed() < Duration::from_secs(2));
    handle.join().unwrap();
}

#[test]
fn rejects_oversized_content_length_before_waiting_for_the_body() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let barrier = Arc::new(Barrier::new(2));
    let server_barrier = Arc::clone(&barrier);
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let _ = read_request(&mut stream);
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            MAX_RESPONSE_BYTES + 1
        )
        .unwrap();
        stream.flush().unwrap();
        server_barrier.wait();
    });
    let origin = format!("http://{address}");
    let scripted_request = request(format!("{origin}/large"));
    let destination = expect_ok(validate_destination(
        TemplateType::General,
        &origin,
        &scripted_request.url,
        None,
    ));

    let started = Instant::now();
    let error = execute_request(&destination, &scripted_request, 2_000).unwrap_err();
    assert_eq!(error.category, "ResponseTooLarge");
    assert!(started.elapsed() < Duration::from_secs(2));
    barrier.wait();
    handle.join().unwrap();
}

#[test]
fn rejects_a_streamed_body_at_one_mib_plus_one() {
    let body = vec![b' '; MAX_RESPONSE_BYTES + 1];
    let mut bytes = b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".to_vec();
    bytes.extend_from_slice(&body);
    let server = TestServer::respond(bytes, Duration::ZERO);
    let scripted_request = request(format!("{}/large", server.origin));

    let error = run(&server, &scripted_request, 2_000).unwrap_err();
    assert_eq!(error.category, "ResponseTooLarge");
    let _ = server.finish();
}

#[test]
fn maps_non_success_status_and_integer_retry_after_without_reading_json() {
    let server = TestServer::respond(
        response(
            "429 Too Many Requests",
            &[("Retry-After", "17".into())],
            b"sentinel-secret-not-json",
        ),
        Duration::ZERO,
    );
    let scripted_request = request(format!("{}/limited", server.origin));

    let error = run(&server, &scripted_request, 2_000).unwrap_err();
    assert_eq!(error.category, "HttpStatus");
    assert_eq!(error.http_status, Some(429));
    assert_eq!(error.retry_after_seconds, Some(17));
    assert!(!error.message.contains("sentinel-secret"));
    let _ = server.finish();
}

#[test]
fn non_success_status_wins_over_an_oversized_declared_body() {
    let server = TestServer::respond(
        format!(
            "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 23\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            MAX_RESPONSE_BYTES + 1
        )
        .into_bytes(),
        Duration::ZERO,
    );
    let scripted_request = request(format!("{}/limited-large", server.origin));

    let error = run(&server, &scripted_request, 2_000).unwrap_err();
    assert_eq!(error.category, "HttpStatus");
    assert_eq!(error.http_status, Some(429));
    assert_eq!(error.retry_after_seconds, Some(23));
    let _ = server.finish();
}

#[test]
fn ignores_http_date_retry_after_and_rejects_redirects() {
    let server = TestServer::respond(
        response(
            "302 Found",
            &[
                ("Location", "http://127.0.0.1:9/leak".into()),
                ("Retry-After", "Wed, 21 Oct 2015 07:28:00 GMT".into()),
            ],
            b"",
        ),
        Duration::ZERO,
    );
    let scripted_request = request(format!("{}/redirect", server.origin));

    let error = run(&server, &scripted_request, 2_000).unwrap_err();
    assert_eq!(error.category, "HttpStatus");
    assert_eq!(error.http_status, Some(302));
    assert_eq!(error.retry_after_seconds, None);
    let _ = server.finish();
}

#[test]
fn parses_json_only_after_status_and_size_checks() {
    let server = TestServer::respond(
        response("200 OK", &[], b"sentinel-secret-invalid-json"),
        Duration::ZERO,
    );
    let scripted_request = request(format!("{}/invalid", server.origin));

    let error = run(&server, &scripted_request, 2_000).unwrap_err();
    assert_eq!(error.category, "InvalidJson");
    assert!(error.http_status.is_none());
    assert!(!error.message.contains("sentinel-secret"));
    let _ = server.finish();
}

#[test]
fn classifies_a_local_plaintext_endpoint_as_tls_when_contacted_over_https() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut client_hello = [0_u8; 4096];
        let read = stream.read(&mut client_hello).unwrap();
        assert!(read > 0);
        let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}");
    });
    let origin = format!("https://{address}");
    let scripted_request = request(format!("{origin}/not-tls"));
    let destination = expect_ok(validate_destination(
        TemplateType::General,
        &origin,
        &scripted_request.url,
        None,
    ));

    let error = execute_request(&destination, &scripted_request, 2_000).unwrap_err();
    assert_eq!(error.category, "Tls");
    assert_eq!(error.message, "Relay TLS negotiation failed.");
    assert!(!error.message.contains(&origin));
    handle.join().unwrap();
}
