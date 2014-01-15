#!/bin/bash
##
## Copyright (C) 2014 Y.Morikawa <http://moya-notes.blogspot.jp/>
##
## License: MIT License  (See LICENSE.md)
##
########################################
## Settings
########################################

# Working Base Directory
BASE_DIR="${HOME}/Pictures/FlashAir"

# Network Device for Wifi (for connection to FlashAir Wifi)
NW_DEV="en0"
#NW_DEV="en1"

# FlashAir Wifi SSID
FLAIR_SSID="flashair"

# FlashAir Index URL & Photos indexes keyword
FLAIR_HOST="flashair"
FLAIR_URL="http://${FLAIR_HOST}/DCIM/101OLYMP"
PHOTO_KEYWORD="^wlansd"

# Sub Directory for Unclassified files
UNCLASS_DIR="someday"

# Post Script (This is executed after archive)
POST_SCRIPT=""

####################
## Local Archived Settings (selective)

# Local Directory Path for Photos Archived
#   (If the value is blank, local archive is not performed)
ARCH_LOCAL_PATH=""

####################
## Remote Archived Settings (selective)

# Remote Directory Path for Photos Archived
#   (If the value is blank, remote archive is not performed)
ARCH_REMOTE_PATH=""

# Network Attachment Storage (NAS) Settings
NAS_PROT="smb"    # "smb" or "afp"
NAS_USER="$USER"
NAS_SERVER="192.168.1.10"
NAS_MOUNT_PATH="share"
NAS_LOCAL_PATH="/Volumes/share"

########################################
## Internal Settings (Do not modified)
########################################

# exiftool Command Name (exiftool displays shooting date and time of various files)
EXIFTOOL=exiftool

# Directory for Logs
LOG_DIR="${BASE_DIR}/logs"

# Archived Photos List Cache File
ARCH_CACHE="${BASE_DIR}/flashair-photos-sync-archived.cache"

SCRIPT_NAME=$(basename $0 .sh)

DATE=$( date +%Y%m%d-%H%M%S )

SUMMARY_LOG="${LOG_DIR}/${SCRIPT_NAME}-summary.log.${DATE}"

WLAN_PREFIX="com.apple.network.wlan.ssid."

RESOLV_CONF="/etc/resolv.conf"

# Directory for FlashAir Index files
INDEX_DIR="${BASE_DIR}/.${SCRIPT_NAME}.indexes.tmp"

# Directory for Photos temporary location
PHOTO_DIR="${BASE_DIR}/.${SCRIPT_NAME}.photos.tmp"

