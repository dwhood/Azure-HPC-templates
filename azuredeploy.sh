#!/bin/bash

set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# != 5 ]; then
    echo "Usage: $0 <MasterHostname> <WorkerHostnamePrefix> <WorkerNodeCount> <HPCUserName> <TemplateBaseUrl>"
    exit 1
fi

yum -y install mdadm

# Set user args
MASTER_HOSTNAME=$1
WORKER_HOSTNAME_PREFIX=$2
WORKER_COUNT=$3
TEMPLATE_BASE_URL="$5"
LAST_WORKER_INDEX=$(($WORKER_COUNT - 1))

# Shares
SHARE_HOME=/share/home
SHARE_DATA=/share/data

# Hpc User
HPC_USER=$4
HPC_UID=7007
HPC_GROUP=users


# Returns 0 if this node is the master node.
#
is_master()
{
    hostname | grep "$MASTER_HOSTNAME"
    return $?
}

# Installs all required packages.
#
install_pkgs()
{
    pkgs="libbz2-1 libz1 openssl libopenssl-devel gcc gcc-c++ nfs-client rpcbind nfs-utils nfs-utils-lib"

    yum -y install $pkgs
}

# Partitions all data disks attached to the VM and creates
# a RAID-0 volume with them.
#
setup_data_disks()
{
    mountPoint="$1"
	createdPartitions=""

    # Loop through and partition disks until not found
    for disk in sdc sdd sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp sdq sdr; do
        fdisk -l /dev/$disk || break
        fdisk /dev/$disk << EOF
n
p
1


t
fd
w
EOF
        createdPartitions="$createdPartitions /dev/${disk}1"
	done

    # Create RAID-0 volume
    if [ -n "$createdPartitions" ]; then
        devices=`echo $createdPartitions | wc -w`
        mdadm --create /dev/md10 --level 0 --raid-devices $devices $createdPartitions
	    mkfs -t ext4 /dev/md10
	    echo "/dev/md10 $mountPoint ext4 defaults,nofail 0 2" >> /etc/fstab
	    mount /dev/md10
    fi
}

# Creates and exports two shares on the master nodes:
#
# /share/home (for HPC user)
# /share/data
#
# These shares are mounted on all worker nodes.
#
setup_shares()
{
    mkdir -p $SHARE_HOME
    mkdir -p $SHARE_DATA

    if is_master; then
	    setup_data_disks $SHARE_DATA
        echo "$SHARE_HOME    *(rw,async)" >> /etc/exports
        echo "$SHARE_DATA    *(rw,async)" >> /etc/exports

        systemctl enable rpcbind
        systemctl enable nfs-server
        systemctl start rpcbind
        systemctl start nfs-server
   
    else
        echo "master:$SHARE_HOME $SHARE_HOME    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        echo "master:$SHARE_DATA $SHARE_DATA    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        mount -a
        mount | grep "^master:$SHARE_HOME"
        mount | grep "^master:$SHARE_DATA"
    fi
}

# Adds a common HPC user to the node and configures public key SSh auth.
# The HPC user has a shared home directory (NFS share on master) and access
# to the data share.
#
setup_hpc_user()
{
    if is_master; then
        useradd -c "HPC User" -g $HPC_GROUP -d $SHARE_HOME -s /bin/bash -m -u $HPC_UID $HPC_USER
        cd /share/home/
        echo ls -la
        
        # Configure public key auth for the HPC user
        su -u $HPC_USER ssh-keygen -t rsa -f $SHARE_HOME/.ssh/id_rsa -q -P ""
        cat $SHARE_HOME/.ssh/id_rsa.pub > $SHARE_HOME/.ssh/authorized_keys

        echo "Host *" > $SHARE_HOME/.ssh/config
        echo "    StrictHostKeyChecking no" >> $SHARE_HOME/.ssh/config
        echo "    UserKnownHostsFile /dev/null" >> $SHARE_HOME/.ssh/config
		echo "    PasswordAuthentication no" >> $SHARE_HOME/.ssh/config

        chown $HPC_USER:$HPC_GROUP $SHARE_HOME/.ssh/authorized_keys
        chown $HPC_USER:$HPC_GROUP $SHARE_HOME/.ssh/config
        chown $HPC_USER:$HPC_GROUP $SHARE_DATA
    else
        useradd -c "HPC User" -g $HPC_GROUP -d $SHARE_HOME/ -s /bin/bash -u $HPC_UID $HPC_USER
    fi

    # Don't require password for HPC user sudo
    echo "$HPC_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
}

# Sets all common environment variables and system parameters.
#
setup_env()
{
    # Set unlimited mem lock
    echo "$HPC_USER hard memlock unlimited" >> /etc/security/limits.conf
	echo "$HPC_USER soft memlock unlimited" >> /etc/security/limits.conf

	# Intel MPI config for IB
    echo "# IB Config for MPI" > /etc/profile.d/hpc.sh
	echo "export I_MPI_FABRICS=shm:dapl" >> /etc/profile.d/hpc.sh
	echo "export I_MPI_DAPL_PROVIDER=ofa-v2-ib0" >> /etc/profile.d/hpc.sh
	echo "export I_MPI_DYNAMIC_CONNECTION=0" >> /etc/profile.d/hpc.sh
}

install_pkgs
setup_shares
setup_hpc_user
setup_env

yum -y install nmap
nmap -P0 -p 1999,2099 flex.cd-adapco.com



