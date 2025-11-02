OpenWrt 网络切换器 AI写的 
一个智能的网络接口切换器，支持自动故障切换和定时切换功能，适用于 OpenWrt/LEDE 系统。

功能特性
🚀 智能故障切换 - 自动检测网络连通性并切换到备用接口

⏰ 定时切换 - 支持按时间计划自动切换网络接口

🖥️ Web 界面 - 完整的 LuCI 配置界面，易于使用

📊 实时监控 - 实时显示网络状态和切换日志

🔧 灵活配置 - 可配置 Ping 目标、检查间隔、优先级等参数

🔒 安全可靠 - 智能锁机制，避免路由表冲突

界面预览
https://via.placeholder.com/800x400.png?text=Network+Switcher+Overview
网络切换器概览页面

https://via.placeholder.com/800x400.png?text=Configuration+Page
配置页面

安装说明
前提条件
OpenWrt 或 LEDE 系统

已安装 LuCI Web 界面

至少两个网络接口（如 WAN、WWAN 等）

编译安装
将项目克隆到 OpenWrt SDK 的 package 目录：

bash
cd openwrt/package
git clone https://github.com/yourusername/network-switcher.git
配置并编译：

bash
make menuconfig
# 在 Network -> network-switcher 中选择为 [*] 或 [M]
make package/network-switcher/compile V=s
安装 IPK 文件：

bash
opkg install bin/packages/your_arch/base/network-switcher_*.ipk
直接安装
从 Releases 页面下载预编译的 IPK 文件：

bash
opkg install network-switcher_1.3.0-1_all.ipk
配置说明
基本配置
访问 LuCI 界面：http://192.168.1.1/cgi-bin/luci/admin/services/network_switcher

在"设置"页面配置以下参数：

全局设置
启用服务 - 开启/关闭网络切换服务

检查间隔 - 网络连通性检查的时间间隔（秒）

Ping 目标 - 用于测试连通性的 IP 地址列表

Ping 成功次数 - 需要成功 Ping 通的目标数量

Ping 次数 - 对每个目标发送的 Ping 包数量

Ping 超时 - 每次 Ping 尝试的超时时间（秒）

切换等待时间 - 切换后验证前的等待时间（秒）

接口配置
接口名称 - 要监控的网络接口（如 wan、wwan）

优先级 - Metric 值，越小优先级越高

主接口 - 设置为主接口，自动切换时优先使用

定时任务
启用 - 启用/禁用定时任务

时间 - 切换时间（HH:MM 格式）

切换目标 - 定时切换的目标接口或自动模式

配置文件
手动编辑配置文件 /etc/config/network_switcher：

bash
config settings 'settings'
    option enabled '1'
    option check_interval '60'
    list ping_targets '8.8.8.8'
    list ping_targets '1.1.1.1'
    list ping_targets '223.5.5.5'
    option ping_success_count '1'
    option ping_count '3'
    option ping_timeout '3'
    option switch_wait_time '3'

config interface 'wan'
    option enabled '1'
    option interface 'wan'
    option metric '10'
    option primary '1'

config interface 'wwan'
    option enabled '1'
    option interface 'wwan'
    option metric '20'
    option primary '0'

config schedule 'morning'
    option enabled '1'
    option time '08:00'
    option target 'auto'

config schedule 'evening'
    option enabled '1'
    option time '18:00'
    option target 'auto'
使用方法
Web 界面操作
服务控制

启用/禁用服务

查看服务状态

重启服务

手动切换

选择目标接口进行手动切换

使用自动模式让系统智能选择

网络测试

测试所有接口的网络连通性

查看详细的 Ping 测试结果

实时日志

查看操作日志和错误信息

支持自动刷新和清空日志

命令行操作
bash
# 启动服务
/usr/bin/network_switcher start

# 停止服务
/usr/bin/network_switcher stop

# 重启服务
/usr/bin/network_switcher restart

# 查看状态
/usr/bin/network_switcher status

# 手动切换到指定接口
/usr/bin/network_switcher switch wan

# 执行自动切换
/usr/bin/network_switcher auto

# 测试网络连通性
/usr/bin/network_switcher test

# 查看配置
/usr/bin/network_switcher debug_config

# 清空日志
/usr/bin/network_switcher clear_log
故障排除
常见问题
服务无法启动

检查是否配置了有效的网络接口

查看系统日志：logread | grep network_switcher

切换失败

确认目标接口有有效的网关和路由

检查接口状态：ubus call network.interface.wan status

Web 界面按钮无响应

清除 LuCI 缓存：rm -rf /tmp/luci-*

重启 uhttpd：/etc/init.d/uhttpd restart

锁冲突问题

检查是否有其他实例运行：pgrep -f network_switcher

清理残留锁文件：rm -f /var/lock/network_switcher.lock

日志查看
bash
# 查看服务日志
tail -f /var/log/network_switcher.log

# 查看系统日志
logread -f | grep network_switcher
调试模式
启用详细日志输出：

bash
/usr/bin/network_switcher debug_config
/usr/bin/network_switcher switch wan 2>&1
文件结构
text
/usr/bin/network_switcher              # 主程序
/etc/config/network_switcher           # 配置文件
/etc/init.d/network_switcher           # 初始化脚本
/usr/lib/lua/luci/controller/network_switcher.lua          # LuCI 控制器
/usr/lib/lua/luci/model/cbi/network_switcher/network_switcher.lua  # CBI 配置
/usr/lib/lua/luci/view/network_switcher/overview.htm       # 概览页面
/usr/lib/lua/luci/view/network_switcher/log.htm            # 日志页面
/var/log/network_switcher.log          # 日志文件
/var/lock/network_switcher.lock        # 锁文件
/var/run/network_switcher.pid          # PID 文件
开发说明
项目结构
text
network-switcher/
├── Makefile                          # 构建配置
├── files/
│   ├── network_switcher.config       # 默认配置文件
│   ├── network_switcher.init         # 初始化脚本
│   ├── network_switcher.sh           # 主程序脚本
│   └── usr/
│       └── lib/
│           └── lua/
│               └── luci/
│                   ├── controller/
│                   │   └── network_switcher.lua
│                   ├── model/
│                   │   └── cbi/
│                   │       └── network_switcher/
│                   │           └── network_switcher.lua
│                   └── view/
│                       └── network_switcher/
│                           ├── overview.htm
│                           └── log.htm
└── README.md
编译开发
设置 OpenWrt 开发环境

将项目放入 package 目录

使用 make menuconfig 选择包

编译：make package/network-switcher/compile V=s

许可证
本项目采用 GPL-2.0 许可证。详见 LICENSE 文件。

贡献
欢迎提交 Issue 和 Pull Request！

Fork 本项目

创建特性分支：git checkout -b feature/AmazingFeature

提交更改：git commit -m 'Add some AmazingFeature'

推送分支：git push origin feature/AmazingFeature

提交 Pull Request

支持
如果您遇到问题，可以通过以下方式获取帮助：

查看 Wiki 页面

提交 Issue

查看 讨论区

更新日志
v1.3.0 (2024-01-01)
✨ 新增定时任务功能

🎨 改进 Web 界面用户体验

🔧 优化锁机制，减少冲突

🐛 修复配置读取问题

📚 完善文档和错误处理

v1.2.0 (2023-12-01)
🚀 初始发布版本

🔄 基本故障切换功能

🌐 LuCI Web 界面

⚙️ 基础配置选项

