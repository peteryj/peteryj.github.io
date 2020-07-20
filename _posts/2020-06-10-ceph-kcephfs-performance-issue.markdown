---
layout: post
title: ceph kcephfs 性能问题
date: 2020-6-10 14:11
comments: true
author: Peter.Y
categories: ceph kcephfs linux 
---

* content
{:toc}

# Intro

本文主要讨论 cephfs kernel client (以下简称kcephfs) 的性能问题。

在我们的测试中，发现顺序IO场景下，不能打满client端的10GB网卡，并且相比`nfs-ganesha+libcephfs`的方案，吞吐相差1倍。
而在随机IO场景中，`kcephfs` 的表现要好于`nfs-ganesha+libcephfs`。

本文中使用到的环境如下:

* 服务端: 
  * ceph v14.2.9
  * 3台物理机，每台40core CPU, OSD对应磁盘为 SATA SSD S4510 x4

* 客户端: centos 7.6, kernel 3.10.0-1127.8.2.el7
  * 一台物理机，40core CPU，10G网络 
  * 客户端部署有 `kcephfs` 挂载和 `nfs kernel client + nfs-ganesha + libcephfs` 挂载
  * 客户端到服务端各服务器网络时延1.5~2ms

使用的性能测试工具:

* fio: v3.7

使用的测试命令

~~~
# fio -group_reporting -iodepth 64 -thread -ioengine=libaio \
  -direct=1 \ 
  -rw=read \ # 随机读写为andread, randwrite
  -bs=4M \ # 随机读写为4K
  -size=10G \
  -runtime=120 \
  -name=perf_test \
  -filename=<kcephfs mount path file> 
~~~

# 性能对比

本文对比的是 `kcephfs` 与 `nfs-ganesha+libcephfs` 这两种方案的性能。

在客户端分别挂载这两种文件存储，使用fio工具分别进行测试。

# 测试结论

## 顺序读写

`kcephfs` 吞吐大约为 600MB/s
`nfs-ganesha+libcephfs` 吞吐大约为 1.3GB/s，达到客户端网络瓶颈。

## 随机读写

`kcephfs` IOPS为32k

`nfs-ganesha+libcephfs` IOPS为13k


# `kcephfs` 顺序性能问题分析

这里分析下为什么 `kcephfs` 无法达到客户端网络上限，瓶颈在哪里。

重新跑一遍测试，通过`top`发现，`kcephfs`下，cpu.sys只占到单核的25%，而`nfs-ganesha+libcephfs`占到近300%。怀疑是代码导致性能问题。

搜索了下，查到一些文章也说`kcephfs`的实现有性能问题，不过对应版本都不太一致。还是自己分析下比较靠谱。

## `kcephfs` 代码分析

首先看下对应版本的kcephfs相关代码片断，主要在 `fs/ceph/file.c` 中

以 `aio_read` 为例进行分析

~~~c

const struct file_operations ceph_file_fops = {
        .open = ceph_open,
        .release = ceph_release,
        .llseek = ceph_llseek,
        .read = do_sync_read,
        .write = do_sync_write,
        .aio_read = ceph_aio_read, // ceph aio read 
        .aio_write = ceph_aio_write,
        .mmap = ceph_mmap,
        .fsync = ceph_fsync,
        .lock = ceph_lock,
        .flock = ceph_flock,
        .splice_read = ceph_file_splice_read,
        .splice_write = ceph_file_splice_write,
        .unlocked_ioctl = ceph_ioctl,
        .compat_ioctl   = ceph_ioctl,
        .fallocate      = ceph_fallocate,
};

...

/*
 * Wrap generic_file_aio_read with checks for cap bits on the inode.
 * Atomically grab references, so that those bits are not released
 * back to the MDS mid-read.
 *
 * Hmm, the sync read case isn't actually async... should it be?
 */
