--[[
================================================================================
 WAR DIRECTOR v2.0 — Unified Single-Authority Bridge (Zero Jitter / Zero Conflict)
================================================================================
 Connects `WAR CORE` (7.41f forward simulation), `ENGINE TRUTH` (live ranges/aggro/
 incoming projectiles), and `EXCHANGE` (cast-lock & 2.2s trade arithmetic) into
 `bot_nevermore.lua` WITHOUT conflicting with Sacred CS, Salve, or Laning Spacing:

   1. NO `POKE` bang-bang oscillator (`9068560663.dem` 40 reversals & 6 CS fix):
      `REFUSE` records `D.State.refuseTradeUntil` (suppressing bad voluntary trade
      initiations) and yields positioning to the single Laning/CS controller.
   2. Split priority entry points:
      - `ExecuteKillOrCastLockOnly`: runs pre-CS strictly for guaranteed `KILL` or
        0.55s pinned enemy cast-lock `PUNISH` / `ANSWER`.
      - `ExecuteTactical`: runs post-Salve & post-`RunSacredCS` for `TRADE`, `BRAWL`,
        and Schmitt-hysteresis `ESCAPE` (releasing cleanly once `dist >= 990u`).
   3. During `ESCAPE`, radial Raze-dodge (`STEP`) and zero-turn defensive Snap-Raze
      remain ACTIVE (`9068560663.dem` 03:17–03:19 triple-coil fix).
   4. `Faerie Fire` (+85 HP), `Stick/Wand` charges, `Mango`, and live `debuff stacks`
      are fed into both `WAR` and `XCH` (`9068560663.dem` 01:53 54-HP kill fix).
================================================================================
]]

local WAR = require("bots/nevermore/war_core")
local ET  = require("bots/nevermore/engine_truth")
local XCH = require("bots/nevermore/exchange")
local U   = require("bots/nevermore/utils")

local D = {}

D.CFG = {
    ENABLED           = true,
    EVAL_INTERVAL     = 0.12,
    MAX_DIST          = 1250, -- Never hijack ticks when enemy is far out of combat reach!
    SEARCH_DT         = 1.0 / 20.0,
    SEARCH_HORIZON    = 2.6,
    LOW_HP_PCT        = 0.30,
    RECOVER_BURST_PAD = 55,
    RECOVER_HP_PCT    = 0.30,
    RECOVER_HP_GAP    = 0.18,
    RECOVER_HOLD      = 2.0,
    ESCAPE_ENTER_DIST = 760,  -- Trigger ESCAPE inside real W/attack threat (< 760u, immune to 820..1050u far-edge bait!)
    RELEASE_DIST      = 950,  -- Release cleanly at 950u (outside Low-HP 860u floor -> ZERO cross-system oscillation!)
    RELEASE_HP_PCT    = 0.46,
    TOWER_PAD         = 868,
    ENGINE_TRUTH      = true,
    INCOMING_MAX_LAND = 0.45,
    PROBE_TOWER_AGGRO = false,
    EXCHANGE_GATE     = true,
    EXCHANGE_LOG      = false,
    DEBUG             = false,
}

local S = {
    lastEval = -100,
    last = nil,
    lastSig = "",
    evalCount = 0,
    mode = nil,
    escapeUntil = 0,
    refuseTradeUntil = -100,
}

local function unit_dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function norm(x, y)
    local l = math.sqrt(x * x + y * y)
    if l < 1e-6 then return 0, 0 end
    return x / l, y / l
end

--[[ KV-exact aggregate creep DPS + per-creep wave geometry against `victim` at `loc`
     (Patch 7.41f: Runty melee 0.75 vs Hero, Piercing ranged 0.50 vs Hero, scaled by armor,
      plus Source 2 `500u` Type 1 protective creep aggro!). ]]--
local function creep_dps_and_wave(creeps, loc, victim, includePreAggro, buildWave)
    if not creeps or not loc then return 0, nil end
    local KC = WAR.C.CREEP
    local armor = 0
    if victim and victim.GetPhysicalArmorValue then
        local ok, a = pcall(victim.GetPhysicalArmorValue, victim)
        if ok and type(a) == "number" then armor = a end
    end
    local mult = ET.ArmorFactor(armor)
    local dps = 0
    local wave = buildWave and {} or nil
    local pad = KC.HULL_PAD or 45
    for _, c in pairs(creeps) do
        if c and c.GetLocation and c:IsAlive() then
            local okL, cLoc = pcall(c.GetLocation, c)
            if okL and cLoc then
                local nm = (c.GetUnitName and c:GetUnitName()) or ""
                local kind, classVsHero = "melee", 0.75
                if nm:find("siege") or nm:find("catapult") then
                    kind, classVsHero = "siege", 0.75
                elseif nm:find("ranged") then
                    kind, classVsHero = "ranged", 0.50
                elseif nm:find("flag") then
                    kind, classVsHero = "flag", 0.75
                end
                local kv = KC[kind] or KC.melee
                local cRange = kv.range or 100
                local reach = cRange + pad
                local unitDps = (kv.dmg or 21) * classVsHero * mult / math.max(0.3, kv.bat or 1.0)
                local dc = unit_dist(cLoc, loc)
                local lockedOnVictim = false
                if victim and c.GetAttackTarget then
                    local okT, tgt = pcall(c.GetAttackTarget, c)
                    if okT and tgt == victim then lockedOnVictim = true end
                end
                if (not lockedOnVictim) and (not includePreAggro) and victim and U.IsCreepAggroedOnBot then
                    local chaseU = (U._State and U._State.myCreepChaseUntil) or nil
                    if U.IsCreepAggroedOnBot(c, victim, chaseU, true) then
                        lockedOnVictim = true
                    end
                end
                if lockedOnVictim or dc <= reach then
                    dps = dps + unitDps
                elseif includePreAggro and dc <= 500 then
                    dps = dps + unitDps * 0.50
                end
                if wave then
                    wave[#wave + 1] = {
                        x = cLoc.x, y = cLoc.y,
                        range = cRange,
                        dps = unitDps,
                        aggro_me = lockedOnVictim,
                    }
                end
            end
        end
    end
    return dps, wave
end

local C_TOWER_DMG, C_TOWER_INT = 65, 0.8182

function D.ApplyTowerTruth(tw, victim, tower, cfg)
    if not tw or not cfg or not cfg.ENGINE_TRUTH then return end
    local f = ET.TowerFacts(victim, tower, 2, 1, cfg.TOWER_PAD)
    if not f then return end
    tw.range = f.range
    tw.interval = f.interval or C_TOWER_INT
    tw.dmg = ET.AppliedTowerDamage(tower, victim)
    tw.raw_damage = f.raw_damage
    tw.aggro_me = f.targeting_me and true or false
    tw.windup = f.windup or ET.FALLBACK.TOWER_WINDUP
    tw.proj_speed = f.proj_speed or ET.FALLBACK.TOWER_PROJ
    tw.acquire = f.acquire or nil
    if f.next_shot_in then
        tw.next_shot = math.max(0.05, math.min(f.next_shot_in, tw.interval))
    end
    cfg.TOWER_PAD = tw.range
