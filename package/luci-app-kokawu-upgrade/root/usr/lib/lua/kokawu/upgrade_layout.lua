-- Strict read-only partition geometry parser, including GPT BIOS-boot entry 128.
-- UUIDs vary per build and intentionally are not part of the geometry.
local M = {}
local function need(ok, why) if not ok then error(why, 0) end end
local function le(s, offset, size)
    local n = 0
    for i = size - 1, 0, -1 do n = n * 256 + s:byte(offset + i + 1) end
    need(n <= 9007199254740991, 'Partition value exceeds exact integer range')
    return n
end
function M.parse(header, boot)
    need(type(header) == 'string' and #header == 32256, 'Incomplete disk header')
    need(header:sub(511, 512) == '\85\170', 'Invalid MBR signature')
    local gpt = header:sub(513, 520) == 'EFI PART'
    need((boot == 'efi' and gpt) or (boot == 'bios' and not gpt), 'Disk boot mode mismatch')
    local map, spans = {}, {}
    local function add(index, kind, start, size, flags)
        need(start > 0 and size > 0 and start + size <= 9007199254740991, 'Invalid partition extent')
        for _, span in ipairs(spans) do
            need(start + size <= span[1] or start >= span[2], 'Overlapping partitions')
        end
        spans[#spans + 1] = {start, start + size}
        map[#map + 1] = {index = index, kind = kind, start = start, size = size, flags = flags}
    end
    if gpt then
        need(le(header, 520, 4) == 65536 and le(header, 524, 4) == 92, 'Unsupported GPT header')
        need(le(header, 584, 8) == 2 and le(header, 592, 4) == 128 and le(header, 596, 4) == 128, 'Unsupported GPT table format')
        for index = 1, 128 do
            local offset = 1024 + (index - 1) * 128
            local kind = header:sub(offset + 1, offset + 16)
            if kind ~= string.rep('\0', 16) then
                local start, finish = le(header, offset + 32, 8), le(header, offset + 40, 8)
                need(start >= 34 and finish >= start, 'Invalid GPT extent')
                add(index, kind, start, finish - start + 1, header:sub(offset + 49, offset + 56))
            end
        end
    else
        for index = 1, 4 do
            local offset = 446 + (index - 1) * 16
            local kind = header:byte(offset + 5)
            if kind ~= 0 then
                need(kind ~= 5 and kind ~= 15 and kind ~= 133 and kind ~= 238, 'Extended/protective MBR not supported')
                add(index, kind, le(header, offset + 8, 4), le(header, offset + 12, 4), header:byte(offset + 1))
            end
        end
    end
    need(#map >= 2 and map[1].index == 1 and map[2].index == 2, 'Missing kernel/rootfs partitions')
    return map
end
function M.compare(disk, image, boot, partition_count)
    local a, b = M.parse(disk, boot), M.parse(image, boot)
    need(#a == #b and #a == partition_count, 'Partition count differs from image or kernel')
    for i, part in ipairs(a) do
        for key, value in pairs(part) do need(b[i][key] == value, 'Partition layout differs: ' .. i .. '/' .. key) end
    end
    return true
end
return M
