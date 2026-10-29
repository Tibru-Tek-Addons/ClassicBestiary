local _, CB = ...
local L = CB.L
local db = CB.db
local structuredTooltips = TooltipDataProcessor ~= nil
local unitHideStatus

-- Rendering helpers use a synchronous context; lifetime and pending loads belong
-- to each tooltip, so the options preview cannot disturb the live unit tooltip.
local states = {}
local current
local textChanged

-- One budget for all tooltips. Native calls cannot be preempted, so their
-- inputs are bounded too; diagnostic trees cannot grow a giant tooltip.
local FRAME_SECONDS, FRAME_STEPS = 0.002, 512
local MAX_ROWS, MAX_TEXT = 200, 2048
local ROW_LIMIT = {}
local scheduler
local queue, head, tail = {}, 1, 0
local steps, deadline

local function enqueue(state)
    if not state.queued then
        tail = tail + 1
        queue[tail], state.queued = state, true
    end
    scheduler:Show()
end

local function checkpoint()
    if states[current.tooltip] ~= current then error(ROW_LIMIT, 0) end
    steps = steps + 1
    if steps >= FRAME_STEPS or GetTimePreciseSec() >= deadline then coroutine.yield() end
end

local function clear(tooltip)
    local state = states[tooltip]
    if not state then return end
    states[tooltip] = nil
    for _, owned in pairs(state.lines) do
        if owned.compact then owned.fontString:SetNonSpaceWrap(owned.nonSpaceWrap) end
    end
    for _, cancel in pairs(state.cancels) do cancel() end
    state.worker, state.mechanics = nil, nil
end

local function style(fontString, body, text, compact)
    fontString:SetFont(body:GetFont())
    fontString:SetTextScale(body == GameTooltipText and 1 or body:GetTextScale())
    fontString:SetSpacing(body:GetSpacing())
    fontString:SetWordWrap(true)
    if compact then fontString:SetNonSpaceWrap(false) end
    fontString:SetText(text)
end

local function boundedText(text)
    if #text <= MAX_TEXT then return text end
    local last = MAX_TEXT - 9
    -- Do not cut a localized UTF-8 character in half.
    for _ = 1, 3 do
        local byte = text:byte(last + 1)
        if byte < 128 or byte > 191 then break end
        last = last - 1
    end
    return text:sub(1, last) .. "...|w|r"
end

local function line(text, muted, right, compact)
    checkpoint()
    local limit = current.rows >= MAX_ROWS
    if limit then text, muted, right, compact = L.DETAILS_LIMIT, true, nil, nil end
    text = boundedText(text)
    if right then right = boundedText(right) end
    local shade = muted and 0.65 or 0.9
    local tooltip = current.tooltip
    if right and right ~= "" then
        tooltip:AddDoubleLine(text, right, shade, shade, shade, shade, shade, shade)
    else
        tooltip:AddLine(text, shade, shade, shade, true)
        right = nil
    end
    local index = tooltip:NumLines()
    local fontString = tooltip:GetLeftLine(index)
    local owned = { left = text, right = right, compact = compact }
    if compact then owned.fontString, owned.nonSpaceWrap = fontString, fontString:CanNonSpaceWrap() end
    style(fontString, current.body, text, compact)
    if right then style(tooltip:GetRightLine(index), current.body, right) end
    current.lines[index], current.lastLine = owned, index
    current.rows = current.rows + 1
    if limit then error(ROW_LIMIT, 0) end
end

local function finiteDuration(milliseconds)
    if milliseconds <= 99000 then return string.format(L.DURATION_FINITE, milliseconds / 1000) end
    local minutes = math.floor(milliseconds / 60000)
    local seconds = (milliseconds - minutes * 60000) / 1000
    if seconds == 0 then return string.format(L.DURATION_MINUTES, minutes) end
    return string.format(L.DURATION_MINUTES_SECONDS, minutes, seconds)
end

local function duration(record)
    if not record then return nil end
    local kind = db.k.d[record.k]
    if kind == "permanent" then return L.DURATION_PERMANENT end
    if kind == "finite" then return finiteDuration(record.v) end
    if kind == "range" then
        if record.h <= 99000 then return string.format(L.DURATION_RANGE, record.l / 1000, record.h / 1000) end
        if record.l > 99000 and record.l % 60000 == 0 and record.h % 60000 == 0 then
            return string.format(L.DURATION_MINUTE_RANGE, record.l / 60000, record.h / 60000)
        end
        return string.format(L.DURATION_MIXED_RANGE, finiteDuration(record.l), finiteDuration(record.h))
    end
    -- Unknown and not-applicable are not finite zero.
end

local function durationIdentity(record)
    if not record then return nil end
    local kind = db.k.d[record.k]
    if kind == "finite" then return string.format("finite:%.17g", record.v) end
    if kind == "range" then return string.format("range:%.17g:%.17g", record.l, record.h) end
    if kind == "permanent" then return kind end
end

local function displayedNPC(tooltip)
    if structuredTooltips then
        local data = tooltip:GetPrimaryTooltipData()
        if not data or data.type ~= Enum.TooltipDataType.Unit then return nil end
        local id = CB.API.ResolveGUID(data.guid)
        return id, data
    end
    local _, unit = tooltip:GetUnit()
    local id = CB.API.ResolveUnit(unit)
    return id, unit
end

local function refreshUnitTooltip()
    if not GameTooltip:IsShown() then return end
    local id, primary = displayedNPC(GameTooltip)
    local state = states[GameTooltip]
    if id and (state or CB.config.enabled) then
        local hideStatus = unitHideStatus
        -- Stop the old job before rebuilding the displayed unit, never mouseover.
        clear(GameTooltip)
        if structuredTooltips then
            GameTooltip:RefreshDataNextUpdate()
        else
            GameTooltip:SetUnit(primary, hideStatus)
        end
    end
end

