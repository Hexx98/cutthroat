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
local PIP_WIDTH, PIP_HEIGHT, PIP_GAP = 22, 22, 4
local BAR_HEIGHT = 20
-- the frame's width at barWidth = 1: five pips at their natural spacing
local BASE_WIDTH = PIP_COUNT * PIP_WIDTH + (PIP_COUNT - 1) * PIP_GAP
local SND_COLOR = { 0.35, 0.80, 0.25 }
local WARN_SECONDS = 5       -- bar turns red and pulses below this
local WARN_PULSE_HZ = 2.5
local WHITE = "Interface\\Buttons\\WHITE8X8"
local PIP_COLORS = {
    { 1.00, 0.82, 0.10 }, { 1.00, 0.82, 0.10 }, { 1.00, 0.82, 0.10 },
    { 1.00, 0.55, 0.10 }, { 1.00, 0.25, 0.10 },
}
local DEFAULTS = {
    locked = false, scale = 1, barWidth = 1, barHeight = 1, pipSize = 1,
    sndMult = 1, pipShape = "square", pipsOnTop = false, showPips = true,
    point = { "CENTER", "CENTER", 0, -180 },
}
-- media\<shape>.tga is the fill; media\<shape>_border.tga is the same shape grown for the outline
-- picker order: geometric shapes first, themed ones on the second row
local SHAPES = {
    "square", "circle", "diamond", "triangle", "star", "hexagon",
    "heart", "crescent", "cross", "dagger", "daggers", "axes",
}
local SHAPE_SET = {}
for _, shape in ipairs(SHAPES) do SHAPE_SET[shape] = true end
local MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\media\\"
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

-- Each pip is two StatusBars ranged [i-1, i] - the outline behind, the colored fill in
-- front - both handed the secret combo point count. The engine draws each one completely
-- or not at all, so a pip, outline included, only appears once that combo point is
-- earned. While unlocked, a faint "ghost" of every pip shows so the bar can be placed.
local pips = {}
for i = 1, PIP_COUNT do
    local holder = CreateFrame("Frame", nil, root)
    holder:SetSize(PIP_WIDTH, PIP_HEIGHT)
    holder:SetPoint("TOPLEFT", root, "TOPLEFT", (i - 1) * (PIP_WIDTH + PIP_GAP), -(BAR_HEIGHT + PIP_GAP))
    -- two unlocked-only preview layers: a dark border under a colour fill (see applyShape)
    local ghostBorder = holder:CreateTexture(nil, "BACKGROUND", nil, 0)
    ghostBorder:SetAllPoints()
    local ghost = holder:CreateTexture(nil, "BACKGROUND", nil, 1)
    ghost:SetAllPoints()
    local function gatedBar(levelOffset)
        local bar = CreateFrame("StatusBar", nil, holder)
        bar:SetAllPoints()
        bar:SetFrameLevel(holder:GetFrameLevel() + levelOffset)
        bar:SetMinMaxValues(i - 1, i)
        bar:SetValue(0)
        return bar
    end
    pips[i] = { holder = holder, ghost = ghost, ghostBorder = ghostBorder, outline = gatedBar(1), fill = gatedBar(2) }
end

local function applyShape()
    local shape = db and db.pipShape or DEFAULTS.pipShape
    local fill, border = MEDIA .. shape .. ".tga", MEDIA .. shape .. "_border.tga"
    for i, pip in ipairs(pips) do
        -- Ghost is the unlocked-only preview: each pip solid in its real colour, with a dark
        -- border underneath, so all five are easy to see and line up against other bars. It's
        -- hidden the instant you lock, leaving only real combo points.
        local c = PIP_COLORS[i]
        pip.ghostBorder:SetTexture(border)
        pip.ghostBorder:SetVertexColor(0, 0, 0, 0.9)
        pip.ghost:SetTexture(fill)
        pip.ghost:SetVertexColor(c[1], c[2], c[3], 0.9)
        pip.outline:SetStatusBarTexture(border)
        pip.outline:SetStatusBarColor(0, 0, 0, 1)
        pip.fill:SetStatusBarTexture(fill)
        pip.fill:SetStatusBarColor(unpack(PIP_COLORS[i]))
    end
end
applyShape()

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

