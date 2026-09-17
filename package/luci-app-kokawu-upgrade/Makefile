include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-kokawu-upgrade
PKG_VERSION:=1.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-kokawu-upgrade
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Kokawu firmware online upgrade
  DEPENDS:=@TARGET_x86_64 +luci-base +lua +luci-lib-jsonc +luci-lib-nixio +rpcd +curl +ca-bundle
endef

define Build/Compile
endef

define Package/luci-app-kokawu-upgrade/install
	$(CP) ./root/* $(1)/
	$(INSTALL_DIR) $(1)/www
	$(CP) ./htdocs/* $(1)/www/
	chmod 0755 $(1)/usr/sbin/kokawu-upgrade $(1)/usr/libexec/rpcd/kokawu.upgrade $(1)/usr/libexec/kokawu-upgrade-layout $(1)/etc/uci-defaults/95-kokawu-upgrade
endef

$(eval $(call BuildPackage,luci-app-kokawu-upgrade))
