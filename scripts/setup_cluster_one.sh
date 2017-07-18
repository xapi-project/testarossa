#!/bin/bash
set -x
set -e

CLUSTER_NAME=cluster
NODE=$(uname -n)

echo "Authenticating whole cluster"
# This should be done by XAPI and incrementally
ALL=$(cut -f2 -d' ' /etc/hosts|grep ^cluster)
pcs cluster auth -u hacluster -p mysecurepassword $ALL

echo "Cluster setup on $NODE"
echo "======================"

# Set up the cluster with one node only
pcs cluster setup --name $CLUSTER_NAME $NODE --auto_tie_breaker=1

# Enable sbd in watchdog mode only (no shared block device needed) with default 5 seconds watchdog timeout and 10 seconds stonith-watchdog-timeout.
pcs stonith sbd enable

echo "Cluster start on $NODE"
echo "======================"
# Start the cluster on this node
pcs cluster start

echo "Configure cluster resources on $NODE"
echo "===================================="
pcs property set stonith-watchdog-timeout=10s

# Set no-quorum-policy=freeze as recommended from GFS2 user manual
pcs property set no-quorum-policy=freeze

# Configure resources: DLM and XAPI master election
pcs resource create dlm ocf:pacemaker:controld op monitor interval=30s on-fail=fence clone interleave=true ordered=true
pcs resource create xapi_master_slave ocf:pacemaker:Stateful --master meta resource-stickiness=100 requires=quorum multiple-active=stop_start
mkfs.gfs2 -O -t cluster:gfs2_demo -p lock_dlm -j 16 /dev/disk/by-path/ip-169*-0
mount -t gfs2 -o noatime,nodiratime /dev/disk/by-path/ip-169*-0 /mnt
