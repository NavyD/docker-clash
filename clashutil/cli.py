import logging
import os
import pwd
import signal
import time
from os import environ, listdir
from pathlib import Path
from shutil import chown, which
from subprocess import Popen
from sys import stderr, stdout
from typing import Tuple

import click
import colorama
import psutil
import yaml
from colorama.ansi import Style
from tenacity import (after_log, before_log, retry, retry_if_exception_type,
                      stop_after_delay)
from tenacity.wait import wait_exponential

from clashutil.clash import Clash, ClashException

log = logging.getLogger(__name__)


@click.command(help='a clash transparent proxy tool')
@click.option('--clean', default=False, is_flag=True, help='clear all configuration for clash')
@click.option('-f', '--config-path', type=Path, help='config file of clash. default read config file from `.`, `$HOME/.config/.clash/`')
@click.option('-p', '--clash-pid', type=int, help='pid of clash. if not specified, find the corresponding clash process from the configuration port')
@click.option('-v', '--verbose', count=True, help='log level. default fatal. level: error: -v to debug: -vvvv')
@click.option('-b', '--clash-bin', type=Path, help='the name or path of clash binary. if not specified, the clash process must already exist')
@click.option('-d', '--clash-home', type=Path, help='clash options: -d')
@click.option('-D', '--detach', is_flag=True, help='exit directly instead of waiting for the clash process')
@click.option('-u', '--user', type=str, help='indicates the user who started the clash process, the default is the user of the current process')
@click.option('-t', '--wait-time', type=float, default=15, show_default=True, help='wait for seconds to check the start of clash. exit if it timeout')
def main(verbose, **kwargs):
    colorama.init()
    _init_log(verbose)

    cli = CliProgram()
    try:
        cli.run(**kwargs)
        return
    except ClashException as e:
        eprint(f"failed to check if clash exists: {e}")
    except CliException as e:
        eprint(f"failed to check cli: {e}")
    cli.clean()


class CliProgram(object):
    __slots__ = ["clash", "clash_process", "log", "clash_pid"]

    def __init__(self):
        self.log = logging.getLogger(__name__)
        self.clash = None
        self.clash_process = None
        self.clash_pid = None
        self._handle_sig()

    def run(self, clash_bin, clash_home, config_path, clash_pid, clean, detach, user, wait_time):
        if clean:
            self.clean()
            exit(0)

        if clash_home and (path := Path(clash_home)):
            if not path.exists():
                path.mkdir(0o744, parents=True)
            if user:
                chown(path, user)

        # find config path from multi-localtion
        # 如果path为None则从`.`, `$HOME/.config/.clash/`中找config文件
        config_path = _find_config_path(
            config_path, ".", "{}/.config/.clash/".format(user_home(user)))

        # load config
        self.log.info(f"loading config from {config_path}")
        with open(config_path, "r") as f:
            config = yaml.safe_load(f)

        # start clash
        if clash_bin and not clash_pid:
            self.clash_process, self.clash_pid = try_start_clash(
                clash_bin, clash_home, user, config_path)
            self.log.debug(
                f"started clash process {self.clash_process}, pid {self.clash_pid}")
            clash_pid = self.clash_pid

        print("checking the clash process")
        self.clash = new_clash_retry(config, clash_pid, wait_time)

        print(f"configuring for clash pid {clash_pid}")
        # config ip for clash
        self.clash.config_net()

        if self.clash_process and not detach:
            print(f"waiting for clash process {clash_pid}")
            self.clash_process.wait()
            self.clean()

    def clean(self):
        print("cleaning up configuration")
        self.log.debug(
            f"cleaning clash {self.clash}, clp {self.clash_process}")
        if self.clash_pid:
            log.info(f"killing clash pid {self.clash_pid}")
            os.kill(self.clash_pid, signal.SIGTERM)

        if self.clash_process:
            log.info(f"killing clash process {self.clash_process.pid}")
            self.clash_process.kill()

        if self.clash:
            log.info(f"cleaning clash {self.clash}")
            self.clash.clean()

    def _handle_sig(self):
        def signal_handler(sig, frame):
            self.log.debug(
                f"get signal {sig}, frame {frame}, clash {self.clash}, clp {self.clash_process}")
            self.clean()
            exit(1)

        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGTERM, signal_handler)


