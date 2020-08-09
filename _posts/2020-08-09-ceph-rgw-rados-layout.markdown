---
layout: post
title: ceph rados 之 rgw layout分析
date: 2020-8-9 09:25
comments: true
author: Peter.Y
categories: ceph
---

* content
{:toc}

# Intro

本文分析下radosgw(即rgw)是如何使用rados的。


# 总体架构

在一个已经启用了rgw的ceph集群中，通常包括以下几种默认的rados pool，只有一种是集群内唯一的，如下

* `.rgw.root`: 单个集群内唯一，存储该集群下所有rgw 的global信息
其余都是按zone划分的，且pool命名中含有zone名称，如下

* `<zone>.rgw.control`: 内部只有notify.<N>等一系列对象，用于内部异步处理时的通知机制。

* `<zone>.rgw.meta`: 存储<zone>下的metadata，包括user, buckets等，注意这里使用了rados pool的`namespace`机制以隔开不同类型的信息。详见[官方文档](http://docs.ceph.com/docs/master/radosgw/layout/)。

* `<zone>.rgw.buckets.index`: 存储着每个bucket内的rgw object元数据

* `<zone>.rgw.buckets.data`: 存储着每个bucket内的rgw object

从上面可以看出，最重要的是 `.rgw.root`, `<zone>.rgw.buckets.index`, `<zone>.rgw.buckets.data` 这三个pool，下面分别来分析。

# .rgw.root

先看下pool有什么内容

~~~
# rados -p .rgw.root ls|sort
...
zonegroup_info.a905159a-f8b0-4d63-8f19-04845005f0bf
...
zonegroups_names.default
...
zone_info.7d0fc755-5ac1-407e-9c8b-0a325b51224d
...
zone_names.default
~~~

看起来是树状结构，分为2层，如下

~~~
zonegroups_names.<zone>, zone_names.<zone>
zone_info.<uuid>
zonegroups_name.default和zone_names.default的内容都指向其中一个zone_info.<uuid>
~~~

暂不清楚其它的zone_info是否还有作用，看了下内容基本一致，除了uid不同

总体来说，这个pool 存储了zone级别的元数据，大部分情况下不用管它，以后分析multisite时再评估下

# default.rgw.buckets.index

官方文档说明如下：

~~~
It’s a different kind of metadata, and kept separately. The bucket index holds a key-value map in rados objects. By default it is a single rados object per bucket, but it is possible since Hammer to shard that map over multiple rados objects. The map itself is kept in omap, associated with each rados object. The key of each omap is the name of the objects, and the value holds some basic metadata of that object – metadata that shows up when listing the bucket. Also, each omap holds a header, and we keep some bucket accounting metadata in that header (number of objects, total size, etc.).

Note that we also hold other information in the bucket index, and it’s kept in other key namespaces. We can hold the bucket index log there, and for versioned objects there is more information that we keep on other keys.
~~~

大意就是这里存了object的部分metadata信息，主要是在list object时会显示出来的那部分。另外，早期版本单个bucket只用一个`rados object`的`omap`来存储单个bucket的所有`bucket index`，在`Hammer`版本之后，可以使用多个`rados object`来存储一个bucket的`bucket index`，也就是`bucket index`的`sharding`。

为什么使用分片？其实很好理解。因为单个`rados object`在ceph中是最小存储单位，它是放存储到单台机器的单块盘上的(盘下做RAID不算)。这使得单个`bucket`的对象数上限受单盘IO能力限制，存在扩容的架构瓶颈。能够想到的技术很自然就是`sharding`了。

## layout

看下大体的布局，以上面那个对象为例，如下

~~~
# rados -p default.rgw.buckets.index ls
.dir.7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5.0
.dir.7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5.1
...
.dir.7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5.44
.......
~~~

如上所示，rados object按照一定规则创建，规则如下

~~~
.dir.<bucket instance>.<shard number>
~~~

以`.dir.7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5.44`为例

* bucket instance = 7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5
* shard number = 44

这是指bucket的第45个index分片

> 有关分片的含义参考本节开头的解释

下面来分析下单个rados的内容

## 单个index rados object分析

继续以`.dir.7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5.44`为例

~~~
# rados -p default.rgw.buckets.index stat .dir.7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5.44
default.rgw.buckets.index/.dir.7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5.44 mtime 2019-07-08 20:01:36.000000, size 0

// 从上面可以看到，该index rados object内容为空

# rados -p default.rgw.buckets.index listxattr .dir.7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5.44
#

// xattr内容也为空
~~~

可以看到，该对象内即没有内容，也没有xattr属性值，看来`bucket index`只利用了omap来存储信息。

~~~
# rados -p default.rgw.buckets.index listomapkeys .dir.7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5.44
filestore/00/001d57f05bda63c370d5a358751bea2819b5bb42
filestore/00/0029047eb08639a98e4b9437d7cbe81fb0471ba7
...
~~~

可以看到，omap中存储了一些信息。以rgw object path 为key，经过shard后写入对应的index rados object的omap中。我们来分析下其中的内容。

以`filestore/00/001d57f05bda63c370d5a358751bea2819b5bb42`为例

~~~
# rados -p default.rgw.buckets.index getomapval .dir.7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5.44 filestore/00/001d57f05bda63c370d5a358751bea2819b5bb42
value (278 bytes) :
00000000  08 03 10 01 00 00 35 00  00 00 66 69 6c 65 73 74  |......5...filest|
00000010  6f 72 65 2f 30 30 2f 30  30 31 64 35 37 66 30 35  |ore/00/001d57f05|
00000020  62 64 61 36 33 63 33 37  30 64 35 61 33 35 38 37  |bda63c370d5a3587|
00000030  35 31 62 65 61 32 38 31  39 62 35 62 62 34 32 01  |51bea2819b5bb42.|
00000040  00 00 00 00 00 00 00 01  05 03 76 00 00 00 01 00  |..........v.....|
00000050  30 09 00 00 00 00 00 4e  ea 7d 5c 20 7e 66 3b 20  |0......N.}\ ~f; |
00000060  00 00 00 36 61 39 32 30  37 63 62 34 61 38 30 35  |...6a9207cb4a805|
00000070  39 35 39 31 61 36 39 38  65 66 37 65 64 38 38 32  |9591a698ef7ed882|
00000080  36 38 33 05 00 00 00 6a  6a 62 6f 64 0c 00 00 00  |683....jjbod....|
00000090  6a 6a 62 6f 64 20 6f 6e  6c 69 6e 65 18 00 00 00  |jjbod online....|
000000a0  61 70 70 6c 69 63 61 74  69 6f 6e 2f 6f 63 74 65  |application/octe|
000000b0  74 2d 73 74 72 65 61 6d  00 30 09 00 00 00 00 00  |t-stream.0......|
000000c0  00 00 00 00 00 00 00 00  00 00 00 00 01 01 02 00  |................|
000000d0  00 00 05 01 02 2f 00 00  00 37 64 30 66 63 37 35  |...../...7d0fc75|
000000e0  35 2d 35 61 63 31 2d 34  30 37 65 2d 39 63 38 62  |5-5ac1-407e-9c8b|
000000f0  2d 30 61 33 32 35 62 35  31 32 32 34 64 2e 35 34  |-0a325b51224d.54|
00000100  31 30 2e 33 32 38 38 32  00 00 00 00 00 00 00 00  |10.32882........|
00000110  00 00 00 00 00 00                                 |......|
00000116
~~~

