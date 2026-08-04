use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QueryCommand {
    pub id: String,
    pub operation: Operation,
    pub provider_kind: ProviderKind,
    pub base_url: String,
    pub request_definition: Option<RequestDefinition>,
    pub extractor_script: String,
    pub secrets: SecretSet,
    pub timeout_ms: u64,
    pub trusted_destination: Option<String>,
}

#[derive(Clone, Copy, Deserialize, PartialEq, Eq, Debug)]
pub enum ProviderKind {
    #[serde(rename = "generic", alias = "Generic")]
    Generic,
    #[serde(rename = "custom", alias = "Custom")]
    Custom,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RequestDefinition {
    pub method: String,
    pub path: String,
    pub query: BTreeMap<String, String>,
    pub headers: BTreeMap<String, String>,
    pub body: Option<String>,
}

#[derive(Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Operation {
    Query,
}

#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SecretSet {
    pub api_key: String,
    pub access_token: String,
    pub user_id: String,
}

#[derive(Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageResult {
    pub is_valid: bool,
    pub invalid_message: Option<String>,
    pub remaining: Option<f64>,
    pub unit: Option<String>,
    pub plan_name: Option<String>,
    pub total: Option<f64>,
    pub used: Option<f64>,
    pub extra: Option<String>,
}

#[derive(Clone, Serialize, PartialEq)]
#[serde(untagged)]
pub enum HostResponse {
    Success(SuccessResponse),
    Failure(FailureResponse),
}

impl HostResponse {
    pub fn success(
        id: impl Into<String>,
        results: Vec<UsageResult>,
        http_status: u16,
        destination_host: impl Into<String>,
        duration_ms: u64,
    ) -> Self {
        Self::Success(SuccessResponse {
            id: id.into(),
            ok: true,
            results,
            meta: ResponseMeta {
                http_status,
                destination_host: destination_host.into(),
                duration_ms,
            },
        })
    }

    pub fn failure(id: impl Into<String>, error: SanitizedError) -> Self {
        Self::Failure(FailureResponse {
            id: id.into(),
            ok: false,
            error,
        })
    }
}

#[derive(Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SuccessResponse {
    pub id: String,
    pub ok: bool,
    pub results: Vec<UsageResult>,
    pub meta: ResponseMeta,
}

#[derive(Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FailureResponse {
    pub id: String,
    pub ok: bool,
    pub error: SanitizedError,
}

#[derive(Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ResponseMeta {
    pub http_status: u16,
    pub destination_host: String,
    pub duration_ms: u64,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SanitizedError {
    pub category: String,
    pub message: String,
    pub http_status: Option<u16>,
    pub retry_after_seconds: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destination_host: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destination_fingerprint: Option<String>,
}
