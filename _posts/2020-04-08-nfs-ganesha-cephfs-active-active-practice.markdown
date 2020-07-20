---
layout: post
title: NFS-Ganesha+CephFS双活模式实践
date: 2020-4-8 22:30
comments: true
author: Peter.Y
categories: Ceph NFS
---

* content
{:toc}

# 基本架构

总共分三层，从上到下依次是

* nfs 服务层，负责提供nfs接口服务，使用nfs-ganesha，纯用户态NFS服务
  * 主数据流: nfs-ganesha -> libcephfs -> mds/rados
  * client recovery: nfs-ganesha -> librados -> rados
  * nfs config -> librados -> rados
* ceph-mds, 负责管理cephFS 元数据
  * 静态多路径分析，解决元数访问不均衡和扩容问题
* ceph rados cluster(osds/mons), 提供rados 对象存储服务
  * 2个pool, cephfs_data 存储数据，cephfs_metadata存储元数据
  * cephfs_data存储client recovery和nfs config数据

# 部署

## ceph-ansible

可直接部署环境，参考相应配置即可

> 第一次启动失败，是因为recover配置了rados_cluster，需要手动加入节点，加入方法如下：

~~~

# // login to nfs-ganesha node 
# ganesha-rados-grace --pool cephfs_data add <hostname>
# // repeat for all the nfs-ganesha nodes which are in the same cluster

~~~

加入之后再重启下docker即可

启动成功后，会自动挂载根路径

# 日常运维

## 业务管理

为便于操作，需要先在mon节点上挂载该集群内根文件目录，以下假定已挂载到 `/mnt/` 下。

* step1，创建业务目录

首先按业务需要，创建一级子路径，示例如下：

~~~

# mkdir -p /mnt/app-<uuid>

~~~

* step2，生成配置文件

~~~
# 配置文件示例, app-<uuid>
[root@mon0 nfs-cluster1]# cat app-1 
EXPORT
{
        Export_id=20134;
        Protocols = 3,4;
        Transports = TCP;
        Path = "/app1-salt";
        Pseudo = /app1;
        Access_Type = RW;
        Attr_Expiration_Time = 0;
        SecType = sys,krb5,krb5i,krb5p;
        Squash = no_root_squash;

        FSAL {
                Name = CEPH;
                User_Id = "admin";
        }
}
~~~

* step3, 上传配置到rados存储

~~~
# rados -p cephfs_data put <cluster>-nfs<N>/app-<uuid> ./app-<uuid>
~~~

* step4, 修改_index，并上传

~~~

# _index文件示例
%url rados://cephfs_data/nfs-cluster1/app-1
%url rados://cephfs_data/nfs-cluster1/app-2
~~~

~~~
# rados -p cephfs_data put <cluster>-nfs<N>/_index ./_index
~~~

* step5, 重启该集群下所有的nfs-ganesha节点

> 这里的recover机制尚未经过验证，建议一台台重启

> 另一个设计思路是，每组容器只服务于一个业务

## 扩容

### nfs扩容

通过ceph-ansible, 推送新的节点即可

### MDS扩容

由于需要按路径分裂，需要手动操作

# TODO

* lvs + nfs-ganesha
