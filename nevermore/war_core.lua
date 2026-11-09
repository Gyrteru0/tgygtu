--[[
================================================================================
 WAR CORE v1.1 (Patch 7.41f Exact) — Predictive Duel Simulator for SF 1v1 Mid
================================================================================
 Pure Lua 5.1 forward simulator (zero Dota API calls).

 Unified v6.6.0 fixes over v6.5.0:
   1. Exact Patch 7.41f constants:
        RAZE_BASE      = { 85, 150, 215, 280 }
        RAZE_STACK     = { 35, 50, 65, 80 }
        STACK_DURATION = 6.0s (7.41e/f debuff duration)
        ATK_RANGE      = 525u
        TOWER_DMG      = 65 post-class/armor fallback
   2. Emergency burst heal (`faerie` +85 HP, `stick_charges` * 15 HP/MP) simulated
      accurately on both heroes (`9068560663.dem` 01:53 fix).
   3. Fixed undeclared global `worstPlan` leak in `WAR.Evaluate`.
================================================================================
]]

local WAR = {}

local C = {
    DT              = 1.0 / 30.0,

    RAZE_MANA       = 75,
    RAZE_CD         = 9.0,
    RAZE_CAST       = 0.55,
    RAZE_DIST       = { 200, 450, 700 },
    RAZE_RADIUS     = 250,
    RAZE_HERO_RADIUS= 274, -- Exact Source 2 FindUnitsInRadius: 250 + 24 hero hull
    RAZE_BASE       = { 85, 150, 215, 280 },
    RAZE_STACK      = { 35, 50, 65, 80 },
    RAZE_PER_SOUL   = 2,
    STACK_DURATION  = 6.0,
    MAX_STACKS      = 4,

    ATK_RANGE       = 525,
    ATK_POINT       = 0.50,
    PROJ_SPEED      = 1200,
    BAT             = 1.60,
    TURN_RATE       = 30.0, -- Exact Source 2 SF turn rate: 0.9 rad / 0.03s = 30.0 rad/s (1718.9 deg/s)
    MAGIC_RESIST    = 0.25,

    TOWER_RANGE     = 868,
    TOWER_LEASH     = 1080,
    TOWER_DMG       = 65,
    TOWER_INTERVAL  = 0.8182,
    TOWER_WINDUP    = 0.60,
    TOWER_PROJECTILE= 750,
    TOWER_FIRST     = 0.35,

    HORIZON         = 3.4,
    INCOMING_LAND   = 0.18,

    CREEP = {
        melee  = { dmg = 21.0, bat = 1.0, range = 100, proj = 0,    hp = 550 },
        ranged = { dmg = 23.5, bat = 1.0, range = 500, proj = 900,  hp = 300 },
        siege  = { dmg = 40.5, bat = 3.0, range = 690, proj = 1100, hp = 935 },
        flag   = { dmg = 21.0, bat = 1.0, range = 100, proj = 0,    hp = 550 },
        HULL_PAD = 45,
    },

    W_HP            = 1.0,
    W_MANA          = 0.28,
    W_TOWER         = 0.0,
    W_STAND         = 0.45,
    DEATH_COST      = 1.0e6,
    KILL_BONUS      = 3.2e5,
    SAFE_HP_ABS     = 135,
}
WAR.C = C

local m_sqrt  = math.sqrt
local m_min   = math.min
local m_max   = math.max
local m_abs   = math.abs
local m_floor = math.floor
local m_cos   = math.cos
local m_sin   = math.sin
local m_atan2 = math.atan2
local m_pi    = math.pi

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function distance(ax, ay, bx, by) local dx, dy = ax - bx, ay - by return m_sqrt(dx * dx + dy * dy) end

WAR.clamp = clamp
WAR.dist = distance

local C_RAZE_MANA        = C.RAZE_MANA
local C_RAZE_CD          = C.RAZE_CD
local C_RAZE_CAST        = C.RAZE_CAST
local C_RAZE_DIST_1      = C.RAZE_DIST[1]
local C_RAZE_DIST_2      = C.RAZE_DIST[2]
local C_RAZE_DIST_3      = C.RAZE_DIST[3]
local C_RAZE_DIST        = C.RAZE_DIST
local C_RAZE_HERO_RADIUS = C.RAZE_HERO_RADIUS
local C_RAZE_HERO_RAD_SQ = C_RAZE_HERO_RADIUS * C_RAZE_HERO_RADIUS
local C_DODGE_RAD_SQ     = (C_RAZE_HERO_RADIUS + 14) * (C_RAZE_HERO_RADIUS + 14)
local C_MAX_STACKS       = C.MAX_STACKS
local C_STACK_DURATION   = C.STACK_DURATION
local C_ATK_RANGE        = C.ATK_RANGE
local C_ATK_POINT        = C.ATK_POINT
local C_ATK_RELOAD       = m_max(0.85, C.BAT * 0.78)
local C_PROJ_SPEED       = C.PROJ_SPEED
local C_TURN_RATE        = C.TURN_RATE
local C_MAGIC_RESIST     = C.MAGIC_RESIST
local C_TOWER_RANGE      = C.TOWER_RANGE
local C_TOWER_LEASH      = C.TOWER_LEASH
local C_TOWER_DMG        = C.TOWER_DMG
local C_TOWER_INTERVAL   = C.TOWER_INTERVAL
local C_TOWER_WINDUP     = C.TOWER_WINDUP
local C_TOWER_PROJECTILE = C.TOWER_PROJECTILE
local C_TOWER_FIRST      = C.TOWER_FIRST
local C_BASE_1, C_BASE_2, C_BASE_3, C_BASE_4 = C.RAZE_BASE[1], C.RAZE_BASE[2], C.RAZE_BASE[3], C.RAZE_BASE[4]
local C_STK_1,  C_STK_2,  C_STK_3,  C_STK_4  = C.RAZE_STACK[1], C.RAZE_STACK[2], C.RAZE_STACK[3], C.RAZE_STACK[4]
local C_PER_SOUL         = C.RAZE_PER_SOUL

