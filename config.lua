local addonName, CB = ...
local L = CB.L

local defaults = {
    mode = "spells",
    expansion = "ctrl",
    reminder = true,
    ignoreFriendly = false,
    enabled = true,
    debugIDs = false,
    debugDetails = false,
}
local modes = { spells = true, spells_compact = true, effects = true, effects_compact = true }
local expansions = { ctrl = true, shift = true, alt = true, never = true, always = true }
local category
local settings = {}
local panel
local samples
local selectedSample = 1

local function RefreshTooltip()
    if CB.RefreshTooltip then
        CB.RefreshTooltip()
    end
end

local function BooleanValue(value, default)
    if type(value) == "boolean" then
        return value
    end
    return default
end

function CB.InitializeConfig()
    local saved = ClassicBestiaryCfg
    if type(saved) ~= "table" then
        saved = {}
    end

    local mode = saved.mode
    local expansion = saved.expansion
    local reminder = saved.reminder
    local ignoreFriendly = saved.ignoreFriendly
    local enabled = saved.enabled
    local debugIDs = saved.debugIDs
    local debugDetails = saved.debugDetails

    -- Retain table identity: registered Settings controls hold this table directly.
    for key in pairs(saved) do
        saved[key] = nil
    end
    saved.mode = type(mode) == "string" and modes[mode] and mode or defaults.mode
    saved.expansion = type(expansion) == "string" and expansions[expansion] and expansion or defaults.expansion
    saved.reminder = BooleanValue(reminder, defaults.reminder)
    saved.ignoreFriendly = BooleanValue(ignoreFriendly, defaults.ignoreFriendly)
    saved.enabled = BooleanValue(enabled, defaults.enabled)
    saved.debugIDs = BooleanValue(debugIDs, defaults.debugIDs)
    saved.debugDetails = BooleanValue(debugDetails, defaults.debugDetails)
    ClassicBestiaryCfg = saved
    CB.config = saved
    return saved
end

local function ModeOptions()
    local options = Settings.CreateControlTextContainer()
    options:Add("spells", L.MODE_SPELLS)
    options:Add("spells_compact", L.MODE_SPELLS_COMPACT)
    options:Add("effects", L.MODE_EFFECTS)
    options:Add("effects_compact", L.MODE_EFFECTS_COMPACT)
    return options:GetData()
end

local function ExpansionOptions()
    local options = Settings.CreateControlTextContainer()
    options:Add("ctrl", L.MODIFIER_CTRL)
    options:Add("shift", L.MODIFIER_SHIFT)
    options:Add("alt", L.MODIFIER_ALT)
    options:Add("never", L.EXPANSION_NEVER)
    options:Add("always", L.EXPANSION_ALWAYS)
    return options:GetData()
end

local function RegisterSetting(parent, key, label, tooltip, options)
    local setting = Settings.RegisterAddOnSetting(
        category, addonName .. "_" .. key, key, CB.config,
        type(defaults[key]), label, defaults[key]
    )
    setting:SetValueChangedCallback(RefreshTooltip)
    settings[key] = setting
    local initializer
    if options then
        initializer = Settings.CreateDropdownInitializer(setting, options, tooltip)
    else
        initializer = Settings.CreateCheckboxInitializer(setting, nil, tooltip)
    end
    local control = CreateFrame("Frame", nil, parent, initializer:GetTemplate())
    -- ScrollBox normally installs this accessor before InitFrame; canvas controls are persistent.
    control.GetElementData = function() return initializer end
    initializer:InitFrame(control)
    control.Text:SetWordWrap(true)
    control.Text:SetJustifyH("LEFT")
    panel.Controls[key] = control
    return control
end

local function LayoutSelector(selector, width)
    selector:SetWidth(width)
    -- The native wrapper centers its dropdown and anchors steppers outside it.
    local _, _, _, decrementX = selector.DecrementButton:GetPoint(1)
    local _, _, _, incrementX = selector.IncrementButton:GetPoint(1)
    local arrowSpace = math.max(
        selector.DecrementButton:GetWidth() + math.abs(decrementX),
        selector.IncrementButton:GetWidth() + math.abs(incrementX)
    )
    selector.Dropdown:SetWidth(math.max(1, width - 2 * arrowSpace))
end

