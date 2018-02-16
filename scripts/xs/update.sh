#!/bin/bash

rm /etc/sysconfig/network-scripts/ifcfg-eth0

systemctl enable xapi-clusterd.service
systemctl start xapi-clusterd.service
systemctl start forkexecd.service
systemctl enable forkexecd.service 2>/dev/null
systemctl start xcp-networkd.service
systemctl enable xcp-networkd.service 2>/dev/null
systemctl start genptoken.service
systemctl enable genptoken.service 2>/dev/null
systemctl start squeezed.service
systemctl enable squeezed.service 2>/dev/null
systemctl start xcp-rrdd.service
systemctl enable xcp-rrdd.service 2>/dev/null
systemctl start xenopsd-xc.service
systemctl enable xenopsd-xc.service 2>/dev/null
systemctl start xapi.service
systemctl enable xapi.service 2>/dev/null
systemctl enable xapi-domains.service 2>/dev/null
systemctl start xapi-domains.service

sleep 5

#systemctl start xcp-rrdd-plugins
#systemctl enable xcp-rrdd-plugins
systemctl start xs-firstboot
#service perfmon start
#chkconfig perfmon on

. /etc/xensource-inventory
xe pif-scan host-uuid=${INSTALLATION_UUID}
PIF=$(xe pif-list device=eth0 params=uuid --minimal)
#xe pif-reconfigure-ip uuid=${PIF} mode=dhcp
#xe pif-plug uuid=${PIF}
pif=`sudo xe pif-list device=eth1 --minimal`
#sudo xe pif-reconfigure-ip uuid=$pif mode=dhcp
sudo xe pif-param-set uuid=$pif other-config:defaultroute=true other-config:peerdns=true
sudo xe pif-unplug uuid=$pif
sudo xe pif-plug uuid=$pif
sudo chmod 777 /var/lib/xcp/xapi
host=`sudo xe host-list --minimal`
sudo xe host-param-set uuid=$host other-config:multipathing=true other-config:multipathhandle=dmp
#sudo /opt/xensource/libexec/xen-cmdline --set-xen dom0_mem=3000M,max:3000M
#sudo reboot
