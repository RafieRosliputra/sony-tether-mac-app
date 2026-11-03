local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local Common = {}

function Common.manifestPath(folder)
    return LrPathUtils.child(folder, 'sonyTether-captures.jsonl')
end

-- The app writes one flat JSON object per line. Parsing it with patterns keeps
-- this plug-in free of any bundled JSON library.
function Common.readManifest(folder)
    local entries = {}
    if folder == nil then return entries end
    local path = Common.manifestPath(folder)
    if not LrFileUtils.exists(path) then return entries end
    local file = io.open(path, 'r')
    if not file then return entries end
    for line in file:lines() do
        local entry = {}
        for key, value in line:gmatch('"([%w_]+)"%s*:%s*"([^"]*)"') do
            entry[key] = value
        end
        for key, value in line:gmatch('"([%w_]+)"%s*:%s*(-?%d+%.?%d*)') do
            entry[key] = tonumber(value)
        end
        if entry.path then entries[#entries + 1] = entry end
    end
    file:close()
    return entries
end

function Common.askFolder()
    local LrDialogs = import 'LrDialogs'
    local result = LrDialogs.runOpenPanel({
        title = 'Choose the sonyTether download folder',
        canChooseDirectories = true,
        canChooseFiles = false,
        allowsMultipleSelection = false,
    })
    if result == nil then return nil end
    return type(result) == 'table' and result[1] or result
end

return Common