static ssize_t ceph_aio_read(struct kiocb *iocb, const struct iovec *iov,
                             unsigned long nr_segs, loff_t pos)
{
        ...
        if ((got & (CEPH_CAP_FILE_CACHE|CEPH_CAP_FILE_LAZYIO)) == 0 ||
            (filp->f_flags & O_DIRECT) || (fi->flags & CEPH_F_SYNC)) {
                dout("aio_sync_read %p %llx.%llx %llu~%u got cap refs on %s\n",
                     inode, ceph_vinop(inode), iocb->ki_pos, (unsigned)len,
                     ceph_cap_string(got));

                if (!read) {
                        ret = generic_segment_checks(iov, &nr_segs,
                                                        &len, VERIFY_WRITE);
                        if (ret)
                                goto out;
                }

                iov_iter_init(&i, iov, nr_segs, len, read);

                if (ci->i_inline_version == CEPH_INLINE_NONE) {
                        if (!retry_op && (filp->f_flags & O_DIRECT)) {
                                ret = ceph_direct_read_write(iocb, &i,
                                                             NULL, NULL); // 异步IO函数
                                if (ret >= 0 && ret < len)
                                        retry_op = CHECK_EOF;
                        } else {
                                ret = ceph_sync_read(iocb, &i, &retry_op);
                        }
                } else {
                        retry_op = READ_INLINE;
                }
        ...
}

...

static ssize_t
ceph_direct_read_write(struct kiocb *iocb, struct iov_iter *iter,
                       struct ceph_snap_context *snapc,
                       struct ceph_cap_flush **pcf)
{
    ...
            ret = ceph_osdc_start_request(req->r_osdc, req, false);//正常返回0
            if (!ret)
                ret = ceph_osdc_wait_request(&fsc->client->osdc, req);//阻寒，等待osdc调用返回

    ...
}

~~~

从上面代码可以看到，`kcephfs` 在 `aio_read` 的实现中使用了同步IO。

参考 [IO解惑: cephfs、libaio与io瓶颈](https://www.jianshu.com/p/f2be49f31aef) 可知，libaio是基于批量提交`aio_read`来实现的，`kcephfs`的实现使得`aio_read`由异步变同步，导致了性能下降，进而影响了整体吞吐。

`aio_write` 与 `aio_read` 类似，都调用到了 `ceph_direct_read_write` 函数来实现核心逻辑，因此存在一样的问题。这里就不展开了。

## `nfs-ganesha+libcephfs` 代码分析

作为对比，我们看下 `nfs-ganesha+libcephfs` 是怎么实现的。仍然以`aio_read`为例

首先看下nfs kernel client的主要代码逻辑，位于`fs/nfs`路径下

~~~c

# ...fs/nfs/file.c

ssize_t
nfs_file_read(struct kiocb *iocb, const struct iovec *iov,
                unsigned long nr_segs, loff_t pos)
{
        struct inode *inode = file_inode(iocb->ki_filp);
        ssize_t result;

        if (iocb->ki_filp->f_flags & O_DIRECT)
                return nfs_file_direct_read(iocb, iov, nr_segs, pos, true);

        dprintk("NFS: read(%pD2, %lu@%lu)\n",
                iocb->ki_filp,
                (unsigned long) iov_length(iov, nr_segs), (unsigned long) pos);

        result = nfs_revalidate_mapping_protected(inode, iocb->ki_filp->f_mapping);
        if (!result) {
                result = generic_file_aio_read(iocb, iov, nr_segs, pos);
                if (result > 0)
                        nfs_add_stats(inode, NFSIOS_NORMALREADBYTES, result);
        }
        return result;
}

# ...fs/nfs/direct.c

/**
 * nfs_file_direct_read - file direct read operation for NFS files
 * @iocb: target I/O control block
 * @iov: vector of user buffers into which to read data
 * @nr_segs: size of iov vector
 * @pos: byte offset in file where reading starts
 *
 * We use this function for direct reads instead of calling
 * generic_file_aio_read() in order to avoid gfar's check to see if
 * the request starts before the end of the file.  For that check
 * to work, we must generate a GETATTR before each direct read, and
 * even then there is a window between the GETATTR and the subsequent
 * READ where the file size could change.  Our preference is simply
 * to do all reads the application wants, and the server will take
 * care of managing the end of file boundary.
 *
 * This function also eliminates unnecessarily updating the file's
 * atime locally, as the NFS server sets the file's atime, and this
 * client must read the updated atime from the server back into its
 * cache.
 */
ssize_t nfs_file_direct_read(struct kiocb *iocb, const struct iovec *iov,
                                unsigned long nr_segs, loff_t pos, bool uio)
{
    ...
    NFS_I(inode)->read_io += iov_length(iov, nr_segs);
    result = nfs_direct_read_schedule_iovec(dreq, iov, nr_segs, pos, uio); // 将请求加入调度队列即返回，符合aio思路
    ...
}

~~~

再来看下 `nfs-ganesha` 关于 `aio_read` 处理逻辑的部分，位于 `src/FSAL/FSAL_CEPH/handle.c` 中

~~~c
/**
 * @brief Read data from a file
 *
 * This function reads data from the given file. The FSAL must be able to
 * perform the read whether a state is presented or not. This function also
 * is expected to handle properly bypassing or not share reservations.  This is
 * an (optionally) asynchronous call.  When the I/O is complete, the done
 * callback is called with the results.
 *
 * @param[in]     obj_hdl       File on which to operate
 * @param[in]     bypass        If state doesn't indicate a share reservation,
 *                              bypass any deny read
 * @param[in,out] done_cb       Callback to call when I/O is done
 * @param[in,out] read_arg      Info about read, passed back in callback
 * @param[in,out] caller_arg    Opaque arg from the caller for callback
 *
 * @return Nothing; results are in callback
 */

static void ceph_fsal_read2(struct fsal_obj_handle *obj_hdl, bool bypass,
                            fsal_async_cb done_cb, struct fsal_io_arg *read_arg,
                            void *caller_arg)
{
    ...
            for (i = 0; i < read_arg->iov_count; i++) {
                nb_read = ceph_ll_read(export->cmount, my_fd, offset, // 同步向后端cephfs发请求
                                       read_arg->iov[i].iov_len,
                                       read_arg->iov[i].iov_base);

                if (nb_read == 0) {
                        read_arg->end_of_file = true;
                        break;
                } else if (nb_read < 0) {
                        status = ceph2fsal_error(nb_read);
                        goto out;
                }

                read_arg->io_amount += nb_read;
                offset += nb_read;
        }

    ...
    done_cb(obj_hdl, status, read_arg, caller_arg); // 处理完成，进行回调

}

~~~

继续追到 `ceph` 里

~~~c

# src/libcephfs.cc

extern "C" int ceph_ll_read(class ceph_mount_info *cmount, Fh* filehandle,
                            int64_t off, uint64_t len, char* buf)
{
  bufferlist bl;
  int r = 0;

  r = cmount->get_client()->ll_read(filehandle, off, len, &bl);
  if (r >= 0)
    {
      bl.copy(0, bl.length(), buf);
      r = bl.length();
    }
  return r;
}

...

# client/Client.cc

// 这里不展开了，有兴趣可以查代码。这里看到对DIRECT_IO，是按同步的方式处理的。

~~~

从上面可以看到，nfs-ganesha向后端cephfs提交的是同步IO。nfs的吞吐，是靠 nfs kernel client 的异步IO来实现的。

# 两种方案随机读写性能分析

从上面的分析可以看出，对于大块IO来说，是否异步对吞吐影响较大。那么对于随机小IO呢？

当单个IO比较小，单IO开销相对降低时，异步IO与同步IO在耗时占比上基本一致。这个时候的随机IO性能，取决于2个因素，1是单个IIO的RTT，2是服务端的并发处理能力。

在我们的对比中，第2点是一致的。因此，主要对比的就是第一点。而第一点是显而易见的，因为`nfs-ganesha+libcephfs`方案下，数据路径相比`kcephfs`更长，RTT更高，因此随机性能会差一些。

# 参考材料

* [CephFS Kernel CLient Throughput Limitation](http://blog.wjin.org/posts/cephfs-kernel-client-throughput-limitation.html)
* [IO解惑: cephfs、libaio与io瓶颈](https://www.jianshu.com/p/f2be49f31aef)