--------------------------------------------------------------------------------
-- damage model (Patch 7.41f exact + Spell Amp + Infused Raindrop 120 block)
--------------------------------------------------------------------------------
local function raze_raw_fast(level, stacks, souls, stackTalent, spellAmp)
    local base, stk
    if level <= 1 then base, stk = C_BASE_1, C_STK_1
    elseif level == 2 then base, stk = C_BASE_2, C_STK_2
    elseif level == 3 then base, stk = C_BASE_3, C_STK_3
    else base, stk = C_BASE_4, C_STK_4 end
    local d = base + (stacks or 0) * (stk + (stackTalent or 0)) + (souls or 0) * C_PER_SOUL
    return d * (spellAmp or 1.0)
end
WAR.RazeDamage = raze_raw_fast

local function raze_applied_fast(level, stacks, souls, mr, stackTalent, spellAmp, magicBlock)
    mr = mr or C_MAGIC_RESIST
    local raw = raze_raw_fast(level or 1, stacks, souls, stackTalent, spellAmp)
    if magicBlock and magicBlock > 0 and raw >= 75 then
        raw = m_max(0, raw - magicBlock)
    end
    return raw * (1.0 - mr)
end
WAR.RazeApplied = raze_applied_fast

function WAR.VolleyDamage(level, stacks, souls, n, mr, stackTalent, spellAmp, magicBlock)
    local total, st = 0, stacks or 0
    for i = 1, (n or 0) do
        local blk = (i == 1) and (magicBlock or 0) or 0
        total = total + WAR.RazeApplied(level, st, souls, mr, stackTalent, spellAmp, blk)
        st = m_min(C.MAX_STACKS, st + 1)
    end
    return total
end

--------------------------------------------------------------------------------
-- unit normalisation & emergency burst consumables
--------------------------------------------------------------------------------
function WAR.Prep(u)
    u = u or {}
    u.hp = u.hp or 1
    u.hp_max = u.hp_max or u.hp
    u.mana = u.mana or 0
    u.dmg = u.dmg or 0
    u.souls = u.souls or 0
    u.raze_level = u.raze_level or 0
    u.stack_talent = u.stack_talent or 0
    u.raze_ready = u.raze_ready or { 0, 0, 0 }
    u.atk_range = u.atk_range or C.ATK_RANGE
    u.atk_ready = u.atk_ready or 0
    u.ms = u.ms or 305
    u.regen_hp = u.regen_hp or 0
    u.regen_mana = u.regen_mana or 0
    u.magic_resist = u.magic_resist or C.MAGIC_RESIST
    u.spell_amp = u.spell_amp or 1.0
    u.magic_block = u.magic_block or 0
    u.raindrop_used = false
    u.alive = (u.alive ~= false)
    u.stacks = u.stacks or 0
    u.stack_t = u.stack_t or -1e9
    u.facing = u.facing or 0
    u.cast_until = u.cast_until or -1
    u.aim_x, u.aim_y = u.aim_x, u.aim_y
    u.atk_until = u.atk_until or -1
    u.proj = {}
    u.incoming = u.incoming or 0
    u.incoming_at = u.incoming_at or C.INCOMING_LAND
    u.pending_raze = nil
    u.stick_charges = u.stick_charges or 0
    if type(u.mango_charges) == "number" then
        u.mango_left = m_max(0, u.mango_charges)
    else
        u.mango_left = (u.mango and not u.mango_used) and 1 or 0
    end
    u.mango = u.mango_left > 0
    u.faerie = u.faerie and true or false
    u.faerie_used = false
    u.stick_used = false
    u.mango_used = (u.mango_left <= 0)
    return u
end

local function try_emergency_heal(u)
    if not u.alive then return end
    if u.stick_charges and u.stick_charges > 0 and not u.stick_used and u.hp <= u.hp_max * 0.30 then
        local gain = u.stick_charges * 15
        u.hp = m_min(u.hp_max, u.hp + gain)
        u.mana = u.mana + gain
        u.stick_used = true
    end
    if u.faerie and not u.faerie_used and u.hp <= m_max(110, u.hp_max * 0.22) then
        u.hp = m_min(u.hp_max, u.hp + 85)
        u.faerie_used = true
    end
end

local function apply_damage(victim, dmg, now)
    if not victim or not victim.alive or dmg <= 0 then return end
    victim.hp = victim.hp - dmg
    victim.hp_taken = (victim.hp_taken or 0) + dmg
    if victim.hp <= 0 then
        -- Pop unused Faerie/Stick right BEFORE lethal hit (mirrors emergency consumable reflex!)
        if victim.stick_charges and victim.stick_charges > 0 and not victim.stick_used then
            local gain = victim.stick_charges * 15
            victim.hp = victim.hp + gain
            victim.mana = victim.mana + gain
            victim.stick_used = true
        end
        if victim.hp <= 0 and victim.faerie and not victim.faerie_used then
            victim.hp = victim.hp + 85
            victim.faerie_used = true
        end
    end
    if victim.hp <= 0 then
        victim.hp = 0
        victim.alive = false
        victim.died_at = now
    else
        try_emergency_heal(victim)
    end
end

local SIM_ME = { raze_ready = { 0, 0, 0 }, proj = {} }
local SIM_HIM = { raze_ready = { 0, 0, 0 }, proj = {} }

