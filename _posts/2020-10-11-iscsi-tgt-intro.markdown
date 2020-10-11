---
layout: post
title: iSCSI及tgt部署介绍
date: 2020-10-11 20:17
comments: true
author: Peter.Y
categories: linux iscsi tgt
---

* content
{:toc}

# Intro

本文简单介绍下iSCSI和iscsi+tgt的部署方案。

# iSCSI 

首先我们来看下几个术语，即什么是SCSI, iSCSI以及iSER。

## SCSI

SCSI, 全称Small Computer System Interface，即小型计算机系统接口。它是一种用于计算机及其周边设备之间（硬盘、软驱、光驱、打印机、扫描仪等）系统级接口的独立处理器标准。

SCSI标准定义命令、通信协议以及实体的电气特性（换成OSI的说法，就是占据物理层、链接层、套接层、应用层），最大部分的应用是在存储设备上（例如硬盘、磁带机），除外，SCSI可以连接的设备包括有扫描仪、光学设备（像CD、DVD）、打印机等等，SCSI命令中有条列出支持的设备SCSI周边设备。

SCSI标准起源于1986年的SCSI-1，发展至今，最新的是`SCSI-3` (2003) 年。

在最新的SCSI-3标准中，其带宽能力从最初的5MB/s增长到640MB/s。除此之外，它还定义了更加全面的协议标准，包括块(SBC)、磁带(SSC)、RAID卡(SCC)、多媒体(MMC)、媒体切换(MCC)等。

## iSCSI

iSCSI, 又称为`IP-SAN`，是一种基于因特网及`SCSI-3`协议下的存储技术，由IETF提出，并于2003年2月11日成为正式的标准。与传统的SCSI技术比较起来，iSCSI技术有以下三个革命性的变化：

* 把原来只用于本机的SCSI协议透过`TCP/IP`网络发送，使连接距离可作无限的地域延伸；
* 连接的服务器数量无限（原来的SCSI-3的上限是15）；
* 由于是服务器架构，因此也可以实现在线扩容以至动态部署。

iSCSI利用TCP/IP作为底层通信机制。

在iSCSI协议中，有两类实体，分别是initiator和target，其中initiator是tcp客户端，target是服务端。target运行在提供存储资源的服务器上，initiator运行在需要使用存储资源的服务器上。

iSCSI协议是一个基于C/S架构的有状态的协议，其中有几个关键术语，如下:

* initiator: iscsi协议的客户端。通常对应一个后端target。同时也对应一个前端scsi设备。
* target: iscsi协议的服务端。通常对应一个client端。
* session: 一个iscsi协议会话，同其它协议一样，由一个initiator和一个target组成。
* lun: 一个逻辑单元，这里指一个逻辑存储设备，如disk等。多个lun可以连接到一个target下。由于多个lun可能并不位于同一台机器上，因此同一个target下会存在多个tcp连接。这些连接也属于同一个session。

initiator和target之间通过login的方式创建并保持一个session，代表对一个存储资源的占用，可以发起读写等操作。