-- Effective pixel metrics. The base constants are the size at every multiplier = 1, and the
-- Scale slider (root:SetScale) zooms the whole frame uniformly on top of this. The three
-- multipliers are deliberately separate so nothing ever distorts a pip:
--   * pipSize  scales pips on BOTH axes, so the shapes keep their aspect ratio
--   * barWidth widens the frame; pips keep their size and spread out to span it
--   * barHeight changes only the Slice and Dice bar's thickness
-- The pip row keeps its own spacing no matter how wide the bar gets: pip and gap scale
-- together with pipSize, so the row grows or shrinks as a unit and the spacing always looks
-- proportional. Widening the bar does NOT push the pips apart - the narrower of the two
-- rows is simply centred against the wider one, and the frame is as wide as the wider row.
local function metrics()
    local barWm = (db and db.barWidth)  or 1
    local barHm = (db and db.barHeight) or 1
    local pipS  = (db and db.pipSize)   or 1

    local pipW, pipH = PIP_WIDTH * pipS, PIP_HEIGHT * pipS
    local gapX = PIP_GAP * pipS
    local pipRowW = PIP_COUNT * pipW + (PIP_COUNT - 1) * gapX

    local barW = BASE_WIDTH * barWm
    return pipW, pipH, gapX, PIP_GAP, BAR_HEIGHT * barHm, math.max(barW, pipRowW), barW, pipRowW
end

-- Sizes and positions everything from the current metrics. Combo points sit below the
-- Slice and Dice bar (default) or above it; either way the frame is re-sized to fit, so
-- the timer bars (anchored to sndHolder via SetAllPoints) follow automatically.
local function applySize()
    local pipW, pipH, gapX, gapY, barH, frameW, barW, pipRowW = metrics()

    -- Pips off: the frame is just the bar. Hiding the holders takes their ghosts and gated
    -- bars with them, so nothing else needs to know.
    if db and not db.showPips then
        for _, pip in ipairs(pips) do pip.holder:Hide() end
        root:SetSize(barW, barH)
        sndHolder:SetSize(barW, barH)
        sndHolder:ClearAllPoints()
        sndHolder:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
        return
    end
    for _, pip in ipairs(pips) do pip.holder:Show() end
    root:SetSize(frameW, pipH + gapY + barH)

    local top = db and db.pipsOnTop
    local pipY = top and 0 or -(barH + gapY)
    local barY = top and -(pipH + gapY) or 0
    -- centre the narrower row against the wider one
    local pipX = (frameW - pipRowW) / 2
    local barX = (frameW - barW) / 2

    for i, pip in ipairs(pips) do
        pip.holder:SetSize(pipW, pipH)
        pip.holder:ClearAllPoints()
        pip.holder:SetPoint("TOPLEFT", root, "TOPLEFT", pipX + (i - 1) * (pipW + gapX), pipY)
    end
    sndHolder:SetSize(barW, barH)
    sndHolder:ClearAllPoints()
    sndHolder:SetPoint("TOPLEFT", root, "TOPLEFT", barX, barY)
end

-- ---------------------------------------------------------------- combo points
local function updateComboPoints()
    -- Secret number: never compared, only handed to the bars.
    -- `or` is a truthiness test, which the client allows on secrets.
    local cp = GetComboPoints("player", "target") or 0
    for _, pip in ipairs(pips) do
        pip.outline:SetValue(cp)
        pip.fill:SetValue(cp)
    end
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
-- Re-anchors the bar at the saved point: only at load and on reset. WoW's layout cache
-- may have restored a dragged position that a lost saved point knows nothing about.
local function applyPosition()
    local p = db.point
    root:ClearAllPoints()
    root:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    root:SetScale(db.scale)
end

local function applyScale()
    root:SetScale(db.scale)
end

local function applyLock()
    local unlocked = not db.locked
    root:EnableMouse(unlocked)
    overlay:SetShown(unlocked)
    hint:SetShown(unlocked)
    for _, pip in ipairs(pips) do
        pip.ghost:SetShown(unlocked)
        pip.ghostBorder:SetShown(unlocked)
    end
    refreshSndVisibility()
end

root:SetScript("OnDragStart", function(self) self:StartMoving() end)
root:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    db.point = { point, relPoint, x, y }
end)