local function reset_sim_unit(dst, src)
    local rr = dst.raze_ready
    local pr = dst.proj
    for i = #pr, 1, -1 do pr[i] = nil end
    local srr = src.raze_ready
    if srr then
        rr[1] = srr[1] or 0
        rr[2] = srr[2] or 0
        rr[3] = srr[3] or 0
    else
        rr[1], rr[2], rr[3] = 0, 0, 0
    end

    dst.x = src.x
    dst.y = src.y
    dst.vx = src.vx
    dst.vy = src.vy
    dst.hp = src.hp or 1
    dst.hp_max = src.hp_max or dst.hp
    dst.true_hp_max = src.true_hp_max
    dst.mana = src.mana or 0
    dst.dmg = src.dmg or 0
    dst.souls = src.souls or 0
    dst.raze_level = src.raze_level or 0
    dst.stack_talent = src.stack_talent or 0
    dst.atk_range = src.atk_range or C.ATK_RANGE
    dst.atk_ready = src.atk_ready or 0
    dst.ms = src.ms or 305
    dst.regen_hp = src.regen_hp or 0
    dst.regen_mana = src.regen_mana or 0
    dst.magic_resist = src.magic_resist or C.MAGIC_RESIST
    dst.spell_amp = src.spell_amp or 1.0
    dst.magic_block = src.magic_block or 0
    dst.raindrop_used = false
    dst.alive = (src.alive ~= false)
    dst.stacks = src.stacks or 0
    dst.stack_t = src.stack_t or -1e9
    dst.facing = src.facing or 0
    dst.cast_until = src.cast_until or -1
    dst.cast_label = src.cast_label
    dst.cast_left = src.cast_left
    dst.cast_band = src.cast_band
    dst.aim_x = src.aim_x
    dst.aim_y = src.aim_y
    dst.atk_until = src.atk_until or -1
    dst.incoming = src.incoming or 0
    dst.incoming_at = src.incoming_at or C.INCOMING_LAND
    dst.incoming_n = src.incoming_n
    dst.pending_raze = nil
    dst.pending_attack = nil
    dst.stick_charges = src.stick_charges or 0
    if type(src.mango_charges) == "number" then
        dst.mango_charges = src.mango_charges
        dst.mango_left = m_max(0, src.mango_charges)
    else
        dst.mango_charges = nil
        dst.mango_left = (src.mango and not src.mango_used) and 1 or 0
    end
    dst.mango = dst.mango_left > 0
    dst.faerie = src.faerie and true or false
    dst.faerie_used = false
    dst.stick_used = false
    dst.mango_used = (dst.mango_left <= 0)
    dst.hp_taken = 0
    dst.died_at = nil
    dst.razes_cast = 0
    dst.last_volley_at = nil
    dst.last_raze_hit_at = nil
    dst.hit_by_raze = 0
    dst.raze_missed = 0
    dst.tower_hits = 0
    return dst
end

--------------------------------------------------------------------------------
-- readiness
--------------------------------------------------------------------------------
local function unit_mango_count(u)
    if not u then return 0 end
    if type(u.mango_left) == "number" then return m_max(0, u.mango_left) end
    if type(u.mango_charges) == "number" then return m_max(0, u.mango_charges) end
    return (u.mango and not u.mango_used) and 1 or 0
end

local function war_affordable(u, _now)
    local mana = u.mana or 0
    if not u.stick_used then mana = mana + (u.stick_charges or 0) * 15 end
    mana = mana + unit_mango_count(u) * 100
    return m_floor((mana + (u.regen_mana or 0) * 1.0) / C_RAZE_MANA)
end
WAR.Affordable = war_affordable

local function war_ready_count(u, now)
    local rr = u.raze_ready
    local n = ((rr[1] or 0) <= now and 1 or 0)
        + ((rr[2] or 0) <= now and 1 or 0)
        + ((rr[3] or 0) <= now and 1 or 0)
    local budget = war_affordable(u, now)
    if n > budget then n = budget end
    return n
end
WAR.ReadyCount = war_ready_count

