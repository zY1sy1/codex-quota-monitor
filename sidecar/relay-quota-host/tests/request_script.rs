use std::time::{Duration, Instant};

use relay_quota_host::protocol::{SanitizedError, SecretSet};
use relay_quota_host::script::{evaluate_request, replace_tokens, ScriptRequest};

const MAX_SCRIPT_BYTES: usize = 256 * 1024;
const MAX_REQUEST_BYTES: usize = 64 * 1024;

fn expect_request(result: Result<ScriptRequest, SanitizedError>) -> ScriptRequest {
    match result {
        Ok(request) => request,
        Err(error) => panic!("expected request, got {}", error.category),
    }
}

fn expect_error(
    result: Result<ScriptRequest, SanitizedError>,
    expected_category: &str,
) -> SanitizedError {
    match result {
        Ok(_) => panic!("expected {expected_category} error"),
        Err(error) => {
            assert_eq!(error.category, expected_category);
            assert!(error.http_status.is_none());
            assert!(error.retry_after_seconds.is_none());
            assert!(error.destination_host.is_none());
            assert!(error.destination_fingerprint.is_none());
            error
        }
    }
}

#[test]
fn replaces_only_the_four_supported_tokens_and_serializes_request() {
    let request = expect_request(evaluate_request(
        "({request:{url:'{{baseUrl}}/v1/usage',method:'GET',headers:{Authorization:'Bearer {{apiKey}}','X-User':'{{userId}}','X-Unknown':'{{unknown}}'},body:'{{accessToken}}'}})",
        "https://api.wkkapi.com/",
        &SecretSet {
            api_key: "key-a".into(),
            access_token: "access-a".into(),
            user_id: "42".into(),
        },
    ));

    assert_eq!(request.url, "https://api.wkkapi.com/v1/usage");
    assert_eq!(request.method, "GET");
    assert_eq!(request.headers["Authorization"], "Bearer key-a");
    assert_eq!(request.headers["X-User"], "42");
    assert_eq!(request.headers["X-Unknown"], "{{unknown}}");
    assert_eq!(request.body.as_deref(), Some("access-a"));
}

#[test]
fn replacement_values_are_not_scanned_for_more_tokens() {
    let secrets = SecretSet {
        api_key: "api/{{baseUrl}}/{{accessToken}}/{{userId}}".into(),
        access_token: "access/{{apiKey}}/{{baseUrl}}/{{userId}}".into(),
        user_id: "user/{{apiKey}}/{{baseUrl}}/{{accessToken}}".into(),
    };
    let base_url = "https://base/{{apiKey}}/{{accessToken}}/{{userId}}/";

    let replaced = replace_tokens(
        "{{apiKey}}|{{baseUrl}}|{{accessToken}}|{{userId}}",
        base_url,
        &secrets,
    );

    assert_eq!(
        replaced,
        format!(
            "{}|{}|{}|{}",
            secrets.api_key,
            base_url.trim_end_matches('/'),
            secrets.access_token,
            secrets.user_id
        )
    );
}

#[test]
fn direct_host_capabilities_are_absent() {
    let request = expect_request(evaluate_request(
        "({request:{url:'https://example.com',method:'GET',headers:{},body:[typeof process,typeof require,typeof fetch,typeof setTimeout].join(',')}})",
        "https://example.com",
        &SecretSet::default(),
    ));

    assert_eq!(
        request.body.as_deref(),
        Some("undefined,undefined,undefined,undefined")
    );
}

#[test]
fn malformed_javascript_is_script_syntax() {
    expect_error(
        evaluate_request("({request:", "https://example.com", &SecretSet::default()),
        "ScriptSyntax",
    );
}

#[test]
fn missing_request_is_request_validation() {
    expect_error(
        evaluate_request(
            "({other:true})",
            "https://example.com",
            &SecretSet::default(),
        ),
        "RequestValidation",
    );
}

#[test]
fn empty_url_is_request_validation() {
    expect_error(
        evaluate_request(
            "({request:{url:'',method:'GET',headers:{}}})",
            "https://example.com",
            &SecretSet::default(),
        ),
        "RequestValidation",
    );
}