case "$( echo $PHOTO_DIR | xargs echo )" in
    /*)
        PHOTO_PATH="${PHOTO_DIR}"
        ;;
    *)
        PHOTO_PATH="$( pwd )/${PHOTO_DIR}"
        ;;
esac

# Directory for Photos Tree
TREE_DIR="${BASE_DIR}/.${SCRIPT_NAME}.photos.tree.tmp"

# Directory for Temporary Download by cURL
CURL_DIR="${BASE_DIR}/.${SCRIPT_NAME}.curl.tmp"

WIFI_SWT_MAX_CNT=20

FLAIR_IDX_DL_MAX_CNT=7

RESTORE_NAS_MAX_CNT=5

TMP_FILE_PRE="${BASE_DIR}/.${SCRIPT_NAME}.tmp."
SWT_WIFI="${TMP_FILE_PRE}swt-wifi.$$"
LOCAL_LIST="${TMP_FILE_PRE}local.$$"
FLAIR_LIST_RAW="${TMP_FILE_PRE}flair.raw.$$"
FLAIR_LIST="${TMP_FILE_PRE}flair.$$"
SKIP_LIST="${TMP_FILE_PRE}skip.$$"
GET_LIST="${TMP_FILE_PRE}get.$$"
GET_CNT="${TMP_FILE_PRE}get.cnt.$$"
RESULT_LOG="${TMP_FILE_PRE}result.$$"
DATE_INFO="${TMP_FILE_PRE}date.$$"
PHOTO_LIST="${TMP_FILE_PRE}photo-list.$$"
PERM_CHK="${TMP_FILE_PRE}permchk.$$"

########################################
## Functions
########################################

return_org_dir(){
    if [ -n "${ORG_DIR}" ]; then
        cd ${ORG_DIR}
    fi
}

abort_for_undefined(){
    echo "" >&2
    while [ $# -gt 0 ]; do
        echo "  ERROR: \"\$$1\" is undefined." >&2
        shift
    done
    echo "" >&2
    exit 1
}

clean_and_compress(){
    echo ""                                            >> "$SUMMARY_LOG"
    echo "[Cleaning Temporary Files and Directories]"  >> "$SUMMARY_LOG"

    rm -fv "${TMP_FILE_PRE}"* "${INDEX_DIR}/"*         >> "$SUMMARY_LOG" 2>&1
    rmdir "${INDEX_DIR}/"                              >> "$SUMMARY_LOG" 2>&1
    curldir_cleaning
    rm -rfv "${TREE_DIR}"                              >> "$SUMMARY_LOG" 2>&1

    echo ""                                          >> "$SUMMARY_LOG"
    echo "[Log Compress]"                            >> "$SUMMARY_LOG"
    echo ""                                          >> "$SUMMARY_LOG"
    echo "Date/Time: $( date '+%Y-%m-%d %H:%M:%S' )" >> "$SUMMARY_LOG"
    echo "--- Log is ended ---"                      >> "$SUMMARY_LOG"
    gzip "$SUMMARY_LOG"

    echo ""
    echo "  [Logs]"
    echo "    ${SUMMARY_LOG}.gz"
    echo ""
}

curldir_cleaning(){
    rm -f "${CURL_DIR}/"* > /dev/null 2>&1
    rmdir "${CURL_DIR}/"  > /dev/null 2>&1
}

photos_cleaning(){
    rm -f "${PHOTO_DIR}/"* >&2
    rmdir "${PHOTO_DIR}/"
}

restore_wifi(){

    ####################
    ## Wifi is restored to original setting

    cur_wifi_ssid=$( networksetup -getairportnetwork ${NW_DEV} | awk '{print $NF}' )
    
    if [ ! "$cur_wifi_ssid" == "$org_wifi_ssid" ]; then
    
        if [ -n "${org_wifi_is_not_found}" ]; then
            echo ""                               >> "$SUMMARY_LOG"
            echo "[Wifi Setting is not Restored]" >> "$SUMMARY_LOG"
            
        else
            echo ""                               >> "$SUMMARY_LOG"
            echo -n "[Wifi Setting is Restored] " >> "$SUMMARY_LOG"
            echo "  " >&2
            echo -n "  Wifi Setting is being restored ... " >&2
            
            echo ${org_wifi_back_cmd[1]} | xargs ${org_wifi_back_cmd[0]}
            
            cur_wifi_ssid=$( networksetup -getairportnetwork ${NW_DEV} | awk '{print $NF}' )
            
            if [ "$cur_wifi_ssid" == "$org_wifi_ssid" ]; then
                echo "Success"  >> "$SUMMARY_LOG"
                echo "OK" >&2
            else
                echo "Failed"  >> "$SUMMARY_LOG"
                echo "Failed" >&2
            fi
        fi

        wait_resolvconf_update
    fi
}

restore_nas(){
    
    ####################
    ## Network Drives Re-Mmount

    if [ ${#nas_org_mount_cmd[*]} -gt 0 ]; then
        echo ""                           >> "$SUMMARY_LOG"
        echo "[Network Drives Re-Mount]"  >> "$SUMMARY_LOG"
        echo ""  >&2
        echo "  Network Drives Re-Mount" >&2
    else
        return
    fi

    for mo_cmd in ${nas_org_mount_cmd[@]}; do
        lpath=$( echo $mo_cmd | awk '{print $NF}' )
        
        echo -n "  Mount \"$lpath\": "  >> "$SUMMARY_LOG"
        echo -n "    \"$lpath\" is being mounted ... " >&2
        
        test -d "$lpath" || mkdir -p $lpath
        cmd=$( echo $mo_cmd | awk '{print $1}' )
        args=$( echo $mo_cmd | sed "s|^${cmd} ||g" )

        restore_nas_cnt=$RESTORE_NAS_MAX_CNT
        success=
        while [ -z "$success" ]; do
            restore_nas_cnt=$( expr $restore_nas_cnt - 1 )

            echo $args | xargs $cmd >/dev/null 2>&1

            if [ $? -ne 0 ]; then
                echo -n "." >&2
            else
                success=1
                echo "Success"  >> "$SUMMARY_LOG"
                echo " OK" >&2
                break
            fi

            if [ $restore_nas_cnt -le 0 ]; then
                echo "Failed"  >> "$SUMMARY_LOG"
                echo " Failed" >&2
                break
            fi

            sleep 1
        done

    done
}

confirm_sync(){
    echo ""
    echo "  Dry run is done. (Destination: \"$1/\")"
    echo ""
    echo "  1 (default): Actual Sync is executed"
    echo "  2          : Check Again with pager (.ex  rsync -n .. | less )"
    echo "  3          : Cancel"
    echo ""
    echo -n "  Please Select [1]: "

    if [ -z "$assume_default_answer" ]; then
        read yn
    else
        echo "(-y option is enable. Default answer is selected)"
        sleep 2
        yn=
    fi
}

archive_by_rsync(){

    src="$1"
    dst="$2"

    rsync -n -avLP "${src}" "${dst}"

    rsync -n -avLP "${src}" "${dst}" >> "$SUMMARY_LOG"
    echo ""                          >> "$SUMMARY_LOG"

    confirm_sync "${dst}"

    while : ; do
        case $yn in
            [3]*)
                echo ""
                echo "  Interrupted"
                echo ""
                echo "  -- rsync is CANCELED"       >> "$SUMMARY_LOG"
                return 1
                ;;
            [2]*)
                rsync -n -avL "${src}" "${dst}" | less
                confirm_sync "${dst}"
                ;;
            *)
                rsync -avLP "${src}" "${dst}"
                stat=$?
                echo "  -- rsync is DONE. (exit status: $stat)"  >> "$SUMMARY_LOG"
                return $stat
                ;;
        esac
    done
}

wait_resolvconf_update(){
    echo -n "    Waiting update of \"$RESOLV_CONF\" ." >&2
    while [ ! -r "$RESOLV_CONF" ]; do
        echo -n "."
        sleep 1
    done
    echo " done."  >&2
}

sigint_trap(){
    echo "" >&2
    echo "  SIGING is received. (ex. Ctrl-C) " >&2
    echo "" >&2
    echo "  Please Wait a minute, Now restoring Wifi and NAS .. " >&2
    return_org_dir
    restore_wifi
    restore_nas
    exit $(expr 128 + 2)
}

help_msg(){
    echo ""
    echo "$(basename $0): "
    echo ""
    echo "Usage: "
    echo "   ./$(basename $0) [Options]"
    echo ""
    echo "Options: "
    echo "   -f: Full Operation (Download and Archive)"
    echo "   -d: Download from FlashAir ONLY (Photos are stored in a temporary directory)"
    echo "   -a: Archived to Local/Remote Directory ONLY"
    echo "   -y: Assume default answer; assume that the answer to any question which would be asked is default answer."
    echo "   -c: Clean Archived Photos List Cache File"
    echo "   -h: Display this help message"
    echo ""
}

########################################
## Trap Settigs
########################################

# Ctrl-C call sigint_trap
trap sigint_trap 2


########################################
## Command Line Options Parser
########################################

if [ $# -lt 1 ]; then
    help_msg
    exit
fi

while (( $# > 0 )) ; do
    case "$1" in
        -f)
            opt_full_opr=1
            shift
            ;;
        -d)
            opt_download_only=1
            shift
            ;;
        -a)
            opt_arch_only=1
            shift
            ;;
        -y)
            opt_yes=1
            shift
            ;;
        -c)
            opt_clean_arch_cache=1
            shift
            ;;
        -h)
            help_msg
            shift
            exit
            ;;
        *)
            echo "" >&2
            echo "  ERROR: \"$1\" is unknown option."     >&2
            echo "         Please use following options"  >&2
            echo "" >&2
            help_msg
            exit 1
            ;;
    esac
done

########################################
## Variables Consistency Checks
########################################

test -n "$BASE_DIR"      || abort_for_undefined BASE_DIR      
test -n "$LOG_DIR"       || abort_for_undefined LOG_DIR       
test -n "$NW_DEV"        || abort_for_undefined NW_DEV        
test -n "$FLAIR_SSID"    || abort_for_undefined FLAIR_SSID    
test -n "$FLAIR_HOST"    || abort_for_undefined FLAIR_HOST    
test -n "$FLAIR_URL"     || abort_for_undefined FLAIR_URL     
test -n "$PHOTO_KEYWORD" || abort_for_undefined PHOTO_KEYWORD 
#test -n "$JHEAD"         || abort_for_undefined JHEAD
test -n "$EXIFTOOL"      || abort_for_undefined EXIFTOOL
test -n "$ARCH_CACHE"    || abort_for_undefined ARCH_CACHE    
test -n "$UNCLASS_DIR"   || abort_for_undefined UNCLASS_DIR    

if [ -z "$ARCH_LOCAL_PATH" ] && [ -z "$ARCH_REMOTE_PATH" ]; then
    echo "" >&2
    echo "  WARNING: Please set \$ARCH_LOCAL_PATH or \$ARCH_REMOTE_PATH " >&2
    abort_for_undefined ARCH_LOCAL_PATH ARCH_REMOTE_PATH
fi

if [ -n "$ARCH_REMOTE_PATH" ]; then
    if  [ -z "${NAS_PROT}" ] || \
        [ -z "${NAS_USER}" ] || \
        [ -z "${NAS_SERVER}" ] || \
        [ -z "${NAS_MOUNT_PATH}" ] || \
        [ -z "${NAS_LOCAL_PATH}" ];then \
        
        echo "" >&2
        echo "  ERROR: In Remote Archive Mode, following values must be valid" >&2
        echo "" >&2
        echo "         \$NAS_PROT \$NAS_USER \$NAS_SERVER \$NAS_MOUNT_PATH \$NAS_LOCAL_PATH" >&2
        echo "" >&2
        exit 1
    fi
fi

if [ ! -r "$RESOLV_CONF" ]; then
    echo "" >&2
    echo "  ERROR: \"$RESOLV_CONF\" is not readable." >&2
    echo "" >&2
    echo "         Please modify \$RESOLV_CONF" >&2
    echo "" >&2
    exit 1
fi



########################################
## Required External Commands Checks
########################################

$EXIFTOOL -ver > /dev/null 2>&1
if [ ! "$?" == 0 ]; then
    echo ""
    echo "  ERROR: This script needs \"$EXIFTOOL\" program."
    echo ""
    echo "  Please Download ExifTool DMG from http://www.sno.phy.queensu.ca/~phil/exiftool/ ."
    echo "  Then Install \"$EXIFTOOL\" by the DMG file."
    echo ""
    exit 1
fi

#$JHEAD -V > /dev/null 2>&1
#if [ ! "$?" == 0 ]; then
#    echo ""
#    echo "  ERROR: This script needs \"$JHEAD\" program."
#    echo ""
#    echo "  Please Download \"$JHEAD\" from http://www.sentex.net/~mwandel/$JHEAD/ "
#    echo "  Then set PATH to the \"$JHEAD\" file."
#    echo ""
#    exit 1
#fi

########################################
## Mode Settings
########################################

if [ -n "$opt_clean_arch_cache" ]; then
    clean_arch_cache_mode=1
else
    clean_arch_cache_mode=
fi

if [ -n "$opt_yes" ]; then
    assume_default_answer=1
else
    assume_default_answer=
fi

if [ -n "$opt_full_opr" ]; then
    download_mode=1
    arch_mode=1
else
    download_mode=
    arch_mode=
fi

if [ -n "$opt_download_only" ]; then
    download_mode=1
fi

if [ -n "$opt_arch_only" ]; then
    arch_mode=1
fi

local_arch_mode=
remote_arch_mode=

if [ -n "$arch_mode" ]; then
    if [ -n "$ARCH_LOCAL_PATH" ]; then
        local_arch_mode=1
    fi
    if [ -n "$ARCH_REMOTE_PATH" ]; then
        remote_arch_mode=1
    fi
fi

########################################
## Pre Scripts
########################################

photo_index_org="$( echo ${FLAIR_URL} | awk -F/ '{print $NF}' )"
photo_index="${INDEX_DIR}/${photo_index_org}.${DATE}.html"

ORG_DIR=$( pwd )

cd "${BASE_DIR}"
if [ $? -ne 0 ]; then
    echo "" >&2
    echo "  ERROR: You can not move to \$BASE_DIR=${BASE_DIR} " >&2
    echo "" >&2
    echo "         Please check existence and permissions of the directory ." >&2
    echo "" >&2
    exit 1
fi
return_org_dir

touch "${PERM_CHK}"
if [ $? -ne 0 ]; then
    echo "" >&2
    echo "  ERROR: You can not create any file in \$BASE_DIR=${BASE_DIR} " >&2
    echo "" >&2
    rm -f "${PERM_CHK}"
    return_org_dir
    exit 1
fi
rm -f "${PERM_CHK}"

return_org_dir

test -d "$INDEX_DIR"       || mkdir "$INDEX_DIR"
test -d "$LOG_DIR"         || mkdir "$LOG_DIR"
test -d "$PHOTO_DIR"       || mkdir "$PHOTO_DIR"
test -f "$ARCH_CACHE"      || touch "$ARCH_CACHE"

curldir_cleaning
test -d "$CURL_DIR"        || mkdir "$CURL_DIR"


########################################
## Main Program
########################################

####################
## Log Start

echo "## Remote Sync Photos from FlashAir ##" >> "$SUMMARY_LOG"
echo "Date/Time: $( date '+%Y-%m-%d %H:%M:%S' )" >> "$SUMMARY_LOG"
echo "" >> "$SUMMARY_LOG"

####################
## Mode Output

echo "[Mode Settings]"           >> "$SUMMARY_LOG"
declare -p assume_default_answer >> "$SUMMARY_LOG"
declare -p clean_arch_cache_mode >> "$SUMMARY_LOG"
declare -p download_mode         >> "$SUMMARY_LOG"
declare -p arch_mode             >> "$SUMMARY_LOG"
declare -p local_arch_mode       >> "$SUMMARY_LOG"
declare -p remote_arch_mode      >> "$SUMMARY_LOG"

####################
## Clean Archived Photos List Cache File

if [ -n "$clean_arch_cache_mode" ]; then

    echo ""  >> "$SUMMARY_LOG"
    echo "[Clean Archived Photos List Cache File]" >> "$SUMMARY_LOG"
    
    echo ""
    echo "  !! CAUTION !!"
    echo ""
    echo "  You use \"-c\" option. "
    echo "  The option means cleaning of archived photos list cache file"
    echo "  \"$ARCH_CACHE\""
    echo ""
    echo "    The file include $( cat $ARCH_CACHE | wc -l ) photos list [$( head -1 $ARCH_CACHE ) -- $( tail -1 $ARCH_CACHE )]"
    echo ""
    echo "  Are you remove the archived photos list cache file really ?"
    echo "  (Next time, all photos in FlashAir must be downloaded.)"
    echo ""
    echo -n "  OK? [y/N]: "

    if [ -z "$assume_default_answer" ]; then
        read yn
    else
        echo "(-y option is enable. Default answer is selected)"
        sleep 2
        yn=
    fi
    
    case $yn in
        [yY]*)
            mv -v ${ARCH_CACHE} ${ARCH_CACHE}.${DATE} >> "$SUMMARY_LOG"
            echo ""
            echo "  \"${ARCH_CACHE}\" is removed."
            echo "  (Backup is created as \"${ARCH_CACHE}.${DATE}\")"
            echo ""
            echo "  ${SCRIPT_NAME} is done."
            echo ""
            
            ;;
        *)
            echo ""
            echo "  Canceled. "
            echo "  ${SCRIPT_NAME} is done."
            echo ""
            
            echo "  Canceled. Exit." >> "$SUMMARY_LOG"
            
            ;;
    esac
    
    clean_and_compress
    return_org_dir
    exit
    
fi


####################
## Passwords are fetched from KEYCHAIN

if [ -n "$download_mode" ] || [ -n "$remote_arch_mode" ]; then

    echo ""                                       >> "$SUMMARY_LOG"
    echo "[Passwords are fetched from KEYCHAIN]"  >> "$SUMMARY_LOG"

    echo "" >&2
    echo "  Passwords are fetched from KEYCHAIN" >&2
    echo "" >&2
    echo "  ** Please Authorize \"security\" program to access to some passwords in KEYCHAIN **" >&2
    echo "" >&2
fi

## Network Drives (already mounted)

if [ -n "$download_mode" ]; then

    echo "  [Network Drives (already mounted)]"  >> "$SUMMARY_LOG"

    IFS=$'\n'
    nas_org_mount_info=($(mount -v | grep ^//))

    nas_org_mount_cmd=()
    nas_org_umount_cmd=()

    if [ ${#nas_org_mount_info[*]} -eq 0 ]; then
        echo "    Not Found."  >> "$SUMMARY_LOG"
    fi

    for info in ${nas_org_mount_info[@]}; do
        um_cmd="umount $(echo $info | awk '{print $3}')"
        nas_org_umount_cmd+=($um_cmd)
    
        fstype=$( echo $info | awk -F"[()]" '{print $2}' | awk -F, '{print $1}' )
        opt=$( echo $info | awk -F"[()]" '{print $2}' | sed 's/^[ A-z0-9]*//g' | sed 's/[ A-z0-9]*$//g' | tr -d " " | sed 's/^,//g' | sed 's/,$//g' )
        if [ -n "$opt" ]; then
            opt="-o $opt"
        fi
        user=$( echo $info | awk '{print $1}' | awk -F@ '{print $1}' )
        server=$( echo $info | awk '{print $1}' | awk -F"[@/]" '{print $4}' )
        rpath="/$( echo $info | awk '{print $1}' | sed 's|^//.*/||g' )"

        lpath=$( echo $info | awk '{print $3}' )

        echo -n "    [${fstype}:${server}${rpath}] "  >> "$SUMMARY_LOG"

        echo -n "    Fetching NAS password for [${fstype}:${server}${rpath}] ... " >&2

        case $fstype in
            smb*)
                keychain_item=$( security find-internet-password -g -s $server -r "smb " 2>&1 1>/dev/null )

                if [ $? -ne 0 ]; then
                    echo "Failed"  >> "$SUMMARY_LOG"
                    echo "ERROR: Passwords can not be fetched from KEYCHAIN" >> "$SUMMARY_LOG"

                    echo ""
                    echo "  ERROR: Passwords about \"smb:${server}${rpath}\" (now mounted)"
                    echo "         can not be fetched from KEYCHAIN"
                    echo ""
                    
                    clean_and_compress
                    return_org_dir
                    exit 1
                fi

                pw=$( echo $keychain_item | grep ^password: | awk -F": " '{print $2}' | sed 's/"//g' )
                mo_cmd="mount_smbfs $opt ${user}:${pw}@${server}${rpath} $lpath"
                ;;
        
            afp*)
                keychain_item=$( security find-internet-password -g -s $server -r "afp " 2>&1 1>/dev/null )
                
                if [ $? -ne 0 ]; then
                    echo "Failed"  >> "$SUMMARY_LOG"
                    echo "ERROR: Passwords can not be fetched from KEYCHAIN" >> "$SUMMARY_LOG"
                    
                    echo ""
                    echo "  ERROR: Passwords about \"afp:${server}${rpath}\" (now mounted)"
                    echo "         can not be fetched from KEYCHAIN"
                    echo ""
                    
                    clean_and_compress
                    return_org_dir
                    exit 1
                fi
                
                pw=$( echo $keychain_item | grep ^password: | awk -F": " '{print $2}' | sed 's/"//g' )
                mo_cmd="mount_afp $opt afp:${user}:${pw}@${server}${rpath} $lpath"
                ;;
            
            *)
                ;;
        esac
        
        echo "Success"  >> "$SUMMARY_LOG"
        echo "OK" >&2
        
        nas_org_mount_cmd+=($mo_cmd)
    done

