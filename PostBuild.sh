#!/bin/bash
set -eu -o pipefail
#
# Install primary OS packages into chroot-env
#
#######################################################################
PROGNAME=$(basename "$0")
PROGDIR="$( dirname "${0}" )"
CHROOTMNT="${CHROOT:-/mnt/ec2-root}"
DEBUG="${DEBUG:-UNDEF}"
FIPSDISABLE="${FIPSDISABLE:-UNDEF}"
GRUBTMOUT="${GRUBTMOUT:-5}"
MAINTUSR="${MAINTUSR:-"maintuser"}"
NOTMPFS="${NOTMPFS:-UNDEF}"
TARGTZ="${TARGTZ:-UTC}"
SUBSCRIPTION_MANAGER="${SUBSCRIPTION_MANAGER:-disabled}"

# Import shared error-exit function
source "${PROGDIR}/err_exit.bashlib"

# Ensure appropriate SEL mode is set
source "${PROGDIR}/no_sel.bashlib"

# Print out a basic usage message
function UsageMsg {
  local SCRIPTEXIT
  SCRIPTEXIT="${1:-1}"

  (
    echo "Usage: ${0} [GNU long option] [option] ..."
    echo "  Options:"
    printf '\t%-4s%s\n' '-f' 'Filesystem-type of chroo-devs (e.g., "xfs")'
    printf '\t%-4s%s\n' '-F' 'Disable FIPS support (NOT IMPLEMENTED)'
    printf '\t%-4s%s\n' '-h' 'Print this message'
    printf '\t%-4s%s\n' '-m' 'Where chroot-dev is mounted (default: "/mnt/ec2-root")'
    printf '\t%-4s%s\n' '-X' 'Declare to be a cross-distro build'
    printf '\t%-4s%s\n' '-z' 'Initial timezone of build-target (default: "UTC")'
    echo "  GNU long options:"
    printf '\t%-20s%s\n' '--cross-distro' 'See "-X" short-option'
    printf '\t%-20s%s\n' '--fstype' 'See "-f" short-option'
    printf '\t%-20s%s\n' '--help' 'See "-h" short-option'
    printf '\t%-20s%s\n' '--mountpoint' 'See "-m" short-option'
    printf '\t%-20s%s\n' '--no-fips' 'See "-F" short-option'
    printf '\t%-20s%s\n' '--no-tmpfs' 'Disable /tmp as tmpfs behavior'
    printf '\t%-20s%s\n' '--timezone' 'See "-z" short-option'
    printf '\t%-20s%s\n' '--use-submgr' 'Do not disable subscription-manager service'
  )
  exit "${SCRIPTEXIT}"
}

# Clean yum/DNF history
function CleanHistory {
  err_exit "Executing yum clean..." NONE
  chroot "${CHROOTMNT}" yum clean --enablerepo=* -y packages || \
    err_exit "Failed executing yum clean"

  err_exit "Nuking DNF history DBs..." NONE
  chroot "${CHROOTMNT}" rm -rf /var/lib/dnf/history.* || \
    err_exit "Failed to nuke DNF history DBs"

}

