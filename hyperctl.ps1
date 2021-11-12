#!/usr/bin/env powershell
# SPDX-License-Identifier: Apache-2.0
# For usage overview, read the readme.md at https://github.com/youurayy/hyperctl

# ---------------------------SETTINGS------------------------------------

$version = 'v1.0.3'
$workdir = '.\tmp'
$guestuser = $env:USERNAME
$sshpath = "$HOME\.ssh\id_rsa.pub"
if (!(test-path $sshpath)) {
  write-host "`n please configure `$sshpath or place a pubkey at $sshpath `n"
  exit
}
$sshpub = $(get-content $sshpath -raw).trim()

$config = $(get-content -path .\.distro -ea silentlycontinue | out-string).trim()
if(!$config) {
  $config = 'FocalFossa'
}

switch ($config) {
  'bionic' {
    $distro = 'ubuntu'
    $generation = 2
    $imgvers="18.04"
    $imagebase = "https://cloud-images.ubuntu.com/releases/server/$imgvers/release"
    $sha256file = 'SHA256SUMS'
    $image = "ubuntu-$imgvers-server-cloudimg-amd64.img"
    $archive = ""
  }
  'disco' {
    $distro = 'ubuntu'
    $generation = 2
    $imgvers="19.04"
    $imagebase = "https://cloud-images.ubuntu.com/releases/server/$imgvers/release"
    $sha256file = 'SHA256SUMS'
    $image = "ubuntu-$imgvers-server-cloudimg-amd64.img"
    $archive = ""
  }
  'FocalFossa' {
    $distro = 'ubuntu'
    $generation = 2
    $imgvers="20.04"
    $imagebase = "https://cloud-images.ubuntu.com/releases/server/$imgvers/release"
    $sha256file = 'SHA256SUMS'
    $image = "ubuntu-$imgvers-server-cloudimg-amd64.img"
    $archive = ""
  }
  'centos' {
    $distro = 'centos'
    $generation = 1
    $imagebase = "https://cloud.centos.org/centos/7/images"
    $sha256file = 'sha256sum.txt'
    $imgvers = "1907"
    $image = "CentOS-7-x86_64-GenericCloud-$imgvers.raw"
    $archive = ".tar.gz"
  }
}

$nettype = 'public' # private/public
$zwitch = 'K8s' # private or public switch name
$natnet = 'natnet' # private net nat net name (privnet only)
$adapter = 'Ethernet' # public net adapter name (pubnet only)

$cpus = 2
$ram = '2GB'
$hdd = '40GB'

$cidr = switch ($nettype) {
  'private' { '10.10.0' }
  'public' { $null }
}

$macs = @(
  '0225EA2C9AE7', # master
  '02A254C4612F', # node1
  '02FBB5136210', # node2
  '02FE66735ED6', # node3
  '021349558DC7', # node4
  '0288F589DCC3', # node5
  '02EF3D3E1283', # node6
  '0225849ADCBB', # node7
  '02E0B0026505', # node8
  '02069FBFC2B0', # node9
  '02F7E0C904D0' # node10
)

# https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64/repodata/filelists.xml
# https://packages.cloud.google.com/apt/dists/kubernetes-xenial/main/binary-amd64/Packages
# ctrl+f "kubeadm"
# $kubeversion = '1.15.11'
# $kubeversion = '1.16.9'
# $kubeversion = '1.17.5'
#$kubeversion = '1.18.2'
$kubeversion = '1.22.3'

$kubepackages = @"
  - docker-ce
  - docker-ce-cli
  - containerd.io
  - [ kubelet, $kubeversion ]
  - [ kubeadm, $kubeversion ]
  - [ kubectl, $kubeversion ]
"@

$cni = 'flannel'

switch ($cni) {
  'flannel' {
    $cniyaml = 'https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml'
    $cninet = '10.244.0.0/16'
  }
  'weave' {
    $cniyaml = 'https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d "\n")'
    $cninet = '10.32.0.0/12'
  }
  'calico' {
    $cniyaml = 'https://docs.projectcalico.org/v3.7/manifests/calico.yaml'
    $cninet = '192.168.0.0/16'
  }
}

$sshopts = @('-o LogLevel=ERROR', '-o StrictHostKeyChecking=no', '-o UserKnownHostsFile=/dev/null')

$dockercli = 'https://github.com/StefanScherer/docker-cli-builder/releases/download/19.03.1/docker.exe'

$helmurl = 'https://get.helm.sh/helm-v3.1.2-windows-amd64.zip'

# ----------------------------------------------------------------------

$imageurl = "$imagebase/$image$archive"
$srcimg = "$workdir\$image"
$vhdxtmpl = "$workdir\$($image -replace '^(.+)\.[^.]+$', '$1').vhdx"


# switch to the script directory
cd $PSScriptRoot | out-null

# stop on any error
$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['*:ErrorAction']='Stop'

$etchosts = "$env:windir\System32\drivers\etc\hosts"

# note: network configs version 1 an 2 didn't work
function get-metadata($vmname, $cblock, $ip) {
if(!$cblock) {
return @"
instance-id: id-$($vmname)
local-hostname: $($vmname)
"@
} else {
return @"
instance-id: id-$vmname
network-interfaces: |
  auto eth0
  iface eth0 inet static
  address $($cblock).$($ip)
  network $($cblock).0
  netmask 255.255.255.0
  broadcast $($cblock).255
  gateway $($cblock).1
local-hostname: $vmname
"@
}
}

