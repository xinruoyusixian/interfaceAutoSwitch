#!/bin/sh
# files/network_switcher.sh

export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin"
export HOME="/root"
umask 0022

CONFIG_FILE="/etc/config/network_switcher"
LOCK_FILE="/var/lock/network_switcher.lock"
LOG_FILE="/var/log/network_switcher.log"
STATE_FILE="/var/state/network_switcher.state"
PID_FILE="/var/run/network_switcher.pid"

# Globals for policy routing
NFT_TABLE="network_switcher"
NFT_CHAIN_PREROUTING="ns_prerouting"
NFT_CHAIN_POSTROUTING="ns_postrouting"
NFT_SET_PREFIX="ns_set"

flush_nftables_config() {
    nft flush table inet ${NFT_TABLE} >/dev/null 2>&1
    nft delete table inet ${NFT_TABLE} >/dev/null 2>&1
}

init_nftables_table_and_chains() {
    # Create a new table
    nft add table inet ${NFT_TABLE}

    # Create prerouting and postrouting chains
    nft add chain inet ${NFT_TABLE} ${NFT_CHAIN_PREROUTING} { type filter hook prerouting priority -150 \; }
    nft add chain inet ${NFT_TABLE} ${NFT_CHAIN_POSTROUTING} { type nat hook postrouting priority 100 \; }
}

setup_policy_routing() {
    log "--- 开始设置策略路由 ---" "POLICY_ROUTING"

    log "清理旧的 dnsmasq 策略路由配置..." "POLICY_ROUTING"
    rm -f /tmp/dnsmasq.d/network_switcher.conf
    touch /tmp/dnsmasq.d/network_switcher.conf

    log "清理旧的 ip rules..." "POLICY_ROUTING"
    ip -4 rule list | grep -oP 'from all fwmark 0x[0-9a-f]+/0xffff lookup \K[0-9]+' | xargs -r -n1 ip -4 rule delete table

    local enabled=$(uci -q get network_switcher.policy_routing.enabled || echo "0")
    if [ "$enabled" != "1" ]; then
        log "策略路由功能已禁用。正在清理所有相关规则..." "POLICY_ROUTING"
        flush_nftables_config
        killall -HUP dnsmasq # Reload dnsmasq to remove old config
        log "--- 策略路由设置完成 (已禁用) ---" "POLICY_ROUTING"
        return
    fi

    log "策略路由功能已启用。正在初始化 nftables..." "POLICY_ROUTING"
    flush_nftables_config
    init_nftables_table_and_chains

    local rule_index=0
    local fwmark=1
    while uci -q get "network_switcher.@routing_rule[$rule_index]" >/dev/null 2>&1; do
        local rule_enabled=$(uci -q get "network_switcher.@routing_rule[$rule_index].enabled" || echo "0")
        local name=$(uci -q get "network_switcher.@routing_rule[$rule_index].name" || echo "未命名规则")
        local target=$(uci -q get "network_switcher.@routing_rule[$rule_index].target")
        local interface=$(uci -q get "network_switcher.@routing_rule[$rule_index].interface")

        if [ "$rule_enabled" = "1" ] && [ -n "$target" ] && [ -n "$interface" ]; then
            log "处理规则 [${name}]: 目标=${target}, 接口=${interface}" "POLICY_ROUTING"
            local set_name="${NFT_SET_PREFIX}_${rule_index}"
            local table_id=$((100 + rule_index))

            log "创建 nft set: ${set_name}" "POLICY_ROUTING"
            nft add set inet ${NFT_TABLE} ${set_name} { type ipv4_addr\; flags interval\; }

            case "$target" in
                # IP/CIDR
                *[0-9].[0-9]*)
                    log "目标为 IP/CIDR，添加到 set..." "POLICY_ROUTING"
                    nft add element inet ${NFT_TABLE} ${set_name} { ${target} }
                    ;;
                # Domain
                *)
                    log "目标为域名，配置 dnsmasq nftset..." "POLICY_ROUTING"
                    echo "nftset=/${target}/4#inet#${NFT_TABLE}#${set_name}" >> /tmp/dnsmasq.d/network_switcher.conf
                    ;;
            esac

            log "添加 nftables 标记规则 (fwmark=${fwmark})..." "POLICY_ROUTING"
            nft add rule inet ${NFT_TABLE} ${NFT_CHAIN_PREROUTING} ip daddr @${set_name} mark set ${fwmark}

            local gateway=$(ubus call network.interface.${interface} status 2>/dev/null | jsonfilter -e '@.route[0].nexthop')
            if [ -n "$gateway" ]; then
                log "为接口 ${interface} 添加 ip rule 和路由 (路由表 ID=${table_id})..." "POLICY_ROUTING"
                ip -4 rule add fwmark ${fwmark} table ${table_id}
                ip -4 route add default via ${gateway} dev $(get_interface_device ${interface}) table ${table_id}

                log "为接口 ${interface} 添加 SNAT 规则..." "POLICY_ROUTING"
                nft add rule inet ${NFT_TABLE} ${NFT_CHAIN_POSTROUTING} oifname "$(get_interface_device ${interface})" masquerade
            else
                log "警告: 无法为接口 ${interface} 获取网关，跳过此规则。" "POLICY_ROUTING"
            fi

            fwmark=$((fwmark + 1))
        else
            log "跳过已禁用的规则 #${rule_index}" "POLICY_ROUTING"
        fi
        rule_index=$((rule_index + 1))
    done

    log "重载 dnsmasq 以应用域名规则..." "POLICY_ROUTING"
    killall -HUP dnsmasq

    log "--- 策略路由设置完成 ---" "POLICY_ROUTING"
}