-- ---------------------------------------------------------------- layout-cache settings store
-- This beta sometimes stops loading SavedVariables back in, for every addon. WoW's layout
-- cache - which remembers where you dragged named frames - has kept working throughout, so
-- lock, shape, scale and pip placement are also encoded as the position of an invisible,
-- named helper frame: x packs shape index + lock + pip placement, y = scale x 100. Whole
-- numbers, because the cache rounds offsets. Saved settings stay the primary store; this
-- only fills the gap.
--
-- x is 100 + shapeIndex (+20 locked, +40 pips above). The 100 offset keeps it clear of the
-- pre-0.11 layout (1-35, which only had room for 9 shapes and would now collide), so those
-- older values are still decoded below and carry over.
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.5, 3, 0.05
local SIZE_MIN, SIZE_MAX, SIZE_STEP = 0.5, 3, 0.05
local store = CreateFrame("Frame", "CutthroatSettingsStore", UIParent)
store:SetSize(1, 1)
store:SetAlpha(0)
store:EnableMouse(false)
store:SetMovable(true) -- required for WoW to remember its position
local storeRead = false

local function writeStore()
    local shapeIndex = 1
    for i, shape in ipairs(SHAPES) do
        if shape == db.pipShape then shapeIndex = i end
    end
    store:ClearAllPoints()
    store:SetPoint("CENTER", UIParent, "CENTER",
        100 + shapeIndex + (db.locked and 20 or 0) + (db.pipsOnTop and 40 or 0)
            + (db.showPips and 0 or 80),
        math.floor(db.scale * 100 + 0.5))
    store:SetUserPlaced(true)
end

-- Takes lock/shape/scale from the layout cache once WoW has restored the helper frame.
local function readStore()
    if storeRead or not db or store:GetNumPoints() == 0 then return end
    local _, _, _, x, y = store:GetPoint(1)
    if not (x and y) then return end
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)

    -- unpack largest flag first: 100 + index (+20 locked, +40 above, +80 pips hidden)
    local index, locked, onTop, showPips
    if x >= 100 then
        local rest = x - 100
        showPips = not (rest > 80)
        if not showPips then rest = rest - 80 end
        onTop = rest > 40
        if onTop then rest = rest - 40 end
        locked = rest > 20
        if locked then rest = rest - 20 end
        index = rest
    elseif x >= 1 and x <= 35 then        -- pre-0.11 layout: index (+10 locked, +20 above)
        local rest = x
        onTop = rest > 20
        if onTop then rest = rest - 20 end
        locked = rest > 10
        if locked then rest = rest - 10 end
        if rest > 5 then return end       -- only five shapes existed back then
        index, showPips = rest, true
    else
        return
    end

    local shape, scale = SHAPES[index], y / 100
    if not shape or scale < SCALE_MIN or scale > SCALE_MAX then return end
    storeRead = true
    db.pipShape, db.locked, db.scale, db.pipsOnTop, db.showPips =
        shape, locked, scale, onTop, showPips
    applyShape()
    applyScale()
    applyLock()
    applySize()
end

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
        -- 0.9.0 had a single width/height pair that stretched the pips along with the bar,
        -- turning round shapes into ovals. Carry the bar size over and let pipSize default
        -- to 1, which puts the pips back to their true aspect ratio.
        if db.barWidth == nil and db.width ~= nil then db.barWidth = db.width end
        if db.barHeight == nil and db.height ~= nil then db.barHeight = db.height end
        db.width, db.height = nil, nil
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        if not SHAPE_SET[db.pipShape] then db.pipShape = DEFAULTS.pipShape end
        applyShape()
        applySize()
        applyPosition()
        applyLock()
        readStore() -- in case the layout cache was applied before us
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
        if event == "PLAYER_ENTERING_WORLD" then
            -- the layout cache is applied shortly after addons load; look a few times
            readStore()
            C_Timer.After(1, guard("readStore", readStore))
            C_Timer.After(3, guard("readStore", readStore))
        end
        updateComboPoints()
        syncFromBuff()
    end
end))

-- ---------------------------------------------------------------- settings panel
-- Built from plain widgets rather than Blizzard option templates, which this client has
-- been dropping; also matches the bar's flat look. Created on first open.
local panel

local function setLocked(locked)
    db.locked = locked
    applyLock()
    writeStore()
    if panel and panel:IsShown() then panel.refresh() end
end

local function setScale(scale)
    db.scale = scale
    applyScale()
    writeStore()
    if panel and panel:IsShown() then panel.refresh() end
end

local function setBarWidth(w)
    db.barWidth = w
    applySize()
    if panel and panel:IsShown() then panel.refresh() end
end

local function setBarHeight(h)
    db.barHeight = h
    applySize()
    if panel and panel:IsShown() then panel.refresh() end
end

local function setPipSize(s)
    db.pipSize = s
    applySize()
    if panel and panel:IsShown() then panel.refresh() end
end

local function setShape(shape)
    db.pipShape = shape
    applyShape()
    writeStore()
    if panel and panel:IsShown() then panel.refresh() end
