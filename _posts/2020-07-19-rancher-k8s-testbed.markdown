---
layout: post
title: 基于Rancher+Vagrant+libvirt搭建kubernetes集群 
date: 2020-7-19 14:11
comments: true
author: Peter.Y
categories: rancher kubernetes vagrant linux 
---

* content
{:toc}

# Intro

本文主要记录使用`Rancher`快速搭建一个k8s集群的方法，便于后续继续研究k8s或者用于持续集成的自动化测试环节。

# Rancher

Rancher是面向kubernetes的跨云多集群管理方案，既支持管理私有云kubernetes集群，也支持管理基于公有云创建的kubernetes集群，如AWS, Azure等。

> 有关Rancher的详细信息可以查看[官方网站](https://www.rancher.cn/)。

`Rancher`主要由`Rancher Server`、`Cluster Agent`与`Node Agent`三部分组成。如下图

![rancher_arch](https://rancher2.docs.rancher.cn/img/rancher/rancher-architecture-cluster-controller.svg)

所有组件都运行在容器中。

`Rancher Server`全局唯一，生产环境中需要做HA部署，方法[文档](https://rancher2.docs.rancher.cn/docs/installation/k8s-install/_index/)中有，这里不展开。

我们主要目标在于研究k8s，因此使用单节点容器部署，存储也使用容器内etcd空间。命令如下

~~~
# sudo docker run -d --restart=unless-stopped \
    -p 80:80 -p 443:443 \
    rancher/rancher:latest
~~~

启动完之后，可以通过如下地址在浏览器访问

~~~
https://<rancher_server_ip>
~~~

第一次登录需要设定帐号、密码、访问域名等。

为了后续的自动化步骤，我们还需要创建API使用的token。方法如下:

* 点击右上角用户，通过`API&Key`生成新的token，记录好，备用。

## API

`Rancher`支持丰富的API系统来操作，具体参考[API文档](https://rancher2.docs.rancher.cn/docs/api/api-custom-cluster/_index)。

主要分为`创建集群`，`生成节点注册命令`，`获取注册命令`这三步。可以写个整合脚本简化步骤。

脚本里最主要的是集群模板那部分

## cluster模板

实际上`Rancher`可以基于页面配置模板，然后基于模板选择集群。我们这里使用API，所以直接在参数中定义好集群模板即可。模板以yaml描述，大致如下

~~~ymal
#
## Cluster Config
#
docker_root_dir: /var/lib/docker
enable_cluster_alerting: false
enable_cluster_monitoring: false
enable_network_policy: false
local_cluster_auth_endpoint:
  enabled: true
#
## Rancher Config
#
rancher_kubernetes_engine_config: # Your RKE template config goes here.
  addon_job_timeout: 30
  authentication:
    strategy: x509
  ignore_docker_version: true
  #
  ## # Currently only nginx ingress provider is supported.
  ## # To disable ingress controller, set `provider: none`
  ## # To enable ingress on specific nodes, use the node_selector, eg:
  ##    provider: nginx
  ##    node_selector:
  ##      app: ingress
  #
  ingress:
    provider: nginx
  kubernetes_version: v1.15.3-rancher3-1
  monitoring:
    provider: metrics-server
  #
  ##   If you are using calico on AWS
  #
  ##    network:
  ##      plugin: calico
  ##      calico_network_provider:
  ##        cloud_provider: aws
  #
  ## # To specify flannel interface
  #
  ##    network:
  ##      plugin: flannel
  ##      flannel_network_provider:
  ##      iface: eth1
  #
  ## # To specify flannel interface for canal plugin
  #
  ##    network:
  ##      plugin: canal
  ##      canal_network_provider:
  ##        iface: eth1
  #
  network:
    options:
      flannel_backend_type: vxlan
    plugin: canal

  # private docker registry
  private_registries:
    - is_default: true
      url: <private registry>
      user: <user name>
      password: <password>
  #
  ##    services:
  ##      kube-api:
  ##        service_cluster_ip_range: 10.43.0.0/16
  ##      kube-controller:
  ##        cluster_cidr: 10.42.0.0/16
  ##        service_cluster_ip_range: 10.43.0.0/16
  ##      kubelet:
  ##        cluster_domain: cluster.local
  ##        cluster_dns_server: 10.43.0.10
  #
  services:
    etcd:
      backup_config:
        enabled: true
        interval_hours: 12
        retention: 6
        safe_timestamp: false
      creation: 12h
      extra_args:
        election-timeout: 5000
        heartbeat-interval: 500
      gid: 0
      retention: 72h
      snapshot: false
      uid: 0
    kube_api:
      always_pull_images: false
      pod_security_policy: false
      service_node_port_range: 30000-32767
    kubelet:
      extra_binds:
        - '/var/openebs/local:/var/openebs/local'
      fail_swap_on: false
      generate_serving_certificate: false
  ssh_agent_auth: false
windows_prefered_cluster: false
~~~

具体解释见[文档](https://rancher2.docs.rancher.cn/docs/cluster-provisioning/rke-clusters/options/_index)

# vagrant

vagrant是轻量级的虚拟机管理平台，可以支持`virtualbox`、`qemu/kvm`、`xen`等多种hypervisor。详见[官方文档](https://www.vagrantup.com/)

本文中基于`qemu/kvm`。安装脚本如下

~~~bash
#!/usr/bin/bash

yum install -y python-pip
yum install -y libxslt-devel libxml2-devel libvirt-devel libguestfs-tools-c ruby-devel gcc libvirt
yum install -y ruby

# install vagrant
yum install -y vagrant

# install libvirt support
vagrant plugin install vagrant-libvirt


# config and enable libvirtd
# change default storage path
sed -i 's,/var/lib/libvirt/images,/data/libvirt/images,g' /etc/libvirt/storage/default.xml

mkdir -p /data2/libvirt/images
virsh pool-destroy default
virsh pool-create --file /etc/libvirt/storage/pool.xml

# enable libvirtd
systemctl enable libvirtd
systemctl start libvirtd

# install centos box
vagrant box add --name xxxx <xx url>


~~~

## Vagrantfile

vagrant基于`Vagrantfile`来描述虚机配置以及初始化过程。其基本格式如下

~~~ruby
# -*- mode: ruby -*-
# vi: set ft=ruby :

require 'yaml'

VAGRANTFILE_API_VERSION = '2'

# we could load settings from yaml file to make it easier to configure
config_file=File.expand_path(File.join(File.dirname(__FILE__), 'vagrant_variables.yml'))
settings=YAML.load_file(config_file)

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  config.vm.box = BOX
  config.vm.box_url = BOX_URL
  config.ssh.insert_key = false # workaround for https://github.com/mitchellh/vagrant/issues/5048
  config.ssh.private_key_path = settings['ssh_private_key_path']
  config.ssh.username = 'root'
  
  $first_run = <<-SCRIPT
  echo "do something when vm first bootup..."
  SCRIPT

  
  # first run script
  config.vm.provision "shell", inline: $first_run
  # first run script end

  # When using libvirt, avoid errors like:
  # "host doesn't support requested feature: CPUID.01H:EDX.ds [bit 21]"
  config.vm.provider :libvirt do |l|
    l.memory = 4096
    l.cpus = 4
    l.cpu_mode = 'host-passthrough'
    l.volume_cache = 'unsafe'
    l.graphics_type = 'none'
  end
end
~~~

# 整合

有了`vagrant`和`Rancher`这两个工具，我们可以编写脚本来自动化创建整个系统了。初步思路如下

1. 使用vagrant创建好一组需要的虚拟机
2. 使用Rancher API创建集群，并生成节点注册脚本，再使用`ansible`在各节点上运行适合的注册命令，即一部分创建为`controller`，一部分创建为`worker`。

脚本这里就不贴了，参考上述内容可以很容易写出来。

# 实际应用

使用该脚本，可以在15分钟建立一个12节点的Rancher管控的k8s集群，基本满足后续研究需求。

# 参考文献

* [Rancher](https://rancher2.docs.rancher.cn/)
* [Vagrant](https://www.vagrantup.com/)
* [Kubernetes](https://kubernetes.io/)
