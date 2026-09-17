local json = require 'luci.jsonc'
local nixio = require 'nixio'
local fs = require 'nixio.fs'
local policy = require 'kokawu.upgrade_policy'
local M = {}
local work = '/tmp/kokawu-upgrade'
local lock = '/tmp/kokawu-upgrade.lock'
local helper = '/usr/libexec/kokawu-upgrade-layout'
local function need(ok, msg) if not ok then error(msg, 0) end end
local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function execute(cmd) return os.execute(cmd) == 0 end
local function capture(cmd)
    local f = io.popen(cmd, 'r')
    if not f then return '' end
    local s = f:read('*a') or ''
    f:close()
    return (s:gsub('%s+$', ''))
end
local function load(path)
    local stat = fs.stat(path)
    if not stat or stat.size > 131072 then return nil end
    local ok, value = pcall(json.parse, fs.readfile(path) or '')
    if ok then return value end
end
local function save(path, value)
    local temp = path .. '.' .. nixio.getpid()
    need(fs.writefile(temp, json.stringify(value)), '无法写入更新状态')
    need(os.rename(temp, path), '无法保存更新状态')
end
local function init()
    nixio.umask('077')
    fs.mkdir(work, '700')
    need(fs.stat(work, 'type') == 'dir' and not fs.readlink(work), '更新缓存目录异常')
    need(fs.chmod(work, '700'), '无法设置更新缓存目录权限')
end
local function current()
    -- Never use a preserved /etc copy: squashfs /rom is the running image.
    return policy.metadata(load('/rom/etc/kokawu-release.json'))
end
local function hardware()
    need(capture('uname -m') == 'x86_64', '只支持 x86-64 设备')
    local mounts = fs.readfile('/proc/mounts') or ''
    need(mounts:find(' /rom squashfs ', 1, true), '不是受支持的 squashfs 启动方式')
    local overlay = mounts:match('([^%s]+) /overlay ')
    need(overlay and overlay:match('^/dev/loop%d+$'), '不支持外置 extroot 或未初始化的持久化分区')
    need(not (fs.readfile('/proc/cmdline') or ''):find('root=/dev/ram', 1, true), '不支持临时内存系统')
    return fs.stat('/sys/firmware/efi') and 'efi' or 'bios'
end
local function state(stage, message, extra)
    local s = load(work .. '/status.json') or {}
    s.state, s.message = stage, message
    if extra then for k, v in pairs(extra) do s[k] = v end end
    save(work .. '/status.json', s)
end
local function unlock()
    fs.unlink(lock .. '/pid')
    fs.rmdir(lock)
end
local function locked()
    local stat = fs.stat(lock)
    if not stat then return false end
    need(stat.type == 'dir' and not fs.readlink(lock), '更新锁目录异常')
    local pid = tonumber(fs.readfile(lock .. '/pid') or '')
    if pid and pid > 1 and (nixio.kill(pid, 0) or nixio.kill(-pid, 0)) then return true end
    -- Grace period covers mkdir -> fork -> child PID publication.
    if os.time() - stat.mtime < 10 then return true end
    unlock()
    state('error', '上次更新任务中断；请重新检查版本', {available = false})
    fs.unlink(work .. '/firmware.img.gz')
    return false
end
local function acquire()
    locked()
    need(fs.mkdir(lock, '700'), '已有更新任务正在运行，请勿重复操作')
    need(fs.writefile(lock .. '/pid', tostring(nixio.getpid())), '无法创建任务锁')
end
local function download(url, path, size, seconds)
    fs.unlink(path)
    local command = 'curl -q --fail --silent --show-error --location --proto =https --proto-redir =https' ..
        ' --connect-timeout 15 --max-time ' .. seconds .. ' --speed-limit 1024 --speed-time 60' ..
        ' --retry 2 --retry-max-time ' .. seconds .. ' --max-filesize ' .. size ..
        ' --output ' .. quote(path) .. ' ' .. quote(url) .. ' 2>' .. quote(work .. '/download.log')
    need(execute(command), '下载失败：请检查 GitHub 连接、设备时间和可用空间（未刷机）')
    local stat = fs.stat(path)
    need(stat and stat.size > 0 and stat.size <= size, '下载文件大小异常')
end
local function fetch()
    local c, boot = current(), hardware()
    download(policy.channel_url, work .. '/manifest.download', 131072, 120)
    local manifest = load(work .. '/manifest.download')
    policy.select(c, manifest, boot, false)
    save(work .. '/manifest.json', manifest)
    return c, manifest, boot
end
local function check_worker()
    local c, manifest = fetch()
    local available = manifest.build_id > c.build_id
    state('idle', available and '发现新版，可备份配置后点击升级' or '当前没有更新版本',
        {latest = manifest, available = available, checked_at = os.time()})
