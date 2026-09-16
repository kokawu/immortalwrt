package.path = 'package/luci-app-kokawu-upgrade/root/usr/lib/lua/?.lua;' .. package.path
local policy = require 'kokawu.upgrade_policy'
local layout = require 'kokawu.upgrade_layout'
local count = 0
local function copy(t)
    if type(t) ~= 'table' then return t end
    local r = {}; for k, v in pairs(t) do r[k] = copy(v) end; return r
end
local current = {schema=1, repository='kokawu/immortalwrt', channel='stable', version='online-10-1', build_id=1001,
    target='x86/64', profile='generic', filesystem='squashfs', layout='x86-64-k128-r1024-v1', commit=string.rep('a', 40)}
local newer = copy(current)
newer.version, newer.build_id = 'online-11-1', 1101
newer.images = {}
for _, boot in ipairs({'bios', 'efi'}) do
    local name = 'immortalwrt-x86-64-generic-squashfs-combined' .. (boot == 'efi' and '-efi' or '') .. '.img.gz'
    newer.images[#newer.images+1] = {boot=boot, name=name, size=2097152, sha256=string.rep('b',64),
        url='https://github.com/kokawu/immortalwrt/releases/download/' .. newer.version .. '/' .. name}
end
local function test(name, fn, success)
    local ok, err = pcall(fn)
    assert(ok == success, name .. ': ' .. tostring(err))
    count = count + 1
end
test('BIOS selection', function() assert(policy.select(current,newer,'bios',true).boot=='bios') end, true)
test('EFI selection', function() assert(policy.select(current,newer,'efi',true).boot=='efi') end, true)
for key, value in pairs({schema=2, repository='other/repo', channel='beta', target='aarch64', profile='other', filesystem='ext4',
    layout='changed', version='../../bad', build_id=123, commit='not-a-sha'}) do
    test('reject metadata ' .. key, function() local n=copy(newer); n[key]=value; policy.select(current,n,'efi',true) end, false)
end
for key, value in pairs({boot='other', name='image.qcow2', size='2097152', sha256=string.rep('z',64), url='https://evil.example/image.gz'}) do
    test('reject image ' .. key, function() local n=copy(newer); n.images[2][key]=value; policy.select(current,n,'efi',true) end, false)
end
test('reject duplicate boot', function() local n=copy(newer); n.images[1]=copy(n.images[2]); policy.select(current,n,'efi',true) end,false)
test('reject missing matching image', function() local n=copy(newer); n.images[2]=nil; policy.select(current,n,'efi',true) end,false)
test('reject downgrade', function() policy.select(newer,newer,'efi',true) end,false)
test('same version check allowed', function() policy.select(newer,newer,'efi',false) end,true)
test('reject missing keep', function() policy.request({version=newer.version}) end,false)
test('reject shell injection', function() policy.request({version="x';reboot",keep=true}) end,false)
test('explicit keep false allowed', function() policy.request({version=newer.version,keep=false}) end,true)

local function header(boot, altered)
    local bytes = {}; for i=1,32256 do bytes[i]=0 end
    local function text(offset, s) for i=1,#s do bytes[offset+i]=s:byte(i) end end
    local function le(offset,n,size) for i=1,size do bytes[offset+i]=n%256; n=math.floor(n/256) end end
    text(510,'\85\170')
    if boot=='efi' then
        text(512,'EFI PART'); le(520,65536,4); le(524,92,4); le(584,2,8); le(592,128,4); le(596,128,4)
        for _, p in ipairs({{1,512,262144},{2,262656,2097152},{128,34,478}}) do
            local offset=1024+(p[1]-1)*128
            text(offset,string.rep(string.char(p[1]),16)); le(offset+32,p[2],8); le(offset+40,p[2]+p[3]-1,8)
        end
        if altered then altered(text,le) end
    else
        for _,p in ipairs({{1,512,262144},{2,262656,2097152}}) do
            local offset=446+(p[1]-1)*16
            le(offset+4,131,1); le(offset+8,p[2],4); le(offset+12,p[3],4)
        end
        if altered then altered(text,le) end
    end
    local out={}; for i=1,#bytes do out[i]=string.char(bytes[i]) end
    return table.concat(out)
end
local bios,efi=header('bios'),header('efi')
test('BIOS layout', function() layout.compare(bios,bios,'bios',2) end,true)
test('EFI layout includes partition 128', function() layout.compare(efi,efi,'efi',3) end,true)
test('reject firmware boot mismatch', function() layout.compare(bios,efi,'bios',2) end,false)
test('reject actual boot mismatch', function() layout.compare(efi,efi,'bios',3) end,false)
test('reject expanded rootfs', function() local b=header('bios',function(_,le) le(474,2097153,4) end); layout.compare(b,bios,'bios',2) end,false)
test('reject changed GPT stub', function() local b=header('efi',function(_,le) le(1024+127*128+40,510,8) end); layout.compare(b,efi,'efi',3) end,false)
test('reject hidden extra kernel partition', function() layout.compare(efi,efi,'efi',4) end,false)
test('reject truncated header', function() layout.parse(efi:sub(1,100),'efi') end,false)
test('reject unsupported GPT entry size', function() layout.parse(header('efi',function(_,le) le(596,256,4) end),'efi') end,false)
test('ignore changing per-build partition GUIDs', function() local b=header('efi',function(text) text(1024+16,string.rep('x',16)) end); layout.compare(b,efi,'efi',3) end,true)
print('Policy/layout tests passed: '..count)
