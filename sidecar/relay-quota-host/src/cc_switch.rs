use std::sync::OnceLock;

use regex::{Regex, RegexSet};
use serde::Serialize;
use zeroize::Zeroize;

pub const MAX_SCRIPT_BYTES: usize = 262_144;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ImportStatus {
    Ready,
    CredentialDetected,
    UnsupportedLanguage,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CcSwitchProviderDescriptor {
    pub source_provider_id: String,
    pub source_app_type: String,
    pub name: String,
    pub endpoint_candidates: Vec<String>,
    pub language: String,
    pub code: Option<String>,
    pub timeout_seconds: u64,
    pub template_type: String,
    pub auto_query_interval_minutes: u64,
    pub import_status: ImportStatus,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CcSwitchDiscoveryError {
    pub category: &'static str,
    pub message: &'static str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CcSwitchDiscoveryResponse {
    pub ok: bool,
    pub providers: Vec<CcSwitchProviderDescriptor>,
    pub error: Option<CcSwitchDiscoveryError>,
}

fn credential_patterns() -> &'static RegexSet {
    static PATTERNS: OnceLock<RegexSet> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        RegexSet::new([
            r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}",
            r"(?i)\bsk-(?:ant-)?[A-Za-z0-9_-]{16,}",
            r#"(?i)\b(api[_-]?key|access[_-]?token|secret)\s*[:=]\s*[\"'][A-Za-z0-9._~+/=-]{16,}[\"']"#,
            r"(?i)https?://[^/\s:@]+:[^@\s/]+@",
        ])
        .expect("credential patterns are constants")
    })
}

fn query_credential_pattern() -> &'static Regex {
    static PATTERN: OnceLock<Regex> = OnceLock::new();
    PATTERN.get_or_init(|| {
        Regex::new(r#"(?i)[?&](?:api[_-]?key|access[_-]?token|token|secret)=([^&\s\"']{8,})"#)
            .expect("query credential pattern is constant")
    })
}

fn is_supported_placeholder(value: &str) -> bool {
    matches!(
        value,
        "{{apiKey}}"
            | "{{accessToken}}"
            | "{{userId}}"
            | "${apiKey}"
            | "${accessToken}"
            | "${userId}"
    )
}

pub fn classify_script(script: &str) -> ImportStatus {
    let query_credential_detected = query_credential_pattern()
        .captures_iter(script)
        .filter_map(|captures| captures.get(1))
        .any(|value| !is_supported_placeholder(value.as_str()));

    if script.len() > MAX_SCRIPT_BYTES
        || script
            .chars()
            .any(|value| value == '\u{7f}' || (value < ' ' && !matches!(value, '\r' | '\n' | '\t')))
        || credential_patterns().is_match(script)
        || query_credential_detected
    {
        ImportStatus::CredentialDetected
    } else {
        ImportStatus::Ready
    }
}

#[allow(dead_code, reason = "used by the database inspector added next")]
fn block_script(mut code: String, status: ImportStatus) -> (Option<String>, ImportStatus) {
    code.zeroize();
    (None, status)
}