# Set up fstab
function CreateFstab {
  local    CHROOTDEV
  local    CHROOTFSTYP
  local -a SWAP_DEVS

  CHROOTDEV="$( findmnt -cnM "${CHROOTMNT}" -o SOURCE )"
  CHROOTFSTYP="$( findmnt -cnM "${CHROOTMNT}" -o FSTYPE )"

  # Need to calculate fstab based on build-type
  if [[ -n ${ISCROSSDISTRO:-} ]]
  then
    err_exit "Setting up /etc/fstab for non-LVMed chroot-dev..." NONE
    if [[ ${CHROOTFSTYP:-} == "xfs" ]]
    then
      ROOTLABEL=$(
        xfs_admin -l "${CHROOTDEV}" | sed -e 's/"$//' -e 's/^.* = "//'
      )
    elif [[ ${CHROOTFSTYP:-} == ext[2-4] ]]
    then
      ROOTLABEL=$( e2label "${CHROOTDEV}" )
    else
      err_exit "Couldn't find fslabel for ${CHROOTMNT}"
    fi
    printf "LABEL=%s\t/\t%s\tdefaults\t 0 0\n" "${ROOTLABEL}" \
      "${CHROOTFSTYP}" > "${CHROOTMNT}/etc/fstab" || \
        err_exit "Failed setting up /etc/fstab"
  else
    err_exit "Setting up /etc/fstab for LVMed chroot-dev..." NONE
    grep "${CHROOTMNT}" /proc/mounts | \
      grep -w "/dev/mapper" | \
    sed -e "s/${FSTYPE}.*/${FSTYPE}\tdefaults,rw\t0 0/" \
        -e "s#${CHROOTMNT}\s#/\t#" \
        -e "s#${CHROOTMNT}##" >> "${CHROOTMNT}/etc/fstab" || \
      err_exit "Failed setting up /etc/fstab"
  fi

  # Add any swaps to fstab
  mapfile -t SWAP_DEVS < <( blkid | awk -F: '/TYPE="swap"/{ print $1 }' )
  for SWAP in "${SWAP_DEVS[@]}"
  do
    if [[ $( grep -q "$( readlink -f "${SWAP}" )" /proc/swaps )$? -eq 0 ]]
    then
      err_exit "${SWAP} is already a mounted swap-dev. Skipping" NONE
      continue
    else
      err_exit "Adding ${SWAP} to ${CHROOTMNT}/etc/fstab" NONE
      printf '%s\tnone\tswap\tdefaults\t0 0\n' "${SWAP}" \
        >> "${CHROOTMNT}/etc/fstab" || \
        err_exit "Failed adding ${SWAP} to ${CHROOTMNT}/etc/fstab"
      err_exit "Success" NONE
    fi
  done

  # Add /boot partition to fstab
  BOOT_PART="$(
    grep "${CHROOTMNT}/boot " /proc/mounts | \
    sed 's/ /:/g'
  )"
  if [[ ${BOOT_PART} =~ ":xfs:" ]]
  then
    err_exit "Adding XFS-formatted /boot filesystem to fstab" NONE
    BOOT_LABEL="$(
      xfs_admin -l "${BOOT_PART//:*/}" | \
      sed -e 's/"$//' -e 's/^.*"//'
    )"
    printf 'LABEL=%s\t/boot\txfs\tdefaults,rw\t0 0\n' "${BOOT_LABEL}" >> \
      "${CHROOTMNT}/etc/fstab" || \
      err_exit "Failed adding '/boot' to /etc/fstab"
  elif [[ ${BOOT_PART} =~ ":ext"[2-4]":" ]]
  then
    err_exit "Adding EXTn-formatted /boot filesystem to fstab" NONE
    BOOT_LABEL="$(
      e2label "${BOOT_PART//:*/}"
    )"
    # shellcheck disable=SC2001
    BOOT_FSTYP="$(
      sed 's/\s\s*/:/g' <<< "${BOOT_PART}" | \
      cut -d ':' -f 3
    )"
    printf 'LABEL=%s\t/boot\t%s\tdefaults,rw\t0 0\n' \
      "${BOOT_LABEL}" "${BOOT_FSTYP}" >> "${CHROOTMNT}/etc/fstab" || \
      err_exit "Failed adding '/boot' to /etc/fstab"
  fi

  # Add /boot/efi partition to fstab
  err_exit "Adding /boot/efi filesystem to fstab" NONE
  UEFI_PART="$(
    grep "${CHROOTMNT}/boot/efi " /proc/mounts | \
    sed 's/ /:/g'
  )"
  UEFI_LABEL="$(
    fatlabel "${UEFI_PART//:*/}"
  )"
  printf 'LABEL=%s\t/boot/efi\tvfat\tdefaults,rw\t0 0\n' "${UEFI_LABEL}" >> \
    "${CHROOTMNT}/etc/fstab" || \
    err_exit "Failed adding '/boot/efi' to /etc/fstab"

  # Set an SELinux label
  if [[ -d ${CHROOTMNT}/sys/fs/selinux ]]
  then
    err_exit "Applying SELinux label to fstab..." NONE
    chcon --reference /etc/fstab "${CHROOTMNT}/etc/fstab" || \
      err_exit "Failed applying SELinux label"
  fi

}

