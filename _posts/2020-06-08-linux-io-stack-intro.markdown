---
layout: post
title: linux io stack 介绍
date: 2020-6-8 21:11
comments: true
author: Peter.Y
categories: linux storage disk io 
---

* content
{:toc}

# Intro

本文基于linux 4.10版本，介绍内核的IO Stack。目标是希望通过这个简单分析，后续在遇到问题时(如性能问题、Ceph存储问题)，有思路。

> 由于内容涉及过多，有很多地方写的过于简单，请包涵。另外本文会持续更新中。

# linux disk io stack 介绍

参考linux 4.0 的 [io stack 图](https://www.thomas-krenn.com/de/wikiDE/images/d/d0/Linux-storage-stack-diagram_v4.10.pdf)

## [LIO](http://linux-iscsi.org/wiki/LIO)

LIO是 linux 实现的 iSCSI Target。

## VFS

`VFS` 全称 `Virtual File System` ，运行在内核中，在IOPath上是和用户程序最近的一个内核模块。

`VFS` 是用户应用程序读写数据的统一抽象层，定义了文件系统层的接口标准。在这一层我们可以看到很多文件系统就实现在这一层，大致分为6类：

* 本地文件系统
* 网络文件系统
* Stackable文件系统
* 伪文件系统
* 特殊文件系统
* FUSE

### 本地文件系统 

本地文件系统就是指我们常用的几种，例如：

* ext2/3/4
* xfs
* zfs
* btrfs

### 网络文件系统

网络文件系统也有很多，例如：
* NFS
* SMBFS/CIFS
* CODA
* CEPHFS

### Stackable文件系统

Stackable文件系统主要包括`ecryptfs`、`unionfs`和`overlayfs`这三种。

`ecryptfs`主要用来实现加密功能，支持文件级别加密。其可以堆叠在其它本地文件系统甚至是网络文件系统之上。

`unionfs`和`overlayfs`主要是用于实现容器化的文件系统。 //TODO

`unionfs-1.x`版本开发于2004年，是第一个联合文件系统的实现版本，早期主要用途是LiveCD，使用一块磁盘和光盘组成联合文件系统。2006年，`aufs`(Advanced Union File System)基于`unionfs-1x`开发，提升了性能和稳定性，不过因为各种原因，没有能进入kernel。不过好在不少发行版，包括`ubuntu`, `debian`等，都包含了这种文件系统。所以还ok。

`overlayfs`算是后起之秀，于2014年合并进linux kernel 3.18版本。与前辈相比，它在稳定性和性能方面有提升。另外，在`overlayfs2`中，支持多达500层的堆叠，相比原先只有2层的堆叠，简化了上层容器化的逻辑，降低了inode开销。


### 伪文件系统和特殊文件系统

伪文件系统主要用于对外暴露一些内核接口，我们常用的如

* proc: 查看运行状态，包括进程状态等，以及一些处理接口
* sysfs: 查看系统状态、内核状态和一些底层设备状态，以及一些操作接口
* debugfs: 提供内核模块的一些debug数据，以及debug操作接口

特殊文件系统主要包括`tmpfs`, `ramfs`等，这两种都是基于内存的文件系统，所以文件内容都是易失的。

它们的主要区别在于，ramfs不使用swap，大小不能设定，有机会耗光内存。
相比来说，还是tmpfs更可靠。

### FUSE

fuse是个apdapter模式，它一面是实现了VFS接口，另一面是通过系统调用向用户态提供了一组hook接口。最终达到的数据流如下

用户读写文件(USERSPACE) -> VFS(KERNEL) -> FUSE(KERNEL) -> 某FUSE文件系统(USERSPACE) 

这样做，可以方便用户开发自定义的各种文件系统，可以基于网络等各类设备。使开发者不必受内核迭代周期的影响。

当然，短板也很明显，就是性能。数据从用户空间到内核再回到用户空间，流程长、拷贝多。

基于FUSE的文件系统有很多了，举例如下:

* CEPHFS-FUSE
* s3fs
* glusterfs

## Page Cache

图的右侧是`Page Cache`，这个组件主要是用于非`DIRECT IO`模式下的内存缓存，以提升IO性能。

在早期的内核中，存在有`Page Cache`和`Buffer Cache`两种。前者是文件系统缓存，后者是块缓存。不过在后续的内核中，这两种cache都被统一到`Page Cache`中了。

### 使用Page Cache的优缺点

使用cache的好处是，提升读写性能；坏处是，数据有可能丢失。

好处是显而易见的，这里不展开。我们重点讨论下坏处。

当我们使用write back模式读写磁盘时，用户IO在落到`Page Cache`中时即返回了。在`Page Cache`落到磁盘这前的这段时间里，如果系统异常，是有概率造成数据丢失的。这里有2种情况:

* 用户IO所在的进程异常退出，操作系统正常运行

这种情况下，不会有问题。因为`Page Cache`的flush是内核行为，有一个内核线程在不断把`Page Cache`中的内容刷到磁盘中去。

* 操作系统异常，直接宕机

这种情况下，一般会发生数据丢失了。因为有数据未落盘，严重会导致文件系统损坏。解决方案一般是通过先日志后数据的方法，如`ext4`等操作系统就支持这种方式。虽然不能阻止数据丢失，但是可以降低文件系统损坏的概率。

### 如何drop cache

首先要注意，page cache是操作系统全局的，因此也只能drop整个操作系统级的所有cache。如果是想要针对单个磁盘，请使用`fsync`或`fdatasync`。

`drop cache` 方法如下

~~~
# echo 1 > /proc/sys/vm/drop_caches // drop page caches
# echo 2 > /proc/sys/vm/drop_caches // drop inode and dentry caches
# echo 3 > /proc/sys/vm/drop_caches // drop both page caches and inode/dentry caches
~~~

### 如何查看page cache情况

~~~
# vmtouch <file>
# //demo
# ➜  ~ vmtouch anaconda-ks.cfg 
           Files: 1
     Directories: 0
  Resident Pages: 1/1  4K/4K  100%
         Elapsed: 0.000137 seconds

~~~

## Stackable Block Layer

越过`VFS`层继续向下深入，在块设备层之上，还有一个`stackable block layer`。

这一层核心功能是提供虚拟块地址到物理块地址的映射，更准确地说，应该是上层块地址到下层块地址的映射，因为映射可以有多层。基于这一点，该层主要用于实现逻辑卷等一些功能和机制。相关技术如下

* device mapper
* lvm
* drbd
* bcache
* mdraid

其中 `device mapper` 是容器镜像的方案之一，也是整个IO地址映射内核框架的主体部分。基余技术如`lvm`、`drbd`等都是基于这个框架之上形成的。

### device mapper

`device mapper` 是运行在内核中的一套通用设备映射机制。它为实现用于存储资源管理的块设备驱动提供了一个高度模块化的内核架构。基于此它实现了以下几个插件功能：

* 软raid
* 软加密
* 镜像
* 快照

其中 `docker` 就是基于快照功能实现的。与`overlayfs`类似，`devicem mapper`的快照也是基于`COW`技术的，区别在于它的最小粒度是`block`，通常块大小为`64KB`。因此，对于文件size大于64KB的文件进行频繁读写的场景，`device mapper`的性能更为占优，反之则`overlayfs`占优。


### lvm

LVM，全称 Logical Volume Managment，逻辑卷管理，是基于`device mapper`之上提供的一种块设备管理方式。`LVM`主要有三个层次，从上到下依次如下

* LV (Logical Volume，逻辑卷)
* VG (Volume Group，卷组)
* PV (Phiscal Volume, 物理卷)

其中物理卷是物理块设备或分区；卷组是一组物理块设备的集合，形成了一个大的物理设备空间；逻辑卷是在卷组之上按线性或是其它方式划分的逻辑块设备。

与`device mapper`对比可以看出，`LVM`把`device mapper`的树状组织结构通过二次封装，变更为了`M:N`的网状结构，即M块物理块设备映射为N个逻辑块设备。这样对于系统管理来说，降低了管理复杂度。

此外，它也提供了`加密`和`快照`等功能。可以想见，都是基于`device mapper`实现的。

### drbd

drbd, 全称Distributed Replicated Block Device，是在内核的块接口层提供的一种数据镜像机制。采用主备方案，通信采用TCP/IP，写数据采用同步或半同步方式实现。

实际使用过程中的主要问题是脑裂。

### bcache

`bcache`是在块设备层提供的缓存机制。主要应用场景是将高速设备和低速设备组合，对用户提供一致的单个块设备接口。常见的场景如1块SSD + 1块HDD。

缓存机制上，支持常见的几种模式，如`writeback`, `writethrough`, `writearound`。这里不展开。

配置上，`bcache`还比较灵活，支持动态扩展多块缓存盘。

### mdraid

`mdraid`是基于内核实现的一种软件raid方案，它可以支持多种raid算法。这里不展开描述，有兴趣参考IBM的文章 [Linux中软件Raid的使用](https://www.ibm.com/developerworks/cn/linux/l-cn-raid/index.html)

## block layer

在 `Stackable Block Layer` 之下的是 `Block Layer`, 即通用块设备层。

这一层是Linux内核IO调度的核心，包含有多种IO调度器，适合于不同业务场景。整体上这一层主要包括2部分，一部分是上层的调度器，负责汇集和调度IO请求；另一部分是底层的硬件设备队列，即 `Hardware Dispatch Queue`。在传统的实现中，硬件设备队列通常只有一个(每设备1个)，因为传统的存储介质多基于磁盘，相对于CPU和内存，是一种机械式的慢速设备。
由于近几年存储介质的IO性能大幅度提升，如 `NVMe SSD`, `Optane SSD`等，单个硬件设备队列成为了瓶颈。
因此，Linux内核增加了`blkmq`机制，简单说就是多硬件设备队列，来提升这部分的性能。我们按单队列和多队列分别讨论。

### 单队列

单队列是linux上的主要IO调度框架，至于为什么是单队列是因为存储介质的IO速度相对于内存和CPU而言，差了不至一个数量级，一个队列完全够用了。

在linux的演进过程中，出现过5种调度器，分别是`Linux Elevator`, `Anticipatory`, `Deadline`, `CFQ`, `NOOP`。其中前两种因为已经老旧，逐步被移出了内核，现在内核中主要还使用的是后三种调度器。

#### Deadline

Deadline, 截止时间调度器，是对Linux Elevator的一种改进。主要特点是避免有些请求太长时间不能处理。
调度器将读写操作分在2个独立的FIFO队列中，分别进行调度。

#### NOOP

NOOP, 全称No Operation，是最简单的调度器。单个FIFO队列，所有请求按照先入先出顺序进行处理。

这个调度器适用于固态盘，因为后端IO能力提升，导致调度器做的多反而容易成为瓶颈。

#### CFQ

CFQ, 全称Completely Fair Scheduler，完全公平调度器。名字和完全公平进程调度器CFS有点像。
这是内核默认启用的调度器。它的主要工作原理如下:

* 为每个有IO需求的进程或线程，建立一个独立的队列来管理请求
* 调度器为每个队列分配时间片，以求在多队列中进行均匀调度，达到完全公平的目的。

### blkmq/多队列

`blkmq`是多队列机制，从lingxu kernel v3.13开始出现，直到v3.18才成熟进入生产级应用。

详细来说，它分为了上下2层队列。上层队列数是固定的，通常是per-core或者per-node。这样的好处是不再需要全局锁，大大提升性能。下层队列数通常与底层存储设备能提供的硬件队列数一致。

上层队列通常采用FIFO队列，不再需要重排序，但仍会保留请求合并。原因是，SSD等基于闪存的现代存储设备本身就是基于随机读写的设备，因此重排序对请求来说没有加速效果，反而增加开销；而仍需要请求合并是因为，闪存的读写有写放大问题，这是介质特性导致的，合并有利于降低开销。

内核在3.18以后的版本默认启用了blkmq，当前它支持以下的设备驱动

* null_blk
* virtio-blk
* scsi
* nvme
* rbd
* loop
* dm-mpath

一般来说，有这样的机制已经足够，不再需要调度算法。不过后来内核还是加入一些调度算法，已知的有

* mq-deadline
* bfq
* kyber

下面我们来看看

#### mq-deadline

这个实际上就是deadline调度器，只是应用到了blkmq上。与deadline相比，主要差别在于底层的多设备队列。

#### bfq

bfq, budget fair queueing, 是一种基于budget的调度器。该算法会给每个进程分配一定量的budget，budget是根据IO请求统计而来，与queue无关。

该调度器的目标主要是支持多种IO场景，如响应式、批处理式、实时IO请求等。

BFQ的CPU相比mq-deadline还是高不少的。这个从代理量可以看出来，mq-deadline的代码大约是800行，而BFQ的代码量已经达到10000行。

#### kyber

kyber，是一种基于可变队列长度的调度器。它的原理大致是，为每个硬件设备队列，按不同IO请求类型建立多个队列。之后根据IO的分布情况，通过动态调整队列长度的方式来实现调度的目的。

kyber算法主要用于高速设备，如NVMe SSD等。它的调度逻辑代码也不复杂，约为1000行。

## 块设备驱动层

这一层就是真实的块设备层了，可以看到以名称区分的不同设备，例如

* /dev/nullb*
* /dev/vd*
* /dev/nvme\*n\*
* /dev/sd*
* /dev/loop*

这些设备都有不同的驱动程序，注意这里的驱动程序还是相对common的，针对一类设备的通用驱动程序。
如`NVMe`, `virtio-blk`, `scsi driver`等。

## 底层设备驱动和物理设备

对于SCSI设备来说，还有一个底层设备驱动，这个驱动通常和物理设备的厂商密切相关。本文不展开。

# 参考资料

* [Linux IO Stack](https://www.thomas-krenn.com/de/wikiDE/images/d/d0/Linux-storage-stack-diagram_v4.10.pdf)
* [Docker五种存储驱动原理及应用场景和性能测试对比](http://dockone.io/article/1513)
* [LIO](http://linux-iscsi.org/wiki/LIO)
* [UnionFS](https://www.filesystems.org/project-unionfs.html)
* [AuFS](https://en.wikipedia.org/wiki/Aufs)
* [OverlayFS](https://en.wikipedia.org/wiki/OverlayFS)
* [DOCKER基础技术：AUFS](https://coolshell.cn/articles/17061.html)
* [docker devicemapper](https://docs.docker.com/storage/storagedriver/device-mapper-driver/)
* [Linux内核中的Device Mapper机制](https://www.ibm.com/developerworks/cn/linux/l-devmapper/index.html)
* [LVM逻辑卷管理](https://www.ibm.com/developerworks/cn/linux/l-lvm2/index.html)
* [Linux中软件Raid的使用](https://www.ibm.com/developerworks/cn/linux/l-cn-raid/index.html)
* [bcache](https://www.kernel.org/doc/Documentation/bcache.txt)
* [调整Linux I/O 调度器优化系统性能](https://www.ibm.com/developerworks/cn/linux/l-lo-io-scheduler-optimize-performance/index.html)
* [The multiqueue block layer](https://lwn.net/Articles/552904/)
* [Linux Block IO: Introducing Multi-queue SSD Access on Multi-core Systems](https://kernel.dk/blk-mq.pdf)
* [IOSchedulers](https://wiki.ubuntu.com/Kernel/Reference/IOSchedulers)
* [BFQ](https://www.kernel.org/doc/Documentation/block/bfq-iosched.txt)
* [kyber IO Scheduler of Linux](https://nan01ab.github.io/2019/02/Kyber.html)

