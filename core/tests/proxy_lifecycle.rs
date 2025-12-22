use std::net::TcpListener;
use std::time::Duration;

use rust_lib_cheddarproxy::api::proxy_api::{
    create_default_config, get_proxy_status, init_core, start_proxy, stop_proxy,
};

fn available_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "Requires ability to bind to localhost sockets"]
async fn proxy_start_stop_transitions_state() {
    let storage_dir = tempfile::tempdir().unwrap();
    init_core(Some(storage_dir.path().to_string_lossy().to_string())).unwrap();

    let mut config = create_default_config();
    config.enable_https = false;
    config.storage_path = storage_dir.path().to_string_lossy().to_string();
    config.port = available_port();

    start_proxy(config).await.expect("proxy starts");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(get_proxy_status().is_running);

    stop_proxy().await.expect("proxy stops");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!get_proxy_status().is_running);
}