end

function D.ApplyIncoming(u, live, env)
    if not u or not live or not D.CFG.ENGINE_TRUTH then return end
    local dmg_of = env and env.projectileDamage or nil
    local total, n = ET.IncomingDamage(live, dmg_of)
    if total == nil then
        total = (env and env.enemyDamageVsMe) or 55
        n = n or 1
    end
    if total and total > 0 then
        u.incoming = total
        u.incoming_at = math.min(D.CFG.INCOMING_MAX_LAND, 0.18)
        u.incoming_n = n
    end
end

function D.TrackVelocity(loc, now)
    local T = S.track
    if not T then T = {}; S.track = T end
    if not T.t or now - T.t > 0.02 then
        T.px, T.py, T.pt = T.lx, T.ly, T.lt
        T.lx, T.ly, T.lt = loc.x, loc.y, now
        T.t = now
    end
    local dt = (T.lt or 0) - (T.pt or 0)
    if not T.px or dt <= 0.02 or dt > 1.2 then return 0, 0 end
    local vx = (T.lx - T.px) / dt
    local vy = (T.ly - T.py) / dt
    local sp = math.sqrt(vx * vx + vy * vy)
    if sp > 900 then return 0, 0 end
    return vx, vy
end

function D.BuildState(bot, s, env)
    local cfg = D.CFG
    local now = env.now or 0
    local bLoc = bot:GetLocation()
    local me = {
        x = bLoc.x, y = bLoc.y,
        hp = bot:GetHealth(), hp_max = bot:GetMaxHealth(),
        mana = bot:GetMana(),
        dmg = env.myDamageVsHim or 0,
        souls = env.mySouls or 0,
        raze_level = env.myRazeLevel or 0,
        stack_talent = env.myStackTalent or 0,
        spell_amp = env.mySpellAmp or 1.0,
        raze_ready = { 0, 0, 0 },
        atk_range = (bot.GetAttackRange and bot:GetAttackRange()) or 525,
        ms = (bot.GetCurrentMovementSpeed and bot:GetCurrentMovementSpeed()) or 305,
        regen_hp = env.myRegen or 1.0,
        regen_mana = env.myManaRegen or 1.0,
        magic_resist = env.myMagicResist or 0.25,
        magic_block = env.myMagicBlock or 0,
        stacks = env.myRazeStacksOnMe or 0,
        stick_charges = env.myStickCharges or 0,
        mango = env.myMango or false,
        mango_charges = env.myMangoCharges,
        faerie = env.myFaerie or false,
    }
    local e = s.enemy
    local el = e and e:GetLocation() or { x = 0, y = 0 }
    local rawHisHp = e and e:GetHealth() or 1
    local effHisHp = (env.hisEffectiveCombatHp and math.max(rawHisHp, env.hisEffectiveCombatHp)) or rawHisHp
    local him = {
        x = el.x, y = el.y,
        hp = effHisHp, hp_max = math.max(e and e:GetMaxHealth() or 1, effHisHp),
        true_hp_max = env.hisTrueMaxHp or (e and e:GetMaxHealth() or 1),
        mana = e and e:GetMana() or 0,
        dmg = env.enemyDamageVsMe or 0,
        souls = env.hisSouls or 0,
        raze_level = env.hisRazeLevel or 0,
        stack_talent = env.hisStackTalent or 0,
        spell_amp = env.hisSpellAmp or 1.0,
        raze_ready = { 0, 0, 0 },
        atk_range = (e and e.GetAttackRange and e:GetAttackRange()) or 525,
        ms = (e and e.GetCurrentMovementSpeed and e:GetCurrentMovementSpeed()) or 305,
        regen_hp = 1.5, regen_mana = 1.0,
        magic_resist = env.hisMagicResist or 0.25,
        magic_block = env.hisMagicBlock or 0,
        stacks = env.hisRazeStacksOnHim or 0,
        stick_charges = env.hisStickCharges or 0,
        mango = env.hisMango or false,
        mango_charges = env.hisMangoCharges,
        faerie = env.hisFaerie or false,
    }
    local function rel(t) local d = (t or 0) - now if d < 0 then d = 0 end return d end
    me.raze_ready  = { rel((env.myRazeReady or {})[1]),  rel((env.myRazeReady or {})[2]),  rel((env.myRazeReady or {})[3]) }
    him.raze_ready = { rel((env.hisRazeReady or {})[1]), rel((env.hisRazeReady or {})[2]), rel((env.hisRazeReady or {})[3]) }

    if e and e.GetLocation then
        local vx, vy = D.TrackVelocity(el, now)
        him.vx, him.vy = vx, vy
    end
    if env.hisCastLeft then him.cast_left = env.hisCastLeft end
    if env.hisCastBand then him.cast_band = env.hisCastBand end
    if bot.IsUsingAbility then
        local ok, cast = pcall(bot.IsUsingAbility, bot)
        if ok and cast then me.cast_left = 0.55 end
    end

    local aggroOffCd = (env.myAggroCdUntil or 0) <= now + 0.15
    -- `v7.9.14-pro` Zero-Cowardice Intent Separation:
    -- `creep_dps_on_me` passes ONLY currently locked creeps (`includePreAggro = false`) so coil/poke trades NEVER fear un-aggroed creeps!
    -- `brawl_creep_dmg_*` passes exact walk-lag + dying-tank-creep damage over bounded `tBrawl` strictly for close right-click sustain!
    local creepDpsMe, enemyWave = creep_dps_and_wave(s.enemyCreeps, me, bot, false, true)
    local creepDpsHim = creep_dps_and_wave(s.allyCreeps, him, e, false, false)
    local brawlWindow = 2.4
    local brawlCreepMe = (U.ComputeIntentCreepBrawlDamage and U.ComputeIntentCreepBrawlDamage(bot, e, s.enemyCreeps, s.allyCreeps, brawlWindow, "BRAWL", aggroOffCd)) or (creepDpsMe * brawlWindow)
    local brawlCreepHim = (e and U.ComputeIntentCreepBrawlDamage and U.ComputeIntentCreepBrawlDamage(e, bot, s.allyCreeps, s.enemyCreeps, brawlWindow, "BRAWL", true)) or (creepDpsHim * brawlWindow)

    local myZ = bLoc.z or 0
    local hisZ = el.z or 0
    local meUphillMiss = (hisZ - myZ) >= 48
    local himUphillMiss = (myZ - hisZ) >= 48
    if type(GetHeightLevel) == "function" and e and e.GetLocation then
        local okM, hM = pcall(GetHeightLevel, bLoc)
        local okH, hH = pcall(GetHeightLevel, el)
        if okM and okH and type(hM) == "number" and type(hH) == "number" then
            meUphillMiss = meUphillMiss or (hH > hM)
            himUphillMiss = himUphillMiss or (hM > hH)
        end
    end

    local st = {
        t = 0,
        me = me, him = him,
        me_stacks = me.stacks,
        him_stacks = him.stacks,
        me_uphill_miss = meUphillMiss,
        him_uphill_miss = himUphillMiss,
        dist = unit_dist(me, him),
        creep_dps_on_me = creepDpsMe,
        creep_dps_on_him = creepDpsHim,
        enemy_wave = enemyWave,
        my_aggro_cd_until = math.max(0, (env.myAggroCdUntil or 0) - now),
        tower = nil,
        gt = now,
    }
    if env.enemyT1Alive and env.enemyT1Loc then
        st.tower = { x = env.enemyT1Loc.x, y = env.enemyT1Loc.y, dmg = C_TOWER_DMG, interval = C_TOWER_INT }
        D.ApplyTowerTruth(st.tower, bot, env.enemyT1, cfg)
    end
    if env.ownT1Loc then
        st.own_tower = { x = env.ownT1Loc.x, y = env.ownT1Loc.y, dmg = C_TOWER_DMG, interval = C_TOWER_INT }
        D.ApplyTowerTruth(st.own_tower, e, env.ownT1, cfg)
    end
    D.ApplyIncoming(me, bot, env)
    if e and e.GetLocation then D.ApplyIncoming(him, e, nil) end

    if env.enemyT1Alive and env.enemyT1Loc then
        st.his_flee = { x = env.enemyT1Loc.x, y = env.enemyT1Loc.y }
    end

    local ax, ay = norm(me.x - him.x, me.y - him.y)
    local anchorLoc = env.safeAnchorLoc or env.ownT1Loc
    local bx, by = norm((anchorLoc and anchorLoc.x or me.x) - me.x,
                        (anchorLoc and anchorLoc.y or me.y) - me.y)
    local fx, fy = norm(ax * 0.65 + bx * 0.55, ay * 0.65 + by * 0.55)
    -- `9069188041.dem` `03:46` Fix: NEVER choose a `fixedAnchor` whose step `(bx, by)` walks INTO the enemy (`dot < -0.10`)!
    local anchorWalksIntoEnemy = anchorLoc and ((bx * ax + by * ay) < -0.10)
        and (math.abs(anchorLoc.x - me.x) + math.abs(anchorLoc.y - me.y) > 45)
    local fixedAnchor = (anchorLoc and not anchorWalksIntoEnemy)
        and { x = anchorLoc.x, y = anchorLoc.y }
        or { x = me.x + fx * 650, y = me.y + fy * 650 }
    st.flee_points = {
        { x = me.x + fx * 650, y = me.y + fy * 650 },
        fixedAnchor,
    }
    st.own_t1_xy = env.ownT1Loc and { x = env.ownT1Loc.x, y = env.ownT1Loc.y } or nil

    if cfg.EXCHANGE_GATE then
        local xst = {
            dist = st.dist,
            locked = (him.cast_left and him.cast_left > 0.1) and him.cast_left or 0,
            me = {
                hp = me.hp, hp_max = me.hp_max, mana = me.mana,
                mana_regen = me.regen_mana, ms = me.ms, dmg = me.dmg,
                rlvl = me.raze_level, souls = me.souls, stack_talent = me.stack_talent,
                spell_amp = me.spell_amp, mr = me.magic_resist, magic_block = me.magic_block,
                stacks = me.stacks, cd = me.raze_ready, cast_left = me.cast_left,
                faerie = me.faerie, stick_charges = me.stick_charges,
                mango = me.mango, mango_charges = me.mango_charges,
                unlocking_mango_mana = env.myUnlockingMangoMana, unlock_eta = env.myUnlockEta,
                courier_mango_mana = env.myCourierMangoMana, courier_faerie_heal = env.myCourierFaerieHeal,
                courier_eta = env.myCourierEta,
                incoming = me.incoming,
            },
            him = {
                hp = him.hp, hp_max = him.hp_max, mana = him.mana,
                mana_regen = him.regen_mana, ms = him.ms, dmg = him.dmg,
                rlvl = him.raze_level, souls = him.souls, stack_talent = him.stack_talent,
                spell_amp = him.spell_amp, mr = him.magic_resist, magic_block = him.magic_block,
                stacks = him.stacks, cd = him.raze_ready, cast_left = him.cast_left,
                faerie = him.faerie, stick_charges = him.stick_charges,
                mango = him.mango, mango_charges = him.mango_charges,
                unlocking_mango_mana = env.hisUnlockingMangoMana, unlock_eta = env.hisUnlockEta,
                courier_mango_mana = env.hisCourierMangoMana, courier_faerie_heal = env.hisCourierFaerieHeal,
                courier_eta = env.hisCourierEta,
                incoming = him.incoming,
            },
            creep_dps_on_me  = st.creep_dps_on_me,
            creep_dps_on_him = st.creep_dps_on_him,
            brawl_creep_dmg_me  = brawlCreepMe,
            brawl_creep_dmg_him = brawlCreepHim,
            me_uphill_miss  = st.me_uphill_miss,
            him_uphill_miss = st.him_uphill_miss,
            tower_on_him = (st.own_tower and st.own_tower.aggro_me)
                and (st.own_tower.dmg or 65) / math.max(0.5, st.own_tower.interval or 0.82) or 0,
            tower_on_me  = (st.tower and st.tower.aggro_me)
                and (st.tower.dmg or 65) / math.max(0.5, st.tower.interval or 0.82) or 0,
        }
        st.exchange = XCH.Verdict(xst)
        if him.cast_left and him.cast_left > 0 and him.cast_band then
            local _ign
            st.react_action, _ign, st.react_band = XCH.React(
                st.dist, him.cast_band, him.cast_left,
                {
                    hp = me.hp, hp_max = me.hp_max, mana = me.mana, ms = me.ms,
                    dmg = me.dmg, rlvl = me.raze_level, souls = me.souls,
                    stack_talent = me.stack_talent, spell_amp = me.spell_amp, mr = me.magic_resist,
                    mango = me.mango, mango_charges = me.mango_charges, stick_charges = me.stick_charges,
                    cd = me.raze_ready,
                },
                {
                    hp = him.hp, hp_max = him.hp_max, dmg = him.dmg, ms = him.ms,
                    stacks = him.stacks, mr = him.magic_resist, magic_block = him.magic_block,
                    raze_dmg = XCH.RazeDamage(
                        him.raze_level or 0, him.souls or 0, me.stacks or 0,
                        me.magic_resist, him.stack_talent, him.spell_amp, me.magic_block),
                },
                { centre = env.hisCastCentre, me_xy = me })
            st.react_centre = env.hisCastCentre or nil
        end
        st.safe_dist = XCH.SafeDistance({ cd = him.raze_ready })
    end
    return st
