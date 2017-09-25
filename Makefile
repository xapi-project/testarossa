ssh-config:
	vagrant ssh-config cluster1 cluster2 cluster3 cluster4 > $@

.PHONY: test clean watch
test: ssh-config
	nosetests --verbosity=3 tests/cluster_demo.py

watch: ssh-config
	scripts/tmuxmulti.sh 'watch -c "ssh -F ssh-config {} sudo -E corosync-quorumtool"' cluster{1,2,3,4}

clean:
	rm -f ssh-config
