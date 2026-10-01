-- Cutthroat: combo point pips + Slice and Dice timer for WoW Forever (1.60.1, interface 16001).
--
-- This client hides combat data from addons ("secret values"):
--  * Combo points are secret: addons may display them but not read, compare, or do math on
--    them. Each pip is a StatusBar ranged [i-1, i] handed the raw count; the engine clamps
--    it, lighting pips 1..cp without this code ever looking at the number.
--  * Buffs cannot be read at all in combat. So a timer bar is built from the cast instead:
--    the cast events still report the spell ID, so on each cast a combo-point-scaled bar
--    starts five countdowns, one per possible combo point count. Five invisible "gate" bars
--    get the secret count (the pip trick again) and each countdown is clipped to its gate's
--    fill, so countdowns 1..cp are visible and the right one, cp, is on top.
--  * Out of combat auras are readable, so a bar re-syncs to the real one there and learns
--    its talent multiplier from it.
--
-- Bars are data, not code: see BAR_DEFS. Slice and Dice is the only one so far.

local ADDON_NAME = ...

local PIP_COUNT = 5
local PIP_WIDTH, PIP_HEIGHT, PIP_GAP = 22, 22, 4
local BAR_HEIGHT = 20
-- the frame's width at barWidth = 1: five pips at their natural spacing
local BASE_WIDTH = PIP_COUNT * PIP_WIDTH + (PIP_COUNT - 1) * PIP_GAP
local WARN_SECONDS = 5       -- bar turns red and pulses below this
local WARN_PULSE_HZ = 2.5
local WHITE = "Interface\\Buttons\\WHITE8X8"
local PIP_COLORS = {
    { 1.00, 0.82, 0.10 }, { 1.00, 0.82, 0.10 }, { 1.00, 0.82, 0.10 },
    { 1.00, 0.55, 0.10 }, { 1.00, 0.25, 0.10 },
}
-- Every timer bar is described here and built by createBar(), so adding one is a new entry
-- rather than another copy of the machinery.
--   seconds  a table = the duration scales with combo points, so the bar runs all five
--            countdowns at once and lets the engine pick (see createBar);
--            a number = a fixed duration, which needs one countdown and no gates.
--   unit     which unit carries the aura - "player" for a buff on us. Debuffs on "target"
--            will also need per-target tracking, which does not exist yet.
--   multKey  db field holding the talent multiplier learned from the real buff.
local BAR_DEFS = {
    {
        key      = "snd",
        label    = "Slice and Dice",
        spellIDs = { [5171] = true, [6774] = true },   -- ranks 1 and 2
        seconds  = { 9, 12, 15, 18, 21 },              -- per combo point, before talents
        color    = { 0.35, 0.80, 0.25 },
        unit     = "player",
        multKey  = "sndMult",
    },
    {
        key       = "expose",
        label     = "Expose Armor",
        spellIDs  = { [8647] = true, [8649] = true, [8650] = true,   -- ranks 1-5
                      [11197] = true, [11198] = true },
        seconds   = 30,        -- fixed: combo points change the armor reduction, not the
                               -- duration. Corrected from the real debuff by learnKey below.
        color     = { 0.85, 0.55, 0.20 },
        unit      = "target",
        harmful   = true,      -- a debuff on the target, not a buff on us
        perTarget = true,      -- one countdown per target GUID
        learnKey  = "exposeSeconds",
    },
    {
        -- both combo-point-scaled and per-target: the gate trick and GUID tracking together
        key       = "rupture",
        label     = "Rupture",
        spellIDs  = { [1943] = true, [8639] = true, [8640] = true,   -- ranks 1-6
                      [11273] = true, [11274] = true, [11275] = true },
        seconds   = { 8, 10, 12, 14, 16 },   -- 6 + 2 per combo point
        color     = { 0.72, 0.33, 0.72 },    -- not red: the expiry warning pulses red
        unit      = "target",
        harmful   = true,
        perTarget = true,
    },
}

