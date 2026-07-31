#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# 1. GLOBALS & STATE
# ==============================================================================
declare -A BLK_CHILDREN
declare -A BLK_TYPE
declare -A BLK_FULLPATH
declare -A SEEN_KNAME
declare -A HAS_PARENT
declare -A ZFS_POOL_TO_BLK

declare -A BLK_FSID
declare -A VISITED_FSID
declare -A MNT_BY_FSID

declare -A MNT_BY_BLK
declare -A MNT_ZFS
declare -a MNT_VIRTUAL_LIST
declare -a ROOT_BLKS

declare -A VISITED_BLK

MOUNTINFO="/proc/self/mountinfo"

# ==============================================================================
# 2. GATHER BLOCK DEVICES (lsblk)
# ==============================================================================
gather_block_devices() {
    local line KNAME PKNAME TYPE FSTYPE LABEL UUID unsorted_roots k

    # Read tree of block devices safely using pairs
    while read -r line; do
        [[ -z "$line" ]] && continue
        
        KNAME="" PKNAME="" TYPE="" FSTYPE="" LABEL="" UUID=""
        [[ $line =~ KNAME=\"([^\"]*)\" ]] && KNAME="${BASH_REMATCH[1]}"
        [[ $line =~ PKNAME=\"([^\"]*)\" ]] && PKNAME="${BASH_REMATCH[1]}"
        [[ $line =~ TYPE=\"([^\"]*)\" ]] && TYPE="${BASH_REMATCH[1]}"
        [[ $line =~ FSTYPE=\"([^\"]*)\" ]] && FSTYPE="${BASH_REMATCH[1]}"
        [[ $line =~ LABEL=\"([^\"]*)\" ]] && LABEL="${BASH_REMATCH[1]}"
        [[ $line =~ UUID=\"([^\"]*)\" ]] && UUID="${BASH_REMATCH[1]}"
        
        [[ -z "$KNAME" ]] && continue
        
        # 1. Map parent-child graphs cleanly
        if [[ -n "$PKNAME" ]]; then
            # SC2076 fix: use standard string globbing instead of regex
            if [[ ! " ${BLK_CHILDREN[$PKNAME]} " == *" $KNAME "* ]]; then
                BLK_CHILDREN["$PKNAME"]+="$KNAME "
            fi
            HAS_PARENT["$KNAME"]=1
        fi
        
        # 2. Record properties
        if [[ -z "${SEEN_KNAME[$KNAME]}" ]]; then
            SEEN_KNAME["$KNAME"]=1
            BLK_TYPE["$KNAME"]="$TYPE"
            
            # Generate a Filesystem ID for RAID deduplication
            local fs_id=""
            if [[ -n "$UUID" ]]; then
                fs_id="$UUID"
            elif [[ "$FSTYPE" == "zfs_member" && -n "$LABEL" ]]; then
                fs_id="zpool:$LABEL"
            elif [[ "$FSTYPE" == "btrfs" && -n "$LABEL" ]]; then
                fs_id="btrfs:$LABEL"
            fi
            
            if [[ -n "$fs_id" ]]; then
                BLK_FSID["$KNAME"]="$fs_id"
            fi
            
            if [[ "$FSTYPE" == "zfs_member" && -n "$LABEL" ]]; then
                ZFS_POOL_TO_BLK["$LABEL"]="$KNAME"
            fi
        fi
    done < <(lsblk -n --pairs -o KNAME,PKNAME,TYPE,FSTYPE,LABEL,UUID 2>/dev/null || true)

    # 3. Establish root drives, sorted alphanumerically
    unsorted_roots=()
    for k in "${!SEEN_KNAME[@]}"; do
        if [[ -z "${HAS_PARENT[$k]}" ]]; then
            unsorted_roots+=("$k")
        fi
    done
    mapfile -t ROOT_BLKS < <(printf "%s\n" "${unsorted_roots[@]}" | sort)
}

# ==============================================================================
# 3. REFINE DEVICE NAMES & TYPES
# ==============================================================================
refine_device_identities() {
    local kname dm_name dm_uuid current_pool line dev_path

    for kname in "${!SEEN_KNAME[@]}"; do
        if [[ -f "/sys/class/block/$kname/dm/name" ]]; then
            dm_name=$(cat "/sys/class/block/$kname/dm/name" 2>/dev/null || true)
            
            if [[ -n "$dm_name" ]]; then
                BLK_FULLPATH["$kname"]="/dev/mapper/$dm_name"
                
                # Check Sysfs UUID for integrity labels
                if [[ -f "/sys/class/block/$kname/dm/uuid" ]]; then
                    dm_uuid=$(cat "/sys/class/block/$kname/dm/uuid" 2>/dev/null || true)
                    if [[ "${dm_uuid^^}" == *"INTEGRITY"* ]]; then
                        BLK_TYPE[$kname]="integrity"
                    fi
                fi
                
                if [[ "${BLK_TYPE[$kname]}" == "crypt" || "${BLK_TYPE[$kname]}" == "dm" ]]; then
                    if command -v integritysetup >/dev/null 2>&1 && integritysetup status "$dm_name" 2>/dev/null | grep -q "INTEGRITY"; then
                        BLK_TYPE[$kname]="integrity"
                    fi
                fi
                continue
            fi
        fi
        BLK_FULLPATH["$kname"]="/dev/$kname"
    done

    # Fallback: Map ZFS pools to physical devices
    if command -v zpool >/dev/null 2>&1; then
        current_pool=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^([A-Za-z0-9_-]+)[[:space:]] ]]; then
                current_pool="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]+([^[:space:]]+) ]]; then
                dev_path="${BASH_REMATCH[1]}"
                kname=$(basename "$(readlink -f "/dev/$dev_path" 2>/dev/null || echo "$dev_path")" 2>/dev/null || echo "${dev_path##*/}")
                
                if [[ -n "$current_pool" && -n "$kname" && -z "${ZFS_POOL_TO_BLK[$current_pool]}" ]]; then
                    ZFS_POOL_TO_BLK["$current_pool"]="$kname"
                fi
            fi
        done < <(zpool list -vH 2>/dev/null || true)
    fi
}

# ==============================================================================
# 4. GATHER MOUNT POINTS
# ==============================================================================
gather_mounts() {
    local line major_minor root target sep_idx i fstype source
    local super_options mount_type subvol_val norm_subvol norm_root entry kname pool_name
    local -a parts

    if [[ ! -f "$MOUNTINFO" ]]; then
        echo "Error: $MOUNTINFO not found." >&2
        exit 1
    fi

    while read -r line; do
        [[ -z "$line" ]] && continue
        
        # SC2206 fix: robust splitting
        read -ra parts <<< "$line"
        major_minor="${parts[2]}"
        root="${parts[3]}"
        target="${parts[4]}"
        
        target="${target//\\040/ }"
        root="${root//\\040/ }"
        
        sep_idx=0
        for i in "${!parts[@]}"; do
            if [[ "${parts[$i]}" == "-" ]]; then
                sep_idx=$i
                break
            fi
        done
        
        fstype="${parts[$((sep_idx + 1))]}"
        source="${parts[$((sep_idx + 2))]}"
        source="${source//\\040/ }"
        super_options="${parts[*]:$((sep_idx + 3))}"

        mount_type="standard"
        if [[ "$root" != "/" ]]; then
            case "$fstype" in
                zfs) 
                    mount_type="subvol" 
                    ;;
                btrfs)
                    subvol_val=""
                    if [[ "$super_options" =~ subvol=([^,[:space:]]+) ]]; then
                        subvol_val="${BASH_REMATCH[1]}"
                    fi
                    
                    norm_subvol="/${subvol_val#/}"
                    norm_subvol="${norm_subvol%/}"
                    norm_root="/${root#/}"
                    norm_root="${norm_root%/}"
                    
                    if [[ "$norm_root" == "$norm_subvol" || -z "$subvol_val" ]]; then
                        mount_type="subvol"
                    else
                        mount_type="bind"
                    fi
                    ;;
                *) mount_type="bind" ;;
            esac
        fi

        entry="${target}|${root}|${fstype}|${mount_type}|${source}"
        kname=""
        
        if [[ "$major_minor" != "0:"* ]] && [[ -e "/sys/dev/block/$major_minor" ]]; then
            kname=$(basename "$(readlink -f "/sys/dev/block/$major_minor")")
        elif [[ -b "$source" ]]; then
            kname=$(basename "$(readlink -f "$source")")
        fi

        if [[ "$fstype" == "zfs" ]]; then
            pool_name="${source%%/*}"
            if [[ -n "${ZFS_POOL_TO_BLK[$pool_name]}" ]]; then
                kname="${ZFS_POOL_TO_BLK[$pool_name]}"
            fi
        fi

        if [[ -n "$kname" && -n "${BLK_TYPE[$kname]}" ]]; then
            local f_id="${BLK_FSID[$kname]}"
            if [[ -n "$f_id" ]]; then
                MNT_BY_FSID["$f_id"]+="$entry"$'\n'
            else
                MNT_BY_BLK["$kname"]+="$entry"$'\n'
            fi
        elif [[ "$fstype" == "zfs" ]]; then
            pool_name="${source%%/*}"
            MNT_ZFS["$pool_name"]+="$entry"$'\n'
        else
            MNT_VIRTUAL_LIST+=("$entry")
        fi
    done < "$MOUNTINFO"
}

# ==============================================================================
# 5. TREE FILTERING (Intelligent LVM Collapse)
# ==============================================================================
get_filtered_children() {
    local kname="$1"
    local result=()
    local c sc r unique keep_lvm
    local -a raw_childs sub_children
    local -A seen_local

    # SC2206 fix: robust splitting
    read -ra raw_childs <<< "${BLK_CHILDREN[$kname]}"

    for c in "${raw_childs[@]}"; do
        [[ -z "$c" ]] && continue

        if [[ "${BLK_TYPE[$c]}" != "lvm" ]]; then
            result+=("$c")
        else
            keep_lvm=0
            local c_fs_id="${BLK_FSID[$c]}"
            if [[ -n "${MNT_BY_BLK[$c]}" || ( -n "$c_fs_id" && -n "${MNT_BY_FSID[$c_fs_id]}" ) ]]; then
                keep_lvm=1
            fi

            for sc in ${BLK_CHILDREN[$c]}; do
                [[ -n "$sc" && "${BLK_TYPE[$sc]}" != "lvm" ]] && keep_lvm=1
            done

            if [[ $keep_lvm -eq 1 ]]; then
                result+=("$c")
            else
                # SC2207 fix: robust splitting of command output
                read -ra sub_children <<< "$(get_filtered_children "$c")"
                for sc in "${sub_children[@]}"; do
                    [[ -n "$sc" ]] && result+=("$sc")
                done
            fi
        fi
    done

    unique=()
    for r in "${result[@]}"; do
        if [[ -n "$r" && -z "${seen_local[$r]}" ]]; then
            seen_local["$r"]=1
            unique+=("$r")
        fi
    done

    echo "${unique[@]}"
}

# ==============================================================================
# 6. RENDERING ENGINE
# ==============================================================================
print_mounts() {
    local list="$1"
    local prefix="$2"
    local is_last_blk="$3"
    
    local entries valid_entries e count primary_idx best_score i
    local target mroot fstype mtype score
    local p_target p_fstype
    local ptr sec_prefix sec_count s sec_ptr resolved_root

    mapfile -t entries <<< "$list"
    valid_entries=()
    for e in "${entries[@]}"; do
        [[ -n "$e" ]] && valid_entries+=("$e")
    done
    
    count=${#valid_entries[@]}
    [[ $count -eq 0 ]] && return

    primary_idx=0
    best_score=999999
    for (( i=0; i<count; i++ )); do
        # Extract mroot and ignore others
        IFS="|" read -r _ mroot _ _ _ <<< "${valid_entries[$i]}"
        score=${#mroot}
        [[ "$mroot" == "/" ]] && score=0
        if [[ $score -lt $best_score ]]; then
            best_score=$score
            primary_idx=$i
        fi
    done

    # SC2034 fix: replace unused variables with _
    IFS="|" read -r p_target _ p_fstype _ _ <<< "${valid_entries[$primary_idx]}"

    ptr="├── "
    [[ "$is_last_blk" -eq 1 ]] && ptr="└── "
    echo "${prefix}${ptr}[${p_fstype}] ${p_target}"

    sec_prefix="${prefix}│   "
    [[ "$is_last_blk" -eq 1 ]] && sec_prefix="${prefix}    "

    sec_count=$((count - 1))
    s=0
    for (( i=0; i<count; i++ )); do
        [[ $i -eq $primary_idx ]] && continue
        
        # SC2034 fix: replace unused fstype and msource with _
        IFS="|" read -r target mroot _ mtype _ <<< "${valid_entries[$i]}"
        
        sec_ptr="├── "
        [[ $s -eq $((sec_count - 1)) ]] && sec_ptr="└── "
        
        resolved_root="${p_target%/}/${mroot#/}"
        [[ -z "$resolved_root" ]] && resolved_root="/"
        
        if [[ "$mroot" == "/" ]]; then
            echo "${sec_prefix}${sec_ptr}[${mtype}] ${target}"
        else
            echo "${sec_prefix}${sec_ptr}[${mtype}] ${target}  [${resolved_root}]"
        fi
        s=$((s + 1))
    done
}

print_blk_tree() {
    local kname="$1"
    local prefix="$2"
    local is_last="$3"
    
    local ptr b_type display_name child_prefix mounts child_count has_mounts mounts_last c child_last fs_id
    local -a children

    ptr="├── "
    [[ "$is_last" -eq 1 ]] && ptr="└── "

    # 1. Block-level deduplication (for LVM, MDRAID, etc)
    if [[ -n "${VISITED_BLK[$kname]}" ]]; then 
        echo "${prefix}${ptr}..."
        return
    fi
    VISITED_BLK["$kname"]=1

    b_type="${BLK_TYPE[$kname]}"
    display_name="${BLK_FULLPATH[$kname]}"
    echo "${prefix}${ptr}[${b_type}] ${display_name}"

    child_prefix="${prefix}│   "
    [[ "$is_last" -eq 1 ]] && child_prefix="${prefix}    "

    # 2. Filesystem-level deduplication (for ZFS & BTRFS Multi-Disk Arrays)
    fs_id="${BLK_FSID[$kname]}"
    if [[ -n "$fs_id" ]]; then
        if [[ -n "${VISITED_FSID[$fs_id]}" ]]; then
            echo "${child_prefix}└── ..."
            return
        fi
        VISITED_FSID["$fs_id"]=1
        mounts="${MNT_BY_FSID[$fs_id]}"
    else
        mounts="${MNT_BY_BLK[$kname]}"
    fi

    # SC2207 fix: robust array loading
    read -ra children <<< "$(get_filtered_children "$kname")"
    
    child_count=${#children[@]}
    has_mounts=0
    [[ -n "$mounts" ]] && has_mounts=1

    if [[ $has_mounts -eq 1 ]]; then
        mounts_last=0
        [[ $child_count -eq 0 ]] && mounts_last=1
        print_mounts "$mounts" "$child_prefix" "$mounts_last"
    fi

    for (( c=0; c<child_count; c++ )); do
        child_last=0
        [[ $c -eq $((child_count - 1)) ]] && child_last=1
        print_blk_tree "${children[$c]}" "$child_prefix" "$child_last"
    done
}

# ==============================================================================
# 7. MAIN EXECUTION
# ==============================================================================
main() {
    local r is_last pool count i target mroot fstype ptr

    if [[ $EUID -ne 0 ]]; then
        echo "[!] Warning: Running as non-root. Some block structures or labels may be hidden." >&2
    fi

    gather_block_devices
    refine_device_identities
    gather_mounts

    echo "=== Block Storage Volumes & Mounts ==="
    for (( r=0; r<${#ROOT_BLKS[@]}; r++ )); do
        is_last=0
        [[ $r -eq $((${#ROOT_BLKS[@]} - 1)) ]] && is_last=1
        print_blk_tree "${ROOT_BLKS[$r]}" "" "$is_last"
    done
    echo ""

    if [[ ${#MNT_ZFS[@]} -gt 0 ]]; then
        echo "=== Unmapped ZFS Pools ==="
        for pool in "${!MNT_ZFS[@]}"; do
            echo "[zpool] $pool"
            print_mounts "${MNT_ZFS[$pool]}" "    " 1
        done
        echo ""
    fi

    if [[ ${#MNT_VIRTUAL_LIST[@]} -gt 0 ]]; then
        echo "=== Kernel & Virtual Filesystems ==="
        mapfile -t sorted_virtuals < <(printf "%s\n" "${MNT_VIRTUAL_LIST[@]}" | sort -t'|' -k1,1)
        
        count=${#sorted_virtuals[@]}
        for (( i=0; i<count; i++ )); do
            # SC2034 fix: ignore unused mtype and msource
            IFS="|" read -r target mroot fstype _ _ <<< "${sorted_virtuals[$i]}"
            
            ptr="├── "
            [[ $i -eq $((count - 1)) ]] && ptr="└── "
            
            if [[ "$mroot" == "/" ]]; then
                echo "${ptr}[${fstype}] ${target}"
            else
                echo "${ptr}[${fstype}] ${target}  [${mroot}]"
            fi
        done
    fi
}

# Run program
main
