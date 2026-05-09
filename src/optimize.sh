optimize_write_sysctl() {
    local file=/etc/sysctl.d/99-sing-box-proxy.conf
    mkdir -p /etc/sysctl.d
    cat >"$file" <<EOF
# Managed by sing-box install script.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.ip_local_port_range = 10240 65535
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
    sysctl --system &>/dev/null || sysctl -p "$file" &>/dev/null || warn "应用网络优化参数失败, 已写入 $file"
}

optimize_bbr() {
    local kernel_major
    local kernel_minor
    warn "启用 BBR 优化..."
    kernel_major=$(uname -r | cut -d. -f1)
    kernel_minor=$(uname -r | cut -d. -f2)
    if [[ $kernel_major -eq 4 && $kernel_minor -ge 9 ]] || [[ $kernel_major -ge 5 ]]; then
        sysctl -w net.ipv4.tcp_congestion_control=bbr net.core.default_qdisc=fq &>/dev/null || true
        echo
        _green "..已经启用 BBR 优化...."
        echo
    else
        warn "当前内核不支持启用 BBR 优化, 已跳过."
    fi
}

optimize_swap() {
    local mem_kb=${SING_BOX_TEST_MEM_KB:-}
    local swap_file=${SING_BOX_SWAP_FILE:-/swapfile}
    local swap_size=${SING_BOX_SWAP_SIZE:-2G}
    local dd_count=${SING_BOX_SWAP_DD_COUNT:-2048}

    [[ ! $mem_kb && -r /proc/meminfo ]] && mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    [[ ! $mem_kb ]] && {
        warn "无法检测内存大小, 已跳过 swap 优化."
        return
    }
    [[ $mem_kb -gt 2097152 ]] && return
    [[ -r /proc/swaps && $(awk 'NR > 1 {print; exit}' /proc/swaps) ]] && return
    [[ -e $swap_file ]] && {
        warn "$swap_file 已存在, 已跳过自动创建 swap."
        return
    }

    warn "检测到内存小于等于 2G, 自动创建 ${swap_size} swap..."
    if ! fallocate -l "$swap_size" "$swap_file" 2>/dev/null; then
        dd if=/dev/zero of="$swap_file" bs=1M count="$dd_count" status=none || {
            warn "创建 swap 文件失败, 已跳过."
            rm -f "$swap_file"
            return
        }
    fi
    chmod 600 "$swap_file"
    mkswap "$swap_file" &>/dev/null || {
        warn "格式化 swap 文件失败, 已跳过."
        rm -f "$swap_file"
        return
    }
    if [[ ! $SING_BOX_SKIP_SWAPON ]]; then
        swapon "$swap_file" &>/dev/null || {
            warn "启用 swap 文件失败, 已保留 $swap_file."
            return
        }
    fi
    awk -v f="$swap_file" '$1 == f {found = 1} END {exit !found}' /etc/fstab 2>/dev/null || {
        echo "$swap_file none swap sw 0 0" >>/etc/fstab
    }
}

optimize_limits() {
    local file=/etc/security/limits.d/99-sing-box.conf
    mkdir -p /etc/security/limits.d
    cat >"$file" <<EOF
# Managed by sing-box install script.
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
}

optimize_logrotate() {
    local file=/etc/logrotate.d/sing-box
    mkdir -p /etc/logrotate.d
    cat >"$file" <<EOF
/var/log/sing-box/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
}

optimize_journald() {
    local dir=/etc/systemd/journald.conf.d
    [[ ! $is_systemd ]] && return
    mkdir -p "$dir"
    cat >"$dir/99-sing-box.conf" <<EOF
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=100M
EOF
}

optimize_system() {
    msg "\n开始执行代理服务器优化..."
    optimize_swap
    optimize_write_sysctl
    optimize_bbr
    optimize_limits
    optimize_logrotate
    optimize_journald
    msg "代理服务器优化完成.\n"
}
