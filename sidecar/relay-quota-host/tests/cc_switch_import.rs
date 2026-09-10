use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicU64, Ordering},
};

use relay_quota_host::cc_switch::{classify_script, inspect_cc_switch_database, ImportStatus};
use rusqlite::{params, Connection};

static FIXTURE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn unique_fixture_path(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "cc-switch-import-{label}-{}-{}.db",
        std::process::id(),
        FIXTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ))
}

fn create_schema(connection: &Connection) {
    connection
        .execute_batch(
            "CREATE TABLE providers (
                id TEXT PRIMARY KEY,
                app_type TEXT NOT NULL,
                name TEXT NOT NULL,
                settings_config TEXT NOT NULL,
                meta TEXT NOT NULL,
                is_current BOOLEAN NOT NULL DEFAULT 0
             );
             CREATE TABLE provider_endpoints (
                id INTEGER PRIMARY KEY,
                provider_id TEXT NOT NULL,
                app_type TEXT NOT NULL,
                url TEXT NOT NULL,
                added_at INTEGER NOT NULL
             );",
        )
        .expect("create fixture schema");
}

fn usage_meta(enabled: bool, language: &str, code: &str) -> String {
    serde_json::json!({
        "usage_script": {
            "enabled": enabled,
            "language": language,
            "code": code,
            "timeout": 10,
            "templateType": "general",
            "autoQueryInterval": 10,
            "apiKey": "FORBIDDEN_META_SECRET_78431"
        }
    })
    .to_string()
}

fn insert_provider(connection: &Connection, id: &str, app_type: &str, name: &str, meta: &str) {
    connection
        .execute(
            "INSERT INTO providers(id,app_type,name,settings_config,meta) VALUES(?1,?2,?3,?4,?5)",
            params![
                id,
                app_type,
                name,
                "{\"apiKey\":\"FORBIDDEN_SETTINGS_SECRET_91357\"}",
                meta
            ],
        )
        .expect("insert provider");
}

fn insert_endpoint(
    connection: &Connection,
    provider_id: &str,
    app_type: &str,
    url: &str,
    added_at: i64,
) {
    connection
        .execute(
            "INSERT INTO provider_endpoints(provider_id,app_type,url,added_at) VALUES(?1,?2,?3,?4)",
            params![provider_id, app_type, url, added_at],
        )
        .expect("insert endpoint");
}

fn create_cc_switch_fixture(path: &Path) {
    let connection = Connection::open(path).expect("create fixture database");
    create_schema(&connection);
    let meta = usage_meta(
        true,
        "javascript",
        "({request:{url:'{{baseUrl}}/v1/usage',method:'GET',headers:{Authorization:'Bearer {{apiKey}}'}},extractor:function(response){return {isValid:true,remaining:response.balance,unit:'USD'};}})",
    );
    insert_provider(&connection, "source-1", "codex", "wakaka", &meta);
    insert_endpoint(
        &connection,
        "source-1",
        "codex",
        "https://api.wkkapi.com",
        1,
    );
}

#[test]
fn blocks_literal_credentials_without_blocking_placeholders() {
    assert_eq!(classify_script(""), ImportStatus::TemplateOnly);
    assert_eq!(classify_script("  \n\t"), ImportStatus::TemplateOnly);

    let blocked = [
        r#"({request:{url:'{{baseUrl}}/usage',headers:{Authorization:'Bearer sk-live-1234567890abcdef'}},extractor:r=>r})"#,
        r#"const apiKey = 'abcdef0123456789abcdef0123456789';"#,
        r#"({request:{url:'https://name:password@relay.example/usage'},extractor:r=>r})"#,
        r#"({request:{url:'https://relay.example/usage?token=abcdef0123456789'},extractor:r=>r})"#,
    ];
    for script in blocked {
        assert_eq!(classify_script(script), ImportStatus::CredentialDetected);
    }

    let allowed = [
        r#"({request:{url:'{{baseUrl}}/usage',headers:{Authorization:'Bearer {{apiKey}}'}},extractor:r=>r})"#,
        r#"({request:{url:`${baseUrl}/usage`,headers:{Authorization:`Bearer ${apiKey}`}},extractor:r=>r})"#,
        r#"({request:{url:'{{baseUrl}}/usage?token={{apiKey}}'},extractor:r=>r})"#,
    ];
    for script in allowed {
        assert_eq!(classify_script(script), ImportStatus::Ready);
    }
}

