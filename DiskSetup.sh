#!/bin/bash
set -eu -o pipefail
#
# Script to automate basic setup of CHROOT device
#
#################################################################
PROGNAME="$( basename "$0" )"
PROGDIR="$( dirname "${0}" )"
BOOTDEVSZMIN="768"
BOOTDEVSZ="${BOOTDEVSZ:-${BOOTDEVSZMIN}}"
UEFIDEVSZ="${UEFIDEVSZ:-128}"
CHROOTDEV="${CHROOTDEV:-UNDEF}"
DEBUG="${DEBUG:-UNDEF}"
FSTYPE="${FSTYPE:-xfs}"
LABEL_BOOT="${LABEL_BOOT:-boot_disk}"
LABEL_UEFI="${LABEL_UEFI:-UEFI_DISK}"

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
    printf '\t%-4s%s\n' '-B' 'Boot-partition size (default: 768MiB)'
    printf '\t%-4s%s\n' '-d' 'Base dev-node used for build-device'
    printf '\t%-4s%s\n' '-f' 'Filesystem-type used for root filesystems (default: xfs)'
    printf '\t%-4s%s\n' '-h' 'Print this message'
    printf '\t%-4s%s\n' '-l' ' for /boot filesystem (default: boot_disk)'
    printf '\t%-4s%s\n' '-L' ' for /boot/efi filesystem (default: UEFI_DISK)'
    printf '\t%-4s%s\n' '-p' 'Comma-delimited string of colon-delimited partition-specs'
    printf '\t%-6s%s\n' '' 'Default layout:'
    printf '\t%-8s%s\n' '' '/:rootVol:4'
    printf '\t%-8s%s\n' '' 'swap:swapVol:2'
    printf '\t%-8s%s\n' '' '/home:homeVol:1'
    printf '\t%-8s%s\n' '' '/var:varVol:2'
    printf '\t%-8s%s\n' '' '/var/tmp:varTmpVol:2'
    printf '\t%-8s%s\n' '' '/var/log:logVol:2'
    printf '\t%-8s%s\n' '' '/var/log/audit:auditVol:100%FREE'
    printf '\t%-4s%s\n' '-r' 'Label to apply to root-partition if not using LVM (default: root_disk)'
    printf '\t%-4s%s\n' '-v' 'Name assigned to root volume-group (default: VolGroup00)'
    printf '\t%-4s%s\n' '-U' 'UEFI-partition size (default: 256MiB)'
    echo "  GNU long options:"
    printf '\t%-20s%s\n' '--boot-size' 'See "-B" short-option'
    printf '\t%-20s%s\n' '--disk' 'See "-d" short-option'
    printf '\t%-20s%s\n' '--fstype' 'See "-f" short-option'
    printf '\t%-20s%s\n' '--help' 'See "-h" short-option'
    printf '\t%-20s%s\n' '--label-boot' 'See "-l" short-option'
    printf '\t%-20s%s\n' '--label-uefi' 'See "-L" short-option'
    printf '\t%-20s%s\n' '--partition-string' 'See "-p" short-option'
    printf '\t%-20s%s\n' '--rootlabel' 'See "-r" short-option'
    printf '\t%-20s%s\n' '--uefi-size' 'See "-U" short-option'
    printf '\t%-20s%s\n' '--vgname' 'See "-v" short-option'
  )
  exit "${SCRIPTEXIT}"
}

