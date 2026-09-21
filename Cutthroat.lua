-- Cutthroat: combo point pips + Slice and Dice timer for WoW Forever (1.60.1, interface 16001).
--
-- This client hides combat data from addons ("secret values"):
--  * Combo points are secret: addons may display them but not read, compare, or do math on
--    them. Each pip is a StatusBar ranged [i-1, i] handed the raw count; the engine clamps
--    it, lighting pips 1..cp without this code ever looking at the number.
--  * Buffs cannot be read at all in combat. So the Slice and Dice timer is built from the
--    cast: the cast events still report the spell ID, so on each cast we start five
--    countdowns, one per possible combo point count. Five invisible "gate" bars get the
--    secret combo point count (the pip trick again) and each countdown is clipped to its
--    gate's fill, so countdowns 1..cp are visible and the right one, cp, is on top.
--  * Out of combat buffs are readable, so the timer re-syncs to the real buff there and
--    learns the Improved Slice and Dice talent multiplier from it.

local ADDON_NAME = ...

local SND_SPELL_IDS = { [5171] = true, [6774] = true } -- ranks 1 and 2
local SND_BASE_SECONDS = { 9, 12, 15, 18, 21 }          -- per combo point, before talents
local PIP_COUNT = 5
local PIP_WIDTH, PIP_HEIGHT, PIP_GAP = 30, 22, 4
local BAR_HEIGHT = 14
local SND_COLOR = { 0.35, 0.80, 0.25 }
local WARN_SECONDS = 5       -- bar turns red and pulses below this
local WARN_PULSE_HZ = 2.5
local WHITE = "Interface\\Buttons\\WHITE8X8"
local PIP_COLORS = {
    { 1.00, 0.82, 0.10 }, { 1.00, 0.82, 0.10 }, { 1.00, 0.82, 0.10 },
    { 1.00, 0.55, 0.10 }, { 1.00, 0.25, 0.10 },
}
local DEFAULTS = { locked = false, scale = 1, sndMult = 1, point = { "CENTER", "CENTER", 0, -180 } }
local PREFIX = "|cff66ccffCutthroat:|r "

local db

