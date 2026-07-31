use std::collections::{HashMap, HashSet};
use std::fs;
use std::os::unix::fs::FileTypeExt;
use std::process::Command;

// Manually link the C library function so we don't need the external `libc` crate
extern "C" {
    fn geteuid() -> u32;
}

#[derive(Clone, Default, Debug)]
struct BlockDevice {
    kname: String,
    pkname: String,
    b_type: String,
    fs_id: String,
    full_path: String,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct MountEntry {
    target: String, // Kept first for easy alphabetical sorting
    root: String,
    fstype: String,
    mtype: String,
    source: String,
}

struct AppState {
    devices: HashMap<String, BlockDevice>,
    children: HashMap<String, Vec<String>>,
    root_blks: Vec<String>,
    zfs_pool_to_blk: HashMap<String, String>,

    mnt_by_fsid: HashMap<String, Vec<MountEntry>>,
    mnt_by_blk: HashMap<String, Vec<MountEntry>>,
    mnt_zfs: HashMap<String, Vec<MountEntry>>,
    mnt_virtual_list: Vec<MountEntry>,
}

fn parse_lsblk_pairs(line: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let mut key = String::new();
    let mut val = String::new();
    let mut in_quotes = false;
    let mut is_key = true;

    for c in line.chars() {
        if c == '=' && is_key {
            is_key = false;
        } else if c == '"' {
            if in_quotes {
                map.insert(key.clone(), val.clone());
                key.clear();
                val.clear();
                is_key = true;
                in_quotes = false;
            } else {
                in_quotes = true;
            }
        } else if c == ' ' && is_key {
            // Ignore spaces between pairs
        } else {
            if is_key {
                key.push(c);
            } else if in_quotes {
                val.push(c);
            }
        }
    }
    map
}

fn gather_block_devices(state: &mut AppState) {
    let out_str = Command::new("lsblk")
        .args(["-n", "--pairs", "-o", "KNAME,PKNAME,TYPE,FSTYPE,LABEL,UUID"])
        .output()
        .map(|out| String::from_utf8_lossy(&out.stdout).into_owned())
        .unwrap_or_default();

    for line in out_str.lines() {
        if line.trim().is_empty() {
            continue;
        }

        let map = parse_lsblk_pairs(line);
        let kname = map.get("KNAME").cloned().unwrap_or_default();
        if kname.is_empty() {
            continue;
        }

        let pkname = map.get("PKNAME").cloned().unwrap_or_default();
        let b_type = map.get("TYPE").cloned().unwrap_or_default();
        
        // We read these locally to calculate the fs_id, but don't need to store them in the struct
        let fstype = map.get("FSTYPE").cloned().unwrap_or_default();
        let label = map.get("LABEL").cloned().unwrap_or_default();
        let uuid = map.get("UUID").cloned().unwrap_or_default();

        if !pkname.is_empty() {
            let siblings = state.children.entry(pkname.clone()).or_default();
            if !siblings.contains(&kname) {
                siblings.push(kname.clone());
            }
        }

        if !state.devices.contains_key(&kname) {
            let mut fs_id = String::new();
            if !uuid.is_empty() {
                fs_id = uuid.clone();
            } else if fstype == "zfs_member" && !label.is_empty() {
                fs_id = format!("zpool:{}", label);
            } else if fstype == "btrfs" && !label.is_empty() {
                fs_id = format!("btrfs:{}", label);
            }

            if fstype == "zfs_member" && !label.is_empty() {
                state.zfs_pool_to_blk.insert(label.clone(), kname.clone());
            }

            state.devices.insert(
                kname.clone(),
                BlockDevice {
                    kname: kname.clone(),
                    pkname,
                    b_type,
                    fs_id,
                    full_path: format!("/dev/{}", kname),
                },
            );
        }
    }

    // Determine root blocks
    let mut roots: Vec<String> = state
        .devices
        .values()
        .filter(|d| d.pkname.is_empty())
        .map(|d| d.kname.clone())
        .collect();
    roots.sort();
    state.root_blks = roots;
}

fn refine_device_identities(state: &mut AppState) {
    let knames: Vec<String> = state.devices.keys().cloned().collect();

    for kname in knames {
        let mut full_path = format!("/dev/{}", kname);
        let mut b_type = state.devices[&kname].b_type.clone();

        let dm_name_path = format!("/sys/class/block/{}/dm/name", kname);
        if let Ok(dm_name) = fs::read_to_string(&dm_name_path) {
            let dm_name = dm_name.trim();
            if !dm_name.is_empty() {
                full_path = format!("/dev/mapper/{}", dm_name);

                let dm_uuid_path = format!("/sys/class/block/{}/dm/uuid", kname);
                if let Ok(dm_uuid) = fs::read_to_string(&dm_uuid_path) {
                    if dm_uuid.to_uppercase().contains("INTEGRITY") {
                        b_type = "integrity".to_string();
                    }
                }

                if b_type == "crypt" || b_type == "dm" {
                    if let Ok(status) = Command::new("integritysetup")
                        .args(["status", dm_name])
                        .output()
                    {
                        if String::from_utf8_lossy(&status.stdout).contains("INTEGRITY") {
                            b_type = "integrity".to_string();
                        }
                    }
                }
            }
        }

        if let Some(dev) = state.devices.get_mut(&kname) {
            dev.full_path = full_path;
            dev.b_type = b_type;
        }
    }

    // ZFS Zpool Map Fallback
    if let Ok(output) = Command::new("zpool").args(["list", "-vH"]).output() {
        let out_str = String::from_utf8_lossy(&output.stdout);
        let mut current_pool = String::new();

        for line in out_str.lines() {
            if line.starts_with(|c: char| c.is_ascii_alphanumeric()) {
                if let Some(pool) = line.split_whitespace().next() {
                    current_pool = pool.to_string();
                }
            } else if line.starts_with(|c: char| c.is_ascii_whitespace()) {
                if let Some(dev_path) = line.split_whitespace().next() {
                    let canon = fs::canonicalize(format!("/dev/{}", dev_path))
                        .unwrap_or_else(|_| dev_path.into());
                    
                    if let Some(kname_os) = canon.file_name() {
                        let kname = kname_os.to_string_lossy().to_string();
                        if !current_pool.is_empty()
                            && !kname.is_empty()
                            && !state.zfs_pool_to_blk.contains_key(&current_pool)
                        {
                            state.zfs_pool_to_blk.insert(current_pool.clone(), kname);
                        }
                    }
                }
            }
        }
    }
}

fn gather_mounts(state: &mut AppState) {
    let mountinfo = fs::read_to_string("/proc/self/mountinfo").unwrap_or_default();

    for line in mountinfo.lines() {
        if line.trim().is_empty() {
            continue;
        }

        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 7 {
            continue;
        }

        let major_minor = parts[2];
        let root = parts[3].replace("\\040", " ");
        let target = parts[4].replace("\\040", " ");

        let sep_idx = parts.iter().position(|&r| r == "-").unwrap_or(0);
        if sep_idx == 0 || sep_idx + 2 >= parts.len() {
            continue;
        }

        let fstype = parts[sep_idx + 1];
        let source = parts[sep_idx + 2].replace("\\040", " ");
        let super_options = parts[(sep_idx + 3)..].join(" ");

        let mount_type = if root != "/" {
            match fstype {
                "zfs" => "subvol",
                "btrfs" => {
                    let mut subvol_val = "";
                    for opt in super_options.split(',') {
                        if let Some(val) = opt.strip_prefix("subvol=") {
                            subvol_val = val;
                            break;
                        }
                    }

                    let norm_subvol = format!("/{}", subvol_val.trim_start_matches('/'));
                    let norm_subvol = norm_subvol.trim_end_matches('/');
                    let norm_root = format!("/{}", root.trim_start_matches('/'));
                    let norm_root = norm_root.trim_end_matches('/');

                    if norm_root == norm_subvol || subvol_val.is_empty() {
                        "subvol"
                    } else {
                        "bind"
                    }
                }
                _ => "bind",
            }
        } else {
            "standard"
        };

        let entry = MountEntry {
            target,
            root,
            fstype: fstype.to_string(),
            mtype: mount_type.to_string(),
            source: source.clone(),
        };

        let mut matched_kname = String::new();

        if !major_minor.starts_with("0:") {
            let sys_path = format!("/sys/dev/block/{}", major_minor);
            if let Ok(canon) = fs::canonicalize(&sys_path) {
                if let Some(name) = canon.file_name() {
                    matched_kname = name.to_string_lossy().to_string();
                }
            }
        } else if let Ok(meta) = fs::metadata(&source) {
            if meta.file_type().is_block_device() {
                if let Ok(canon) = fs::canonicalize(&source) {
                    if let Some(name) = canon.file_name() {
                        matched_kname = name.to_string_lossy().to_string();
                    }
                }
            }
        }

        if fstype == "zfs" {
            let pool_name = source.split('/').next().unwrap_or(&source);
            if let Some(blk) = state.zfs_pool_to_blk.get(pool_name) {
                matched_kname = blk.clone();
            }
        }

        if !matched_kname.is_empty() && state.devices.contains_key(&matched_kname) {
            let f_id = &state.devices[&matched_kname].fs_id;
            if !f_id.is_empty() {
                state.mnt_by_fsid.entry(f_id.clone()).or_default().push(entry);
            } else {
                state.mnt_by_blk.entry(matched_kname).or_default().push(entry);
            }
        } else if fstype == "zfs" {
            let pool_name = source.split('/').next().unwrap_or(&source).to_string();
            state.mnt_zfs.entry(pool_name).or_default().push(entry);
        } else {
            state.mnt_virtual_list.push(entry);
        }
    }
}

fn get_filtered_children(kname: &str, state: &AppState) -> Vec<String> {
    let raw_children = state.children.get(kname).cloned().unwrap_or_default();
    let mut result = Vec::new();

    for c in raw_children {
        if let Some(dev) = state.devices.get(&c) {
            if dev.b_type != "lvm" {
                result.push(c);
            } else {
                let mut keep_lvm = false;

                if state.mnt_by_blk.contains_key(&c)
                    || (!dev.fs_id.is_empty() && state.mnt_by_fsid.contains_key(&dev.fs_id))
                {
                    keep_lvm = true;
                }

                if let Some(sub_children) = state.children.get(&c) {
                    for sc in sub_children {
                        if let Some(sub_dev) = state.devices.get(sc) {
                            if sub_dev.b_type != "lvm" {
                                keep_lvm = true;
                            }
                        }
                    }
                }

                if keep_lvm {
                    result.push(c);
                } else {
                    result.extend(get_filtered_children(&c, state));
                }
            }
        }
    }

    // Dedup
    let mut seen = HashSet::new();
    result.into_iter().filter(|r| seen.insert(r.clone())).collect()
}

fn print_mounts(entries: &[MountEntry], prefix: &str, is_last_blk: bool) {
    if entries.is_empty() {
        return;
    }

    let mut primary_idx = 0;
    let mut best_score = usize::MAX;

    for (i, e) in entries.iter().enumerate() {
        let score = if e.root == "/" { 0 } else { e.root.len() };
        if score < best_score {
            best_score = score;
            primary_idx = i;
        }
    }

    let p = &entries[primary_idx];
    let ptr = if is_last_blk { "└── " } else { "├── " };
    println!("{}{}[{}] {}", prefix, ptr, p.fstype, p.target);

    let sec_prefix = if is_last_blk {
        format!("{}    ", prefix)
    } else {
        format!("{}│   ", prefix)
    };

    let sec_entries: Vec<_> = entries
        .iter()
        .enumerate()
        .filter(|(i, _)| *i != primary_idx)
        .map(|(_, e)| e)
        .collect();

    let sec_count = sec_entries.len();

    for (s, e) in sec_entries.iter().enumerate() {
        let sec_ptr = if s == sec_count - 1 { "└── " } else { "├── " };
        
        let p_target_trim = p.target.trim_end_matches('/');
        let e_root_trim = e.root.trim_start_matches('/');
        let mut resolved_root = format!("{}/{}", p_target_trim, e_root_trim);
        if resolved_root == "/" || resolved_root.is_empty() {
            resolved_root = "/".to_string();
        }

        if e.root == "/" {
            println!("{}{}[{}] {}", sec_prefix, sec_ptr, e.mtype, e.target);
        } else {
            println!(
                "{}{}[{}] {}  [{}]",
                sec_prefix, sec_ptr, e.mtype, e.target, resolved_root
            );
        }
    }
}

fn print_blk_tree(
    kname: &str,
    prefix: &str,
    is_last: bool,
    state: &AppState,
    visited_blk: &mut HashSet<String>,
    visited_fsid: &mut HashSet<String>,
) {
    let ptr = if is_last { "└── " } else { "├── " };

    if !visited_blk.insert(kname.to_string()) {
        println!("{}{}", prefix, format!("{}...", ptr));
        return;
    }

    let dev = &state.devices[kname];
    println!("{}{}[{}] {}", prefix, ptr, dev.b_type, dev.full_path);

    let child_prefix = if is_last {
        format!("{}    ", prefix)
    } else {
        format!("{}│   ", prefix)
    };

    let empty_mounts = Vec::new();
    let mounts = if !dev.fs_id.is_empty() {
        if !visited_fsid.insert(dev.fs_id.clone()) {
            println!("{}└── ...", child_prefix);
            return;
        }
        state.mnt_by_fsid.get(&dev.fs_id).unwrap_or(&empty_mounts)
    } else {
        state.mnt_by_blk.get(kname).unwrap_or(&empty_mounts)
    };

    let children = get_filtered_children(kname, state);
    let child_count = children.len();
    let has_mounts = !mounts.is_empty();

    if has_mounts {
        let mounts_last = child_count == 0;
        print_mounts(mounts, &child_prefix, mounts_last);
    }

    for (c, child) in children.iter().enumerate() {
        let child_last = c == child_count - 1;
        print_blk_tree(
            child,
            &child_prefix,
            child_last,
            state,
            visited_blk,
            visited_fsid,
        );
    }
}

fn main() {
    let euid = unsafe { geteuid() };
    if euid != 0 {
        eprintln!("[!] Warning: Running as non-root. Some block structures or labels may be hidden.");
    }

    let mut state = AppState {
        devices: HashMap::new(),
        children: HashMap::new(),
        root_blks: Vec::new(),
        zfs_pool_to_blk: HashMap::new(),
        mnt_by_fsid: HashMap::new(),
        mnt_by_blk: HashMap::new(),
        mnt_zfs: HashMap::new(),
        mnt_virtual_list: Vec::new(),
    };

    gather_block_devices(&mut state);
    refine_device_identities(&mut state);
    gather_mounts(&mut state);

    println!("=== Block Storage Volumes & Mounts ===");
    let mut visited_blk = HashSet::new();
    let mut visited_fsid = HashSet::new();

    let root_count = state.root_blks.len();
    for (r, root) in state.root_blks.iter().enumerate() {
        let is_last = r == root_count - 1;
        print_blk_tree(
            root,
            "",
            is_last,
            &state,
            &mut visited_blk,
            &mut visited_fsid,
        );
    }
    println!();

    if !state.mnt_zfs.is_empty() {
        println!("=== Unmapped ZFS Pools ===");
        for (pool, mounts) in &state.mnt_zfs {
            println!("[zpool] {}", pool);
            print_mounts(mounts, "    ", true);
        }
        println!();
    }

    if !state.mnt_virtual_list.is_empty() {
        println!("=== Kernel & Virtual Filesystems ===");
        state.mnt_virtual_list.sort(); // Sorts by target first due to struct ordering
        let count = state.mnt_virtual_list.len();

        for (i, entry) in state.mnt_virtual_list.iter().enumerate() {
            let ptr = if i == count - 1 { "└── " } else { "├── " };
            if entry.root == "/" {
                println!("{}[{}] {}", ptr, entry.fstype, entry.target);
            } else {
                println!(
                    "{}[{}] {}  [{}]",
                    ptr, entry.fstype, entry.target, entry.root
                );
            }
        }
    }
}
