#!/bin/bash


hostname=rancher.$(hostname -d)
network=name=eth0,firewall=1,bridge=vmbr0,ip=172.30.13.101/20,gw=172.30.0.1

id=8000
storage=local-btrfs

size=64
repository=https://github.com/Deltachaos/tretboot-proxmox-lxc-rancher.git
image=ubuntu-24.04-standard_24.04-2_amd64.tar.zst
k3s_version=v1.28.10+k3s1

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
EOF
) | pct exec $id -- tee -a /var/lib/rancher/k3s/server/manifests/tretboot.yaml
pct exec $id -- ln -s /usr/local/bin/k3s /usr/bin/k3s
pct exec $id -- /bin/sh -c "wget -O - https://get.k3s.io | INSTALL_K3S_VERSION=${k3s_version} sh -"