# Configure cloud-init
function ConfigureCloudInit {
  local CLINITUSR
  local CLOUDCFG

  CLOUDCFG="${CHROOTMNT}/etc/cloud/cloud.cfg"
  CLINITUSR="$(
    grep -E "name: (maintuser|centos|ec2-user|cloud-user|almalinux)" \
      "${CLOUDCFG}" | \
    awk '{print $2}'
  )"

  # Reset key parms in standard cloud.cfg file
  if [ "${CLINITUSR}" = "" ]
  then
    err_exit "Astandard cloud-init file: can't reset default-user config"
  else
    # Ensure passwords *can* be used with SSH
    err_exit "Allow password logins to SSH..." NONE
    sed -i -e '/^ssh_pwauth/s/\(false\|0\)$/true/' "${CLOUDCFG}" || \
      err_exit "Failed allowing password logins"

    # Delete current "system_info:" block
    err_exit "Nuking standard system_info block..." NONE
    sed -i '/^system_info/,/^  ssh_svcname/d' "${CLOUDCFG}" || \
      err_exit "Failed to nuke standard system_info block"

    # Replace deleted "system_info:" block
    (
      printf "system_info:\n"
      printf "  default_user:\n"
      printf "   name: '%s'\n" "${MAINTUSR}"
      printf "   lock_passwd: true\n"
      printf "   gecos: Local Maintenance User\n"
      printf "   groups: [wheel, adm]\n"
      printf "   sudo: ['ALL=(root) TYPE=sysadm_t ROLE=sysadm_r NOPASSWD:ALL']\n"
      printf "   shell: /bin/bash\n"
      printf "   selinux_user: staff_u\n"
      printf "  distro: rhel\n"
      printf "  paths:\n"
      printf "   cloud_dir: /var/lib/cloud\n"
      printf "   templates_dir: /etc/cloud/templates\n"
      printf "  ssh_svcname: sshd\n"
    ) >> "${CLOUDCFG}"

    # Update NS-Switch map-file for SEL-enabled environment
    err_exit "Enabling SEL lookups by nsswitch..." NONE
    printf "%-12s %s\n" sudoers: files >> "${CHROOTMNT}/etc/nsswitch.conf" || \
      err_exit "Failed enabling SEL lookups by nsswitch"
  fi
}

# Set up logging
function ConfigureLogging {
  local LOGFILE

  # Null out log files
  find "${CHROOTMNT}/var/log" -type f | while read -r LOGFILE
  do
    err_exit "Nulling ${LOGFILE}..." NONE
    cat /dev/null > "${LOGFILE}" || \
      err_exit "Faile to null ${LOGFILE}"
  done

  # Persistent journald logs
  err_exit "Persisting journald logs..." NONE
  echo 'Storage=persistent' >> "${CHROOTMNT}/etc/systemd/journald.conf" || \
    err_exit "Failed persisting journald logs"

  # Ensure /var/log/journal always exists
  err_exit "Creating journald logging-location..." NONE
  install -d -m 0755 "${CHROOTMNT}/var/log/journal" || \
    err_exit "Failed to create journald logging-location"

  err_exit "Ensuring journald logfile storage always exists..." NONE
  chroot "${CHROOTMNT}" systemd-tmpfiles --create --prefix /var/log/journal || \
    err_exit "Failed configuring systemd-tmpfiles"
}