function CB.RefreshTooltip()
    refreshUnitTooltip()
    if CB.RefreshPreview then CB.RefreshPreview() end
end

local function requestSpell(id)
    local state = current
    if state.cancels[id] or not C_Spell.DoesSpellExist(id) or C_Spell.IsSpellDataCached(id) then return end
    local spell = Spell:CreateFromSpellID(id)
    state.cancels[id] = spell:ContinueWithCancelOnSpellLoad(function()
        if states[state.tooltip] == state then textChanged(state) end
    end)
end

local function spellIcon(info)
    if not info or not info.iconID then return "" end
    -- Zero dimensions track the final font, including later tooltip skin passes.
    return string.format("|T%d:0:0:0:0|t ", info.iconID)
end
local function spellName(id, hideIDs)
    current.spells[id] = true
    local info = C_Spell.GetSpellInfo(id)
    if info and info.name then
        local icon = spellIcon(info)
        local debugID = CB.config.debugIDs and not hideIDs and string.format(L.DEBUG_SPELL_ID, id) or ""
        return icon .. info.name .. debugID
    end
    requestSpell(id)
    if CB.config.debugDetails then
        if C_Spell.DoesSpellExist(id) then return string.format(L.SPELL_PENDING, id) end
        return string.format(L.SPELL_UNAVAILABLE, id)
    end
    return L.ABILITY_NAME .. (CB.config.debugIDs and not hideIDs and string.format(L.DEBUG_SPELL_ID, id) or "")
end

local function description(id, indent, unverified)
    -- Put uncertainty in the indentation slot, never in the ability/effect name.
    local prefix = unverified and indent:sub(1, -3) .. L.UNVERIFIED_MARKER or indent
    -- Uncached descriptions use the cancellable async request below.
    local text = C_Spell.DoesSpellExist(id) and C_Spell.IsSpellDataCached(id)
        and C_Spell.GetSpellDescription(id) or nil
    if text and text ~= "" then
        line(prefix .. text, true)
    else
        requestSpell(id)
        if CB.config.debugDetails then line(prefix .. L.DESCRIPTION_PENDING, true)
        elseif unverified then line(prefix .. L.UNVERIFIED_VARIANT, true) end
    end
end

