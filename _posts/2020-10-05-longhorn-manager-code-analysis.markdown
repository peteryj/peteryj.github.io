---
layout: post
title: longhorn-manager 源码分析
date: 2020-10-5 22:00
comments: true
author: Peter.Y
categories: longhorn
---

* content
{:toc}

# Intro

本文记录 `longhorn-manager` 项目的源码分析，包括模块分析及主要流程代码级分析

# 代码组织及模块介绍

从代码组织结构看，大致划分如下：

* main.go
* app
* api
* client
* controller
* csi
* datastore
* deploy
* engineapi
* k8s
* manager
* package
* scheduler
* types
* upgrade
* util

我们从main.go入手，先分析下启动过程

## main.go

包含`longhorn-manager`的入口，主要是使用cli模块创建命令行参数关联子命令入口，包括7类子命令，分别是:
~~~
daemon
snapshot
deploy-driver
csi
post-upgrade
unisntall
migrate-for-pre-070-volumes // 遗留代码，不作分析
~~~

这些子命令都放置在`app`模块下，下面来看下`app`

## app

app下包含的是各子命令的入口描述，以`daemon`为例

~~~
func DaemonCmd() cli.Command {
        return cli.Command{
                Name: "daemon",
                Flags: []cli.Flag{
                        cli.StringFlag{
                                Name:  FlagEngineImage,
                                Usage: "Specify Longhorn engine image",
                        },
                        cli.StringFlag{
                                Name:  FlagInstanceManagerImage,
                                Usage: "Specify Longhorn instance manager image",
                        },
                        cli.StringFlag{
                                Name:  FlagManagerImage,
                                Usage: "Specify Longhorn manager image",
                        },
                        cli.StringFlag{
                                Name:  FlagServiceAccount,
                                Usage: "Specify service account for manager",
                        },
                        cli.StringFlag{
                                Name:  FlagKubeConfig,
                                Usage: "Specify path to kube config (optional)",
                        },
                },
                Action: func(c *cli.Context) {
                        if err := startManager(c); err != nil {
                                logrus.Fatalf("Error starting manager: %v", err)
                        }
                },
        }
}

~~~

主要是定义子命令的参数解析，以及子命令的主函数入口，这里是`startManager`。

其中 `daemon`, `deploy-driver`, `csi` 这三个子命令会作为daemon进程一直运行。我们重点来看下

### daemon

启动函数为`startManager`，启动过程主要分为以下几个部分:
* 参数检查
* 环境检查
* 加载配置
* 自动升级
* 启动各种controllers
* 启动volumeManager
* 创建longhornNode和engineImage资源
* 启动apiServer

其中参数检查忽略，其它的我们分析看看

#### 环境检查

环境检查主要是检查当前系统中是否安装了iscsiadmin，检查方法有点意思，逻辑如下:
* 启动时将宿主机`/proc`路径挂载到`/host/proc`下
* 通过查找当前进程的祖先进程，找到`dockerd`或者`containerd`，从而定位到了其namespace
* 通过`nsenter`命令，只进入`mount`和`net`这两个子命名空间，尝试运行`iscsiadmin --version`来检测是否有在运行

#### 加载配置

* 读取longhorn全局配置，并覆盖代码中指定的default配置`SettingDefinitions`
* 获取`pod`运行的ip地址和宿主机hostname

#### 自动升级
当longhorn发生版本变化时，会触发升级逻辑。这里还用到了k8s的分布式选举组件`k8s.io/client-go/tools/leaderelection`。这里暂不展开。

#### 启动各种controllers

k8s上的应用基本都是follow operator/controller + etcd的设计模式。这里也差不多，主要函数入口是`controller/controller_mamanger.go:StartControllers()`。

这个函数主要工作如下
~~~
* 初始化k8s client和longhorn client
* 创建监听器informer，监听包括replica、engine、node、pod等一系列资源的变更
* 创建`datastore`，并传入各种informer作初始化
* 创建各种controller，包括
    * EngineImageController
    * VolumeController
    * ReplicaController
    * EngineController
    * NodeController
    * WebsocketController
    * SettingController
    * InstanceManagerController
    * K8sPVCController
    * KubernetesNodeController