# Configure Networking
function ConfigureNetworking {

  # Set up ifcfg-eth0 file
  err_exit "Setting up ifcfg-eth0 file..." NONE
  (
    printf 'DEVICE="eth0"\n'
    printf 'BOOTPROTO="dhcp"\n'
    printf 'ONBOOT="yes"\n'
    printf 'TYPE="Ethernet"\n'
    printf 'USERCTL="yes"\n'
    printf 'PEERDNS="yes"\n'
    printf 'IPV6INIT="no"\n'
    printf 'PERSISTENT_DHCLIENT="1"\n'
  ) > "${CHROOTMNT}/etc/sysconfig/network-scripts/ifcfg-eth0" || \
    err_exit "Failed setting up file"

  # Set up sysconfig/network file
  err_exit "Setting up network file..." NONE
  (
    printf 'NETWORKING="yes"\n'
    printf 'NETWORKING_IPV6="no"\n'
    printf 'NOZEROCONF="yes"\n'
    printf 'HOSTNAME="localhost.localdomain"\n'
  ) > "${CHROOTMNT}/etc/sysconfig/network" || \
    err_exit "Failed setting up file"

  # Ensure NetworkManager starts
  chroot "${CHROOTMNT}" systemctl enable NetworkManager
}

# EL9 is more annoying about SysV-isms
function ConfigureRcLocalGenerator {
  local GENERATOR_DIR="${CHROOTMNT}/etc/systemd/system-generators"
  local GENERATOR_FIL="${GENERATOR_DIR}/systemd-rc-local-generator"

  # Ensure systemd file is present
  if [[ ! -f ${GENERATOR_FIL} ]]
  then
    printf "Creating %s... " "${GENERATOR_DIR}"
    install -Z "system_u:object_r:etc_t:s0" -dDm 0755 -o root -g root \
      "${GENERATOR_DIR}" || err_exit "Failed creating ${GENERATOR_DIR}"
    echo "Success!"

    printf "Creating %s... " "${GENERATOR_FIL}"
    install -bDm 0600 -o root -g root /dev/null "${GENERATOR_FIL}" || \
      err_exit "Failed creating ${GENERATOR_FIL}"
    echo "Success!"

    printf "Setting SELinux label on %s... " "${GENERATOR_FIL}"
    chcon -u system_u -r object_r -t etc_t "${GENERATOR_FIL}" || \
      err_exit "Failed creating ${GENERATOR_FIL}"
    echo "Success!"
  fi
}


# Firewalld config
function FirewalldSetup {
  err_exit "Setting up baseline firewall rules..." NONE
  chroot "${CHROOTMNT}" /bin/bash -c "(
    firewall-offline-cmd --set-default-zone=drop
    firewall-offline-cmd --zone=trusted --change-interface=lo
    firewall-offline-cmd --zone=drop --add-service=ssh
    firewall-offline-cmd --zone=drop --add-service=dhcpv6-client
    firewall-offline-cmd --zone=drop --add-icmp-block-inversion
    firewall-offline-cmd --zone=drop --add-icmp-block=fragmentation-needed
    firewall-offline-cmd --zone=drop --add-icmp-block=packet-too-big
  )" || \
  err_exit "Failed etting up baseline firewall rules"
}

# Get root dev
function ClipPartition {
  local CHROOTDEV

  CHROOTDEV="${1}"

  # Get base device-name
  if [[ ${CHROOTDEV} =~ nvme ]]
  then
    CHROOTDEV="${CHROOTDEV%p*}"
  else
    CHROOTDEV="${CHROOTDEV%[0-9]}"
  fi

  echo "${CHROOTDEV}"
}

