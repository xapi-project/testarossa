#!/bin/bash
set -x
set -e

ISCSI_IP=169.254.0.16  # TODO pass this in
GFS2_JOURNALS=4  # 16?

CLUSTER_NAME=xapi-cluster
NODE=$(uname -n)

#IP_ADDRS=$(ip addr | fgrep inet | grep -v ' lo$' | awk '{print $2}' | sed 's/\/[0-9]*$//')
IP_ADDRS=$(ip addr | fgrep inet | grep ' eth1$' | awk '{print $2}' | sed 's/\/[0-9]*$//')  # TODO only use eth1 until corosync config can cope with more interfaces

echo "Cluster setup on $NODE"
echo "======================"

# Set up the cluster with one node only
ADDRS=$(echo $IP_ADDRS | sed 's/ /","/g')
secret=$(/opt/xcli create '{"hostname":"'$NODE'","addresses":["'$ADDRS'"]}')

echo "Configure cluster resources on $NODE"
echo "===================================="
DEV=/dev/disk/by-path/ip-$ISCSI_IP:3260-*-0
mkfs.gfs2 -O -t $CLUSTER_NAME:gfs2_demo -p lock_dlm -j $GFS2_JOURNALS $DEV
mount -t gfs2 -o noatime,nodiratime $DEV /mnt

# Return the secret
echo $secret
