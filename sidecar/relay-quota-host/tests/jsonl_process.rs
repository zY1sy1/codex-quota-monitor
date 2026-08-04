use std::{
    io::{Read, Write},
    net::TcpListener,
    process::{Command, Stdio},
    thread,
};

use serde_json::{json, Value};
use url::Url;

fn read_http_request(stream: &mut std::net::TcpStream) {
    let mut request = Vec::new();
    let mut byte = [0_u8; 1];
    while !request.ends_with(b"\r\n\r\n") {
        if stream.read(&mut byte).expect("read relay request") == 0 {
            return;
        }
        request.push(byte[0]);
    }
    let header_text = String::from_utf8_lossy(&request);
    let content_length = header_text
        .lines()
        .find_map(|line| {
            let (name, value) = line.split_once(':')?;
            name.eq_ignore_ascii_case("content-length")
                .then(|| value.trim().parse::<usize>().ok())
                .flatten()
        })
        .unwrap_or(0);
    let mut body = vec![0_u8; content_length];
    stream
        .read_exact(&mut body)
        .expect("read relay request body");
}

fn spawn_server(
    status: &'static str,
    extra_headers: &'static str,
    body: &'static str,
) -> (String, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind local test server");
    let address = listener.local_addr().expect("read local address");
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept relay request");
        read_http_request(&mut stream);
        let response = format!(
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\n{extra_headers}Content-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        stream
            .write_all(response.as_bytes())
            .expect("write relay response");
    });
    (format!("http://{address}"), server)
}

fn spawn_json_server(body: &'static str) -> (String, thread::JoinHandle<()>) {
    spawn_server("200 OK", "", body)
}

fn spawn_repeating_json_server(
    body: &'static str,
    count: usize,
) -> (String, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind local test server");
    let address = listener.local_addr().expect("read local address");
    let server = thread::spawn(move || {
        for _ in 0..count {
            let (mut stream, _) = listener.accept().expect("accept relay request");
            read_http_request(&mut stream);
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            stream
                .write_all(response.as_bytes())
                .expect("write relay response");
        }
    });
    (format!("http://{address}"), server)
}

fn canonical_trust(base_url: &str) -> String {
    let url = Url::parse(base_url).expect("parse test base URL");
    let host = url.host_str().expect("test URL host");
    let host = if host.contains(':') {
        format!("[{host}]")
    } else {
        host.to_ascii_lowercase()
    };
    format!(
        "{}://{}:{}",
        url.scheme().to_ascii_lowercase(),
        host,
        url.port_or_known_default().expect("known test port")
    )
}

fn query(id: &str, base_url: &str) -> Value {
    json!({
        "id": id,
        "operation": "query",
        "providerKind": "generic",
        "baseUrl": base_url,
        "requestDefinition": {
            "method": "GET",
            "path": "/usage",
            "query": {},
            "headers": {},
            "body": null
        },
        "extractorScript": "function(response){return {isValid:true,remaining:response.balance,unit:'USD'};}",
        "secrets": {"apiKey":"", "accessToken":"", "userId":""},
        "timeoutMs": 2000,
        "trustedDestination": canonical_trust(base_url)
    })
}

fn run_host_with_args(args: &[&str], input: &[u8]) -> (std::process::ExitStatus, Vec<u8>, Vec<u8>) {
    let mut command = Command::new(env!("CARGO_BIN_EXE_relay-quota-host"));
    command.args(args);
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn relay quota host");
    let mut stdin = child.stdin.take().expect("take child stdin");
    stdin.write_all(input).expect("write child input");
    drop(stdin);
    let output = child.wait_with_output().expect("wait for relay quota host");
    (output.status, output.stdout, output.stderr)
}

fn run_host(input: &[u8]) -> (std::process::ExitStatus, Vec<u8>, Vec<u8>) {
    run_host_with_args(&[], input)
}