end

local function setShowPips(show)
    db.showPips = show
    applySize()
    applyLock()
    writeStore()
    if panel and panel:IsShown() then panel.refresh() end
end

-- the Placement control cycles: below -> above -> hidden -> below
local function cyclePipDisplay()
    if not db.showPips then
        db.showPips, db.pipsOnTop = true, false
    elseif db.pipsOnTop then
        db.showPips = false
    else
        db.pipsOnTop = true
    end
    applySize()
    applyLock()
    writeStore()
    if panel and panel:IsShown() then panel.refresh() end
end

local function setPipsOnTop(onTop)
    db.pipsOnTop = onTop
    db.showPips = true          -- asking for a placement implies you want them visible
    applySize()
    writeStore()
    if panel and panel:IsShown() then panel.refresh() end
end

local function resetPosition()
    db.point = { unpack(DEFAULTS.point) }
    db.scale, db.barWidth, db.barHeight, db.pipSize = 1, 1, 1, 1
    applyPosition()
    applySize()
    writeStore()
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

-- A labelled horizontal slider on one row at vertical offset y. apply(value) is called
-- (from OnValueChanged) with the stepped value whenever the user drags or wheels it;
-- the label on the left shows labelFmt. refresh() pushes db values back in via SetValue.
local function makeSlider(parent, y, min, max, step, labelFmt, apply, inset)
    inset = inset or 14
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", inset, y)
    local slider = CreateFrame("Slider", nil, parent)
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(150, 14)
    slider:SetPoint("TOPRIGHT", -inset, y)
    slider:SetMinMaxValues(min, max)
    slider:SetValueStep(step)
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
        self:SetValue(self:GetValue() + delta * step)
    end)
    slider:SetScript("OnValueChanged", function(_, value)
        value = math.floor(value / step + 0.5) * step
        label:SetFormattedText(labelFmt, value)
        if db then apply(value) end
    end)
    slider.label = label
    return slider
end

-- ---------------------------------------------------------------- section boxes
-- WoW has no rounded-rectangle primitive and this client keeps dropping Blizzard's backdrop
-- templates, so each box is nine-sliced from one corner tile: four corners (the same
-- texture flipped with SetTexCoord) plus three flat bands. These are regions of the panel
-- on ARTWORK, which keeps them above the panel background but below the OVERLAY labels.
local PANEL_W = 280
local function roundedBox(p, top, bottom, inset, radius, r, g, b, a)
    local L, R = 8 + inset, PANEL_W - 8 - inset
    local w, h = R - L, top - bottom
    local function band(x, y, bw, bh)
        local t = p:CreateTexture(nil, "ARTWORK")
        t:SetColorTexture(r, g, b, a)
        t:SetPoint("TOPLEFT", p, "TOPLEFT", x, y)
        t:SetSize(bw, bh)
    end
    local function corner(x, y, cl, cr, ct, cb)
        local t = p:CreateTexture(nil, "ARTWORK")
        t:SetTexture(MEDIA .. "corner.tga")
        t:SetTexCoord(cl, cr, ct, cb)
        t:SetVertexColor(r, g, b, a)
        t:SetPoint("TOPLEFT", p, "TOPLEFT", x, y)
        t:SetSize(radius, radius)
    end
    corner(L,          top,             0, 1, 0, 1)
    corner(R - radius, top,             1, 0, 0, 1)
    corner(L,          bottom + radius, 0, 1, 1, 0)
    corner(R - radius, bottom + radius, 1, 0, 1, 0)
    band(L,          top - radius,    w,              h - 2 * radius)
    band(L + radius, top,             w - 2 * radius, radius)
    band(L + radius, bottom + radius, w - 2 * radius, radius)
end

-- A bordered box: outline, then the fill inset inside it. The radius is generous and the
-- outline 2px on purpose - a 1px line has too few pixels to hold its position around a
-- tight curve, so it visibly steps inward where the arc meets the straight edge.
local function sectionBox(p, top, bottom)
    roundedBox(p, top,     bottom,     0, 12, 0.24, 0.24, 0.32, 1)
    roundedBox(p, top - 2, bottom + 2, 2, 10, 0.115, 0.115, 0.15, 1)
end

local function sectionHeader(p, y, text)
    local fs = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetText(text)
    fs:SetTextColor(0.46, 0.56, 0.82)
end

