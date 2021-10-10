import os
from typing import Tuple
import click
import psutil
from tenacity.wait import wait_exponential
import yaml
from pathlib import Path
from colorama.ansi import Style
from os import listdir, environ
import logging
import signal
from clashutil.clash import Clash, ClashException
import colorama
from sys import stderr
from subprocess import Popen
from tenacity import retry, retry_if_exception_type, before_log, after_log, stop_after_delay
from shutil import which, chown
import time

log = logging.getLogger(__name__)


class CliProgram(object):
    __slots__ = ["clash", "clash_process", "log", "clash_pid"]

    def __init__(self):
        self.log = logging.getLogger(__name__)
        self.clash = None
        self.clash_process = None
        self.clash_pid = None
        self._handle_sig()

    def run(self, clash_bin, clash_home, config_path, clash_pid, clean, detach, user):
        if clash_home and (path := Path(clash_home)) and not path.exists():
            path.mkdir(0o744, parents=True)
            if user:
                chown(path, user)

        # find config path from multi-localtion
        # 如果path为None则从`.`, `$HOME/.config/.clash/`中找config文件
        config_path = _find_config_path(
            config_path, ".", "{}/.config/.clash/".format(environ["HOME"]))

        if not clash_pid:
            # start clash
            self.clash_process, self.clash_pid = _try_start_clash(
                clash_bin, clash_home, user, config_path)
            self.log.info(
                f"started clash process {self.clash_process}, pid {self.clash_pid}")
            clash_pid = self.clash_pid

        # load config
        self.log.info(f"loading config from {config_path}")
        with open(config_path, "r") as f:
            config = yaml.safe_load(f)

        # check clash
        self.clash = _new_clash_retry(config, clash_pid)

        if clean:
            self.clean()
            if not clash_pid:
                return

        # config ip for clash
        self.clash.config_net()

        if self.clash_process and not detach:
            self.log.info(f"waiting for clash process {clash_pid}")
            self.clash_process.wait()
            self.clean()

    def clean(self):
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


@click.command()
@click.option('-c', '--clean', default=False, is_flag=True)
@click.option('-f', '--config-path', type=Path)
@click.option('-p', '--clash-pid', type=int)
@click.option('-v', '--verbose', count=True)
@click.option('-b', '--clash-bin', type=Path, help='start the clash')
@click.option('-d', '--clash-home', type=Path)
@click.option('-D', '--detach', is_flag=True)
@click.option('-u', '--user', type=str)
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


@retry(
    wait=wait_exponential(multiplier=1, min=1, max=5),
    retry=retry_if_exception_type(ClashException),
    stop=stop_after_delay(10),
    after=after_log(log, logging.INFO),
    before=before_log(log, logging.INFO),
    reraise=True,
)
def _new_clash_retry(config, pid):
    return Clash(config, pid=pid)


def _try_start_clash(clash_bin, clash_home, user, config_path) -> Tuple[Popen, int]:
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
