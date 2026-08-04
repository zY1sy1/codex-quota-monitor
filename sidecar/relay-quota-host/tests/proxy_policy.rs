use std::{
    collections::BTreeMap,
    env,
    ffi::OsString,
    io::{Read, Write},
    net::TcpListener,
    sync::{mpsc, Mutex},
    thread,
    time::{Duration, Instant},
};

use relay_quota_host::{
    destination::validate_destination, http_client::execute_request, script::ScriptRequest,
};

static ENV_MUTEX: Mutex<()> = Mutex::new(());
const PROXY_VARIABLES: [&str; 6] = [
    "HTTP_PROXY",
    "http_proxy",
    "HTTPS_PROXY",
    "https_proxy",
    "ALL_PROXY",
    "all_proxy",
];
const NO_PROXY_VARIABLES: [&str; 2] = ["NO_PROXY", "no_proxy"];

struct ProxyEnvironment {
    saved: Vec<(&'static str, Option<OsString>)>,
}

impl ProxyEnvironment {
    fn poisoned(proxy_url: &str) -> Self {
        let mut saved = Vec::new();
        for name in PROXY_VARIABLES.into_iter().chain(NO_PROXY_VARIABLES) {
            saved.push((name, env::var_os(name)));
        }
        set_proxy_variables(proxy_url);
        for name in NO_PROXY_VARIABLES {
            env::remove_var(name);
        }
        Self { saved }
    }
}

impl Drop for ProxyEnvironment {
    fn drop(&mut self) {
        for (name, value) in self.saved.drain(..) {
            match value {
                Some(value) => env::set_var(name, value),
                None => env::remove_var(name),
            }
        }
    }
}

fn set_proxy_variables(proxy_url: &str) {
    for name in PROXY_VARIABLES {
        env::set_var(name, proxy_url);
    }
}

fn request(url: String) -> ScriptRequest {
    ScriptRequest {
        url,
        method: "GET".into(),
        headers: BTreeMap::new(),
        body: None,
    }
}

#[test]
fn loopback_is_forced_direct_while_remote_relays_keep_ambient_proxy_support() {
    let _lock = ENV_MUTEX
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let poison_proxy = TcpListener::bind("127.0.0.1:0").unwrap();
    poison_proxy.set_nonblocking(true).unwrap();
    let proxy_url = format!("http://{}", poison_proxy.local_addr().unwrap());
    let _environment = ProxyEnvironment::poisoned(&proxy_url);

    let target = TcpListener::bind("127.0.0.1:0").unwrap();
    target.set_nonblocking(true).unwrap();
    let target_address = target.local_addr().unwrap();
    let (contact_sender, contact_receiver) = mpsc::channel();
    let target_handle = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            match target.accept() {
                Ok((mut stream, _)) => {
                    contact_sender.send(true).unwrap();
                    let mut request = [0_u8; 4096];
                    let _ = stream.read(&mut request);
                    let _ = stream.write_all(
                        b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}",
                    );
                    return;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    if Instant::now() >= deadline {
                        contact_sender.send(false).unwrap();
                        return;
                    }
                    thread::sleep(Duration::from_millis(5));
                }
                Err(_) => {
                    contact_sender.send(false).unwrap();
                    return;
                }
            }
        }
    });
    let loopback_origin = format!("http://{target_address}");
    let loopback_request = request(format!("{loopback_origin}/usage"));
    let loopback_destination = validate_destination(
        &loopback_origin,
        &loopback_request.url,
        Some(loopback_origin.as_str()),
    )
    .unwrap_or_else(|error| panic!("destination validation failed: {}", error.category));

    let loopback_result = execute_request(&loopback_destination, &loopback_request, 500);
    let target_contacted = contact_receiver
        .recv_timeout(Duration::from_secs(3))
        .unwrap();
    target_handle.join().unwrap();
    let poison_contacted = poison_proxy.accept().is_ok();
    assert!(loopback_result.is_ok());
    assert!(target_contacted);
    assert!(!poison_contacted, "loopback request reached ambient proxy");

    let remote_url = "http://relay.invalid:8080/usage";
    let remote_error = validate_destination(
        "http://relay.invalid:8080",
        remote_url,
        Some("http://relay.invalid:8080"),
    )
    .expect_err("remote plaintext relay must be rejected");
    assert_eq!(remote_error.category, "DestinationValidation");
}