read_uci_config() {
    ENABLED=$(uci -q get network_switcher.settings.enabled)
    [ -z "$ENABLED" ] && ENABLED=$(uci -q get network_switcher.settings.enabled || echo "1")
    CHECK_INTERVAL=$(uci -q get network_switcher.settings.check_interval || echo "60")
    PING_COUNT=$(uci -q get network_switcher.settings.ping_count || echo "3")
    PING_TIMEOUT=$(uci -q get network_switcher.settings.ping_timeout || echo "3")
    SWITCH_WAIT_TIME=$(uci -q get network_switcher.settings.switch_wait_time || echo "3")
    
    # 确保数值变量有合理的默认值
    [ -z "$CHECK_INTERVAL" ] && CHECK_INTERVAL=60
    [ -z "$PING_COUNT" ] && PING_COUNT=3
    [ -z "$PING_TIMEOUT" ] && PING_TIMEOUT=3
    [ -z "$SWITCH_WAIT_TIME" ] && SWITCH_WAIT_TIME=3
    
    PING_SUCCESS_COUNT=$(uci -q get network_switcher.settings.ping_success_count || echo "1")
    [ -z "$PING_SUCCESS_COUNT" ] && PING_SUCCESS_COUNT=1
    
    # More robust way to read UCI list into a space-separated string
    local targets
    local IFS_bak="$IFS"
    IFS=$'\n'
    targets=$(uci -q get network_switcher.settings.ping_targets)
    if [ -n "$targets" ]; then
        PING_TARGETS=$(echo $targets)
    fi
    IFS="$IFS_bak"

    # Fallback to default if still empty
    if [ -z "$PING_TARGETS" ]; then
        PING_TARGETS="8.8.8.8 1.1.1.1 223.5.5.5"
    fi
    
    # 去除多余空格
    PING_TARGETS=$(echo $PING_TARGETS | sed 's/^ *//;s/ *$//')
    
    
    INTERFACES=""
    INTERFACE_COUNT=0
    PRIMARY_INTERFACE=""
    
    # 首先处理命名接口配置
    local config_sections=$(uci show network_switcher 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1)
    
    for section in $config_sections; do
        if [ "$section" = "settings" ] || [ "$section" = "schedule" ]; then
            continue
        fi
        
        local enabled=$(uci -q get network_switcher.$section.enabled || echo "1")
        local interface=$(uci -q get network_switcher.$section.interface)
        local device=$(uci -q get network_switcher.$section.device)
        local primary=$(uci -q get network_switcher.$section.primary || echo "0")
        
        if [ "$enabled" = "1" ] && [ -n "$interface" ]; then
            # 检查是否已经添加过这个接口
            if echo "$INTERFACES" | grep -q "\b$interface\b"; then
                continue
            fi
            
            INTERFACE_COUNT=$((INTERFACE_COUNT + 1))
            INTERFACES="$INTERFACES $interface"
            
            if [ "$primary" = "1" ]; then
                PRIMARY_INTERFACE="$interface"
            fi
        fi
    done
    
    # 然后处理匿名接口配置
    local section_index=0
    while uci -q get "network_switcher.@interface[$section_index]" >/dev/null 2>&1; do
        local enabled=$(uci -q get "network_switcher.@interface[$section_index].enabled" || echo "1")
        local interface=$(uci -q get "network_switcher.@interface[$section_index].interface")
        local device=$(uci -q get "network_switcher.@interface[$section_index].device")
        local primary=$(uci -q get "network_switcher.@interface[$section_index].primary" || echo "0")
        
        if [ "$enabled" = "1" ] && [ -n "$interface" ]; then
            # 检查是否已经添加过这个接口
            if echo "$INTERFACES" | grep -q "\b$interface\b"; then
                section_index=$((section_index + 1))
                continue
            fi
            
            INTERFACE_COUNT=$((INTERFACE_COUNT + 1))
            INTERFACES="$INTERFACES $interface"
            
            if [ "$primary" = "1" ]; then
                PRIMARY_INTERFACE="$interface"
            fi
        fi
        
        section_index=$((section_index + 1))
    done
    
    # 如果没有找到任何接口，使用默认值
    if [ $INTERFACE_COUNT -eq 0 ]; then
        INTERFACES="wan wwan"
        INTERFACE_COUNT=2
        PRIMARY_INTERFACE="wan"
    fi
    
    # 如果没有设置主接口，使用第一个接口
    if [ -z "$PRIMARY_INTERFACE" ] && [ $INTERFACE_COUNT -gt 0 ]; then
        PRIMARY_INTERFACE=$(echo $INTERFACES | awk '{print $1}')
    fi
    
    LOG_LEVEL=$(uci -q get network_switcher.settings.log_level || echo "INFO")

    # 调试信息
    log "配置读取: ENABLED=$ENABLED, INTERFACES='$INTERFACES', PRIMARY='$PRIMARY_INTERFACE', LOG_LEVEL='$LOG_LEVEL'" "DEBUG"
}

