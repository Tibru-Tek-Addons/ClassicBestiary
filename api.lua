local addonName, CB = ...
local db = CB.db

local API = { API_VERSION = 1 }
local dictionaries = db.k

function CB.IsAbilityExcluded(npcID, ability)
    if dictionaries.b[ability.d] == "accepted" then return false end
    local excludedAbilities = CB.excludedAbilities[npcID]
    return CB.excludedSpells[ability.s] or (excludedAbilities and excludedAbilities[ability.s])
end
-- Generated records share pooled tables. Every table query owns its entire result.
local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, child in pairs(value) do
        result[key] = copy(child)
    end
    return result
end

function API.GetManifest()
    return copy(db.m)
end

function API.GetNPC(npcID)
    local result = copy(db.n[npcID])
    if not result then return nil end
    local kept = 1
    for _, ability in ipairs(result.b) do
        if not CB.IsAbilityExcluded(npcID, ability) then
            result.b[kept] = ability
            kept = kept + 1
        end
    end
    for index = kept, #result.b do result.b[index] = nil end
    return result
end

function API.GetSpell(spellID)
    return copy(db.s[spellID])
end

function API.GetDictionaries()
    return copy(dictionaries)
end

-- Only scalars escape this iterator; raw difficulty modes belong to GetNPC.
function API.IterateAbilities(npcID, confirmedOnly)
    local npc = db.n[npcID]
    local abilities = npc and npc.b
    local index = 0
    return function()
        if not abilities then
            return nil
        end
        while true do
            index = index + 1
            local ability = abilities[index]
            if not ability then
                return nil
            end
            local disposition = dictionaries.b[ability.d]
            if not CB.IsAbilityExcluded(npcID, ability) and (not confirmedOnly or disposition == "accepted") then
                return ability.s, disposition
            end
        end
    end
end

local function spellArray(spellID, field)
    local spell = db.s[spellID]
    if not spell then
        return nil, "missing"
    end
    return copy(spell[field] or {}), dictionaries.c[spell.c]
end

function API.GetEffects(spellID)
    return spellArray(spellID, "e")
end

function API.GetRelationships(spellID)
    return spellArray(spellID, "r")
end

function API.GetSummons(spellID)
    return spellArray(spellID, "u")
end

function API.ResolveGUID(guid)
    -- Check secrecy before nil comparison, type inspection or any string operation.
    if issecretvalue(guid) then
        return nil, "restricted"
    end
    if guid == nil then
        return nil, "missing"
    end
    if type(guid) ~= "string" then
        return nil, "malformed"
    end
    local kind = string.match(guid, "^([%a]+)%-")
    if not kind then
        return nil, "malformed"
    end
    if kind == "Player" then
        return nil, "player"
    end
    if kind == "Pet" then
        return nil, "pet"
    end
    -- Vehicle identities are deliberately not treated as Creature identities.
    if kind ~= "Creature" then
        return nil, "non_creature"
    end
    local id = string.match(guid, "^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-%x+$")
    local npcID = id and tonumber(id)
    if not npcID or npcID <= 0 or npcID > 9007199254740991 then
        return nil, "malformed"
    end
    return npcID, "ok"
end

function API.ResolveUnit(unit)
    if issecretvalue(unit) then
        return nil, "restricted"
    end
    if unit == nil then
        return nil, "missing"
    end
    if type(unit) ~= "string" or unit == "" then
        return nil, "malformed"
    end
    if C_Secrets.ShouldUnitIdentityBeSecret(unit) then
        return nil, "restricted"
    end
    return API.ResolveGUID(UnitGUID(unit))
end

function API.GetNPCEffects(npcID, confirmedOnly)
    if not db.n[npcID] then
        return nil
    end
    local byToken = {}
    local tokens = {}
    local path = {}
    local active = {}

    local function addEffects(spellID, directSpellID, disposition)
        local spell = db.s[spellID]
        if spell.e then
            for _, effect in ipairs(spell.e) do
                local token = dictionaries.e[effect.t]
                if token and token ~= "unknown" and token ~= "trigger" then
                    local entry = byToken[token]
                    if not entry then
                        entry = { token = token, causes = {} }
                        byToken[token] = entry
                        tokens[#tokens + 1] = token
                    end
                    entry.causes[#entry.causes + 1] = {
                        directSpellID = directSpellID,
                        spellID = spellID,
                        effectIndex = effect.i,
                        scope = dictionaries.s[effect.s],
                        duration = copy(effect.d),
                        path = copy(path),
                        disposition = disposition,
                    }
                end
            end
        end
    end

    -- An explicit DFS stack handles arbitrarily deep relationship chains.
    -- Path-local protection preserves diamond paths and independent direct casts.
    local stack = {}
    for directSpellID, disposition in API.IterateAbilities(npcID, confirmedOnly) do
        local directSpell = db.s[directSpellID]
        if directSpell then
            active[directSpellID] = true
            addEffects(directSpellID, directSpellID, disposition)
            stack[1] = { id = directSpellID, spell = directSpell, nextRelationship = 1 }
            while #stack > 0 do
                local frame = stack[#stack]
                local relationship = frame.spell.r and frame.spell.r[frame.nextRelationship]
                if relationship then
                    frame.nextRelationship = frame.nextRelationship + 1
                    local childID = relationship.s
                    local child = db.s[childID]
                    if child and not active[childID] and not CB.excludedSpells[childID] then
                        path[#path + 1] = relationship
                        active[childID] = true
                        addEffects(childID, directSpellID, disposition)
                        stack[#stack + 1] = { id = childID, spell = child, nextRelationship = 1 }
                    end
                else
                    active[frame.id] = nil
                    stack[#stack] = nil
                    if #stack > 0 then
                        path[#path] = nil
                    end
                end
            end
        end
    end
    table.sort(tokens)
    local result = {}
    for index, token in ipairs(tokens) do
        result[index] = byToken[token]
    end
    return result
end

CB.API = API
