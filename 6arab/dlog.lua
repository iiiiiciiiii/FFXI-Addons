--[[
    6arab - Debug Log (7arg style)
    Ring buffer, newest first, timestamp + category tag + colour per category.
    Always-recorded lines: actions, decisions (with reasons), failures, errors.
    Verbose-only lines: packet / engine traces (only when verbose is on).
]]--

local chat = require('chat')

local dlog = {
    lines   = {},
    max     = 400,
    verbose = false,
    echo    = false,
    filter  = 'ALL',
}

dlog.cats = {
    SONG = { 0.96, 0.74, 0.26, 1.0 },
    GONE = { 0.66, 0.68, 0.74, 1.0 },
    WEAR = { 1.00, 0.62, 0.30, 1.0 },
    FAIL = { 1.00, 0.36, 0.36, 1.0 },
    PKT  = { 0.60, 0.62, 0.72, 1.0 },
    UI   = { 0.62, 0.90, 0.66, 1.0 },
    CMD  = { 0.82, 0.68, 1.00, 1.0 },
    CFG  = { 0.80, 0.80, 0.80, 1.0 },
    INFO = { 0.92, 0.90, 0.84, 1.0 },
    ERR  = { 1.00, 0.20, 0.20, 1.0 },
}
dlog.order = { 'ALL', 'SONG', 'GONE', 'WEAR', 'FAIL', 'PKT', 'UI', 'CMD', 'CFG', 'INFO', 'ERR' }

function dlog.add(cat, msg, verbose_only)
    if verbose_only and not dlog.verbose then return end
    table.insert(dlog.lines, 1, {
        t   = os.date('%H:%M:%S'),
        cat = cat,
        msg = tostring(msg),
        v   = verbose_only and true or false,
    })
    while #dlog.lines > dlog.max do
        table.remove(dlog.lines)
    end
    if dlog.echo then
        print(chat.header('6arab'):append(chat.message(('[%s] %s'):format(cat, tostring(msg)))))
    end
end

function dlog.clear()
    dlog.lines = {}
end

local function make_dir(path)
    local mk = ashita.fs.create_directory or ashita.fs.create_dir
    if mk then pcall(mk, path) end
end

-- Saves to Ashita/logs/6arab/6arab_<date>_<time>.log (oldest line first).
function dlog.save()
    local base = AshitaCore:GetInstallPath()
    make_dir(('%s\\logs'):format(base))
    local dir = ('%s\\logs\\6arab'):format(base)
    make_dir(dir)
    local fname = ('%s\\6arab_%s.log'):format(dir, os.date('%Y-%m-%d_%H-%M-%S'))
    local f, err = io.open(fname, 'w')
    if not f then
        dlog.add('ERR', 'Save failed: ' .. tostring(err))
        return nil
    end
    f:write('6arab - debug log - by Jboor\n')
    for i = #dlog.lines, 1, -1 do
        local l = dlog.lines[i]
        f:write(('%s [%s]%s %s\n'):format(l.t, l.cat, l.v and ' (v)' or '', l.msg))
    end
    f:close()
    dlog.add('INFO', 'Log saved: ' .. fname)
    return fname
end

return dlog
