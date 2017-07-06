#!/bin/bash
set -x
set -e

# workaround NilClass exception
vagrant up infrastructure || vagrant up infrastructure

HOSTS=$(vagrant status |  grep ^cluster |cut -f1 -d' '|xargs echo)
vagrant up $HOSTS
echo $HOSTS

echo "Cluster auth"
echo "============"
vagrant ssh cluster1 -c "sudo pcs cluster auth -u hacluster -p mysecurepassword $HOSTS"

echo "Cluster setup"
echo "============="

vagrant ssh cluster1 -c "sudo pcs cluster setup --name cluster $HOSTS"
vagrant ssh cluster1 -c "sudo pcs stonith sbd enable"

echo "Cluster start"
echo "============="

vagrant ssh cluster1 -c "sudo pcs cluster enable --all"
vagrant ssh cluster1 -c "sudo pcs cluster start --all"
vagrant ssh cluster1 -c "sudo pcs property set no-quorum-policy=freeze"
vagrant ssh cluster1 -c "sudo pcs resource create dlm ocf:pacemaker:controld op monitor interval=30s on-fail=fence clone interleave=true ordered=true"
