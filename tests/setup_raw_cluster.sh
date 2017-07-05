#!/bin/bash
set -x
set -e

# workaround NilClass exception
vagrant up infrastructure || vagrant up infrastructure

HOSTS=$(vagrant status |  grep ^cluster |cut -f1 -d' '|xargs echo)
vagrant up $HOSTS
echo $HOSTS
# vagrant rsync $HOSTS

echo "Cluster auth"
echo "============"
vagrant ssh cluster1 -c "sudo pcs cluster auth -u hacluster -p mysecurepassword $HOSTS"


for host in $HOSTS; do
    vagrant ssh $host -c "sudo /scripts/setup_raw $HOSTS"
done


echo "Updating cluster properties"
echo "==========================="
vagrant ssh cluster1 -c "\
sudo cibadmin --replace -o resources --xml-pipe </scripts/raw/cib_resources.xml &&\
sudo cibadmin --replace -o crm_config --xml-pipe </scripts/raw/cib_crm_config.xml"

echo "Enabling SBD"
vagrant ssh cluster1 -c "sudo pcs cluster stop --all"
vagrant ssh cluster1 -c "sudo pcs stonith sbd enable"
vagrant ssh cluster1 -c "sudo pcs cluster start --all"

vagrant ssh cluster1 -c "\
sudo dlm_tool status; \
sudo corosync-quorumtool; \
sudo crm_mon -1"