-- ---------------------------------------------------------------- error capture
-- The client's error UI replaces any global handler an addon installs, so handlers are
-- wrapped here and failures saved (deduplicated) to SavedVariables on logout/reload.
local errors, errorIndex = {}, {}
local function guard(where, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if ok then return end
        local okS, msg = pcall(tostring, err)
        msg = "[" .. where .. "] " .. (okS and msg or "<unprintable error>")
        local entry = errorIndex[msg]
        if entry then
            entry.count = entry.count + 1
        elseif #errors < 30 then
            entry = { first = date("%H:%M:%S"), count = 1, message = msg }
            errorIndex[msg] = entry
            errors[#errors + 1] = entry
        end
    end
end

-- Check secrecy before anything else touches the value.
local function isReadable(v)
    if issecretvalue and issecretvalue(v) then return false end
    return v ~= nil
end

local function aurasHidden()
    if C_Secrets and C_Secrets.ShouldAurasBeSecret then
        local ok, hidden = pcall(C_Secrets.ShouldAurasBeSecret)
        if ok and isReadable(hidden) then return hidden end
    end
    return InCombatLockdown()
end

-- ---------------------------------------------------------------- widgets
local function makeBar(parent, width, height)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(width, height)
    local border = holder:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    border:SetColorTexture(0, 0, 0, 1)

    local bar = CreateFrame("StatusBar", nil, holder)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("BOTTOMRIGHT", -1, 1)
    bar:SetStatusBarTexture(WHITE)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.12, 0.12, 0.12, 1)
    return holder, bar
end

local width = PIP_COUNT * PIP_WIDTH + (PIP_COUNT - 1) * PIP_GAP

local root = CreateFrame("Frame", "CutthroatFrame", UIParent)
root:SetSize(width, PIP_HEIGHT + PIP_GAP + BAR_HEIGHT)
root:SetClampedToScreen(true)
root:SetMovable(true)
root:RegisterForDrag("LeftButton")

-- shown only while unlocked
local overlay = root:CreateTexture(nil, "OVERLAY")
overlay:SetPoint("TOPLEFT", -4, 4)
overlay:SetPoint("BOTTOMRIGHT", 4, -4)
overlay:SetColorTexture(0.2, 0.6, 1, 0.25)
local hint = root:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
hint:SetPoint("BOTTOM", root, "TOP", 0, 6)
hint:SetText("Cutthroat: drag to move, then /cut lock")

local pips = {}
for i = 1, PIP_COUNT do
    local holder, bar = makeBar(root, PIP_WIDTH, PIP_HEIGHT)
    holder:SetPoint("TOPLEFT", root, "TOPLEFT", (i - 1) * (PIP_WIDTH + PIP_GAP), -(BAR_HEIGHT + PIP_GAP))
    bar:SetStatusBarColor(unpack(PIP_COLORS[i]))
    bar:SetMinMaxValues(i - 1, i)
    bar:SetValue(0)
    pips[i] = bar
end

-- Slice and Dice area: an idle placeholder plus five gated countdowns stacked on top
local sndHolder = CreateFrame("Frame", nil, root)
sndHolder:SetSize(width, BAR_HEIGHT)
sndHolder:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
local sndBackdrop = sndHolder:CreateTexture(nil, "BACKGROUND")
sndBackdrop:SetAllPoints()
sndBackdrop:SetColorTexture(0, 0, 0, 0.6)
local placeholder = sndHolder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
placeholder:SetPoint("CENTER")
placeholder:SetText("Slice and Dice")
placeholder:SetAlpha(0.5)

local timers = {}
local baseLevel = sndHolder:GetFrameLevel()
for i = 1, PIP_COUNT do
    -- invisible gate: full when combo points >= i, empty otherwise
    local gate = CreateFrame("StatusBar", nil, sndHolder)
    gate:SetAllPoints()
    gate:SetStatusBarTexture(WHITE)
    gate:SetMinMaxValues(i - 1, i)
    gate:SetValue(0)
    gate:SetAlpha(0)

    -- window sized to the gate's fill; clips the countdown inside it
    local fill = gate:GetStatusBarTexture()
    local window = CreateFrame("Frame", nil, sndHolder)
    window:SetClipsChildren(true)
    window:SetFrameLevel(baseLevel + 5 * i) -- higher combo points draw on top
    window:SetPoint("TOPLEFT", fill, "TOPLEFT")
    window:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")

    local holder, bar = makeBar(window, width, BAR_HEIGHT)
    holder:SetAllPoints(sndHolder)
    bar:SetStatusBarColor(unpack(SND_COLOR))
    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("CENTER")
    holder:Hide()

    timers[i] = { gate = gate, holder = holder, bar = bar, text = text, length = 0 }
end

-- ---------------------------------------------------------------- combo points
local function updateComboPoints()
    -- Secret number: never compared, only handed to the bars.
    -- `or` is a truthiness test, which the client allows on secrets.
    local cp = GetComboPoints("player", "target") or 0
    for i = 1, PIP_COUNT do pips[i]:SetValue(cp) end
end

-- ---------------------------------------------------------------- slice and dice
local sndStart  -- GetTime() the current countdowns started; nil when idle
local pendingCP -- secret combo point count captured as the cast is sent

local function refreshSndVisibility()
    local idle = not sndStart
    placeholder:SetShown(idle)
    sndHolder:SetShown(not idle or (db ~= nil and not db.locked))
end

local function stopTimers()
    sndStart = nil
    for _, t in ipairs(timers) do t.holder:Hide() end
    refreshSndVisibility()
end

-- lengths: seconds per countdown. open: value for the gates - the secret combo point
-- count after a cast, or PIP_COUNT to open all of them when the real buff is known.
local function startTimers(start, lengths, open)
    sndStart = start
    for i, t in ipairs(timers) do
        t.length = lengths[i]
        t.gate:SetValue(open)
        t.bar:SetMinMaxValues(0, t.length)
        t.holder:Show()
    end
    refreshSndVisibility()
end

local sinceUpdate = 0
sndHolder:SetScript("OnUpdate", guard("OnUpdate", function(_, elapsed)
    if not sndStart then return end
    sinceUpdate = sinceUpdate + elapsed
    if sinceUpdate < 0.05 then return end
    sinceUpdate = 0
    local now, running = GetTime(), false
    for _, t in ipairs(timers) do
        if t.holder:IsShown() then
            local remaining = sndStart + t.length - now
            if remaining <= 0 then
                t.holder:Hide()
            else
                running = true
                t.bar:SetValue(remaining)
                t.text:SetFormattedText("Slice and Dice  %.1f", remaining)
                if remaining <= WARN_SECONDS then
                    -- pulse between bright and dark red; color, not alpha, so the
                    -- stacked countdowns underneath never show through
                    local k = 0.5 + 0.5 * math.sin(now * 2 * math.pi * WARN_PULSE_HZ)
                    t.bar:SetStatusBarColor(0.45 + 0.55 * k, 0.05 + 0.10 * k, 0.05 + 0.05 * k)
                else
                    t.bar:SetStatusBarColor(unpack(SND_COLOR))
                end
            end
        end
    end
    if not running then stopTimers() end
end))

local function isSliceAndDiceCast(spellID)
    return isReadable(spellID) and SND_SPELL_IDS[spellID] or false
end

local function onCastSent(spellID)
    if isSliceAndDiceCast(spellID) then
        pendingCP = GetComboPoints("player", "target")
    end
end

local function onCastSucceeded(spellID)
    if not isSliceAndDiceCast(spellID) then return end
    local cp = pendingCP or GetComboPoints("player", "target") or 0
    pendingCP = nil
    local lengths = {}
    for i = 1, PIP_COUNT do lengths[i] = SND_BASE_SECONDS[i] * db.sndMult end
    startTimers(GetTime(), lengths, cp)
end

-- Only callable while auras are readable (out of combat); throws otherwise.
local function findSliceAndDice()
    for i = 1, 40 do
        local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
        if not aura then return nil end
        local id = aura.spellId
        if isReadable(id) and SND_SPELL_IDS[id] then return aura end
    end
end

-- Replace the cast-based estimate with the real buff whenever the client lets us see it.
local function syncFromBuff()
    if aurasHidden() then return end
    local ok, aura = pcall(findSliceAndDice)
    if not ok then return end
    if not aura then
        if sndStart then stopTimers() end
        return
    end
    local exp, dur = aura.expirationTime, aura.duration
    if not (isReadable(exp) and isReadable(dur)) or dur <= 0 then return end

    -- learn the talent multiplier from the buff's full (5 combo point) duration
    local okB, base = pcall(C_UnitAuras.GetAuraBaseDuration, "player", aura.auraInstanceID)
    if okB and isReadable(base) and base > 0 then
        db.sndMult = base / SND_BASE_SECONDS[PIP_COUNT]
    end

    local lengths = {}
    for i = 1, PIP_COUNT do lengths[i] = dur end
    startTimers(exp - dur, lengths, PIP_COUNT)
end

-- ---------------------------------------------------------------- position and lock
local function applyPosition()
    local p = db.point
    root:ClearAllPoints()
    root:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    root:SetScale(db.scale)
end

local function applyLock()
    local unlocked = not db.locked
    root:EnableMouse(unlocked)
    overlay:SetShown(unlocked)
    hint:SetShown(unlocked)
    refreshSndVisibility()
end

root:SetScript("OnDragStart", function(self) self:StartMoving() end)
root:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    db.point = { point, relPoint, x, y }
end)

