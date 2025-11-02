-- files/usr/lib/lua/luci/model/cbi/network_switcher/routing.lua
local uci = require("luci.model.uci").cursor()
local sys = require("luci.sys")

m = Map("network_switcher", "策略路由",
    "<h3>策略路由说明</h3>" ..
    "<p>此功能允许您将特定的网络流量通过指定的接口路由出去。</p>" ..
    "<ol>" ..
    "<li><b>启用策略路由:</b> 首先启用下方的“启用策略路由”开关。</li>" ..
    "<li><b>添加规则:</b> 在“路由规则”部分添加您的分流规则。</li>" ..
    "<li><b>目标地址:</b> 可以是单个IP (<code>1.2.3.4</code>), CIDR网段 (<code>1.2.3.0/24</code>), 或者域名 (<code>example.com</code>, <code>*.example.com</code>)。</li>" ..
    "<li><b>保存与应用:</b> 点击“保存并应用”后，系统将自动重载防火墙和相关服务以使规则生效。</li>" ..
    "</ol>")

-- 全局策略路由设置
s = m:section(TypedSection, "policy_routing", "全局设置")
s.anonymous = true
s.addremove = false

s:option(Flag, "enabled", "启用策略路由", "启用或禁用所有策略路由规则。")

-- 路由规则表格
rules = m:section(TypedSection, "routing_rule", "路由规则")
rules.anonymous = true
rules.addremove = true
rules.sortable = true
rules.template = "cbi/tblsection"

rules:option(Flag, "enabled", "启用").default = 1
rules:option(Value, "name", "规则名称", "为规则指定一个描述性名称。")
rules:option(Value, "target", "目标地址", "可以是 IP, CIDR, 或域名。")

-- 动态获取接口列表
local interface_list = {}
uci:foreach("network", "interface", function(s)
    local proto = s.proto
    if proto and proto ~= "none" then
        table.insert(interface_list, s[".name"])
    end
end)

if #interface_list == 0 then
    -- Fallback
    interface_list = {"wan", "wan2", "wwan"}
end

local iface = rules:option(ListValue, "interface", "出口接口")
for _, i in ipairs(interface_list) do
    iface:value(i)
end

function m.on_after_commit(self)
    -- Reload firewall and restart dnsmasq to apply changes
    sys.call("/etc/init.d/network_switcher restart >/dev/null 2>&1")
    sys.call("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
    sys.call("/sbin/reload_config >/dev/null 2>&1")
end

return m
