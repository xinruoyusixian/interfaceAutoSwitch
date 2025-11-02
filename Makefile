include $(TOPDIR)/rules.mk

PKG_NAME:=network-switcher
PKG_VERSION:=1.2.6
PKG_RELEASE:=1

PKG_MAINTAINER:=Your Name <your@email.com>
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/network-switcher
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Routing and Redirection
  TITLE:=智能网络接口切换器
  DEPENDS:=+lua +luci-lib-json +luci-lib-nixio
  PKGARCH:=all
endef

define Package/network-switcher/description
  一个智能的网络接口切换器，支持LuCI网页界面。
  提供WAN和WWAN接口之间的自动故障切换功能。
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/network-switcher/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/network_switcher
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/network_switcher
	
	$(INSTALL_BIN) ./files/network_switcher.init $(1)/etc/init.d/network_switcher
	$(INSTALL_BIN) ./files/network_switcher.sh $(1)/usr/bin/network_switcher
	$(INSTALL_CONF) ./files/network_switcher.config $(1)/etc/config/network_switcher
	
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/network_switcher.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/model/cbi/network_switcher/network_switcher.lua $(1)/usr/lib/lua/luci/model/cbi/network_switcher/
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/model/cbi/network_switcher/routing.lua $(1)/usr/lib/lua/luci/model/cbi/network_switcher/
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/view/network_switcher/overview.htm $(1)/usr/lib/lua/luci/view/network_switcher/
endef

define Package/network-switcher/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
    echo "启用network_switcher服务..."
    /etc/init.d/network_switcher enable
    echo "你可以在LuCI中配置网络切换器: 服务 -> 网络切换器"
fi
exit 0
endef

$(eval $(call BuildPackage,network-switcher))
