local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrPrefs = import 'LrPrefs'

local Common = require 'Common'
local prefs = LrPrefs.prefsForPlugin()

local folder = prefs.lastFolder
if folder == nil or folder == '' then
    folder = Common.askFolder()
    if folder == nil then return 'cancelled' end
    prefs.lastFolder = folder
end

local entries = Common.readManifest(folder)
if #entries == 0 then
    LrDialogs.message('sonyTether', 'No captures found in\n' .. folder
        .. '\n\nUse "Choose session folder…" if this is the wrong folder.', 'info')
    return 'empty'
end

local catalog = LrApplication.activeCatalog()
local added, skipped = 0, 0

catalog:withWriteAccessDo('sonyTether import', function()
    for _, entry in ipairs(entries) do
        local path = entry.path
        if LrFileUtils.exists(path) then
            if catalog:findPhotoByPath(path) then
                skipped = skipped + 1
            else
                local ok = pcall(function() catalog:addPhoto(path) end)
                if ok then added = added + 1 else skipped = skipped + 1 end
            end
        else
            skipped = skipped + 1
        end
    end
end)

LrDialogs.message('sonyTether',
    string.format('Imported %d photo(s).\nSkipped %d (already in catalog or file missing).\n\n%s',
        added, skipped, folder), 'info')