#[test]
fn exposes_empty_builtin_balance_templates_as_template_only() {
    let path = unique_fixture_path("template-only");
    let connection = Connection::open(&path).expect("create template-only fixture");
    create_schema(&connection);
    let meta = serde_json::json!({
        "usage_script": {
            "enabled": true,
            "language": "javascript",
            "code": "",
            "timeout": 10,
            "templateType": "balance",
            "autoQueryInterval": 5
        }
    })
    .to_string();
    insert_provider(&connection, "source-deepseek", "codex", "DeepSeek", &meta);
    insert_endpoint(
        &connection,
        "source-deepseek",
        "codex",
        "https://api.deepseek.com",
        1,
    );
    drop(connection);

    let response = inspect_cc_switch_database(&path);
    let serialized = serde_json::to_string(&response).expect("serialize response");

    assert!(response.ok);
    assert_eq!(response.providers.len(), 1);
    assert_eq!(
        response.providers[0].import_status,
        ImportStatus::TemplateOnly
    );
    assert!(response.providers[0].code.is_none());
    assert_eq!(response.providers[0].template_type, "balance");
    assert!(serialized.contains("\"importStatus\":\"templateOnly\""));
    fs::remove_file(path).expect("remove fixture");
}

#[test]
fn rejects_control_characters_and_oversized_scripts() {
    assert_eq!(
        classify_script("function x(){\u{0000}}"),
        ImportStatus::CredentialDetected
    );
    assert_eq!(
        classify_script(&"a".repeat(262_145)),
        ImportStatus::CredentialDetected
    );
}

#[test]
fn reads_only_whitelisted_usage_fields() {
    let path = unique_fixture_path("whitelist");
    create_cc_switch_fixture(&path);
    let before = fs::metadata(&path)
        .expect("fixture metadata")
        .modified()
        .expect("modified time");

    let response = inspect_cc_switch_database(&path);
    let serialized = serde_json::to_string(&response).expect("serialize response");

    assert!(response.ok);
    assert_eq!(
        response.providers[0].endpoint_candidates,
        ["https://api.wkkapi.com"]
    );
    assert!(serialized.contains("/v1/usage"));
    assert!(!serialized.contains("FORBIDDEN_META_SECRET_78431"));
    assert!(!serialized.contains("FORBIDDEN_SETTINGS_SECRET_91357"));
    assert_eq!(
        fs::metadata(&path)
            .expect("metadata after")
            .modified()
            .expect("modified time"),
        before
    );
    fs::remove_file(path).expect("remove fixture");
}

#[test]
fn defaults_missing_optional_template_type_to_general() {
    let path = unique_fixture_path("optional-template-type");
    let connection = Connection::open(&path).expect("create optional template fixture");
    create_schema(&connection);
    insert_provider(
        &connection,
        "source-without-template",
        "codex",
        "without-template",
        &serde_json::json!({
            "usage_script": {
                "enabled": true,
                "language": "javascript",
                "code": "({request:{url:'{{baseUrl}}/usage',method:'GET'},extractor:r=>r})",
                "timeout": 10,
                "autoQueryInterval": 10
            }
        })
        .to_string(),
    );
    drop(connection);

    let response = inspect_cc_switch_database(&path);

    assert!(response.ok);
    assert_eq!(response.providers.len(), 1);
    assert_eq!(response.providers[0].template_type, "general");
    fs::remove_file(path).expect("remove optional template fixture");
}

#[test]
fn reports_missing_and_unsupported_databases_without_details() {
    let missing_path = unique_fixture_path("missing");
    let missing = inspect_cc_switch_database(&missing_path);
    assert!(!missing.ok);
    assert_eq!(
        missing.error.as_ref().map(|error| error.category),
        Some("CcSwitchNotFound")
    );

    let unsupported_path = unique_fixture_path("unsupported");
    Connection::open(&unsupported_path).expect("create unsupported database");
    let unsupported = inspect_cc_switch_database(&unsupported_path);
    assert!(!unsupported.ok);
    assert_eq!(
        unsupported.error.as_ref().map(|error| error.category),
        Some("CcSwitchSchemaUnsupported")
    );
    fs::remove_file(unsupported_path).expect("remove unsupported database");
}