end

local FAST_HOLD_DEC = { mode = "HOLD", plan = { name = "hold500_none", hold_dist = 500, raze_policy = "none", engage = true, attack = true } }

function D.Decide(st, now)
    local cfg = D.CFG
    if not cfg.ENABLED then return nil end
    local castFlag = (st.him.cast_left and st.him.cast_left > 0.05) and 1 or 0
    local sig = string.format("%d|%d|%d|%d|%d|%d|%d|%d",
        math.floor(st.me.hp / 25), math.floor(st.him.hp / 25),
        math.floor(st.dist / 85),
        math.floor(st.me.mana / 50), math.floor(now * 3),
        (st.him.hp <= (st.me.dmg * 3) and 1 or 0),
        (st.me.hp <= (st.him.dmg * 3) and 1 or 0),
        castFlag)
    if S.last and castFlag == 0 and (now - S.lastEval) < cfg.EVAL_INTERVAL and sig == S.lastSig then
        return S.last
    end
    S.lastEval = now
    S.lastSig = sig
    S.evalCount = S.evalCount + 1

    -- Exact Provable Upper-Bound Theorem (`v7.9.22-pro` Zero-Loss Fast Path):
    -- When `cfg.EXCHANGE_GATE == true` and `st.exchange` is present AND `st.dist > cfg.ESCAPE_ENTER_DIST` (`760u`),
    -- `closeThreat` (`st.dist <= 760`) is provably `false` in `D.Override`, so `D.Override` ONLY inspects whether
    -- `dec.mode == "KILL"`. If `st.him.hp` exceeds the absolute mathematical upper bound of all damage `me` + `own_tower`
    -- + `creep_dps_on_him` could deal over `SEARCH_HORIZON` (`2.6s`), `r.his_dead` is provably `false` on all 44 plans!
    local d
    if cfg.EXCHANGE_GATE and st.exchange and (st.dist or 0) > cfg.ESCAPE_ENTER_DIST then
        local me, him = st.me, st.him
        local maxRazeDmg = ((me.raze_level or 0) > 0)
            and WAR.VolleyDamage(me.raze_level, him.stacks or 0, me.souls or 0, 3, him.magic_resist, me.stack_talent, me.spell_amp, 0)
            or 0
        local maxOwnTowerDmg = st.own_tower and (5 * ((st.own_tower.dmg or 65) + 10)) or 0
        local maxCreepDmg = (st.creep_dps_on_him or 0) * ((cfg.SEARCH_HORIZON or 2.6) + 0.30)
        local maxTotalDealt = (him.incoming or 0) + maxRazeDmg + 4 * (me.dmg or 0) + maxOwnTowerDmg + maxCreepDmg
        if (him.hp or 0) > maxTotalDealt + 5 then
            d = D.Override(st, FAST_HOLD_DEC, now)
            S.last = d
            S.mode = d.mode
            return d
        end
    end

    d = WAR.Evaluate(st, {
        dt = cfg.SEARCH_DT,
        horizon = cfg.SEARCH_HORIZON,
        flee_points = st.flee_points,
    })
    d = D.Override(st, d, now)
    S.last = d
    S.mode = d.mode
    return d
