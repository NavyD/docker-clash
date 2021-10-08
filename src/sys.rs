use anyhow::{anyhow, bail, Result};
use cmd_lib::*;
use getset::{Getters, Setters};
use log::*;
use procfs::{
    net::*,
    process::{all_processes, FDTarget, Process},
};
use users::{get_current_uid, get_user_by_name, get_user_by_uid, User};

use crate::clash::Config;

pub fn get_user_by_pid(pid: u32) -> Result<User> {
    get_user_by_uid(Process::new(pid as i32)?.owner)
        .ok_or_else(|| anyhow!("not found user by pid: {:?}", pid))
}

// FIXME: tcp()只列出部分地址，常见的端口都无法找出
pub fn get_pid_by_port(port: u16) -> Result<u32> {
    let tcp_inode = tcp()?
        .iter()
        .find(|en| {
            info!("entry: {:?}", en);
            en.local_address.port() == port
        })
        .map(|en| en.inode)
        .ok_or_else(|| anyhow!("The port {} is not in use", port))?;
    let processes = all_processes()?;
    for p in &processes {
        for fd in p.fd()? {
            if let FDTarget::Socket(inode) = fd.target {
                if tcp_inode == inode {
                    return Ok(p.pid as u32);
                }
            }
        }
    }
    error!(
        "not found tcp inode {} for all processes {}",
        tcp_inode,
        processes.len()
    );
    bail!("not found pid by port {}", port)
}

/// 解析uid或username转换为user。空字符串将解析为当前用户
pub fn parse_user(user: &str) -> Result<User> {
    if user.is_empty() {
        get_user_by_uid(get_current_uid())
    } else {
        user.parse::<u32>()
            .map(get_user_by_uid)
            .unwrap_or_else(|_| get_user_by_name(user))
    }
    .ok_or_else(|| anyhow!("not found user for {}", user))
}

static CHAIN_CLASH: &str = "CLASH";
static CHAIN_CLASH_EX: &str = "CLASH_EXTERNAL";
static TABLE_NAT: &str = "nat";
static TABLE_MANGLE: &str = "mangle";

#[derive(Debug, Clone, Getters, Setters, Builder)]
#[getset(get = "pub", set = "pub")]
pub struct IptInfo {
    tun_name: String,
    table_id: u32,
    mark_id: u32,
    local_ipset: String,
    clash_config: Config,
}

impl IptInfo {
    /// 清理所有关于clash的iptables相关的配置。允许重复调用不会panic
    pub fn clean(&self) {
        // delete routing table and fwmark
        let (tun_name, table_id, mark_id) = (&self.tun_name, self.table_id, self.mark_id);

        info!("cleaning up the ip configuration");
        run_cmd!(ip rule del fwmark "$mark_id" lookup "$table_id").unwrap_or_else(|e| {
            warn!(
                "failed to delete ip rule fwmark {} of table {}: {}",
                mark_id, table_id, e
            )
        });
        run_cmd!(ip route del default dev "$tun_name" table "$table_id").unwrap_or_else(|e| {
            warn!(
                "failed to delete routing table {} of device {}: {}",
                table_id, tun_name, e
            )
        });
        run_cmd!(ip route del local default dev lo table $table_id).unwrap_or_else(|e| {
            warn!(
                "failed to delete default routing local of device lo of table {}: {}",
                table_id, e
            )
        });

        info!("cleaning up the iptables configuration");
        clean_chain(TABLE_NAT, CHAIN_CLASH);
        clean_chain(TABLE_NAT, CHAIN_CLASH_EX);
        clean_chain(TABLE_MANGLE, CHAIN_CLASH);
        clean_chain(TABLE_MANGLE, CHAIN_CLASH_EX);

        let setname = &self.local_ipset;
        info!("destorying ipset {}", setname);
        run_cmd!(ipset destroy $setname)
            .unwrap_or_else(|e| warn!("failed to destroy ipset {}: {}", setname, e));
    }

