---
layout: post
title: CephFS debug方法
date: 2020-4-29 14:30
comments: true
author: Peter.Y
categories: Ceph kernel debug
---

* content
{:toc}

# Intro

本文介绍cephfs 常用debug方法。主要针对 kernel client (以下简称 kcephfs)，环境是 

> centos 7.6, kernel version 3.10.0-957.el7

以及`ceph-mds`服务端组件的debug

# kernel client

## 相关内核模块介绍

kernel默认包括的ceph kernel 模块如下

~~~
# find /lib/modules/3.10.0-957.27.2.el7.x86_64/kernel/ -name "*rbd*" -or -name "*ceph*"
/lib/modules/3.10.0-957.27.2.el7.x86_64/kernel/net/ceph/libceph.ko.xz
/lib/modules/3.10.0-957.27.2.el7.x86_64/kernel/drivers/block/rbd.ko.xz
/lib/modules/3.10.0-957.27.2.el7.x86_64/kernel/fs/ceph/ceph.ko.xz
~~~

其中 `rbd` 是krbd的主要模块, `libceph` 是网络通信的主要模块，而 `ceph` 是 kcephfs的主要模块。
本文主要关注 `ceph` 这个模块。

内核模块在一定程度上可以动态加载生效。因此，当某个版本 kernel 不能满足要求时，可以手动编译并替代原生内核模块来解决。

需要注意的是，内核模块与内核版本强相关，必须要拿到版本完全一致的内核代码才能修改和编译。

如何编译内核模块不在本文讨论范围内。

## 如何debug kernel

不管什么debug，最主要的是源码和log。

### 内核源码