fi


## Wifi (already connected)

if [ -n "$download_mode" ]; then

    echo "  [Wifi (already connected)]"  >> "$SUMMARY_LOG"
    org_wifi_info=$( networksetup -getairportnetwork ${NW_DEV} )

    if [ $? -ne 0 ]; then
        echo "  ERROR: Network Information abount \"${NW_DEV}\" can not be required" >> "$SUMMARY_LOG"
    
        echo ""
        echo "  ERROR: Network Information abount \"${NW_DEV}\" can not be required."
        echo ""
        echo "         Please modify \"NW_DEV\" value for your system."
        echo ""
    
        clean_and_compress
        return_org_dir
        exit 1
    fi

    unset org_wifi_is_not_found
    org_wifi_is_not_found=$( echo $org_wifi_info | grep "not associated" )
    
    if [ -n "${org_wifi_is_not_found}" ]; then
        echo "    Now not associated any Wifi Network "     >> "$SUMMARY_LOG"
        
    else
        org_wifi_ssid=$( echo $org_wifi_info | awk '{print $NF}' )
    
        #declare -p org_wifi_ssid
        
        echo -n "    [$org_wifi_ssid] "                                >> "$SUMMARY_LOG"
        echo -n "    Fetching Wifi Password for [$org_wifi_ssid] ... " >&2

        keychain_item=$( security find-generic-password -gs ${WLAN_PREFIX}${org_wifi_ssid} 2>&1 1>/dev/null )
        
        if [ $? -ne 0 ]; then
            echo "Failed"  >> "$SUMMARY_LOG"
            echo "ERROR: Passwords can not be fetched from KEYCHAIN" >> "$SUMMARY_LOG"
        
            echo ""
            echo "  ERROR: Passwords about Current Wifi \"${org_wifi_ssid}\""
            echo "         can not be fetched from KEYCHAIN"
            echo ""
        
            clean_and_compress
            return_org_dir
            exit 1
        fi
        echo "Success"  >> "$SUMMARY_LOG"
        echo "OK" >&2

        org_wifi_pw=$( echo $keychain_item | grep ^password: | awk -F": " '{print $2}' | sed 's/"//g' )

        org_wifi_back_cmd=("networksetup")
        org_wifi_back_cmd+=("-setairportnetwork ${NW_DEV} ${org_wifi_ssid} \"${org_wifi_pw}\"")

    fi
