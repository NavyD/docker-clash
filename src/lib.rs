use once_cell::sync::Lazy;

pub static CRATE_NAME: Lazy<String> = Lazy::new(|| env!("CARGO_PKG_NAME").replace('-', "_"));
pub static CRATE_VERSION: &str = env!("CARGO_PKG_VERSION");

pub mod clash;
pub mod sys;
pub mod cli;

#[cfg(test)]
mod tests {
    use super::*;
    use log::LevelFilter;
    use std::sync::Once;

    static INIT: Once = Once::new();

    #[cfg(test)]
    #[ctor::ctor]
    fn init() {
        INIT.call_once(|| {
            env_logger::builder()
                .is_test(true)
                .filter_level(LevelFilter::Debug)
                .filter_module(&CRATE_NAME, LevelFilter::Trace)
                .init();
        });
    }
}