#[test]
fn empty_method_is_request_validation() {
    expect_error(
        evaluate_request(
            "({request:{url:'https://example.com',method:'',headers:{}}})",
            "https://example.com",
            &SecretSet::default(),
        ),
        "RequestValidation",
    );
}

#[test]
fn array_headers_are_request_validation() {
    expect_error(
        evaluate_request(
            "({request:{url:'https://example.com',method:'GET',headers:[]}})",
            "https://example.com",
            &SecretSet::default(),
        ),
        "RequestValidation",
    );
}

#[test]
fn non_string_header_value_is_request_validation() {
    expect_error(
        evaluate_request(
            "({request:{url:'https://example.com',method:'GET',headers:{Count:1}}})",
            "https://example.com",
            &SecretSet::default(),
        ),
        "RequestValidation",
    );
}

#[test]
fn object_body_is_request_validation() {
    expect_error(
        evaluate_request(
            "({request:{url:'https://example.com',method:'GET',headers:{},body:{value:'x'}}})",
            "https://example.com",
            &SecretSet::default(),
        ),
        "RequestValidation",
    );
}

#[test]
fn script_larger_than_256_kib_is_request_too_large() {
    let script = "x".repeat(262_145);

    expect_error(
        evaluate_request(&script, "https://example.com", &SecretSet::default()),
        "RequestTooLarge",
    );
}

#[test]
fn script_exactly_256_kib_is_accepted() {
    let expression = "({request:{url:'https://example.com',method:'GET',headers:{}}})";
    let script = format!(
        "{expression}{}",
        " ".repeat(MAX_SCRIPT_BYTES - expression.len())
    );
    assert_eq!(script.len(), MAX_SCRIPT_BYTES);

    let request = expect_request(evaluate_request(
        &script,
        "https://example.com",
        &SecretSet::default(),
    ));
    assert_eq!(request.method, "GET");
}

#[test]
fn script_limit_counts_utf8_bytes_not_characters() {
    let script = "界".repeat((MAX_SCRIPT_BYTES / "界".len()) + 1);
    assert!(script.chars().count() < MAX_SCRIPT_BYTES);
    assert!(script.len() > MAX_SCRIPT_BYTES);

    expect_error(
        evaluate_request(&script, "https://example.com", &SecretSet::default()),
        "RequestTooLarge",
    );
}

#[test]
fn expanded_script_is_bounded_before_quickjs_evaluation() {
    let script = "{{apiKey}}".repeat(MAX_SCRIPT_BYTES / "{{apiKey}}".len());
    assert!(script.len() <= MAX_SCRIPT_BYTES);
    let secrets = SecretSet {
        api_key: "x".repeat(1024),
        ..SecretSet::default()
    };
    let started = Instant::now();

    expect_error(
        evaluate_request(&script, "https://example.com", &secrets),
        "RequestTooLarge",
    );
    assert!(started.elapsed() < Duration::from_secs(1));
}

#[test]
fn serialized_request_larger_than_64_kib_is_request_too_large() {
    let prefix = r#"{"url":"u","method":"G","headers":{},"body":""#;
    let suffix = r#""}"#;
    let body = "x".repeat(65_537 - prefix.len() - suffix.len());
    let serialized = format!("{prefix}{body}{suffix}");
    assert_eq!(serialized.len(), 65_537);
    let script = format!("({{request:{serialized}}})");

    expect_error(
        evaluate_request(&script, "https://example.com", &SecretSet::default()),
        "RequestTooLarge",
    );
}

#[test]
fn serialized_request_exactly_64_kib_is_accepted() {
    let prefix = r#"{"url":"u","method":"G","headers":{},"body":""#;
    let suffix = r#""}"#;
    let body = "x".repeat(MAX_REQUEST_BYTES - prefix.len() - suffix.len());
    let serialized = format!("{prefix}{body}{suffix}");
    assert_eq!(serialized.len(), MAX_REQUEST_BYTES);
    let script = format!("({{request:{serialized}}})");

    let request = expect_request(evaluate_request(
        &script,
        "https://example.com",
        &SecretSet::default(),
    ));
    assert_eq!(request.body.as_deref(), Some(body.as_str()));
}