local immunitySchools = { "physical", "holy", "fire", "nature", "frost", "shadow", "arcane" }
local function effectLabel(token, mask)
    if token == "school_immunity" and mask then
        if mask == 127 then return L.effect_immunity end
        if mask == 1 then return L.effect_physical_immunity end
        if mask == 126 then return L.effect_magic_immunity end
        local names, bit = {}, 1
        for _, school in ipairs(immunitySchools) do
            if mask % (bit * 2) >= bit then names[#names + 1] = L["school_" .. school] end
            bit = bit * 2
        end
        return string.format(L.SCHOOL_IMMUNITY, table.concat(names, "/"))
    end
    return rawget(L, "effect_" .. token) or token
end

local function effectParts(effect, detailed, omitDuration)
    local text = effectLabel(effect.token, effect.schoolMask)
    local tags = {}
    for _, tag in ipairs(effect.targeting or {}) do tags[tag] = true end
    local cleave = effect.token == "damage" and tags.cleave
    -- Colloquial maintained group aura, not the generic low-level aura scope.
    local aura = tags.group_aura and effect.areaAura and effect.durationKind == "permanent"
    if cleave then text = L.effect_cleave end
    if detailed and effect.token == "extra_attacks" and effect.value then
        text = string.format("%g %s", effect.value, text)
    end
    if effect.timing and not aura and not omitDuration then text = string.format(L.EFFECT_DURATION, text, effect.timing) end
    local qualifiers = {}
    if effect.ranged then qualifiers[#qualifiers + 1] = "ranged" end
    for _, tag in ipairs(effect.targeting or {}) do
        local redundant = (tag == "cleave" and cleave)
            or (tag == "aoe" and (tags.cone or tags.line or tags.rectangle or tags.cleave))
            or (tag == "chain" and tags.cleave)
            or (tag == "multi_target" and (tags.aoe or tags.cone or tags.line or tags.rectangle or tags.chain or tags.cleave))
        if not redundant then qualifiers[#qualifiers + 1] = (tag == "group_aura" and aura) and "aura" or tag end
    end
    return qualifiers, text, not aura and effect.timing or nil
end

local function qualified(qualifiers, text, pair)
    local words, aura = {}, false
    for _, tag in ipairs(qualifiers) do
        if tag == "aura" then aura = true
        else words[#words + 1] = rawget(L, "target_" .. tag) or tag end
    end
    if aura then text = string.format(pair and L.EFFECT_AURA_PAIR or L.EFFECT_AURA, text) end
    if #words == 0 then return text end
    return string.format(L.EFFECT_QUALIFIED, table.concat(words, " "), text)
end

local function effectText(effect, detailed)
    local qualifiers, text = effectParts(effect, detailed)
    return qualified(qualifiers, text)
end

local function effectKey(effect, ranged)
    if ranged == nil then ranged = effect.ranged end
    return effect.token .. (ranged and ":ranged:" or ":local:") .. effect.targetKey
        .. (effect.schoolMask and ":schools:" .. effect.schoolMask or "")
end

local function rangedEffect(spell, effect)
    local properties = spell.p
    local targets = effect.x and effect.x.t
    -- Qualify only an explicit enemy-target effect. Self/area/unknown targets
    -- do not inherit an unrelated hostile or friendly cast range.
    if not properties or properties.dt == 2 or not targets or targets[1] ~= 6
        or (targets[2] ~= 0 and targets[2] ~= 6) then return false end
    -- SpellRange flag 0x1 uses combat reach, not a fixed ranged cast distance.
    if properties.rf and properties.rf % 2 == 1 then return false end
    local maximum, minimum = properties.rh, properties.rl
    return maximum ~= nil and maximum > 5
        and (minimum == nil or (minimum >= 0 and minimum <= maximum))
end

-- Shared by ability profiles, effect summaries and expanded child siblings.
local priorities = { school_immunity = -1, interrupt = 0, stun = 1, knockback = 1, fear = 2, charm = 3, confuse = 4, silence = 5,
    pacify_silence = 6, pacify = 7, root = 8, disarm = 9, snare = 10, taunt = 11,
    attack_slow = 12, cast_slow = 13, armor_reduction = 14, damage_taken_increase = 15,
    healing_reduction = 16, extra_attacks = 29, damage = 30, periodic_damage = 31,
    heal = 20, periodic_heal = 21, armor_increase = 22, damage_taken_reduction = 23,
    healing_increase = 24, thorns = 24, attack_haste = 25, cast_haste = 26, movement_speed_increase = 27,
    summon = 28, instant_kill = 1, pull = 1, dispel = 12, dispel_mechanic = 12,
    remove_aura = 14, resource_drain = 17, resource_burn = 17, threat_change = 17,
    health_leech = 30, periodic_health_leech = 31, proc_damage = 30, attack = 30,
    force_cast = 28, leap = 27, jump = 27, charge = 27, teleport = 27,
    damage_absorb = 20, healing_absorb = 16, mana_shield = 20, spell_reflect = 20,
    effect_immunity = -1, aura_immunity = -1, damage_immunity = -1, dispel_immunity = -1,
    mechanic_immunity = -1, ability_only_casting = 5, prevents_fleeing = 8,
    feign_death = 11, force_deselect = 11, unattackable = -1, interrupt_regeneration = 16,
    periodic_resource_leech = 17, periodic_resource_burn = 17, resource_gain = 24,
    periodic_resource_gain = 24, resistance_reduction = 14, resistance_increase = 22,
    damage_done_reduction = 15, damage_done_increase = 24, stat_reduction = 15, stat_increase = 24,
    attack_power_reduction = 15, attack_power_increase = 24, max_health_reduction = 15,
    max_health_increase = 24, resource_cost_increase = 16, resource_cost_reduction = 24,
    threat_reduction = 17, threat_increase = 17, damage_split = 23, sanctuary = 23,
    stealth = 27, invisibility = 27, stealth_detection = 27, invisibility_detection = 27,
    transform = 27, shapeshift = 27 }
local auraScopes = { aura = true, persistent_area = true, party_area = true,
    raid_area = true, pet_area = true, friendly_area = true, enemy_area = true, owner_area = true }
local groupAuraScopes = { party_area = true, raid_area = true, pet_area = true,
    friendly_area = true, owner_area = true }

local function validSchoolMask(mask)
    return type(mask) == "number" and mask > 0 and mask <= 127 and mask % 1 == 0
end

local function immunityMask(spell, effect, lifetime)
    local mask = effect.x and effect.x.v and effect.x.v[1]
    if not validSchoolMask(mask) then return nil end
    local targets = effect.x.t
    local kind = lifetime and db.k.d[lifetime.k]
    if not targets or (kind ~= "finite" and kind ~= "permanent" and kind ~= "range") then return mask end
    -- Combine only schools declared by this spell for the same explicit targets,
    -- aura scope and known duration. Never union different abilities or children.
    for _, other in ipairs(spell.e) do
        checkpoint()
        if db.k.e[other.t] == "school_immunity" and other.s == effect.s then
            local details = other.x
            local otherTargets = details and details.t
            local otherMask = details and details.v and details.v[1]
            local otherLifetime = other.d or spell.d
            if validSchoolMask(otherMask) and otherTargets
                and targets[1] == otherTargets[1] and targets[2] == otherTargets[2]
                and otherLifetime and lifetime.k == otherLifetime.k
                and lifetime.v == otherLifetime.v and lifetime.l == otherLifetime.l and lifetime.h == otherLifetime.h then
                local bit = 1
                while bit <= 64 do
                    if otherMask % (bit * 2) >= bit and mask % (bit * 2) < bit then mask = mask + bit end
                    bit = bit * 2
                end
            end
        end
    end
    return mask
end

local function effectLess(a, b)
    local ap, bp = priorities[a.token] or 100, priorities[b.token] or 100
    if ap ~= bp then return ap < bp end
    if a.token ~= b.token then return a.token < b.token end
    if a.ranged ~= b.ranged then return not a.ranged end
    -- Special targeting precedes an otherwise identical ordinary effect.
    if a.targetKey == "" and b.targetKey ~= "" then return false end
    if b.targetKey == "" and a.targetKey ~= "" then return true end
    if a.targetKey ~= b.targetKey then return a.targetKey < b.targetKey end
    return (a.schoolMask or 0) < (b.schoolMask or 0)
end

local function sortedEffects(effects, compare)
    local result = {}
    for _, effect in pairs(effects) do result[#result + 1] = effect end
    table.sort(result, compare or effectLess)
    return result
end

local function mergeMechanic(effects, candidate, inherited, source)
    local ranged = candidate.ranged and not inherited
    local key = effectKey(candidate, ranged)
    local entry = effects[key]
    if not entry then
        entry = { token = candidate.token, timing = candidate.timing, timingKey = candidate.timingKey, durationKind = candidate.durationKind,
            value = candidate.value, schoolMask = candidate.schoolMask, ranged = ranged, areaAura = candidate.areaAura,
            targeting = candidate.targeting, targetKey = candidate.targetKey, spells = {} }
        effects[key] = entry
    else
        if entry.timingKey ~= candidate.timingKey then entry.timing, entry.timingKey = nil, nil end
        if entry.durationKind ~= candidate.durationKind then entry.durationKind = nil end
        if entry.value ~= candidate.value then entry.value = nil end
        entry.areaAura = entry.areaAura and candidate.areaAura
    end
    if source then entry.spells[source] = true else
        for id in pairs(candidate.spells) do checkpoint(); entry.spells[id] = true end
    end
end

local function ownMechanics(id)
    local cache = current.ownProfiles
    if cache[id] then return cache[id] end
    local effects = {}
    cache[id] = effects
    if CB.excludedSpells[id] then return effects end
    local spell = db.s[id]
    for _, effect in ipairs(spell and spell.e or {}) do
        checkpoint()
        local token = db.k.e[effect.t]
        if token and token ~= "unknown" and token ~= "trigger" then
            local scope = db.k.s[effect.s]
            -- Only the owning aura supplies an inherited duration.
            local lifetime = effect.d or (auraScopes[scope] and spell.d or nil)
            local targeting = CB.effectTargeting[id]
            targeting = targeting and targeting[effect.i]
            mergeMechanic(effects, { token = token, timing = duration(lifetime),
                durationKind = lifetime and db.k.d[lifetime.k], timingKey = durationIdentity(lifetime),
                value = token == "extra_attacks" and effect.x
                    and db.k.u[effect.x.u] == "attacks" and effect.v or nil,
                schoolMask = token == "school_immunity" and immunityMask(spell, effect, lifetime) or nil,
                ranged = rangedEffect(spell, effect), areaAura = groupAuraScopes[scope],
                targeting = targeting, targetKey = targeting and table.concat(targeting, ":") or "",
                spells = { [id] = true } })
        end
    end
    return effects
end

local function rowMechanics(id, related)
    local own = ownMechanics(id)
    if not related then return own end
    local cache = current.childOwnProfiles
    if cache[id] then return cache[id] end
    local ranged = false
    for _, effect in pairs(own) do checkpoint(); if effect.ranged then ranged = true; break end end
    if not ranged then cache[id] = own; return own end
    local effects = {}
    for _, effect in pairs(own) do checkpoint(); mergeMechanic(effects, effect, true) end
    cache[id] = effects
    return effects
end
local function mechanics(id)
    local cache = current.mechanics
    if cache[id] then return cache[id] end
    if CB.excludedSpells[id] then
        cache[id] = {}; current.children[cache[id]] = {}; return cache[id]
    end
    -- Iterative Kosaraju: a cycle shares one complete profile; acyclic children
    -- are computed once, bottom-up. Cached subgraphs are immutable boundaries.
    -- This avoids walking each descendant's whole closure again for its row.
    local visited, order, reverse = { [id] = true }, {}, {}
    local stack = { { id = id, index = 1 } }
    while #stack > 0 do
        checkpoint()
        local frame = stack[#stack]
        local spell = db.s[frame.id]
        local child = spell and spell.r and spell.r[frame.index]
        if child then
            frame.index = frame.index + 1
            if not CB.excludedSpells[child.s] and not cache[child.s] then
                local parents = reverse[child.s]
                if not parents then parents = {}; reverse[child.s] = parents end
                parents[#parents + 1] = frame.id
                if not visited[child.s] then
                    visited[child.s] = true
                    stack[#stack + 1] = { id = child.s, index = 1 }
                end
            end
        else
            order[#order + 1] = frame.id
            stack[#stack] = nil
        end
    end
    local components, componentOf = {}, {}
    for index = #order, 1, -1 do
        checkpoint()
        local root = order[index]
        if not componentOf[root] then
            local component = {}
            components[#components + 1], componentOf[root] = component, component
            stack = { root }
            while #stack > 0 do
                checkpoint()
                local node = table.remove(stack)
                component[#component + 1] = node
                for _, parent in ipairs(reverse[node] or {}) do
                    checkpoint()
                    if not componentOf[parent] then
                        componentOf[parent] = component
                        stack[#stack + 1] = parent
                    end
                end
            end
        end
    end
    for index = #components, 1, -1 do
        local component, effects, merged = components[index], {}, {}
        local children = {}
        current.children[effects] = children
        for _, spellID in ipairs(component) do
            checkpoint()
            local spell = db.s[spellID]
            for _, effect in pairs(ownMechanics(spellID)) do checkpoint(); mergeMechanic(effects, effect) end
            for _, child in ipairs(spell and spell.r or {}) do
                checkpoint()
                if not CB.excludedSpells[child.s] and componentOf[child.s] ~= component then
                    local childEffects = cache[child.s]
                    if childEffects then children[childEffects] = true end
                    if childEffects and not merged[childEffects] then
                        merged[childEffects] = true
                        for _, effect in pairs(childEffects) do checkpoint(); mergeMechanic(effects, effect) end
                    end
                end
            end
        end
        for _, node in ipairs(component) do checkpoint(); cache[node] = effects end
    end
    return cache[id]
end

-- Child cast range does not establish a trigger's delivery reach. Project each
-- source's role without mutating the cached component used for root ownership.
local function displayMechanics(id)
    local cache = current.directProfiles
    if cache[id] then return cache[id] end
    local base = mechanics(id)
    local changed = false
    for _, effect in pairs(base) do
        checkpoint()
        if effect.ranged then
            for source in pairs(effect.spells) do
                checkpoint()
                if source ~= id then changed = true; break end
            end
        end
        if changed then break end
    end
    if not changed then cache[id] = base; return base end
    local effects = {}
    for _, effect in pairs(base) do
        checkpoint()
        if effect.ranged then
            for source in pairs(effect.spells) do
                checkpoint()
                mergeMechanic(effects, effect, source ~= id, source)
            end
        else
            mergeMechanic(effects, effect)
        end
    end
    cache[id] = effects
    return effects
end

local function sortEntries(entries)
    for _, entry in ipairs(entries) do checkpoint(); entry.order = sortedEffects(entry.effects) end
    table.sort(entries, function(a, b)
        local ao, bo = a.order, b.order
        -- Unsupported/absent mechanics have no profile and always go last.
        if #ao == 0 and #bo > 0 then return false end
        if #bo == 0 and #ao > 0 then return true end
        for index = 1, math.min(#ao, #bo) do
            if effectLess(ao[index], bo[index]) then return true end
            if effectLess(bo[index], ao[index]) then return false end
        end
        if #ao ~= #bo then return #ao < #bo end
        for index = 1, math.min(#a.ids, #b.ids) do
            if a.ids[index] ~= b.ids[index] then return a.ids[index] < b.ids[index] end
        end
        if #a.ids ~= #b.ids then return #a.ids < #b.ids end
        -- Duplicate child IDs can still have distinct declared relationship rows.
        local ar, br = a.relation, b.relation
        if not ar or not br then return false end
        local ak, bk = db.k.r[ar.k], db.k.r[br.k]
        if ak ~= bk then return ak < bk end
        if ar.e ~= br.e then return (ar.e or 0) < (br.e or 0) end
        return (ar.c or "") < (br.c or "")
    end)
end

local function presentation(npcID, abilityIDs)
    local groups, result, emitted = {}, {}, {}
    for _, group in ipairs(CB.abilityGroups[npcID] or {}) do
        checkpoint()
        for _, id in ipairs(group.ids) do checkpoint(); groups[id] = group end
    end
    for _, id in ipairs(abilityIDs) do
        checkpoint()
        local group = groups[id]
        if not group then
            result[#result + 1] = { ids = { id }, effects = mechanics(id) }
        elseif not emitted[group] then
            result[#result + 1] = { ids = group.ids, selected = group.selected, alternatives = group.alternatives, effects = mechanics(group.selected) }
            emitted[group] = true
        end
    end
    for _, entry in ipairs(result) do
        checkpoint()
        entry.component = entry.effects
        entry.effects = displayMechanics(entry.selected or entry.ids[1])
    end
    sortEntries(result)
    -- The mechanic cache already collapses cycles. Walk its component DAG once:
    -- a displayed ancestor owns its declared children, including transitive ones.
    local representatives, seen, indegrees, nodes = {}, {}, {}, {}
    for _, entry in ipairs(result) do
        checkpoint()
        local effects = entry.component
        if not representatives[effects] then representatives[effects] = entry end
        if not seen[effects] then
            seen[effects], indegrees[effects] = true, 0
            nodes[#nodes + 1] = effects
        end
    end
    local index = 1
    while index <= #nodes do
        checkpoint()
        local effects = nodes[index]
        for child in pairs(current.children[effects]) do
            checkpoint()
            indegrees[child] = (indegrees[child] or 0) + 1
            if not seen[child] then seen[child] = true; nodes[#nodes + 1] = child end
        end
        index = index + 1
    end
    local ready, covered = {}, {}
    for _, effects in ipairs(nodes) do
        checkpoint()
        if indegrees[effects] == 0 then ready[#ready + 1] = effects end
    end
    index = 1
    while index <= #ready do
        checkpoint()
        local effects = ready[index]
        for child in pairs(current.children[effects]) do
            checkpoint()
            if covered[effects] or representatives[effects] then covered[child] = true end
            indegrees[child] = indegrees[child] - 1
            if indegrees[child] == 0 then ready[#ready + 1] = child end
        end
        index = index + 1
    end
    local roots = {}
    for _, entry in ipairs(result) do
        checkpoint()
        if not covered[entry.component] and representatives[entry.component] == entry then
            roots[#roots + 1] = entry
        end
    end
    return roots
end

local function debugIDs(ids)
    if not CB.config.debugIDs then return "" end
    return string.format(L.DEBUG_SPELL_IDS, table.concat(ids, ", "))
end

local function entryName(entry, hideIDs)
    local name = spellName(entry.selected or entry.ids[1], hideIDs)
    if not entry.selected or #entry.ids == 1 or hideIDs or not CB.config.debugIDs then return name end
    return name .. string.format(L.DEBUG_CANDIDATES, table.concat(entry.ids, ", "))
end

-- Share exact known lifetimes after adjacent effects, without parentheses.
-- Group duration first; qualifier subgroups retain their own source roles.
local function formattedParts(parts)
    local common = parts[1].qualifiers
    local timing, timingKey = parts[1].timing, parts[1].timingKey
    for index = 2, #parts do
        checkpoint()
        local tags, shared = {}, {}
        for _, tag in ipairs(parts[index].qualifiers) do tags[tag] = true end
        for _, tag in ipairs(common) do if tags[tag] then shared[#shared + 1] = tag end end
        common = shared
        if timingKey ~= parts[index].timingKey then timing, timingKey = nil, nil end
    end
    local shared, groups, order = {}, {}, {}
    for _, tag in ipairs(common) do shared[tag] = true end
    for _, part in ipairs(parts) do
        checkpoint()
        local qualifiers = {}
        for _, tag in ipairs(part.qualifiers) do
            if not shared[tag] then qualifiers[#qualifiers + 1] = tag end
        end
        local partTiming, partKey = part.timing, part.timingKey
        if timingKey then partTiming, partKey = nil, nil end
        local key = partKey and "d:" .. partKey
            or qualifiers[1] and "q:" .. qualifiers[1] or "t:" .. part.text
        if not groups[key] then groups[key] = {}; order[#order + 1] = key end
        local group = groups[key]
        group[#group + 1] = { qualifiers = qualifiers, text = part.text, timing = partTiming, timingKey = partKey }
    end
    local labels, count = {}, 0
    for _, key in ipairs(order) do
        checkpoint()
        local group, text, terms = groups[key], nil, 0
        if not group[1].qualifiers[1] and not group[1].timingKey then
            text, terms = group[1].text, 1
        else
            text, terms = formattedParts(group)
        end
        labels[#labels + 1], count = text, count + terms
    end
    local text = labels[1]
    for index = 2, #labels do text = string.format(L.EFFECT_PAIR, text, labels[index]) end
    text = qualified(common, text, count > 1)
    if timing then
        text = string.format(L.EFFECT_DURATION, text, timing)
    end
    return text, count
end

local function combinedEffectList(effects, detailed)
    local parts = {}
    for index, effect in ipairs(effects) do
        checkpoint()
        local qualifiers, text, timing = effectParts(effect, detailed, true)
        parts[index] = { qualifiers = qualifiers, text = text, timing = timing,
            timingKey = timing and effect.timingKey or nil }
    end
    if #parts == 0 then return "" end
    local text = formattedParts(parts)
    return text
end

local function combinedEffects(first, second, detailed)
    local text = combinedEffectList({ first, second }, detailed)
    return #text <= 36 and text or nil
end

local function salient(effects)
    local first
    for _, effect in ipairs(sortedEffects(effects)) do
        if first then return combinedEffects(first, effect, true) or effectText(first, true) end
        first = effect
    end
    return first and effectText(first, true) or ""
end

local function spellDetails(id, indent)
    local spell = db.s[id]
    if not spell then return end
    if CB.config.debugDetails then
        local lifetime = duration(spell.d)
        if lifetime then line(indent .. string.format(L.SPELL_DURATION, lifetime), true) end
        for _, effect in ipairs(spell.e or {}) do
            local token = db.k.e[effect.t]
            local scope = db.k.s[effect.s]
            local mask = effect.x and effect.x.v and effect.x.v[1]
            local text = effectLabel(token, mask) .. " (" .. (rawget(L, "scope_" .. scope) or scope) .. ")"
            local timing = duration(effect.d)
            if timing then text = text .. ": " .. timing end
            line(indent .. text, true)
        end
        if db.k.c[spell.c] ~= "classified" then line(indent .. L.MECHANICS_UNKNOWN, true) end
        if spell.p and spell.p.pc then line(indent .. string.format(L.CLIENT_PROC_CHANCE, spell.p.pc), true) end
    end
    for _, summon in ipairs(spell.u or {}) do
        -- No reliable localized creature-name API is assumed for an arbitrary ID.
        local text = string.format(L.SUMMON_CREATURE, summon.n)
        if summon.q then text = text .. string.format(L.SUMMON_QUANTITY, summon.q) end
        local timing = duration(summon.d)
        if timing then text = text .. string.format(L.SUMMON_LIFETIME, timing) end
        line(indent .. text, true)
    end
end

local function detailTree(id, depth, label, unverified)
    local stack = { { id = id, depth = depth or 0, label = label, unverified = unverified } }
    local visited = {}
    while #stack > 0 do
        checkpoint()
        local entry = table.remove(stack)
        local indent = string.rep("  ", math.min(entry.depth, 6))
        local relation = entry.relation
        if relation then
            local kind = db.k.r[relation.k]
            local relationLabel = rawget(L, "relationship_" .. kind) or kind
            if kind == "proc" and relation.c then relationLabel = relationLabel .. ": " .. relation.c end
            if CB.config.debugDetails then
                if relation.e then relationLabel = relationLabel .. string.format(L.RELATION_EFFECT, relation.e) end
                if entry.depth > 6 then relationLabel = relationLabel .. string.format(L.RELATION_DEPTH, entry.depth) end
            end
            line(indent .. relationLabel, true)
        end
        if visited[entry.id] then
            if CB.config.debugDetails then line(indent .. spellName(entry.id) .. L.RELATION_SEEN, true) end
        else
            visited[entry.id] = true
            line(indent .. (entry.label or spellName(entry.id)), false, salient(rowMechanics(entry.id, entry.depth > 0)))
            description(entry.id, indent .. "  ", entry.unverified)
            spellDetails(entry.id, indent .. "  ")
            local spell = db.s[entry.id]
            local children = {}
            for _, child in ipairs(spell and spell.r or {}) do
                checkpoint()
                if not CB.excludedSpells[child.s] then
                    children[#children + 1] = { ids = { child.s }, relation = child }
                end
            end
            if entry.depth >= 1 and not CB.config.debugDetails then
                if #children > 0 then line(indent .. "  " .. string.format(L.RELATED_LIMIT, #children), true) end
            else
                for _, child in ipairs(children) do checkpoint(); child.effects = rowMechanics(child.ids[1], true) end
                sortEntries(children)
                for index = #children, 1, -1 do
                    checkpoint()
                    local child = children[index]
                    stack[#stack + 1] = { id = child.ids[1], depth = entry.depth + 1, relation = child.relation }
                end
            end
        end
    end
end

local function expanded()
    local key = CB.config.expansion
    if key == "always" then return true end
    if key == "ctrl" then return IsControlKeyDown() end
    if key == "shift" then return IsShiftKeyDown() end
    if key == "alt" then return IsAltKeyDown() end
    return false
end

local function compactEntry(text, ids)
    -- Keep only the icon and first word together; the rest wraps at real spaces.
    local first, rest = text:match("^(|T.-|t %S+)(.*)$")
    if not first then first, rest = text:match("^(%S+)(.*)$") end
    return "|W" .. (first or text) .. "|w" .. (rest or "") .. debugIDs(ids) .. " "
end

local function summaryEffectLess(a, b)
    if effectLess(a, b) then return true end
    if effectLess(b, a) then return false end
    return (a.timing or "") < (b.timing or "")
end

local function summaryKey(effect)
    return effectKey(effect) .. ":" .. (effect.timingKey or "")
end

local function mergeSummaryEffect(combined, effect, entry)
    if not combined then
        combined = { token = effect.token, ranged = effect.ranged, targeting = effect.targeting,
            targetKey = effect.targetKey, durationKind = effect.durationKind, areaAura = effect.areaAura,
            timing = effect.timing, timingKey = effect.timingKey, schoolMask = effect.schoolMask, ids = {}, spells = {} }
    end
    if combined.durationKind ~= effect.durationKind then combined.durationKind = nil end
    combined.areaAura = combined.areaAura and effect.areaAura
    for _, id in ipairs(entry.ids) do checkpoint(); combined.ids[id] = true end
    for id in pairs(effect.spells) do checkpoint(); combined.ids[id] = true; combined.spells[id] = true end
    return combined
end

local function summary(entries)
    local groups, fallback = {}, {}
    for _, entry in ipairs(entries) do
        checkpoint()
        local effects = sortedEffects(entry.effects, summaryEffectLess)
        if #effects == 0 then fallback[#fallback + 1] = entry else
            local keys = {}
            for index, effect in ipairs(effects) do checkpoint(); keys[index] = summaryKey(effect) end
            local key = table.concat(keys, "/")
            local group = groups[key]
            if not group then group = { effects = {}, roots = {} }; groups[key] = group end
            group.roots[entry.selected or entry.ids[1]] = true
            for index, effect in ipairs(effects) do
                checkpoint()
                group.effects[index] = mergeSummaryEffect(group.effects[index], effect, entry)
            end
        end
    end
    local ordered = sortedEffects(groups, function(a, b)
        for index = 1, math.min(#a.effects, #b.effects) do
            if summaryEffectLess(a.effects[index], b.effects[index]) then return true end
            if summaryEffectLess(b.effects[index], a.effects[index]) then return false end
        end
        return #a.effects > #b.effects
    end)
    local compact = {}
    for _, group in ipairs(ordered) do
        checkpoint()
        local ids, spellIDs, allIDs = {}, {}, {}
        for _, effect in ipairs(group.effects) do
            for id in pairs(effect.ids) do checkpoint(); allIDs[id] = true end
        end
        for id in pairs(allIDs) do checkpoint(); ids[#ids + 1] = id end
        for id in pairs(group.roots) do checkpoint(); spellIDs[#spellIDs + 1] = id end
        table.sort(ids); table.sort(spellIDs)
        local spellID = spellIDs[1]
        current.spells[spellID] = true
        local info = C_Spell.GetSpellInfo(spellID)
        if not info then requestSpell(spellID) end
        local text = combinedEffectList(group.effects)
        if CB.config.mode == "effects" then
            line(spellIcon(info) .. text .. debugIDs(ids))
        else
            compact[#compact + 1] = compactEntry(spellIcon(info) .. text, ids)
        end
    end
    if #compact > 0 then line(table.concat(compact, " "), false, nil, true) end
    -- Grouping hints cover icon+label only; inline ID lists wrap independently.
    for _, entry in ipairs(fallback) do
        if CB.config.mode == "effects_compact" then
            line(compactEntry(entryName(entry, true), entry.ids), false, nil, true)
        else
            line(entryName(entry))
        end
    end
end

local function abilities(npcID)
    local npc = db.n[npcID]
    if CB.config.debugIDs then line(string.format(L.DEBUG_NPC_ID, npcID), true) end
    if not npc then return end
    local ids, provisional, unresolved = {}, false, false
    -- Read scalar fields without copying pooled records. Check even excluded
    -- rows: a filtering iterator could otherwise skip a huge list without yielding.
    for _, ability in ipairs(npc.b) do
        checkpoint()
        if not CB.IsAbilityExcluded(npcID, ability) then
            local disposition = db.k.b[ability.d]
            ids[#ids + 1] = ability.s
            provisional = provisional or disposition == "provisional"
            unresolved = unresolved or disposition == "unresolved"
        end
    end
    local detailed = expanded()
    if #ids == 0 then
        if detailed and CB.config.debugDetails and #npc.b == 0 then line(L.ABILITIES_UNKNOWN, true) end
        return
    end
    local entries = presentation(npcID, ids)
    if detailed then
        if CB.config.debugDetails then
            if provisional then line(L.ASSOCIATIONS_PROVISIONAL, true) end
            if unresolved then line(L.ASSOCIATIONS_UNRESOLVED, true) end
            if db.k.a[npc.a] ~= "ok" or db.k.t[npc.t] ~= "present" then line(L.COVERAGE_PARTIAL, true) end
        end
        for _, entry in ipairs(entries) do
            checkpoint()
            if not entry.selected then detailTree(entry.ids[1]) else
                detailTree(entry.selected, 0, entryName(entry), true)
                if CB.config.debugDetails and entry.alternatives > 0 then
                    line("  " .. string.format(L.ABILITY_CANDIDATES, entry.alternatives), true)
                end
            end
        end
    elseif CB.config.mode == "spells" then
        for _, entry in ipairs(entries) do line(entryName(entry)) end
    elseif CB.config.mode == "spells_compact" then
        local chunks = {}
        for _, entry in ipairs(entries) do
            checkpoint()
            chunks[#chunks + 1] = compactEntry(entryName(entry, true), entry.ids)
        end
        if #chunks > 0 then line(table.concat(chunks, " "), false, nil, true) end
    else
        summary(entries)
    end
    local modifier = rawget(L, "MODIFIER_" .. string.upper(CB.config.expansion))
    if CB.config.reminder and modifier and not detailed then line(string.format(L.DETAILS_HINT, modifier), true) end
end

local function drawAbilities(tooltip, npcID)
    clear(tooltip)
    local body = tooltip:NumLines() > 1 and tooltip:GetLeftLine(tooltip:NumLines()) or GameTooltipText
    local state = { tooltip = tooltip, npcID = npcID, spells = {}, mechanics = {}, children = {}, cancels = {},
        directProfiles = {}, ownProfiles = {}, childOwnProfiles = {},
        body = body, lines = {}, rows = 0, firstLine = tooltip:NumLines() + 1 }
    state.face, state.size, state.flags = body:GetFont()
    state.scale, state.spacing = body == GameTooltipText and 1 or body:GetTextScale(), body:GetSpacing()
    state.worker = coroutine.create(function() abilities(npcID) end)
    states[tooltip] = state
    enqueue(state)
end

local function render(tooltip, data)
    if tooltip ~= GameTooltip or not CB.config or not CB.config.enabled then return end
    local npcID, primary = displayedNPC(tooltip)
    if not npcID or states[tooltip] then return end
    local unit
    if structuredTooltips then
        if primary ~= data then return end
        unit = UnitTokenFromGUID(data.guid)
    else
        unit = primary
    end
    if issecretvalue(unit) then return end
    if unit then
        local restricted = C_Secrets.ShouldUnitIdentityBeSecret(unit)
        if issecretvalue(restricted) or restricted then return end
        local controlled = UnitPlayerControlled(unit)
        if issecretvalue(controlled) or controlled then return end
    end
    if CB.config.ignoreFriendly then
        if not unit then return end -- Can't establish friendliness for this identity.
        local friendly = UnitIsFriend("player", unit)
        if issecretvalue(friendly) or friendly then return end
    end
    drawAbilities(tooltip, npcID)
end

function CB.RenderPreview(tooltip, sample)
    clear(tooltip)
    tooltip:ClearLines()
    local color = FACTION_BAR_COLORS[sample.friendly and 5 or 2]
    tooltip:SetText(sample.name, color.r, color.g, color.b)
    -- The native level template takes a number; an unknown boss level must not
    -- pass "??" through its numeric conversion (which the client displays as 0).
    local level = sample.level < 0 and LEVEL .. " ??" or string.format(UNIT_LEVEL_TEMPLATE, sample.level)
    tooltip:AddLine(level, 0.7, 0.7, 0.7, true)
    if CB.config.enabled and not (CB.config.ignoreFriendly and sample.friendly) then
        drawAbilities(tooltip, sample.id)
    end
    tooltip:Show()
end

local function layout(tooltip)
    local state = states[tooltip]
    if not state or not state.lastLine or tooltip:NumLines() < state.lastLine then return end
    local body = tooltip:GetLeftLine(tooltip:NumLines())
    local face, size, flags = body:GetFont()
    local scale, spacing = body:GetTextScale(), body:GetSpacing()
    local last = state.lines[state.lastLine]
    if state.face ~= face or state.size ~= size or state.flags ~= flags
        or state.scale ~= scale or state.spacing ~= spacing
        or (last.compact and body:CanNonSpaceWrap()) then
        state.face, state.size, state.flags = face, size, flags
        state.scale, state.spacing, state.body = scale, spacing, body
        state.restyle = true
        enqueue(state)
    end
end

local function restyle()
    for index = current.firstLine, current.lastLine or current.firstLine - 1 do
        checkpoint()
        local texts = current.lines[index]
        style(current.tooltip:GetLeftLine(index), current.body, texts.left, texts.compact)
        if texts.right then style(current.tooltip:GetRightLine(index), current.body, texts.right) end
    end
    current.styled = true
end

local function tick()
    steps, deadline = 0, GetTimePreciseSec() + FRAME_SECONDS
    while head <= tail and steps < FRAME_STEPS and GetTimePreciseSec() < deadline do
        local state = queue[head]
        queue[head], head, state.queued = nil, head + 1, nil
        steps = steps + 1
        if states[state.tooltip] == state then
            if not state.worker and state.restyle then
                state.restyle = nil
                state.worker = coroutine.create(restyle)
            end
            if state.worker then
                local previous = current
                current = state
                local worker = state.worker
                local ok, message = coroutine.resume(worker)
                current = previous
                if not ok or coroutine.status(worker) == "dead" then
                    state.worker, state.mechanics = nil, nil
                end
                if not ok and message ~= ROW_LIMIT then geterrorhandler()(message) end
                if states[state.tooltip] == state and (state.lastLine ~= state.publishedLine or state.styled) then
                    state.publishedLine, state.styled = state.lastLine, nil
                    state.tooltip:Show()
                    if CB.LayoutPreview then CB.LayoutPreview() end
                end
            elseif state.textDirty then
                state.textDirty = nil
                if state.tooltip == GameTooltip then refreshUnitTooltip()
                elseif CB.RefreshPreview then CB.RefreshPreview() end
            end
            if states[state.tooltip] == state and (state.worker or state.restyle or state.textDirty) then enqueue(state) end
        end
    end
    if head > tail then queue, head, tail = {}, 1, 0; scheduler:Hide() end
end

textChanged = function(state)
    -- Arriving spell text must not cancel and rebuild an unfinished tree.
    state.textDirty = true
    enqueue(state)
end

local function watch(tooltip)
    local function cleared()
        clear(tooltip)
        if tooltip == GameTooltip then unitHideStatus = nil end
    end
    tooltip:HookScript("OnTooltipCleared", cleared)
    tooltip:HookScript("OnHide", cleared)
    hooksecurefunc(tooltip, "Show", function() layout(tooltip) end)
end

function CB.InitializePreview(tooltip)
    watch(tooltip)
end

function CB.InitializeTooltip()
    scheduler = CreateFrame("Frame")
    scheduler:Hide()
    scheduler:SetScript("OnUpdate", tick)
    watch(GameTooltip)
    if structuredTooltips then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, render)
    else
        GameTooltip:HookScript("OnTooltipSetUnit", render)
        hooksecurefunc(GameTooltip, "SetUnit", function(tooltip, _, hideStatus)
            unitHideStatus = hideStatus
        end)
    end
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("MODIFIER_STATE_CHANGED")
    frame:RegisterEvent("SPELL_TEXT_UPDATE")
    frame:SetScript("OnEvent", function(_, event, spellID)
        if event == "MODIFIER_STATE_CHANGED" then
            if next(states) then CB.RefreshTooltip() end
        elseif not issecretvalue(spellID) then
            for _, state in pairs(states) do
                if state.spells[spellID] then textChanged(state) end
            end
        end
    end)
end
