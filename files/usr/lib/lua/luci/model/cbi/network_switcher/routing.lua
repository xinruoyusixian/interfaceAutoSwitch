-- files/usr/lib/lua/luci/model/cbi/network_switcher/routing.lua
local uci = require("luci.model.uci").cursor()

m = Map("network_switcher", "策略路由")

m.description = '<div class="cbi-section-description">' ..
    '<h3>策略路由说明</h3>' ..
    '<p>此功能允许您将特定的网络流量通过指定的接口路由出去。</p>' ..
    '<h4>使用步骤：</h4>' ..
    '<ol>' ..
    '<li>启用下方的"启用策略路由"开关</li>' ..
    '<li>在下方的文本框中输入路由规则，每行一条</li>' ..
    '<li>规则格式：<code>&lt;目标地址&gt; &lt;出口接口&gt;</code></li>' ..
    '<li>点击"保存并应用"使规则生效</li>' ..
    '</ol>' ..
    '<h4>示例：</h4>' ..
    '<ul>' ..
    '<li><code>192.168.100.10 wan</code></li>' ..
    '<li><code>example.com wwan</code></li>' ..
    '<li><code>10.0.0.0/8 wwan</code></li>' ..
    '</ul>' ..
    '</div>'

s = m:section(TypedSection, "policy_routing", "全局设置")
s.anonymous = true
s.addremove = false

s:option(Flag, "enabled", "启用策略路由", "启用或禁用所有策略路由规则")

local rules_option = s:option(TextValue, "rules_text", "路由规则")
rules_option.rows = 15
rules_option.wrap = "off"
rules_option.description = "在此处输入所有路由规则，每行一条。格式：目标地址 出口接口"

function rules_option.cfgvalue(self, section)
    local rules = {}
    uci:foreach("network_switcher", "routing_rule", 
        function(s)
            if s.target and s.interface then
                table.insert(rules, s.target .. " " .. s.interface)
            end
        end
    )
    return table.concat(rules, "\n")
end

function rules_option.write(self, section, value)
    uci:delete_all("network_switcher", "routing_rule")
    
    local index = 1
    for line in value:gmatch("[^\r\n]+") do
        line = line:gsub("^%s*(.-)%s*$", "%1")
        if #line > 0 and not line:match("^#") then
            local target, interface = line:match("^(%S+)%s+(%S+)$")
            if target and interface then
                uci:set("network_switcher", "rule_" .. index, "routing_rule")
                uci:set("network_switcher", "rule_" .. index, "target", target)
                uci:set("network_switcher", "rule_" .. index, "interface", interface)
                uci:set("network_switcher", "rule_" .. index, "enabled", "1")
                index = index + 1
            end
        end
    end
end

function m.on_after_commit(self)
    os.execute("(sleep 2 && /etc/init.d/network_switcher policy-routing) >/dev/null 2>&1 &")
end

return m
