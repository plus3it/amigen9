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
GRUBPKGS_ARM=(
      grub2-efi-aa64
      grub2-efi-aa64-modules
      grub2-tools
      grub2-tools-extra
      grub2-tools-minimal
)
GRUBPKGS_X86=(
      grub2-efi-x64
      grub2-efi-x64-modules
      grub2-pc-modules
      grub2-tools
      grub2-tools-efi
      grub2-tools-minimal
)
MINXTRAPKGS=(
  chrony
  cloud-init
  cloud-utils-growpart
  dracut-config-generic
  efibootmgr
  firewalld
  gdisk
  grubby
  kernel
  kexec-tools
  libnsl
  lvm2
  python3-pip
  rng-tools
  unzip
)
EXCLUDEPKGS=(
  alsa-firmware
  alsa-tools-firmware
  biosdevname
  insights-client
  iprutils
  iwl100-firmware
  iwl1000-firmware
  iwl105-firmware
  iwl135-firmware
  iwl2000-firmware
  iwl2030-firmware
  iwl3160-firmware
  iwl5000-firmware
  iwl5150-firmware
  iwl6000g2a-firmware
  iwl6050-firmware
  iwl7260-firmware
  rhc
)
RPMFILE=${RPMFILE:-UNDEF}
RPMGRP=${RPMGRP:-core}


# shellcheck disable=SC1091
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
    printf '\t%-4s%s\n' '-a' 'List of repository-names to activate'
    printf '\t%-6s%s' '' 'Default activation: '
    GetDefaultRepos
    printf '\t%-4s%s\n' '-e' 'Extra RPMs to install from enabled repos'
    printf '\t%-4s%s\n' '-g' 'RPM-group to intall (default: "core")'
    printf '\t%-4s%s\n' '-h' 'Print this message'
    printf '\t%-4s%s\n' '-M' 'File containing list of RPMs to install'
    printf '\t%-4s%s\n' '-m' 'Where to mount chroot-dev (default: "/mnt/ec2-root")'
    printf '\t%-4s%s\n' '-r' 'List of repo-def repository RPMs or RPM-URLs to install'
    printf '\t%-4s%s\n' '-X' 'Declare to be a cross-distro build'
    printf '\t%-4s%s\n' '-x' 'List of RPMs to exclude from build-list'
    printf '\t%-20s%s\n' '--cross-distro' 'See "-X" short-option'
    printf '\t%-20s%s\n' '--exclude-rpms' 'See "-x" short-option'
    printf '\t%-20s%s\n' '--extra-rpms' 'See "-e" short-option'
    printf '\t%-20s%s\n' '--help' 'See "-h" short-option'
    printf '\t%-20s%s\n' '--mountpoint' 'See "-m" short-option'
    printf '\t%-20s%s\n' '--pkg-manifest' 'See "-M" short-option'
    printf '\t%-20s%s\n' '--repo-activation' 'See "-a" short-option'
    printf '\t%-20s%s\n' '--repo-rpms' 'See "-r" short-option'
    printf '\t%-20s%s\n' '--rpm-group' 'See "-g" short-option'
    printf '\t%-20s%s\n' '--setup-dnf' 'Addresses (OL8) distribution-specific DNF config-needs'
  )
  exit "${SCRIPTEXIT}"
}

# Default yum repository-list for selected OSes
function GetDefaultRepos {
  local -a BASEREPOS

  # Make sure we can use `rpm` command
  if [[ $(rpm -qa --quiet 2> /dev/null)$? -ne 0 ]]
  then
    err_exit "The rpm command not functioning correctly"
  fi

  case $( rpm -qf /etc/os-release --qf '%{name}' ) in
    almalinux-release)
      BASEREPOS=(
        appstream
        baseos
        extras
      )
      ;;
    centos-stream-release)
      BASEREPOS=(
        appstream
        baseos
        extras-common
      )
      ;;
    oraclelinux-release)
      BASEREPOS=(
        ol9_UEKR7
        ol9_appstream
        ol9_baseos_latest
      )
      ;;
    redhat-release-server|redhat-release)
      BASEREPOS=(
        rhel-9-appstream-rhui-rpms
        rhel-9-baseos-rhui-rpms
        rhui-client-config-server-9
      )
      ;;
    rocky-release)
      BASEREPOS=(
        appstream
        baseos
        extras
      )
      ;;
    system-release) # Amazon should be shot for this
      BASEREPOS=(
        amazonlinux
        kernel-livepatch
      )
      ;;
    *)
      echo "Unknown OS. Aborting" >&2
      exit 1
      ;;
  esac

  ( IFS=',' ; echo "${BASEREPOS[*]}" )
}

