---
layout: post
title: NFS kernel client debug
date: 2020-4-30 14:00
comments: true
author: Peter.Y
categories: NFS kernel debug
---

* content
{:toc}

# Intro

本文介绍nfs debug 方法

服务端使用 `nfs-ganesha` ，直接打开debug 选项即可，没什么好说的。这里重点讲下 kernel client debug方法。

# debug

## debug log
由于我们使用的是nfs-utils的nfs client，该软件基于libtirpc开发。因此有封装好的rpcdebug工具，如下

~~~
# rpcdebug -vh
usage: rpcdebug [-v] [-h] [-m module] [-s flags...|-c flags...]
       set or cancel debug flags.

Module     Valid flags
rpc        xprt call debug nfs auth bind sched trans svcsock svcdsp misc cache all
nfs        vfs dircache lookupcache pagecache proc xdr file root callback client mount fscache pnfs pnfs_ld state all
nfsd       sock fh export svc proc fileop auth repcache xdr lockd all
nlm        svc client clntlock svclock monitor clntsubs svcsubs hostcache xdr all
~~~

通常我们打开nfs和rpc即可，nfsd是服务端，nlm是nfsv3中的子协议，对nfsv4来说用不着。

~~~
# rpcdebug -m rpc -s all
# rpcdebug -m nfs -s all
~~~

该命令实际上是去操作 `/proc/sys/sunrpc/{nfs_debug,rpc_debug}` 这几个文件，打开对应的标记位。

查看log，通过如下命令

~~~
# dmesg -w | tee debug.log
~~~

## nfsiostat

nfs client 也有一些集成度较好的metric工具，如nfsiostat, 它可以识别系统中的nfs挂载点，并统计iostat数据。

> 统计的数据来源是 `/proc/self/mountstats`

除了展示基本的读写吞吐、延时指标外，还可以展示cache命中的情况，详见示例。

示例如下:

~~~

➜  ~ nfsiostat
 
xx:/ mounted on /mnt:
 
   op/s     rpc bklog
   1.70    0.00
read:            ops/s         kB/s       kB/op     retrans     avg RTT (ms)    avg exe (ms)
          0.000   0.000   0.000       0 (0.0%)    0.000   0.000
write:           ops/s         kB/s       kB/op     retrans     avg RTT (ms)    avg exe (ms)
          0.662 678.614 1024.367       0 (0.0%)  24.425 2615.039
 
 
➜  ~ nfsiostat -h
Usage: nfsiostat [ <interval> [ <count> ] ] [ <options> ] [ <mount point> ]
 
 Sample iostat-like program to display NFS client per-mount' statistics.  The
<interval> parameter specifies the amount of time in seconds between each
report.  The first report contains statistics for the time since each file
system was mounted.  Each subsequent report contains statistics collected
during the interval since the previous report.  If the <count> parameter is
specified, the value of <count> determines the number of reports generated at
<interval> seconds apart.  If the interval parameter is specified without the
<count> parameter, the command generates reports continuously. If one or more
<mount point> names are specified, statistics for only these mount points will
be displayed.  Otherwise, all NFS mount points on the client are listed.
 
Options:
  --version             show program's version number and exit
  -h, --help            show this help message and exit
 
  Statistics Options:
    File I/O is displayed unless one of the following is specified:
 
    -a, --attr          displays statistics related to the attribute cache
    -d, --dir           displays statistics related to directory operations
    -p, --page          displays statistics related to the page cache
 
  Display Options:
    Options affecting display format:
 
    -s, --sort          Sort NFS mount points by ops/second
    -l LIST, --list=LIST
                        only print stats for first LIST mount points
                        

