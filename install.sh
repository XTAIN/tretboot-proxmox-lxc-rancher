#!/bin/bash

default_storage=$(pvesm status --content rootdir | grep active | cut -d' ' -f1)
default_hostname=rancher.$(hostname -d)
default_id=$(pvesh get /cluster/nextid)
default_bridge=$(brctl show | awk 'NR>1 {print $1}' | grep vmbr | head -n1)

firewall=${firewall:-1}

if [ -z "${bridge}" ]; then
  bridge=${default_bridge}
fi

ip=${ip:-dhcp}
ip6=${ip6:-}
default_network="name=eth0,firewall=${firewall},bridge=${bridge}"

if [ "${ip}" ]; then
  default_network="${default_network},ip=${ip}"
fi

if [ "${ip6}" ]; then
  default_network="${default_network},ip6=${ip6}"
fi

if [ -z "${hostname}" ]; then
  hostname=${default_hostname}
fi
if [ -z "${network}" ]; then
  network=${default_network}
fi
if [ -z "${storage}" ]; then
  storage=${default_storage}
fi
if [ -z "${id}" ]; then
  id=${default_id}
fi

size=${size:-64}
repository=${repository:-https://github.com/Deltachaos/tretboot-proxmox-lxc-rancher.git}
image=${image:-ubuntu-24.04-standard_24.04-2_amd64.tar.zst}
k3s_version=${k3s_version:-v1.28.10+k3s1}

pveam update
pveam download $storage $image

cat > /etc/modules-load.d/docker.conf <<EOF
aufs
overlay
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
br_netfilter
rbd
options nf_conntrack hashsize=196608
EOF

cat > /etc/sysctl.d/100-docker.conf  <<EOF
net.netfilter.nf_conntrack_max=786432
EOF

sysctl net.netfilter.nf_conntrack_max=786432

while read p; do
  modprobe "$p"
done </etc/modules-load.d/docker.conf

if pct status $id || qm status $id; then
   echo "VM with $id already exists." > /dev/stderr
   exit 1
fi

pct create $id $storage:vztmpl/$image --cores 2 --memory 4096 --swap 2048 --rootfs ${storage}:${size} --hostname=$hostname --onboot 1
(cat <<EOF
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop: 
lxc.mount.auto: "proc:rw sys:rw"
EOF
) | cat - >> /etc/pve/lxc/$id.conf
pct start $id
pct set $id --net0 $network
pct exec $id -- mkdir -p /var/lib/rancher/k3s/server/manifests
pct exec $id -- mkdir -p /etc/rancher/k3s
(cat <<EOF
#!/bin/sh -e

if [ ! -e /dev/kmsg ]; then
    ln -s /dev/console /dev/kmsg
fi

mount --make-rshared /
EOF
) | pct exec $id -- tee /usr/local/bin/k3s-lxc
pct exec $id -- chmod +x /usr/local/bin/k3s-lxc
(cat <<EOF
[Unit]
Description=Adds k3s compatability
After=basic.target

[Service]
Restart=no
Type=oneshot
ExecStart=/usr/local/bin/k3s-lxc
Environment=

[Install]
WantedBy=multi-user.target
EOF
) | pct exec $id -- tee /etc/systemd/system/k3s-lxc.service
pct exec $id -- systemctl daemon-reload
pct exec $id -- systemctl enable k3s-lxc.service
pct exec $id -- systemctl start k3s-lxc.service
(cat <<EOF
disable:
  - servicelb
  - traefik
  - local-storage
EOF
) | pct exec $id -- tee /etc/rancher/k3s/config.yaml
pct exec $id -- wget -O /var/lib/rancher/k3s/server/manifests/tretboot.yaml https://raw.githubusercontent.com/Deltachaos/tretboot/main/tretboot.yaml
(cat <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: tretboot-config
  namespace: tretboot
data:
  repository: "$repository"
  path: "tretboot"
  rancher.yaml: |
    hostname: $hostname
  tretboot-fleet.yaml: |
    repository:
      url: "$repository"
EOF
) | pct exec $id -- tee -a /var/lib/rancher/k3s/server/manifests/tretboot.yaml
pct exec $id -- ln -s /usr/local/bin/k3s /usr/bin/k3s
pct exec $id -- ln -s /usr/local/bin/kubectl /usr/bin/kubectl
pct exec $id -- ln -s /usr/local/bin/crictl /usr/bin/crictl
pct exec $id -- /bin/sh -c "wget -O - https://get.k3s.io | INSTALL_K3S_VERSION=${k3s_version} sh -"