local function LayoutControl(control, parent, x, y, width)
    control:ClearAllPoints()
    control:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    control:SetWidth(width)
    control.Text:ClearAllPoints()
    control.Tooltip:ClearAllPoints()
    if control.Checkbox then
        control.Checkbox:ClearAllPoints()
        control.Checkbox:SetPoint("LEFT", control, "LEFT", 0, 0)
        control.Text:SetPoint("LEFT", control, "LEFT", 36, 0)
        control.Text:SetWidth(width - 40)
        local height = math.max(control.Checkbox:GetHeight(), control.Text:GetStringHeight() + 12)
        control:SetHeight(height)
        control.Tooltip:SetPoint("TOPLEFT", control.Text, "TOPLEFT")
        control.Tooltip:SetPoint("BOTTOMRIGHT", control.Text, "BOTTOMRIGHT")
        return height
    end
    control.Text:SetPoint("TOPLEFT", control, "TOPLEFT", 4, 0)
    control.Text:SetWidth(width - 8)
    local labelHeight = control.Text:GetStringHeight()
    control.Control:ClearAllPoints()
    control.Control:SetPoint("TOPLEFT", control, "TOPLEFT", 0, -labelHeight - 6)
    LayoutSelector(control.Control, width)
    control.Tooltip:SetAllPoints(control.Text)
    local height = labelHeight + 6 + control.Control:GetHeight()
    control:SetHeight(height)
    return height
end

local mainKeys = { "enabled", "mode", "expansion", "reminder", "ignoreFriendly" }
local debugKeys = { "debugIDs", "debugDetails" }

-- GameTooltip has no maximum-width API. Only oversized static previews need
-- explicit cell wrapping and row heights; ordinary native layout stays intact.
local function LimitPreviewWidth(tooltip, maximumWidth)
    if tooltip:GetWidth() <= maximumWidth and not tooltip.widthLimited then return end
    tooltip.widthLimited = true
    local padding, gap = 12, 12
    local width = 0
    for index = 1, tooltip:NumLines() do
        local left, right = tooltip:GetLeftLine(index), tooltip:GetRightLine(index)
        local lineWidth = left:GetUnboundedStringWidth()
        if right:GetText() and right:GetText() ~= "" then
            lineWidth = lineWidth + gap + right:GetUnboundedStringWidth()
        end
        width = math.max(width, lineWidth)
    end
    width = math.min(maximumWidth, width + 2 * padding)
    local contentWidth = math.max(1, width - 2 * padding)
    local y = padding
    for index = 1, tooltip:NumLines() do
        local left, right = tooltip:GetLeftLine(index), tooltip:GetRightLine(index)
        local hasRight = right:GetText() and right:GetText() ~= ""
        local leftWidth = contentWidth
        if hasRight then
            leftWidth = math.min(left:GetUnboundedStringWidth(), math.max(
                (contentWidth - gap) * 0.4, contentWidth - gap - right:GetUnboundedStringWidth()
            ))
        end
        left:ClearAllPoints()
        left:SetPoint("TOPLEFT", tooltip, "TOPLEFT", padding, -y)
        left:SetWidth(math.max(1, leftWidth))
        left:SetHeight(0)
        left:SetWordWrap(true)
        local _, fontSize = left:GetFont()
        local height = math.max(fontSize * left:GetTextScale(), left:GetStringHeight())
        if hasRight then
            right:ClearAllPoints()
            right:SetPoint("TOPRIGHT", tooltip, "TOPRIGHT", -padding, -y)
            right:SetWidth(math.max(1, contentWidth - gap - leftWidth))
            right:SetHeight(0)
            right:SetWordWrap(true)
            height = math.max(height, right:GetStringHeight())
        end
        y = y + height + 2
    end
    tooltip:SetSize(width, y + padding - 2)
end

local refreshingPreview = false
local layingOutPreview = false

