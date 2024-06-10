#!/bin/bash

host_ip_addr=$(hostname -I | awk '{print $1}')
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

proxmox_api=${proxmox_api:-1}
proxmox_api_create_user=${proxmox_api_create_user:-1}

if [ "${proxmox_api}" == "1" ]; then
  if [ -z "${proxmox_api_host}" ]; then
    proxmox_api_host="${host_ip_addr}"
  fi
  if [ -z "${proxmox_api_username}" ]; then
    proxmox_api_username="rancher@pve"
  fi
  if [ -z "${proxmox_api_password}" ]; then
    proxmox_api_password=$(openssl rand -base64 18)
  fi

  if [ "${proxmox_api_create_user}" == "1" ]; then
    if ! pveum user add "${proxmox_api_username}" --password "${proxmox_api_password}"; then
      echo "Error creating API user" > /dev/stderr
      exit 1
    fi
    pveum aclmod / -user "${proxmox_api_username}" -role Administrator
  fi;
fi;

size=${size:-64}
tretboot_url=${tretboot_url:-https://raw.githubusercontent.com/Deltachaos/tretboot/main/tretboot.yaml}
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

configmap_proxmox_api=""
if [ "${proxmox_api}" == "1" ]; then
  configmap_proxmox_api="$(cat - <<EOF
    proxmox:
      host: "$proxmox_api_host"
      username: "$proxmox_api_username"
      password: "$proxmox_api_password"
EOF
)"
fi

configmap_extra_repositories=""

i=0
while true; do
  fleet_name=$(eval echo \${local_fleet_${i}_name})
  fleet_repo=$(eval echo \${local_fleet_${i}_repo})
  fleet_branch=$(eval echo \${local_fleet_${i}_branch:-main})
  fleet_path=$(eval echo \${local_fleet_${i}_path:-""})
  fleet_auth=$(eval echo \${local_fleet_${i}_auth:-true})

  if [ -z "${fleet_repo}" ]; then
    break
  fi

  if [ -z "${fleet_name}" ]; then
    break
  fi

  configmap_extra_repositories="$(cat - <<EOF
      ${fleet_name}:
          repo: "${fleet_repo}"
          branch: "${fleet_branch}"
          path: "${fleet_path}"
          auth: ${fleet_auth}
$configmap_extra_repositories
EOF
)"

  ((i++))
done

configmap_git_ssh=""
if [ "${fleet_ssh_key}" ]; then
  temp_private_key=$(mktemp)
  chmod 600 "$temp_private_key"
  tee "$temp_private_key" <<EOF
$fleet_ssh_key
EOF

  fleet_ssh_key_public=$(ssh-keygen -y -f "$temp_private_key")
  fleet_ssh_key_private=$(cat $temp_private_key | awk '{printf "%s\\n", $0}')
  rm -f "$temp_private_key"

  configmap_git_ssh="$(cat - <<EOF
    ssh: {"private": "${fleet_ssh_key_private}","public":"${fleet_ssh_key_public}"}
EOF
)"
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
pct exec $id -- wget -O /var/lib/rancher/k3s/server/manifests/tretboot.yaml $tretboot_url
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
    extraRepositories:
$configmap_extra_repositories
$configmap_proxmox_api
$configmap_git_ssh
EOF
) | pct exec $id -- tee -a /var/lib/rancher/k3s/server/manifests/tretboot.yaml
pct exec $id -- ln -s /usr/local/bin/k3s /usr/bin/k3s
pct exec $id -- ln -s /usr/local/bin/kubectl /usr/bin/kubectl
pct exec $id -- ln -s /usr/local/bin/crictl /usr/bin/crictl
pct exec $id -- /bin/sh -c "wget -O - https://get.k3s.io | INSTALL_K3S_VERSION=${k3s_version} sh -"
