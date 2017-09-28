HOSTS=cluster1 cluster2 cluster3 cluster4 cluster5
ssh-config: $(foreach host,$(HOSTS),.vagrant/machines/$(host)/xenserver/id)
	vagrant ssh-config $(HOSTS) > $@

.PHONY: test clean watch
test: ssh-config
	nosetests --verbosity=3 tests/cluster_demo.py

watch: ssh-config
	scripts/tmuxmulti.sh 'while ! ssh -t -F ssh-config {} sudo -E  corosync-quorumtool -m; do sleep 1; done' $(HOSTS)
#	scripts/tmuxmulti.sh 'while ! ssh -t -F ssh-config {} sudo -E tail -f /var/log/daemon.log; do sleep 1; done' $(HOSTS)

clean:
	rm -f ssh-config
