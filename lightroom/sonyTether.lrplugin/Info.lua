--[[ sonyTether Lightroom Classic plug-in.

     Install: File → Plug-in Manager → Add → pick this .lrplugin folder.
     Use:     Library → Plug-in Extras → sonyTether → …
]]

return {
    LrSdkVersion = 10.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = 'com.johorstudio.sonytether',
    LrPluginName = 'sonyTether',
    LrPluginInfoUrl = 'https://github.com/RafieRosliputra/sony-tether-mac-app',
    LrLibraryMenuItems = {
        { title = 'Import session photos', file = 'Import.lua' },
        { title = 'Choose session folder…', file = 'ChooseFolder.lua' },
        { title = 'Session status', file = 'Status.lua' },
    },
}
