#!/usr/bin/python
#
# Builds a cluster of three nodes, then removes all nodes.
# Expects xapi-clusterd to be running on each node.
#

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
    ssh = ["ssh", "-F", ssh_config_file, host, cmd]
    print " * Executing on %s: %s" % (host, cmd)
    return execute(ssh)

def assert_null(s):
    assert s=='N'

def get_ip(host):
    return ssh_cmd(host, "sudo ip addr show dev eth1 | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/'")

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

print "Destroy any existing configuration"
ssh_cmd("cluster1", "sudo /opt/xcli destroy")
ssh_cmd("cluster2", "sudo /opt/xcli destroy")
ssh_cmd("cluster3", "sudo /opt/xcli destroy")

print "Create cluster on node 1 (%s)" % (c1)

stdout = ssh_cmd("cluster1", "sudo /opt/xcli create '%s'" % (json.dumps(m1)))
if stdout.startswith('['):
    print >>sys.stderr, "CLI command failed"
    sys.exit(1)
existing = [m1]

secret = stdout[2:-1]
print "Secret token was '%s'" % (secret)

print "Join node 2 (%s) to the cluster" % (c2)
assert_null(ssh_cmd("cluster2", "sudo /opt/xcli join %s '%s' '%s'" % (secret, json.dumps(m2), json.dumps(existing))))
existing.append(m2)

print "Join node 3 (%s) to the cluster" % (c3)
assert_null(ssh_cmd("cluster3", "sudo /opt/xcli join %s '%s' '%s'" % (secret, json.dumps(m3), json.dumps(existing))))
existing.append(m3)

print "Shut down node 2 (%s)" % (c2)
assert_null(ssh_cmd("cluster2", "sudo /opt/xcli shutdown"))

print "Shut down node 3 (%s)" % (c3)
assert_null(ssh_cmd("cluster3", "sudo /opt/xcli shutdown"))

print "Destroy node 1 (%s)" % (c1)
assert_null(ssh_cmd("cluster1", "sudo /opt/xcli destroy"))
