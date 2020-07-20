---
layout: post
title: ceph-ansible test framework 使用
date: 2020-5-25 14:00
comments: true
author: Peter.Y
categories: ceph ansible pytest 
---

* content
{:toc}

# Intro

本文主要分析 `ceph-ansible` 项目下的tests框架是如何运行的，目标是理解后能够自定义测试用例，实现测试自动化。

该项目主要使用`pytest`以及插件`testinfra`，并配合使用`vagrant`创建多机自动测试环境来实现自动化测试。

# 组件介绍

## pytest

`ceph-ansible` 使用 [pytest](https://docs.pytest.org/) 作为测试框架。不同ceph版本依赖pytest版本有不同，下面都以 `ceph-v14.2.9` 为例进行分析，这个版本使用的pytest版本情况如下。

~~~
# py.test --version
This is pytest version 3.6.1, imported from /usr/lib/python2.7/site-packages/pytest.pyc
setuptools registered plugins:
  testinfra-3.2.0 at /usr/lib/python2.7/site-packages/testinfra/plugin.py
  pytest-forked-1.0.2 at /usr/lib/python2.7/site-packages/pytest_forked/__init__.pyc
  pytest-xdist-1.27.0 at /usr/lib/python2.7/site-packages/xdist/plugin.py
  pytest-xdist-1.27.0 at /usr/lib/python2.7/site-packages/xdist/looponfail.py

~~~

有关测试框架的细节，可以参考[官方文档](https://docs.pytest.org/)。

## testinfra

`testinfra`是`pytest`的插件，它主要用于指定运行的服务器，通常默认是本地服务器，也可以指定远程服务器。

其中远程服务器支持以`Salt`, `Ansible`, `Puppet`等方式来管理。本文以`Ansible`为例，示例如下

~~~
# /usr/bin/py.test -n 8 \                             # 指定8线程并发测试
    --durations=0 \                                   # 展示所有执行慢的测试用例
    --sudo -v \                                    
    --connection=ansible \                            # 指定连接方式使用ansible
    --ansible-inventory={changedir}/{env:INVENTORY} \ # 指定inventory，即待测试的机器列表
    --ssh-config={changedir}/vagrant_ssh_config \     # 指定待连接的机器列表
    {toxinidir}/tests/functional/tests                # 指定测试用例
~~~

其中`vagrant_ssh_config`文件如下

~~~
...
Host osd1
  HostName 192.168.121.58
  User root
  Port 22
  UserKnownHostsFile /dev/null
  StrictHostKeyChecking no
  PasswordAuthentication no
  IdentityFile /root/.vagrant.d/insecure_private_key
  IdentitiesOnly yes
  LogLevel FATAL
...
~~~

> 为了支持多并发，还需要安装`pytest-xdist`，这样可以通过`-n <parallel>`来指定并发数。

`testinfra`的信息是如何传递给`pytest`的呢？通过实现`pytest`的插件接口，`testinfra`实现了`host` fixture，其封装了待测试主机上的很多信息和检测功能。例如

~~~
Host.mount_point # 挂载点相关
Host.package     # package相关
Host.interface   # 网卡信息
Host.sysctl      # 操作系统参数
~~~

详细参考 [官方文档](https://testinfra.readthedocs.io/en/latest/modules.html#host)


以下我们按照`ceph-ansible`中的目录结构分析用到的pytest部分功能，并给出后续扩展思路。

# ceph-ansible 测试框架目录分析

相关目录和文件如下

~~~
# tree -L 2 tests/
tests/
|-- conftest.py
|-- functional
|   `-- tests
|-- library
|   |-- test_ceph_crush.py
|   |-- test_ceph_key.py
|   `-- test_ceph_volume.py
|-- plugins
|   `-- filter
|       `-- test_ipaddrs_in_ranges.py
|-- pytest.ini
`-- requirements.txt
~~~

其中 `requirements.txt` 不用分析，其余的我们来看下。

## pytest.ini

有关`pytest.ini`文件的定义和说明参考[官方文档](https://docs.pytest.org/en/3.6.1/reference.html?highlight=pytest.ini#configuration-options)

主要存放一些默认的配置文件，可以被命令行通过 `-o/--override-ini` 来替代。

`pytest.ini`文件内容如下
~~~
# this is just a placeholder so that we can define what the 'root' of the tests
# dir really is. 
[pytest]
markers =
  dashboard: environment with dashboard enabled
  no_docker: environment without containers
  docker: environment with containers
  all: for all nodes
  iscsigws: for iscsigw nodes
  mdss: for mds nodes
  mgrs: for mgr nodes
  mons: for mon nodes
  nfss: for nfs nodes
  osds: for osd nodes
  rbdmirrors: for rbdmirror nodes
  rgws: for rgw nodes
  grafanas: for grafana nodes

~~~

项目本身没有使用，所有测试用例都是通过自动发现和`conftest.py`来实现的。

## conftest.py

conftest.py的加载是按目录次序进行override的，同级目录优先，找不到再向父目录查找，示例:

~~~
conftest.py
testa/conftest.py
testa/test_a.py
test_root.py

# 当运行test_a.py时，加载testa/conftest.py
~~~

conftest.py主要用于实现了几个fixture，先来看下fixture的说明

> Fixture是以装饰器的方式实现的，可以修饰单个测试用例，测试类或全局。用于构建一些基础设施。

conftest.py主要定义了两个`fixture`

~~~
@pytest.fixture(scope="module")
def setup():
   ...
   
@pytest.fixture()
def node(host, request):
   ...
~~~

`setup` 用于获取全局的配置参数，如osds, mdss等

`node` 用于获取单个执行节点的相关信息

详细内容可以参考相关源码。

## library and plugins

这里保存的是`ceph-ansible`下的`plugin`和`library`下的工具代码的测试用例，此处不详述。

## functional/tests

这个目录下存储主要的测试用例，也是本文关注的重点。

按各个模块划分测试用例如下

~~~
osd
mon
mgr
rbd-mirror
rgw
nfs
iscsi
grafana
~~~

一共有48个测试用例，根据待测试的机器数量N，一共会产生48xN个测试任务，但由于部分测试只能在部分节点生效，所以在实际测试结果中，会看到很多SKIP。示例如下

~~~
============= 5 failed, 152 passed, 743 skipped in 202.16 seconds ==============
ERROR: InvocationError for command /usr/bin/py.test -n 8 --durations=0 --sudo -v --connection=ansible --ansible-inventory=/ceph-ansible/tests/functional/testbed/hosts --ssh-config=/ceph-ansible/tests/functional/testbed/vagrant_ssh_config /ceph-ansible/tests/functional/tests (exited with code 1)

~~~

