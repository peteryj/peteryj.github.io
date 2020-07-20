---
layout: post
title: Ceph 开发环境建立
date: 2020-2-21 22:30
comments: true
author: Peter.Y
categories: Ceph
---

* content
{:toc}

# Intro
本文主要讲述luminous版本的dev环境建立实践

# 环境

* 操作系统: >=Centos 7.6

> 仅在公司repo中存在该问题。在官方repo中，由于都指向了最新repo，所以无此问题。

# 安装步骤

以下参考[官方文档](https://docs.ceph.com/docs/luminous/install/build-ceph/)实践，并补充issue解决方案

> 编译过程中需要连接外网，需要编译机器连接外网并且配置好翻墙代理，否则龟速

* step1: ./install_deps.sh

~~~
// 方框表示仅在公司遇到的问题，下同

遇到python34-devel安装失败，原因是公司repo没有正确包含依赖包python-rpm-macros和python-srpm-macros。需要手动安装通过后，再重新启动install_deps.sh
~~~

这一步完成各种依赖安装

* step2: ./do_cmake.sh

这一步进行预编译，生成相关目录并准备配置文件

* step3: cd build && ./make

编译完成后在bin/下

# 运行unit test

* step1: make tests

安装测试依赖工具和环境

* step2: ctest

使用ctest，运行单元测试用例

