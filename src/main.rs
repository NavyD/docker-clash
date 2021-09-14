use std::collections::HashSet;
use std::ffi::OsString;
use std::fs::File;
use std::io::BufReader;
use std::net::TcpListener;
use std::path::PathBuf;
use std::{env, ops::Deref};

use anyhow::{anyhow, bail, Error, Result};
use cmd_lib::*;
use docker_clash::sys;
use docker_clash::{clash::Config, CRATE_NAME, CRATE_VERSION};
use iptables::IPTables;
use log::*;
use macros::*;
use once_cell::sync::Lazy;
use serde::{Deserialize, Deserializer, Serialize};
use serde_yaml::Value;
use structopt::StructOpt;
use users::{get_current_uid, get_user_by_name, get_user_by_uid, User};
use which::which;

fn main() -> Result<()> {
    env_logger::builder()
        .filter_level(LevelFilter::Warn)
        .filter_module(&CRATE_NAME, LevelFilter::Trace)
        .init();
    let mut opt = Opt::from_args();
    opt.init()?;
    // 1. parse yaml

    // 2. init env

    // clean env

    // run clash

    // do iptables

    // wait clash
    Ok(())
}

#[derive(StructOpt, Debug, Clone)]
struct Opt {
    /// tun device name
    #[structopt(long, default_value = "utun")]
    tun_name: String,

    /// table id
    #[structopt(long, default_value = &DEFAULT_TABLE_ID)]
    table_id: u32,

    /// mark id.
    #[structopt(long, default_value = &DEFAULT_MARK_ID)]
    mark_id: u32,

    /// user id or name for running clash. default current user.
    #[structopt(short, long, parse(try_from_str=parse_user), default_value = "")]
    user: User,

    /// clash config path of config.yaml. if not specified, use other options
    #[structopt(short = "-f", long)]
    config_path: Option<PathBuf>,

    #[structopt(flatten)]
    config: Config,

    #[structopt(short, long)]
    pid: Option<u32>,

    #[structopt(long)]
    clean: bool,
}

static DEFAULT_MARK_ID: Lazy<String> = Lazy::new(|| 0x162.to_string());
static DEFAULT_TABLE_ID: &Lazy<String> = &DEFAULT_MARK_ID;

/// 解析uid或username转换为user。空字符串将解析为当前用户
fn parse_user(user: &str) -> Result<User> {
    if user.is_empty() {
        get_user_by_uid(get_current_uid())
    } else {
        user.parse::<u32>()
            .map(get_user_by_uid)
            .unwrap_or_else(|_| get_user_by_name(user))
    }
    .ok_or_else(|| anyhow!("not found user for {}", user))
}

impl Opt {
    /// check env, init config, check if clash is started
    fn init(&mut self) -> Result<()> {
        self.check_env()?;

        // filling config from config file
        if let Some(path) = &self.config_path {
            info!("loading config from {:?}", path);
            let clash_config = Config::try_from_path(path)?;
            trace!("loaded config: {:?}", clash_config);
            self.config.fill_if_some(clash_config);
        }
        if self.pid.is_none() {
            self.pid = Some(self.get_pid()?);
        }

        // check if clash is started
        self.check_clash_started()?;
        Ok(())
    }

    /// 返回pid。如果未指定pid则从可用的一个config.port找出对应的pid
    fn get_pid(&self) -> Result<u32> {
        if let Some(pid) = self.pid {
            return Ok(pid);
        }
        let config = &self.config;
        trace!("looking for a port from config: {:?}", config);
        let port = config
            .port
            .or(config.mixed_port)
            .or(config.redir_port)
            .or(config.socks_port)
            .ok_or_else(|| {
                error!("not found ports in config: {:?}", config);
                anyhow!("not found any ports")
            })?;
        debug!("looking for pid by port: {}", port);
        sys::get_pid_by_port(port).map_err(|e| anyhow!("not found pid by port {}: {}", port, e))
    }

    /// 检查clash配置中的所有端口是否被绑定 且 所有端口对应的pid是否一致
    fn check_clash_started(&self) -> Result<()> {
        let config = &self.config;
        let pid = self.get_pid()?;
        let port_enabled = |port: Option<u16>| {
            if let Some(port) = port {
                trace!("checking if port {} is available", port);
                let addr = format!("127.0.0.1:{}", port);
                // 绑定了端口表示clash没有启用
                let enabled = if let Err(e) = TcpListener::bind(&addr) {
                    trace!(
                        "checking whether the pids of the port {} are consistent: {}",
                        port,
                        e
                    );
                    // 检查pid不一致
                    match sys::get_pid_by_port(port) {
                        Ok(id) => {
                            if id == pid {
                                true
                            } else {
                                error!("inconsistent pid: {}, old: {}", id, pid);
                                false
                            }
                        }
                        Err(e) => {
                            error!("not found pid by port {}: {}", port, e);
                            false
                        }
                    }
                } else {
                    // early release port when drop
                    error!("found port {} not in use", port);
                    false
                };
                info!("port {} enabled: {}", port, enabled);
                enabled
            } else {
                // 没有端口时 作为启用处理
                true
            }
        };
        if port_enabled(config.port)
            && port_enabled(config.mixed_port)
            && port_enabled(config.redir_port)
            && port_enabled(config.socks_port)
        {
            info!("checked that all clash ports have been enabled");
            Ok(())
        } else {
            bail!("the clash process does not start")
        }
    }

    fn check_env(&self) -> Result<()> {
        // todo!()
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use log::LevelFilter;
    use std::sync::Once;

    static INIT: Once = Once::new();

    static OPT: Lazy<Opt> = Lazy::new(|| {
        let config = r#"
port: 7890
socks-port: 7891
#redir-port: 7892
mixed-port: 7893
mode: rule"#
            .parse::<Config>()
            .unwrap();
        Opt {
            clean: false,
            config,
            config_path: None,
            pid: None,
            user: parse_user("").unwrap(),
            mark_id: DEFAULT_MARK_ID.parse().unwrap(),
            table_id: DEFAULT_TABLE_ID.parse().unwrap(),
            tun_name: "utun".to_string(),
        }
    });

    #[cfg(test)]
    #[ctor::ctor]
    fn init() {
        INIT.call_once(|| {
            env_logger::builder()
                .is_test(true)
                .filter_level(LevelFilter::Error)
                .filter_module(&CRATE_NAME, LevelFilter::Debug)
                .init();
        });
    }

    #[ignore]
    #[test]
    fn test_check_clash() -> Result<()> {
        OPT.check_clash_started()?;
        Ok(())
    }
}