fi

## Wifi (FlashAir)

if [ -n "$download_mode" ]; then

    echo "  [Wifi (FlashAir)]"  >> "$SUMMARY_LOG"

    echo -n "    [$FLAIR_SSID] "                                >> "$SUMMARY_LOG"
    echo -n "    Fetching Wifi Password for [$FLAIR_SSID] ... " >&2

    keychain_item=$( security find-generic-password -gs ${WLAN_PREFIX}${FLAIR_SSID} 2>&1 1>/dev/null )

    if [ $? -ne 0 ]; then
        echo "Failed"  >> "$SUMMARY_LOG"
        echo "ERROR: Passwords can not be fetched from KEYCHAIN" >> "$SUMMARY_LOG"
        
        echo ""
        echo "  ERROR: Passwords about Current Wifi \"${FLAIR_SSID}\""
        echo "         can not be fetched from KEYCHAIN"
        echo ""
        
        clean_and_compress
        return_org_dir
        exit 1
    fi
    echo "Success"  >> "$SUMMARY_LOG"
    echo "OK" >&2

    flair_wifi_pw=$( echo $keychain_item | grep ^password: | awk -F": " '{print $2}' | sed 's/"//g' )

    flair_wifi_change_cmd=("networksetup")
    flair_wifi_change_cmd+=("-setairportnetwork ${NW_DEV} ${FLAIR_SSID} \"${flair_wifi_pw}\"")