log() {
    local message="$1"
    local level="$2"

    [ -z "$LOG_LEVEL" ] && LOG_LEVEL="INFO"

    case "$LOG_LEVEL" in
        "DEBUG")
            ;;
        "INFO")
            if [ "$level" = "DEBUG" ]; then
                return
            fi
            ;;
        "WARN")
            if [ "$level" = "DEBUG" ] || [ "$level" = "INFO" ]; then
                return
            fi
            ;;
        "ERROR")
            if [ "$level" != "ERROR" ]; then
                return
            fi
            ;;
        "POLICY_ROUTING")
            ;;
        *)
            if [ "$level" = "DEBUG" ]; then
                return
            fi
            ;;
    esac

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

acquire_lock_silent() {
    local max_retries=2
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        if [ -f "$LOCK_FILE" ]; then
            local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
            if [ -n "$lock_pid" ] && [ -d "/proc/$lock_pid" ]; then
                retry_count=$((retry_count + 1))
                sleep 1
                continue
            else
                rm -f "$LOCK_FILE" 2>/dev/null
            fi
        fi
        
        echo $$ > "$LOCK_FILE" 2>/dev/null
        if [ -f "$LOCK_FILE" ] && [ "$(cat "$LOCK_FILE" 2>/dev/null)" = "$$" ]; then
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        sleep 1
    done
    
    return 1
}

acquire_lock() {
    if ! acquire_lock_silent; then
        echo "另一个实例正在运行，无法获取锁"
        exit 1
    fi
}