function WAR.ReadyLabels(u, now, horizon)
    local out = {}
    local lim = now + (horizon or 0)
    for i = 1, 3 do
        if (u.raze_ready[i] or 0) <= lim then out[#out + 1] = i end
    end
    return out
end

local function war_burst(attacker, victim, horizon, now, opts)
    local lvl = attacker and attacker.raze_level or 0
    if lvl <= 0 then return 0, 0 end
    now = now or 0
    local lim = now + horizon
    local rr = attacker.raze_ready
    local n = ((rr[1] or 0) <= lim and 1 or 0)
        + ((rr[2] or 0) <= lim and 1 or 0)
        + ((rr[3] or 0) <= lim and 1 or 0)
    local budget = war_affordable(attacker, now)
    if budget < n then n = budget end
    if n > 3 then n = 3 end
    if opts and opts.max and n > opts.max then n = opts.max end
    if not victim or n <= 0 then return 0, n end
    local total, st = 0, victim.stacks or 0
    local mr = victim.magic_resist or C_MAGIC_RESIST
    local spellAmp = attacker.spell_amp or 1.0
    local souls = attacker.souls
    local stTal = attacker.stack_talent
    local firstBlock = (not victim.raindrop_used) and (victim.magic_block or 0) or 0
    for i = 1, n do
        local blk = (i == 1) and firstBlock or 0
        total = total + raze_applied_fast(lvl, st, souls, mr, stTal, spellAmp, blk)
        if st < C_MAX_STACKS then st = st + 1 end
    end
    return total, n
end
WAR.Burst = war_burst

--------------------------------------------------------------------------------
-- aiming & step simulation
--------------------------------------------------------------------------------
local QUALITY_RANK = { poor = 0, solid = 1, lock = 2, clean = 3 }

local function war_find_shot(u, foe, now, minQuality)
    if (u.raze_level or 0) <= 0 or not foe or not foe.alive then return nil end
    local effMana = (u.mana or 0) + unit_mango_count(u) * 100
        + ((not u.stick_used) and ((u.stick_charges or 0) * 15) or 0)
    if effMana < C_RAZE_MANA then return nil end

    local atkU = foe.atk_until
    local cstU = foe.cast_until
    local locked = (atkU and atkU > now) or (cstU and cstU > now)
    local lockTime = 0
    if atkU and atkU > now then lockTime = atkU - now end
    if cstU and cstU > now and (cstU - now) > lockTime then lockTime = cstU - now end
    local fms = foe.ms or 305
    local escape = locked and m_max(0, fms * m_max(0, C_RAZE_CAST - lockTime))
                           or (fms * C_RAZE_CAST)

    local tx = foe.x + (foe.vx or 0) * C_RAZE_CAST
    local ty = foe.y + (foe.vy or 0) * C_RAZE_CAST
    local dx, dy = u.x - tx, u.y - ty
    local dd = m_sqrt(dx * dx + dy * dy)

    local best, bestSlack = nil, -1e9
    local rr = u.raze_ready
    local radSlackBase = (C_RAZE_HERO_RADIUS - 18) - escape
    if (rr[1] or 0) <= now then
        local s1 = radSlackBase - m_abs(dd - C_RAZE_DIST_1)
        if s1 > bestSlack then best, bestSlack = 1, s1 end
    end
    if (rr[2] or 0) <= now then
        local s2 = radSlackBase - m_abs(dd - C_RAZE_DIST_2)
        if s2 > bestSlack then best, bestSlack = 2, s2 end
    end
    if (rr[3] or 0) <= now then
        local s3 = radSlackBase - m_abs(dd - C_RAZE_DIST_3)
        if s3 > bestSlack then best, bestSlack = 3, s3 end
    end
    if not best then return nil end
    local quality = "poor"
    if locked and bestSlack > -180 then quality = "lock" end
    if bestSlack >= 0 then quality = locked and "lock" or "solid" end
    if bestSlack >= 60 then quality = "clean" end
    minQuality = minQuality or "solid"
    if QUALITY_RANK[quality] < QUALITY_RANK[minQuality] then return nil, bestSlack, quality end
    return best, bestSlack, quality
end
WAR.FindShot = war_find_shot

local function start_attack(u, tgt, now)
    local d = distance(u.x, u.y, tgt.x, tgt.y)
    if d > (u.atk_range or C.ATK_RANGE) + 25 then return false end
    if u.atk_ready > now or u.cast_until > now then return false end
    if u.pending_attack then return false end
    u.atk_until = now + C.ATK_POINT
    u.pending_attack = {
        t = now + C.ATK_POINT, dmg = u.dmg, target = tgt,
        ready = now + m_max(0.85, C.BAT * 0.78),
    }
    return true
end

local function resolve_pending_attack(u, now)
    local a = u.pending_attack
    if not a or a.t > now then return end
    u.pending_attack = nil
    u.atk_ready = a.ready
    local t = a.target
    if not t or not t.alive then return end
    local d = distance(u.x, u.y, t.x, t.y)
    u.proj[#u.proj + 1] = { t = now + d / C.PROJ_SPEED, dmg = a.dmg, target = t }
end

local function cancel_attack(u)
    if u.pending_attack then
        u.pending_attack = nil
        u.atk_until = -1
        return true
    end
    return false
end

local function apply_projectiles(u, now)
    local proj = u.proj
    local n = #proj
    if n == 0 then return end
    local w = 0
    for i = 1, n do
        local p = proj[i]
        if p.t <= now then
            apply_damage(p.target, p.dmg, now)
        else
            w = w + 1
            proj[w] = p
        end
    end
    for i = w + 1, n do
        proj[i] = nil
    end
end

local function resolve_raze(u, now)
    local p = u.pending_raze
    if not p or p.t > now then return end
    u.pending_raze = nil
    local tgt = p.target
    if not tgt or not tgt.alive then return end
    local d = C.RAZE_DIST[p.idx]
    local cx = u.x + m_cos(u.facing) * d
    local cy = u.y + m_sin(u.facing) * d
    if distance(cx, cy, tgt.x, tgt.y) <= C.RAZE_HERO_RADIUS then
        local appliedDmg = p.dmg
        if (tgt.magic_block or 0) > 0 and not tgt.raindrop_used and (p.raw_dmg or 100) >= 75 then
            local mr = tgt.magic_resist or C.MAGIC_RESIST
            local reducedRaw = m_max(0, (p.raw_dmg or (appliedDmg / m_max(0.05, 1.0 - mr))) - tgt.magic_block)
            appliedDmg = reducedRaw * (1.0 - mr)
            tgt.raindrop_used = true
        end
        apply_damage(tgt, appliedDmg, now)
        tgt.stacks = m_min(C.MAX_STACKS, (tgt.stacks or 0) + 1)
        tgt.stack_t = now
        tgt.last_raze_hit_at = now
        tgt.hit_by_raze = (tgt.hit_by_raze or 0) + 1
    else
        u.raze_missed = (u.raze_missed or 0) + 1
    end
end

local function step_toward(u, gx, gy, dt, now)
    if not u.alive then return end
    if u.cast_until > now then return end
    if u.atk_until and u.atk_until > now then return end
    local d = distance(u.x, u.y, gx, gy)
    if d < 2 then return end
    local step = m_min(d, u.ms * dt)
    local nx, ny = (gx - u.x) / d, (gy - u.y) / d
    u.x = u.x + nx * step
    u.y = u.y + ny * step
    u.vx, u.vy = nx * u.ms, ny * u.ms
    if u.atk_until <= now then u.facing = m_atan2(ny, nx) end
end

local function control(u, foe, plan, now, dt)
    if not u.alive then return "dead" end

    local hold = plan.hold_dist or 440
    local pol = plan.raze_policy or "none"
    local attackOn = plan.attack ~= false
    if plan.adaptive and foe and foe.alive then
        local foeEff = foe.hp + ((foe.faerie and not foe.faerie_used) and 85 or 0)
        local myEff = u.hp + ((u.faerie and not u.faerie_used) and 85 or 0)
        local canFinish = (war_burst(u, foe, 1.6, now) + u.dmg * 2) >= foeEff
        local inDanger = (war_burst(foe, u, 1.6, now) + foe.dmg * 2) >= myEff
        if canFinish then
            hold = m_min(hold, 260)
            pol = "burst"
            attackOn = true
        elseif inDanger and plan.punish_danger ~= false then
            hold = m_max(hold, 620)
        end
    end

    if u.cast_until > now then
        if u.aim_x and u.aim_y then
            local want = m_atan2(u.aim_y - u.y, u.aim_x - u.x)
            local diff = want - u.facing
            while diff > m_pi do diff = diff - 2 * m_pi end
            while diff < -m_pi do diff = diff + 2 * m_pi end
            local maxTurn = C_TURN_RATE * dt
            u.facing = u.facing + clamp(diff, -maxTurn, maxTurn)
        end
        return "casting"
    end

    local d = 1e9
    if foe and foe.alive then
        local dx, dy = u.x - foe.x, u.y - foe.y
        d = m_sqrt(dx * dx + dy * dy)
    end

    if plan.dodge ~= false and foe and foe.alive and foe.cast_until > now and foe.cast_label then
        local bandD = C_RAZE_DIST[foe.cast_label] or 450
        local cx = foe.x + m_cos(foe.facing) * bandD
        local cy = foe.y + m_sin(foe.facing) * bandD
        local rx, ry = u.x - cx, u.y - cy
        local dcSq = rx * rx + ry * ry
        if dcSq <= C_DODGE_RAD_SQ then
            if plan.cancel_dodge ~= false then cancel_attack(u) end
            local rl = m_sqrt(dcSq)
            if rl < 1e-3 then rx, ry, rl = 1, 0, 1 end
            step_toward(u, u.x + (rx / rl) * 195, u.y + (ry / rl) * 195, dt, now)
            return "dodge"
        end
    end

    local want, quality = false, nil
    if pol == "burst" then
        want, quality = true, (plan.raze_quality or "solid")
    elseif pol == "single" then
        want, quality = (now - (u.last_volley_at or -1e9) > 2.0), (plan.raze_quality or "solid")
    elseif pol == "trade" then
        local hisReady = (foe and war_ready_count(foe, now)) or 0
        local myBurst = war_burst(u, foe, 2.2, now)
        local hisBurst = foe and war_burst(foe, u, 2.2, now) or 0
        want = (hisReady == 0)
            or (myBurst >= 0.85 * hisBurst and myBurst > 0)
            or (foe and foe.hp < (plan.finish_hp or 260))
        if foe and foe.cast_until and foe.cast_until > now then want = true end
        quality = (hisReady == 0) and (plan.raze_quality or "solid") or "poor"
    elseif pol == "lethal" then
        want = foe and (war_burst(u, foe, 1.8, now) >= foe.hp + 25)
        quality = "poor"
    elseif pol == "answer" then
        want = (foe and foe.last_raze_hit_at and now - foe.last_raze_hit_at <= 0.7) or false
        quality = "poor"
    end
    if want and foe and foe.alive then
        local idx = war_find_shot(u, foe, now, quality)
        if idx then
            while u.mana < C_RAZE_MANA and unit_mango_count(u) > 0 do
                u.mana = u.mana + 100
                u.mango_left = unit_mango_count(u) - 1
                u.mango_used = (u.mango_left <= 0)
                u.mango = (u.mango_left > 0)
            end
            if u.mana < C_RAZE_MANA and (u.stick_charges or 0) > 0 and not u.stick_used then
                local g = u.stick_charges * 15
                u.mana = u.mana + g
                u.hp = m_min(u.hp_max, u.hp + g)
                u.stick_used = true
            end
            if u.mana >= C_RAZE_MANA then
                local stacks = foe.stacks or 0
                local rawDmg = raze_raw_fast(u.raze_level, stacks, u.souls, u.stack_talent, u.spell_amp)
                local dmg = raze_applied_fast(u.raze_level, stacks, u.souls, foe.magic_resist, u.stack_talent, u.spell_amp, 0)
                u.mana = u.mana - C_RAZE_MANA
                u.raze_ready[idx] = now + C_RAZE_CD
                u.cast_until = now + C_RAZE_CAST
                u.cast_label = idx
                u.razes_cast = (u.razes_cast or 0) + 1
                u.last_volley_at = now
                u.aim_x = foe.x + (foe.vx or 0) * C_RAZE_CAST
                u.aim_y = foe.y + (foe.vy or 0) * C_RAZE_CAST
                u.pending_raze = { t = now + C_RAZE_CAST, idx = idx, dmg = dmg, raw_dmg = rawDmg, target = foe }
                return "raze"
            end
        end
    end

    if plan.flee then
        step_toward(u, plan.flee_x or u.x, plan.flee_y or u.y, dt, now)
        return "flee"
    end
    if foe and foe.alive then
        if plan.engage ~= false then
            if d > hold + 45 then
                local k = (d - hold) / d
                step_toward(u, u.x + (foe.x - u.x) * k, u.y + (foe.y - u.y) * k, dt, now)
            elseif d < hold - 120 then
                local k = (hold - d) / d
                step_toward(u, u.x - (foe.x - u.x) * k, u.y - (foe.y - u.y) * k, dt, now)
            end
        end
        if attackOn and d <= (u.atk_range or C.ATK_RANGE) + 25 and u.atk_until <= now then
            if start_attack(u, foe, now) then return "attack" end
        end
    end
    return "hold"
end

local SIM_Q_ME = {}
local SIM_Q_HIM = {}

local function queue_tower_shot(q, fire_t, dmg, dist, wu, ps)
    q[#q + 1] = {
        t = fire_t + (wu or C.TOWER_WINDUP) + dist / m_max(1, ps or C.TOWER_PROJECTILE),
        dmg = dmg,
    }
end

local function apply_tower_shots(q, t, victim)
    local n = #q
    if n == 0 then return end
    local w = 0
    for i = 1, n do
        local e = q[i]
        if e.t <= t then
            if victim.alive then
                victim.tower_hits = (victim.tower_hits or 0) + 1
                apply_damage(victim, e.dmg, t)
            end
        else
            w = w + 1
            q[w] = e
        end
    end
    for i = w + 1, n do
        q[i] = nil
    end
end

function WAR.Simulate(state, myPlan, hisPlan, horizon)
    horizon = horizon or C.HORIZON
    local t0 = state.t or 0
    local me = reset_sim_unit(SIM_ME, state.me)
    local him = reset_sim_unit(SIM_HIM, state.him)
    if state.me_stacks then me.stacks = state.me_stacks; me.stack_t = t0 end
    if state.him_stacks then him.stacks = state.him_stacks; him.stack_t = t0 end

    if (me.incoming or 0) > 0 then
        him.proj[#him.proj + 1] = { t = t0 + (me.incoming_at or C.INCOMING_LAND), dmg = me.incoming, target = me }
    end
    if (him.incoming or 0) > 0 then
        me.proj[#me.proj + 1] = { t = t0 + (him.incoming_at or C.INCOMING_LAND), dmg = him.incoming, target = him }
    end

    local mp = myPlan or {}
    local hp = hisPlan or {}
    local tower = state.tower
    local ownTower = state.own_tower
    local me0, him0 = me.hp, him.hp

    local dt = state.dt or C.DT
    local steps = m_floor(horizon / dt + 0.5)
    local aggroMe, aggroHim = false, false
    local windup = (tower and tower.windup) or C.TOWER_WINDUP
    local projSpeed = (tower and tower.proj_speed) or C.TOWER_PROJECTILE
    local ownWindup = (ownTower and ownTower.windup) or C.TOWER_WINDUP
    local ownProjSpeed = (ownTower and ownTower.proj_speed) or C.TOWER_PROJECTILE
    local qMe, qHim = SIM_Q_ME, SIM_Q_HIM
    for i = #qMe, 1, -1 do qMe[i] = nil end
    for i = #qHim, 1, -1 do qHim[i] = nil end

    local tFirst = (tower and tower.next_shot) or C.TOWER_FIRST
    local nextMe, nextHim = t0 + tFirst, t0 + C.TOWER_FIRST
    local waveAggroUntil = -1
    local aggroCdUntil = state.my_aggro_cd_until or 0
    local t = t0

    local enemyWave = state.enemy_wave
    local nWave = enemyWave and #enemyWave or 0
    local meAtkTrigSq = ((me.atk_range or C_ATK_RANGE) + 35) ^ 2

    for i = 0, steps do
        t = t0 + i * dt
        if me.alive then me.hp = m_min(me.hp_max, me.hp + me.regen_hp * dt) end
        if him.alive then him.hp = m_min(him.hp_max, him.hp + him.regen_hp * dt) end

        if me.alive and him.alive then
            control(me, him, mp, t, dt)
            control(him, me, hp, t, dt)
            if nWave > 0 and mp.attack then
                local hdx, hdy = me.x - him.x, me.y - him.y
                if (hdx * hdx + hdy * hdy) <= meAtkTrigSq and t >= aggroCdUntil then
                    for w = 1, nWave do
                        local cw = enemyWave[w]
                        local cdx, cdy = me.x - cw.x, me.y - cw.y
                        if (cdx * cdx + cdy * cdy) <= 250000 then
                            waveAggroUntil = m_max(waveAggroUntil, t + 2.3)
                            aggroCdUntil = t + 3.0
                            break
                        end
                    end
                end
            end
        elseif me.alive then
            if mp.flee then step_toward(me, mp.flee_x or me.x, mp.flee_y or me.y, dt, t) end
        elseif him.alive then
            if hp.flee then step_toward(him, hp.flee_x or him.x, hp.flee_y or him.y, dt, t) end
        end

        apply_tower_shots(qMe, t, me)
        apply_tower_shots(qHim, t, him)
        resolve_pending_attack(me, t)
        resolve_pending_attack(him, t)
        resolve_raze(me, t)
        resolve_raze(him, t)
        apply_projectiles(me, t)
        apply_projectiles(him, t)

        if t - me.stack_t > C_STACK_DURATION then me.stacks = 0 end
        if t - him.stack_t > C_STACK_DURATION then him.stacks = 0 end

        if me.alive then
            if nWave > 0 then
                local dynWaveDps = 0
                local chaseActive = (waveAggroUntil > t)
                local chaseExtra = chaseActive and (315 * m_min(1.4, m_max(0, t - t0))) or 0
                local mpEngage = mp.engage
                for w = 1, nWave do
                    local cw = enemyWave[w]
                    local cdx, cdy = me.x - cw.x, me.y - cw.y
                    local dcSq = cdx * cdx + cdy * cdy
                    local reach = (cw.range or 100) + 45
                    if cw.aggro_me and dcSq <= (reach + 260) * (reach + 260) then
                        dynWaveDps = dynWaveDps + cw.dps
                    elseif chaseActive and dcSq <= (reach + chaseExtra) * (reach + chaseExtra) then
                        dynWaveDps = dynWaveDps + cw.dps
                    elseif mpEngage then
                        local r3 = m_min(reach, 155)
                        if dcSq <= r3 * r3 then dynWaveDps = dynWaveDps + cw.dps * 0.65 end
                    end
                end
                if dynWaveDps > 0 then apply_damage(me, dynWaveDps * dt, t) end
            elseif (state.creep_dps_on_me or 0) > 0 then
                apply_damage(me, state.creep_dps_on_me * dt, t)
            end
        end
        if him.alive and (state.creep_dps_on_him or 0) > 0 then
            apply_damage(him, state.creep_dps_on_him * dt, t)
        end

        if tower and me.alive then
            local d = distance(me.x, me.y, tower.x, tower.y)
            if tower.aggro_me then aggroMe = true end
            if d <= (tower.range or C.TOWER_RANGE) then aggroMe = true end
            if aggroMe and d > C.TOWER_LEASH then aggroMe = false end
            if aggroMe and t >= nextMe then
                nextMe = t + (tower.interval or C.TOWER_INTERVAL)
                queue_tower_shot(qMe, t, (tower.dmg or C.TOWER_DMG), d, windup, projSpeed)
            end
        end
        if ownTower and him.alive then
            local d = distance(him.x, him.y, ownTower.x, ownTower.y)
            if ownTower.aggro_me then aggroHim = true end
            if d <= (ownTower.range or C.TOWER_RANGE) then aggroHim = true end
            if aggroHim and t >= nextHim then
                nextHim = t + (ownTower.interval or C.TOWER_INTERVAL)
                queue_tower_shot(qHim, t, (ownTower.dmg or C.TOWER_DMG), d, ownWindup, ownProjSpeed)
            end
        end

        if not me.alive or not him.alive then
            for j = i + 1, steps do
                t = t0 + j * dt
                if me.alive and mp.flee then step_toward(me, mp.flee_x or me.x, mp.flee_y or me.y, dt, t) end
                if him.alive and hp.flee then step_toward(him, hp.flee_x or him.x, hp.flee_y or him.y, dt, t) end
                if tower and me.alive then
                    local d = distance(me.x, me.y, tower.x, tower.y)
                    if tower.aggro_me then aggroMe = true end
                    if d <= (tower.range or C.TOWER_RANGE) then aggroMe = true end
                    if aggroMe and d > C.TOWER_LEASH then aggroMe = false end
                    if aggroMe and t >= nextMe then
                        nextMe = t + (tower.interval or C.TOWER_INTERVAL)
                        queue_tower_shot(qMe, t, (tower.dmg or C.TOWER_DMG), d, windup, projSpeed)
                    end
                    apply_tower_shots(qMe, t, me)
                    if not me.alive then break end
                end
            end
            break
        end
    end

    local res = {
        my_hp = me.hp, his_hp = him.hp,
        my_dead = not me.alive, his_dead = not him.alive,
        dealt = him0 - him.hp,
        taken = me0 - me.hp,
        mana_left = me.mana,
        razes_cast = me.razes_cast or 0,
        my_x = me.x, my_y = me.y,
        his_x = him.x, his_y = him.y,
        t_end = t,
        horizon = horizon,
        tower_hits_taken = me.tower_hits or 0,
    }
    res.net = res.dealt - res.taken
    return res
end

--------------------------------------------------------------------------------
-- plan generation & minimax evaluation
--------------------------------------------------------------------------------
local DEFAULT_MY_HOLD_PLANS = {
    { name = "hold500_none",  hold_dist = 500, raze_policy = "none",  engage = true, attack = true },
    { name = "hold500_trade", hold_dist = 500, raze_policy = "trade", engage = true, attack = true },
    { name = "hold500_burst", hold_dist = 500, raze_policy = "burst", engage = true, attack = true },
    { name = "hold700_none",  hold_dist = 700, raze_policy = "none",  engage = true, attack = true },
    { name = "hold700_trade", hold_dist = 700, raze_policy = "trade", engage = true, attack = true },
    { name = "hold700_burst", hold_dist = 700, raze_policy = "burst", engage = true, attack = true },
    { name = "hold260_none",  hold_dist = 260, raze_policy = "none",  engage = true, attack = true },
    { name = "hold260_trade", hold_dist = 260, raze_policy = "trade", engage = true, attack = true },
    { name = "hold260_burst", hold_dist = 260, raze_policy = "burst", engage = true, attack = true },
}

local DEFAULT_HIS_BASE_PLANS = {
    { name = "aggressive", hold_dist = 320, raze_policy = "burst", engage = true, attack = true, adaptive = true },
    { name = "reactive",   hold_dist = 440, raze_policy = "trade", engage = true, attack = true,
      adaptive = true, cancel_dodge = true, raze_quality = "lock" },
    { name = "passive",    hold_dist = 700, raze_policy = "none",  engage = false, attack = true },
}

function WAR.MyPlans(_state, opts)
    opts = opts or {}
    local plans = {}
    -- Order `500, 700, 260` + `"none", "trade", "burst"` so equal-utility ties (e.g. 0 razes / OOM!)
    -- ALWAYS resolve to `hold500_none` (`HOLD` at max attack range) instead of `hold250_burst` (`W2 02:28` fix)!
    if not opts.holds and not opts.pols then
        for i = 1, 9 do plans[i] = DEFAULT_MY_HOLD_PLANS[i] end
    else
        local holds = opts.holds or { 500, 700, 260 }
        local pols = opts.pols or { "none", "trade", "burst" }
        for _, h in ipairs(holds) do
            for _, p in ipairs(pols) do
                plans[#plans + 1] = {
                    name = string.format("hold%d_%s", h, p),
                    hold_dist = h, raze_policy = p, engage = true, attack = true,
                }
            end
        end
    end
    if opts.flee_points then
        for i, fp in ipairs(opts.flee_points) do
            plans[#plans + 1] = {
                name = "flee" .. i, flee = true, flee_x = fp.x, flee_y = fp.y,
                raze_policy = opts.flee_pol or "lethal", attack = false, engage = false,
            }
        end
    end
    return plans
end

function WAR.HisPlans(state, opts)
    opts = opts or {}
    local plans = {
        DEFAULT_HIS_BASE_PLANS[1],
        DEFAULT_HIS_BASE_PLANS[2],
        DEFAULT_HIS_BASE_PLANS[3],
    }
    local hf = opts.his_flee or state.his_flee
    if hf then
        plans[4] = {
            name = "retreat_tower", flee = true, flee_x = hf.x, flee_y = hf.y,
            attack = false, engage = false, raze_policy = "lethal",
        }
    end
    return plans
end

local function utility(state, res)
    local me, him = state.me, state.him
    local u = 0
    if res.my_dead then
        u = u - C.DEATH_COST
    elseif res.my_hp < C.SAFE_HP_ABS then
        u = u - (C.SAFE_HP_ABS - res.my_hp) * 1.35
    end
    if res.his_dead then u = u + C.KILL_BONUS end
    u = u + C.W_HP * ((him.hp - res.his_hp) - (me.hp - res.my_hp))
    u = u + C.W_MANA * (res.mana_left - me.mana)
    local mePct = res.my_hp / m_max(1, me.hp_max)
    local himTrueMax = m_max(1, him.true_hp_max or him.hp_max)
    local himScale = himTrueMax / m_max(1, him.hp_max)
    local himPct = (res.his_hp * himScale) / himTrueMax
    u = u + C.W_STAND * (mePct - himPct) * m_max(me.hp_max, himTrueMax)
    return u
end
WAR.Utility = utility

function WAR.Evaluate(state, opts)
    opts = opts or {}
    local myPlans = WAR.MyPlans(state, opts)
    local hisPlans = WAR.HisPlans(state, opts)
    local horizon = opts.horizon or C.HORIZON
    state.dt = opts.dt or C.DT
    local nHis = #hisPlans

    -- Check if `state.me` is mathematically incapable of casting ANY Shadowraze over `[0, horizon]`
    -- (`raze_level <= 0` OR max mana over `horizon` `< 75` OR all 3 coils on CD `> horizon`):
    -- When true, `"trade"` and `"burst"` on the exact same `hold_dist` produce bit-for-bit identical
    -- simulation trajectories to `"none"`!
    local me = state.me
    local meMaxMana = (me.mana or 0) + m_max(0, me.regen_mana or 0) * horizon
        + ((me.stick_charges or 0) * 15)
        + ((type(me.mango_charges) == "number" and m_max(0, me.mango_charges) or (me.mango and 1 or 0)) * 100)
    local rr = me.raze_ready or {}
    local tEnd = (state.now or 0) + horizon
    local anyRazeOffCd = ((rr[1] or 0) <= tEnd) or ((rr[2] or 0) <= tEnd) or ((rr[3] or 0) <= tEnd)
    local meCannotRaze = ((me.raze_level or 0) <= 0) or (meMaxMana < C.RAZE_MANA) or (not anyRazeOffCd)

    local scored = {}
    local bestSafe = nil
    local lastNoneEntryByHold = nil
    if meCannotRaze then lastNoneEntryByHold = {} end

    for _, mp in ipairs(myPlans) do
        local reused = (meCannotRaze and not mp.flee and mp.hold_dist and mp.raze_policy ~= "none")
            and lastNoneEntryByHold[mp.hold_dist] or nil
        if reused then
            scored[#scored + 1] = {
                plan = mp,
                worstUtil = reused.worstUtil,
                avgUtil = reused.avgUtil,
                worst = reused.worst,
                dieCount = reused.dieCount,
                dieProb = reused.dieProb,
                killAll = reused.killAll,
                pruned = reused.pruned,
            }
        else
            local worst, sum, n = nil, 0, 0
            local worstUtil = 1e18
            local dieCount = 0
            local killAll = true
            local pruned = false
            local alpha = bestSafe and bestSafe.worstUtil or nil
            local isNonePol = (mp.raze_policy == "none")

            for j = 1, nHis do
                local r = WAR.Simulate(state, mp, hisPlans[j], horizon)
                local u = utility(state, r)
                sum = sum + u; n = n + 1
                if u < worstUtil then worstUtil = u; worst = r end
                if r.my_dead then dieCount = dieCount + 1 end
                if not r.his_dead then killAll = false end

                -- Exact Minimax Alpha-Beta Cutoff (100.000% result-preserving!):
                -- Once at least one `dieCount == 0` plan (`bestSafe`) has been found:
                --   (a) any subsequent plan with `dieCount > 0` can NEVER be `KILL`, NEVER beat `bestSafe`,
                --       and `not bestSafe` fallback is unreachable -> prune remaining `hisPlans`!
                --   (b) any non-`"none"` plan with `killAll == false` and `worstUtil <= alpha` can NEVER be
                --       `KILL` and its final `min` utility is `<= alpha` (strict `>` needed to beat `bestSafe`) -> prune!
                if alpha ~= nil and j < nHis then
                    if dieCount > 0 then
                        pruned = true
                        break
                    elseif (not isNonePol) and (not killAll) and (worstUtil <= alpha) then
                        pruned = true
                        break
                    end
                end
            end

            --Guaranteed Kill early-exit (`first plan in myPlans order with dieCount == 0 and killAll`)!
            if (not pruned) and dieCount == 0 and killAll then
                return {
                    mode = "KILL", plan = mp, ev = worst,
                    worst = worst, score = worstUtil,
                    why = "guaranteed kill under every enemy response",
                }
            end

            local entry = {
                plan = mp,
                worstUtil = worstUtil,
                avgUtil = sum / n,
                worst = worst,
                dieCount = dieCount,
                dieProb = dieCount / n,
                killAll = (not pruned) and killAll or false,
                pruned = pruned,
            }
            scored[#scored + 1] = entry
            if (not pruned) and dieCount == 0 and (not bestSafe or worstUtil > bestSafe.worstUtil) then
                bestSafe = entry
            end
            if meCannotRaze and isNonePol and not mp.flee and mp.hold_dist then
                lastNoneEntryByHold[mp.hold_dist] = entry
            end
        end
    end

    if not bestSafe then
        local lowest = 1
        for _, s in ipairs(scored) do if s.dieProb < lowest then lowest = s.dieProb end end
        local cand
        for _, s in ipairs(scored) do
            if s.dieProb <= lowest + 1e-9 and (not cand or s.worstUtil > cand.worstUtil) then cand = s end
        end
        if cand and cand.dieProb > 0 then
            return {
                mode = "ESCAPE", plan = cand.plan, ev = cand.worst, worst = cand.worst,
                score = cand.worstUtil, danger = true,
                why = "every plan risks death: minimise loss",
            }
        end
    end

    local s = bestSafe
    local mode = "HOLD"
    -- NEVER emit `TRADE` on a plan that casts 0 Razes (`W2 02:28` dry-mana 6 MP suicide fix!):
    if (s.plan.raze_policy == "burst" or s.plan.raze_policy == "trade" or s.plan.raze_policy == "lethal")
        and (s.worst.razes_cast or 0) > 0 then
        mode = "TRADE"
    end
    if s.plan.flee then mode = "ESCAPE" end

    if mode == "TRADE" and (s.worst.his_hp - s.worst.my_hp) <= 0 and (s.worst.net or 0) <= 0 then
        for _, c in ipairs(scored) do
            if c.dieCount == 0 and c.plan.raze_policy == "none" and c.worstUtil > s.worstUtil then
                s = c; mode = "HOLD"; break
            end
        end
    end

    return {
        mode = mode, plan = s.plan, ev = s.worst, worst = s.worst,
        avg = s.avgUtil, score = s.worstUtil,
        why = "best worst-case safe plan",
    }
end

function WAR.SelfTest()
    local fails = {}
    local function check(name, got, want, tol)
        tol = tol or 1e-6
        if m_abs(got - want) > tol then
            fails[#fails + 1] = string.format("%s: got %.3f want %.3f", name, got, want)
        end
    end
    -- Patch 7.41f: L1 base 85 * 0.75 = 63.75
    check("raze L1 base 7.41f", WAR.RazeApplied(1, 0, 0, 0.25), 63.75)
    -- Patch 7.41f: L4 base 280 + 2*80 + 10*2 = 460 * 0.75 = 345.0
    check("raze L4 stacked 7.41f", WAR.RazeApplied(4, 2, 10, 0.25), 345.0)
    -- Patch 7.41f: volley of 3 at L3 (215/65), 8 souls (+16): (231 + 296 + 361) * 0.75 = 666.0
    check("volley3 7.41f", WAR.VolleyDamage(3, 0, 8, 3, 0.25), 666.0)
    return #fails == 0, fails
end

return WAR
