# Introduction

This project contains the build-automation for creating LVM-enabled Enterprise
Linux 9 AMIs for use in AWS envrionments. Testing and support will be given to
RHEL 9 and CentOS 9-stream. Other EL9-derivatives should also work. However,
there are currently no plans by the project-owners to specifically verify
compatibility with other RHEL9-adjacent distributions.

## Purpose

The DISA STIGs specify that root/operating-system drive _must_ have a specific,
minimum set of partitions present. Because re-partitioning the root drive is not
practical once a system &ndash; particularly one that is cloud-hosted &ndash; is
booted, this project was undertaken to ensure that VM templates (primarily
Amazon Machine Images) would be available to create virtual machines (primarily
EC2s) that would have the STIG-mandated partitioning-scheme "from birth".

As of the RHEL 9 v1r1 STIG release, the following minimum set of partitions are
required:

* `/home` (per: V-257843/RHEL-09-231010)
* `/tmp` (per: V-257844/RHEL-09-231015)
* `/var` (per: V-257845/RHEL-09-231020)
* `/var/log` (per: V-257846RHEL-09-231025)
* `/var/log/audit` (per: V-257847/RHEL-09-231030)
* `/var/tmp` (per: V-257848 /RHEL-09-231035)

The images published by this project owner to AWS &ndash; in the commercial and
GovCloud partitions &ndash; have a filesystem layout that looks like:

~~~bash
# df -PH
Filesystem                    Size  Used Avail Use% Mounted on
devtmpfs                      4.2M     0  4.2M   0% /dev
tmpfs                         4.1G     0  4.1G   0% /dev/shm
tmpfs                         1.7G  9.0M  1.7G   1% /run
/dev/mapper/RootVG-rootVol    4.3G  1.7G  2.7G  38% /
tmpfs                         4.1G     0  4.1G   0% /tmp
/dev/mapper/RootVG-homeVol    1.1G   42M  1.1G   4% /home
/dev/nvme0n1p3                508M  231M  277M  46% /boot
/dev/mapper/RootVG-varVol     2.2G  232M  2.0G  11% /var
/dev/nvme0n1p2                256M  7.4M  249M   3% /boot/efi
/dev/mapper/RootVG-logVol     2.2G   68M  2.1G   4% /var/log
/dev/mapper/RootVG-varTmpVol  2.2G   50M  2.1G   3% /var/tmp
/dev/mapper/RootVG-auditVol   6.8G   82M  6.7G   2% /var/log/audit
tmpfs                         819M     0  819M   0% /run/user/1000
~~~

Users of this automation can customize both which partitions to make on the root
disk as well as what size and filesystem-type to make them. Consult the
`DiskSetup.sh` utility's help pages for guidance.

# Further Security Notes

Additionally, the system-images produced by this automation allows the following
system-security features to be enabled:

* FIPS 140-2 mode
* SELinux &ndash; set to either `Enforcing` (preferred) or `Permissive`
* UEFI support (to support system-owner's further ability to enable [SecureBoot](https://access.redhat.com/articles/5254641)
  and other Trusted-Computing capabilities)

This capability is offered as some organizations' security-auditors not only
require that some or all of these features be enabled, but that they be enabled
"from birth" (i.e., a configuraton-reboot to activate them is not sufficient).

As of the writing of this guide:
* FIPS mode is enabled (verify with `fips-mode-setup --check`)
* SELinux is set to `Enforcing` (verify with `getenforce`)
* UEFI is available (verify with `echo $( [[ -d /sys/firmware/efi/ ]] )$?` or
  `dmesg | grep -i EFI`)

Lastly, host-based firewall capabilities are enabled via the `firewalld`
service. The images published by this project's owners only enable two services:
`sshd` and `dhcpv6-client`. All other services and ports are blocked by default.
These settings may be validated using `firewall-cmd --list-all`.

# Software Loadout and Updates

The Red Hat images published by this project's owners make use of the `@core`
RPM package-group plus select utilities to cloud-enable the resulting images
(e.g. `cloud-init` and CSP-tooling like Amazon's SSM Agent and AWS CLI).

The Red Hat images published by this project's owners make use of the
official Red Hat repositories managed by Red Hat on behalf of the CSP. If these
repositories will not be suitable to the image-user, it will be necessary for
the image-user to create their own images. The `OSpackages.sh` script accepts
arguments that allow the configuration of custom repositories and RPMs (the
script requires custom repositories be configured by site repository-RPMs)