#[test]
fn reports_a_locked_database_as_busy() {
    let path = unique_fixture_path("busy");
    create_cc_switch_fixture(&path);
    let connection = Connection::open(&path).expect("open locking connection");
    connection
        .execute_batch("BEGIN EXCLUSIVE; UPDATE providers SET name = name;")
        .expect("lock fixture");

    let response = inspect_cc_switch_database(&path);

    assert!(!response.ok);
    assert_eq!(
        response.error.as_ref().map(|error| error.category),
        Some("CcSwitchDatabaseBusy")
    );
    connection
        .execute_batch("ROLLBACK")
        .expect("release fixture lock");
    drop(connection);
    fs::remove_file(path).expect("remove fixture");
}

#[test]
fn sorts_deduplicates_and_caps_endpoint_candidates() {
    let path = unique_fixture_path("endpoints");
    let connection = Connection::open(&path).expect("create endpoint fixture");
    create_schema(&connection);
    insert_provider(
        &connection,
        "source-1",
        "codex",
        "wakaka",
        &usage_meta(true, "javascript", "({request:{},extractor:r=>r})"),
    );
    for index in (0..20).rev() {
        insert_endpoint(
            &connection,
            "source-1",
            "codex",
            &format!("https://relay-{index:02}.example"),
            index,
        );
    }
    insert_endpoint(
        &connection,
        "source-1",
        "codex",
        "https://relay-00.example",
        30,
    );
    drop(connection);

    let response = inspect_cc_switch_database(&path);

    assert!(response.ok);
    assert_eq!(response.providers[0].endpoint_candidates.len(), 16);
    assert_eq!(
        response.providers[0].endpoint_candidates[0],
        "https://relay-00.example"
    );
    assert_eq!(
        response.providers[0].endpoint_candidates[15],
        "https://relay-15.example"
    );
    fs::remove_file(path).expect("remove fixture");
}

#[test]
fn reports_current_providers_without_leaking_settings() {
    let path = unique_fixture_path("current");
    let connection = Connection::open(&path).expect("create current fixture");
    create_schema(&connection);
    insert_provider(
        &connection,
        "source-current-codex",
        "codex",
        "wakaka",
        &usage_meta(true, "javascript", "({request:{},extractor:r=>r})"),
    );
    insert_provider(
        &connection,
        "source-current-claude",
        "claude",
        "OpenCode Go",
        &usage_meta(true, "javascript", "({request:{},extractor:r=>r})"),
    );
    connection
        .execute_batch(
            "UPDATE providers SET is_current = 1
             WHERE id IN ('source-current-codex','source-current-claude');",
        )
        .expect("mark current providers");
    drop(connection);

    let response = inspect_cc_switch_database(&path);
    let serialized = serde_json::to_string(&response).expect("serialize response");

    assert!(response.ok);
    assert_eq!(response.current_providers.len(), 2);
    assert_eq!(response.current_providers[0].app_type, "claude");
    assert_eq!(
        response.current_providers[0].provider_id,
        "source-current-claude"
    );
    assert_eq!(response.current_providers[0].name, "OpenCode Go");
    assert_eq!(response.current_providers[1].app_type, "codex");
    assert_eq!(
        response.current_providers[1].provider_id,
        "source-current-codex"
    );
    assert!(serialized.contains("\"currentProviders\""));
    assert!(!serialized.contains("FORBIDDEN_META_SECRET_78431"));
    assert!(!serialized.contains("FORBIDDEN_SETTINGS_SECRET_91357"));
    fs::remove_file(path).expect("remove fixture");
}

#[test]
fn omits_disabled_usage_scripts() {
    let path = unique_fixture_path("disabled");
    let connection = Connection::open(&path).expect("create disabled fixture");
    create_schema(&connection);
    insert_provider(
        &connection,
        "source-1",
        "codex",
        "disabled",
        &usage_meta(false, "javascript", "literal script"),
    );
    drop(connection);

    let response = inspect_cc_switch_database(&path);

    assert!(response.ok);
    assert!(response.providers.is_empty());
    fs::remove_file(path).expect("remove fixture");
}

