use std::net::TcpListener;
use std::path::PathBuf;

use anyhow::{anyhow, bail, Result};
use cmd_lib::*;
use cmd_lib_core::run_fun;
use docker_clash::{
    clash::Config,
    sys::{self, IptInfoBuilder},
    CRATE_NAME,
};
use log::*;
use once_cell::sync::Lazy;
use structopt::StructOpt;
use which::which;

fn main() -> Result<()> {
    let opt = Opt::from_args();
    init_log(opt.verbose)?;
    opt.check_env()?;
    if opt.clean {
        opt.check_clean()?;
    } else {
        opt.check_clash_started()?;
    }

    let ipt = IptInfoBuilder::default()
        .tun_name(opt.ipt_config.tun_name.clone())
        .mark_id(opt.ipt_config.mark_id)
        .table_id(opt.ipt_config.table_id)
        .local_ipset(DEFAULT_LOCAL_IPSET_NAME.to_string())
        .clash_config(opt.config.clone())
        .build()?;

    if opt.clean {
        ipt.clean();
    } else {
        ipt.config(opt.pid.expect("not found pid"))?;
    }
    Ok(())
}
#[derive(StructOpt, Debug, Clone, PartialEq, Eq, Default)]
pub struct Opt {
    #[structopt(flatten)]
    ipt_config: IptConfig,

    /// clash config path of config.yaml. if not specified, use other options
    #[structopt(short = "-f", long)]
    config_path: Option<PathBuf>,

    #[structopt(flatten)]
    config: Config,

    #[structopt(short, long)]
    pid: Option<u32>,

    #[structopt(short, long)]
    clean: bool,

    #[structopt(short, parse(from_occurrences))]
    verbose: u8,
}

/// 使用`-vvvvv`最多5个v启用Error->Trace的日志级别
fn init_log(verbose: u8) -> Result<()> {
    if verbose > 5 {
        bail!("invalid arg: {} > 5 number of verbose", verbose);
    }
    let level: log::LevelFilter = unsafe { std::mem::transmute((verbose) as usize) };
    env_logger::builder()
        .filter_level(LevelFilter::Error)
        .filter_module("cmd_lib::process", LevelFilter::Off)
        .filter_module(&CRATE_NAME, level)
        .init();
    Ok(())
}

static DEFAULT_IPT: Lazy<IptConfig> = Lazy::new(Default::default);
static DEFAULT_MARK_ID: Lazy<String> = Lazy::new(|| DEFAULT_IPT.mark_id.to_string());
static DEFAULT_TABLE_ID: Lazy<String> = Lazy::new(|| DEFAULT_IPT.table_id.to_string());
static DEFAULT_LOCAL_IPSET_NAME: &str = "local_net_clash";

#[derive(StructOpt, Debug, Clone, PartialEq, Eq)]
struct IptConfig {
    /// tun device name
    #[structopt(long, default_value = &DEFAULT_IPT.tun_name)]
    pub tun_name: String,

    /// table id
    #[structopt(long, default_value = &DEFAULT_TABLE_ID)]
    pub table_id: u32,

    /// mark id.
    #[structopt(long, default_value = &DEFAULT_MARK_ID)]
    pub mark_id: u32,
}

impl Default for IptConfig {
    fn default() -> Self {
        Self {
            tun_name: "utun".to_string(),
            table_id: 0x162,
            mark_id: 0x162,
        }
    }
}

impl Opt {
    /// 检查clash配置中的所有端口是否被绑定 且 所有端口对应的pid是否一致
    fn check_clash_started(&self) -> Result<()> {
        let config = &self.get_config()?;
        let pid = self.get_pid()?;
        let port_enabled = |port: Option<u16>| {
            if let Some(port) = port {
                trace!("checking if port {} is available", port);
                let addr = format!("127.0.0.1:{}", port);
                // 检查端口是否被占用 绑定了端口表示clash没有启用
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
        info!("checking dependencies info");
        debug!("sh path: {:?}", which("sh")?);
        debug!("lsof version: {}", run_fun!(sh -c "lsof -v 2>&1")?);
        // cargo fmt error: run_fun!(ps --version) -> run_fun!(ps - -version)?)
        debug!("ps version: {}", run_fun("ps --version")?);
        debug!("iptables version: {}", run_fun("iptables --version")?);
        debug!("ip version: {}", run_fun("ip -V")?);
        debug!("ipset version: {}", run_fun!(ipset version)?);
        Ok(())
    }

    fn check_clean(&self) -> Result<()> {
        if !self.clean {
            return Ok(());
        }
        let new = Opt {
            clean: self.clean,
            verbose: self.verbose,
            ipt_config: self.ipt_config.clone(),
            ..Default::default()
        };
        if self != &new {
            // error!("");
            bail!("invalid arguments for clean");
        }
        Ok(())
    }

    /// filling config from config file and self.config
    fn get_config(&self) -> Result<Config> {
        let mut config = self.config.clone();
        // filling config from config file
        if let Some(path) = &self.config_path {
            info!("loading config from {:?}", path.canonicalize()?);
            let clash_config = Config::try_from_path(path)?;
            trace!("loaded config: {:?}", clash_config);
            config.fill_if_some(clash_config);
        }
        Ok(config)
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
            .or(config.socks_port)
            .or(config.redir_port)
            .ok_or_else(|| {
                error!("not found ports in config: {:?}", config);
                anyhow!("not found any ports")
            })?;
        debug!("looking for pid by port: {}", port);
        sys::get_pid_by_port(port).map_err(|e| anyhow!("not found pid by port {}: {}", port, e))
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
            config,
            ..Default::default()
        }
    });

    #[ignore]
    #[test]
    fn test_check_clash() -> Result<()> {
        OPT.check_clash_started()?;
        Ok(())
    }
}
