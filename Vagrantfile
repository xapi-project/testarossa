# -*- mode: ruby -*-
# vi: set ft=ruby :

# Vagrantfile API/syntax version. Don't touch unless you know what you're doing!
VAGRANTFILE_API_VERSION = "2"

LOCAL_BRANCH = ENV.fetch("LOCAL_BRANCH", "trunk-ring3")

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
# Disable default synced folder
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.define "infrastructure" do |infra|
    infra.vm.box = "jonludlam/xs-centos-7"
    infra.vm.provision "shell", path: "scripts/infra/vagrant_provision.sh"
    infra.vm.synced_folder "scripts/infra", "/scripts", type: "rsync", rsync__args: ["--verbose", "--archive", "-z", "--copy-links"]
    infra.vm.network "public_network", bridge: "xenbr0"
    infra.vm.network "public_network", bridge: "xenbr1"
  end

  (1..3).each do |i|
    config.vm.define "host#{i}" do |host|
      host.vm.box = "jonludlam/xs-#{LOCAL_BRANCH}"
      host.vm.provision "shell",
        inline: "hostname host#{i}; echo host#{i} > /etc/hostname"
      host.vm.synced_folder "xs/rpms", "/rpms", type: "rsync", rsync__args: ["--verbose", "--archive", "-z", "--copy-links"]
      host.vm.synced_folder "xs/opt", "/opt", type: "rsync", rsync__args: ["--verbose", "--archive", "-z", "--copy-links"]
      host.vm.synced_folder "xs/sbin", "/sbin", type: "rsync", rsync__args: ["--verbose", "--archive", "-z", "--copy-links"]
      host.vm.synced_folder "xs/bin", "/bin", type: "rsync", rsync__args: ["--verbose", "--archive", "-z", "--copy-links"]
      host.vm.synced_folder "xs/boot", "/boot", type: "rsync", rsync__args: ["--verbose", "--archive", "-z", "--copy-links"]
      host.vm.synced_folder "scripts/xs", "/scripts", type: "rsync", rsync__args: ["--verbose", "--archive", "-z", "--copy-links"]

      host.vm.provision "shell", path: "scripts/xs/update.sh"
      host.vm.network "public_network", bridge: "xenbr0"
      host.vm.network "public_network", bridge: "xenbr1"
    end
  end

  config.vm.provider "xenserver" do |xs|
    xs.memory = 4096
  end
end