➜  /mnt cat /proc/self/mountstats
...
device xx:/ mounted on /mnt with fstype nfs4 statvers=1.1
    opts:   rw,vers=4.1,rsize=1048576,wsize=1048576,namlen=255,acregmin=3,acregmax=60,acdirmin=30,acdirmax=60,hard,noresvport,proto=tcp,timeo=600,retrans=2,sec=sys,clientaddr=xx,local_lock=none
    age:    9503
    impl_id:    name='',domain='',date='0,0'
    caps:   caps=0x3ffd7,wtmult=512,dtsize=32768,bsize=0,namlen=255
    nfsv4:  bm0=0xfcff8fff,bm1=0x40f9be3e,bm2=0x802,acl=0x0,sessions,pnfs=not configured
    sec:    flavor=1,pseudoflavor=1
    events: 35 259 2 1005 9 7 511 256000 0 66 0 26 18 2 6 4 0 3 0 0 256000 0 0 0 0 0 0
    bytes:  1048576000 1048576000 0 1048576000 1048576000 2097152000 256000 256000
    RPC iostats version: 1.0  p/v: 100003/4 (nfs)
    xprt:   tcp 0 0 1 0 0 12755 12754 0 51500 0 32 101086 25994
    per-op statistics
            NULL: 0 0 0 0 0 0 0 0
            READ: 1000 1000 0 220000 1048680000 1689 503927 505677
           WRITE: 2000 2000 0 2097616000 288000 5178088 48850 5230077
          COMMIT: 11 11 0 2244 1144 0 615 615
            OPEN: 2 2 0 632 704 0 140 141
    OPEN_CONFIRM: 0 0 0 0 0 0 0 0
     OPEN_NOATTR: 1 1 0 272 316 0 18 18
    OPEN_DOWNGRADE: 0 0 0 0 0 0 0 0
           CLOSE: 3 3 0 684 528 0 56 56
         SETATTR: 0 0 0 0 0 0 0 0
          FSINFO: 2 2 0 416 328 0 37 37
           RENEW: 0 0 0 0 0 0 0 0
     SETCLIENTID: 0 0 0 0 0 0 0 0
    SETCLIENTID_CONFIRM: 0 0 0 0 0 0 0 0
            LOCK: 0 0 0 0 0 0 0 0
           LOCKT: 0 0 0 0 0 0 0 0
           LOCKU: 0 0 0 0 0 0 0 0
          ACCESS: 13 13 0 2756 2184 0 260 261
         GETATTR: 36 36 0 7344 8640 0 668 671
          LOOKUP: 7 7 0 1556 672 0 133 133
     LOOKUP_ROOT: 1 1 0 180 276 0 18 18
          REMOVE: 0 0 0 0 0 0 0 0
          RENAME: 0 0 0 0 0 0 0 0
            LINK: 0 0 0 0 0 0 0 0
         SYMLINK: 0 0 0 0 0 0 0 0
          CREATE: 0 0 0 0 0 0 0 0
        PATHCONF: 1 1 0 200 116 0 18 18
          STATFS: 9662 9662 0 2085704 1545920 3350 198228 202134
        READLINK: 0 0 0 0 0 0 0 0
         READDIR: 7 7 0 1596 2548 0 204 204
     SERVER_CAPS: 3 3 0 624 492 0 55 55
     DELEGRETURN: 0 0 0 0 0 0 0 0
          GETACL: 0 0 0 0 0 0 0 0
          SETACL: 0 0 0 0 0 0 0 0
    FS_LOCATIONS: 0 0 0 0 0 0 0 0
    RELEASE_LOCKOWNER: 0 0 0 0 0 0 0 0
         SECINFO: 0 0 0 0 0 0 0 0
    FSID_PRESENT: 0 0 0 0 0 0 0 0
     EXCHANGE_ID: 0 0 0 0 0 0 0 0
    CREATE_SESSION: 0 0 0 0 0 0 0 0
    DESTROY_SESSION: 0 0 0 0 0 0 0 0
        SEQUENCE: 0 0 0 0 0 0 0 0
    GET_LEASE_TIME: 0 0 0 0 0 0 0 0
    RECLAIM_COMPLETE: 0 0 0 0 0 0 0 0
       LAYOUTGET: 0 0 0 0 0 0 0 0
    GETDEVICEINFO: 0 0 0 0 0 0 0 0
    LAYOUTCOMMIT: 0 0 0 0 0 0 0 0
    LAYOUTRETURN: 0 0 0 0 0 0 0 0
    SECINFO_NO_NAME: 1 1 0 168 104 18 18 37
    TEST_STATEID: 0 0 0 0 0 0 0 0
    FREE_STATEID: 0 0 0 0 0 0 0 0
    GETDEVICELIST: 0 0 0 0 0 0 0 0
    BIND_CONN_TO_SESSION: 0 0 0 0 0 0 0 0
    DESTROY_CLIENTID: 0 0 0 0 0 0 0 0
            SEEK: 0 0 0 0 0 0 0 0
        ALLOCATE: 0 0 0 0 0 0 0 0
      DEALLOCATE: 0 0 0 0 0 0 0 0
     LAYOUTSTATS: 0 0 0 0 0 0 0 0
           CLONE: 0 0 0 0 0 0 0 0
            COPY: 0 0 0 0 0 0 0 0

~~~

# client reset

有时客户端不能正常连接到服务端，需要client端重连，但不是所有情况下都能触发。但是这个时候client端做umount也会hang住。

有一个tricky的方法是，利用sunrpc的inject_fault机制，强行阻断rpc数据包，等待连接超时并重置连接。

具体方法如下：

~~~
# cat /sys/kernel/debug/sunrpc/inject_fault
0 // 代表不生效
# echo 10000 > /sys/kernel/debug/sunrpc/inject_fault
# // 代表每10000个包允许过一个包，基本上等于disable发包了。

...
// 超时N秒后，N取决于超时恢复时间

...
# echo 0 > /sys/kernel/debug/sunrpc/inject_fault

// 过几秒后，hang操作恢复正常
~~~

该方法主要用于一些有负载均衡的场景。

# 参考资料

[inject_fault](https://patchwork.kernel.org/patch/6482871/)