# Set up grub on chroot-dev
function GrubSetup {
  local CHROOTDEV
  local CHROOTKRN
  local GRUBCMDLINE
  local ROOTTOK
  local VGCHECK

  # Check what kernel is in the chroot-dev
  CHROOTKRN=$(
      chroot "${CHROOTMNT}" rpm --qf '%{version}-%{release}.%{arch}\n' -q kernel
    )

  # See if chroot-dev is LVM2'ed
  VGCHECK="$( grep \ "${CHROOTMNT}"\  /proc/mounts | \
      awk '/^\/dev\/mapper/{ print $1 }'
    )"

  # Determine our "root=" token
  if [[ ${VGCHECK:-} == '' ]]
  then
    CHROOTDEV="$( findmnt -cnM "${CHROOTMNT}" -o SOURCE )"
    CHROOTFSTYP="$( findmnt -cnM "${CHROOTMNT}" -o FSTYPE )"

    if [[ ${CHROOTFSTYP} == "xfs" ]]
    then
      ROOTTOK="root=LABEL=$(
        xfs_admin -l "${CHROOTDEV}" | sed -e 's/"$//' -e 's/^.* = "//'
      )"
    elif [[ ${CHROOTFSTYP} == ext[2-4] ]]
    then
      ROOTTOK="root=LABEL=$(
        e2label "${CHROOTDEV}"
      )"
    else
      err_exit "Could not determine chroot-dev's filesystem-label"
    fi

    CHROOTDEV="$( ClipPartition "${CHROOTDEV}" )"
  else
    ROOTTOK="root=${VGCHECK}"
    VGCHECK="${VGCHECK%-*}"

    # Compute PV from VG info
    CHROOTDEV="$(
        vgs --no-headings -o pv_name "${VGCHECK//\/dev\/mapper\//}" | \
        sed 's/[ 	][ 	]*//g'
      )"

    CHROOTDEV="$( ClipPartition "${CHROOTDEV}" )"

    # Make sure device is valid
    if [[ -b ${CHROOTDEV} ]]
    then
      err_exit "Found ${CHROOTDEV}" NONE
    else
      err_exit "No such device ${CHROOTDEV}"
    fi

    # Exit if computation failed
    if [[ ${CHROOTDEV:-} == '' ]]
    then
      err_exit "Failed to find PV from VG"
    fi

  fi

  # Assemble string for GRUB_CMDLINE_LINUX value
  GRUBCMDLINE="${ROOTTOK} "
  GRUBCMDLINE+="vconsole.keymap=us "
  GRUBCMDLINE+="vconsole.font=latarcyrheb-sun16 "
  GRUBCMDLINE+="console=tty1 "
  GRUBCMDLINE+="console=ttyS0,115200n8 "
  GRUBCMDLINE+="rd.blacklist=nouveau "
  GRUBCMDLINE+="net.ifnames=0 "
  GRUBCMDLINE+="nvme_core.io_timeout=4294967295 "
  if [[ ${FIPSDISABLE} == "true" ]]
  then
    GRUBCMDLINE+="fips=0"
  fi

  # Write default/grub contents
  err_exit "Writing default/grub file..." NONE
  (
    printf 'GRUB_TIMEOUT=%s\n' "${GRUBTMOUT}"
    printf 'GRUB_DISTRIBUTOR="CentOS Linux"\n'
    printf 'GRUB_DEFAULT=saved\n'
    printf 'GRUB_DISABLE_SUBMENU=true\n'
    printf 'GRUB_TERMINAL_OUTPUT="console"\n'
    printf 'GRUB_SERIAL_COMMAND="serial --speed=115200"\n'
    printf 'GRUB_CMDLINE_LINUX="%s"\n' "${GRUBCMDLINE}"
    printf 'GRUB_DISABLE_RECOVERY=true\n'
    printf 'GRUB_DISABLE_OS_PROBER=true\n'
    printf 'GRUB_ENABLE_BLSCFG=true\n'
  ) > "${CHROOTMNT}/etc/default/grub" || \
    err_exit "Failed writing default/grub file"

  # Reinstall the grub-related RPMs (just in case)
  err_exit "Reinstalling the GRUB-related RPMs ..." NONE
  dnf reinstall -y shim-x64 grub2-\* || \
    err_exit "Failed while reinstalling the GRUB-related RPMs" NONE
  err_exit "GRUB-related RPMs reinstalled"  NONE


  # Install GRUB2 bootloader when EFI not active
  if [[ ! -d /sys/firmware/efi ]]
  then
  chroot "${CHROOTMNT}" /bin/bash -c "/sbin/grub2-install ${CHROOTDEV}"
  fi

  # Install GRUB config-file(s)
  err_exit "Installing BIOS-boot GRUB components..." NONE
  chroot "${CHROOTMNT}" /bin/bash -c "grub2-install ${CHROOTDEV} \
    --target=i386-pc"|| \
    err_exit "Failed to install BIOS-boot GRUB components"
  err_exit "BIOS-boot GRUB components installed" NONE

  err_exit "Installing GRUB config-file..." NONE
  chroot "${CHROOTMNT}" /bin/bash -c "/sbin/grub2-mkconfig \
    -o /boot/grub2/grub.cfg --update-bls-cmdline" || \
    err_exit "Failed to install GRUB config-file"
  err_exit "GRUB config-file installed" NONE

  # Make intramfs in chroot-dev
  if [[ ${FIPSDISABLE} != "true" ]]
  then
    err_exit "Attempting to enable FIPS mode in ${CHROOTMNT}..." NONE
    chroot "${CHROOTMNT}" /bin/bash -c "fips-mode-setup --enable" || \
      err_exit "Failed to enable FIPS mode"
  else
    err_exit "Installing initramfs..." NONE
    chroot "${CHROOTMNT}" dracut -fv "/boot/initramfs-${CHROOTKRN}.img" \
      "${CHROOTKRN}" || \
      err_exit "Failed installing initramfs"
  fi


}

