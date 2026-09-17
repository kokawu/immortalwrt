-- Pure validation: no network, filesystem writes or shell commands.
local M = {}
M.repository = 'kokawu/immortalwrt'
M.channel_url = 'https://github.com/' .. M.repository .. '/releases/download/online-latest/manifest.json'

local function need(ok, message)
    if not ok then error(message, 0) end
end
local function integer(n, lo, hi)
    return type(n) == 'number' and n == math.floor(n) and n >= lo and n <= hi
end
local function date_version(v)
    if type(v) ~= 'string' or #v >= 64 then return false end
    local y, m, d, seq = v:match('^(%d%d%d%d)%.(%d%d)%.(%d%d)%-(%d%d+)$')
    y, m, d, seq = tonumber(y), tonumber(m), tonumber(d), tonumber(seq)
    if not y or not m or m < 1 or m > 12 or not seq or seq < 1 then return false end
    local days = {31,28,31,30,31,30,31,31,30,31,30,31}
    if y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) then days[2] = 29 end
    return y >= 1 and d >= 1 and d <= days[m]
end
function M.tag(version)
    return date_version(version) and ('v' .. version) or version
end
function M.metadata(m)
    need(type(m) == 'table', '缺少固件版本信息')
    need(m.schema == 1 and m.repository == M.repository and m.channel == 'stable', '更新仓库或渠道不匹配')
    need(m.target == 'x86/64' and m.profile == 'generic' and m.filesystem == 'squashfs', '只支持 x86-64 generic squashfs')
    need(m.layout == 'x86-64-k128-r1024-v1', '固件分区规格不匹配，需要手动升级')
    need(type(m.version) == 'string' and #m.version < 64, '版本格式错误')
    local run, attempt = m.version:match('^online%-(%d+)%-(%d+)$')
    need(integer(m.build_id, 1, 8000000000000099), '构建序号错误')
    if run then
        need(integer(tonumber(attempt), 1, 99) and integer(tonumber(run), 1, 80000000000000), '版本格式错误')
        need(m.build_id == tonumber(run) * 100 + tonumber(attempt), '构建序号错误')
    else
        need(date_version(m.version), '版本格式错误')
    end
    need(type(m.commit) == 'string' and #m.commit == 40 and not m.commit:find('[^0-9a-f]'), '源码提交格式错误')
    return m
end
function M.select(current, manifest, boot, newer)
    M.metadata(current)
    M.metadata(manifest)
    need(boot == 'efi' or boot == 'bios', '未知启动方式')
    need(current.layout == manifest.layout, '分区规格变化，拒绝在线升级')
    if newer then need(manifest.build_id > current.build_id, '没有可升级的新版（不允许降级）') end
    need(type(manifest.images) == 'table' and #manifest.images >= 1 and #manifest.images <= 2, '镜像清单错误')
    local selected, seen = nil, {}
    for _, image in ipairs(manifest.images) do
        need(type(image) == 'table' and (image.boot == 'efi' or image.boot == 'bios'), '镜像启动方式错误')
        need(not seen[image.boot], '镜像清单包含重复启动方式')
        seen[image.boot] = true
        local suffix = image.boot == 'efi' and '%-efi' or ''
        need(type(image.name) == 'string' and #image.name < 200 and image.name:match('^[%w._%-]+%-x86%-64%-generic%-squashfs%-combined' .. suffix .. '%.img%.gz$'), '不支持的镜像文件名')
        need(integer(image.size, 1048576, 1073741824), '镜像大小超出安全范围')
        need(type(image.sha256) == 'string' and #image.sha256 == 64 and not image.sha256:find('[^0-9a-f]'), 'SHA256 格式错误')
        need(image.url == 'https://github.com/' .. M.repository .. '/releases/download/' .. M.tag(manifest.version) .. '/' .. image.name, '镜像下载地址不属于固定版本仓库')
        if image.boot == boot then selected = image end
    end
    need(selected ~= nil, '没有与当前启动方式匹配的镜像')
    return selected
end
function M.request(input)
    need(type(input) == 'table' and type(input.version) == 'string' and #input.version < 64 and (input.version:match('^online%-%d+%-%d+$') or date_version(input.version)), '必须指定刚检查到的版本')
    need(type(input.keep) == 'boolean', '必须明确选择是否保留配置')
    return input
end
return M
