--[[
    nard  (نرد - "dice")
    Floating Corsair roll tracker for Ashita v4 - Phoenix (level 75 cap)
    Theeb theme - by Jboor

    Shows each active Phantom Roll as a floating die:
      - roll name, die with the total, effect value, time left
      - flames on a Lucky number, gold glow on 11, red on Unlucky / Bust
      - bust chance + Double-Up window countdown on your newest roll
    Tracks your own rolls and (optionally) other Corsairs' rolls that hit you.

    Commands:
      /nard              settings window
      /nard test         preview rolls (cycles 3 presets)
      /nard clear        clear tracked rolls
      /nard min          minimize / restore the overlay
      /nard lock         lock / unlock overlay position
      /nard scale <n>    overlay size (0.6 - 2.0)
      /nard show|hide    show / hide the overlay
      /nard reset        move the overlay back to default position
      /nard log          debug log window
      /nard debug [on|off]  verbose (debug) tracing
]]--

addon.name    = 'nard'
addon.author  = 'Jboor'
addon.version = '1.2.0'
addon.desc    = 'Floating Corsair roll tracker (Phoenix Lv75) - Theeb theme'
addon.link    = ''

require('common')
local imgui    = require('imgui')
local settings = require('settings')
local chat     = require('chat')
local rolls    = require('rolls')
local dlog     = require('dlog')

----------------------------------------------------------------------------
-- constants
----------------------------------------------------------------------------
local ROLL_DURATION = 300   -- Phantom Roll lasts 5 min at 75
local DU_WINDOW     = 45    -- Double-Up chance window (seconds)
local DOUBLE_UP_ID  = 123
local COR_JOB       = 17
local MSG_BUST      = 426
local MSG_INITIAL   = { [420] = true, [421] = true, [422] = true, [423] = true }
local MSG_DOUBLE    = { [424] = true, [425] = true, [426] = true, [427] = true }

local ROUND_ALL = ImDrawFlags_RoundCornersAll or ImDrawCornerFlags_All or 0
local frame_jobs = {}   -- party main jobs, refreshed each frame (party-job bonus)

local C = {
    gold   = { 0.96, 0.74, 0.26, 1.0 },
    flame  = { 1.00, 0.62, 0.18, 1.0 },
    cream  = { 0.97, 0.94, 0.86, 1.0 },
    steel  = { 0.66, 0.72, 0.82, 1.0 },
    dim    = { 0.50, 0.53, 0.60, 1.0 },
    slate  = { 0.17, 0.21, 0.29, 1.0 },
    red    = { 1.00, 0.38, 0.38, 1.0 },
    green  = { 0.58, 0.96, 0.52, 1.0 },
    bg     = { 0.07, 0.08, 0.11, 0.95 },
    bg2    = { 0.13, 0.15, 0.20, 1.0 },
}

----------------------------------------------------------------------------
-- settings
----------------------------------------------------------------------------
local defaults = T{
    visible    = true,
    minimized  = false,
    locked     = false,
    scale      = 1.0,
    show_party = true,
    show_bust  = true,
    show_empty = true,
    row_labels = true,
    panel      = false,   -- glass frame behind each row (off = dice float freely)
    cor_only   = true,    -- only show / track while you're on COR
    show_cd    = true,    -- Phantom Roll cooldown pill
    free       = false,   -- separate pieces, each moved on its own
    solo_hide  = true,    -- hide everything when not in a party for a while
    solo_mins  = 6,       -- ...this many minutes
    pieces     = T{},     -- saved piece positions / lock state
    cd_warn    = 5,       -- amber warning this many seconds before ready (0 = off)
    s_die      = 1.0,     -- separate sizes (multiplied by the overall scale)
    s_name     = 1.0,
    s_info     = 1.0,
    s_cd       = 1.0,
    s_fx       = 1.0,
    cor_sub    = false,   -- also count COR as sub job
    pos_x      = 320,
    pos_y      = 260,
    verbose    = false,
    echo       = false,
}
local cfg = settings.load(defaults)

-- size multiplier for one part (older settings files may not have the key yet)
local function sz(key)
    local v = tonumber(cfg[key])
    if v == nil or v <= 0 then return 1 end
    return v
end

local state = {
    active       = {},
    next_id      = 1,
    overlay_open = { true },
    cfg_win      = { open = false, min = false, open_tbl = { true } },
    log_win      = { open = false, min = false, open_tbl = { true } },
    reset_pos    = false,
    pos_dirty    = false,
    test_i       = 0,
    piece_reset  = {},
    phover       = {},
    no_hit       = false,
    testing      = false,
}

local function sync_log()
    dlog.verbose = cfg.verbose
    dlog.echo    = cfg.echo
end
sync_log()

settings.register('settings', 'nard_settings_update', function (s)
    if s ~= nil then cfg = s end
    sync_log()
    settings.save()
end)

local function msg(text)
    print(chat.header(addon.name):append(chat.message(text)))
end

----------------------------------------------------------------------------
-- game helpers
----------------------------------------------------------------------------
local function party() return AshitaCore:GetMemoryManager():GetParty() end
local function player() return AshitaCore:GetMemoryManager():GetPlayer() end

local function my_id()
    local ok, id = pcall(function () return party():GetMemberServerId(0) end)
    return ok and id or 0
end

local function member_name(id)
    local ok, name = pcall(function ()
        local p = party()
        for i = 0, 17 do
            if p:GetMemberServerId(i) == id then return p:GetMemberName(i) end
        end
        return nil
    end)
    return ok and name or nil
end

local function is_cor()
    local ok, r = pcall(function ()
        local p = player()
        return p:GetMainJob() == COR_JOB or p:GetSubJob() == COR_JOB
    end)
    return ok and r or false
end

local function main_is_cor()
    local ok, r = pcall(function () return player():GetMainJob() == COR_JOB end)
    return ok and r or false
end

-- Is nard switched on right now? (COR-only mode)
local function cor_active()
    if not cfg.cor_only then return true end
    local ok, r = pcall(function ()
        local p = player()
        if p:GetMainJob() == COR_JOB then return true end
        return cfg.cor_sub and p:GetSubJob() == COR_JOB
    end)
    return ok and r or false
end

-- Are there other people in my party / alliance?
local function in_party()
    local ok, r = pcall(function ()
        local p = party()
        for i = 1, 17 do
            if p:GetMemberIsActive(i) == 1 and p:GetMemberServerId(i) ~= 0 then return true end
        end
        return false
    end)
    return ok and r or false
end

-- Hidden because you've been out of a party for cfg.solo_mins minutes?
local solo = { since = nil, hidden = false }
local function solo_update(now)
    if not cfg.solo_hide then
        if solo.hidden then dlog.add('INFO', 'Solo hide turned off - nard shown') end
        solo.since, solo.hidden = nil, false
        return
    end
    if in_party() then
        if solo.hidden then dlog.add('INFO', 'Joined a party - nard shown again') end
        solo.since, solo.hidden = nil, false
        return
    end
    if solo.since == nil then
        solo.since = now
        dlog.add('INFO', ('Not in a party - nard hides in %d min unless you join one'):format(tonumber(cfg.solo_mins) or 6), true)
    end
    local limit = (tonumber(cfg.solo_mins) or 6) * 60
    if not solo.hidden and now - solo.since >= limit then
        solo.hidden = true
        dlog.add('INFO', ('Out of a party for %d min - nard hidden until you join one'):format(tonumber(cfg.solo_mins) or 6))
    end
end

local function i_am_dead()
    local ok, r = pcall(function ()
        local idx = party():GetMemberTargetIndex(0)
        local st  = AshitaCore:GetMemoryManager():GetEntity():GetStatus(idx)
        return st == 2 or st == 3
    end)
    return ok and r or false
end

local function fmt_time(sec)
    sec = math.max(0, math.floor(sec))
    return ('%d:%02d'):format(math.floor(sec / 60), sec % 60)
end

local function anim_time()
    if imgui.GetTime then return imgui.GetTime() end
    return os.clock()
end