acquire_lock_non_blocking() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && [ -d "/proc/$lock_pid" ]; then
            return 1
        else
            rm -f "$LOCK_FILE" 2>/dev/null
        fi
    fi
    
    echo $$ > "$LOCK_FILE" 2>/dev/null
    if [ -f "$LOCK_FILE" ] && [ "$(cat "$LOCK_FILE" 2>/dev/null)" = "$$" ]; then
        return 0
    fi
    
    return 1
}

release_lock() {
    if [ -f "$LOCK_FILE" ] && [ "$(cat "$LOCK_FILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$LOCK_FILE"
    fi
}

cleanup_stale_processes() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -z "$lock_pid" ] || [ ! -d "/proc/$lock_pid" ]; then
            rm -f "$LOCK_FILE"
        fi
    fi
    
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -z "$pid" ] || [ ! -d "/proc/$pid" ]; then
            rm -f "$PID_FILE"
        fi
    fi
    
    local stale_pids=$(pgrep -f "network_switcher daemon" 2>/dev/null)
    if [ -n "$stale_pids" ]; then
        for pid in $stale_pids; do
            if [ "$pid" != "$$" ]; then
                kill $pid 2>/dev/null
            fi
        done
    fi
}

service_control() {
    local action="$1"
    
    case "$action" in
        "start")
            echo "正在启动网络切换服务..."
            
            cleanup_stale_processes
            
            if [ -f "$PID_FILE" ] && [ -d "/proc/$(cat "$PID_FILE")" ]; then
                echo "服务已在运行 (PID: $(cat "$PID_FILE"))"
                return 0
            fi
            
            read_uci_config
            
            if [ $INTERFACE_COUNT -eq 0 ]; then
                echo "错误: 未配置任何有效的网络接口"
                return 1
            fi
            
            mkdir -p /var/lock /var/log /var/state /var/run
            
            log "启动网络切换服务" "SERVICE"
            
            setup_policy_routing

            run_daemon &
            local pid=$!
            echo $pid > "$PID_FILE"
            sleep 2
            
            if [ -d "/proc/$pid" ]; then
                echo "服务启动成功 (PID: $pid)"
            else
                echo "服务启动失败"
                rm -f "$PID_FILE"
                return 1
            fi
            ;;
        "stop")
            echo "正在停止网络切换服务..."
            
            cleanup_stale_processes
            
            if [ -f "$PID_FILE" ]; then
                local pid=$(cat "$PID_FILE")
                if [ -d "/proc/$pid" ]; then
                    echo "停止服务 (PID: $pid)"
                    kill $pid 2>/dev/null
                    sleep 2
                    
                    if [ -d "/proc/$pid" ]; then
                        kill -9 $pid 2>/dev/null
                        echo "强制停止服务"
                    fi
                    
                    log "停止网络切换服务" "SERVICE"
                else
                    echo "服务未运行"
                fi
                rm -f "$PID_FILE"
            else
                echo "服务未运行"
            fi
            
            flush_nftables_config

            echo "服务停止完成"
            ;;
        "restart")
            echo "正在重启网络切换服务..."
            acquire_lock
            trap release_lock EXIT
            service_control stop
            sleep 2
            service_control start
            ;;
        "status")
            if [ -f "$PID_FILE" ]; then
                local pid=$(cat "$PID_FILE")
                if [ -d "/proc/$pid" ]; then
                    echo "运行中 (PID: $pid)"
                    return 0
                else
                    echo "已停止"
                    return 1
                fi
            else
                if pgrep -f "network_switcher daemon" >/dev/null 2>&1; then
                    echo "运行中"
                    return 0
                else
                    echo "已停止"
                    return 1
                fi
            fi
            ;;
    esac
}

get_configured_interfaces() {
    for iface in $INTERFACES; do
        echo "$iface"
    done
}

get_interface_device() {
    local interface="$1"
    local device=$(uci -q get network_switcher.$interface.device)
    [ -n "$device" ] && echo "$device" && return

    ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null
}