大体结构如下：
~~~
byte0~1: 08 03 ：疑似是flag，对比多组数据后得到
byte2~5: 10 01 00 00: 整个value的长度，小端序，这里是0x110
byte6~9: 35 00 00 00: 第一个metadata的长度，这里是53
byte10~62: xxxxxx: 第一个metadata的内容，长度为53个字节

....
~~~

> 后面部分结构感觉不是完全按这个规律走的，或者就是有padding，需要找到代码中的对应数据结构进一步分析

# default.rgw.buckets.data

这部分主要存储的是rgw object数据，先来看下

~~~
# rados -p default.rgw.buckets.data ls | head -2
7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5__shadow_filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b.2~tjuryJHLXegTvCyXDvrfV8jKE_eePjD.1_21
7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5_filestore/20/206955edc002e137962dd5b967f1bb413b441499

// 看到有两种奇怪的格式，分别代表分片上传文件和普通文件这两种，我们分别分析
~~~

## 对象size <= 4MB

这类文件使用一个rados object足够，并使用xattr来存储对象的元数据，示例

~~~
# rados -p default.rgw.buckets.data stat 7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5_filestore/f6/f605fd94765d34d8caa72f93996d74593dff841d
default.rgw.buckets.data/7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5_filestore/f6/f605fd94765d34d8caa72f93996d74593dff841d mtime 2019-03-05 11:35:47.000000, size 1015