----------------------------------------------------------------------------
-- action packet (0x028) parsing
----------------------------------------------------------------------------
local function parse_action(e)
    local raw     = e.data_raw
    local maxbits = e.size * 8
    local off     = 40
    local function bits(n)
        if off + n > maxbits then error('action packet overrun') end
        local v = ashita.bits.unpack_be(raw, 0, off, n)
        off = off + n
        return v
    end

    local act = { targets = {} }
    act.actor = bits(32)
    local tcount = bits(6)
    off = off + 4
    act.category = bits(4)
    if act.category ~= 6 then return act end   -- only job abilities matter

    act.param = bits(16)
    off = off + 16
    act.recast = bits(32)

    for _ = 1, tcount do
        local t = { id = bits(32), actions = {} }
        local acount = bits(4)
        for _ = 1, acount do
            local a = {}
            a.reaction  = bits(5)
            a.animation = bits(12)
            a.effect    = bits(7)
            a.knockback = bits(3)
            a.param     = bits(17)
            a.message   = bits(10)
            a.flags     = bits(31)
            if bits(1) == 1 then
                local d = bits(10); local p = bits(17); local m = bits(10)
                a.add = { d, p, m }
            end
            if bits(1) == 1 then
                local d = bits(10); local p = bits(14); local m = bits(10)
                a.spike = { d, p, m }
            end
            t.actions[#t.actions + 1] = a
        end
        act.targets[#act.targets + 1] = t
    end
    return act
end

-- The action packet carries the job ability id directly (rolls 98-117,
-- Double-Up 123) - same as XIUI's tracker.
local function resolve_roll(param)
    local def = rolls.by_id[param]
    if def then return def, def.name, 'id' end
    if param == DOUBLE_UP_ID then return nil, 'Double-Up', 'double-up' end
    return nil, nil, nil
end

----------------------------------------------------------------------------
-- roll tracking
----------------------------------------------------------------------------
local function remove_entry(entry)
    for i, e in ipairs(state.active) do
        if e == entry then table.remove(state.active, i) return end
    end
end

local function overlaps(a, b)
    if a == nil or b == nil then return true end
    for id in pairs(a) do
        if b[id] then return true end
    end
    return false
end

-- Same roll name AND the same group of people (a Chaos Roll on the melee is
-- a different effect from a Chaos Roll on the mages).
local function find_entry(actor, name, targets)
    for _, e in ipairs(state.active) do
        if e.actor == actor and e.def.name == name and overlaps(e.targets, targets) then return e end
    end
    return nil
end

local MAGE_JOBS = { [3] = true, [4] = true, [5] = true, [10] = true, [15] = true }  -- WHM BLM RDM BRD SMN

-- Labels a roll by who it landed on: MELEE, MAGES, SELF or PARTY.
local function classify(actor, targets)
    if actor ~= my_id() then return 'PARTY' end
    local melee, mage = 0, 0
    pcall(function ()
        local p = party()
        for i = 1, 17 do
            local id = p:GetMemberServerId(i)
            if id ~= 0 and targets[id] then
                if MAGE_JOBS[p:GetMemberMainJob(i)] then mage = mage + 1 else melee = melee + 1 end
            end
        end
    end)
    if melee == 0 and mage == 0 then return 'SELF' end
    return (mage > melee) and 'MAGES' or 'MELEE'
end

local ROW_ORDER = { MELEE = 1, MAGES = 2, SELF = 3, PARTY = 4 }

local function latest_du_entry(actor)
    local best = nil
    local now = os.time()
    for _, e in ipairs(state.active) do
        if e.actor == actor and e.du_until and now <= e.du_until then
            if best == nil or e.started > best.started then best = e end
        end
    end
    return best
end

-- Rolls stay on whoever they hit, so a Corsair rotating melee -> mages can
-- have 4 rolls out at once. Keep at most MAX_PER_COR per Corsair (oldest drops).
local MAX_PER_COR = 4
local function enforce_cap(actor)
    while true do
        local count, oldest = 0, nil
        for _, e in ipairs(state.active) do
            if e.actor == actor then
                count = count + 1
                if oldest == nil or e.started < oldest.started then oldest = e end
            end
        end
        if count < MAX_PER_COR or oldest == nil then return end
        dlog.add('ROLL', ('%s dropped (more than %d rolls out)'):format(oldest.def.name, MAX_PER_COR))
        remove_entry(oldest)
    end
end

local function on_action(act)
    local def, name, how = resolve_roll(act.param)
    local is_du = (how == 'double-up')
    if def == nil and not is_du then
        if act.actor == my_id() then
            dlog.add('PKT', ('JA param=%d name=%s - not a roll'):format(act.param, tostring(name)), true)
        end
        return
    end

    local me = my_id()
    local mine = (act.actor == me)
    local tgt, hits_me = nil, false
    for _, t in ipairs(act.targets) do
        if t.id == me then tgt = t; hits_me = true; break end
    end
    if tgt == nil then tgt = act.targets[1] end
    if tgt == nil or tgt.actions[1] == nil then
        dlog.add('ERR', 'Roll packet had no target data')
        return
    end

    if not mine then
        if not hits_me then
            dlog.add('PKT', ('Roll by %d ignored - not in range of you'):format(act.actor), true)
            return
        end
        if not cfg.show_party then
            dlog.add('PKT', ('Roll by %s ignored - party rolls off'):format(member_name(act.actor) or act.actor), true)
            return
        end
    end

    local a = tgt.actions[1]
    local total, message = a.param, a.message
    dlog.add('PKT', ('actor=%d param=%d (%s via %s) total=%d msg=%d'):format(
        act.actor, act.param, tostring(name), tostring(how), total, message), true)

    local targets = {}
    for _, t in ipairs(act.targets) do targets[t.id] = true end

    local entry = nil
    if def ~= nil then
        -- a Double-Up always continues the roll whose window is open
        local open = latest_du_entry(act.actor)
        if open ~= nil and open.def.name == def.name and not MSG_INITIAL[message] then
            entry = open
        else
            entry = find_entry(act.actor, def.name, targets)
        end
    else
        entry = latest_du_entry(act.actor)
        if entry == nil then
            dlog.add('ERR', 'Double-Up seen but no open roll to attach it to')
            return
        end
        def = entry.def
    end

    local now = os.time()
    local is_double
    if MSG_DOUBLE[message] then
        is_double = true
    elseif MSG_INITIAL[message] then
        is_double = false
    else
        is_double = is_du or (entry ~= nil and entry.du_until ~= nil and now <= entry.du_until)
    end

    local busted = (message == MSG_BUST) or total > 11

    if entry == nil or not is_double then
        if entry ~= nil then remove_entry(entry) end
        enforce_cap(act.actor)
        entry = {
            id         = state.next_id,
            actor      = act.actor,
            actor_name = mine and 'you' or (member_name(act.actor) or '?'),
            def        = def,
            mine       = mine,
            started    = now,
            targets    = targets,
            group      = classify(act.actor, targets),
        }
        dlog.add('ROLL', ('%s placed in %s row (%d targets)'):format(def.name, entry.group, #act.targets), true)
        state.next_id = state.next_id + 1
        table.insert(state.active, entry)
        if not busted then
            dlog.add('ROLL', ('%s %s -> %d (%s)%s'):format(entry.actor_name, def.name, total,
                rolls.effect_text(def, total),
                (total == def.lucky and ' LUCKY') or (total == def.unlucky and ' unlucky') or ''))
        end
    else
        -- this server resets the roll's 5 min on Double-Up too (per XIUI)
        entry.started = now
        if not busted then
            dlog.add('DBLUP', ('%s Double-Up %s -> %d (%s)'):format(entry.actor_name, def.name, total,
                rolls.effect_text(def, total)))
        end
    end

    entry.busted = busted
    if busted then
        entry.bust_total = (total > 11) and total or nil
        entry.du_until = nil
        dlog.add('BUST', ('%s busted %s%s'):format(entry.actor_name, def.name,
            entry.bust_total and (' at ' .. entry.bust_total) or ''))
    else
        entry.value = total
        if total == 11 then entry.smash_pending = true elseif total == def.lucky then entry.burst_pending = true end
        if mine and total < 11 then
            entry.du_until = now + DU_WINDOW
        else
            entry.du_until = nil
        end
    end

    -- only your newest roll can be doubled-up
    if mine then
        for _, e in ipairs(state.active) do
            if e ~= entry and e.mine then e.du_until = nil end
        end
    end
end

-- Real buff check: drop a die once nobody it landed on still has the roll's
-- buff (level sync on/off, dispel, death, wore off early). Uses your own buff
-- list and the party buff packet (0x076). Roll status id = ability id + 212.
local BUST_STATUS = 309
local party_buffs = {}   -- [server id] = { [status id] = true }

local function parse_party_buffs(data)
    for i = 0, 4 do
        local base = 0x04 + i * 0x30
        local id = struct.unpack('I', data, base + 1)
        if id ~= nil and id ~= 0 then
            local lo  = struct.unpack('I', data, base + 0x08 + 1)
            local hi  = struct.unpack('I', data, base + 0x0C + 1)
            local set = {}
            for j = 0, 31 do
                local b = data:byte(base + 0x10 + j + 1)
                if b ~= nil and b ~= 0xFF then
                    local word = (j < 16) and lo or hi
                    local high = bit.band(bit.rshift(word, (j % 16) * 2), 3)
                    set[b + 256 * high] = true
                end
            end
            party_buffs[id] = set
        end
    end
end

local function my_buffs()
    local set = {}
    pcall(function ()
        for _, v in pairs(player():GetBuffs()) do
            if v ~= nil and v > 0 and v ~= 255 then set[v] = true end
        end
    end)
    return set
end

local last_verify = 0
local function verify_buffs(now)
    if now == last_verify then return end     -- once a second is plenty
    last_verify = now
    local me, mine = my_id(), my_buffs()
    for i = #state.active, 1, -1 do
        local e = state.active[i]
        if e.targets ~= nil and now - e.started >= 3 then
            local status = e.busted and BUST_STATUS or (e.def.id + 212)
            local seen, has, unknown = false, false, 0
            for id in pairs(e.targets) do
                if id == me then
                    seen = true
                    if mine[status] then has = true end
                elseif not e.busted then
                    local pb = party_buffs[id]
                    if pb == nil then unknown = unknown + 1
                    else
                        seen = true
                        if pb[status] then has = true end
                    end
                end
            end
            if seen and not has and unknown == 0 then
                dlog.add('ROLL', ('%s removed - nobody it hit still has the buff (sync / dispel / wore off)'):format(e.def.name))
                table.remove(state.active, i)
            end
        end
    end
end

----------------------------------------------------------------------------
-- Keep rolls across reloads / updates: save to a small file whenever they
-- change, restore on load (still-running ones only), then fill in any roll
-- buff you have that nard has no record of (shown with a "?").
----------------------------------------------------------------------------
local roll_file_dir = nil
local function roll_file()
    local ok, name = pcall(function () return party():GetMemberName(0) end)
    if not ok or name == nil or name == '' then return nil end
    local base = AshitaCore:GetInstallPath()
    if roll_file_dir == nil then
        local mk = ashita.fs.create_directory or ashita.fs.create_dir
        if mk then
            pcall(mk, base .. '\\config')
            pcall(mk, base .. '\\config\\addons')
            pcall(mk, base .. '\\config\\addons\\nard')
        end
        roll_file_dir = base .. '\\config\\addons\\nard'
    end
    return ('%s\\rolls_%s.txt'):format(roll_file_dir, name)
end

local last_sig, last_save_check = nil, 0
local function save_rolls(force)
    if state.testing then return end
    local now = os.time()
    if not force and now == last_save_check then return end
    last_save_check = now
    local lines, sig = {}, {}
    for _, e in ipairs(state.active) do
        local tg = {}
        for id in pairs(e.targets or {}) do tg[#tg + 1] = tostring(id) end
        local l = table.concat({
            e.def.id, e.value or 0, e.started, e.group or 'MELEE', e.busted and 1 or 0, e.bust_total or 0,
            e.mine and 1 or 0, e.actor or 0, e.unknown and 1 or 0, table.concat(tg, ','),
        }, '|')
        lines[#lines + 1] = l
        sig[#sig + 1] = l
    end
    local s = table.concat(sig, ';')
    if not force and s == last_sig then return end
    local path = roll_file()
    if path == nil then return end
    local f = io.open(path, 'w')
    if f == nil then dlog.add('ERR', 'Could not save rolls to ' .. path) return end
    f:write(table.concat(lines, '\n'))
    f:close()
    last_sig = s
    dlog.add('INFO', ('Saved %d roll(s)'):format(#lines), true)
end

local function split(str, sep)
    local out = {}
    for part in (str .. sep):gmatch('(.-)' .. sep:gsub('%p', '%%%0')) do out[#out + 1] = part end
    return out
end

local restored = false
local function restore_rolls()
    if restored or state.testing then return end
    local me = my_id()
    if me == 0 then return end              -- wait until the character is loaded
    restored = true
    local now, count = os.time(), 0

    local path = roll_file()
    local f = path and io.open(path, 'r')
    if f then
        for line in f:lines() do
            local p = split(line, '|')
            local def = rolls.by_id[tonumber(p[1] or '')]
            local started = tonumber(p[3] or '')
            if def and started and now - started < ROLL_DURATION then
                local tg = {}
                for id in (p[10] or ''):gmatch('%d+') do tg[tonumber(id)] = true end
                local v = tonumber(p[2]) or 0
                local e = {
                    id = state.next_id, def = def, value = (v > 0) and v or nil, started = started,
                    group = p[4] ~= '' and p[4] or 'MELEE', busted = p[5] == '1',
                    bust_total = (tonumber(p[6]) or 0) > 0 and tonumber(p[6]) or nil,
                    mine = p[7] == '1', actor = tonumber(p[8]) or 0, unknown = p[9] == '1',
                    targets = next(tg) and tg or nil,
                }
                e.actor_name = e.mine and 'you' or (member_name(e.actor) or '?')
                state.next_id = state.next_id + 1
                table.insert(state.active, e)
                count = count + 1
            end
        end
        f:close()
    end

    -- roll buffs on you that nard has no record of
    local mine, extra = my_buffs(), 0
    for _, def in ipairs(rolls.list) do
        if mine[def.id + 212] then
            local known = false
            for _, e in ipairs(state.active) do
                if e.def == def and not e.busted and (e.targets == nil or e.targets[me]) then known = true end
            end
            if not known then
                table.insert(state.active, {
                    id = state.next_id, def = def, value = nil, started = now, unknown = true,
                    group = 'SELF', mine = false, actor = 0, actor_name = '?', targets = { [me] = true },
                })
                state.next_id = state.next_id + 1
                extra = extra + 1
            end
        end
    end
    if count + extra > 0 then
        dlog.add('ROLL', ('Restored %d roll(s) from last session, %d found on your buffs'):format(count, extra))
    end
    last_sig = nil
end

local was_active = nil
local function tick()
    local active = cor_active()
    if active ~= was_active then
        if was_active ~= nil then
            dlog.add('INFO', active and 'COR detected - nard on' or 'Not on COR - nard off (hidden, not tracking)')
        end
        if not active and not state.testing then state.active = {} end
        was_active = active
    end
    if not active and not state.testing then return end
    local now = os.time()
    if now ~= state.solo_tick then state.solo_tick = now; solo_update(now) end
    if not state.testing then
        restore_rolls()
        verify_buffs(now)
        save_rolls(false)
    end
    for i = #state.active, 1, -1 do
        local e = state.active[i]
        if now >= e.started + ROLL_DURATION then
            dlog.add('ROLL', ('%s expired'):format(e.def.name))
            table.remove(state.active, i)
        elseif e.du_until and now > e.du_until then
            e.du_until = nil
            dlog.add('DBLUP', ('Double-Up window closed for %s'):format(e.def.name), true)
        end
    end
    if not state.testing and #state.active > 0 and i_am_dead() then
        state.active = {}
        dlog.add('ROLL', 'You died - all roll effects cleared')
    end
end

local test_presets = {
    -- melee pair + mage pair (your usual rotation)
    function (now)
        return {
            { group = 'MELEE', def = rolls.by_name["chaos roll"],     value = 4,  started = now - 150 },
            { group = 'MELEE', def = rolls.by_name["samurai roll"],   value = 9,  started = now - 120 },
            { group = 'MAGES', def = rolls.by_name["evoker's roll"],  value = 5,  started = now - 40 },
            { group = 'MAGES', def = rolls.by_name["wizard's roll"],  value = 8,  started = now - 12, du_until = now + 33 },
        }
    end,
    function (now)
        return {
            { group = 'MELEE', def = rolls.by_name["hunter's roll"],  value = 4,  started = now - 88 },
            { group = 'MELEE', def = rolls.by_name["corsair's roll"], value = 8,  started = now - 16, du_until = now + 15 },
        }
    end,
    function (now)
        return {
            { group = 'MELEE', def = rolls.by_name["fighter's roll"], value = 11, started = now - 250 },
            { group = 'MELEE', def = rolls.by_name["rogue's roll"],   value = 9,  started = now - 230 },
            { group = 'MAGES', def = rolls.by_name["warlock's roll"], value = 8,  started = now - 60 },
            { group = 'MAGES', def = rolls.by_name["magus's roll"],   value = 10, started = now - 10, busted = true, bust_total = 14 },
        }
    end,
}

local function test_rolls()
    state.test_i = (state.test_i % #test_presets) + 1
    local now, me = os.time(), my_id()
    state.active = {}
    for _, p in ipairs(test_presets[state.test_i](now)) do
        p.id = state.next_id; state.next_id = state.next_id + 1
        p.actor = me; p.actor_name = 'you'; p.mine = true
        if not p.busted and p.value == 11 then p.smash_pending = true
        elseif not p.busted and p.value == p.def.lucky then p.burst_pending = true end
        table.insert(state.active, p)
    end
    state.testing = true
    dlog.add('CMD', ('Test preset %d loaded'):format(state.test_i))
end

----------------------------------------------------------------------------
-- drawing helpers
----------------------------------------------------------------------------
local function col32(c) return imgui.GetColorU32(c) end

-- Sized text goes through the window draw list: AddText(font, size, pos, col, text).
-- (SetWindowFontScale doesn't exist in newer Ashita ImGui builds.)
-- If a build can't do sized text either, fall back to the default font size.
local sized_text = nil   -- nil = untested, true / false after first try

local function dl_text(dl, sx, sy, col, txt, size)
    if sized_text ~= false then
        local ok = pcall(function () dl:AddText(imgui.GetFont(), size, { sx, sy }, col, txt) end)
        if ok then sized_text = true return end
        sized_text = false
        dlog.add('ERR', 'Sized text not supported by this ImGui build - using default size')
    end
    dl:AddText({ sx, sy }, col, txt)
end

local function text_size(txt, fscale)
    local w, h = imgui.CalcTextSize(txt)
    if sized_text == false then return w, h end
    return w * fscale, h * fscale
end

-- x, y are window-relative (same space as SetCursorPos).
local function text_at(x, y, col, txt, fscale, outline)
    local dl     = imgui.GetWindowDrawList()
    local wx, wy = imgui.GetWindowPos()
    local size   = imgui.GetFontSize() * fscale
    local sx, sy = wx + x, wy + y
    if outline then
        -- full outline so text reads on any background (no frame behind it)
        local oc = col32({ 0, 0, 0, 0.90 })
        dl_text(dl, sx + 1, sy + 1, oc, txt, size)
        dl_text(dl, sx - 1, sy + 1, oc, txt, size)
        dl_text(dl, sx + 1, sy - 1, oc, txt, size)
        dl_text(dl, sx - 1, sy - 1, oc, txt, size)
    end
    dl_text(dl, sx, sy, col32(col), txt, size)
end

-- Small round icon button: 'min', 'max', 'close', 'help'
local function round_button(id, kind, r)
    local clicked = imgui.InvisibleButton(id, { r * 2, r * 2 })
    local hovered = imgui.IsItemHovered()
    local x1, y1 = imgui.GetItemRectMin()
    local cx, cy = x1 + r, y1 + r
    local dl = imgui.GetWindowDrawList()
    local ring = hovered and C.gold or C.steel
    if kind == 'close' and hovered then ring = C.red end

    dl:AddCircleFilled({ cx, cy }, r, col32(hovered and { 0.96, 0.74, 0.26, 0.28 } or { 0.05, 0.06, 0.09, 0.75 }), 20)
    dl:AddCircle({ cx, cy }, r, col32(ring), 20, 1.3)

    local g  = r * 0.45
    local gc = col32(hovered and C.cream or C.steel)
    if kind == 'min' then
        dl:AddLine({ cx - g, cy }, { cx + g, cy }, gc, 1.6)
    elseif kind == 'max' then
        dl:AddLine({ cx - g, cy }, { cx + g, cy }, gc, 1.6)
        dl:AddLine({ cx, cy - g }, { cx, cy + g }, gc, 1.6)
    elseif kind == 'close' then
        dl:AddLine({ cx - g, cy - g }, { cx + g, cy + g }, gc, 1.6)
        dl:AddLine({ cx - g, cy + g }, { cx + g, cy - g }, gc, 1.6)
    elseif kind == 'help' then
        local tw, th = imgui.CalcTextSize('?')
        dl:AddText({ cx - tw / 2, cy - th / 2 }, gc, '?')
    elseif kind == 'gear' then
        local spin = hovered and (os.clock() * 1.5) or 0
        for k = 0, 7 do
            local a = spin + k * math.pi / 4
            dl:AddLine({ cx + math.cos(a) * r * 0.30, cy + math.sin(a) * r * 0.30 },
                       { cx + math.cos(a) * r * 0.66, cy + math.sin(a) * r * 0.66 }, gc, r * 0.26)
        end
        dl:AddCircleFilled({ cx, cy }, r * 0.46, gc, 16)
        dl:AddCircleFilled({ cx, cy }, r * 0.19, col32(hovered and { 0.30, 0.24, 0.12, 1 } or { 0.05, 0.06, 0.09, 1 }), 12)
    elseif kind == 'bug' then
        local by = cy + r * 0.10
        for k = -1, 1 do                                   -- legs
            local ly = by + k * r * 0.20
            dl:AddLine({ cx - r * 0.22, ly }, { cx - r * 0.56, ly + k * r * 0.14 }, gc, 1.1)
            dl:AddLine({ cx + r * 0.22, ly }, { cx + r * 0.56, ly + k * r * 0.14 }, gc, 1.1)
        end
        dl:AddLine({ cx - r * 0.08, cy - r * 0.36 }, { cx - r * 0.26, cy - r * 0.58 }, gc, 1.1)   -- antennae
        dl:AddLine({ cx + r * 0.08, cy - r * 0.36 }, { cx + r * 0.26, cy - r * 0.58 }, gc, 1.1)
        dl:AddCircleFilled({ cx, cy - r * 0.26 }, r * 0.17, gc, 12)                              -- head
        dl:AddCircleFilled({ cx, by }, r * 0.30, gc, 14)                                          -- body
        dl:AddLine({ cx, by - r * 0.26 }, { cx, by + r * 0.28 },
            col32(hovered and { 0.30, 0.24, 0.12, 1 } or { 0.05, 0.06, 0.09, 1 }), 1.0)            -- wing split
    end
    return clicked, hovered
end

local function tooltip_text(text)
    imgui.BeginTooltip()
    imgui.PushTextWrapPos(280)
    imgui.TextColored(C.cream, text)
    imgui.PopTextWrapPos()
    imgui.EndTooltip()
end

local function help_marker(id, text)
    imgui.SameLine()
    imgui.SetCursorPosY(imgui.GetCursorPosY() + 3)
    local _, hov = round_button(id, 'help', 6.5)
    if hov then tooltip_text(text) end
end

local n_colors, n_vars = 0, 0
local function push_theme()
    local cols = {
        { ImGuiCol_WindowBg,         C.bg },
        { ImGuiCol_ChildBg,          { 0.04, 0.05, 0.07, 0.90 } },
        { ImGuiCol_PopupBg,          C.bg },
        { ImGuiCol_Border,           { 0.96, 0.74, 0.26, 0.35 } },
        { ImGuiCol_Text,             C.cream },
        { ImGuiCol_FrameBg,          C.bg2 },
        { ImGuiCol_FrameBgHovered,   { 0.19, 0.21, 0.28, 1.0 } },
        { ImGuiCol_FrameBgActive,    { 0.23, 0.26, 0.34, 1.0 } },
        { ImGuiCol_CheckMark,        C.gold },
        { ImGuiCol_SliderGrab,       C.gold },
        { ImGuiCol_SliderGrabActive, C.flame },
        { ImGuiCol_Button,           { 0.16, 0.18, 0.24, 1.0 } },
        { ImGuiCol_ButtonHovered,    { 0.55, 0.42, 0.16, 1.0 } },
        { ImGuiCol_ButtonActive,     { 0.75, 0.56, 0.18, 1.0 } },
        { ImGuiCol_Header,           { 0.55, 0.42, 0.16, 0.60 } },
        { ImGuiCol_HeaderHovered,    { 0.75, 0.56, 0.18, 0.70 } },
        { ImGuiCol_HeaderActive,     { 0.85, 0.64, 0.20, 0.80 } },
        { ImGuiCol_Separator,        { 0.96, 0.74, 0.26, 0.25 } },
    }
    for _, c in ipairs(cols) do imgui.PushStyleColor(c[1], c[2]) end
    n_colors = #cols
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 10)
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 6)
    imgui.PushStyleVar(ImGuiStyleVar_ChildRounding, 6)
    imgui.PushStyleVar(ImGuiStyleVar_PopupRounding, 8)
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1)
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 10, 8 })
    n_vars = 6
end

local function pop_theme()
    imgui.PopStyleVar(n_vars)
    imgui.PopStyleColor(n_colors)
end

-- Custom slim header: title + stylish minimize / close buttons.
local function window_header(title, W, ws)
    local x0, y0 = imgui.GetCursorPosX(), imgui.GetCursorPosY()
    imgui.SetCursorPosY(y0 + 1)
    imgui.TextColored(C.gold, title)
    local r = 7
    imgui.SameLine()
    imgui.SetCursorPos({ x0 + W - r * 4 - 6, y0 })
    if round_button('##min_' .. title, ws.min and 'max' or 'min', r) then
        ws.min = not ws.min
        dlog.add('UI', ('%s %s'):format(title, ws.min and 'minimized' or 'restored'))
    end
    imgui.SameLine()
    imgui.SetCursorPos({ x0 + W - r * 2, y0 })
    if round_button('##cls_' .. title, 'close', r) then
        ws.open = false
        dlog.add('UI', title .. ' closed')
    end
end

----------------------------------------------------------------------------
-- overlay
----------------------------------------------------------------------------
local OVERLAY_HELP = table.concat({
    'nard - floating Corsair rolls',
    'Drag the empty area to move (unless locked).',
    '',
    'Flames = Lucky   Gold = 11',
    'Icicles = Unlucky   Red = Bust (penalty shown)',
    'Bust % = chance your next Double-Up busts.',
    'Small number beside it = Double-Up seconds left.',
    'Up to 4 of your rolls: MELEE row + MAGES row,',
    'sorted by the jobs each roll landed on.',
    '',
    'Right-click: separate pieces, lock, settings',
    '',
    '/nard          settings',
    '/nard test     preview rolls',
    '/nard min      minimize',
    '/nard lock     lock position',
    '/nard scale n  size',
    '/nard log      debug log',
    '',
    'Values are base (no gear), Lv75.',
}, '\n')

local function roll_tooltip(e, now)
    imgui.BeginTooltip()
    imgui.TextColored(C.gold, e.def.name)
    imgui.SameLine()
    imgui.TextColored(C.steel, '(' .. (e.actor_name or '?') .. ')')
    imgui.TextColored(C.cream, e.def.desc)
    imgui.TextColored(C.green, ('Lucky %d'):format(e.def.lucky))
    imgui.SameLine()
    imgui.TextColored(C.red, ('  Unlucky %d'):format(e.def.unlucky))
    imgui.Separator()
    for v = 1, 11 do
        local c = C.dim
        if v == e.value and not e.busted then c = C.gold
        elseif v == e.def.lucky then c = C.green
        elseif v == e.def.unlucky then c = C.red end
        local p = rolls.power(e.def, v, frame_jobs) or 0
        local ps = (math.abs(p % 1) < 0.05) and ('%d'):format(math.floor(p + 0.5)) or ('%.1f'):format(p)
        imgui.TextColored(c, ('%2d:%-4s'):format(v, ps))
        if v ~= 6 and v ~= 11 then imgui.SameLine() end
    end
    imgui.Separator()
    if e.busted then
        imgui.TextColored(C.red, 'BUSTED' .. (e.bust_total and (' at ' .. e.bust_total) or '')
            .. '  ' .. rolls.bust_text(e.def))
    end
    local _, boosted = rolls.power(e.def, 1, frame_jobs)
    if boosted then
        imgui.TextColored(C.green, ('Party job bonus included (+%s)'):format(
            tostring(e.def.bonus / (e.def.scale or 1))))
    end
    imgui.TextColored(C.steel, 'Time left ' .. fmt_time(e.started + ROLL_DURATION - now))
    imgui.TextColored(C.dim, 'LSB values, no Phantom Roll+ gear (Lv75).')
    imgui.EndTooltip()
end

local function draw_flames(dl, sx, sy, TS, t, S)
    for k = 3, 1, -1 do
        local g = k * 4 * S
        dl:AddRectFilled({ sx - g, sy - g }, { sx + TS + g, sy + TS + g },
            col32({ 1.0, 0.55, 0.10, 0.07 * (4 - k) }), 10 * S + g)
    end
    for k = 0, 5 do
        local fx    = sx + TS * (0.08 + k * 0.168)
        local base  = sy + TS * 0.14
        local tall  = (k == 2 or k == 3) and 0.08 or 0
        local h     = TS * (0.30 + tall + 0.08 * math.sin(t * 9 + k * 1.9))   -- tips stay under the name
        local sway  = math.sin(t * 6.3 + k * 2.3) * TS * 0.05
        local hw    = TS * 0.10
        dl:AddTriangleFilled({ fx - hw, base }, { fx + hw, base }, { fx + sway, base - h },
            col32({ 1.0, 0.42, 0.06, 0.92 }))
        dl:AddTriangleFilled({ fx - hw * 0.55, base }, { fx + hw * 0.55, base }, { fx + sway * 0.7, base - h * 0.62 },
            col32({ 1.0, 0.86, 0.28, 0.95 }))
    end
end

-- 4-point twinkle star (two crossed rays + bright core)
local function draw_star(dl, x, y, r, a)
    if a <= 0.02 then return end
    local c1 = col32({ 0.85, 0.95, 1.00, a })
    local c2 = col32({ 1.00, 1.00, 1.00, a })
    dl:AddLine({ x - r, y }, { x + r, y }, c1, 1.2)
    dl:AddLine({ x, y - r }, { x, y + r }, c1, 1.2)
    dl:AddLine({ x - r * 0.45, y - r * 0.45 }, { x + r * 0.45, y + r * 0.45 }, c1, 0.8)
    dl:AddLine({ x - r * 0.45, y + r * 0.45 }, { x + r * 0.45, y - r * 0.45 }, c1, 0.8)
    dl:AddCircleFilled({ x, y }, r * 0.28, c2, 8)
end

-- Ice shine on top of the die: sweeping glint + twinkling sparkles.
local function draw_ice_shine(dl, sx, sy, TS, t, S)
    -- diagonal glint: parallel lines on x + y = c, cut exactly to the face
    -- (no clip rect needed), sweeping every ~3.2s with a pause between passes
    local m      = 3 * S
    local span   = TS - m * 2
    local cycle  = 3.2
    local phase  = (t % cycle) / cycle            -- 0..1
    local c      = (-0.35 + phase * 2.9) * span    -- runs off both ends = pause
    for k = -4, 4 do
        local cc = c + k * 1.6 * S
        local a  = 0.55 * (1 - math.abs(k) / 5)
        local u0 = math.max(0, cc - span)
        local u1 = math.min(span, cc)
        if u1 > u0 then
            dl:AddLine({ sx + m + u0, sy + m + (cc - u0) }, { sx + m + u1, sy + m + (cc - u1) },
                col32({ 1.0, 1.0, 1.0, a }), 1.6 * S)
        end
    end

    -- sparkles around the die and at icicle tips (each twinkles on its own beat)
    local spots = {
        { -0.10, 0.08, 4.5, 0.0 }, { 1.10, 0.22, 3.5, 1.7 }, { 0.92, -0.10, 3.0, 3.1 },
        { 0.17, 1.21, 3.0, 4.4 },  { 0.50, 1.25, 3.5, 2.4 }, { 0.83, 1.18, 2.8, 5.3 },
        { 0.30, 0.20, 2.6, 0.9 },
    }
    for _, p in ipairs(spots) do
        local w = math.sin(t * 2.6 + p[4])
        local a = (w > 0) and (w ^ 3) or 0
        draw_star(dl, sx + TS * p[1], sy + TS * p[2], p[3] * S * (0.6 + 0.4 * a), a)
    end
end

-- Frosty breathing glow (drawn BEHIND the die).
local function draw_frost_glow(dl, sx, sy, TS, t, S)
    local pulse = 0.70 + 0.30 * math.sin(t * 2.2)
    for k = 3, 1, -1 do
        local g = k * 4 * S
        dl:AddRectFilled({ sx - g, sy - g }, { sx + TS + g, sy + TS + g },
            col32({ 0.30, 0.68, 1.00, 0.08 * (4 - k) * pulse }), 10 * S + g)
    end
end

local function draw_icicles(dl, sx, sy, TS, t, S)
    local base = sy + TS * 0.93
    local lengths = { 0.26, 0.17, 0.30, 0.15, 0.23 }
    for k = 1, 5 do
        local ph  = t * 1.5 + k * 2.3
        local sh  = math.sin(ph)
        local ix  = sx + TS * (0.17 + 0.165 * (k - 1))
        local w   = TS * (0.072 + 0.010 * math.cos(ph))
        local len = TS * (lengths[k] + 0.02 * sh)
        dl:AddTriangleFilled({ ix - w, base }, { ix + w, base }, { ix, base + len },
            col32({ 0.45, 0.75, 0.95, 0.85 }))
        dl:AddTriangleFilled({ ix - w * 0.42, base }, { ix + w * 0.42, base }, { ix, base + len * 0.62 },
            col32({ 0.90, 0.97, 1.00, 0.75 + sh * 0.2 }))
    end
end

----------------------------------------------------------------------------
-- styled layout: glass row panels, status chips, slim timers
----------------------------------------------------------------------------
local ROW_TINT = {
    MELEE = { 0.96, 0.74, 0.26 },
    MAGES = { 0.55, 0.72, 1.00 },
    SELF  = { 0.72, 0.76, 0.84 },
    PARTY = { 0.72, 0.80, 0.95 },
}

local STATE = {
    normal  = { name = { 0.80, 0.84, 0.90, 1 }, eff = C.cream },
    lucky   = { name = C.gold, eff = { 1.00, 0.86, 0.40, 1 }, chip = 'LUCKY',
                bg = { 0.42, 0.22, 0.04, 0.96 }, fg = { 1.00, 0.88, 0.55, 1 }, bd = { 1.00, 0.62, 0.18, 1 } },
    max     = { name = C.gold, eff = C.gold, chip = 'MAX',
                bg = { 0.42, 0.30, 0.04, 0.96 }, fg = { 1.00, 0.92, 0.60, 1 }, bd = { 1.00, 0.80, 0.30, 1 } },
    unlucky = { name = { 0.62, 0.85, 1.00, 1 }, eff = { 0.72, 0.90, 1.00, 1 }, chip = 'UNLUCKY',
                bg = { 0.06, 0.18, 0.32, 0.96 }, fg = { 0.78, 0.92, 1.00, 1 }, bd = { 0.45, 0.77, 0.98, 1 } },
    bust    = { name = C.red, eff = C.red, chip = 'BUST',
                bg = { 0.36, 0.05, 0.05, 0.96 }, fg = { 1.00, 0.78, 0.75, 1 }, bd = { 1.00, 0.35, 0.32, 1 } },
}

local function roll_state(e)
    local v = e.value or 0
    if e.busted then return 'bust' end
    if v == 11 then return 'max' end
    if v == e.def.lucky then return 'lucky' end
    if v == e.def.unlucky then return 'unlucky' end
    return 'normal'
end

local function shows_du(e)
    return cfg.show_bust and e.mine and e.du_until ~= nil and not e.busted and (e.value or 0) < 11
end

local function layout(S)
    local m = { S = S }
    local sd, sn, si, sf = sz('s_die'), sz('s_name'), sz('s_info'), sz('s_fx')
    m.TS     = 46 * S * sd
    m.colW   = math.max(m.TS * 1.6 + 30 * S, 104 * S * math.max(sn, si))
    m.nscale = 0.82 * S * sn; m._d, m.nh = text_size('A', m.nscale)
    m.escale = 1.00 * S * si; m._d, m.eh = text_size('A', m.escale)
    m.tscale = 0.74 * S * si; m.tw, m.th = text_size('0:00', m.tscale)
    m.cscale = 0.62 * S * sd; m._d, m.ch = text_size('A', m.cscale)
    m.dscale = 0.74 * S * si; m._d, m.dh = text_size('A', m.dscale)
    m.flame  = 26 * S * sd * math.max(0.4, sf)   -- room for the fire crown above the die
    m.ice    = 16 * S * sd                       -- room for icicles / chip below the die
    m.barH   = 5 * S * si
    m.pillH  = m.dh + 5 * S
    m.padTop = 12 * S
    m.padBot = 9 * S
    m.padX   = 9 * S
    return m
end

local function row_height(m, has_du)
    local S = m.S
    local h = m.padTop + m.nh + m.flame + m.TS + m.ice + (m.eh + m.th + 15 * S) + m.padBot
    if has_du then h = h + 6 * S + m.pillH end
    return h
end

local function pill(dl, wx, wy, x, y, w, h, bg, bd)
    dl:AddRectFilled({ wx + x, wy + y }, { wx + x + w, wy + y + h }, col32(bg), h / 2)
    dl:AddRect({ wx + x, wy + y }, { wx + x + w, wy + y + h }, col32(bd), h / 2, ROUND_ALL, 1.0)
end

----------------------------------------------------------------------------
-- Lucky fire: ~170 soft layered particles (red rim, orange body, white-hot
-- core) rising from all four sides into a crown, plus backing, glow, smoke
-- and sparks. Fully deterministic from time - no per-frame state.
----------------------------------------------------------------------------
local function hash(n)
    local s = math.sin(n * 127.1 + 311.7) * 43758.5453
    return s - math.floor(s)
end

local FIRE_RAMP = {   -- p, r, g, b  (white-hot -> yellow -> orange -> red -> ember)
    { 0.00, 1.00, 0.965, 0.82 },
    { 0.20, 1.00, 0.81,  0.31 },
    { 0.45, 1.00, 0.50,  0.11 },
    { 0.72, 0.77, 0.18,  0.055 },
    { 1.00, 0.43, 0.094, 0.04 },
}
local function fire_ramp(p)
    if p < 0 then p = 0 elseif p > 1 then p = 1 end
    for k = 2, #FIRE_RAMP do
        local b = FIRE_RAMP[k]
        if p <= b[1] then
            local a = FIRE_RAMP[k - 1]
            local f = (p - a[1]) / (b[1] - a[1])
            return a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f, a[4] + (b[4] - a[4]) * f
        end
    end
    return 0.43, 0.094, 0.04
end

local FIRE_RISE = 0.72   -- crown height (1.0 = preview size)
local FIRE = {}
for i = 0, 169 do
    local r, r2 = hash(i), hash(i + 0.5)
    local q = { i = i }
    if r < 0.5 then        -- top edge: tallest over the middle (crown)
        q.u, q.v, q.side = 0.04 + r2 * 0.92, 0.08, 0
        q.rise = 0.55 + 0.55 * (1 - math.abs(q.u - 0.5) * 2) + hash(i + 0.1) * 0.25
    elseif r < 0.86 then   -- left / right edges, climbing up
        q.side = (r < 0.68) and -1 or 1
        q.u, q.v = (q.side < 0) and 0.02 or 0.98, 0.15 + r2 * 0.85
        q.rise = 0.35 + q.v * 0.7 + hash(i + 0.1) * 0.2
    else                   -- underneath
        q.u, q.v, q.side = 0.15 + r2 * 0.7, 0.98, 0
        q.rise = 0.35 + hash(i + 0.1) * 0.2
    end
    q.life  = 0.6 + hash(i + 0.25) * 0.45
    q.off   = hash(i + 0.75) * 3
    q.size  = 0.075 + hash(i + 0.2) * 0.055
    q.front = hash(i + 0.3) < 0.14
    FIRE[#FIRE + 1] = q
end

local function fire_particle(dl, q, x, y, TS, t, grow, pass, amul)
    local p = ((t + q.off) % q.life) / q.life
    if (pass == 0) ~= (p >= 0.45) then return end      -- older (cooler) ones first
    local bx, by = x + TS * q.u, y + TS * q.v
    local lean = q.side * TS * 0.06 * math.sin(math.pi * p)
    local turb = math.sin(t * 2.6 + q.i * 1.7 + p * 4.5) * 0.045 * TS * p
    local pull = (x + TS * 0.5 - bx) * 0.35 * p * p * ((q.side == 0) and 1 or 0.6)
    local px = bx + turb + lean + pull
    local py = by - TS * q.rise * FIRE_RISE * sz('s_fx') * p * grow
    local r = TS * q.size * ((p < 0.2) and (0.75 + 1.25 * p) or (1 - 0.8 * (p - 0.2) / 0.8)) * (0.6 + 0.4 * grow)
    if r < 0.4 then r = 0.4 end
    local a = ((p < 0.06) and (p / 0.06) or 1) * (1 - p) ^ 0.9 * 0.82 * grow * amul
    if a <= 0.01 then return end
    local r1, g1, b1 = fire_ramp(p)
    local r2, g2, b2 = fire_ramp(p * 0.55)
    dl:AddCircleFilled({ px, py }, r, col32({ r1, g1, b1, a }), 12)
    dl:AddCircleFilled({ px, py - r * 0.08 }, r * 0.62, col32({ r2, g2, b2, math.min(1, a * 1.05) }), 10)
    if p < 0.5 then
        dl:AddCircleFilled({ px, py - r * 0.12 }, r * 0.3, col32({ 1.0, 0.97, 0.87, a * (1 - p * 1.6) }), 8)
    end
end

local function fire_flicker(t) return 0.84 + 0.09 * math.sin(t * 13) + 0.07 * math.sin(t * 7.3) end

-- behind the die: dark backing, heat glow, smoke, main fire
local function draw_fire_back(dl, x, y, TS, t, grow, S)
    local cx = x + TS / 2
    for k = 5, 1, -1 do
        dl:AddCircleFilled({ cx, y + TS * 0.12 }, TS * (0.55 + 0.14 * k), col32({ 0.10, 0.04, 0.03, 0.035 * (6 - k) * grow }), 24)
    end
    local fl = fire_flicker(t)
    for k = 5, 1, -1 do
        local g = k * 4 * S
        dl:AddRectFilled({ x - g, y - g - k * 2.5 * S }, { x + TS + g, y + TS + g - k * 2.5 * S },
            col32({ 1.0, (90 + 14 * k) / 255, 0.08, 0.05 * (6 - k) * grow * fl }), 12 * S + g)
    end
    for i = 0, 11 do                                    -- faint smoke above
        local life = 2.4
        local p  = ((t + i * 0.6) % life) / life
        local sx = x + TS * (0.2 + 0.6 * hash(i + 9)) + math.sin(t * 1.2 + i) * 0.12 * TS * p
        local sy = y - TS * 0.45 - p * TS * 0.6
        local a  = 0.09 * (1 - p) * ((p < 0.15) and (p / 0.15) or 1) * grow
        dl:AddCircleFilled({ sx, sy }, TS * (0.07 + 0.12 * p), col32({ 0.15, 0.13, 0.13, a }), 14)
    end
    for pass = 0, 1 do
        for _, q in ipairs(FIRE) do
            if not q.front then fire_particle(dl, q, x, y, TS, t, grow, pass, 1) end
        end
    end
end

-- in front of the die: a few see-through licks + sparks with streaks
local function draw_fire_front(dl, x, y, TS, t, grow, S)
    for pass = 0, 1 do
        for _, q in ipairs(FIRE) do
            if q.front then fire_particle(dl, q, x, y, TS, t, grow, pass, 0.55) end
        end
    end
    for i = 0, 11 do
        local life = 1.0 + hash(i + 3) * 0.6
        local p  = ((t + i * 0.33) % life) / life
        local sx = x + TS * (0.1 + 0.8 * hash(i + 4)) + math.sin(t * 4 + i * 2) * 0.14 * TS * p
        local sy = y + TS * 0.1 - p * TS * 1.15
        local a  = (1 - p) * grow
        dl:AddLine({ sx, sy }, { sx - math.cos(t * 4 + i * 2) * 0.17 * S * 3, sy + 5 * S },
            col32({ 1.0, (210 - 70 * p) / 255, 0.35, a * 0.8 }), 1.4 * S)
        dl:AddCircleFilled({ sx, sy }, 1.0 * S, col32({ 1.0, 0.98, 0.82, a }), 8)
    end
end

-- hot inner edge on the die face (drawn with the die)
local function draw_hot_edge(dl, sx, sy, TS, rr, t, S, grow)
    local fl = fire_flicker(t)
    for k = 1, 4 do
        local d = k * 1.5 * S
        dl:AddRect({ sx + d, sy + d }, { sx + TS - d, sy + TS - d },
            col32({ 1.0, (110 + 25 * k) / 255, 0.12, (0.45 - k * 0.1) * fl * grow }), math.max(1, rr - k * S), ROUND_ALL, 1.5 * S)
    end
    dl:AddRect({ sx, sy }, { sx + TS, sy + TS }, col32({ 1.0, (120 + 50 * fl) / 255, 0.14, 1 }), rr, ROUND_ALL, 2.2 * S)
end

----------------------------------------------------------------------------
-- Explosion: plays once when a roll lands on Lucky or 11.
----------------------------------------------------------------------------
local BURST_TIME = 1.4

-- behind the die: shockwave rings + flash bloom
local function draw_burst_back(dl, cx, cy, TS, dt, S, gold)
    if dt < 0 or dt > BURST_TIME then return end
    if dt < 0.6 then
        local k = dt / 0.6
        for i = 0, 2 do
            local rad = TS * (0.6 + k * (1.2 + i * 0.3))
            local a = (1 - k) * (0.7 - i * 0.2)
            local c = gold and { 1.0, 0.89, 0.47, a } or { 1.0, 0.59, 0.16, a }
            dl:AddCircle({ cx, cy }, rad, col32(c), 40, (5 - i * 1.5) * S * (1 - k) + 1)
        end
    end
    if dt < 0.35 then
        local k = dt / 0.35
        for j = 6, 1, -1 do
            dl:AddCircleFilled({ cx, cy }, TS * (0.3 + k * 1.1) * j / 6,
                col32({ 1.0, (200 + 9 * (6 - j)) / 255, (120 + 20 * (6 - j)) / 255, 0.13 * (1 - k) }), 32)
        end
    end
end

-- in front: sparks flying out + falling embers (seeded per roll)
local function draw_burst_front(dl, cx, cy, TS, dt, S, gold, seed)
    if dt < 0 or dt > BURST_TIME then return end
    for k = 0, 25 do
        local life = 0.55 + hash(seed + k * 1.3) * 0.35
        if dt <= life then
            local f  = dt / life
            local a  = (k / 26) * math.pi * 2 + hash(seed + k * 2.1) * 0.25
            local sp = (70 + hash(seed + k * 3.7) * 90) * S
            local d  = TS * 0.5 + sp * (1 - (1 - f) ^ 2) * 0.8
            local px = cx + math.cos(a) * d
            local py = cy + math.sin(a) * d + 18 * S * f * f
            local L  = (6 + hash(seed + k * 5.9) * 8) * S * (1 - f * 0.6)
            local hot = hash(seed + k * 7.7) < 0.55
            local c  = hot and { 1.0, 0.94, 0.71, 1 - f } or (gold and { 1.0, 0.82, 0.35, 1 - f } or { 1.0, 0.47, 0.12, 1 - f })
            dl:AddLine({ px, py }, { px - math.cos(a) * L, py - math.sin(a) * L }, col32(c), 2 * S * (1 - f * 0.5))
        end
    end
    for k = 0, 9 do
        local life = 0.9 + hash(seed + 50 + k) * 0.4
        if dt <= life then
            local f  = dt / life
            local a  = hash(seed + 60 + k) * math.pi * 2
            local sp = (25 + hash(seed + 70 + k) * 40) * S
            local d  = TS * 0.5 + sp * (1 - (1 - f) ^ 2) * 0.8
            local px = cx + math.cos(a) * d
            local py = cy + math.sin(a) * d + 40 * S * f * f
            local c  = gold and { 1.0, 0.92, 0.59, 1 - f } or { 1.0, (180 - 60 * f) / 255, 0.24, 1 - f }
            dl:AddCircleFilled({ px, py }, (1.5 + hash(seed + 80 + k) * 1.5) * S * (1 - f * 0.5), col32(c), 8)
        end
    end
end

local function draw_die(dl, e, st, sx, sy, TS, t, S, grow)
    local rr = 9 * S
    if st == 'unlucky' then draw_frost_glow(dl, sx, sy, TS, t, S) end
    if st == 'max' then
        local pulse = 0.5 + 0.5 * math.sin(t * 4)
        for k = 3, 1, -1 do
            local g = k * 3.5 * S
            dl:AddRectFilled({ sx - g, sy - g }, { sx + TS + g, sy + TS + g },
                col32({ 1.0, 0.82, 0.30, (0.06 + 0.05 * pulse) * (4 - k) }), rr + g)
        end
    end
    local face, shade, border = { 0.97, 0.96, 0.93, 1 }, { 0.81, 0.80, 0.77, 1 }, { 0.30, 0.33, 0.38, 1 }
    if st == 'lucky' then face, shade, border = { 1.0, 0.94, 0.84, 1 }, { 0.91, 0.77, 0.58, 1 }, { 1.0, 0.62, 0.18, 1 }
    elseif st == 'max' then face, shade, border = { 1.0, 0.91, 0.58, 1 }, { 0.92, 0.74, 0.32, 1 }, { 0.85, 0.60, 0.12, 1 }
    elseif st == 'unlucky' then face, shade, border = { 0.88, 0.94, 0.99, 1 }, { 0.71, 0.80, 0.88, 1 }, { 0.45, 0.77, 0.98, 1 }
    elseif st == 'bust' then face, shade, border = { 0.36, 0.11, 0.13, 1 }, { 0.24, 0.07, 0.08, 1 }, { 1.0, 0.35, 0.32, 1 } end

    for k, a in ipairs({ 0.30, 0.16, 0.08 }) do   -- soft layered shadow
        local d = k * 1.5 * S
        dl:AddRectFilled({ sx - d * 0.3, sy + d }, { sx + TS + d * 0.3, sy + TS + d + d * 0.3 }, col32({ 0, 0, 0, a }), rr + d * 0.3)
    end
    dl:AddRectFilled({ sx, sy }, { sx + TS, sy + TS }, col32(shade), rr)
    dl:AddRectFilled({ sx, sy }, { sx + TS, sy + TS * 0.88 }, col32(face), rr)
    dl:AddRect({ sx, sy }, { sx + TS, sy + TS }, col32(border), rr, ROUND_ALL, 1.8 * S)
    if st == 'lucky' then draw_hot_edge(dl, sx, sy, TS, rr, t, S, grow or 1) end
end

----------------------------------------------------------------------------
-- 11 "zoom & smash": the die flies at the screen, hangs, smashes back home
-- (hit-stop), then a soft impact: scorch, dust, ember dots, a few shards.
-- Zoom + impact draw on the foreground list so nothing gets clipped.
----------------------------------------------------------------------------
local SMASH_TIME = 3.0
local HIT_STOP   = 0.08

local function fg_list(dl)
    local ok, f = pcall(function () return imgui.GetForegroundDrawList() end)
    if ok and f ~= nil then return f end
    return dl
end

local function ell_fill(dl, cx, cy, rx, ry, col, seg)
    seg = seg or 24
    local px, py = cx + rx, cy
    for i = 1, seg do
        local a = i / seg * math.pi * 2
        local nx, ny = cx + math.cos(a) * rx, cy + math.sin(a) * ry
        dl:AddTriangleFilled({ cx, cy }, { px, py }, { nx, ny }, col)
        px, py = nx, ny
    end
end

local function ease_out(k) return 1 - (1 - k) ^ 3 end
local function ease_in(k) return k * k * k end

local function smash_pose(dt, homeCY, S)
    if dt >= 0 and dt < 0.9 then
        local k = ease_out(math.min(1, dt / 0.75))
        local sc = 1 + 1.5 * k
        if dt > 0.75 then sc = sc + math.sin(dt * 70) * 0.03 end
        return sc, homeCY - 26 * S * k
    elseif dt >= 0.9 and dt < 1.0 then
        local k = ease_in((dt - 0.9) / 0.1)
        return 2.5 - 1.6 * k, homeCY - 26 * S * (1 - k)
    end
    return 1, homeCY
end

local function smash_number(fg, x, y, size, num, S, sc)
    local vs = (#num > 1 and 1.70 or 2.10) * S * sz('s_die') * sc
    local w, h = text_size(num, vs)
    dl_text(fg, x + (size - w) / 2, y + size * 0.45 - h / 2, col32({ 0.28, 0.17, 0.05, 1 }), num, imgui.GetFontSize() * vs)
end

-- phase 1: flying at the screen (drawn instead of the normal die)
local function draw_smash_zoom(fg, e, cx, homeCY, TS, dt, t, S)
    local sc, cy = smash_pose(dt, homeCY, S)
    local zk = math.max(0, math.min(1, (sc - 1) / 1.5))
    fg:AddRectFilled({ -10, -10 }, { 10000, 10000 }, col32({ 0.05, 0.03, 0.09, 0.38 * zk }))
    for i = 0, 11 do                                   -- slow turning light rays
        local a, sp, L = i / 12 * math.pi * 2 + dt * 0.6, 0.09, 260 * S
        fg:AddTriangleFilled({ cx, cy }, { cx + math.cos(a - sp) * L, cy + math.sin(a - sp) * L },
            { cx + math.cos(a + sp) * L, cy + math.sin(a + sp) * L }, col32({ 1.0, 0.86, 0.47, 0.06 * zk }))
    end
    for i = 0, 23 do                                   -- speed lines
        local a  = (i / 24) * math.pi * 2 + hash(i) * 0.2
        local p  = (dt * 2.4 + hash(i + 30)) % 1
        local r0 = TS * sc * 0.72 + p * 130 * S
        local ln = (14 + hash(i + 31) * 22) * S * zk
        fg:AddLine({ cx + math.cos(a) * r0, cy + math.sin(a) * r0 }, { cx + math.cos(a) * (r0 + ln), cy + math.sin(a) * (r0 + ln) },
            col32({ 1.0, 0.93, 0.67, 0.45 * zk * (1 - p) }), (0.7 + hash(i + 32) * 1.2) * S)
    end
    for j = 6, 1, -1 do
        fg:AddCircleFilled({ cx, cy }, TS * sc * (0.55 + j * 0.13), col32({ 1.0, (200 + 8 * j) / 255, (90 + 15 * j) / 255, 0.045 * (7 - j) * zk }), 32)
    end
    for g = 4, 1, -1 do                                -- afterimages
        local gd = dt - g * 0.035
        if gd >= 0 then
            local gs, gcy = smash_pose(gd, homeCY, S)
            local sz = TS * gs
            fg:AddRectFilled({ cx - sz / 2, gcy - sz / 2 }, { cx + sz / 2, gcy + sz / 2 },
                col32({ 1.0, 0.91, 0.58, 0.15 * (5 - g) / 4 }), sz * 0.2)
        end
    end
    local sz = TS * sc
    local x, y = cx - sz / 2, cy - sz / 2
    draw_die(fg, e, 'max', x, y, sz, t, S, 1)
    fg:AddRectFilled({ x + sz * 0.08, y + sz * 0.06 }, { x + sz * 0.92, y + sz * 0.28 }, col32({ 1, 1, 1, 0.30 }), sz * 0.15)
    if dt < 0.2 then
        fg:AddRectFilled({ x, y }, { x + sz, y + sz }, col32({ 1, 1, 0.94, 0.85 * (1 - dt / 0.2) }), 9 * S)
    end
    smash_number(fg, x, y, sz, tostring(e.value or 11), S, sc)
end

-- scorch mark under the die (window list, drawn before the die)
local function draw_scorch(dl, cx, ground, TS, k0, S)
    if k0 < 0 or k0 > 2.6 then return end
    local f = (k0 < 1.6) and math.min(1, k0 / 0.1) or (1 - (k0 - 1.6) / 1.0)
    for j = 6, 1, -1 do
        ell_fill(dl, cx, ground - 2 * S, TS * (0.35 + 0.16 * j), TS * (0.06 + 0.035 * j), col32({ 0.16, 0.09, 0.04, 0.05 * (7 - j) * f }))
    end
    local hot = math.max(0, 1 - k0 / 1.2)
    for j = 3, 1, -1 do
        ell_fill(dl, cx, ground - 2 * S, TS * (0.25 + 0.12 * j), TS * (0.04 + 0.02 * j), col32({ 1.0, (150 + 20 * j) / 255, 0.24, 0.06 * (4 - j) * f * hot }))
    end
end

-- phase 2: impact (foreground)
local function draw_smash_impact(fg, cx, cy, ground, TS, k0, t, S, seed)
    if k0 < 0 or k0 > 1.6 then return end
    if k0 < 0.18 then
        fg:AddRectFilled({ -10, -10 }, { 10000, 10000 }, col32({ 1.0, 0.98, 0.89, 0.35 * (1 - k0 / 0.18) }))
    end
    if k0 < 0.7 then                                   -- soft bloom + thin flare
        local a = 1 - k0 / 0.7
        local br = TS * (0.5 + 0.9 * ease_out(math.min(1, k0 / 0.25)))
        for j = 7, 1, -1 do
            fg:AddCircleFilled({ cx, cy }, br * j / 7, col32({ 1.0, (210 + 6 * (7 - j)) / 255, (120 + 16 * (7 - j)) / 255, 0.09 * a }), 32)
        end
        local fw = (50 + 150 * ease_out(math.min(1, k0 / 0.3))) * S
        ell_fill(fg, cx, cy, fw, 2.6 * S, col32({ 1.0, 0.84, 0.43, 0.18 * a }), 28)
        ell_fill(fg, cx, cy, fw * 0.75, 1.9 * S, col32({ 1.0, 0.84, 0.43, 0.18 * a }), 28)
        ell_fill(fg, cx, cy, fw * 0.5, 1.2 * S, col32({ 1.0, 1.0, 0.96, 0.6 * a }), 28)
    end
    if k0 < 0.75 then                                  -- faint shockwave
        local k = k0 / 0.75
        local rad = TS * (0.6 + k * 1.9)
        for j = 0, 4 do
            fg:AddCircle({ cx, cy }, rad - j * 2.4 * S, col32({ 1.0, (220 + 6 * j) / 255, (130 + 18 * j) / 255, (1 - k) * 0.07 * ((j == 2) and 2 or 1) }), 48, 3 * S)
        end
    end
    if k0 < 1.5 then                                   -- dust puffs rolling out
        local k = math.min(1, k0 / 1.5)
        for i = 0, 11 do
            local side = (i % 2 == 1) and 1 or -1
            local d    = TS * (0.35 + ease_out(k) * (0.9 + hash(i) * 0.6))
            local rad  = TS * (0.07 + k * 0.16 * (0.7 + hash(i + 2) * 0.6))
            local px, py = cx + side * d, ground - 3 * S - k * 12 * S * hash(i + 3)
            fg:AddCircleFilled({ px, py }, rad, col32({ 0.59, 0.53, 0.48, 0.28 * (1 - k) }), 16)
            fg:AddCircleFilled({ px, py }, rad * 0.6, col32({ 0.75, 0.70, 0.65, 0.18 * (1 - k) }), 12)
        end
    end
    if k0 < 1.1 then                                   -- a few shards kicked up
        local k = k0 / 1.1
        for i = 0, 11 do
            local a    = math.pi * (1.05 + hash(seed + i + 3) * 0.9)
            local sp   = (55 + hash(seed + i + 4) * 80) * S
            local s    = (2 + hash(seed + i + 5) * 2.5) * S * (1 + (0.4 + hash(seed + i + 9) * 0.7) * k)
            local ang  = hash(seed + i + 6) * 6 + (hash(seed + i + 7) - 0.5) * 10 * k
            local gold = hash(seed + i + 8) < 0.65
            local d    = TS * 0.45 + sp * ease_out(k)
            local px   = cx + math.cos(a) * d
            local py   = ground + math.sin(a) * d * 0.9 + 70 * S * k * k
            local al   = math.max(0, 1 - k * k)
            local ca, sa = math.cos(ang), math.sin(ang)
            local function R(x, y) return { px + x * ca - y * sa, py + x * sa + y * ca } end
            local A, B, Cc, Hh = R(-s, -s * 0.55), R(s, -s * 0.25), R(s * 0.35, s * 0.85), R(s * 0.1, -s * 0.05)
            fg:AddTriangleFilled(A, B, Cc, col32(gold and { 0.88, 0.63, 0.16, al } or { 0.47, 0.41, 0.36, al }))
            fg:AddTriangleFilled(A, B, Hh, col32(gold and { 1.0, 0.93, 0.63, al * 0.9 } or { 0.67, 0.62, 0.57, al }))
        end
    end
    if k0 < 1.4 then                                   -- glowing ember dots
        for i = 0, 15 do
            local life = 0.7 + hash(seed + i + 54) * 0.6
            if k0 <= life then
                local k  = k0 / life
                local a  = math.pi * (1.0 + hash(seed + i + 50)) + ((hash(seed + i + 51) < 0.2) and math.pi * 0.5 or 0)
                local d  = TS * 0.4 + (40 + hash(seed + i + 52) * 90) * S * ease_out(k)
                local r  = (1.2 + hash(seed + i + 53) * 1.6) * S
                local px = cx + math.cos(a) * d
                local py = ground - 4 * S + math.sin(a) * d * 0.8 + 40 * S * k * k
                fg:AddCircleFilled({ px, py }, r * 3 * (1 - k * 0.5), col32({ 1.0, 0.75, 0.31, 0.14 * (1 - k) }), 12)
                fg:AddCircleFilled({ px, py }, r * (1 - k * 0.4), col32({ 1.0, (235 - 70 * k) / 255, (150 - 80 * k) / 255, 1 - k }), 10)
            end
        end
        for i = 0, 5 do                                -- embers drifting off the scorch
            local p = ((k0 * 0.8 + hash(i + 70)) % 1.4) / 1.4
            fg:AddCircleFilled({ cx + (hash(i + 71) - 0.5) * TS * 1.1 + math.sin(t * 2 + i) * 2 * S, ground - 2 * S - p * 24 * S },
                1.1 * S * (1 - p), col32({ 1.0, (190 - 60 * p) / 255, 0.31, (1 - p) * math.max(0, 1 - k0 / 1.4) }), 8)
        end
    end
end

-- gold shine that sweeps across an 11 die every ~2.4s, plus twinkles
local function draw_gold_glint(dl, sx, sy, TS, t, S)
    local g = (t % 2.4) / 0.7
    if g < 1 then
        local m  = 3 * S
        local sp = TS - m * 2
        local c  = (-0.3 + g * 2.6) * sp
        for k = -4, 4 do
            local cc = c + k * 1.7 * S
            local u0, u1 = math.max(0, cc - sp), math.min(sp, cc)
            if u1 > u0 then
                dl:AddLine({ sx + m + u0, sy + m + (cc - u0) }, { sx + m + u1, sy + m + (cc - u1) },
                    col32({ 1, 1, 1, 0.5 * (1 - math.abs(k) / 5) }), 1.6 * S)
            end
        end
    end
    local spots = { { -0.12, 0.10, 4.0, 0.0 }, { 1.12, 0.20, 3.2, 1.7 }, { 0.90, -0.12, 2.8, 3.1 } }
    for _, p in ipairs(spots) do
        local w = math.sin(t * 2.6 + p[4])
        local a = (w > 0) and (w ^ 3) or 0
        if a > 0.02 then
            local x, y, r = sx + TS * p[1], sy + TS * p[2], p[3] * S
            local c = col32({ 1.0, 0.96, 0.78, a * 0.8 })
            dl:AddLine({ x - r, y }, { x + r, y }, c, 1.0)
            dl:AddLine({ x, y - r }, { x, y + r }, c, 1.0)
            dl:AddCircleFilled({ x, y }, r * 0.3, col32({ 1, 1, 1, a }), 8)
        end
    end
end

local function draw_column(e, m, cx, top, dl, wx, wy, t, now)
    local S, colW, TS = m.S, m.colW, m.TS
    local def = e.def
    local st  = roll_state(e)
    local sty = STATE[st]
    local mid = cx + colW / 2

    -- name on a ribbon tag (edge tinted by row: gold melee, blue mages)
    local y    = top + m.padTop
    local name = def.short
    local nw   = text_size(name, m.nscale)
    local tint = ROW_TINT[e.group or 'MELEE'] or ROW_TINT.SELF
    local rw, rh = nw + 22 * S, m.nh + 5 * S
    local rx, ry = mid - rw / 2, y - 2.5 * S
    pill(dl, wx, wy, rx, ry, rw, rh, { 0.05, 0.06, 0.09, 0.88 }, { tint[1], tint[2], tint[3], 0.80 })
    dl:AddCircleFilled({ wx + rx + 7 * S, wy + ry + rh / 2 }, 1.9 * S, col32({ tint[1], tint[2], tint[3], 1 }), 10)
    local ncol = sty.name
    if st == 'normal' then ncol = e.mine and C.cream or ROW_TINT.PARTY end
    text_at(rx + 13 * S, y, ncol, name, m.nscale, false)
    y = y + m.nh + m.flame

    -- die (+ explosion when it just landed on Lucky / 11, + fire on Lucky)
    local tx = mid - TS / 2
    local sx, sy = wx + tx, wy + y
    if e.burst_pending then e.burst_at = t; e.burst_pending = nil end
    local dt = e.burst_at and (t - e.burst_at) or 99
    if dt > BURST_TIME then e.burst_at = nil; dt = 99 end
    local bursting = dt <= BURST_TIME
    local pop  = (dt < 0.45) and (1 + 0.28 * math.sin(math.min(1, dt / 0.45) * math.pi) * math.exp(-dt * 2)) or 1
    local grow = (dt < 0.75) and math.max(0, math.min(1, (dt - 0.15) / 0.6)) or 1
    local TSd  = TS * pop
    local dsx, dsy = sx + (TS - TSd) / 2, sy + (TS - TSd) / 2
    local ccx, ccy = sx + TS / 2, sy + TS / 2
    local gold = (st == 'max')

    -- 11: zoom at the screen, then smash home (with a short hit-stop)
    if e.smash_pending then e.smash_at = t; e.smash_pending = nil end
    local sraw = e.smash_at and (t - e.smash_at) or 99
    if sraw > SMASH_TIME then e.smash_at = nil; sraw = 99 end
    local smashing = sraw <= SMASH_TIME
    local stopped  = smashing and sraw >= 1.0 and sraw < 1.0 + HIT_STOP
    local sdt      = (sraw < 1.0) and sraw or (stopped and 1.0 or (sraw - HIT_STOP))
    local zooming  = smashing and sdt < 1.0
    local impact   = smashing and (sdt - 1.0) or -1
    if stopped then
        pop = 1.14
    elseif impact >= 0 and impact < 0.35 then
        pop = 1 + 0.14 * (1 - impact / 0.35)
        local sh = (1 - impact / 0.35) * 3 * S
        dsx = math.sin(t * 95) * sh
        dsy = math.cos(t * 81) * sh * 0.6
    end
    local jx, jy = (impact >= 0 and impact < 0.35 and not stopped) and dsx or 0, (impact >= 0 and impact < 0.35 and not stopped) and dsy or 0
    TSd = TS * pop
    dsx, dsy = sx + (TS - TSd) / 2 + jx, sy + (TS - TSd) / 2 + jy

    if zooming then
        draw_smash_zoom(fg_list(dl), e, ccx, ccy, TS, sdt, t, S * sz('s_fx'))
    else
        if impact >= 0 then draw_scorch(dl, ccx, sy + TS, TS, impact, S) end
        if st == 'lucky' then draw_fire_back(dl, dsx, dsy, TSd, t, grow, S) end
        if bursting then draw_burst_back(dl, ccx, ccy, TS * sz('s_fx'), dt, S * sz('s_fx'), gold) end
        draw_die(dl, e, st, dsx, dsy, TSd, t, S, grow)
        if dt < 0.25 then
            dl:AddRectFilled({ dsx, dsy }, { dsx + TSd, dsy + TSd }, col32({ 1, 1, 1, 0.85 * (1 - dt / 0.25) }), 9 * S)
        end
        if impact >= 0 and impact < 0.15 then
            dl:AddRectFilled({ dsx, dsy }, { dsx + TSd, dsy + TSd }, col32({ 1, 1, 0.94, 0.7 * (1 - impact / 0.15) }), 9 * S)
        end
        local num = e.busted and tostring(e.bust_total or 'X') or tostring(e.value or '?')
        local numc = C.slate
        if st == 'bust' then numc = { 1.0, 0.80, 0.78, 1 } elseif st == 'lucky' or st == 'max' then numc = { 0.28, 0.17, 0.05, 1 } end
        local vs = (#num > 1 and 1.70 or 2.10) * S * sz('s_die') * pop
        local vw, vh = text_size(num, vs)
        text_at(dsx - wx + (TSd - vw) / 2, dsy - wy + TSd * 0.45 - vh / 2, numc, num, vs, false)
        if st == 'lucky' then draw_fire_front(dl, dsx, dsy, TSd, t, grow, S) end
        if bursting then draw_burst_front(dl, ccx, ccy, TS, dt, S * sz('s_fx'), gold, e.id * 7.31) end
        if st == 'max' and (impact < 0 or impact > 0.5) then draw_gold_glint(dl, dsx, dsy, TSd, t, S) end
        if impact >= 0 then draw_smash_impact(fg_list(dl), ccx, ccy, sy + TS, TS * sz('s_fx'), impact, t, S * sz('s_fx'), e.id * 5.17) end
    end
    if st == 'unlucky' then
        draw_icicles(dl, sx, sy, TS, t, S)
        draw_ice_shine(dl, sx, sy, TS, t, S)
    end

    -- status chip straddling the die's bottom edge
    if sty.chip and not zooming then
        local cw = text_size(sty.chip, m.cscale)
        local w, h = cw + 12 * S, m.ch + 4 * S
        local px, py = mid - w / 2, y + TS - h / 2 + 1 * S
        pill(dl, wx, wy, px, py, w, h, sty.bg, sty.bd)
        text_at(px + 6 * S, py + 2 * S, sty.fg, sty.chip, m.cscale, false)
    end

    -- "?" marker on the die corner
    if m.hover then
        local qr = 5.5 * S
        imgui.SetCursorPos({ tx + TS - qr + 3 * S, y - qr - 1 * S })
        local _, qhov = round_button('##nq' .. e.id, 'help', qr)
        if qhov then roll_tooltip(e, now) end
    end
    y = y + TS + m.ice

    -- info plate: effect on top, timer bar + time below
    local plx, plw = cx + 6 * S, colW - 12 * S
    local plh = m.eh + m.th + 15 * S
    local pbd = sty.bd or { tint[1], tint[2], tint[3], 1 }
    dl:AddRectFilled({ wx + plx, wy + y }, { wx + plx + plw, wy + y + plh }, col32({ 0.05, 0.06, 0.09, 0.84 }), 7 * S)
    dl:AddRect({ wx + plx, wy + y }, { wx + plx + plw, wy + y + plh }, col32({ pbd[1], pbd[2], pbd[3], 0.40 }), 7 * S, ROUND_ALL, 1.0)

    local etxt = e.busted and rolls.bust_text(def) or (e.unknown and ('? ' .. def.stat)) or rolls.effect_text(def, e.value, frame_jobs)
    local ew = text_size(etxt, m.escale)
    text_at(mid - ew / 2, y + 5 * S, sty.eff, etxt, m.escale, false)
    y = y + 5 * S + m.eh + 5 * S

    local left = e.started + ROLL_DURATION - now
    local frac = e.unknown and 1 or math.max(0, math.min(1, left / ROLL_DURATION))
    local bc = e.unknown and { 0.55, 0.60, 0.70, 1 } or { 0.36, 0.80, 0.52, 1 }
    if frac < 0.10 then bc = { 0.92, 0.34, 0.30, 1 } elseif frac < 0.20 then bc = { 0.94, 0.72, 0.26, 1 } end
    local tstr = e.unknown and '--:--' or fmt_time(left)
    local bx0  = plx + 8 * S
    local bw   = plw - 16 * S - m.tw - 6 * S
    local by0  = y + (m.th - m.barH) / 2
    dl:AddRectFilled({ wx + bx0 - 1, wy + by0 - 1 }, { wx + bx0 + bw + 1, wy + by0 + m.barH + 1 }, col32({ 0, 0, 0, 0.75 }), m.barH / 2 + 1)
    dl:AddRectFilled({ wx + bx0, wy + by0 }, { wx + bx0 + bw, wy + by0 + m.barH }, col32({ 0.12, 0.13, 0.16, 0.85 }), m.barH / 2)
    if frac > 0 then
        dl:AddRectFilled({ wx + bx0, wy + by0 }, { wx + bx0 + math.max(m.barH, bw * frac), wy + by0 + m.barH }, col32(bc), m.barH / 2)
    end
    text_at(bx0 + bw + 6 * S, y, frac < 0.20 and bc or C.steel, tstr, m.tscale, false)
    y = y + m.th + 5 * S

    -- Double-Up pill
    if shows_du(e) then
        y = y + 6 * S
        local chance = rolls.bust_chance(e.value)
        local t1 = (chance == 0) and 'SAFE' or ('BUST %d%%'):format(math.floor(chance * 100 + 0.5))
        local t2 = ('%ds'):format(math.max(0, e.du_until - now))
        local w1 = text_size(t1, m.dscale)
        local w2 = text_size(t2, m.dscale)
        local w  = w1 + w2 + 30 * S
        local px = mid - w / 2
        local fg, bg, bd
        if chance == 0 then fg, bg, bd = C.green, { 0.06, 0.24, 0.12, 0.92 }, { 0.40, 0.85, 0.50, 0.9 }
        elseif chance >= 0.5 then fg, bg, bd = { 1.0, 0.55, 0.52, 1 }, { 0.30, 0.06, 0.06, 0.92 }, { 1.0, 0.38, 0.34, 0.9 }
        else fg, bg, bd = { 1.0, 0.78, 0.40, 1 }, { 0.30, 0.18, 0.04, 0.92 }, { 1.0, 0.68, 0.25, 0.9 } end
        pill(dl, wx, wy, px, y, w, m.pillH, bg, bd)
        text_at(px + 9 * S, y + 2.5 * S, fg, t1, m.dscale, false)
        dl:AddCircleFilled({ wx + px + 9 * S + w1 + 6 * S, wy + y + m.pillH / 2 }, 1.5 * S, col32(C.dim), 8)
        text_at(px + 21 * S + w1, y + 2.5 * S, C.steel, t2, m.dscale, false)
    end
end

-- Groups rolls into rows (MELEE, MAGES, SELF, PARTY), oldest first in each row.
local function build_rows(list)
    local by = {}
    for _, e in ipairs(list) do
        local g = e.group or 'MELEE'
        by[g] = by[g] or {}
        table.insert(by[g], e)
    end
    local rows = {}
    for g, items in pairs(by) do
        table.sort(items, function (a, b) return a.started < b.started end)
        table.insert(rows, { label = g, items = items })
    end
    table.sort(rows, function (a, b) return (ROW_ORDER[a.label] or 9) < (ROW_ORDER[b.label] or 9) end)
    return rows
end

local function sorted_flat(list)
    local out = {}
    for _, row in ipairs(build_rows(list)) do
        for _, e in ipairs(row.items) do table.insert(out, e) end
    end
    return out
end

----------------------------------------------------------------------------
-- Phantom Roll + Double-Up cooldowns (read from the game's own recast timers)
----------------------------------------------------------------------------
local PR_RECAST_ID = 193
local DU_RECAST_ID = 194
local CDS = {
    pr = { rid = PR_RECAST_ID, total = 60, prev = 0, ready_at = nil, label = 'PHANTOM ROLL', icon = 1, key = 'pr' },
    du = { rid = DU_RECAST_ID, total = 10, prev = 0, ready_at = nil, label = 'DOUBLE-UP',    icon = 2, key = 'du' },
}

local function ability_recast(rid)
    local ok, v = pcall(function ()
        local r = AshitaCore:GetMemoryManager():GetRecast()
        for i = 0, 31 do
            if r:GetAbilityTimerId(i) == rid then
                return r:GetAbilityTimer(i) / 60     -- 1/60 s -> seconds
            end
        end
        return 0
    end)
    return (ok and v) or 0
end

-- remaining seconds + full length (learned when the timer starts, so merits count)
local function cd_update(cd, t)
    local rem = ability_recast(cd.rid)
    if rem > cd.prev + 0.5 then
        cd.total = math.max(1, math.ceil(rem))
        dlog.add('ROLL', ('%s recast started (%ds)'):format(cd.label, cd.total), true)
    end
    if rem <= 0 and cd.prev > 0 then cd.ready_at = t end
    cd.prev = rem
    return rem, cd.total
end

-- Double-Up only matters while one of your rolls has its window open
local function du_window_open()
    local now = os.time()
    for _, e in ipairs(state.active) do
        if e.mine and e.du_until and now <= e.du_until and not e.busted and (e.value or 0) < 11 then return true end
    end
    return false
end

local function fmt_cd(sec)
    if sec < 10 then return ('%.1f'):format(sec) end
    return fmt_time(sec)
end

local function cd_tooltip()
    imgui.BeginTooltip()
    local pr = ability_recast(PR_RECAST_ID)
    imgui.TextColored(C.gold, 'Phantom Roll')
    imgui.SameLine()
    imgui.TextColored(pr > 0 and C.cream or C.green, pr > 0 and ('%s  (full %s)'):format(fmt_cd(pr), fmt_time(CDS.pr.total)) or 'Ready')
    local du = ability_recast(DU_RECAST_ID)
    imgui.TextColored(C.gold, 'Double-Up')
    imgui.SameLine()
    if du > 0 then
        imgui.TextColored(C.cream, ('%s  (full %ds)'):format(fmt_cd(du), CDS.du.total))
    elseif du_window_open() then
        imgui.TextColored(C.green, 'Ready - window open')
    else
        imgui.TextColored(C.steel, 'Ready - no roll to double')
    end
    imgui.EndTooltip()
end

-- tiny die icon(s): 1 = Phantom Roll, 2 = Double-Up (two stacked dice)
local function cd_icon(dl, x, y, s, kind, ready)
    local face = ready and { 0.80, 1.0, 0.82, 1 } or { 0.97, 0.94, 0.86, 1 }
    local pc   = col32(ready and { 0.08, 0.30, 0.14, 1 } or { 0.17, 0.21, 0.29, 1 })
    if kind == 2 then
        local d = s * 0.72
        dl:AddRectFilled({ x, y }, { x + d, y + d }, col32({ face[1] * 0.75, face[2] * 0.75, face[3] * 0.75, 1 }), d * 0.25)
        local ox, oy = x + s - d, y + s - d
        dl:AddRectFilled({ ox, oy }, { ox + d, oy + d }, col32(face), d * 0.25)
        dl:AddRect({ ox, oy }, { ox + d, oy + d }, col32({ 0, 0, 0, 0.45 }), d * 0.25, ROUND_ALL, 1.0)
        dl:AddCircleFilled({ ox + d * 0.32, oy + d * 0.32 }, d * 0.12, pc, 8)
        dl:AddCircleFilled({ ox + d * 0.68, oy + d * 0.68 }, d * 0.12, pc, 8)
        return
    end
    dl:AddRectFilled({ x, y }, { x + s, y + s }, col32(face), s * 0.25)
    dl:AddCircleFilled({ x + s * 0.30, y + s * 0.30 }, s * 0.11, pc, 8)
    dl:AddCircleFilled({ x + s * 0.50, y + s * 0.50 }, s * 0.11, pc, 8)
    dl:AddCircleFilled({ x + s * 0.70, y + s * 0.70 }, s * 0.11, pc, 8)
end

local function cd_pill_width(S, label)
    local lw = text_size(label, 0.62 * S)
    local tw = text_size('READY', 0.78 * S)
    return 6 * S + 12 * S + 6 * S + lw + 10 * S + tw + 9 * S
end

local function cd_row_width(S)
    return math.max(cd_pill_width(S, CDS.pr.label), cd_pill_width(S, CDS.du.label))
end

-- one pill: [icon] LABEL ....... 0:42 / READY   (mode: 'cool' | 'ready' | 'idle')
local function draw_cd_pill(dl, wx, wy, x, y, S, t, cd, rem, mode)
    local w, h  = cd_pill_width(S, cd.label), 20 * S
    local W0, H0, X0, Y0 = w, h, x, y                 -- layout size / hit box stay fixed
    local ready = (mode == 'ready')
    local flash = (ready and cd.ready_at) and math.max(0, 1 - (t - cd.ready_at) / 0.8) or 0
    local wt    = tonumber(cfg.cd_warn) or 0
    local warn  = (mode == 'cool' and wt > 0 and rem <= wt) and (1 - rem / wt) or nil   -- 0..1
    local beat  = 0
    if warn then
        -- soft breathing: one constant slow pace (never speeds up),
        -- with a small gentle swell in time with the glow
        beat = 0.5 + 0.5 * math.sin(t * 2.0)
        local sc = 1 + 0.035 * beat
        x, y = x - w * (sc - 1) / 2, y - h * (sc - 1) / 2
        w, h, S = w * sc, h * sc, S * sc
    end
    local x0, y0 = wx + x, wy + y

    if ready then
        local pulse = 0.5 + 0.5 * math.sin(t * 3)
        for k = 3, 1, -1 do
            local g = k * 2.5 * S
            dl:AddRectFilled({ x0 - g, y0 - g }, { x0 + w + g, y0 + h + g },
                col32({ 0.35, 0.90, 0.50, (0.04 + 0.03 * pulse + 0.10 * flash) * (4 - k) }), h / 2 + g)
        end
        dl:AddRectFilled({ x0, y0 }, { x0 + w, y0 + h }, col32({ 0.04, 0.17, 0.09, 0.90 }), h / 2)
        dl:AddRect({ x0, y0 }, { x0 + w, y0 + h }, col32({ 0.40, 0.88, 0.52, 0.65 + 0.3 * pulse }), h / 2, ROUND_ALL, 1.2)
        if flash > 0 then
            dl:AddRectFilled({ x0, y0 }, { x0 + w, y0 + h }, col32({ 0.75, 1.0, 0.80, 0.45 * flash }), h / 2)
        end
    elseif mode == 'idle' then
        dl:AddRectFilled({ x0, y0 }, { x0 + w, y0 + h }, col32({ 0.05, 0.06, 0.09, 0.80 }), h / 2)
        dl:AddRect({ x0, y0 }, { x0 + w, y0 + h }, col32({ 0.55, 0.58, 0.65, 0.40 }), h / 2, ROUND_ALL, 1.0)
    else
        local frac = math.max(0, math.min(1, rem / cd.total))
        dl:AddRectFilled({ x0, y0 }, { x0 + w, y0 + h }, col32({ 0.05, 0.06, 0.09, 0.88 }), h / 2)
        if warn then
            -- almost ready: soft warm glow that gently breathes
            local wp = beat
            for k = 3, 1, -1 do
                local g = k * 2.5 * S
                dl:AddRectFilled({ x0 - g, y0 - g }, { x0 + w + g, y0 + h + g },
                    col32({ 1.0, 0.72, 0.30, (0.025 + 0.035 * wp) * (4 - k) * (0.6 + 0.4 * warn) }), h / 2 + g)
            end
            dl:AddRectFilled({ x0, y0 }, { x0 + w, y0 + h }, col32({ 0.16, 0.10, 0.04, 0.90 }), h / 2)
            dl:AddRectFilled({ x0, y0 }, { x0 + math.max(h, w * frac), y0 + h }, col32({ 1.0, 0.72, 0.30, 0.22 + 0.08 * wp }), h / 2)
            dl:AddRect({ x0, y0 }, { x0 + w, y0 + h }, col32({ 1.0, 0.78, 0.40, 0.50 + 0.25 * wp }), h / 2, ROUND_ALL, 1.2)
        else
            dl:AddRectFilled({ x0, y0 }, { x0 + math.max(h, w * frac), y0 + h }, col32({ 0.96, 0.74, 0.26, 0.22 }), h / 2)
            dl:AddRect({ x0, y0 }, { x0 + w, y0 + h }, col32({ 0.96, 0.74, 0.26, 0.55 }), h / 2, ROUND_ALL, 1.0)
        end
    end

    local is = 12 * S
    cd_icon(dl, x0 + 6 * S, y0 + (h - is) / 2, is, cd.icon, ready)
    local _, lh = text_size('A', 0.62 * S)
    local lc = ready and { 0.78, 0.95, 0.82, 1 } or (warn and { 0.98, 0.86, 0.66, 1 }) or (mode == 'idle' and C.dim or C.steel)
    text_at(x + 6 * S + is + 6 * S, y + (h - lh) / 2, lc, cd.label, 0.62 * S, false)
    local tt = (mode == 'cool') and fmt_cd(rem) or (ready and 'READY' or '--')
    local tc = ready and C.green or (warn and { 1.0, 0.82, 0.50, 1 }) or (mode == 'idle' and C.dim or C.cream)
    local tw, th = text_size(tt, 0.78 * S)
    text_at(x + w - 9 * S - tw, y + (h - th) / 2, tc, tt, 0.78 * S, false)

    if not state.no_hit then
        imgui.SetCursorPos({ X0, Y0 })
        imgui.InvisibleButton('##nard_cd_' .. cd.key, { W0, H0 })
        if imgui.IsItemHovered() then cd_tooltip() end
    end
    return W0, H0
end

-- Phantom Roll on top, Double-Up underneath (each its own pill), centered in W; returns height
local function draw_cd_row(dl, wx, wy, x, y, W, S, t)
    local prr = cd_update(CDS.pr, t)
    local dur = cd_update(CDS.du, t)
    local w1  = cd_pill_width(S, CDS.pr.label)
    local w2  = cd_pill_width(S, CDS.du.label)
    local _, h = draw_cd_pill(dl, wx, wy, x + (W - w1) / 2, y, S, t, CDS.pr, prr, prr > 0 and 'cool' or 'ready')
    local gap = 6 * S
    local dmode = (dur > 0) and 'cool' or (du_window_open() and 'ready' or 'idle')
    draw_cd_pill(dl, wx, wy, x + (W - w2) / 2, y + h + gap, S, t, CDS.du, dur, dmode)
    return h * 2 + gap
end

-- minimized: small ring with seconds inside (green dot when ready, grey when idle)
local function draw_cd_ring(dl, wx, wy, x, y, m, S, t, cd, rem, mode)
    local cx, cy, r = wx + x + m / 2, wy + y + m / 2, m / 2
    if mode ~= 'cool' then
        local ready = (mode == 'ready')
        local pulse = 0.5 + 0.5 * math.sin(t * 3)
        dl:AddCircleFilled({ cx, cy }, r, col32(ready and { 0.04, 0.17, 0.09, 0.95 } or { 0.05, 0.06, 0.09, 0.95 }), 20)
        dl:AddCircle({ cx, cy }, r - 1, col32(ready and { 0.40, 0.88, 0.52, 0.7 + 0.3 * pulse } or { 0.55, 0.58, 0.65, 0.5 }), 20, 1.6 * S)
        if cd.icon == 2 then
            cd_icon(dl, cx - r * 0.5, cy - r * 0.5, r, 2, ready)
        else
            dl:AddCircleFilled({ cx, cy }, r * 0.32, col32(ready and { 0.45, 0.95, 0.55, 1 } or { 0.55, 0.58, 0.65, 1 }), 12)
        end
    else
        local frac = math.max(0, math.min(1, rem / cd.total))
        local wt   = tonumber(cfg.cd_warn) or 0
        local warn = (wt > 0 and rem <= wt) and (1 - rem / wt) or nil
        if warn then
            local wp = 0.5 + 0.5 * math.sin(t * 2.0)
            r = r * (1 + 0.05 * wp)
            for k = 3, 1, -1 do
                dl:AddCircleFilled({ cx, cy }, r + k * 1.8 * S, col32({ 1.0, 0.72, 0.30, (0.03 + 0.04 * wp) * (4 - k) * (0.6 + 0.4 * warn) }), 20)
            end
        end
        dl:AddCircleFilled({ cx, cy }, r, col32(warn and { 0.20, 0.11, 0.02, 0.95 } or { 0.05, 0.06, 0.09, 0.95 }), 20)
        dl:AddCircle({ cx, cy }, r - 1.5 * S, col32({ 1, 1, 1, 0.10 }), 24, 2 * S)
        local segs = math.max(2, math.floor(28 * frac))
        local a0 = -math.pi / 2
        for i = 0, segs - 1 do
            local a1 = a0 + (i / segs) * frac * math.pi * 2
            local a2 = a0 + ((i + 1) / segs) * frac * math.pi * 2
            dl:AddLine({ cx + math.cos(a1) * (r - 1.5 * S), cy + math.sin(a1) * (r - 1.5 * S) },
                       { cx + math.cos(a2) * (r - 1.5 * S), cy + math.sin(a2) * (r - 1.5 * S) },
                       col32(warn and { 1.0, 0.78, 0.40, 1 } or (cd.icon == 2 and { 0.55, 0.80, 1.00, 1 } or { 0.96, 0.74, 0.26, 1 })), 2 * S)
        end
        local tt = tostring(math.ceil(rem))
        local tw, th = text_size(tt, 0.66 * S)
        text_at(x + (m - tw) / 2, y + (m - th) / 2, C.cream, tt, 0.66 * S, false)
    end
    imgui.SetCursorPos({ x, y })
    imgui.InvisibleButton('##nard_cdm_' .. cd.key, { m, m })
    if imgui.IsItemHovered() then cd_tooltip() end
end

-- one row of dice (with optional panel + tab label); returns its height
local function draw_row(dl, wx, wy, bx, y, W, row, m, t, now, hovered)
    local S = m.S
    local tint = ROW_TINT[row.label] or ROW_TINT.SELF
    local has_du = false
    for _, e in ipairs(row.items) do if shows_du(e) then has_du = true end end
    local rh = row_height(m, has_du)
    local x0, y0, x1, y1 = wx + bx, wy + y, wx + bx + W, wy + y + rh

    if cfg.panel then
        -- glass panel
        dl:AddRectFilled({ x0, y0 }, { x1, y1 }, col32({ 0.05, 0.06, 0.09, 0.80 }), 12 * S)
        dl:AddRectFilled({ x0 + 1, y0 + 1 }, { x1 - 1, y0 + rh * 0.42 }, col32({ 1, 1, 1, 0.03 }), 11 * S)
        dl:AddRect({ x0, y0 }, { x1, y1 }, col32({ tint[1], tint[2], tint[3], 0.45 }), 12 * S, ROUND_ALL, 1.0)
        dl:AddLine({ x0 + 14 * S, y0 + 1 }, { x1 - 14 * S, y0 + 1 }, col32({ tint[1], tint[2], tint[3], 0.30 }), 1.0)

        -- faint dividers between rolls
        for i = 2, #row.items do
            local lx = x0 + 4 * S + (i - 1) * m.colW
            dl:AddLine({ lx, y0 + 14 * S }, { lx, y1 - 12 * S }, col32({ 1, 1, 1, 0.07 }), 1.0)
        end
    end

    for i, e in ipairs(row.items) do
        draw_column(e, m, bx + 4 * S + (i - 1) * m.colW, y, dl, wx, wy, t, now)
    end

    -- tab label on the top edge (drawn last so it sits on the border)
    if cfg.row_labels and (cfg.panel or hovered) then
        local ls = 0.66 * S
        local lw, lh = text_size(row.label, ls)
        local tw, th = lw + 18 * S, lh + 4 * S
        local tx, ty = bx + 12 * S, y - th / 2
        if cfg.panel then
            pill(dl, wx, wy, tx, ty, tw, th, { 0.06, 0.07, 0.10, 1 }, { tint[1], tint[2], tint[3], 0.75 })
        else
            -- frameless: label + thin fading rule, no box
            local lx = wx + tx + 14 * S + lw
            local ly = wy + ty + th / 2
            dl:AddLine({ lx, ly }, { wx + bx + W - 6 * S, ly }, col32({ tint[1], tint[2], tint[3], 0.22 }), 1.0)
        end
        dl:AddCircleFilled({ wx + tx + 6 * S, wy + ty + th / 2 }, 2.2 * S, col32({ 0, 0, 0, 0.9 }), 10)
        dl:AddCircleFilled({ wx + tx + 6 * S, wy + ty + th / 2 }, 1.8 * S, col32({ tint[1], tint[2], tint[3], 1 }), 10)
        text_at(tx + 11 * S, ty + 2 * S, { tint[1], tint[2], tint[3], 1 }, row.label, ls, not cfg.panel)
    end

    return rh
end

local function draw_overlay_full(list, now)
    local S      = cfg.scale
    local m      = layout(S)
    local rows   = build_rows(list)
    local n      = 1
    for _, row in ipairs(rows) do n = math.max(n, #row.items) end
    local W      = n * m.colW + 8 * S
    local EMPTY  = 'Phantom Roll ready'
    if #rows == 0 and not cfg.show_cd then
        -- make the empty marker wide enough for its text (it was being clipped)
        W = math.max(W, text_size(EMPTY, 0.85 * S) + 28 * S)
    end
    if cfg.show_cd then W = math.max(W, cd_row_width(S * sz('s_cd')) + 8 * S) end
    local bx, by = imgui.GetCursorPos()
    local wx, wy = imgui.GetWindowPos()
    local dl     = imgui.GetWindowDrawList()
    local t      = anim_time()

    -- header (wordmark + help + minimize) only shows while you hover the overlay
    -- keep counting as hovered while a header button is being pressed, and for a
    -- moment after the mouse leaves, so clicks on the gear / bug / minimize land
    local hflag = ImGuiHoveredFlags_AllowWhenBlockedByActiveItem or 128
    local okh, hv = pcall(function () return imgui.IsWindowHovered(hflag) end)
    if not okh then hv = imgui.IsWindowHovered() end
    if hv or imgui.IsAnyItemActive() then state.hover_until = t + 0.5 end
    local hovered = (state.hover_until or 0) > t
    m.hover = hovered
    local r = 6 * S
    if hovered then
        local hs = 0.80 * S
        local _, hh = text_size('nard', hs)
        text_at(bx + 4 * S, by + r - hh / 2, C.gold, 'nard', hs, true)
        imgui.SetCursorPos({ bx + W - r * 2, by })
        if round_button('##nard_min', 'min', r) then
            cfg.minimized = true
            settings.save()
            dlog.add('UI', 'Overlay minimized')
        end
        imgui.SetCursorPos({ bx + W - r * 4 - 5 * S, by })
        local _, hov = round_button('##nard_help', 'help', r)
        if hov then tooltip_text(OVERLAY_HELP) end
        imgui.SetCursorPos({ bx + W - r * 6 - 10 * S, by })
        local gc, ghov = round_button('##nard_cfg', 'gear', r)
        if gc then state.cfg_win.open = not state.cfg_win.open end
        if ghov then tooltip_text('Settings  (/nard)') end
        imgui.SetCursorPos({ bx + W - r * 8 - 15 * S, by })
        local bc, bhov = round_button('##nard_dbg', 'bug', r)
        if bc then state.log_win.open = not state.log_win.open end
        if bhov then tooltip_text('Debug log  (/nard log)') end
    end

    local y = by + r * 2 + 10 * S
    if cfg.show_cd then
        local ph = draw_cd_row(dl, wx, wy, bx, y - 6 * S, W, S * sz('s_cd'), t)
        y = y - 6 * S + ph + ((#rows > 0) and 18 * S or 4 * S)
    end
    if #rows == 0 and not cfg.show_cd then
        local h = 34 * S
        if cfg.panel then
            dl:AddRectFilled({ wx + bx, wy + y }, { wx + bx + W, wy + y + h }, col32({ 0.05, 0.06, 0.09, 0.78 }), 12 * S)
            dl:AddRect({ wx + bx, wy + y }, { wx + bx + W, wy + y + h }, col32({ 0.96, 0.74, 0.26, 0.35 }), 12 * S, ROUND_ALL, 1.0)
        end
        local txt = EMPTY
        local w, th = text_size(txt, 0.85 * S)
        if not cfg.panel then
            pill(dl, wx, wy, bx + (W - w) / 2 - 11 * S, y + (h - th) / 2 - 3 * S, w + 22 * S, th + 6 * S,
                { 0.05, 0.06, 0.09, 0.86 }, { 0.96, 0.74, 0.26, 0.55 })
        end
        text_at(bx + (W - w) / 2, y + (h - th) / 2, { 0.85, 0.87, 0.92, 1 }, txt, 0.85 * S, false)
        y = y + h
    end

    for _, row in ipairs(rows) do
        local rh = draw_row(dl, wx, wy, bx, y, W, row, m, t, now, hovered)
        y = y + rh + 14 * S
    end

    imgui.SetCursorPos({ bx, by })
    imgui.Dummy({ W, y - by - 10 * S })
end

local function draw_overlay_compact(list, now)
    local S      = cfg.scale
    local m      = 20 * S
    local gap    = 4 * S
    local pad    = 6 * S
    local r      = 6 * S
    local flat   = sorted_flat(list)
    local n      = #flat
    local bx, by = imgui.GetCursorPos()
    local wx, wy = imgui.GetWindowPos()
    local dl     = imgui.GetWindowDrawList()

    local splits = 0
    for i = 2, n do
        if flat[i].group ~= flat[i - 1].group then splits = splits + 1 end
    end
    local sgap   = 8 * S
    local label  = (n == 0 and not cfg.show_cd) and 'nard' or nil
    local lw     = label and (text_size(label, 0.85 * S) + gap) or 0
    local cdw    = cfg.show_cd and ((m + gap) * 2 + ((n > 0) and sgap or 0)) or 0
    local h      = m + pad * 2 - 4 * S
    local w      = pad * 2 + h * 0.3 + lw + cdw + n * (m + gap) + splits * sgap + r * 2
    local px, py = wx + bx, wy + by

    dl:AddRectFilled({ px, py }, { px + w, py + h }, col32({ 0.07, 0.08, 0.11, 0.88 }), h / 2)
    dl:AddRect({ px, py }, { px + w, py + h }, col32({ 0.96, 0.74, 0.26, 0.45 }), h / 2, ROUND_ALL, 1.2)

    local x = bx + pad + h * 0.15
    local ty = by + (h - m) / 2
    if label then
        local _, lh = text_size(label, 0.85 * S)
        text_at(x, by + (h - lh) / 2, C.gold, label, 0.85 * S, false)
        x = x + lw
    end
    if cfg.show_cd then
        local at = anim_time()
        local prr = cd_update(CDS.pr, at)
        local dur = cd_update(CDS.du, at)
        draw_cd_ring(dl, wx, wy, x, ty, m, S, at, CDS.pr, prr, prr > 0 and 'cool' or 'ready')
        x = x + m + gap
        draw_cd_ring(dl, wx, wy, x, ty, m, S, at, CDS.du, dur,
            (dur > 0) and 'cool' or (du_window_open() and 'ready' or 'idle'))
        x = x + m + gap
        if n > 0 then
            local dx = wx + x + sgap / 2 - gap / 2
            dl:AddLine({ dx, wy + ty + 3 * S }, { dx, wy + ty + m - 3 * S }, col32({ 0.96, 0.74, 0.26, 0.45 }), 1.2)
            x = x + sgap
        end
    end
    for i, e in ipairs(flat) do
        if i > 1 and e.group ~= flat[i - 1].group then
            -- thin divider between the melee set and the mage set
            local dx = wx + x + sgap / 2 - gap / 2
            dl:AddLine({ dx, wy + ty + 3 * S }, { dx, wy + ty + m - 3 * S }, col32({ 0.96, 0.74, 0.26, 0.45 }), 1.2)
            x = x + sgap
        end
        local v       = e.value or 0
        local lucky   = (not e.busted) and v == e.def.lucky
        local unlucky = (not e.busted) and v == e.def.unlucky
        local face, nc = { 0.98, 0.95, 0.87, 1 }, C.slate
        if e.busted then face, nc = { 0.45, 0.10, 0.10, 1 }, { 1, 0.85, 0.85, 1 }
        elseif lucky then face, nc = { 1.0, 0.80, 0.45, 1 }, { 0.30, 0.15, 0.02, 1 }
        elseif v == 11 then face, nc = { 1.0, 0.90, 0.55, 1 }, { 0.35, 0.20, 0.02, 1 }
        elseif unlucky then face, nc = { 0.80, 0.90, 0.99, 1 }, { 0.08, 0.20, 0.26, 1 } end
        local sx, sy = wx + x, wy + ty
        dl:AddRectFilled({ sx, sy }, { sx + m, sy + m }, col32(face), 5 * S)
        local txt = e.busted and 'X' or tostring(v)
        local tw, th = text_size(txt, 1.0 * S)
        text_at(x + (m - tw) / 2, ty + (m - th) / 2, nc, txt, 1.0 * S, false)
        imgui.SetCursorPos({ x, ty })
        imgui.InvisibleButton('##nc' .. e.id, { m, m })
        if imgui.IsItemHovered() then roll_tooltip(e, now) end
        x = x + m + gap
    end
    imgui.SetCursorPos({ x, by + (h - r * 2) / 2 })
    if round_button('##nard_max', 'max', r) then
        cfg.minimized = false
        settings.save()
        dlog.add('UI', 'Overlay restored')
    end
    imgui.SetCursorPos({ bx, by })
    imgui.Dummy({ w, h })
end

----------------------------------------------------------------------------
-- Separate pieces: each cooldown pill and each roll row gets its own window.
-- Right-click a piece -> unlock / lock / reset / join back.
----------------------------------------------------------------------------
local PIECE_NAME = {
    pr = 'Phantom Roll cooldown', du = 'Double-Up cooldown',
    MELEE = 'Melee rolls', MAGES = 'Mage rolls', SELF = 'Your rolls', PARTY = 'Party rolls',
}
local PIECE_OFF = { pr = 0, du = 26, MELEE = 62, MAGES = 250, SELF = 440, PARTY = 630 }

local function piece_default(key)
    return { x = cfg.pos_x, y = cfg.pos_y + (PIECE_OFF[key] or 0) * cfg.scale, unlocked = false }
end

local function piece(key)
    if type(cfg.pieces) ~= 'table' then cfg.pieces = {} end
    local p = cfg.pieces[key]
    if type(p) ~= 'table' or tonumber(p.x) == nil or tonumber(p.y) == nil then
        p = piece_default(key)
        cfg.pieces[key] = p
    end
    return p
end

local function set_all_pieces(unlocked)
    for key in pairs(PIECE_NAME) do piece(key).unlocked = unlocked end
    settings.save()
    dlog.add('UI', unlocked and 'All pieces unlocked - drag them, right-click to lock' or 'All pieces locked')
end

local function reset_layout()
    for key in pairs(PIECE_NAME) do
        local u = piece(key).unlocked
        cfg.pieces[key] = piece_default(key)
        cfg.pieces[key].unlocked = u
        state.piece_reset[key] = true
    end
    settings.save()
    dlog.add('UI', 'Piece layout reset')
end

local function set_free(on)
    cfg.free = on
    if on then
        for key in pairs(PIECE_NAME) do
            if type(cfg.pieces) ~= 'table' or cfg.pieces[key] == nil then
                piece(key)
                state.piece_reset[key] = true
            end
        end
        set_all_pieces(true)
        dlog.add('UI', 'Pieces separated - drag each one, right-click > Lock here')
    else
        dlog.add('UI', 'Pieces joined back into one overlay')
    end
    settings.save()
end

local function rclick_open(id)
    local hflag = ImGuiHoveredFlags_AllowWhenBlockedByActiveItem or 128
    local ok, hv = pcall(function () return imgui.IsWindowHovered(hflag) end)
    if not ok then hv = imgui.IsWindowHovered() end
    if hv and imgui.IsMouseClicked(1) then imgui.OpenPopup(id) end
    return hv
end

local function menu_item(label) return imgui.Selectable(label, false) end

local function common_menu_tail()
    imgui.Separator()
    if menu_item('Settings') then state.cfg_win.open = true end
    if menu_item('Debug log') then state.log_win.open = true end
end

-- right-click menu on the joined overlay
local function main_context_menu()
    if imgui.BeginPopup('nard_ctx_main') then
        imgui.TextColored(C.gold, 'nard')
        imgui.Separator()
        if menu_item('Separate pieces (move each freely)') then set_free(true) end
        if menu_item(cfg.locked and 'Unlock overlay' or 'Lock overlay') then
            cfg.locked = not cfg.locked
            settings.save()
        end
        if menu_item(cfg.minimized and 'Restore' or 'Minimize') then
            cfg.minimized = not cfg.minimized
            settings.save()
        end
        common_menu_tail()
        imgui.EndPopup()
    end
end

-- right-click menu on one piece
local function piece_context_menu(key)
    local id = 'nard_ctx_' .. key
    if imgui.BeginPopup(id) then
        local p = piece(key)
        imgui.TextColored(C.gold, PIECE_NAME[key] or key)
        imgui.Separator()
        if menu_item(p.unlocked and 'Lock here' or 'Unlock (drag to move)') then
            p.unlocked = not p.unlocked
            settings.save()
            dlog.add('UI', ('%s %s'):format(PIECE_NAME[key] or key, p.unlocked and 'unlocked' or 'locked'))
        end
        if menu_item('Unlock all') then set_all_pieces(true) end
        if menu_item('Lock all') then set_all_pieces(false) end
        if menu_item('Reset this piece') then
            local u = p.unlocked
            cfg.pieces[key] = piece_default(key)
            cfg.pieces[key].unlocked = u
            state.piece_reset[key] = true
            settings.save()
        end
        imgui.Separator()
        if menu_item('Join everything back') then set_free(false) end
        common_menu_tail()
        imgui.EndPopup()
    end
end

local PIECE_FLAGS = nil
local function piece_window(key, drawfn)
    local p = piece(key)
    local S = cfg.scale
    if PIECE_FLAGS == nil then
        PIECE_FLAGS = bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_NoBackground,
            ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoSavedSettings,
            ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav)
    end
    local cond = state.piece_reset[key] and ImGuiCond_Always or ImGuiCond_Appearing
    imgui.SetNextWindowPos({ p.x, p.y }, cond)
    state.piece_reset[key] = nil
    local flags = PIECE_FLAGS
    if not p.unlocked then flags = bit.bor(flags, ImGuiWindowFlags_NoMove) end

    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 6 * S, 6 * S })
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0)
    if imgui.Begin('nard_piece_' .. key, state.overlay_open, flags) then
        local t = anim_time()
        local bx, by = imgui.GetCursorPos()
        local wx, wy = imgui.GetWindowPos()
        local dl     = imgui.GetWindowDrawList()

        local hv = rclick_open('nard_ctx_' .. key)
        if hv then state.phover[key] = t + 0.5 end
        local hovered = (state.phover[key] or 0) > t

        state.no_hit = p.unlocked          -- no click-catching buttons while dragging
        drawfn(dl, wx, wy, bx, by, hovered and not p.unlocked, p.unlocked)
        state.no_hit = false

        if p.unlocked then
            local ww, wh = imgui.GetWindowSize()
            local pulse = 0.5 + 0.5 * math.sin(t * 2.0)
            dl:AddRect({ wx + 1, wy + 1 }, { wx + ww - 1, wy + wh - 1 },
                col32({ 0.96, 0.74, 0.26, 0.45 + 0.30 * pulse }), 8 * S, ROUND_ALL, 1.4)
            local tag = 'DRAG  -  right-click to lock'
            local tw, th = text_size(tag, 0.55 * S)
            pill(dl, wx, wy, 4 * S, wh - th - 7 * S, tw + 12 * S, th + 4 * S, { 0.05, 0.06, 0.09, 0.92 }, { 0.96, 0.74, 0.26, 0.6 })
            text_at(10 * S, wh - th - 5 * S, C.gold, tag, 0.55 * S, false)
        end

        local x, y = imgui.GetWindowPos()
        if math.abs(x - p.x) > 0.5 or math.abs(y - p.y) > 0.5 then
            p.x, p.y = x, y
            state.pieces_dirty = true
        end
        if state.pieces_dirty and not imgui.IsMouseDown(0) then
            state.pieces_dirty = false
            settings.save()
            dlog.add('UI', ('%s moved to %d,%d'):format(PIECE_NAME[key] or key, x, y), true)
        end
        piece_context_menu(key)
    end
    imgui.End()
    imgui.PopStyleVar(2)
end

local function draw_free_layout(list, now)
    local S = cfg.scale
    local m = layout(S)
    if cfg.show_cd then
        for _, key in ipairs({ 'pr', 'du' }) do
            piece_window(key, function (dl, wx, wy, bx, by, hovered, unlocked)
                local t  = anim_time()
                local Sc = S * sz('s_cd')
                local cd = CDS[key]
                local rem = cd_update(cd, t)
                local mode
                if key == 'pr' then mode = (rem > 0) and 'cool' or 'ready'
                else mode = (rem > 0) and 'cool' or (du_window_open() and 'ready' or 'idle') end
                local w, h = draw_cd_pill(dl, wx, wy, bx + 3 * S, by + 3 * S, Sc, t, cd, rem, mode)
                imgui.SetCursorPos({ bx, by })
                imgui.Dummy({ w + 6 * S, h + 6 * S + (unlocked and 16 * S or 0) })
            end)
        end
    end
    for _, row in ipairs(build_rows(list)) do
        piece_window(row.label, function (dl, wx, wy, bx, by, hovered, unlocked)
            local t = anim_time()
            local W = #row.items * m.colW + 8 * S
            m.hover = hovered
            local top = by + 10 * S
            local rh = draw_row(dl, wx, wy, bx, top, W, row, m, t, now, hovered or unlocked or cfg.panel)
            imgui.SetCursorPos({ bx, by })
            imgui.Dummy({ W, top - by + rh + (unlocked and 16 * S or 0) })
        end)
    end
end

local function draw_overlay()
    if not cfg.visible then return end
    if not state.testing and not cor_active() then return end
    if not state.testing and solo.hidden then return end
    if my_id() == 0 and not state.testing then return end
    local list = state.active
    if #list == 0 and not (cfg.show_empty and is_cor())
        and not (cfg.show_cd and ability_recast(PR_RECAST_ID) > 0) then return end

    local now = os.time()
    local S   = cfg.scale
    frame_jobs = rolls.party_jobs()

    if cfg.free and not cfg.minimized then
        push_theme()
        draw_free_layout(list, now)
        pop_theme()
        return
    end

    imgui.SetNextWindowPos({ cfg.pos_x, cfg.pos_y }, state.reset_pos and ImGuiCond_Always or ImGuiCond_FirstUseEver)
    state.reset_pos = false

    push_theme()
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 6 * S, 6 * S })
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0)

    local flags = bit.bor(
        ImGuiWindowFlags_NoDecoration,
        ImGuiWindowFlags_NoBackground,
        ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoSavedSettings,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav)
    if cfg.locked then flags = bit.bor(flags, ImGuiWindowFlags_NoMove) end

    if imgui.Begin('nard_overlay', state.overlay_open, flags) then
        if cfg.minimized then
            draw_overlay_compact(list, now)
        else
            draw_overlay_full(list, now)
        end
        rclick_open('nard_ctx_main')
        main_context_menu()
        local x, y = imgui.GetWindowPos()
        if math.abs(x - cfg.pos_x) > 0.5 or math.abs(y - cfg.pos_y) > 0.5 then
            cfg.pos_x, cfg.pos_y = x, y
            state.pos_dirty = true
        end
        if state.pos_dirty and not imgui.IsMouseDown(0) then
            state.pos_dirty = false
            settings.save()
            dlog.add('UI', ('Overlay moved to %d,%d'):format(x, y), true)
        end
    end
    imgui.End()

    imgui.PopStyleVar(2)
    pop_theme()
end

----------------------------------------------------------------------------
-- settings window
----------------------------------------------------------------------------
local function opt_checkbox(label, key, tip)
    local v = { cfg[key] }
    if imgui.Checkbox(label, v) then
        cfg[key] = v[1]
        sync_log()
        settings.save()
        dlog.add('CFG', ('%s = %s'):format(key, tostring(v[1])))
    end
    help_marker('##h_' .. key, tip)
end

local function size_slider(W, label, key, lo, hi, tip)
    imgui.PushItemWidth(W - 70)
    local v = { sz(key) }
    local changed = imgui.SliderFloat('##sz_' .. key, v, lo, hi, label .. '  %.2f')
    if changed then cfg[key] = v[1] end
    -- save when you let go of the slider (or on every change if this build can't tell)
    local ok, done = pcall(function () return imgui.IsItemDeactivatedAfterEdit() end)
    if (ok and done) or (not ok and changed) then
        settings.save()
        dlog.add('CFG', ('%s size = %.2f'):format(label, sz(key)))
    end
    imgui.PopItemWidth()
    help_marker('##h_sz_' .. key, tip)
end

-- BeginChild differs between ImGui builds (bool border vs child flags).
-- Try each form once and remember which one works.
local child_form = nil
local function begin_child(id, size)
    local forms = {
        function () return imgui.BeginChild(id, size, true) end,
        function () return imgui.BeginChild(id, size, ImGuiChildFlags_Borders or ImGuiChildFlags_Border or 1) end,
        function () return imgui.BeginChild(id, size, 1, 0) end,
        function () return imgui.BeginChild(id, size) end,
    }
    if child_form then
        local ok = pcall(forms[child_form])
        return ok
    end
    for i, f in ipairs(forms) do
        local ok = pcall(f)
        if ok then
            child_form = i
            dlog.add('INFO', ('BeginChild form %d works on this build'):format(i), true)
            return true
        end
    end
    dlog.add('ERR', 'BeginChild not supported - log shown without scroll box')
    return false
end

-- Place a popup window next to the overlay every time it opens, kept on screen.
local function place_window(dx, dy)
    local sw, sh = 1920, 1080
    pcall(function ()
        local ds = imgui.GetIO().DisplaySize
        sw, sh = ds.x or ds[1] or sw, ds.y or ds[2] or sh
    end)
    local x = math.max(10, math.min(cfg.pos_x + dx, sw - 300))
    local y = math.max(10, math.min(cfg.pos_y + dy, sh - 300))
    imgui.SetNextWindowPos({ x, y }, ImGuiCond_Appearing)
end

local function draw_config()
    local ws = state.cfg_win
    if not ws.open then return end
    local W = 250
    push_theme()
    place_window(40, 60)
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoCollapse)
    if imgui.Begin('nard_config', ws.open_tbl, flags) then
        window_header('nard', W, ws)
        if not ws.min then
            imgui.Separator()
            opt_checkbox('Show overlay', 'visible', 'Show the floating roll dice.')
            opt_checkbox('Lock position', 'locked', 'Stop the overlay from being dragged.')
            opt_checkbox('Party rolls', 'show_party', "Also show other Corsairs' rolls that land on you (blue names).")
            opt_checkbox('Bust chance', 'show_bust', 'Under your newest roll: chance the next Double-Up busts, and Double-Up seconds left.')
            opt_checkbox('Row labels', 'row_labels', 'Show MELEE / MAGES labels over each row. Rows are picked from the jobs of the party members each roll hit (WHM BLM RDM BRD SMN = mages).')
            opt_checkbox('Only on COR', 'cor_only', "Hide nard and stop tracking unless your main job is COR. It switches on by itself when you change to COR.")
            if cfg.cor_only then
                opt_checkbox('  ...or sub COR', 'cor_sub', 'Also switch on when COR is your sub job.')
            end
            opt_checkbox('Roll cooldowns', 'show_cd', 'Phantom Roll and Double-Up recasts at the top of nard. Double-Up turns green only when it is off cooldown AND a Double-Up window is open; grey means no roll to double.')
            if cfg.show_cd then
                imgui.PushItemWidth(W - 70)
                local wv = { tonumber(cfg.cd_warn) or 5 }
                if imgui.SliderFloat('##cd_warn', wv, 0, 15, (wv[1] < 0.5) and 'Warning off' or 'Warn %.0f s before') then
                    cfg.cd_warn = math.floor(wv[1] + 0.5)
                    settings.save()
                end
                imgui.PopItemWidth()
                help_marker('##h_cd_warn', 'Amber pulsing highlight on the cooldown pills this many seconds before they are ready. 0 = off.')
            end
            opt_checkbox('Hide when solo', 'solo_hide', 'Hide nard completely after you have been out of a party for the time below. It comes back the moment you join a party (or alliance).')
            if cfg.solo_hide then
                imgui.PushItemWidth(W - 70)
                local mv = { tonumber(cfg.solo_mins) or 6 }
                if imgui.SliderFloat('##solo_mins', mv, 1, 30, 'after %.0f min solo') then
                    cfg.solo_mins = math.floor(mv[1] + 0.5)
                    settings.save()
                end
                imgui.PopItemWidth()
                help_marker('##h_solo_mins', 'How long you can be out of a party before nard hides. /nard test still previews while hidden.')
            end
            opt_checkbox('Panel frame', 'panel', 'Draw a dark glass frame behind each row. Off = the dice float freely over the game, with outlined text.')
            opt_checkbox('Show when empty', 'show_empty', "While you're COR (main or sub), show a small 'Phantom Roll' marker when no rolls are up.")

            imgui.Spacing()
            imgui.TextColored(C.gold, 'Sizes')
            help_marker('##h_sizes', 'Each part has its own size. Overall scales everything; the others multiply on top of it.')
            size_slider(W, 'Overall',        'scale',  0.6, 2.0, 'Everything at once. Also: /nard scale 1.2')
            size_slider(W, 'Dice',           's_die',  0.6, 1.8, 'The dice, their numbers and the LUCKY / UNLUCKY chips.')
            size_slider(W, 'Roll names',     's_name', 0.6, 1.8, 'The name ribbons above each die.')
            size_slider(W, 'Effect & timer', 's_info', 0.6, 1.8, 'The plate under each die (effect value, timer) and the Double-Up pill.')
            size_slider(W, 'Cooldowns',      's_cd',   0.6, 1.8, 'The Phantom Roll and Double-Up cooldown pills at the top.')
            size_slider(W, 'Effects',        's_fx',   0.3, 1.8, 'Fire height, Lucky explosion and the 11 zoom & smash.')
            if imgui.Button('Reset sizes', { 100, 0 }) then
                cfg.scale, cfg.s_die, cfg.s_name, cfg.s_info, cfg.s_cd, cfg.s_fx = 1, 1, 1, 1, 1, 1
                settings.save()
                dlog.add('CFG', 'Sizes reset')
            end

            imgui.Spacing()
            imgui.TextColored(C.gold, 'Layout')
            help_marker('##h_layout', 'Separate pieces: the Phantom Roll pill, the Double-Up pill and each roll row (MELEE / MAGES / ...) become their own pieces. Right-click any piece to unlock it, drag it, then right-click > Lock here.')
            local fv = { cfg.free == true }
            if imgui.Checkbox('Separate pieces', fv) then set_free(fv[1]) end
            if cfg.free then
                if imgui.Button('Unlock all', { 74, 0 }) then set_all_pieces(true) end
                imgui.SameLine()
                if imgui.Button('Lock all', { 64, 0 }) then set_all_pieces(false) end
                imgui.SameLine()
                if imgui.Button('Reset', { 50, 0 }) then reset_layout() end
                help_marker('##h_reset', 'Reset puts every piece back in a stack under the overlay position. Right-click a single piece to reset just that one.')
            end

            imgui.Spacing()
            imgui.TextColored(C.gold, 'Debug')
            help_marker('##h_debug', 'Everything nard does is written to the debug log. Commands: /nard log, /nard debug on|off')
            opt_checkbox('Verbose (debug) tracing', 'verbose', 'Also record packet / engine traces (every roll packet with ids and message numbers, piece moves, recasts).')
            opt_checkbox('Echo to chat', 'echo', 'Also print every log line to your chat window.')
            if imgui.Button('Open log', { 74, 0 }) then state.log_win.open = true end
            imgui.SameLine()
            if imgui.Button('Save log', { 74, 0 }) then
                local f = dlog.save()
                if f then msg('Log saved: ' .. f) end
            end
            imgui.SameLine()
            if imgui.Button('Clear log', { 74, 0 }) then dlog.clear() end

            imgui.Spacing()
            if imgui.Button('Test', { 56, 0 }) then test_rolls() end
            help_marker('##h_test', 'Preview with fake rolls. Click again to cycle: 4 rolls (melee + mages), 2 rolls with Double-Up, 11 + Bust.')
            imgui.SameLine()
            if imgui.Button('Clear', { 56, 0 }) then
                state.active = {}
                state.testing = false
                dlog.add('CMD', 'Rolls cleared')
            end
            imgui.SameLine()
            if imgui.Button('Log', { 48, 0 }) then state.log_win.open = not state.log_win.open end

            imgui.Spacing()
            imgui.TextColored(C.dim, 'by Jboor')
        end
    end
    imgui.End()
    pop_theme()
end

----------------------------------------------------------------------------
-- debug log window
----------------------------------------------------------------------------
local function draw_log()
    local ws = state.log_win
    if not ws.open then return end
    local W = 520
    push_theme()
    place_window(60, 90)
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoCollapse)
    if imgui.Begin('nard_log', ws.open_tbl, flags) then
        window_header('nard - debug log', W, ws)
        if not ws.min then
            imgui.Separator()
            local v = { cfg.verbose }
            if imgui.Checkbox('Verbose (debug) tracing', v) then
                cfg.verbose = v[1]; sync_log(); settings.save()
                dlog.add('CFG', 'verbose = ' .. tostring(v[1]))
            end
            help_marker('##h_verbose', 'Also record packet / engine traces (every roll packet with ids and message numbers).')
            imgui.SameLine()
            local ec = { cfg.echo }
            if imgui.Checkbox('Echo to chat', ec) then
                cfg.echo = ec[1]; sync_log(); settings.save()
            end
            imgui.SameLine()
            if imgui.Button('Clear') then dlog.clear() end
            imgui.SameLine()
            if imgui.Button('Save to file') then
                local f = dlog.save()
                if f then msg('Log saved: ' .. f) end
            end
            imgui.SameLine()
            imgui.PushItemWidth(90)
            if imgui.BeginCombo('##filter', dlog.filter) then
                for _, c in ipairs(dlog.order) do
                    if imgui.Selectable(c, dlog.filter == c) then dlog.filter = c end
                end
                imgui.EndCombo()
            end
            imgui.PopItemWidth()

            local boxed = begin_child('##nard_log_lines', { W, 260 })
            local shown = 0
            for _, l in ipairs(dlog.lines) do
                if (dlog.filter == 'ALL' or dlog.filter == l.cat) and (boxed or shown < 20) then
                    imgui.TextColored(C.dim, l.t)
                    imgui.SameLine()
                    imgui.TextColored(dlog.cats[l.cat] or C.cream, '[' .. l.cat .. ']')
                    imgui.SameLine()
                    imgui.TextColored(l.v and C.dim or C.cream, l.msg)
                    shown = shown + 1
                end
            end
            if boxed then imgui.EndChild() end
            imgui.TextColored(C.dim, ('%d / %d lines   -   Ashita/logs/nard/'):format(#dlog.lines, dlog.max))
        end
    end
    imgui.End()
    pop_theme()
end

----------------------------------------------------------------------------
-- events
----------------------------------------------------------------------------
ashita.events.register('load', 'nard_load', function ()
    dlog.add('INFO', ('nard v%s loaded'):format(addon.version))
end)

ashita.events.register('unload', 'nard_unload', function ()
    pcall(save_rolls, true)
    settings.save()
end)

ashita.events.register('packet_in', 'nard_packet_in', function (e)
    if e.id == 0x028 then
        local ok, act = pcall(parse_action, e)
        if not ok then
            dlog.add('ERR', 'Action parse failed: ' .. tostring(act))
            return
        end
        if act.category == 6 then
            if not cor_active() then return end
            if state.testing then state.testing = false; state.active = {} end
            local ok2, err = pcall(on_action, act)
            if not ok2 then dlog.add('ERR', 'Roll handler error: ' .. tostring(err)) end
        end
    elseif e.id == 0x076 then
        local ok, err = pcall(parse_party_buffs, e.data)
        if not ok then dlog.add('ERR', 'Party buff parse failed: ' .. tostring(err)) end
    elseif e.id == 0x00A then
        for _, en in ipairs(state.active) do en.du_until = nil end
        dlog.add('INFO', 'Zoned - Double-Up windows closed', true)
    end
end)

ashita.events.register('d3d_present', 'nard_present', function ()
    tick()
    draw_overlay()
    draw_config()
    draw_log()
end)

local HELP = {
    '/nard - settings window',
    '/nard test - preview rolls (cycles presets)',
    '/nard clear - clear tracked rolls',
    '/nard min - minimize / restore overlay',
    '/nard lock - lock position (all pieces when separated)',
    '/nard unlock - unlock position / all pieces',
    '/nard free - separate pieces on / off',
    '/nard layout reset - put separated pieces back',
    '/nard scale <0.6-2.0> - overlay size',
    '/nard show | hide',
    '/nard reset - default position',
    '/nard log - debug log',
    '/nard debug [on|off] - verbose tracing',
}

ashita.events.register('command', 'nard_command', function (e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/nard' then return end
    e.blocked = true

    local sub = (args[2] or ''):lower()
    dlog.add('CMD', e.command)

    if sub == '' or sub == 'config' or sub == 'settings' then
        state.cfg_win.open = not state.cfg_win.open
    elseif sub == 'test' then
        test_rolls()
    elseif sub == 'clear' then
        state.active = {}
        state.testing = false
    elseif sub == 'min' then
        cfg.minimized = not cfg.minimized
    elseif sub == 'lock' then
        if cfg.free then
            set_all_pieces(false)
            msg('All pieces locked')
        else
            cfg.locked = not cfg.locked
            msg('Overlay ' .. (cfg.locked and 'locked' or 'unlocked'))
        end
    elseif sub == 'unlock' then
        if cfg.free then set_all_pieces(true); msg('All pieces unlocked - drag them') else cfg.locked = false; msg('Overlay unlocked') end
    elseif sub == 'free' or sub == 'separate' then
        set_free(not cfg.free)
        msg(cfg.free and 'Pieces separated - drag them, right-click > Lock here' or 'Pieces joined back')
    elseif sub == 'layout' and (args[3] or ''):lower() == 'reset' then
        reset_layout()
        msg('Piece layout reset')
    elseif sub == 'scale' then
        local n = tonumber(args[3])
        if n then
            cfg.scale = math.max(0.6, math.min(2.0, n))
            msg(('Scale %.2f'):format(cfg.scale))
        else
            msg('Usage: /nard scale <0.6-2.0>')
        end
    elseif sub == 'show' then
        cfg.visible = true
    elseif sub == 'hide' then
        cfg.visible = false
    elseif sub == 'reset' then
        cfg.pos_x, cfg.pos_y = defaults.pos_x, defaults.pos_y
        state.reset_pos = true
    elseif sub == 'log' then
        state.log_win.open = not state.log_win.open
    elseif sub == 'debug' then
        local a = (args[3] or ''):lower()
        if a == 'on' then cfg.verbose = true
        elseif a == 'off' then cfg.verbose = false
        else cfg.verbose = not cfg.verbose end
        sync_log()
        msg('Verbose tracing ' .. (cfg.verbose and 'ON' or 'OFF'))
    else
        for _, line in ipairs(HELP) do msg(line) end
    end
    settings.save()
end)
