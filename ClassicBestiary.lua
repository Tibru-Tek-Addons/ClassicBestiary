local addonName, CB = ...
local L = CB.L

local manifest = CB.db.m

-- Data queries are usable as soon as the ordered addon files finish loading.
ClassicBestiary = CB.API

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, _, loadedAddon)
    if loadedAddon ~= addonName then return end
    self:UnregisterEvent("ADDON_LOADED")
    CB.InitializeConfig()
    CB.RegisterSettings()
    CB.InitializeTooltip()
    SLASH_CLASSICBESTIARY1 = "/bestiary"
    SlashCmdList.CLASSICBESTIARY = function(message)
        if message:match("^%s*reset%s*$") then
            CB.ResetConfig()
            print(L.SETTINGS_RESET)
        elseif message:match("^%s*status%s*$") then
            local version, build, _, interface = GetBuildInfo()
            print(string.format(L.STATUS, version, build, tostring(interface), manifest.db2.build))
        else
            CB.OpenSettings()
        end
    end
end)
