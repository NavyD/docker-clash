# clash

实现思路：

检查clash启动端口确认正常启动后，将对iptables操作后退出，不用在程序内对clash进行任何操作


## 问题

- 如何检查指定的pid是否存在`kill -0 $pid`

    查询man page：

    >If sig is 0, then no signal is sent, but error checking is still performed; this can be used to check for the existence of a process ID or process group ID.

    可能会因为权限问题返回非0值，但进程是存在的，解决方法使用`ps -p $PID`

参考：

- [What does `kill -0` do?](https://unix.stackexchange.com/a/169899)
- [How to check if a process id (PID) exists](https://stackoverflow.com/a/15774758/8566831)
