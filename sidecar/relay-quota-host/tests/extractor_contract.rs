use std::time::{Duration, Instant};

use relay_quota_host::{
    protocol::{SanitizedError, SecretSet},
    script::{evaluate_extractor, evaluate_extractor_with_context, WAKAKA_PRESET_SCRIPT},
};
use serde_json::{json, Value};

fn category(script: &str, response: &Value) -> String {
    extractor_error(script, response).category
}

fn extractor_error(script: &str, response: &Value) -> SanitizedError {
    match evaluate_extractor(script, response) {
        Ok(_) => panic!("extractor unexpectedly succeeded"),
        Err(error) => error,
    }
}

#[test]
fn accepts_one_result_and_preserves_explicit_zero() {
    let results = evaluate_extractor(
        "({request:{url:'https://example.com'},extractor:r=>({isValid:true,remaining:r.balance,unit:'USD'})})",
        &json!({"balance": 0.0}),
    )
    .unwrap();

    assert_eq!(results.len(), 1);
    assert_eq!(results[0].remaining, Some(0.0));
    assert_eq!(results[0].unit.as_deref(), Some("USD"));
}

#[test]
fn accepts_nonempty_arrays_and_preserves_plan_fields() {
    let results = evaluate_extractor(
        "({extractor:r=>r.plans.map(p=>({isValid:true,planName:p.name,remaining:p.remaining,total:p.total,used:p.used,unit:p.unit,extra:p.reset}))})",
        &json!({"plans":[{"name":"Weekly","remaining":50,"total":100,"used":50,"unit":"requests","reset":"7d"}]}),
    )
    .unwrap();

    assert_eq!(results.len(), 1);
    assert_eq!(results[0].plan_name.as_deref(), Some("Weekly"));
    assert_eq!(results[0].remaining, Some(50.0));
    assert_eq!(results[0].total, Some(100.0));
    assert_eq!(results[0].used, Some(50.0));
    assert_eq!(results[0].extra.as_deref(), Some("7d"));
}

#[test]
fn defaults_absent_null_and_undefined_fields_without_coercion() {
    let results = evaluate_extractor(
        "({extractor:r=>[{},Object.create(null),{isValid:null,invalidMessage:null,remaining:null,unit:undefined,planName:null,total:undefined,used:null,extra:undefined}]})",
        &json!({}),
    )
    .unwrap();

    assert_eq!(results.len(), 3);
    for result in results {
        assert!(result.is_valid);
        assert_eq!(result.invalid_message, None);
        assert_eq!(result.remaining, None);
        assert_eq!(result.unit, None);
        assert_eq!(result.plan_name, None);
        assert_eq!(result.total, None);
        assert_eq!(result.used, None);
        assert_eq!(result.extra, None);
    }
}

#[test]
fn rejects_empty_arrays_and_non_object_roots_or_entries() {
    for script in [
        "({extractor:r=>[]})",
        "({extractor:r=>null})",
        "({extractor:r=>undefined})",
        "({extractor:r=>5})",
        "({extractor:r=>[{} , null]})",
        "({extractor:r=>new Map([['remaining',5]])})",
        "({extractor:r=>new Date()})",
        "({extractor:r=>new Proxy({}, {})})",
        "({extractor:r=>Object.create({remaining:5})})",
    ] {
        assert_eq!(category(script, &json!({})), "ResultValidation", "{script}");
    }
}

#[test]
fn rejects_coercive_field_types_before_serialization() {
    for script in [
        "({extractor:r=>({isValid:'true'})})",
        "({extractor:r=>({isValid:1})})",
        "({extractor:r=>({invalidMessage:true})})",
        "({extractor:r=>({remaining:'5'})})",
        "({extractor:r=>({remaining:5n})})",
        "({extractor:r=>({unit:5})})",
        "({extractor:r=>({planName:{}})})",
        "({extractor:r=>({total:false})})",
        "({extractor:r=>({used:'1'})})",
        "({extractor:r=>({extra:[]})})",
        "({extractor:r=>({remaining:function(){}})})",
        "({extractor:r=>({unit:Symbol('USD')})})",
        "({extractor:r=>({extra:new Map()})})",
        "({extractor:r=>({planName:new Proxy({}, {})})})",
    ] {
        assert_eq!(category(script, &json!({})), "ResultValidation", "{script}");
    }
}