# Partition as LVM
function CarveLVM {
  local ITER
  local MOUNTPT
  local PARTITIONARRAY
  local PARTITIONSTR
  local VOLFLAG
  local VOLNAME
  local VOLSIZE

  # Whether to use flag-passed partition-string or default values
  if [ -z ${GEOMETRYSTRING+x} ]
  then
    # This is fugly but might(??) be easier for others to follow/update
    PARTITIONSTR="/:rootVol:4"
    PARTITIONSTR+=",swap:swapVol:2"
    PARTITIONSTR+=",/home:homeVol:1"
    PARTITIONSTR+=",/var:varVol:2"
    PARTITIONSTR+=",/var/tmp:varTmpVol:2"
    PARTITIONSTR+=",/var/log:logVol:2"
    PARTITIONSTR+=",/var/log/audit:auditVol:100%FREE"
  else
    PARTITIONSTR="${GEOMETRYSTRING}"
  fi

  # Convert ${PARTITIONSTR} to iterable array
  IFS=',' read -r -a PARTITIONARRAY <<< "${PARTITIONSTR}"

  # Clear the target-disk of partitioning and other structural data
  CleanChrootDiskPrtTbl

  # Lay down the base partitions
  err_exit "Laying down new partition-table..." NONE
  parted -s "${CHROOTDEV}" -- mktable gpt \
    mkpart primary "${FSTYPE}" 1049k 2m \
    mkpart primary fat16 4096s $(( 2 + UEFIDEVSZ ))m \
    mkpart primary xfs $((
      2 + UEFIDEVSZ ))m $(( ( 2 + UEFIDEVSZ ) + BOOTDEVSZ
    ))m \
    mkpart primary xfs $(( ( 2 + UEFIDEVSZ ) + BOOTDEVSZ ))m 100% \
    set 1 bios_grub on \
    set 2 esp on \
    set 3 bls_boot on \
    set 4 lvm on || \
      err_exit "Failed laying down new partition-table"

  ## Create LVM objects

  # Let's only attempt this if we're a secondary EBS
  if [[ ${CHROOTDEV} == /dev/xvda ]] || [[ ${CHROOTDEV} == /dev/nvme0n1 ]]
  then
    err_exit "Skipping explicit pvcreate opertion... " NONE
  else
    err_exit "Creating LVM2 PV ${CHROOTDEV}${PARTPRE:-}4..." NONE
    pvcreate "${CHROOTDEV}${PARTPRE:-}4" || \
      err_exit "PV creation failed. Aborting!"
  fi

  # Create root VolumeGroup
  err_exit "Creating LVM2 volume-group ${VGNAME}..." NONE
  vgcreate -y "${VGNAME}" "${CHROOTDEV}${PARTPRE:-}4" || \
    err_exit "VG creation failed. Aborting!"

  # Create LVM2 volume-objects by iterating ${PARTITIONARRAY}
  ITER=0
  while [[ ${ITER} -lt ${#PARTITIONARRAY[*]} ]]
  do
    MOUNTPT="$( cut -d ':' -f 1 <<< "${PARTITIONARRAY[${ITER}]}")"
    VOLNAME="$( cut -d ':' -f 2 <<< "${PARTITIONARRAY[${ITER}]}")"
    VOLSIZE="$( cut -d ':' -f 3 <<< "${PARTITIONARRAY[${ITER}]}")"

    # Create LVs
    if [[ ${VOLSIZE} =~ FREE ]]
    then
      # Make sure 'FREE' is given as last list-element
      if [[ $(( ITER += 1 )) -eq ${#PARTITIONARRAY[*]} ]]
      then
        VOLFLAG="-l"
        VOLSIZE="100%FREE"
      else
        echo "Using 'FREE' before final list-element. Aborting..."
        kill -s TERM " ${TOP_PID}"
      fi
    else
      VOLFLAG="-L"
      VOLSIZE+="g"
    fi
    lvcreate --yes -W y "${VOLFLAG}" "${VOLSIZE}" -n "${VOLNAME}" "${VGNAME}" || \
      err_exit "Failure creating LVM2 volume '${VOLNAME}'"

    # Create FSes on LVs
    if [[ ${MOUNTPT} == swap ]]
    then
      err_exit "Creating swap filesystem..." NONE
      mkswap "/dev/${VGNAME}/${VOLNAME}" || \
        err_exit "Failed creating swap filesystem..."
    else
      err_exit "Creating filesystem for ${MOUNTPT}..." NONE
      mkfs -t "${FSTYPE}" "${MKFSFORCEOPT}" "/dev/${VGNAME}/${VOLNAME}" || \
        err_exit "Failure creating filesystem for '${MOUNTPT}'"
    fi

    (( ITER+=1 ))
  done

}

# Partition with no LVM
function CarveBare {
  # Clear the target-disk of partitioning and other structural data
  CleanChrootDiskPrtTbl

  # Lay down the base partitions
  err_exit "Laying down new partition-table..." NONE
  parted -s "${CHROOTDEV}" -- mklabel gpt \
    mkpart primary "${FSTYPE}" 1049k 2m \
    mkpart primary fat16 4096s $(( 2 + UEFIDEVSZ ))m \
    mkpart primary xfs $((
      2 + UEFIDEVSZ ))m $(( ( 2 + UEFIDEVSZ ) + BOOTDEVSZ
    ))m \
    mkpart primary xfs $(( ( 2 + UEFIDEVSZ ) + BOOTDEVSZ ))m 100% \
    set 1 bios_grub on \
    set 2 esp on \
    set 3 bls_boot on || \
    err_exit "Failed laying down new partition-table"

  # Create FS on partitions
  err_exit "Creating filesystem on ${CHROOTDEV}${PARTPRE:-}4..." NONE
  mkfs -t "${FSTYPE}" "${MKFSFORCEOPT}" -L "${ROOTLABEL}" \
    "${CHROOTDEV}${PARTPRE:-}4" || \
    err_exit "Failed creating filesystem"
}

function CleanChrootDiskPrtTbl {
  local HAS_PARTS
  local PART_NUM
  local PDEV

  
  # Exit if there's no VTOC to clear
  if [[ $( parted -s "${CHROOTDEV}" print > /dev/null 2>&1 )$? -ne 0 ]]
  then
    echo "Disk has no partitions to clear"
    return
  fi

  # Iteratively nuke partitions from NVMe devices
  if [[ ${CHROOTDEV} == "/dev/nvme"* ]]
  then
    for PDEV in $( blkid | grep "${CHROOTDEV}" | sed 's/:.*$//' )
    do
      PART_NUM="${PDEV//*p/}"

      printf "Deleting partition %s from %s... " "${PART_NUM}" "${CHROOTDEV}"
      parted -sf "${CHROOTDEV}" rm "${PART_NUM}"
      echo SUCCESS
    done
  # Iteratively nuke partitions from Xen Virtual Disk devices
  elif [[ ${CHROOTDEV} == "/dev/xvd"* ]]
  then
    for PDEV in $( blkid | grep "${CHROOTDEV}" | sed 's/:.*$//' )
    do
      PART_NUM="${PDEV//*xvd?/}"

      printf "Deleting partition %s from %s... " "${PART_NUM}" "${CHROOTDEV}"
      parted -sf "${CHROOTDEV}" rm "${PART_NUM}"
      echo SUCCESS
    done
  fi

  # Ask kernel to update its partition-map of target-disk
  partprobe "${CHROOTDEV}"


  # Null-out any lingering disk structs
  err_exit "Clearing existing partition-tables..." NONE
  dd if=/dev/zero of="${CHROOTDEV}" bs=512 count=1000 > /dev/null 2>&1 || \
    err_exit "Failed clearing existing partition-tables"

  # Ask kernel, again, to update its partition-map of target-disk
  partprobe "${CHROOTDEV}" || true
}

function SetupBootParts {

  # Make filesystem for /boot/efi
  err_exit "Creating filesystem on ${CHROOTDEV}${PARTPRE:-}2..." NONE
  mkfs -t vfat -n "${LABEL_UEFI}" "${CHROOTDEV}${PARTPRE:-}2" || \
    err_exit "Failed creating filesystem"

  # Make filesystem for /boot
  err_exit "Creating filesystem on ${CHROOTDEV}${PARTPRE:-}3..." NONE
  mkfs -t "${FSTYPE}" "${MKFSFORCEOPT}" -L "${LABEL_BOOT}" \
    "${CHROOTDEV}${PARTPRE:-}3" || \
    err_exit "Failed creating filesystem"
}


######################
## Main program-flow
######################
OPTIONBUFR=$( getopt \
  -o b:B:d:f:hl:L:p:r:U:v: \
  --long boot-size:,disk:,fstype:,help,label-boot:,label-uefi:,partition-string:,rootlabel:,uefi-size:,vgname: \
  -n "${PROGNAME}" -- "$@")

eval set -- "${OPTIONBUFR}"

###################################
# Parse contents of ${OPTIONBUFR}
###################################
while true
do
  case "$1" in
    -B|--boot-size)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            BOOTDEVSZ=${2}
            if [[ ${BOOTDEVSZ} -lt ${BOOTDEVSZMIN} ]]
            then
              err_exit "Requested size for '/boot' filesystem is too small" 1
            fi
            shift 2;
            ;;
        esac
        ;;
    -d|--disk)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            CHROOTDEV=${2}
            shift 2;
            ;;
        esac
        ;;
    -f|--fstype)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          ext3|ext4)
            FSTYPE=${2}
            MKFSFORCEOPT="-F"
            shift 2;
            ;;
          xfs)
            FSTYPE=${2}
            MKFSFORCEOPT="-f"
            shift 2;
            ;;
          *)
            err_exit "Error: unrecognized/unsupported FSTYPE. Aborting..."
            shift 2;
            exit 1
            ;;
        esac
        ;;
    -h|--help)
        UsageMsg 0
        ;;
    -l|--label-boot)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            LABEL_BOOT=${2}
            shift 2;
            ;;
        esac
        ;;
    -L|--label-uefi)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            LABEL_UEFI=${2}
            shift 2;
            ;;
        esac
        ;;
    -p|--partition-string)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            GEOMETRYSTRING=${2}
            shift 2;
            ;;
        esac
        ;;
    -r|--rootlabel)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            ROOTLABEL=${2}
            shift 2;
            ;;
        esac
        ;;
    -U|--uefi-size)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
            UEFIDEVSZ=${2}
            shift 2;
            ;;
        esac
        ;;
    -v|--vgname)
        case "$2" in
          "")
            err_exit "Error: option required but not specified"
            shift 2;
            exit 1
            ;;
          *)
          VGNAME=${2}
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

# Bail if not root
if [[ ${EUID} != 0 ]]
then
  err_exit "Must be root to execute disk-carving actions"
fi

# See if our carve-target is an NVMe
if [[ ${CHROOTDEV} == "UNDEF" ]]
then
  err_exit "Failed to specify partitioning-target. Aborting"
elif [[ ${CHROOTDEV} =~ /dev/nvme ]]
then
  PARTPRE="p"
else
  PARTPRE=""
fi

# Determine how we're formatting the disk
if [[ -z ${ROOTLABEL+xxx} ]] && [[ -n ${VGNAME+xxx} ]]
then
  CarveLVM
elif [[ -n ${ROOTLABEL+xxx} ]] && [[ -z ${VGNAME+xxx} ]]
then
  CarveBare
elif [[ -z ${ROOTLABEL+xxx} ]] && [[ -z ${VGNAME+xxx} ]]
then
  err_exit "Failed to specifiy a partitioning-method. Aborting"
else
  err_exit "The '-r'/'--rootlabel' and '-v'/'--vgname' flag-options are mutually-exclusive. Exiting." 0
fi

# Take care of /boot/... paritions
SetupBootParts
