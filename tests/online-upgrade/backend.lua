-- All filesystem, network, fork and sysupgrade operations are mocked in memory.
-- This file cannot access a router or execute a real upgrade.
package.path = 'package/luci-app-kokawu-upgrade/root/usr/lib/lua/?.lua;' .. package.path
local function copy(t)
    if type(t)~='table' then return t end
    local r={}; for k,v in pairs(t) do r[k]=copy(v) end; return r
end
local objects, files, dirs, commands, options, serial
local work='/tmp/kokawu-upgrade'
local lock='/tmp/kokawu-upgrade.lock'
local function encode(t) serial=serial+1; local key='JSON:'..serial; objects[key]=copy(t); return key end
local json={stringify=function(t) return encode(t) end,parse=function(s) return copy(objects[s]) end}
local fs={}
function fs.mkdir(path) if dirs[path] then return nil end; dirs[path]={mtime=100}; return true end
function fs.stat(path,key)
    local v
    if dirs[path] then v={type='dir',mtime=dirs[path].mtime,size=0}
    elseif files[path] then v={type='reg',size=(path==work..'/firmware.img.gz' and (options.bad_size and 1 or 2097152) or #files[path])} end
    return key and v and v[key] or v
end
function fs.readfile(path) return files[path] end
function fs.writefile(path,s) files[path]=s; return #s end
function fs.unlink(path) files[path]=nil; return true end
function fs.rmdir(path) dirs[path]=nil; return true end
function fs.chmod() return true end
function fs.readlink() return nil end
local nixio={stdin=0,stdout=1,stderr=2}
function nixio.umask() return 0 end
function nixio.getpid() return 20 end
function nixio.kill() return options.locked or false end
function nixio.fork() if options.fork_fail then return nil end; return 0 end
function nixio.setsid() return true end
function nixio.open() return {close=function() end} end
function nixio.dup() return true end
function nixio.nanosleep() end
package.preload['luci.jsonc']=function() return json end
package.preload['nixio.fs']=function() return fs end
package.preload['nixio']=function() return nixio end
os.time=function() return 200 end
os.rename=function(a,b) files[b]=files[a]; files[a]=nil; return true end
os.exit=function(code) error({simulated_exit=code},0) end
local current={schema=1,repository='kokawu/immortalwrt',channel='stable',version='online-10-1',build_id=1001,
    target='x86/64',profile='generic',filesystem='squashfs',layout='x86-64-k128-r1024-v1',commit=string.rep('a',40)}
local latest=copy(current)
latest.version,latest.build_id='online-11-1',1101
local name='immortalwrt-x86-64-generic-squashfs-combined-efi.img.gz'
latest.images={{boot='efi',name=name,size=2097152,sha256=string.rep('b',64),
    url='https://github.com/kokawu/immortalwrt/releases/download/online-11-1/'..name}}
local remote
os.execute=function(cmd)
    commands[#commands+1]=cmd
    if cmd:find('curl -q',1,true) then
        if options.network_fail then return 1 end
        if cmd:find('/online-latest/manifest.json',1,true) then files[work..'/manifest.download']=encode(remote)
        elseif options.image_fail then return 1
        else files[work..'/firmware.img.gz']='image' end
    elseif cmd:find('/usr/libexec/kokawu-upgrade-layout',1,true) and options.layout_fail then return 1
    elseif cmd:find('/sbin/sysupgrade -T',1,true) and options.validation_fail then return 1
    end
    return 0
end
io.popen=function(cmd)
    local s=''
    if cmd=='uname -m' then s=options.wrong_arch and 'aarch64' or 'x86_64'
    elseif cmd:find('df -Pk',1,true) then s=options.disk_full and '5' or '9000000'
    elseif cmd:find('sha256sum',1,true) then s=string.rep(options.bad_hash and 'c' or 'b',64)..' image' end
    return {read=function() return s end,close=function() end}
end
local count=0
local function run(label,opts,action,request,expect_flash,expect_image)
    objects,files,dirs,commands,options,serial={},{},{},{},opts,0
    dirs[work]={mtime=100}; dirs['/sys/firmware/efi']={mtime=100}
    files['/rom/etc/kokawu-release.json']=encode(current)
    files[work..'/manifest.json']=encode(latest)
    files['/proc/mounts']=opts.wrong_fs and 'root / ext4 rw' or '/dev/root /rom squashfs ro\n/dev/loop0 /overlay f2fs rw'
    files['/proc/meminfo']='MemAvailable: '..(opts.low_memory and '10' or '9000000')..' kB'
    files['/proc/cmdline']='root=PARTUUID=test'
    if opts.missing_identity then files['/rom/etc/kokawu-release.json']=nil end
    if opts.locked then dirs[lock]={mtime=100}; files[lock..'/pid']='123' end
    remote=copy(latest)
    if opts.channel_changed then remote.version='online-12-1'; remote.build_id=1201; remote.images[1].url=remote.images[1].url:gsub('online%-11%-1','online-12-1') end
    package.loaded['kokawu.upgrade']=nil
    local service=require 'kokawu.upgrade'
    pcall(service.start,action,request)
    local flash,image=0,0
    for _,cmd in ipairs(commands) do
        if cmd:match('^/sbin/sysupgrade ') and not cmd:match('^/sbin/sysupgrade %-T ') then
            flash=flash+1
            assert(not cmd:find('-F',1,true),label..': force must never be used')
            assert((cmd:find('sysupgrade -n ',1,true)~=nil)==(request.keep==false),label..': keep mismatch')
        end
        if cmd:find('curl -q',1,true) and cmd:find('/online-11-1/',1,true) then image=image+1 end
    end
    local final=json.parse(files[work..'/status.json'] or '') or {}
    assert(flash==expect_flash,label..': unexpected flash count '..flash..'; '..tostring(final.message))
    if expect_image~=nil then assert(image==expect_image,label..': unexpected image download') end
    if not opts.locked then assert(not dirs[lock],label..': leaked lock after worker exit') end
    count=count+1
end
local request={version=latest.version,keep=true}
run('check only never downloads firmware',{},'check',nil,0,0)
run('happy path preserves config',{},'upgrade',request,1,1)
run('explicit reset uses -n',{},'upgrade',{version=latest.version,keep=false},1,1)
for _,fault in ipairs({'network_fail','image_fail','bad_hash','bad_size','layout_fail','validation_fail','disk_full','low_memory',
    'fork_fail','wrong_arch','wrong_fs','missing_identity','locked','channel_changed'}) do
    run('reject '..fault,{[fault]=true},'upgrade',request,0)
end
run('stale confirmation',{},'upgrade',{version='online-9-1',keep=true},0,0)
run('bad keep type',{},'upgrade',{version=latest.version,keep='false'},0,0)
run('injection request',{},'upgrade',{version="x; reboot",keep=true},0,0)
run('unknown method',{},'flash',request,0,0)
print('Mock backend tests passed: '..count)