end

function D.Override(st, dec, now)
    if dec and dec.mode == "KILL" then
        S.escapeUntil = 0
        return dec
    end
    local cfg = D.CFG
    local meEff = st.me.hp + ((st.me.faerie and 85) or 0) + ((st.me.stick_charges or 0) * 15) - (st.me.incoming or 0)
    local himEff = st.him.hp + ((st.him.faerie and 85) or 0) + ((st.him.stick_charges or 0) * 15) - (st.him.incoming or 0)
    local mePct = math.max(0, meEff) / math.max(1, st.me.hp_max)
    local hisPct = math.max(0, himEff) / math.max(1, st.him.hp_max)

    -- `9068560663.dem` 01:53 Fix: If enemy is inside immediate 2-swing / 1-raze finish range and we survive 1 swing, FINISH HIM!
    local myImmediateFinish = WAR.Burst(st.me, st.him, 0.9, 0) + (st.dist <= 585 and (st.me.dmg * 2.05) or 0)
    if st.dist <= 620 and himEff <= myImmediateFinish and meEff > (st.him.dmg * 1.15 + WAR.Burst(st.him, st.me, 0.7, 0)) then
        S.escapeUntil = 0
        return {
            mode = "KILL",
            plan = { name = "finish_low_foe", hold_dist = 260, raze_policy = "burst", engage = true, attack = true },
            why = "immediate finish window overrides retreat",
        }
    end

    local towerKill = false
    if st.tower then
        local radius = st.tower.range or cfg.TOWER_PAD
        local d = unit_dist(st.me, st.tower)
        local shots = 0
        if st.tower.aggro_me then shots = shots + 1 end
        if d <= radius then
            local ms = math.max(200, st.me.ms or 305)
            local exitT = (radius - d) / ms + (st.tower.windup or 0.6) + d / math.max(1, st.tower.proj_speed or 750)
            local per = math.max(0.5, st.tower.interval or 0.82)
            shots = math.max(1, shots + math.floor(exitT / per))
        end
        local killDmg = shots * (st.tower.dmg or 65)
        if shots > 0 and meEff <= killDmg * 0.90 then towerKill = true end
    end

    local hisBurst = WAR.Burst(st.him, st.me, 1.4, 0) + (st.dist <= 600 and st.him.dmg * 1.2 or 0)
    local closeThreat = st.dist <= cfg.ESCAPE_ENTER_DIST
    -- `v7.9.15` (`auto-20261106-2139` `05:12.05` `408 HP + Faerie = 493 meEff` vs `550 hisBurst` Fix):
    -- When `meEff <= hisBurst + 10` (enemy's 1.4s multi-coil + auto burst genuinely kills us even through Faerie Fire!),
    -- ALWAYS trigger `oneVolleyFromDeath` regardless of flat `< 395` early-game HP cap; keep `< 395 & mePct < 0.42` for pad!
    local oneVolleyFromDeath = closeThreat
        and ((meEff <= hisBurst + 10 and mePct < 0.56)
            or (meEff <= hisBurst + cfg.RECOVER_BURST_PAD and mePct < 0.42 and meEff < 395))
    local farBehindClose = closeThreat and (mePct < cfg.RECOVER_HP_PCT and meEff < 320) and (hisPct > mePct + cfg.RECOVER_HP_GAP)
    local tacticalDanger = closeThreat and (dec and dec.mode == "ESCAPE")

    if towerKill or oneVolleyFromDeath or farBehindClose or tacticalDanger then
        S.escapeUntil = math.max(S.escapeUntil or 0, now + cfg.RECOVER_HOLD)
    end

    -- Clean Schmitt-trigger release: once we reach >= 950u from enemy (and not tanking enemy tower or in active 1-volley lethal),
    -- RELEASE immediately so Salve (`HandleProactiveAndActiveSalve`) and `RunSacredCS` own the tick!
    if (S.escapeUntil or 0) > now then
        if not towerKill and not oneVolleyFromDeath and (st.dist >= cfg.RELEASE_DIST or mePct >= cfg.RELEASE_HP_PCT) then
            S.escapeUntil = 0
        else
            return {
                mode = "ESCAPE", plan = { flee = true },
                why = towerKill and "tower execution" or "close lethal threat retreat",
            }
        end
    end

    local x = st.exchange
    if x and cfg.EXCHANGE_GATE then
        if x.verdict == "PUNISH" then
            return {
                mode = "PUNISH", plan = { name = "punish_cast_lock", raze_policy = "burst" },
                why = "exchange: " .. tostring(x.why), exchange = x,
            }
        end
        if x.verdict == "DISENGAGE" then
            if st.dist <= cfg.ESCAPE_ENTER_DIST then
                S.escapeUntil = math.max(S.escapeUntil or 0, now + 1.1)
                return { mode = "ESCAPE", plan = { flee = true }, why = "exchange: " .. tostring(x.why) }
            end
            S.refuseTradeUntil = math.max(S.refuseTradeUntil or 0, now + 0.35)
            return { mode = "HOLD", plan = { raze_policy = "none" }, why = "safe distance hold" }
        end
        if x.verdict == "ENTER" and dec and dec.mode ~= "KILL" then
            -- Hold `495u`: strictly outside enemy `Shadowraze1` (`200 + 274 = 474u` hull edge!) while inside
            -- our `573u` right-click reach AND our `Shadowraze2 (450u)` + `Shadowraze3 (700u)` bands!
            return {
                mode = "TRADE",
                plan = { name = "exchange_enter", hold_dist = 495, raze_policy = "trade", raze_quality = "solid", engage = true, attack = true },
                why = "exchange: " .. tostring(x.why), exchange = x,
            }
        end
        if x.verdict == "BRAWL" and dec and dec.mode ~= "KILL" then
            return {
                mode = "BRAWL", plan = { name = "exchange_brawl", engage = true, attack = true },
                why = "exchange: " .. tostring(x.why), exchange = x,
            }
        end
        if x.verdict == "HOLD" and dec and dec.mode ~= "KILL" then
            return { mode = "HOLD", plan = { raze_policy = "none" }, why = "exchange: " .. tostring(x.why) }
        end
        if x.verdict == "REFUSE" then
            -- Advisory gate ONLY: NEVER hijack movement with POKE (eliminates 960u bang-bang oscillation!)
            S.refuseTradeUntil = math.max(S.refuseTradeUntil or 0, now + 0.35)
            return { mode = "HOLD", plan = { raze_policy = "none" }, why = "refuse bad trade; yield to CS/spacing" }
        end
    end

    if dec and dec.mode == "TRADE" and WAR.Affordable(st.me, 0) <= 0 then
        return { mode = "HOLD", plan = { raze_policy = "none" }, why = "zero affordable razes -> hold" }
    end
    -- `auto-20261031-0230` `01:51.1` Out-Razed Tier Walk-In Fix:
    -- When enemy has a higher Shadowraze level (`Lvl 3 vs Lvl 2` = `150+50` vs `85+35`) and mana for `>= 1` coil,
    -- NEVER proactively walk into `hold_dist = 460` (`TRADE`) unless we have lethal (`KILL` / `PUNISH`)!
    local hisMangoMana = (type(st.him.mango_charges) == "number" and st.him.mango_charges * 100)
        or ((st.him.mango and 100) or (st.him.mango_mana or 0))
    if dec and dec.mode == "TRADE" and (st.him.raze_level or 0) > (st.me.raze_level or 0)
        and ((st.him.mana or 0) + hisMangoMana >= 75) then
        S.refuseTradeUntil = math.max(S.refuseTradeUntil or 0, now + 0.35)
        return { mode = "HOLD", plan = { raze_policy = "none" }, why = "out-razed tier -> hold safe spacing" }
    end

    return dec
end

local function attack_target_is_free(bot, s, myDmg, env)
    if env and env.imminentCS then return false end
    if s.enemyCreeps then
        local bLoc = bot:GetLocation()
        for _, c in pairs(s.enemyCreeps) do
            if c and c.GetHealth and c:IsAlive() and c:GetHealth() <= myDmg + 28 then
                local l = c:GetLocation()
                if unit_dist(l, bLoc) <= 650 then return false end
            end
        end
    end
    return true
end

--[[ Pre-CS High-Priority Reflex: ONLY executes guaranteed `KILL` or 0.55s pinned enemy cast-lock `PUNISH` / `ANSWER`. ]]--
function D.ExecuteKillOrCastLockOnly(bot, s, dec, env)
    if not dec then return false end
    local st = env.state
    local e = s.enemy
    if not e or not e:IsAlive() then return false end
    local meLoc = bot:GetLocation()
    local eLoc = e:GetLocation()

    -- 1. Pinned enemy in 0.55s Shadowraze cast animation -> guaranteed `ANSWER` / `PUNISH` coil!
    -- `v7.9.15` (`auto-20261106-2139` `05:12.05` `408 HP, myStacks=1` Pre-CS Self-Root Fix):
    -- NEVER self-root `0.55s` on a non-lethal `answer`/`PUNISH` when `dec.mode == "ESCAPE"` OR when enemy's
    -- 1.4s multi-coil + auto burst kills us (`meEff <= hisBurst14 + 35`) unless our single coil kills him NOW!
    if st.react_action == "answer" or dec.mode == "PUNISH" then
        local meEffCast = st.me.hp + ((st.me.faerie and 85) or 0) + ((st.me.stick_charges or 0) * 15) - (st.me.incoming or 0)
        local himEffCast = st.him.hp + ((st.him.faerie and 85) or 0) + ((st.him.stick_charges or 0) * 15) - (st.him.incoming or 0)
        local myOneCoilDmg = WAR.Burst(st.me, st.him, 0.0, 0, { max = 1 })
        local hisBurst14 = WAR.Burst(st.him, st.me, 1.4, 0) + (st.dist <= 600 and st.him.dmg * 1.2 or 0)
        local lethalCounterNow = (myOneCoilDmg >= himEffCast)
        if lethalCounterNow or (dec.mode ~= "ESCAPE" and meEffCast > hisBurst14 + 35) then
            local probeMe = {
                x = meLoc.x, y = meLoc.y, ms = st.me.ms, hp = st.me.hp, hp_max = st.me.hp_max,
                mana = st.me.mana, raze_level = st.me.raze_level, stack_talent = st.me.stack_talent, spell_amp = st.me.spell_amp,
                raze_ready = { st.me.raze_ready[1], st.me.raze_ready[2], st.me.raze_ready[3] },
                souls = st.me.souls, mango = st.me.mango, mango_charges = st.me.mango_charges, stick_charges = st.me.stick_charges, alive = true,
            }
            local probeHim = {
                x = eLoc.x, y = eLoc.y, ms = 0, hp = st.him.hp, hp_max = st.him.hp_max,
                mana = st.him.mana, raze_level = st.him.raze_level, magic_resist = st.him.magic_resist, magic_block = st.him.magic_block,
                raze_ready = { st.him.raze_ready[1], st.him.raze_ready[2], st.him.raze_ready[3] },
                souls = st.him.souls, alive = true,
                atk_until = (env.now or 0) + 0.6,
            }
            local shot = WAR.FindShot(probeMe, probeHim, 0, "poor")
            if shot and env.castRaze(bot, shot, eLoc, e) then return true end
        end
    end

    -- 2. Guaranteed `KILL` mode -> convert immediately!
    if dec.mode == "KILL" then
        return D.ExecuteTactical(bot, s, dec, env)
    end
    return false
end

--[[ Post-Salve & Post-SacredCS Tactical Execution (`KILL`, `ESCAPE`, `TRADE`, `BRAWL`). ]]--
function D.ExecuteTactical(bot, s, dec, env)
    if not dec or dec.mode == "HOLD" then return false end
    local st = env.state
    local e = s.enemy
    if not e or not e:IsAlive() then return false end
    local meLoc = bot:GetLocation()
    local eLoc = e:GetLocation()
    local dist = unit_dist(meLoc, eLoc)
    local plan = dec.plan or {}

    -- 1. Active enemy 0.55s Raze windup reaction (WORKS EVEN DURING ESCAPE! Fixes `9068560663.dem` 03:17–03:19
    --    and `9079381960.dem` `05:22.7`: when `need > maxStep` so we CANNOT outrun an enemy `E(700)` circle anyway,
    --    fire back our ready `E(700)` if we comfortably survive the coil instead of walking radially through `700u` for 0 return!)
    if st.react_action then
        local castBandCentre = XCH.C.BANDS[st.him.cast_band or 3] or 700
        local needOut = XCH.C.RADIUS - math.abs(st.dist - castBandCentre)
        local maxWalkInRem = (st.me.ms or 305) * math.max(0, (st.him.cast_left or 0.55) - 0.05) * 0.90
        local inescapableCoilSafeAnswer = (dec.mode == "ESCAPE")
            and (needOut > maxWalkInRem)
            and (st.dist >= 580)
            and ((st.me.hp or 0) > (XCH.RazeDamage(
                st.him.raze_level or 0, st.him.souls or 0, st.me.stacks or 0,
                st.me.magic_resist, st.him.stack_talent, st.him.spell_amp, st.me.magic_block) + 140))
        if st.react_action == "answer" and (dec.mode ~= "ESCAPE" or inescapableCoilSafeAnswer) then
            local probeMe = {
                x = meLoc.x, y = meLoc.y, ms = st.me.ms, hp = st.me.hp, hp_max = st.me.hp_max,
                mana = st.me.mana, raze_level = st.me.raze_level, stack_talent = st.me.stack_talent, spell_amp = st.me.spell_amp,
                raze_ready = { st.me.raze_ready[1], st.me.raze_ready[2], st.me.raze_ready[3] },
                souls = st.me.souls, mango = st.me.mango, mango_charges = st.me.mango_charges, stick_charges = st.me.stick_charges, alive = true,
            }
            local probeHim = {
                x = eLoc.x, y = eLoc.y, ms = 0, hp = st.him.hp, hp_max = st.him.hp_max,
                mana = st.him.mana, raze_level = st.him.raze_level, magic_resist = st.him.magic_resist, magic_block = st.him.magic_block,
                raze_ready = { st.him.raze_ready[1], st.him.raze_ready[2], st.him.raze_ready[3] },
                souls = st.him.souls, alive = true,
                atk_until = (env.now or 0) + 0.6,
            }
            local shot = WAR.FindShot(probeMe, probeHim, 0, "poor")
            if shot and env.castRaze(bot, shot, eLoc, e) then return true end
        elseif (st.react_action == "step" or st.react_action == "eat") and st.react_centre then
            local dxC = meLoc.x - st.react_centre.x
            local dyC = meLoc.y - st.react_centre.y
            local need = 274 - math.sqrt(dxC * dxC + dyC * dyC)
            local px, py = XCH.ExitPoint(meLoc.x, meLoc.y, st.react_centre.x, st.react_centre.y,
                                         math.max(55, need), st.own_t1_xy, 42)
            return env.moveTo({ x = px, y = py }, true)
        elseif st.react_action == "trade" and dec.mode ~= "ESCAPE" then
            if attack_target_is_free(bot, s, st.me.dmg, env) and env.attackHero then
                return env.attackHero()
            end
        end
    end

    -- 2. ESCAPE: ALWAYS convert a lethal 1-Raze turn-and-fire kill (`W6 08:02.0` 2-stack `E` fix!),
    --    or fire zero-turn Snap-Raze if already facing close pursuer (`03:17` fix!), otherwise retreat to fixed anchor!
    if dec.mode == "ESCAPE" then
        local probeMe = {
            x = meLoc.x, y = meLoc.y, ms = st.me.ms, hp = st.me.hp, hp_max = st.me.hp_max,
            mana = st.me.mana, raze_level = st.me.raze_level, stack_talent = st.me.stack_talent, spell_amp = st.me.spell_amp,
            raze_ready = { st.me.raze_ready[1], st.me.raze_ready[2], st.me.raze_ready[3] },
            souls = st.me.souls, mango = st.me.mango, mango_charges = st.me.mango_charges, stick_charges = st.me.stick_charges, alive = true,
        }
        local probeHim = {
            x = eLoc.x, y = eLoc.y, ms = st.him.ms, vx = st.him.vx, vy = st.him.vy,
            hp = st.him.hp, hp_max = st.him.hp_max, mana = st.him.mana,
            raze_level = st.him.raze_level, magic_resist = st.him.magic_resist, magic_block = st.him.magic_block,
            raze_ready = st.him.raze_ready, souls = st.him.souls, alive = true,
        }
        local hisMangoM = (type(st.him.mango_charges) == "number" and st.him.mango_charges * 100) or ((st.him.mango and 100) or 0)
        local hisPotMana = (st.him.mana or 0) + hisMangoM + ((st.him.stick_charges or 0) * 15)
        local myAff = WAR.Affordable(probeMe, 0)
        if myAff >= 1 and dist <= 925 then
            local lethalShot = WAR.FindShot(probeMe, probeHim, 0, "solid")
            if lethalShot then
                local s0 = st.him.stacks or 0
                local himMr = st.him.magic_resist or 0.25
                local himBlk = st.him.magic_block or 0
                local oneRazeDmg = WAR.RazeApplied(st.me.raze_level, s0, st.me.souls, himMr, st.me.stack_talent, st.me.spell_amp, himBlk)
                local twoRazeDmg = oneRazeDmg + WAR.RazeApplied(st.me.raze_level, math.min(4, s0 + 1), st.me.souls, himMr, st.me.stack_talent, st.me.spell_amp, 0)
                local himSurvHp = st.him.hp + ((st.him.faerie and 85) or 0) + ((st.him.stick_charges or 0) * 15)
                local safeNonLethalFarWD = (st.me.hp > 225)
                    or (dist >= 680 and env.canSnapRaze and env.canSnapRaze(bot, lethalShot, e))
                local lCenterEsc = XCH.C.BANDS[lethalShot] or 700
                local holdEarlyPokeEsc = U.ShouldHoldEarlyNonLethalPokeRaze
                    and U.ShouldHoldEarlyNonLethalPokeRaze(bot, e, s, lCenterEsc) or false
                local freeDryFarPoke = (not holdEarlyPokeEsc)
                    and (hisPotMana < 75) and (dist >= 585 and dist <= 885)
                    and ((st.creep_dps_on_me or 0) <= 18) and safeNonLethalFarWD
                local dryTwoRazeKill = (myAff >= 2) and (twoRazeDmg >= himSurvHp)
                    and (hisPotMana < 75 or dist > 565)
                -- `auto-20261031-0230` `02:09.1` Self-Root Death #2 Fix:
                -- NEVER turn 180 deg + self-root `0.55s` inside enemy right-click range (`<= 545u`) for a non-lethal `69`-dmg
                -- coil when `myMS >= hisMS` (running away past T1/wave saves our life!). Only fire close last-stand coil when
                -- either `oneRaze + 1 hit` threatens lethal OR a faster Boots enemy (`hisMS >= myMS + 25`) is already on us!
                local inescapablePursuit = ((st.him.ms or 305) >= (st.me.ms or 305) + 25) and (dist <= 420)
                    and (st.me.hp <= (st.him.dmg or 55) * 1.45)
                local razePlusHitLethal = (oneRazeDmg + (st.me.dmg or 50) >= himSurvHp)
                    and (st.me.hp > (st.him.dmg or 55) + 20)
                local lastStandClose = (st.me.mana >= 75) and (dist <= 545)
                    and (razePlusHitLethal or (inescapablePursuit and env.canSnapRaze and env.canSnapRaze(bot, lethalShot, e)))
                local allowMangoEsc = (oneRazeDmg >= himSurvHp) or dryTwoRazeKill or razePlusHitLethal
                if (oneRazeDmg >= himSurvHp or dryTwoRazeKill or freeDryFarPoke or lastStandClose)
                    and env.castRaze(bot, lethalShot, eLoc, e, allowMangoEsc) then
                    return true
                end
            end
        end
        local snapSafeInEscape = (dist >= 565)
            or (st.me.hp >= 265)
            or ((st.him.ms or 305) >= (st.me.ms or 305) + 22)
        if snapSafeInEscape and st.me.hp >= 180 and st.me.mana >= 75 and dist >= 100 and dist <= 860 and env.canSnapRaze then
            local shot = WAR.FindShot(probeMe, probeHim, 0, "solid")
            local snapCenterEsc = shot and (XCH.C.BANDS[shot] or 450) or nil
            local holdSnapEsc = shot and U.ShouldHoldEarlyNonLethalPokeRaze
                and U.ShouldHoldEarlyNonLethalPokeRaze(bot, e, s, snapCenterEsc) or false
            if shot and (not holdSnapEsc) and env.canSnapRaze(bot, shot, e) then
                return env.castRaze(bot, shot, eLoc, e, false)
            end
        end
        local fp = (st.flee_points and st.flee_points[2]) or (st.flee_points and st.flee_points[1])
        if not fp then return false end
        return env.moveTo(fp, false)
    end

    -- 3. BRAWL (manaless right-click advantage): never drop imminent CS, NEVER stand inside >= 2 aggroed creeps,
    --    and (`v7.9.18` `9079381960.dem` `01:30.6..01:36.6` Faerie + Uphill Fix) account for `Faerie Fire (+85)` + `Stick`
    --    AND `25%` uphill miss in `twoHitFinishWD`, refusing lowground-into-HG foot brawls while creeps hit us!
    local aggroOnMeWD = (U.CountEnemyCreepsAggroedOnBot and U.CountEnemyCreepsAggroedOnBot(bot, s, (U._State and U._State.myCreepChaseUntil) or nil)) or 0
    local kiteLockActive = (U._State and U._State.creepKiteUntil and (env.now or 0) < U._State.creepKiteUntil) or false
    local himRawNowWD = (e.GetHealth and e:GetHealth()) or (st.him.hp or 999)
    local himEffNowWD = himRawNowWD + ((st.him.faerie and 85) or 0) + ((st.him.stick_charges or 0) * 15)
    local effHitMultWD = st.me_uphill_miss and 1.42 or 1.90
    local oneHitRawPopWD = (not st.me_uphill_miss) and (himRawNowWD <= (st.me.dmg or 45) * 0.95)
    local twoHitFinishWD = oneHitRawPopWD or (himEffNowWD <= (st.me.dmg or 45) * effHitMultWD)
    if dec.mode == "BRAWL" then
        if not attack_target_is_free(bot, s, st.me.dmg, env) then return false end
        if (aggroOnMeWD >= 2 or kiteLockActive) and not twoHitFinishWD then return false end
        if st.me_uphill_miss and aggroOnMeWD >= 1 and not twoHitFinishWD then return false end
        if aggroOnMeWD >= 1 and (st.me.dmg or 45) < (st.him.dmg or 45) - 4 and not twoHitFinishWD then return false end
        local reach = (st.me.atk_range or 525) + 25
        if dist <= reach and env.attackHero then return env.attackHero() end
        if not st.me_uphill_miss and dist <= reach + 160 then return env.approach(e) end
        return false
    end

    -- 4. KILL or TRADE
    if dec.mode == "KILL" or dec.mode == "TRADE" then
        if dec.mode == "TRADE" and not attack_target_is_free(bot, s, st.me.dmg, env) then
            return false
        end
        local probeMe = {
            x = meLoc.x, y = meLoc.y, ms = st.me.ms, hp = st.me.hp, hp_max = st.me.hp_max,
            mana = st.me.mana, raze_level = st.me.raze_level, stack_talent = st.me.stack_talent, spell_amp = st.me.spell_amp,
            raze_ready = { st.me.raze_ready[1], st.me.raze_ready[2], st.me.raze_ready[3] },
            souls = st.me.souls, mango = st.me.mango, mango_charges = st.me.mango_charges, stick_charges = st.me.stick_charges, alive = true,
        }
        local probeHim = {
            x = eLoc.x, y = eLoc.y, ms = st.him.ms, vx = st.him.vx, vy = st.him.vy,
            hp = st.him.hp, hp_max = st.him.hp_max, mana = st.him.mana,
            raze_level = st.him.raze_level, magic_resist = st.him.magic_resist, magic_block = st.him.magic_block,
            raze_ready = { st.him.raze_ready[1], st.him.raze_ready[2], st.him.raze_ready[3] },
            souls = st.him.souls, alive = true,
        }
        local myAffTrade = WAR.Affordable(probeMe, 0)
        local courMangoW = (U.GetIncomingCourierMana and U.GetIncomingCourierMana(bot, 6.5)) or 0
        local effTradePool = (st.me.mana or 0)
            + ((type(st.me.mango_charges) == "number" and st.me.mango_charges * 100) or ((st.me.mango and 100) or 0))
            + courMangoW
        local hisMangoT = (type(st.him.mango_charges) == "number" and st.him.mango_charges * 100) or ((st.him.mango and 100) or 0)
        local hisPotManaT = (st.him.mana or 0) + hisMangoT + ((st.him.stick_charges or 0) * 15)
        -- `auto-20261102-0007` (`4:36.87`, `8:22.40`, `10:02.73`) + `auto-20261102-0139` (`3:58.80` Courier-ETA & Crippled Enemy) Fix:
        --   * Only hold back single-coil trades when `effTradePool < 145` (accounting for incoming courier Mangoes `<= 6.5s`!),
        --   * AND enemy actually holds `>= 150 MP` (`2+` counter-coils!) AND enemy is healthy (`hp > singleRaze + 95` & `hp > 260`)!
        local oneMyRazeW = (U.GetNRazeDamage and U.GetNRazeDamage(bot, e, 1)) or 120
        local fightingUnderOwnT1 = st.own_t1_xy
            and (unit_dist(meLoc, st.own_t1_xy) <= 780)
            and (unit_dist(eLoc, st.own_t1_xy) <= 840)
        -- `v7.9.18` (`9079381960.dem` `05:44.0..05:46.9` Under-Own-T1 Close-Brawl Fix):
        -- NEVER suppress ready `Q(200)` / `W(450)` via `singleCoilOutgunned` when Enemy has ALREADY committed inside
        -- `dist <= 440u` or is fighting us under our own Allied T1!
        local closeCommittedOrOwnT1 = (dist <= 440) or fightingUnderOwnT1
        local singleCoilOutgunned = (dec.mode == "TRADE")
            and (not closeCommittedOrOwnT1)
            and (myAffTrade <= 1)
            and (effTradePool < 145)
            and (hisPotManaT >= 150)
            and ((st.him.hp or 999) > math.max(260, oneMyRazeW + 95))
        -- `v7.9.8-pro` (`1630 @ 03:33.33` `84->11 MP` Last-Mana `E(700)` Into Death Fix!):
        -- When spending this coil leaves us completely dry (`effTradePool < 145`) while we are already `>= 110 HP` behind
        -- an armed enemy (`hisPotManaT >= 75`), do NOT burn our last `75 MP` on a naked `E(700)` inside `d < 775u`!
        local lastManaBehindEnemy = (dec.mode == "TRADE")
            and (not closeCommittedOrOwnT1)
            and (myAffTrade <= 1)
            and (effTradePool < 145)
            and (hisPotManaT >= 75)
            and ((st.him.hp or 999) > (st.me.hp or 0) + 110)
            and ((st.him.hp or 999) > math.max(260, oneMyRazeW + 95))
        local shot = WAR.FindShot(probeMe, probeHim, 0, dec.mode == "KILL" and "poor" or "solid")
        local shotCenterTr = shot and (XCH.C.BANDS[shot] or 450) or nil
        local holdTradePoke = (dec.mode == "TRADE") and shot and U.ShouldHoldEarlyNonLethalPokeRaze
            and U.ShouldHoldEarlyNonLethalPokeRaze(bot, e, s, shotCenterTr) or false
        local allowMangoTrade = (dec.mode == "KILL")
            or ((st.him.stacks or 0) >= 2)
            or ((st.him.hp or 999) <= (oneMyRazeW * 2 + (st.me.dmg or 50) * 1.35))
        if shot and (not holdTradePoke)
            and (not singleCoilOutgunned or (shot == 3 and dist >= 665))
            and (not lastManaBehindEnemy or (shot == 3 and dist >= 775)) then
            return env.castRaze(bot, shot, eLoc, e, allowMangoTrade)
        end

        local reach = (st.me.atk_range or 525) + 20
        if dec.mode == "KILL" then
            if dist <= reach and (st.him.hp <= st.me.dmg * 1.15 or st.me.mana < 75) and env.attackHero then
                return env.attackHero()
            end
            if dist > 460 then return env.approach(e) end
            if dist <= reach and env.attackHero then return env.attackHero() end
        else
            -- `v7.9.17` (`auto-20261107-0354` `00:28.60`, `00:41.93`, `02:33.47`, `02:42.40` Spent-Coil & Outer-`W` Spacing):
            --   1. When BOTH our `W` and `E` are spent (`> 1.2s` CD or `< 75 MP`) while Enemy holds a live `W(450)` (`<= 1.4s`,
            --      `hisPotManaT >= 75`) and we don't have a 2-hit right-click finish, NEVER loiter at `495u` — step back to `775u`!
            --   2. When our `W` IS ready while Enemy's `E` is on CD (`> 1.5s`) and Enemy's `W` IS ready (`hisPotManaT >= 75`),
            --      hold outer-`W` stance (`610u`, never approaching inside `< 615u`!) instead of walking down to `495u`!
            local myWSpent = ((st.me.raze_ready[2] or 0) > now + 1.2) or ((st.me.mana or 0) < 75)
            local myESpent = ((st.me.raze_ready[3] or 0) > now + 1.2) or ((st.me.mana or 0) < 75)
            local hisWLive = ((st.him.raze_ready[2] or 0) <= now + 1.45) and (hisPotManaT >= 75)
            local hisEOnCd = ((st.him.raze_ready[3] or 0) > now + 1.50) or (hisPotManaT < 75)
            local spentMidFarVsW = myWSpent and myESpent and hisWLive and (not twoHitFinishWD)
            local outerWStance = (not myWSpent) and hisWLive and hisEOnCd and (not twoHitFinishWD)

            if spentMidFarVsW and dist < 755 then
                local tx, ty = own_t1_xy(bot, s)
                local dx1, dy1 = norm(meLoc.x - eLoc.x, meLoc.y - eLoc.y)
                local dx2, dy2 = norm(tx - eLoc.x, ty - eLoc.y)
                local bx, by = norm(dx1 * 0.55 + dx2 * 0.45, dy1 * 0.55 + dy2 * 0.45)
                return env.moveTo({ x = eLoc.x + bx * 785, y = eLoc.y + by * 785 }, false)
            end

            -- Wide hysteresis deadband `[hold - 135, hold + 95]` prevents micro-oscillation!
            -- `v7.9.18` (`05:21.5` Fix): When `singleCoilOutgunned` holds against live Enemy `W(450)`, hold `765u` (`> 724u` `W` hull)!
            local hold = singleCoilOutgunned and math.max(plan.hold_dist or 470, hisWLive and 765 or 690)
                or (outerWStance and 610 or (plan.hold_dist or 470))
            local safeRightClickTrade = (not singleCoilOutgunned) and (not spentMidFarVsW)
                and (twoHitFinishWD or (aggroOnMeWD < 2 and not kiteLockActive and not (outerWStance and dist >= 565)))
            if dist <= reach and safeRightClickTrade and attack_target_is_free(bot, s, st.me.dmg, env) and env.attackHero then
                return env.attackHero()
            end
            local approachCap = outerWStance and (hold + 35) or (hold + 95)
            if safeRightClickTrade and dist > approachCap and dist <= 780 then return env.approach(e) end
            local innerMin = outerWStance and 575 or (hold - 135)
            if dist < innerMin then
                local tx, ty = own_t1_xy(bot, s)
                local dx1, dy1 = norm(meLoc.x - eLoc.x, meLoc.y - eLoc.y)
                local dx2, dy2 = norm(tx - eLoc.x, ty - eLoc.y)
                local bx, by = norm(dx1 * 0.60 + dx2 * 0.40, dy1 * 0.60 + dy2 * 0.40)
                return env.moveTo({ x = meLoc.x + bx * (hold - dist + 45), y = meLoc.y + by * (hold - dist + 45) }, false)
            end
        end
    end

    return false
end

function D.Reset()
    S.lastEval = -100
    S.last = nil
    S.lastSig = ""
    S.mode = nil
end

D.State = S

return D