is_interface_available() {
    local interface="$1"
    local device=$(get_interface_device "$interface")
    
    if [ -z "$device" ]; then
        return 1
    fi
    
    if ! ip link show "$device" 2>/dev/null | grep -q "state UP"; then
        return 1
    fi
    
    local gateway=$(ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
    if [ -z "$gateway" ]; then
        return 1
    fi
    
    return 0
}

test_network_connectivity() {
    local interface="$1"
    local device=$(get_interface_device "$interface")
    
    if [ -z "$device" ]; then
        return 1
    fi
    
    local success_count=0
    for target in $PING_TARGETS; do
        if ping -I "$device" -c $PING_COUNT -W $PING_TIMEOUT "$target" >/dev/null 2>&1; then
            success_count=$((success_count + 1))
            if [ $success_count -ge $PING_SUCCESS_COUNT ]; then
                return 0 # Success
            fi
        fi
    done
    
    return 1 # Failure
}

switch_interface() {
    local target_interface="$1"
    
    echo "开始切换到: $target_interface"
    log "开始切换到: $target_interface" "SWITCH"
    
    local device=$(get_interface_device "$target_interface")
    if [ -z "$device" ]; then
        echo "错误: 无法获取接口设备"
        return 1
    fi
    
    local gateway=$(ubus call network.interface.$target_interface status 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
    if [ -z "$gateway" ]; then
        echo "错误: 无法获取网关"
        return 1
    fi
    
    local metric="10"
    
    # 查找接口的metric配置
    local config_sections=$(uci show network_switcher 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1)
    for section in $config_sections; do
        if [ "$section" = "settings" ] || [ "$section" = "schedule" ]; then
            continue
        fi
        
        local iface=$(uci -q get network_switcher.$section.interface)
        if [ "$iface" = "$target_interface" ]; then
            metric=$(uci -q get network_switcher.$section.metric || echo "10")
            break
        fi
    done
    
    local section_index=0
    while uci -q get "network_switcher.@interface[$section_index]" >/dev/null 2>&1; do
        local iface=$(uci -q get "network_switcher.@interface[$section_index].interface")
        if [ "$iface" = "$target_interface" ]; then
            metric=$(uci -q get "network_switcher.@interface[$section_index].metric" || echo "10")
            break
        fi
        section_index=$((section_index + 1))
    done
    
    log "删除默认路由..." "INFO"
    ip route del default 2>/dev/null
    log "添加新默认路由: via $gateway dev $device metric $metric" "INFO"
    ip route replace default via "$gateway" dev "$device" metric "$metric"
    
    # 确保 SWITCH_WAIT_TIME 有值
    local wait_time=${SWITCH_WAIT_TIME:-3}
    log "等待 $wait_time 秒..." "INFO"
    sleep "$wait_time"
    
    local current_device=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
    log "当前默认路由设备: $current_device" "INFO"
    
    if [ "$current_device" = "$device" ]; then
        log "路由切换成功，测试网络连通性..." "INFO"
        if test_network_connectivity "$target_interface"; then
            echo "切换到 $target_interface 成功"
            log "切换到 $target_interface 成功" "SWITCH"
            echo "$target_interface" > "$STATE_FILE"
            return 0
        else
            echo "切换后网络测试失败"
        fi
    else
        echo "路由切换验证失败，期望设备: $device，实际设备: $current_device"
    fi
    
    echo "切换验证失败"
    log "切换到 $target_interface 失败" "ERROR"
    return 1
}

auto_switch() {
    if [ "$ENABLED" != "1" ]; then
        echo "服务未启用"
        return 0
    fi
    
    if [ -n "$PRIMARY_INTERFACE" ]; then
        if is_interface_available "$PRIMARY_INTERFACE" && test_network_connectivity "$PRIMARY_INTERFACE"; then
            local current_device=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
            local primary_device=$(get_interface_device "$PRIMARY_INTERFACE")
            
            if [ "$current_device" != "$primary_device" ]; then
                echo "主接口可用，切换到主接口: $PRIMARY_INTERFACE"
                switch_interface "$PRIMARY_INTERFACE" && {
                    return 0
                }
            else
                echo "已经是主接口，无需切换"
                return 0
            fi
        else
            echo "主接口不可用: $PRIMARY_INTERFACE"
        fi
    fi
    
    for interface in $INTERFACES; do
        if [ "$interface" != "$PRIMARY_INTERFACE" ]; then
            if is_interface_available "$interface" && test_network_connectivity "$interface"; then
                local current_device=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
                local target_device=$(get_interface_device "$interface")
                
                if [ "$current_device" != "$target_device" ]; then
                    echo "备用接口可用，切换到: $interface"
                    switch_interface "$interface" && {
                        return 0
                    }
                else
                    echo "已经是目标接口，无需切换"
                    return 0
                fi
            else
                echo "接口不可用: $interface"
            fi
        fi
    done
    
    echo "所有接口都不可用"
    log "所有接口都不可用" "ERROR"
    return 1
}

show_status() {
    echo "=== 网络切换器状态 ==="
    echo "服务状态: $(service_control status)"
    echo "检查间隔: ${CHECK_INTERVAL}秒"
    echo "主接口: ${PRIMARY_INTERFACE:-未设置}"
    echo ""
    
    local current_device=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
    local current_interface=""
    for interface in $INTERFACES; do
        local device=$(get_interface_device "$interface")
        if [ "$device" = "$current_device" ]; then
            current_interface="$interface"
            break
        fi
    done
    
    if [ -n "$current_interface" ]; then
        echo "当前互联网出口: $current_interface"
    else
        echo "当前互联网出口: $current_device"
    fi
    
    echo -e "\n=== 接口状态 ==="
    
    if [ $INTERFACE_COUNT -eq 0 ]; then
        echo "未配置任何网络接口"
    else
        for interface in $INTERFACES; do
            echo -e "\n--- $interface"
            local device=$(get_interface_device "$interface")
            local gateway=$(ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
            local status=$(ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null || echo "false")
            
            echo "  设备: $device"
            echo "  状态: $status"
            echo "  网关: $gateway"
            
            if [ "$status" = "true" ] && [ -n "$device" ] && [ -n "$gateway" ]; then
                if test_network_connectivity "$interface"; then
                    echo "  网络: ✓ 连通"
                else
                    echo "  网络: ✗ 断开"
                fi
            else
                echo "  网络: ✗ 不可用"
            fi
        done
    fi
}

test_connectivity() {
    log "=== 网络连通性测试 ===" "INFO"
    log "测试目标: $PING_TARGETS" "INFO"
    log "Ping次数: $PING_COUNT, 超时: ${PING_TIMEOUT}s" "INFO"
    log "要求成功次数: $PING_SUCCESS_COUNT" "INFO"

    if [ $INTERFACE_COUNT -eq 0 ]; then
        log "未配置任何网络接口" "WARN"
        return
    fi

    for interface in $INTERFACES; do
        log "--- 测试接口: $interface ---" "INFO"
        local device=$(get_interface_device "$interface")

        if [ -z "$device" ]; then
            log "  [状态] ✗ 接口未就绪" "WARN"
            continue
        fi

        log "  [状态] ✓ 接口就绪 (设备: $device)" "INFO"

        if is_interface_available "$interface"; then
            log "  [Ping 测试]" "INFO"
            
            local success_count=0
            local total_targets=$(echo "$PING_TARGETS" | wc -w)

            for target in $PING_TARGETS; do
                if ping -I "$device" -c $PING_COUNT -W $PING_TIMEOUT "$target" >/dev/null 2>&1; then
                    log "    ✓ $target: 成功" "INFO"
                    success_count=$((success_count + 1))
                else
                    log "    ✗ $target: 失败" "INFO"
                fi
            done

            log "  [结果]" "INFO"
            log "    - 成功: $success_count" "INFO"
            log "    - 失败: $((total_targets - success_count))" "INFO"
            log "    - 总计: $total_targets" "INFO"
            
            if [ $success_count -ge $PING_SUCCESS_COUNT ]; then
                log "  [结论] ✓ 通过 (成功次数 $success_count >= 要求次数 $PING_SUCCESS_COUNT)" "INFO"
            else
                log "  [结论] ✗ 失败 (成功次数 $success_count < 要求次数 $PING_SUCCESS_COUNT)" "INFO"
            fi
        else
            log "  [状态] ✗ 接口不可用 (无活动链接或网关)" "WARN"
        fi
    done
    log "=== 测试完成 ===" "INFO"
}



clear_log() {
    if [ -f "$LOG_FILE" ]; then
        > "$LOG_FILE"
        echo "日志已清空"
        log "日志已清空" "SERVICE"
    else
        echo "日志文件不存在"
    fi
}

# 在主脚本中添加定时任务处理函数
check_schedule() {
    local current_time=$(date '+%H:%M')
    local current_minutes=$(date '+%H:%M' | sed 's/://')
    
    # 检查所有定时任务
    local section_index=0
    while uci -q get "network_switcher.@schedule[$section_index]" >/dev/null 2>&1; do
        local enabled=$(uci -q get "network_switcher.@schedule[$section_index].enabled" || echo "1")
        local schedule_time=$(uci -q get "network_switcher.@schedule[$section_index].time")
        local target=$(uci -q get "network_switcher.@schedule[$section_index].target")
        
        if [ "$enabled" = "1" ] && [ -n "$schedule_time" ] && [ -n "$target" ]; then
            local schedule_minutes=$(echo "$schedule_time" | sed 's/://')
            
            # 简单的时间匹配（精确到分钟）
            if [ "$current_minutes" = "$schedule_minutes" ]; then
                echo "执行定时任务: $schedule_time -> $target"
                log "执行定时任务: $schedule_time -> $target" "SCHEDULE"
                
                if [ "$target" = "auto" ]; then
                    auto_switch
                else
                    switch_interface "$target"
                fi
                
                # 避免同一分钟内重复执行
                sleep 1
                return 0
            fi
        fi
        
        section_index=$((section_index + 1))
    done
    
    return 0
}

# 在 run_daemon 函数中添加定时任务检查
run_daemon() {
    trap 'log "收到信号，退出守护进程" "SERVICE"; rm -f "$PID_FILE"; exit 0' TERM INT
    
    log "启动守护进程" "SERVICE"

    local last_schedule_check=0
    
    while true; do
        read_uci_config
        
        if [ "$ENABLED" = "1" ] && [ $INTERFACE_COUNT -gt 0 ]; then
            if ! acquire_lock_non_blocking; then
                log "无法获取锁，跳过此次检查" "DEBUG"
                sleep "$CHECK_INTERVAL"
                continue
            fi

            # 每分钟检查一次定时任务
            local current_time=$(date +%s)
            if [ $((current_time - last_schedule_check)) -ge 59 ]; then
                check_schedule
                last_schedule_check=$current_time
            else
                auto_switch
            fi

            release_lock
        else
            log "服务已禁用或无接口配置，退出守护进程" "SERVICE"
            break
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

main() {
    read_uci_config

    case "$1" in
        start|stop|restart)
            service_control "$1"
            ;;
        daemon)
            run_daemon
            ;;
        auto)
            acquire_lock
            auto_switch
            release_lock
            ;;
        switch)
            if [ -n "$2" ]; then
                acquire_lock
                switch_interface "$2"
                release_lock
            else
                echo "用法: $0 switch <接口名>"
                echo "可用接口:"
                get_configured_interfaces
            fi
            ;;
        test)
            test_connectivity
            ;;
        status)
            show_status
            ;;
        configured_interfaces)
            get_configured_interfaces
            ;;
        clear_log)
            clear_log
            ;;
        current_interface)
            ip route show default 2>/dev/null | head -1 | awk '{print $5}'
            ;;
        cleanup)
            cleanup_stale_processes
            ;;
        policy-routing)
            setup_policy_routing
            ;;
        *)
            echo "网络切换器 v1.2.4"
            echo ""
            echo "用法: $0 <命令>"
            echo ""
            echo "命令:"
            echo "  start       启动服务"
            echo "  stop        停止服务" 
            echo "  restart     重启服务"
            echo "  status      服务状态"
            echo "  daemon      守护进程"
            echo "  auto        自动切换"
            echo "  switch IF   切换到接口"
            echo "  test        网络测试"
            echo "  policy-routing 应用策略路由"
            echo "  configured_interfaces 已配置接口"
            echo "  clear_log   清空日志"
            echo "  current_interface 当前接口"
            echo "  cleanup     清理残留进程"
            ;;
    esac
}

main "$@"