def user_home(user) -> str:
    if not user:
        return environ["HOME"]
    log.debug(f"finding username for user {user}")
    try:
        name = pwd.getpwuid(int(user)).pw_name
    except ValueError:
        name = user
    home = os.path.expanduser(f"~{name}")
    log.debug(f"found home {home} for username {name}")
    return home


def new_clash_retry(config, clash_pid, wait_time):
    class my_retry(retry_if_exception_type):
        def __call__(self, retry_state):
            if retry_state.outcome.failed:
                log.info(f"retry: {retry_state}")
                print(
                    f"{colorama.Fore.YELLOW}not found clash process in attempts {retry_state.attempt_number}{Style.RESET_ALL}", file=stdout)
                return self.predicate(retry_state.outcome.exception())
            else:
                return False

    @retry(
        wait=wait_exponential(multiplier=1, min=1, max=3),
        retry=my_retry(ClashException),
        stop=stop_after_delay(wait_time),
        after=after_log(log, logging.DEBUG),
        before=before_log(log, logging.DEBUG),
        reraise=True,
    )
    def _new(config, pid):
        return Clash(config, pid=pid)

    try:
        # check clash
        return _new(config, clash_pid)
    except ClashException as e:
        raise ClashException(
            f"{e}. retry statistics: {_new.retry.statistics}")


def try_start_clash(clash_bin, clash_home, user, config_path) -> Tuple[Popen, int]:
    if not clash_bin:
        return None, None
    clash_bin = which(clash_bin)
    cmd = f"{clash_bin} -f {config_path}"
    if clash_home:
        cmd += f" -d {clash_home}"
    if not user:
        log.info(f"running clash cmd: {cmd}")
        print(f"starting clash: {cmd}")
        p = Popen(cmd.split(), start_new_session=True)
        return p, p.pid

    # [python := Assignment expressions](https://docs.python.org/3/whatsnew/3.8.html#assignment-expressions)
    if path := which("gosu"):
        log.info(f"running clash cmd: {cmd} with user {user} and {path}")
        cmd = f"{path} {user} {cmd}"
        print(f"starting clash: {cmd}")
        p = Popen(cmd.split(), start_new_session=True)
        return p, p.pid

    if path := which("sudo"):
        log.info(f"running clash cmd: {cmd} with user {user} and {path}")
        cmd = f"{path} -u {user} {cmd}"
        print(f"starting clash: {cmd}")
        p = Popen(cmd.split(), start_new_session=True)
        # waiting for proc sys
        time.sleep(0.3)

        p_children = psutil.Process(p.pid).children()
        if (sz := len(p_children)) != 1:
            log.error(
                f"invalid children processes {p_children} for sudo: {cmd}")
            raise CliException(f"invalid children processes {sz} for {cmd}")
        return p, p_children[0].pid

    raise CliException("only supported `gosu` and `sudo` for user option")


def _init_log(verbose: int):
    if verbose > 4:
        verbose = 4
    elif verbose < 0:
        raise CliException(f"invalid option: verbose={verbose}")
    logging.basicConfig(
        format='%(asctime)s.%(msecs)03d [%(levelname)-8s] [%(name)s.%(funcName)s]: %(message)s',
        level=logging.getLevelName((5 - verbose) * 10),
        datefmt='%Y-%m-%d %H:%M:%S'
    )


def _find_config_path(*paths) -> Path:
    """
    如果path为None则从
    `.`, `$HOME/.config/.clash/`中找config文件

    如果未找到可用的path则抛出异常
    """
    filenames = {"config.yaml", "config.yml"}
    log.debug(f"finding config files {filenames} in {paths}")
    for p in paths:
        if p is None:
            continue
        p = Path(p)
        if p.is_dir():
            for name in listdir(p):
                if name in filenames:
                    return p.joinpath(name)
        elif p.is_file() and p.name in filenames:
            return p
    raise CliException(f"not found config file in {paths}")


def eprint(*args, **kwargs):
    print(f"{colorama.Fore.RED}{args}{Style.RESET_ALL}", file=stderr, **kwargs)


class CliException(Exception):
    pass