function get-userdata-shared($cblock) {
return @"
#cloud-config

mounts:
  - [ swap ]

groups:
  - docker

users:
  - name: $guestuser
    ssh_authorized_keys:
      - $($sshpub)
    sudo: [ 'ALL=(ALL) NOPASSWD:ALL' ]
    groups: [ sudo, docker ]
    shell: /bin/bash
    # lock_passwd: false # passwd won't work without this
    # passwd: '`$6`$rounds=4096`$byY3nxArmvpvOrpV`$2M4C8fh3ZXx10v91yzipFRng1EFXTRNDE3q9PvxiPc3kC7N/NHG8HiwAvhd7QjMgZAXOsuBD5nOs0AJkByYmf/' # 'test'

write_files:
  # resolv.conf hard-set is a workaround for intial setup
  - path: /etc/resolv.conf
    content: |
      nameserver 192.168.60.1
  - path: /etc/systemd/resolved.conf
    content: |
      [Resolve]
      DNS= 192.168.60.1
  - path: /tmp/append-etc-hosts
    content: |
      $(produce-etc-hosts -cblock $cblock -prefix '      ')
  - path: /etc/modules-load.d/k8s.conf
    content: |
      br_netfilter
  - path: /etc/sysctl.d/k8s.conf
    content: |
      net.bridge.bridge-nf-call-ip6tables = 1
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-arptables = 1
      net.ipv4.ip_forward = 1
  - path: /etc/docker/daemon.json
    content: |
      {
        "exec-opts": ["native.cgroupdriver=systemd"],
        "log-driver": "json-file",
        "log-opts": {
          "max-size": "100m"
        },
        "storage-driver": "overlay2",
        "storage-opts": [
          "overlay2.override_kernel_check=true"
        ]
      }
"@
}

function get-userdata-centos($cblock) {
return @"
$(get-userdata-shared -cblock $cblock)
  # https://github.com/kubernetes/kubernetes/issues/56850
  - path: /usr/lib/systemd/system/kubelet.service.d/12-after-docker.conf
    content: |
      [Unit]
      After=docker.service
  # https://github.com/clearlinux/distribution/issues/39
  - path: /etc/chrony.conf
    content: |
      refclock PHC /dev/ptp0 trust poll 2
      makestep 1 -1
      maxdistance 16.0
      #pool pool.ntp.org iburst
      driftfile /var/lib/chrony/drift
      logdir /var/log/chrony

package_upgrade: true

yum_repos:
  docker-ce-stable:
    name: Docker CE Stable - `$basearch
    baseurl: https://download.docker.com/linux/centos/7/`$basearch/stable
    enabled: 1
    gpgcheck: 1
    gpgkey: https://download.docker.com/linux/centos/gpg
    priority: 1
  kubernetes:
    name: Kubernetes
    baseurl: https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
    enabled: 1
    gpgcheck: 1
    repo_gpgcheck: 1
    gpgkey: https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
    priority: 1

packages:
  - hyperv-daemons
  - yum-utils
  - cifs-utils
  - device-mapper-persistent-data
  - lvm2
$kubepackages

runcmd:
  - echo "sudo tail -f /var/log/messages" > /home/$guestuser/log
  - systemctl restart chronyd
  - cat /tmp/append-etc-hosts >> /etc/hosts
  # https://docs.docker.com/install/linux/docker-ce/centos/
  - setenforce 0
  - sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
  - mkdir -p /etc/systemd/system/docker.service.d
  - systemctl mask --now firewalld
  - systemctl daemon-reload
  - systemctl enable docker
  - systemctl enable kubelet
  # https://github.com/kubernetes/kubeadm/issues/954
  - echo "exclude=kube*" >> /etc/yum.repos.d/kubernetes.repo
  - systemctl start docker
  - touch /home/$guestuser/.init-completed
"@
}

