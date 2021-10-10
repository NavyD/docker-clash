from typing import Dict, List, Set
from psutil import Process, net_connections
from os import walk
from pathlib import Path
from subprocess import CalledProcessError, CompletedProcess, run
import logging

log = logging.getLogger(__name__)


class Clash:
    def __init__(
        self,
        config: Dict,
        pid=None,
        table_id=0x162,
        tun_name="utun",
        mark_id=0x162,
        local_ipset="local_clash_ip_set"
    ):
        self.log = logging.getLogger(__name__)
        ports = {
            config.get("port"),
            config.get("socks-port"),
            config.get("redir-port"),
            config.get("mixed-port"),
        }
        if not config:
            raise ClashException("empty config")
        if not pid:
            # [Converting list to *args when calling function [duplicate]](https://stackoverflow.com/a/3941529/8566831)
            pid = get_clash_pid_by_ports(*ports)

        self.process = Process(pid)

        # check if port is available for clash pid
        conns = self.process.connections()
        unused_ports = set()
        for port in ports:
            if not any(conn.laddr.port == port for conn in conns):
                self.log.debug(f"not found port {port} in clash pid {pid}")
                unused_ports.add(port)
        if len(unused_ports) == len(ports):
            raise ClashException(
                f"not found any port in {ports} for clash {pid}")
        elif len(unused_ports) > 0:
            self.log.warning(
                f"found unlistened ports {unused_ports}  in clash pid {pid}")

        self.config = config
        self.table_id = table_id
        self.tun_name = tun_name
        self.mark_id = mark_id
        self.local_ipset = local_ipset

        self.uid = self.process.uids().real

    def __str__(self):
        """
        [How to print instances of a class using print()?](https://stackoverflow.com/a/32635523/8566831)
        """
        fields = {k: v for k, v in self.__dict__.items() if k != 'config'}
        fields['config'] = str(self.config)[:100] + "..."
        return str(self.__class__) + ": " + str(fields)

    def clean(self):
        self.log.debug("cleaning config for clash")
        self.process.kill()
        processes = run_cmd(
            f"""
# delete routing table and fwmark
ip route del default dev "{self.tun_name}" table "{self.table_id}"
ip rule del fwmark "{self.mark_id}" lookup "{self.table_id}"
# route for tproxy
ip rule del fwmark {self.mark_id} table {self.table_id}
ip route del local default dev lo table {self.table_id}

# clash nat chain
iptables -t nat -D OUTPUT -j CLASH
iptables -t nat -F CLASH
iptables -t nat -X CLASH

iptables -t nat -D PREROUTING -j CLASH_EXTERNAL
iptables -t nat -F CLASH_EXTERNAL
iptables -t nat -X CLASH_EXTERNAL

# clash mangle chain
iptables -t mangle -D OUTPUT -j CLASH
iptables -t mangle -F CLASH
iptables -t mangle -X CLASH

iptables -t mangle -D PREROUTING -j CLASH_EXTERNAL
iptables -t mangle -F CLASH_EXTERNAL
iptables -t mangle -X CLASH_EXTERNAL
            """,
            check=False,
            capture_output=True
        )
        for p in processes:
            if p.returncode != 0:
                log.info("failed to clean for `{}`: {}".format(
                    p.args, p.stderr.strip()))

    def config_net(self):
        if self.config["tun"]["enable"]:
            self.__config_tun()
        else:
            self.__config_redir()

    def __config_tun(self):
        table, chain = "mangle", "CLASH"
        self.__create_iptables_chain(table, chain)
        self.__local_ips(table, chain)
        self.log.debug("configuring to take over clash host internal traffic")
        run_cmd(
            f"""
# filter clash traffic running under uid 注意顺序 owner过滤 要在 set mark之前
iptables -t {table} -A {chain} -m owner --uid-owner "{self.uid}" -j RETURN
# mark
iptables -t {table} -A {chain} -j MARK --set-xmark {self.mark_id}
# 接管clash宿主机内部流量
iptables -t {table} -A OUTPUT -j {chain}
            """
        )

        table, chain = "mangle", "CLASH_EXTERNAL"
        self.__create_iptables_chain(table, chain)
        self.__local_ips(table, chain)

        self.log.debug("configuring take over forwarding traffic")
        run_cmd(
            f"""
# avoid rerouting for local docker
iptables -t {table} -A {chain} -i "{self.tun_name}" -j RETURN
# mark
iptables -t {table} -A {chain} -j MARK --set-xmark {self.mark_id}
# 接管转发流量
iptables -t {table} -A PREROUTING -j {chain}
            """
        )

        self.log.debug("configuring route table and rule for ip")
        run_cmd(
            f"""
# utun route table
ip route replace default dev "{self.tun_name}" table "{self.table_id}"
ip rule add fwmark "{self.mark_id}" lookup "{self.table_id}"
            """
        )

        self.log.debug("configuring rp_filter for sys prop net.ipv4.conf")
        run_cmd(
            f"""
# 排除 rp_filter 的故障 反向路由
sysctl -w net.ipv4.conf."{self.tun_name}".rp_filter=0 2> /dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 2> /dev/null
            """
        )

    def __config_redir(self):
        self.log.debug("getting redir port in config %s",
                       str(self.config)[:100])
        redir_port = self.config.get(
            "redir-port", self.config.get("mixed-port"))
        if redir_port is None:
            raise ClashException("not found redir port")
        self.__check_tproxy_mod()
        self.log.info("configuring redir")

        table, chain = "nat", "CLASH"
        self.__create_iptables_chain(table, chain)
        self.__local_ips(table, chain)

        self.log.debug("configuring to take over clash host internal traffic")
        run_cmd(
            f"""
# 过滤本机clash流量 避免循环 user无法使用代理
iptables -t {table} -A {chain} -m owner --uid-owner "{self.uid}" -j RETURN
iptables -t {table} -A {chain} -p tcp -j REDIRECT --to-port "{redir_port}"
# 接管clash宿主机内部流量
iptables -t {table} -A OUTPUT -j {chain}
            """
        )

        table, chain = "nat", "CLASH_EXTERNAL"
        self.__create_iptables_chain(table, chain)
        self.__local_ips(table, chain)

        self.log.debug("configuring TCP forwarding traffic")
        run_cmd(
            f"""
iptables -t {table} -A {chain} -p tcp -d 8.8.8.8 -j REDIRECT --to-port "{redir_port}"
iptables -t {table} -A {chain} -p tcp -d 8.8.4.4 -j REDIRECT --to-port "{redir_port}"
iptables -t {table} -A {chain} -p tcp -j REDIRECT --to-port "{redir_port}"
iptables -t {table} -A PREROUTING -j {chain}
            """
        )

        table, chain = "mangle", "CLASH_EXTERNAL"
        self.__create_iptables_chain(table, chain)
        self.__local_ips(table, chain)

        log.debug("configuring udp tproxy")
        run_cmd(
            f"""
iptables -t {table} -A {chain} -p udp -j TPROXY --on-port "{redir_port}" --tproxy-mark {self.mark_id}
iptables -t {table} -A PREROUTING -j {chain}
            """
        )

        log.info("configuring route table and rule for ip")
        run_cmd(
            f"""
ip rule add fwmark {self.mark_id} table {self.table_id}
ip route add local default dev lo table {self.table_id}
            """
        )

        log.info("configure sys properties for docker bridge traffic")
        run_cmd(
            """
sysctl -w net.bridge.bridge-nf-call-iptables=0
sysctl -w net.bridge.bridge-nf-call-ip6tables=0
sysctl -w net.bridge.bridge-nf-call-arptables=0
            """
        )

    def __local_ips(self, table: str, chain: str):
        self.log.debug(f"appending local iptable table {table}, chain {chain}")
        run_cmd(
            f"""
iptables -t "{table}" -A "{chain}" -d 0.0.0.0/8 -j RETURN
iptables -t "{table}" -A "{chain}" -d 127.0.0.0/8 -j RETURN
iptables -t "{table}" -A "{chain}" -d 224.0.0.0/4 -j RETURN
iptables -t "{table}" -A "{chain}" -d 172.16.0.0/12 -j RETURN
iptables -t "{table}" -A "{chain}" -d 127.0.0.0/8 -j RETURN
iptables -t "{table}" -A "{chain}" -d 169.254.0.0/16 -j RETURN
iptables -t "{table}" -A "{chain}" -d 240.0.0.0/4 -j RETURN
iptables -t "{table}" -A "{chain}" -d 192.168.0.0/16 -j RETURN
iptables -t "{table}" -A "{chain}" -d 10.0.0.0/8 -j RETURN
            """
        )

    def __create_iptables_chain(self, table: str, chain: str):
        self.log.debug(f"creating iptable table {table} chain {chain}")
        run_cmd(
            f"""
    iptables -t {table} -N {chain}
    iptables -t {table} -F {chain}
            """
        )

    def __check_tproxy_mod(self):
        path = "/lib/modules/{}".format(
            Path("/proc/sys/kernel/osrelease").read_text())
        self.log.debug(f"checking if the tproxy module exists in path {path}")
        for _, _, files in walk(path, followlinks=True):
            for name in files:
                if name.startswith("xt_TPROXY.ko"):
                    return
        raise ClashException(f"not found xt_TPROXY.ko in {path}")


