---
layout: post
title: ceph rgw 文件读取过程代码分析
date: 2020-8-9 09:25
comments: true
author: Peter.Y
categories: ceph rgw
---

* content
{:toc}

# Intro

本文记录ceph rgw 大文件请求部分的代码走读，主要看swift逻辑部分，frontend使用`civetweb`。

# 主体框架

rgw_process.cc 是主要入口

下一层是rgw_op.cc，这一层还没有细分s3和swift

# Get请求

主要分为

* 初始化各种参数

* 根据请求类型获取handler

* 检验请求合法性

* 处理请求，这一步又细分为

    1. 初始化请求
    2. 计算rados层地址
    3. 读取权限信息
    4. 初始化请求
    5. 验证请求权限
    6. 验证请求参数
    7. 预执行
    8. 执行
    9. 完成请求处理


主要逻辑在`执行`部分，相关代码为`rgw_op.cc:1641 RGWGetObj:execute()`，下面来重点分析

# RGWGetObj:execute()

在Get请求中，也分为以下几步

1. 创建RGWRados层对象和数据
2. get_params(): 从http request中读取数据，如header等，初始化为get op的参数。有一个特殊逻辑，如果请求的参数中`multipart-manifest`为空，则标记`skip_manifest=true`，后续会跳过`user.rgw.manifest`处理逻辑。
3. 创建读请求操作实例，`RGWRados::Object::Read read_op`，并从rados层读取omap, xattrs等元数据信息。
4. 根据不同元数据参数，进行不同逻辑处理，包括`gettorrent`, `user_manifest`, `slo_manifest`, `manifest`, 以及range到底层数据映射的处理
5. 调用`read_po.iterate()`进行实际读取数据

## RGWGetObj::handle_slo_manifest()

这个函数处理`user.rgw.slo_manifest`中的内容。大致分为以下几步

1. 从入参的数据中读取，并生成`RGWSLOInfo slo_info`数据结构。
2. 该数据中包括slo parts，所有的分片信息，轮循读取信息，包括每个part对应的bucket, acl, policy等信息，组织为`rgw_slo_part`结构，并将其存放到`slo_parts`列表中。
3. 根据所有分片的`etag`信息，生成整个rgw_obj的md5作为etag。
4. 根据range计算出底层位置offset和length。
5. 调用`iterate_slo_parts()`函数开始处理每个slo分片的读取逻辑，其中针对`user_manifest`，在每个分片上使用回调函数`get_obj_user_manifest_iterate_cb()`来进行处理。

## rgw_op.cc:iterate_slo_parts()

这个函数是个静态局部函数。主要逻辑如下

1. 生成itertor，并根据ofs调整至合适的start位置
2. 轮循terator，对于swiftSLO的第一个分片，调用传入的回调函数。

下面看看回调函数`get_obj_user_manifest_iterate_cb()`，主要逻辑如下。

1. 调用RGWGetObj::read_user_manifest_part()，主调用逻辑都在该函数内。
2. 创建分片读取操作对象`RGWRados::Object::Read read_op`，以准备后续调用。
3. 从attrs中读取出`policy`信息到`obj_policy`。
4. 调用`verify_object_permission()`，以验证操作是否有权限。
5. 权限验证通过后，通过`read_op.iterate()`开始读取整个对象。

## RGWRados::Object::Read::iterate()

该函数是读对象时的总入口函数。主要逻辑如下

1. 根据传入的对象信息，判断是个普通对象还是一个大文件对象，通过`manifest`属性进行判断。对于大文件对象，其`manifest`中存储了多个分片(即`part`)的地址。
2. 如果是大文件对象，按 `object -> parts -> striped` 的3层逻辑迭代读取，并在读取过程中通过回调将结果返回给客户端。
3. 如果是普通文件对象，直接按`object -> striped` 的2层逻辑读取，并在读取过程中通过回调将结果返回给客户端。

每个`stripe`读取完成后，会触发一次调用`RGWRados::flush_read_list()`，该函数会检查所有已完成rados读取的strip，依次调用`client_cb->handle_data()`把`http body`数据发回客户端。

# http body读取逻辑处理

http请求处理过程通常都会设计为链式流程，ceph也是如此。本节关注body数据读取完成后的请求处理链。实际上这个链条在请求处理前就完成了。相关函数是`RGWCivetWebFrontend::process()`，包括如下几个串行处理流程。

~~~
* reordering
* buffering
* chunking
* conlen_controlling
* civetweb
~~~

这样设计有什么好处呢？我理解有两点

1. 扩展方便

从设计模式角度看，链式处理后续要扩展增加新的处理逻辑是方便的

2. 结合分片+异步IO性能优

从上面分析可知，大文件会被切分为4MB的分片进行读取。使用链式处理，配合AIO，使整个流程非常清晰明了。


