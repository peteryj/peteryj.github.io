---
layout: post
title: Ceph Container 使用实践
date: 2020-2-22 22:30
comments: true
author: Peter.Y
categories: Ceph Docker
---

* content
{:toc}

# Intro

本文介绍如何使用ceph-ansible部署ceph docker。分三个部分。一是制作ceph docker镜像，二是部署ceph docker镜像，三是ceph-ansible部署docker的主要流程分析。

本文分析的源码版本
* ceph-container: v3.2.10
* ceph-ansible: v3.2.29
* ceph: v12.2.10

# 制作ceph镜像

如果你没有对ceph进行二次开发，那么可以使用官方编译好的镜像，参考：

* [ceph/daemon](https://hub.docker.com/r/ceph/daemon)
* [ceph/ceph](https://hub.docker.com/r/ceph/ceph)

如果对ceph有二次开发，并且生成和发布了自己的package，那么就需要编译自己的镜像。

## ceph-container

[ceph-container](https://github.com/ceph/ceph-container) 这个项目用于创建ceph docker镜像。

[CONTRIBUTING](https://github.com/ceph/ceph-container/blob/master/CONTRIBUTING.md) 这篇解释了项目代码的主要结构，如何创建和编译定制的镜像，以及如何debug。

编译命令很简单。

~~~
# 命令

make FLAVORS=<CEPH_VERSION>[CEPH_POINT_RELEASE],<DISTRO>,<DISTRO_VERSION> [stage|build] [daemon|daemon-base]

# 含义

FLAVORS - 定义要编译的目标，分为几个部分，用于映射到不同的路径

stage|build: 编译目标
* stage - 只生成待编译文件，放到目录`staging/`下
* build - 先生成待编译文件，再执行`docker build`，产生镜像

daemon|daemon-base: 编译镜像
* daemon-base - 基础镜像，包含指定版本的所有包
* daemon - 可运行的ceph镜像，基于`daemon-base`构建
~~~

stage生成的内容遵循一定的规则进行覆盖，利用这个规则来达到定制的目标。以下是覆盖规则。

~~~
# Most specific
ceph-releases/<ceph release>/<base os repository>/<base os release>/{daemon-base,daemon}/FILE
ceph-releases/<ceph release>/<base os repository>/<base os release>/FILE
ceph-releases/<ceph release>/<base os repository>/{daemon-base,daemon}/FILE
ceph-releases/<ceph release>/<base os repository>/FILE
ceph-releases/<ceph release>/{daemon-base,daemon}/FILE
ceph-releases/<ceph release>/FILE
ceph-releases/ALL/<base os repository>/<base os release>/{daemon-base,daemon}/FILE
ceph-releases/ALL/<base os repository>/<base os release>/FILE
ceph-releases/ALL/<base os repository>/{daemon-base,daemon}/FILE
ceph-releases/ALL/<base os repository>/FILE
ceph-releases/ALL/{daemon-base,daemon}/FILE
ceph-releases/ALL/FILE
src/{daemon-base,daemon}/FILE
src/FILE
# Least specific
~~~

项目使用如上的约定形式来组织override的关系。从上往下看，越向下越通用。`<ceph release>`等变量的获取是通过FLAVORS得到的。

## 示例

我的定制镜像的代码路径如下

~~~
ceph-releases/luminous/centos/{daemon-base,daemon}
~~~

编译命令如下

make FLAVORS=luminous-12.2.10-dev1,centos,7 BASEOS_REGISTRY=docker-registry.peteryj.io/ceph BASEOS_REPO=centos BASEOS_TAG=7.6-dev-1 RELEASE=dev1 build

执行结果如下

~~~

  CEPH_VERSION      : luminous
  CEPH_POINT_RELEASE: -12.2.10-dev1
  DISTRO            : centos
  DISTRO_VERSION    : 7
  HOST_ARCH         : x86_64
  BASEOS_REGISTRY   : docker-registry.peteryj.io/ceph
  BASEOS_REPO       : centos
  BASEOS_TAG        : 7.6-dev-1
  IMAGES_TO_BUILD   : daemon-base daemon
  STAGING_DIR       : staging/luminous-12.2.10-dev1-centos-7-x86_64
  RELEASE           : dev1
  DAEMON_BASE_IMAGE : ceph/daemon-base:dev1-luminous-centos-7.6-dev-1-x86_64
  DAEMON_IMAGE      : ceph/daemon:dev1-luminous-centos-7.6-dev-1-x86_64

Computed:
  BASE_IMAGE        : docker-registry.peteryj.io/ceph/centos:7.6-dev-1

~~~

从上面可以很清楚看明白，FLAVORS是怎么映射到变量上面，并怎么作用到最终镜像上的。这里不赘述。

编译完成后，执行 docker images，就可以看到`daemon`和`daemon-base`两个镜像

# 用 ceph-ansible 部署 ceph docker image

执行命令其实很简单，使用官方自带的site-docker.yml.sample即可，只需要在inventory中指定docker image地址和版本即可。

inventory文件片断示例

~~~
[all]
ceph_docker_registry=docker.io
ceph_docker_image=ceph/daemon
ceph_docker_image_tag=latest-luminous
~~~

部署命令示例

~~~
ansible-playbook -i <inventory> site-docker.yml --extra-vars "ceph_docker_image_tag=12.2.10-dev1.1"
~~~

下面分析下ceph-ansible安装 ceph docker 的主要过程

> 以下假定读者已经熟悉 `ceph-ansible` 安装 `bear-metal` 版本。

## ceph-ansible 安装 ceph docker 过程分析

我们以项目中 `site-docker.yml.sample` 为例进行分析。通过对比，发现主要差别在于 `ceph-docker-common` 这个 `role` 上。其余的 `role` 都是采用条件语句控制部分需要 ceph docker 特殊处理的逻辑。

我们主要分析以下几个role:

* ceph-docker-common
* ceph-handler
* ceph-config

对于具体服务类，分析以下几个role:

* ceph-mon
* ceph-osd
* ceph-rgw
* ceph-mds
* ceph-nfs

### role: ceph-docker-common

基本上分为以下几步

* 准备 docker 运行环境
* 获取 ceph docker 镜像
* 配置文件目录等访问权限

#### 准备 docker 运行环境

主要完成以下工作

* 检查systemd是否正常工作
* 检查核心配置是否存在，包括 moniter/rgw 监控地址和端口
* 预安装
  * 去除不必要的udev文件
  * 安装docker和ntp
  * 启动dockerd
* 检查配置环境以及是否有ceph集群正在运行，如果发现有残留配置或正在运行，则出错退出，要求手动清理
* 检查时间同步ntp/chrony是否正确运行

#### 获取 ceph docker 镜像

* 检查旧docker容器以及对应容器版本，并记录
* docker pull 指定的docker image, 并记录
* 比较docker pull 前后的镜像SHA1差异，如不同则触发handler重启
* 获取并记录`ceph_version`变量和`ceph_release`，用于后续任务

#### 配置文件目录等访问权限

设定 /etc/ceph, 以及 /var/lib/ceph/bootstrap-* 的目录权限

### role:ceph-handler

handler被放在一个集中的role中，主要用于监听ceph运行版本和状态，在版本变更时触发指定的服务。

> 注意！对于指定的单个服务而言，如osd，是按并发度一起重启的。因此如果需要分批次，需要在运行时特别指定机器

docker版本和非docker版本差异主要在运行命令上，docker版本通过`docker exec <container_name> <ceph command>`的方式来执行。

下面主要分析下服务启动脚本的模板，主要分析 `mon` 和 `osd` 这两个服务

#### restart_mon_daemon.sh.j2

脚本主要流程如下:
* 测试*.asok文件是否存在，
* 尝试运行，并检测到`ceph -s`中显示加入到monitor集群，即在`quorum_names`分组中。

#### restart_osd_daemon.sh.j2

脚本主要流程:
* 重启每个osd进程
* 检测*.asok文件是否存在，并运行ceph -s，检测pg是否正常启动。

### role: ceph-config

脚本主要流程：
* 使用`ceph_volme`脚本创建底层块设备的分区、格式化等工作，传入`CEPH_CONTAINER_IMAGE`以标识docker版本
* 生成集群uuid
* 根据模板 `ceph.conf.j2` 生成配置文件

`ceph_volume`通过docker run运行。配置特权权限，并映射进磁盘路径和asok文件。从结果上看，相当于只使用容器的命名空间功能，实际效果和直接运行cpeh_volume没有什么区别。

### role: ceph-mon

主要流程
* 处理配置文件
* 创建ceph-mon@.service, docker版本会基于docker run 运行，然后启动服务
* 在docker宿主机上配置命令，便于运维操作。如 ceph, radosgw-admin, rados, rbd。启动方式修改为通过docker exec执行。
* 检测*.asok文件是否存在，以判断是否正常启动
* 将monitor组中其它节点加入bootstrap分组中，以在启动时直接互连
* 从monitor节点宿主机上取回配置和初始生成的`keyring`文件，存到`fetch`目录中，以备后续部署使用。
* 创建`restapi`和`mgr`服务用到的`keyring`文件并保存到`fetch`中
* 配置`crush rules`并更新到 `/etc/ceph/ceph.conf`中

### role: ceph-mgr

主要流程
* copy `keyring` 和目录到osd机器上，并配置相关权限
* 生成service文件, 启动`mgr`
* 检测`ceph mgr dump`中的`available`，判断启动成功
* 根据配置`ceph_mgr_modules`，启动相关模块

### role: ceph-osd

主要流程
* ceph系统配置优化
* copy `keyring` 和目录到osd机器上
* 生成`ceph-disk`相关参数，准备初始化块设备。docker版通过`-e`传入docker内部执行。
* 通过`docker run`运行特权容器，按不同osd场景，`non-collocated`, `lvm`等，分别初始化块设备
* 启动`osd`
  * 通过模板生成启动脚本`ceph-osd-run.sh`，以及服务文件`ceph-osd.service`
  * 如果有对service文件修改，则复制修改进去。这里由于docker版的service均是`ceph-ansible`生成，因此不需要。
  * 通过`ceph-handler`重启 `ceph-osd@.service` 服务。

### role: ceph-rgw

主要流程
* copy `keyring` 和目录到机器上
* 启动`rgw`
  * 通过`ceph-radosgw.service.j2`生成service文件
  * 启动ceph-radosgw服务
* 根据参数，配置`master|slave`集群
* 根据参数，创建rados pool等

### role: ceph-mds

主要流程
* 创建`cephfs_pools`指定的2个rados pool, 默认是`cephfs_metadata`和`cephfs_data`
* 创建`cephfs`指定的文件系统，并使用上面创建好的2个pool，启用`multimds`
* copy `keyring` 和目录到机器上
* 启动mds
  * 生成service文件
  * 启动mds
  * 检测*.asok文件，检测到测启动完成

### role: ceph-nfs

主要流程
* copy `keyring` 和目录到机器上，并配置权限
* 关闭正在运行的nfs server
* 安装包，有`nfs-ganesha-ceph`和`nfs-ganesha-rgw`两个包，对应着底层存储使用文件系统和对象存储两种方案。方案优劣不在本文范围内。
* 拷贝或生成配置文件，`keyring`及设置访问权限
* 根据`ganesha.conf.j2`生成配置文件，并启动nfs

# 参考资料
* [ceph-container](https://github.com/ceph/ceph-container)
* [ceph-ansible](https://github.com/ceph/ceph-ansible)
* [如何给docker配置代理](https://docs.docker.com/config/daemon/systemd/#httphttps-proxy)


