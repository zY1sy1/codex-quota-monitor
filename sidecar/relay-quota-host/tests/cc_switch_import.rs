use relay_quota_host::cc_switch::{classify_script, ImportStatus};

#[test]
fn blocks_literal_credentials_without_blocking_placeholders() {
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
