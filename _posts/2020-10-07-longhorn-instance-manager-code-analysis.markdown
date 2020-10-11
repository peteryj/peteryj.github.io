---
layout: post
title: longhorn-instance-manager 源码分析
date: 2020-10-7 20:17
comments: true
author: Peter.Y
categories: longhorn
---

* content
{:toc}


# Intro

本文记录 `longhorn-instance-manager` 项目的源码分析，包括模块分析及主要流程代码级分析

# 代码组织及模块介绍

`longhorn-instance-manager` 负责管理单个Node上的engine和replica进程。

从代码组织结构看，大致划分如下：

* main.go: 入口函数
* app: 子命令入口模块, 包括`daemon`和`process`两个子命令。
* pkg: 存放各类子命令的相关处理逻辑，如`process`, `rpc`, `health_probe`等
* package: 打包程序


# 启动分析

## daemon

daemon的入口子命令是`start`。主要启动过程如下:

1. 创建ProcessManager，该组件负责处理主要业务逻辑。
2. 创建healthCheckServer，该组件负责处理健康检查。
3. 创建grpcServer，并监听端口，默认8500，负责接收和处理来自外部的请求。主要是longhorn-manager。并将``ProcessManager`, `healthCheckServer`注册到grpc中。

## process

process的入口子命令是`process`，该命令主要是实现了`ProcessManager`的grpc client，支持process的CRUD等操作。

# 模块分析

## ProcessManager

从上面看出，主要逻辑是在`ProcessManager`内，代码位于`pkg/process`内。

启动逻辑如下:

1. 创建数据结构，主要包括广播组件`broadcaster`, manager通信通道`broadcastCh`, 子进程通信通道`processUpdateCh`, 进程执行器`Executor`
2. 向`broadcaster`注册，通信通道设为`broadcastCh`。
3. 启动主监听器，主要负责接收`processUpdateCh`消息，从中获取`RPCResponse`，并把它转发给`broadcastCh`。

`broadcaster`实现了一个简单的单源多订阅模式的组件。它被初始化为接收`broadcastCh`的消息，并转发给向其订阅的n个`Process`。

上面介绍了`ProcessManager`的主要工作线程，下面看下grpc触发的各类函数实现。主要包括如下

* ProcessCreate
* ProcessDelete
* ProcessReplace
* ProcessGet
* ProcessList
* ProcessLog
* ProcessWatch

### ProcessCreate

主要逻辑如下:

1. 创建`Process`数据结构
2. 调用`ProcessManager.registerProcess()`进行注册, 注册的主要工作是分配监听端口号，以及设置与`ProcessManager`的通信通道`processUpdateCh`。分配端口号是根据传入的端口范围，找到一段连续的空闲端口。
3. 发送创建消息给`processUpdateCh`并调用`Process.start()`启动进程。
4. 启动进程的主要逻辑如下:

    a. 创建一个`Executor`
    
    b. 创建一个goroutine，并在其中执行executor.run()，通过`engine-binaries`启动engine进程
    
    c. 创建一个goroutine，启动healthChecker，轮循探测`engine`进和的监听端口是否通信正常，正常则返回启动成功。
    
### ProcessDelete

与创建相反，先停止`engine`进程，再向`ProcessManager`解除注册。

### ProcessReplace

基本过程是创建+删除，如下

1. 按创建的步骤，先创建一个新的`engine`进程并启动
2. 监听30s，直到新的进程启动完成
3. 向旧的进程发起`SIGHUP`，中断，并修改pm等数据结构。

### ProcessLog

这是`stream`类型的grpc调用，它会保持连接，不断读取engine的log，并返回给调用方

### ProcessWatch

这是`stream`类型的grpc调用，它会保持连接，并订阅`broadcaster`，不断把接收到的process的消息转发给调用方


