ssh-config:
	vagrant ssh-config cluster1 cluster2 cluster3 infrastructure > $@

.PHONY: test clean
test: ssh-config
	nosetests --verbosity=3 tests/cluster_demo.py

clean:
	rm -f ssh-config
