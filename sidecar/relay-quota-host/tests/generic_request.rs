use relay_quota_host::{
    protocol::{ProviderKind, RequestDefinition, SanitizedError, SecretSet},
    script::{evaluate_generic_request, ScriptRequest},
};
use std::collections::BTreeMap;

fn map(entries: &[(&str, &str)]) -> BTreeMap<String, String> {
    entries
        .iter()
        .map(|(name, value)| ((*name).into(), (*value).into()))
        .collect()
}

fn expect_request(result: Result<ScriptRequest, SanitizedError>) -> ScriptRequest {
    match result {
        Ok(request) => request,
        Err(error) => panic!("expected request, got {}", error.category),
    }
}

#[test]
fn generic_query_command_round_trips_structured_request_definition() {
    let command = serde_json::json!({
        "id": "generic-1",
        "operation": "query",
        "providerKind": "generic",
        "baseUrl": "http://127.0.0.1:1234",
        "requestDefinition": {
            "method": "POST",
            "path": "/usage",
            "query": {"scope": "current"},
            "headers": {"Authorization": "Bearer {{apiKey}}"},
            "body": "{\"token\":\"{{accessToken}}\"}"
        },
        "extractorScript": "function(response){return {remaining:response.balance};}",
        "secrets": {"apiKey":"a","accessToken":"b","userId":""},
        "timeoutMs": 10000,
        "trustedDestination": "http://127.0.0.1:1234"
    });
    let parsed: relay_quota_host::protocol::QueryCommand =
        serde_json::from_value(command).expect("generic command");
    assert_eq!(parsed.provider_kind, ProviderKind::Generic);
    assert_eq!(parsed.request_definition.expect("request").method, "POST");
}

#[test]
fn generic_request_expands_tokens_without_quickjs() {
    let definition = RequestDefinition {
        method: "POST".into(),
        path: "/usage/{{userId}}".into(),
        query: map(&[("scope", "{{accessToken}}"), ("repeat", "{{apiKey}}")]),
        headers: map(&[("Authorization", "Bearer {{apiKey}}")]),
        body: Some("{\"token\":\"{{accessToken}}\"}".into()),
    };
    let secrets = SecretSet {
        api_key: "api-key".into(),
        access_token: "access-token".into(),
        user_id: "user-7".into(),
    };

    let request = expect_request(evaluate_generic_request(
        &definition,
        "https://relay.example/root",
        &secrets,
    ));

    assert_eq!(request.method, "POST");
    assert_eq!(
        request.url,
        "https://relay.example/usage/user-7?repeat=api-key&scope=access-token"
    );
    assert_eq!(request.headers["Authorization"], "Bearer api-key");
    assert_eq!(
        request.body.as_deref(),
        Some("{\"token\":\"access-token\"}")
    );
}

#[test]
fn generic_request_rejects_absolute_or_cross_origin_paths() {
    let secrets = SecretSet::default();
    for path in [
        "https://evil.example/private",
        "//evil.example/private",
        "/usage#fragment",
        "/usage\nforbidden",
    ] {
        let definition = RequestDefinition {
            method: "GET".into(),
            path: path.into(),
            query: BTreeMap::new(),
            headers: BTreeMap::new(),
            body: None,
        };
        let error = match evaluate_generic_request(&definition, "https://relay.example", &secrets) {
            Ok(_) => panic!("invalid path was accepted"),
            Err(error) => error,
        };
        assert_eq!(error.category, "RequestValidation");
    }
}