function get-userdata-ubuntu($cblock) {
return @"
$(get-userdata-shared -cblock $cblock)
  # https://github.com/kubernetes/kubernetes/issues/56850
  - path: /etc/systemd/system/kubelet.service.d/12-after-docker.conf
    content: |
      [Unit]
      After=docker.service
  - path: /etc/apt/preferences.d/docker-pin
    content: |
      Package: *
      Pin: origin download.docker.com
      Pin-Priority: 600
  - path: /etc/systemd/network/99-default.link
    content: |
      [Match]
      Path=/devices/virtual/net/*
      [Link]
      NamePolicy=kernel database onboard slot path
      MACAddressPolicy=none
  # https://github.com/clearlinux/distribution/issues/39
  - path: /etc/chrony/chrony.conf
    content: |
      refclock PHC /dev/ptp0 trust poll 2
      makestep 1 -1
      maxdistance 16.0
      #pool pool.ntp.org iburst
      driftfile /var/lib/chrony/chrony.drift
      logdir /var/log/chrony
apt:
  sources:
    kubernetes:
      source: "deb http://apt.kubernetes.io/ kubernetes-xenial main"
      key: |
        -----BEGIN PGP PUBLIC KEY BLOCK-----

        xsBNBGA9EFkBCAC1ilzST0wns+uwZyEA5IVtYeyAuXTaQUEAd70SqIlQpDd4EyVi
        x3SCanQIu8dG9Zq3+x28WBb2OuXP9oc06ybOWdu2m7N5PY0BUT4COA36JV/YrxmN
        s+5/M+YnDHppv63jgRIOkzXzXNo6SwTsl2xG9fKB3TS0IMvBkWdw5PGrBM5GghRc
        ecgoSAAwRbWJXORHGKVwlV6tOxQZ/xqA08hPJneMfsMFPOXsitgGRHoXjlUWLVeJ
        70mmIYsC/pBglIwCzmdD8Ee39MrlSXbuXVQiz38iHfnvXYpLEmgNXKzI0DH9tKg8
        323kALzqaJlLFOLJm/uVJXRUEfKS3LhVZQMzABEBAAHNUVJhcHR1cmUgQXV0b21h
        dGljIFNpZ25pbmcgS2V5IChjbG91ZC1yYXB0dXJlLXNpZ25pbmcta2V5LTIwMjEt
        MDMtMDEtMDhfMDFfMDkucHViKcLAaAQTAQgAHAUCYD0QWQkQ/uqRaTB+oHECGwMF
        CQPDCrACGQEAAHtlCACxSWMp3yRcLmsHhxGDt59nhSNXhouWiNePSMe5vETQA/lh
        ip9Zx/NPRCa4q5jpIDBlEYOg67YanztcjSWGSI35Xblq43H4uLSxh4PtKzZMo+Uj
        8n2VNHOZXBdGcsODcU3ynF64r7eTQevUe2aU0KN2o656O3HrE4itOVKYwnnkmNsk
        G45b9b7DJnsQ6WPszUc8lNhsa2gBI6vfLl68vjj7PlWw030BM/RoMEPpoOApohHo
        sfnNhxJmE1AxwBkMEzyo2kZhPZGh85LDnDbAvjSFKqYSPReKmRFjLlo3DPVHZ/de
        Qn6noHbgUChLo21FefhlZO6tysrb283MWMIyY/YSzsBNBGA9EFkBCADcdO/Aw1qu
        dZORZCNLz3vTiQSFcUFYyScfJJnwUsg8fy0kgg9olFY0GK5icT6n/shc1RlIpuqr
        OQYBZgtK3dSZfOAXE2N20HUvC+nrKKuXXX+jcM/X1kHxwX5tG6fB1fyNH0p/Qqsz
        EfYRHJu0Y4PonTYIslITnEzlN4hUN6/mx1+mWPl4P4R7/h6+p7Q2jtaClEtddF0e
        eOf16Ma5S8fff80uZCLJoVu3lOXCT22oCf7qmH2XddmqGisUScqwmbmuv30tdQed
        n+8njKo2pfpVF1Oa67CWRXdKTknuZybxI9Ipcivy8CISL2Do0uzij7SR7keVf7G1
        Q3K3iJ0wn6mDABEBAAHCwF8EGAEIABMFAmA9EFkJEP7qkWkwfqBxAhsMAAA/3AgA
        FJ2hEp2144fzgtNWHOVFv27hsrO7wYFZwoic9lHSl4iEw8mJc/3kEXdg9Vf9m1zb
        G/kZ6slmzpfv7zDAdN3h3HT0B1yrb3xXzRX0zhOYAbQSUnc6DemhDZoDWt/wVceK
        fzvebB9VTDzRBUVzxCduvY6ij0p2APZpnTrznvCPoCHkfzBMC3Zyk1FueiPTPoP1
        9M0BProMy8qDVSkFr0uX3PM54hQN6mGRQg5HVVBxUNaMnn2yOQcxbQ/T/dKlojdp
        RmvpGyYjfrvyExE8owYn8L7ly2N76GcY6kiN1CmTnCgdrbU0SPacm7XbxTYlQHwJ
        CEa9Hf4/nuiBaxwXKuc/y8bATQRfyX5eAQgA0z1F3ZDbtOe1/j90k1cQsyaVNjJ/
        rVGpinUnVWpmxnmBSDXKfxBsDRoXW9GtQWx7NUlmGW88IeHevqd5OAAc1TDvkaTL
        v2gcfROWjp+XPBsx42f1RGoXqiy4UlHEgswoUmXDeY89IUxoZgBmr4jLekTM0n2y
        IWT49ZA8wYhndEMHf6zj5ya+LWj67kd3nAY4R7YtfwTBnf5Y9Be80Jwo6ez66oKR
        DwU/I6PcF9sLzsl7MEiPxrH2xYmjiXw52Hp4GhIPLBfrt1jrNGdtHEq+pEu+ih6U
        32tyY2LHx7fDQ8PMOHtx/D8EMzYkT/bV3jAEikM93pjI/3pOh8Y4oWPahQARAQAB
        zbpnTGludXggUmFwdHVyZSBBdXRvbWF0aWMgU2lnbmluZyBLZXkgKC8vZGVwb3Qv
        Z29vZ2xlMy9wcm9kdWN0aW9uL2JvcmcvY2xvdWQtcmFwdHVyZS9rZXlzL2Nsb3Vk
        LXJhcHR1cmUtcHVia2V5cy9jbG91ZC1yYXB0dXJlLXNpZ25pbmcta2V5LTIwMjAt
        MTItMDMtMTZfMDhfMDUucHViKSA8Z2xpbnV4LXRlYW1AZ29vZ2xlLmNvbT7CwGgE
        EwEIABwFAl/Jfl4JEItXxcKDb0vrAhsDBQkDwwqwAhkBAABBeggAmnpK6OmlCSXd
        5lba7SzjnsFfHrdY3qeXsJqTq3sP6Wo0VQXiG1dWsFZ9P/BHHpxXo5j+lhXHQlqL
        g1SEv0JkRUFfTemFzfD4sGpa0Vd20yhQR5MGtXBB+AGnwhqNHA7yW/DdyZzP0Zm9
        Skhiq+2V6ZpC7WFaq+h4M5frJ65R9F8LJea90sr6gYL0WE0CmaSqpgRHdbnYnlaC
        0hffPJCnjQ4xWvkNUo2Txlvl7pIBPJAVG0g8fGPKugrM4d1VWPuSVHqopkYCdgA2
        Nv95RLQGTrZsHAZYWNHD1laoGteBO5ExkligulvejX8vSuy+GKafJ0zBK7rNfNWq
        sMDXzKp6Z87ATQRfyX5eAQgAw0ofinQXjYyHJVVZ0SrdEE+efd8heFlWbf04Dbmh
        GebypJ6KFVSKvnCSH2P95VKqvE3uHRI6HbRcinuV7noKOqo87PE2BXQgB16V0aFK
        JU9eJvqpCfK4Uq6TdE8SI1iWyXZtzZa4E2puUSicN0ocqTVMcqJZx3pV8asigwpM
        QUg5kesXHX7d8HUJeSJCAMMXup8sJklLaZ3Ri0SXSa2iYmlhdiAYxTYN70xGI+Hq
        HoWXeF67xMi1azGymeZun9aOkFEbs0q1B/SU/4r2agpoT6aLApV119G24vStGf/r
        lcpOr++prNzudKyKtC9GHoTPBvvqphjuNtftKgi5HQ+f4wARAQABwsBfBBgBCAAT
        BQJfyX5eCRCLV8XCg29L6wIbDAAAGxoIAMO5YUlhJWaRldUiNm9itujwfd31SNbU
        GFd+1iBJQibGoxfv2Q3ySdnep3LkEpXh+VkXHHOIWXysMrAP3qaqwp8HO8irE6Ge
        LMPMbCRdVLUORDbZHQK1YgSR0uGNlWeQxFJq+RIIRrWRYfWumi6HjFTP562Qi7LQ
        1aDyhKS6JB7v4HmwsH0/5/VNXaJRSKL4OnigApecTsfq83AFae0eD+du4337nc93
        SjHS4T67LRtMOWG8nzz8FjDj6fpFBeOXmHUe5CipNPVayTZBBidCkEOopqkdU59J
        MruHL5H6pwlBdK65+wnQai0gr9UEYYK+kwoUH+8p1rD8+YBnVY4d7SM=
        =pRoV
        -----END PGP PUBLIC KEY BLOCK-----    docker:
      arches: amd64
      source: "deb http://download.docker.com/linux/ubuntu bionic stable"
      key: |
        -----BEGIN PGP PUBLIC KEY BLOCK-----

        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
        YT90qFF93M3v01BbxP+EIY2/9tiIPbrd
        =0YYh
        -----END PGP PUBLIC KEY BLOCK-----

package_update: true

package_upgrade: true

packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - linux-tools-virtual
  - linux-cloud-tools-virtual
  - cifs-utils
  - chrony
$kubepackages

runcmd:
  - echo "sudo tail -f /var/log/syslog" > /home/$guestuser/log
  - systemctl mask --now systemd-timesyncd
  - systemctl enable --now chrony
  - systemctl stop kubelet
  - cat /tmp/append-etc-hosts >> /etc/hosts
  - mkdir -p /usr/libexec/hypervkvpd && ln -s /usr/sbin/hv_get_dns_info /usr/sbin/hv_get_dhcp_info /usr/libexec/hypervkvpd
  - chmod o+r /lib/systemd/system/kubelet.service
  - chmod o+r /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
  # https://github.com/kubernetes/kubeadm/issues/954
  - apt-mark hold kubeadm kubelet
  - touch /home/$guestuser/.init-completed
"@
}

function create-public-net($zwitch, $adapter) {
  new-vmswitch -name $zwitch -allowmanagementos $true -netadaptername $adapter | format-list
}

function create-private-net($natnet, $zwitch, $cblock) {
  new-vmswitch -name $zwitch -switchtype internal | format-list
  new-netipaddress -ipaddress "$($cblock).1" -prefixlength 24 -interfacealias "vEthernet ($zwitch)" | format-list
  new-netnat -name $natnet -internalipinterfaceaddressprefix "$($cblock).0/24" | format-list
}

function produce-yaml-contents($path, $cblock) {
  set-content $path ([byte[]][char[]] `
    "$(&"get-userdata-$distro" -cblock $cblock)`n") -encoding byte
}

function produce-iso-contents($vmname, $cblock, $ip) {
  md $workdir\$vmname\cidata -ea 0 | out-null
  set-content $workdir\$vmname\cidata\meta-data ([byte[]][char[]] `
    "$(get-metadata -vmname $vmname -cblock $cblock -ip $ip)") -encoding byte
  produce-yaml-contents -path $workdir\$vmname\cidata\user-data -cblock $cblock
}

function make-iso($vmname) {
  $fsi = new-object -ComObject IMAPI2FS.MsftFileSystemImage
  $fsi.FileSystemsToCreate = 3
  $fsi.VolumeName = 'cidata'
  $vmdir = (resolve-path -path "$workdir\$vmname").path
  $path = "$vmdir\cidata"
  $fsi.Root.AddTreeWithNamedStreams($path, $false)
  $isopath = "$vmdir\$vmname.iso"
  $res = $fsi.CreateResultImage()
  $cp = New-Object CodeDom.Compiler.CompilerParameters
  $cp.CompilerOptions = "/unsafe"
  if (!('ISOFile' -as [type])) {
    Add-Type -CompilerParameters $cp -TypeDefinition @"
      public class ISOFile {
        public unsafe static void Create(string iso, object stream, int blkSz, int blkCnt) {
          int bytes = 0; byte[] buf = new byte[blkSz];
          var ptr = (System.IntPtr)(&bytes); var o = System.IO.File.OpenWrite(iso);
          var i = stream as System.Runtime.InteropServices.ComTypes.IStream;
          if (o != null) { while (blkCnt-- > 0) { i.Read(buf, blkSz, ptr); o.Write(buf, 0, bytes); }
            o.Flush(); o.Close(); }}}
"@ }
  [ISOFile]::Create($isopath, $res.ImageStream, $res.BlockSize, $res.TotalBlocks)
}

function create-machine($zwitch, $vmname, $cpus, $mem, $hdd, $vhdxtmpl, $cblock, $ip, $mac) {
  $vmdir = "$workdir\$vmname"
  $vhdx = "$workdir\$vmname\$vmname.vhdx"

  new-item -itemtype directory -force -path $vmdir | out-null

  if (!(test-path $vhdx)) {
    copy-item -path $vhdxtmpl -destination $vhdx -force
    resize-vhd -path $vhdx -sizebytes $hdd

    produce-iso-contents -vmname $vmname -cblock $cblock -ip $ip
    make-iso -vmname $vmname

    $vm = new-vm -name $vmname -memorystartupbytes $mem -generation $generation `
      -switchname $zwitch -vhdpath $vhdx -path $workdir

    if($generation -eq 2) {
      set-vmfirmware -vm $vm -enablesecureboot off
    }

    set-vmprocessor -vm $vm -count $cpus
    add-vmdvddrive -vmname $vmname -path $workdir\$vmname\$vmname.iso

    if(!$mac) { $mac = create-mac-address }

    get-vmnetworkadapter -vm $vm | set-vmnetworkadapter -staticmacaddress $mac
    set-vmcomport -vmname $vmname -number 2 -path \\.\pipe\$vmname
  }
  start-vm -name $vmname
}

function delete-machine($name) {
  stop-vm $name -turnoff -confirm:$false -ea silentlycontinue
  remove-vm $name -force -ea silentlycontinue
  remove-item -recurse -force $workdir\$name
}

function delete-public-net($zwitch) {
  remove-vmswitch -name $zwitch -force -confirm:$false
}

function delete-private-net($zwitch, $natnet) {
  remove-vmswitch -name $zwitch -force -confirm:$false
  remove-netnat -name $natnet -confirm:$false
}

function create-mac-address() {
  return "02$((1..5 | %{ '{0:X2}' -f (get-random -max 256) }) -join '')"
}

function basename($path) {
  return $path.substring(0, $path.lastindexof('.'))
}

function prepare-vhdx-tmpl($imageurl, $srcimg, $vhdxtmpl) {
  if (!(test-path $workdir)) {
    mkdir $workdir | out-null
  }
  if (!(test-path $srcimg$archive)) {
    download-file -url $imageurl -saveto $srcimg$archive
  }

  get-item -path $srcimg$archive | %{ write-host 'srcimg:', $_.name, ([math]::round($_.length/1MB, 2)), 'MB' }

  if($sha256file) {
    $hash = shasum256 -shaurl "$imagebase/$sha256file" -diskitem $srcimg$archive -item $image$archive
    echo "checksum: $hash"
  }
  else {
    echo "no sha256file specified, skipping integrity ckeck"
  }

  if(($archive -eq '.tar.gz') -and (!(test-path $srcimg))) {
    tar xzf $srcimg$archive -C $workdir
  }
  elseif(($archive -eq '.xz') -and (!(test-path $srcimg))) {
    7z e $srcimg$archive "-o$workdir"
  }
  elseif(($archive -eq '.bz2') -and (!(test-path $srcimg))) {
    7z e $srcimg$archive "-o$workdir"
  }

  if (!(test-path $vhdxtmpl)) {
    qemu-img.exe convert $srcimg -O vhdx -o subformat=dynamic $vhdxtmpl
  }

  echo ''
  get-item -path $vhdxtmpl | %{ write-host 'vhxdtmpl:', $_.name, ([math]::round($_.length/1MB, 2)), 'MB' }
  return
}

function download-file($url, $saveto) {
  echo "downloading $url to $saveto"
  $progresspreference = 'silentlycontinue'
  invoke-webrequest $url -usebasicparsing -outfile $saveto # too slow w/ indicator
  $progresspreference = 'continue'
}

function produce-etc-hosts($cblock, $prefix) {
  $ret = switch ($nettype) {
    'private' {
@"
#
$prefix#
$prefix$($cblock).10 master
$prefix$($cblock).11 node1
$prefix$($cblock).12 node2
$prefix$($cblock).13 node3
$prefix$($cblock).14 node4
$prefix$($cblock).15 node5
$prefix$($cblock).16 node6
$prefix$($cblock).17 node7
$prefix$($cblock).18 node8
$prefix$($cblock).19 node9
$prefix#
$prefix#
"@
    }
    'public' {
      ''
    }
  }
  return $ret
}

function update-etc-hosts($cblock) {
  produce-etc-hosts -cblock $cblock -prefix '' | out-file -encoding utf8 -append $etchosts
  get-content $etchosts
}

function create-nodes($num, $cblock) {
  1..$num | %{
    echo creating node $_
    create-machine -zwitch $zwitch -vmname "node$_" -cpus 4 -mem 4GB -hdd 40GB `
      -vhdxtmpl $vhdxtmpl -cblock $cblock -ip $(10+$_)
  }
}

function delete-nodes($num) {
  1..$num | %{
    echo deleting node $_
    delete-machine -name "node$_"
  }
}

function get-our-vms() {
  return get-vm | where-object { ($_.name -match 'master|node.*') }
}

function get-our-running-vms() {
  return get-vm | where-object { ($_.state -eq 'running') -and ($_.name -match 'master|node.*') }
}

function shasum256($shaurl, $diskitem, $item) {
  $pat = "^(\S+)\s+\*?$([regex]::escape($item))$"

  $hash = get-filehash -algo sha256 -path $diskitem | %{ $_.hash}

  $webhash = ( invoke-webrequest $shaurl -usebasicparsing ).tostring().split("`n") | `
    select-string $pat | %{ $_.matches.groups[1].value }

  if(!($hash -ieq $webhash)) {
    throw @"
    SHA256 MISMATCH:
       shaurl: $shaurl
         item: $item
     diskitem: $diskitem
     diskhash: $hash
      webhash: $webhash
"@
  }
  return $hash
}

function got-ctrlc() {
  if ([console]::KeyAvailable) {
    $key = [system.console]::readkey($true)
    if (($key.modifiers -band [consolemodifiers]"control") -and ($key.key -eq "C")) {
      return $true
    }
  }
  return $false;
}

function wait-for-node-init($opts, $name) {
  while ( ! $(ssh $opts $guestuser@master 'ls ~/.init-completed 2> /dev/null') ) {
    echo "waiting for $name to init..."
    start-sleep -seconds 5
    if( got-ctrlc ) { exit 1 }
  }
}

function to-unc-path($path) {
  $item = get-item $path
  return $path.replace($item.root, '/').replace('\', '/')
}

function to-unc-path2($path) {
  return ($path -replace '^[^:]*:?(.+)$', "`$1").replace('\', '/')
}

function hyperctl() {
  kubectl --kubeconfig=$HOME/.kube/config.hyperctl $args
}

function print-aliases($pwsalias, $bashalias) {
  echo ""
  echo "powershell alias:"
  echo "  write-output '$pwsalias' | out-file -encoding utf8 -append `$profile"
  echo ""
  echo "bash alias:"
  echo "  write-output `"``n$($bashalias.replace('\', '\\'))``n`" | out-file -encoding utf8 -append -nonewline ~\.profile"
  echo ""
  echo "  -> restart your shell after applying the above"
}

function install-kubeconfig() {
  new-item -itemtype directory -force -path $HOME\.kube | out-null
  scp $sshopts $guestuser@master:.kube/config $HOME\.kube\config.hyperctl

  $pwsalias = "function hyperctl() { kubectl --kubeconfig=$HOME\.kube\config.hyperctl `$args }"
  $bashalias = "alias hyperctl='kubectl --kubeconfig=$HOME\.kube\config.hyperctl'"

  $cachedir="$HOME\.kube\cache\discovery\$cidr.10_6443"
  if (test-path $cachedir) {
    echo ""
    echo "deleting previous $cachedir"
    echo ""
    rmdir $cachedir -recurse
  }

  echo "executing: hyperctl get pods --all-namespaces`n"
  hyperctl get pods --all-namespaces
  echo ""
  echo "executing: hyperctl get nodes`n"
  hyperctl get nodes

  print-aliases -pwsalias $pwsalias -bashalias $bashalias
}

function install-helm() {
  if (!(get-command "helm" -ea silentlycontinue)) {
    choco install -y kubernetes-helm
  }
  else {
    choco upgrade kubernetes-helm
  }

  echo ""
  echo "helm version: $(helm version)"

  $helm = "helm --kubeconfig $(to-unc-path2 $HOME\.kube\config.hyperctl)"
  $pwsalias = "function hyperhelm() { $helm `$args }"
  $bashalias = "alias hyperhelm='$helm'"

  print-aliases -pwsalias $pwsalias -bashalias $bashalias
  echo "  -> then you can use e.g.: hyperhelm version"
}

function print-local-repo-tips() {
echo @"
# you can now publish your apps, e.g.:

TAG=master:30699/yourapp:`$(git log --pretty=format:'%h' -n 1)
docker build ../yourapp/image/ --tag `$TAG
docker push `$TAG
hyperhelm install yourapp ../yourapp/chart/ --set image=`$TAG
"@
}

echo ''

if($args.count -eq 0) {
  $args = @( 'help' )
}

switch -regex ($args) {
  ^help$ {
    echo @"
  Practice real Kubernetes configurations on a local multi-node cluster.
  Inspect and optionally customize this script before use.

  Usage: .\hyperctl.ps1 command+

  Commands:

     (pre-requisites are marked with ->)

  -> install - install basic chocolatey packages
      config - show script config vars
       print - print etc/hosts, network interfaces and mac addresses
  ->     net - install private or public host network
  ->   hosts - append private network node names to etc/hosts
  ->   image - download the VM image
      master - create and launch master node
       nodeN - create and launch worker node (node1, node2, ...)
        info - display info about nodes
        init - initialize k8s and setup host kubectl
      reboot - soft-reboot the nodes
    shutdown - soft-shutdown the nodes
        save - snapshot the VMs
     restore - restore VMs from latest snapshots
        stop - stop the VMs
       start - start the VMs
      delete - stop VMs and delete the VM files
      delnet - delete the network
         iso - write cloud config data into a local yaml
      docker - setup local docker with the master node
       share - setup local fs sharing with docker on master
       helm2 - setup helm 2 with tiller in k8s
       helm3 - setup helm 3
        repo - install local docker repo in k8s

  For more info, see: https://github.com/youurayy/hyperctl
"@
  }
  ^install$ {
    if (!(get-command "7z" -ea silentlycontinue)) {
      choco install -y 7zip.commandline
    }
    if (!(get-command "qemu-img" -ea silentlycontinue)) {
      choco install -y qemu-img
    }
    if (!(get-command "kubectl" -ea silentlycontinue)) {
      choco install -y kubernetes-cli
    }
    else {
      choco upgrade kubernetes-cli
    }
  }
  ^config$ {
    echo "   version: $version"
    echo "    config: $config"
    echo "    distro: $distro"
    echo "   workdir: $workdir"
    echo " guestuser: $guestuser"
    echo "   sshpath: $sshpath"
    echo "  imageurl: $imageurl"
    echo "  vhdxtmpl: $vhdxtmpl"
    echo "      cidr: $cidr.0/24"
    echo "    switch: $zwitch"
    echo "   nettype: $nettype"
    switch ($nettype) {
      'private' { echo "    natnet: $natnet" }
      'public'  { echo "   adapter: $adapter" }
    }
    echo "      cpus: $cpus"
    echo "       ram: $ram"
    echo "       hdd: $hdd"
    echo "       cni: $cni"
    echo "    cninet: $cninet"
    echo "   cniyaml: $cniyaml"
    echo " dockercli: $dockercli"
  }
  ^print$ {
    echo "***** $etchosts *****"
    get-content $etchosts | select-string -pattern '^#|^\s*$' -notmatch

    echo "`n***** configured mac addresses *****`n"
    echo $macs

    echo "`n***** network interfaces *****`n"
    (get-vmswitch 'switch' -ea:silent | `
      format-list -property name, id, netadapterinterfacedescription | out-string).trim()

    if ($nettype -eq 'private') {
      echo ''
      (get-netipaddress -interfacealias 'vEthernet (switch)' -ea:silent | `
        format-list -property ipaddress, interfacealias | out-string).trim()
      echo ''
      (get-netnat 'natnet' -ea:silent | format-list -property name, internalipinterfaceaddressprefix | out-string).trim()
    }
  }
  ^net$ {
    switch ($nettype) {
      'private' { create-private-net -natnet $natnet -zwitch $zwitch -cblock $cidr }
      'public' { create-public-net -zwitch $zwitch -adapter $adapter }
    }
  }
  ^hosts$ {
    switch ($nettype) {
      'private' { update-etc-hosts -cblock $cidr }
      'public' { echo "not supported for public net - use dhcp"  }
    }
  }
  ^macs$ {
    $cnt = 10
    0..$cnt | %{
      $comment = switch ($_) {0 {'master'} default {"node$_"}}
      $comma = if($_ -eq $cnt) { '' } else { ',' }
      echo "  '$(create-mac-address)'$comma # $comment"
    }
  }
  ^image$ {
    prepare-vhdx-tmpl -imageurl $imageurl -srcimg $srcimg -vhdxtmpl $vhdxtmpl
  }
  ^master$ {
    create-machine -zwitch $zwitch -vmname 'master' -cpus $cpus `
      -mem $(Invoke-Expression $ram) -hdd $(Invoke-Expression $hdd) `
      -vhdxtmpl $vhdxtmpl -cblock $cidr -ip '10' -mac $macs[0]
  }
  '(^node(?<number>\d+)$)' {
    $num = [int]$matches.number
    $name = "node$($num)"
    create-machine -zwitch $zwitch -vmname $name -cpus $cpus `
      -mem $(Invoke-Expression $ram) -hdd $(Invoke-Expression $hdd) `
      -vhdxtmpl $vhdxtmpl -cblock $cidr -ip "$($num + 10)" -mac $macs[$num]
  }
  ^info$ {
    get-our-vms
  }
  ^init$ {
    get-our-vms | %{ wait-for-node-init -opts $sshopts -name $_.name }

    $init = "sudo kubeadm init --pod-network-cidr=$cninet && \
      mkdir -p `$HOME/.kube && \
      sudo cp /etc/kubernetes/admin.conf `$HOME/.kube/config && \
      sudo chown `$(id -u):`$(id -g) `$HOME/.kube/config && \
      kubectl apply -f `$(eval echo $cniyaml)"

    echo "executing on master: $init"

    ssh $sshopts $guestuser@master $init
    if (!$?) {
      echo "master init has failed, aborting"
      exit 1
    }

    if((get-our-vms | where { $_.name -match "node.+" }).count -eq 0) {
      echo ""
      echo "no worker nodes, removing NoSchedule taint from master..."
      ssh $sshopts $guestuser@master 'kubectl taint nodes master node-role.kubernetes.io/master:NoSchedule-'
      echo ""
    }
    else {
      $joincmd = $(ssh $sshopts $guestuser@master 'sudo kubeadm token create --print-join-command')
      get-our-vms | where { $_.name -match "node.+" } |
        %{
          $node = $_.name
          echo "`nexecuting on $node`: $joincmd"
          ssh $sshopts $guestuser@$node sudo $joincmd
          if (!$?) {
            echo "$node init has failed, aborting"
            exit 1
          }
        }
    }

    install-kubeconfig
  }
  ^reboot$ {
    get-our-vms | %{ $node = $_.name; $(ssh $sshopts $guestuser@$node 'sudo reboot') }
  }
  ^shutdown$ {
    get-our-vms | %{ $node = $_.name; $(ssh $sshopts $guestuser@$node 'sudo shutdown -h now') }
  }
  ^save$ {
    get-our-vms | checkpoint-vm
  }
  ^restore$ {
    get-our-vms | foreach-object { $_ | get-vmsnapshot | sort creationtime | `
      select -last 1 | restore-vmsnapshot -confirm:$false }
  }
  ^stop$ {
    get-our-vms | stop-vm
  }
  ^start$ {
    get-our-vms | start-vm
  }
  ^delete$ {
    get-our-vms | %{ delete-machine -name $_.name }
  }
  ^delnet$ {
    switch ($nettype) {
      'private' { delete-private-net -zwitch $zwitch -natnet $natnet }
      'public' { delete-public-net -zwitch $zwitch }
    }
  }
  ^time$ {
    echo "local: $(date)"
    get-our-vms | %{
      $node = $_.name
      echo ---------------------$node
      # ssh $sshopts $guestuser@$node "date ; if which chronyc > /dev/null; then sudo chronyc makestep ; date; fi"
      ssh $sshopts $guestuser@$node "date"
    }
  }
  ^track$ {
    get-our-vms | %{
      $node = $_.name
      echo ---------------------$node
      ssh $sshopts $guestuser@$node "date ; sudo chronyc tracking"
    }
  }
  ^docker$ {
    $saveto = "C:\ProgramData\chocolatey\bin\docker.exe"
    if (!(test-path $saveto)) {
      echo "installing docker cli..."
      download-file -url $dockercli -saveto $saveto
    }
    echo ""
    echo "powershell:"
    echo "  write-output '`$env:DOCKER_HOST = `"ssh://$guestuser@master`"' | out-file -encoding utf8 -append `$profile"
    echo ""
    echo "bash:"
    echo "  write-output `"``nexport DOCKER_HOST='ssh://$guestuser@master'``n`" | out-file -encoding utf8 -append -nonewline ~\.profile"
    echo ""
    echo ""
    echo "(restart your shell after applying the above)"
  }
  ^share$ {
    if (!( get-smbshare -name 'hyperctl' -ea silentlycontinue )) {
      echo "creating host $HOME -> /hyperctl share..."
      new-smbshare -name 'hyperctl' -path $HOME
    }
    else {
      echo "(not creating $HOME -> /hyperctl share, already present...)"
    }
    echo ""

    $unc = to-unc-path -path $HOME
    $cmd = "sudo mkdir -p $unc && sudo mount -t cifs //$cidr.1/hyperctl $unc -o sec=ntlm,username=$guestuser,vers=3.0,sec=ntlmv2,noperm"
    set-clipboard -value $cmd
    echo $cmd
    echo "  ^ copied to the clipboard, paste & execute on master:"
    echo "    (just right-click (to paste), <enter your Windows password>, Enter, Ctrl+D)"
    echo ""
    ssh $sshopts $guestuser@master

    echo ""
    $unc = to-unc-path -path $pwd.path
    $cmd = "docker run -it -v $unc`:$unc r-base ls -l $unc"
    set-clipboard -value $cmd
    echo $cmd
    echo "  ^ copied to the clipboard, paste & execute locally to test the sharing"
  }
  ^helm$ {
    install-helm
  }
  ^repo$ {
    # install openssl if none is provided
    # don't try to install one bc the install is intrusive and not fully automated
    $openssl = "openssl.exe"
    if(!(get-command "openssl" -ea silentlycontinue)) {
      # fall back to cygwin openssl if installed
      $openssl = "C:\tools\cygwin\bin\openssl.exe"
      if(!(test-path $openssl)) {
        echo "error: please make sure 'openssl' command is in the path"
        echo "(or install Cygwin so that '$openssl' exists)"
        echo ""
        exit 1
      }
    }

    # add remote helm repo to you local ~/.helm registry
    hyperhelm repo add stable https://kubernetes-charts.storage.googleapis.com
    hyperhelm repo update

    # prepare secrets for local repo
    $certs="$workdir\certs"
    md $certs -ea 0 | out-null
    $expr = "$openssl req -newkey rsa:4096 -nodes -sha256 " +
      "-subj `"/C=/ST=/L=/O=/CN=master`" -keyout $certs/tls.key -x509 " +
      "-days 365 -out $certs/tls.cert"
    invoke-expression $expr
    hyperctl create secret tls master --cert=$certs/tls.cert --key=$certs/tls.key

    # distribute certs to our nodes
    get-our-vms | %{
      $node = $_.name
      $(scp $sshopts $certs/tls.cert $guestuser@$node`:)
      $(ssh $sshopts $guestuser@$node 'sudo mkdir -p /etc/docker/certs.d/master:30699/')
      $(ssh $sshopts $guestuser@$node 'sudo mv tls.cert /etc/docker/certs.d/master:30699/ca.crt')
    }

    hyperhelm install registry stable/docker-registry `
      --set tolerations[0].key=node-role.kubernetes.io/master `
      --set tolerations[0].operator=Exists `
      --set tolerations[0].effect=NoSchedule `
      --set nodeSelector.kubernetes\.io/hostname=master `
      --set tlsSecretName=master `
      --set service.type=NodePort `
      --set service.nodePort=30699

    echo ''
    print-local-repo-tips
    echo ''
  }
  ^iso$ {
    produce-yaml-contents -path "$($distro).yaml" -cblock $cidr
    echo "debug cloud-config was written to .\${distro}.yaml"
  }
  default {
    echo 'invalid command; try: .\hyperctl.ps1 help'
  }
}

echo ''
