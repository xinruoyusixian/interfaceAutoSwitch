-- files/usr/lib/lua/luci/model/cbi/network_switcher/routing.lua
local uci = require("luci.model.uci").cursor()
local sys = require("luci.sys")
local fs = require("nixio.fs")

m = Map("network_switcher", "策略路由",
    "<h3>策略路由说明</h3>" ..
    "<p>此功能允许您将特定的网络流量通过指定的接口路由出去。</p>" ..
    "<ol>" ..
    "<li><b>启用策略路由:</b> 首先启用下方的“启用策略路由”开关。</li>" ..
    "<li><b>批量添加规则:</b> 在下方的文本框中输入您的路由规则，每行一条。</li>" ..
    "<li><b>规则格式:</b> 每行格式为 <code>&lt;目标地址&gt; &lt;出口接口&gt;</code>，用空格或Tab分隔。例如:</li>" ..
    "<ul>" ..
    "<li><code>192.168.100.10 wan</code></li>" ..
    "<li><code>example.com wwan</code></li>" ..
    "<li><code>*.google.com wan</code></li>" ..
    "<li><code>10.0.0.0/8 wwan</code></li>" ..
    "</ul>" ..
    "<li><b>保存与应用:</b> 点击“保存并应用”后，系统将自动重载防火墙和相关服务以使规则生效。</li>" ..
    "</ol>")

-- 全局策略路由设置
s = m:section(TypedSection, "policy_routing", "全局设置")
s.anonymous = true
s.addremove = false

s:option(Flag, "enabled", "启用策略路由", "启用或禁用所有策略路由规则。")

-- 路由规则文本框
local rules_option = s:option(TextValue, "rules_text", "路由规则 (批量编辑)")
rules_option.rows = 15
rules_option.wrap = "off"
rules_option.description = "在此处输入所有路由规则，每行一条，格式为: <目标> <接口>"

-- 在 on_after_commit 中处理文本到UCI的转换
-- cfgvalue function to populate the textarea from UCI sections
function rules_option.cfgvalue(self, section)
    local rules = {}
    uci:foreach("network_switcher", "routing_rule", function(s)
        local target = s.target
        local interface = s.interface
        if target and interface then
            table.insert(rules, string.format("%s %s", target, interface))
        end
    end)
    return table.concat(rules, "\n")
end

-- on_after_commit is now write_json, which is a more standard way for TextValue
function rules_option.write(self, section, value)
    -- First, clear all old routing_rule sections
    while uci:get("network_switcher", uci:get_first("network_switcher", "routing_rule")) do
        uci:delete("network_switcher", uci:get_first("network_switcher", "routing_rule"))
    end

    -- Parse each line from the textarea value and create new sections
    local rule_index = 0
    for line in (value .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if #line > 0 and not line:match("^#") then
            local target, interface = line:match("([^%s]+)%s+([^%s]+)")
            if target and interface then
                local section_name = uci:add("network_switcher", "routing_rule")
                uci:set("network_switcher", section_name, "target", target)
                uci:set("network_switcher", section_name, "interface", interface)
                uci:set("network_switcher", section_name, "enabled", "1")
                uci:set("network_switcher", section_name, "name", "Rule " .. (rule_index + 1))
                rule_index = rule_index + 1
            end
        end
    end
    -- We don't need to call uci:save/commit here, CBI handles it
end

function m.on_after_commit(self)
    -- Need to commit the changes made in rules_option.write
    uci:save("network_switcher")
    uci:commit("network_switcher")

    -- Reload service asynchronously
    fs.write("/tmp/network_switcher_restart.sh", "#!/bin/sh\n/etc/init.d/network_switcher policy-routing\n")
    sys.call("chmod +x /tmp/network_switcher_restart.sh")
    sys.call("/tmp/network_switcher_restart.sh >/dev/null 2>&1 &")
end

return m