#[test]
fn removes_code_for_unsupported_languages_and_detected_credentials() {
    let path = unique_fixture_path("blocked-code");
    let connection = Connection::open(&path).expect("create blocked fixture");
    create_schema(&connection);
    insert_provider(
        &connection,
        "source-python",
        "codex",
        "python",
        &usage_meta(true, "python", "FORBIDDEN_UNSUPPORTED_CODE_24680"),
    );
    insert_provider(
        &connection,
        "source-secret",
        "codex",
        "secret",
        &usage_meta(
            true,
            "javascript",
            "const apiKey = 'abcdef0123456789abcdef0123456789';",
        ),
    );
    drop(connection);

    let response = inspect_cc_switch_database(&path);
    let serialized = serde_json::to_string(&response).expect("serialize response");

    assert!(response.ok);
    assert_eq!(response.providers.len(), 2);
    assert_eq!(
        response.providers[0].import_status,
        ImportStatus::UnsupportedLanguage
    );
    assert!(response.providers[0].code.is_none());
    assert_eq!(
        response.providers[1].import_status,
        ImportStatus::CredentialDetected
    );
    assert!(response.providers[1].code.is_none());
    assert!(!serialized.contains("FORBIDDEN_UNSUPPORTED_CODE_24680"));
    assert!(!serialized.contains("abcdef0123456789abcdef0123456789"));
    fs::remove_file(path).expect("remove fixture");
}

#[test]
fn rejects_more_than_the_bounded_provider_count() {
    let path = unique_fixture_path("provider-limit");
    let mut connection = Connection::open(&path).expect("create provider limit fixture");
    create_schema(&connection);
    let transaction = connection.transaction().expect("start fixture transaction");
    let meta = usage_meta(true, "javascript", "({request:{},extractor:r=>r})");
    for index in 0..129 {
        insert_provider(
            &transaction,
            &format!("source-{index:03}"),
            "codex",
            &format!("provider-{index:03}"),
            &meta,
        );
    }
    transaction.commit().expect("commit fixture transaction");
    drop(connection);

    let response = inspect_cc_switch_database(&path);

    assert!(!response.ok);
    assert!(response.providers.is_empty());
    assert_eq!(
        response.error.as_ref().map(|error| error.category),
        Some("CcSwitchSchemaUnsupported")
    );
    fs::remove_file(path).expect("remove fixture");
}

#[test]
fn rejects_a_discovery_response_above_the_client_byte_limit() {
    let path = unique_fixture_path("response-limit");
    let mut connection = Connection::open(&path).expect("create response limit fixture");
    create_schema(&connection);
    let transaction = connection.transaction().expect("start fixture transaction");
    let code = "a".repeat(262_144);
    let meta = usage_meta(true, "javascript", &code);
    for index in 0..4 {
        insert_provider(
            &transaction,
            &format!("source-{index}"),
            "codex",
            &format!("provider-{index}"),
            &meta,
        );
    }
    transaction.commit().expect("commit fixture transaction");
    drop(connection);

    let response = inspect_cc_switch_database(&path);

    assert!(!response.ok);
    assert!(response.providers.is_empty());
    assert_eq!(
        response.error.as_ref().map(|error| error.category),
        Some("CcSwitchSchemaUnsupported")
    );
    fs::remove_file(path).expect("remove fixture");
}

#[test]
fn inspector_process_emits_one_sanitized_json_line() {
    let path = unique_fixture_path("process");
    create_cc_switch_fixture(&path);

    let output = Command::new(env!("CARGO_BIN_EXE_relay-quota-host"))
        .arg("--inspect-cc-switch")
        .arg(&path)
        .output()
        .expect("run inspector process");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    assert_eq!(
        output.stdout.iter().filter(|byte| **byte == b'\n').count(),
        1
    );
    assert!(output.stdout.ends_with(b"\n"));
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("parse inspector output");
    assert_eq!(response["ok"], true);
    assert_eq!(response["providers"][0]["name"], "wakaka");
    let stdout = String::from_utf8(output.stdout).expect("inspector output is UTF-8");
    assert!(!stdout.contains("FORBIDDEN_META_SECRET_78431"));
    assert!(!stdout.contains("FORBIDDEN_SETTINGS_SECRET_91357"));
    fs::remove_file(path).expect("remove fixture");
}