具体的iscsi协议参考[RFC3720](https://tools.ietf.org/html/rfc3720)。这里不展开。

## iSER

iSER，全称 iSCSI Extensions for RDMA，是把iSCSI协议运行在RDMA网络之上的辅助协议。这里的RDMA, 可以是RoCE或者是iWARP。

这种方案可以直接在initiator和target的内存中交换数据，减少了数据拷贝，从而降低了CPU开销，提升了性能。


# Linux LIO

从上文可知iSCSI是运行在tcp/ip网络之上的SCSI协议和标准。下面我们来看下Linux LIO。

Linux LIO运行在内核态，于2010年合入内核。
在此之前，Linux中使用的是stgt框架，该框架大部分运行在用户态，支持远端设备和本地设备，远端设备通过网络连接，本地设备通过stgt的内核模块`target_core`和`target_drivers`，直接读写`scsi mid layer`。该方案支持的本地设备有限，只有iSCSI和iSER，一些新的设备协议都不支持，如`FCoE`等。

因此，Linux才发展出了Linux LIO。LIO框架如下图

![](https://img-blog.csdn.net/20150703185507212?watermark/2/text/aHR0cDovL2Jsb2cuY3Nkbi5uZXQv/font/5a6L5L2T/fontsize/400/fill/I0JBQkFCMA==/dissolve/70/gravity/Center)

从图中可以看出，LIO框架设计的非常灵活，大致分为3层。

最上层是应用层，运行在用户态，包括操作CLI和UI。其余都运行在内核态。中间一层是Unified Target，包括通用target管理引擎和存储管理引擎。最下层包括2个模块，`Fabric`和`Storage`，分别抽象了连接协议和存储后端。`Fabric`支持了`iSCSI`, `FCoE`, `vHost`, `iSER`等协议，`Storage`支持文件IO后端，Block后端和Raw设备后端。

这个框架的问题主要是全部运行在内核态，后续迭代相对困难。因此我们回过头来看下[stgt](http://stgt.sourceforge.net/)。

# tgt

[tgt](https://github.com/fujita/tgt) 是运行在用户态的iscsi网关，它支持多种后端，并且可扩展。

由于运行在用户态，在容器化流行的今天，它反而比Linux LIO显得更加灵活。

其架构如下图

![](https://img-blog.csdnimg.cn/20190916160921985.png?x-oss-process=image/watermark,type_ZmFuZ3poZW5naGVpdGk,shadow_10,text_aHR0cHM6Ly9ibG9nLmNzZG4ubmV0L01vcnJ5X0NoYW4=,size_16,color_FFFFFF,t_70)

可以看到，除了target是本地磁盘以外的场景外，其余都是走自定义的协议库，并且可以通过第三方动态库链接进来，可以说非常灵活了。

tgt还对应有一个initiator工具，名为`iscsid`。下面我们看看怎么部署。

# iscsi + tgt

我们以centos7为例进行说明，其它Linux发行版请自行查找软件，基本都有安装包，不行还可以编译安装。

## 安装

需要安装下面2个包

~~~
# yum install -y iscsi-initiator-utils
# yum install -y scsi-target-utils
~~~

## 部署iscsid

通过以下命令部署和启动iscsid

~~~
# systemctl enable iscsid
# systemctl start iscsid
~~~

## 部署tgt

通过以下命令部署和启动tgtd

~~~
# systemctl start tgtd
# systemctl enable tgtd
~~~

## 创建和使用

我们以创建一个本地盘设备为例来演示

### 创建target

分三步，创建target, 添加lun, 配置访问权限

我们使用工具tgtadm来进行设置。这个工具被包含在上面的安装包内。命令如下

~~~
// 1. 创建target
# tgtadm --lld iscsi --op new --mode target --tid 1 -T iqn.1996-05.com.redhat:tt.xx

// 2. 添加lun
# tgtadm --lld iscsi --op new --mode logicalunit --tid 1 --lun 1 -b /data/lun

// 3. 配置访问权限
# tgtadm --lld iscsi --mode target --op bind --tid 1 -I ALL

~~~

上述操作完成后，我们可以调用initiator来创建客户端设备了

### 创建initiator

使用工具iscsiadm与iscsid交互，完成initiator的操作。
主要分2步，discovery和login。命令如下

~~~
// 连接指定的IP:Port，尝试发现有哪些target
# iscsiadm -m discovery -t sendtargets -p <iscsi_targetIP>:<port>

// 输出类似如下

192.168.1.1:3260,1 iqn.1997-05.com.test:raid

// login上面发现的target
# iscsiadm -m node –T iqn.1997-05.com.test:raid -p <iscsi_targetIP>:<port> -l
~~~

这时fdisk -l就可以看到多出了一个块设备，但是我们怎么确定它一定是通过iscsi创建的呢。我们可以通过下述命令来确认。

~~~
# iscsiadm -m session -P 3

....
   scsi2 Channel 00 Id 0 Lun: 1
        Attached scsi disk sdd          State: running

~~~

从上述示例可以看到，新建的块设备名称是`sdd`。

这种方式使用上不太友好，因为`sdx`的编号太不固定了。我们可以通过`mknod`的方式，创建另一个设备指向`sdd`。这里就不展开了。

# 总结

本文主要介绍了iscsi的一些简单概念，以及如何在linux下使用tgt搭建iscsi server。

# 参考资料

* [wiki:SCSI](https://en.wikipedia.org/wiki/SCSI)
* [wiki:iSCSI](https://en.wikipedia.org/wiki/ISCSI)
* [wiki:iSER](https://en.wikipedia.org/wiki/ISCSI_Extensions_for_RDMA)
* [tgt:SCST](https://blog.csdn.net/scaleqiao/article/details/46753209?utm_medium=distribute.pc_relevant_t0.none-task-blog-BlogCommendFromMachineLearnPai2-1.nonecase&depth_1-utm_source=distribute.pc_relevant_t0.none-task-blog-BlogCommendFromMachineLearnPai2-1.nonecase)
* [tgt:Linux/LIO](https://blog.csdn.net/cybertan/article/details/9475503?utm_medium=distribute.pc_relevant.none-task-blog-BlogCommendFromMachineLearnPai2-5.nonecase&depth_1-utm_source=distribute.pc_relevant.none-task-blog-BlogCommendFromMachineLearnPai2-5.nonecase)
* [tgt:stgt](https://blog.csdn.net/scaleqiao/article/details/46706953)
* [tgt:SCST vs LIO](https://blog.csdn.net/cybertan/article/details/9475503?utm_medium=distribute.pc_relevant.none-task-blog-BlogCommendFromMachineLearnPai2-5.nonecase&depth_1-utm_source=distribute.pc_relevant.none-task-blog-BlogCommendFromMachineLearnPai2-5.nonecase)
* [tgt框架介绍](https://blog.csdn.net/Morry_Chan/article/details/100891020?utm_medium=distribute.pc_relevant.none-task-blog-BlogCommendFromMachineLearnPai2-3.nonecase&depth_1-utm_source=distribute.pc_relevant.none-task-blog-BlogCommendFromMachineLearnPai2-3.nonecase)
* [tgt安装和使用](https://blog.csdn.net/QTM_Gitee/article/details/82717107?utm_medium=distribute.pc_relevant.none-task-blog-BlogCommendFromMachineLearnPai2-1.nonecase&depth_1-utm_source=distribute.pc_relevant.none-task-blog-BlogCommendFromMachineLearnPai2-1.nonecase)