# rados -p default.rgw.buckets.data listxattr 7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5_filestore/f6/f605fd94765d34d8caa72f93996d74593dff841d
user.rgw.acl
user.rgw.content_type
user.rgw.etag
user.rgw.idtag
user.rgw.manifest
user.rgw.pg_ver
user.rgw.source_zone
user.rgw.tail_tag
user.rgw.x-amz-content-sha256
user.rgw.x-amz-date
# rados -p default.rgw.buckets.data getxattr 7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5_filestore/f6/f605fd94765d34d8caa72f93996d74593dff841d user.rgw.manifest
[njjbod,7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5,7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.55filestore/f6/f605fd94765d34d8caa72f93996d74593dff841d�@!.NOaBgcV858UDIC2DoGnSxocBAOZRm21_ @@default-placementdefault-placement
# 
# rados -p default.rgw.buckets.data ls|grep NOaBgcV858UDIC2DoGnSxocBAOZRm21
# 
~~~

## 4MB < 对象size <= 100MB(默认的rgw分片大小)

这种情况下，需要多个rados object来存储一个rgw object的内容，示例如下

~~~
# rados -p default.rgw.buckets.data stat 7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5_filestore/e3/e38c7561c599756172dc46bcdf7636bc7d463216
default.rgw.buckets.data/7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5_filestore/e3/e38c7561c599756172dc46bcdf7636bc7d463216 mtime 2019-03-05 11:34:27.000000, size 4194304

# rados -p default.rgw.buckets.data listxattr 7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5_filestore/e3/e38c7561c599756172dc46bcdf7636bc7d463216
user.rgw.acl
user.rgw.content_type
user.rgw.etag
user.rgw.idtag
user.rgw.manifest
user.rgw.pg_ver
user.rgw.source_zone
user.rgw.tail_tag
user.rgw.x-amz-content-sha256
user.rgw.x-amz-date

# rados -p default.rgw.buckets.data getxattr 7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5_filestore/e3/e38c7561c599756172dc46bcdf7636bc7d463216 user.rgw.manifest
[njjbod,7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5,7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.55filestore/e3/e38c7561c599756172dc46bcdf7636bc7d463216@@!.49QE2N5U-NZoCbhaPD6i3EnTi9H4pp8_ @@default-placementdefault-placement
# 

# rados -p default.rgw.buckets.data ls|grep 49QE2N5U-NZoCbhaPD6i3EnTi9H4pp8
7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5__shadow_.49QE2N5U-NZoCbhaPD6i3EnTi9H4pp8_1

# rados -p default.rgw.buckets.data stat 7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5__shadow_.49QE2N5U-NZoCbhaPD6i3EnTi9H4pp8_1
default.rgw.buckets.data/7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5__shadow_.49QE2N5U-NZoCbhaPD6i3EnTi9H4pp8_1 mtime 2019-03-05 11:34:27.000000, size 1134592

# rados -p default.rgw.buckets.data listxattr 7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5__shadow_.49QE2N5U-NZoCbhaPD6i3EnTi9H4pp8_1

# rados -p default.rgw.buckets.data listomapvals 7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5__shadow_.49QE2N5U-NZoCbhaPD6i3EnTi9H4pp8_1


~~~


从上面可以看出，仍以第一个rados对象为入口，在其中的`xattr user.rgw.manifest`中存储shadow对象的object key，并以 `<shadow key>_<N>`的形式命名后续的rados object，且xattr只存储在首个rados对象中。


## 对象size > 100MB(s3默认分片大小)

这种情况下，需要结合上述`对象size <= 100MB`的情况一起来处理，我们直接看示例

~~~

# rados -p default.rgw.buckets.data ls |grep filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b
7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5_filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b
7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5__multipart_filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b.2~tjuryJHLXegTvCyXDvrfV8jKE_eePjD.1
7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5__multipart_filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b.2~tjuryJHLXegTvCyXDvrfV8jKE_eePjD.2
7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5__multipart_filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b.2~tjuryJHLXegTvCyXDvrfV8jKE_eePjD.3
...

// 查看下首对象的信息

# rados -p default.rgw.buckets.data stat 7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5_filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b
default.rgw.buckets.data/7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5_filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b mtime 2019-06-11 07:46:20.000000, size 0
# 
# rados -p default.rgw.buckets.data listxattr 7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5_filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b
user.rgw.acl
user.rgw.content_type
user.rgw.etag
user.rgw.idtag
user.rgw.manifest
user.rgw.pg_ver
user.rgw.source_zone
user.rgw.tail_tag
user.rgw.x-amz-content-sha256
user.rgw.x-amz-meta-md5-hash
# rados -p default.rgw.buckets.data getxattr 7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5_filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b user.rgw.manifest

njjbod,7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5,7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.55filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3bWfilestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b.2~tjuryJHLXegTvCyXDvrfV8jKE_eePjD efault-placement

# 

// 可以看到首对象的metadata中包含了后续子rados object的shadow key信息
# rados -p default.rgw.buckets.data ls |grep filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b| grep multipart


7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5__multipart_filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b.2~tjuryJHLXegTvCyXDvrfV8jKE_eePjD.1
7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5__multipart_filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b.2~tjuryJHLXegTvCyXDvrfV8jKE_eePjD.2
7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5__multipart_filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b.2~tjuryJHLXegTvCyXDvrfV8jKE_eePjD.3

// 其中每个分片中包括了该分片的metadata信息，例如etag值
# rados -p default.rgw.buckets.data listxattr 7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5__multipart_filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b.2~tjuryJHLXegTvCyXDvrfV8jKE_eePjD.1
user.rgw.acl
user.rgw.content_type
user.rgw.etag
user.rgw.pg_ver
user.rgw.source_zone
# 
# rados -p default.rgw.buckets.data getxattr 7d0fc755-5ac1-407e-9c8b-0a325b51224d.15377.5__multipart_filestore/12/12d156586e04b38afba13bb0196a34cf0e858a3b.2~tjuryJHLXegTvCyXDvrfV8jKE_eePjD.1 user.rgw.etag
18cd66e0cbc7ff86ec5029a52e762009
# 

~~~

# 参考资料

* [http://docs.ceph.com/docs/master/radosgw/layout/](http://docs.ceph.com/docs/master/radosgw/layout/)
