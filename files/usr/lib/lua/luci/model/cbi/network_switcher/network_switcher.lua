-- files/usr/lib/lua/luci/model/cbi/network_switcher/network_switcher.lua
local uci = require("luci.model.uci").cursor()

m = Map("network_switcher", "网络切换器配置", 
    "一个智能的网络接口切换器，支持自动故障切换和定时切换功能。")

s = m:section(TypedSection, "settings", "全局设置")
s.anonymous = true
s.addremove = false

check_interval = s:option(Value, "check_interval", "检查间隔(秒)", 
    "网络检查的时间间隔")
check_interval.datatype = "uinteger"
check_interval.default = "60"
check_interval.placeholder = "60"

ping_targets = s:option(DynamicList, "ping_targets", "Ping目标", 
    "用于测试连通性的IP地址(每行一个)")
ping_targets.default = {"8.8.8.8", "1.1.1.1", "223.5.5.5"}
ping_targets.placeholder = "8.8.8.8"

ping_count = s:option(Value, "ping_count", "Ping次数", 
    "对每个目标发送的ping包数量")
ping_count.datatype = "range(1,10)"
ping_count.default = "3"
ping_count.placeholder = "3"

ping_timeout = s:option(Value, "ping_timeout", "Ping超时(秒)", 
    "每次ping尝试的超时时间")
ping_timeout.datatype = "range(1,10)"
ping_timeout.default = "3"
ping_timeout.placeholder = "3"

switch_wait_time = s:option(Value, "switch_wait_time", "切换等待时间(秒)", 
    "切换后验证前的等待时间")
switch_wait_time.datatype = "range(1,10)"
switch_wait_time.default = "3"
switch_wait_time.placeholder = "3"

local function get_wan_interfaces()
    local interfaces = {}
    uci:foreach("network", "interface", function(s)
        -- A simple check for what might be a WAN interface.
        -- This is not perfect but is more robust than the previous method.
        -- We're looking for interfaces that have a gateway.
        local proto = s.proto
        if proto and proto ~= "none" and proto ~= "static" then
            table.insert(interfaces, s[".name"])
        end
    end)

    if #interfaces == 0 then
        -- Fallback to a default list if no potential WAN interfaces are found
        return {"wan", "wan2", "wwan"}
    end

    return interfaces
end

local interface_list = get_wan_interfaces()

interfaces_s = m:section(TypedSection, "interface", "接口配置",
    "配置网络接口用于切换。接口按优先级顺序使用(metric值越小优先级越高)。设置主接口用于自动切换的默认选择。")
interfaces_s.anonymous = true
interfaces_s.addremove = true
interfaces_s.template = "cbi/tblsection"

enabled_iface = interfaces_s:option(Flag, "enabled", "启用")
enabled_iface.default = "1"

iface_name = interfaces_s:option(ListValue, "interface", "接口名称")
for _, iface in ipairs(interface_list) do
    iface_name:value(iface, iface)
end

device = interfaces_s:option(Value, "device", "物理设备名 (可选)",
    "手动指定用于ping测试的物理设备名 (例如 eth0.2)。如果留空，脚本将自动检测。")
device.placeholder = "自动检测"

metric = interfaces_s:option(Value, "metric", "优先级", 
    "metric值越小优先级越高")
metric.datatype = "range(1,999)"
metric.default = "10"

primary = interfaces_s:option(Flag, "primary", "主接口", 
    "设置为主接口，自动切换时优先使用")
primary.default = "0"

function interfaces_s.validate(self, section)
    local primary_count = 0
    uci:foreach("network_switcher", "interface", function(s)
        if s.primary == "1" then
            primary_count = primary_count + 1
        end
    end)

    if primary_count == 0 then
        return nil, "必须设置一个主接口"
    elseif primary_count > 1 then
        return nil, "只能设置一个主接口"
    end

    return true
end

-- 重新设计定时任务部分
schedule_s = m:section(TypedSection, "schedule", "定时任务",
    "配置定时接口切换。每个定时任务包含时间和对应的切换目标。")
schedule_s.anonymous = true
schedule_s.addremove = true
schedule_s.template = "cbi/tblsection"

schedule_enabled = schedule_s:option(Flag, "enabled", "启用")
schedule_enabled.default = "1"

schedule_time = schedule_s:option(Value, "time", "时间", 
    "切换时间，格式: HH:MM (24小时制)")
schedule_time.datatype = "time"
schedule_time.default = "08:00"
schedule_time.placeholder = "08:00"

function schedule_time.validate(self, value, section)
    if not value then
        return nil, "时间不能为空"
    end
    if not value:match("^([01][0-9]|2[0-3]):[0-5][0-9]$") then
        return nil, "无效的时间格式，请输入 HH:MM 格式 (例如 08:30)"
    end
    return value
end

local target_list = {"auto"}
for _, iface in ipairs(interface_list) do
    table.insert(target_list, iface)
end

schedule_target = schedule_s:option(ListValue, "target", "切换目标", 
    "定时切换的目标接口")
schedule_target.default = "auto"
for _, target in ipairs(target_list) do
    schedule_target:value(target, target)
end

return m
