#!/usr/bin/python
#
# Builds a cluster of three nodes, then removes all nodes.
# Expects xapi-clusterd to be running on each node.
#

from nose import with_setup
import os
import subprocess
import json
import sys

ssh_config_file="ssh-config"
hosts = ["cluster1", "cluster2", "cluster3", "infrastructure"]

def execute(cmd):
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    stdout = proc.communicate()[0].strip()
    rc = proc.returncode

    # "set -e"
    if rc <> 0:
        print >>sys.stderr, "Command executed with rc %d" % rc
        sys.exit(rc)

    return stdout

def generate_ssh_config():
    cmd = ["vagrant", "ssh-config"]
    cmd.extend(hosts)
    stdout = execute(cmd)
    with open(ssh_config_file, 'w') as f:
        f.write(stdout)

def ssh_cmd(host, cmd):
    if not os.path.exists(ssh_config_file):
        generate_ssh_config()
    ssh = ["ssh", "-F", ssh_config_file, host, "sudo", cmd]
    print " * Executing on %s: %s" % (host, cmd)
    return execute(ssh)

def assert_null(s):
    assert s=='N'

def get_ip(host):
    return ssh_cmd(host, "ip addr show dev eth1 | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/'")

def create_cluster(node):
    print "Create cluster on node %s" % (node['hostname'])

    stdout = ssh_cmd(node['hostname'], "/opt/xcli create '%s'" % (json.dumps(node)))
    if stdout.startswith('['):
        print >>sys.stderr, "CLI command failed"
        sys.exit(1)

    secret = stdout[2:-1]
    print "Secret token was '%s'" % (secret)
    return secret

def join_node(node, secret, existing):
    print "Join node %s to the cluster" % (node['hostname'])
    assert_null(ssh_cmd(node['hostname'], "/opt/xcli join %s '%s' '%s'" % (secret, json.dumps(node), json.dumps(existing))))

def shutdown_node(node):
    print "Shut down node %s" % (node['hostname'])
    assert_null(ssh_cmd(node['hostname'], "/opt/xcli shutdown"))

def destroy_node(node):
    print "Destroy node %s" % (node['hostname'])
    assert_null(ssh_cmd(node['hostname'], "/opt/xcli destroy"))

def get_diagnostics(node):
    return ssh_cmd(node['hostname'], "/opt/xcli diagnostics")

def get_nodeid(node):
    output = get_diagnostics(node)
    nodeid = [x.split(" ")[3] for x in output.split('\n') if x.startswith("Local node id:")][0]
    print "Node ID for %s is %s" % (node['hostname'], nodeid)
    return nodeid

print "Get node eth1 IP addresses"
c1 = get_ip("cluster1")
c2 = get_ip("cluster2")
c3 = get_ip("cluster3")
print "c1 = '%s'" % (c1)
print "c2 = '%s'" % (c2)
print "c3 = '%s'" % (c3)

m1 = {"hostname":"cluster1", "addresses":[c1]}
m2 = {"hostname":"cluster2", "addresses":[c2]}
m3 = {"hostname":"cluster3", "addresses":[c3]}

def destroy_existing():
    print "Destroy any existing configuration"
    destroy_node(m1)
    destroy_node(m2)
    destroy_node(m3)

def create_two_node_cluster():
    destroy_existing()
    print "Set up 2-node cluster"
    global secret
    secret = create_cluster(m1)
    existing = [m1]
    join_node(m2, secret, existing)
    existing.append(m2)
    return existing

def create_three_node_cluster():
    existing = create_two_node_cluster()
    join_node(m3, secret, existing)
    existing.append(m3)
    return existing

def no_setup():
    pass

def no_teardown():
    pass

@with_setup(create_two_node_cluster, no_teardown)
def test_nodeids_stable_over_join():
    """Check node IDs are stable over node-join"""
    n1 = get_nodeid(m1)
    n2 = get_nodeid(m2)
    join_node(m3, secret, [m1, m2])
    n1b = get_nodeid(m1)
    n2b = get_nodeid(m2)
    print "Node ids were {%s, %s} and are now {%s, %s}" % (n1, n2, n1b, n2b)
    assert (n1==n1b)
    assert (n2==n2b)

@with_setup(create_three_node_cluster, no_teardown)
def test_nodeids_unique():
    """Check node IDs are unique"""
    n1 = get_nodeid(m1)
    n2 = get_nodeid(m2)
    n3 = get_nodeid(m3)
    print "Node ids are {%s, %s, %s}" % (n1, n2, n3)
    assert (n1 <> n2)
    assert (n1 <> n3)

@with_setup(create_three_node_cluster, no_teardown)
def test_two_shutdowns():
    """Check two shutdowns and a destroy work"""
    shutdown_node(m2)
    shutdown_node(m3)
    destroy_node(m1)