    pub fn config(&self, uid: u32) -> Result<()> {
        self.config_ipset()?;
        if self.clash_config.tun.enable.unwrap_or(false) {
            self.config_tun(uid)?;
        } else {
            self.config_redir(uid)?;
        }
        Ok(())
    }

    fn config_ipset(&self) -> Result<()> {
        let name = &self.local_ipset;
        info!("configuring local ips for ipset {}", name);
        run_cmd!(
            ipset create $name hash:net;
            ipset add $name 0.0.0.0/8;
            ipset add $name 127.0.0.0/8;
            ipset add $name 10.0.0.0/8;
            ipset add $name 169.254.0.0/16;
            ipset add $name 192.168.0.0/16;
            ipset add $name 224.0.0.0/4;
            ipset add $name 240.0.0.0/4;
            ipset add $name 172.16.0.0/12;
            ipset add $name 100.64.0.0/10;
        )
        .map_err(|e| {
            error!("failed to config local ipset {}: {}", name, e);
            e.into()
        })
    }

    fn config_redir(&self, uid: u32) -> Result<()> {
        info!("configuring redir mode");
        let (table_id, mark_id) = (self.table_id, self.mark_id);
        let local_ipset_name = &self.local_ipset;
        let redir_port = self.clash_config.redir_port.ok_or_else(|| {
            error!("not found redir-port in config: {:?}", self.clash_config);
            anyhow!("not found redir port")
        })?;
        debug!("configuring table mangle and nat of iptables for redir");
        run_cmd! (
            // 接管clash宿主机内部流量
            iptables -t nat -N $CHAIN_CLASH;
            iptables -t nat -F $CHAIN_CLASH;
            // private
            iptables -t nat -A $CHAIN_CLASH -m set --match-set $local_ipset_name dst -j RETURN;
            // 过滤本机clash流量 避免循环 user无法使用代理
            iptables -t nat -A $CHAIN_CLASH -m owner --uid-owner $uid -j RETURN;
            iptables -t nat -A $CHAIN_CLASH -p tcp -j REDIRECT --to-port $redir_port;
            // to OUTPUT
            iptables -t nat -A OUTPUT -j $CHAIN_CLASH;

            // 转发流量 tcp redir
            iptables -t nat -N $CHAIN_CLASH_EX;
            iptables -t nat -F $CHAIN_CLASH_EX;
            // google dns first
            iptables -t nat -A $CHAIN_CLASH_EX -p tcp -d 8.8.8.8 -j REDIRECT --to-port $redir_port;
            iptables -t nat -A $CHAIN_CLASH_EX -p tcp -d 8.8.4.4 -j REDIRECT --to-port $redir_port;
            // private
            iptables -t nat -A $CHAIN_CLASH_EX -m set --match-set $local_ipset_name dst -j RETURN;
            // tcp redir
            iptables -t nat -A $CHAIN_CLASH_EX -p tcp -j REDIRECT --to-port $redir_port;
            // to PREROUTING
            iptables -t nat -A PREROUTING -j $CHAIN_CLASH_EX;

            // 转发流量 udp tproxy
            iptables -t mangle -N $CHAIN_CLASH_EX;
            iptables -t mangle -F $CHAIN_CLASH_EX;
            // private
            iptables -t mangle -A $CHAIN_CLASH_EX -m set --match-set $local_ipset_name dst -j RETURN;
            // udp tproxy redir
            iptables -t mangle -A $CHAIN_CLASH_EX -p udp -j TPROXY --on-port $redir_port --tproxy-mark $mark_id;
            // to PREROUTING
            iptables -t mangle -A PREROUTING -j $CHAIN_CLASH_EX;
        )?;

        debug!("configuring route table and rule for ip");
        run_cmd! (
            ip rule add fwmark $mark_id table $table_id;
            ip route add local default dev lo table $table_id;
        )
        .map_err(|e| anyhow!("failed to configure ip route and rule: {}", e))?;

        info!("configure sys properties for docker bridge traffic");
        run_cmd! (
            sysctl -w net.bridge.bridge-nf-call-iptables=0;
            sysctl -w net.bridge.bridge-nf-call-ip6tables=0;
            sysctl -w net.bridge.bridge-nf-call-arptables=0;
        )
        .unwrap_or_else(|e| {
            warn!(
                "unable to configure proxy docker internal traffic with sysctl: {}",
                e
            )
        });
        Ok(())
    }

