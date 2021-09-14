use macros::FillFn;

#[derive(Debug, Clone, FillFn, Default)]
pub struct StructFill {
    redir_port: Option<u16>,
    port: Option<u16>,
    socks_port: Option<u16>,
    num: usize,
}

impl StructFill {
    pub fn test(&self) {
        // for test
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fill() {
        println!("bbbbbbbbb {}", module_path!());
        let mut old = StructFill {
            socks_port: Some(1323),
            num: 0,
            ..Default::default()
        };
        assert!(old.redir_port.is_none());

        let new = StructFill {
            redir_port: Some(532),
            num: 100,
            socks_port: Some(13421),
            port: None,
        };

        old.fill_if_some(new.clone());
        assert_eq!(old.redir_port, new.redir_port);
        assert_ne!(old.socks_port, new.socks_port);
        assert_eq!(old.num, new.num);
        assert_eq!(old.port, new.port);
    }
}
