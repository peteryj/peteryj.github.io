---
layout: post
title: kata-container下privileged的问题
date: 2020-8-24 09:25
comments: true
author: Peter.Y
categories: kata kubernetes docker
---

* content
{:toc}

# Intro

本文介绍`kata-container`并解决其在`Privileged` + `dev mapping` 场景下的问题。

# Privileged + device mapping

在试验中，发现当容器启动参数加上`privileged`和设备映射时，会失败。

经过调查，发现kataContainer的确对`Privileged`的支持不是太好。原因也很明确，因为与其增加安全性的设计理念是相背的。

在技术细节方面，主要是kata不能支持透传所有的`/dev`, 而`Privileged`模式默认会透传所有的`/dev`，当容器发现有一些设备不存在时，就会启动失败。

具体的讨论细节和故事参考这里，解决思路就是增加一个filter list，以指定具体想透传哪些设备。

* [https://github.com/kata-containers/runtime/issues/1568](https://github.com/kata-containers/runtime/issues/1568)
* [https://github.com/containerd/cri/issues/1213](https://github.com/containerd/cri/issues/1213)