    fn config_tun(&self, uid: u32) -> Result<()> {
        info!("configuring tun mode");
        let (tun_name, table_id, mark_id) = (&self.tun_name, self.table_id, self.mark_id);
        let local_ipset_name = &self.local_ipset;

        debug!("configuring table mangle for iptables");
        let _ = run_cmd! {
            // 接管clash宿主机内部流量
            iptables -t mangle -N $CHAIN_CLASH;
            iptables -t mangle -F $CHAIN_CLASH;
            // filter clash traffic running under uid 注意顺序 owner过滤 要在 set mark之前
            iptables -t mangle -A $CHAIN_CLASH -m owner --uid-owner $uid -j RETURN;
            // private
            iptables -t mangle -A $CHAIN_CLASH -m set --match-set $local_ipset_name dst -j RETURN;
            // mark
            iptables -t mangle -A $CHAIN_CLASH -j MARK --set-xmark $mark_id;
            // to OUTPUT
            iptables -t mangle -A OUTPUT -j $CHAIN_CLASH;

            // 接管转发流量
            iptables -t mangle -N $CHAIN_CLASH_EX;
            iptables -t mangle -F $CHAIN_CLASH_EX;
            // private
            iptables -t mangle -A $CHAIN_CLASH_EX -m set --match-set $local_ipset_name dst -j RETURN;
            // avoid rerouting for local docker
            iptables -t mangle -A $CHAIN_CLASH_EX -i $tun_name -j RETURN;
            // mark
            iptables -t mangle -A $CHAIN_CLASH_EX -j MARK --set-xmark $mark_id;
            // to PRER
            iptables -t mangle -A PREROUTING -j $CHAIN_CLASH_EX;
        }
        .map_err(|e| {
            error!(
                "failed to configure iptables when configuring tun mode: {}",
                e
            );
            anyhow!("failed to config tun in iptables: {}", e)
        })?;

        debug!("configuring route table and rule for ip");
        run_cmd!(
            // utun route table
            ip route replace default dev $tun_name table $table_id;
            ip rule add fwmark $mark_id lookup $table_id;
        )
        .map_err(|e| anyhow!("failed to config tun in ip route: {}", e))?;

        info!("configuring rp_filter for sys prop net.ipv4.conf");
        run_cmd!(
            // 排除 rp_filter 的故障 反向路由
            sysctl -w net.ipv4.conf.$tun_name.rp_filter=0;
            sysctl -w net.ipv4.conf.all.rp_filter=0;
        )
        .unwrap_or_else(|e| warn!("failed to configure rp_filter: {}", e));
        Ok(())
    }
}

fn clean_chain(table: &str, chain: &str) {
    run_cmd!(iptables -t "$table" -D OUTPUT -j "$chain").unwrap_or_else(|e| {
        warn!(
            "failed to delete iptables rule `-j {}` in chain OUTPUT of table {}: {}",
            chain, table, e
        )
    });
    run_cmd!(iptables -t "$table" -D PREROUTING -j "$chain").unwrap_or_else(|e| {
        warn!(
            "failed to delete iptables rule `-j {}` in chain PREROUTING of table {}: {}",
            chain, table, e
        )
    });
    run_cmd! (iptables -t $table -F $chain).unwrap_or_else(|e| {
        warn!(
            "failed to empty all rules of chain {} in table {}: {}",
            chain, table, e
        )
    });
    run_cmd!(iptables -t $table -X $chain)
        .unwrap_or_else(|e| warn!("failed to delete chain {} in table {}: {}", chain, table, e));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{net::TcpListener, process::*};

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
        // test(9090);
        Ok(())
    }
}