function GrubSetup_BIOS {
  err_exit "Installing helper-script..." NONE
  install -bDm 0755  "$( dirname "${0}" )/DualMode-GRUBsetup.sh" \
    "${CHROOTMNT}/root" || err_exit "Failed installing helper-script"
  err_exit "SUCCESS" NONE

  err_exit "Running helper-script..." NONE
  chroot "${CHROOTMNT}" /root/DualMode-GRUBsetup.sh || \
    err_exit "Failed running helper-script..."
  err_exit "SUCCESS" NONE

  err_exit "Cleaning up helper-script..." NONE
  rm "${CHROOTMNT}/root/DualMode-GRUBsetup.sh" || \
    err_exit "Failed removing helper-script..."
  err_exit "SUCCESS" NONE

}


# Configure SELinux
function SELsetup {
  if [[ -d ${CHROOTMNT}/sys/fs/selinux ]]
  then
    err_exit "Setting up SELinux configuration..." NONE
    chroot "${CHROOTMNT}" /bin/sh -c "
      (
        rpm -q --scripts selinux-policy-targeted | \
        sed -e '1,/^postinstall scriptlet/d' | \
        sed -e '1i #!/bin/sh'
      ) > /tmp/selinuxconfig.sh ; \
      bash -x /tmp/selinuxconfig.sh 1" || \
    err_exit "Failed cofiguring SELinux"

    err_exit "Running fixfiles in chroot..." NONE
    chroot "${CHROOTMNT}" /sbin/fixfiles -f relabel || \
      err_exit "Errors running fixfiles"
  else
    # The selinux-policy RPM's %post script currently is not doing The Right
    # Thing (TM), necessitating the creation of a /.autorelabel file in this
    # section. Have filed BugZilla ID #2208282 with Red Hat
    touch "${CHROOTMNT}/.autorelabel" || \
      err_exit "Failed creating /.autorelabel file"

    err_exit "SELinux not available" NONE
  fi
}

# Timezone setup
function TimeSetup {

  # If requested TZ exists, set it
  if [[ -e ${CHROOTMNT}/usr/share/zoneinfo/${TARGTZ} ]]
  then
    err_exit "Setting default TZ to ${TARGTZ}..." NONE
    rm -f "${CHROOTMNT}/etc/localtime" || \
      err_exit "Failed to clear current TZ default"
    chroot "${CHROOTMNT}" ln -s "/usr/share/zoneinfo/${TARGTZ}" \
      /etc/localtime || \
      err_exit "Failed setting ${TARGTZ}"
  else
    true
  fi
}