local function LayoutPanel()
    local columnWidth = math.max(1, math.min(300, math.floor((panel:GetWidth() - 56) / 2)))
    panel.Header:SetWidth(math.max(1, panel:GetWidth() - 40))
    panel.HeaderFrame:SetHeight(panel.Header:GetStringHeight())
    local y = 0
    panel.PreviewHeading:ClearAllPoints()
    panel.PreviewHeading:SetPoint("TOPLEFT", panel.Options, "TOPLEFT", 4, -y)
    panel.PreviewHeading:SetWidth(columnWidth - 8)
    y = y + panel.PreviewHeading:GetStringHeight() + 10
    panel.PreviewHelp:ClearAllPoints()
    panel.PreviewHelp:SetPoint("TOPLEFT", panel.Options, "TOPLEFT", 4, -y)
    panel.PreviewHelp:SetWidth(columnWidth - 8)
    y = y + panel.PreviewHelp:GetStringHeight() + 12
    panel.PreviewSelector:ClearAllPoints()
    panel.PreviewSelector:SetPoint("TOPLEFT", panel.Options, "TOPLEFT", 0, -y)
    LayoutSelector(panel.PreviewSelector, columnWidth)
    y = y + panel.PreviewSelector:GetHeight() + 20
    for _, key in ipairs(mainKeys) do
        y = y + LayoutControl(panel.Controls[key], panel.Options, 0, y, columnWidth) + 12
    end
    panel.Options:SetSize(columnWidth, y)

    panel.DebugSection:ClearAllPoints()
    panel.DebugSection:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 16, 16)
    panel.DebugSection:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -16, 16)
    local debugWidth = panel.DebugSection:GetWidth()
    local debugColumnWidth = math.max(1, math.floor((debugWidth - 16) / 2))
    local debugHeight = 0
    for index, key in ipairs(debugKeys) do
        debugHeight = math.max(debugHeight, LayoutControl(
            panel.Controls[key], panel.DebugSection, (index - 1) * (debugColumnWidth + 16), 36, debugColumnWidth
        ))
    end
    for _, key in ipairs(debugKeys) do
        panel.Controls[key]:SetHeight(debugHeight)
    end
    panel.DebugSection:SetHeight(36 + debugHeight + 12)

    panel.PreviewTooltip:ClearAllPoints()
    panel.PreviewTooltip:SetPoint("TOPLEFT", panel.Options, "TOPRIGHT", 16, 0)
end

function CB.LayoutPreview()
    if not panel or not panel:IsVisible() or layingOutPreview then
        return
    end
    layingOutPreview = true
    LayoutPanel()
    local tooltip = panel.PreviewTooltip
    -- Local widths are available during Settings' show transition; screen
    -- coordinates may not resolve until the canvas and its ancestors are visible.
    local maximumWidth = math.min(420, math.max(1, panel:GetWidth() - panel.Options:GetWidth() - 48))
    LimitPreviewWidth(tooltip, maximumWidth)
    layingOutPreview = false
end

function CB.RefreshPreview()
    if not panel or not panel:IsVisible() or refreshingPreview then
        return
    end
    refreshingPreview = true
    panel.PreviewTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    panel.PreviewTooltip:SetParent(UIParent)
    -- Keep control help (TOOLTIP strata) above this persistent preview.
    panel.PreviewTooltip:SetFrameStrata("DIALOG")
    CB.RenderPreview(panel.PreviewTooltip, samples[selectedSample])
    CB.LayoutPreview()
    refreshingPreview = false
end

