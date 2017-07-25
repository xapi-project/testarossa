# -*- mode: ruby -*-
# vi: set ft=ruby :

# Vagrantfile API/syntax version. Don't touch unless you know what you're doing!
VAGRANTFILE_API_VERSION = "2"

LOCAL_BRANCH = ENV.fetch("LOCAL_BRANCH", "feature-qemu-datapath")

USER = ENV.fetch("USER")

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
# Disable default synced folder
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.define "infrastructure" do |infra|
    infra.vm.box = "jonludlam/xs-centos-7"
    infra.vm.provision "shell", path: "scripts/infra/vagrant_provision.sh"
    infra.vm.synced_folder "scripts/infra", "/scripts", type: "rsync", rsync__args: ["--verbose", "--archive", "-z", "--copy-links"]
    infra.vm.network "public_network", bridge: "xenbr0"
    config.vm.provider "xenserver" do |xs|
        xs.name = "#{USER}/infrastructure/#{infra.vm.box}"
    end
  end

  (1..3).each do |i|
    config.vm.define "honolulu#{i}" do |host|
      host.vm.box = "jonludlam/release-honolulu-master"
      folders = {'xs/rpms' => '/rpms',
                 'xs/opt' => '/opt',
                 'xs/sbin' => '/sbin',
                 'xs/bin' => '/bin',
                 'xs/boot' => '/boot',
                 'scripts/xs' => '/scripts'}
      folders.each { |k,v| host.vm.synced_folder k, v, type: "rsync", rsync__args: ["--verbose", "--archive", "-z", "--copy-links"] }
      host.vm.network "public_network", bridge: "xenbr0"
      host.vm.provision "shell", path: "scripts/xs/update.sh"
      host.vm.provision :ansible do |ansible|
        ansible.groups = {
	  "honolulu" => (1..3).map{|i| "honolulu#{i}"}
	}
	ansible.limit = "honolulu"
	ansible.playbook = "playbook.yml"
      end
    end
  end

  (1..3).each do |i|
    hostname = "host#{i}"
    config.vm.define hostname do |host|
      host.vm.box = "jonludlam/#{LOCAL_BRANCH}"
      host.vm.provision "shell",
        inline: "hostname host#{i}; echo #{hostname} > /etc/hostname"
      folders = {'xs/rpms' => '/rpms',
                 'xs/opt' => '/opt',
                 'xs/sbin' => '/sbin',
                 'xs/bin' => '/bin',
                 'xs/boot' => '/boot',
                 'scripts/xs' => '/scripts'}
      folders.each { |k,v| host.vm.synced_folder k, v, type: "rsync", rsync__args: ["--verbose", "--archive", "-z", "--copy-links"] }

      host.vm.provision "shell", path: "scripts/xs/update.sh"
      host.vm.network "public_network", bridge: "xenbr0"
      host.vm.network "public_network", bridge: "xenbr1"
      config.vm.provider "xenserver" do |xs|
        xs.name = "#{USER}/#{hostname}/#{host.vm.box}"
      end
    end
  end

# Defines cluster{1,2,3} for corosync investigation
  N = 3
  NAMES = Hash[ (1..N).map{|i| [i, "cluster#{i}"]} ]
  (1..N).each do |i|
    hostname = NAMES[i]
    config.vm.define hostname do |host|
      host.vm.box = "jonludlam/#{LOCAL_BRANCH}"
      host.vm.network "public_network", bridge: "xenbr0"
      host.vm.synced_folder "scripts", "/scripts", type:"rsync", rsync__args: ["--verbose", "--archive", "-z", "--copy-links"]
      config.vm.provider "xenserver" do |xs|
        xs.name = "#{USER}/#{hostname}/#{host.vm.box}"
      end
      if i == N
          host.vm.provision :ansible do |ansible|
            ansible.groups = {
              "cluster" => NAMES.collect { |k, v| v },
              "infra" => ["infrastructure"]
            }
            ansible.limit = "cluster"
#        ansible.verbose = "vvv"
            ansible.playbook = "playbook.yml"
          end
      end
    end
  end

  config.vm.provider "xenserver" do |xs|
    xs.use_himn = true
    xs.memory = 1024
    xs.xs_host = "gandalf.uk.xensource.com"
    xs.xs_username = "root"
    xs.xs_password = "xenroot"
  end
end