local DEFAULTS = {
    locked = false, scale = 1, barWidth = 1, barHeight = 1, pipSize = 1,
    sndMult = 1, pipShape = "square", pipsOnTop = false, showPips = true,
    barLayout = "vertical",   -- or "horizontal"
    alwaysShowPips = false,   -- keep empty pip sockets on screen at zero combo points
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

-- The ghost textures do two different jobs and look different for each:
--   unlocked   - a positioning aid: every pip solid in its real colour, easy to line up
--   empty pips - a permanent socket: hollow and dim, so earned pips still stand out
-- Unlocked wins when both apply. Filling the sockets in colour would make it look like you
-- always had five combo points, which is the opposite of useful.
local function applyPipGhosts()
    local shape = (db and db.pipShape) or DEFAULTS.pipShape
    local fill, border = MEDIA .. shape .. ".tga", MEDIA .. shape .. "_border.tga"
    local unlocked = db ~= nil and not db.locked
    local sockets  = db ~= nil and db.alwaysShowPips
    for i, pip in ipairs(pips) do
        if unlocked then
            local c = PIP_COLORS[i]
            pip.ghostBorder:SetTexture(border)
            pip.ghostBorder:SetVertexColor(0, 0, 0, 0.9)
            pip.ghost:SetTexture(fill)
            pip.ghost:SetVertexColor(c[1], c[2], c[3], 0.9)
        elseif sockets then
            pip.ghostBorder:SetTexture(border)
            pip.ghostBorder:SetVertexColor(0, 0, 0, 0.55)
            pip.ghost:SetTexture(border)   -- the outline, not the fill: an empty socket
            pip.ghost:SetVertexColor(0.55, 0.55, 0.62, 0.35)
        end
        pip.ghost:SetShown(unlocked or sockets)
        pip.ghostBorder:SetShown(unlocked or sockets)
    end
end

local function applyShape()
    local shape = db and db.pipShape or DEFAULTS.pipShape
    local fill, border = MEDIA .. shape .. ".tga", MEDIA .. shape .. "_border.tga"
    for i, pip in ipairs(pips) do
        pip.outline:SetStatusBarTexture(border)
        pip.outline:SetStatusBarColor(0, 0, 0, 1)
        pip.fill:SetStatusBarTexture(fill)
        pip.fill:SetStatusBarColor(unpack(PIP_COLORS[i]))
    end
    applyPipGhosts()
end
applyShape()

-- One timer bar: an idle placeholder plus its countdowns.
--
-- A combo-point-scaled bar cannot know which duration applies, because the count is secret.
-- So it builds five countdowns and lets the engine choose: five invisible gate bars ranged
-- [i-1, i] are handed the secret count, and each countdown is clipped to its gate's fill, so
-- countdowns 1..cp are visible and the right one, cp, draws on top. A fixed-duration bar
-- needs none of that - one countdown, no gates.
local function createBar(def)
    local bar = { def = def, start = nil, timers = {}, byGuid = {} }

    local frame = CreateFrame("Frame", nil, root)
    frame:SetSize(width, BAR_HEIGHT)
    frame:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
    bar.frame = frame

    local backdrop = frame:CreateTexture(nil, "BACKGROUND")
    backdrop:SetAllPoints()
    backdrop:SetColorTexture(0, 0, 0, 0.6)

    local placeholder = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    placeholder:SetPoint("CENTER")
    placeholder:SetText(def.label)
    placeholder:SetAlpha(0.5)
    bar.placeholder = placeholder

    local gated = type(def.seconds) == "table"
    local baseLevel = frame:GetFrameLevel()
    for i = 1, gated and PIP_COUNT or 1 do
        local parent, gate = frame, nil
        if gated then
            -- invisible gate: full when combo points >= i, empty otherwise
            gate = CreateFrame("StatusBar", nil, frame)
            gate:SetAllPoints()
            gate:SetStatusBarTexture(WHITE)
            gate:SetMinMaxValues(i - 1, i)
            gate:SetValue(0)
            gate:SetAlpha(0)

            -- window sized to the gate's fill; clips the countdown inside it
            local fill = gate:GetStatusBarTexture()
            local window = CreateFrame("Frame", nil, frame)
            window:SetClipsChildren(true)
            window:SetFrameLevel(baseLevel + 5 * i) -- higher combo points draw on top
            window:SetPoint("TOPLEFT", fill, "TOPLEFT")
            window:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")
            parent = window
        end

        local holder, statusBar = makeBar(parent, width, BAR_HEIGHT)
        holder:SetAllPoints(frame)
        statusBar:SetStatusBarColor(unpack(def.color))
        local text = statusBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("CENTER")
        holder:Hide()

        bar.timers[i] = { gate = gate, holder = holder, bar = statusBar, text = text, length = 0 }
    end
    return bar
end

local bars, barsByKey = {}, {}
for _, def in ipairs(BAR_DEFS) do
    local bar = createBar(def)
    bars[#bars + 1] = bar
    barsByKey[def.key] = bar
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
    local pipS = (db and db.pipSize) or 1
    local pipW, pipH = PIP_WIDTH * pipS, PIP_HEIGHT * pipS
    local gapX = PIP_GAP * pipS
    return pipW, pipH, gapX, PIP_GAP, PIP_COUNT * pipW + (PIP_COUNT - 1) * gapX
end

-- Bars stack downward for now; the vertical/horizontal direction toggle arrives with the
-- container work. Each bar carries its own size, so they are centred against each other -
-- left-aligning bars of different widths just looks like a mistake.
local BAR_GAP = 2

-- per-bar settings live in db.bars[key]; before that exists everything falls back to 1/on
local function barSettings(key)
    return db and db.bars and db.bars[key]
end

local function barSize(bar)
    local s = barSettings(bar.def.key)
    return BASE_WIDTH * ((s and s.w) or 1), BAR_HEIGHT * ((s and s.h) or 1)
end

local function barEnabled(bar)
    local s = barSettings(bar.def.key)
    return s == nil or s.on ~= false
end

-- bars in the user's chosen order; falls back to definition order before db loads
local function orderedBars()
    local out = {}
    for _, key in ipairs((db and db.barOrder) or {}) do
        local bar = barsByKey[key]
        if bar then out[#out + 1] = bar end
    end
    if #out == 0 then return bars end
    return out
end

local function horizontal()
    return db ~= nil and db.barLayout == "horizontal"
end

-- Stacked: as wide as the widest bar, as tall as all of them plus the gaps.
-- Side by side: the other way round.
local function barsAreaSize()
    local maxW, maxH, sumW, sumH, shown = 0, 0, 0, 0, 0
    for _, bar in ipairs(orderedBars()) do
        if barEnabled(bar) then
            local w, h = barSize(bar)
            if w > maxW then maxW = w end
            if h > maxH then maxH = h end
            sumW, sumH, shown = sumW + w, sumH + h, shown + 1
        end
    end
    local gaps = shown > 1 and (shown - 1) * BAR_GAP or 0
    if horizontal() then return sumW + gaps, maxH end
    return maxW, sumH + gaps
end

-- Creates any missing per-bar settings and keeps the order list honest. Called at load, so a
-- new BAR_DEFS entry just appears at the bottom rather than needing a migration. The width and
-- height a bar starts with come from the old single barWidth/barHeight pair, so upgrading does
-- not change how anything looks.
local function ensureBarSettings()
    db.bars = db.bars or {}
    for _, def in ipairs(BAR_DEFS) do
        local s = db.bars[def.key]
        if not s then
            s = { w = db.barWidth or 1, h = db.barHeight or 1, on = true }
            db.bars[def.key] = s
        end
        if s.on == nil then s.on = true end
        s.w, s.h = s.w or 1, s.h or 1
    end

    local order, seen = {}, {}
    for _, key in ipairs(db.barOrder or {}) do
        if barsByKey[key] and not seen[key] then
            order[#order + 1], seen[key] = key, true
        end
    end
    for _, def in ipairs(BAR_DEFS) do          -- anything new goes on the end
        if not seen[def.key] then order[#order + 1] = def.key end
    end
    db.barOrder = order
end

-- Sizes and positions only; showing/hiding is barRefreshVisibility's job. Bars are centred
-- across whichever axis they are not laid out along, so differing sizes read as deliberate.
local function layoutBars(frameW, y)
    local horiz = horizontal()
    local barsW, barsH = barsAreaSize()
    local x = (frameW - barsW) / 2
    for _, bar in ipairs(orderedBars()) do
        if barEnabled(bar) then
            local w, h = barSize(bar)
            bar.frame:SetSize(w, h)
            bar.frame:ClearAllPoints()
            if horiz then
                bar.frame:SetPoint("TOPLEFT", root, "TOPLEFT", x, y - (barsH - h) / 2)
                x = x + w + BAR_GAP
            else
                bar.frame:SetPoint("TOPLEFT", root, "TOPLEFT", (frameW - w) / 2, y)
                y = y - h - BAR_GAP
            end
        else
            bar.frame:Hide()
        end
    end
end

-- Sizes and positions everything from the current metrics. Combo points sit below the
-- Slice and Dice bar (default) or above it; either way the frame is re-sized to fit, so
-- each bar's countdowns (anchored to its frame via SetAllPoints) follow automatically.
local function applySize()
    local pipW, pipH, gapX, gapY, pipRowW = metrics()
    local barsW, barsH = barsAreaSize()
    local showPips = (db == nil) or db.showPips
    -- the frame is as wide as the widest row in it; everything narrower is centred
    local frameW = math.max(barsW, showPips and pipRowW or 0)

    -- Pips off: the frame is just the bars. Hiding the holders takes their ghosts and gated
    -- bars with them, so nothing else needs to know.
    if not showPips then
        for _, pip in ipairs(pips) do pip.holder:Hide() end
        root:SetSize(frameW, barsH)
        layoutBars(frameW, 0)
        return
    end
    for _, pip in ipairs(pips) do pip.holder:Show() end
    root:SetSize(frameW, pipH + gapY + barsH)

    local top = db and db.pipsOnTop
    local pipY = top and 0 or -(barsH + gapY)
    local barY = top and -(pipH + gapY) or 0
    local pipX = (frameW - pipRowW) / 2

    for i, pip in ipairs(pips) do
        pip.holder:SetSize(pipW, pipH)
        pip.holder:ClearAllPoints()
        pip.holder:SetPoint("TOPLEFT", root, "TOPLEFT", pipX + (i - 1) * (pipW + gapX), pipY)
    end
    layoutBars(frameW, barY)
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
local pendingCP -- secret combo point count captured as the cast is sent

local function barRefreshVisibility(bar)
    if not barEnabled(bar) then bar.frame:Hide(); return end
    local idle = not bar.start
    bar.placeholder:SetShown(idle)
    bar.frame:SetShown(not idle or (db ~= nil and not db.locked))
end

local function refreshBarVisibility()
    for _, bar in ipairs(bars) do barRefreshVisibility(bar) end
end

local function barStop(bar)
    bar.start = nil
    for _, t in ipairs(bar.timers) do t.holder:Hide() end
    barRefreshVisibility(bar)
end

-- lengths: seconds per countdown. open: value for the gates - the secret combo point count
-- after a cast, or PIP_COUNT to open all of them when the real aura is known. A fixed
-- duration bar has no gates, so open is ignored.
local function barStart(bar, start, lengths, open)
    bar.start = start
    for i, t in ipairs(bar.timers) do
        t.length = lengths[i]
        if t.gate then
            -- open is the secret combo point count, and for a per-target bar it has been
            -- parked in a table and read back out. That round-trip was verified working
            -- 2026-09-30: secrets survive being stored as table *values* (only table keys are
            -- refused), so a bar returns at the right length when you switch back to a mob.
            -- The pcall stays as cheap insurance - a refusal here would otherwise throw in
            -- the cast path - and falls back to opening every gate, which overestimates
            -- rather than showing nothing.
            if not pcall(t.gate.SetValue, t.gate, open) then
                t.gate:SetValue(PIP_COUNT)
            end
        end
        t.bar:SetMinMaxValues(0, t.length)
        t.holder:Show()
    end
    barRefreshVisibility(bar)
end

-- returns true while any countdown on this bar is still running
local function barUpdate(bar, now)
    local running = false
    for _, t in ipairs(bar.timers) do
        if t.holder:IsShown() then
            local remaining = bar.start + t.length - now
            if remaining <= 0 then
                t.holder:Hide()
            else
                running = true
                t.bar:SetValue(remaining)
                t.text:SetFormattedText("%s  %.1f", bar.def.label, remaining)
                if remaining <= WARN_SECONDS then
                    -- pulse between bright and dark red; color, not alpha, so the
                    -- stacked countdowns underneath never show through
                    local k = 0.5 + 0.5 * math.sin(now * 2 * math.pi * WARN_PULSE_HZ)
                    t.bar:SetStatusBarColor(0.45 + 0.55 * k, 0.05 + 0.10 * k, 0.05 + 0.05 * k)
                else
                    t.bar:SetStatusBarColor(unpack(bar.def.color))
                end
            end
        end
    end
    return running
end

-- Driven from the root frame rather than any one bar, so it keeps running no matter which
-- bars are hidden.
local sinceUpdate = 0
root:SetScript("OnUpdate", guard("OnUpdate", function(_, elapsed)
    sinceUpdate = sinceUpdate + elapsed
    if sinceUpdate < 0.05 then return end
    sinceUpdate = 0
    local now = GetTime()
    for _, bar in ipairs(bars) do
        if bar.start and not barUpdate(bar, now) then
            -- a per-target countdown that ran out is done for that mob too
            if bar.def.perTarget then
                local guid = UnitGUID("target")
                if guid then bar.byGuid[guid] = nil end
            end
            barStop(bar)
        end
    end
end))

local function barForSpell(spellID)
    if not isReadable(spellID) then return nil end
    for _, bar in ipairs(bars) do
        if bar.def.spellIDs[spellID] then return bar end
    end
end

-- seconds per countdown for a fresh cast, talent multiplier applied
local function castLengths(bar)
    local def = bar.def
    -- a learned duration (read off the real aura) wins over the assumed one
    if type(def.seconds) == "number" then
        return { (def.learnKey and db[def.learnKey]) or def.seconds }
    end
    local mult = (def.multKey and db[def.multKey]) or 1
    local lengths = {}
    for i = 1, PIP_COUNT do lengths[i] = def.seconds[i] * mult end
    return lengths
end

local function onCastSent(spellID)
    if barForSpell(spellID) then
        pendingCP = GetComboPoints("player", "target")
    end
end

-- ---------------------------------------------------------------- per-target bars
-- A debuff belongs to the mob it was cast on, not to us, so those bars keep one countdown per
-- target GUID: casting on a second mob does not wipe the first, and changing target swaps
-- which countdown is on screen. GUIDs are plain values and usable as table keys even in
-- combat, unlike the combo point count.
--
-- Limitation worth knowing: a miss, dodge, resist or dispel cannot be seen in combat, because
-- debuffs are unreadable there. The bar will happily count down a debuff that never landed.
local function pruneExpired(bar, now)
    for guid, entry in pairs(bar.byGuid) do
        local longest = 0
        for _, len in ipairs(entry.lengths) do
            if len > longest then longest = len end
        end
        if now > entry.start + longest then bar.byGuid[guid] = nil end
    end
end

local function barShowForTarget(bar)
    local guid = UnitGUID("target")
    local entry = guid and bar.byGuid[guid]
    if entry then
        barStart(bar, entry.start, entry.lengths, entry.open or PIP_COUNT)
    else
        barStop(bar)
    end
end

local function refreshTargetBars()
    local now = GetTime()
    for _, bar in ipairs(bars) do
        if bar.def.perTarget then
            pruneExpired(bar, now)
            barShowForTarget(bar)
        end
    end
end

local function onCastSucceeded(spellID)
    local bar = barForSpell(spellID)
    if not bar then return end
    local cp = pendingCP or GetComboPoints("player", "target") or 0
    pendingCP = nil

    if bar.def.perTarget then
        local guid = UnitGUID("target")
        if not guid then return end   -- nothing to attach the timer to
        bar.byGuid[guid] = { start = GetTime(), lengths = castLengths(bar), open = cp }
        barShowForTarget(bar)
    else
        barStart(bar, GetTime(), castLengths(bar), cp)
    end
end

-- Only callable while auras are readable (out of combat); throws otherwise.
local function findAura(bar)
    for i = 1, 40 do
        local aura = C_UnitAuras.GetBuffDataByIndex(bar.def.unit, i)
        if not aura then return nil end
        local id = aura.spellId
        if isReadable(id) and bar.def.spellIDs[id] then return aura end
    end
end

local function syncBar(bar)
    local ok, aura = pcall(findAura, bar)
    if not ok then return end
    if not aura then
        if bar.start then barStop(bar) end
        return
    end
    local exp, dur = aura.expirationTime, aura.duration
    if not (isReadable(exp) and isReadable(dur)) or dur <= 0 then return end

    local def = bar.def
    -- learn the talent multiplier from the aura's full (5 combo point) duration
    if def.multKey and type(def.seconds) == "table" then
        local okB, base = pcall(C_UnitAuras.GetAuraBaseDuration, def.unit, aura.auraInstanceID)
        if okB and isReadable(base) and base > 0 then
            db[def.multKey] = base / def.seconds[PIP_COUNT]
        end
    end

    -- the real duration is known, so every countdown gets it and every gate is opened
    local lengths = {}
    for i = 1, #bar.timers do lengths[i] = dur end
    barStart(bar, exp - dur, lengths, PIP_COUNT)
end

-- Replace the cast-based estimate with the real aura whenever the client lets us see it.
-- Per-target bars sit this out: reading a debuff off the target needs aura APIs that have not
-- been verified on this client, and a half-working sync would fight the cast timer. Their
-- countdowns stay cast-driven for now.
local function syncFromBuff()
    if aurasHidden() then return end
    for _, bar in ipairs(bars) do
        if not bar.def.perTarget then syncBar(bar) end
    end
end

-- ---------------------------------------------------------------- the combat log is closed
-- Settled 2026-09-30: registering COMBAT_LOG_EVENT_UNFILTERED raises ADDON_ACTION_FORBIDDEN -
-- it is a *protected* event here, not merely a silent one. Do not try again, and do not
-- re-add a watcher to check; the attempt itself taints the addon and errors on every load.
--
-- This is the secret-value system working as designed. The combat log is the largest possible
-- side channel for hidden combat state, so it is closed to addons outright.
--
-- The consequence worth knowing: UNIT_SPELLCAST_SUCCEEDED means the ability went off, not
-- that it connected. A dodged or parried finisher still spends energy and combo points, so a
-- countdown starts for a debuff that never landed, and nothing in combat can tell us
-- otherwise. Correcting that has to wait until combat ends and auras are readable again.

-- ---------------------------------------------------------------- /cut check
-- The debuff durations and rank spell IDs the bars are built on are assumptions. Out of
-- combat the real values are readable, so this dumps whatever is on the target: if a rank ID
-- is wrong the spell shows up here with its real one, and the duration is right beside it.
-- Results also go to CutthroatDB.probe, which survives to the next reload.
local function probeTarget()
    if not UnitExists("target") then
        print(PREFIX .. "no target - target something with the debuff on it.")
        return
    end
    if aurasHidden() then
        print(PREFIX .. "auras are hidden in combat. Step out of combat and try again " ..
                        "while the debuff is still ticking.")
        return
    end

    local out = { when = date("%H:%M:%S"), target = UnitName("target"), rows = {} }
    local function say(s)
        print("   " .. s)
        out.rows[#out.rows + 1] = s
    end
    print(PREFIX .. "aura probe:")
    say("combat=" .. tostring(InCombatLockdown()) .. "  aurasHidden=" .. tostring(aurasHidden()))

    -- what this client actually offers, rather than what we assume it does
    local okList, names = pcall(function()
        local t = {}
        for k, v in pairs(C_UnitAuras) do
            if type(v) == "function" then t[#t + 1] = k end
        end
        table.sort(t)
        return t
    end)
    say("C_UnitAuras: " .. (okList and table.concat(names, ", ") or "<could not list>"))

    -- walk one aura source and report what came back; player buffs are the control, since
    -- those are known to work out of combat
    local function walk(label, fn)
        local n, first = 0, nil
        for i = 1, 40 do
            local ok, a = pcall(fn, i)
            if not ok then say(label .. ": ERROR " .. tostring(a)); return end
            if not a then break end
            n = n + 1
            local id = a.spellId
            local bar = isReadable(id) and barForSpell(id)
            local row = string.format("%s id=%s dur=%s%s", tostring(a.name), tostring(id),
                tostring(a.duration), bar and ("  <- " .. bar.def.label) or "")
            if n <= 6 then say("    " .. row) end
            first = first or row
        end
        say(label .. ": " .. n .. " found")
    end

    walk("player buffs (control)", function(i) return C_UnitAuras.GetBuffDataByIndex("player", i) end)
    if C_UnitAuras.GetDebuffDataByIndex then
        walk("target debuffs", function(i) return C_UnitAuras.GetDebuffDataByIndex("target", i) end)
    else
        say("target debuffs: GetDebuffDataByIndex does not exist")
    end
    if C_UnitAuras.GetAuraDataByIndex then
        walk("target HARMFUL", function(i) return C_UnitAuras.GetAuraDataByIndex("target", i, "HARMFUL") end)
    else
        say("target HARMFUL: GetAuraDataByIndex does not exist")
    end
    if C_UnitAuras.GetBuffDataByIndex then
        walk("target buffs", function(i) return C_UnitAuras.GetBuffDataByIndex("target", i) end)
    end

    say("combat log: protected on this client (registering it raises ADDON_ACTION_FORBIDDEN)")

    db.probe = out
    print(PREFIX .. "saved to CutthroatDB.probe (written on /reload or logout).")
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
    applyPipGhosts()
    refreshBarVisibility()
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
            + (db.showPips and 0 or 80) + (db.barLayout == "horizontal" and 160 or 0)
            + (db.alwaysShowPips and 320 or 0),
        math.floor(db.scale * 100 + 0.5))
    store:SetUserPlaced(true)
end

-- Takes lock/shape/scale from the layout cache once WoW has restored the helper frame.
local function readStore()
    if storeRead or not db or store:GetNumPoints() == 0 then return end
    local _, _, _, x, y = store:GetPoint(1)
    if not (x and y) then return end
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)

    -- unpack largest flag first:
    -- 100 + index (+20 locked, +40 pips above, +80 pips hidden, +160 side by side,
    -- +320 empty pips shown)
    local index, locked, onTop, showPips, horiz, sockets
    if x >= 100 then
        local rest = x - 100
        sockets = rest > 320
        if sockets then rest = rest - 320 end
        horiz = rest > 160
        if horiz then rest = rest - 160 end
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
        index, showPips, horiz, sockets = rest, true, false, false
    else
        return
    end

    local shape, scale = SHAPES[index], y / 100
    if not shape or scale < SCALE_MIN or scale > SCALE_MAX then return end
    storeRead = true
    db.pipShape, db.locked, db.scale, db.pipsOnTop, db.showPips =
        shape, locked, scale, onTop, showPips
    db.barLayout = horiz and "horizontal" or "vertical"
    db.alwaysShowPips = sockets
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
        ensureBarSettings()
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
        refreshTargetBars()   -- a new target has its own debuff timers, or none
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

-- The slash commands predate per-bar sizing and have no bar to aim at, so they set every
-- bar. Per-bar sizing lives in the settings panel.
local function setAllBars(w, h)
    for _, def in ipairs(BAR_DEFS) do
        local s = db.bars and db.bars[def.key]
        if s then
            if w then s.w = w end
            if h then s.h = h end
        end
    end
    applySize()
    if panel and panel:IsShown() then panel.refresh() end
end

local function setBarWidth(w)  setAllBars(w, nil) end
local function setBarHeight(h) setAllBars(nil, h) end

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

local function setBarSize(key, w, h)
    local s = db.bars and db.bars[key]
    if not s then return end
    if w then s.w = w end
    if h then s.h = h end
    applySize()
    if panel and panel:IsShown() then panel.refresh() end
end

local function setBarEnabled(key, on)
    local s = db.bars and db.bars[key]
    if not s then return end
    s.on = on
    applySize()
    refreshBarVisibility()
    if panel and panel:IsShown() then panel.refresh() end
end

local function setAlwaysShowPips(on)
    db.alwaysShowPips = on
    applyPipGhosts()
    writeStore()
    if panel and panel:IsShown() then panel.refresh() end
end

local function setBarLayout(mode)
    db.barLayout = mode
    applySize()
    writeStore()
    if panel and panel:IsShown() then panel.refresh() end
end

-- delta -1 moves the bar up the stack, +1 down
local function moveBar(key, delta)
    local order = db.barOrder
    for i, k in ipairs(order) do
        if k == key then
            local j = i + delta
            if j < 1 or j > #order then return end
            order[i], order[j] = order[j], order[i]
            applySize()
            if panel and panel:IsShown() then panel.refresh() end
            return
        end
    end
end

local function setShowPips(show)
    db.showPips = show
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
    db.scale, db.pipSize = 1, 1
    for _, def in ipairs(BAR_DEFS) do
        local s = db.bars and db.bars[def.key]
        if s then s.w, s.h = 1, 1 end
    end
    applyPosition()
    applySize()
    writeStore()
    if panel and panel:IsShown() then panel.refresh() end
end

local function makeButton(parent, label, width, onClick, height)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, height or 22)
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
    p:SetSize(PANEL_W, 468)   -- height is recomputed below, once the sections are laid out
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

    -- ---- Timer bars ----
    -- One row per bar: reorder arrows, the name (click to select it), and an on/off toggle.
    -- The two sliders underneath act on whichever bar is selected - a width and a height
    -- slider on every row would never fit at this width. Rows are positional: row i shows
    -- whatever bar currently sits at that place in db.barOrder, so reordering just relabels
    -- them. Offsets are derived from the bar count so another bar does not break the layout.
    local ROW_H, nBars = 24, #BAR_DEFS
    local layoutY    = -150
    local rowsTop    = layoutY - 30
    local wSliderY   = rowsTop - nBars * ROW_H - 12
    local hSliderY   = wSliderY - 30
    local barsBottom = hSliderY - 24

    sectionHeader(p, -128, "TIMER BARS")
    sectionBox(p, -142, barsBottom)

    local dirLabel = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    dirLabel:SetPoint("TOPLEFT", IN, layoutY)
    dirLabel:SetText("Layout")
    local dirButton = makeButton(p, "", 142, function()
        setBarLayout(horizontal() and "vertical" or "horizontal")
    end)
    dirButton:SetPoint("TOPRIGHT", -IN, layoutY + 4)

    local selectedBar = BAR_DEFS[1].key
    local barRows = {}
    for i = 1, nBars do
        local y, row = rowsTop - (i - 1) * ROW_H, {}
        row.up = makeButton(p, "^", 16, function() moveBar(row.key, -1) end, 18)
        row.up:SetPoint("TOPLEFT", IN, y)
        row.down = makeButton(p, "v", 16, function() moveBar(row.key, 1) end, 18)
        row.down:SetPoint("TOPLEFT", IN + 18, y)
        row.name = makeButton(p, "", 128, function()
            selectedBar = row.key
            p.refresh()
        end, 18)
        row.name:SetPoint("TOPLEFT", IN + 38, y)
        row.sel = row.name:CreateTexture(nil, "BORDER")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(0.30, 0.38, 0.68, 0.75)
        row.toggle = makeButton(p, "", 56, function()
            local s = db.bars and db.bars[row.key]
            if s then setBarEnabled(row.key, not s.on) end
        end, 18)
        row.toggle:SetPoint("TOPRIGHT", -IN, y)
        barRows[i] = row
    end

    local barWidthSlider = makeSlider(p, wSliderY, SIZE_MIN, SIZE_MAX, SIZE_STEP, "Width  %.2f", function(v)
        local s = db.bars and db.bars[selectedBar]
        if s and math.abs(v - s.w) > 0.001 then setBarSize(selectedBar, v, nil) end
    end, IN)
    local barHeightSlider = makeSlider(p, hSliderY, SIZE_MIN, SIZE_MAX, SIZE_STEP, "Height  %.2f", function(v)
        local s = db.bars and db.bars[selectedBar]
        if s and math.abs(v - s.h) > 0.001 then setBarSize(selectedBar, nil, v) end
    end, IN)

    -- ---- Combo points ----
    local comboTop    = barsBottom - 26
    local pipSizeY    = comboTop - 8
    local emptyY      = pipSizeY - 34
    local placementY  = emptyY - 30
    local shapeY      = placementY - 24
    local gridTop     = shapeY - 18
    local comboBottom = gridTop - 2 * 28 - 8

    sectionHeader(p, barsBottom - 12, "COMBO POINTS")
    -- Pip visibility. It was folded into Placement at first and nobody could find it, so it
    -- gets its own control - parked in the empty space beside the bottom row of shape
    -- buttons (the grid ends at x=194, the content edge is 260), which costs no extra height.
    local showButton = makeButton(p, "", 58, function() setShowPips(not db.showPips) end)
    showButton:SetPoint("TOPRIGHT", -IN, gridTop - 29)
    sectionBox(p, comboTop, comboBottom)
    local pipSizeSlider = makeSlider(p, pipSizeY, SIZE_MIN, SIZE_MAX, SIZE_STEP, "Pip size  %.2f", function(v)
        if math.abs(v - db.pipSize) > 0.001 then db.pipSize = v; applySize() end
    end, IN)

    -- pip shape: one icon button per shape
    local shapeLabel = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    shapeLabel:SetPoint("TOPLEFT", IN, shapeY)
    shapeLabel:SetText("Shape")
    local shapeButtons = {}
    local SHAPE_COLS = 6   -- 6 x 30px = 180px, comfortably inside the 252px content width
    for idx, shape in ipairs(SHAPES) do
        local row = math.floor((idx - 1) / SHAPE_COLS)
        local col = (idx - 1) % SHAPE_COLS
        local b = CreateFrame("Button", nil, p)
        b:SetSize(24, 24)
        b:SetPoint("TOPLEFT", IN + col * 30, gridTop - row * 28)
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
    local emptyLabel = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    emptyLabel:SetPoint("TOPLEFT", IN, emptyY)
    emptyLabel:SetText("Empty pips")
    local emptyButton = makeButton(p, "", 142, function()
        setAlwaysShowPips(not db.alwaysShowPips)
    end)
    emptyButton:SetPoint("TOPRIGHT", -IN, emptyY + 4)

    layoutLabel:SetPoint("TOPLEFT", IN, placementY)
    layoutLabel:SetText("Placement")
    local layoutButton = makeButton(p, "", 142, function() setPipsOnTop(not db.pipsOnTop) end)
    layoutButton:SetPoint("TOPRIGHT", -IN, placementY + 4)

    -- reset
    local resetButton = makeButton(p, "Reset size and position", 252, resetPosition)
    resetButton:SetPoint("TOPLEFT", 14, comboBottom - 16)

    -- read-only info
    local info = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    info:SetPoint("TOPLEFT", 14, comboBottom - 48)
    -- now that the sections know their own heights, size the panel to fit them
    p:SetSize(PANEL_W, -comboBottom + 94)
    info:SetPoint("RIGHT", -14, 0)
    info:SetJustifyH("LEFT")

    function p.refresh()
        lockButton.text:SetText(db.locked and "Locked" or "Unlocked (drag the bar)")
        scaleSlider:SetValue(db.scale)
        scaleSlider.label:SetFormattedText("Scale  %.2f", db.scale)
        dirButton.text:SetText(horizontal() and "Side by side" or "Stacked")
        -- rows are positional, so relabel each one from the current order
        for i, row in ipairs(barRows) do
            local key = db.barOrder and db.barOrder[i]
            row.key = key
            local bar = key and barsByKey[key]
            if bar then
                local s = db.bars[key]
                row.name.text:SetText(bar.def.label)
                row.toggle.text:SetText(s.on and "On" or "Off")
                row.name:SetAlpha(s.on and 1 or 0.45)
                row.sel:SetShown(key == selectedBar)
                row.up:SetShown(i > 1)
                row.down:SetShown(i < #barRows)
            end
        end
        local sel = db.bars and db.bars[selectedBar]
        if sel then
            barWidthSlider:SetValue(sel.w)
            barWidthSlider.label:SetFormattedText("Width  %.2f", sel.w)
            barHeightSlider:SetValue(sel.h)
            barHeightSlider.label:SetFormattedText("Height  %.2f", sel.h)
        end
        pipSizeSlider:SetValue(db.pipSize)
        pipSizeSlider.label:SetFormattedText("Pip size  %.2f", db.pipSize)
        for shape, b in pairs(shapeButtons) do b.selected:SetShown(shape == db.pipShape) end
        -- standalone button with no label beside it, so it names the action rather than the
        -- state: "Hide" while the pips are showing, "Show" while they are hidden
        showButton.text:SetText(db.showPips and "Hide" or "Show")
        layoutButton.text:SetText(db.pipsOnTop and "Above the bar" or "Below the bar")
        emptyButton.text:SetText(db.alwaysShowPips and "Always shown" or "Hidden until earned")
        -- nothing else in this section does anything while the pips are hidden
        local lit = db.showPips and 1 or 0.3
        pipSizeSlider:SetAlpha(lit);  pipSizeSlider:EnableMouse(db.showPips)
        emptyButton:SetAlpha(lit);    emptyButton:EnableMouse(db.showPips)
        emptyLabel:SetAlpha(lit)
        layoutButton:SetAlpha(lit);   layoutButton:EnableMouse(db.showPips)
        layoutLabel:SetAlpha(lit)
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
            print(PREFIX .. "the typed commands still work: /cut lock | unlock | reset | scale <n> | barwidth <n> | barheight <n> | pipsize <n> | pips above|below|show|hide|empty")
        end
    elseif cmd == "lock" then
        setLocked(true)
        print(PREFIX .. "locked.")
    elseif cmd == "unlock" then
        setLocked(false)
        print(PREFIX .. "unlocked. Drag it where you like, then /cut lock")
    elseif cmd == "check" then
        probeTarget()
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
        elseif arg == "empty" then
            setAlwaysShowPips(not db.alwaysShowPips)
            print(PREFIX .. (db.alwaysShowPips
                and "empty combo points always shown."
                or  "combo points appear as they are earned."))
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
        print(PREFIX .. "/cut opens settings. Also: /cut lock | unlock | reset | scale | barwidth | barheight | pipsize <0.5-3> | shape <name> | pips above|below|show|hide|empty")
    end
end