fi


## Network Drive for Remote Archive

if [ -n "$remote_arch_mode" ]; then

    echo "  [Network Drives for Remote Archive]"  >> "$SUMMARY_LOG"

    msg="${NAS_PROT}:${NAS_USER}@${NAS_SERVER}/${NAS_MOUNT_PATH}"
    echo -n "    [${msg}] " >> "$SUMMARY_LOG"
    echo -n "    Fetching NAS Password for [${msg}] ... " >&2

    server=${NAS_SERVER}
    case ${NAS_PROT} in
        smb*)
            keychain_item=$( security find-internet-password -g -s $server -r "smb " 2>&1 1>/dev/null )

            if [ $? -ne 0 ]; then
                echo "Failed"  >> "$SUMMARY_LOG"
                echo "ERROR: Passwords can not be fetched from KEYCHAIN" >> "$SUMMARY_LOG"
                
                echo ""
                echo "  ERROR: Passwords about \"smb:${server}${rpath}\" (for backup)"
                echo "         can not be fetched from KEYCHAIN"
                echo ""
                
                clean_and_compress
                return_org_dir
                exit 1
            fi

            pw=$( echo $keychain_item | grep ^password: | awk -F": " '{print $2}' | sed 's/"//g' )
            remote_arch_nas_mount_cmd=("mount_smbfs")
            remote_arch_nas_mount_cmd+=("//${NAS_USER}:${pw}@${NAS_SERVER}/${NAS_MOUNT_PATH} ${NAS_LOCAL_PATH}")
            ;;
    
        afp*)
            keychain_item=$( security find-internet-password -g -s $server -r "afp " 2>&1 1>/dev/null )

            if [ $? -ne 0 ]; then
                echo "Failed"  >> "$SUMMARY_LOG"
                echo "ERROR: Passwords can not be fetched from KEYCHAIN" >> "$SUMMARY_LOG"
                
                echo ""
                echo "  ERROR: Passwords about \"afp:${server}${rpath}\" (for backup)"
                echo "         can not be fetched from KEYCHAIN"
                echo ""
                
                clean_and_compress
                return_org_dir
                exit 1
            fi

            pw=$( echo $keychain_item | grep ^password: | awk -F": " '{print $2}' | sed 's/"//g' )
            remote_arch_nas_mount_cmd=("mount_afp")
            remote_arch_nas_mount_cmd+=("afp:${NAS_USER}:${pw}@${NAS_SERVER}/${NAS_MOUNT_PATH} ${NAS_LOCAL_PATH}")
            ;;
        *)
            ;;
    esac

    echo "Success"  >> "$SUMMARY_LOG"
    echo "OK" >&2
    
    #declare -p remote_arch_nas_mount_cmd
fi

####################
## Network Drives (already mounted) Unmount

