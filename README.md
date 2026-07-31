# VolumeTree
A mount tree view including modern file systems

Vibe coded like a Tony Stark wannabe.

## Example
```
> volumeTree
=== Block Storage Volumes & Mounts ===
├── [disk] /dev/mmcblk1
│   ├── [part] /dev/mmcblk1p1
│   │   └── [vfat] /media/boot
│   └── [part] /dev/mmcblk1p2
│       └── [ext4] /
├── [disk] /dev/mmcblk1boot0
├── [disk] /dev/mmcblk1boot1
├── [disk] /dev/sda
│   ├── [part] /dev/sda1
│   │   └── [ext4] /media/ext4
│   ├── [part] /dev/sda2
│   │   └── [integrity] /dev/mapper/i_01_a
│   │       └── [lvm] /dev/mapper/vg_01-lv_01
│   │           └── [crypt] /dev/mapper/crypt_lvm_01
│   │               └── [xfs] /media/lvm
│   ├── [part] /dev/sda3
│   │   └── [crypt] /dev/mapper/crypt_btrfs_01
│   │       └── [btrfs] /media/btrfs
│   │           └── [bind] /var/www/html  [/media/btrfs/www]
│   └── [part] /dev/sda4
│       └── [zfs] /media/zfs
└── [disk] /dev/sdb
    ├── [part] /dev/sdb1
    │   └── [xfs] /media/xfs
    ├── [part] /dev/sdb2
    │   └── [integrity] /dev/mapper/i_01_b
    │       └── ...
    ├── [part] /dev/sdb3
    │   └── [crypt] /dev/mapper/crypt_btrfs_02
    │       └── ...
    └── [part] /dev/sdb4
        └── ...

=== Kernel & Virtual Filesystems ===
├── [devtmpfs] /dev
├── [hugetlbfs] /dev/hugepages
├── [mqueue] /dev/mqueue
├── [devpts] /dev/pts
├── [tmpfs] /dev/shm
├── [proc] /proc
├── [tmpfs] /run
├── [ramfs] /run/credentials/systemd-sysusers.service
├── [tmpfs] /run/lock
├── [tmpfs] /run/netns  [/netns]
├── [tmpfs] /run/user/0
├── [sysfs] /sys
├── [bpf] /sys/fs/bpf
├── [cgroup2] /sys/fs/cgroup
├── [fusectl] /sys/fs/fuse/connections
├── [pstore] /sys/fs/pstore
├── [configfs] /sys/kernel/config
└── [securityfs] /sys/kernel/security
```