-- ---------------------------------------------------------------- events
local function registerPlayerEvent(event)
    if root.RegisterUnitEvent and pcall(root.RegisterUnitEvent, root, event, "player") then return end
    root:RegisterEvent(event)
end

root:RegisterEvent("ADDON_LOADED")
root:RegisterEvent("PLAYER_LOGOUT")
root:RegisterEvent("PLAYER_ENTERING_WORLD")
root:RegisterEvent("PLAYER_TARGET_CHANGED")
root:RegisterEvent("PLAYER_REGEN_ENABLED")
registerPlayerEvent("UNIT_POWER_UPDATE")
registerPlayerEvent("UNIT_AURA")
registerPlayerEvent("UNIT_SPELLCAST_SENT")
registerPlayerEvent("UNIT_SPELLCAST_SUCCEEDED")

root:SetScript("OnEvent", guard("OnEvent", function(_, event, ...)
    local unit, arg2 = ...
    if event == "ADDON_LOADED" then
        if unit ~= ADDON_NAME then return end
        -- Settings are per character: this beta has stopped loading account-wide saved
        -- variables back in. loadCount/lastLoad/lastSave make a repeat of that easy to spot.
        CutthroatDB = type(CutthroatDB) == "table" and CutthroatDB or {}
        db = CutthroatDB
        db.loadCount = (db.loadCount or 0) + 1
        db.lastLoad = date("%Y-%m-%d %H:%M:%S")
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        applyPosition()
        applyLock()
        root:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGOUT" then
        if db then
            db.errors = errors
            db.lastSave = date("%Y-%m-%d %H:%M:%S")
        end
    elseif event == "UNIT_POWER_UPDATE" then
        if unit == "player" and arg2 == "COMBO_POINTS" then updateComboPoints() end
    elseif event == "UNIT_SPELLCAST_SENT" then
        if unit == "player" then onCastSent((select(4, ...))) end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if unit == "player" then onCastSucceeded((select(3, ...))) end
    elseif event == "UNIT_AURA" then
        if unit == "player" then syncFromBuff() end
    else -- PLAYER_ENTERING_WORLD, PLAYER_TARGET_CHANGED, PLAYER_REGEN_ENABLED
        updateComboPoints()
        syncFromBuff()
    end
end))