~~~

从controller的代码组织来看，基本分为三个部分

* 创建，包括创建数据结构，关联事件源和队列，事件handler主要是过滤和入队
* 主要goroutine逻辑，就是处理队列中的消息，一般是创建同步各种资源，并依需要写回k8s中，以此会触发其它事件。

从上面可以看出，这是以发布订阅模式为基础的框架，理解这一点之后我们可以展开看看各个controller

##### KubernetesNodeController

这个controller负责监听k8s node的label和annotation，主要是`annotation`:

`node.longhorn.io/default-disks-config`: <disk config json>

这个配置指定了node上用于longhorn存储的路径，如果检测出来多个路径指向了相同的文件系统，则报错。

disk config josn示例如下

~~~
node.longhorn.io/default-disks-config: '[{"path": "/diska", "storageReserved":
      1048576, "allowScheduling": true, "tags": ["hdd", "fast"]}, {"path": "/diskb",
      "storageReserved": 1048576, "allowScheduling": true, "tags": ["hdd", "fast"]},
      {"path": "/diskc", "storageReserved": 1048576, "allowScheduling": true, "tags":
      ["hdd", "fast"]}]'

~~~

如果检测到，则更新对应的`nodes.longhorn.io`(lhn)资源的annotation标识。

##### EngineImageController

该controller负责监听和处理engineImage资源事件，另外监听volume和daemoneSets事件。

对于volume事件，查找其对应的engineImage，并过滤掉非本节点的engineImage，之后产生对应的engineImage事件。

对于daemoneSet事件，主要是检查其metadata.ownerReferences下的信息，如果有变更，则产生对应的engineImage事件。

处理事件的主要逻辑是`syncEngineImage()`函数，其主要逻辑如下:

1. 获取engineImage资源对象，检查status.ownerID对应的node
2. 如果node down了或者没有id，则发起更新，抢占owner，如果冲突就退让，不会报错。说明底层机制保证了冲突情况下至少有一个可以正常设置。另外，即便有异常，下一次仍会检测到。
3. 如果engineImage.status.ownerID是本节点，则继续后面的检查，否则退出
4. 根据engineImage名称获取对应的daemonSet资源对象，如果为空则创建daemonSet资源对象
5. 检查ds的image版本信息是否正确，如错误则清理掉，待后续更新
6. 检查ds.status.desiredNumberScheduled是否为0，如是则更新状态为Not scheduled
7. 检查ds.status.NumberAvailable，如果少于规定数量，则更新状态为no enough pods
8. 检查engineImage兼容性

##### EngineController

该controller负责监听和处理engine资源事件，另外监听instanceManager事件，主要是监听engine类型的instanceManager事件。

对于instanceManager事件，将该instanceManager负责管理的属于当前Node的engines找出来，每个建立对应的事件。

处理engine事件的主要函数是`syncEngine()`，其主要逻辑如下:

1. 获取engine资源对象，检查是否有节点在管理，如没有则设置其ownerID为当前Node并更新etcd。如果是待清理则执行清理动作。
2. 检查engine当前的Image版本是否和spec.engineImage一致，如果不一致则执行更新。更新动作为向instanceManager发起grpc调用ProcessReplace()，升级该engine对象对应的instanceManager资源对象，包括1个engine进程和n个replica进程。
3. 当更新完成版本一致后，设置status.currentReplicaAddressMap为spec中的值。
4. 调用`instanceHandler.ReconcileInstanceState()`，根据更新后的配置，重新创建和启动instance相关资源对象和进程。
    
    a. 首先获取instanceManager资源对象，并检查版本是否是APIVersionOne，如果是则认为非兼容，直接关闭相关对象并报错待人工处理。
    
    b. 检查状态是否为待启动并且没有对应进程，是则调用`engineController.CreateInstance()`，最终发起grpc调用ProcessCreate()，让instanceManager启动对应进程。
    
    c. 调用`syncStatusWithInstanceManager()`，根据instanceManager的状态来更新engine.status相关信息。