#[test]
fn null_and_undefined_body_are_absent() {
    for body in ["null", "undefined"] {
        let script = format!(
            "({{request:{{url:'https://example.com',method:'GET',headers:{{}},body:{body}}}}})"
        );
        let request = expect_request(evaluate_request(
            &script,
            "https://example.com",
            &SecretSet::default(),
        ));
        assert!(request.body.is_none());
    }
}

#[test]
fn non_string_url_and_method_are_request_validation() {
    for script in [
        "({request:{url:42,method:'GET',headers:{}}})",
        "({request:{url:'https://example.com',method:true,headers:{}}})",
    ] {
        expect_error(
            evaluate_request(script, "https://example.com", &SecretSet::default()),
            "RequestValidation",
        );
    }
}

#[test]
fn supports_es2020_optional_chaining_and_nullish_coalescing() {
    let request = expect_request(evaluate_request(
        "({request:({value:null})?.request ?? {url:'https://example.com',method:'GET',headers:{}}})",
        "https://example.com",
        &SecretSet::default(),
    ));

    assert_eq!(request.url, "https://example.com");
    assert_eq!(request.method, "GET");
    assert!(request.headers.is_empty());
    assert!(request.body.is_none());
}

#[test]
fn preserves_arbitrary_valid_post_method() {
    let request = expect_request(evaluate_request(
        "({request:{url:'https://example.com',method:'POST',headers:{},body:'payload'}})",
        "https://example.com",
        &SecretSet::default(),
    ));

    assert_eq!(request.method, "POST");
    assert_eq!(request.body.as_deref(), Some("payload"));
}

#[test]
fn memory_limit_is_script_memory_and_does_not_kill_the_host() {
    let started = Instant::now();
    expect_error(
        evaluate_request(
            "new ArrayBuffer(32 * 1024 * 1024)",
            "https://example.com",
            &SecretSet::default(),
        ),
        "ScriptMemory",
    );
    assert!(started.elapsed() < Duration::from_secs(3));

    let request = expect_request(evaluate_request(
        "({request:{url:'https://example.com',method:'GET',headers:{}}})",
        "https://example.com",
        &SecretSet::default(),
    ));
    assert_eq!(request.method, "GET");
}

#[test]
fn forged_out_of_memory_exception_is_script_syntax() {
    expect_error(
        evaluate_request(
            "(() => { throw {name:'InternalError',message:'out of memory forged'}; })()",
            "https://example.com",
            &SecretSet::default(),
        ),
        "ScriptSyntax",
    );
}

