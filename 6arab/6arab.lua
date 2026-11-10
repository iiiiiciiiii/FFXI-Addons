--[[
    6arab  (طرب - "musical delight")
    Floating Bard song tracker for Ashita v4 - Phoenix (level 75 cap)
    Theeb theme - by Jboor   (companion to nard)

    Shows each song you sing as a floating note tile:
      - song name ribbon, note tile, effect, timer bar + time left
      - amber pulse when a song is about to end
      - when a song finishes it turns grey, stays 20s (configurable), then fades away
      - recast pill under a song that is still on cooldown
      - party songs row + enemy songs row (Requiem, Lullaby, Elegy, Threnody)
    Real buff check: a song that wears off early or gets overwritten goes grey at once.

    Commands:
      /6arab              settings window
      /6arab test         preview songs (cycles 3 presets)
      /6arab clear        clear tracked songs
      /6arab min          minimize / restore the overlay
      /6arab lock         lock / unlock overlay position
      /6arab scale <n>    overlay size (0.6 - 2.0)
      /6arab show|hide    show / hide the overlay
      /6arab reset        move the overlay back to default position
      /6arab log          debug log window
      /6arab debug [on|off]  verbose (debug) tracing
]]--

addon.name    = '6arab'
addon.author  = 'Jboor'
addon.version = '3.0.3'
addon.desc    = 'Floating Bard song tracker (Phoenix Lv75) - Theeb theme'
addon.link    = ''

require('common')
local imgui    = require('imgui')
local settings = require('settings')
local chat     = require('chat')
local songs    = require('songs')
local dlog     = require('dlog')

----------------------------------------------------------------------------
-- constants
----------------------------------------------------------------------------
local BRD_JOB    = 10
local TROUBADOUR = 348
local MSG_WEAR   = 206
local MSG_DEFEAT = { [6] = true, [20] = true, [97] = true }
local FAIL_MSG   = { [75] = true, [85] = true, [283] = true, [284] = true, [653] = true, [654] = true, [655] = true, [656] = true }
local ENDING_AT  = 15    -- seconds left when the amber "ending" pulse starts

local ROUND_ALL = ImDrawFlags_RoundCornersAll or ImDrawCornerFlags_All or 0
local ROUND_BOT = ImDrawFlags_RoundCornersBottom or ImDrawCornerFlags_Bot or ROUND_ALL
local REFILL_TIME = 0.7   -- seconds the tile takes to refill on a new cast

local C = {
    gold   = { 0.96, 0.74, 0.26, 1.0 },
    flame  = { 1.00, 0.62, 0.18, 1.0 },
    cream  = { 0.97, 0.94, 0.86, 1.0 },
    steel  = { 0.66, 0.72, 0.82, 1.0 },
    dim    = { 0.50, 0.53, 0.60, 1.0 },
    slate  = { 0.17, 0.21, 0.29, 1.0 },
    red    = { 1.00, 0.38, 0.38, 1.0 },
    green  = { 0.58, 0.96, 0.52, 1.0 },
    grey   = { 0.55, 0.56, 0.60, 1.0 },
    bg     = { 0.07, 0.08, 0.11, 0.95 },
    bg2    = { 0.13, 0.15, 0.20, 1.0 },
}

local ROW_TINT = {
    MELEE = { 0.96, 0.74, 0.26 },
    MAGES = { 0.55, 0.72, 1.00 },
    ENEMY = { 1.00, 0.46, 0.40 },
}
local ROW_ORDER = { MELEE = 1, MAGES = 2, ENEMY = 3 }

-- BRD abilities shown as cooldown pills (recast ids from the job ability table)
local ABILITIES = {
    { key = 'cd_sv',    short = 'SV',    name = 'Soul Voice',  rid = 0,   buff = 52,  main = true,  col = { 1.00, 0.55, 0.85 } },
    { key = 'cd_pian',  short = 'PIAN',  name = 'Pianissimo',  rid = 112, buff = 409, col = { 0.62, 0.86, 1.00 } },
    { key = 'cd_night', short = 'NIGHT', name = 'Nightingale', rid = 109, buff = 347, main = true, col = { 0.80, 0.70, 1.00 } },
    { key = 'cd_troub', short = 'TROUB', name = 'Troubadour',  rid = 110, buff = 348, main = true, col = { 1.00, 0.78, 0.40 } },
}


----------------------------------------------------------------------------
-- settings
----------------------------------------------------------------------------
local defaults = T{
    visible     = true,
    minimized   = false,
    locked      = false,
    scale       = 1.0,
    s_icon      = 1.0,     -- separate sizes (multiplied by the overall scale)
    s_name      = 1.0,
    s_info      = 1.0,
    fade_s      = 4,       -- seconds a finished song takes to fade away
    exact       = true,    -- read real time left from your buff bar
    raw_cal     = 0,       -- learned buff-timer clock offset (absolute timer builds)
    raw_cal_ok  = false,
    show_set    = true,    -- ghost tiles for songs from your set that are not up
    set_melee   = T{ '', '', '', '' },
    set_mages   = T{ '', '', '', '' },
    show_cd     = true,    -- ability cooldown pills on top
    cd_sv       = true,
    cd_pian     = true,
    cd_night    = true,
    cd_troub    = true,
    cd_on_sub   = false,   -- show Pianissimo pill when BRD is only your sub job
    grey_early  = false,   -- also grey out songs that end early (overwritten / wore off / defeated / KO)
    bonus_pct   = 0,       -- song duration bonus % from gear
    bonus_flat  = 0,       -- flat seconds added to party songs
    track_enemy = true,
    show_recast = true,
    row_labels  = true,
    panel       = false,   -- glass frame behind each row (off = tiles float freely)
    show_empty  = true,
    brd_only    = true,    -- only show / track while you're on BRD
    brd_sub     = true,    -- ...also when BRD is your sub job
    pos_x       = 320,
    pos_y       = 480,
    verbose     = false,
    echo        = false,
}
local cfg = settings.load(defaults)

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
    testing      = false,
    last_cast    = 0,
}

local function sync_log()
    dlog.verbose = cfg.verbose
    dlog.echo    = cfg.echo
end
sync_log()