5. engine相关进程创建成功后，我们需要创建对应的engineMonitor。该monitor会启动一个gorountine，它每5s执行一次状态检查，并调用`refresh()`来刷新状态。`refresh()`函数展开如下:
    
    a. 调用`replicaList()`，其背后会调用cli与instanceManager通信，获取该engine对应的replica列表。
    
    b. 遍历该列表，检查其状态是否正常，如正常则更新到engine.status.replicaModeMap
    
    c. 调用`snapshotList()`，与instanceManager通信，获取该engine的snaplist列表，并更新到engine.status.snapshots中。
    
    d. 调用`info()`，获取endpoint和volume相关信息，并用以更新status下的相关状态信息，如果endpoint尚未初始化，则尝试启动它。
    
    e. 更新status.rebuildReplicaStatus信息。
    
    f. 调用`snapshotBackupStatus()`和`snapshotPurgeStatus()`，通过cli与instanceManager通信，获取snapshot相关信息，并更新engine.status相关字段。
    
    g. 以上engine.status更新完成，写回etcd。
    
    h. 根据spec.volumeSize，如果比当前值大并且允许自动扩容，则调用`expand()`，通过instanceManager()进行扩容操作。
    
    i. 调用`backupRestoreStatus()`，通过instanceManager获取当前backupRestore状态信息。并做相应检查，如果需要，就调用`backupRestore()`触发instanceManager执行restore动作。

6. 检测engine状态，如果是running且engineMonitor已经创建成功，并且该engine下有对应的replica，则我们检查下replica状态是否正常，通过调用`ReconcileEngineState()`:

    a. 清理异常的replica

    b. 检查`engine.status.replicaModeMap` 与 `engine.status.currentReplicaAddressMap`，对于后者中存在而在前者中不存在的，触发`startRebuildReplica()`进行重新构建。注意每次只重建一个，剩下的待下次触发后再执行。

engineController负责了主要组件的创建和管理，包括和instanceManager的通信，以及控制engines和replica的进程管控。

##### ReplicaController

该controller负责管理replica资源对象，主要监听replica的事件，另外还监听instanceManager的事件。

对于instanceManager事件，将该instanceManager负责管理的属于当前Node的replicas找出来，每个建立对应的事件。

处理事件的主要函数是`syncReplicas()`函数，其主要逻辑如下:

1. 获取replica资源对象，检查是否有节点在管理，如没有则设置其ownerID为当前Node并更新etcd。如果是待清理则执行清理动作。
2. 调用`instanceHandler.ReconcileInstanceState()`，根据更新后的配置，重新创建和启动instance相关资源对象和进程。细节与[engineController](#engineController)相同。

##### VolumeController

该controller负责管理volumes资源对象，主要监听volume事件，另外还监听engine和replica资源对象的事件。

对于engine和replica事件，将其转换为对应的为volume事件。

处理volume事件的主要函数是`syncVolume()`，其主要逻辑如下:

1. 获取volume资源对象，检查是否有节点在管理，如没有则设置其ownerID为当前Node并更新etcd。
2. 如果是清理事件，则依次序删除engines, replicas, pv, pvc并退出。
3. 根据volume获取对应的engine, replicas资源对象。
4. 检查该engine对象

    a. 调用`reconcileEngineReplicaState()`，主要检查其副本数是否正常等。

    b. 调用`updateRecurringJobs()`，按需创建一组cronjobs用于更新volume对象。

    c. 调用`upgradeEngineForVolue()`，根据volume的信息，更新engine，包括replica副本等。

5. 调用`reconcileVolumeState()`以更新volume状态，这段逻辑较复杂。

    a. 获取volume对应的engine对象

    b. 如果volume.status.fromBackup不为空，则说明该volume是backup，则尝试从backup中restore该volume。

    c. 检查volume.status.currentNodeID的各种case，处理并更新volume.status，如restore等，这里暂不展开。

    d. 如果engine对象为空，则创建它，并写入etcd。

    e. 如果engine.snapshots不为空，则统计其总长度并记录到volume.status中。

    f. 如果replicas为空，则创建它，并保证创建numOfReplicas个，写入etcd。

    g. 尝试调度replicas。这是通过`scheduler/replica_scheduler.go`实现的，这里不展开。基本思路就是先选Node，按antiZone策略、sameZone策略、磁盘空间等filter一遍。在最终得到的列表中随机选择。调度完成后，将目标Node和磁盘信息更新到replica资源对象中。

    h. 如果全部replica调度都已完成，则更新volume.status.conditions中的scheduled状态为true。

    i. 对于backup/restore的volume，修改其状态为禁止前端挂载。

    j. 处理离线扩容的状态变更。

    k. 处理replica异常时的恢复。分两种。
        1) 如果全部fail，则要找全部replica，如果都已经是unhealth状态，则无可恢复数据 ，返回失败；如果有可用的，则标记进行恢复；更新volume.status的相关内容，并且重新挂载。
        2) 如果部分fail，则不用做什么，直接remount即可。

    l. 更新volume.status.currentNodeID字段，根据当前volume和replica的状态

