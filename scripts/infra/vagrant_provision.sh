#!/bin/bash

set -e
set -x

yum clean all
# NB LVM is only here because there was a problem
# upgrading device-mapper without explicitly upgrading
# lvm2. A transient problem, probably, so worth taking
# out later
yum install -y lvm2 targetcli python-rtslib nfs-utils
modprobe target_core_mod
modprobe iscsi_target_mod
mkdir -p /var/target/pr/ /nfs
/scripts/add_lun.py
/scripts/unset_acls.py
chmod 777 /nfs
systemctl enable rpcbind
systemctl enable nfs-server
#systemctl enable nfs-lock
#systemctl enable nfs-idmap
systemctl start rpcbind
systemctl start nfs-server
#systemctl start nfs-lock
#systemctl start nfs-idmap
echo '/nfs *(rw,no_root_squash,no_all_squash)' > /etc/exports
systemctl restart nfs-server


