#!/bin/bash


# 关闭SELinux
sed -i --follow-symlinks 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
setenforce 0

# 关闭防火墙
systemctl stop firewalld.service
systemctl disable firewalld.service

sleep 2

# 免密登录
ssh-keygen -t rsa
ssh-copy-id root@192.168.252.141
ssh-copy-id root@192.168.252.142
ssh-copy-id root@192.168.252.143
ssh-copy-id root@192.168.252.144
ssh-copy-id root@192.168.252.145
ssh-copy-id root@192.168.252.146

sleep 2 
# 关闭DNS解析
sed -i 's/#UseDNS yes/UseDNS no/g' /etc/ssh/sshd_config

# 安装vim,wget等常用软件
yum install -y vim net-tools psmisc wget lftp unzip bzip2 bash-completion rsync lrzsz

sleep 2
sed -i '/set ruler/a\set tabstop=4' /etc/vimrc

# 更换yum源
cp -a /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.bak
wget -O /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-7.repo
yum clean all
yum repolist