#[test]
fn rejects_non_finite_numeric_fields() {
    for field in ["remaining", "total", "used"] {
        for value in ["NaN", "Infinity", "-Infinity"] {
            let script = format!("({{extractor:r=>({{{field}:{value}}})}})");
            assert_eq!(category(&script, &json!({})), "ResultValidation");
        }
    }
}

#[test]
fn ignores_unknown_string_named_fields_but_rejects_enumerable_symbols() {
    let results = evaluate_extractor(
        "({extractor:r=>({remaining:2,unknown:{deep:true}})})",
        &json!({}),
    )
    .unwrap();
    assert_eq!(results[0].remaining, Some(2.0));

    let symbol_script =
        "({extractor:r=>{const x={remaining:2};x[Symbol('hidden')]='value';return x}})";
    assert_eq!(category(symbol_script, &json!({})), "ResultValidation");
}

#[test]
fn overridden_to_json_cannot_erase_invalid_native_fields() {
    for script in [
        "({extractor:r=>({remaining:function(){},toJSON(){return {remaining:5}}})})",
        "({extractor:r=>({remaining:Symbol('x'),toJSON(){return {remaining:5}}})})",
        "({extractor:r=>({remaining:new Map(),toJSON(){return {remaining:5}}})})",
    ] {
        assert_eq!(category(script, &json!({})), "ResultValidation", "{script}");
    }
}

#[test]
fn enforces_4096_utf8_byte_limit_for_every_string_field() {
    for field in ["invalidMessage", "unit", "planName", "extra"] {
        let ascii_limit = format!("({{extractor:r=>({{{field}:'a'.repeat(4096)}})}})");
        assert!(
            evaluate_extractor(&ascii_limit, &json!({})).is_ok(),
            "{field}"
        );

        let ascii_over = format!("({{extractor:r=>({{{field}:'a'.repeat(4097)}})}})");
        assert_eq!(
            category(&ascii_over, &json!({})),
            "ResultValidation",
            "{field}"
        );

        let multibyte_limit = format!("({{extractor:r=>({{{field}:'界'.repeat(1365)+'a'}})}})");
        assert!(
            evaluate_extractor(&multibyte_limit, &json!({})).is_ok(),
            "{field}"
        );

        let multibyte_over = format!("({{extractor:r=>({{{field}:'界'.repeat(1366)}})}})");
        assert_eq!(
            category(&multibyte_over, &json!({})),
            "ResultValidation",
            "{field}"
        );
    }
}

#[test]
fn rejects_normalized_results_over_256_kib() {
    let script = "({extractor:r=>Array.from({length:4096},(_,i)=>({planName:String(i)}))})";
    assert_eq!(category(script, &json!({})), "ResultValidation");
}

#[test]
fn response_is_native_json_data_not_executable_source() {
    let marker = "'});globalThis.injected=true;({x:'";
    let response = json!({"value": marker, "__proto__": {"polluted": true}});
    let results = evaluate_extractor(
        "({extractor:r=>({isValid:globalThis.injected===undefined && ({}).polluted===undefined,extra:r.value})})",
        &response,
    )
    .unwrap();

    assert!(results[0].is_valid);
    assert_eq!(results[0].extra.as_deref(), Some(marker));
}

#[test]
fn direct_host_capabilities_are_absent_from_extractor_context() {
    let results = evaluate_extractor(
        "({extractor:r=>({extra:[typeof process,typeof require,typeof fetch,typeof setTimeout].join(',')})})",
        &json!({}),
    )
    .unwrap();
    assert_eq!(
        results[0].extra.as_deref(),
        Some("undefined,undefined,undefined,undefined")
    );
}

