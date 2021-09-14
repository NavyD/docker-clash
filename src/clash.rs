use std::{convert::TryFrom, fs::File, io::BufReader, path::Path, str::FromStr};

use anyhow::{anyhow, bail, Error, Result};
use cmd_lib::*;
use log::*;
use macros::FillFn;
use serde::Deserialize;
use structopt::StructOpt;

#[derive(Debug, Clone, Deserialize, StructOpt, Default, FillFn)]
#[serde(rename_all = "kebab-case", default)]
pub struct Config {
    #[structopt(long)]
    pub redir_port: Option<u16>,

    #[structopt(long)]
    pub port: Option<u16>,

    #[structopt(long)]
    pub socks_port: Option<u16>,

    #[structopt(long)]
    pub mixed_port: Option<u16>,

    #[structopt(long)]
    pub allow_lan: Option<bool>,

    #[structopt(flatten)]
    pub tun: Tun,
}

#[derive(Debug, Clone, Deserialize, StructOpt, Default)]
#[serde(rename_all = "kebab-case")]
pub struct Tun {
    #[structopt(long = "--tun-enable")]
    pub enable: Option<bool>,
}

impl Config {
    pub fn try_from_path<P: AsRef<Path>>(path: P) -> Result<Self> {
        serde_yaml::from_reader(BufReader::new(File::open(path)?)).map_err(Into::into)
    }
}

impl FromStr for Config {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        serde_yaml::from_str(s).map_err(Into::into)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_de_clash_config() -> Result<()> {
        let s = r#"
port: 7890
socks-port: 7891
redir-port: 7892
mixed-port: 7893
mode: rule
log-level: warning
allow-lan: true
external-controller: 0.0.0.0:9090
secret: "59090"
bind-address: "*"
bind-address: "*"
external-ui: /ui
tun-enable: true
interface-name: eth0
# When set to false, resolver won't translate hostnames to IPv6 addresses
ipv6: false
tun:
  enable: true
  stack: system
  # stack: gvisor
  dns-hijack:
    - tcp://8.8.8.8:53
    - tcp://8.8.4.4:53
dns:
  enable: true
  ipv6: false
  # enhanced-mode: fake-ip
  enhanced-mode: redir-host
  fake-ip-range: 198.18.0.1/16
  listen: 0.0.0.0:5353
  use-hosts: true"#;
        let config = serde_yaml::from_str::<Config>(s)?;
        assert_eq!(config.allow_lan, Some(true));
        assert_eq!(config.redir_port, Some(7892));
        assert_eq!(config.port, Some(7890));
        assert_eq!(config.tun.enable, Some(true));
        Ok(())
    }
}
