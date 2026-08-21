use std::{
    collections::BTreeMap,
    io::{self, Write},
    path::Path,
    sync::OnceLock,
    time::Duration,
};

use regex::{Regex, RegexSet};
use rusqlite::{Connection, Error as SqlError, ErrorCode, OpenFlags};
use serde::Serialize;
use zeroize::Zeroize;

pub const MAX_SCRIPT_BYTES: usize = 262_144;

const MAX_PROVIDERS: usize = 128;
const MAX_ENDPOINTS_PER_PROVIDER: usize = 16;
const MAX_TEXT_BYTES: usize = 4096;
const MAX_DISCOVERY_RESPONSE_BYTES: usize = 1_048_576;
const DISCOVERY_RESPONSE_BASE_BYTES: usize = 64;
const DESCRIPTOR_JSON_OVERHEAD_BYTES: usize = 512;

const PROVIDER_QUERY: &str = r#"
SELECT
    id,
    app_type,
    name,
    json_extract(meta, '$.usage_script.enabled'),
    json_extract(meta, '$.usage_script.language'),
    json_extract(meta, '$.usage_script.code'),
    json_extract(meta, '$.usage_script.timeout'),
    json_extract(meta, '$.usage_script.templateType'),
    json_extract(meta, '$.usage_script.autoQueryInterval')
FROM providers
WHERE json_type(meta, '$.usage_script') = 'object'
  AND json_extract(meta, '$.usage_script.enabled') = 1
ORDER BY app_type, name, id
LIMIT 129
"#;

const ENDPOINT_QUERY: &str = r#"
SELECT provider_id, app_type, url
FROM provider_endpoints
ORDER BY provider_id, app_type, added_at, url
"#;

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

    if script.trim().is_empty()
        || script.len() > MAX_SCRIPT_BYTES
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

fn block_script(mut code: String, status: ImportStatus) -> (Option<String>, ImportStatus) {
    code.zeroize();
    (None, status)
}

fn discovery_failure(category: &'static str, message: &'static str) -> CcSwitchDiscoveryResponse {
    CcSwitchDiscoveryResponse {
        ok: false,
        providers: Vec::new(),
        error: Some(CcSwitchDiscoveryError { category, message }),
    }
}

fn sql_error_details(error: &SqlError) -> (&'static str, &'static str) {
    match error {
        SqlError::SqliteFailure(inner, _)
            if matches!(
                inner.code,
                ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked
            ) =>
        {
            ("CcSwitchDatabaseBusy", "CC Switch database is busy.")
        }
        _ => (
            "CcSwitchSchemaUnsupported",
            "CC Switch database schema is unsupported.",
        ),
    }
}

fn map_sql_error(error: &SqlError) -> CcSwitchDiscoveryResponse {
    let (category, message) = sql_error_details(error);
    discovery_failure(category, message)
}

fn valid_text(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_TEXT_BYTES
        && !value
            .chars()
            .any(|character| character == '\u{7f}' || character < ' ')
}

fn estimated_json_string_bytes(value: &str) -> usize {
    value.chars().fold(2_usize, |size, character| {
        size.saturating_add(match character {
            '"' | '\\' | '\n' | '\r' | '\t' => 2,
            value if value < ' ' => 6,
            value => value.len_utf8(),
        })
    })
}

fn estimated_descriptor_bytes(
    source_provider_id: &str,
    source_app_type: &str,
    name: &str,
    endpoint_candidates: &[String],
    language: &str,
    code: Option<&str>,
    template_type: &str,
) -> usize {
    [
        source_provider_id,
        source_app_type,
        name,
        language,
        template_type,
    ]
    .into_iter()
    .chain(endpoint_candidates.iter().map(String::as_str))
    .chain(code)
    .fold(DESCRIPTOR_JSON_OVERHEAD_BYTES, |size, value| {
        size.saturating_add(estimated_json_string_bytes(value))
    })
}

fn zeroize_provider_codes(providers: &mut [CcSwitchProviderDescriptor]) {
    for provider in providers {
        if let Some(code) = provider.code.as_mut() {
            code.zeroize();
        }
    }
}

fn bounded_failure(
    providers: &mut [CcSwitchProviderDescriptor],
    category: &'static str,
    message: &'static str,
) -> CcSwitchDiscoveryResponse {
    zeroize_provider_codes(providers);
    discovery_failure(category, message)
}

