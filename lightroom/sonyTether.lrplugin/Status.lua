local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'
local Common = require 'Common'

local prefs = LrPrefs.prefsForPlugin()
local folder = prefs.lastFolder or ''
local entries = folder ~= '' and Common.readManifest(folder) or {}
LrDialogs.message('sonyTether',
    string.format('Session folder: %s\nCaptures in manifest: %d',
        folder ~= '' and folder or '(not set)', #entries), 'info')