if [ -n "$download_mode" ]; then

    echo ""                                            >> "$SUMMARY_LOG"
    echo "[Network Drives (already mounted) Unmount]"  >> "$SUMMARY_LOG"
    echo ""  >&2
    echo "  Network Drives (already mounted) Unmount" >&2

    if [ ${#nas_org_umount_cmd[*]} -eq 0 ]; then
        echo "    Not Found."  >> "$SUMMARY_LOG"
        echo "    Not Found. " >&2
    else
        for um_cmd in ${nas_org_umount_cmd[@]}; do
            lpath=$( echo $um_cmd | awk '{print $NF}' )
            
            echo -n "  Umount \"$lpath\": "  >> "$SUMMARY_LOG"
            echo -n "    \"$lpath\" is being umounted ... " >&2
            
            cmd=$( echo $um_cmd | awk '{print $1}' )
            args=$( echo $um_cmd | sed "s|^${cmd} ||g" )
            echo $args | xargs $cmd
            
            if [ $? -ne 0 ]; then
                echo "Failed"  >> "$SUMMARY_LOG"
                echo "ERROR: Umount of Network Drives before switching Wifi is failed " >> "$SUMMARY_LOG"
                
                echo ""
                echo "  ERROR: Umount of \"$lpath\" before switching Wifi is failed"
                echo ""
                
                clean_and_compress
                return_org_dir
                exit 1
            fi
            
            echo "Success"  >> "$SUMMARY_LOG"
            echo "done." >&2
        done
    fi
fi
    
####################
## Switch Wifi to FlashAir

if [ -n "$download_mode" ]; then

    echo ""                               >> "$SUMMARY_LOG"
    echo -n "[Switch Wifi to FlashAir] "  >> "$SUMMARY_LOG"
    echo ""  >&2
    echo "  ##########################################################" >&2
    echo "  ##  Now, Switching Wifi to FlashAir...                  ##" >&2
    echo "  ##                                                      ##" >&2
    echo "  ##  Please Power ON (or Reboot) FlashAir Device.        ##" >&2
    echo "  ##    (Completion of switch to FlashAir takes a time.)  ##" >&2
    echo "  ##########################################################" >&2
    echo ""  >&2

    wifi_swt_cnt=$WIFI_SWT_MAX_CNT
    while : ; do
        echo ${flair_wifi_change_cmd[1]} | xargs ${flair_wifi_change_cmd[0]} > ${SWT_WIFI} 2>&1
        cur_wifi_ssid=$( networksetup -getairportnetwork ${NW_DEV} | awk '{print $NF}' )

        if [ "$cur_wifi_ssid" == "$FLAIR_SSID" ]; then
            break
        fi

        wifi_swt_cnt=$( expr $wifi_swt_cnt - 1 )
        
        echo "" >&2
        echo "    Following message is returned." >&2
        echo "      [$( cat ${SWT_WIFI} )]"       >&2
        echo -n "    Retrying (remaining $wifi_swt_cnt times) ... " >&2
        
        if [ $wifi_swt_cnt -le 0 ]; then
            echo "Failed"  >> "$SUMMARY_LOG"
            echo "ERROR: Switching to FlashAir Wifi \"$FLAIR_SSID\" is failed " >> "$SUMMARY_LOG"
            
            echo ""
            echo "  ERROR: Switching to FlashAir Wifi \"$FLAIR_SSID\" is failed"
            echo ""

            restore_nas
            clean_and_compress
            return_org_dir
            exit 1
        fi
    done

    echo "Success"  >> "$SUMMARY_LOG"
    echo " done." >&2

    wait_resolvconf_update

fi

    
####################
## Download INDEX File from FlashAir

if [ -n "$download_mode" ]; then

    echo ""                                    >> "$SUMMARY_LOG"
    echo "[Download INDEX File from FlashAir]" >> "$SUMMARY_LOG"
    echo ""  >&2
    echo "  Download INDEX File from FlashAir"

    flair_idx_dl_cnt=$FLAIR_IDX_DL_MAX_CNT

    while [ $flair_idx_dl_cnt -gt 0 ]; do
        flair_idx_dl_cnt=$( expr $flair_idx_dl_cnt - 1 )

        curl -O -R $FLAIR_URL
        
        if [ $? -ne 0 ]; then
            echo -n "    Retrying (remaining $flair_idx_dl_cnt times) ... " >&2
        else
            break
        fi
        sleep 1
    done

    if [ ! -f "$photo_index_org" ]; then
        echo ""
        echo "  ERROR: \"$FLAIR_URL\" can not be downloaded"
        echo ""

        echo "ERROR: \"$FLAIR_URL\" can not be downloaded" >> "$SUMMARY_LOG"

        restore_wifi
        restore_nas
        clean_and_compress
        return_org_dir
        exit 1
    fi

    mv -v $photo_index_org $photo_index

    echo "Download of \"$FLAIR_URL\" is OK"  >> "$SUMMARY_LOG"
    echo "Renamed to  \"$photo_index\""      >> "$SUMMARY_LOG"
    echo ""                                  >> "$SUMMARY_LOG"

fi
    
####################
## Photos Listing

if [ -n "$download_mode" ]; then

    echo -n "" >&2
    echo -n "  Archived Photos List is fetching from \"$ARCH_CACHE\" ... " >&2
    cat "$ARCH_CACHE" | sort > "${LOCAL_LIST}.1"
    echo "done." >&2

    echo -n "  Yet not Archived (but already Downloaded) Photos Listing in \"$PHOTO_DIR\" ... " >&2
    ls -1 "$PHOTO_DIR/" | sort > "${LOCAL_LIST}.2"
    echo "done." >&2

    cat "${LOCAL_LIST}."? | sort | uniq > "${LOCAL_LIST}"

    if [ -f "$FLAIR_LIST_RAW" ]; then
        rm "$FLAIR_LIST_RAW"
    fi

    echo -n "  FlashAir Photo Listing ... " >&2
    cat "$photo_index" | while read line; do
        img=$( echo $line | grep $PHOTO_KEYWORD | awk -F, '{print $2}' )
        if [ -n "$img" ]; then
            echo "$img" >> "$FLAIR_LIST_RAW"
        fi
    done
    cat "$FLAIR_LIST_RAW" | sort | uniq > "$FLAIR_LIST"
    echo "done." >&2

    diff -y "$LOCAL_LIST" "$FLAIR_LIST" | grep -vE ">|<" | awk '{print $1}' > "$SKIP_LIST"
    diff    "$LOCAL_LIST" "$FLAIR_LIST" | grep     "^>"  | awk '{print $2}' > "$GET_LIST"

    skip_num=$(  cat "$SKIP_LIST"  | wc -l )
    get_num=$(   cat "$GET_LIST"   | wc -l )

    echo "[Search Files from Index file]" >> "$SUMMARY_LOG"
    echo "Skip    : $skip_num"  >> "$SUMMARY_LOG"
    echo "Donwload: $get_num"   >> "$SUMMARY_LOG"
    echo ""                     >> "$SUMMARY_LOG"

fi

####################
## Download Photos

if [ -n "$download_mode" ]; then

    echo    ""
    echo    "  [Donwload] " 
    echo    "    Skip    : $skip_num"
    echo -n "    Download: $get_num"

    echo    "[Donwload] "             >> "$SUMMARY_LOG"
    echo    "    Skip    : $skip_num" >> "$SUMMARY_LOG"
    echo -n "    Download: $get_num"  >> "$SUMMARY_LOG"

    if [ $get_num -ne 0 ]; then
        first=$( cat "$GET_LIST" | head -1 )
        end=$(   cat "$GET_LIST" | tail -1 )
        echo " [$first - $end]"
        echo " [$first - $end]" >> "$SUMMARY_LOG"
    else
        echo ""
        echo "" >> "$SUMMARY_LOG"
    fi

    echo "" >> "$SUMMARY_LOG"

    if [ "$get_num" -eq 0 ]; then
        echo "New Photos are not found. " >> "$SUMMARY_LOG"

        echo "  New Photos are not found." 
        echo ""

    else

        echo -n "  OK? [Y/n]: "

        if [ -z "$assume_default_answer" ]; then
            read yn
        else
            echo "(-y option is enable. Default answer is selected)"
            sleep 2
            yn=
        fi

        case $yn in
            [nN]*)
                echo ""
                echo "  Interrupted"
                echo ""
                    
                echo "  Canceled. Exit." >> "$SUMMARY_LOG"

                restore_wifi
                restore_nas
                clean_and_compress
                return_org_dir
                exit
                ;;
            *)
                ;;
        esac

        get_num=$( cat "$GET_LIST" | wc -l | xargs echo )
        echo 0 > "$GET_CNT"
        cat "$GET_LIST" | while read img; do
            expr $(cat "$GET_CNT") + 1 > "$GET_CNT"
            cd "${CURL_DIR}"
            echo "  curl -O -R ${FLAIR_URL}/$img" >&2
            curl -O -R ${FLAIR_URL}/$img >&2
            if [ $? -eq 0 ] || [ -f "$img" ]; then
                return_org_dir

                $EXIFTOOL "${CURL_DIR}/$img" 2>/dev/null | grep "^Modify Date" | head -1 | cut -d: -f 2-10 | sed 's/\+.*$//g' > "$DATE_INFO"
                if [ ! -s "$DATE_INFO" ]; then
                    $EXIFTOOL "${CURL_DIR}/$img" 2>/dev/null | grep "^Create Date" | head -1 | cut -d: -f 2-10 | sed 's/\+.*$//g' > "$DATE_INFO"
                fi
                #$JHEAD "${CURL_DIR}/$img" 2>/dev/null | grep ^Date/Time | cut -d: -f 2-10  > "$DATE_INFO"

                time=$( cat "$DATE_INFO" | sed 's/:\([0-9][0-9]\)$/.\1/' | sed 's/[: ]//g' )
                if [ -n "$time" ]; then
                    echo "  touch -t $time \"${CURL_DIR}/$img\""
                    touch -t $time "${CURL_DIR}/$img" >&2
                fi

                mv "${CURL_DIR}/$img" "${PHOTO_DIR}/"
                echo "OK:$img" >> "$RESULT_LOG"
            else
                return_org_dir
                echo "NG:$img" >> "$RESULT_LOG"
            fi
            echo "[$(cat $GET_CNT)/${get_num}]" >&2
        done

        ok_num=$( grep -c "^OK:" "$RESULT_LOG" )
        ng_num=$( grep -c "^NG:" "$RESULT_LOG" )

        echo "  [FlashAir Photos Download Results]"
        echo "    Success: $ok_num"
        echo "    Failure: $ng_num"
        echo ""

        ####################
        ## FlashAir Photos Download Summary Log

        echo "[FlashAir Photos Download Results Summary]" >> "$SUMMARY_LOG"
        echo "Success: $ok_num"                           >> "$SUMMARY_LOG"
        echo "Failure: $ng_num"                           >> "$SUMMARY_LOG"
        echo ""                                           >> "$SUMMARY_LOG"
        echo "[FlashAir Photos Download Results Details]" >> "$SUMMARY_LOG"
        cat  "$RESULT_LOG"                                >> "$SUMMARY_LOG"

    fi