pub fn inspect_cc_switch_database(path: &Path) -> CcSwitchDiscoveryResponse {
    if !path.is_file() {
        return discovery_failure("CcSwitchNotFound", "CC Switch database was not found.");
    }

    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY
        | OpenFlags::SQLITE_OPEN_URI
        | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let connection = match Connection::open_with_flags(path, flags) {
        Ok(value) => value,
        Err(error) => return map_sql_error(&error),
    };
    if connection.busy_timeout(Duration::from_millis(250)).is_err() {
        return discovery_failure("CcSwitchDatabaseBusy", "CC Switch database is busy.");
    }

    let mut endpoints: BTreeMap<(String, String), Vec<String>> = BTreeMap::new();
    let mut endpoint_statement = match connection.prepare(ENDPOINT_QUERY) {
        Ok(value) => value,
        Err(error) => return map_sql_error(&error),
    };
    let endpoint_rows = match endpoint_statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
        ))
    }) {
        Ok(value) => value,
        Err(error) => return map_sql_error(&error),
    };
    for row in endpoint_rows {
        let (provider_id, app_type, endpoint) = match row {
            Ok(value) => value,
            Err(error) => return map_sql_error(&error),
        };
        if !valid_text(&provider_id) || !valid_text(&app_type) || !valid_text(&endpoint) {
            continue;
        }
        let values = endpoints.entry((provider_id, app_type)).or_default();
        if values.len() < MAX_ENDPOINTS_PER_PROVIDER && !values.contains(&endpoint) {
            values.push(endpoint);
        }
    }

    let mut statement = match connection.prepare(PROVIDER_QUERY) {
        Ok(value) => value,
        Err(error) => return map_sql_error(&error),
    };
    let rows = match statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, bool>(3)?,
            row.get::<_, String>(4)?,
            row.get::<_, String>(5)?,
            row.get::<_, i64>(6)?,
            row.get::<_, Option<String>>(7)?,
            row.get::<_, i64>(8)?,
        ))
    }) {
        Ok(value) => value,
        Err(error) => return map_sql_error(&error),
    };

    let mut providers = Vec::new();
    let mut estimated_response_bytes = DISCOVERY_RESPONSE_BASE_BYTES;
    for row in rows {
        let (id, app_type, name, enabled, language, mut code, timeout, template_type, interval) =
            match row {
                Ok(value) => value,
                Err(error) => {
                    let (category, message) = sql_error_details(&error);
                    return bounded_failure(&mut providers, category, message);
                }
            };

        let template_type = template_type.unwrap_or_else(|| "general".to_owned());
        if !enabled
            || !valid_text(&id)
            || !valid_text(&app_type)
            || !valid_text(&name)
            || !valid_text(&language)
            || !valid_text(&template_type)
        {
            code.zeroize();
            continue;
        }
        if providers.len() == MAX_PROVIDERS {
            code.zeroize();
            return bounded_failure(
                &mut providers,
                "CcSwitchSchemaUnsupported",
                "CC Switch provider result is too large.",
            );
        }

        let status = if !language.eq_ignore_ascii_case("javascript") {
            ImportStatus::UnsupportedLanguage
        } else {
            classify_script(&code)
        };
        let (code, status) = if status == ImportStatus::Ready {
            (Some(code), status)
        } else {
            block_script(code, status)
        };
        let endpoint_candidates = endpoints
            .remove(&(id.clone(), app_type.clone()))
            .unwrap_or_default();
        let descriptor_bytes = estimated_descriptor_bytes(
            &id,
            &app_type,
            &name,
            &endpoint_candidates,
            &language,
            code.as_deref(),
            &template_type,
        );
        estimated_response_bytes = estimated_response_bytes.saturating_add(descriptor_bytes);
        if estimated_response_bytes > MAX_DISCOVERY_RESPONSE_BYTES {
            let mut code = code;
            if let Some(value) = code.as_mut() {
                value.zeroize();
            }
            return bounded_failure(
                &mut providers,
                "CcSwitchSchemaUnsupported",
                "CC Switch provider result is too large.",
            );
        }

        providers.push(CcSwitchProviderDescriptor {
            source_provider_id: id,
            source_app_type: app_type,
            name,
            endpoint_candidates,
            language,
            code,
            timeout_seconds: timeout.clamp(2, 30) as u64,
            template_type,
            auto_query_interval_minutes: interval.clamp(0, 1440) as u64,
            import_status: status,
        });
    }

    CcSwitchDiscoveryResponse {
        ok: true,
        providers,
        error: None,
    }
}

pub fn run_inspector_mode(path: &Path) -> i32 {
    let response = inspect_cc_switch_database(path);
    let stdout = io::stdout();
    let mut writer = stdout.lock();
    if serde_json::to_writer(&mut writer, &response).is_err()
        || writer.write_all(b"\n").is_err()
        || writer.flush().is_err()
    {
        return 1;
    }
    if response.ok {
        0
    } else {
        1
    }
}