#[test]
fn syntax_execution_and_missing_extractor_errors_are_sanitized() {
    let sentinel = "EXTRACTOR_SECRET_SENTINEL";
    for (script, expected) in [
        ("({extractor: =>", "ScriptSyntax"),
        ("({request:{}})", "ExtractorExecution"),
        ("({extractor:5})", "ExtractorExecution"),
        (
            "({extractor:r=>{throw new Error(r.secret)}})",
            "ExtractorExecution",
        ),
    ] {
        let error = extractor_error(script, &json!({"secret": sentinel}));
        assert_eq!(error.category, expected);
        let encoded = serde_json::to_string(&error).unwrap();
        assert!(!encoded.contains(sentinel));
        assert!(!encoded.contains(script));
    }
}

#[test]
fn oversized_script_and_response_are_rejected_without_echoing_input() {
    let script = "x".repeat(262_145);
    let error = extractor_error(&script, &json!({}));
    assert_eq!(error.category, "RequestTooLarge");
    assert!(!error.message.contains(&script));

    let sentinel = "RESPONSE_SENTINEL";
    let response = json!({"payload": format!("{sentinel}{}", "x".repeat(1_048_576))});
    let error = extractor_error("({extractor:r=>({})})", &response);
    assert_eq!(error.category, "ResultValidation");
    assert!(!serde_json::to_string(&error).unwrap().contains(sentinel));
}

#[test]
fn memory_limit_and_caught_oom_are_terminal_and_process_recovers() {
    for script in [
        "({extractor:r=>({extra:new ArrayBuffer(32*1024*1024)})})",
        "({extractor:r=>{try{new ArrayBuffer(32*1024*1024)}catch(e){};return {remaining:99}}})",
    ] {
        assert_eq!(category(script, &json!({})), "ScriptMemory");
    }

    let recovered = evaluate_extractor(
        "({extractor:r=>({remaining:r.balance})})",
        &json!({"balance": 7}),
    )
    .unwrap();
    assert_eq!(recovered[0].remaining, Some(7.0));
}

#[test]
fn catastrophic_native_regex_is_process_bounded_and_next_run_recovers() {
    let started = Instant::now();
    let error = extractor_error(
        "({extractor:r=>({isValid:/(a+)+$/.test(r.text)})})",
        &json!({"text": format!("{}!", "a".repeat(100_000))}),
    );
    assert_eq!(error.category, "ScriptTimeout");
    assert!(started.elapsed() < Duration::from_secs(4));

    let recovered = evaluate_extractor("({extractor:r=>({remaining:3})})", &json!({})).unwrap();
    assert_eq!(recovered[0].remaining, Some(3.0));
}

#[test]
fn infinite_loop_is_process_bounded() {
    let started = Instant::now();
    let error = extractor_error("({extractor:r=>{while(true){} }})", &json!({}));
    assert_eq!(error.category, "ScriptTimeout");
    assert!(started.elapsed() < Duration::from_secs(4));
}

#[test]
fn huge_sparse_result_array_is_rejected_before_host_allocation_and_process_recovers() {
    let error = extractor_error("({extractor:r=>new Array(100000000)})", &json!({}));
    assert_eq!(error.category, "ResultValidation");

    let recovered = evaluate_extractor("({extractor:r=>({remaining:4})})", &json!({})).unwrap();
    assert_eq!(recovered[0].remaining, Some(4.0));
}

#[test]
fn true_minimum_wire_shape_accepts_2361_results_and_rejects_2362() {
    let script = "({extractor:r=>Array.from({length:r.count},()=>({isValid:true,invalidMessage:'',remaining:0,unit:'',planName:'',total:0,used:0,extra:''}))})";
    let results = evaluate_extractor(script, &json!({"count": 2361})).unwrap();
    assert_eq!(results.len(), 2361);

    let error = extractor_error(script, &json!({"count": 2362}));
    assert_eq!(error.category, "ResultValidation");
}