local function CreatePanel()
    panel = CreateFrame("Frame", "ClassicBestiaryOptions")
    panel:Hide()
    panel.Controls = {}
    panel.HeaderFrame = CreateFrame("Frame", nil, panel)
    panel.HeaderFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    panel.HeaderFrame:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -16)
    panel.Header = panel.HeaderFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    panel.Header:SetPoint("TOPLEFT", 4, 0)
    panel.Header:SetJustifyH("LEFT")
    panel.Header:SetText(L.ADDON_NAME .. " - " .. C_AddOns.GetAddOnMetadata(addonName, "Version"))
    panel.Options = CreateFrame("Frame", nil, panel)
    panel.Options:SetPoint("TOPLEFT", panel.HeaderFrame, "BOTTOMLEFT", 0, -16)
    panel.DebugSection = CreateFrame("Frame", "ClassicBestiaryDebugSection", panel)
    local divider = panel.DebugSection:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.5, 0.5, 0.5, 0.5)
    divider:SetPoint("TOPLEFT")
    divider:SetPoint("TOPRIGHT")
    divider:SetHeight(1)
    local heading = panel.DebugSection:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", 4, -12)
    heading:SetText(L.DEBUG_SECTION)
    panel.PreviewHeading = panel.Options:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.PreviewHeading:SetJustifyH("LEFT")
    panel.PreviewHeading:SetText(L.PREVIEW_HEADING)
    panel.PreviewHelp = panel.Options:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.PreviewHelp:SetJustifyH("LEFT")
    panel.PreviewHelp:SetWordWrap(true)
    panel.PreviewHelp:SetText(L.PREVIEW_HELP)
    samples = {
        { id = 1846, name = L.PREVIEW_LORIK, level = 61, friendly = false },
        { id = 589, name = L.PREVIEW_PILLAGER, level = 14, friendly = false },
        { id = 7275, name = L.PREVIEW_SEZZZIZ, level = 47, friendly = false },
        { id = 12259, name = L.PREVIEW_GEHENNAS, level = -1, friendly = false },
        { id = 10439, name = L.PREVIEW_RAMSTEIN, level = 61, friendly = false },
    }
    panel.PreviewSelector = CreateFrame("Frame", "ClassicBestiaryPreviewSelector", panel.Options, "SettingsDropdownWithButtonsTemplate")
    panel.PreviewSelector.Label:Hide()
    panel.PreviewSelector:SetSteppersShown(true)
    panel.PreviewSelector.Dropdown:SetDefaultText(samples[selectedSample].name)
    panel.PreviewSelector.Dropdown:SetupMenu(function(dropdown, rootDescription)
        for index, sample in ipairs(samples) do
            rootDescription:CreateRadio(sample.name, function(value)
                return selectedSample == value
            end, function(value)
                selectedSample = value
                -- Closed-menu Pick updates text but does not signal the wrapper.
                -- Complete the native selection update before rebuilding preview.
                dropdown:Update()
                CB.RefreshPreview()
            end, index)
        end
    end)
    -- UIParent keeps the preview outside settings ancestors' clipping rectangles.
    panel.PreviewTooltip = CreateFrame("GameTooltip", "ClassicBestiaryPreviewTooltip", UIParent, "GameTooltipTemplate")
    -- Clamping can move an oversized preview left over the settings column.
    panel.PreviewTooltip:SetClampedToScreen(false)
    panel.PreviewTooltip:HookScript("OnTooltipCleared", function(tooltip) tooltip.widthLimited = nil end)
    CB.InitializePreview(panel.PreviewTooltip)
    panel.OnRefresh = CB.RefreshPreview
    panel.OnDefault = function() CB.ResetConfig() end
    panel:SetScript("OnShow", CB.RefreshPreview)
    panel:SetScript("OnHide", function() panel.PreviewTooltip:Hide() end)
    panel:SetScript("OnSizeChanged", CB.LayoutPreview)
end

function CB.RegisterSettings()
    if category then
        return category
    end
    if not CB.config then
        CB.InitializeConfig()
    end
    CreatePanel()
    category = Settings.RegisterCanvasLayoutCategory(panel, L.ADDON_NAME)
    RegisterSetting(panel.Options, "enabled", L.OPTION_ENABLED, L.OPTION_ENABLED_HELP)
    RegisterSetting(panel.Options, "mode", L.OPTION_MODE, L.OPTION_MODE_HELP, ModeOptions)
    RegisterSetting(panel.Options, "expansion", L.OPTION_EXPANSION, L.OPTION_EXPANSION_HELP, ExpansionOptions)
    RegisterSetting(panel.Options, "reminder", L.OPTION_REMINDER, L.OPTION_REMINDER_HELP)
    RegisterSetting(panel.Options, "ignoreFriendly", L.OPTION_IGNORE_FRIENDLY, L.OPTION_IGNORE_FRIENDLY_HELP)
    RegisterSetting(panel.DebugSection, "debugIDs", L.OPTION_DEBUG_IDS, L.OPTION_DEBUG_IDS_HELP)
    RegisterSetting(panel.DebugSection, "debugDetails", L.OPTION_DEBUG_DETAILS, L.OPTION_DEBUG_DETAILS_HELP)
    Settings.RegisterAddOnCategory(category)
    return category
end

function CB.OpenSettings()
    local registeredCategory = CB.RegisterSettings()
    Settings.OpenToCategory(registeredCategory:GetID())
end

function CB.ResetConfig()
    if not CB.config then
        CB.InitializeConfig()
    end
    local saved = CB.config
    for key in pairs(saved) do
        if defaults[key] == nil then
            saved[key] = nil
        end
    end
    for key, value in pairs(defaults) do
        if settings[key] then
            -- Use the same path as user changes so controls and callbacks stay in sync.
            settings[key]:SetValue(value, true)
        else
            saved[key] = value
        end
    end
    ClassicBestiaryCfg = saved
    RefreshTooltip()
end