def run_cmd(sh_cmd: str, split_line=True, check=True, capture_output=True, text=True, **kwargs) -> List[CompletedProcess]:
    try:
        res = []
        if split_line:
            for line in sh_cmd.splitlines():
                line = line.strip()
                if line and not line.startswith("#"):
                    log.debug(f"running cmd line: `{line}`")
                    p = run(line, shell=True, capture_output=capture_output,
                            check=check, text=text, **kwargs)
                    log.debug(f"completed process: {p} for cmd: {line}")
                    res.append(p)
        else:
            res.append(
                run(sh_cmd, shell=True, capture_output=capture_output, check=check, text=text, **kwargs))
        return res
    except CalledProcessError as e:
        raise ClashException(f"failed to execute `{e.cmd}`: {e.stderr}, {e.stdout}, {e.output}")


def get_pids_by_port(port: int) -> Set[int]:
    return {conn.pid for conn in net_connections() if conn.laddr.port == port} if port else None


def get_clash_pid(config: Dict) -> int:
    return get_clash_pid_by_ports(
        config.get("port"),
        config.get("socks-port"),
        config.get("redir-port"),
        config.get("mixed-port"),
    )


def get_clash_pid_by_ports(*ports) -> int:
    pids = None
    for port in ports:
        if port:
            cur_pids = get_pids_by_port(port)
            log.debug(
                f"found cur pids {cur_pids} and pids {pids} for port {port}")
            if not cur_pids:
                continue
            elif not pids:
                pids = cur_pids
            elif pids != cur_pids:
                raise ClashException(
                    f"Inconsistent pids: {pids}, cur pids: {cur_pids}")
    if not pids:
        raise ClashException(f"not found clash pid by ports: {ports}")
    log.info(f"found clash pids {pids}")
    if len(pids) != 1 or None in pids:
        raise ClashException(f"multiple or no pids {pids} in one port {port}")
    return pids.pop()


class ClashException(Exception):
    pass
