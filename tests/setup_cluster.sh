#!/bin/bash
set -x
set -e

vagrant up infrastructure

HOSTS=$(vagrant status |  grep ^cluster |cut -f1 -d' '|xargs echo)
vagrant up $HOSTS
echo $HOSTS

echo "Cluster auth"
echo "============"
vagrant ssh cluster1 -c "sudo pcs cluster auth -u hacluster -p mysecurepassword $HOSTS"

echo "Cluster setup"
echo "============="

vagrant ssh cluster1 -c "sudo pcs cluster setup --name cluster $HOSTS --auto_tie_breaker=1"
vagrant ssh cluster1 -c "sudo pcs stonith sbd enable"

echo "Cluster start"
echo "============="

vagrant ssh cluster1 -c "sudo pcs cluster enable --all" || true
vagrant ssh cluster1 -c "sudo pcs cluster start --all"
vagrant ssh cluster1 -c "sudo pcs property set no-quorum-policy=freeze"
vagrant ssh cluster1 -c "sudo pcs resource create dlm ocf:pacemaker:controld op monitor interval=30s on-fail=fence clone interleave=true ordered=true"
vagrant ssh cluster1 -c "sudo pcs property set stonith-watchdog-timeout=10s"
vagrant ssh cluster1 -c "sudo pcs resource create xapi_master_slave ocf:pacemaker:Stateful --master meta resource-stickiness=100 requires=quorum multiple-active=stop_start"
vagrant ssh cluster1 -c "sudo pcs resource create xapi_unique_master ocf:pacemaker:Stateful meta resource-stickiness=100 requires=quorum multiple-active=stop_start"
while ! vagrant ssh cluster1 -c "sudo crm_mon -1" | grep Masters; do
    echo retrying
done
vagrant ssh cluster1 -c "sudo mkfs.gfs2 -O -t cluster:gfs2_demo -p lock_dlm -j 3 /dev/disk/by-path/ip-169*-0"
for h in $HOSTS; do
    vagrant ssh $h -c "sudo mount -t gfs2 -o noatime,nodiratime /dev/disk/by-path/ip-169*-0 /mnt"
done