6. 清理出错的replica信息，并更新etcd

##### NodeController

该controller负责处理node相关的逻辑。它主要监听lhn的事件，另外还监听pod，replica, k8sNode以及全局settings这些资源变更事件。

对于非lhn的事件，都会转化为lhn事件。如下

* settings事件会触发对所有lhn的事件
* managerPod资源事件会触发对所有lhn的事件
* replica资源事件会触发对所在node的lhn事件
* k8sNode资源事件会触 发对所在node的lhn事件

处理事件的主要逻辑是`syncNode()`函数，其主要逻辑如下

1. 查找到本节点对应的managerPod
2. 查看pod.status.conditions状态，如果是running，则更新对应lhn的node.status.conditions状态为ready，否则更新为down
3. 如果没有找到managerPod，则更新lhn的node.status.conditions为找不到managerPod
4. 读取k8sNode状态信息，用于更新lhn信息

    a. 如果k8sNode没有ready，则更新lhn状态为notReady；如果k8sNode状态是磁盘网络等资源出现问题，如耗尽等，也更新对应状态

    b. 其余情况忽略

5. 准备节点调度

    a. 首先根据cordon标记过滤节点，longhorn有一个全局配置`disable-scheduling-on-cordoned-node`来启动或禁用这一过滤，默认为true。

    b. 根据k8sNode的label `topology.k8s.io/region`以及`topology.k8s.io/zone`信息，来获取节点的物理拓扑信息，并写入lhn的`status.region`和`status.zone`中。

6. 调用syncDiskStatus以更新lhnNode上的disk信息

    a. 调用`nsenter stat -fc`以获取node.spec.disks指定的磁盘信息，生成fsid2Disks

    b. 遍历fsid2Disks，检测重复的磁盘，最终更新远diskStatus，如总存储空间等

    c. 读取节点上各磁盘的所有replica信息，并计算节点各磁盘可用空间，生成调度信息，并写入node.disk.status.conditions中以便后续调度使用。

7. 调用syncNodeStatus以更新lhnNode的status信息，主要是检测volumeMounts中的`longhorn`，是否具备`mountPropagation: Bidirectional`。

8. 调用syncInstanceManagers，主要逻辑就是遍历当前节点上的`engine`和`replica`这两种`instanceManager`，没有的话就创建。

##### WebsocketController

用于处理api模块的websocket请求，不展开

##### SettingController

监听全局settings变更，并做相应的处理，比较多的是`backup-target`的处理。其它部分不太复杂，这里不继续深入了。

##### InstanceManagerController

该controller负责处理instanceManager相关的逻辑。

主要监听instanceManager事件，除此之外，还监听instanceManager的Pod事件，并把pod转化为对应的instanceManager事件。

处理事件的主要逻辑是`syncInstanceManager()`函数，其主要逻辑如下:

1. 确定收到的事件是当前Node所负责的instanceManager，并获取相关资源对象
2. 检查instanceManager的status，并正确设置
3. 检查instanceManagerMonitor线程是否启动，如没有则启动。
4. 检查instanceManagerPod的状态，如果不是Running，则尝试重启该Pod。

有关第3点再展开看下，monitor线程通过grpc协议监听instanceManager进程的状态，当有变化或者每60s内，会触 发同步instanceManager进程对应的子进程列表，获取后会更新status.instances。

##### K8sPVController

