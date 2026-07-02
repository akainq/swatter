// Conformance: официальный sentry (Rust crate) должен доставить ошибку
// в Swatter, зная только DSN (ADR-0001).
// Запуск: SWATTER_DSN=... cargo run
use std::env;

fn main() {
    let dsn = env::var("SWATTER_DSN").expect("SWATTER_DSN not set");

    let guard = sentry::init((
        dsn,
        sentry::ClientOptions {
            release: Some("conformance@0.0.1".into()),
            environment: Some("conformance".into()),
            ..Default::default()
        },
    ));

    let err = std::io::Error::new(
        std::io::ErrorKind::Other,
        "conformance: hello from sentry-rust",
    );
    sentry::capture_error(&err);

    // drop гарантирует flush перед выходом
    drop(guard);
    println!("event sent");
}
