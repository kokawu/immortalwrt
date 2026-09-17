# 定制固件在线升级

## 使用方式

首次需要手动安装带 `luci-app-kokawu-upgrade` 的新固件。之后打开 **系统 → 在线升级**：

1. 查看当前版本，点击“检查新版”。设备每天当地时间 09:23 也会检查一次。
2. 新版提示显示在此页面，不是全站弹窗；定时任务只下载小型版本清单，不下载镜像、不刷机。
3. 通过页面链接前往“备份／升级”下载配置备份。
4. 点击“下载并升级”，选择是否保留配置，再次确认后才执行。
5. 等待下载、校验、升级及重启，期间不要断电。清除配置后应按新固件默认地址重新登录。

保留配置不等于保留后装的软件。没有无人值守刷机入口；命令行工具只提供 `check` 和 `status`。

## 第一版支持范围

- 固定仓库 `kokawu/immortalwrt`、`stable` 渠道，APK-only。
- x86/64 generic、squashfs，BIOS 对应 MBR，EFI 对应 GPT。
- 内核分区 128 MiB、rootfs 分区 1024 MiB；**实际分区表也必须与新镜像一致**。
- QCOW2 仍可用于初次部署虚拟机；虚拟机内更新下载匹配的 `combined[-efi].img.gz`，绝不把 QCOW2 传给 sysupgrade。
- 不支持 ext4、EROFS、ONIE、外置 extroot、非 512 字节逻辑扇区、自定义/扩容分区、跨类型切换或降级。无法可靠识别就停止并要求手动处理。
- 当前版本来自只读 `/rom/etc/kokawu-release.json`，不会使用保留配置中的旧 `/etc` 副本。

需要镜像压缩大小加 64 MiB 的可用内存及 `/tmp` 空间。GitHub 无法连接、时钟错误或证书验证失败时，不会绕过 HTTPS 验证。

## 编译与发布

`Build firmware` 工作流新增 `publish_updates` 开关：

- `true`：完整构建成功后发布独立版本 `vYYYY.MM.DD-NN`，再更新 `online-latest` Release 的 `manifest.json`。
- `false`：只上传 Actions 构建产物，适合第一轮验证，不会改变在线渠道。Tag push 构建仍发布；**测试请在 master 上手动运行并取消开关，不要推送 build-* / kokawu-* 标签**。
- 现有每日同步工作流仍保留原有逻辑：上游有新提交时触发构建。没有上游变更，不会仅为了版本号每天重编译。
- 两种原始升级镜像必须都存在并通过格式检查，否则不能发布在线更新清单。
- 镜像 URL 指向独立版本，不指向可变的 `latest/download`；先完成全部附件上传并公开版本，最后才更新渠道清单。
- 发布阶段串行，并比较构建序号，较旧且耗时更长的构建不能覆盖较新渠道。
- 新版本标识在编译前生成。不能只从旧固件中安装本插件来绕过首次刷入与版本标识要求。

配置明确使用 `CONFIG_GRUB_IMAGES`、`CONFIG_GRUB_EFI_IMAGES`、`CONFIG_TARGET_IMAGES_GZIP`；当前源码没有 `CONFIG_EFI_IMAGES` 符号。

## 安全边界

后端固定仓库、渠道和 URL，验证 JSON 字段类型、版本递增、镜像名、启动方式、大小和 SHA256。下载使用系统 CA 验证并限制协议、时间、体积。下载成功后：

1. 检查完整资产 SHA256 和字节数（包含 OpenWrt fwtool 元数据尾部）。
2. 只读解析实际启动盘与镜像的 MBR/GPT 分区表，比较全部分区的类型、起点、大小及标志；包含 GPT 第 128 项 BIOS-boot 分区，忽略每次构建会变化的 UUID。
3. 运行 `sysupgrade -T`；不使用 `-F` 或跳过兼容性检查。
4. 保持独占任务锁，再执行 sysupgrade。只有显式 RPC `upgrade` 可进入这一步。

所有 RPC 方法有独立 ACL；不给任意命令执行或任意 URL 下载权限。确认后会重新检查清单；渠道已变化则要求重新确认，不会悄悄换成另一个版本。

信任边界是 GitHub 仓库/Actions 权限和 HTTPS CA，SHA256 用于完整性检查，**不是独立的固件签名**。有仓库发布权限的人能发布新版；不得把这套机制描述为对仓库失陷的防护。

## 验证与排错

本地/CI 检查：

```sh
python3 -m unittest discover -s tests/online-upgrade -p 'test_*.py' -v
lua5.1 tests/online-upgrade/policy.lua
lua5.1 tests/online-upgrade/backend.lua
node --check package/luci-app-kokawu-upgrade/htdocs/luci-static/resources/view/system/kokawu-upgrade.js
```

测试使用合成镜像头及内存模拟，不能替代设备测试。正式使用前应在可恢复的虚拟机中测试两次构建之间的升级：BIOS/EFI 各一次，保留配置/清空配置、网络断开、下载失败、SHA 不符、分区变化均需覆盖；确认 LuCI、联网和常用插件正常。不要为了测试在生产路由器上直接刷机。

路由器只读排错：

```sh
kokawu-upgrade status
ubus call kokawu.upgrade status
cat /tmp/kokawu-upgrade/download.log
cat /tmp/kokawu-upgrade/layout.log
cat /tmp/kokawu-upgrade/validation.log
cat /tmp/kokawu-upgrade/upgrade.log
```

这些是临时状态/日志，重启会清空。任务中断后进程已退出的旧锁会在下次访问时清理；正在运行的升级不能通过删除锁来并行启动第二个任务。网络问题修复后重新“检查新版”即可重试。

## 日期版本号与旧版迁移

按北京时间的构建日期分配 2026.09.17-01 这样的版本，同日依次递增。
编译前原子预留 v2026.09.17-01 标签，避免并行构建撞号；失败、测试构建及重跑可能留下跳号，这是正常现象。
是否有新版仍由内部 Actions 构建序号判断，不依赖日期字符串排序。
旧 online-* Release 及下载地址保留，不改写已刷入的只读版本标识。
首版插件仅接受旧格式；升级到日期版前，需要更新兼容新旧格式的 upgrade_policy.lua 及页面文件，否则会安全拒绝新版清单。

CI 在编译后启动临时 BIOS 和 EFI 虚拟机，检查真实 LuCI HTTP 页面、ucode math 模块、在线升级 RPC、固件标识、启动类型及 nixio 目录权限，同时检查镜像 SHA256、分区匹配及 sysupgrade -T。
测试失败会阻止发布和渠道更新；日志上传到 runtime-smoke 构建附件。
这些是新镜像启动冒烟检查，并不等于旧版到新版的完整 sysupgrade 回归测试，也不会刷写实际路由器。