-- ---------------------------------------------------------------- settings panel
-- Built from plain widgets rather than Blizzard option templates, which this client has
-- been dropping; also matches the bar's flat look. Created on first open.
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.5, 3, 0.05
local panel

local function setLocked(locked)
    db.locked = locked
    applyLock()
    if panel and panel:IsShown() then panel.refresh() end
end

local function setScale(scale)
    db.scale = scale
    applyPosition()
    if panel and panel:IsShown() then panel.refresh() end
end

local function resetPosition()
    db.point = { unpack(DEFAULTS.point) }
    db.scale = 1
    applyPosition()
    if panel and panel:IsShown() then panel.refresh() end
end

local function makeButton(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, 22)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.18, 0.18, 0.18, 1)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.12)
    local text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("CENTER")
    text:SetText(label)
    b.text = text
    b:SetScript("OnClick", onClick)
    return b
end

local function buildPanel()
    local p = CreateFrame("Frame", "CutthroatOptions", UIParent)
    p:SetSize(280, 196)
    p:SetPoint("CENTER")
    p:SetFrameStrata("DIALOG")
    p:SetClampedToScreen(true)
    p:SetMovable(true)
    p:EnableMouse(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving)
    p:SetScript("OnDragStop", p.StopMovingOrSizing)
    p:Hide()
    -- Escape closes it, like Blizzard's own panels
    if UISpecialFrames then tinsert(UISpecialFrames, "CutthroatOptions") end

    local border = p:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    border:SetColorTexture(0, 0, 0, 1)
    local bg = p:CreateTexture(nil, "BORDER")
    bg:SetPoint("TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", -1, 1)
    bg:SetColorTexture(0.08, 0.08, 0.08, 0.95)

    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Cutthroat")
    local version = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    version:SetPoint("LEFT", title, "RIGHT", 6, 0)
    local okV, v = pcall(C_AddOns.GetAddOnMetadata, ADDON_NAME, "Version")
    version:SetText(okV and v and ("v" .. v) or "")

    local close = makeButton(p, "X", 22, function() p:Hide() end)
    close:SetPoint("TOPRIGHT", -6, -6)

    -- lock / unlock
    local lockLabel = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lockLabel:SetPoint("TOPLEFT", 14, -44)
    lockLabel:SetText("Position")
    local lockButton = makeButton(p, "", 150, function() setLocked(not db.locked) end)
    lockButton:SetPoint("TOPRIGHT", -14, -40)

    -- scale slider
    local scaleLabel = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    scaleLabel:SetPoint("TOPLEFT", 14, -82)
    local slider = CreateFrame("Slider", nil, p)
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(150, 14)
    slider:SetPoint("TOPRIGHT", -14, -82)
    slider:SetMinMaxValues(SCALE_MIN, SCALE_MAX)
    slider:SetValueStep(SCALE_STEP)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(4)
    track:SetColorTexture(0.25, 0.25, 0.25, 1)
    slider:SetThumbTexture(WHITE)
    local thumb = slider:GetThumbTexture()
    thumb:SetSize(10, 14)
    thumb:SetVertexColor(1.00, 0.82, 0.10)
    slider:EnableMouseWheel(true)
    slider:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(self:GetValue() + delta * SCALE_STEP)
    end)
    slider:SetScript("OnValueChanged", function(_, value)
        value = math.floor(value / SCALE_STEP + 0.5) * SCALE_STEP
        scaleLabel:SetFormattedText("Scale  %.2f", value)
        if db and math.abs(value - db.scale) > 0.001 then
            db.scale = value
            applyPosition()
        end
    end)

    -- reset
    local resetButton = makeButton(p, "Reset position and scale", 252, resetPosition)
    resetButton:SetPoint("TOPLEFT", 14, -114)

    -- read-only info
    local info = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    info:SetPoint("TOPLEFT", 14, -150)
    info:SetPoint("RIGHT", -14, 0)
    info:SetJustifyH("LEFT")

    function p.refresh()
        lockButton.text:SetText(db.locked and "Locked" or "Unlocked (drag the bar)")
        slider:SetValue(db.scale)
        scaleLabel:SetFormattedText("Scale  %.2f", db.scale)
        if math.abs(db.sndMult - 1) < 0.001 then
            info:SetText("Slice and Dice talent bonus: not learned yet\n(learned after your first Slice and Dice out of combat)")
        else
            info:SetFormattedText("Slice and Dice talent bonus: +%d%% (learned)\nCommands: /cut lock | unlock | reset | scale <n>",
                math.floor((db.sndMult - 1) * 100 + 0.5))
        end
    end
    p:SetScript("OnShow", p.refresh)
    return p