settings.register('settings', '6arab_settings_update', function (s)
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

local function is_brd()
    local ok, r = pcall(function ()
        local p = player()
        return p:GetMainJob() == BRD_JOB or p:GetSubJob() == BRD_JOB
    end)
    return ok and r or false
end

-- Is 6arab switched on right now? (BRD-only mode)
-- Raw job read: true / false, or nil when the game gives no job right now
-- (it briefly reports job 0 at times - that must not switch 6arab off).
local function brd_raw()
    if not cfg.brd_only then return true end
    local ok, r = pcall(function ()
        local p = player()
        local mj, sj = p:GetMainJob(), p:GetSubJob()
        if mj == BRD_JOB then return true end
        if cfg.brd_sub and sj == BRD_JOB then return true end
        if mj == 0 or mj == nil or (cfg.brd_sub and (sj == 0 or sj == nil)) then return nil end
        return false
    end)
    if not ok then return nil end
    return r
end

-- Stable on/off: switches on at once, but only off after the job has read
-- "not BRD" for JOB_OFF_DELAY seconds in a row.
local JOB_OFF_DELAY = 8
local job = { on = nil, off_since = nil }
local function job_update(now)
    local r = brd_raw()
    if r == nil then job.off_since = nil; return end
    if r then
        job.off_since = nil
        if job.on ~= true then
            if job.on ~= nil then dlog.add('INFO', 'BRD detected - 6arab on') end
            job.on = true
        end
    elseif job.on ~= false then
        job.off_since = job.off_since or now
        if job.on == nil or now - job.off_since >= JOB_OFF_DELAY then
            if job.on ~= nil then dlog.add('INFO', 'Not on BRD - 6arab off (hidden, not tracking)') end
            job.on = false
            job.off_at = now
        end
    end
end

local function brd_active()
    if not cfg.brd_only then return true end
    if job.on == nil then return brd_raw() == true end
    return job.on
end

local function i_am_dead()
    local ok, r = pcall(function ()
        local idx = party():GetMemberTargetIndex(0)
        local st  = AshitaCore:GetMemoryManager():GetEntity():GetStatus(idx)
        return st == 2 or st == 3
    end)
    return ok and r or false
end

local function mob_name(id)
    local ok, n = pcall(function ()
        return AshitaCore:GetMemoryManager():GetEntity():GetName(bit.band(id, 0x0FFF))
    end)
    if ok and n ~= nil and n ~= '' then return n end
    return 'target'
end

local function my_buffs()
    local set = {}
    pcall(function ()
        for _, v in pairs(player():GetBuffs()) do
            if v ~= nil and v > 0 and v ~= 255 then set[v] = (set[v] or 0) + 1 end
        end
    end)
    return set
end

local function spell_recast(id)
    if id == nil or id <= 0 then return 0 end
    local ok, v = pcall(function ()
        return AshitaCore:GetMemoryManager():GetRecast():GetSpellTimer(id) / 60   -- 1/60 s -> seconds
    end)
    return (ok and v) or 0
end

-- recast for a tracked song (test songs carry a fake one)
local function rc_of(e)
    if e.test_rc_end then return math.max(0, e.test_rc_end - os.time()) end
    return spell_recast(e.spell)
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
-- action packet (0x028) parsing  (same layout as nard)
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
    if act.category ~= 4 then return act end   -- only finished spells matter

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
            if bits(1) == 1 then off = off + 37 end
            if bits(1) == 1 then off = off + 34 end
            t.actions[#t.actions + 1] = a
        end
        act.targets[#act.targets + 1] = t
    end
    return act
end

----------------------------------------------------------------------------
-- song tracking
----------------------------------------------------------------------------
local function find_entry(key)
    for _, e in ipairs(state.active) do
        if e.key == key then return e end
    end
    return nil
end

local function mark_done(e, why)
    if e.done_at ~= nil then return end
    if why ~= 'DONE' and not cfg.grey_early then
        for i, x in ipairs(state.active) do
            if x == e then table.remove(state.active, i) break end
        end
        dlog.add('GONE', ('%s removed (%s)'):format(e.def.name, why:lower()))
        return
    end
    e.done_at = os.time()
    e.why = why
    dlog.add('GONE', ('%s -> grey (%s)'):format(e.def.name, why:lower()))
end

local MAGE_JOBS = { [3] = true, [4] = true, [5] = true, [10] = true, [15] = true }  -- WHM BLM RDM BRD SMN
local MAGE_SONGS = { Ballad = true }

-- MELEE or MAGES, from the jobs of the party members a song landed on
-- (you are left out); if that can't tell, from the song itself.
local function classify(targets, def)
    local melee, mage = 0, 0
    pcall(function ()
        local p = party()
        for i = 1, 17 do
            local id = p:GetMemberServerId(i)
            if id ~= 0 and targets ~= nil and targets[id] then
                if MAGE_JOBS[p:GetMemberMainJob(i)] then mage = mage + 1 else melee = melee + 1 end
            end
        end
    end)
    if mage > melee then return 'MAGES' end
    if melee > mage then return 'MELEE' end
    return MAGE_SONGS[def.fam.k] and 'MAGES' or 'MELEE'
end

local function calc_duration(def)
    local d = def.base
    if not def.enemy then
        d = d * (1 + (tonumber(cfg.bonus_pct) or 0) / 100) + (tonumber(cfg.bonus_flat) or 0)
    end
    if my_buffs()[TROUBADOUR] then d = d * 2 end
    return math.floor(d + 0.5)
end

local function on_spell(act)
    local me = my_id()
    if me == 0 or act.actor ~= me then return end
    local name = songs.name_of(act.param)
    if name == nil then return end
    local def = songs.def(name)

    local landed, buff, enemy_id, hit_me = 0, 0, nil, false
    local targets = {}
    for _, t in ipairs(act.targets) do
        local a = t.actions[1]
        if a ~= nil then
            dlog.add('PKT', ('  target %d msg=%d param=%d'):format(t.id, a.message, a.param), true)
            if not FAIL_MSG[a.message] then
                landed = landed + 1
                targets[t.id] = true
                if buff == 0 then buff = a.param end
                if t.id == me then hit_me = true end
                if enemy_id == nil and t.id ~= me then enemy_id = t.id end
            end
        end
    end
    dlog.add('PKT', ('spell=%d (%s) targets=%d landed=%d buff=%d'):format(act.param, name, #act.targets, landed, buff), true)

    if landed == 0 then
        dlog.add('FAIL', ('%s had no effect / resisted - not tracked'):format(name))
        return
    end
    if def.enemy and not cfg.track_enemy then
        dlog.add('SONG', ('%s skipped (enemy songs off)'):format(name), true)
        return
    end

    local dur = calc_duration(def)
    if dur <= 0 then
        dlog.add('SONG', ('%s landed (instant - not tracked)'):format(name))
        return
    end

    if state.testing then state.testing = false; state.active = {} end
    local now = os.time()
    state.last_cast = now
    local group = def.enemy and 'ENEMY' or classify(targets, def)
    local key = def.enemy and ('%d:%d'):format(act.param, enemy_id or 0) or ('%d:%s'):format(act.param, group)
    local e = find_entry(key)
    if e ~= nil and e.done_at == nil and now - e.started <= 2 then
        e.tcount = math.max(e.tcount or 0, landed)
        for id in pairs(targets) do e.targets[id] = true end
        dlog.add('PKT', ('%s: duplicate cast packet ignored'):format(name), true)
        return
    end
    if e ~= nil then
        e.fill_from = e.done_at and 0 or math.max(0, math.min(1, (e.ends - now) / e.dur))
        e.started, e.dur, e.ends = now, dur, now + dur
        e.done_at, e.why = nil, nil
        e.buff, e.targets, e.tcount, e.hit_me = buff, targets, landed, hit_me
        e.buff_seen, e.before, e.learn_until = false, my_buffs(), now + 4
        e.pop_pending = true
        dlog.add('SONG', ('%s refreshed (%s, %d hit)'):format(name, fmt_time(dur), landed))
        return
    end

    e = {
        id = state.next_id, key = key, spell = act.param, def = def,
        group = group,
        started = now, dur = dur, ends = now + dur,
        buff = buff, targets = targets, tcount = landed, hit_me = hit_me,
        enemy_id = def.enemy and enemy_id or nil,
        enemy_name = def.enemy and enemy_id and mob_name(enemy_id) or nil,
        pop_pending = true, fill_from = 0,
        buff_seen = false, before = my_buffs(), learn_until = now + 4,
    }
    state.next_id = state.next_id + 1
    table.insert(state.active, e)
    dlog.add('SONG', ('%s -> %s row, %s, %d hit%s'):format(name, group, fmt_time(dur), landed,
        e.enemy_name and (' on ' .. e.enemy_name) or ''))
end

local function on_message(data)
    local target = struct.unpack('I', data, 0x08 + 1)
    local p1     = struct.unpack('I', data, 0x0C + 1)
    local m      = bit.band(struct.unpack('H', data, 0x18 + 1), 0x7FFF)
    if m == MSG_WEAR then
        for _, e in ipairs(state.active) do
            if e.group == 'ENEMY' and e.done_at == nil and e.enemy_id == target and e.buff == p1 then
                mark_done(e, 'WORE OFF')
            end
        end
    elseif MSG_DEFEAT[m] then
        for _, e in ipairs(state.active) do
            if e.group == 'ENEMY' and e.done_at == nil and e.enemy_id == target then
                mark_done(e, 'DEFEATED')
            end
        end
    end
end

-- Real buff check (once a second). A song is only checked once its buff has
-- actually been SEEN on you - either the id from the packet, or a buff that
-- appeared right after the cast (learned). If 6arab never sees it, the song
-- just runs on its timer, so a wrong id can never remove a song.
local last_verify = 0
local function verify_buffs(now)
    if now == last_verify then return end
    last_verify = now
    local have = my_buffs()

    -- 1) learn / confirm buff ids for fresh songs
    local claimed = {}
    for _, e in ipairs(state.active) do
        if e.buff_seen then claimed[e.buff] = (claimed[e.buff] or 0) + 1 end
    end
    for _, e in ipairs(state.active) do
        if e.group ~= 'ENEMY' and e.done_at == nil and e.hit_me and not e.buff_seen and e.learn_until then
            if (e.buff or 0) > 0 and (have[e.buff] or 0) > (claimed[e.buff] or 0) then
                e.buff_seen = true
                claimed[e.buff] = (claimed[e.buff] or 0) + 1
                dlog.add('SONG', ('%s buff %d confirmed on you'):format(e.def.name, e.buff), true)
            else
                for b, cnt in pairs(have) do
                    if cnt > ((e.before or {})[b] or 0) and cnt > (claimed[b] or 0) then
                        dlog.add('SONG', ('%s buff learned: %d (packet said %d)'):format(e.def.name, b, e.buff or 0), true)
                        e.buff, e.buff_seen = b, true
                        claimed[b] = (claimed[b] or 0) + 1
                        break
                    end
                end
            end
            if not e.buff_seen and now > e.learn_until then
                e.learn_until = nil
                dlog.add('SONG', ('%s: buff not found on you - timer only'):format(e.def.name), true)
            end
            if e.buff_seen then e.before = nil end
        end
    end

    -- 2) fewer copies of a seen buff than songs shown -> the oldest went away
    local by_buff = {}
    for _, e in ipairs(state.active) do
        if e.group ~= 'ENEMY' and e.done_at == nil and e.buff_seen and now - e.started >= 3 then
            by_buff[e.buff] = by_buff[e.buff] or {}
            table.insert(by_buff[e.buff], e)
        end
    end
    for b, list in pairs(by_buff) do
        local extra = #list - (have[b] or 0)
        if extra > 0 then
            table.sort(list, function (a, c) return a.started < c.started end)
            local why = (now - state.last_cast <= 4) and 'OVERWRITTEN' or 'WORE OFF'
            for i = 1, extra do mark_done(list[i], why) end
        end
    end
end

----------------------------------------------------------------------------
-- Exact timers from your own buff bar. Ashita builds differ in what the
-- status timers hold, so 6arab works it out: if a timer counts down by 60 a
-- second it is "time left"; if it stays put it is an end stamp, and the clock
-- is learned the moment one of your buffs wears off. Until then (or if the
-- numbers look wrong) songs just use the estimate.
----------------------------------------------------------------------------
local sec_now, sec_clock = os.time(), os.clock()
-- os.time() with a smooth fraction of the current second (for the draining fill)
local function now_f()
    return sec_now + math.min(0.999, math.max(0, os.clock() - sec_clock))
end

local tm = { mode = nil, votes_rem = 0, votes_abs = 0, prev = {}, prev_c = 0, warned = false }

local function read_status()
    local ok, out = pcall(function ()
        local p = player()
        local ids, raws = p:GetBuffs(), p:GetStatusTimers()
        if ids == nil or raws == nil then return nil end
        local list = {}
        for k, id in pairs(ids) do
            local r = raws[k]
            if id ~= nil and id > 0 and id ~= 255 and r ~= nil and r > 0 and r < 0x7FFFFFFF then
                list[#list + 1] = { slot = k, id = id, raw = r }
            end
        end
        return list
    end)
    if ok then return out end
    return nil
end

local function raw_now()
    return now_f() * 60 + (tonumber(cfg.raw_cal) or 0)
end

local function exact_timers(now)
    if not cfg.exact then return end
    local list = read_status()
    if list == nil then
        if not tm.warned then tm.warned = true; dlog.add('INFO', 'Buff timers not readable on this build - using estimates') end
        return
    end
    local c = os.clock()

    -- learn what kind of timers this build gives
    local dt = c - tm.prev_c
    if dt >= 0.8 then
        local cur = {}
        for _, b in ipairs(list) do cur[b.slot] = b end
        for slot, old in pairs(tm.prev) do
            local b = cur[slot]
            if b and b.id == old.id then
                local d = old.raw - b.raw
                if math.abs(d - dt * 60) < dt * 20 then tm.votes_rem = tm.votes_rem + 1
                elseif d == 0 then tm.votes_abs = tm.votes_abs + 1 end
            elseif not b and (now - state.last_cast) > 2 and tm.mode == 'absolute' then
                -- a buff just wore off: its end stamp is "now" -> learn the clock
                local still = false
                for _, x in ipairs(list) do if x.id == old.id and x.raw == old.raw then still = true end end
                if not still then
                    cfg.raw_cal = old.raw - now_f() * 60
                    cfg.raw_cal_ok = true
                    settings.save()
                    dlog.add('INFO', ('Buff clock learned from a wear-off (buff %d)'):format(old.id), true)
                end
            end
        end
        if tm.mode == nil then
            if tm.votes_rem >= 3 then tm.mode = 'remaining'; dlog.add('INFO', 'Buff timers: time-left mode - exact song timers on')
            elseif tm.votes_abs >= 3 then tm.mode = 'absolute'; dlog.add('INFO', 'Buff timers: end-stamp mode - exact timers start after the first wear-off') end
        end
        tm.prev, tm.prev_c = {}, c
        for _, b in ipairs(list) do tm.prev[b.slot] = { id = b.id, raw = b.raw } end
    end

    if tm.mode == nil or (tm.mode == 'absolute' and not cfg.raw_cal_ok) then return end

    -- match songs to buff timers (same buff: soonest song <-> soonest timer)
    local raws_by = {}
    for _, b in ipairs(list) do
        raws_by[b.id] = raws_by[b.id] or {}
        table.insert(raws_by[b.id], b.raw)
    end
    local songs_by = {}
    for _, e in ipairs(state.active) do
        if e.group ~= 'ENEMY' and e.done_at == nil and e.buff_seen and e.hit_me then
            songs_by[e.buff] = songs_by[e.buff] or {}
            table.insert(songs_by[e.buff], e)
        end
    end
    local rn = raw_now()
    for b, ls in pairs(songs_by) do
        local rs = raws_by[b]
        if rs then
            table.sort(rs)
            table.sort(ls, function (a, x) return a.ends < x.ends end)
            for i, e in ipairs(ls) do
                local r = rs[i]
                if r then
                    local left = (tm.mode == 'remaining') and (r / 60) or ((r - rn) / 60)
                    if left > -2 and left < 1200 and left < e.dur * 3 + 60 then
                        local nf = now_f()
                        e.ends = nf + math.max(0, left)
                        e.dur = math.max(1, e.ends - e.started)
                        if not e.exact then
                            e.exact = true
                            dlog.add('SONG', ('%s: exact timer from buff bar (%s left)'):format(e.def.name, fmt_time(left)), true)
                        end
                    elseif tm.mode == 'absolute' then
                        cfg.raw_cal_ok = false   -- clock looks wrong: relearn it
                        dlog.add('INFO', 'Buff clock looked wrong - relearning (estimates for now)', true)
                        return
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------------------
-- Keep songs across reloads: save to a small file whenever they change,
-- restore still-running ones on load.
----------------------------------------------------------------------------
local song_file_dir = nil
local function song_file()
    local ok, name = pcall(function () return party():GetMemberName(0) end)
    if not ok or name == nil or name == '' then return nil end
    local base = AshitaCore:GetInstallPath()
    if song_file_dir == nil then
        local mk = ashita.fs.create_directory or ashita.fs.create_dir
        if mk then
            pcall(mk, base .. '\\config')
            pcall(mk, base .. '\\config\\addons')
            pcall(mk, base .. '\\config\\addons\\6arab')
        end
        song_file_dir = base .. '\\config\\addons\\6arab'
    end
    return ('%s\\songs_%s.txt'):format(song_file_dir, name)
end

local last_sig, last_save_check = nil, 0
local function save_songs(force)
    if state.testing then return end
    local now = os.time()
    if not force and now == last_save_check then return end
    last_save_check = now
    local lines = {}
    for _, e in ipairs(state.active) do
        lines[#lines + 1] = table.concat({
            e.spell, e.def.name, e.started, e.dur, e.buff or 0, e.tcount or 0, e.hit_me and 1 or 0,
            e.enemy_id or 0, (e.enemy_name or ''):gsub('|', ''), e.done_at or 0, e.why or '', e.group or '',
        }, '|')
    end
    local s = table.concat(lines, '\n')
    if not force and s == last_sig then return end
    local path = song_file()
    if path == nil then return end
    local f = io.open(path, 'w')
    if f == nil then dlog.add('ERR', 'Could not save songs to ' .. path) return end
    f:write(s)
    f:close()
    last_sig = s
    dlog.add('INFO', ('Saved %d song(s)'):format(#lines), true)
end

local function split(str, sep)
    local out = {}
    for part in (str .. sep):gmatch('(.-)' .. sep:gsub('%p', '%%%0')) do out[#out + 1] = part end
    return out
end

local restored = false
local function restore_songs()
    if restored or state.testing then return end
    if my_id() == 0 then return end
    restored = true
    local path = song_file()
    local f = path and io.open(path, 'r')
    if not f then return end
    local now, count = os.time(), 0
    for line in f:lines() do
        local p = split(line, '|')
        local spell, name = tonumber(p[1] or ''), p[2]
        local started, dur = tonumber(p[3] or ''), tonumber(p[4] or '')
        local done_at = tonumber(p[10] or '') or 0
        if spell and name and name ~= '' and started and dur then
            local gone = (done_at > 0 and now - done_at >= cfg.fade_s) or (done_at == 0 and now >= started + dur + cfg.fade_s)
            if not gone then
                local def = songs.def(name)
                local eid = tonumber(p[8] or '') or 0
                local grp = def.enemy and 'ENEMY' or ((p[12] == 'MELEE' or p[12] == 'MAGES') and p[12] or classify(nil, def))
                table.insert(state.active, {
                    id = state.next_id, spell = spell, def = def, group = grp,
                    key = def.enemy and ('%d:%d'):format(spell, eid) or ('%d:%s'):format(spell, grp),
                    started = started, dur = dur, ends = started + dur,
                    buff = tonumber(p[5] or '') or 0, tcount = tonumber(p[6] or '') or 0, hit_me = p[7] == '1',
                    enemy_id = (eid > 0) and eid or nil, enemy_name = (p[9] ~= '') and p[9] or nil,
                    done_at = (done_at > 0) and done_at or nil, why = (p[11] ~= '') and p[11] or nil,
                })
                state.next_id = state.next_id + 1
                count = count + 1
            end
        end
    end
    f:close()
    if count > 0 then dlog.add('SONG', ('Restored %d song(s) from last session'):format(count)) end
    last_sig = nil
end

local was_active = nil
local function tick()
    local ts = os.time()
    if ts ~= sec_now then sec_now, sec_clock = ts, os.clock() end
    local now = os.time()
    job_update(now)
    local active = brd_active()
    -- off for a full minute (real job change) -> drop the songs
    if not active and not state.testing and #state.active > 0 and job.off_at and now - job.off_at >= 60 then
        state.active = {}
        dlog.add('INFO', 'Off BRD for a minute - songs cleared')
    end
    if not active and not state.testing then return end
    if not state.testing then
        restore_songs()
        verify_buffs(now)
        exact_timers(now)
        save_songs(false)
    end
    if not cfg.track_enemy then
        local n = 0
        for i = #state.active, 1, -1 do
            if state.active[i].group == 'ENEMY' then table.remove(state.active, i); n = n + 1 end
        end
        if n > 0 then dlog.add('GONE', ('%d enemy song(s) cleared (enemy songs off)'):format(n)) end
    end
    for i = #state.active, 1, -1 do
        local e = state.active[i]
        if e.done_at == nil and now >= e.ends then
            e.done_at, e.why = e.ends, 'DONE'
            dlog.add('GONE', ('%s finished -> fading out over %ds'):format(e.def.name, cfg.fade_s))
        end
        if e.done_at ~= nil and (now - e.done_at >= cfg.fade_s + 1 or (e.fade_t0 and anim_time() - e.fade_t0 >= math.max(0.5, tonumber(cfg.fade_s) or 4))) then
            dlog.add('GONE', ('%s removed'):format(e.def.name), true)
            table.remove(state.active, i)
        end
    end
    if not state.testing and i_am_dead() then
        for _, e in ipairs(state.active) do
            if e.group ~= 'ENEMY' and e.done_at == nil then mark_done(e, 'KO') end
        end
    end
end

----------------------------------------------------------------------------
-- test presets
----------------------------------------------------------------------------
local test_presets = {
    function (now)
        return {
            { n = 'Valor Minuet IV',  dur = 120, left = 85 },
            { n = 'Advancing March',  dur = 120, left = 100, g = 'MAGES' },
            { n = 'Advancing March',  dur = 120, left = 12 },
            { n = "Mage's Ballad II", dur = 120, done = 0, why = 'DONE' },
            { n = "Mage's Ballad",    dur = 120, left = 60 },
            { n = 'Carnage Elegy',    dur = 180, left = 150, enemy = 'Goblin Pathfinder', rc = 14 },
            { n = 'Foe Requiem VI',   dur = 143, left = 70, enemy = 'Goblin Pathfinder' },
        }
    end,
    function (now)
        return {
            { n = 'Valor Minuet IV',  dur = 120, left = 118, pop = true, from = 0.15, rc = 18 },
            { n = 'Valor Minuet III', dur = 120, left = 64 },
            { n = 'Foe Lullaby',      dur = 30,  left = 21, enemy = 'Orcish Fighter' },
        }
    end,
    function (now)
        return {
            { n = 'Sword Madrigal',   dur = 120, done = 2, why = 'OVERWRITTEN' },
            { n = 'Victory March',    dur = 120, left = 110 },
            { n = 'Advancing March',  dur = 120, left = 95 },
            { n = 'Battlefield Elegy', dur = 120, done = 0, why = 'DEFEATED', enemy = 'Yagudo Priest' },
        }
    end,
}

local function test_songs()
    state.test_i = (state.test_i % #test_presets) + 1
    local now = os.time()
    state.active = {}
    for _, p in ipairs(test_presets[state.test_i](now)) do
        local def = songs.def(p.n)
        local started = p.done and (now - p.dur - p.done) or (now - (p.dur - p.left))
        local e = {
            id = state.next_id, key = 'test:' .. p.n, spell = 0, def = def,
            group = p.enemy and 'ENEMY' or (p.g or classify(nil, def)),
            started = started, dur = p.dur, ends = started + p.dur, tcount = 5, hit_me = true,
            enemy_name = p.enemy, pop_pending = p.pop, fill_from = p.from or 0,
            test_rc_end = p.rc and (now + p.rc) or nil,
        }
        if p.done then e.done_at, e.why, e.ends = now - p.done, p.why, math.min(e.ends, now - p.done) end
        state.next_id = state.next_id + 1
        if not (p.done and p.why ~= 'DONE' and not cfg.grey_early) then table.insert(state.active, e) end
    end
    state.testing = true
    for i, a in ipairs(ABILITIES) do a.test_rem = ({ 2400, 0, 95, 0 })[i] end
    dlog.add('CMD', ('Test preset %d loaded'):format(state.test_i))
end

----------------------------------------------------------------------------
-- drawing helpers (nard style)
----------------------------------------------------------------------------
local function col32(c) return imgui.GetColorU32(c) end

local function A(c, k)
    return { c[1], c[2], c[3], (c[4] or 1) * k }
end

local function mix(a, b, k)
    return { a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k, a[3] + (b[3] - a[3]) * k, 1 }
end

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
        local oc = col32({ 0, 0, 0, 0.90 * (col[4] or 1) })
        dl_text(dl, sx + 1, sy + 1, oc, txt, size)
        dl_text(dl, sx - 1, sy + 1, oc, txt, size)
        dl_text(dl, sx + 1, sy - 1, oc, txt, size)
        dl_text(dl, sx - 1, sy - 1, oc, txt, size)
    end
    dl_text(dl, sx, sy, col32(col), txt, size)
end

-- eighth note: head, stem, flag  (x, y = top-left of a box of size s)
local function draw_note(dl, x, y, s, col)
    local hx, hy = x + s * 0.38, y + s * 0.72
    local stem   = hx + s * 0.13
    local top    = y + s * 0.14
    local th     = math.max(1.4, s * 0.085)
    dl:AddCircleFilled({ hx, hy }, s * 0.17, col, 16)
    dl:AddLine({ stem, hy }, { stem, top }, col, th)
    dl:AddLine({ stem, top }, { stem + s * 0.26, top + s * 0.17 }, col, th)
    dl:AddLine({ stem + s * 0.26, top + s * 0.17 }, { stem + s * 0.20, top + s * 0.36 }, col, th)
end

-- Small round icon button: 'min', 'max', 'close', 'help', 'gear', 'bug'
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
        for k = -1, 1 do
            local ly = by + k * r * 0.20
            dl:AddLine({ cx - r * 0.22, ly }, { cx - r * 0.56, ly + k * r * 0.14 }, gc, 1.1)
            dl:AddLine({ cx + r * 0.22, ly }, { cx + r * 0.56, ly + k * r * 0.14 }, gc, 1.1)
        end
        dl:AddLine({ cx - r * 0.08, cy - r * 0.36 }, { cx - r * 0.26, cy - r * 0.58 }, gc, 1.1)
        dl:AddLine({ cx + r * 0.08, cy - r * 0.36 }, { cx + r * 0.26, cy - r * 0.58 }, gc, 1.1)
        dl:AddCircleFilled({ cx, cy - r * 0.26 }, r * 0.17, gc, 12)
        dl:AddCircleFilled({ cx, by }, r * 0.30, gc, 14)
        dl:AddLine({ cx, by - r * 0.26 }, { cx, by + r * 0.28 },
            col32(hovered and { 0.30, 0.24, 0.12, 1 } or { 0.05, 0.06, 0.09, 1 }), 1.0)
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

local function pill(dl, wx, wy, x, y, w, h, bg, bd)
    dl:AddRectFilled({ wx + x, wy + y }, { wx + x + w, wy + y + h }, col32(bg), h / 2)
    dl:AddRect({ wx + x, wy + y }, { wx + x + w, wy + y + h }, col32(bd), h / 2, ROUND_ALL, 1.0)
end

----------------------------------------------------------------------------
-- overlay
----------------------------------------------------------------------------
local OVERLAY_HELP = table.concat({
    '6arab - floating Bard songs',
    'Drag the empty area to move (unless locked).',
    '',
    'Each song: name, note tile, effect, timer.',
    'Amber pulse = ending soon.',
    'Grey = finished / wore off / overwritten.',
    'It flashes grey, then fades out fast.',
    'Small pill under a song = its recast.',
    'Faint dashed tile = a song from your set that is not up.',
    'Top pills: Soul Voice / Pianissimo / Nightingale / Troubadour.',
    'Top row: melee songs.  Under it: mage songs.',
    'Enemy debuffs / sleep: bars on the side.',
    '',
    '/6arab          settings',
    '/6arab test     preview songs',
    '/6arab min      minimize',
    '/6arab lock     lock position',
    '/6arab scale n  size',
    '/6arab log      debug log',
    '',
    'Durations are base (Lv75) + your bonus setting.',
}, '\n')

local function song_state(e, now)
    if e.done_at then return 'done' end
    if e.ends - now <= ENDING_AT then return 'ending' end
    return 'active'
end

-- Finished songs: quick grey flash, then fade straight out across the linger time.
local function fade_of(e, now, t)
    if not e.done_at then return 1 end
    local span = math.max(0.5, tonumber(cfg.fade_s) or 4)
    e.fade_t0 = e.fade_t0 or t            -- smooth clock from the moment it went grey
    local k = (t - e.fade_t0) / span
    if k <= 0.15 then return 1 end
    return math.max(0, 1 - ((k - 0.15) / 0.85) ^ 0.7)
end

local function layout(S)
    local m = { S = S }
    local si, sn, sf = sz('s_icon'), sz('s_name'), sz('s_info')
    m.TS     = 42 * S * si
    m.colW   = math.max(m.TS * 1.6 + 30 * S, 104 * S * math.max(sn, sf))
    m.nscale = 0.80 * S * sn; m._d, m.nh = text_size('A', m.nscale)
    m.escale = 0.92 * S * sf; m._d, m.eh = text_size('A', m.escale)
    m.tscale = 0.74 * S * sf; m.tw, m.th = text_size('0:00', m.tscale)
    m.cscale = 0.60 * S * si; m._d, m.ch = text_size('A', m.cscale)
    m.dscale = 0.70 * S * sf; m._d, m.dh = text_size('A', m.dscale)
    m.fx     = 18 * S * si    -- room above the tile for the floating notes
    m.chipH  = 12 * S * si    -- room below the tile for the status chip
    m.barH   = 5 * S * sf
    m.pillH  = m.dh + 5 * S
    m.padTop = 12 * S
    m.padBot = 9 * S
    return m
end

local function row_height(m, has_pill)
    local S = m.S
    local h = m.padTop + m.nh + m.fx + m.TS + m.chipH + (m.eh + m.th + 15 * S) + m.padBot
    if has_pill then h = h + 6 * S + m.pillH end
    return h
end

local function shows_recast(e)
    return not e.ghost and cfg.show_recast and e.done_at == nil and rc_of(e) > 0
end

local function song_tooltip(e, now)
    imgui.BeginTooltip()
    imgui.TextColored(e.def.col, e.def.name)
    imgui.TextColored(C.cream, e.def.eff)
    imgui.Separator()
    if e.group == 'ENEMY' then
        imgui.TextColored(C.steel, 'On: ' .. (e.enemy_name or 'target'))
    else
        imgui.TextColored(C.steel, ('Landed on %d member%s%s'):format(e.tcount or 0, (e.tcount == 1) and '' or 's',
            e.hit_me and ' (incl. you)' or ''))
    end
    imgui.TextColored(C.steel, 'Duration ' .. fmt_time(e.dur))
    if e.done_at then
        imgui.TextColored(C.grey, 'Ended: ' .. (e.why or 'DONE'):lower())
        imgui.TextColored(C.grey, ('Disappears in %ds'):format(math.max(0, cfg.fade_s - (now - e.done_at))))
    else
        imgui.TextColored(C.green, 'Time left ' .. fmt_time(e.ends - now))
    end
    local rc = rc_of(e)
    imgui.TextColored(rc > 0 and C.gold or C.dim, rc > 0 and ('Recast %ds'):format(math.ceil(rc)) or 'Recast ready')
    imgui.TextColored(C.dim, e.exact and 'Timer read from your buff bar.' or 'Timer estimated (base Lv75 + bonus).')
    imgui.EndTooltip()
end

local POP_TIME = 0.9

-- clip support differs between builds; test once
local clip_ok = nil
local function with_clip(dl, x1, y1, x2, y2, fn)
    if clip_ok ~= false then
        local ok = pcall(function () dl:PushClipRect({ x1, y1 }, { x2, y2 }, true) end)
        if ok then
            clip_ok = true
            local ok2, err = pcall(fn)
            dl:PopClipRect()
            if not ok2 then error(err) end
            return true
        end
        clip_ok = false
        dlog.add('INFO', 'Clip rects not supported - using simple note colour', true)
    end
    return false
end

-- How full a tile is (1 = just sung, 0 = finished), with the refill animation.
local function fill_of(e, t)
    if e.done_at then return 0 end
    local target = math.max(0, math.min(1, (e.ends - now_f()) / e.dur))
    if e.fill_at then
        local k = (t - e.fill_at) / REFILL_TIME
        if k >= 1 then e.fill_at = nil
        else
            k = 1 - (1 - k) ^ 3
            return (e.fill_from or 0) + (target - (e.fill_from or 0)) * k
        end
    end
    return target
end

-- The tile is the timer: song colour fills it and drains down as time runs out.
local function draw_tile(dl, e, st, sx, sy, TS, t, S, k, frac)
    local rr = 9 * S
    local c  = e.def.col
    local done = (st == 'done')
    local border = done and { 0.48, 0.49, 0.53, 1 } or { c[1], c[2], c[3], 1 }

    if not done then
        -- breathing glow in the song colour (amber pulse when ending)
        local pulse = 0.5 + 0.5 * math.sin(t * ((st == 'ending') and 7 or 2.2) + e.id)
        local gc = (st == 'ending') and { 1.0, 0.70, 0.22 } or c
        local ga = ((st == 'ending') and (0.07 + 0.07 * pulse) or (0.03 + 0.03 * pulse)) * (0.4 + 0.6 * frac)
        for g = 3, 1, -1 do
            local d = g * 3.5 * S
            dl:AddRectFilled({ sx - d, sy - d }, { sx + TS + d, sy + TS + d }, col32({ gc[1], gc[2], gc[3], ga * (4 - g) * k }), rr + d)
        end
        if st == 'ending' then border = mix(border, { 1.0, 0.70, 0.22 }, pulse) end
    end

    for g, a in ipairs({ 0.30, 0.16, 0.08 }) do   -- soft layered shadow
        local d = g * 1.5 * S
        dl:AddRectFilled({ sx - d * 0.3, sy + d }, { sx + TS + d * 0.3, sy + TS + d + d * 0.3 }, col32({ 0, 0, 0, a * k }), rr + d * 0.3)
    end

    -- empty glass
    local empty = done and { 0.22, 0.23, 0.25, 1 } or mix(c, { 0.04, 0.05, 0.07 }, 0.82)
    dl:AddRectFilled({ sx, sy }, { sx + TS, sy + TS }, col32(A(empty, k)), rr)

    -- liquid: song colour from the bottom up to the current level
    local level = sy + TS * (1 - frac)
    if frac > 0.001 then
        local body = mix(c, { 1, 1, 1 }, 0.30)
        local deep = mix(c, { 0, 0, 0 }, 0.15)
        dl:AddRectFilled({ sx, level }, { sx + TS, sy + TS }, col32(A(deep, k)), rr, (frac > 0.97) and ROUND_ALL or ROUND_BOT)
        if TS * frac > 5 * S then
            dl:AddRectFilled({ sx + 2 * S, level + 1 }, { sx + TS * 0.55, sy + TS - 2 * S }, col32(A(body, 0.45 * k)), rr * 0.6, ROUND_BOT)
        end
        -- wavy surface
        if frac < 0.995 then
            local amp = math.min(1.6 * S, TS * frac * 0.5)
            local seg = 8
            local px, py = nil, nil
            for i = 0, seg do
                local x = sx + 3 * S + (TS - 6 * S) * i / seg
                local y = level + math.sin(t * 4 + i * 0.9 + e.id) * amp
                if px then dl:AddLine({ px, py }, { x, y }, col32({ 1, 1, 1, 0.75 * k }), 1.4 * S) end
                px, py = x, y
            end
        end
    end
    -- glass shine
    dl:AddRectFilled({ sx + 3 * S, sy + 3 * S }, { sx + TS - 3 * S, sy + TS * 0.30 }, col32({ 1, 1, 1, 0.07 * k }), rr * 0.7)

    -- note: light over the empty part, dark over the liquid
    local nx, ny, ns = sx + TS * 0.14, sy + TS * 0.06, TS * 0.74
    local light = done and { 0.62, 0.63, 0.67, 1 } or mix(c, { 1, 1, 1 }, 0.55)
    local dark  = mix(c, { 0, 0, 0 }, 0.62)
    local clipped = false
    if not done then
        clipped = with_clip(dl, sx, sy, sx + TS, level + 0.5, function ()
            draw_note(dl, nx, ny, ns, col32(A(light, 0.85 * k)))
        end)
        if clipped then
            with_clip(dl, sx, level, sx + TS, sy + TS, function ()
                draw_note(dl, nx, ny, ns, col32(A(dark, k)))
            end)
        end
    end
    if not clipped then
        draw_note(dl, nx + 1, ny + 1, ns, col32({ 0, 0, 0, 0.55 * k }))
        draw_note(dl, nx, ny, ns, col32(A(done and light or mix(c, { 1, 1, 1 }, 0.75), k)))
    end

    dl:AddRect({ sx, sy }, { sx + TS, sy + TS }, col32(A(border, k)), rr, ROUND_ALL, 1.8 * S)
end

-- little notes drifting up above a live tile
local function draw_drift(dl, e, sx, sy, TS, t, S)
    local c = e.def.col
    for n = 0, 1 do
        local ph = (t * 0.55 + n * 0.5 + e.id * 0.37) % 1
        local x  = sx + TS * (0.22 + 0.46 * n) + math.sin(t * 2.1 + n * 2 + e.id) * TS * 0.07
        local y  = sy - 3 * S - ph * TS * 0.42
        local a  = (ph < 0.15) and (ph / 0.15) or (1 - ph)
        draw_note(dl, x, y - TS * 0.26, TS * 0.26, col32({ c[1], c[2], c[3], 0.85 * a }))
    end
end

local function draw_pop(dl, cx, cy, TS, dt, S, c)
    if dt < 0 or dt > POP_TIME then return end
    local k = dt / POP_TIME
    for i = 0, 1 do
        local rad = TS * (0.55 + k * (0.9 + i * 0.35))
        dl:AddCircle({ cx, cy }, rad, col32({ c[1], c[2], c[3], (1 - k) * (0.7 - i * 0.3) }), 40, (4 - i * 1.5) * S * (1 - k) + 1)
    end
end

----------------------------------------------------------------------------
-- Your usual song set: songs from the set that are not up show as ghost tiles
----------------------------------------------------------------------------
local DEMO_SET = { MELEE = { 'Valor Minuet IV', 'Advancing March', 'Sword Madrigal' }, MAGES = { "Mage's Ballad II", "Mage's Ballad" } }

local function add_ghosts(rows)
    if not cfg.show_set then return rows end
    for _, g in ipairs({ { 'MELEE', cfg.set_melee }, { 'MAGES', cfg.set_mages } }) do
        local label, set = g[1], g[2] or {}
        local any = false
        for _, n in ipairs(set) do if n ~= nil and n ~= '' then any = true end end
        if not any and state.testing then set = DEMO_SET[label] end
        local row = nil
        for _, r in ipairs(rows) do if r.label == label then row = r end end
        for i, name in ipairs(set) do
            if name ~= nil and name ~= '' then
                local have = false
                for _, e in ipairs(row and row.items or {}) do
                    if not e.ghost and e.def.name == name and e.done_at == nil then have = true end
                end
                if not have then
                    if row == nil then row = { label = label, items = {} }; table.insert(rows, row) end
                    table.insert(row.items, { ghost = true, id = 'g' .. label .. i, def = songs.def(name), group = label, spell = songs.id_of(name) })
                end
            end
        end
    end
    table.sort(rows, function (a, b) return (ROW_ORDER[a.label] or 9) < (ROW_ORDER[b.label] or 9) end)
    return rows
end

local function draw_ghost(e, m, cx, top, dl, wx, wy, t, now)
    local S, colW, TS = m.S, m.colW, m.TS
    local mid  = cx + colW / 2
    local c    = e.def.col
    local tint = ROW_TINT[e.group] or ROW_TINT.MELEE
    local br   = 0.75 + 0.25 * math.sin(t * 2 + #e.id)

    local y    = top + m.padTop
    local name = e.def.short
    local nw   = text_size(name, m.nscale)
    local rw, rh = nw + 22 * S, m.nh + 5 * S
    local rx, ry = mid - rw / 2, y - 2.5 * S
    pill(dl, wx, wy, rx, ry, rw, rh, { 0.05, 0.06, 0.09, 0.55 }, { tint[1], tint[2], tint[3], 0.30 })
    text_at(rx + 13 * S, y, { 0.70, 0.72, 0.78, 0.75 }, name, m.nscale, false)
    y = y + m.nh + m.fx

    -- ghost tile: faint glass, dashed song-colour outline, faint note
    local tx = mid - TS / 2
    local sx, sy = wx + tx, wy + y
    local rr = 9 * S
    dl:AddRectFilled({ sx, sy }, { sx + TS, sy + TS }, col32({ 0.05, 0.06, 0.09, 0.45 }), rr)
    local dash, gap = 5 * S, 4 * S
    local col = col32({ c[1], c[2], c[3], 0.55 * br })
    local edges = { { sx + rr, sy, sx + TS - rr, sy }, { sx + rr, sy + TS, sx + TS - rr, sy + TS },
                    { sx, sy + rr, sx, sy + TS - rr }, { sx + TS, sy + rr, sx + TS, sy + TS - rr } }
    for _, ed in ipairs(edges) do
        local len = math.max(math.abs(ed[3] - ed[1]), math.abs(ed[4] - ed[2]))
        local p = 0
        while p < len do
            local q = math.min(len, p + dash)
            local f1, f2 = p / len, q / len
            dl:AddLine({ ed[1] + (ed[3] - ed[1]) * f1, ed[2] + (ed[4] - ed[2]) * f1 },
                       { ed[1] + (ed[3] - ed[1]) * f2, ed[2] + (ed[4] - ed[2]) * f2 }, col, 1.4 * S)
            p = q + gap
        end
    end
    for _, cr in ipairs({ { sx + rr, sy + rr, math.pi, 1.5 * math.pi }, { sx + TS - rr, sy + rr, 1.5 * math.pi, 2 * math.pi },
                          { sx + TS - rr, sy + TS - rr, 0, 0.5 * math.pi }, { sx + rr, sy + TS - rr, 0.5 * math.pi, math.pi } }) do
        local a1, a2 = cr[3], cr[4]
        local mida = (a1 + a2) / 2
        dl:AddLine({ cr[1] + math.cos(a1) * rr, cr[2] + math.sin(a1) * rr }, { cr[1] + math.cos(mida) * rr, cr[2] + math.sin(mida) * rr }, col, 1.4 * S)
        dl:AddLine({ cr[1] + math.cos(mida) * rr, cr[2] + math.sin(mida) * rr }, { cr[1] + math.cos(a2) * rr, cr[2] + math.sin(a2) * rr }, col, 1.4 * S)
    end
    draw_note(dl, sx + TS * 0.14, sy + TS * 0.06, TS * 0.74, col32({ c[1], c[2], c[3], 0.28 * br }))

    -- chip: MISSING
    local chip = 'NOT UP'
    local cw = text_size(chip, m.cscale)
    local w, h = cw + 12 * S, m.ch + 4 * S
    local px, py = mid - w / 2, y + TS - h / 2 + 1 * S
    pill(dl, wx, wy, px, py, w, h, { 0.12, 0.13, 0.16, 0.92 }, { c[1], c[2], c[3], 0.55 })
    text_at(px + 6 * S, py + 2 * S, { 0.85, 0.86, 0.90, 1 }, chip, m.cscale, false)

    local rc = spell_recast(e.spell)
    if m.hover then
        local qr = 5.5 * S
        imgui.SetCursorPos({ tx - qr - 1 * S, y - qr - 1 * S })
        local _, qhov = round_button('##' .. e.id, 'help', qr)
        if qhov then
            tooltip_text(('%s is not up\nIn your %s song set\n%s'):format(e.def.name, e.group,
                (rc > 0) and ('Recast ' .. math.ceil(rc) .. 's') or 'Ready to sing'))
        end
    end
    y = y + TS + m.chipH

    -- plate: effect + READY / recast
    local plx, plw = cx + 6 * S, colW - 12 * S
    local plh = m.eh + m.th + 15 * S
    dl:AddRectFilled({ wx + plx, wy + y }, { wx + plx + plw, wy + y + plh }, col32({ 0.05, 0.06, 0.09, 0.55 }), 7 * S)
    dl:AddRect({ wx + plx, wy + y }, { wx + plx + plw, wy + y + plh }, col32({ tint[1], tint[2], tint[3], 0.20 }), 7 * S, ROUND_ALL, 1.0)
    local ew = text_size(e.def.eff, m.escale)
    text_at(mid - ew / 2, y + 5 * S, { c[1], c[2], c[3], 0.55 }, e.def.eff, m.escale, false)
    local rt = (rc > 0) and ('RECAST %ds'):format(math.ceil(rc)) or 'SING'
    local rtw = text_size(rt, m.tscale)
    text_at(mid - rtw / 2, y + 10 * S + m.eh, (rc > 0) and { 1.0, 0.80, 0.42, 1 } or { C.green[1], C.green[2], C.green[3], br }, rt, m.tscale, false)
end

local function draw_column(e, m, cx, top, dl, wx, wy, t, now)
    if e.ghost then return draw_ghost(e, m, cx, top, dl, wx, wy, t, now) end
    local S, colW, TS = m.S, m.colW, m.TS
    local st  = song_state(e, now)
    local k   = fade_of(e, now, t)
    local mid = cx + colW / 2
    local done = (st == 'done')
    local tint = ROW_TINT[e.group] or ROW_TINT.MELEE

    -- name ribbon
    local y    = top + m.padTop
    local name = e.def.short
    local nw   = text_size(name, m.nscale)
    local rw, rh = nw + 22 * S, m.nh + 5 * S
    local rx, ry = mid - rw / 2, y - 2.5 * S
    local dotc = done and C.grey or e.def.col
    pill(dl, wx, wy, rx, ry, rw, rh, { 0.05, 0.06, 0.09, 0.88 * k }, { tint[1], tint[2], tint[3], (done and 0.35 or 0.80) * k })
    dl:AddCircleFilled({ wx + rx + 7 * S, wy + ry + rh / 2 }, 1.9 * S, col32(A(dotc, k)), 10)
    text_at(rx + 13 * S, y, A(done and C.grey or C.cream, k), name, m.nscale, false)
    y = y + m.nh + m.fx

    -- tile
    local tx = mid - TS / 2
    local sx, sy = wx + tx, wy + y
    if e.pop_pending then e.pop_at = t; e.fill_at = t; e.pop_pending = nil end
    local dt = e.pop_at and (t - e.pop_at) or 99
    if dt > POP_TIME then e.pop_at = nil; dt = 99 end
    local pop = (dt < 0.45) and (1 + 0.22 * math.sin(math.min(1, dt / 0.45) * math.pi) * math.exp(-dt * 2)) or 1
    local TSd = TS * pop
    local dsx, dsy = sx + (TS - TSd) / 2, sy + (TS - TSd) / 2
    if not done then draw_drift(dl, e, sx, sy, TS, t, S) end
    draw_pop(dl, sx + TS / 2, sy + TS / 2, TS, dt, S, e.def.col)
    draw_tile(dl, e, st, dsx, dsy, TSd, t, S, k, fill_of(e, t))
    if dt < 0.22 then
        dl:AddRectFilled({ dsx, dsy }, { dsx + TSd, dsy + TSd }, col32({ 1, 1, 1, 0.8 * (1 - dt / 0.22) }), 9 * S)
    end
    if e.group == 'ENEMY' then   -- red corner = enemy song
        dl:AddTriangleFilled({ sx + TS - 11 * S, sy + 1 }, { sx + TS - 1, sy + 1 }, { sx + TS - 1, sy + 11 * S },
            col32(A(done and C.grey or C.red, k)))
    end

    -- status chip straddling the tile's bottom edge
    local chip, cbg, cfg_, cbd
    if done then
        chip, cbg, cfg_, cbd = (e.why or 'DONE'), { 0.16, 0.17, 0.19, 0.96 }, { 0.80, 0.81, 0.85, 1 }, { 0.50, 0.51, 0.55, 1 }
    elseif st == 'ending' then
        chip, cbg, cfg_, cbd = 'ENDING', { 0.36, 0.22, 0.04, 0.96 }, { 1.00, 0.86, 0.50, 1 }, { 1.00, 0.66, 0.20, 1 }
    end
    if chip then
        local cw = text_size(chip, m.cscale)
        local w, h = cw + 12 * S, m.ch + 4 * S
        local px, py = mid - w / 2, y + TS - h / 2 + 1 * S
        pill(dl, wx, wy, px, py, w, h, A(cbg, k), A(cbd, k))
        text_at(px + 6 * S, py + 2 * S, A(cfg_, k), chip, m.cscale, false)
    end

    -- "?" marker on the tile corner (while hovering the overlay)
    if m.hover then
        local qr = 5.5 * S
        imgui.SetCursorPos({ tx - qr - 1 * S, y - qr - 1 * S })
        local _, qhov = round_button('##sq' .. e.id, 'help', qr)
        if qhov then song_tooltip(e, now) end
    end
    y = y + TS + m.chipH

    -- info plate: effect on top, timer bar + time below
    local plx, plw = cx + 6 * S, colW - 12 * S
    local plh = m.eh + m.th + 15 * S
    local pbd = done and C.grey or { tint[1], tint[2], tint[3], 1 }
    dl:AddRectFilled({ wx + plx, wy + y }, { wx + plx + plw, wy + y + plh }, col32({ 0.05, 0.06, 0.09, 0.84 * k }), 7 * S)
    dl:AddRect({ wx + plx, wy + y }, { wx + plx + plw, wy + y + plh }, col32({ pbd[1], pbd[2], pbd[3], 0.40 * k }), 7 * S, ROUND_ALL, 1.0)

    local etxt = e.def.eff
    if e.group ~= 'ENEMY' and (e.tcount or 0) > 0 then etxt = ('%s  x%d'):format(etxt, e.tcount) end
    local ew = text_size(etxt, m.escale)
    text_at(mid - ew / 2, y + 5 * S, A(done and C.grey or e.def.col, k), etxt, m.escale, false)
    y = y + 5 * S + m.eh + 5 * S

    local frac, bc, tstr
    if done then
        local left = math.max(0, cfg.fade_s - (now - e.done_at))
        frac = (cfg.fade_s > 0) and (left / cfg.fade_s) or 0
        bc   = { 0.45, 0.46, 0.50, 1 }
        tstr = ('-%ds'):format(math.ceil(left))
    else
        local left = e.ends - now
        frac = math.max(0, math.min(1, left / e.dur))
        bc   = { 0.36, 0.80, 0.52, 1 }
        if left <= ENDING_AT then bc = { 0.94, 0.62, 0.22, 1 } elseif frac < 0.30 then bc = { 0.94, 0.80, 0.30, 1 } end
        tstr = fmt_time(left)
    end
    local bx0 = plx + 8 * S
    local bw  = plw - 16 * S - m.tw - 6 * S
    local by0 = y + (m.th - m.barH) / 2
    dl:AddRectFilled({ wx + bx0 - 1, wy + by0 - 1 }, { wx + bx0 + bw + 1, wy + by0 + m.barH + 1 }, col32({ 0, 0, 0, 0.75 * k }), m.barH / 2 + 1)
    dl:AddRectFilled({ wx + bx0, wy + by0 }, { wx + bx0 + bw, wy + by0 + m.barH }, col32({ 0.12, 0.13, 0.16, 0.85 * k }), m.barH / 2)
    if frac > 0 then
        dl:AddRectFilled({ wx + bx0, wy + by0 }, { wx + bx0 + math.max(m.barH, bw * frac), wy + by0 + m.barH }, col32(A(bc, k)), m.barH / 2)
    end
    text_at(bx0 + bw + 6 * S, y, A(done and C.grey or ((st == 'ending') and bc or C.steel), k), tstr, m.tscale, false)
    y = y + m.th + 5 * S

    -- recast pill
    if shows_recast(e) then
        y = y + 6 * S
        local t1 = 'RECAST'
        local t2 = ('%ds'):format(math.ceil(rc_of(e)))
        local w1 = text_size(t1, m.dscale)
        local w2 = text_size(t2, m.dscale)
        local w  = w1 + w2 + 30 * S
        local px = mid - w / 2
        pill(dl, wx, wy, px, y, w, m.pillH, { 0.30, 0.20, 0.04, 0.92 }, { 1.0, 0.68, 0.25, 0.9 })
        text_at(px + 9 * S, y + 2.5 * S, { 1.0, 0.80, 0.42, 1 }, t1, m.dscale, false)
        dl:AddCircleFilled({ wx + px + 9 * S + w1 + 6 * S, wy + y + m.pillH / 2 }, 1.5 * S, col32(C.dim), 8)
        text_at(px + 21 * S + w1, y + 2.5 * S, C.steel, t2, m.dscale, false)
    end
end

-- Party row then enemy row, oldest first in each row.
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

local function draw_row(dl, wx, wy, bx, y, W, row, m, t, now, hovered)
    local S = m.S
    local tint = ROW_TINT[row.label] or ROW_TINT.MELEE
    local has_pill = false
    for _, e in ipairs(row.items) do if shows_recast(e) then has_pill = true end end
    local rh = row_height(m, has_pill)
    local x0, y0, x1, y1 = wx + bx, wy + y, wx + bx + W, wy + y + rh

    if cfg.panel then
        dl:AddRectFilled({ x0, y0 }, { x1, y1 }, col32({ 0.05, 0.06, 0.09, 0.80 }), 12 * S)
        dl:AddRectFilled({ x0 + 1, y0 + 1 }, { x1 - 1, y0 + rh * 0.42 }, col32({ 1, 1, 1, 0.03 }), 11 * S)
        dl:AddRect({ x0, y0 }, { x1, y1 }, col32({ tint[1], tint[2], tint[3], 0.45 }), 12 * S, ROUND_ALL, 1.0)
        for i = 2, #row.items do
            local lx = x0 + 4 * S + (i - 1) * m.colW
            dl:AddLine({ lx, y0 + 14 * S }, { lx, y1 - 12 * S }, col32({ 1, 1, 1, 0.07 }), 1.0)
        end
    end

    for i, e in ipairs(row.items) do
        draw_column(e, m, bx + 4 * S + (i - 1) * m.colW, y, dl, wx, wy, t, now)
    end

    if cfg.row_labels and not row.nolabel and (cfg.panel or hovered) then
        local ls = 0.66 * S
        local label = row.label
        local lw, lh = text_size(label, ls)
        local tw, th = lw + 18 * S, lh + 4 * S
        local tx, ty = bx + 12 * S, y - th / 2
        if cfg.panel then
            pill(dl, wx, wy, tx, ty, tw, th, { 0.06, 0.07, 0.10, 1 }, { tint[1], tint[2], tint[3], 0.75 })
        else
            local lx = wx + tx + 14 * S + lw
            local ly = wy + ty + th / 2
            dl:AddLine({ lx, ly }, { wx + bx + W - 6 * S, ly }, col32({ tint[1], tint[2], tint[3], 0.22 }), 1.0)
        end
        dl:AddCircleFilled({ wx + tx + 6 * S, wy + ty + th / 2 }, 2.2 * S, col32({ 0, 0, 0, 0.9 }), 10)
        dl:AddCircleFilled({ wx + tx + 6 * S, wy + ty + th / 2 }, 1.8 * S, col32({ tint[1], tint[2], tint[3], 1 }), 10)
        text_at(tx + 11 * S, ty + 2 * S, { tint[1], tint[2], tint[3], 1 }, label, ls, not cfg.panel)
    end

    return rh
end

-- Enemy song as a slim bar: name + time, draining bar, mob name under it.
local function enemy_bar_height(m)
    local S = m.S
    return 6 * S + m.nh + 4 * S + 8 * S * sz('s_info') + 3 * S + m.ch + 6 * S
end

local function draw_enemy_bar(dl, wx, wy, x, y, w, e, m, t, now)
    local S    = m.S
    local st   = song_state(e, now)
    local k    = fade_of(e, now, t)
    local done = (st == 'done')
    local c    = done and C.grey or e.def.col
    local h    = enemy_bar_height(m)
    if e.pop_pending then e.pop_at = t; e.fill_at = t; e.pop_pending = nil end
    local frac = fill_of(e, t)

    -- plate + red accent on the left edge
    local x0, y0, x1, y1 = wx + x, wy + y, wx + x + w, wy + y + h
    dl:AddRectFilled({ x0, y0 }, { x1, y1 }, col32({ 0.05, 0.06, 0.09, 0.86 * k }), 7 * S)
    local bd = done and C.grey or ROW_TINT.ENEMY
    if st == 'ending' then bd = mix(bd, { 1.0, 0.70, 0.22 }, 0.5 + 0.5 * math.sin(t * 7)) end
    dl:AddRect({ x0, y0 }, { x1, y1 }, col32({ bd[1], bd[2], bd[3], 0.45 * k }), 7 * S, ROUND_ALL, 1.0)
    dl:AddRectFilled({ x0 + 1, y0 + 4 * S }, { x0 + 3.5 * S, y1 - 4 * S }, col32(A(done and C.grey or C.red, k)), 2 * S)

    -- line 1: name (left) + time (right)
    local px = x + 9 * S
    local ty = y + 6 * S
    local tstr = done and 'gone' or fmt_time(e.ends - now)
    local tw = text_size(tstr, m.tscale)
    text_at(px, ty, A(done and C.grey or C.cream, k), e.def.short, m.nscale, false)
    local tcol = done and C.grey or ((st == 'ending') and { 1.0, 0.70, 0.22, 1 } or C.steel)
    text_at(x + w - 8 * S - tw, ty + (m.nh - m.th) / 2, A(tcol, k), tstr, m.tscale, false)

    -- line 2: draining bar in the song colour
    local bh  = 8 * S * sz('s_info')
    local by0 = ty + m.nh + 4 * S
    local bx0, bw = px, w - 17 * S
    dl:AddRectFilled({ wx + bx0 - 1, wy + by0 - 1 }, { wx + bx0 + bw + 1, wy + by0 + bh + 1 }, col32({ 0, 0, 0, 0.75 * k }), bh / 2 + 1)
    dl:AddRectFilled({ wx + bx0, wy + by0 }, { wx + bx0 + bw, wy + by0 + bh }, col32(A(mix(c, { 0.04, 0.05, 0.07 }, 0.80), k)), bh / 2)
    if frac > 0.001 then
        local fw = math.max(bh, bw * frac)
        dl:AddRectFilled({ wx + bx0, wy + by0 }, { wx + bx0 + fw, wy + by0 + bh }, col32(A(mix(c, { 0, 0, 0 }, 0.10), k)), bh / 2)
        dl:AddRectFilled({ wx + bx0 + 2, wy + by0 + 1 }, { wx + bx0 + fw - 2, wy + by0 + bh * 0.45 }, col32({ 1, 1, 1, 0.22 * k }), bh / 3)
        -- small moving shine on the bar's edge
        local gx = wx + bx0 + fw - 3 * S + math.sin(t * 5) * 1.5 * S
        dl:AddLine({ gx, wy + by0 + 1 }, { gx, wy + by0 + bh - 1 }, col32({ 1, 1, 1, 0.55 * k }), 1.4 * S)
    end
    if e.pop_at and t - e.pop_at < 0.25 then
        dl:AddRectFilled({ wx + bx0, wy + by0 }, { wx + bx0 + bw, wy + by0 + bh }, col32({ 1, 1, 1, 0.7 * (1 - (t - e.pop_at) / 0.25) }), bh / 2)
    end

    -- line 3: effect + mob name (left), recast READY / cooldown pill (right)
    local ly  = by0 + bh + 3 * S
    local rc  = rc_of(e)
    local rtx = (rc > 0) and ('RECAST %ds'):format(math.ceil(rc)) or 'READY'
    local rw  = text_size(rtx, m.cscale) + 10 * S
    local rh  = m.ch + 2 * S
    local rx  = x + w - 8 * S - rw
    local rfg, rbg, rbd
    if rc > 0 then
        rfg, rbg, rbd = { 1.0, 0.80, 0.42, 1 }, { 0.30, 0.20, 0.04, 0.92 }, { 1.0, 0.68, 0.25, 0.9 }
    else
        local pulse = 0.75 + 0.25 * math.sin(t * 4)
        rfg, rbg, rbd = C.green, { 0.06, 0.24, 0.12, 0.92 }, { 0.40, 0.85, 0.50, 0.9 * pulse }
    end
    pill(dl, wx, wy, rx, ly - 1 * S, rw, rh, A(rbg, k), A(rbd, k))
    text_at(rx + 5 * S, ly, A(rfg, k), rtx, m.cscale, false)

    local sub = ('%s  -  %s'):format(e.def.eff, e.enemy_name or 'target')
    text_at(px, ly, A(done and C.grey or C.dim, k), sub, m.cscale, false)

    -- hover anywhere on the bar for details
    imgui.SetCursorPos({ x, y })
    imgui.InvisibleButton('##eb' .. e.id, { w, h })
    if imgui.IsItemHovered() then song_tooltip(e, now) end
    return h
end

----------------------------------------------------------------------------
-- BRD ability cooldown pills (Soul Voice, Pianissimo, Nightingale, Troubadour)
----------------------------------------------------------------------------

local function ability_recast(rid)
    local ok, v = pcall(function ()
        local r = AshitaCore:GetMemoryManager():GetRecast()
        for i = 0, 31 do
            if r:GetAbilityTimerId(i) == rid and r:GetAbilityTimer(i) > 0 then
                local sec = r:GetAbilityTimer(i) / 60     -- 1/60 s -> seconds
                if sec > 7200 then return 0 end           -- not a real timer
                return sec
            end
        end
        return 0
    end)
    return (ok and v) or 0
end

local function fmt_cd(sec)
    sec = math.max(0, math.ceil(sec))
    if sec >= 3600 then return ('%d:%02d:%02d'):format(math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60) end
    return fmt_time(sec)
end

-- Soul Voice / Nightingale / Troubadour are main-job BRD only; sub BRD gets Pianissimo.
local function main_is_brd()
    local ok, r = pcall(function () return player():GetMainJob() == BRD_JOB end)
    return ok and r or false
end

local function cd_list()
    local out = {}
    local main = state.testing or main_is_brd()
    if not main and not cfg.cd_on_sub then return out end   -- sub BRD: no pills unless asked
    for _, a in ipairs(ABILITIES) do
        if cfg[a.key] ~= false and (main or not a.main) then out[#out + 1] = a end
    end
    return out
end

local function cd_pill_text(a, buffs)
    if buffs[a.buff] then return 'ON', 'on' end
    local rem = state.testing and (a.test_rem or 0) or ability_recast(a.rid)
    if rem > 0 then return fmt_cd(rem), 'cool' end
    return 'READY', 'ready'
end

local function cd_row_width(S)
    if not cfg.show_cd then return 0 end
    local w, buffs = 0, my_buffs()
    for _, a in ipairs(cd_list()) do
        local txt = cd_pill_text(a, buffs)
        w = w + text_size(a.short, 0.66 * S) + text_size(txt, 0.70 * S) + 22 * S + 5 * S
    end
    return w
end

local function draw_cd_row(dl, wx, wy, x, y, S, t)
    local list = cd_list()
    if not cfg.show_cd or #list == 0 then return 0 end
    local buffs = my_buffs()
    local _, th = text_size('A', 0.70 * S)
    local h = th + 7 * S
    local px = x
    for _, a in ipairs(list) do
        local txt, mode = cd_pill_text(a, buffs)
        local w1 = text_size(a.short, 0.66 * S)
        local w2 = text_size(txt, 0.70 * S)
        local w  = w1 + w2 + 22 * S
        local fg, bg, bd
        if mode == 'on' then
            local pulse = 0.5 + 0.5 * math.sin(t * 4)
            fg, bg, bd = { a.col[1], a.col[2], a.col[3], 1 }, { a.col[1] * 0.30, a.col[2] * 0.30, a.col[3] * 0.30, 0.95 }, { a.col[1], a.col[2], a.col[3], 0.6 + 0.4 * pulse }
            for g = 2, 1, -1 do
                local d = g * 2.5 * S
                dl:AddRectFilled({ wx + px - d, wy + y - d }, { wx + px + w + d, wy + y + h + d }, col32({ a.col[1], a.col[2], a.col[3], 0.08 * (3 - g) * pulse }), h / 2 + d)
            end
        elseif mode == 'ready' then
            fg, bg, bd = C.green, { 0.06, 0.24, 0.12, 0.92 }, { 0.40, 0.85, 0.50, 0.9 }
        else
            fg, bg, bd = { 1.0, 0.80, 0.42, 1 }, { 0.30, 0.20, 0.04, 0.92 }, { 1.0, 0.68, 0.25, 0.9 }
        end
        pill(dl, wx, wy, px, y, w, h, bg, bd)
        text_at(px + 8 * S, y + (h - th) / 2 + 1 * S, { a.col[1], a.col[2], a.col[3], 1 }, a.short, 0.66 * S, false)
        dl:AddCircleFilled({ wx + px + 8 * S + w1 + 4 * S, wy + y + h / 2 }, 1.4 * S, col32(C.dim), 8)
        text_at(px + 14 * S + w1, y + (h - th) / 2, fg, txt, 0.70 * S, false)
        imgui.SetCursorPos({ px, y })
        imgui.InvisibleButton('##cd_' .. a.key, { w, h })
        if imgui.IsItemHovered() then
            tooltip_text(('%s\n%s'):format(a.name, (mode == 'on') and 'Active now' or ((mode == 'ready') and 'Ready to use' or ('Ready in ' .. txt))))
        end
        px = px + w + 5 * S
    end
    return h
end

local function draw_overlay_full(list, now)
    local S      = cfg.scale
    local m      = layout(S)
    local all    = add_ghosts(build_rows(list))
    local rows, side = {}, nil
    for _, row in ipairs(all) do
        if row.label == 'ENEMY' then side = row else table.insert(rows, row) end
        for _, e in ipairs(row.items) do
            m.colW = math.max(m.colW, text_size(e.def.short, m.nscale) + 34 * S)
        end
    end
    local n = (#rows > 0) and 1 or 0
    for _, row in ipairs(rows) do n = math.max(n, #row.items) end
    local GAP    = 14 * S
    local leftW  = (n > 0) and (n * m.colW + 8 * S) or 0
    local sideW  = 0
    if side then
        sideW = 150 * S
        for _, e in ipairs(side.items) do
            sideW = math.max(sideW, text_size(e.def.short, m.nscale) + text_size('0:00', m.tscale) + 34 * S,
                text_size(('%s  -  %s'):format(e.def.eff, e.enemy_name or 'target'), m.cscale) + text_size('RECAST 00s', m.cscale) + 36 * S)
        end
    end
    local W      = leftW + ((leftW > 0 and sideW > 0) and GAP or 0) + sideW
    W = math.max(W, m.colW + 8 * S, cd_row_width(S) + 8 * S)
    local EMPTY  = 'No songs up'
    if #all == 0 then W = math.max(W, text_size(EMPTY, 0.85 * S) + 28 * S) end
    local bx, by = imgui.GetCursorPos()
    local wx, wy = imgui.GetWindowPos()
    local dl     = imgui.GetWindowDrawList()
    local t      = anim_time()

    -- header (wordmark + buttons) only while you hover the overlay
    local hflag = ImGuiHoveredFlags_AllowWhenBlockedByActiveItem or 128
    local okh, hv = pcall(function () return imgui.IsWindowHovered(hflag) end)
    if not okh then hv = imgui.IsWindowHovered() end
    if hv or imgui.IsAnyItemActive() then state.hover_until = t + 0.5 end
    local hovered = (state.hover_until or 0) > t
    m.hover = hovered
    local r = 6 * S
    if hovered then
        local hs = 0.80 * S
        local _, hh = text_size('6arab', hs)
        draw_note(dl, wx + bx + 2 * S, wy + by + r - 7 * S, 14 * S, col32(C.gold))
        text_at(bx + 16 * S, by + r - hh / 2, C.gold, '6arab', hs, true)
        imgui.SetCursorPos({ bx + W - r * 2, by })
        if round_button('##6arab_min', 'min', r) then
            cfg.minimized = true
            settings.save()
            dlog.add('UI', 'Overlay minimized')
        end
        imgui.SetCursorPos({ bx + W - r * 4 - 5 * S, by })
        local _, hov = round_button('##6arab_help', 'help', r)
        if hov then tooltip_text(OVERLAY_HELP) end
        imgui.SetCursorPos({ bx + W - r * 6 - 10 * S, by })
        local gc, ghov = round_button('##6arab_cfg', 'gear', r)
        if gc then state.cfg_win.open = not state.cfg_win.open end
        if ghov then tooltip_text('Settings  (/6arab)') end
        imgui.SetCursorPos({ bx + W - r * 8 - 15 * S, by })
        local bc, bhov = round_button('##6arab_dbg', 'bug', r)
        if bc then state.log_win.open = not state.log_win.open end
        if bhov then tooltip_text('Debug log  (/6arab log)') end
    end

    local y = by + r * 2 + 10 * S
    local cdh = draw_cd_row(dl, wx, wy, bx + 4 * S, y - 4 * S, S, t)
    if cdh > 0 then y = y + cdh + ((#all > 0) and 14 * S or 2 * S) end
    local y_top = y
    if #all == 0 and cdh == 0 then
        local h = 34 * S
        local w, th = text_size(EMPTY, 0.85 * S)
        pill(dl, wx, wy, bx + (W - w) / 2 - 11 * S, y + (h - th) / 2 - 3 * S, w + 22 * S, th + 6 * S,
            { 0.05, 0.06, 0.09, 0.86 }, { 0.96, 0.74, 0.26, 0.55 })
        text_at(bx + (W - w) / 2, y + (h - th) / 2, { 0.85, 0.87, 0.92, 1 }, EMPTY, 0.85 * S, false)
        y = y + h
    end

    -- MELEE row on top, MAGES row under it
    for _, row in ipairs(rows) do
        local rh = draw_row(dl, wx, wy, bx, y, leftW, row, m, t, now, hovered)
        y = y + rh + 14 * S
    end

    -- enemy songs (debuffs / sleep): slim bars stacked on the side
    if side then
        local sx = bx + ((leftW > 0) and (leftW + GAP) or 0)
        local sy = y_top
        if cfg.row_labels and hovered then
            local ls = 0.66 * S
            local tint = ROW_TINT.ENEMY
            local _, lh = text_size('ENEMY', ls)
            dl:AddCircleFilled({ wx + sx + 6 * S, wy + sy - lh / 2 - 2 * S }, 1.8 * S, col32({ tint[1], tint[2], tint[3], 1 }), 10)
            text_at(sx + 11 * S, sy - lh - 4 * S, { tint[1], tint[2], tint[3], 1 }, 'ENEMY', ls, true)
        end
        for _, e in ipairs(side.items) do
            local h = draw_enemy_bar(dl, wx, wy, sx, sy, sideW, e, m, t, now)
            sy = sy + h + 6 * S
        end
        y = math.max(y, sy + 10 * S)
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
    local rows   = build_rows(list)
    local flat   = {}
    for _, row in ipairs(rows) do for _, e in ipairs(row.items) do flat[#flat + 1] = e end end
    local n      = #flat
    local bx, by = imgui.GetCursorPos()
    local wx, wy = imgui.GetWindowPos()
    local dl     = imgui.GetWindowDrawList()
    local t      = anim_time()

    local splits = 0
    for i = 2, n do if flat[i].group ~= flat[i - 1].group then splits = splits + 1 end end
    local sgap  = 8 * S
    local label = (n == 0) and '6arab' or nil
    local lw    = label and (text_size(label, 0.85 * S) + gap) or 0
    local h     = m + pad * 2 - 4 * S
    local w     = pad * 2 + h * 0.3 + lw + n * (m + gap) + splits * sgap + r * 2
    local px, py = wx + bx, wy + by

    dl:AddRectFilled({ px, py }, { px + w, py + h }, col32({ 0.07, 0.08, 0.11, 0.88 }), h / 2)
    dl:AddRect({ px, py }, { px + w, py + h }, col32({ 0.96, 0.74, 0.26, 0.45 }), h / 2, ROUND_ALL, 1.2)

    local x  = bx + pad + h * 0.15
    local ty = by + (h - m) / 2
    if label then
        local _, lh = text_size(label, 0.85 * S)
        text_at(x, by + (h - lh) / 2, C.gold, label, 0.85 * S, false)
        x = x + lw
    end
    for i, e in ipairs(flat) do
        if i > 1 and e.group ~= flat[i - 1].group then
            local dx = wx + x + sgap / 2 - gap / 2
            dl:AddLine({ dx, wy + ty + 3 * S }, { dx, wy + ty + m - 3 * S }, col32({ 0.96, 0.74, 0.26, 0.45 }), 1.2)
            x = x + sgap
        end
        local st = song_state(e, now)
        local k  = fade_of(e, now, t)
        local sx, sy = wx + x, wy + ty
        if e.pop_pending then e.pop_at = t; e.fill_at = t; e.pop_pending = nil end
        local frac = fill_of(e, t)
        local c = e.def.col
        local bd = (st == 'done') and { 0.48, 0.49, 0.53, 1 } or c
        if st == 'ending' then bd = mix(bd, { 1.0, 0.70, 0.22 }, 0.5 + 0.5 * math.sin(t * 7)) end
        local empty = (st == 'done') and { 0.22, 0.23, 0.25, 1 } or mix(c, { 0.04, 0.05, 0.07 }, 0.82)
        dl:AddRectFilled({ sx, sy }, { sx + m, sy + m }, col32(A(empty, k)), 5 * S)
        if frac > 0.001 then
            local level = sy + m * (1 - frac)
            dl:AddRectFilled({ sx, level }, { sx + m, sy + m }, col32(A(mix(c, { 0, 0, 0 }, 0.15), k)), 5 * S, (frac > 0.97) and ROUND_ALL or ROUND_BOT)
            if frac < 0.995 then
                dl:AddLine({ sx + 2, level }, { sx + m - 2, level }, col32({ 1, 1, 1, 0.7 * k }), 1.0)
            end
        end
        draw_note(dl, sx + m * 0.12 + 1, sy + m * 0.06 + 1, m * 0.76, col32({ 0, 0, 0, 0.5 * k }))
        draw_note(dl, sx + m * 0.12, sy + m * 0.06, m * 0.76, col32(A((st == 'done') and { 0.62, 0.63, 0.67, 1 } or mix(c, { 1, 1, 1 }, 0.75), k)))
        dl:AddRect({ sx, sy }, { sx + m, sy + m }, col32(A(bd, k)), 5 * S, ROUND_ALL, 1.2)
        if e.group == 'ENEMY' then
            dl:AddTriangleFilled({ sx + m - 6 * S, sy + 1 }, { sx + m - 1, sy + 1 }, { sx + m - 1, sy + 6 * S }, col32(A(st == 'done' and C.grey or C.red, k)))
        end
        imgui.SetCursorPos({ x, ty })
        imgui.InvisibleButton('##sc' .. e.id, { m, m })
        if imgui.IsItemHovered() then song_tooltip(e, now) end
        x = x + m + gap
    end
    imgui.SetCursorPos({ x, by + (h - r * 2) / 2 })
    if round_button('##6arab_max', 'max', r) then
        cfg.minimized = false
        settings.save()
        dlog.add('UI', 'Overlay restored')
    end
    imgui.SetCursorPos({ bx, by })
    imgui.Dummy({ w, h })
end

local function draw_overlay()
    if not cfg.visible then return end
    if not state.testing and not brd_active() then return end
    if my_id() == 0 and not state.testing then return end
    local list = state.active
    if #list == 0 and not state.testing and not (cfg.show_empty and is_brd()) then return end

    local now = os.time()
    local S   = cfg.scale

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

    if imgui.Begin('6arab_overlay', state.overlay_open, flags) then
        local ok, err = pcall(function ()
            if cfg.minimized then
                draw_overlay_compact(list, now)
            else
                draw_overlay_full(list, now)
            end
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
        end)
        if not ok then dlog.add('ERR', 'Overlay draw: ' .. tostring(err)) end
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
    local ok, done = pcall(function () return imgui.IsItemDeactivatedAfterEdit() end)
    if (ok and done) or (not ok and changed) then
        settings.save()
        dlog.add('CFG', ('%s size = %.2f'):format(label, sz(key)))
    end
    imgui.PopItemWidth()
    help_marker('##h_sz_' .. key, tip)
end

local function int_slider(W, key, lo, hi, fmt, tip)
    imgui.PushItemWidth(W - 70)
    local v = { tonumber(cfg[key]) or 0 }
    if imgui.SliderFloat('##is_' .. key, v, lo, hi, fmt) then
        cfg[key] = math.floor(v[1] + 0.5)
        settings.save()
    end
    imgui.PopItemWidth()
    help_marker('##h_is_' .. key, tip)
end

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
    place_window(40, -120)
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoCollapse)
    if imgui.Begin('6arab_config', ws.open_tbl, flags) then
        local ok, err = pcall(function ()
            window_header('6arab', W, ws)
            if not ws.min then
                imgui.Separator()
                opt_checkbox('Show overlay', 'visible', 'Show the floating song tiles.')
                opt_checkbox('Lock position', 'locked', 'Stop the overlay from being dragged.')
                opt_checkbox('Enemy songs', 'track_enemy', 'Also track Requiem, Lullaby, Elegy and Threnody you land on mobs (red corner, bottom row).')
                opt_checkbox('Recast pill', 'show_recast', 'Show a small RECAST pill under a song while it is still on cooldown.')
                opt_checkbox('Row labels', 'row_labels', 'Show SONGS / ENEMY labels over each row while you hover.')
                opt_checkbox('Only on BRD', 'brd_only', 'Hide 6arab and stop tracking unless you are BRD. It switches on by itself when you change to BRD.')
                if cfg.brd_only then
                    opt_checkbox('  ...or sub BRD', 'brd_sub', 'Also switch on when BRD is your sub job.')
                end
                opt_checkbox('Panel frame', 'panel', 'Draw a dark glass frame behind each row. Off = the tiles float freely over the game.')
                opt_checkbox('Show when empty', 'show_empty', "While you're BRD, show a small 'No songs up' marker when nothing is running.")

                imgui.Spacing()
                imgui.TextColored(C.gold, 'Songs')
                help_marker('##h_songs', 'Timers use the base Lv75 duration (2:00 for most songs). Add your instrument / gear bonus so they match the game.')
                int_slider(W, 'fade_s', 1, 30, 'Fade out %.0f s', 'How fast a finished song fades away after it turns grey.')
                opt_checkbox('Grey on early end', 'grey_early', 'Off: songs that end early (overwritten, wore off, mob defeated, KO) just disappear. On: they go grey with the reason, like finished songs.')
                int_slider(W, 'bonus_pct', 0, 100, 'Duration +%.0f%%', 'Song duration bonus from your instrument / gear.')
                int_slider(W, 'bonus_flat', 0, 60, 'Duration +%.0f s', 'Flat seconds added to party songs.')

                opt_checkbox('Exact timers', 'exact', 'Read the real time left of your songs from your buff bar (covers instrument bonus and Troubadour). Falls back to the estimate if this Ashita build cannot read buff timers.')

                imgui.Spacing()
                imgui.TextColored(C.gold, 'Song set')
                help_marker('##h_set', 'Pick the songs you normally keep up. Any song from your set that is not running shows as a faint ghost tile with SING / recast, so you see at a glance what to sing.')
                opt_checkbox('Show missing songs', 'show_set', 'Ghost tiles for songs from your set that are not up.')
                for _, grp in ipairs({ { 'MELEE', 'set_melee' }, { 'MAGES', 'set_mages' } }) do
                    imgui.TextColored(ROW_TINT[grp[1]], grp[1])
                    cfg[grp[2]] = cfg[grp[2]] or T{ '', '', '', '' }
                    for i = 1, 4 do
                        local cur = cfg[grp[2]][i] or ''
                        imgui.PushItemWidth(W - 40)
                        if imgui.BeginCombo(('##%s%d'):format(grp[2], i), (cur ~= '') and cur or '- none -') then
                            if imgui.Selectable('- none -', cur == '') then
                                cfg[grp[2]][i] = ''; settings.save()
                            end
                            for _, nm in ipairs(songs.SET_CHOICES) do
                                if imgui.Selectable(nm, cur == nm) then
                                    cfg[grp[2]][i] = nm; settings.save()
                                    dlog.add('CFG', ('%s set slot %d = %s'):format(grp[1], i, nm))
                                end
                            end
                            imgui.EndCombo()
                        end
                        imgui.PopItemWidth()
                    end
                end

                imgui.Spacing()
                imgui.TextColored(C.gold, 'Cooldowns')
                help_marker('##h_cds', 'Pills on top of 6arab: green READY, amber countdown, glowing ON while the ability is active.')
                opt_checkbox('Show cooldowns', 'show_cd', 'Ability cooldown pills on top of the overlay.')
                if cfg.show_cd then
                    opt_checkbox('  Pianissimo on sub BRD', 'cd_on_sub', 'When BRD is only your sub job, the pills are hidden. Turn this on to still show the Pianissimo pill.')
                    for _, a in ipairs(ABILITIES) do
                        opt_checkbox('  ' .. a.name, a.key, ('Show the %s pill.%s'):format(a.name, a.main and ' (Only when BRD is your main job.)' or ''))
                    end
                end

                imgui.Spacing()
                imgui.TextColored(C.gold, 'Sizes')
                help_marker('##h_sizes', 'Each part has its own size. Overall scales everything; the others multiply on top of it.')
                size_slider(W, 'Overall',        'scale',  0.6, 2.0, 'Everything at once. Also: /6arab scale 1.2')
                size_slider(W, 'Note tiles',     's_icon', 0.6, 1.8, 'The note tiles and their status chips.')
                size_slider(W, 'Song names',     's_name', 0.6, 1.8, 'The name ribbons above each tile.')
                size_slider(W, 'Effect & timer', 's_info', 0.6, 1.8, 'The plate under each tile and the recast pill.')
                if imgui.Button('Reset sizes', { 100, 0 }) then
                    cfg.scale, cfg.s_icon, cfg.s_name, cfg.s_info = 1, 1, 1, 1
                    settings.save()
                    dlog.add('CFG', 'Sizes reset')
                end

                imgui.Spacing()
                imgui.TextColored(C.gold, 'Debug')
                help_marker('##h_debug', 'Everything 6arab does is written to the debug log. Commands: /6arab log, /6arab debug on|off')
                opt_checkbox('Verbose (debug) tracing', 'verbose', 'Also record packet / engine traces (every song packet with target, message and buff ids).')
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
                if imgui.Button('Test', { 56, 0 }) then test_songs() end
                help_marker('##h_test', 'Preview with fake songs. Click again to cycle: normal set, fresh cast + recast, songs gone grey.')
                imgui.SameLine()
                if imgui.Button('Clear', { 56, 0 }) then
                    state.active = {}
                    state.testing = false
                    dlog.add('CMD', 'Songs cleared')
                end
                imgui.SameLine()
                if imgui.Button('Log', { 48, 0 }) then state.log_win.open = not state.log_win.open end

                imgui.Spacing()
                imgui.TextColored(C.dim, 'by Jboor')
            end
        end)
        if not ok then dlog.add('ERR', 'Settings draw: ' .. tostring(err)) end
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
    place_window(60, -90)
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoCollapse)
    if imgui.Begin('6arab_log', ws.open_tbl, flags) then
        local ok, err = pcall(function ()
            window_header('6arab - debug log', W, ws)
            if not ws.min then
                imgui.Separator()
                local v = { cfg.verbose }
                if imgui.Checkbox('Verbose (debug) tracing', v) then
                    cfg.verbose = v[1]; sync_log(); settings.save()
                    dlog.add('CFG', 'verbose = ' .. tostring(v[1]))
                end
                help_marker('##h_verbose', 'Also record packet / engine traces.')
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

                local boxed = begin_child('##6arab_log_lines', { W, 260 })
                local shown = 0
                local ok2, err2 = pcall(function ()
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
                end)
                if boxed then imgui.EndChild() end
                if not ok2 then error(err2) end
                imgui.TextColored(C.dim, ('%d / %d lines   -   Ashita/logs/6arab/'):format(#dlog.lines, dlog.max))
            end
        end)
        if not ok then dlog.add('ERR', 'Log draw: ' .. tostring(err)) end
    end
    imgui.End()
    pop_theme()
end

----------------------------------------------------------------------------
-- events
----------------------------------------------------------------------------
ashita.events.register('load', '6arab_load', function ()
    dlog.add('INFO', ('6arab v%s loaded - by Jboor'):format(addon.version))
end)

ashita.events.register('unload', '6arab_unload', function ()
    pcall(save_songs, true)
    settings.save()
end)

ashita.events.register('packet_in', '6arab_packet_in', function (e)
    if e.id == 0x028 then
        local ok, act = pcall(parse_action, e)
        if not ok then
            dlog.add('ERR', 'Action parse failed: ' .. tostring(act))
            return
        end
        if act.category == 4 then
            if not brd_active() then return end
            local ok2, err = pcall(on_spell, act)
            if not ok2 then dlog.add('ERR', 'Song handler error: ' .. tostring(err)) end
        end
    elseif e.id == 0x029 then
        local ok, err = pcall(on_message, e.data)
        if not ok then dlog.add('ERR', 'Message parse failed: ' .. tostring(err)) end
    elseif e.id == 0x00A then
        local n = 0
        for i = #state.active, 1, -1 do
            if state.active[i].group == 'ENEMY' then table.remove(state.active, i); n = n + 1 end
        end
        if n > 0 then dlog.add('INFO', ('Zoned - %d enemy song(s) cleared'):format(n)) end
    end
end)

ashita.events.register('d3d_present', '6arab_present', function ()
    local ok, err = pcall(tick)
    if not ok then dlog.add('ERR', 'Tick: ' .. tostring(err)) end
    draw_overlay()
    draw_config()
    draw_log()
end)

local HELP = {
    '/6arab - settings window',
    '/6arab test - preview songs (cycles presets)',
    '/6arab clear - clear tracked songs',
    '/6arab min - minimize / restore overlay',
    '/6arab lock - lock / unlock position',
    '/6arab scale <0.6-2.0> - overlay size',
    '/6arab show | hide',
    '/6arab reset - default position',
    '/6arab log - debug log',
    '/6arab debug [on|off] - verbose tracing',
}

ashita.events.register('command', '6arab_command', function (e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/6arab' then return end
    e.blocked = true

    local sub = (args[2] or ''):lower()
    dlog.add('CMD', e.command)

    if sub == '' or sub == 'config' or sub == 'settings' then
        state.cfg_win.open = not state.cfg_win.open
    elseif sub == 'test' then
        test_songs()
    elseif sub == 'clear' then
        state.active = {}
        state.testing = false
    elseif sub == 'min' then
        cfg.minimized = not cfg.minimized
    elseif sub == 'lock' then
        cfg.locked = not cfg.locked
        msg('Overlay ' .. (cfg.locked and 'locked' or 'unlocked'))
    elseif sub == 'unlock' then
        cfg.locked = false
        msg('Overlay unlocked')
    elseif sub == 'scale' then
        local n = tonumber(args[3])
        if n then
            cfg.scale = math.max(0.6, math.min(2.0, n))
            msg(('Scale %.2f'):format(cfg.scale))
        else
            msg('Usage: /6arab scale <0.6-2.0>')
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
