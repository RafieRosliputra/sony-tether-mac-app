local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'
local Common = require 'Common'

local folder = Common.askFolder()
if folder == nil then return 'cancelled' end
LrPrefs.prefsForPlugin().lastFolder = folder
LrDialogs.message('sonyTether', 'Session folder set to\n' .. folder, 'info')