fi

####################
## Restore Wifi and NAS
if [ -n "$download_mode" ]; then

    restore_wifi
    restore_nas

fi

####################
## Construct Date Tree

treed_photos_num=-1
if [ -n "$local_arch_mode" ] || [ -n "$remote_arch_mode" ]; then

    if [ -d "$TREE_DIR" ]; then
        echo -n "  Cleaning Tree Dir \"$TREE_DIR/\" ... " >&2
        rm -rf "$TREE_DIR"
        echo "done." >&2
    fi

    mkdir "$TREE_DIR"
    
    ls -1 "$PHOTO_DIR" > "$PHOTO_LIST"
    
    echo -n "  Creating Date Tree Structure in \"$TREE_DIR/\" " >&2
    cat "$PHOTO_LIST" | while read file; do
        echo -n "."
        $EXIFTOOL "${PHOTO_DIR}/$file" 2>/dev/null | grep "^Modify Date" | head -1 | cut -d: -f 2-4 | awk '{print $1}' > "$DATE_INFO"
        if [ ! -s "$DATE_INFO" ]; then
            $EXIFTOOL "${PHOTO_DIR}/$file" 2>/dev/null | grep "^Create Date" | head -1 | cut -d: -f 2-10 | awk '{print $1}' > "$DATE_INFO"
        fi
        #$JHEAD "${PHOTO_DIR}/$file" 2>/dev/null | grep ^Date/Time | cut -d: -f 2-4 | awk '{print $1}' > "$DATE_INFO"
        
        year=$( cat "$DATE_INFO" | awk -F: '{print $1}' )
        day=$(  cat "$DATE_INFO" | sed 's/://g' )
        
        if [ -n "$year" ] && [ -n "$day" ]; then
            mkdir -p "${TREE_DIR}/${year}/${day}"
            cd "${TREE_DIR}/${year}/${day}"
            ln -s "${PHOTO_PATH}/$file" ./
            return_org_dir
        else
            mkdir -p "${TREE_DIR}/${UNCLASS_DIR}"
            cd "${TREE_DIR}/${UNCLASS_DIR}"
            ln -s "${PHOTO_PATH}/$file" ./
            return_org_dir
        fi
    done
    echo " done." >&2

    treed_photos_num=$( echo $( find "${TREE_DIR}/" -type l | wc -l ) )
fi

####################
## New Photos Existence Check

if [ -n "$local_arch_mode" ] || [ -n "$remote_arch_mode" ]; then
    if [ $treed_photos_num -lt 1 ]; then
        echo ""
        echo "    Notice: New Photos are not found."
        echo "            Archive is Canceled."
        echo ""

        local_arch_mode=
        remote_arch_mode=
    fi