end

local function togglePanel()
    panel = panel or buildPanel()
    panel:SetShown(not panel:IsShown())
end

-- ---------------------------------------------------------------- slash commands
SLASH_CUTTHROAT1 = "/cut"
SLASH_CUTTHROAT2 = "/cutthroat"
SlashCmdList.CUTTHROAT = function(msg)
    local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    if cmd == "" then
        local ok, err = pcall(togglePanel)
        if not ok then
            print(PREFIX .. "settings panel failed to open: " .. tostring(err))
            print(PREFIX .. "the typed commands still work: /cut lock | unlock | reset | scale <n>")
        end
    elseif cmd == "lock" then
        setLocked(true)
        print(PREFIX .. "locked.")
    elseif cmd == "unlock" then
        setLocked(false)
        print(PREFIX .. "unlocked. Drag it where you like, then /cut lock")
    elseif cmd == "reset" then
        resetPosition()
        print(PREFIX .. "position and scale reset.")
    elseif cmd == "scale" then
        local n = tonumber(arg)
        if n and n >= SCALE_MIN and n <= SCALE_MAX then
            setScale(n)
            print(PREFIX .. "scale " .. n)
        else
            print(PREFIX .. "usage: /cut scale 0.5-3  (e.g. /cut scale 1.5)")
        end
    else
        print(PREFIX .. "/cut opens settings. Also: /cut lock | unlock | reset | scale <0.5-3>")
    end
end
