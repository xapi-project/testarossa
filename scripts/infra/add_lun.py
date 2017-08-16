#!/usr/bin/env python

import rtslib_fb
import commands

ips = commands.getoutput("/sbin/ifconfig | grep -i \"inet\" | grep -iv \"inet6\" | " +
	"awk {'print $2'} | grep -v 127.0.0.1").splitlines()

iscsi = rtslib_fb.FabricModule("iscsi")
f = rtslib_fb.FileIOStorageObject("test1", "/tmp/test.img", 2000000000)
f2 = rtslib_fb.FileIOStorageObject("test2", "/tmp/test2.img", 2000000000)
target = rtslib_fb.Target(iscsi)
tpg = rtslib_fb.TPG(target,1)
tpg.enable = True
tpg.set_attribute("authentication",False)
tpg.set_attribute("demo_mode_write_protect",False)
for ip in ips:
    rtslib_fb.NetworkPortal(tpg, ip, 3260)
lun = rtslib_fb.LUN(tpg, 0, f)
lun2 = rtslib_fb.LUN(tpg, 1, f2)
tpg.set_attribute("cache_dynamic_acls",True)
tpg.set_attribute("generate_node_acls",True)
print target.wwn
