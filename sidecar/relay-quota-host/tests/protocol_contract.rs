use relay_quota_host::protocol::{
    HostResponse, Operation, ProviderKind, QueryCommand, SanitizedError, UsageResult,
};
use serde_json::json;

#[test]
fn success_response_has_stable_camel_case_shape() {
    let response = HostResponse::success(
        "query-1",
        vec![UsageResult {
            is_valid: true,
            invalid_message: None,
            remaining: Some(18.42),
            unit: Some("USD".into()),
            plan_name: None,
            total: None,
            used: None,
            extra: None,
        }],
        200,
        "api.wkkapi.com",
        84,
    );
    let value = serde_json::to_value(response).unwrap();
    assert_eq!(value["id"], "query-1");
    assert_eq!(value["ok"], true);
    assert_eq!(value["results"][0]["remaining"], 18.42);
    assert_eq!(value["meta"]["destinationHost"], "api.wkkapi.com");
    assert!(value.get("error").is_none());
}

#[test]
fn deserializes_generic_query_command_with_structured_request_and_camel_case_secrets() {
    let command: QueryCommand = serde_json::from_value(json!({
        "id": "query-1",
        "operation": "query",
        "providerKind": "generic",
        "baseUrl": "https://api.wkkapi.com",
        "requestDefinition": {
            "method": "POST",
            "path": "/usage",
            "query": { "scope": "current" },
            "headers": { "Authorization": "Bearer {{apiKey}}" },
            "body": "{\"token\":\"{{accessToken}}\"}"
        },
        "extractorScript": "function(response){return {remaining:response.balance};}",
        "secrets": {
            "apiKey": "key",
            "accessToken": "token",
            "userId": "user"
        },
        "timeoutMs": 5000,
        "trustedDestination": "api.wkkapi.com"
    }))
    .unwrap();

    assert_eq!(command.id, "query-1");
    assert!(command.operation == Operation::Query);
    assert!(command.provider_kind == ProviderKind::Generic);
    assert_eq!(command.request_definition.as_ref().unwrap().method, "POST");
    assert_eq!(
        command.request_definition.as_ref().unwrap().query["scope"],
        "current"
    );
    assert_eq!(command.secrets.api_key, "key");
}

#[test]
fn rejects_unknown_query_command_fields() {
    let result = serde_json::from_value::<QueryCommand>(json!({
        "id": "query-1",
        "operation": "query",
        "providerKind": "generic",
        "baseUrl": "https://api.wkkapi.com",
        "requestDefinition": {
            "method": "GET",
            "path": "/usage",
            "query": {},
            "headers": {},
            "body": null
        },
        "extractorScript": "function(response){return response;}",
        "secrets": { "apiKey": "", "accessToken": "", "userId": "" },
        "timeoutMs": 5000,
        "unexpected": true
    }));

    assert!(result.is_err());
}

#[test]
fn rejects_unknown_secret_set_fields() {
    let result = serde_json::from_value::<QueryCommand>(json!({
        "id": "query-1",
        "operation": "query",
        "providerKind": "generic",
        "baseUrl": "https://api.wkkapi.com",
        "requestDefinition": {
            "method": "GET",
            "path": "/usage",
            "query": {},
            "headers": {},
            "body": null,
            "unexpected": true
        },
        "extractorScript": "function(response){return response;}",
        "secrets": {
            "apiKey": "",
            "accessToken": "",
            "userId": "",
            "unexpected": true
        },
        "timeoutMs": 5000
    }));

    assert!(result.is_err());
}

#[test]
fn failure_response_omits_success_branches() {
    let response = HostResponse::failure(
        "query-1",
        SanitizedError {
            category: "HttpStatus".into(),
            message: "Relay request returned HTTP 401.".into(),
            http_status: Some(401),
            retry_after_seconds: None,
            destination_host: None,
            destination_fingerprint: None,
        },
    );
    let value = serde_json::to_value(response).unwrap();

    assert_eq!(
        value,
        json!({
            "id": "query-1",
            "ok": false,
            "error": {
                "category": "HttpStatus",
                "message": "Relay request returned HTTP 401.",
                "httpStatus": 401,
                "retryAfterSeconds": null
            }
        })
    );
    assert!(value.get("results").is_none());
    assert!(value.get("meta").is_none());
}
