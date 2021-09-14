use std::collections::HashSet;

use anyhow::{anyhow, bail, Error, Result};
use cmd_lib::*;
use log::*;
use users::{get_current_uid, get_user_by_name, get_user_by_uid, User};
use which::which;

use crate::cli::Opt;

/// 使用ps命令找到pid进程对应的username
pub fn get_user_by_pid(pid: u32) -> Result<User> {
    let username = run_fun!(ps -o user= -p $pid)?;
    debug!("got username {} by pid: {}", username, pid);
    get_user_by_name(&username).ok_or_else(|| anyhow!("not found user by name: {}", username))
}

/// 通过port找出唯一对应pid。如果发现多个pid或没有pid则返回err
///
/// 使用`lsof`解析
pub fn get_pid_by_port(port: u16) -> Result<u32> {
    let res = run_fun!(lsof -i :$port -F p)?;
    let pids = res
        .lines()
        .map(|line| {
            trace!("parsing line: {}", line);
            match line.as_bytes().get(0) {
                Some(b'p') => line[1..].parse::<u32>().ok(),
                _ => None,
            }
        })
        .flatten()
        .collect::<HashSet<_>>();
    if pids.len() != 1 {
        error!(
            "illegal {} pids found: {:?}. output: {}",
            pids.len(),
            pids,
            res
        );
        bail!("illegal {} pids found", pids.len())
    }
    Ok(pids.into_iter().next().unwrap())
}

static CHAIN_CLASH: &str = "CLASH";
static CHAIN_CLASH_EX: &str = "CLASH_EXTERNAL";
static TABLE_NAT: &str = "nat";
static TABLE_MANGLE: &str = "mangle";

struct Program {
    opt: Opt,
}

impl Program {
    fn new(opt: Opt) -> Result<Self> {
        Ok(Self { opt })
    }

    fn setup_redir(&self) -> Result<()> {
        let (tun_name, table_id, mark_id, uid) = (
            &self.opt.tun_name,
            self.opt.table_id,
            self.opt.mark_id,
            self.opt.user.uid(),
        );
        if let Err(e) = run_cmd! {
            // 接管clash宿主机内部流量
            iptables -t mangle -N "$CHAIN_CLASH";
            iptables -t mangle -F "$CHAIN_CLASH";
            // filter clash traffic running under uid 注意顺序 owner过滤 要在 set mark之前
            iptables -t mangle -A "$CHAIN_CLASH" -m owner --uid-owner "$uid" -j RETURN;
            // private
            local_iptables mangle "$CHAIN_CLASH"
            // mark
            iptables -t mangle -A "$CHAIN_CLASH" -j MARK --set-xmark $mark_id

            iptables -t mangle -A OUTPUT -j "$CHAIN_CLASH"

            // 接管转发流量
            iptables -t mangle -N CLASH_EXTERNAL
            iptables -t mangle -F CLASH_EXTERNAL
            // private
            local_iptables mangle CLASH_EXTERNAL
            // avoid rerouting for local docker
            iptables -t mangle -A CLASH_EXTERNAL -i "$tun_name" -j RETURN
            // mark
            iptables -t mangle -A CLASH_EXTERNAL -j MARK --set-xmark $mark_id

            iptables -t mangle -A PREROUTING -j CLASH_EXTERNAL

            // utun route table
            ip route replace default dev "$tun_name" table "$table_id"
            ip rule add fwmark "$mark_id" lookup "$table_id"

            // 排除 rp_filter 的故障 反向路由
            sysctl -w net.ipv4.conf."$tun_name".rp_filter=0
            sysctl -w net.ipv4.conf.all.rp_filter=0
        } {
            bail!("setup tun failed: {}", e)
        }
        Ok(())
    }

    fn setup_dir() -> Result<()> {
        todo!()
    }

    fn clean(&self) -> Result<()> {
        // delete routing table and fwmark
        info!("cleaning ip route");
        let (tun_name, table_id, mark_id) =
            (&self.opt.tun_name, self.opt.table_id, self.opt.mark_id);
        if let Err(e) = run_cmd! {
            ip route del default dev "$tun_name" table "$table_id"
            ip rule del fwmark "$mark_id" lookup "$table_id"

            ip rule del fwmark "$mark_id" table "$table_id"
            ip route del local default dev lo table "$table_id"
        } {
            warn!("Error cleaning up ip route: {}", e);
        }

        info!("cleaning iptables");
        clean_chain(TABLE_NAT, CHAIN_CLASH)?;
        clean_chain(TABLE_NAT, CHAIN_CLASH_EX)?;
        clean_chain(TABLE_MANGLE, CHAIN_CLASH)?;
        clean_chain(TABLE_MANGLE, CHAIN_CLASH_EX)?;
        Ok(())
    }
}

fn clean_chain(table: &str, chain: &str) -> Result<()> {
    run_cmd! (
        // ignore error
        sh -c r#"
            iptables -t "$table" -D OUTPUT -j "$chain" || true;
            iptables -t "$table" -D PREROUTING -j "$chain" || true;
        "#;
        iptables -t "$table" -F "$chain";
        iptables -t "$table" -X "$chain";
    )
    .map_err(Into::into)
}

fn append_local(table: &str, chain: &str) -> Result<()> {
    run_cmd! (
        iptables -t "$table" -A "$chain" -d 0.0.0.0/8 -j RETURN
        iptables -t "$table" -A "$chain" -d 127.0.0.0/8 -j RETURN
        iptables -t "$table" -A "$chain" -d 224.0.0.0/4 -j RETURN
        iptables -t "$table" -A "$chain" -d 172.16.0.0/12 -j RETURN
        iptables -t "$table" -A "$chain" -d 127.0.0.0/8 -j RETURN
        iptables -t "$table" -A "$chain" -d 169.254.0.0/16 -j RETURN
        iptables -t "$table" -A "$chain" -d 240.0.0.0/4 -j RETURN
        iptables -t "$table" -A "$chain" -d 192.168.0.0/16 -j RETURN
        iptables -t "$table" -A "$chain" -d 10.0.0.0/8 -j RETURN
    )
    .map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{net::TcpListener, process::*, sync::Once};

    #[test]
    fn test_get_user_by_pid() -> Result<()> {
        let user = get_user_by_pid(id())?;
        assert_eq!(user.uid(), get_current_uid());
        Ok(())
    }

    #[test]
    fn test_get_pid_by_port() -> Result<()> {
        let test = |port| {
            // release the bound tcp port on drop
            let cur_id = TcpListener::bind(format!("127.0.0.1:{}", port)).map(|_| ());
            let pid = get_pid_by_port(port).map_err(|_| ());
            assert!((pid.is_ok() && cur_id.is_err()) || (pid.is_err() && cur_id.is_ok()));
            if let Ok(pid) = pid {
                // check if a process id exists
                assert!(run_fun!(kill -0 $pid).is_ok());
            }
        };
        test(0);
        test(56123);
        // 3306 不是当前用户启动的 lsof无法找到同时tcp无法绑定
        // test(3306);
        test(9090);
        Ok(())
    }
}