fi

####################
## Local Archive

arch_complete=
if [ -n "$local_arch_mode" ]; then
    
    echo ""                >> "$SUMMARY_LOG"
    echo "[Local Archive]" >> "$SUMMARY_LOG"
    
    arch_complete=
    
    archive_by_rsync "${TREE_DIR}/" "${ARCH_LOCAL_PATH}/"
    if [ $? -eq 0 ]; then
        echo ""
        echo "    Local Archive is Completed!"
        echo ""
        arch_complete=1
    else
        echo ""
        echo "    Some Problems are occurred in Local Archive."
        echo ""
    fi
fi
    
####################
## Remote Archive

if [ -n "$remote_arch_mode" ]; then
    arch_complete=

    echo ""                 >> "$SUMMARY_LOG"
    echo "[Remote Archive]" >> "$SUMMARY_LOG"
    
    ## Check already mounted NAS
    echo "  [Target NAS]: ${NAS_PROT}://${NAS_USER}@${NAS_SERVER}/${NAS_MOUNT_PATH} on ${NAS_LOCAL_PATH}" >> "$SUMMARY_LOG"

    echo -n "  Checking Remote Archive NAS \"${NAS_PROT}://${NAS_USER}@${NAS_SERVER}/${NAS_MOUNT_PATH} on ${NAS_LOCAL_PATH}\" Mount Status ... " >&2
    already_mount=
    lpath=$( echo $NAS_LOCAL_PATH | sed 's|/*$||g' )

    IFS=$'\n'
    nas_cur_mount_info=($(mount -v | grep ^//))

    for info in ${nas_cur_mount_info[@]}; do
        cur_lpath=$( echo $info | awk '{print $3}' | sed 's|/*$||g' )

        if [ "$lpath" == "$cur_lpath" ]; then
            already_mount=1
        fi
    done
    echo "done." >&2

    ## Mount NAS
    mount_success=
    if [ -z "$already_mount" ]; then
        echo -n "    NAS Mount: " >> "$SUMMARY_LOG"

        echo -n "  Mount \"${NAS_PROT}://${NAS_USER}@${NAS_SERVER}/${NAS_MOUNT_PATH} on ${NAS_LOCAL_PATH}\" ... " >&2
        if [ ! -d "$NAS_LOCAL_PATH" ];then
            mkdir $NAS_LOCAL_PATH
        fi
        echo ${remote_arch_nas_mount_cmd[1]} | xargs ${remote_arch_nas_mount_cmd[0]}
        if [ $? -eq 0 ]; then
            mount_success=1
            echo "done." >&2
            echo "Success"  >> "$SUMMARY_LOG"
        else
            echo "Failed"   >> "$SUMMARY_LOG"
            echo "FAILED." >&2
            echo ""  >&2
            echo "  ERROR: Sorry, \"${NAS_PROT}://${NAS_USER}@${NAS_SERVER}/${NAS_MOUNT_PATH} on ${NAS_LOCAL_PATH}\" can not be mounted. "  >&2
            echo ""  >&2
            echo "         Remote Archive is failed"  >&2
            echo ""  >&2
        fi
    else
        echo "    Already Mounted" >> "$SUMMARY_LOG"
        echo "  \"${NAS_PROT}://${NAS_USER}@${NAS_SERVER}/${NAS_MOUNT_PATH} on ${NAS_LOCAL_PATH}\" is already mounted " >&2
        mount_success=1
    fi
    
    ## Rsync to NAS
    if [ -n "$mount_success" ]; then
        archive_by_rsync "${TREE_DIR}/" "${ARCH_REMOTE_PATH}/"
        if [ $? -eq 0 ]; then
            echo ""
            echo "    Remote Archive is Completed!"
            echo ""
            arch_complete=1
        else
            echo ""
            echo "    Some Problems are occurred in Remote Archive."
            echo ""
        fi
    fi

fi

####################
## Update Archived Photos List Cache File
if [ -n "$arch_complete" ]; then

    echo -n "  Update Archived Photos List Cache File \"$ARCH_CACHE\" ... " >&2
    cat "${ARCH_CACHE}" > "${ARCH_CACHE}.tmp"
    ls -1 "${PHOTO_DIR}/" | sort >> "${ARCH_CACHE}.tmp"
    cat "${ARCH_CACHE}.tmp" | sort | uniq > "${ARCH_CACHE}"
    rm -f "${ARCH_CACHE}.tmp"
    echo " done." >&2
    echo ""       >&2
    
    echo ""                                            >> "$SUMMARY_LOG"
    echo "[Update Archived Photos List Cache File]"    >> "$SUMMARY_LOG"
    echo "$(ls -1 ${PHOTO_DIR}/ | wc -l) items are added on \"$ARCH_CACHE\"" >> "$SUMMARY_LOG"
    
    photos_cleaning

elif [ $treed_photos_num -eq 0 ]; then

    echo ""                                            >> "$SUMMARY_LOG"
    echo "[Update Archived Photos List Cache File]"    >> "$SUMMARY_LOG"
    echo "Update of \"$ARCH_CACHE\" is not needed because New Photos are not found." >> "$SUMMARY_LOG"
    
else

    echo ""       >&2
    echo "  NOTICE: Archived Photos List Cache File \"$ARCH_CACHE\" is not updated. " >&2
    echo "          Downloaded photos are remained in following directory for next archive. " >&2
    echo "          \"${PHOTO_DIR}/\"" >&2
    echo ""       >&2
    
    echo ""                                                 >> "$SUMMARY_LOG"
    echo "[Update Archived Photos List Cache File]"         >> "$SUMMARY_LOG"
    echo "\"$ARCH_CACHE\" is not updated for some problems" >> "$SUMMARY_LOG"

fi

####################
## Execute Post Script
if [ -n "$POST_SCRIPT" ]; then
    echo ""                      >> "$SUMMARY_LOG"
    echo "[Execute Post Script]" >> "$SUMMARY_LOG"
    declare -p POST_SCRIPT       >> "$SUMMARY_LOG"

    echo "  Executing Post Script \"$POST_SCRIPT\" " >&2
    eval "$POST_SCRIPT"
    echo "" >&2
fi

####################
## Cleaning tmp files

clean_and_compress
return_org_dir

####################
## Termination

echo "  ${SCRIPT_NAME} is done."
echo ""
exit 0
