--[[
    6arab - song data (Phoenix, level 75 cap)
    Song names come from the game's own spell resources (Singing skill),
    this file only adds colour, a short ribbon name, the effect label and
    the base duration at 75 (no gear).
]]--

local songs = {}

local ROMAN = { I = 1, II = 2, III = 3, IV = 4, V = 5, VI = 6, VII = 7 }

local EL_COL = {
    Fire      = { 1.00, 0.42, 0.30, 1 },
    Ice       = { 0.60, 0.90, 1.00, 1 },
    Wind      = { 0.50, 0.95, 0.50, 1 },
    Earth     = { 0.85, 0.68, 0.40, 1 },
    Lightning = { 0.82, 0.52, 1.00, 1 },
    Water     = { 0.40, 0.62, 1.00, 1 },
    Light     = { 1.00, 1.00, 0.88, 1 },
    Dark      = { 0.60, 0.48, 0.78, 1 },
}

local ETUDE_STAT = {
    Sinewy = 'STR', Dextrous = 'DEX', Vivacious = 'VIT', Quick = 'AGI',
    Learned = 'INT', Spirited = 'MND', Enchanting = 'CHR',
    Herculean = 'STR', Uncanny = 'DEX', Vital = 'VIT', Swift = 'AGI',
    Sage = 'INT', Logical = 'MND', Bewitching = 'CHR',
}

-- dur = base seconds at 75 (nil = 120)
songs.FAMILIES = {
    { k = 'Requiem',  enemy = true, col = { 0.68, 0.45, 0.95, 1 }, eff = 'DoT' },
    { k = 'Lullaby',  enemy = true, col = { 0.58, 0.80, 1.00, 1 }, eff = 'Sleep',   dur = 30 },
    { k = 'Elegy',    enemy = true, col = { 0.62, 0.62, 0.76, 1 }, eff = 'Slow' },
    { k = 'Threnody', enemy = true, col = { 0.88, 0.52, 0.42, 1 }, eff = 'Res down', dur = 60 },
    { k = 'Virelai',  enemy = true, col = { 1.00, 0.60, 0.85, 1 }, eff = 'Charm',   dur = 30 },
    { k = 'Finale',   enemy = true, col = { 0.90, 0.90, 0.90, 1 }, eff = 'Dispel',  dur = 0 },
    { k = 'March',    col = { 0.96, 0.80, 0.30, 1 }, eff = 'Haste' },
    { k = 'Minuet',   col = { 1.00, 0.45, 0.36, 1 }, eff = 'ATK up' },
    { k = 'Madrigal', col = { 1.00, 0.64, 0.26, 1 }, eff = 'ACC up' },
    { k = 'Prelude',  col = { 0.62, 0.92, 0.42, 1 }, eff = 'R.ACC up' },
    { k = 'Ballad',   col = { 0.42, 0.64, 1.00, 1 }, eff = 'Refresh' },
    { k = 'Paeon',    col = { 1.00, 0.56, 0.76, 1 }, eff = 'Regen' },
    { k = 'Minne',    col = { 0.74, 0.80, 0.90, 1 }, eff = 'DEF up' },
    { k = 'Mambo',    col = { 0.42, 0.92, 0.78, 1 }, eff = 'EVA up' },
    { k = 'Etude',    col = { 0.86, 0.72, 1.00, 1 }, eff = 'Stat up' },
    { k = 'Carol',    col = { 0.95, 0.95, 0.62, 1 }, eff = 'Resist' },
    { k = 'Hymnus',   col = { 1.00, 1.00, 0.86, 1 }, eff = 'Reraise' },
    { k = 'Mazurka',  col = { 0.62, 0.86, 1.00, 1 }, eff = 'Move speed' },
}
local DEFAULT = { k = 'Song', col = { 0.82, 0.82, 0.82, 1 }, eff = 'Song' }

-- these keep their first word on the ribbon (it tells two songs apart)
local KEEP_FIRST = { March = true, Madrigal = true, Prelude = true, Mambo = true, Elegy = true, Lullaby = true }

local function element_of(name)
    for el in pairs(EL_COL) do
        if name:find(el, 1, true) then return el end
    end
    return nil
end