end
local function space(size)
    local kb = tonumber(capture("df -Pk /tmp | awk 'END {print $4}'"))
    local mem = tonumber((fs.readfile('/proc/meminfo') or ''):match('MemAvailable:%s+(%d+)'))
    local required = math.ceil(size / 1024) + 65536
    need(kb and mem and kb > required and mem > required, '临时空间或可用内存不足：需要镜像大小加 64 MiB 余量')
end
local function verify_image(image)
    local path = work .. '/firmware.img.gz'
    local stat = fs.stat(path)
    need(stat and stat.size == image.size, '镜像大小不符，已停止升级')
    local digest = capture('sha256sum ' .. quote(path)):match('^(%x+)')
    need(digest == image.sha256, 'SHA256 校验失败，已停止升级')
    -- OpenWrt appends fwtool metadata after the gzip stream; gzip -t may
    -- reject that valid trailer. Verify the complete asset's SHA256 instead.
    -- sysupgrade -T alone permits partition layout changes on x86.
    need(execute(helper .. ' >' .. quote(work .. '/layout.log') .. ' 2>&1'), '实际磁盘与镜像分区布局不一致或无法识别；请手动升级')
    need(execute('/sbin/sysupgrade -T ' .. quote(path) .. ' >' .. quote(work .. '/validation.log') .. ' 2>&1'), '系统固件兼容性检查失败，未刷机')
end
local function upgrade_worker(input)
    -- Re-fetch under the same task lock. A channel change needs a new user confirmation.
    local c, manifest, boot = fetch()
    need(input.version == manifest.version, '新版清单已变化，请重新检查并确认升级')
    local image = policy.select(c, manifest, boot, true)
    state('downloading', '正在下载匹配当前启动方式的固件，请勿断电', {latest = manifest, available = false})
    local path = work .. '/firmware.img.gz'
    fs.unlink(path)
    space(image.size)
    download(image.url, path, image.size, 1800)
    state('verifying', '正在校验镜像、分区布局与系统兼容性')
    verify_image(image)
    -- Keep the image private and task lock held all the way into sysupgrade.
    state('upgrading', '校验通过，正在升级并重启；请勿断电')
    nixio.nanosleep(3)
    local option = input.keep and '' or '-n '
    local ok = execute('/sbin/sysupgrade ' .. option .. quote(path) .. ' >' .. quote(work .. '/upgrade.log') .. ' 2>&1')
    need(ok, 'sysupgrade 执行失败，请查看 /tmp/kokawu-upgrade/upgrade.log')
    -- Successful sysupgrade normally kills this worker. If it returns, keep lock
    -- during reboot rather than permit another upgrade request.
    nixio.nanosleep(120)
    error('升级命令已返回，但设备尚未重启；请检查系统日志', 0)
end
function M.status()
    init()
    local busy = locked()
    local s = load(work .. '/status.json') or {state = 'idle', message = '尚未检查新版', available = false}
    local ok, c = pcall(current)
    s.current = ok and c or nil
    if not ok then s.available, s.message = false, tostring(c) end
    local supported, boot = pcall(hardware)
    s.boot = supported and boot or nil
    if not supported then s.available, s.message = false, tostring(boot) end
    if busy and s.state == 'idle' then s.state = 'checking' end
    return s
end
function M.start(action, input)
    init()
    need(action == 'check' or action == 'upgrade', '未知操作')
    local c, boot = current(), hardware()
    if action == 'upgrade' then
        policy.request(input)
        local cached = load(work .. '/manifest.json')
        policy.select(c, cached, boot, true)
        need(input.version == cached.version, '版本已过期，请重新检查并确认')
    end
    acquire()
    local ok, err = pcall(function()
        state('checking', action == 'check' and '正在检查新版' or '正在复核已确认版本', {available = false})
        local pid = nixio.fork()
        need(pid ~= nil, '无法启动后台更新任务')
        if pid == 0 then
            nixio.setsid()
            local null = nixio.open('/dev/null', 'r+')
            if not null then unlock(); os.exit(1) end
            nixio.dup(null, nixio.stdin)
            nixio.dup(null, nixio.stdout)
            nixio.dup(null, nixio.stderr)
            null:close()
            fs.writefile(lock .. '/pid', tostring(nixio.getpid()))
            local success, message = pcall(function()
                if action == 'check' then check_worker() else upgrade_worker(input) end
            end)
            if not success then
                pcall(state, 'error', tostring(message), {available = false})
                fs.unlink(work .. '/firmware.img.gz')
            end
            unlock()
            os.exit(success and 0 or 1)
        end
    end)
    if not ok then unlock(); error(err, 0) end
    return {accepted = true, message = '任务已启动'}
end
return M