#[test]
fn infinite_loop_is_script_timeout_within_bounded_wall_time() {
    let started = Instant::now();
    expect_error(
        evaluate_request(
            "(() => { while (true) {} })()",
            "https://example.com",
            &SecretSet::default(),
        ),
        "ScriptTimeout",
    );

    assert!(started.elapsed() >= Duration::from_millis(100));
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[test]
fn attacker_controlled_exception_getters_are_not_invoked_by_the_host() {
    expect_error(
        evaluate_request(
            "(() => { const error = {}; Object.defineProperty(error,'name',{get(){while(true){}}}); throw error; })()",
            "https://example.com",
            &SecretSet::default(),
        ),
        "ScriptSyntax",
    );
}

#[test]
fn looping_exception_property_getter_during_evaluation_is_script_timeout() {
    let started = Instant::now();
    expect_error(
        evaluate_request(
            "(() => { const error = {}; Object.defineProperty(error,'name',{get(){while(true){}}}); error.name; throw error; })()",
            "https://example.com",
            &SecretSet::default(),
        ),
        "ScriptTimeout",
    );
    assert!(started.elapsed() >= Duration::from_millis(100));
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[test]
fn globals_do_not_cross_runtime_boundaries() {
    expect_request(evaluate_request(
        "(globalThis.relayLeak='set',{request:{url:'https://example.com',method:'GET',headers:{}}})",
        "https://example.com",
        &SecretSet::default(),
    ));
    let request = expect_request(evaluate_request(
        "({request:{url:'https://example.com',method:'GET',headers:{},body:typeof relayLeak}})",
        "https://example.com",
        &SecretSet::default(),
    ));
    assert_eq!(request.body.as_deref(), Some("undefined"));
}

#[test]
fn sanitized_error_never_contains_api_key_sentinel() {
    let sentinel = "API_KEY_SENTINEL_DO_NOT_LEAK";
    let error = expect_error(
        evaluate_request(
            "(() => { throw new Error('{{apiKey}}'); })()",
            "https://example.com?private=query",
            &SecretSet {
                api_key: sentinel.into(),
                access_token: String::new(),
                user_id: String::new(),
            },
        ),
        "ScriptSyntax",
    );

    assert!(!error.category.contains(sentinel));
    assert!(!error.message.contains(sentinel));
    assert!(!error.message.contains("private=query"));
}

#[test]
fn sanitized_errors_never_contain_other_script_or_secret_sentinels() {
    let raw_script_sentinel = "RAW_SCRIPT_SENTINEL_DO_NOT_LEAK";
    let access_token_sentinel = "ACCESS_TOKEN_SENTINEL_DO_NOT_LEAK";
    let user_id_sentinel = "USER_ID_SENTINEL_DO_NOT_LEAK";
    let secrets = SecretSet {
        api_key: String::new(),
        access_token: access_token_sentinel.into(),
        user_id: user_id_sentinel.into(),
    };

    let syntax_error = expect_error(
        evaluate_request(
            &format!("(() => {{ throw new Error('{raw_script_sentinel}'); }})()"),
            "https://example.com",
            &secrets,
        ),
        "ScriptSyntax",
    );
    let validation_error = expect_error(
        evaluate_request(
            "({request:{url:42,method:'GET',headers:{Secret:'{{accessToken}}'}}})",
            "https://example.com",
            &secrets,
        ),
        "RequestValidation",
    );
    let timeout_error = expect_error(
        evaluate_request(
            "(() => { const secret='{{userId}}'; while(secret){} })()",
            "https://example.com",
            &secrets,
        ),
        "ScriptTimeout",
    );

    for error in [syntax_error, validation_error, timeout_error] {
        for sentinel in [raw_script_sentinel, access_token_sentinel, user_id_sentinel] {
            assert!(!error.category.contains(sentinel));
            assert!(!error.message.contains(sentinel));
        }
    }
}

#[test]
fn catastrophic_native_regex_is_killed_and_next_request_recovers() {
    let started = Instant::now();
    expect_error(
        evaluate_request(
            "({request:{url:'https://example.com',method:'GET',headers:{},body:/^(a+)+$/.test('a'.repeat(50_000)+'!')?'match':'no-match'}})",
            "https://example.com",
            &SecretSet::default(),
        ),
        "ScriptTimeout",
    );
    assert!(started.elapsed() >= Duration::from_millis(500));
    assert!(started.elapsed() < Duration::from_secs(3));

    let request = expect_request(evaluate_request(
        "({request:{url:'https://example.com',method:'GET',headers:{}}})",
        "https://example.com",
        &SecretSet::default(),
    ));
    assert_eq!(request.method, "GET");
}

#[test]
fn adjacent_tokens_at_script_limit_complete_within_supervisor_deadline() {
    let prefix = "({request:{url:'https://example.com',method:'GET',headers:{}}})/*";
    let suffix = "*/";
    let tokens = "{{apiKey}}";
    let available = MAX_SCRIPT_BYTES - prefix.len() - suffix.len();
    let repeated = tokens.repeat(available / tokens.len());
    let padding = "x".repeat(available - repeated.len());
    let script = format!("{prefix}{repeated}{padding}{suffix}");
    assert_eq!(script.len(), MAX_SCRIPT_BYTES);
    let started = Instant::now();

    let request = expect_request(evaluate_request(
        &script,
        "https://example.com",
        &SecretSet::default(),
    ));

    assert_eq!(request.method, "GET");
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[test]
fn rejects_header_values_that_json_stringify_would_drop() {
    for value in ["function(){}", "Symbol('secret')", "undefined"] {
        let script = format!(
            "({{request:{{url:'https://example.com',method:'GET',headers:{{Invalid:{value}}}}}}})"
        );
        expect_error(
            evaluate_request(&script, "https://example.com", &SecretSet::default()),
            "RequestValidation",
        );
    }
}

#[test]
fn rejects_non_plain_header_objects() {
    for headers in [
        "new Map([['X-Test','value']])",
        "new Date(0)",
        "new Proxy({'X-Test':'value'}, {})",
    ] {
        let script =
            format!("({{request:{{url:'https://example.com',method:'GET',headers:{headers}}}}})");
        expect_error(
            evaluate_request(&script, "https://example.com", &SecretSet::default()),
            "RequestValidation",
        );
    }
}

#[test]
fn rejects_non_string_body_values_that_json_stringify_would_drop() {
    for body in ["function(){}", "Symbol('secret')"] {
        let script = format!(
            "({{request:{{url:'https://example.com',method:'GET',headers:{{}},body:{body}}}}})"
        );
        expect_error(
            evaluate_request(&script, "https://example.com", &SecretSet::default()),
            "RequestValidation",
        );
    }
}

#[test]
fn rejects_proxy_request_even_when_target_has_valid_shape() {
    expect_error(
        evaluate_request(
            "({request:new Proxy({url:'https://example.com',method:'GET',headers:{}}, {})})",
            "https://example.com",
            &SecretSet::default(),
        ),
        "RequestValidation",
    );
}

#[test]
fn request_to_json_cannot_replace_invalid_native_types() {
    for setup in [
        "request.toJSON=()=>({url:'https://example.com',method:'GET',headers:{}})",
        "Object.prototype.toJSON=()=>({url:'https://example.com',method:'GET',headers:{}})",
    ] {
        let script = format!(
            "(() => {{ const request={{url:42,method:'GET',headers:{{}}}}; {setup}; return {{request}}; }})()"
        );
        expect_error(
            evaluate_request(&script, "https://example.com", &SecretSet::default()),
            "RequestValidation",
        );
    }
}

#[test]
fn replacing_global_json_cannot_replace_invalid_native_types() {
    expect_error(
        evaluate_request(
            "(() => { JSON.stringify=()=>'{\"url\":\"https://example.com\",\"method\":\"GET\",\"headers\":{}}'; return {request:{url:42,method:'GET',headers:{}}}; })()",
            "https://example.com",
            &SecretSet::default(),
        ),
        "RequestValidation",
    );
}

#[test]
fn null_prototype_headers_are_accepted() {
    let request = expect_request(evaluate_request(
        "(() => { const headers=Object.create(null); headers['X-Test']='value'; return {request:{url:'https://example.com',method:'GET',headers}}; })()",
        "https://example.com",
        &SecretSet::default(),
    ));
    assert_eq!(request.headers["X-Test"], "value");
}

#[test]
fn caught_out_of_memory_is_terminal_script_memory() {
    expect_error(
        evaluate_request(
            "(() => { try { new ArrayBuffer(32 * 1024 * 1024); } catch (_) {} return {request:{url:'https://example.com',method:'GET',headers:{}}}; })()",
            "https://example.com",
            &SecretSet::default(),
        ),
        "ScriptMemory",
    );
}

#[test]
fn out_of_memory_then_loop_prioritizes_script_timeout() {
    let started = Instant::now();
    expect_error(
        evaluate_request(
            "(() => { try { new ArrayBuffer(32 * 1024 * 1024); } catch (_) {} while(true){} })()",
            "https://example.com",
            &SecretSet::default(),
        ),
        "ScriptTimeout",
    );
    assert!(started.elapsed() >= Duration::from_millis(100));
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[test]
fn out_of_memory_then_unrelated_throw_stays_script_memory() {
    expect_error(
        evaluate_request(
            "(() => { try { new ArrayBuffer(32 * 1024 * 1024); } catch (_) {} throw new Error('unrelated'); })()",
            "https://example.com",
            &SecretSet::default(),
        ),
        "ScriptMemory",
    );
}