# Make /tmp a tmpfs
function SetupTmpfs {
  if [[ ${NOTMPFS:-} == "true" ]]
  then
    err_exit "Requested no use of tmpfs for /tmp" NONE
  else
    err_exit "Unmasking tmp.mount unit..." NONE
    chroot "${CHROOTMNT}" /bin/systemctl unmask tmp.mount || \
      err_exit "Failed unmasking tmp.mount unit"

    err_exit "Enabling tmp.mount unit..." NONE
    chroot "${CHROOTMNT}" /bin/systemctl enable tmp.mount || \
      err_exit "Failed enabling tmp.mount unit"

  fi
}

# Disable kdump
function DisableKdumpSvc {
  err_exit "Disabling kdump service... " NONE
  chroot "${CHROOTMNT}" /bin/systemctl disable --now kdump || \
    err_exit "Failed while disabling kdump service"

  err_exit "Masking kdump service... " NONE
  chroot "${CHROOTMNT}" /bin/systemctl mask --now kdump || \
    err_exit "Failed while masking kdump service"
}

# Initialize authselect Subsystem
function authselectInit {
  err_exit "Attempting to initialize authselect... " NONE
  chroot "${CHROOTMNT}" /bin/authselect select sssd --force || \
    err_exit "Failed initializing authselect" 1
  err_exit "Succeeded initializing authselect" NONE
}


######################
## Main program-flow
######################
OPTIONBUFR=$( getopt \
  -o Ff:hm:t:Xz: \
  --long cross-distro,fstype:,grub-timeout:,help,mountpoint:,no-fips,no-tmpfs,timezone,use-submgr \
  -n "${PROGNAME}" -- "$@")

eval set -- "${OPTIONBUFR}"

###################################
# Parse contents of ${OPTIONBUFR}
###################################
while true
do
  case "$1" in
    --use-submgr)
        SUBSCRIPTION_MANAGER="enabled"
        shift 1;
        ;;
    -F|--no-fips)
        FIPSDISABLE="true"
        shift 1;
        ;;
    -f|--fstype)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            FSTYPE="${2}"
            if [[ $( grep -qw "${FSTYPE}" <<< "${VALIDFSTYPES[*]}" ) -ne 0 ]]
            then
              err_exit "Invalid fstype [${FSTYPE}] requested"
            fi
            shift 2;
            ;;
        esac
        ;;
    -g|--grub-timeout)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            GRUBTMOUT="${2}"
            shift 2;
            ;;
        esac
        ;;
    --no-tmpfs)
        NOTMPFS="true"
        ;;
    -h|--help)
        UsageMsg 0
        ;;
    -m|--mountpoint)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            CHROOTMNT="${2}"
            shift 2;
            ;;
        esac
        ;;
    -X|--cross-distro)
        ISCROSSDISTRO=TRUE
        shift
        break
        ;;
    -z|--timezone)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            TARGTZ="${2}"
            shift 2;
            ;;
        esac
        ;;
    --)
      shift
      break
      ;;
    *)
      err_exit "Internal error!"
      exit 1
      ;;
  esac
done

###############
# Call to arms!

# Create /etc/fstab in chroot-dev
CreateFstab

# Set /tmp as a tmpfs
SetupTmpfs

# Ensure no systemd-rc-local-generator log-spamming
ConfigureRcLocalGenerator

# Configure logging
ConfigureLogging

# Configure networking
ConfigureNetworking

# Set up firewalld
FirewalldSetup

# Configure time services
TimeSetup

# Configure cloud-init
ConfigureCloudInit

# Do GRUB2 setup tasks
GrubSetup

# Do GRUB2 setup tasks for BIOS-boot compatibility
GrubSetup_BIOS

# Initialize authselect subsystem
authselectInit

# Wholly disable kdump service
DisableKdumpSvc

# Clean up yum/dnf history
CleanHistory

# Apply SELinux settings
SELsetup