function songs.family(name)
    for _, f in ipairs(songs.FAMILIES) do
        if name:find(f.k, 1, true) then return f end
    end
    return DEFAULT
end

local function roman_of(name)
    return name:match(' (%u+)$')
end

function songs.short(name, fam)
    local num = roman_of(name)
    local tail = num and (' ' .. num) or ''
    if fam.k == 'Etude' then
        local first = name:match('^(%a+)')
        return ((ETUDE_STAT[first] or 'STAT') .. ' ETUDE'):upper()
    elseif fam.k == 'Carol' or fam.k == 'Threnody' then
        local el = element_of(name) or ''
        return (el .. ' ' .. fam.k .. tail):upper()
    elseif KEEP_FIRST[fam.k] then
        return name:upper()
    end
    local rest = name:match('^%S+%s+(.+)$')
    return (rest or name):upper()
end

function songs.effect(name, fam)
    if fam.k == 'Etude' then
        local first = name:match('^(%a+)')
        return (ETUDE_STAT[first] or 'Stat') .. ' up'
    elseif fam.k == 'Carol' then
        return (element_of(name) or '') .. ' resist'
    elseif fam.k == 'Threnody' then
        return (element_of(name) or '') .. ' res down'
    end
    return fam.eff
end

function songs.color(name, fam)
    if fam.k == 'Carol' or fam.k == 'Threnody' then
        local el = element_of(name)
        if el then return EL_COL[el] end
    end
    return fam.col
end

function songs.base_duration(name, fam)
    local d = fam.dur or 120
    if fam.k == 'Requiem' then
        local n = ROMAN[roman_of(name) or 'I'] or 1
        d = 47 + 16 * n                       -- I 63s ... VII 159s
    elseif fam.k == 'Elegy' then
        d = name:find('Carnage', 1, true) and 180 or 120
    end
    return d
end

-- Song name for a spell id, or nil when it is not a bard song.
function songs.name_of(id)
    local ok, name = pcall(function ()
        local r = AshitaCore:GetResourceManager():GetSpellById(id)
        if r == nil then return nil end
        if r.Skill ~= 40 and r.Type ~= 5 then return nil end   -- 40 = Singing, Type 5 = BardSong
        return r.Name[1]
    end)
    return ok and name or nil
end

-- Songs you can pick for your usual set (BRD up to 75)
songs.SET_CHOICES = {
    'Valor Minuet', 'Valor Minuet II', 'Valor Minuet III', 'Valor Minuet IV',
    'Advancing March', 'Victory March',
    'Sword Madrigal', 'Blade Madrigal',
    "Hunter's Prelude", "Archer's Prelude",
    "Mage's Ballad", "Mage's Ballad II",
    "Army's Paeon", "Army's Paeon II", "Army's Paeon III", "Army's Paeon IV", "Army's Paeon V",
    "Knight's Minne", "Knight's Minne II", "Knight's Minne III", "Knight's Minne IV",
    'Sheepfoe Mambo', 'Dragonfoe Mambo',
    'Sinewy Etude', 'Dextrous Etude', 'Vivacious Etude', 'Quick Etude',
    'Learned Etude', 'Spirited Etude', 'Enchanting Etude',
    'Fire Carol', 'Ice Carol', 'Wind Carol', 'Earth Carol',
    'Lightning Carol', 'Water Carol', 'Light Carol', 'Dark Carol',
    "Goddess's Hymnus", 'Chocobo Mazurka',
}

-- spell id for a song name (for ghost-tile recasts), nil if unknown
local id_cache = {}
function songs.id_of(name)
    if id_cache[name] ~= nil then return id_cache[name] or nil end
    local ok, id = pcall(function ()
        local r = AshitaCore:GetResourceManager():GetSpellByName(name, 0)
        return r and r.Id or nil
    end)
    id_cache[name] = (ok and id) or false
    return (ok and id) or nil
end

local cache = {}
function songs.def(name)
    if cache[name] then return cache[name] end
    local fam = songs.family(name)
    local d = {
        name  = name,
        fam   = fam,
        enemy = fam.enemy == true,
        short = songs.short(name, fam),
        eff   = songs.effect(name, fam),
        col   = songs.color(name, fam),
        base  = songs.base_duration(name, fam),
    }
    cache[name] = d
    return d
end

return songs