该controller负责监听和处理pv事件，除此之外，它也监听pod和volume事件。

对于Pod事件，检查其所有的spec.volumes对应的pvc信息，如果匹配上，则转换为一个pv事件

对于volume事件，检查其状态为Bound，则转换为一个pv事件

处理事件的主函数是`syncKubernetesStatus()`，其主要逻辑如下

1. 根据delete事件中记录到pvToVolumeCache中的待删除的PV，执行清理动作，主要是把volume.status.kubernetesStatus.PV* 清空。
2. 如果不是待清理pv，则进入新增和更新处理。
3. 根据pv获取到对应的volume资源对象，忽略掉不是当前Node的volume资源对象
4. 根据volume的状态更新controller的一些信息，主要是workloadStatus这个信息
5. 根据workloadStatus的状态，判断是否要执行一些清理动作，如volumeAttachments等。这里不再展开。

#### 创建volumeManager

根据ds创建`volumeManager`，逻辑很简单

#### 创建longhornNode和engineImage资源

分两步

* 初始化settings相关的配置，使用命令行参数中的配置覆盖掉之前加载的全局默认配置

* 创建longhornNode的内存结构，并通过k8s longhornClient写入集群，触发其它任务
* 创建engineImage的内存结构，并通过k8s longhornClient写入集群，触发其它任务

#### 启动apiServer

创建url router，代码位于`api/`目录下，主要是各种资源的CRUD，这里不展开。
最后一步，启动监听端口`9500`。

至此，启动过程就完成了。

## 模块分析

上面分析了main.go中的启动过程，下面按照文件组织结构分析下代码。主要模块如下

* app: 子命令的入口模块，如`daemon`，`deploy-driver`, `csi`, `snapshot`, `post-upgrader`等。
* api: 主要负责实现各api的逻辑，`api/router.go`中存放url路由。
* client: longhorn-manager自身的client实现，在csi模式中会用到，由[go-rancher](https://github.com/rancher/go-rancher)项目生成。
* controller: 各类controller组件的实现逻辑，基本上每类crd资源都有对应的controller。
* csi: 实现`csi-plugin`的主要逻辑
* datastore: 存储接口模块，主要封装的是和k8s集群api交互，写操作会落到etcd中。
* deploy: 存放一些部署脚本和yaml文件
* engineapi: 负责longhorn-manager与其它组件交互的接口，一种是通过engine_binaries/的命令行调用的接口，这种主要有`backup`, `engine`, `snapshot`; 另一种是封装的instance-manager的grpc client，主要逻辑是`engine`, `replica`两类进程的创建和维护。
* k8s: 实现k8s的client接口实现，如各类资源的CRUD实现，以及事件订阅等。
* manager: api模块的后台逻辑实现，同时也是`VolumeManager`的主要实现
* package: docker打包相关
* scheduler: replica调度相关逻辑，在`volume`的创建中会用到。
* types: 一些类型定义
* upgrade: 存放的是api升级或者版本升级时的处理代码，包括在线离线不等
* util: 各种杂项代码

大部分逻辑都比较清晰，我们分析下csi下的代码

### csi模块

该模块内主要有以下几个文件

* manager.go: 模块入口，负责创建模块内的其余组件。
* identity_server.go: 实现csi定义的`identity`接口，主要负责检测插件能力等。
* controller_server.go: 实现csi定义的`controller`接口，包括CRUD volumes和snapshots，以及一些其它功能。实现上调用了`client`模块中的代码，走restful api接口。
* node_server.go: 实现csi定义的`node`接口，主要负责执行`mount`和`umount`动作。
* server.go: grpc server端代码实现，主要是接受上述三种接口的注册，并启动一个grpcServer接受外部请求。
* deployment.go: 存放`deploy-driver`相关的逻辑，主要是`attacher`, `provisioner`, `resizer` 这三类CSI插件的创建和启动逻辑。

由上可以看出，grpcServer负责接收外部的请求，再转换为`identity`, `node`, `controller`三类接口实现。
而`attacher`, `provisioner`, `resizer`是负责运行csi协议并和k8s集群协作的组件，它定义了上述三类接口并通过调用这三类接口实现了CSI的功能。