# Install base/setup packages in chroot-dev
function PrepChroot {
  local -a BASEPKGS
  local   DNF_ELEM
  local   DNF_FILE
  local   DNF_VALUE

  # Create an array of packages to install
  BASEPKGS=(
    yum-utils
  )

  # Don't try to be helpful if doing cross-distro (i.e., "bootstrapper-build")
  if [[ -z ${ISCROSSDISTRO:-} ]]
  then
    mapfile -t -O "${#BASEPKGS[@]}" BASEPKGS < <(
      rpm --qf '%{name}\n' -qf /etc/os-release ; \
      rpm --qf '%{name}\n' -qf  /etc/yum.repos.d/* 2>&1 | grep -v "not owned" | sort -u ; \
    )
  fi

  # Ensure DNS lookups work in chroot-dev
  if [[ ! -e ${CHROOTMNT}/etc/resolv.conf ]]
  then
    err_exit "Installing ${CHROOTMNT}/etc/resolv.conf..." NONE
    install -Dm 000644 /etc/resolv.conf "${CHROOTMNT}/etc/resolv.conf"
  fi

  # Ensure etc/rc.d/init.d exists in chroot-dev
  if [[ ! -e ${CHROOTMNT}/etc/rc.d/init.d ]]
  then
    install -dDm 000755 "${CHROOTMNT}/etc/rc.d/init.d"
  fi

  # Ensure etc/init.d exists in chroot-dev
  if [[ ! -e ${CHROOTMNT}/etc/init.d ]]
  then
    ln -t "${CHROOTMNT}/etc" -s ./rc.d/init.d
  fi

  # Satisfy weird, OL8-dependecy:
  # * Ensure the /etc/dnf and /etc/yum contents are present
  if [[ -n "${DNF_ARRAY:-}" ]]
  then
    err_exit "Execute DNF hack..." NONE
    for DNF_ELEM in "${DNF_ARRAY[@]}"
    do
      DNF_FILE=${DNF_ELEM//=*/}
      DNF_VALUE=${DNF_ELEM//*=/}

      err_exit "Creating ${CHROOTMNT}/etc/dnf/vars/${DNF_FILE}... " NONE
      install -bDm 0644 <(
        printf "%s" "${DNF_VALUE}"
      ) "${CHROOTMNT}/etc/dnf/vars/${DNF_FILE}" || err_exit Failed
      err_exit "Success" NONE
    done
  fi

  # Clean out stale RPMs
  if [[ $( stat /tmp/*.rpm > /dev/null 2>&1 )$? -eq 0 ]]
  then
    err_exit "Cleaning out stale RPMs..." NONE
    rm -f /tmp/*.rpm || \
      err_exit "Failed cleaning out stale RPMs"
  fi

  # Stage our base RPMs
  if [[ -n ${OSREPOS:-} ]]
  then
    dnf download \
      --disablerepo "*" \
      --enablerepo  "${OSREPOS}" \
      -y \
      --destdir /tmp "${BASEPKGS[@]}"
  else
    dnf download -y --destdir /tmp "${BASEPKGS[@]}"
  fi

  if [[ ${REPORPMS:-} != '' ]]
  then
    FetchCustomRepos
  fi

  # Initialize RPM db in chroot-dev
  err_exit "Initializing RPM db..." NONE
  rpm --root "${CHROOTMNT}" --initdb || \
    err_exit "Failed initializing RPM db"

  # Install staged RPMs
  err_exit "Installing staged RPMs..." NONE
  rpm --force --root "${CHROOTMNT}" -ivh --nodeps --nopre /tmp/*.rpm || \
    err_exit "Failed installing staged RPMs"

  # Work around recent gimpiness in yum RPM
  if [[ -d ${CHROOTMNT}/etc/yum/pluginconf.d ]]
  then
    echo "Deleting ${CHROOTMNT}/etc/yum/pluginconf.d"
    rm -rf ${CHROOTMNT}/etc/yum/pluginconf.d
  fi

  # Install dependences for base RPMs
  err_exit "Installing base RPM's dependences..." NONE
  yum --disablerepo="*" --enablerepo="${OSREPOS}" \
    --installroot="${CHROOTMNT}" -y reinstall "${BASEPKGS[@]}" || \
    err_exit "Failed installing base RPM's dependences"

  # Ensure yum-utils are installed in chroot-dev
  err_exit "Ensuring yum-utils are installed..." NONE
  yum --disablerepo="*" --enablerepo="${OSREPOS}" \
    --installroot="${CHROOTMNT}" -y install yum-utils || \
    err_exit "Failed installing yum-utils"
}

# Install selected package-set into chroot-dev
function MainInstall {
  local YUMCMD

  YUMCMD="yum --nogpgcheck --installroot=${CHROOTMNT} "
  YUMCMD+="--disablerepo=* --enablerepo=${OSREPOS} install -y "

  # If RPM-file not specified, use a group from repo metadata
  if [[ ${RPMFILE} == "UNDEF" ]]
  then
    # Expand the "core" RPM group and store as array
    mapfile -t INCLUDEPKGS < <(
      yum groupinfo "${RPMGRP}" 2>&1 | \
      sed -n '/Mandatory/,/Optional Packages:/p' | \
      sed -e '/^ [A-Z]/d' -e 's/^[[:space:]]*[-=+[:space:]]//'
    )

    # Don't assume that just because the operator didn't pass
    # a manifest-file that the repository is properly run and has
    # the group metadata that it ought to have
    if [[ ${#INCLUDEPKGS[*]} -eq 0 ]]
    then
      err_exit "Oops: unable to parse metadata from repos"
    fi
  # Try to read from local file
  elif [[ -s ${RPMFILE} ]]
  then
    err_exit "Reading manifest-file" NONE
    mapfile -t INCLUDEPKGS < "${RPMFILE}"
  # Try to read from URL
  elif [[ ${RPMFILE} =~ http([s]{1}|):// ]]
  then
    err_exit "Reading manifest from ${RPMFILE}" NONE
    mapfile -t INCLUDEPKGS < <( curl -sL "${RPMFILE}" )
    if [[ ${#INCLUDEPKGS[*]} -eq 0 ]] ||
      [[ ${INCLUDEPKGS[*]} =~ "Not Found" ]] ||
      [[ ${INCLUDEPKGS[*]} =~ "Access Denied" ]]
    then
      err_exit "Failed reading manifest from URL"
    fi
  else
    err_exit "The manifest file does not exist or is empty"
  fi

  # Add extra packages to include-list (array)
  case $( uname -i ) in
    x86_64)
      INCLUDEPKGS=(
        "${INCLUDEPKGS[@]}"
        "${MINXTRAPKGS[@]}"
        "${EXTRARPMS[@]}"
        "${GRUBPKGS_X86[@]}"
      )
      if [[ $( grep -q 'Amazon Linux' /etc/os-release )$? -eq 0 ]]
      then
        INCLUDEPKGS+=(
          dosfstools
          efi-filesystem
          grub2-efi-x64-ec2
          selinux-policy
          selinux-policy-targeted
          yum
        )
      else
        INCLUDEPKGS+=(
          shim-x64
          dhcp-client
        )
      fi
      ;;
    aarch64)
      INCLUDEPKGS=(
        "${INCLUDEPKGS[@]}"
        "${MINXTRAPKGS[@]}"
        "${EXTRARPMS[@]}"
        "${GRUBPKGS_ARM[@]}"
      )
      if [[ $( grep -q 'Amazon Linux' /etc/os-release )$? -ne 0 ]]
      then
        INCLUDEPKGS+=(
          shim-aa64
          shim-unsigned-aarch64
          dhcp-client
        )
      fi
      ;;
    *)
      err_exit "Architecture not yet supported" 1
      ;;
  esac

  # Remove excluded packages from include-list
  for EXCLUDE in "${EXCLUDEPKGS[@]}" "${EXTRAEXCLUDE[@]}"
  do
    INCLUDEPKGS=( "${INCLUDEPKGS[@]//*${EXCLUDE}*}" )
  done

  # Install packages
  YUMCMD+="$( IFS=' ' ; echo "${INCLUDEPKGS[*]}" )"
  ${YUMCMD} --allowerasing -x "$( IFS=',' ; echo "${EXCLUDEPKGS[*]}" )"

  # Verify installation
  err_exit "Verifying installed RPMs" NONE
  for RPM in "${INCLUDEPKGS[@]}"
  do
    if [[ ${RPM} = '' ]]
    then
      continue
    fi

    err_exit "Checking presence of ${RPM}..." NONE
    chroot "${CHROOTMNT}" bash -c "rpm -q ${RPM}" || \
    err_exit "Failed finding ${RPM}"
  done
}

# Get custom repo-RPMs
function FetchCustomRepos {
  local REPORPM

  for REPORPM in ${REPORPMS//,/ }
  do
    if [[ ${REPORPM} =~ http[s]*:// ]]
    then
      err_exit "Fetching ${REPORPM} with curl..." NONE
      ( cd /tmp && curl --connect-timeout 15 -O  -sL "${REPORPM}" ) || \
        err_exit "Fetch failed"
    else
      err_exit "Fetching ${REPORPM} with yum..." NONE
      yumdownloader --destdir=/tmp "${REPORPM}" > /dev/null 2>&1 || \
        err_exit "Fetch failed"
    fi
  done
}


######################
## Main program-flow
######################
OPTIONBUFR=$( getopt \
  -o a:e:Fg:hM:m:r:Xx: \
  --long cross-distro,exclude-rpms:,extra-rpms:,help,mountpoint:,pkg-manifest:,repo-activation:,repo-rpms:,rpm-group:,setup-dnf: \
  -n "${PROGNAME}" -- "$@")

eval set -- "${OPTIONBUFR}"

###################################
# Parse contents of ${OPTIONBUFR}
###################################
while true
do
  case "$1" in
    -a|--repo-activation)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            OSREPOS=${2}
            shift 2;
            ;;
        esac
        ;;
    -e|--extra-rpms)
        case "$2" in
          "")
            echo "Error: option required but not specified" > /dev/stderr
            shift 2;
            exit 1
            ;;
          *)
            IFS=, read -ra EXTRARPMS <<< "$2"
            shift 2;
            ;;
        esac
        ;;
    -g|--rpm-group)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            RPMGRP=${2}
            shift 2;
            ;;
        esac
        ;;
    -h|--help)
        UsageMsg 0
        ;;
    --setup-dnf)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            IFS=, read -ra DNF_ARRAY <<< "$2"
            shift 2;
            ;;
        esac
        ;;
    -M|--pkg-manifest)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            RPMFILE=${2}
            shift 2;
            ;;
        esac
        ;;
    -m|--mountpoint)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            CHROOTMNT=${2}
            shift 2;
            ;;
        esac
        ;;
    -r|--repo-rpms)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            REPORPMS=${2}
            shift 2;
            ;;
        esac
        ;;
    -X|--cross-distro)
        ISCROSSDISTRO=TRUE
        shift
        ;;
    -x|--exclude-rpms)
        case "$2" in
          "")
            echo "Error: option required but not specified" > /dev/stderr
            shift 2;
            exit 1
            ;;
          *)
            IFS=, read -ra EXTRAEXCLUDE <<< "$2"
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

# Repos to activate
if [[ ${OSREPOS:-} == '' ]]
then
  OSREPOS="$( GetDefaultRepos )"
fi

# Install minimum RPM-set into chroot-dev
PrepChroot

# Install the desired RPM-group or manifest-file
MainInstall

#############################################
## Ensure AMI repo-activations are correct ##
# disable any repo that might interfere
chroot "${CHROOTMNT}" /usr/bin/yum-config-manager --disable "*"

# Enable the requested list of repos
chroot "${CHROOTMNT}" /usr/bin/yum-config-manager --enable "${OSREPOS}"
