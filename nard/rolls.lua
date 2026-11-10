--[[
    nard - roll data (Phoenix, level 75 cap)
    The 20 rolls a Corsair learns up to 75. Potency tables mirror LSB corsair.lua
    (same tables XIUI uses). values[1..11] = power per total, bust = penalty power.
    id     = ability id sent in the action packet (98..117)
    job    = job id that adds `bonus` when that job is in your party
    scale  = divide power by this for display (Gallant's is in 1/100 %)
    sign   = '+' buff, '-' reduction (Choral SIRD, Gallant's damage taken)
]]--

local rolls = {}

local P, F = '%', ''

rolls.list = {
    { id =  98, name = "Fighter's Roll", short = "FIGHTER'S", lvl = 49, job =  1, bonus =  6, lucky = 5, unlucky = 9, unit = P, sign = '+', stat = 'DA',      desc = 'Double Attack rate',
      values = { 2, 2, 3, 4, 12, 5, 6, 7, 1, 9, 18 }, bust = 6 },
    { id =  99, name = "Monk's Roll",    short = "MONK'S",    lvl = 31, job =  2, bonus = 10, lucky = 3, unlucky = 7, unit = P, sign = '+', stat = 'S.Blow',  desc = 'Subtle Blow',
      values = { 8, 10, 32, 12, 14, 16, 4, 20, 22, 24, 40 }, bust = 11 },
    { id = 100, name = "Healer's Roll",  short = "HEALER'S",  lvl = 20, job =  3, bonus =  4, lucky = 3, unlucky = 7, unit = P, sign = '+', stat = 'Cure',    desc = 'Cure potency received',
      values = { 3, 4, 12, 5, 6, 7, 1, 8, 9, 10, 16 }, bust = 4 },
    { id = 101, name = "Wizard's Roll",  short = "WIZARD'S",  lvl = 58, job =  4, bonus = 10, lucky = 5, unlucky = 9, unit = F, sign = '+', stat = 'MAB',     desc = 'Magic attack bonus',
      values = { 4, 6, 8, 10, 25, 12, 14, 17, 2, 20, 30 }, bust = 10 },
    { id = 102, name = "Warlock's Roll", short = "WARLOCK'S", lvl = 46, job =  5, bonus =  5, lucky = 4, unlucky = 8, unit = F, sign = '+', stat = 'M.Acc',   desc = 'Magic accuracy',
      values = { 2, 3, 4, 12, 5, 6, 7, 1, 8, 9, 15 }, bust = 5 },
    { id = 103, name = "Rogue's Roll",   short = "ROGUE'S",   lvl = 43, job =  6, bonus =  6, lucky = 5, unlucky = 9, unit = P, sign = '+', stat = 'Crit',    desc = 'Critical hit rate',
      values = { 2, 2, 3, 4, 12, 5, 6, 6, 1, 8, 19 }, bust = 6 },
    { id = 104, name = "Gallant's Roll", short = "GALLANT'S", lvl = 55, job =  7, bonus = 500, scale = 100, lucky = 3, unlucky = 7, unit = P, sign = '-', stat = 'DT', desc = 'Physical damage taken',
      values = { 600, 800, 2400, 900, 1100, 1200, 300, 1500, 1700, 1800, 3000 }, bust = 500 },
    { id = 105, name = "Chaos Roll",     short = "CHAOS",     lvl = 14, job =  8, bonus = 10, lucky = 4, unlucky = 8, unit = P, sign = '+', stat = 'ATK',     desc = 'Attack',
      values = { 6, 8, 9, 25, 11, 13, 16, 3, 17, 19, 31 }, bust = 10 },
    { id = 106, name = "Beast Roll",     short = "BEAST",     lvl = 34, job =  9, bonus = 10, lucky = 4, unlucky = 8, unit = P, sign = '+', stat = 'Pet ATK', desc = 'Pet attack',
      values = { 4, 5, 7, 19, 8, 9, 11, 2, 13, 14, 23 }, bust = 7 },
    { id = 107, name = "Choral Roll",    short = "CHORAL",    lvl = 26, job = 10, bonus = 25, lucky = 2, unlucky = 6, unit = P, sign = '-', stat = 'SIRD',    desc = 'Spell interruption rate',
      values = { 13, 55, 17, 20, 25, 8, 30, 35, 40, 45, 65 }, bust = 25 },
    { id = 108, name = "Hunter's Roll",  short = "HUNTER'S",  lvl = 11, job = 11, bonus = 15, lucky = 4, unlucky = 8, unit = F, sign = '+', stat = 'ACC',     desc = 'Accuracy',
      values = { 10, 13, 15, 40, 18, 20, 25, 5, 27, 30, 50 }, bust = 5 },
    { id = 109, name = "Samurai Roll",   short = "SAMURAI",   lvl = 37, job = 12, bonus = 10, lucky = 2, unlucky = 6, unit = F, sign = '+', stat = 'STP',     desc = 'Store TP',
      values = { 8, 32, 10, 12, 14, 4, 16, 20, 22, 24, 40 }, bust = 5 },
    { id = 110, name = "Ninja Roll",     short = "NINJA",     lvl =  8, job = 13, bonus =  6, lucky = 4, unlucky = 8, unit = F, sign = '+', stat = 'EVA',     desc = 'Evasion',
      values = { 4, 5, 5, 14, 6, 7, 9, 2, 10, 11, 18 }, bust = 6 },
    { id = 111, name = "Drachen Roll",   short = "DRACHEN",   lvl = 23, job = 14, bonus = 15, lucky = 4, unlucky = 8, unit = F, sign = '+', stat = 'Pet ACC', desc = 'Pet accuracy',
      values = { 10, 13, 15, 40, 18, 20, 25, 5, 28, 30, 50 }, bust = 15 },
    { id = 112, name = "Evoker's Roll",  short = "EVOKER'S",  lvl = 40, job = 15, bonus =  1, lucky = 5, unlucky = 9, unit = F, sign = '+', stat = 'Refresh', desc = 'Refresh (MP per tick)',
      values = { 1, 1, 1, 1, 3, 2, 2, 2, 1, 3, 4 }, bust = 1 },
    { id = 113, name = "Magus's Roll",   short = "MAGUS'S",   lvl = 17, job = 16, bonus =  8, lucky = 2, unlucky = 6, unit = F, sign = '+', stat = 'MDB',     desc = 'Magic defense',
      values = { 5, 20, 6, 8, 9, 3, 10, 13, 14, 15, 25 }, bust = 5 },
    { id = 114, name = "Corsair's Roll", short = "CORSAIR'S", lvl =  5, job = 17, bonus =  0, lucky = 5, unlucky = 9, unit = P, sign = '+', stat = 'EXP',     desc = 'Experience points gained',
      values = { 10, 11, 11, 12, 20, 13, 15, 16, 8, 17, 24 }, bust = 6 },
    { id = 115, name = "Puppet Roll",    short = "PUPPET",    lvl = 52, job = 18, bonus =  8, lucky = 3, unlucky = 7, unit = F, sign = '+', stat = 'Pet MAB', desc = 'Pet magic attack / accuracy',
      values = { 4, 5, 18, 7, 9, 10, 2, 11, 13, 15, 22 }, bust = 8 },
    { id = 116, name = "Dancer's Roll",  short = "DANCER'S",  lvl = 61, job = 19, bonus =  4, lucky = 3, unlucky = 7, unit = F, sign = '+', stat = 'Regen',   desc = 'Regen (HP per tick)',
      values = { 3, 4, 12, 5, 6, 7, 1, 8, 9, 10, 16 }, bust = 4 },
    { id = 117, name = "Scholar's Roll", short = "SCHOLAR'S", lvl = 64, job = 20, bonus =  4, lucky = 2, unlucky = 6, unit = F, sign = '+', stat = 'Cons.MP', desc = 'Conserve MP',
      values = { 2, 9, 3, 4, 5, 2, 6, 6, 7, 9, 14 }, bust = 4 },
}

rolls.DOUBLE_UP_ID = 123

rolls.by_name = {}
rolls.by_id   = {}
for _, r in ipairs(rolls.list) do
    rolls.by_name[r.name:lower()] = r
    rolls.by_id[r.id] = r
end

-- Main jobs of active party members 0-5 (for the party-job bonus).
function rolls.party_jobs()
    local present = {}
    pcall(function ()
        local p = AshitaCore:GetMemoryManager():GetParty()
        for i = 0, 5 do
            if p:GetMemberIsActive(i) == 1 then present[p:GetMemberMainJob(i)] = true end
        end
    end)
    return present
end

local function fmt_num(v)
    v = math.abs(v)
    if math.abs(v % 1) < 0.05 then return ('%d'):format(math.floor(v + 0.5)) end
    return ('%.1f'):format(v)
end

-- Power for a total (with party-job bonus when that job is in party).
function rolls.power(def, total, jobs)
    local p = def and def.values[total]
    if p == nil then return nil, false end
    local boosted = jobs ~= nil and jobs[def.job] == true and def.bonus > 0
    if boosted then p = p + def.bonus end
    return p / (def.scale or 1), boosted
end

-- "+40 ACC", "-6% DT" ... second return = party-job bonus applied.
function rolls.effect_text(def, total, jobs)
    local v, boosted = rolls.power(def, total, jobs)
    if v == nil then return '', false end
    return ('%s%s%s %s'):format(def.sign, fmt_num(v), def.unit, def.stat), boosted
end

-- Bust penalty text, e.g. "-10% ATK" (opposite sign of the roll).
function rolls.bust_text(def)
    if def == nil or def.bust == nil then return 'BUST' end
    local s = (def.sign == '-') and '+' or '-'
    return ('%s%s%s %s'):format(s, fmt_num(def.bust / (def.scale or 1)), def.unit, def.stat)
end

-- Chance (0..1) that the next Double-Up busts from this total.
function rolls.bust_chance(total)
    if total == nil or total < 1 or total > 11 then return 0 end
    return math.max(0, total - 5) / 6
end

return rolls