local function buildPanel()
    local p = CreateFrame("Frame", "CutthroatOptions", UIParent)
    p:SetSize(PANEL_W, 468)
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

    -- Three sections, so it's obvious at a glance which controls act on the bar and which
    -- act on the pips - Scale sits in General because it zooms the whole frame.
    local IN = 20   -- controls sit 12px inside the box edge

    -- ---- General ----
    sectionHeader(p, -40, "GENERAL")
    sectionBox(p, -54, -116)
    local lockLabel = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lockLabel:SetPoint("TOPLEFT", IN, -62)
    lockLabel:SetText("Position")
    local lockButton = makeButton(p, "", 142, function() setLocked(not db.locked) end)
    lockButton:SetPoint("TOPRIGHT", -IN, -58)
    local scaleSlider = makeSlider(p, -92, SCALE_MIN, SCALE_MAX, SCALE_STEP, "Scale  %.2f", function(v)
        if math.abs(v - db.scale) > 0.001 then db.scale = v; applyScale(); writeStore() end
    end, IN)

    -- ---- Slice and Dice bar ----
    sectionHeader(p, -128, "SLICE AND DICE BAR")
    sectionBox(p, -142, -204)
    local barWidthSlider = makeSlider(p, -150, SIZE_MIN, SIZE_MAX, SIZE_STEP, "Bar width  %.2f", function(v)
        if math.abs(v - db.barWidth) > 0.001 then db.barWidth = v; applySize() end
    end, IN)
    local barHeightSlider = makeSlider(p, -180, SIZE_MIN, SIZE_MAX, SIZE_STEP, "Bar height  %.2f", function(v)
        if math.abs(v - db.barHeight) > 0.001 then db.barHeight = v; applySize() end
    end, IN)

    -- ---- Combo points ----
    sectionHeader(p, -216, "COMBO POINTS")
    sectionBox(p, -230, -374)
    local pipSizeSlider = makeSlider(p, -238, SIZE_MIN, SIZE_MAX, SIZE_STEP, "Pip size  %.2f", function(v)
        if math.abs(v - db.pipSize) > 0.001 then db.pipSize = v; applySize() end
    end, IN)

    -- pip shape: one icon button per shape
    local shapeLabel = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    shapeLabel:SetPoint("TOPLEFT", IN, -296)
    shapeLabel:SetText("Shape")
    local shapeButtons = {}
    local SHAPE_COLS = 6   -- 6 x 30px = 180px, comfortably inside the 252px content width
    for idx, shape in ipairs(SHAPES) do
        local row = math.floor((idx - 1) / SHAPE_COLS)
        local col = (idx - 1) % SHAPE_COLS
        local b = CreateFrame("Button", nil, p)
        b:SetSize(24, 24)
        b:SetPoint("TOPLEFT", IN + col * 30, -314 - row * 28)
        local selected = b:CreateTexture(nil, "BACKGROUND")
        selected:SetPoint("TOPLEFT", -3, 3)
        selected:SetPoint("BOTTOMRIGHT", 3, -3)
        selected:SetColorTexture(1, 1, 1, 0.25)
        local outline = b:CreateTexture(nil, "BORDER")
        outline:SetAllPoints()
        outline:SetTexture(MEDIA .. shape .. "_border.tga")
        outline:SetVertexColor(0, 0, 0, 1)
        local icon = b:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetTexture(MEDIA .. shape .. ".tga")
        icon:SetVertexColor(unpack(PIP_COLORS[1]))
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetPoint("TOPLEFT", -3, 3)
        hl:SetPoint("BOTTOMRIGHT", 3, -3)
        hl:SetColorTexture(1, 1, 1, 0.12)
        b:SetScript("OnClick", function() setShape(shape) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText((shape:gsub("^%l", string.upper)))
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b.selected = selected
        shapeButtons[shape] = b
    end

    -- combo points above or below the Slice and Dice bar
    local layoutLabel = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    layoutLabel:SetPoint("TOPLEFT", IN, -272)
    layoutLabel:SetText("Placement")
    local layoutButton = makeButton(p, "", 142, cyclePipDisplay)
    layoutButton:SetPoint("TOPRIGHT", -IN, -268)

    -- reset
    local resetButton = makeButton(p, "Reset size and position", 252, resetPosition)
    resetButton:SetPoint("TOPLEFT", 14, -390)

    -- read-only info
    local info = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    info:SetPoint("TOPLEFT", 14, -422)
    info:SetPoint("RIGHT", -14, 0)
    info:SetJustifyH("LEFT")

    function p.refresh()
        lockButton.text:SetText(db.locked and "Locked" or "Unlocked (drag the bar)")
        scaleSlider:SetValue(db.scale)
        scaleSlider.label:SetFormattedText("Scale  %.2f", db.scale)
        barWidthSlider:SetValue(db.barWidth)
        barWidthSlider.label:SetFormattedText("Bar width  %.2f", db.barWidth)
        barHeightSlider:SetValue(db.barHeight)
        barHeightSlider.label:SetFormattedText("Bar height  %.2f", db.barHeight)
        pipSizeSlider:SetValue(db.pipSize)
        pipSizeSlider.label:SetFormattedText("Pip size  %.2f", db.pipSize)
        for shape, b in pairs(shapeButtons) do b.selected:SetShown(shape == db.pipShape) end
        layoutButton.text:SetText(not db.showPips and "Hidden"
            or (db.pipsOnTop and "Above the bar" or "Below the bar"))
        -- pip size and shape do nothing while the pips are hidden, so dim them out
        local lit = db.showPips and 1 or 0.3
        pipSizeSlider:SetAlpha(lit)
        pipSizeSlider:EnableMouse(db.showPips)
        shapeLabel:SetAlpha(lit)
        for _, b in pairs(shapeButtons) do
            b:SetAlpha(lit)
            b:EnableMouse(db.showPips)
        end
        if math.abs(db.sndMult - 1) < 0.001 then
            info:SetText("Slice and Dice talent bonus: not learned yet\n(learned after your first Slice and Dice out of combat)")
        else
            info:SetFormattedText("Slice and Dice talent bonus: +%d%% (learned)\nCommands: /cut lock | reset | scale | barwidth | barheight | pipsize <n>",
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
            print(PREFIX .. "the typed commands still work: /cut lock | unlock | reset | scale <n> | barwidth <n> | barheight <n> | pipsize <n> | pips above|below|show|hide")
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
    elseif cmd == "shape" then
        if SHAPE_SET[arg] then
            setShape(arg)
            print(PREFIX .. "pip shape " .. arg)
        else
            print(PREFIX .. "usage: /cut shape " .. table.concat(SHAPES, " | "))
        end
    elseif cmd == "pips" then
        if arg == "above" or arg == "top" then
            setPipsOnTop(true)
            print(PREFIX .. "combo points above the Slice and Dice bar.")
        elseif arg == "below" or arg == "bottom" then
            setPipsOnTop(false)
            print(PREFIX .. "combo points below the Slice and Dice bar.")
        elseif arg == "hide" or arg == "off" then
            setShowPips(false)
            print(PREFIX .. "combo points hidden - just the Slice and Dice bar now.")
        elseif arg == "show" or arg == "on" then
            setShowPips(true)
            print(PREFIX .. "combo points shown.")
        else
            print(PREFIX .. "usage: /cut pips above | below | show | hide")
        end
    elseif cmd == "scale" then
        local n = tonumber(arg)
        if n and n >= SCALE_MIN and n <= SCALE_MAX then
            setScale(n)
            print(PREFIX .. "scale " .. n)
        else
            print(PREFIX .. "usage: /cut scale 0.5-3  (e.g. /cut scale 1.5)")
        end
    elseif cmd == "barwidth" or cmd == "width" then
        local n = tonumber(arg)
        if n and n >= SIZE_MIN and n <= SIZE_MAX then
            setBarWidth(n)
            print(PREFIX .. "bar width " .. n)
        else
            print(PREFIX .. "usage: /cut barwidth 0.5-3  (e.g. /cut barwidth 1.5)")
        end
    elseif cmd == "barheight" or cmd == "height" then
        local n = tonumber(arg)
        if n and n >= SIZE_MIN and n <= SIZE_MAX then
            setBarHeight(n)
            print(PREFIX .. "bar height " .. n)
        else
            print(PREFIX .. "usage: /cut barheight 0.5-3  (e.g. /cut barheight 1.5)")
        end
    elseif cmd == "pipsize" or cmd == "pip" then
        local n = tonumber(arg)
        if n and n >= SIZE_MIN and n <= SIZE_MAX then
            setPipSize(n)
            print(PREFIX .. "pip size " .. n)
        else
            print(PREFIX .. "usage: /cut pipsize 0.5-3  (e.g. /cut pipsize 1.5)")
        end
    else
        print(PREFIX .. "/cut opens settings. Also: /cut lock | unlock | reset | scale | barwidth | barheight | pipsize <0.5-3> | shape <name> | pips above|below|show|hide")
    end
end
