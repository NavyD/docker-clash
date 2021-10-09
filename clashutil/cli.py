from pathlib import Path
from typing import Dict
import click
from colorama.ansi import Style
import yaml
from os import listdir, environ
import logging
from clashutil.clash import Clash, ClashException
from colorama import init, Fore
from sys import stderr


log = logging.getLogger(__name__)
init()


@click.command()
@click.option('-c', '--clean', default=False, is_flag=True)
@click.option('-f', '--config-file', type=Path)
@click.option('-p', '--clash-pid', type=int)
@click.option('-v', '--verbose', count=True)
def main(clean: bool, clash_pid: int, config_file: Path, verbose: int):
    __init_log(verbose)
    config = __load_config(config_file)
    clash = Clash(config, pid=clash_pid)
    if clean:
        clash.clean()
        return
    try:
        clash.config_net()
        return
    except ClashException as e:
        eprint(f"config clash failed: {e}")
    except Exception as e:
        eprint(f"other exception: {e}")
    log.error(f"failed to config clash: {clash}")
    clash.clean()
    return


def __init_log(verbose: int):
    if verbose > 4:
        verbose = 4
    elif verbose < 0:
        raise CliException(f"invalid option: verbose={verbose}")
    logging.basicConfig(
        format='%(asctime)s.%(msecs)03d [%(levelname)-8s] [%(name)s.%(funcName)s]: %(message)s',
        level=logging.getLevelName((5 - verbose) * 10),
        datefmt='%Y-%m-%d %H:%M:%S'
    )


def __load_config(path=None) -> Dict:
    """
    从path中加载clash配置文件。如果path为None则从
    `.`, `$HOME/.config/.clash/`中找config文件

    如果未找到可用的path则抛出异常
    """
    path = __find_config_file(
        path, ".", "{}/.config/.clash/".format(environ["HOME"]))
    log.info(f"loading config from {path}")
    with open(path, "r") as f:
        return yaml.safe_load(f)


def __find_config_file(*paths) -> Path:
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
    print(f"{Fore.RED}{args}{Style.RESET_ALL}", file=stderr, **kwargs)


class CliException(Exception):
    pass
