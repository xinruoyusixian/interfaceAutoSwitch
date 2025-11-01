-- files/usr/lib/lua/luci/controller/network_switcher.lua
module("luci.controller.network_switcher", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/network_switcher") then
        return
    end
    
    entry({"admin", "services", "network_switcher"}, firstchild(), "网络切换器", 60).dependent = false
    entry({"admin", "services", "network_switcher", "overview"}, template("network_switcher/overview"), "概览", 1)
    entry({"admin", "services", "network_switcher", "settings"}, cbi("network_switcher/network_switcher"), "设置", 2)
    entry({"admin", "services", "network_switcher", "log"}, template("network_switcher/log"), "日志", 3)
    
    entry({"admin", "services", "network_switcher", "status"}, call("action_status"))
    entry({"admin", "services", "network_switcher", "switch"}, call("action_switch"))
    entry({"admin", "services", "network_switcher", "test"}, call("action_test"))
    entry({"admin", "services", "network_switcher", "get_log"}, call("action_get_log"))
    entry({"admin", "services", "network_switcher", "service_control"}, call("action_service_control"))
    entry({"admin", "services", "network_switcher", "clear_log"}, call("action_clear_log"))
    entry({"admin", "services", "network_switcher", "get_configured_interfaces"}, call("action_get_configured_interfaces"))
end

function action_status()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    local response = {}
    
    local service_status = sys.exec("/usr/bin/network_switcher status 2>/dev/null")
    if service_status:match("运行中") then
        response.service = "running"
    else
        response.service = "stopped"
    end
    
    local status_output = sys.exec("/usr/bin/network_switcher status 2>/dev/null")
    response.status_output = status_output
    
    lucihttp.prepare_content("application/json")
    lucihttp.write_json(response)
end

function action_switch()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    local interface = lucihttp.formvalue("interface")
    local response = {}
    
    if interface then
        local command
        if interface == "auto" then
            command = "auto"
        else
            command = "switch " .. interface
        end
        
        local result = sys.exec("/usr/bin/network_switcher " .. command .. " 2>&1")
        response.success = true
        response.message = result
    else
        response.success = false
        response.message = "无效的接口"
    end
    
    lucihttp.prepare_content("application/json")
    lucihttp.write_json(response)
end

function action_test()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    local result = sys.exec("/usr/bin/network_switcher test 2>&1")
    local response = {
        success = true,
        output = result
    }
    
    lucihttp.prepare_content("application/json")
    lucihttp.write_json(response)
end

function action_get_log()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    local log_content = "日志文件为空"
    if nixio.fs.access("/var/log/network_switcher.log") then
        log_content = sys.exec("cat /var/log/network_switcher.log 2>/dev/null | tail -100")
    end
    
    lucihttp.prepare_content("text/plain")
    lucihttp.write(log_content)
end

function action_service_control()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    local action = lucihttp.formvalue("action")
    local response = {}
    
    if action == "start" or action == "stop" or action == "restart" then
        local result = sys.exec("/usr/bin/network_switcher " .. action .. " 2>&1")
        response.success = true
        response.message = result
    else
        response.success = false
        response.message = "无效的操作"
    end
    
    lucihttp.prepare_content("application/json")
    lucihttp.write_json(response)
end

function action_clear_log()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    local result = sys.exec("/usr/bin/network_switcher clear_log 2>&1")
    local response = {
        success = true,
        message = result
    }
    
    lucihttp.prepare_content("application/json")
    lucihttp.write_json(response)
end

function action_get_configured_interfaces()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    local interfaces = sys.exec("/usr/bin/network_switcher configured_interfaces 2>/dev/null")
    local interface_list = {}
    
    for line in interfaces:gmatch("[^\r\n]+") do
        if line:match("^[%w%-_]+$") and not line:match("另一个实例") and not line:match("无法获取锁") then
            table.insert(interface_list, line)
        end
    end
    
    if #interface_list == 0 then
        table.insert(interface_list, "wan")
        table.insert(interface_list, "wwan")
    end
    
    lucihttp.prepare_content("application/json")
    lucihttp.write_json(interface_list)
end