fn response_lines(stdout: &[u8]) -> Vec<Value> {
    stdout
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
        .map(|line| serde_json::from_slice(line).expect("parse host response"))
        .collect()
}

fn assert_failure(stdout: &[u8], stderr: &[u8], category: &str) -> Value {
    assert!(stderr.is_empty());
    let responses = response_lines(stdout);
    assert_eq!(responses.len(), 1);
    assert_eq!(responses[0]["ok"], false);
    assert_eq!(responses[0]["error"]["category"], category);
    responses.into_iter().next().expect("one response")
}

fn assert_secret_absent(stdout: &[u8], stderr: &[u8], secret: &str) {
    assert!(!String::from_utf8_lossy(stdout).contains(secret));
    assert!(!String::from_utf8_lossy(stderr).contains(secret));
}

fn assert_secret_absent_ascii_case(stdout: &[u8], stderr: &[u8], secret: &str) {
    let secret = secret.to_ascii_lowercase();
    assert!(!String::from_utf8_lossy(stdout)
        .to_ascii_lowercase()
        .contains(&secret));
    assert!(!String::from_utf8_lossy(stderr)
        .to_ascii_lowercase()
        .contains(&secret));
}

#[test]
fn valid_query_round_trips_through_the_real_process() {
    let (base_url, server) = spawn_json_server(r#"{"balance":0}"#);
    let mut input = serde_json::to_vec(&query("query-1", &base_url)).expect("encode query");
    input.push(b'\n');

    let (status, stdout, stderr) = run_host(&input);

    assert!(status.success());
    assert!(stderr.is_empty());
    server.join().expect("join local server");
    let lines: Vec<&[u8]> = stdout.split(|byte| *byte == b'\n').collect();
    assert_eq!(lines.len(), 2);
    assert!(lines[1].is_empty());
    let response: Value = serde_json::from_slice(lines[0]).expect("parse host response");
    assert_eq!(response["id"], "query-1");
    assert_eq!(response["ok"], true);
    assert_eq!(response["results"][0]["remaining"].as_f64(), Some(0.0));
    assert_eq!(response["meta"]["httpStatus"], 200);
    assert_eq!(response["meta"]["destinationHost"], "127.0.0.1");
    assert!(response["meta"]["durationMs"].is_number());
}

#[test]
fn framing_errors_are_sanitized_and_the_stream_recovers_after_an_overlong_line() {
    let (base_url, server) = spawn_json_server(r#"{"balance":7}"#);
    let valid = serde_json::to_vec(&query("after-overlong", &base_url)).expect("encode query");
    let mut input = Vec::with_capacity(512 * 1024 + valid.len() + 32);
    input.extend_from_slice(b"\nnot-json\r\n");
    input.extend_from_slice(&[0xff, b'\n']);
    input.extend(std::iter::repeat_n(b'x', 512 * 1024 + 1));
    input.push(b'\n');
    input.extend_from_slice(&valid);

    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    assert!(stderr.is_empty());
    server.join().expect("join local server");

    let responses = response_lines(&stdout);
    assert_eq!(responses.len(), 5);
    for response in &responses[..4] {
        assert_eq!(response["id"], "");
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["category"], "Protocol");
    }
    assert_eq!(responses[4]["id"], "after-overlong");
    assert_eq!(responses[4]["ok"], true);
}

#[test]
fn crlf_and_eof_terminated_final_lines_are_each_commands() {
    let input = b"{}\r\n{}";
    let (status, stdout, stderr) = run_host(input);
    assert!(status.success());
    assert!(stderr.is_empty());
    let responses = response_lines(&stdout);
    assert_eq!(responses.len(), 2);
    assert!(responses
        .iter()
        .all(|response| response["error"]["category"] == "Protocol"));
}

#[test]
fn self_test_and_argument_handling_are_exact_and_silent() {
    let (status, stdout, stderr) = run_host_with_args(&["--self-test"], b"");
    assert!(status.success());
    assert_eq!(stdout, b"relay-quota-host: ok\n");
    assert!(stderr.is_empty());

    for args in [vec!["--unknown"], vec!["--self-test", "extra"]] {
        let (status, stdout, stderr) = run_host_with_args(&args, b"");
        assert!(!status.success());
        assert!(stdout.is_empty());
        assert!(stderr.is_empty());
    }
}

#[test]
fn closing_stdin_without_commands_exits_cleanly_and_silently() {
    let (status, stdout, stderr) = run_host(b"");
    assert!(status.success());
    assert!(stdout.is_empty());
    assert!(stderr.is_empty());
}

#[test]
fn empty_oversized_and_control_character_ids_are_rejected_without_echo() {
    const SECRET: &str = "SENTINEL_INVALID_ID_741";
    let base_url = "http://127.0.0.1:9";
    let ids = [
        String::new(),
        "x".repeat(129),
        "I".repeat(500 * 1024),
        format!("{SECRET}\n"),
    ];
    let mut input = Vec::new();
    for id in ids {
        serde_json::to_writer(&mut input, &query(&id, base_url)).expect("encode invalid id query");
        input.push(b'\n');
    }

    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    assert!(stderr.is_empty());
    assert_secret_absent(&stdout, &stderr, SECRET);
    let responses = response_lines(&stdout);
    assert_eq!(responses.len(), 4);
    assert!(responses.iter().all(|response| response["id"] == ""));
    assert!(responses
        .iter()
        .all(|response| response["error"]["category"] == "Protocol"));
}

#[test]
fn sequential_commands_do_not_share_quickjs_globals() {
    let (base_url, server) = spawn_repeating_json_server(r#"{"balance":3}"#, 2);
    let script = "function(response){globalThis.commandCount=(globalThis.commandCount??0)+1;return {isValid:true,remaining:globalThis.commandCount,unit:'count'};}";
    let mut first = query("fresh-1", &base_url);
    first["extractorScript"] = Value::String(script.into());
    let mut second = query("fresh-2", &base_url);
    second["extractorScript"] = Value::String(script.into());
    let mut input = serde_json::to_vec(&first).expect("encode first command");
    input.push(b'\n');
    input.extend(serde_json::to_vec(&second).expect("encode second command"));
    input.push(b'\n');

    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    assert!(stderr.is_empty());
    server.join().expect("join local server");
    let responses = response_lines(&stdout);
    assert_eq!(responses.len(), 2);
    assert_eq!(responses[0]["results"][0]["remaining"].as_f64(), Some(1.0));
    assert_eq!(responses[1]["results"][0]["remaining"].as_f64(), Some(1.0));
}

#[test]
fn timeout_below_the_minimum_is_clamped_and_still_runs() {
    let (base_url, server) = spawn_json_server(r#"{"balance":2}"#);
    let mut command = query("clamped-low", &base_url);
    command["timeoutMs"] = Value::from(0);
    let mut input = serde_json::to_vec(&command).expect("encode query");
    input.push(b'\n');

    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    assert!(stderr.is_empty());
    server.join().expect("join local server");
    assert_eq!(response_lines(&stdout)[0]["ok"], true);
}

#[test]
fn http_status_retry_after_and_redirect_metadata_are_stable() {
    for (status_line, headers, expected_status, expected_retry) in [
        ("401 Unauthorized", "", 401, None),
        (
            "429 Too Many Requests",
            "Retry-After: 17\r\n",
            429,
            Some(17),
        ),
        (
            "302 Found",
            "Location: http://127.0.0.1/elsewhere\r\n",
            302,
            None,
        ),
    ] {
        let (base_url, server) = spawn_server(status_line, headers, r#"{"error":"private"}"#);
        let mut input = serde_json::to_vec(&query("status", &base_url)).expect("encode query");
        input.push(b'\n');
        let (status, stdout, stderr) = run_host(&input);
        assert!(status.success());
        server.join().expect("join local server");
        let response = assert_failure(&stdout, &stderr, "HttpStatus");
        assert_eq!(response["error"]["httpStatus"], expected_status);
        match expected_retry {
            Some(seconds) => assert_eq!(response["error"]["retryAfterSeconds"], seconds),
            None => assert!(response["error"]["retryAfterSeconds"].is_null()),
        }
    }
}

#[test]
fn script_request_response_and_extractor_failures_use_only_stable_categories() {
    let cases = [
        ("({broken", "ScriptSyntax"),
        (
            "({request:{url:'{{baseUrl}}/usage',method:'GET',headers:{Bad:['not','a','string']}},extractor:r=>r})",
            "RequestValidation",
        ),
    ];
    for (script, category) in cases {
        let mut command = query("failure", "http://127.0.0.1:9");
        if category == "ScriptSyntax" || category == "RequestValidation" {
            command["providerKind"] = Value::String("custom".into());
            command["requestDefinition"] = Value::Null;
        }
        command["extractorScript"] = Value::String(script.into());
        let mut input = serde_json::to_vec(&command).expect("encode failure query");
        input.push(b'\n');
        let (status, stdout, stderr) = run_host(&input);
        assert!(status.success());
        assert_failure(&stdout, &stderr, category);
    }

    let (base_url, server) = spawn_server("200 OK", "", "not-json");
    let mut input = serde_json::to_vec(&query("invalid-json", &base_url)).expect("encode query");
    input.push(b'\n');
    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    server.join().expect("join local server");
    assert_failure(&stdout, &stderr, "InvalidJson");

    let (base_url, server) = spawn_json_server(r#"{"balance":5}"#);
    let mut command = query("invalid-result", &base_url);
    command["extractorScript"] =
        Value::String("function(response){return {isValid:true,remaining:'wrong'};}".into());
    let mut input = serde_json::to_vec(&command).expect("encode query");
    input.push(b'\n');
    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    server.join().expect("join local server");
    assert_failure(&stdout, &stderr, "ResultValidation");
}

#[test]
fn infinite_request_and_extractor_scripts_time_out_without_stalling_the_service() {
    let mut command = query("request-timeout", "http://127.0.0.1:9");
    command["providerKind"] = Value::String("custom".into());
    command["requestDefinition"] = Value::Null;
    command["extractorScript"] =
        Value::String("(()=>{while(true){} return {request:{}}})()".into());
    let mut input = serde_json::to_vec(&command).expect("encode timeout query");
    input.push(b'\n');
    let started = std::time::Instant::now();
    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    assert!(started.elapsed() < std::time::Duration::from_secs(10));
    assert_failure(&stdout, &stderr, "ScriptTimeout");

    let (base_url, server) = spawn_json_server(r#"{"balance":5}"#);
    let mut command = query("extractor-timeout", &base_url);
    command["extractorScript"] = Value::String("function(response){while(true){}}".into());
    let mut input = serde_json::to_vec(&command).expect("encode timeout query");
    input.push(b'\n');
    let started = std::time::Instant::now();
    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    server.join().expect("join local server");
    assert!(started.elapsed() < std::time::Duration::from_secs(10));
    assert_failure(&stdout, &stderr, "ScriptTimeout");
}

#[test]
fn secret_sentinels_never_cross_failure_stdout_or_stderr() {
    const SECRET: &str = "SENTINEL_RELAY_SECRET_932";

    let mut syntax = query(&format!("{SECRET}\n"), "http://127.0.0.1:9");
    syntax["providerKind"] = Value::String("custom".into());
    syntax["requestDefinition"] = Value::Null;
    syntax["extractorScript"] = Value::String(format!("function(response){{ /* {SECRET} */"));
    syntax["secrets"] = json!({"apiKey":SECRET,"accessToken":SECRET,"userId":SECRET});
    let mut input = serde_json::to_vec(&syntax).expect("encode syntax query");
    input.push(b'\n');
    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    assert_secret_absent(&stdout, &stderr, SECRET);
    assert_failure(&stdout, &stderr, "Protocol");

    let mut syntax = query("syntax-secret", "http://127.0.0.1:9");
    syntax["providerKind"] = Value::String("custom".into());
    syntax["requestDefinition"] = Value::Null;
    syntax["extractorScript"] = Value::String(format!("function(response){{ /* {SECRET} */"));
    syntax["secrets"] = json!({"apiKey":SECRET,"accessToken":SECRET,"userId":SECRET});
    let mut input = serde_json::to_vec(&syntax).expect("encode syntax query");
    input.push(b'\n');
    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    assert_secret_absent(&stdout, &stderr, SECRET);
    assert_failure(&stdout, &stderr, "ScriptSyntax");

    let mut invalid_header = query("header-secret", "http://127.0.0.1:9");
    invalid_header["providerKind"] = Value::String("custom".into());
    invalid_header["requestDefinition"] = Value::Null;
    invalid_header["extractorScript"] = Value::String("({request:{url:'{{baseUrl}}/usage',method:'GET',headers:{Bad:[\"{{apiKey}}\"]}},extractor:r=>r})".into());
    invalid_header["secrets"] = json!({"apiKey":SECRET,"accessToken":SECRET,"userId":SECRET});
    let mut input = serde_json::to_vec(&invalid_header).expect("encode header query");
    input.push(b'\n');
    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    assert_secret_absent(&stdout, &stderr, SECRET);
    assert_failure(&stdout, &stderr, "RequestValidation");

    let (base_url, server) = spawn_server("500 Internal Server Error", "", SECRET);
    let mut http = query("http-secret", &base_url);
    http["providerKind"] = Value::String("custom".into());
    http["requestDefinition"] = Value::Null;
    http["secrets"] = json!({"apiKey":SECRET,"accessToken":SECRET,"userId":SECRET});
    http["extractorScript"] = Value::String("({request:{url:'{{baseUrl}}/usage',method:'POST',headers:{Authorization:'Bearer {{apiKey}}'},body:'{{accessToken}}'},extractor:r=>r})".into());
    let mut input = serde_json::to_vec(&http).expect("encode HTTP query");
    input.push(b'\n');
    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    server.join().expect("join local server");
    assert_secret_absent(&stdout, &stderr, SECRET);
    assert_failure(&stdout, &stderr, "HttpStatus");

    let (base_url, server) = spawn_server("200 OK", "", SECRET);
    let mut invalid_json = query("json-secret", &base_url);
    invalid_json["secrets"] = json!({"apiKey":SECRET,"accessToken":SECRET,"userId":SECRET});
    let mut input = serde_json::to_vec(&invalid_json).expect("encode invalid JSON query");
    input.push(b'\n');
    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    server.join().expect("join local server");
    assert_secret_absent(&stdout, &stderr, SECRET);
    assert_failure(&stdout, &stderr, "InvalidJson");

    let (base_url, server) = spawn_json_server(r#"{"private":"SENTINEL_RELAY_SECRET_932"}"#);
    let mut invalid_result = query("result-secret", &base_url);
    invalid_result["secrets"] = json!({"apiKey":SECRET,"accessToken":SECRET,"userId":SECRET});
    invalid_result["extractorScript"] = Value::String(
        "function(response){return {isValid:true,remaining:response.private};}".into(),
    );
    let mut input = serde_json::to_vec(&invalid_result).expect("encode invalid result query");
    input.push(b'\n');
    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    server.join().expect("join local server");
    assert_secret_absent(&stdout, &stderr, SECRET);
    assert_failure(&stdout, &stderr, "ResultValidation");
}

#[test]
fn direct_worker_modes_never_emit_credential_sentinels() {
    const SECRET: &str = "DIRECT_WORKER_SENTINEL_614";

    let request_input = json!({
        "script": format!(
            "({{request:{{url:'https://relay.example/usage',method:'GET',headers:{{Authorization:'Bearer {SECRET}'}},body:undefined}},extractor:r=>r}})"
        ),
        "baseUrl": "https://relay.example",
        "secrets": {"apiKey": SECRET, "accessToken": SECRET, "userId": SECRET}
    });
    let request_bytes = serde_json::to_vec(&request_input).expect("encode request worker input");
    let (status, stdout, stderr) = run_host_with_args(&["--request-worker"], &request_bytes);
    assert!(status.success());
    assert_secret_absent(&stdout, &stderr, SECRET);

    let extractor_input = json!({
        "script": "({extractor:r=>({isValid:false,invalidMessage:r.secret,unit:'USD'})})",
        "responseJson": format!(r#"{{"secret":"{SECRET}"}}"#),
        "baseUrl": "https://relay.example",
        "secrets": {"apiKey": SECRET, "accessToken": SECRET, "userId": SECRET}
    });
    let extractor_bytes =
        serde_json::to_vec(&extractor_input).expect("encode extractor worker input");
    let (status, stdout, stderr) = run_host_with_args(&["--extractor-worker"], &extractor_bytes);
    assert!(status.success());
    assert_secret_absent(&stdout, &stderr, SECRET);
}

#[test]
fn input_io_errors_emit_one_lifecycle_response_without_raw_details() {
    struct FailingReader;

    impl Read for FailingReader {
        fn read(&mut self, _buffer: &mut [u8]) -> std::io::Result<usize> {
            Err(std::io::Error::other("SENTINEL_IO_DETAIL_205"))
        }
    }

    let mut output = Vec::new();
    assert!(relay_quota_host::run_jsonl(FailingReader, &mut output).is_err());
    assert!(!String::from_utf8_lossy(&output).contains("SENTINEL_IO_DETAIL_205"));
    let responses = response_lines(&output);
    assert_eq!(responses.len(), 1);
    assert_eq!(responses[0]["id"], "");
    assert_eq!(responses[0]["error"]["category"], "SidecarLifecycle");
}

#[test]
fn direct_handle_line_enforces_the_byte_limit_before_json_parsing() {
    let oversized = vec![b' '; 512 * 1024 + 1];
    let response = relay_quota_host::handle_line(&oversized);
    let encoded = serde_json::to_value(response).expect("encode direct response");
    assert_eq!(encoded["id"], "");
    assert_eq!(encoded["error"]["category"], "Protocol");

    let multibyte = format!("{{\"id\":\"{}\"}}", "界".repeat(180_000));
    assert!(multibyte.len() > 512 * 1024);
    let response = relay_quota_host::handle_line(multibyte.as_bytes());
    let encoded = serde_json::to_value(response).expect("encode direct response");
    assert_eq!(encoded["error"]["category"], "Protocol");
}

#[test]
fn custom_trust_metadata_cannot_reveal_case_folded_credentials() {
    const SECRET: &str = "LeAkMe741";
    let mut command = query("custom-secret-host", "https://safe.example");
    command["providerKind"] = Value::String("custom".into());
    command["requestDefinition"] = Value::Null;
    command["extractorScript"] = Value::String("({request:{url:'http://{{apiKey}}.example/usage',method:'GET',headers:{}},extractor:r=>r})".into());
    command["secrets"] = json!({"apiKey":SECRET,"accessToken":"LeakMe","userId":""});
    let mut input = serde_json::to_vec(&command).expect("encode custom query");
    input.push(b'\n');

    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    let response = assert_failure(&stdout, &stderr, "DestinationValidation");
    assert_secret_absent_ascii_case(&stdout, &stderr, SECRET);
    assert_secret_absent_ascii_case(&stdout, &stderr, "LeakMe");
    assert!(response["error"].get("destinationHost").is_none());
    assert!(response["error"].get("destinationFingerprint").is_none());
}

#[test]
fn successful_extractor_results_cannot_return_query_credentials() {
    const API_SECRET: &str = "API_SENTINEL_401";
    const ACCESS_SECRET: &str = "ACCESS_SENTINEL_402";
    const USER_SECRET: &str = "USER_SENTINEL_403";
    let (base_url, server) = spawn_json_server(r#"{"balance":5}"#);
    let mut command = query("credential-result", &base_url);
    command["secrets"] = json!({
        "apiKey": API_SECRET,
        "accessToken": ACCESS_SECRET,
        "userId": USER_SECRET
    });
    command["extractorScript"] = Value::String("function(response){return {isValid:false,invalidMessage:'{{apiKey}}',remaining:1,unit:'{{accessToken}}',planName:'{{userId}}',extra:'{{apiKey}}/{{accessToken}}/{{userId}}'};}".into());
    let mut input = serde_json::to_vec(&command).expect("encode credential result query");
    input.push(b'\n');

    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    server.join().expect("join local server");
    assert_failure(&stdout, &stderr, "ResultValidation");
    for secret in [API_SECRET, ACCESS_SECRET, USER_SECRET] {
        assert_secret_absent_ascii_case(&stdout, &stderr, secret);
    }
}

#[test]
fn successful_destination_hosts_cannot_contain_query_credentials() {
    const SHORT_SECRET: &str = "0.0";
    let (base_url, server) = spawn_json_server(r#"{"balance":5}"#);
    let mut command = query("credential-host", &base_url);
    command["secrets"] = json!({"apiKey":SHORT_SECRET,"accessToken":"0.0","userId":""});
    let mut input = serde_json::to_vec(&command).expect("encode credential host query");
    input.push(b'\n');

    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    server.join().expect("join local server");
    assert_failure(&stdout, &stderr, "ResultValidation");
    assert_secret_absent_ascii_case(&stdout, &stderr, SHORT_SECRET);
}

#[test]
fn structurally_valid_ids_containing_credentials_are_protocol_failures() {
    const SECRET: &str = "IdSecret882";
    let mut command = query("prefix-idsecret882-suffix", "http://127.0.0.1:9");
    command["extractorScript"] = Value::String("function(response){".into());
    command["secrets"] = json!({"apiKey":SECRET,"accessToken":"","userId":""});
    let mut input = serde_json::to_vec(&command).expect("encode secret id query");
    input.push(b'\n');

    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    let response = assert_failure(&stdout, &stderr, "Protocol");
    assert_eq!(response["id"], "");
    assert_secret_absent_ascii_case(&stdout, &stderr, SECRET);
}

#[test]
fn safe_custom_trust_metadata_is_preserved_when_it_matches_no_credential() {
    let mut command = query("safe-custom-host", "https://safe.example");
    command["providerKind"] = Value::String("custom".into());
    command["requestDefinition"] = Value::Null;
    command["baseUrl"] = Value::String("https://relay-safe.example".into());
    command["trustedDestination"] = Value::Null;
    command["extractorScript"] = Value::String("({request:{url:'https://relay-safe.example/usage',method:'GET',headers:{}},extractor:r=>r})".into());
    command["secrets"] =
        json!({"apiKey":"credential-741","accessToken":"overlap-credential-741","userId":""});
    let mut input = serde_json::to_vec(&command).expect("encode safe custom query");
    input.push(b'\n');

    let (status, stdout, stderr) = run_host(&input);
    assert!(status.success());
    let response = assert_failure(&stdout, &stderr, "DestinationTrustRequired");
    assert_eq!(response["error"]["destinationHost"], "relay-safe.example");
    assert_eq!(
        response["error"]["destinationFingerprint"],
        "https://relay-safe.example:443"
    );
}