获取 centos 对应版本内核代码，参考 [github repo](https://github.com/kernerist?tab=repositories)

下面以 `centos7.6.1810` 对应的 [repo](https://github.com/kernerist/RHEL_7.6.1810_3.10.0-957.27.2.el7) 为例。

下载源码
~~~
git clone https://github.com/kernerist/RHEL_7.6.1810_3.10.0-957.27.2.el7.git
~~~

kcephfs相关的代码在 `fs/ceph` 下。

### debug log

kcephfs 可以按 kernel debug 的标准方式打开 debug log。

#### kernel log level 定义

~~~
#define KERN_EMERG 0    /*紧急事件消息，系统崩溃之前提示，表示系统不可用*/
#define KERN_ALERT 1    /*报告消息，表示必须立即采取措施*/
#define KERN_CRIT 2     /*临界条件，通常涉及严重的硬件或软件操作失败*/
#define KERN_ERR 3      /*错误条件，驱动程序常用KERN_ERR来报告硬件的错误*/
#define KERN_WARNING 4  /*警告条件，对可能出现问题的情况进行警告*/
#define KERN_NOTICE 5   /*正常但又重要的条件，用于提醒。常用于与安全相关的消息*/
#define KERN_INFO 6     /*提示信息，如驱动程序启动时，打印硬件信息*/
#define KERN_DEBUG 7   /*调试级别的消息*/
~~~

具体命令如下：

#### 查看当前debug log level

~~~
# cat /proc/sys/kernel/printk
	4       4       1       7
	current	default	minimum	boot-time-default
~~~

其中 `current` 是指当前的 console log level，我们主要关注这个。

#### 修改debug log level

~~~
# echo 8 > /proc/sys/kernel/printk
# cat /proc/sys/kernel/printk
8 4 1 7
~~~

#### 打开 dynamic debug log

上面的修改方法只能打开 `KERN_INFO` 以上的log，对于 `KERN_DEBUG` 或者通过`pr_debug()`语句打印的log，我们需要另一种方法来打开，即[Dynamic debug](https://www.kernel.org/doc/html/v4.11/admin-guide/dynamic-debug-howto.html)

##### 前提条件

需要确保内核开启了 CONFIG_DYNAMIC_DEBUG=y，检查方法如下

~~~
# sudo cat /boot/config-`uname -r` | grep DYNAMIC_DEBUG
~~~

再查看下是否挂载了debugfs，没有的话尝试挂载

~~~
mount -o rw.remount -t debugfs none /sys/kernel/debug/
~~~

##### 开启dynamic debug

dynmaic debug 支持非常丰富的log 过滤选项，可按照模块、文件、代码行等粒度选择要开启的debug log。
详细参考[Dynamic debug](https://www.kernel.org/doc/html/v4.11/admin-guide/dynamic-debug-howto.html)

下面仅就开启`ceph`内核模块为例，命令格式如下

~~~
echo "module ceph [+-=][pflmt_]" >/sys/kernel/debug/dynamic_debug/control
~~~

其中 `+-=`含义如下

~~~
-    remove the given flags
+    add the given flags
=    set the flags to the given flags
~~~

`pflmt_`含义如下

~~~
p    enables the pr_debug() callsite.
f    Include the function name in the printed message
l    Include line number in the printed message
m    Include module name in the printed message
t    Include thread ID in messages not generated from interrupt context
_    No flags are set. (Or'd with others on input)
~~~

具体示例如下

~~~
# // 开启 ceph 模块的函数名，行号，内核线程名
# echo "module ceph +pflt" >/sys/kernel/debug/dynamic_debug/control
~~~

> dynamic debug影响系统性能，切记debug完要关闭！

#### 查看debug log

kernel log 输出有几种方式，最简单的是使用 `dmesg`

~~~
# dmesg -w | tee debug.log
~~~

示例如下

~~~
[626187.960015] __ceph_do_getattr:2233: ceph:  do_getattr result=0
[626189.846853] delayed_work:3535: ceph:  mdsc delayed_work
[626189.853734] ceph_check_delayed_caps:3938: ceph:  check_delayed_caps
[626189.857563] __ceph_lookup_mds_session:434: ceph:  lookup_mds_session ffff9af013abb000 1
[626189.861862] get_session:403: ceph:  mdsc get_session ffff9af013abb000 1 -> 2
[626189.865894] get_session:403: ceph:  mdsc get_session ffff9af013abb000 2 -> 3
[626189.869876] con_get:4039: ceph:  mdsc con_get ffff9af013abb000 ok (3)
[626189.873709] ceph_put_mds_session:414: ceph:  mdsc put_session ffff9af013abb000 3 -> 2
[626189.878029] con_put:4050: ceph:  mdsc con_put ffff9af013abb000 (1)
[626189.881837] ceph_put_mds_session:414: ceph:  mdsc put_session ffff9af013abb000 2 -> 1
[626190.093320] get_session:403: ceph:  mdsc get_session ffff9af013abb000 1 -> 2
[626190.100630] con_get:4039: ceph:  mdsc con_get ffff9af013abb000 ok (2)
[626190.104545] con_put:4050: ceph:  mdsc con_put ffff9af013abb000 (1)
[626190.108318] ceph_put_mds_session:414: ceph:  mdsc put_session ffff9af013abb000 2 -> 1
~~~

抓取到需要的log后，打开debug.log分析即可

### debugfs

除了kernel debug log之外，ceph自身还提供一些常用的metric供分析问题，类似于server端的`admin socket`

位置及内容如下

~~~

#  ~ ls -l /sys/kernel/debug/ceph 
总用量 0
drwxr-xr-x 2 root root 0 Apr 28 23:25 c6eed356-0973-4ec1-8adb-6c76dacf3178.client4464
drwxr-xr-x 2 root root 0 Apr 28 23:33 c6eed356-0973-4ec1-8adb-6c76dacf3178.client4473

#  ~ ls -l /sys/kernel/debug/ceph/c6eed356-0973-4ec1-8adb-6c76dacf3178.client4464 
总用量 0
lrwxrwxrwx 1 root root 0 Apr 28 23:25 bdi -> ../../bdi/ceph-12
-r-------- 1 root root 0 Apr 28 23:25 caps
-r-------- 1 root root 0 Apr 28 23:25 client_options
-r-------- 1 root root 0 Apr 28 23:25 dentry_lru
-r-------- 1 root root 0 Apr 28 23:25 mdsc
-r-------- 1 root root 0 Apr 28 23:25 mdsmap
-r-------- 1 root root 0 Apr 28 23:25 mds_sessions
-r-------- 1 root root 0 Apr 28 23:25 monc
-r-------- 1 root root 0 Apr 28 23:25 monmap
-r-------- 1 root root 0 Apr 28 23:25 osdc
-r-------- 1 root root 0 Apr 28 23:25 osdmap
-rw------- 1 root root 0 Apr 28 23:25 writeback_congestion_kb

~~~

如上所示，在`/sys/kernel/debug/ceph/`下，每个client连接建立一个子目录。怎么知道是哪个client呢？有一个方法是通过mds的admin socket，查到连接到该mds的`clientid`以及对应的ip。示例如下

~~~
# ceph daemon /var/run/ceph/bj.kunlun.test.cluster2-mds.bj-cluster2-node4-test.asok session ls
[
    {
        "id": 4464,  // 4464 就是客户端的client id
        "num_leases": 0,
        "num_caps": 5,
        "state": "open",
        "request_load_avg": 0,
        "uptime": 51693.690616,
        "replay_requests": 0,
        "completed_requests": 1,
        "reconnecting": false,
        "inst": "client.4464 <ip>:0/2210658890", // <ip> 就是客户端的ip
        "client_metadata": {
            "entity_id": "admin",
            "hostname": "localhost",
            "kernel_version": "3.10.0-957.27.2.el7.x86_64",
            "root": "/"
        }
    }
]

~~~

解决了客户端定位问题之后，我们再来看看详细的指标含义，如下

~~~
bdi: BDI info about the Ceph system (blocks dirtied, written, etc)

caps: counts of file “caps” structures in-memory and used

client_options: dumps the options provided to the CephFS mount

dentry_lru: Dumps the CephFS dentries currently in-memory

mdsc: Dumps current requests to the MDS

mdsmap: Dumps the current MDSMap epoch and MDSes

mds_sessions: Dumps the current sessions to MDSes

monc: Dumps the current maps from the monitor, and any “subscriptions” held

monmap: Dumps the current monitor map epoch and monitors

osdc: Dumps the current ops in-flight to OSDs (ie, file data IO)

osdmap: Dumps the current OSDMap epoch, pools, and OSDs
~~~

# ceph-mds debug

ceph-mds 可以能过ceph的admin socket机制，实时打开debug选项，或者查看内存中主要的数据结构。

以 `slow request` 为例，可以查看

~~~
# ceph daemon /var/run/ceph/<mds>.asok dump_ops_in_flight
{
    "ops": [],
    "num_ops": 0
}
~~~

其它选项，可以通过help自行研究，还是比较全面的。

~~~
ceph daemon /var/run/ceph/<mds>.asok help
{
    "cache status": "show cache status",
    "config diff": "dump diff of current config and default config",
    "config diff get": "dump diff get <field>: dump diff of current and default config setting <field>",
    "config get": "config get <field>: get the config value",
    "config help": "get config setting schema and descriptions",
    "config set": "config set <field> <val> [<val> ...]: set a config variable",
    "config show": "dump current config settings",
    "dirfrag ls": "List fragments in directory",
    "dirfrag merge": "De-fragment directory by path",
    "dirfrag split": "Fragment directory by path",
    "dump cache": "dump metadata cache (optionally to a file)",
    "dump loads": "dump metadata loads",
    "dump tree": "dump metadata cache for subtree",
    "dump_blocked_ops": "show the blocked ops currently in flight",
    "dump_historic_ops": "show slowest recent ops",
    "dump_historic_ops_by_duration": "show slowest recent ops, sorted by op duration",
    "dump_mempools": "get mempool stats",
    "dump_ops_in_flight": "show the ops currently in flight",
    "export dir": "migrate a subtree to named MDS",
    "flush journal": "Flush the journal to the backing store",
    "flush_path": "flush an inode (and its dirfrags)",
    "force_readonly": "Force MDS to read-only mode",
    "get subtrees": "Return the subtree map",
    "get_command_descriptions": "list available commands",
    "git_version": "get git sha1",
    "help": "list available commands",
    "log dump": "dump recent log entries to log file",
    "log flush": "flush log entries to log file",
    "log reopen": "reopen log file",
    "objecter_requests": "show in-progress osd requests",
    "ops": "show the ops currently in flight",
    "osdmap barrier": "Wait until the MDS has this OSD map epoch",
    "perf dump": "dump perfcounters value",
    "perf histogram dump": "dump perf histogram values",
    "perf histogram schema": "dump perf histogram schema",
    "perf reset": "perf reset <name>: perf reset all or one perfcounter name",
    "perf schema": "dump perfcounters schema",
    "scrub_path": "scrub an inode and output results",
    "session evict": "Evict a CephFS client",
    "session ls": "Enumerate connected CephFS clients",
    "status": "high-level status of MDS",
    "tag path": "Apply scrub tag recursively",
    "version": "get ceph version"
}

~~~

# 参考资料

* [kernel debug](https://elinux.org/Debugging_by_printing)
* [dynamic-debug-howto](https://www.kernel.org/doc/html/v4.11/admin-guide/dynamic-debug-howto.html)
* [ceph内核模块编译及调试](https://blog.csdn.net/hedongho/article/details/79705563)
* [cephfs kernel mount debug](https://docs.ceph.com/docs/luminous/cephfs/troubleshooting/#kernel-mount-debugging)