#[test]
fn extractor_context_replaces_all_supported_placeholders_inside_worker() {
    let secrets = SecretSet {
        api_key: "api-context-value".into(),
        access_token: "access-context-value".into(),
        user_id: "user-context-value".into(),
    };
    let script = "({extractor:r=>({extra:['{{baseUrl}}','{{apiKey}}','{{accessToken}}','{{userId}}'].join('|')})})";
    let results = evaluate_extractor_with_context(
        script,
        &json!({}),
        "https://relay.example/base/",
        &secrets,
    )
    .unwrap();
    assert_eq!(
        results[0].extra.as_deref(),
        Some(
            "https://relay.example/base|api-context-value|access-context-value|user-context-value"
        )
    );
}

#[test]
fn extractor_context_errors_never_echo_placeholder_values() {
    let sentinels = SecretSet {
        api_key: "API_ERROR_SENTINEL".into(),
        access_token: "ACCESS_ERROR_SENTINEL".into(),
        user_id: "USER_ERROR_SENTINEL".into(),
    };
    let script =
        "({extractor:r=>{throw new Error('{{apiKey}}|{{accessToken}}|{{userId}}|{{baseUrl}}')}})";
    let error = match evaluate_extractor_with_context(
        script,
        &json!({}),
        "https://BASE_ERROR_SENTINEL.example",
        &sentinels,
    ) {
        Ok(_) => panic!("extractor unexpectedly succeeded"),
        Err(error) => error,
    };
    let encoded = serde_json::to_string(&error).unwrap();
    for sentinel in [
        "API_ERROR_SENTINEL",
        "ACCESS_ERROR_SENTINEL",
        "USER_ERROR_SENTINEL",
        "BASE_ERROR_SENTINEL",
    ] {
        assert!(!encoded.contains(sentinel));
    }
}

#[test]
fn wakaka_preset_normalizes_synthetic_wallet_fixture() {
    let response: Value =
        serde_json::from_str(include_str!("fixtures/wakaka-wallet.json")).unwrap();
    let results = evaluate_extractor(WAKAKA_PRESET_SCRIPT, &response).unwrap();

    assert_eq!(results.len(), 1);
    assert_eq!(results[0].remaining, Some(18.42));
    assert_eq!(results[0].unit.as_deref(), Some("USD"));
    assert_eq!(results[0].plan_name.as_deref(), Some("Wallet"));
}

#[test]
fn wakaka_preset_normalizes_two_synthetic_subscription_plans() {
    let response: Value =
        serde_json::from_str(include_str!("fixtures/wakaka-subscription.json")).unwrap();
    let results = evaluate_extractor(WAKAKA_PRESET_SCRIPT, &response).unwrap();

    assert_eq!(results.len(), 2);
    assert_eq!(results[0].plan_name.as_deref(), Some("Weekly"));
    assert_eq!(results[0].remaining, Some(75.0));
    assert_eq!(results[0].total, Some(100.0));
    assert_eq!(results[1].plan_name.as_deref(), Some("Monthly"));
    assert_eq!(results[1].remaining, Some(1200.0));
    assert_eq!(results[1].total, Some(2000.0));
}

#[test]
fn general_and_new_api_synthetic_extractors_are_compatible() {
    let general = evaluate_extractor(
        "({request:{url:'{{baseUrl}}/user/balance'},extractor:r=>({remaining:r.balance,unit:r.unit??'USD'})})",
        &json!({"balance": 6.25, "unit": "USD"}),
    )
    .unwrap();
    assert_eq!(general[0].remaining, Some(6.25));
    assert_eq!(general[0].unit.as_deref(), Some("USD"));

    let new_api = evaluate_extractor(
        "({request:{url:'{{baseUrl}}/api/user/self'},extractor:r=>({isValid:r.success,remaining:r.data.quota-r.data.used,total:r.data.quota,used:r.data.used,unit:'tokens',planName:r.data.plan})})",
        &json!({"success": true, "data": {"quota": 1000, "used": 125, "plan": "Pro"}}),
    )
    .unwrap();
    assert_eq!(new_api[0].remaining, Some(875.0));
    assert_eq!(new_api[0].total, Some(1000.0));
    assert_eq!(new_api[0].used, Some(125.0));
    assert_eq!(new_api[0].plan_name.as_deref(), Some("Pro"));
}
