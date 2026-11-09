
-- Nevermore Bot v7.9.33-pro — Pro 1v1 Mid Architecture (Opening Raze Supremacy, Millisecond Ray-Dodge & Near-Launch Windup Lock: 795u Motion-Buffer Windup Preservation + Pre-Raze Auto-Release Combo Gate + CS-Lockout Harass Guard + 36-Ray Detonation-Clearance Dodge Solver + Live Threat-Center Sightline Offset + Staircase Aggro Denial)
local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local S = require("bots/nevermore/souls")
local L = require("bots/nevermore/lasthit")
local P = require("bots/nevermore/positioning")
local K = require("bots/nevermore/combat")
local W = require("bots/nevermore/world")
local LN = require("bots/nevermore/lane")
local I = require("bots/nevermore/intent")
local WV = require("bots/nevermore/wave")
local WAR = require("bots/nevermore/war_core")
local WD  = require("bots/nevermore/war_director")
local ET  = require("bots/nevermore/engine_truth")

-- Simulation-only diagnostics: counts every gate of the free-pressure handlers. Outside the
-- simulator (no BOT_SIM_PROBE global) this compiles to a no-op, so the shipped bot pays nothing.
local function FDBG(k)
    if not _G.BOT_SIM_PROBE then return end
    local d = _G.__freeDbg
    if not d then d = {}; _G.__freeDbg = d end
    d[k] = (d[k] or 0) + 1
end

-- Load marker: if this line is missing from the console the file did not load
-- and the stock Valve bot plays instead (look for [VScript] errors).
print("[SF-BOT] bot_nevermore.lua loaded (v7.9.33-pro: 795u-windup-lock + pre-raze-auto-combo + cs-lockout-harass-guard + 36ray-dodge-solver + sightline-offset + staircase-aggro-denial)")

U.DEBUG = false
U._S = S -- Soul-economy hook used by `lasthit.lua` scorer

-- All handlers live in the H table instead of being local functions: works around the
-- Lua 5.1 limit of 60 upvalues per function (otherwise the file does not compile in Dota).
local H = {}

local SAFE_DISTANCE = C.SAFE_DISTANCE or {
    MIN_DISTANCE_FROM_ENEMY = 750,
    MIN_DISTANCE_CRITICAL   = 950,
    CRITICAL_HP_FACTOR      = 1.05,
    KILL_THREAT_FACTOR      = 1.20,
    SINGLE_KILL_FACTOR      = 1.10,
}


local State = {
    hunting                   = false, -- Hunting (see H.ComputeHunt)
    attackTarget              = nil,
    attackStartTime           = 0,
    deaggroTime               = 0,
    prepTarget                = nil,
    prepTargetTime            = 0,
    lhAttackTarget            = nil,
    defensive                 = false,
    defensiveSince            = 0,
    enemyAggroCount           = 0,
    flyingProjectiles         = {},
    firedThisAttack           = false,
    lastAggroTime             = 0,
    aggroPullTime             = 0,
    myCreepAggroCdUntil       = 0,
    myCreepChaseUntil         = 0,
    lastAggroPrimeAt          = -100,
    lastItemUseTime           = 0,
    lastHarassTime            = 0,
    needsTP                   = false,
    tpOrderTime               = -100,
    -- Commitment to "finish" or "run" (prevents fight<->flee flapping)
    commitKillUntil           = 0,
    fleeUntil                 = 0,
    -- Enemy is teleporting to its T1 (TP channel visible / respawned after death)
    enemyTPIncomingUntil      = 0,
    enemyWasAlive             = true,
    aimingRaze                = nil,
    aimingTarget              = nil,
    aimingLoc                 = nil,
    aimingStartTime           = 0,
    aimingValidationRadius    = nil,
    forcedRetreatLoc          = nil,
    forcedRetreatUntil        = 0,
    -- Commitment to walk out of the enemy T1 (point + deadline)
    towerEscapeLoc            = nil,
    towerEscapeUntil          = 0,
    nearChainUntil            = 0, -- Window for the follow-up raze chain after punishing an enemy that walked up to us
    lastMoveLoc               = nil,
    lastMoveTime              = 0,
    emergencyRetreat          = nil,
    emergencyRetreatStartTime = 0,
    emergencyTPQueued         = false,
    glyphUsedForDive          = false,
    glyphDiveTime             = 0,
    lastForceSalveTime        = 0,
    enemyT1ClosestCreepDist   = nil,
    enemyT1ClosestCreepTime   = 0,
    actionTaken               = false,
    holdPos = false,
    goingToFountain           = false,
    fountainReason            = nil,
    enemyReachedLevel2First   = false,
    heroAttackTarget          = nil,
    heroAttackTime            = 0,
    _lastSalveAutoBuyTime     = 0,
    -- Tango: sticky tree choice (fixes oscillating between trees)
    tangoTree                 = nil,
    tangoCastAt = 0,
    tangoFails = 0,
    tangoTreeLoc              = nil,
    tangoChosenAt             = 0,
    tangoBestDist             = math.huge,
    tangoBadTree              = nil,
    tangoBadTreeTime          = 0,
    -- Dodging the enemy raze
    dodgeLoc                  = nil,
    dodgeUntil                = 0,
    -- Turn-rate asymmetry 1v0 slip & 2v1 double-stack combo state (`v7.9.26-pro`)
    turnAbuseCombo            = nil,
    postRazeDisengagePureRadialUntil = 0,
    -- Intent and context
    intent                    = "FARM",
    lastIntentPrint           = 0,
    siegeWaitUntil            = 0,
}

-- Context for the intent FSM (reused, no per-tick allocation)
local IntentCtx = {
    enemy = false, race = nil, myHpPct = 1, myRazes = 0, healing = false,
    enemyDist = 99999, enemyDistToWave = 99999, enemyAbsent = false,
    enemyUnderHisTower = false, canCatch = true, underEnemyTower = false,
}

-- Hook for utils (glyph for a dive): "we are really committing" = aiming a raze / hit a hero <= 1 s ago
U._State = State -- Test hook: State access from the tooling
U._engagedCheck = function(bot, enemy)
    if State.aimingRaze then return true end
    if (GameTime() - (State.heroAttackTime or -10)) <= 1.0 then return true end
    return false
end

-- force=true: micro-steps (turning for a raze, dodging) must not be swallowed by deduplication.
function H.SmartMove(bot, loc, threshold, force, stackAbility)
    if not loc then return false end
    if State.actionTaken then return false end
    local botLoc = bot:GetLocation()
    -- Smooth tangential obstacle & tower hull steering on real navigation moves (`> 55u`, never altering micro-turns!)
    if not force then
        loc = U.SteerAroundObstacles(bot, loc, W.s)
    end
    -- `v7.9.10-pro` Universal Cliff-Safe Passability + Live Enemy-Coil No-Entry Law (`2048` `#55` `277u -> 235u` Fix!):
    loc = U.EnsurePassable(bot, loc)
    local enemy = (H._enemyHeroNear and U.CanQuery(H._enemyHeroNear) and H._enemyHeroNear:IsAlive()) and H._enemyHeroNear or nil
    if enemy and U.CanQuery(enemy) and botLoc and not State.dodgeLoc and K.EnemyPhase then
        local phLbl = K.EnemyPhase()
        if phLbl then
            local liveCenter = K.EnemyRazeCenter(enemy, phLbl)
            local rHero = (C.RAZE and C.RAZE.HERO_EFF_RADIUS) or 274
            local dBotC = U.DistanceBetweenLocations(botLoc, liveCenter)
            local dLocC = U.DistanceBetweenLocations(loc, liveCenter)
            local enHpMove = enemy:GetHealth() or 9999
            local canFinishMove = (enHpMove <= 175) and ((bot:GetHealth() or 0) > K.EnemyRazeDamage(bot, enemy, 1) + 185)
            if not canFinishMove and dBotC >= rHero - 2 and dLocC < rHero + 24 then
                local radOut = (dBotC > 1) and (botLoc - liveCenter):Normalized() or (P.GetFountain(bot) - liveCenter):Normalized()
                loc = U.EnsurePassable(bot, liveCenter + radOut * (rHero + 42))
            end
        end
    end
    if not force and botLoc and U.DistanceBetweenLocations(botLoc, loc) <= 22 then
        State.actionTaken = true
        return true
    end
    if enemy and not State.forcedRetreatLoc and not State.survivalLoc and not State.towerEscapeLoc
        and not K.StackLeadStepSafe(bot, enemy, loc)
        and not H.StackLeadThirdRazeOK(bot, enemy, stackAbility, loc, W.s) then return false end
    threshold = threshold or 60
    local now = GameTime()
    local last = State.lastMoveLoc
    if force then
        if last and (now - State.lastMoveTime) < 0.1 and U.DistanceBetweenLocations(last, loc) <= 4 then
            State.actionTaken = true
            return true
        end
    elseif last and (now - State.lastMoveTime) < 0.6 then
        if U.DistanceBetweenLocations(last, loc) <= threshold then
            -- A move order to this point was already issued recently: treat it as in progress (actionTaken),
            -- otherwise the next handler overrides it and everything reverses on the next tick.
            State.actionTaken = true
            return true
        end
        -- Anti-Reversal Hysteresis (`9068560663.dem` + `v7.9.19` `9080125239.dem` Anti-Jitter Stabilization):
        -- Block sharp >= 105-deg ambient move reversals (`dot < -0.25`) within 0.48s when no emergency
        -- dodge/tower/retreat override is active, eliminating bang-bang movement twitching across handlers!
        local urgentOverride = State.forcedRetreatLoc or State.survivalLoc or State.towerEscapeLoc
            or State.dodgeLoc or State.urgentMoveOverride
        if not urgentOverride and botLoc and (now - State.lastMoveTime) < 0.48 then
            local prevDx, prevDy = last.x - botLoc.x, last.y - botLoc.y
            local newDx, newDy = loc.x - botLoc.x, loc.y - botLoc.y
            local prevL = math.sqrt(prevDx * prevDx + prevDy * prevDy)
            local newL = math.sqrt(newDx * newDx + newDy * newDy)
            if prevL > 35 and newL > 35 then
                local dot = (prevDx * newDx + prevDy * newDy) / (prevL * newL)
                if dot < -0.25 then
                    State.actionTaken = true
                    return true
                end
            end
        end
    end
    State.lastMoveLoc = loc
    State.lastMoveTime = now
    bot:Action_MoveToLocation(loc)
    State.actionTaken = true
    return true
end

function H.ClearMoveCache()
    State.lastMoveLoc = nil
    State.lastMoveTime = 0
end

function H.SmartFace(bot, point, stackAbility)
    if not bot or not point then return false end
    local botLoc = bot:GetLocation()
    if not botLoc then return false end
    if U.FacingCos and U.FacingCos(bot, point) >= 0.994 then
        return true
    end
    local dist = U.DistanceBetweenLocations(botLoc, point)
    local step = (C.RAZE and C.RAZE.TURN_STEP) or 36
    local stepLoc = (dist > step + 10) and (botLoc + (point - botLoc):Normalized() * step) or point
    if not stackAbility and bot.Action_MoveDirectly then
        bot:Action_MoveDirectly(stepLoc)
        State.lastMoveLoc = stepLoc
        State.lastMoveTime = GameTime()
        State.actionTaken = true
        return true
    end
    return H.SmartMove(bot, stepLoc, 16, true, stackAbility)
end

function H.ClearRazeState()
    State.shortCombatCast = nil
    State.aimingRaze = nil
    State.aimingTarget = nil
    State.aimingLoc = nil
    State.aimingStartTime = 0
    State.aimingValidationRadius = nil
    State.aimingFollowup = nil
    State.aimingMustHitHero = nil
    State.aimingLastEnemyVel = nil
    State.pumpFakeCancelAt = nil
    State.aimingProactiveZone = nil
end

function H.StartRazeCast(ability, target, loc, validationRadius, isCS, mustHitHero)
    State.aimingFollowup = nil
    State.aimingMustHitHero = mustHitHero or nil
    State.aimingLastEnemyVel = nil
    if target and U.CanQuery(target) and target.GetVelocity then
        local okV, tv = pcall(target.GetVelocity, target)
        if okV and tv and tv.x then State.aimingLastEnemyVel = tv end
    end
    State.lastRazeOrderTime = GameTime()
    local isHeroTarget = target and target.IsHero and target:IsHero()
    if isHeroTarget and U.CanQuery(target) then
        local age = U.GetRecentEnemyRazeHitAge(target)
        if age <= C.RAZE.MIRROR_INSTANT_SEC then
            State.mirrorAnsweredEnemy = target
            State.mirrorAnsweredHit = GameTime() - age
        end
        local data = U.GetRazeAbilityData(ability)
        local chain = State.razeFollowup
        if chain and chain.enemy == target and GameTime() <= chain.untilTime then
            State.aimingFollowup = chain
            State.razeFollowup = nil -- The second cast consumes, never renews, this plan.
        elseif data and (data.label == "far" or data.label == "mid") then
            State.razeFollowup = {
                enemy = target, label = data.label == "far" and "mid" or "far",
                opened = GameTime(), untilTime = GameTime() + 2.5,
                stacks = U.GetShadowrazeDebuff(target),
            }
        end
    end
    State.aimingRaze = ability
    State.aimingTarget = target
    State.aimingLoc = loc
    State.aimingStartTime = GameTime()
    State.aimingValidationRadius = validationRadius or C.RAZE.HIT_RADIUS
    State.aimingIsCS = (isCS == true) or (target ~= nil and not isHeroTarget)
    State.actionTaken = true
end

function H.HandleActiveRazeValidation(bot)
    if not State.aimingRaze then return false end
    local now = GameTime()
    if bot:IsUsingAbility() or bot:IsChanneling() then
        local elapsed = now - State.aimingStartTime
        -- Do not cancel a completed cast just because the target moves during backswing.
        if elapsed >= C.RAZE.CAST_POINT and not State.aimingRaze:IsInAbilityPhase() then
            local finData = U.GetRazeAbilityData(State.aimingRaze)
            if finData and State.aimingTarget and State.aimingTarget.IsHero and State.aimingTarget:IsHero()
                and ((State.aimingRaze:GetCooldownTimeRemaining() or 0) > 4.5) then
                State.justDetonatedHeroRazeLabel = finData.label
                State.justDetonatedHeroRazeAt = now
            end
            H.ClearRazeState()
            return false
        end
        local remaining = math.max(0, C.RAZE.CAST_POINT - elapsed)

        local data = U.GetRazeAbilityData(State.aimingRaze)
        if not data then
            bot:Action_ClearActions(true)
            H.ClearRazeState()
            H.ClearMoveCache()
            return true
        end

        local enemyNow = H._enemyHeroNear

        -- Deliberate `0.28s` Pro Pump-Fake Cancel (`v7.9.8-pro` `1630 @ 04:10.27` `rzD=189u` & `04:37.27` `rzD=116u` Fix!):
        -- Keep the real `E(700)` cast whenever `(bot:GetMana() >= 150)` AND predicted impact is a solid `<= 185u` hit
        -- (not just when `walkedInward`!), so we NEVER self-cancel a guaranteed centered coil!
        if State.pumpFakeCancelAt and elapsed >= (State.pumpFakeCancelAt - State.aimingStartTime) then
            local keepRealHit = false
            if enemyNow and U.CanQuery(enemyNow) and enemyNow:IsAlive() then
                local eImp = U.PredictPosition(enemyNow, remaining)
                local bNowP = bot:GetLocation()
                local impErr = U.GetRazeHitErrorWithCurrentFacing(bot, eImp, data.center)
                local walkedInward = State.aimingLoc
                    and (U.DistanceBetweenLocations(bNowP, enemyNow:GetLocation()) <= U.DistanceBetweenLocations(bNowP, State.aimingLoc) - 20)
                if (walkedInward and impErr <= 115) or ((bot:GetMana() or 0) >= 150 and impErr <= 185) then
                    keepRealHit = true
                end
            end
            State.pumpFakeCancelAt = nil
            if not keepRealHit then
                bot:Action_ClearActions(true)
                H.ClearRazeState()
                H.ClearMoveCache()
                return true
            end
        end

        -- Check whether live enemy hero (visible OR just stepped into river/highground FoW `<= 0.65s` ago while still alive!)
        -- lands inside this exact coil (`<= 262u` inside Source 2 `250 + 24 = 274u` hero hull hit radius!), OR another creep dies!
        local leadHero = math.min(remaining, 0.04)
        local enemyHitByCoil = false
        if enemyNow and U.CanQuery(enemyNow) and enemyNow:IsAlive() and (enemyNow:GetHealth() or 0) > 0 then
            local eNowLoc = enemyNow:GetLocation()
            if enemyNow.GetVelocity then
                local okV, ev = pcall(enemyNow.GetVelocity, enemyNow)
                if okV and ev and ev.x then State.aimingLastEnemyVel = ev end
            end
            local ePred = U.PredictPosition(enemyNow, remaining + leadHero)
            -- `auto-20261102-0159` `11:05.3` Whiff #1 + `9072025270` `02:49.73` Fix:
            -- On CS-centered dual-value coils (`State.aimingIsCS`), tighten hero containment (`254u` predicted & `264u` live)
            -- so an outer-rim hero walking away never keeps a doomed CS coil alive!
            local predLimH = State.aimingIsCS and (C.RAZE.HIT_RADIUS + 2) or (C.RAZE.HIT_RADIUS + 3)
            if (U.GetRazeHitErrorWithCurrentFacing(bot, ePred, data.center) <= predLimH
                    and (not State.aimingIsCS or U.GetRazeHitErrorWithCurrentFacing(bot, eNowLoc, data.center) <= (C.RAZE.HIT_RADIUS + 4)))
                or (remaining <= 0.10 and U.GetRazeHitErrorWithCurrentFacing(bot, eNowLoc, data.center) <= (C.RAZE.HIT_RADIUS + 2)) then
                enemyHitByCoil = true
            end
        elseif W.s and W.s.enemyAlive ~= false and (W.s.enemyAbsentFor or 99) <= 0.65 and W.s.enemyLastLoc then
            -- `auto-20261102-0159` `17:02.4` Whiff #2 Night-FoW Fix:
            -- Extrapolate `enemyLastLoc` along last-known velocity across `(enemyAbsentFor + remaining)` and require BOTH
            -- `enemyLastLoc` AND `fogPred` to sit strictly inside the `250u` coil (`<= 254u`), so an enemy walking past
            -- `800u` night vision (`395u` outside `W(450)`) is cancelled cleanly instead of blindly firing into empty FoW!
            local fogLoc = W.s.enemyLastLoc
            local dtFog = math.min(1.0, (W.s.enemyAbsentFor or 0) + remaining)
            local lv = State.aimingLastEnemyVel
            local fogPred = (lv and lv.x)
                and Vector(fogLoc.x + lv.x * dtFog, fogLoc.y + lv.y * dtFog, fogLoc.z or 128)
                or fogLoc
            if U.GetRazeHitErrorWithCurrentFacing(bot, fogLoc, data.center) <= (C.RAZE.HIT_RADIUS + 4)
                and U.GetRazeHitErrorWithCurrentFacing(bot, fogPred, data.center) <= (C.RAZE.HIT_RADIUS + 2) then
                enemyHitByCoil = true
            end
        end

        local otherKillableCreepInCoil = false
        if State.aimingIsCS and W.s and W.s.enemyCreeps then
            local rawBase = U.GetRazeDamage(bot, State.aimingRaze, 0)
            for _, oc in pairs(W.s.enemyCreeps) do
                if oc ~= State.aimingTarget and U.CanQuery(oc) and oc:IsAlive() and (oc:GetHealth() or 0) > 0 then
                    local magicDmg = math.floor(oc:GetActualIncomingDamage(rawBase, DAMAGE_TYPE_MAGICAL))
                    local ocPred = U.PredictPosition(oc, remaining)
                    if (oc:GetHealth() or 9999) <= magicDmg
                        and U.GetRazeHitErrorWithCurrentFacing(bot, oc:GetLocation(), data.center) <= (C.RAZE.HIT_RADIUS - 8)
                        and U.GetRazeHitErrorWithCurrentFacing(bot, ocPred, data.center) <= (C.RAZE.HIT_RADIUS - 10) then
                        otherKillableCreepInCoil = true
                        break
                    end
                end
            end
        end

        -- `9056774541.dem` `03:07.63` + `auto-20261102-0159.dem` `17:02.4` Whiff #2 Fix:
        --   1. When a river/staircase creep dies mid-cast and the enemy drops into FoW, keep the cast ONLY when
        --      `enemyHitByCoil` (computed above from `W.s.enemyLastLoc` + velocity!) confirms they are actually inside the coil!
        --   2. NEVER S-cancel a Dual-Value CS coil when `enemyHitByCoil` OR `otherKillableCreepInCoil` holds!
        local aimingHeroRef = (State.aimingTarget ~= nil) and (not State.aimingIsCS)
        local tgtAlive = U.CanQuery(State.aimingTarget)
            and State.aimingTarget:IsAlive()
            and (State.aimingTarget:GetHealth() or 0) > 0
        if not tgtAlive then
            if enemyHitByCoil or otherKillableCreepInCoil then
                return true
            end
            State.mirrorAnsweredHit = nil
            State.razeFollowup = State.aimingFollowup
            bot:Action_ClearActions(true)
            H.ClearRazeState()
            H.ClearMoveCache()
            return true
        end

        -- `auto-20261102-0159.dem` `11:05.3` Whiff #1 Premature Creep-Death Abort:
        -- If `State.aimingTarget` is a CS creep (`e.g. 14 HP under T1`) and incoming allied tower/creep attacks will kill it
        -- BEFORE `remaining` elapses while neither `enemyHitByCoil` nor `otherKillableCreepInCoil` holds, S-cancel now (`0` MP)!
        local prematureCreepDeath = false
        if State.aimingIsCS and remaining >= 0.066 and W.s and U.PredictHP then
            local incomingOnTarget = U.MergeLists(W.s.allyCreeps, W.s.allyTowers)
            local okHp, hpBeforeDet = pcall(U.PredictHP, State.aimingTarget, math.max(0.033, remaining - 0.033), "min", incomingOnTarget)
            if okHp and type(hpBeforeDet) == "number" and hpBeforeDet <= 0 then
                prematureCreepDeath = true
            end
        end

        -- `v7.9.19` (`9080125239.dem` `B#06 @ tk=6426` `dRC = 268.9u` Whiff + `H#01/02/05` Mutual-Cast Dodge Override!):
        --   1. Replay-calibrated SF hull truth: `254.4u` hits (`H#02`, `tk=10344`) while `268.9u` WHIFFS (`B#06` `tk=6426`)!
        --      Previously `C.RAZE.HIT_RADIUS + 18` (`268u`!) let `267.9u` pass at `remaining = 0.13s`, wasting `75 MP` & `9s CD`!
        --      Tighten hero validation to `254u` (`remaining > 0.16s`) and `252u..253u` (`0.055s <= remaining <= 0.16s`)!
        --   2. Mutual-Cast Dodge Priority: if we JUST started a non-lethal hero raze (`elapsed <= 0.22s`, `remaining >= 0.33s`)
        --      while the enemy SF is ALREADY further into his own Shadowraze windup (`enRem < remaining - 0.05s`) that covers us
        --      and we can step outside `258u` within `enRem`, abort our early windup (`0 MP, 0 CD`) and dodge his coil first!
        if aimingHeroRef and not State.aimingIsCS and elapsed <= 0.22 and remaining >= 0.33
            and enemyNow and U.CanQuery(enemyNow) and enemyNow:IsAlive() and K.EnemyPhase then
            local enPhLbl, _, enPhRem = K.EnemyPhase()
            if enPhLbl and enPhRem and enPhRem < (remaining - 0.05) then
                local enCenterNow = K.EnemyRazeCenter(enemyNow, enPhLbl)
                local dToEnCoil = enCenterNow and U.DistanceBetweenLocations(bot:GetLocation(), enCenterNow) or 999
                local oneMyRaze = (U.GetNRazeDamage and U.GetNRazeDamage(bot, enemyNow, 1)) or 150
                local nonLethalMyCast = (enemyNow:GetHealth() or 9999) > (oneMyRaze + 85)
                local myMsNow = bot:GetCurrentMovementSpeed() or 305
                if nonLethalMyCast and dToEnCoil <= 258 and (dToEnCoil + enPhRem * myMsNow) >= 260 then
                    State.mirrorAnsweredHit = nil
                    bot:Action_ClearActions(true)
                    H.ClearRazeState()
                    H.ClearMoveCache()
                    return false
                end
            end
        end

        local effLead = aimingHeroRef and math.min(remaining, 0.04) or (C.RAZE.LAND_LEAD or 0.08)
        local predicted = U.PredictPosition(State.aimingTarget, remaining + effLead)
        local error = U.GetRazeHitErrorWithCurrentFacing(bot, predicted, data.center)
        local limit
        local isProactiveZone = (State.aimingProactiveZone == true) and aimingHeroRef
        if isProactiveZone then
            if remaining > 0.16 then
                limit = C.RAZE.HIT_RADIUS + 8
                if enemyNow and U.CanQuery(enemyNow) and enemyNow:IsAlive() then
                    local dLiveZ = U.DistanceBetweenLocations(bot:GetLocation(), enemyNow:GetLocation())
                    if math.abs(dLiveZ - data.center) <= 260 then
                        return true
                    end
                end
            else
                local exactImp = U.PredictPosition(State.aimingTarget, remaining)
                local exactErr = U.GetRazeHitErrorWithCurrentFacing(bot, exactImp, data.center)
                if exactErr <= (C.RAZE.HIT_RADIUS + 2) then
                    return true
                end
                limit = -1 -- Force clean 0-MP S-cancel below!
            end
        elseif aimingHeroRef then
            local heroHullLimit = (remaining <= 0.16) and (C.RAZE.HIT_RADIUS + 3) or (C.RAZE.HIT_RADIUS + 4)
            limit = math.min((State.aimingValidationRadius or C.RAZE.HIT_RADIUS) + 4, heroHullLimit)
            if remaining <= 0.16 then
                local exactImp = U.PredictPosition(State.aimingTarget, remaining)
                local exactErr = U.GetRazeHitErrorWithCurrentFacing(bot, exactImp, data.center)
                if exactErr <= (C.RAZE.HIT_RADIUS + 3) then
                    return true
                end
                limit = -1
            end
        else
            limit = math.min(State.aimingValidationRadius or C.RAZE.HIT_RADIUS, C.RAZE.HIT_RADIUS) - 10
        end

        -- For Dual-Value CS coils:
        --   1. NEVER abort if enemyHero (or a 2nd killable creep) is still inside the coil!
        --   2. DO abort (`0` mana, `0s` CD!) if `State.aimingMustHitHero` was required to justify a 1-melee-creep raze
        --      and `enemyHero` escaped outside the coil (`9072025270.dem` `02:49.73` `#24` Fix)!
        local lostRequiredHero = State.aimingIsCS
            and (State.aimingMustHitHero ~= nil)
            and (elapsed >= 0.08)
            and (not enemyHitByCoil)
            and (not otherKillableCreepInCoil)
        if ((error > limit or prematureCreepDeath) and not (State.aimingIsCS and (enemyHitByCoil or otherKillableCreepInCoil)))
            or lostRequiredHero then
            if isProactiveZone and not prematureCreepDeath then
                -- Clean defensive zone-denial S-cancel (`0` MP, `0` CD): anti-loop throttle for `1.05s` unless enemy steps `42u` deeper!
                State.proactiveZoneCancelUntil = now + 1.05
                if enemyNow and U.CanQuery(enemyNow) then
                    State.proactiveZoneCancelDist = U.DistanceBetweenLocations(bot:GetLocation(), enemyNow:GetLocation())
                end
            elseif aimingHeroRef or lostRequiredHero then
                U._lastHeroRazeCancel = now
            end
            State.mirrorAnsweredHit = nil -- A cancelled cast has not answered the hit.
            State.razeFollowup = State.aimingFollowup
            bot:Action_ClearActions(true)
            H.ClearRazeState()
            H.ClearMoveCache()
        end
        return true
    end

    if now > (State.aimingStartTime or 0) + 1.0 then
        H.ClearRazeState()
    end

    return false
end

function H.SafeClearActions(bot)
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    bot:Action_ClearActions(true)
    H.ClearMoveCache()
    return true
end

-- Power Treads (`v7.8.0` Pro Attribute Discipline — `9070886384.dem` `06:53–07:45` Fix):
-- * `SURVIVE` (`STR = 0`) ONLY when genuinely threatened (retreating, `< 38% HP` / `< 340 HP`, or close lethal/2-stack danger).
-- * `CAST` (`INT = 2`) right before casting Shadowraze (unless close-combat `STR` lock already has `>= 85 MP`).
-- * `FIGHT` (`AGI = 1`, `+10 Damage & +10 Attack Speed`) whenever attacking Enemy Hero, Enemy Tower, pushing, or farming safely!
function H.ShouldLockStrengthTreads(bot)
    local now = GameTime()
    if now < (State.castTreadsHoldUntil or -100) then
        return false
    end
    local cfg = C.TREADS or {}
    local curHp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth())
    local hpPct = curHp / maxHp
    local activeForcedRetreat = (State.forcedRetreatLoc ~= nil) and (now < (State.forcedRetreatUntil or 0))
    local enemy = W and W.s and W.s.enemy
    local enemyLive = enemy and U.CanQuery(enemy) and enemy:IsAlive()
    local dEnemy = enemyLive and (W.s.enemyDist or GetUnitToLocationDistance(bot, enemy:GetLocation())) or 9999
    if State.intent == I.RETREAT or State.emergencyRetreat or State.goingToFountain then
        return true
    end
    -- `v7.9.24-pro` (`auto-20261108-1523` `06:24..07:15` Zombie `forcedRetreatLoc` STR-Lock Fix):
    -- Only lock `STR` on an active `forcedRetreatLoc` (`now < forcedRetreatUntil`) when genuinely threatened
    -- (`hpPct < 0.72` or live enemy `<= 1200u` or recently hit by tower), NEVER on a `100% HP` uncontested T1 step-out!
    if activeForcedRetreat and (hpPct < 0.72 or dEnemy <= 1200 or (bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(1.4))) then
        return true
    end
    if hpPct < math.max(cfg.SURVIVE_HP_PCT or 0.30, 0.38) or curHp < 340 then
        return true
    end
    if enemyLive and dEnemy <= 1020 then
        local R = K._race
        local myStacks, myRem = U.GetShadowrazeDebuff(bot)
        local enPot = U.GetPotentialManaForRaze(enemy)
        if (R and R.valid and (R.heCanKillNow or R.heCanKillSoon or curHp <= (R.enBurstSoon or 0) + 150))
            or ((myStacks or 0) >= 2 and (myRem or 0) > 0.45 and enPot >= 75)
            or hpPct < 0.48 then
            return true
        end
    end
    return false
end

function H.ManageTreads(bot, mode)
    if not U.HasItem(bot, "item_power_treads") then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local cfg = C.TREADS or {}
    local opts = nil
    local curHp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth())
    local hpPct = curHp / maxHp
    local curMana = bot:GetMana() or 0
    local enemyDist = (W and W.s and W.s.enemy and U.CanQuery(W.s.enemy) and W.s.enemy:IsAlive())
        and (W.s.enemyDist or GetUnitToLocationDistance(bot, W.s.enemy:GetLocation()))
        or 9999
    local needStr = H.ShouldLockStrengthTreads(bot)
    if mode == "CAST" then
        -- `v7.9.13-pro` (`0210 @ 11:24.40..11:25.80` 30x `STR<->INT` Infinite Paralysis Loop Fix!):
        -- In dangerous close combat (`enemyDist <= 1080` and `needStr or hpPct < 0.56`):
        --   * If `curMana >= 75`, DO NOT toggle `STR -> INT` (`return false` so `CastOrTurnRaze` fires `Action_UseAbility`
        --     IMMEDIATELY on this tick without stripping `-220 MaxHP` or triggering `SURVIVE` revert next tick!).
        --   * Only toggle `STR -> INT` under `needStr` when `curMana >= 63 and curMana < 75` (so `+120 MaxMP` lifts us across `75 MP`),
        --     and hold `State.castTreadsHoldUntil` for `0.22s` so `ShouldLockStrengthTreads` NEVER reverts `INT -> STR` mid-cast!
        if enemyDist <= 1080 and (needStr or hpPct < 0.56) then
            if curMana >= 75 or curMana < 63 then
                return false
            end
            local switched = U.UpdatePowerTreads(bot, "CAST", { oneUseOnly = false, urgent = true, hold = 0.30 })
            if switched then
                State.castTreadsHoldUntil = GameTime() + 0.22
            end
            return switched
        end
        opts = { oneUseOnly = false, urgent = true, hold = 0.30 }
    elseif mode == "SURVIVE" then
        if GameTime() < (State.castTreadsHoldUntil or -100) then
            return false
        end
        opts = { urgent = true, hold = 1.15 }
    else
        if needStr then
            mode = "SURVIVE"
            opts = { urgent = (hpPct < 0.38 or curHp < 340), hold = 1.10 }
        else
            mode = "FIGHT"
            opts = { hold = math.min(cfg.MODE_HOLD or 0.85, 0.85) }
        end
    end
    return U.UpdatePowerTreads(bot, mode, opts)
end

-- Safe non-cancelling Power Treads toggle helper: NEVER interrupts casts, active attack windups, or imminent CS!
-- `allowDuringCSSlack = true` is passed by `L.ExecutePhaseLockedCS` (`freshDelta >= 9`) and `L.RunSacredCS` (`bestPlan == nil`)
-- so `L._imminentCS` pre-marking NEVER self-deadlocks Power Treads on `STR` during wave farming!
function H.TrySafeTreadsSwitch(bot, mode, allowDuringCSSlack)
    if State.actionTaken then return false end
    if not U.HasItem(bot, "item_power_treads") then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local curTick = math.floor(GameTime() * 30.0 + 0.5)
    local rec = U._unitTrack and U._unitTrack[bot]
    if rec and rec.wasAnim == true and rec.launchTick and rec.launchTick >= curTick then
        return false
    end
    if W and W.s and W.s.enemy and H.IsHeroWindupNow and H.IsHeroWindupNow(bot, W.s.enemy) then
        return false
    end
    if (not allowDuringCSSlack) and L and L._imminentCS then return false end
    if H.ManageTreads(bot, mode or "FIGHT") then
        State.actionTaken = true
        return true
    end
    return false
end

function H.SteerClearOfAllyT2Hull(bot, targetLoc, enemyLoc)
    if not (bot and targetLoc) then return targetLoc end
    local ws = W and W.s or nil
    local t2L = (ws and ws.allyT2Alive and ws.allyT2Loc) or nil
    if not t2L then return targetLoc end
    local bLoc = bot:GetLocation()
    local seg = targetLoc - bLoc
    local segLen = math.sqrt(seg.x * seg.x + seg.y * seg.y)
    if segLen <= 35 then return targetLoc end
    local sx, sy = seg.x / segLen, seg.y / segLen
    local rx2, ry2 = t2L.x - bLoc.x, t2L.y - bLoc.y
    local dToT2 = math.sqrt(rx2 * rx2 + ry2 * ry2)
    local proj2 = rx2 * sx + ry2 * sy
    if dToT2 <= 25 or proj2 <= -20 or proj2 >= segLen + 60 then return targetLoc end
    local cx2 = bLoc.x + sx * math.max(0, math.min(segLen, proj2))
    local cy2 = bLoc.y + sy * math.max(0, math.min(segLen, proj2))
    local dSegT2 = math.sqrt((t2L.x - cx2) * (t2L.x - cx2) + (t2L.y - cy2) * (t2L.y - cy2))
    if dSegT2 >= 205 then return targetLoc end
    local ux2, uy2 = rx2 / dToT2, ry2 / dToT2
    local pA = Vector(-uy2, ux2, 0)
    local pB = Vector(uy2, -ux2, 0)
    local pullLead = (dToT2 > 235) and -45 or 85
    local cA = Vector(t2L.x + ux2 * pullLead + pA.x * 248, t2L.y + uy2 * pullLead + pA.y * 248, bLoc.z)
    local cB = Vector(t2L.x + ux2 * pullLead + pB.x * 248, t2L.y + uy2 * pullLead + pB.y * 248, bLoc.z)
    local eRef = enemyLoc or (ws and ws.enemy and U.CanQuery(ws.enemy) and ws.enemy:GetLocation()) or nil
    local chosen = (eRef and U.DistanceBetweenLocations(cA, eRef) < U.DistanceBetweenLocations(cB, eRef)) and cB or cA
    return U.EnsurePassable(bot, chosen)
end

function H.BeginForcedRetreat(bot, loc, duration)
    if not loc then return false end
    local now = GameTime()
    local bLoc = bot:GetLocation()
    -- Project short retreat targets cleanly AND steer around T1 tower hulls & creep walls (`v4.2.0` `Demo 1` `2:47` & `4:10` Fix!)
    local stepDist = U.DistanceBetweenLocations(bLoc, loc)
    if stepDist < 220 then
        local fnt = P.GetFountain(bot)
        local dir = (stepDist > 4) and (loc - bLoc):Normalized() or (fnt - bLoc):Normalized()
        loc = bLoc + dir * 240
    end
    local same = State.forcedRetreatLoc ~= nil
        and U.DistanceBetweenLocations(State.forcedRetreatLoc, loc) <= 120
        and now < (State.forcedRetreatUntil or 0)
    State.forcedRetreatLoc = loc
    State.forcedRetreatUntil = math.max(State.forcedRetreatUntil or 0, now + (duration or 0.65))
    State.fleeUntil = math.max(State.fleeUntil or 0, now + 1.2)
    State.actionTaken = true
    if not same then
        -- Switch Power Treads to STR on tick 1 ONLY when genuinely threatened (`ShouldLockStrengthTreads`),
        -- NEVER when stepping out of an uncontested tower at full HP with 0 enemy heroes!
        if H.ShouldLockStrengthTreads(bot)
            and (now - (State.lastRetreatTreadsToggleAt or -100)) >= 0.50
            and H.ManageTreads(bot, "SURVIVE") then
            State.lastRetreatTreadsToggleAt = now
            State.lastMoveLoc = nil
            State.lastMoveTime = 0
            return true
        end
        if bot:IsUsingAbility() then
            bot:Action_ClearActions(true)
        end
    end
    local movePt = H.SteerClearOfAllyT2Hull(bot, U.EnsurePassable(bot, U.SteerAroundObstacles(bot, loc, W.s)), nil)
    State.forcedRetreatLoc = movePt
    State.lastMoveLoc = movePt
    State.lastMoveTime = now
    bot:Action_MoveToLocation(movePt)
    return true
end

function H.TickForcedRetreat(bot, s)
    if not State.forcedRetreatLoc then return false end
    local now = GameTime()
    if now >= (State.forcedRetreatUntil or 0) then
        H.ClearForcedRetreat()
        return false
    end
    local bLoc = bot:GetLocation()
    local remDist = U.DistanceBetweenLocations(bLoc, State.forcedRetreatLoc)
    -- Zero-Stall Arrival Rule: NEVER stand idle at `forcedRetreatLoc` waiting for timer expiry!
    if remDist <= 65 then
        local enemy = s and s.enemy
        local dryNeedDist = (enemy and U.CanQuery(enemy) and now < (State.dryRetreatHystUntil or 0))
            and (((U.GetDrySafeStandoffDist and U.GetDrySafeStandoffDist(bot, enemy)) or 745) + 95) or 0
        if enemy and U.CanQuery(enemy)
            and ((U.EnemyApproachSpeed(bot, enemy) > 45 and GetUnitToLocationDistance(bot, enemy:GetLocation()) < 860)
                or (dryNeedDist > 0 and GetUnitToLocationDistance(bot, enemy:GetLocation()) < dryNeedDist)) then
            local fnt = P.GetFountain(bot)
            local ext = bLoc + (fnt - bLoc):Normalized() * 280
            local movePt = U.EnsurePassable(bot, U.SteerAroundObstacles(bot, ext, s or W.s))
            State.forcedRetreatLoc = movePt
            State.lastMoveLoc = movePt
            State.lastMoveTime = now
            bot:Action_MoveToLocation(movePt)
            State.actionTaken = true
            return true
        end
        H.ClearForcedRetreat()
        return false
    end
    return H.SmartMove(bot, State.forcedRetreatLoc, 60)
end

-- `v7.9.1` Exact Right-Click Pursuit Kinematics & Unshielded Enemy-T1 Dive Gate (`9071946472.dem` `02:39.2–02:42.9` Fix!):
-- Prevents suicidal zero-catch right-click chases (`305 MS` vs `305 MS` at `d = 720..853u` under Radiant T1 with `38 MP` & `0` creeps!).
function H.CanKinematicallyCatchForAttack(bot, enemy, enemyTowers, allyCreeps, maxCatchSec)
    if not bot or not enemy or not U.CanQuery(enemy) then return false end
    local bLoc = bot:GetLocation()
    local eLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(bLoc, eLoc)
    local atkReach = (bot:GetAttackRange() or 500) + 32
    if d <= atkReach then
        return true
    end

    local gap = d - atkReach
    local myMS = math.max(260, (bot.GetCurrentMovementSpeed and bot:GetCurrentMovementSpeed()) or 305)
    local enMS = math.max(260, (enemy.GetCurrentMovementSpeed and enemy:GetCurrentMovementSpeed()) or 305)
    local enHome = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_BASE or C.POSITIONS.RADIANT_BASE

    -- `v7.9.3` (`H01` + `auto-20261101-2135` `2:15..2:59` `26–112 HP` Fix!):
    -- Measure REAL enemy outward velocity from live velocity or frame-to-frame position deltas (`U.EnemyOutwardSpeed`),
    -- NEVER inventing `0.65 * enMS` phantom flee speed just because `eLoc` stands on the enemy half of mid!
    local awaySpeed = 0
    local dirToEn = (eLoc - bLoc):Normalized()
    local ev = (enemy.GetVelocity and enemy:GetVelocity()) or nil
    if ev and (math.abs(ev.x or 0) + math.abs(ev.y or 0)) > 15 then
        awaySpeed = (ev.x * dirToEn.x) + (ev.y * dirToEn.y)
    elseif U.EnemyOutwardSpeed then
        awaySpeed = U.EnemyOutwardSpeed(bot, enemy) or 0
    else
        local movingAwayTracker = K.IsEnemyMovingAway and K.IsEnemyMovingAway(bot, enemy)
        local enemyCloserHome = enHome and (U.DistanceBetweenLocations(eLoc, enHome) < U.DistanceBetweenLocations(bLoc, enHome) - 40)
        if movingAwayTracker and enemyCloserHome then
            awaySpeed = enMS * 0.85
        end
    end

    local closeSpeed = myMS - math.max(0, awaySpeed)
    local towers = enemyTowers or (W and W.s and W.s.enemyTowers) or {}
    local allies = allyCreeps or (W and W.s and W.s.allyCreeps) or {}
    local radialOk = (closeSpeed > 14 or gap <= 42)
    local tCatch = radialOk and (gap / math.max(15, closeSpeed)) or 999
    if radialOk and tCatch <= (maxCatchSec or 1.75) then
        local catchTravel = math.min(1200, gap + math.max(0, awaySpeed) * tCatch)
        local catchLoc = bLoc + dirToEn * catchTravel
        local towerSafe = true
        for _, tw in pairs(towers) do
            if tw and U.CanQuery(tw) and tw:IsAlive() then
                local tLoc = tw:GetLocation()
                local shield = LN.TowerShieldCountLoc and LN.TowerShieldCountLoc(tLoc, tw, allies, catchLoc) or 0
                if shield <= 0 and U.DistanceBetweenLocations(catchLoc, tLoc) < 880 then
                    if gap > 40 or H.TowerBurnActive() or (bot:GetHealth() or 0) < 330 then
                        towerSafe = false
                        break
                    end
                end
            end
        end
        if towerSafe then
            return true, nil
        end
    end

    -- `v7.9.25-pro` (`auto-20261108-1609` `02:58..03:06` `12 HP` Enemy Flank Escape 2D Chord-Intercept Fix!):
    -- When a fleeing crippled enemy runs laterally/northward (`(-504,764)->(-940,1041)`) while trapped behind or beside
    -- SF relative to his sanctuary (`dBotSanctuary <= dEnSanctuary + 340`), 1D radial `closeSpeed` is `<= 0` at equal
    -- `305 vs 305 MS`, yet SF's straight 2D chord to his escape path toward `enSanctuary` arrives BEFORE him!
    local wsCatch = W and W.s
    local enSanctuary = (wsCatch and wsCatch.enemyT1Alive ~= false and wsCatch.enemyT1Loc) or enHome
    if enSanctuary and d <= 1520 then
        local dBotSanc = U.DistanceBetweenLocations(bLoc, enSanctuary)
        local dEnSanc  = U.DistanceBetweenLocations(eLoc, enSanctuary)
        if dBotSanc <= dEnSanc + 340 and dEnSanc >= 960 then
            local toSanc = (enSanctuary - eLoc)
            if toSanc:Length2D() > 1 then
                local safePerimeterGoal = enSanctuary + (eLoc - enSanctuary):Normalized() * 945
                local chordMaxSec = math.max(maxCatchSec or 1.80, 4.60)
                for _, alpha in ipairs({ 0.38, 0.54, 0.70, 0.86 }) do
                    local candPt = eLoc + (safePerimeterGoal - eLoc) * alpha
                    local safeTw = true
                    if wsCatch and wsCatch.enemyT1Alive ~= false and wsCatch.enemyT1Loc
                        and U.DistanceBetweenLocations(candPt, wsCatch.enemyT1Loc) < 920 then
                        safeTw = false
                    end
                    if safeTw then
                        for _, tw in pairs(towers) do
                            if tw and U.CanQuery(tw) and tw:IsAlive()
                                and U.DistanceBetweenLocations(candPt, tw:GetLocation()) < 920 then
                                safeTw = false
                                break
                            end
                        end
                    end
                    if safeTw and (type(IsLocationPassable) ~= "function" or IsLocationPassable(candPt)) then
                        local tEn = U.DistanceBetweenLocations(eLoc, candPt) / enMS
                        local tBot = math.max(0, U.DistanceBetweenLocations(bLoc, candPt) - (atkReach - 22)) / myMS
                        if tBot <= (tEn + 0.22) and tBot <= chordMaxSec then
                            return true, candPt
                        end
                    end
                end
            end
        end
    end
    return false, nil
end

-- `v7.9.25-pro` (`auto-20261108-1609` `00:25..01:02` `327+100 -> 27 MP` Level-1 Mana Bankruptcy Guard):
-- Prevents dumping SF's LAST `75 MP` (`leaving < 75 MP` OOM and activating `IsDryVsArmedEnemySF` for 60–90s!) or spamming
-- `0`-stack Level-1 (`62` magic dmg) hero-only pokes below `190 MP` when `0` creeps die and the enemy isn't lethal.
function H.WouldBreakEarlyManaReserve(bot, enemy, ability)
    if not bot or not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local myMana = bot:GetMana() or 0
    local hasReserveItem = (U.GetMangoMana(bot) >= 75)
        or (bot.HasModifier and bot:HasModifier("modifier_clarity_potion"))
    local enPotMana = U.GetPotentialManaForRaze(enemy)
    local enHp = enemy:GetHealth() or 9999
    local d = U.DistanceBetweenLocations(bot:GetLocation(), enemy:GetLocation())
    local oneRaze = U.GetNRazeDamage(bot, enemy, 1)
    local myAtk = K.AttackDamageVs(bot, enemy)
    local nearLethal = enHp <= (oneRaze + ((d <= 555) and myAtk or 0) + 25)
    if nearLethal then return false end

    local enStacks, enRem = U.GetShadowrazeDebuff(enemy)
    enStacks = ((enRem or 0) >= 0.55) and (enStacks or 0) or 0

    -- 1. Never burn our LAST `75 MP` (`myMana < 150` without Mango/Clarity -> `< 75 MP` OOM after cast!) on a non-lethal
    --    hero-only poke against an armed rival (`enPotMana >= 75`), UNLESS landing a 3rd stack (`enStacks >= 2`) or a
    --    2nd stack that drops him critically low (`<= 175 HP`)!
    if myMana < 150 and (not hasReserveItem) and enPotMana >= 75 then
        if enStacks >= 2 or (enStacks >= 1 and (enHp - oneRaze) <= 175) then
            return false
        end
        return true
    end

    -- 2. At Shadowraze Level 1 (`62` hero dmg for `75 MP`), NEVER spend mana below `190 MP` on a `0`-stack hero-only poke
    --    against a healthy (`> 260 HP`) opponent — save `>= 150 MP` for Dual-Value CS+Hero Razes & 2-stack combos!
    local rLvl = (ability and ability.GetLevel and ability:GetLevel())
        or ((bot:GetAbilityByName("nevermore_shadowraze2") and bot:GetAbilityByName("nevermore_shadowraze2"):GetLevel()) or 1)
    if rLvl <= 1 and enStacks == 0 and myMana < 190 and enHp > 260 and enPotMana >= 75 then
        return true
    end
    return false
end

function H.ClearForcedRetreat()
    State.forcedRetreatLoc = nil
    State.forcedRetreatUntil = 0
end

-- `v7.9.8-pro` (`1630 @ 00:32.6..00:36.0` `d=54u` & `03:36.0..03:39.0` `d=59u` Suicide De-Aggro Fix!):
-- Selects an allied lane creep safe for `Action_AttackUnit(ac, true)` aggro reset:
--   1. NEVER pick a split allied creep standing deeper on the enemy side than `enemyHero` (`acDistFnt > enDistFnt + 35`).
--   2. NEVER pick an out-of-attack-range allied creep (`da > maxReach`) unless it lies strictly behind us toward our
--      Fountain (`acDistFnt < botDistFnt - 40`), so `Action_AttackUnit` NEVER walks SF forward into enemy melee range!
function H.FindSafeDeaggroAllyCreep(bot, allyList, enemyHero)
    if not bot or not allyList then return nil, nil end
    local bLoc = bot:GetLocation()
    local fnt = P.GetFountain(bot)
    local botDistFnt = U.DistanceBetweenLocations(bLoc, fnt)
    local maxReach = math.max(500, bot:GetAttackRange() or 500) + 45
    local hasEn = enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
    local enDistFnt = hasEn and U.DistanceBetweenLocations(enemyHero:GetLocation(), fnt) or math.huge

    local bestHealthy, bestHealthyDist = nil, math.huge
    local bestAny, bestAnyDist = nil, math.huge
    for _, ac in pairs(allyList) do
        if ac and U.CanQuery(ac) and ac:IsAlive() and (ac:GetHealth() or 0) > 65 then
            local acLoc = ac:GetLocation()
            local da = GetUnitToLocationDistance(bot, acLoc)
            local acDistFnt = U.DistanceBetweenLocations(acLoc, fnt)
            local safeVsEnemy = (not hasEn) or (acDistFnt <= enDistFnt + 35)
            local noForwardWalk = (da <= maxReach) or (acDistFnt < botDistFnt - 40)
            if safeVsEnemy and noForwardWalk then
                if da < bestAnyDist then
                    bestAnyDist, bestAny = da, ac
                end
                if (ac:GetHealth() or 0) * 2 > (ac:GetMaxHealth() or 550) + 20 and da < bestHealthyDist then
                    bestHealthyDist, bestHealthy = da, ac
                end
            end
        end
    end
    return bestHealthy, bestAny
end

-- Commitment to walk out of the enemy tower (see HandleEnemyTowerSafety)
function H.ClearTowerEscape()
    State.towerEscapeLoc = nil
    State.towerEscapeUntil = 0
end

function H.CastOrTurnRaze(bot, ability, actionType, aimLoc, target)
    if State.combatPolicyActive == true and target and target.IsHero and target:IsHero()
        and not State.heroCombatAllowed then return false end
    if not ability or (target and not U.CanQuery(target)) then return false end
    if target and State.towerChaseBlockedEnemy == target then return false end
    if target and K.HasRazeStackLead(bot, target) then
        local distance = GetUnitToLocationDistance(bot, target:GetLocation())
        if K.EnemyBandsAcross(target, distance, distance, 0.7) > 0
            and not H.StackLeadThirdRazeOK(bot, target, ability, bot:GetLocation(), W.s) then return false end
    end
    if State.actionTaken then return false end
    -- `v7.9.10-pro` (`2048` `#05/#11/#26/#36/#63` `err=934u` 2-Tick Self-Cancel Fix!):
    -- `nevermore_shadowraze1/2/3` are `DOTA_ABILITY_BEHAVIOR_NO_TARGET`, so calling `Action_UseAbility` while `51°` off-axis
    -- cancels the turn order in Source 2 and triggers an instant 2-tick `HandleActiveRazeValidation` self-cancel!
    -- Always require true `H.RazeFacingOK(bot, aimLoc)` + `GetRazeHitErrorWithCurrentFacing <= hitLim` before pressing cast!
    if actionType == "CAST" and aimLoc and not H.RazeFacingOK(bot, aimLoc) then
        actionType = "TURN"
    elseif actionType == "TURN" and aimLoc and H.RazeFacingOK(bot, aimLoc) then
        actionType = "CAST"
    end

    local data = U.GetRazeAbilityData(ability)
    local isUrgentSnapOrKill = false
    if data and target and U.CanQuery(target) then
        local isHeroTarget = target.IsHero and target:IsHero()
        -- `v4.2.0` Strict Raw-Velocity Reach & Anti-Creep-Sliver Gate (`Demo 1` `0:44.47` `d=1050u` & `Demo 2` `0:47.67` `3 HP` Fix!)
        if isHeroTarget then
            if not U.WillRazeStrictlyCoverMovingTarget(bot, ability, target) then
                return false
            end
            local isLethalHeroCoil = (target:GetHealth() or 9999) <= (U.GetNRazeDamage(bot, target, 1) + 15)
            local _, remDebuff = U.GetShadowrazeDebuff(target)
            local enInPhase = K.EnemyPhase() ~= nil
            isUrgentSnapOrKill = isLethalHeroCoil or enInPhase or ((remDebuff or 99) <= 0.78)
            if U.RazeJukeOK and not U.RazeJukeOK(bot, ability, target, isLethalHeroCoil) then
                return false
            end
            if U.HeroRazeRuinsCreepCS(bot, ability, aimLoc, target, W.s) then
                return false
            end
        end
        -- Check the band against both the current and the predicted position (aimLoc): the raze lands
        -- 0.55 s later and an approaching enemy changes band in that time.
        local distNow = GetUnitToLocationDistance(bot, target:GetLocation())
        local errNow = math.abs(distNow - data.center)
        local errPred = errNow
        if aimLoc then
            errPred = math.abs(GetUnitToLocationDistance(bot, aimLoc) - data.center)
        end
        local isHeroBandCheck = target.IsHero and target:IsHero()
        local awayBandSpd = isHeroBandCheck and (U.EnemyOutwardSpeed and U.EnemyOutwardSpeed(bot, target) or 0) or 999
        local maxBandErr = (State._proactiveZoneCastMode and 264)
            or ((isHeroBandCheck and awayBandSpd <= 35) and 258 or (C.RAZE.STRICT_RADIUS + 35))
        if math.min(errNow, errPred) > maxBandErr then
            return false
        end
    end

    if actionType == "TURN" then
        -- Guard against an endless turn: turning 180 degrees takes ~0.1 s,
        -- so TURNing for over 0.45 s means something does not add up (target on the circle edge etc.);
        -- then TURN razes are blocked for 1 s and control goes back to the rest of the logic.
        local now = GameTime()
        if now < (State.razeTurnBlockUntil or 0) then return false end
        if (now - (State.lastTurnTick or -10)) > 0.25 then State.turnSince = now end
        State.lastTurnTick = now
        if (now - (State.turnSince or now)) > 0.45 then
            State.razeTurnBlockUntil = now + 1.0
            State.turnSince = now
            return false
        end
        local botLoc = bot:GetLocation()
        local turnLoc = aimLoc or (target and target:GetLocation()) or botLoc
        State._razeTurnStampAt = now
        return H.SmartFace(bot, turnLoc)
    elseif actionType == "CAST" then
        State._razeTurnStampAt = nil
        -- Every caller, including mirror/finish shortcuts, must cover the landing point (using desired facing when turn-masked!).
        if data and target and U.CanQuery(target) then
            local isHeroTgt2 = target.IsHero and target:IsHero()
            local effLead = State._proactiveZoneCastMode and 0.02 or (isHeroTgt2 and 0.04 or (C.RAZE.LAND_LEAD or 0.08))
            local landing = U.PredictPosition(target, C.RAZE.CAST_POINT + effLead)
            local hitLim = State._proactiveZoneCastMode and 264
                or (isHeroTgt2 and (((C.RAZE and C.RAZE.HERO_EFF_RADIUS) or 274) - 14) or (C.RAZE.HIT_RADIUS - 10))
            if U.GetRazeHitErrorWithCurrentFacing(bot, landing, data.center) > hitLim then
                return false
            end
        end
        -- Before a non-urgent raze switch Power Treads to INT; SKIP the 1-tick Treads delay on urgent lethal / mirror / expiring-stack
        -- coils OR whenever `ShouldLockStrengthTreads` is active and `(bot:GetMana() or 0) >= 75`!
        if not isUrgentSnapOrKill and H.ManageTreads(bot, "CAST") then
            State.actionTaken = true
            return true
        end
        State.castTreadsHoldUntil = nil
        bot:Action_UseAbility(ability)
        H.StartRazeCast(ability, target, aimLoc, C.RAZE.HIT_RADIUS)
        H.ClearMoveCache()
        return true
    end

    return false
end

function H.GetDynamicRazeConeDeg(bot, aimLoc)
    local baseAng = (C.RAZE and C.RAZE.MAX_ANGLE_TO_CAST) or 6
    if not bot or not aimLoc then return baseAng end
    local bLoc = bot:GetLocation()
    if not bLoc then return baseAng end
    local d = math.max(200.0, U.DistanceBetweenLocations(bLoc, aimLoc))
    local dyn = math.deg(math.asin(math.min(0.38, 66.0 / d)))
    return math.max(baseAng, math.min(14.5, dyn))
end

function H.RazeFacingOK(bot, aimLoc)
    if not aimLoc then return true end
    return U.GetAngleDifference(bot, aimLoc) <= H.GetDynamicRazeConeDeg(bot, aimLoc)
end



function H.GetRazeAbilityByLabel(bot, label)
    if label == "near" then return bot:GetAbilityByName("nevermore_shadowraze1") end
    if label == "mid"  then return bot:GetAbilityByName("nevermore_shadowraze2") end
    if label == "far"  then return bot:GetAbilityByName("nevermore_shadowraze3") end
    return nil
end

-- Sort `{ "near", "mid", "far" }` in ascending order of `|predDist - center|` (`9055695956.dem` `tk=12868` `5:28` fix!):
-- At `dist = 663.9u`, `|663.9 - 700| = 36.1u` (`far` dead-center bullseye!) strictly beats `|663.9 - 450| = 213.9u`
-- (`mid` razor-edge that `S`-cancelled when enemy stepped `30u` back!). Reuses a static 3-slot array (zero GC churn).
local _CENTERED_ORDER = { "near", "mid", "far" }
function H.BestCenteredRazeOrder(bot, target)
    local d = 450
    if bot and target and U.CanQuery(target) then
        local pred = U.PredictPosition(target, C.RAZE.CAST_POINT or 0.55)
        d = GetUnitToLocationDistance(bot, pred or target:GetLocation())
        -- `v7.9.19` (`9080125239.dem` `B#06 @ 01:30.83` `557->704u` Post-Attack Kite Fix):
        -- When target is already at `dNow >= 550u` and either moving outward (`vAway >= 18`) or just finished firing an
        -- auto-attack (`<= 0.45s` ago, after which human SFs immediately kite back!), bias `d` outward by `+45u` when `E(700)`
        -- is ready so `"far"` (`E700`) is chosen dead-center instead of outer-rim `"mid"` (`W450`)!
        local dNowOrd = GetUnitToLocationDistance(bot, target:GetLocation())
        local vAwayOrd = (U.EnemyOutwardSpeed and U.EnemyOutwardSpeed(bot, target)) or 0
        local justShotUs = (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(target, 0.55)) or false
        local eAbOrd = bot:GetAbilityByName("nevermore_shadowraze3")
        if dNowOrd >= 550 and eAbOrd and U.IsRazeAbilityCastable(bot, eAbOrd) and (vAwayOrd >= 18 or justShotUs) then
            d = math.max(d, dNowOrd + 55)
        end
    end
    local eNear = math.abs(d - 200)
    local eMid  = math.abs(d - 450)
    local eFar  = math.abs(d - 700)
    if eNear <= eMid and eNear <= eFar then
        _CENTERED_ORDER[1] = "near"
        if eMid <= eFar then _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "mid", "far"
        else _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "far", "mid" end
    elseif eMid <= eNear and eMid <= eFar then
        _CENTERED_ORDER[1] = "mid"
        if eNear <= eFar then _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "near", "far"
        else _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "far", "near" end
    else
        _CENTERED_ORDER[1] = "far"
        if eMid <= eNear then _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "mid", "near"
        else _CENTERED_ORDER[2], _CENTERED_ORDER[3] = "near", "mid" end
    end
    return _CENTERED_ORDER
end

-- Robust: CAST if at the current facing the circle covers the enemy both now and
-- after the cast time; TURN toward the aim point if it covers after turning; otherwise nil.
function H.GetRazeActionType(bot, ability, target)
    if not ability or not target or not U.CanQuery(target) then return nil, nil end
    local data = U.GetRazeAbilityData(ability)
    if not data then return nil, nil end
    local errAim, errFacing, aim = U.RobustRazeErrors(bot, target, data.center, C.RAZE.CAST_POINT)
    local limit = C.RAZE.HIT_RADIUS - (C.RAZE.ROBUST_MARGIN or 30)
    if errFacing <= limit and H.RazeFacingOK(bot, aim) then return "CAST", aim end
    if errAim <= limit then return "TURN", aim end

    -- `v7.6.0` High-Value Hero Impact-Prediction Window (`01:33.67` `R2` & `01:36.7–01:37.6` `R3` Held-Coil Fix!):
    -- Along the radial line from SF, `RobustRazeErrors` capped fleeing `305 u/s` targets at `dNow <= 728u` for `R3`
    -- even though Source 2 hits heroes out to `250 + 24 = 274u` (`d_impact <= 974u`, `dNow <= 806u`) and
    -- `HandleActiveRazeValidation` monitors every `0.033s` tick (S-cancelling for 0 mana / 0 CD if they juke!).
    local isHeroTgt = target.IsHero and target:IsHero()
    if isHeroTgt then
        local enHp = target:GetHealth() or 9999
        local oneDmg = K.MyRazeDamage(bot, target, 1)
        local stacks, rem = U.GetShadowrazeDebuff(target)
        local enPotMana = (target:GetMana() or 0) + U.GetMangoMana(target)
        local highValueWindow = (enHp <= oneDmg + 95)
            or ((stacks or 0) >= 1 and (rem or 0) >= C.RAZE.CAST_POINT + 0.06)
            or (enHp <= 290 and enPotMana < 75 and (bot:GetHealth() or 0) >= 340)
        if highValueWindow then
            local pImp = U.PredictPosition(target, C.RAZE.CAST_POINT) or target:GetLocation()
            local impLimit = C.RAZE.HIT_RADIUS + 6 -- 256u (18u inside true 274.0u hero hull edge)
            local impErrAim = U.GetRazeHitErrorWithDesiredFacing(bot, pImp, data.center)
            local impErrFac = U.GetRazeHitErrorWithCurrentFacing(bot, pImp, data.center)
            if impErrFac <= impLimit and H.RazeFacingOK(bot, pImp) then return "CAST", pImp end
            if impErrAim <= impLimit then return "TURN", pImp end
        end
    end
    return nil, aim
end

function H.GetStickLikeItem(bot)
    local wand = U.GetActiveItemByName(bot, "item_magic_wand")
    if wand and (not wand.GetCurrentCharges or wand:GetCurrentCharges() > 0) then return wand end
    local stick = U.GetActiveItemByName(bot, "item_magic_stick")
    if stick and (not stick.GetCurrentCharges or stick:GetCurrentCharges() > 0) then return stick end
    return nil
end

function H.GetPotentialCombatMana(bot)
    local mana = bot:GetMana() or 0
    local wand = U.GetActiveItemByName(bot, "item_magic_wand")
    if wand and wand.GetCurrentCharges then
        mana = mana + (wand:GetCurrentCharges() or 0) * 15
    end
    local stick = U.GetActiveItemByName(bot, "item_magic_stick")
    if stick and stick.GetCurrentCharges then
        mana = mana + (stick:GetCurrentCharges() or 0) * 15
    end
    mana = mana + U.GetMangoMana(bot) -- By charges
    return mana
end

function H.TryUseBurstManaItem(bot, allowMango)
    local item = H.GetStickLikeItem(bot)
    if not item and allowMango then
        item = U.GetActiveItemByName(bot, "item_enchanted_mango")
    end
    if not item then return false end
    bot:Action_UseAbility(item)
    State.lastItemUseTime = GameTime()
    State.actionTaken = true
    return true
end

function H.IsInHeroAttackAnimation(bot)
    if not State.heroAttackTarget then return false end
    if not State.heroAttackTarget:IsAlive() then
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        return false
    end
    local target = bot:GetAttackTarget()
    if target ~= State.heroAttackTarget then
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        return false
    end
    local elapsed = GameTime() - State.heroAttackTime
    local bat = bot:GetSecondsPerAttack() or 1.7
    if elapsed < bat + 0.1 then
        return true
    end
    State.heroAttackTarget = nil
    State.heroAttackTime = 0
    return false
end

function H.IsSameAttackTarget(bot, target)
    return U.IsAttackingAction(bot) and bot:GetAttackTarget() == target
end

function H.IssueHeroAttack(bot, enemyHero)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.towerChaseBlockedEnemy == enemyHero then return false end
    -- `v7.9.16` (`auto-20261107-0255` `01:04.80..01:08.87` Central Multi-Creep Aggro Shield):
    -- NEVER initiate or continue non-lethal right-click trading / uphill orb-walking while `>= 2` enemy lane creeps
    -- are aggroed on SF (or during `State.creepKiteUntil` disengage) unless `enemyHero` is `<= 2` right-clicks from death!
    local wsNow = W and W.s or nil
    local aggroNow = (U.CountEnemyCreepsAggroedOnBot and U.CountEnemyCreepsAggroedOnBot(bot, wsNow, State.myCreepChaseUntil)) or 0
    local nowG = GameTime()
    local myAtkHero = K.AttackDamageVs(bot, enemyHero)
    local bLocAtk, eLocAtk = bot:GetLocation(), enemyHero:GetLocation()
    local uphillMissAtk = ((eLocAtk.z or 0) - (bLocAtk.z or 0)) >= 48
    if type(GetHeightLevel) == "function" then
        local okB, hB = pcall(GetHeightLevel, bLocAtk)
        local okE, hE = pcall(GetHeightLevel, eLocAtk)
        if okB and okE and type(hB) == "number" and type(hE) == "number" then
            uphillMissAtk = uphillMissAtk or (hE > hB)
        end
    end
    local enRawHpHero = math.max(1, (enemyHero:GetHealth() or 9999)
        - ((U.GetOwnInFlightDamageOnHero and U.GetOwnInFlightDamageOnHero(bot, enemyHero)) or 0))
    local enEffHpHero = enRawHpHero
        + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(enemyHero)) or 0)
        + ((U.GetStickCharges and U.GetStickCharges(enemyHero)) or 0) * 15
    local myHpHero = bot:GetHealth() or 0
    local healthyTwoHitChase = (not uphillMissAtk) and (myHpHero >= 460) and (aggroNow <= 2)
        and (enEffHpHero <= math.max(125, myAtkHero * 2.25))
    local oneShotRawHero = (not uphillMissAtk) and (enRawHpHero <= myAtkHero * 0.96)
    local twoHitLethalHero = oneShotRawHero or healthyTwoHitChase
        or (enEffHpHero <= myAtkHero * (uphillMissAtk and 1.42 or 1.90))
    if (aggroNow >= 2 or (uphillMissAtk and aggroNow >= 1) or (State.creepKiteUntil and nowG < State.creepKiteUntil)) and not twoHitLethalHero then
        return false
    end
    local distance = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local myRange = (bot.GetAttackRange and bot:GetAttackRange()) or 500
    -- `v7.9.27-pro` (`auto-20261108-2034` `02:23.64..02:26.44` Post-Release Reload Chase Orb-Walk!):
    -- In Source 2 C++, `CDOTA_BaseNPC::StartAttack` stamps `m_flLastAttackTime` at `t = 0.00s` (START of windup),
    -- and projectile release occurs at `effAP = baseAP * (spa / 1.60)` (`~0.39s`). Therefore the true post-release
    -- backswing/reload window is `[effAP + 0.03 .. spa - 0.06]`! During this window, step FORWARD toward a fleeing
    -- low-HP `enemyHero` instead of standing in backswing or kiting backward!
    local recChaseOuter = U._unitTrack and U._unitTrack[bot]
    local curTkChaseOuter = math.floor(nowG * 30.0 + 0.5)
    local stillWindingUpOuter = recChaseOuter and recChaseOuter.wasAnim and recChaseOuter.launchTick
        and curTkChaseOuter <= (recChaseOuter.launchTick + 3)
    do
        local lastAtkChase = (bot.GetLastAttackTime and bot:GetLastAttackTime()) or -100
        local spaChase = (bot.GetSecondsPerAttack and bot:GetSecondsPerAttack()) or 1.25
        local baseApChase = (bot.GetAttackPoint and bot:GetAttackPoint()) or 0.50
        local effApChase = baseApChase * (spaChase / 1.60)
        local sinceChase = nowG - lastAtkChase
        local stillWindingUp = stillWindingUpOuter
        local inReloadChase = (not stillWindingUp) and (lastAtkChase > 0)
            and (sinceChase >= effApChase + 0.03) and (sinceChase <= spaChase - 0.06)
        if inReloadChase and (twoHitLethalHero or (myHpHero >= 480 and enEffHpHero <= myAtkHero * 2.85)) then
            local outSpdChase = (U.EnemyOutwardSpeed and U.EnemyOutwardSpeed(bot, enemyHero)) or 0
            if outSpdChase >= 55 or distance >= (myRange - 95) then
                local predChase = U.PredictPosition(enemyHero, 0.35)
                local safeT1Chase = true
                if wsNow and wsNow.enemyT1Alive ~= false and wsNow.enemyT1Loc then
                    safeT1Chase = U.DistanceBetweenLocations(predChase, wsNow.enemyT1Loc) >= 910
                end
                if safeT1Chase and U.DistanceBetweenLocations(bLocAtk, predChase) > 22 then
                    H.SmartMove(bot, predChase, 18)
                    State.heroAttackTarget = enemyHero
                    State.heroAttackTime = nowG
                    return true
                end
            end
        end
    end
    -- Backswing Uphill Orb-Walk (`0.000s` DPS loss!):
    -- While right-click is cooling down in backswing (`remAtkCD > 0.16`), step uphill onto equal elevation (`z >= enemy`)
    -- inside attack range so subsequent attacks never suffer the `25%` Source 2 river-to-highground miss penalty!
    if (not stillWindingUpOuter) and type(GetHeightLevel) == "function" then
        local bLocNow, eLocNow = bLocAtk, eLocAtk
        if GetHeightLevel(bLocNow) < GetHeightLevel(eLocNow) then
            local lastAtkT = (bot.GetLastAttackTime and bot:GetLastAttackTime()) or -100
            local spaNow = (bot.GetSecondsPerAttack and bot:GetSecondsPerAttack()) or 1.2
            local apNow = (bot.GetAttackPoint and bot:GetAttackPoint()) or 0.5
            local sinceAtk = GameTime() - lastAtkT
            local inBackswingWindow = (lastAtkT > 0) and (sinceAtk > 0.04) and ((spaNow - sinceAtk) > (apNow + 0.10))
            if inBackswingWindow then
                local hgOrb = P.AvoidUphillMiss(bot, bLocNow, eLocNow, myRange - 15)
                if hgOrb and GetHeightLevel(hgOrb) >= GetHeightLevel(eLocNow)
                    and U.DistanceBetweenLocations(bLocNow, hgOrb) > 10 then
                    H.SmartMove(bot, hgOrb, 15)
                    State.heroAttackTarget = enemyHero
                    State.heroAttackTime = GameTime()
                    return true
                end
                -- `v7.9.18` (`9079381960.dem` `01:30.6..01:36.6` Faerie Fire Uphill-Ramp Bait Fix):
                -- ONLY orb-walk directly up the enemy's highground lip when ZERO enemy creeps are near `eLocNow`
                -- (`<= 520u`) OR we hold a true EHP 2-hit finish (`twoHitLethalHero` accounting for Faerie Fire & 25% miss)!
                local enCreepsNearRamp = 0
                for _, ec in pairs((wsNow and wsNow.enemyCreeps) or {}) do
                    if U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(ec:GetLocation(), eLocNow) <= 520 then
                        enCreepsNearRamp = enCreepsNearRamp + 1
                    end
                end
                if distance > 180 and ((bot:GetHealth() or 0) >= 160)
                    and (twoHitLethalHero or (aggroNow == 0 and enCreepsNearRamp == 0)) then
                    H.SmartMove(bot, eLocNow, 25)
                    State.heroAttackTarget = enemyHero
                    State.heroAttackTime = GameTime()
                    return true
                end
            end
        end
    end
    local hullAtkReach = math.max(525, myRange) + 48
    local domRightClickOk = K.HasDominantRightClickPosture and K.HasDominantRightClickPosture(bot, enemyHero, W and W.s or nil)
    if K.HasRazeStackLead(bot, enemyHero) and distance > hullAtkReach and not domRightClickOk then
        if K.EnemyBandsAcross(enemyHero, distance, distance, 0.7) > 0 then return false end
        local stop = enemyHero:GetLocation() + (bot:GetLocation()-enemyHero:GetLocation()):Normalized()
            * math.min(distance, hullAtkReach)
        if not K.StackLeadStepSafe(bot, enemyHero, stop) then return false end
    elseif domRightClickOk and distance > hullAtkReach then
        -- Even when right-click dominant, do not walk `< 435u` into ready enemy `R1` just to chase if already out of range
        local stop = enemyHero:GetLocation() + (bot:GetLocation()-enemyHero:GetLocation()):Normalized()
            * math.min(distance, hullAtkReach)
        if U.DistanceBetweenLocations(stop, enemyHero:GetLocation()) < 435
            and K.EnemyManaBudget(enemyHero, true) >= 75
            and K.EnemyRazeReadyIn("near") <= 0.8 then
            return false
        end
    end
    local sameTarget = H.IsSameAttackTarget(bot, enemyHero)
    -- Switch Power Treads to Agility (`FIGHT`: `+10 Damage & +10 AS`) before initiating a non-one-shot hero attack,
    -- OR during the post-launch attack backswing window while attacking `enemyHero` (`9070886384.dem` `06:55` Fix)!
    local enHpForPt = enemyHero:GetHealth() or 9999
    local oneShotSkipPt = enHpForPt <= K.AttackDamageVs(bot, enemyHero) * 1.15
    if not oneShotSkipPt and (not stillWindingUpOuter) and U.HasItem(bot, "item_power_treads") then
        local lastAtkPt = bot:GetLastAttackTime() or -100
        local spaPt = math.max(0.65, bot:GetSecondsPerAttack() or 1.40)
        local apPt = (bot.GetAttackPoint and bot:GetAttackPoint()) or 0.50
        local sincePt = GameTime() - lastAtkPt
        local inSafePtWindow = (not sameTarget) or (lastAtkPt > 0 and sincePt >= 0.05 and (spaPt - sincePt) >= (apPt + 0.12))
        if inSafePtWindow and H.TrySafeTreadsSwitch(bot, "FIGHT") then
            State.heroAttackTarget = enemyHero
            State.heroAttackTime = GameTime()
            return true
        end
    end
    if not sameTarget then
        -- `v7.9.33-pro` (`auto-20261109-0306` `2:26.27` `tk=7294..7306` CS-Lockout Harass Initiation Guard!):
        -- NEVER initiate a brand-new non-lethal Stage B hero right-click (`1.85s` windup + cooldown lockout) when
        -- `WouldRightClickLockoutCS` proves an active lane creep (`Rm#299` dying in `1.60s`) would die during reload,
        -- eliminating both the doomed mid-swing abort at `tk=7306` and wasted `500u` creep aggro!
        if not twoHitLethalHero and enEffHpHero > myAtkHero * 2.55
            and nowG >= (State.commitKillUntil or 0)
            and not State.bypassCSLockoutForHeroAtk
            and wsNow and L and L.WouldRightClickLockoutCS and L.WouldRightClickLockoutCS(bot, wsNow) then
            return false
        end
        local nowAtk = GameTime()
        -- Track exact Source 2 Lane Creep Aggro state (`500u` trigger radius, `3.00s` global CD, `2.30s` forced chase):
        if nowAtk >= (State.myCreepAggroCdUntil or 0) then
            local creepsIn500 = false
            local eCreepsNow = (W and W.s and W.s.enemyCreeps) or (bot.GetNearbyLaneCreeps and bot:GetNearbyLaneCreeps(525, true)) or {}
            for _, ec in pairs(eCreepsNow) do
                if U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 500 then
                    creepsIn500 = true
                    break
                end
            end
            State.myCreepAggroCdUntil = nowAtk + 3.00
            if creepsIn500 then
                State.myCreepChaseUntil = nowAtk + 2.30
            end
        end
        bot:Action_AttackUnit(enemyHero, true)
        H.ClearMoveCache()
        State.attackTarget = enemyHero
        State.attackStartTime = nowAtk
        State.heroAttackTarget = enemyHero
        State.heroAttackTime = nowAtk
        State.heroAttackStartLAT = bot:GetLastAttackTime() or -100
        if distance <= hullAtkReach + 18 then
            local apCommit = (bot.GetAttackPoint and bot:GetAttackPoint()) or 0.50
            State.heroAttackCommitUntil = nowAtk + math.min(0.74, apCommit + 0.24)
        end
        State.firedThisAttack = false
    elseif State.attackTarget ~= enemyHero then
        State.attackTarget = enemyHero
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
    end
    -- `v7.9.32-pro` Pro Post-Launch Orb-Walk Backswing Cancel (`auto-20261109-0306` `2:40.97` `tk=7736..7748` `46 HP` Escape Fix!):
    -- When `sameTarget == true` and `m_flLastAttackTime` has JUST stamped (`0.04s .. spa - 0.24s`), Dota 2 C++ otherwise
    -- plays out `0.40s` of stationary post-attack backswing before walking! Cancel backswing immediately by stepping toward
    -- `enemyHero` whenever chasing (`distance > hullAtkReach - 55`) or climbing uphill (`bLoc.z + 25 < eLoc.z`) outside enemy T1/Q!
    if sameTarget then
        local latOrb = bot:GetLastAttackTime() or -100
        local nowOrb = GameTime()
        local sinceOrb = nowOrb - latOrb
        local spaOrb = math.max(0.65, bot:GetSecondsPerAttack() or 1.45)
        local apOrb = (bot.GetAttackPoint and bot:GetAttackPoint()) or 0.50
        if latOrb > 0 and sinceOrb >= 0.04 and (spaOrb - sinceOrb) >= math.max(0.24, apOrb * 0.48) then
            local bLocOrb = bot:GetLocation()
            local eLocOrb = enemyHero:GetLocation()
            local uphillChaseOrb = ((bLocOrb.z or 0) + 25 < (eLocOrb.z or 0)) and (distance > 300)
            if distance > (hullAtkReach - 55) or uphillChaseOrb then
                local wsOrb = W and W.s
                local safeFromEnT1Orb = (not wsOrb) or (wsOrb.enemyT1Alive == false) or (not wsOrb.enemyT1Loc)
                    or (U.DistanceBetweenLocations(bLocOrb, wsOrb.enemyT1Loc) > 930)
                local safeFromNearCoilOrb = (enHpForPt <= K.AttackDamageVs(bot, enemyHero) * 1.15)
                    or (distance > 515)
                    or (K.EnemyManaBudget(enemyHero, true) < 75)
                    or (K.EnemyRazeReadyIn("near") > 0.8)
                if safeFromEnT1Orb and safeFromNearCoilOrb then
                    bot:Action_MoveToLocation(eLocOrb)
                    H.ClearMoveCache()
                    State.heroAttackTarget = enemyHero
                    State.heroAttackTime = nowOrb
                    State.heroAttackCommitUntil = 0
                    return true
                end
            end
        end
    end
    if distance <= hullAtkReach + 12 and (bot:GetLastAttackTime() or -100) <= (State.heroAttackStartLAT or -100) + 0.004 then
        local apHold = (bot.GetAttackPoint and bot:GetAttackPoint()) or 0.50
        if GameTime() >= (State.heroAttackCommitUntil or -100) then
            local spaHold = math.max(0.65, bot:GetSecondsPerAttack() or 1.45)
            if (GameTime() - (bot:GetLastAttackTime() or -100)) >= (spaHold * 0.85) then
                State.heroAttackStartLAT = bot:GetLastAttackTime() or -100
                State.heroAttackCommitUntil = GameTime() + math.min(0.74, apHold + 0.24)
            end
        end
    end
    State.heroAttackTarget = enemyHero
    State.heroAttackTime = GameTime()
    return true
end

-- The attack animation detector uses the ANIMATION (GetAnimActivity/GetAnimCycle), not the order time:
-- the attack order is issued 0-1 s before the real swing (the hero is still walking/turning),
-- so an order-time lock expired before the actual swing and the next
-- handler (creep aggro drop, last hit, raze turn, positioning) cancelled the attack a fraction
-- of a second before the attack point. Called every tick before decisions are made.
function H.UpdateAttackActivity(bot)
    local now = GameTime()
    local act, cyc = nil, nil
    if bot.GetAnimActivity then
        local ok, a = pcall(bot.GetAnimActivity, bot)
        if ok and type(a) == "number" then act = a end
    end
    if act == nil then
        State.atkAnimAvailable = false
        State.atkAnimSince = nil
        return
    end
    if bot.GetAnimCycle then
        local ok, c = pcall(bot.GetAnimCycle, bot)
        if ok and type(c) == "number" then cyc = c end
    end
    State.atkAnimAvailable = true
    local A1 = _G.ACTIVITY_ATTACK or 1503
    local A2 = _G.ACTIVITY_ATTACK2 or 1504
    local A3 = _G.ACTIVITY_ATTACK_EVENT or 1505
    local isAtk = (act == A1 or act == A2 or act == A3)
    if isAtk then
        local restarted = cyc and State.atkAnimCycle and (cyc < State.atkAnimCycle - 0.05)
        if not State.atkAnimSince or restarted then State.atkAnimSince = now end
    else
        State.atkAnimSince = nil
    end
    State.atkAnimCycle = cyc
end

-- Is a right-click swing at the enemy hero in progress (attack point not reached yet)?
-- `v7.8.0` + `v7.9.33-pro` (`auto-20261109-0306` `2:26.67` `tk=7306` `718.4u < 823.0u` Motion-Buffer Fix!):
-- Holds BOTH during `rec.wasAnim == true` (`with +3t VScript pre-release tolerance`) AND during `State.heroAttackCommitUntil`
-- while `d <= 795u` (`inside Source 2's 525 + 24 + 24 + 250 = 823.0u C2C ranged attack motion buffer`), clearing `0.000s` on launch!
function H.IsHeroWindupNow(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) or not enemyHero:IsAlive() then return false end
    local latNow = bot:GetLastAttackTime() or -100
    if State.heroAttackStartLAT and latNow > State.heroAttackStartLAT + 0.004 then
        State.heroAttackCommitUntil = 0
    end
    local okT, target = pcall(bot.GetAttackTarget, bot)
    local targetingHero = (okT and target == enemyHero)
        or (State.heroAttackTarget == enemyHero and (GameTime() - (State.heroAttackTime or -100)) <= 0.75)
    if not targetingHero then return false end
    if not U.IsAttackingAction(bot) then return false end
    local dHeroNow = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if dHeroNow > 795 then return false end
    local curTick = math.floor(GameTime() * 30.0 + 0.5)
    local rec = U._unitTrack and U._unitTrack[bot]
    if rec ~= nil and rec.wasAnim == true and rec.launchTick ~= nil and curTick <= (rec.launchTick + 3) then
        return true
    end
    if GameTime() < (State.heroAttackCommitUntil or 0)
        and latNow <= (State.heroAttackStartLAT or -100) + 0.004 then
        return true
    end
    return false
end

-- Exact remaining time (`sec`) until our active hero right-click spawns its `1200 u/s` projectile (`nil` if not winding up):
function H.GetHeroWindupRemainingSec(bot, enemyHero)
    if not H.IsHeroWindupNow(bot, enemyHero) then return nil end
    local nowW = GameTime()
    local curTick = math.floor(nowW * 30.0 + 0.5)
    local rec = U._unitTrack and U._unitTrack[bot]
    if rec ~= nil and rec.wasAnim == true and rec.launchTick ~= nil then
        return math.max(0.033, (rec.launchTick - curTick) / 30.0)
    end
    if nowW < (State.heroAttackCommitUntil or 0) then
        return math.max(0.067, (State.heroAttackCommitUntil or 0) - nowW)
    end
    return nil
end

-- `v7.9.33-pro` (`auto-20261109-0306` `2:39.80` `tk=7700` `12/14t` Pre-Raze Auto-Release Solo-Kill Fix!):
-- Basic attacks and Shadowraze do NOT share cooldowns or cast points (`0.000s` backswing cancel!). When SF is already
-- `<= 0.22s` (`<= 6..7` ticks) from launching a hero bolt and a single Shadowraze ALONE does NOT 1-shot `enemyHero`
-- (`121 < 161 HP` at `tk=7700`!), NEVER self-cancel the `72`-dmg bolt to turn/cast Raze — let the bolt launch first and
-- snap Shadowraze on the very next tick while the bolt is in mid-air (`72 + 121 = 193 > 161 HP` guaranteed kill!)!
function H.ShouldFinishNearLaunchHeroAutoBeforeRaze(bot, enemyHero, earlyRace)
    if not bot or not enemyHero or not U.CanQuery(enemyHero) or not enemyHero:IsAlive() then return false end
    if State.emergencyRetreat then return false end
    if earlyRace and earlyRace.valid and earlyRace.heCanKillNow then return false end
    if bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(0.5) then return false end
    local remSec = H.GetHeroWindupRemainingSec(bot, enemyHero)
    if not remSec or remSec > 0.22 then return false end
    local oneRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
    local enRawHp = math.max(1, (enemyHero:GetHealth() or 9999)
        - ((U.GetOwnInFlightDamageOnHero and U.GetOwnInFlightDamageOnHero(bot, enemyHero)) or 0))
    local enEffHp = enRawHp + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(enemyHero)) or 0)
    if oneRazeDmg >= (enEffHp + 4) then
        return false -- Single Raze already 1-shots cleanly; no need to wait!
    end
    return true
end

-- "Let the attack land": while a swing at the hero is in progress, no non-emergency handler issues
-- orders (70-90 damage in 0.3-0.5 s beats all of them). Exceptions: his burst right now
-- is lethal, instant lethal coil is ready, the enemy tower is hitting us, emergency retreat.
function H.ShouldHoldForHeroWindup(bot, s, enemyHero, race)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not H.IsHeroWindupNow(bot, enemyHero) then return false end
    if State.emergencyRetreat then return false end
    if race and race.valid and race.heCanKillNow then return false end
    if U.CanQuickTurnKillWithRaze(bot, enemyHero) then return false end
    local t1 = s and s.enemyT1
    if t1 and U.CanQuery(t1) and t1.GetAttackTarget then
        local okT, tgt = pcall(t1.GetAttackTarget, t1)
        if okT and tgt == bot then return false end
    end
    if bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(0.5) then return false end
    return true
end

function H.IsHeroAttackWindupLocked(bot)
    local target = bot:GetAttackTarget()
    if not U.IsAttackingAction(bot) or not target or not target:IsAlive() then
        return false
    end
    if not (target.IsHero and target:IsHero()) then
        return false
    end
    if State.attackTarget ~= target then
        State.attackTarget = target
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
    end
    local elapsed = GameTime() - (State.attackStartTime or 0)
    local ap = bot:GetAttackPoint() or 0
    return elapsed < (ap + 0.06)
end

-- "Shield" under the tower: a live (non-siege) allied creep inside the tower radius that is CLOSER to the
-- tower than refLoc (the bot by default), with the tower not currently hitting us. The old check
-- ("any creep within 760 of the tower") missed the case where the creeps walked off after the enemy
-- while the bot stayed the tower's closest target.
function H._hasTankCreepUnderTower(tower, allyCreeps, refLoc)
    if not tower or not tower:IsAlive() then return false end
    local bot = GetBot()
    local tgt = tower.GetAttackTarget and tower:GetAttackTarget()
    if bot and tgt == bot then return false end
    -- "Burn" after leaving the tower: it was hitting US just now - do not trust the shield
    -- (last hits/approaches only from outside its radius until the burn expires)
    if H.TowerBurnActive and H.TowerBurnActive() then return false end
    local ref = refLoc or (bot and bot:GetLocation())
    local count = LN.TowerShieldCount(tower, allyCreeps, ref)
    return count >= 1
end

-- A creep tank under the tower does not justify going in when the enemy hero is nearby and we are weaker
-- (he is at full HP, we are not): in that trade under the tower we simply die while wandering between points.
function H._TowerApproachAllowed(bot, tower, allyCreeps, targetLoc)
    if H._hasTankCreepUnderTower(tower, allyCreeps, targetLoc) then
        local eh = H._enemyHeroNear and H._enemyHeroNear
        if eh and U.CanQuery(eh) then
            local d = GetUnitToLocationDistance(eh, targetLoc)
            if d <= 900 then
                local myHp, enHp = bot:GetHealth(), eh:GetHealth()
                if myHp < enHp - 100 or (bot:GetHealth() / math.max(1, bot:GetMaxHealth())) < 0.50 then
                    return false
                end
            end
        end
        return true
    end
    return false
end

function H.GetSafeApproach(bot, targetLoc, enemyTowers, allyCreeps)
    if W.s and W.s.enemyT1Alive ~= false and W.s.enemyT1Loc then
        local tLoc = W.s.enemyT1Loc
        local noReenterActive = (GameTime() < (State.noReenterEnemyT1Until or -1000))
            or (bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(1.8))
        if noReenterActive and U.DistanceBetweenLocations(targetLoc, tLoc) < 935 then
            local dir = (P.GetFountain(bot) - tLoc):Normalized()
            return tLoc + dir * 935
        end
        if U.DistanceBetweenLocations(targetLoc, tLoc) < 890
            and LN.TowerShieldCountLoc(tLoc, W.s.enemyT1, allyCreeps, targetLoc) < 1 then
            local dir = (P.GetFountain(bot) - tLoc):Normalized()
            return tLoc + dir * 890
        end
    end
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local distToTower = GetUnitToLocationDistance(tower, targetLoc)
            if distToTower < 830 then
                if not H._TowerApproachAllowed(bot, tower, allyCreeps, targetLoc) then
                    local dir = (targetLoc - tower:GetLocation()):Normalized()
                    return tower:GetLocation() + dir * 885
                end
            end
        end
    end
    return targetLoc
end

function H.GetSafeApproachLoose(bot, targetLoc, enemyTowers, allyCreeps)
    if W.s and W.s.enemyT1Alive ~= false and W.s.enemyT1Loc then
        local tLoc = W.s.enemyT1Loc
        local noReenterActive = (GameTime() < (State.noReenterEnemyT1Until or -1000))
            or (bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(1.8))
        if noReenterActive and U.DistanceBetweenLocations(targetLoc, tLoc) < 935 then
            local dir = (P.GetFountain(bot) - tLoc):Normalized()
            return tLoc + dir * 935
        end
        if U.DistanceBetweenLocations(targetLoc, tLoc) < 890
            and LN.TowerShieldCountLoc(tLoc, W.s.enemyT1, allyCreeps, targetLoc) < 1 then
            local dir = (P.GetFountain(bot) - tLoc):Normalized()
            return tLoc + dir * 890
        end
    end
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local distToTower = GetUnitToLocationDistance(tower, targetLoc)
            if distToTower < 740 then
                if not H._TowerApproachAllowed(bot, tower, allyCreeps, targetLoc) then
                    local dir = (targetLoc - tower:GetLocation()):Normalized()
                    return tower:GetLocation() + dir * 815
                end
            end
        end
    end
    return targetLoc
end

-- Single entry point for ANY approach toward the enemy hero:
-- 1) do not chase a fleeing enemy with equal/greater speed (pointless, we lose creeps);
-- 2) leash at his T1: do not enter the tower radius without a creep shield;
-- 3) the usual point correction relative to the tower.
-- Can we close to distance dAfter without entering our own "band fear" range?
function H.ApproachIntoBandOK(bot, enemyHero, dAfter)
    if State.intent == I.RETREAT then return false end
    local R = K._race
    local killing = (R and R.valid and R.canKillSoon) or State.hunting -- Hunting = finishing
    -- With a fresh stack on us, closing into the near band (< 470 = his right click + near
    -- raze with the stack bonus) is forbidden except to finish; with 2+ stacks we do not close at all.
    -- Previously only "band fear" was checked (it did not trigger without a stack when edge >= 0), so the mirror /
    -- stack finish walked a stacked bot right up to the enemy.
    if not killing then
        local st, rem = U.GetShadowrazeDebuff(bot)
        if (st or 0) >= 1 and (rem or 0) >= 1.0 then
            local nearFear = (C.STACK_NEAR_FEAR and C.STACK_NEAR_FEAR.MIN_DISTANCE) or 470
            if dAfter < nearFear then return false end
            if st >= 2 then return false end
        end
    end
    -- Single minimum distance (band fear + the "with a stack, stay out of his ready bands" rule)
    local fearMin = U.GetMinDistWithStack(bot, enemyHero)
    if fearMin <= 0 then return true end
    return dAfter >= fearMin - 20
end

function H.ApproachEnemyPoint(bot, enemyHero, loc, threshold, enemyTowers, allyCreeps, allowDive, stackAbility)
    if State.combatPolicyActive == true and enemyHero and not State.heroCombatAllowed then return false end
    if not loc then return false end
    if State.actionTaken then return false end
    if State.towerChaseBlockedEnemy == enemyHero and enemyHero then return false end
    local third = stackAbility and H.StackLeadThirdRazeOK(bot, enemyHero, stackAbility, loc, W.s)
    if enemyHero and not K.StackLeadStepSafe(bot, enemyHero, loc) and not third then return false end
    if allowDive and H.TowerBurnActive() then allowDive = false end -- No dives after leaving the T1
    if enemyHero and U.CanQuery(enemyHero) then
        local botLoc = bot:GetLocation()
        local enLoc = enemyHero:GetLocation()
        local dNow = U.DistanceBetweenLocations(botLoc, enLoc)
        local dAfter = U.DistanceBetweenLocations(loc, enLoc)
        if dAfter < dNow - 60 then
            -- Closing in: does it make sense?
            if not K.CanCatch(bot, enemyHero, dAfter, 2.0) then return false end
            -- Do not enter his READY band if our own fear triggers there too
            -- (ShouldRetreatFromEnemyRazeStack): otherwise we get an "approach - get scared - back off" loop.
            if not allowDive and not third and not H.ApproachIntoBandOK(bot, enemyHero, dAfter) then return false end
        end
        local t1 = W.s.enemyT1
        if t1 and not allowDive then
            local okLoc, tLoc = pcall(t1.GetLocation, t1)
            if okLoc and tLoc then
                local leash = (C.TOWER and C.TOWER.CHASE_LEASH) or 820
                if U.DistanceBetweenLocations(tLoc, loc) < leash and LN.TowerDanger(bot, t1, allyCreeps, loc) >= 2 then
                    return false
                end
                -- Do not chase the enemy BEHIND his T1. The leash above only checked the radius, so
                -- a point on the far side of the tower passed the check - and walking back would mean
                -- crossing its attack radius (hence the freezes under the tower).
                if LN.IsBeyondTower(bot, t1, loc) then return false end
            end
        end
    end
    loc = H.GetSafeApproachLoose(bot, loc, enemyTowers or {}, allyCreeps or {})
    if U.DistanceBetweenLocations(bot:GetLocation(), loc) <= (threshold or 35) then return false end
    return H.SmartMove(bot, loc, threshold or 35, false, stackAbility)
end

function H.IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps)
    local botLoc = bot:GetLocation()
    local enemy = H._enemyHeroNear
    if enemy and K.HasRazeStackLead(bot, enemy) then
        local walk = math.max(0, U.DistanceBetweenLocations(botLoc, targetLoc) - bot:GetAttackRange())
        local stop = botLoc + (targetLoc - botLoc):Normalized() * walk
        if not K.StackLeadStepSafe(bot, enemy, stop) then return false end
    end
    local atkR = (bot.GetAttackRange and bot:GetAttackRange()) or 500
    local walkDist = math.max(0, U.DistanceBetweenLocations(botLoc, targetLoc) - math.max(480, atkR - 15))
    local attackStandLoc = (walkDist > 0.5)
        and (botLoc + (targetLoc - botLoc):Normalized() * walkDist)
        or botLoc
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            if not H._hasTankCreepUnderTower(tower, allyCreeps) then
                if GetUnitToLocationDistance(tower, botLoc) < 860 then return false end
                if GetUnitToLocationDistance(tower, attackStandLoc) < 860 then return false end
            end
        end
    end
    return true
end

function H.IsSafeToHarass(bot, targetLoc, enemyTowers, allyCreeps)
    local botLoc = bot:GetLocation()
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            -- `v7.9.18` (`9079381960.dem` `02:41.60` `dBotRT1 = 684.3u` 3x Attack-Cancel Fix):
            -- True Source 2 `CDOTA_BaseNPC_Tower` hero-attack aggro trigger radius is `500u` (`~575u` safe center-to-center)!
            -- At `d >= 575u` with a firm allied creep shield (`>= 250` total creep HP tanking T1), right-clicking an enemy
            -- hero NEVER switches tower aggro onto SF! Require `>= 790u` ONLY when unshielded!
            local tLoc = tower:GetLocation()
            local dTw = GetUnitToLocationDistance(tower, botLoc)
            local firmShield = H._hasTankCreepUnderTower(tower, allyCreeps, botLoc)
                and LN.HasFirmTowerCreepShield and LN.HasFirmTowerCreepShield(tLoc, tower, allyCreeps, botLoc, 250)
            if firmShield then
                if dTw < 575 then return false end
            else
                if dTw < 790 then return false end
                if GetUnitToLocationDistance(tower, targetLoc) < 320 then return false end
            end
        end
    end
    return true
end

function H.IsSafeToCommitKillAttack(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local towerToEnemy = GetUnitToLocationDistance(tower, enemyHero:GetLocation())
            if towerToEnemy <= 850 then
                if H._hasTankCreepUnderTower(tower, allyCreeps) then
                    return true
                end
                if GetUnitToLocationDistance(bot, tower:GetLocation()) > 810 then
                    return true
                end
                return false
            end
        end
    end
    return true
end

function H.GetEnemyT1Tower(enemyTowers)
    for _, tower in pairs(enemyTowers or {}) do
        if tower and tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                return tower
            end
        end
    end
    return nil
end

-- Bot near its own T1 (within radius of the tower)
function H.IsNearOwnT1(bot, radius)
    local s = W.s
    local t1 = s and s.allyT1
    if not t1 then return false end
    local okL, tl = pcall(t1.GetLocation, t1)
    if not okL or not tl then return false end
    return GetUnitToLocationDistance(bot, tl) <= (radius or 400)
end

function H.IsBotUnderEnemyT1(bot, enemyTowers)
    local t1 = H.GetEnemyT1Tower(enemyTowers)
    if not t1 then return false, nil end
    if GetUnitToLocationDistance(bot, t1:GetLocation()) <= 880 then
        return true, t1
    end
    return false, t1
end

function H.HasRazeResource(bot)
    return H.GetPotentialCombatMana(bot) >= 75
end

function H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if H.TowerBurnActive() then return false end
    local underT1, t1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then return false end
    if bot:GetLevel() < 5 then return false end
    if not H.HasRazeResource(bot) then return false end
    local enemyCanPunish = U.EnemyCanUseRaze(enemyHero)
    local atkActual = enemyHero:GetActualIncomingDamage(bot:GetAttackDamage() or 0, DAMAGE_TYPE_PHYSICAL)
    local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
    local twoRaze = U.GetTwoRazeDamage(bot, enemyHero)
    local enemyVeryLow = enemyHero:GetHealth() <= (oneRaze + atkActual * 2.0) or enemyHero:GetHealth() <= (twoRaze + atkActual)
    if not enemyCanPunish then return true end
    if enemyVeryLow then return true end
    return false
end

function H.TryUseGlyphForT1Retreat(bot, enemyTowers, allyCreeps)
    if not U.IsGlyphAvailable(bot) then return false end
    local underT1, t1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then return false end
    if not H._hasTankCreepUnderTower(t1, allyCreeps) then return false end
    U.UseGlyph(bot)
    State.actionTaken = true
    return true
end

function H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, mode)
    local safeLoc = P.GetLasthitPosition(bot, enemyCreeps or {}, allyCreeps or {}, nil, mode or "PASSIVE")
    local fountain = P.GetFountain(bot)
    local t1 = H.GetEnemyT1Tower(enemyTowers)
    local tLoc = (t1 and t1:IsAlive() and t1:GetLocation()) or (W.s and W.s.enemyT1Alive and W.s.enemyT1Loc) or nil
    if tLoc then
        local dir = (fountain - tLoc):Normalized()
        local extra = 150
        safeLoc = tLoc + dir * (865 + C.T1_SAFETY.RETREAT_BUFFER + extra)
    end
    return safeLoc
end

function H.HandleEnemyTowerSafety(bot, s, enemyHero)
    -- CRITICAL TWO-PART FIX (`9056568054.dem` `tk=14006` `837.5u` stall & `9056774541.dem` `tk=6338` `817.0u` FoW stall):
    --   1. Drive tower evacuation from `s.enemyT1Alive` + `s.enemyT1Loc` EVEN WHEN `s.enemyT1 == nil` in Highground FoW!
    --   2. True Dota 2 C++ T1 reach center-to-center = `700 + 144 + 24 = 868.0u` (NOT `720u`!), with full exit at `965u+`!
    local t1 = s and s.enemyT1 or nil
    if not (s and s.enemyT1Alive) then
        State.t1EnterTime = nil
        H.ClearTowerEscape()
        return false
    end
    local tLoc = (t1 and U.CanQuery(t1) and t1:GetLocation()) or (s and s.enemyT1Loc) or nil
    if not tLoc then return false end
    local cfg = C.TOWER or {}
    local escapeRad = math.max(cfg.ESCAPE_RADIUS or 965, 965)
    local d = GetUnitToLocationDistance(bot, tLoc)
    local now = GameTime()

    -- The tower is nearly down (`<= 3` hits, visible OR FoW `s.enemyT1LastHp`, e.g. `14 HP` at `07:23`!) - finish it!
    if LN.IsTowerFinishableOrFoW and LN.IsTowerFinishableOrFoW(bot, s)
        or (t1 and LN.IsTowerFinishable(bot, t1)) then
        State.t1EnterTime = nil
        State.towerBurnUntil = nil
        State.noReenterEnemyT1Until = nil
        H.ClearTowerEscape()
        H.ClearForcedRetreat()
        return false
    end

    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local towerBoltIncoming = false
    for _, p in pairs((bot.GetIncomingTrackingProjectiles and bot:GetIncomingTrackingProjectiles()) or {}) do
        if p and p.is_attack and p.caster and p.caster.IsTower then
            local okTw, isTw = pcall(p.caster.IsTower, p.caster)
            if okTw and isTw then towerBoltIncoming = true; break end
        end
    end

    -- `9069188041.dem` `01:44.0-01:46.3` T1 Exit Freeze Fix:
    -- Enemy T1 max attack range is `868u` (`700 + 144 + 24`). Once `d > escapeRad` (`>= 980u`), T1 CANNOT fire
    -- any new attack! Previously `towerBoltIncoming` (`0.67s` flight) + `WasRecentlyDamagedByTower(1.25)` kept
    -- `onMeEarly = true` at `d = 1030u`, calling `SmartMove` to `State.towerEscapeLoc` (`dist == 0`, `v == 0`)
    -- and freezing SF motionless for `1.2-1.9s` while the human SF walked up and landed 2 free attacks!
    local onMeEarly = false
    if d <= 905 then
        onMeEarly = towerBoltIncoming
        if not onMeEarly and t1 and U.CanQuery(t1) and t1.GetAttackTarget then
            local okTE, tgtE = pcall(t1.GetAttackTarget, t1)
            if okTE and tgtE == bot then onMeEarly = true end
        end
        if not onMeEarly and bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(1.25) then
            onMeEarly = true
        end
    elseif t1 and U.CanQuery(t1) and t1.GetAttackTarget then
        local okTE, tgtE = pcall(t1.GetAttackTarget, t1)
        if okTE and tgtE == bot then onMeEarly = true end
    end

    if (State.towerEscapeUntil or 0) > now and State.towerEscapeLoc then
        if d > escapeRad and not onMeEarly then
            State.noReenterEnemyT1Until = math.max(State.noReenterEnemyT1Until or 0, now + 2.2)
            H.ClearTowerEscape()
        elseif not onMeEarly and H.LaneEnemyAbsent(s) and LN.TowerShieldCountLoc(tLoc, t1, s.allyCreeps, bot:GetLocation()) >= 1 then
            H.ClearTowerEscape()
            H.ClearForcedRetreat()
        else
            State.noReenterEnemyT1Until = math.max(State.noReenterEnemyT1Until or 0, now + 2.2)
            if GetUnitToLocationDistance(bot, State.towerEscapeLoc) <= 75 then
                local fnt = P.GetFountain(bot)
                State.towerEscapeLoc = bot:GetLocation() + (fnt - bot:GetLocation()):Normalized() * 240
            end
            H.SmartMove(bot, State.towerEscapeLoc, 45)
            State.actionTaken = true
            return true
        end
    elseif (State.towerEscapeUntil or 0) > 0 then
        H.ClearTowerEscape()
    end

    -- True C++ T1 reach center-to-center = `868.0u` (`700 + 144 + 24`): `885u` eliminates the entire `[720u..868u]` blind zone!
    -- Pre-horn ward-return guard (`9072220529.dem` `tk=4390..4440` `dRT1=881u` bounce fix): while walking around Enemy T1
    -- before `0:02` with `0` tower aggro (`not onMeEarly`), only trigger emergency pushback inside `785u` (`> 724u` night sight/atk)!
    local dtimeTw = (type(DotaTime) == "function") and DotaTime() or 99
    local preHornSkirt = (dtimeTw < 2.0) and not onMeEarly
    local inRange = d <= (preHornSkirt and 785 or 885)
    if not inRange then State.t1EnterTime = nil end
    if d > escapeRad and not onMeEarly then return false end
    if State.actionTaken then return false end

    local onMe = onMeEarly
    local reason = nil
    if onMe then
        State.noReenterEnemyT1Until = math.max(State.noReenterEnemyT1Until or 0, now + 2.6)
        reason = "tower on me"
    elseif inRange then
        if not State.t1EnterTime then State.t1EnterTime = now end
        local shield = LN.TowerShieldCountLoc(tLoc, t1, s.allyCreeps, bot:GetLocation())
        local shieldHpTotal = 0
        for _, ac in pairs(s.allyCreeps or {}) do
            if U.CanQuery(ac) and ac:IsAlive() and U.DistanceBetweenLocations(ac:GetLocation(), tLoc) <= 780 then
                shieldHpTotal = shieldHpTotal + (ac:GetHealth() or 0)
            end
        end
        if shield == 0 or (shield == 1 and shieldHpTotal <= 235 and not H.LaneEnemyAbsent(s)) then
            State.noReenterEnemyT1Until = math.max(State.noReenterEnemyT1Until or 0, now + 2.6)
            reason = "no shield"
        else
            -- `v7.9.18` (`9079381960.dem` `02:41.60` `684.3u` 3x Windup-Cancel Fix):
            -- Outside Source 2's `500u` tower hero-aggro radius (`d >= 575u`) with a firm creep shield (`shieldHpTotal >= 250`
            -- and `not onMe`), attacking or casting Raze on an enemy hero NEVER switches T1 aggro onto us! Only enforce
            -- `DIVE_MAX_TIME` when stepped inside `< 575u` (true `500u` hero-aggro zone) or when shield is thin (`< 250 HP`)!
            local outsideHeroAggro500 = (d >= 575) and (shieldHpTotal >= 250) and (not onMe)
            local cur = bot:GetAttackTarget()
            local heroEngaged = State.aimingRaze and true or false
            if not heroEngaged and (not t1 or cur ~= t1) and (now - (State.heroAttackTime or -10)) <= 1.5 then heroEngaged = true end
            if not heroEngaged and cur and U.CanQuery(cur) and cur.IsHero and cur:IsHero() then heroEngaged = true end
            if heroEngaged and not outsideHeroAggro500 and (now - State.t1EnterTime) > (cfg.DIVE_MAX_TIME or 1.0) then
                reason = "dive budget"
            end
        end
    end

    if not reason and inRange and enemyHero and U.CanQuery(enemyHero) and bot.WasRecentlyDamagedByHero then
        if bot:WasRecentlyDamagedByHero(enemyHero, 1.5) then
            local killing = U.CanOneShotEnemyHero(bot, enemyHero) or U.CanQuickTurnKillWithRaze(bot, enemyHero)
            local committed = GameTime() < (State.commitKillUntil or 0)
            local R = K._race
            local firmShield575 = (not onMe) and (d >= 575)
                and (LN.HasFirmTowerCreepShield and LN.HasFirmTowerCreepShield(tLoc, t1, s.allyCreeps, bot:GetLocation(), 260))
                and (bot:GetHealth() or 0) >= math.max(380, (enemyHero:GetHealth() or 0) - 45)
                and not (R and R.valid and R.heCanKillSoon)
            local shieldHold = firmShield575
                or ((not onMe) and LN.TowerShieldCountLoc(tLoc, t1, s.allyCreeps, bot:GetLocation()) >= 1
                    and (bot:GetHealth() or 0) >= 520 and (t1 ~= nil and bot:GetAttackTarget() == t1)
                    and not (R and R.valid and R.heCanKillSoon))
            if not killing and not committed and not shieldHold then
                reason = "hero hits me under T1"
            end
        end
    end
    if not reason then return false end

    if reason ~= "no shield" and enemyHero and U.CanQuery(enemyHero) then
        local hp = bot:GetHealth()
        local maxHp = math.max(1, bot:GetMaxHealth())
        local tDmg = 100
        if t1 and U.CanQuery(t1) and t1.GetAttackDamage then
            local okD, v = pcall(t1.GetAttackDamage, t1)
            if okD and type(v) == "number" and v > 0 then tDmg = v end
        end
        local hpOk = hp >= maxHp * 0.40 and hp >= tDmg * 3
        local within = (now - (State.t1EnterTime or now)) <= (cfg.DIVE_MAX_TIME or 1.0)
        if hpOk and within then
            local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if U.CanOneShotEnemyHero(bot, enemyHero) and dist <= bot:GetAttackRange() + 60 then
                return false
            end
            if not onMe and U.CanQuickTurnKillWithRaze(bot, enemyHero) then
                return false
            end
        end
    end

    local burn = cfg.BURN_SEC or 2.5
    if (now - (State.lastTowerEscapeAt or -100)) < (cfg.REPEAT_WINDOW or 10) then burn = cfg.BURN_REPEAT_SEC or 6.0 end
    State.lastTowerEscapeAt = now
    State.towerBurnUntil = now + burn
    State.t1EnterTime = nil
    local escape = LN.TowerEscapePointLoc(bot, tLoc)
    State.towerEscapeLoc = escape
    State.towerEscapeUntil = now + (cfg.ESCAPE_COMMIT_SEC or 3.0)
    H.BeginForcedRetreat(bot, escape, 0.9)
    if U.DEBUG then print(string.format("[SF-BOT] tower escape (%s) d=%.0f", reason, d)) end
    return true
end

-- The tower burn is active (we had to leave the T1 recently)
function H.TowerBurnActive()
    return GameTime() < (State.towerBurnUntil or 0)
end

-- A few of my hits are left on the enemy T1 - hit it no matter what (`v7.9.24-pro` Visible + FoW `s.enemyT1LastHp` Finish!):
-- In 1v1 Mid, destroying Enemy T1 wins the match immediately. Supports BOTH visible `s.enemyT1` AND Highground FoW
-- `s.enemyT1LastHp` (e.g. `auto-20261108-1523` `07:22.47..07:50.73` where Radiant T1 had `14 HP` = `1` hit left in FoW!),
-- and runs BEFORE `RunSacredCS` so fresh creep waves NEVER distract SF from ending the game!
function H.HandleEnemyTowerFinish(bot, s, enemyHero)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not s or s.enemyT1Alive == false or not s.enemyT1Loc then return false end
    local finishable = (LN.IsTowerFinishableOrFoW and LN.IsTowerFinishableOrFoW(bot, s))
        or (s.enemyT1 and LN.IsTowerFinishable(bot, s.enemyT1))
    if not finishable then return false end

    if enemyHero and U.CanQuery(enemyHero) then
        if U.CanOneShotEnemyHero(bot, enemyHero) or U.CanQuickTurnKillWithRaze(bot, enemyHero) then
            return false
        end
    end

    State.t1EnterTime = nil
    State.towerBurnUntil = nil
    State.noReenterEnemyT1Until = nil
    H.ClearTowerEscape()
    H.ClearForcedRetreat()

    local t1 = s.enemyT1
    local tLoc = s.enemyT1Loc
    if t1 and U.CanQuery(t1) then
        local okL, liveLoc = pcall(t1.GetLocation, t1)
        if okL and liveLoc then tLoc = liveLoc end
        local hits = LN.TowerHitsToKill(bot, t1)
        if hits > 1 and H.TrySafeTreadsSwitch(bot, "FIGHT", true) then
            return true
        end
        if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= t1 then
            bot:Action_AttackUnit(t1, true)
            H.ClearMoveCache()
        end
        State.actionTaken = true
        return true
    end

    -- Enemy T1 is finishable (`<= 3` hits in `s.enemyT1LastHp`) but currently hidden in Highground FoW:
    -- Toggle Power Treads to `AGI` while stepping up onto the Highground vision/attack lip (`460u` from `tLoc`) to reveal & finish!
    if H.TrySafeTreadsSwitch(bot, "FIGHT", true) then
        return true
    end
    local fnt = P.GetFountain(bot)
    local revealPt = tLoc + (fnt - tLoc):Normalized() * 440
    H.SmartMove(bot, revealPt, 35)
    State.actionTaken = true
    return true
end

function H.IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps)
    if not ability or not enemyHero or not U.CanQuery(enemyHero) then return false end
    local t1 = H.GetEnemyT1Tower(enemyTowers)
    if not t1 or not t1:IsAlive() then return false end
    if H._hasTankCreepUnderTower(t1, allyCreeps) then return false end
    if H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then return false end
    local data = U.GetRazeAbilityData(ability)
    if not data then return false end
    local enemyNearTower = GetUnitToLocationDistance(t1, enemyHero:GetLocation()) <= 900
    if not enemyNearTower then return false end
    local botUnderT1 = GetUnitToLocationDistance(bot, t1:GetLocation()) <= 880
    local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, data.center)
    local setupUnderT1 = setupPos and U.DistanceBetweenLocations(setupPos, t1:GetLocation()) < 900
    if botUnderT1 or setupUnderT1 then
        return true
    end
    return false
end

function H.HandleMidStackSpacing(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana()<75 or not U.IsRazeAbilityCastable(bot,H.GetRazeAbilityByLabel(bot,"mid")) then return false end
    if enemyHero:GetAttackTarget()==bot and GetUnitToLocationDistance(bot,enemyHero:GetLocation())<=bot:GetAttackRange() then return false end
    local active, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if not active or hitLabel ~= "mid" then return false end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local minHold = C.RAZE.NEAR_CENTER + 110
    local maxHold = C.RAZE.FAR_CENTER - 110
    local desired = C.RAZE.MID_CENTER
    if dist >= minHold and dist <= maxHold then return false end
    local dir = botLoc - enemyLoc
    if dist < 1 then
        dir = U.GetFountain(bot) - enemyLoc
    end
    dir = dir:Normalized()
    local holdLoc = enemyLoc + dir * desired
    holdLoc = H.GetSafeApproachLoose(bot, holdLoc, enemyTowers or {}, allyCreeps or {})
    return H.SmartMove(bot, holdLoc, 35)
end

function H.GetNearRazeAttackFollowupInfo(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil, nil, nil end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return false, nil, nil, nil end
    local nearRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
    local atkRaw = bot:GetAttackDamage() or 0
    local atkActual = enemyHero:GetActualIncomingDamage(atkRaw, DAMAGE_TYPE_PHYSICAL)
    if atkActual <= 0 then return false, nil, nil, nil end
    local hpAfterRaze = enemyHero:GetHealth() - nearRazeDmg
    if hpAfterRaze <= 0 then return false, nearRazeDmg, atkActual, 0 end
    local attacksNeeded = math.ceil(hpAfterRaze / atkActual)
    if attacksNeeded >= 1 and attacksNeeded <= 2 then
        return true, nearRazeDmg, atkActual, attacksNeeded
    end
    return false, nearRazeDmg, atkActual, attacksNeeded
end

function H.HandleCloseAttackFinish(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not H.HasRazeResource(bot) then return false end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local underT1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if underT1 and not H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then
        return false
    end
    local canFinish, _, _, attacksNeeded = H.GetNearRazeAttackFollowupInfo(bot, enemyHero)
    if not canFinish then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) and not canOneShot then return false end
    if not H.IsSafeToCommitKillAttack(bot, enemyHero, enemyTowers, allyCreeps) and not canOneShot then return false end
    local attackRange = bot:GetAttackRange() + 60
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if dist <= attackRange then
        return H.IssueHeroAttack(bot, enemyHero)
    end
    if dist <= attackRange + 260 then
        local botLoc = bot:GetLocation()
        local dir = (enemyHero:GetLocation() - botLoc):Normalized()
        local approachLoc = botLoc + dir * math.min(dist - attackRange + 20, 220)
        if H.ApproachEnemyPoint(bot, enemyHero, approachLoc, 35, enemyTowers, allyCreeps) then
            return true
        end
    end
    return false
end

function H.HandleLethalTwoRazeSequence(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if H.GetPotentialCombatMana(bot) < 150 then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana() < 75 and H.TryUseBurstManaItem(bot, true) then return true end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")
    if not q or q:GetLevel() == 0 then return false end

    local stacks = U.GetShadowrazeDebuff(enemyHero)
    if stacks ~= 0 then return false end

    local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
    local twoRaze = U.GetTwoRazeDamage(bot, enemyHero)
    if twoRaze < enemyHero:GetHealth() then return false end
    if oneRaze >= enemyHero:GetHealth() then return false end

    local candidates = {
        { label = "mid",  ability = w, center = C.RAZE.MID_CENTER  },
        { label = "far",  ability = e, center = C.RAZE.FAR_CENTER  },
        { label = "near", ability = q, center = C.RAZE.NEAR_CENTER },
    }

    for _, c in ipairs(candidates) do
        if c.ability and U.IsRazeAbilityCastable(bot, c.ability) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, c.ability, enemyTowers, allyCreeps) then
            local actionType, aimLoc = H.GetRazeActionType(bot, c.ability, enemyHero)
            if actionType and H.CastOrTurnRaze(bot, c.ability, actionType, aimLoc, enemyHero) then
                return true
            end
        end
    end

    local opener = nil
    if w and U.IsRazeAbilityCastable(bot, w) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, w, enemyTowers, allyCreeps) then
        opener = { ability = w, center = C.RAZE.MID_CENTER, label = "mid" }
    elseif e and U.IsRazeAbilityCastable(bot, e) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, e, enemyTowers, allyCreeps) then
        opener = { ability = e, center = C.RAZE.FAR_CENTER, label = "far" }
    elseif q and U.IsRazeAbilityCastable(bot, q) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then
        opener = { ability = q, center = C.RAZE.NEAR_CENTER, label = "near" }
    end

    if opener then
        local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, opener.center)
        if setupPos then
            local currentDist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if math.abs(currentDist - opener.center) > 90 then
                if H.ApproachEnemyPoint(bot, enemyHero, setupPos, 35, enemyTowers, allyCreeps) then
                    return true
                end
            end
        end
    end

    return false
end

function H.TryRazeEnemy(bot, enemyHero, current_mode, enemyTowers, allyCreeps, isLethalChase, forceExtend)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false end
    if not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end

    if bot:GetMana() < 75 and H.GetPotentialCombatMana(bot) >= 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end

    local ability, actionType, aimLoc = U.GetBestRaze(bot, enemyHero, current_mode, isLethalChase or false, forceExtend or false)
    if ability then
        local data = U.GetRazeAbilityData(ability)
        local predDist = GetUnitToLocationDistance(bot, aimLoc or enemyHero:GetLocation())
        local underT1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
        if data and data.label == "near" and predDist > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) and not isLethalChase and not forceExtend then
            ability, actionType, aimLoc = nil, nil, nil
        elseif data and data.label == "near" and underT1 and not H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) and not isLethalChase and not forceExtend then
            ability, actionType, aimLoc = nil, nil, nil
        elseif data and (data.label == "mid" or data.label == "far") and H.IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps) then
            ability, actionType, aimLoc = nil, nil, nil
        end
    end

    if H.CastOrTurnRaze(bot, ability, actionType, aimLoc, enemyHero) then return true end

    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    local followUp = stacks > 0 and rem_time >= (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2)
    if (forceExtend or (stacks > 0 and rem_time <= C.RAZE.EXTEND_AT + 0.6) or isLethalChase or followUp) and bot:GetMana() >= 75 then
        local setupPos = U.GetRazeSetupPosition(bot, enemyHero)
        -- Do not close in for a finishing raze into the NEAR band (200 from him) - that is his
        -- right-click range and his near raze; finish from mid/far or do not finish at all
        if setupPos and followUp and not isLethalChase and not forceExtend then
            local pred = U.PredictPosition(enemyHero, 0.35) or enemyHero:GetLocation()
            if U.DistanceBetweenLocations(setupPos, pred) <= C.RAZE.NEAR_CENTER + 10 then setupPos = nil end
        end
        if setupPos then
            -- Approaching his T1 for a raze is allowed while the tower is busy with a creep (a raze gives no aggro)
            -- and his burst cannot kill us; not below 50% HP.
            local allowDive = isLethalChase
            if not allowDive and (followUp or forceExtend) then
                local R = K._race
                local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
                if hpPct >= 0.5 and not (R and R.valid and R.heCanKillSoon) and H.TowerLockedOnCreep(W.s.enemyT1) then
                    allowDive = true
                end
            end
            -- If the safe boundary (tower) cuts off most of the approach, the raze position is
            -- unreachable: do not stamp at the boundary, give the tick to siege/last hits (not for finishing).
            local reachable = true
            if not isLethalChase then
                local clamped = H.GetSafeApproachLoose(bot, setupPos, enemyTowers or {}, allyCreeps or {})
                if clamped and U.DistanceBetweenLocations(clamped, setupPos) > 200 then reachable = false end
            end
            if reachable and H.ApproachEnemyPoint(bot, enemyHero, setupPos, 35, enemyTowers, allyCreeps, allowDive) then
                return true
            end
        end
    end

    return false
end

function H.StackLeadThirdRazeOK(bot, enemy, ability, point, snapshot)
    if not ability or not K.HasRazeStackLead(bot, enemy) then return false end
    if State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc
        or GameTime() < (State.fleeUntil or 0) then return false end
    local stacks, remain = U.GetShadowrazeDebuff(enemy)
    if stacks ~= 2 or not U.IsRazeAbilityCastable(bot, ability) then return false end
    local data = U.GetRazeAbilityData(ability)
    if not data or data.label == "near" then return false end
    local race = K._race
    if not race or not race.valid or race.heCanKillSoon then return false end
    local horizon = U.DistanceBetweenLocations(bot:GetLocation(), point) / math.max(1, bot:GetCurrentMovementSpeed())
        + C.RAZE.CAST_POINT + (C.RAZE.LAND_LEAD or 0.08) + 0.1
    if horizon > 1.25 or remain <= horizon + 0.1 then return false end
    local predicted = U.PredictPosition(enemy, horizon)
    local d = U.DistanceBetweenLocations(point, enemy:GetLocation())
    local dp = U.DistanceBetweenLocations(point, predicted)
    if math.max(math.abs(d-data.center), math.abs(dp-data.center)) > C.RAZE.HIT_RADIUS - 40 then return false end
    local before = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local beforePred = GetUnitToLocationDistance(bot, predicted)
    local replies = K.EnemyBandsAcross(enemy, math.min(d, dp, before, beforePred), math.max(d, dp, before, beforePred), horizon)
    if replies > 1 then return false end -- Do not turn 2:1 into a possible 3:3.
    local snap = snapshot or {}
    for _, tower in pairs(snap.enemyTowers or {}) do
        if tower and tower:IsAlive() and (GetUnitToLocationDistance(bot, tower:GetLocation()) < 900
            or U.DistanceBetweenLocations(point, tower:GetLocation()) < 900) then return false end
    end
    local incoming = K.EnemyRazeDamage(bot, enemy, replies)
    if math.min(d, dp) <= enemy:GetAttackRange() + enemy:GetCurrentMovementSpeed() * horizon then
        incoming = incoming + K.AttackDamageVs(enemy, bot) * math.ceil(horizon / math.max(0.6, enemy:GetSecondsPerAttack()))
    end
    for _, creep in pairs(snap.enemyCreeps or {}) do
        if U.CanQuery(creep) and creep:IsAlive() then
            if creep:GetAttackTarget() == bot or U.DistanceBetweenLocations(point, creep:GetLocation()) <= 500 then
                incoming = incoming + K.AttackDamageVs(creep, bot) * math.max(1, math.ceil(horizon / math.max(0.75, creep:GetSecondsPerAttack())))
            end
        end
    end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if not projectile.is_attack or not U.CanQuery(projectile.caster) then return false end
            incoming = incoming + K.AttackDamageVs(projectile.caster, bot)
        end
    end
    -- Account for enemy instant heals + post-cast retreat damage when walking into enemy range:
    -- NEVER step forward at low HP against a healthy higher-stat SF unless the 3rd raze is lethal.
    local enEffHp = (enemy:GetHealth() or 0) + (U.HasItem(enemy, "item_faerie_fire") and 85 or 0) + U.GetStickCharges(enemy) * 15
    local myThirdRaze = K.MyRazeDamage(bot, enemy, 1)
    local lethalFinish = (enEffHp - myThirdRaze) <= K.AttackDamageVs(bot, enemy) * 1.15
    if lethalFinish then
        return bot:GetHealth() - incoming >= math.max(95, K.AttackDamageVs(enemy, bot) * 1.1)
    end
    local retreatGap = math.max(0, (enemy:GetAttackRange() + 90) - d)
    local retreatTime = math.min(2.2, retreatGap / math.max(1, bot:GetCurrentMovementSpeed()))
    local postDisengageIncoming = incoming + K.AttackDamageVs(enemy, bot) * math.ceil(retreatTime / math.max(0.65, enemy:GetSecondsPerAttack()))
    local myAfter = bot:GetHealth() - postDisengageIncoming
    local enAfter = enEffHp - myThirdRaze
    return myAfter >= math.max(210, K.AttackDamageVs(enemy, bot) * 2.8) and myAfter >= (enAfter - 95)
end

function H.HandleStackLead(bot, snapshot, race)
    local enemy = snapshot.enemy
    if not K.HasRazeStackLead(bot, enemy) or State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
    for _, label in ipairs({"far", "mid"}) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if H.StackLeadThirdRazeOK(bot, enemy, ab, bot:GetLocation(), snapshot) then
            local action, aim = H.GetRazeActionType(bot, ab, enemy)
            if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then return true end
        end
        if ab and U.IsRazeAbilityCastable(bot, ab) and distance > K.Center(label) + 150 then
            local point = enemy:GetLocation() + (bot:GetLocation()-enemy:GetLocation()):Normalized() * (K.Center(label)+150)
            if H.StackLeadThirdRazeOK(bot, enemy, ab, point, snapshot)
                and H.ApproachEnemyPoint(bot, enemy, point, 25, snapshot.enemyTowers, snapshot.allyCreeps, false, ab) then return true end
        end
    end
    -- `9070869385.dem` `03:00.53–03:01.87` Anti-Conveyor `HandleStackLead` Fix:
    -- NEVER walk backward from `d < 585u` (`557u`) through a ready `700u` `Shadowraze3` when `450u` `mid` is already on CD,
    -- and NEVER force a `0.45s` stack-lead retreat when `K.HasDominantRightClickPosture` holds right-click supremacy!
    local walkingOutIntoReadyR3 = (distance < 585)
        and (K.EnemyRazeReadyIn("mid") > 1.8)
        and (K.EnemyRazeReadyIn("far") <= 1.2)
    local domRightClickLead = K.HasDominantRightClickPosture and K.HasDominantRightClickPosture(bot, enemy, snapshot)
    if K.EnemyBandsAcross(enemy, distance, distance, 0.7) > 0
        and not walkingOutIntoReadyR3
        and not domRightClickLead then
        local _, outer = K.EnemyBandsAcross(enemy, 0, 2000, 1.0)
        local safe = math.max(distance + 120, outer + 60)
        local point = enemy:GetLocation() + (bot:GetLocation()-enemy:GetLocation()):Normalized() * safe
        point = H.GetSafeApproach(bot, point, snapshot.enemyTowers, snapshot.allyCreeps)
        H.ClearRazeState()
        return H.BeginForcedRetreat(bot, point, 0.45)
    end
    return false
end

-- A confirmed first hit may be followed by ONE other ranged raze, even at
-- equal resources. This is not permission to initiate against an equal opponent.
function H.GetPendingRazeFollowup(bot, enemy, race, snapshot)
    local chain = State.razeFollowup
    if not chain or chain.enemy ~= enemy or not U.CanQuery(enemy) then return nil end
    local now = GameTime()
    if now > chain.untilTime or now < chain.opened + C.RAZE.CAST_POINT then return nil end
    if not race or not race.valid or race.heCanKillSoon then return nil end
    local stacks, remaining = U.GetShadowrazeDebuff(enemy)
    if stacks <= chain.stacks then return nil end -- No blind chase after a miss.
    local ab = H.GetRazeAbilityByLabel(bot, chain.label)
    if not U.IsRazeAbilityCastable(bot, ab) then return nil end
    local center = U.GetRazeCenterByLabel(chain.label)
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dist < 350 or dist > 1000 then return nil end
    local reach = center + C.RAZE.STRICT_RADIUS - 30
    local horizon = math.max(0, dist - reach) / math.max(1, bot:GetCurrentMovementSpeed())
        + C.RAZE.CAST_POINT + (C.RAZE.LAND_LEAD or 0.08) + 0.1
    if horizon > chain.untilTime - now or remaining <= horizon + 0.1
        or not K.CanCatch(bot, enemy, reach, horizon) then return nil end
    local snap = snapshot or W.s or {}
    local goal = enemy:GetLocation() + (bot:GetLocation() - enemy:GetLocation()):Normalized() * center
    for _, tower in pairs(snap.enemyTowers or {}) do
        if tower and tower:IsAlive() and (GetUnitToLocationDistance(bot, tower:GetLocation()) < 800
            or U.DistanceBetweenLocations(goal, tower:GetLocation()) < 800) then return nil end
    end
    local incoming, count = K.EnemyBurstVs(bot, enemy, math.min(dist, center), horizon, false)
    local enemyRange = (enemy:GetAttackRange() or 525) + 80
    if math.min(dist, center) > enemyRange
        and math.min(dist, center) <= enemyRange + enemy:GetCurrentMovementSpeed() * horizon then
        incoming = incoming + K.AttackDamageVs(enemy, bot)
    end
    local regen = math.max(0, enemy.GetManaRegen and enemy:GetManaRegen() or 0)
    local extra = math.floor((K.EnemyManaBudget(enemy, true) + regen * horizon) / 75)
        - math.floor(K.EnemyManaBudget(enemy, true) / 75)
    if extra > 0 then
        incoming = incoming + K.EnemyRazeDamage(bot, enemy, math.min(3, count + extra))
            - K.EnemyRazeDamage(bot, enemy, count)
    end
    for _, creep in pairs(snap.enemyCreeps or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then
            incoming = incoming + K.AttackDamageVs(creep, bot)
                * math.ceil(horizon / math.max(0.6, creep:GetSecondsPerAttack()))
        end
    end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if not projectile.is_attack or not U.CanQuery(projectile.caster) then return nil end
            incoming = incoming + K.AttackDamageVs(projectile.caster, bot)
        end
    end
    if bot:GetHealth() - incoming < math.max(110, K.AttackDamageVs(enemy, bot)) then return nil end
    if incoming > K.MyRazeDamage(bot, enemy, 1) + math.max(80, bot:GetHealth() - enemy:GetHealth()) then return nil end
    return ab, center
end

function H.HandlePendingRazeFollowup(bot, enemy, race, snapshot)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local ab, center = H.GetPendingRazeFollowup(bot, enemy, race, snapshot)
    if not ab then return false end
    local action, aim = H.GetRazeActionType(bot, ab, enemy)
    if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then return true end
    local predicted = U.PredictPosition(enemy, 0.3)
    local desired = center == C.RAZE.MID_CENTER and center + 150 or center
    local setup = predicted + (bot:GetLocation() - predicted):Normalized() * desired
    if not setup then return false end
    for _, tower in pairs(snapshot.enemyTowers or {}) do
        if tower and tower:IsAlive() and U.DistanceBetweenLocations(setup, tower:GetLocation()) < 800 then return false end
    end
    return H.ApproachEnemyPoint(bot, enemy, setup, 25, snapshot.enemyTowers or {}, snapshot.allyCreeps or {})
end

function H.EnemyStackNeedsImmediateExtension(bot, enemyHero)
    if not U.CanQuery(enemyHero) then return false end
    if bot:GetMana() < 75 then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks <= 0 then return false end
    if rem_time <= 0.15 then return false end
    if rem_time > C.RAZE.EXTEND_AT + 0.6 then return false end
    -- Do not run to extend a stack on an enemy we cannot reach before it expires (previously
    -- a pointless jog after an enemy that left): the far raze must be reachable in the remaining stack time.
    if not K.CanCatch(bot, enemyHero, C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS - 60, math.max(0.3, rem_time - C.RAZE.CAST_POINT)) then
        return false
    end
    -- Mana/defence discipline: extending a stack also costs 75 mana and must NEVER walk a wounded/outstatted hero forward.
    local R = K._race
    if R and R.valid and R.heCanKillSoon and not R.canKillNow then return false end
    if R and R.valid and R.losingHard and not R.canKillSoon then return false end
    local minSafeHp = math.max(220, K.AttackDamageVs(enemyHero, bot) * 3.0)
    local killing = R and R.valid and R.canKillSoon
    if killing then return bot:GetHealth() >= math.max(110, K.AttackDamageVs(enemyHero, bot) * 1.4) end
    if bot:GetHealth() < minSafeHp then return false end
    -- A clear advantage in the trade (edge >= 100, he cannot kill us right away) - extend the stack
    if R and R.valid and R.edge >= 100 and not R.heCanKillNow and (bot:GetMana() - 75) >= 75 then return true end
    if State.defensive and not H.HasTradeSupport(R) then return false end
    if H.HarassManaOK(bot, R) then return true end
    if stacks >= 2 and R and R.valid and R.edge >= 40 and (bot:GetMana() - 75) >= 75 then return true end
    return false
end

function H.ForceExtendEnemyStack(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not H.EnemyStackNeedsImmediateExtension(bot, enemyHero) then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return true end
    if State.actionTaken then return false end

    State.prepTarget = nil
    State.attackTarget = nil
    State.attackStartTime = 0
    State.firedThisAttack = false
    State.aggroPullTime = 0
    State.deaggroTime = 0

    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    local isLethal = U.GetTwoRazeDamage(bot, enemyHero) >= enemyHero:GetHealth() * 0.90
    local ability, actionType, aimLoc = U.GetBestRaze(bot, enemyHero, "AGGRESSIVE", isLethal, true)
    if ability and actionType then
        local data = U.GetRazeAbilityData(ability)
        if data and data.label == "near" and actionType == "TURN" then
            local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if distToEnemy > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then
                ability = nil
                actionType = nil
            end
        end
        if ability and actionType and H.CastOrTurnRaze(bot, ability, actionType, aimLoc, enemyHero) then
            return true
        end
    end

    local shouldCloseIn, closePos = U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if shouldCloseIn and closePos then
        if H.ApproachEnemyPoint(bot, enemyHero, closePos, 35, enemyTowers, allyCreeps) then
            return true
        end
    end

    local setupPos = U.GetRazeSetupPosition(bot, enemyHero)
    if setupPos then
        if H.ApproachEnemyPoint(bot, enemyHero, setupPos, 45, enemyTowers, allyCreeps) then
            return true
        end
    end

    local desiredCenter = C.RAZE.MID_CENTER
    local enemyLoc = enemyHero:GetLocation()
    local botLoc = bot:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local desired = nil
    if dist > desiredCenter + 60 then
        local dir = (enemyLoc - botLoc):Normalized()
        desired = botLoc + dir * math.min(dist - desiredCenter, 380)
    elseif dist < desiredCenter - 100 then
        local dir = (botLoc - enemyLoc):Normalized()
        desired = enemyLoc + dir * desiredCenter
    else
        return false
    end
    if H.ApproachEnemyPoint(bot, enemyHero, desired, 45, enemyTowers, allyCreeps) then
        return true
    end
    return false
end

function H.LevelUpAbilities(bot)
    local ap = (bot.GetAbilityPoints and bot:GetAbilityPoints()) or 0
    local lvl = math.min(30, (bot.GetLevel and bot:GetLevel()) or 1)
    -- `v7.9.20-pro` (`9080457787.dem` `invalid order (60). Ability is hidden.` Zero-Spam Engine Fix):
    --   1. In Dota 2 `7.41f`, `"special_bonus_attributes"` sits in `m_vecAbilities.0015` (`CDOTA_Ability_Special_Bonus_Attributes`)
    --      with `m_bHidden == true`. Humans upgrade it via protobuf `DOTA_CM_SpecialAbility = 358`, whereas the restricted
    --      Bot Script VM only exposes `ActionImmediate_LevelAbility(name)` -> `DOTA_UNIT_ORDER_TRAIN_ABILITY` (`order = 11`),
    --      which `server.dll` rejects on hidden abilities with error `60: Ability is hidden` (`4,264` console warnings in `9080457787.dem`!).
    --   2. Strictly gate `TryLearn` on `not (ab.IsHidden and ab:IsHidden())`: visible Talents (`m_vecAbilities.0007..0014`,
    --      `m_bHidden == false`) and core skills upgrade cleanly with ZERO console errors, and once all non-hidden skills
    --      available at `(lvl, ap)` are maxed we memoize `(lvl, ap)` so `LevelUpAbilities` costs `0.000ms` per tick!
    if State.maxedNonHiddenLvl == lvl and State.maxedNonHiddenAP == ap then
        return
    end

    local function TryLearn(name, wantRanks, allowZeroAPTalent)
        if not name then return false end
        if C.SKILL and C.SKILL.ALLOW_FRENZY == false and name == "nevermore_frenzy" then
            return false
        end
        if name == "nevermore_requiem" then
            return false
        end
        local isRealTalent = (string.find(name, "special_bonus", 1, true) ~= nil) and (name ~= "special_bonus_attributes")
        if ap <= 0 and not (allowZeroAPTalent and isRealTalent) then
            return false
        end
        local maxRank = isRealTalent and 1
            or ((name == "special_bonus_attributes") and math.min(7, wantRanks or 7) or math.min(4, wantRanks or 4))
        local okA, ab = pcall(bot.GetAbilityByName, bot, name)
        if okA and ab and not (ab.IsHidden and ab:IsHidden()) and ab.GetLevel and (ab:GetLevel() or 0) < maxRank then
            local canUpg = (ab.CanAbilityBeUpgraded == nil) and (ap > 0) or ab:CanAbilityBeUpgraded()
            if canUpg then
                State.maxedNonHiddenLvl = nil
                State.maxedNonHiddenAP = nil
                bot:ActionImmediate_LevelAbility(name)
                return true
            end
        end
        return false
    end

    -- 1. Core `L1..L8` progression (`Q` at `1,3,5,7` -> `4/4`; `Presence` at `2,4,6,8` -> `4/4`; `0` Requiem, `0` Frenzy):
    if ap > 0 then
        local wantRaze = math.min(4, math.floor((lvl + 1) / 2))
        if wantRaze >= 1 and TryLearn("nevermore_shadowraze1", wantRaze, false) then return end
        local wantPresence = math.min(4, math.floor(lvl / 2))
        if wantPresence >= 1 and TryLearn("nevermore_dark_lord", wantPresence, false) then return end
    end

    -- 2. Milestone Talents (`L10, L15, L20, L25`) — checked EVEN WHEN `ap == 0` so free `7.40+` Talent Points train immediately!
    local talents = (C.SKILL and C.SKILL.TALENTS) or {
        { minLevel = 10, name = "special_bonus_unique_nevermore_7" },
        { minLevel = 15, name = "special_bonus_unique_nevermore_3" },
        { minLevel = 20, name = "special_bonus_unique_nevermore_1" },
        { minLevel = 25, name = "special_bonus_unique_nevermore_raze_procsattacks" },
    }
    for _, t in ipairs(talents) do
        if lvl >= t.minLevel and TryLearn(t.name, 1, true) then
            return
        end
    end

    if ap <= 0 then
        State.maxedNonHiddenLvl = lvl
        State.maxedNonHiddenAP = ap
        return
    end

    -- 3. Remaining Ability Points (`L9+`): upgrades `"special_bonus_attributes"` if Valve ever un-hides `slot[15]`,
    --    otherwise cleanly memoizes `(lvl, ap)` with ZERO `invalid order (60)` console spam!
    if TryLearn("special_bonus_attributes", 7, false) then return end

    -- 4. Deterministic safety fallback (`0` Requiem, `0` Frenzy):
    for _, fb in ipairs({
        "nevermore_shadowraze1",
        "nevermore_dark_lord",
        "special_bonus_attributes",
    }) do
        if TryLearn(fb, 7, false) then return end
    end

    State.maxedNonHiddenLvl = lvl
    State.maxedNonHiddenAP = ap
end

function H.IsInDangerForRegen(bot, heroDist)
    heroDist = math.min(1600, heroDist or 850)
    local heroes = bot:GetNearbyHeroes(heroDist, true, BOT_MODE_NONE)
    if heroes and #heroes > 0 then return true end
    local creeps = bot:GetNearbyLaneCreeps(600, true)
    if creeps and #creeps > 0 then return true end
    local projs = bot:GetIncomingTrackingProjectiles()
    if projs and #projs > 0 then return true end
    return false
end

function H.HasEnemyProjectileIncoming(bot)
    local projs = bot:GetIncomingTrackingProjectiles() or {}
    for _, p in pairs(projs) do
        local caster = p and p.caster
        if caster then
            local isEnemy = true
            if caster.GetTeam then
                isEnemy = caster:GetTeam() ~= bot:GetTeam()
            end
            if isEnemy then
                return true, p
            end
        end
    end
    return false, nil
end

-- Only Hero / Tower projectiles can cancel `modifier_flask_healing` in Dota 2 7.00-7.41f!
-- Ranged lane creep projectiles NEVER break Healing Salve — treating ranged creep attacks as
-- Salve-breaking caused `BAR 9:09-9:16` (`(1367,1047) -> (2543,2113)` walk away from Mid T1)!
function H.HasSalveBreakingProjectileIncoming(bot)
    local projs = bot:GetIncomingTrackingProjectiles() or {}
    for _, p in pairs(projs) do
        local caster = p and p.caster
        if caster then
            local isEnemy = (not caster.GetTeam) or (caster:GetTeam() ~= bot:GetTeam())
            if isEnemy then
                local okH, isHero = false, false
                if caster.IsHero then okH, isHero = pcall(caster.IsHero, caster) end
                local okT, isTower = false, false
                if caster.IsTower then okT, isTower = pcall(caster.IsTower, caster) end
                if (okH and isHero) or (okT and isTower) then
                    return true, p
                end
            end
        end
    end
    return false, nil
end

function H.GetSalveSafeRetreatLocation(bot, enemyHero)
    local fountain = P.GetFountain(bot)
    local botLoc = bot:GetLocation()
    local safeDistance = 1120
    if enemyHero and U.CanQuery(enemyHero) then
        local enemyLoc = enemyHero:GetLocation()
        local dir = fountain - enemyLoc
        if U.DistanceBetweenLocations(fountain, enemyLoc) < 1 then
            dir = fountain - botLoc
        end
        dir = dir:Normalized()
        return enemyLoc + dir * safeDistance
    end
    -- When enemy hero is in fog, NEVER walk toward Fountain past `T1 + 420u` (`BAR 9:10` fix)!
    local t1Safe = P.GetT1Close(bot, 420)
    if t1Safe then
        return t1Safe
    end
    local dir = (fountain - botLoc):Normalized()
    return botLoc + dir * 280
end

function H.HandleActiveSalveSafety(bot, enemyHero)
    if not bot:HasModifier("modifier_flask_healing") then
        return false
    end
    if (bot:GetHealth() or 0) >= (bot:GetMaxHealth() or 1) * 0.96 then
        return false
    end
    local safeDistance = 1065
    local incomingProjectile = H.HasSalveBreakingProjectileIncoming(bot)
    local tooCloseToEnemy = false
    if enemyHero and U.CanQuery(enemyHero) then
        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if dist < safeDistance then
            tooCloseToEnemy = true
        end
    end
    if incomingProjectile or tooCloseToEnemy then
        local safeLoc = H.GetSalveSafeRetreatLocation(bot, enemyHero)
        H.BeginForcedRetreat(bot, safeLoc, 0.65)
        return true
    end
    -- Already outside `1065u` and 0 hero/tower projectiles: DO NOT freeze in place with `actionTaken = true`!
    -- Allow normal lane positioning / CS to operate smoothly inside XP range while Salve finishes ticking!
    return false
end

-- Safety condition: he has no time to turn around, catch up and land a second stack on us.
-- Finishing a creep right after the enemy hero's projectile. His projectile is in flight,
-- and after it lands the creep falls into my finish threshold -> hit now so my attack lands
-- right after his (the window between his hit and the creep dying).
function H.HandleProjectileSnipe(bot, enemyCreeps, enemyHero, enemyTowers, allyCreeps)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local now = GameTime()
    if now < (State.snipeCooldown or 0) then return false end
    if State.prepTarget then return false end
    local myPoint = bot:GetAttackPoint() or 0.5
    for _, c in pairs(enemyCreeps or {}) do
        if c and U.CanQuery(c) and c:IsAlive() then
            local projs = U.SafeGetIncomingProjectiles(c)
            if type(projs) == "table" then
                for _, pr in pairs(projs) do
                    if pr.is_attack and pr.caster == enemyHero then
                        local speed = 1200
                        if enemyHero.GetAttackProjectileSpeed then
                            local okS, sp = pcall(enemyHero.GetAttackProjectileSpeed, enemyHero)
                            if okS and type(sp) == "number" and sp > 0 then speed = sp end
                        end
                        local eta = 0.3
                        if pr.location then
                            eta = U.DistanceBetweenLocations(pr.location, c:GetLocation()) / speed
                        end
                        if eta <= 0.7 then
                            local myDmg = U.SFDamageRange(bot, c).min
                            local ctx = U.GetTargetPredictionContext(c, { enemyHero })
                            local hpAfter = U.PredictHPWithContext(ctx, c, eta + 0.05, "avg")
                            -- his hit does not kill the creep but makes it mine
                            if hpAfter > 0 and hpAfter <= myDmg * 0.97 then
                                local travel = 0.2
                                if bot.GetAttackProjectileSpeed then
                                    local okPS, psp = pcall(bot.GetAttackProjectileSpeed, bot)
                                    if okPS and type(psp) == "number" and psp > 0 then
                                        travel = U.DistanceBetweenLocations(bot:GetLocation(), c:GetLocation()) / psp
                                    end
                                end
                                local impact = myPoint + travel + 0.03
                                -- my attack lands AFTER his projectile and inside the window before the creep dies
                                if impact >= eta - 0.06 and impact <= eta + 1.1 then
                                    if H.IsSafeToAttack(bot, c:GetLocation(), enemyTowers, allyCreeps) then
                                        State.prepTarget = c
                                        State.prepTargetTime = now
                                        State.snipeCooldown = now + 0.3
                                        if not U.IsAttackingAction(bot)
                                            or bot:GetAttackTarget() ~= c then
                                            bot:Action_AttackUnit(c, true)
                                            H.ClearMoveCache()
                                        end
                                        return true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

-- At the end of an already-started dry duel, take the remaining swings instead of wasting them walking.
function H.HandleDryLastStand(bot,enemy,s)
    if State.actionTaken or bot:GetHealth()>bot:GetMaxHealth()*0.40 or not U.CanQuery(enemy) or enemy:GetAttackTarget()~=bot or bot:IsUsingAbility() or bot:IsChanneling()
        or bot:IsStunned() or (bot.IsDisarmed and bot:IsDisarmed()) or State.towerEscapeLoc then return false end
    local now=GameTime()
    local involved=bot:GetAttackTarget()==enemy
        or (State.heroAttackTarget==enemy and now-(State.heroAttackTime or -100)<2)
        or (State.heroCombatEnemy==enemy and now<(State.heroCombatUntil or 0))
    if not involved or GetUnitToLocationDistance(bot,enemy:GetLocation())>bot:GetAttackRange() then return false end
    if K.MyManaBudget(bot,true)+math.max(0,(bot.GetManaRegen and bot:GetManaRegen()) or 0)*0.8>=75
        or K.EnemyManaBudget(enemy,true)+math.max(0,(enemy.GetManaRegen and enemy:GetManaRegen()) or 0)*0.8>=75 then return false end
    local damage=bot:GetActualIncomingDamage(enemy:GetAttackDamage()+math.max(3,(enemy.GetBaseDamageVariance and enemy:GetBaseDamageVariance()) or 0),DAMAGE_TYPE_PHYSICAL)
    local committed=State.lastStandEnemy==enemy and now<(State.lastStandUntil or 0)
    if damage<=0 or (not committed and (bot:GetHealth()>damage*2
        or enemy:GetHealth()>math.max(enemy:GetMaxHealth()*0.40,K.AttackDamageVs(bot,enemy)*3))) then return false end
    for _,tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot,tower:GetLocation())<900 then return false end
    end
    -- Explicit last-stand exception: only this dry, in-range case may cancel a prior hero retreat.
    H.ClearForcedRetreat();State.survivalLoc=nil;State.survivalUntil=0;State.fleeUntil=0
    State.dodgeLoc=nil;State.dodgeUntil=0;State.goingToFountain=false;State.fountainReason=nil
    State.towerChaseBlockedEnemy=nil;State.heroCombatAllowed=true
    if not H.IssueHeroAttack(bot,enemy) then return false end
    State.lastStandEnemy=enemy;State.lastStandUntil=now+1.0
    State.actionTaken=true;State.lastCombatStage="dry-last-stand"
    return true
end

-- After an exchange, a hero already in attack range gets an actionable answer, not a spacing tour.
function H.HandleContactTrade(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) or enemy:GetAttackTarget()~=bot then return false end
    local ours,ourTime=U.GetShadowrazeDebuff(bot)
    local theirs,theirTime=U.GetShadowrazeDebuff(enemy)
    if ours<2 or theirs<2 or ourTime<=0.2 or theirTime<=0.2 then return false end
    local distance=GetUnitToLocationDistance(bot,enemy:GetLocation())
    if distance>bot:GetAttackRange() then return false end
    if H.HandleGuaranteedRazeKill(bot,enemy,s.enemyTowers or {},s.allyCreeps or {})
        or H.HandleGuaranteedAttackKill(bot,enemy,s.enemyTowers or {},s.allyCreeps or {}) then
        State.actionTaken=true;State.lastCombatStage="contact-trade-finish"
        return true
    end
    local horizon=(bot:GetAttackPoint() or 0.5)+distance/math.max(1,bot:GetAttackProjectileSpeed())+0.15
    local incoming=K.ShortReplyIncoming(bot,enemy,horizon,s)
    local R = K._race
    local losingContact = (bot:GetHealth()-incoming<math.max(120,K.AttackDamageVs(enemy,bot)*1.6))
        or (R and R.valid and R.losingHard and not R.canKillNow)
    if losingContact then
        local point=U.GetSafeDistancePosition(bot,enemy)
            or U.GetRetreatWaypoint(bot,(bot:GetLocation()-enemy:GetLocation()):Normalized())
        State.lastCombatStage="contact-trade-retreat"
        return H.BeginForcedRetreat(bot,point,2.0)
    end
    for _,label in ipairs({"near","mid","far"}) do
        local ab=H.GetRazeAbilityByLabel(bot,label)
        if U.IsRazeAbilityCastable(bot,ab) then
            local action,aim=H.GetRazeActionType(bot,ab,enemy)
            if action and H.CastOrTurnRaze(bot,ab,action,aim,enemy) then
                State.shortCombatCast=State.aimingRaze==ab
                State.actionTaken=true;State.lastCombatStage="contact-trade-raze"
                return true
            end
        end
    end
    if not H.IssueHeroAttack(bot,enemy) then return false end
    State.heroCombatEnemy=enemy;State.heroCombatUntil=GameTime()+1.25
    State.actionTaken=true;State.lastCombatStage="contact-trade-attack"
    return true
end

-- ---------------------------------------------------------------------------------------------
-- FREE PRESSURE (2026-10-20, replay-driven)
-- In the 20.10 demo against a human SF the bot threw 2 hero right-clicks in 9 minutes (the human
-- threw 29) and went 130 seconds without a single raze while being right-clicked. Both handlers
-- below add exactly one action in windows where the bot previously did nothing, and every gate is
-- a veto: they can only fire when walking is NOT required (the target is already in range), the
-- expected incoming burst cannot kill us, no enemy tower is near, and no last hit is being stolen.
-- ---------------------------------------------------------------------------------------------

-- A last hit we would lose by swinging at the hero instead (same rule for razes: a 0.55 s cast).
local function FreePressureStealsLastHit(bot, s, pad)
    for _, creep in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(creep) and creep:IsAlive() then
            local d = GetUnitToLocationDistance(bot, creep:GetLocation())
            if d <= bot:GetAttackRange() + (pad or 0)
                and creep:GetHealth() <= K.AttackDamageVs(bot, creep) + 20 then
                return true
            end
        end
    end
    return false
end

local function FreePressureTowerClear(bot, s, radius)
    for _, tower in pairs((s and s.enemyTowers) or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot, tower:GetLocation()) < radius then
            return false
        end
    end
    return true
end

-- One raze when he is on top of us, when he just cast (hit or miss - both are answers),
-- and a bounded proactive raze in a window where nothing threatens us at all.
function H.FreePressureColdWindow(bot, enemy, cold)
    local pressured = H.IsEnemyPressuring(bot, enemy)
    local inWindow = State.heroCombatEnemy == enemy and GameTime() < (State.heroCombatUntil or 0)
    if cold == false then return pressured or inWindow end
    return (not pressured) and (not inWindow)
end

function H.HandleFreeRazeAnswer(bot, s, race, cold)
    FDBG("raze_calls")
    if not C.FREE_RAZE or not C.FREE_RAZE.ENABLED then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if State.actionTaken or State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc
        or GameTime() < (State.fleeUntil or 0) then FDBG("raze_busy") return false end
    if bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() then FDBG("raze_busycast") return false end
    if State.aimingRaze then FDBG("raze_aiming") return false end
    if race and race.heCanKillSoon then FDBG("raze_race") return false end
    if not FreePressureTowerClear(bot, s, C.FREE_RAZE.TOWER_CLEAR) then FDBG("raze_tower") return false end

    local pressured = (enemy.GetAttackTarget and enemy:GetAttackTarget() == bot) or false
    local castAge = GameTime() - ((K._enemy and K._enemy.lastAnyCastAt) or -100)
    -- Answer = he is right-clicking us, or he just cast anything (a hit OR a miss: a miss is exactly
    -- the situation the demo showed the bot ignoring for 130 seconds).
    local answering = pressured or castAge <= C.FREE_RAZE.REPLY_WINDOW
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())

    if answering then
        if cold then
            -- The cold pipeline runs before any combat stage: leave answers to the combat
            -- pipeline, which has already judged the trade. Only the proactive branch is ours.
            FDBG("raze_cold_answering") return false
        end
        FDBG("raze_answering")
        if bot:GetMana() < 75 or hpPct < C.FREE_RAZE.MIN_HP_PCT_ANSWER then FDBG("raze_mana_hp") return false end
    else
        FDBG("raze_proactive")
        local enemyCanAnswer = K.EnemyManaBudget(enemy, true)
            + math.max(0, (enemy.GetManaRegen and enemy:GetManaRegen() or 0)) * 1.2 >= 75
        -- Nobody is threatening us: allow proactive centered coil on surplus mana, `>= 115 MP` with Mango/Stick reserve,
        -- OR `>= 75 MP` (`MIN_HP_PCT_VS_DRY`) when the enemy SF is dry (`< 75` potential mana) and cannot raze back!
        local reqMana = enemyCanAnswer and C.FREE_RAZE.SURPLUS_MANA or (C.FREE_RAZE.SURPLUS_MANA_VS_DRY or 75)
        local minHpPct = enemyCanAnswer and C.FREE_RAZE.MIN_HP_PCT or (C.FREE_RAZE.MIN_HP_PCT_VS_DRY or 0.32)
        local pokeManaOK = (bot:GetMana() >= reqMana)
            or (bot:GetMana() >= 115 and (K.MyManaBudget(bot, true) >= 150 or not enemyCanAnswer))
        if not pokeManaOK or hpPct < minHpPct then FDBG("raze_reserve") return false end
        if K.ShortReplyIncoming(bot, enemy, 1.2, s) > bot:GetHealth() * 0.25 then FDBG("raze_incoming") return false end
        if enemyCanAnswer and hpPct < C.FREE_RAZE.SAFE_VS_ANSWER_PCT then FDBG("raze_cananswer") return false end
    end

    -- He must already be inside one of our three bands: no walking, no setup position.
    local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local centers = { far = C.RAZE.FAR_CENTER, mid = C.RAZE.MID_CENTER, near = C.RAZE.NEAR_CENTER }
    local inBand = false
    for _, label in ipairs({ "far", "mid", "near" }) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if ab and U.IsRazeAbilityCastable(bot, ab)
            and math.abs(distance - centers[label]) <= C.RAZE.HIT_RADIUS - (C.RAZE.ROBUST_MARGIN or 30) then
            inBand = true
            break
        end
    end
    if not inBand then FDBG("raze_band") return false end

    local horizon = C.RAZE.CAST_POINT + 0.35
    local incoming = K.ShortReplyIncoming(bot, enemy, horizon, s)
    if bot:GetHealth() - incoming < math.max(C.FREE_RAZE.MIN_HP_AFTER, K.AttackDamageVs(enemy, bot) * 1.25) then
        FDBG("raze_incoming2") return false
    end
    if FreePressureStealsLastHit(bot, s, C.FREE_HIT.LASTHIT_PAD) then FDBG("raze_lasthit") return false end

    for _, label in ipairs({ "far", "mid", "near" }) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if ab and U.IsRazeAbilityCastable(bot, ab) and not H.WouldBreakEarlyManaReserve(bot, enemy, ab) then
            local action, aim = H.GetRazeActionType(bot, ab, enemy)
            if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                State.shortCombatCast = State.aimingRaze == ab
                State.dodgeLoc = nil
                State.dodgeUntil = 0
                State.actionTaken = true
                State.lastCombatStage = answering and "free-raze-answer" or "free-raze-window"
                _G.__lastCombatStage = State.lastCombatStage
                FDBG(answering and "raze_fired_answer" or "raze_fired_window")
                return true
            end
        end
    end
    FDBG("raze_noaction")
    return false
end

-- A right-click that costs nothing: the target is ALREADY inside our attack range (no chase, no
-- wave break), the swing cannot get us killed, and it does not steal a last hit. The order is
-- re-issued every tick while the situation holds, so the hero keeps swinging.
function H.HandleFreeRightClick(bot, s, race)
    FDBG("hit_calls")
    if not C.FREE_HIT or not C.FREE_HIT.ENABLED then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then FDBG("hit_noenemy") return false end
    if State.actionTaken or State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc
        or GameTime() < (State.fleeUntil or 0) then FDBG("hit_busy") return false end
    if bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() then FDBG("hit_busycast") return false end
    if State.aimingRaze then FDBG("hit_aiming") return false end
    if race and race.heCanKillSoon then FDBG("hit_race") return false end
    local dEnemyNow = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local effAtkRange = math.max(525, bot:GetAttackRange() or 525)
    local maxPokeDist = effAtkRange + 48
    if dEnemyNow > maxPokeDist then FDBG("hit_range") return false end
    if not FreePressureTowerClear(bot, s, C.FREE_HIT.TOWER_CLEAR) then FDBG("hit_tower") return false end
    if not H.IsSafeToHarass(bot, enemy:GetLocation(), s.enemyTowers or {}, s.allyCreeps or {}) then FDBG("hit_harass") return false end

    -- Immortal Right-Click Reciprocation & Walk-Up Harass (`v3.9.0` + `v7.7.0` `9070869385.dem` `03:00–03:08` Fix):
    -- Valve C++ `enemy:GetAttackTarget()` resets to `nil` immediately after orb-walk projectile launch (`ShaNachnetsya`
    -- orb-walked 25/25 right-clicks while `ehpPct > 0.35`, blocking `HandleFreeRightClick` on 100% of ticks after `02:30`!).
    -- Strike whenever: (a) he is hitting/recently hit us (`1.85s` orb-walk window), (b) he is inside our `573u` hull-to-hull
    -- attack reach while we hold `HasDominantRightClickPosture`, OR (c) clean walk-up poke with `<= 1` aggro creep!
    local losingDryDuel = (K.EnemyManaBudget(enemy, true) < 75)
        and (bot:GetHealth() < enemy:GetHealth() - 25)
        and (K.AttackDamageVs(bot, enemy) < K.AttackDamageVs(enemy, bot) + 4)
    local pressured = (not losingDryDuel) and (((enemy.GetAttackTarget and enemy:GetAttackTarget() == bot)
        or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 1.85))) or false)
    local ehpPct = enemy:GetHealth() / math.max(1, enemy:GetMaxHealth())
    local aggroOnMe = 0
    for _, c in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(c) and c:IsAlive() and c:GetAttackTarget() == bot then aggroOnMe = aggroOnMe + 1 end
    end
    local dryNowFree = H.IsDryVsEnemyRaze(bot, enemy)
    local domRightClickPoke = (not dryNowFree)
        and (K.HasDominantRightClickPosture and K.HasDominantRightClickPosture(bot, enemy, s))
        and aggroOnMe <= 2
        and dEnemyNow <= effAtkRange + 42
    local cleanWalkupPoke = domRightClickPoke or ((not dryNowFree)
        and dEnemyNow <= effAtkRange + 15
        and aggroOnMe <= 1
        and ((U.GetShadowrazeDebuff(bot) or 0) <= (U.GetShadowrazeDebuff(enemy) or 0))
        and (bot:GetHealth() >= bot:GetMaxHealth() * 0.58 or K.EnemyManaBudget(enemy, true) < 75))
    if not pressured and not cleanWalkupPoke and ehpPct > C.FREE_HIT.FINISH_HP_PCT then FDBG("hit_reason") return false end
    FDBG(pressured and "hit_pressured" or "hit_lowfoe")

    if FreePressureStealsLastHit(bot, s, C.FREE_HIT.LASTHIT_PAD) then FDBG("hit_lasthit") return false end

    local horizon = (bot:GetAttackPoint() or 0.5) + C.FREE_HIT.SETTLE_TIME
    local incoming = K.ShortReplyIncoming(bot, enemy, horizon, s)
    if bot:GetHealth() - incoming < math.max(C.FREE_HIT.SAFE_HP_ABS,
        K.AttackDamageVs(enemy, bot) * C.FREE_HIT.SAFE_HP_FACTOR) then
        FDBG("hit_incoming") return false
    end

    if not H.IssueHeroAttack(bot, enemy) then FDBG("hit_issuefail") return false end
    FDBG("hit_issued")
    State.heroCombatEnemy = enemy
    State.heroCombatUntil = GameTime() + 1.25
    State.actionTaken = true
    State.lastCombatStage = "free-right-click"
    _G.__lastCombatStage = State.lastCombatStage
    return true
end

-- A survival retreat is separate from tactical spacing. No turn, mirror or chase
-- may steal its order, even when an enemy raze happens to be on cooldown.
-- Low HP alone must not cancel a winning, already-started dry right-click duel.
-- This is not permission to turn back during a retreat or to chase a fleeing hero.
function H.HandleWinningDryDuel(bot, enemy, snapshot)
    local now = GameTime()
    if not enemy or not U.CanQuery(enemy) then return false end
    if State.forcedRetreatLoc or State.survivalLoc
        or now < (State.fleeUntil or 0) or State.goingToFountain then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() or (bot.IsDisarmed and bot:IsDisarmed()) then return false end
    if bot:GetHealth() / math.max(1, bot:GetMaxHealth()) > 0.45 then return false end
    local continuing = bot:GetAttackTarget() == enemy
        or (State.heroAttackTarget == enemy and now - (State.heroAttackTime or -100) < 0.35)
    if not continuing or enemy:GetAttackTarget() ~= bot then return false end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dist > bot:GetAttackRange() or U.GetAngleDifference(bot, enemy:GetLocation()) > 25 then return false end
    -- Avoid projecting a clean duel while tower/creep damage is also incoming.
    for _, tower in pairs((snapshot and snapshot.enemyTowers) or {}) do
        if tower and tower:IsAlive() and GetUnitToLocationDistance(bot, tower:GetLocation()) < 900 then return false end
    end
    for _, creep in pairs((snapshot and snapshot.enemyCreeps) or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then return false end
    end
    local hp = bot:GetHealth()
    local enDamage = bot:GetActualIncomingDamage((enemy:GetAttackDamage() or 0)
        + math.max(3, (enemy.GetBaseDamageVariance and enemy:GetBaseDamageVariance()) or 0), DAMAGE_TYPE_PHYSICAL)
    local myDamage = U.SFDamageRange(bot, enemy).min
    if myDamage <= 0 or enDamage <= 0 then return false end
    -- Compare impact events, not "enemy hits NOW" versus our entire fresh windup.
    local function impacts(attacker, target, damage, own)
        local events = {}
        local period = math.max(0.1, attacker:GetSecondsPerAttack() or 1.7)
        local speed = math.max(1,attacker:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED)
        for _, projectile in pairs(U.SafeGetIncomingProjectiles(target)) do
            if not projectile.is_attack or projectile.caster ~= attacker then return nil end
            if projectile.location then
                events[#events+1] = {time=U.DistanceBetweenLocations(projectile.location,target:GetLocation())/speed, damage=damage}
            elseif not own then
                events[#events+1] = {time=0,damage=damage}
            end
        end
        local last = attacker:GetLastAttackTime() or -100
        local travel = dist/speed
        local first
        if last > 0 and now-last <= period+0.1 then
            first = math.max(0,last+period-now) + travel
        else
            first = own and ((attacker:GetAttackPoint() or 0.5)+travel) or 0
        end
        first = math.max(0,first+(own and 0.04 or -0.08))
        for i=0,5 do events[#events+1]={time=first+i*period,damage=damage} end
        table.sort(events,function(x,y) return x.time<y.time end)
        return events
    end
    local outgoing = impacts(bot,enemy,myDamage,true)
    local incoming = impacts(enemy,bot,enDamage,false)
    if not outgoing or not incoming then return false end
    local function lethalAt(events,health)
        for _,e in ipairs(events) do
            health=health-e.damage
            if health<=0 then return e.time end
        end
        return math.huge
    end
    local enemyHp = enemy:GetHealth()+U.GetStickCharges(enemy)*15
        + math.max(0,enemy:GetHealthRegen() or 0)*4
    if U.HasItem(enemy,"item_faerie_fire") then enemyHp=enemyHp+85 end
    local killAt = lethalAt(outgoing,enemyHp)
    local dieAt = lethalAt(incoming,hp)
    if killAt>4 or killAt+0.06>=dieAt then return false end
    -- Include mango/wand charges and mana regenerated before our killing hit.
    if K.MyManaBudget(bot, true) + math.max(0, bot:GetManaRegen() or 0) * killAt >= 75
        or K.EnemyManaBudget(enemy, true) + math.max(0, enemy:GetManaRegen() or 0) * killAt >= 75 then return false end
    if not H.IssueHeroAttack(bot, enemy) then return false end
    State.lastCombatStage = "timed-dry-finish"
    State.actionTaken = true
    return true
end

function H.CanTakeShortCombatAction(bot,enemy,s)
    if not U.CanQuery(enemy) or State.actionTaken or State.goingToFountain
        or State.forcedRetreatLoc or State.survivalLoc or GameTime()<(State.fleeUntil or 0)
        or bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() then return false end
    for _,tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot,tower:GetLocation())<900 then return false end
    end
    if State.towerChaseBlockedEnemy==enemy then
        if H.TowerChaseBlocked(bot,s) then return false end
        State.towerChaseBlockedEnemy=nil
    end
    return true
end

-- Keep a safe answer through its cast point, while still validating aim and new threats.
function H.HandleShortCombatCast(bot,enemy,s)
    if not State.shortCombatCast or not State.aimingRaze or State.aimingTarget~=enemy
        or not U.CanQuery(enemy) or not bot:IsUsingAbility() or State.forcedRetreatLoc
        or State.survivalLoc or State.goingToFountain or GameTime()<(State.fleeUntil or 0) then return false end
    for _,tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot,tower:GetLocation())<900 then return false end
    end
    local remaining=math.max(0,C.RAZE.CAST_POINT-(GameTime()-State.aimingStartTime))
    if bot:GetHealth()-K.ShortReplyIncoming(bot,enemy,remaining+0.15,s)<math.max(60,K.AttackDamageVs(enemy,bot)) then return false end
    if H.HandleActiveRazeValidation(bot) then
        State.lastCombatStage="short-cast-validation"
        State.actionTaken=true
        return true
    end
    return false
end

-- A short stationary answer is not the same decision as tanking a 2.5-second combo.
function H.HandleSafeRazeReply(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) or bot:GetMana()<75 then return false end
    local age=U.GetRecentEnemyRazeHitAge(enemy)
    local castAge=GameTime()-((K._enemy and K._enemy.lastAnyCastAt) or -100)
    local phase=K.EnemyPhase()
    local phaseThreat=phase and GetUnitToLocationDistance(bot,K.EnemyRazeCenter(enemy,phase))<=C.RAZE.HIT_RADIUS+20
    -- Right-click pressure is a reason to answer even when no raze landed on us and he has not
    -- cast for a while: an SF standing in our face taking free swings must not be free.
    local pressuredNow=(enemy.GetAttackTarget and enemy:GetAttackTarget()==bot) or false
    if not phaseThreat and age>0.8 and not pressuredNow and (castAge>1.0 or not H.IsEnemyPressuring(bot,enemy)) then return false end
    if K.HasRazeStackLead(bot,enemy) then return false end -- The bounded third-spell rule owns this case.
    local hitTime=GameTime()-age
    if not phaseThreat and age<=0.8 and State.mirrorAnsweredEnemy==enemy and State.mirrorAnsweredHit
        and math.abs(State.mirrorAnsweredHit-hitTime)<0.001 then return false end
    if GetUnitToLocationDistance(bot,enemy:GetLocation())<=bot:GetAttackRange()
        and U.SFDamageRange(bot,enemy).min>=enemy:GetHealth() then return false end
    local incoming=K.ShortReplyIncoming(bot,enemy,C.RAZE.CAST_POINT+0.3,s)
    if bot:GetHealth()-incoming<math.max(80,K.AttackDamageVs(enemy,bot)) then return false end
    -- `9056774541.dem` `02:00.87` (`tk=9258`, `230 HP` vs `736 HP / 265 MP` respawned enemy):
    -- NEVER freeze `0.55s` to fire a single non-lethal reply coil at `< 285 HP` into a healthy full-mana SF!
    if (bot:GetHealth() or 0) < 285 and (enemy:GetHealth() or 9999) > 420
        and ((enemy:GetMana() or 0) + U.GetMangoMana(enemy)) >= 150 then
        return false
    end
    for _,label in ipairs({(phaseThreat and phase) or U.GetRecentEnemyRazeHitLabel(enemy) or "far","far","mid","near"}) do
        local ab=H.GetRazeAbilityByLabel(bot,label)
        if U.IsRazeAbilityCastable(bot,ab) then
            local action,aim=H.GetRazeActionType(bot,ab,enemy)
            if action and H.CastOrTurnRaze(bot,ab,action,aim,enemy) then
                State.shortCombatCast = State.aimingRaze==ab
                State.dodgeLoc=nil; State.dodgeUntil=0
                if State.shortCombatCast and label=="mid" and State.razeFollowup then State.razeFollowup.reply=true end
                State.lastCombatStage="safe-short-reply"
                State.actionTaken=true
                return true
            end
        end
    end
    return false
end

-- A confirmed middle reply owns one short far follow-up before generic stack spacing.
function H.HandleReplyFarFollowup(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) or bot:GetMana()<75 then return false end
    local chain=State.razeFollowup
    if not chain or not chain.reply or chain.enemy~=enemy or chain.label~="far"
        or GameTime()>chain.untilTime or GameTime()<chain.opened+C.RAZE.CAST_POINT then return false end
    local stacks,remaining=U.GetShadowrazeDebuff(enemy)
    if stacks<=chain.stacks or K.HasRazeStackLead(bot,enemy) then return false end
    local ab=H.GetRazeAbilityByLabel(bot,"far")
    if not U.IsRazeAbilityCastable(bot,ab) then return false end
    local action,aim=H.GetRazeActionType(bot,ab,enemy)
    local point=bot:GetLocation()
    local dist=GetUnitToLocationDistance(bot,enemy:GetLocation())
    local move=0
    if not action then
        local desired=C.RAZE.FAR_CENTER-150
        if dist>=desired or desired-dist>160 then return false end
        move=desired-dist
        point=enemy:GetLocation()+(bot:GetLocation()-enemy:GetLocation()):Normalized()*desired
    end
    local horizon=C.RAZE.CAST_POINT+0.3+move/math.max(1,bot:GetCurrentMovementSpeed())
    if remaining<horizon+0.1 or GameTime()+horizon>chain.untilTime then return false end
    local incoming=K.ShortReplyIncoming(bot,enemy,horizon,s)
    if bot:GetHealth()-incoming<math.max(80,K.AttackDamageVs(enemy,bot)) then return false end
    if action then
        if not H.CastOrTurnRaze(bot,ab,action,aim,enemy) then return false end
        State.shortCombatCast=State.aimingRaze==ab
    else
        if not H.ApproachEnemyPoint(bot,enemy,point,25,s.enemyTowers or {},s.allyCreeps or {}) then return false end
    end
    State.dodgeLoc=nil;State.dodgeUntil=0
    State.lastCombatStage="reply-far-followup";State.actionTaken=true
    return true
end

-- Continue an existing close fight through one funded cooldown cycle; never initiate at parity.
function H.HandleManaCycleContinuation(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) then return false end
    if enemy:GetAttackTarget()~=bot or GetUnitToLocationDistance(bot,enemy:GetLocation())>bot:GetAttackRange() then return false end
    if not H.IsRazeFollowUp(bot,enemy) and not (State.heroCombatEnemy==enemy and GameTime()<State.heroCombatUntil) then return false end
    if not K.ManaCycleWindow(bot,enemy,s) then return false end
    for _,label in ipairs({"near","mid","far"}) do
        local ab=H.GetRazeAbilityByLabel(bot,label)
        if U.IsRazeAbilityCastable(bot,ab) then
            local action,aim=H.GetRazeActionType(bot,ab,enemy)
            if action and H.CastOrTurnRaze(bot,ab,action,aim,enemy) then
                State.shortCombatCast = State.aimingRaze==ab
                State.lastCombatStage="mana-cycle-raze";State.actionTaken=true;return true
            end
        end
    end
    if not H.IssueHeroAttack(bot,enemy) then return false end
    State.lastCombatStage="mana-cycle-attack"
    State.actionTaken=true
    return true
end

function H.ComputeCutOffSafeRetreatTarget(bot, enemy, desiredPoint, minSpacing)
    local bLoc = bot:GetLocation()
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then
        return desiredPoint
    end
    local eLoc = enemy:GetLocation()
    local curDist = U.DistanceBetweenLocations(bLoc, eLoc)
    if curDist > 920 or curDist < 1 then
        return desiredPoint
    end
    local toGoal = desiredPoint - bLoc
    if toGoal:Length2D() < 10 then
        return desiredPoint
    end
    local goalDir = toGoal:Normalized()
    local toEnemy = (eLoc - bLoc):Normalized()
    local cutOffCos = goalDir.x * toEnemy.x + goalDir.y * toEnemy.y
    -- `auto-20261023-0050` `07:14.23` + `v7.9.30-pro` (`auto-20261109-0026` `6:14..6:23` `(-1559,+1482)` River Dead-End Fix!):
    --   1. Only detour when `enemy` genuinely blocks a narrow forward cone toward `desiredPoint` (`cutOffCos > 0.58` & `curDist <= 680`
    --      or `cutOffCos > 0.72`). When `enemy` is laterally offset (`e.g. (-646,-271)` vs `(-703,-89) -> Dire T1 (524,652)`),
    --      `desiredPoint` is ALREADY completely clear!
    --   2. Pivot candidate arcs around `goalDir` (NEVER around `away` when `away` points into enemy territory!), require
    --      monotonic progress toward Fountain (`cand · fntDir >= 0.28`), and test multi-step passability (`180u, 300u, step`)
    --      so a `480u` river-ramp cliff edge NEVER flips our retreat `156 deg` backward into the enemy's top-river dead-end!
    if cutOffCos <= 0.58 or (curDist > 680 and cutOffCos <= 0.76) then
        return desiredPoint
    end
    local fnt = P.GetFountain(bot)
    local fntDir = (fnt - bLoc):Normalized()
    local stepLen = minSpacing or 420
    local perpG1 = Vector(-goalDir.y, goalDir.x, 0)
    local perpG2 = Vector(goalDir.y, -goalDir.x, 0)
    local away = (bLoc - eLoc):Normalized()
    -- Tight `~31 deg` Home-Corridor Skirt (`0.85 * goalDir ± 0.52 * perpG`): clears enemy hull & `Q(200)` center
    -- (`e.g. (-858,-338) -> (-690,+50) -> Dire T1 (524,652)`) WITHOUT turning `87 deg` due North into the river!
    local candA = (goalDir * 0.85 + perpG1 * 0.52):Normalized()
    local candB = (goalDir * 0.85 + perpG2 * 0.52):Normalized()

    local function evalArc(cand)
        local fntProg = cand.x * fntDir.x + cand.y * fntDir.y
        local homeProg = cand.x * goalDir.x + cand.y * goalDir.y
        local clearCos = -(cand.x * toEnemy.x + cand.y * toEnemy.y) -- higher = further from enemy
        for _, dProbe in ipairs({ stepLen, 300, 185 }) do
            local pt = bLoc + cand * dProbe
            local pass = (type(IsLocationPassable) ~= "function") or IsLocationPassable(pt)
            local widensOrSafe = U.DistanceBetweenLocations(pt, eLoc) >= math.min(curDist + 35, 520)
                or (cand.x * away.x + cand.y * away.y) >= -0.15
            if pass and widensOrSafe then
                return pt, (homeProg * 1.10 + fntProg * 0.85 + clearCos * 0.65), fntProg
            end
        end
        return nil, -999, fntProg
    end

    local ptA, scA, fpA = evalArc(candA)
    local ptB, scB, fpB = evalArc(candB)
    if ptA and fpA >= 0.55 and (not ptB or fpB < 0.55 or scA >= scB) then return ptA end
    if ptB and fpB >= 0.55 then return ptB end
    if ptA and (not ptB or scA >= scB) then return ptA end
    if ptB then return ptB end
    -- Fallback: keep >= 70% homeward velocity so we NEVER drift sideways down the river!
    local safeFallbackDir = (away * 0.30 + goalDir * 0.70):Normalized()
    return bLoc + safeFallbackDir * stepLen
end

function H.HandleSurvivalRetreat(bot, enemy, race)
    local now = GameTime()
    local visible = enemy and U.CanQuery(enemy)
    local myHp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth())
    local hpPct = myHp / maxHp
    if visible and enemy:IsAlive() then
        local lr = U.SolveLethalRace(bot, enemy, W and W.s or nil)
        if lr and lr.winsFirstKill and lr.tKillHim <= 2.25 then
            State.survivalLoc = nil
            State.survivalUntil = 0
            return false
        end
    end
    local enAtk = visible and K.AttackDamageVs(enemy, bot) or 55
    local enBurstAvail = visible and K.EnemyBurstVs(bot, enemy, GetUnitToLocationDistance(bot, enemy:GetLocation()), 2.2, false) or 0
    local actualLethalRisk = (myHp <= 215)
        or (race and race.valid and (race.heCanKillNow or race.heCanKillSoon))
        or ((myHp - enBurstAvail) <= math.max(155, enAtk * 2.1))
    local crushingRightClick = visible
        and ((enemy:GetMana() or 0) + U.GetMangoMana(enemy) < 150)
        and myHp >= 310
        and K.AttackDamageVs(bot, enemy) >= enAtk + 9

    local danger = visible and GetUnitToLocationDistance(bot, enemy:GetLocation()) < 1200
        and hpPct <= 0.45
        and actualLethalRisk
        and not crushingRightClick
        and enemy:GetHealth() / math.max(1, enemy:GetMaxHealth()) > hpPct + 0.12
    local active = State.survivalLoc ~= nil and now < (State.survivalUntil or 0)
    if active and visible and hpPct < 0.50 and actualLethalRisk and not crushingRightClick
        and GetUnitToLocationDistance(bot, enemy:GetLocation()) < 990 then
        danger = true
    end
    local favourable = visible and race and race.valid and not race.heCanKillSoon
        and (race.spellWindow or H.GetPendingRazeFollowup(bot, enemy, race)
            or (race.edge >= 0 and myHp >= enemy:GetHealth()))
    if favourable or crushingRightClick then danger = false end
    if danger then State.survivalUntil = now + 1.6 end
    if now >= (State.survivalUntil or 0) or not danger then
        State.survivalLoc = nil
        State.survivalUntil = 0
        return false
    end
    -- Fixed-anchor safe lane retreat (`bot_unbeatable` zero-jitter synthesis: anchor to `behindT1` world coordinate
    -- instead of moving `enemy:GetLocation() + homeDir * 1035` every tick, wrapped in `ComputeCutOffSafeRetreatTarget`!):
    local fountain = P.GetFountain(bot)
    local behindT1 = (P.GetBehindT1 and P.GetBehindT1(bot, 280)) or nil
    local rawTarget
    if behindT1 and visible and U.DistanceBetweenLocations(behindT1, enemy:GetLocation()) >= 940 then
        rawTarget = behindT1
    else
        local bLocS = bot:GetLocation()
        local toFntS = (fountain - bLocS):Normalized()
        if visible then
            local eLocS = enemy:GetLocation()
            local relES = eLocS - bLocS
            local latES = math.abs(relES.x * (-toFntS.y) + relES.y * toFntS.x)
            if latES >= 250 then
                local awayS = (U.DistanceBetweenLocations(bLocS, eLocS) > 5) and (bLocS - eLocS):Normalized() or toFntS
                rawTarget = bLocS + (toFntS * 0.74 + awayS * 0.26):Normalized() * 580
            else
                local homeDir = (fountain - eLocS):Normalized()
                rawTarget = eLocS + homeDir * 1015
            end
        else
            rawTarget = bLocS + toFntS * 1015
        end
    end
    local cutSafe = visible and H.ComputeCutOffSafeRetreatTarget(bot, enemy, rawTarget, 440) or rawTarget
    State.survivalLoc = H.SteerClearOfAllyT2Hull(bot, cutSafe, visible and enemy:GetLocation() or nil)
    -- Hold calm safe anchor upon arrival (`< 85u`) while `danger` remains true — NEVER clear `survivalLoc` and return `false`
    -- to let lower wave-seek handlers walk right back into danger (`30Hz` 85u arrival ping-pong fix!)!
    if GetUnitToLocationDistance(bot, State.survivalLoc) < 85 then
        if U.IsAttackingAction(bot) then
            bot:Action_ClearActions(true)
        end
        State.actionTaken = true
        return true
    end
    State.fleeUntil = math.max(State.fleeUntil or 0, now + 0.9)
    local moving = bot:GetCurrentActionType() == BOT_ACTION_TYPE_MOVE_TO
    if moving and State.survivalOrderLoc == State.survivalLoc
        and now - (State.survivalOrderTime or -100) < 1.2 then
        State.actionTaken = true
        return true
    end
    State.survivalOrderLoc = State.survivalLoc
    State.survivalOrderTime = now
    return H.SmartMove(bot, State.survivalLoc, 60)
end


function H.HandleEnemyNearRazeCounter(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    -- Clean flee - no turning toward the enemy
    if GameTime() < (State.fleeUntil or 0) and GameTime() >= (State.commitKillUntil or 0) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local q_enemy = enemyHero:GetAbilityByName("nevermore_shadowraze1")
    if not q_enemy or not q_enemy:IsInAbilityPhase() then return false end

    local enemyLoc = enemyHero:GetLocation()
    local enemyFacing = enemyHero:GetFacing()
    local rad = math.rad(enemyFacing)
    local forward = Vector(math.cos(rad), math.sin(rad), 0)
    local center = enemyLoc + forward * C.RAZE.NEAR_CENTER
    if U.DistanceBetweenLocations(center, bot:GetLocation()) > C.RAZE.HIT_RADIUS then
        return false
    end

    local q_bot = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q_bot or not U.IsRazeAbilityCastable(bot, q_bot) then return false end

    local botPred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
    local myError = U.GetRazeHitErrorWithDesiredFacing(bot, botPred, C.RAZE.NEAR_CENTER)
    if myError <= C.RAZE.HIT_RADIUS + 30 then
        local actionType = "TURN"
        if U.GetAngleDifference(bot, botPred) <= C.RAZE.MAX_ANGLE_TO_CAST then
            actionType = "CAST"
        end
        if H.CastOrTurnRaze(bot, q_bot, actionType, botPred, enemyHero) then
            return true
        end
    end

    return false
end

function H.GetPotentialRecallHpPct(bot)
    local hp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local bonus = 0
    if bot:HasModifier("modifier_flask_healing") then
        bonus = bonus + 390
    elseif U.HasItem(bot, "item_flask") then
        bonus = bonus + 390
    end
    return math.min(maxHp, hp + bonus) / maxHp
end


-- Pro 1v1 Post-Kill Economy & Lane Reset (`tk=11000` live fix):
-- When we solo-kill the enemy SF, NEVER abandon an uncontested mid wave on a 7,000u walk to Fountain
-- if we have `>= 100g` (First Blood / kill bounty buys instant `item_flask` via courier!) OR already
-- own a Salve/Tango! Stay in lane, farm 100% of the uncontested wave (+4-8 CS & solo XP), and pop the
-- courier-delivered Salve right before enemy TP lands. Only walk to Fountain when `< 35% HP` WITH `< 100g`
-- AND zero healing items — and once walking to Fountain, NEVER abort halfway before 95% HP / 88% MP!
function H.HandlePostKillReset(bot, snapshot)
    local kills = snapshot and snapshot.myKills
    if type(kills) == "number" then
        local previous = State.postKillCount
        State.postKillCount = kills
        if previous ~= nil and kills > previous then
            H.ClearForcedRetreat()
            H.ClearTowerEscape()
            State.survivalLoc = nil
            State.survivalUntil = 0
            State.emergencyRetreat = nil
            State.commitKillUntil = 0
            State.nearChainUntil = 0
            State.dodgeLoc = nil
            local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
            -- Immediately start unlocking Backpack `item_flask` on the exact kill tick so its `6.0s` Backpack CD
            -- finishes LONG before the dead enemy hero respawns (`15–22s`) and channels TP (`+3.0s`)!
            if bot:FindItemSlot("item_flask") >= 6 and bot:FindItemSlot("item_flask") <= 8 then
                H.EnsureConsumableReady(bot, "item_flask")
            end
            State.lastEnemyKillAt = GameTime()
            State.lastEnemyKillRespawnAt = GameTime() + math.max(12.0, math.min(28.0, 9.0 + ((snapshot and snapshot.enemyLastLevel) or 3) * 3.2))
            -- `v7.9.30-pro` (`auto-20261109-0026` `7:34.07` `59/1232 HP` Post-Kill +Salve-Cap / Buyback Danger Fix!):
            --   1. `gold >= 100` ONLY counts as regen if `not U._salveCapReached` (otherwise `item_purchase_nevermore` refuses
            --      to buy `item_flask` while saving for `item_boots`, stranding SF at `59 HP` with `0` Salve!).
            --   2. After `3:30` (`DotaTime >= 210` or `suddenDeathDanger`), surviving a duel at `< 18% HP` (`e.g. 59/1232 HP`)
            --      with `0` on-hand/pipeline healing leaves SF dead to an instant Enemy Buyback + `3s` TP + Boots chase!
            local hasOnHandOrPipeHeal = U.HasItem(bot, "item_flask")
                or U.HasItem(bot, "item_tango")
                or (U.HasSalveInPipeline and U.HasSalveInPipeline(bot))
                or bot:HasModifier("modifier_flask_healing")
                or bot:HasModifier("modifier_tango_heal")
            local canActuallyBuySalve = ((bot:GetGold() or 0) >= 100) and (not U._salveCapReached)
            local dtimeKill = (type(DotaTime) == "function" and DotaTime()) or 0
            local criticalPostKillNoOnHand = (hpPct <= 0.18) and (not hasOnHandOrPipeHeal)
                and (dtimeKill >= 210 or (snapshot and snapshot.suddenDeathDanger) or (snapshot and snapshot.enemyHasBoots))
            if (hpPct <= 0.35 and not hasOnHandOrPipeHeal and not canActuallyBuySalve) or criticalPostKillNoOnHand then
                bot:Action_ClearActions(true)
                H.ClearRazeState()
                H.ClearMoveCache()
                State.prepTarget = nil
                State.needsTP = false -- Request TP immediately upon full Fountain restore.
                State.goingToFountain = true
                State.fountainReason = "POST_KILL"
            end
        end
    end
    -- Proactive Post-Kill Overstay Guard (`9056469656.dem` `03:07–03:12` Death #1 prevention):
    -- After shoving the wave post-kill, DO NOT sit `< 75% HP` or `< 150 MP` right next to enemy T1 (`<= 850u`)
    -- inside the `2.5s` window right as the full-HP/full-MP enemy hero is respawning! Step back to river (`>= 980u`
    -- from enemy T1) BEFORE they even finish channeling TP!
    if snapshot and snapshot.enemyAlive == false and State.lastEnemyKillRespawnAt
        and GameTime() >= State.lastEnemyKillRespawnAt - 2.5 then
        local hpPctNow = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
        local myReadyRazes = K.MyReadyRazeCount(bot, true)
        local tLoc = snapshot.enemyT1Alive and snapshot.enemyT1Loc or nil
        if (hpPctNow < 0.78 or myReadyRazes < 2) and tLoc then
            if GetUnitToLocationDistance(bot, tLoc) < 980 then
                local fnt = P.GetFountain(bot)
                local safeRiver = tLoc + (fnt - tLoc):Normalized() * 1120
                H.SmartMove(bot, safeRiver, 45)
                State.actionTaken = true
                return true
            end
        end
    end
    if State.goingToFountain and State.fountainReason == "POST_KILL" then
        -- When critically low (`<= 26% HP`) with `0` Salve and a ready `item_tpscroll` after `3:30` (or on Enemy Buyback),
        -- channel TP straight to Fountain once clear of close aggroed creeps (`3.0s` full reset vs `22s` walk!).
        local hpPctRec = (bot:GetHealth() or 0) / math.max(1, bot:GetMaxHealth() or 1)
        local dtimeRec = (type(DotaTime) == "function" and DotaTime()) or 0
        if not H.IsAtFountain(bot) and hpPctRec <= 0.26 and (dtimeRec >= 210 or (snapshot and (GameTime() - (snapshot.enemyRespawnedAt or -100)) <= 12.0)) then
            local aggroCntRec = (U.CountEnemyCreepsAggroedOnBot and U.CountEnemyCreepsAggroedOnBot(bot, snapshot, State.myCreepChaseUntil)) or 0
            if (aggroCntRec == 0 or (bot:GetHealth() or 0) >= 145 + aggroCntRec * 48)
                and H.TryTPHome(bot, snapshot and snapshot.enemy or nil) then
                return true
            end
        end
        if H.HandleFountainRecall(bot) then return true end
        if State.needsTP then return H.HandleReturnTP(bot) end
    end
    return false
end

function H.ShouldCommitDeepFountainWalk(bot, s)
    if not bot or not bot:IsAlive() or H.IsAtFountain(bot) then return false end
    local snap = s or (W and W.s)
    if snap and snap.enemyAlive == false then return false end
    if U.HasAnyHealing(bot) then return false end
    local courierHasSalve, courierLoc = U.IsCourierBringSalve(bot)
    if courierHasSalve and courierLoc and GetUnitToLocationDistance(bot, courierLoc) <= 1300 then
        return false
    end
    local maxHp = math.max(1, bot:GetMaxHealth())
    local hpPct = (bot:GetHealth() or 0) / maxHp
    if hpPct > 0.36 then return false end
    local fountain = P.GetFountain(bot)
    local t1 = P.GetT1Close(bot, 0)
    if not fountain or not t1 then return false end
    local distToFountain = GetUnitToLocationDistance(bot, fountain)
    local distToT1 = GetUnitToLocationDistance(bot, t1)
    local t1ToFountain = U.DistanceBetweenLocations(t1, fountain)
    -- Already `>= 1500u` behind Mid T1 at `<= 36% HP` (`auto-20261031-1939` `07:13`), OR `>= 900u` behind Mid T1 at
    -- critical `<= 22% HP` (`0210 @ 10:40` `182/1408 HP = 12.9% HP` at `(1016, 1484)` with 0 Salve/Tango!):
    -- finishing the walk to Fountain gives a FREE 100% HP/MP heal instead of turning 180 deg back to river at 182 HP!
    if (distToT1 >= 1500 and distToFountain <= (t1ToFountain - 1350))
        or (distToT1 >= 900 and hpPct <= 0.22 and distToFountain <= (t1ToFountain - 750)) then
        local enemyHero = snap and snap.enemy
        if enemyHero and U.CanQuery(enemyHero) and U.EnemyResourcesAsWeak(bot, enemyHero, hpPct) then
            return false
        end
        State.goingToFountain = true
        State.fountainReason = "DEEP_LOW_HP"
        return true
    end
    return false
end

function H.ShouldGoToFountain(bot)
    if H.ShouldCommitDeepFountainWalk(bot, W and W.s) then
        return true, "DEEP_LOW_HP"
    end
    local enemyHero = W and W.s and W.s.enemy or nil
    if U.IsSalveAvailableOrImminent and U.IsSalveAvailableOrImminent(bot, enemyHero) then
        return false, nil
    end
    local hpCritical = (C.FOUNTAIN and C.FOUNTAIN.GO_HP_CRITICAL_PCT) or 0.15
    local potentialHpPct = H.GetPotentialRecallHpPct(bot)
    if potentialHpPct < hpCritical then
        -- The enemy has exactly as few resources as we do - walking to the fountain simply hands
        -- him the lane and the wave. Keep the distance and regen.
        if U.EnemyResourcesAsWeak(bot, enemyHero, nil) then return false, nil end
        return true, "HP"
    end
    return false, nil
end

function H.ShouldAbortFountainRecall(bot)
    -- Hysteresis (`auto-20261031-1939` Death #2 Fix!): NEVER abort an active Fountain walk the instant
    -- passive HP regen ticks from `14.9%` to `15.0%` (`165 HP`) with zero Salve/Tango!
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    if hpPct >= 0.48 then
        return true
    end
    if U.HasAnyHealing(bot) or (U.HasSalveInPipeline and U.HasSalveInPipeline(bot)) then
        local ownT1 = P.GetT1Tower(bot)
        if not ownT1 or GetUnitToLocationDistance(bot, ownT1) < 1450 then
            return true
        end
        local potentialHpPct = H.GetPotentialRecallHpPct(bot)
        if potentialHpPct >= 0.50 then
            return true
        end
    end
    return false
end

function H.IsAtFountain(bot)
    if bot.HasModifier and bot:HasModifier("modifier_fountain_aura_buff") then
        return true
    end
    local fountain = P.GetFountain(bot)
    -- CRITICAL FIX (`v7.9.0`): Previously `math.max(1500, ...)` returned `true` at `1490u` near T3/Barracks WITHOUT
    -- `modifier_fountain_aura_buff`, making `HandleFountainRecall` stop walking (`0` regen AFK stall!).
    local radius = math.min(540, (C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 520)
    return GetUnitToLocationDistance(bot, fountain) <= radius
end

function H.IsFountainFullyRestored(bot)
    local hp = bot:GetHealth()
    local maxHp = math.max(1, bot:GetMaxHealth())
    local mana = bot:GetMana()
    local maxMana = bot:GetMaxMana()
    local hpPct = hp / maxHp
    local manaPct = (maxMana > 0) and (mana / maxMana) or 1.0
    local waitHpPct = 0.95
    local waitManaPct = 0.88
    return hpPct >= waitHpPct and manaPct >= waitManaPct
end

function H.HandleFountainRecall(bot)
    if State.goingToFountain then
        if not bot:IsAlive() then
            State.goingToFountain = false
            State.fountainReason = nil
            return false
        end
        -- `v5.2.0` Dead-Enemy Recall Abort: if the opposing hero just died while we are still in lane (`>= 140 HP`),
        -- NEVER walk 7,000u back to Fountain — stay in lane, farm the uncontested wave, and Salve!
        if not H.IsAtFountain(bot) and State.fountainReason ~= "POST_KILL"
            and W.s and W.s.enemyAlive == false and (bot:GetHealth() or 0) >= 140 then
            State.goingToFountain = false
            State.fountainReason = nil
            H.ClearMoveCache()
            return false
        end
        if not H.IsAtFountain(bot) and State.fountainReason ~= "EMERGENCY" and State.fountainReason ~= "POST_KILL" and H.ShouldAbortFountainRecall(bot) then
            State.goingToFountain = false
            State.fountainReason = nil
            H.ClearMoveCache()
            return false
        end
        if H.IsAtFountain(bot) then
            if H.IsFountainFullyRestored(bot) then
                State.goingToFountain = false
                State.fountainReason = nil
                State.needsTP = true
                return false
            else
                State.actionTaken = true
                return true
            end
        else
            local fountain = P.GetFountain(bot)
            local recallDest = fountain
            local sRec = W.s
            local allyT1Loc = (sRec and sRec.allyT1Loc) or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1)
            if allyT1Loc and sRec and #(sRec.allyCreeps or {}) == 0 then
                local dMeFnt = GetUnitToLocationDistance(bot, fountain)
                local dT1Fnt = U.DistanceBetweenLocations(allyT1Loc, fountain)
                if dMeFnt > dT1Fnt - 90 then
                    for _, ec in pairs(sRec.enemyCreeps or {}) do
                        if U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 520 then
                            recallDest = allyT1Loc + (fountain - allyT1Loc):Normalized() * 240
                            break
                        end
                    end
                end
            end
            H.SmartMove(bot, recallDest, 80)
            State.actionTaken = true
            return true
        end
    end

    if State.emergencyRetreat then return false end
    if bot:HasModifier("modifier_flask_healing") or bot:HasModifier("modifier_tango_heal") then return false end
    if H.IsInDangerForRegen(bot, 900) then return false end
    local should, reason = H.ShouldGoToFountain(bot)
    if should then
        State.goingToFountain = true
        State.fountainReason = reason
        H.ClearForcedRetreat()
        local fountain = P.GetFountain(bot)
        local recallDest = fountain
        local sRec = W.s
        local allyT1Loc = (sRec and sRec.allyT1Loc) or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1)
        if allyT1Loc and sRec and #(sRec.allyCreeps or {}) == 0 then
            local dMeFnt = GetUnitToLocationDistance(bot, fountain)
            local dT1Fnt = U.DistanceBetweenLocations(allyT1Loc, fountain)
            if dMeFnt > dT1Fnt - 90 then
                for _, ec in pairs(sRec.enemyCreeps or {}) do
                    if U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 520 then
                        recallDest = allyT1Loc + (fountain - allyT1Loc):Normalized() * 240
                        break
                    end
                end
            end
        end
        H.SmartMove(bot, recallDest, 80)
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandleReturnTP(bot)
    local t1 = P.GetT1Close(bot)
    local fountain = P.GetFountain(bot)
    local distToT1 = GetUnitToLocationDistance(bot, t1)
    local distToFountain = GetUnitToLocationDistance(bot, fountain)
    local minTpDist = math.max(2600, (C.TP and C.TP.RETURN_DISTANCE_FROM_T1) or 3000)
    local farFromT1 = distToT1 >= minTpDist
    local nearFount = H.IsAtFountain(bot)
    -- `v7.9.8-pro` (`1638 @ 00:11.13` Wasted Opening TP to T1 Fix!):
    --   1. Fix Lua boolean `and/or` short-circuit (`DotaTime() > 15` was `false` at `11.13s`, falling through to `GameTime() > 20` -> `true`!).
    --   2. NEVER burn an `80s` CD / `100g` TP Scroll before `DotaTime() > 45s` (walking with Wave 1 from T3/T2 is always strictly optimal!).
    --   3. Only set `healedDeepBehindLane` when SF actually retreated deep toward Fountain (`distToFountain <= 2200` or active fountain trip),
    --      NEVER during an opening/post-block walk near T2/T3!
    local gameStarted = false
    if type(DotaTime) == "function" then
        gameStarted = (DotaTime() > 45.0)
    else
        gameStarted = (GameTime() > 125.0)
    end

    -- Never waste an 80s TP cooldown on a short walk when already near T1 (< 2600u)!
    if not farFromT1 then
        State.needsTP = false
        State.tpSwapStep = 0
        return false
    end

    -- Whenever inside the Fountain after `0:45` (e.g. respawn or manual/emergency recall), OR deep near Fountain (`<= 2200u`)
    -- and healed up (`>= 78% HP`) after finishing a retreat Salve, mark TP return!
    local healedDeepBehindLane = farFromT1 and not nearFount
        and (distToFountain <= 2200 or State.fountainReason ~= nil)
        and not State.goingToFountain
        and not (bot.HasModifier and bot:HasModifier("modifier_flask_healing"))
        and ((bot:GetHealth() or 0) / math.max(1, bot:GetMaxHealth() or 1)) >= 0.78
    if (nearFount or healedDeepBehindLane) and gameStarted then
        State.needsTP = true
    end

    if not State.needsTP then return false end
    if not gameStarted then return false end

    -- If inside or right next to Fountain, ensure full heal in Fountain aura BEFORE teleporting —
    -- UNLESS an enemy creep wave is already crashing into our Mid T1 (`v5.2.0` TP-arrival CS budget: save 6-8 under-tower CS at >= 82% HP & >= 165 MP!).
    -- `v7.9.0` 3.0s-Ahead TP Channel Time-Budget:
    -- TP Scroll channels for `3.0s` (`325 u/s * 3.0s = 975u` creep march!). Forecast unshielded enemy waves within
    -- `1720u` of our Mid T1 so we start channeling BEFORE the wave crashes under tower, saving 100% of Wave CS!
    local urgentWaveUnderOwnT1 = false
    if W.s and W.s.allyT1 and U.CanQuery(W.s.allyT1) then
        local ownT1Loc = W.s.allyT1:GetLocation()
        local underCount, approachingCount = 0, 0
        for _, ec in pairs(W.s.enemyCreeps or {}) do
            if U.CanQuery(ec) and ec:IsAlive() then
                local dc = U.DistanceBetweenLocations(ec:GetLocation(), ownT1Loc)
                if dc <= 780 then underCount = underCount + 1 end
                if dc <= 1720 then approachingCount = approachingCount + 1 end
            end
        end
        if underCount >= 2 or (approachingCount >= 2 and #(W.s.allyCreeps or {}) == 0) then
            urgentWaveUnderOwnT1 = true
        end
    end
    local readyForUrgentWaveTP = urgentWaveUnderOwnT1
        and ((bot:GetHealth() / math.max(1, bot:GetMaxHealth())) >= 0.78)
        and ((bot:GetMana() or 0) >= 150)
    if nearFount and not H.IsFountainFullyRestored(bot) and not readyForUrgentWaveTP then
        if not (bot.HasModifier and bot:HasModifier("modifier_fountain_aura_buff")) then
            H.SmartMove(bot, fountain, 40)
        else
            bot:Action_ClearActions(false)
        end
        State.actionTaken = true
        return true
    end

    -- A TP order was just issued: hold still briefly so channel starts cleanly without canceling it
    if GameTime() - (State.tpOrderTime or -100) < 0.6 then
        State.actionTaken = true
        return true
    end

    local tp = U.GetTPScroll(bot)
    if not tp then
        -- ONLY buy a TP scroll if the hero AND personal courier genuinely own ZERO TP scrolls anywhere!
        if not U.HasAnyTPScroll(bot) and nearFount and bot:GetGold() >= 100
            and GameTime() - (State.tpBuyTime or -100) > 15.0 then
            bot:ActionImmediate_PurchaseItem("item_tpscroll")
            State.tpBuyTime = GameTime()
            State.actionTaken = true
            return true
        end
        State.needsTP = false
        return false
    end

    State.tpSwapStep = 0
    local castOk, castable = false, false
    if tp.IsFullyCastable then castOk, castable = pcall(tp.IsFullyCastable, tp) end
    if castOk and castable and bot:GetMana() >= 75 then
        bot:Action_UseAbilityOnLocation(tp, t1)
        State.tpOrderTime = GameTime()
        State.goingToFountain = false
        State.needsTP = false
        State.actionTaken = true
        return true
    end

    -- Scroll on short cooldown (<= 6s) while standing in Fountain: wait in Fountain, then teleport!
    local cdOk, cd = pcall(tp.GetCooldownTimeRemaining, tp)
    if nearFount and cdOk and type(cd) == "number" and cd > 0 and cd <= 6.0 then
        State.actionTaken = true
        return true
    end

    -- Scroll on long cooldown (e.g. > 6s): clear needsTP so we NEVER waste TP near T1 25s later!
    State.needsTP = false
    return false
end

-- v6.4/v6.6 TP Home Instead of Walking Home:
-- When committed to an emergency fountain reset (`State.emergencyRetreat == "FOUNTAIN"`), far from fountain
-- (`>= 2600u`), out of enemy cancel/projectile reach, and NOT holding an usable Healing Salve, channel TP home!
function H.TryTPHome(bot, enemyHero)
    local fountain = P.GetFountain(bot)
    local dFount = GetUnitToLocationDistance(bot, fountain)
    if dFount < 2600 then return false end
    if bot:FindItemSlot("item_flask") >= 0 and bot:FindItemSlot("item_flask") <= 8 then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    -- `02:12.7` (`tk=7414`) Fix: NEVER burn `75 MP` + `100g` TP Home when a Salve is in stash/courier OR `>= 72g`
    -- behind own T1 (`< 1450u`) OR the enemy is equally crippled on resources!
    if U.IsSalveAvailableOrImminent and U.IsSalveAvailableOrImminent(bot, enemyHero) then return false end
    if U.EnemyResourcesAsWeak and U.EnemyResourcesAsWeak(bot, enemyHero, nil) then return false end
    local tp = U.GetTPScroll(bot)
    if not tp then return false end
    if bot:IsChanneling() or bot:IsUsingAbility() then return false end
    if enemyHero and U.CanQuery(enemyHero) then
        local d = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local ms = bot:GetCurrentMovementSpeed() or 305
        if d < 980 + ms * 1.2 or H.HasEnemyProjectileIncoming(bot) then
            return false
        end
    end
    local ok, castable = false, false
    if tp.IsFullyCastable then ok, castable = pcall(tp.IsFullyCastable, tp) end
    if not (ok and castable) then return false end
    bot:Action_UseAbilityOnLocation(tp, fountain)
    State.tpHomeTime = GameTime()
    State.goingToFountain = false
    State.actionTaken = true
    return true
end

-- Defensive stance "I am weaker" (with hysteresis). The criterion is K.Race: a 6 s trade projection
-- (burst + right clicks + HP pool + towers), not just razes. While defending: do not answer his
-- right clicks without creep/tower support, do not harass, do not contest last hits,
-- stand behind our creeps (PASSIVE position), heal earlier.
function H.UpdateDefensive(bot, s, race)
    local now = s.now or GameTime()
    local cfg = C.DEFENSE or {}
    if not race or not race.valid then
        if not s.enemyAlive then State.defensive = false end
        return State.defensive
    end
    if race.spellWindow and not race.heCanKillSoon then
        State.defensive = false
        return false
    end
    if not State.defensive then
        if race.weaker then
            State.defensive = true
            State.defensiveSince = now
        end
    else
        local held = now - (State.defensiveSince or 0)
        if not race.weaker and race.edgeLong > -(cfg.EXIT_EDGE or 40) and held >= (cfg.MIN_HOLD_SEC or 2.0) then
            State.defensive = false
        end
    end
    return State.defensive
end

-- Support in the fight: my creeps are hitting him / he is under my tower.
function H.HasTradeSupport(race)
    local cfg = C.DEFENSE or {}
    if (State.enemyAggroCount or 0) >= (cfg.SUPPORT_CREEPS or 2) then return true end
    if race and race.valid and (race.myTowerOnHim or 0) > 0 then return true end
    return false
end

-- Can we spend 75 mana on a harass raze (not CS, not a finish): the reserve depends on the level.
-- followUp = the enemy has a fresh stack and is still in reach: the second/third raze finishes the stack
-- (+35/50/65/80 bonus per stack, he cannot answer) - the mana reserve does not apply.
function H.HarassManaOK(bot, race, followUp)
    local mana = H.GetPotentialCombatMana(bot)
    if mana < 75 then return false end
    if race and race.valid and (race.canKillSoon or race.spellWindow) then return true end
    if State.hunting then return true end -- Hunting: mana for 1 raze (+mango) is enough
    local enemy = (race and race.enemy) or H._enemyHeroNear
    if enemy and K.HasDominantRightClickPosture and K.HasDominantRightClickPosture(bot, enemy, W.s) then
        return true
    end
    local cfg = C.MANA or {}
    local lvl = bot:GetLevel() or 1
    if followUp then
        -- Finishing an active Shadowraze stack (`+35/50/65/80` bonus): keep only minimal reserve (`50` at L1-L2, `35` at L3+)
        if GameTime() < (State.nearChainUntil or 0) then return true end
        local keep = (lvl <= (cfg.EARLY_LEVEL_L2 or 2)) and 50 or 35
        return (mana - 75) >= keep
    end
    local reserve = cfg.RESERVE_FOR_PRESSURE or 75
    if lvl <= (cfg.EARLY_LEVEL_L2 or 2) then
        reserve = 115
    elseif lvl <= (cfg.EARLY_LEVEL_L4 or 4) then
        reserve = 65
    end
    return (mana - 75) >= reserve
end

-- "Stack finish": the enemy has a fresh raze stack (remaining >= FOLLOWUP_MIN_REMAIN) and is within
-- band reach (accounting for his movement during the cast).
function H.IsRazeFollowUp(bot, enemyHero)
    if not U.CanQuery(enemyHero) then return false end
    local stacks, rem = U.GetShadowrazeDebuff(enemyHero)
    if (stacks or 0) <= 0 then return false end
    if (rem or 0) < (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2) then return false end
    local pred = U.PredictPosition(enemyHero, C.RAZE.PREDICT_DELAY)
    local d = GetUnitToLocationDistance(bot, pred or enemyHero:GetLocation())
    return d <= C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 60
end

-- The enemy T1 is "busy" with a creep: its current target is not a hero, is alive, with HP for >= 2 shots.
-- The tower does not switch to a hero while the target is alive and nobody right-clicks the hero (a raze gives no aggro).
function H.TowerLockedOnCreep(t1)
    if not t1 then return false end
    local okA, alive = pcall(t1.IsAlive, t1)
    if not okA or not alive then return false end
    if t1.CanBeSeen and not t1:CanBeSeen() then return false end
    local okT, tgt = pcall(t1.GetAttackTarget, t1)
    if not okT or not tgt or not U.CanQuery(tgt) then return false end
    if tgt.IsHero and tgt:IsHero() then return false end
    local okD, dmg = pcall(t1.GetAttackDamage, t1)
    if not okD or type(dmg) ~= "number" or dmg <= 0 then dmg = 100 end
    return (tgt:GetHealth() or 0) >= dmg * 2
end


-- Convert a clear lane lead into ranged pressure, without requiring a prior
-- enemy miss or an already-open raze stack. Never bypass retreat or tower safety.
function H.HasLanePressureAdvantage(bot, enemy, race)
    if not enemy or not U.CanQuery(enemy) or not race or not race.valid then return false end
    if race.heCanKillSoon then return false end
    if race.spellWindow then return true end
    if race.edge < 0 then return false end
    local hp, enemyHp = bot:GetHealth(), enemy:GetHealth()
    local myHit, enemyHit = K.AttackDamageVs(bot, enemy), K.AttackDamageVs(enemy, bot)
    local levelLead = bot:GetLevel() > enemy:GetLevel()
    local soulLead = S.GetSouls(bot) - S.GetSouls(enemy)
    -- Absolute resources and the projected trade, never a percentage of our own pool.
    local healthLead = hp - enemyHp >= math.max(100, enemyHit * 1.5)
    local laneLead = levelLead and soulLead >= 4 and hp >= enemyHp
    local attackLead = myHit >= enemyHit * 1.20 and hp >= enemyHp and myHit > 0
    return healthLead or laneLead or attackLead

end

-- Observe incoming pressure independently of farm targets and attack intent.
function H.IsEnemyPressuring(bot, enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    if enemy:GetAttackTarget() == bot then return true end
    local label = K.EnemyPhase()
    if label then
        local center = K.EnemyRazeCenter(enemy, label)
        if center and GetUnitToLocationDistance(bot, center) <= C.RAZE.HIT_RADIUS + 30 then return true end
    end
    if bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 2.0) then return true end
    if bot.WasRecentlyDamagedByPlayer and enemy.GetPlayerID then
        local id = enemy:GetPlayerID()
        if id and id >= 0 and bot:WasRecentlyDamagedByPlayer(id, 2.0) then return true end
    end
    if U.GetRecentEnemyRazeHitAge(enemy) <= 2.0 then return true end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if projectile.caster == enemy then return true end
        end
    end
    return false
end

function H.TowerChaseBlocked(bot, snapshot)
    local enemy, tower = snapshot.enemy, snapshot.enemyT1
    if not U.CanQuery(enemy) or not tower or not tower:IsAlive() then return false end
    if GetUnitToLocationDistance(enemy, tower:GetLocation()) > 820 then return false end
    local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if distance <= bot:GetAttackRange() and H.IsSafeToHarass(bot, enemy:GetLocation(), snapshot.enemyTowers, snapshot.allyCreeps) then return false end
    if GetUnitToLocationDistance(bot, tower:GetLocation()) >= 900 then
        if State.aimingTarget == enemy and State.aimingRaze and bot:IsUsingAbility() then return false end
        for _, label in ipairs(K.LABELS) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if U.IsRazeAbilityCastable(bot, ab) and not H.IsTowerDiveRazeUnsafe(bot, enemy, ab, snapshot.enemyTowers, snapshot.allyCreeps) then
                local action = H.GetRazeActionType(bot, ab, enemy)
                if action then return false end
            end
        end
    end
    return true
end

function H.UpdateTowerChase(bot, snapshot)
    local enemy = snapshot.enemy
    if not H.TowerChaseBlocked(bot, snapshot) then
        State.towerChaseBlockedEnemy = nil
        return false
    end
    local wasChasing = bot:GetAttackTarget() == enemy
        or (State.heroCombatEnemy == enemy and GameTime() < (State.heroCombatUntil or 0)
            and bot:GetCurrentActionType() == BOT_ACTION_TYPE_MOVE_TO)
    State.towerChaseBlockedEnemy = enemy
    State.heroCombatAllowed = false
    State.heroCombatEnemy = nil
    State.heroCombatUntil = 0
    State.commitKillUntil = 0
    State.razeFollowup = nil
    if GetUnitToLocationDistance(bot, snapshot.enemyT1:GetLocation()) < 900
        or H.IsEnemyPressuring(bot, enemy) then
        local escPt = LN.TowerEscapePoint(bot, snapshot.enemyT1)
        -- `v7.9.9-pro` (`1814 @ 08:42.40..08:45.07` `571u` Tower-Clamp Free-Hit Deadlock Fix):
        -- When `IsEnemyPressuring` fires while `enemy` stands under his T1 (`403u` from T1, `571u <= 573u` attack reach!)
        -- and `towerChaseBlockedEnemy` blocks us from hitting back, ensure `escPt` steps AT LEAST `660u` outside `enemy`
        -- (`strictly beyond 573u hull-to-hull right-click reach!`) AND `>= 980u` outside `enemyT1`!
        if enemy and U.CanQuery(enemy) and H.IsEnemyPressuring(bot, enemy) then
            local eLocEsc = enemy:GetLocation()
            local tLocEsc = snapshot.enemyT1:GetLocation()
            if U.DistanceBetweenLocations(escPt, eLocEsc) < 660 then
                local fntEsc = P.GetFountain(bot)
                local awayEn = (fntEsc - eLocEsc):Normalized()
                escPt = eLocEsc + awayEn * 675
                if U.DistanceBetweenLocations(escPt, tLocEsc) < 980 then
                    escPt = tLocEsc + (fntEsc - tLocEsc):Normalized() * 995
                end
            end
        end
        return H.BeginForcedRetreat(bot, escPt, 0.6)
    end
    if wasChasing then H.SafeClearActions(bot) end
    return false -- Outside danger: release the tick to lane work, not another chase.
end

-- One combat pipeline for both initiation and retaliation. Its caller owns the
-- tick: farm/prehit state is never consulted and cannot suppress a combat stage.
function H.RunCombatPriority(bot, snapshot, race)
    local enemy = snapshot.enemy
    if not enemy or not U.CanQuery(enemy) then return false end
    if H.UpdateTowerChase(bot, snapshot) then return true end
    if State.towerChaseBlockedEnemy == enemy then return false end
    local towers, allies = snapshot.enemyTowers or {}, snapshot.allyCreeps or {}
    State.prepTarget = nil
    State.lhAttackTarget = nil
    State.aggroPullTime = 0
    State.heroCombatEnemy = enemy
    State.heroCombatUntil = GameTime() + 1.25
    local function stage(name, ...)
        if H[name](...) then
            State.lastCombatStage = name
            State.actionTaken = true
            return true
        end
        return false
    end
    if stage("HandleEnemyTowerSafety", bot, snapshot, enemy) then return true end
    if stage("HandleEmergencyConsumables", bot, race) then return true end
    if stage("HandleGuaranteedRazeKill", bot, enemy, towers, allies) then return true end
    if stage("HandleGuaranteedAttackKill", bot, enemy, towers, allies) then return true end
    if stage("HandleEnemyRazeDodge", bot, enemy) then return true end
    -- Answer him: a cast he just threw (hit or miss) and any right-click pressure deserve one
    -- raze back while nothing threatens us. Runs before the combo ladder so it is not starved.
    if stage("HandleFreeRazeAnswer", bot, W.s, race, false) then return true end
    if race and race.valid and race.heCanKillSoon and not race.canKillNow then
        local point = U.GetSafeDistancePosition(bot, enemy)
            or U.GetRetreatWaypoint(bot, (bot:GetLocation() - enemy:GetLocation()):Normalized())
        State.lastCombatStage = "lethal-threat-retreat"
        State.commitKillUntil = 0
        return H.BeginForcedRetreat(bot, point, 1.0)
    end
    if State.aimingRaze and stage("HandleActiveRazeValidation", bot) then return true end
    if bot:IsUsingAbility() or bot:IsChanneling() then
        State.lastCombatStage = "finish-current-cast"
        State.actionTaken = true
        return true
    end
    if stage("HandleStackLead", bot, snapshot, race) then return true end
    -- Preserve a HERO swing, never a creep swing. Safety and lethal finishes above
    -- may interrupt it; ordinary movement/pressure below may not.
    if stage("ShouldHoldForHeroWindup", bot, snapshot, enemy, race) then return true end
    if stage("HandleInstantMirrorRaze", bot, enemy, race, snapshot) then return true end
    if stage("HandlePendingRazeFollowup", bot, enemy, race, snapshot) then return true end
    if race and race.spellWindow then
        if stage("HandleAdvantageRazePressure", bot, enemy, race, towers, allies, nil) then return true end
    end
    if H.CanContinueDryRazeChain(bot, enemy, race) then
        if H.TryRazeEnemy(bot, enemy, "AGGRESSIVE", towers, allies, false, false) then return true end
    end
    if stage("HandleEnemyNearRazeCounter", bot, enemy) then return true end
    if stage("ForceExtendEnemyStack", bot, enemy, towers, allies) then return true end
    if stage("HandleNearRazeReplyPressure", bot, enemy, towers, allies) then return true end
    if race and race.valid and race.canKillSoon then
        if stage("HandleLethalTwoRazeSequence", bot, enemy, towers, allies) then return true end
        if stage("HandleNearRazeFinish", bot, enemy, towers, allies) then return true end
    end
    if stage("HandleImmediateNearRazePunish", bot, enemy, "AGGRESSIVE", towers, allies) then return true end
    if stage("HandleCloseEnemyPunish", bot, enemy, towers, allies) then return true end
    if stage("HandleMirrorRazeTrade", bot, enemy, towers, allies, allies, snapshot.enemyCreeps or {}) then return true end
    if stage("HandleCloseAttackFinish", bot, enemy, towers, allies) then return true end
    local stacked, band = U.IsSecondStackDangerActive(bot, enemy)
    if stacked and band == "mid" and not (race and race.spellWindow) then
        if stage("HandleMidStackSpacing", bot, enemy, towers, allies) then return true end
    end
    if stage("HandleRetaliationAttack", bot, enemy, towers, allies) then return true end
    -- Generic attacks/approach are deliberately LAST, not an early return that
    -- makes every specialised combo handler unreachable.
    if stage("HandleAdvantageRazePressure", bot, enemy, race, towers, allies, nil) then return true end
    -- Last non-destructive option before conceding the tick: a free swing at what is already
    -- inside our attack range (the answer raze had its turn right after the dodge stage).
    if stage("HandleFreeRightClick", bot, W.s, race) then return true end
    -- CRITICAL (`v3.6.0` Anti-Winning-Retreat Fix):
    -- `RunCombatPriority` is entered when we are NOT losing the trade (`edge >= 0` / dominant HP / kill chase).
    -- If the enemy ran past `1150u` or both sides' spells are on short CD, NEVER trigger `BeginForcedRetreat`
    -- (`800ms` backward flee!) unless we are genuinely at risk right now — yield cleanly so CS / T1 siege / forward lane hold run!
    local dangerNow = (not race or not race.valid)
        or race.heCanKillSoon
        or race.losingHard
        or (((bot:GetHealth() or 0) - (race.enBurstSoon or 0)) < 170 and (race.edge or 0) < 40)
    if not dangerNow then
        return false
    end
    local point = U.GetSafeDistancePosition(bot, enemy)
        or U.GetRetreatWaypoint(bot, (bot:GetLocation() - enemy:GetLocation()):Normalized())
    State.lastCombatStage = "no-safe-action-retreat"
    return H.BeginForcedRetreat(bot, point, 0.8)
end

function H.HandleIncomingHeroPressure(bot, snapshot, race)
    local enemy = snapshot.enemy
    if not H.IsEnemyPressuring(bot, enemy) then return false end
    if H.UpdateTowerChase(bot, snapshot) then return true end
    if State.towerChaseBlockedEnemy == enemy then return false end
    State.prepTarget = nil
    State.lhAttackTarget = nil
    State.heroCombatEnemy = enemy
    State.heroCombatUntil = GameTime() + 1.25
    local valid = race and race.valid
    if valid and race.canKillNow then
        if H.HandleGuaranteedRazeKill(bot, enemy, snapshot.enemyTowers or {}, snapshot.allyCreeps or {}) then return true end
        if H.HandleGuaranteedAttackKill(bot, enemy, snapshot.enemyTowers or {}, snapshot.allyCreeps or {}) then return true end
    end
    local losing = not valid or (race.heCanKillSoon and not race.canKillNow)
        or (valid and race.losingHard and not race.spellWindow
            and not race.canKillSoon and not H.GetPendingRazeFollowup(bot, enemy, race, snapshot))
        or (valid and race.weakerSustained and not race.spellWindow
            and not race.canKillSoon and not H.GetPendingRazeFollowup(bot, enemy, race, snapshot)
            and (bot:GetHealth() + 120 < (race.enEffHpNow or enemy:GetHealth()) or race.ttkMe < race.ttkHim * 0.62))
    if losing then
        State.commitKillUntil = 0
        H.ClearRazeState()
        local loc = U.GetSafeDistancePosition(bot, enemy)
        if not loc then
            local away = (bot:GetLocation() - enemy:GetLocation()):Normalized()
            loc = U.GetRetreatWaypoint(bot, away)
        end
        H.BeginForcedRetreat(bot, loc, 1.0)
        return true
    end
    -- Both response and initiative use the same specialist-first pipeline.
    local previous = State.intent
    State.intent = I.TRADE
    local acted = H.RunCombatPriority(bot, snapshot, race)
    State.intent = previous
    return acted

end

-- Combat owns the tick once selected. Creeps are not a reason to ignore an
-- attacker, but retreat, lethal damage and tower safety still take precedence.
function H.CanContinueDryRazeChain(bot, enemy, race)
    if not race or not race.valid or race.heCanKillSoon or not U.CanQuery(enemy) then return false end
    if K.EnemyManaBudget(enemy, true) + math.max(0, enemy.GetManaRegen and enemy:GetManaRegen() or 0) * 0.7 >= 75 then return false end
    if not H.IsRazeFollowUp(bot, enemy) then return false end
    for _, label in ipairs(K.LABELS) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if U.IsRazeAbilityCastable(bot, ab) and H.GetRazeActionType(bot, ab, enemy) then return true end
    end
    return false
end

function H.ShouldEngageHero(bot, enemy, race)
    if not enemy or not U.CanQuery(enemy) or not race or not race.valid or race.heCanKillSoon then return false end
    if State.towerChaseBlockedEnemy == enemy or H.TowerChaseBlocked(bot, W.s) then return false end
    if GetUnitToLocationDistance(bot, enemy:GetLocation()) > 1150 then return false end
    if H.CanContinueDryRazeChain(bot, enemy, race) then return true end
    if K.HasRazeStackLead(bot, enemy) and not H.IsEnemyPressuring(bot, enemy) then return false end
    if H.GetPendingRazeFollowup(bot, enemy, race) then return true end
    if H.HasLanePressureAdvantage(bot, enemy, race) then return true end
    if H.IsEnemyPressuring(bot, enemy) then return true end
    return State.heroCombatEnemy == enemy and GameTime() < (State.heroCombatUntil or 0)

end

-- Once our last-hit swing has started, a rival projectile is NOT grounds to
-- surrender it. Timing uncertainty can reverse arrival order at short distances.
function H.ShouldCancelCommittedLastHit(predictedHP, threshold, buffer, remaining, window)
    return predictedHP > threshold + buffer and remaining > 0.01 and remaining <= window
end

function H.HandleAdvantageRazePressure(bot, enemy, race, towers, allies, nextLastHit)
    if not H.ShouldEngageHero(bot, enemy, race) then return false end
    if State.actionTaken or State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc then return false end
    if State.intent == I.RETREAT or GameTime() < (State.fleeUntil or 0) then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    -- A chosen hero fight may interrupt even a creep last-hit windup.
    local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if distance > 1150 then return false end
    local setupAbility, setupCenter
    local followUp = H.IsRazeFollowUp(bot, enemy)
    local spellBudget = bot:GetMana() >= 150 or (bot:GetMana() >= 75
        and ((race.enRazesSoon or 0) == 0 or followUp or race.canKillSoon
            or H.IsEnemyPressuring(bot, enemy)))
    for _, label in ipairs({"far", "mid", "near"}) do
        local ability = H.GetRazeAbilityByLabel(bot, label)
        if spellBudget and ability and U.IsRazeAbilityCastable(bot, ability) then
            local center = label == "far" and C.RAZE.FAR_CENTER or (label == "mid" and C.RAZE.MID_CENTER or C.RAZE.NEAR_CENTER)
            if not setupAbility and label ~= "near" then setupAbility, setupCenter = ability, center end
            if not H.IsTowerDiveRazeUnsafe(bot, enemy, ability, towers, allies) then
                local action, aim = H.GetRazeActionType(bot, ability, enemy)
                if action and H.CastOrTurnRaze(bot, ability, action, aim, enemy) then return true end
            end
        end
    end
    -- A lead also means right-click pressure, not waiting for spell mana/cooldowns.
    if distance <= bot:GetAttackRange() and H.IsSafeToHarass(bot, enemy:GetLocation(), towers, allies) then
        if H.IssueHeroAttack(bot, enemy) then
            State.actionTaken = true
            return true
        end
    end
    if not setupAbility then
        -- `v7.9.29-pro` (`auto-20261108-2131` `01:43.3..01:44.4` `< 75 MP` Own-T1 Walk-Out Fix!):
        -- Without a castable coil (`< 75 MP`), NEVER foot-chase beyond `atkRange + 95` into an armed rival (`>= 75 MP`),
        -- and NEVER abandon enemy creeps currently inside/entering our own `allyT1` (`<= 1,020u`)!
        if ((enemy:GetMana() or 0) + U.GetMangoMana(enemy)) >= 75 and distance > ((bot:GetAttackRange() or 500) + 95) then
            return false
        end
        local wsAdv = W and W.s or nil
        local ownT1Adv = wsAdv and wsAdv.allyT1Alive ~= false and wsAdv.allyT1Loc or nil
        if ownT1Adv then
            for _, ecAdv in pairs((wsAdv and wsAdv.enemyCreeps) or {}) do
                if U.CanQuery(ecAdv) and ecAdv:IsAlive()
                    and U.DistanceBetweenLocations(ecAdv:GetLocation(), ownT1Adv) <= 1020 then
                    return false
                end
            end
        end
        setupCenter = bot:GetAttackRange() - 30
    end
    -- Walk only a short step toward a ready mid/far band, never into near-raze range.
    if setupCenter and distance > setupCenter + 10 then
        local here = bot:GetLocation()
        local step = math.min(220, distance - setupCenter)
        local point = here + (enemy:GetLocation() - here):Normalized() * step
        return H.ApproachEnemyPoint(bot, enemy, point, 35, towers, allies, false)
    end
    return false
end

function H.EarlyRazePolicyBlocks(bot, enemyHero)
    local cfg = C.RAZE or {}
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local razeLvl = (q and q:GetLevel()) or 0
    if razeLvl >= (cfg.AGGRO_MIN_RAZE_LEVEL or 2) then return false end
    if not U.CanQuery(enemyHero) then return true end
    -- Mirror / answer: he cast a raze (hit or missed) in the last MIRROR_WINDOW s
    local E = K._enemy
    if E and E.lastAnyCastAt and (GameTime() - E.lastAnyCastAt) <= (cfg.MIRROR_WINDOW or 2.5) then return false end
    if U.HasEnemyMissedRazeRecently() then return false end
    -- He walked up close: the near band starts a chain of up to 3 razes
    local pred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT) or enemyHero:GetLocation()
    local d = GetUnitToLocationDistance(bot, pred)
    local dNow = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if math.min(d, dNow) <= (cfg.EARLY_CHAIN_DIST or 360) then return false end
    -- An open chain window (he already took a near raze and is leaving)
    if GameTime() < (State.nearChainUntil or 0) then return false end
    -- `v7.9.17` (`auto-20261107-0354` `00:25..00:42` Level 1-2 Stack-Extend & Unanswerable Outer-`W` Unlock):
    -- Never block Raze Lvl 1 when enemy already carries `enStacks >= 1`, or when enemy's `E(700)` is on CD (`> 1.8s`)!
    local enStE, enRemE = U.GetShadowrazeDebuff(enemyHero)
    if (enStE or 0) >= 1 and (enRemE or 0) >= 0.65 then return false end
    if K.EnemyRazeReadyIn("far") > 1.8 and math.min(d, dNow) <= 755 then return false end
    return true
end

function H.ShouldTryRazePressure(bot, enemyHero, current_mode, aggroCount)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false, current_mode end
    if not U.CanQuery(enemyHero) then return false, current_mode end
    local intent = State.intent
    if intent == I.RETREAT then return false, current_mode end
    -- Mana reserve: pressure with razes only if mana for one more remains after the cast
    -- (except when the enemy cannot answer or we kill him).
    local R = K._race
    local killing = R and R.valid and (R.canKillSoon or State.hunting) -- Hunting = finishing
    local followUp = H.IsRazeFollowUp(bot, enemyHero)
    -- "Free pressure": the enemy has NO raze available (cooldown or mana) and we are
    -- ahead in the trade - raze without a mana reserve. The old reserve (112-150) kept the bot
    -- on right clicks only even though the enemy could not answer with a raze ("I have 1 coil, he has 0 - hit!").
    local dPress = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local enemyBandOnCdHere = not K.EnemyReadyBandAt(enemyHero, dPress, 1.2)
    local freePressure = R and R.valid and R.edge >= 0 and bot:GetMana() >= 75
        and ((R.enRazesSoon or 0) == 0 or enemyBandOnCdHere)
    -- Mana: reserve by level (at level 1-2 a "harmless" enemy is no reason to go to zero: mana is needed
    -- for last hits and the answer, and he will just regen the 64 damage). Finishing a stack - no reserve.
    if not killing and not freePressure and not H.HarassManaOK(bot, R, followUp) then
        return false, current_mode
    end
    -- Raze policy with 1 point (hero L1-L2): do NOT start a trade from range - he regens/eats a mango
    -- for the 85 damage while 75 mana (a quarter of the pool) is lost. Raze only: (a) as a mirror/answer
    -- to his cast, (b) when he walked up close himself (near->mid->far chain),
    -- (c) finishing a stack / killing. From 2 raze points (usually L3) aggression is as before.
    if not killing and not followUp and H.EarlyRazePolicyBlocks(bot, enemyHero) then
        return false, current_mode
    end
    -- Defence: raze him only with support (creeps/tower hitting him), to finish, or
    -- finishing a stack on a LEAVING enemy (he cannot answer, the stack is free)
    if State.defensive and not killing and not H.HasTradeSupport(R) then
        if not (followUp and K.IsEnemyMovingAway(bot, enemyHero)) then
            return false, current_mode
        end
    end
    if followUp then return true, "AGGRESSIVE" end
    if intent == I.ALLIN or intent == I.TRADE or intent == I.ZONE then return true, "AGGRESSIVE" end
    if intent == I.PUSH and R and R.valid and R.edge >= 0 then return true, "AGGRESSIVE" end
    if current_mode == "NEUTRAL" or current_mode == "AGGRESSIVE" then return true, current_mode end
    if bot:GetLevel() > 1 and U.HasEnemyMissedRazeRecently() and H.GetPotentialCombatMana(bot) >= 75 then
        return true, "AGGRESSIVE"
    end
    if aggroCount > 1 or H.GetPotentialCombatMana(bot) < 75 then return false, current_mode end
    local levelDiff = bot:GetLevel() - enemyHero:GetLevel()
    local soulDiff = S.GetSouls(bot) - S.GetSouls(enemyHero)
    local bracerDiff = U.GetItemCount(bot, "item_bracer") - U.GetItemCount(enemyHero, "item_bracer")
    if levelDiff > 0 or soulDiff >= 6 or bracerDiff > 0 then return true, "NEUTRAL" end
    return false, current_mode
end

function H.ShouldAttackHarassEnemy(bot, enemyHero, current_mode, aggroCount, enemyTowers, allyCreeps)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false end
    if not U.CanQuery(enemyHero) then return false end
    if State.defensive and not H.HasTradeSupport(K._race) then return false end
    local interruptRegen = U.IsEnemyHighValueRegen(enemyHero)
    local enemyMissed = U.HasEnemyMissedRazeRecently() and bot:GetLevel() > 1
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local attackRange = bot:GetAttackRange() + 60
    if dist > attackRange then return false end
    local minDistStack = U.GetMinDistWithStack(bot, enemyHero)
    if minDistStack > 0 and dist < minDistStack then return false end
    if not H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then
        if interruptRegen then
            for _, tower in pairs(enemyTowers or {}) do
                if tower:IsAlive() and GetUnitToLocationDistance(tower, bot:GetLocation()) < 720 then
                    return false
                end
            end
        else
            return false
        end
    end
    if interruptRegen then
        return (bot:GetHealth() / bot:GetMaxHealth()) >= 0.30
    end
    local maxAggro = enemyMissed and 2 or 1
    if aggroCount > maxAggro then return false end
    if (bot:GetHealth() / bot:GetMaxHealth()) < C.HARASS.MIN_HP_PCT then return false end
    if current_mode == "PASSIVE" and not enemyMissed then
        local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
        local eHpPct = enemyHero:GetHealth() / enemyHero:GetMaxHealth()
        if (myHpPct - eHpPct) < -0.15 then
            local levelDiff = bot:GetLevel() - enemyHero:GetLevel()
            local soulDiff = S.GetSouls(bot) - S.GetSouls(enemyHero)
            if levelDiff <= 0 and soulDiff < 6 then return false end
        end
    end
    return true
end

function H.GetEnemyApproachDistance(enemyMissed)
    return enemyMissed and C.HARASS.APPROACH_DISTANCE_MISS or C.HARASS.APPROACH_DISTANCE
end

function H.ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if bot:GetMana() < 75 then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks <= 0 then return false end
    if rem_time <= 0.15 then return false end
    if rem_time > C.RAZE.EXTEND_AT + 0.8 then return false end
    return true
end

function H.IsDryVsEnemyRaze(bot, enemyHero)
    if U.IsDryVsArmedEnemySF then
        return U.IsDryVsArmedEnemySF(bot, enemyHero, W and W.s or nil)
    end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    return H.GetPotentialCombatMana(bot) < 75 and U.GetPotentialManaForRaze(enemyHero) >= 75
end

-- "Raze parity". The trade is roughly even (level, items) but he has mana for two
-- razes and we have one. Until we save as much, do not close into mid-band distance:
-- otherwise he catches us with the second raze and we have nothing to mirror with.
function H.IsManaBudgetDisadvantage(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local cfg = C.MANA or {}
    if cfg.PARITY_ENABLE == false then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    local enBudget = K.EnemyRazeBudget(enemyHero, true)
    if enBudget < (cfg.PARITY_MIN_ENEMY or 2) then return false end
    local myBudget = K.MyRazeBudget(bot, true)
    if enBudget - myBudget < (cfg.PARITY_GAP or 1) then return false end
    -- A clear advantage in the trade - no fear: our edge has to be converted
    local R = K._race
    if R and R.valid and (R.edge >= 100 or R.canKillSoon) then return false end
    -- "Roughly equal": level and items
    if math.abs((bot:GetLevel() or 1) - (enemyHero:GetLevel() or 1)) > (cfg.PARITY_LEVEL_DIFF or 1) then
        return false
    end
    if math.abs(U.GetLaneItemPower(bot) - U.GetLaneItemPower(enemyHero)) > (cfg.PARITY_ITEM_DIFF or 0.35) then
        return false
    end
    return true
end

function H.HandleRazeRangedCreepWithHero(bot, enemyHero, enemyCreeps, allyAttackers, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if H.GetPotentialCombatMana(bot) < 75 then return false end
    -- Harass raze - with the level-based mana reserve (like any pressure)
    if not H.HarassManaOK(bot, K._race) then return false end
    if bot:GetMana() < 75 and H.TryUseBurstManaItem(bot, true) then return true end

    local heroPred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
    local abilities = {
        bot:GetAbilityByName("nevermore_shadowraze2"),
        bot:GetAbilityByName("nevermore_shadowraze3"),
    }

    for _, creep in pairs(enemyCreeps or {}) do
        if creep and creep:IsAlive() then
            local name = creep:GetUnitName() or ""
            if name:find("ranged") then
                local creepPred = U.PredictPosition(creep, C.RAZE.CAST_POINT)
                if U.DistanceBetweenLocations(creepPred, heroPred) <= 180 then
                    local ctx = U.GetTargetPredictionContext(creep, allyAttackers)
                    local predHp = U.PredictHPWithContext(ctx, creep, C.RAZE.CAST_POINT + 0.07)
                    for _, ability in ipairs(abilities) do
                        if ability and U.IsRazeAbilityCastable(bot, ability) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps) then
                            local data = U.GetRazeAbilityData(ability)
                            local baseDmg = U.GetRazeDamage(bot, ability, 0)
                            local actualCreepDmg = creep:GetActualIncomingDamage(baseDmg, DAMAGE_TYPE_MAGICAL)
                            local midPoint = Vector(
                                (creepPred.x + heroPred.x) * 0.5,
                                (creepPred.y + heroPred.y) * 0.5,
                                (creepPred.z + heroPred.z) * 0.5
                            )
                            local plannedError = U.GetRazeHitErrorWithDesiredFacing(bot, midPoint, data.center)
                            -- This is a "2 in 1" raze (creep + hero): the hero must be covered robustly
                            -- (now and after the cast), otherwise it is just 75 mana for one creep while the band
                            -- goes on cooldown right as he arrives
                            local heroErrAim = U.RobustRazeErrors(bot, enemyHero, data.center, C.RAZE.CAST_POINT)
                            local heroCovered = heroErrAim <= (C.RAZE.HIT_RADIUS - 60)
                            if predHp > 0 and predHp <= actualCreepDmg + 12 and plannedError <= C.RAZE.HIT_RADIUS and heroCovered then
                                local actionType = "TURN"
                                if U.GetAngleDifference(bot, midPoint) <= C.RAZE.MAX_ANGLE_TO_CAST then
                                    actionType = "CAST"
                                end
                                if H.CastOrTurnRaze(bot, ability, actionType, midPoint, enemyHero) then
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

-- Emergency consumables BEFORE retreats/salves: wand/faerie when nearly dead,
-- mango for a finish (the raze decides the fight). They used to be in HandleItemsAndConsumables
-- at the end of the tick - while retreating the tick ended earlier and the faerie "was not pressed before death".
function H.HandleEmergencyConsumables(bot, race, snapshot)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if GameTime() < (State.lastItemUseTime or 0) + 0.3 then return false end
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    local curHp = bot:GetHealth() or 0
    local commitKill = GameTime() < (State.commitKillUntil or 0)
    local enemy = snapshot and snapshot.enemy or (W.s and W.s.enemy)
    local enemyLive = U.CanQuery(enemy)
    local distance = enemyLive and GetUnitToLocationDistance(bot, enemy:GetLocation()) or 99999

    -- Compute TRUE imminent impact damage (`imminentImpact`): ONLY real in-flight attack projectiles on `bot`,
    -- active enemy Shadowraze cast phase whose AOE covers `bot`, or melee/tower attack actively swinging at `bot`!
    -- NEVER waste `item_faerie_fire` (`-2` permanent attack damage!) at `18%–40%` HP with `0` projectiles in flight
    -- (`9056469656.dem` `02:02.72` `tk=6648`: `149/824 = 18.1% HP`, `Sha` at `873u` running away, `Flask` popped `0.66s` later!).
    local imminentImpact = 0
    if enemyLive then
        local label = K.EnemyPhase()
        if label then
            local center = K.EnemyRazeCenter(enemy, label)
            if center and GetUnitToLocationDistance(bot, center) <= C.RAZE.HIT_RADIUS + 30 then
                imminentImpact = imminentImpact + K.EnemyRazeDamage(bot, enemy, 1)
            end
        end
        if distance <= 215 and enemy.GetAttackTarget and enemy:GetAttackTarget() == bot then
            imminentImpact = imminentImpact + K.AttackDamageVs(enemy, bot)
        end
    end
    if snapshot then
        for _, c in pairs(snapshot.enemyCreeps or {}) do
            if U.CanQuery(c) and c:IsAlive() and c:GetAttackTarget() == bot and GetUnitToLocationDistance(bot, c:GetLocation()) <= 190 then
                imminentImpact = imminentImpact + K.AttackDamageVs(c, bot)
            end
        end
        for _, tw in pairs(snapshot.enemyTowers or {}) do
            if U.CanQuery(tw) and tw:IsAlive() and tw.GetAttackTarget and tw:GetAttackTarget() == bot
                and GetUnitToLocationDistance(bot, tw:GetLocation()) <= 780 then
                imminentImpact = imminentImpact + bot:GetActualIncomingDamage(tw:GetAttackDamage() or 90, DAMAGE_TYPE_PHYSICAL)
            end
        end
    end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if projectile.is_attack and U.CanQuery(projectile.caster) then
                imminentImpact = imminentImpact + K.AttackDamageVs(projectile.caster, bot)
            end
        end
    end
    if hpPct < (C.ITEMS.STICK_USE_PCT or 0.10) then
        local stickItem = H.GetStickLikeItem(bot)
        if stickItem then
            bot:Action_UseAbility(stickItem)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return true
        end
    end
    local imminentLethal = imminentImpact > 0 and curHp <= imminentImpact + 26
    local noFlaskOrTango = (not U.HasItem(bot, "item_flask")) and (not U.HasItem(bot, "item_tango"))
        and not (bot.HasModifier and (bot:HasModifier("modifier_flask_healing") or bot:HasModifier("modifier_tango_heal")))
    -- `v7.9.27-pro` (`auto-20261108-2026` `03:24.23` `tk=10894` `130/1006 HP` @ `d=651u` Wasted Faerie Fire Fix!):
    -- When `imminentImpact == 0` (0 projectiles in flight!) and SF holds `item_flask`, ONLY trigger `criticalLowFloor`
    -- if the enemy can ACTUALLY deal damage at `distance` right now (inside basic-attack reach `<= enRange + 45`, OR
    -- holding `>= 75 MP` with an off-CD Shadowraze band whose circle covers `distance`)! Never burn Faerie Fire (+2 dmg!)
    -- at `d=651u` after Enemy already spent `W` & `E` (`8.9s` CD) and is outside `500u` auto & `474u` `Q`!
    local enHasRazeMpNow = enemyLive and (((enemy:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(enemy) or 0)) >= 75) or false
    local enRangeFaerie = (enemyLive and enemy.GetAttackRange and enemy:GetAttackRange()) or 500
    local enAutoCanHitNow = enemyLive and (distance <= enRangeFaerie + 45)
    local enCoilCanHitNow = false
    if enHasRazeMpNow then
        local qRdyF = (not K.EnemyRazeReadyIn) or (K.EnemyRazeReadyIn("near") <= 0.65)
        local wRdyF = (not K.EnemyRazeReadyIn) or (K.EnemyRazeReadyIn("mid")  <= 0.65)
        local eRdyF = (not K.EnemyRazeReadyIn) or (K.EnemyRazeReadyIn("far")  <= 0.65)
        enCoilCanHitNow = (qRdyF and distance <= 485)
            or (wRdyF and distance >= 185 and distance <= 725)
            or (eRdyF and distance >= 435 and distance <= 975)
    end
    local enemyCanReachDamageNow = enAutoCanHitNow or enCoilCanHitNow
    local enemyRazeExecThreat = enemyLive and distance <= 940 and noFlaskOrTango and enCoilCanHitNow
        and curHp <= ((K.EnemyRazeDamage and K.EnemyRazeDamage(bot, enemy, 1) or 140) + 22)
    local criticalLowFloor = (hpPct <= 0.145
        and (imminentImpact > 0 or enemyCanReachDamageNow or (not U.HasItem(bot, "item_flask") and enemyLive and distance <= 680)))
        or (curHp <= 175 and enemyRazeExecThreat)
    if imminentLethal or criticalLowFloor then
        local faerie = U.GetActiveItemByName(bot, "item_faerie_fire")
        if faerie then
            bot:Action_UseAbility(faerie)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return true
        end
    end
    -- Mango for the finish: let the raze decide the fight right now
    if commitKill and bot:GetMana() < 75 and (bot:GetMana() + U.GetMangoMana(bot)) >= 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end
    return false
end

-- Plant only when healing is needed; identify the new tree by POSITION, never by handle.
-- (21.10 correction of the 20.10 finding) The bot does plant a branch - and then could not find
-- its own tree: `plan.before[tree]` is keyed by the tree userdata returned by GetNearbyTrees, and in
-- the real client two calls do not return the same userdata for the same tree.  So "not before[tree]"
-- was true for every tree and the bot ate whatever OLD tree happened to lie within 80 of the plant
-- point; the branch stayed on the map as a tree and the tango charge was spent on a stranger.
-- Now the "already there" set is stored as POSITIONS (matched within 12 units) and the plant point is
-- chosen so that no tree stands within 90 units of it - then the only tree that can be within 60 of
-- the point a second later is the one we planted.
-- =================================================================================================
-- PROVEN SOURCE 2 ENGINE INVARIANT (`libserver.so` + live `.dem` ticks `4108`, `3990..4146`, `7704..7708`):
-- Human `DOTA_UNIT_ORDER_CAST_TARGET_TREE` accepts dynamic `CDOTA_TempTree` (`id >= N_static`),
-- whereas Valve's C++ `CDOTA_Bot::Action_UseAbilityOnTree(pAbility, iTree)` validates `0 <= iTree < N_static`
-- against the static map tree array (`ValveSoftware/Dota2-Gameplay#23152`, `#34354`) and `bot:GetNearbyTrees`
-- ignores `CDOTA_TempTree` completely! Planting `item_branches` from a Lua Bot therefore destroys `50g` +
-- `-1 STR/AGI/INT` (`-22 HP`, `-12 MP`, `-1 DMG`) for ZERO Tango healing (`auto-20261107-2214` `tk=4108` Fix!).
-- Always keep `item_branches` in inventory purely for permanent `+1 all stats` until sold/swapped, and eat
-- static trees cleanly via `H.TryWaveSafeStaticTango` / `H.TryInstantAdjacentTango`!
-- =================================================================================================
function H.HandleActiveBranchTango(_bot)
    State.branchTango = nil
    State.branchTangoSwapUntil = nil
    return false
end

function H.HandleBranchTango(_bot, _tango)
    State.branchTango = nil
    State.branchTangoSwapUntil = nil
    return false
end

function H.HandleItemsAndConsumables(bot, bestTarget, enemyCreeps, allyAttackers, enemyTowers, enemyHero)
    if GameTime()>=(State.branchTangoSwapUntil or -math.huge) then U.ManageInventorySlots(bot) end
    -- An eat-tree order was issued: hold position until modifier_tango_heal appears (up to 1 s)
    if State.tangoCastAt > 0 and (GameTime() - State.tangoCastAt) < 1.0 then
        if bot:HasModifier("modifier_tango_heal") then
            H.ClearTangoState()
            State.tangoFails = 0
        else
            State.actionTaken = true
            return true
        end
    end
    if GameTime() < State.lastItemUseTime + 0.3 then return false end
    if H.ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero) then return false end

    local hpPct = bot:GetHealth() / bot:GetMaxHealth()
    -- (Wand/faerie moved to HandleEmergencyConsumables - the start of the tick)
    if bot:GetMana() < 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end

    local isHighValueBeingAttacked = false
    for _, c in pairs(enemyCreeps or {}) do
        if c:IsAlive() then
            local name = c:GetUnitName() or ""
            if name:find("ranged") or name:find("flagbearer") or name:find("siege") then
                if (c:GetHealth() / c:GetMaxHealth()) < 0.50 then
                    isHighValueBeingAttacked = true
                    break
                end
                for _, atk in pairs(allyAttackers or {}) do
                    if atk:IsAlive() and atk:GetAttackTarget() == c then
                        isHighValueBeingAttacked = true
                        break
                    end
                end
                if isHighValueBeingAttacked then break end
            end
        end
    end

    local tcfg = C.TANGO or {}
    local missingHp = bot:GetMaxHealth() - bot:GetHealth()
    local wantTango = hpPct < (tcfg.USE_HP_PCT or 0.80) and missingHp >= (tcfg.MIN_MISSING_HP or 100)
    -- In an active fight (TRADE/ALLIN) do not walk to trees while HP is above 60%; in ZONE eat below 60%
    local intent = State.intent
    if (intent == "TRADE" or intent == "ALLIN") and hpPct >= 0.60 then wantTango = false end
    if intent == "ZONE" and hpPct >= 0.60 then wantTango = false end
    if intent == "RETREAT" then wantTango = false end
    -- A "valuable creep under attack" delays the tango only at HP >= 50%
    if hpPct < 0.50 then isHighValueBeingAttacked = false end
    if bot:HasModifier("modifier_tango_heal") then
        H.ClearTangoState()
        wantTango = false
    end

    if wantTango and not isHighValueBeingAttacked then
        local tango = U.GetActiveItemByName(bot, "item_tango")
        if tango then
            local now = GameTime()
            -- An eat-tree order was already issued: wait for modifier_tango_heal without leaving the tree.
            -- Otherwise the next handler walks the bot away and the eat order is cancelled (loop).
            if State.tangoCastAt > 0 and (now - State.tangoCastAt) < 1.0 then
                State.actionTaken = true
                return true
            end
            if State.tangoCastAt > 0 then
                -- The order did not work within 1 s: try again, after two failures use another tree
                State.tangoFails = (State.tangoFails or 0) + 1
                State.tangoCastAt = 0
                if State.tangoFails >= 2 then
                    State.tangoBadTree = State.tangoTree
                    State.tangoBadTreeTime = now
                    State.tangoFails = 0
                    H.ClearTangoState()
                end
            end
            local branchAction,waitingForBranch=H.HandleBranchTango(bot,tango)
            if branchAction then return true end
            if waitingForBranch then return false end
            local tree, treeLoc = H.GetStickyTangoTree(bot, enemyHero, enemyTowers)
            if tree and treeLoc then
                local distToTree = U.DistanceBetweenLocations(bot:GetLocation(), treeLoc)
                if distToTree > 165 then
                    H.SmartMove(bot, treeLoc, 40)
                    return true
                end
                bot:Action_UseAbilityOnTree(tango, tree)
                State.branchTangoDone=true
                State.lastItemUseTime = now
                State.tangoCastAt = now
                State.actionTaken = true
                return true
            end
        end
    elseif not wantTango then
        H.ClearTangoState()
    end

    return false
end

function H.ProcessTelemetry(bot)
    local now = GameTime()
    for i = #State.flyingProjectiles, 1, -1 do
        local proj = State.flyingProjectiles[i]
        if now > proj.impactTime + 0.15 then
            table.remove(State.flyingProjectiles, i)
        end
    end
end

function H.HandleEmergencyRetreat(bot, enemyHero)
    local fountain = P.GetFountain(bot)
    local distToFountain = GetUnitToLocationDistance(bot, fountain)
    local returnHpPct = (C.TP and C.TP.RETURN_HP_PCT) or 0.50
    local hpPct = bot:GetHealth() / bot:GetMaxHealth()

    if enemyHero and U.CanQuery(enemyHero) then
        local canOneShot, oneShotMethod = U.CanOneShotEnemyHero(bot, enemyHero)
        local canRazeKill, razeLabel = U.CanKillEnemyWithOneRaze(bot, enemyHero)
        if canOneShot then
            return false
        end
        if canRazeKill then
            return false
        end
    end

    if State.emergencyRetreat == "FOUNTAIN" and hpPct >= returnHpPct then
        if H.IsAtFountain(bot) then
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
            State.goingToFountain = true
            State.fountainReason = "HP"
        else
            -- HP recovered on the way (regen/tango/salve): the emergency retreat is over. Otherwise
            -- "FOUNTAIN" would stay in State and on the next HP dip below 50% would force
            -- a fountain run (committedFountain) for no real reason.
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
            H.ClearForcedRetreat()
        end
        return false
    end

    local ownT1Pos = P.GetT1Close(bot, 0)
    local deepPastOwnT1 = ownT1Pos and (GetUnitToLocationDistance(bot, ownT1Pos) >= 1450)
        and (distToFountain < U.DistanceBetweenLocations(ownT1Pos, fountain) - 900)
    -- `02:11.7–02:12.7` (`tk=7384..7414`) Fix: clear latched `State.emergencyRetreat == "FOUNTAIN"` BEFORE `TryTPHome`
    -- whenever we are NOT yet deep past own T1 (`not deepPastOwnT1`) and either a Salve is in pipeline/nearly affordable
    -- (`>= 72g`) OR the enemy also backed off crippled (`EnemyResourcesAsWeak`, including FoW)!
    if State.emergencyRetreat == "FOUNTAIN" and not deepPastOwnT1 then
        if (U.IsSalveAvailableOrImminent and U.IsSalveAvailableOrImminent(bot, enemyHero))
            or (U.EnemyResourcesAsWeak and U.EnemyResourcesAsWeak(bot, enemyHero, hpPct)) then
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
            H.ClearForcedRetreat()
            return false
        end
    end

    if State.emergencyRetreat == "FOUNTAIN" and hpPct < returnHpPct then
        if H.TryTPHome(bot, enemyHero) then return true end
    end

    local committedFountain = State.emergencyRetreat == "FOUNTAIN"
        and State.emergencyRetreatStartTime > 0
        and ((GameTime() - State.emergencyRetreatStartTime) >= 2.5 or deepPastOwnT1)
        and (W.s == nil or W.s.enemyAlive ~= false)
        and not U.HasAnyHealing(bot)
        and not (not deepPastOwnT1 and U.IsSalveAvailableOrImminent and U.IsSalveAvailableOrImminent(bot, enemyHero))
        and distToFountain > ((C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 500)

    if committedFountain then
        H.BeginForcedRetreat(bot, fountain, 1.0)
        return true
    end

    local reason, extraLoc = U.GetEmergencyRetreatReason(bot, enemyHero)
    if not reason then
        if State.emergencyRetreat then
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
        end
        return false
    end

    if reason == "COURIER" and extraLoc then
        State.emergencyRetreat = "COURIER"
        State.emergencyRetreatStartTime = 0
        local botLoc = bot:GetLocation()
        local dist = U.DistanceBetweenLocations(botLoc, extraLoc)
        if dist > 150 then
            local toFountain = (fountain - botLoc):Normalized()
            local toCourier = (extraLoc - botLoc):Normalized()
            local blended = (toCourier * 0.8 + toFountain * 0.2):Normalized()
            H.SmartMove(bot, botLoc + blended * math.min(dist, 400), 60)
        end
        State.actionTaken = true
        return true
    end

    if State.emergencyRetreat ~= "FOUNTAIN" then
        State.emergencyRetreatStartTime = GameTime()
    end
    State.emergencyRetreat = "FOUNTAIN"

    if distToFountain < ((C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 500) then
        State.emergencyRetreat = nil
        State.goingToFountain = true
        State.fountainReason = "EMERGENCY"
        State.actionTaken = true
        return true
    end

    H.BeginForcedRetreat(bot, fountain, 1.0)
    return true
end

function H.HandleGlyph(bot, enemyHero, enemyTowers, allyTowers, allyCreeps)
    if U.ShouldUseGlyphDefensive(bot, allyTowers) then
        U.UseGlyph(bot)
        State.actionTaken = true
        return true
    end
    if U.ShouldUseGlyphForKillDive(bot, enemyHero, enemyTowers, allyTowers, allyCreeps) then
        U.UseGlyph(bot)
        State.glyphUsedForDive = true
        State.glyphDiveTime = GameTime()
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandleForcedSalve(bot)
    if not U.ShouldForceSalve(bot) then return false end
    if GameTime() < State.lastForceSalveTime + 1.0 then return false end
    local nearbyEnemyHeroes = bot:GetNearbyHeroes(700, true, BOT_MODE_NONE)
    if nearbyEnemyHeroes and #nearbyEnemyHeroes > 0 then
        local fountain = P.GetFountain(bot)
        local botLoc = bot:GetLocation()
        H.SmartMove(bot, botLoc + (fountain - botLoc):Normalized() * 400, 60)
        State.actionTaken = true
        return true
    end
    local nearbyEnemyCreeps = bot:GetNearbyLaneCreeps(500, true) or {}
    for _, c in pairs(nearbyEnemyCreeps) do
        if U.CanQuery(c) and c:GetAttackTarget() == bot then -- Creep in fog -> do not query
            local fountain = P.GetFountain(bot)
            local botLoc = bot:GetLocation()
            H.SmartMove(bot, botLoc + (fountain - botLoc):Normalized() * 350, 60)
            State.actionTaken = true
            return true
        end
    end
    local flask = U.GetActiveItemByName(bot, "item_flask")
    if flask then
        if H.HasEnemyProjectileIncoming(bot) then
            local safeLoc = H.GetSalveSafeRetreatLocation(bot, nil)
            H.BeginForcedRetreat(bot, safeLoc, 0.65)
            return true
        end
        bot:Action_UseAbilityOnEntity(flask, bot)
        State.lastForceSalveTime = GameTime()
        State.lastItemUseTime = GameTime()
        State.actionTaken = true
        return true
    end
    return false
end

-- Purchases have one owner: item_purchase_nevermore.lua.

function H.HandleSafeDistanceFromEnemy(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if canOneShot then
        if H.IssueHeroAttack(bot, enemyHero) then
            State.lastHarassTime = GameTime()
            State.lastAggroTime = GameTime()
            State.aggroPullTime = GameTime() + 0.25
            return true
        end
    end
    local canQuickRazeKill, razeLabel = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if canQuickRazeKill then
        local ability = H.GetRazeAbilityByLabel(bot, razeLabel)
        if ability then
            local predLoc = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
            local angleDiff = U.GetAngleDifference(bot, predLoc)
            local actionType = angleDiff <= C.RAZE.MAX_ANGLE_TO_CAST and "CAST" or "TURN"
            if H.CastOrTurnRaze(bot, ability, actionType, predLoc, enemyHero) then
                return true
            end
        end
    end
    if not U.IsInEnemyRazeKillThreat(bot, enemyHero) then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    local safeLoc = U.GetSafeDistancePosition(bot, enemyHero)
    if not safeLoc then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local hp = bot:GetHealth()
    local threat1 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 1)
    local isCritical = (threat1 > 0 and hp <= threat1 * SAFE_DISTANCE.CRITICAL_HP_FACTOR)
    local minDist = isCritical and (SAFE_DISTANCE.MIN_DISTANCE_CRITICAL or 950) or SAFE_DISTANCE.MIN_DISTANCE_FROM_ENEMY
    if dist < minDist then
        local duration = isCritical and 1.20 or 0.80
        H.BeginForcedRetreat(bot, safeLoc, duration)
        return true
    end
    return false
end

function H.HandleDryManaMidRazeAvoidance(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if K.EnemyCastableRazeCount(enemyHero, 1.4) <= 0 then
        State.dryRetreatHystUntil = 0
        return false
    end
    if not H.IsDryVsEnemyRaze(bot, enemyHero) then
        State.dryRetreatHystUntil = 0
        return false
    end
    if K.HasDominantRightClickPosture and K.HasDominantRightClickPosture(bot, enemyHero, W.s) then
        State.dryRetreatHystUntil = 0
        return false
    end
    -- `v7.9.7-pro` (`0255 @ 08:36.6` `5 HP`, `0307 @ 08:52.4` `17 HP` Escape, `0307 @ 10:12.8` `10 HP` Turnback Fix!):
    -- NEVER run away from a `1–2` right-click lethal enemy (`<= 1.85x` attack damage) when our HP comfortably tanks
    -- his desperation burst (`+145 HP` cushion) and we can kinematically catch him outside unshielded Enemy T1!
    do
        local dCheckOne = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local myHpOne = bot:GetHealth() or 0
        local myAtkOne = K.AttackDamageVs(bot, enemyHero)
        local inFlightOne = (U.GetOwnInFlightDamageOnHero and U.GetOwnInFlightDamageOnHero(bot, enemyHero)) or 0
        local enEffHpOne = math.max(1, (enemyHero:GetHealth() or 9999) - inFlightOne)
            + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(enemyHero)) or 0)
        local isTrueOneShot = U.CanOneShotEnemyHero(bot, enemyHero) or (enEffHpOne <= myAtkOne * 0.98)
        local burstHere = K.EnemyBurstVs(bot, enemyHero, math.min(dCheckOne, 500), 1.15, false)
        local finishMultOne = (myHpOne >= 460) and 2.25 or 1.85
        if ((isTrueOneShot and myHpOne >= burstHere + 8)
                or (enEffHpOne <= myAtkOne * finishMultOne and myHpOne >= 340 and myHpOne >= burstHere + 145))
            and H.CanKinematicallyCatchForAttack(bot, enemyHero, W.s and W.s.enemyTowers, W.s and W.s.allyCreeps, 1.85) then
            State.dryRetreatHystUntil = 0
            return false
        end
    end
    if State.actionTaken then return false end
    local now = GameTime()
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local safeDryDist = (U.GetDrySafeStandoffDist and U.GetDrySafeStandoffDist(bot, enemyHero)) or 745
    if safeDryDist <= 0 then return false end
    -- `v7.9.1` Dry-Mana Retreat Distance + Time Hysteresis (`9071946472.dem` `03:39.0–03:45.1` Oscillation Fix!):
    -- Enter retreat when `dist < safeDryDist - 12` (`~733u`), and KEEP retreating until `dist >= safeDryDist + 105` (`~850u`)
    -- while `now < State.dryRetreatHystUntil` so SF never releases retreat at `782u` and turns back into enemy coils/autos!
    local inHyst = now < (State.dryRetreatHystUntil or 0)
    local triggerDist = inHyst and (safeDryDist + 55) or (safeDryDist - 12)
    if dist >= triggerDist then return false end
    local fnt = P.GetFountain(bot)
    local deepT1 = P.GetBehindT1(bot, 320)
    if dist >= safeDryDist and U.DistanceBetweenLocations(bot:GetLocation(), fnt) <= U.DistanceBetweenLocations(deepT1, fnt) then
        return false
    end
    -- `auto-20261102-0007` (`7:58..8:06` `1002 HP` @ `dEC=1554u` & `8:56..9:03` `925 HP` @ `dEC=1626u`) 1,340u XP-Radius Tether:
    -- When healthy (`>= 580 HP` & above 2-raze + buffer) with `0` raze stacks, NEVER let forward enemy posturing push SF
    -- beyond `1,340u` from active lane `enemyCreeps` (strictly inside Dota 2's `1,500u` XP radius!).
    local myHpDry = bot:GetHealth() or 0
    local myStDry = U.GetShadowrazeDebuff(bot) or 0
    local healthyForXpTether = (myStDry == 0)
        and (myHpDry >= math.max(580, K.EnemyRazeDamage(bot, enemyHero, 2) + 95))
    local nearestCreepLoc = nil
    local minCreepDist = 9999
    if healthyForXpTether and W and W.s and W.s.enemyCreeps then
        for _, ec in pairs(W.s.enemyCreeps) do
            if ec and U.CanQuery(ec) and ec:IsAlive() then
                local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                if dc < minCreepDist and dc <= 2200 then
                    minCreepDist = dc
                    nearestCreepLoc = ec:GetLocation()
                end
            end
        end
    end
    if nearestCreepLoc and minCreepDist >= 1310 and dist >= 545 then
        return false
    end
    local retreatLoc = U.GetMidBandExitPosition(bot, enemyHero)
    if nearestCreepLoc and U.DistanceBetweenLocations(retreatLoc, nearestCreepLoc) > 1340 then
        local clampedXpLoc = nearestCreepLoc + (fnt - nearestCreepLoc):Normalized() * 1340
        if U.DistanceBetweenLocations(clampedXpLoc, enemyHero:GetLocation()) >= 545 then
            retreatLoc = clampedXpLoc
        end
    end
    State.dryRetreatHystUntil = now + 1.45
    H.BeginForcedRetreat(bot, retreatLoc, 0.90)
    return true
end

function H.HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local desired = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_DISTANCE) or 215
    local minDist = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_MIN_DISTANCE) or 150
    local maxDist = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_MAX_DISTANCE) or 250
    local tol = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_TOLERANCE) or 25
    if dist >= minDist and dist <= maxDist then
        H.SafeClearActions(bot)
        bot:Action_MoveToLocation(botLoc)
        State.lastMoveLoc = botLoc
        State.lastMoveTime = GameTime()
        State.actionTaken = true
        return true
    end
    -- With a stack on us do NOT close on the enemy (near band = his right click + near raze
    -- with the bonus); "keep the answer distance" only if already adjacent (back off to 215)
    if dist > maxDist then return false end
    local dir = botLoc - enemyLoc
    if dist < 1 then
        dir = U.GetFountain(bot) - enemyLoc
    end
    dir = dir:Normalized()
    local holdLoc = enemyLoc + dir * desired
    holdLoc = H.GetSafeApproachLoose(bot, holdLoc, enemyTowers or {}, allyCreeps or {})
    H.SmartMove(bot, holdLoc, tol)
    State.actionTaken = true
    return true
end

function H.HandleNearRazeReplyPressure(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if not secondStackActive or hitLabel ~= "near" then return false end
    local myStacks, myRemain = U.GetShadowrazeDebuff(bot)
    if myStacks ~= 1 or myRemain <= C.RAZE.RETREAT_MIN_REMAIN then return false end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and U.IsRazeAbilityCastable(bot, q) then
        local willHit, _, predicted = U.WillRazeHit(bot, q, enemyHero, C.RAZE.CAST_POINT, false)
        if willHit then
            local actionType = U.GetAngleDifference(bot, predicted) <= C.RAZE.MAX_ANGLE_TO_CAST and "CAST" or "TURN"
            if H.CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
                return true
            end
        end
    end

    local enemyIsHittingUs = false
    if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then
        enemyIsHittingUs = true
    end
    if not enemyIsHittingUs and bot.WasRecentlyDamagedByHero then
        enemyIsHittingUs = bot:WasRecentlyDamagedByHero(enemyHero, 1.0)
    end

    if enemyIsHittingUs then
        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local attackRange = bot:GetAttackRange() + 60
        if dist <= attackRange then
            if H.IssueHeroAttack(bot, enemyHero) then
                State.lastHarassTime = GameTime()
                State.lastAggroTime = GameTime()
                State.aggroPullTime = GameTime() + 0.25
                return true
            end
        end
    end

    return H.HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps)
end

function H.HandleMirrorRazeTrade(bot, enemyHero, enemyTowers, allyCreeps, allyCreepsData, enemyCreepsData)
    if not U.CanQuery(enemyHero) or State.towerChaseBlockedEnemy==enemyHero or State.actionTaken then return false end
    local active,label=U.IsSecondStackDangerActive(bot,enemyHero)
    if not active or not label then return false end
    local ab=H.GetRazeAbilityByLabel(bot,label)
    if not U.IsRazeAbilityCastable(bot,ab) then return false end
    local action,aim=H.GetRazeActionType(bot,ab,enemyHero)
    if action then return H.CastOrTurnRaze(bot,ab,action,aim,enemyHero) end
    -- A real in-range attacker must not get free hits while we reposition for a different band.
    if enemyHero:GetAttackTarget()==bot and GetUnitToLocationDistance(bot,enemyHero:GetLocation())<=bot:GetAttackRange() then return false end
    local setup=U.GetRazeSetupPositionForAbility(bot,enemyHero,U.GetRazeCenterByLabel(label))
    return setup and H.ApproachEnemyPoint(bot,enemyHero,setup,35,enemyTowers,allyCreeps) or false
end

-- Instant mirror. His raze just landed on us (<= MIRROR_INSTANT_SEC): he stands
-- in the same band on our side (symmetry) - answer immediately with the same band (his copy is on a 9 s cd)
-- or with any band that covers robustly. Previously the answer came after the stack-exit rule and the
-- finish block, i.e. 0.5-1 s later when the enemy had already moved ("mirrors slowly").
-- Without closing: cast/turn in place only. No mirror if: his burst is lethal now; less than
-- MIRROR_MIN_HP_LEFT would remain after his next raze; we are under his T1 without a creep shield.
H._mirrorOrder = { nil, nil, nil }
function H.HandleInstantMirrorRaze(bot, enemyHero, race, s)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    -- While fleeing we MAY answer (an instant reply to his raze that hit us) -
    -- this is a deliberate "turn, cast, run again", not twitching (as it was before v2.6)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local age = U.GetRecentEnemyRazeHitAge(enemyHero)
    if age > ((C.RAZE and C.RAZE.MIRROR_INSTANT_SEC) or 0.7) then return false end
    -- Deduplicate the enemy HIT, not all our casts for 1.2 seconds.
    local hitTime = GameTime() - age
    if State.mirrorAnsweredEnemy == enemyHero and State.mirrorAnsweredHit
        and math.abs(State.mirrorAnsweredHit - hitTime) < 0.001 then return false end
    if H.GetPotentialCombatMana(bot) < 75 then return false end
    local canKillNow = race and race.valid and race.canKillNow
    if race and race.valid and race.heCanKillNow and not canKillNow then return false end
    local oneRaze = K.EnemyRazeDamage(bot, enemyHero, 1)
    if not canKillNow and (bot:GetHealth() - oneRaze) < ((C.RAZE and C.RAZE.MIRROR_MIN_HP_LEFT) or 110) then
        return false
    end
    local underT1 = H.IsBotUnderEnemyT1(bot, s and s.enemyTowers or {})
    if underT1 and not H.TowerLockedOnCreep(s and s.enemyT1) then return false end
    if bot:GetMana() < 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
        return false
    end
    local hitLabel = U.GetRecentEnemyRazeHitLabel(enemyHero)
    local order = H._mirrorOrder
    local n = 0
    if hitLabel then n = n + 1; order[n] = hitLabel end
    for i = 1, 3 do
        if K.LABELS[i] ~= hitLabel then n = n + 1; order[n] = K.LABELS[i] end
    end
    for i = 1, n do
        local ab = H.GetRazeAbilityByLabel(bot, order[i])
        if ab and U.IsRazeAbilityCastable(bot, ab) then
            local actionType, aimLoc = H.GetRazeActionType(bot, ab, enemyHero)
            if actionType and H.CastOrTurnRaze(bot, ab, actionType, aimLoc, enemyHero) then
                if U.DEBUG then print(string.format("[SF-BOT] instant mirror %s (%s) age=%.2f", order[i], actionType, age)) end
                return true
            end
        end
    end
    return false
end

function H.HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and hitLabel ~= "near" then return false end
    local shouldClose, closePos = U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if not shouldClose or not closePos then return false end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local canQuickRazeKill, _ = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if canQuickRazeKill then
    elseif U.IsInEnemyRazeKillThreat(bot, enemyHero) then
        return false
    end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and U.IsRazeAbilityCastable(bot, q) then
        local willHit, _, predicted = U.WillRazeHit(bot, q, enemyHero, C.RAZE.CAST_POINT, false)
        if willHit then
            -- Via the shared CastOrTurnRaze (facing check + turn step, not walking to the enemy)
            local actionType = H.RazeFacingOK(bot, predicted) and "CAST" or "TURN"
            if H.CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
                return true
            end
        end
    end

    if H.ApproachEnemyPoint(bot, enemyHero, closePos, 35, enemyTowers, allyCreeps) then
        return true
    end
    return false
end

function H.HandleImmediateNearRazePunish(bot, enemyHero, current_mode, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana() < 75 and H.GetPotentialCombatMana(bot) >= 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or not U.IsRazeAbilityCastable(bot, q) then return false end
    -- The mana reserve for the near punish was removed (v2.3 gated it with a 130 reserve: at 141 mana the bot
    -- silently stood in the near band and took stacks). The enemy walked up close - that is the best moment
    -- for a trade: a near raze now, mid/far at the runner. Only 75 mana is needed.
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local secondStackActive, safeReplyLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and safeReplyLabel ~= "near" then return false end
    -- Robust - the near circle must cover the enemy both now and after the cast time
    -- (an enemy leaving the near band is not "punished" with a raze into thin air)
    -- A margin of >= 100 u from the near circle edge: an enemy standing at the edge (380-450) gets out of
    -- the circle during the cast as soon as he starts moving; such a target is hit by the mid raze (via GetBestRaze).
    if K.IsEnemyMovingAway(bot, enemyHero) then return false end
    local errAim, errFacing, predicted = U.RobustRazeErrors(bot, enemyHero, C.RAZE.NEAR_CENTER, C.RAZE.CAST_POINT)
    local limit = C.RAZE.HIT_RADIUS - 100
    if errAim > limit then return false end
    local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if distToEnemy > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then return false end
    if H.IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then
        local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
        if oneRaze < enemyHero:GetHealth() then return false end
    end
    local actionType = "TURN"
    if errFacing <= limit then -- Same threshold as the candidate (no TURN dead zone)
        actionType = "CAST"
    end
    if H.CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
        if actionType == "CAST" then
            -- Chain window: for the next ~5 s the stack-finishing razes go without a mana reserve
            State.nearChainUntil = GameTime() + ((C.RAZE and C.RAZE.NEAR_CHAIN_WINDOW) or 5.0)
        end
        return true
    end
    return false
end

-- The enemy walked up close - punishing him beats waiting for the last hit. Previously at this moment
-- the last-hit block ran (is_free_to_prehit = false) and the bot silently stood by the creep while being hit.
-- Try the near raze first; if it does not cover, finish for sure with mid/far
-- and extend the stack (he is already in reach, too late for him to leave).
function H.HandleCloseEnemyPunish(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local cfg = C.RAZE or {}
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if dist > (cfg.PUNISH_CLOSE_RANGE or 520) then return false end
    if H.GetPotentialCombatMana(bot) < (cfg.PUNISH_MIN_POT_MANA or 150) then return false end
    local R = K._race
    local weWin = R and R.valid and (R.canKillSoon or R.edge > 0)
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) and not weWin and not U.CanOneShotEnemyHero(bot, enemyHero) then
        return false
    end
    if bot:GetMana() < 75 and H.TryUseBurstManaItem(bot, true) then return true end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and H.IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then return false end

    if H.HandleImmediateNearRazePunish(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps) then
        return true
    end

    -- Near does not cover - hit with mid/far and extend the stack
    State.nearChainUntil = math.max(State.nearChainUntil or 0, GameTime() + (cfg.NEAR_CHAIN_WINDOW or 5.0))
    if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, true) then
        return true
    end
    return false
end

function H.HandleBootDisadvantageMidRazeFear(bot, enemyHero)
    if U.CanQuery(enemyHero) and K.BandSafeFromEnemy(enemyHero, "mid", 1.2) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if H.IsNearOwnT1(bot, 400) then return false end -- Do not retreat past our own T1
    if not U.ShouldFearBootsMidRaze(bot, enemyHero) then return false end
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) then return false end
    if U.CanKillEnemyWithTwoRazes(bot, enemyHero) then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midRadius = (C.BOOT_FEAR and C.BOOT_FEAR.MID_RAZE_RADIUS) or 220
    if math.abs(dist - C.RAZE.MID_CENTER) > midRadius then return false end
    local retreatLoc = U.GetMidBandExitPosition(bot, enemyHero) -- Short step past the band edge
    H.BeginForcedRetreat(bot, retreatLoc, (C.BOOT_FEAR and C.BOOT_FEAR.RETREAT_DURATION) or 0.95)
    return true
end

-- Is any "mid band fear" active (same conditions as the three handlers below,
-- without the distance check). The U._midFear flag makes the minimum enemy distance proactive.
function H.MidRazeFearActive(bot, enemyHero)
    if U.CanQuery(enemyHero) and K.BandSafeFromEnemy(enemyHero, "mid", 1.2) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) or not U.EnemyHasRaze(enemyHero) then return false end
    -- Do not back off past our own T1: the tower will punish him and retreating behind it loses the lane
    if H.IsNearOwnT1(bot, 400) then return false end
    if State.enemyReachedLevel2First and bot:GetLevel() < 2 then return true end
    if H.IsDryVsEnemyRaze(bot, enemyHero) then return true end
    if H.IsManaBudgetDisadvantage(bot, enemyHero) then return true end
    if U.ShouldFearBootsMidRaze(bot, enemyHero) and not U.IsInEnemyRazeKillThreat(bot, enemyHero)
        and not U.CanKillEnemyWithTwoRazes(bot, enemyHero) then
        return true
    end
    return false
end

function H.HandleEnemyLevel2FirstMidRazeFear(bot, enemyHero)
    if U.CanQuery(enemyHero) and K.BandSafeFromEnemy(enemyHero, "mid", 1.2) then return false end
    if not State.enemyReachedLevel2First then return false end
    if H.IsNearOwnT1(bot, 400) then return false end -- Do not retreat past our own T1
    if bot:GetLevel() >= 2 then
        State.enemyReachedLevel2First = false
        return false
    end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midRadius = 220
    if math.abs(dist - C.RAZE.MID_CENTER) > midRadius then return false end
    local retreatLoc = U.GetMidBandExitPosition(bot, enemyHero) -- Short step past the band edge
    H.BeginForcedRetreat(bot, retreatLoc, 0.90)
    return true
end

function H.HandleEnemyT1WaveDriftRetreat(bot, enemyHero, enemyTowers, allyCreeps, enemyCreeps)
    local underT1, t1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    if H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    -- The tower is nearly down - stay under it and finish it
    if LN.IsTowerFinishable(bot, t1) then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    local closestDist = math.huge
    local closestCreep = nil
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            local name = c:GetUnitName() or ""
            local isSiege = name:find("siege") or name:find("catapult")
            if not isSiege then
                local d = GetUnitToLocationDistance(t1, c:GetLocation())
                if d < closestDist then
                    closestDist = d
                    closestCreep = c
                end
            end
        end
    end
    local prevDist = State.enemyT1ClosestCreepDist
    State.enemyT1ClosestCreepDist = (closestCreep and closestDist) or nil
    State.enemyT1ClosestCreepTime = GameTime()
    local driftStart = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_START) or 620
    local driftHard = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_HARD) or 700
    local driftDelta = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_DELTA) or 22
    local shouldRetreat = false
    if not closestCreep then
        shouldRetreat = true
    elseif closestDist >= driftHard then
        shouldRetreat = true
    elseif prevDist and closestDist >= driftStart and closestDist > (prevDist + driftDelta) then
        shouldRetreat = true
    end
    if not shouldRetreat then return false end
    -- NEVER burn our 300s team Glyph just to step out of enemy T1 range (`9070559899.dem` `08:07.4` `tk=17580` Fix:
    -- `creep 2239` crossed `706.8u >= 700u` while SF stood at `833.9u` = `34u` inside `868u` outer edge and wasted Glyph!).
    local safeLoc = H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
    H.BeginForcedRetreat(bot, safeLoc, 0.90)
    return true
end

-- True when a single right-click from `bot` kills `enemyHero` right now WITHOUT walking (`<= atkRange + 25`)
-- while respecting enemy T1 dive safety (`9070149539.dem` `05:05` `tk=12312` & `tk=12340` 1-Hit Execution Fix!).
function H.CanSafeInRangeOneShot(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) or not enemyHero:IsAlive() then return false, 9999 end
    if not U.CanOneShotEnemyHero(bot, enemyHero) then return false, 9999 end
    local eLoc = enemyHero:GetLocation()
    local dist = GetUnitToLocationDistance(bot, eLoc)
    local atkRange = (bot:GetAttackRange() or 525) + 25
    if dist > atkRange then return false, dist end
    local myHp = bot:GetHealth() or 0
    local aggroRad = (C.TOWER and C.TOWER.AGGRO_RADIUS) or 868
    for _, tw in pairs(enemyTowers or {}) do
        if tw and tw:IsAlive() then
            if LN.IsBeyondTower(bot, tw, eLoc) then
                return false, dist
            end
            if GetUnitToLocationDistance(tw, eLoc) < (aggroRad - 525)
                and not H._hasTankCreepUnderTower(tw, allyCreeps) and myHp < 280 then
                return false, dist
            end
        end
    end
    if H.IsBotUnderEnemyT1(bot, enemyTowers) then
        if H.TowerBurnActive() or myHp < (bot:GetMaxHealth() or 600) * 0.40 or myHp < 300 then
            return false, dist
        end
    end
    return true, dist
end

-- Detects whether stepping from `botLoc` to `stepLoc` runs into unpassable terrain or a tree trunk (`<= 58u`),
-- which caused Source 2 C++ navmesh in `9070149539.dem` (`tk=12322..12348`) to detour SF `110 deg` SW around
-- the Dire T1 tree grove (`yaw=242..247 deg`), stalling `angleDiff` at `18..22 deg` and never firing `Raze3`!
function H.IsStepBlockedByTerrainOrTrees(bot, botLoc, stepLoc)
    if type(IsLocationPassable) == "function" then
        local okP, pass = pcall(IsLocationPassable, stepLoc)
        if okP and pass == false then return true end
    end
    if bot and bot.GetNearbyTrees and type(GetTreeLocation) == "function" then
        local okT, trees = pcall(bot.GetNearbyTrees, bot, 130)
        if okT and type(trees) == "table" then
            local seg = stepLoc - botLoc
            local segLen = seg:Length2D()
            local segDir = (segLen > 0.001) and (seg * (1.0 / segLen)) or Vector(1, 0, 0)
            local minProj = math.min(14, segLen)
            for _, tr in ipairs(trees) do
                local okL, tLoc = pcall(GetTreeLocation, tr)
                if okL and tLoc then
                    local rel = tLoc - botLoc
                    local dStart = rel:Length2D()
                    local proj = math.max(minProj, math.min(segLen, rel.x * segDir.x + rel.y * segDir.y))
                    local closest = botLoc + segDir * proj
                    local dSeg = U.DistanceBetweenLocations(tLoc, closest)
                    local dEnd = U.DistanceBetweenLocations(tLoc, stepLoc)
                    if (dEnd <= 58 and dEnd < dStart + 4) or (dSeg <= 56 and dEnd < dStart - 4) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- Finds a passable, tree-free micro-step to turn SF toward `dir` without C++ navmesh tree-avoidance detours.
function H.ComputeTreeSafeTurnStep(bot, botLoc, dir, maxDist)
    local cap = math.max(18, maxDist or 999)
    for _, stepDist in ipairs({ 48, 28, 72, 18 }) do
        if stepDist <= cap + 1 then
            local cand = botLoc + dir * stepDist
            if not H.IsStepBlockedByTerrainOrTrees(bot, botLoc, cand) then
                return cand, false
            end
        end
    end
    for _, degOff in ipairs({ -8, 8, -16, 16, -28, 28, -42, 42 }) do
        local rad = math.rad(degOff)
        local c, sn = math.cos(rad), math.sin(rad)
        local rDir = Vector(dir.x * c - dir.y * sn, dir.x * sn + dir.y * c, 0)
        for _, stepDist in ipairs({ 48, 32 }) do
            local cand = botLoc + rDir * stepDist
            if not H.IsStepBlockedByTerrainOrTrees(bot, botLoc, cand) then
                return cand, true
            end
        end
    end
    return botLoc + dir * 20, true
end

-- Home-biased & obstacle-steered step-out target for `reverseFarUntil` (`9070149539.dem` Death #1 `tk=9622..9742` Fix:
-- blends radial `away` with `toHome` toward own Mid T1 so SF retreats up the wide mid ramp toward T1 protection
-- instead of backing NW into the top-river dead-end cliff `(-192.6, 706.9)`!).
function H.ComputeSafeFarRazeStepBack(bot, enemyHero, targetDist)
    local bLoc = bot:GetLocation()
    local eLoc = enemyHero:GetLocation()
    local away = (bLoc - eLoc)
    if away:Length2D() < 1 then
        away = (P.GetFountain(bot) - bLoc)
    end
    away = away:Normalized()
    local homeAnchor = (P and P.GetT1Close and P.GetT1Close(bot)) or P.GetFountain(bot)
    local toHomeVec = homeAnchor - bLoc
    local stepDir = away
    if toHomeVec:Length2D() > 35 then
        local toHome = toHomeVec:Normalized()
        local dotHome = away.x * toHome.x + away.y * toHome.y
        if dotHome > -0.20 then
            local blended = away * 0.62 + toHome * 0.38
            if blended:Length2D() > 0.01 then
                stepDir = blended:Normalized()
            end
        end
    end
    local wantDist = targetDist or 555
    local rawTarget = eLoc + stepDir * wantDist
    if U.DistanceBetweenLocations(rawTarget, eLoc) < 520 then
        rawTarget = eLoc + away * wantDist
    end
    return U.SteerAroundObstacles(bot, rawTarget, W and W.s or nil)
end

function H.HandleGuaranteedAttackKill(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    -- `v7.9.29-pro` Fadeaway Lethal-In-Air Tower Peel (`auto-20261108-2131` `04:11` Zero-Tower-Hit Execution):
    -- Once a `0%`-miss lethal right-click projectile from `bot` is ALREADY in flight toward `enemyHero` near `enemyTowers`,
    -- peel outside `920u` immediately instead of keeping `Action_AttackUnit` active and walking inside `870u` tower range!
    local bLocG = bot:GetLocation()
    local eLocG = enemyHero:GetLocation()
    if bLocG and eLocG and ((bLocG.z or 0) + 25 >= (eLocG.z or 0)) then
        local inAirG = (U.GetOwnInFlightDamageOnHero and U.GetOwnInFlightDamageOnHero(bot, enemyHero)) or 0
        if inAirG >= (enemyHero:GetHealth() or 9999) + 3 then
            for _, twG in pairs(enemyTowers or {}) do
                if twG and twG:IsAlive() then
                    local twLocG = twG:GetLocation()
                    if twLocG and U.DistanceBetweenLocations(bLocG, twLocG) <= 975 then
                        local peelDirG = (bLocG - twLocG):Normalized()
                        bot:Action_MoveToLocation(twLocG + peelDirG * 925)
                        State.actionTaken = true
                        return true
                    end
                end
            end
        end
    end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if not canOneShot then return false end
    local eLoc = enemyHero:GetLocation()
    local dist = GetUnitToLocationDistance(bot, eLoc)
    local enDry = (U.GetPotentialManaForRaze(enemyHero) or 0) < 75
    local myHp = bot:GetHealth() or 0
    -- `v7.9.7-pro` + `v7.9.8-pro` (`1630 @ 01:32.6..01:36.2` `3–28 HP` Escape at `156 HP` vs Unused Mango Fix!):
    -- Remove arbitrary `myHp >= 320` gate: at L1–L2 (`156 HP` vs `65` single-raze burst), surviving `burst + 65 HP`
    -- while 1 right-click kills `enemyHero` (`3–28 HP`) is 100% lethal-safe! Extend direct `Action_AttackUnit` reach to
    -- `+250u` (`~775u`) AND keep pressuring in the open river (`>= 1,060u` outside Enemy T1) even at `305 vs 305 MS`
    -- so the instant the crippled enemy stops/turns (`01:34.80`), SF executes immediately instead of orbiting at `700u`!
    local tankSafeOneShot = (myHp >= K.EnemyBurstVs(bot, enemyHero, math.min(dist, 500), 1.15, false) + 8)
    local extraOneShotReach = (enDry and myHp >= 85) and 435 or (tankSafeOneShot and 250 or 80)
    local attackRange = bot:GetAttackRange() + extraOneShotReach
    -- Hitting a hero inside his T1 radius draws the tower onto us: only with an HP margin
    local underT1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    local enemyDeepUnderHisT1 = false
    local minEnemyToHisTower = 9999
    local aggroRad = (C.TOWER and C.TOWER.AGGRO_RADIUS) or 868
    for _, tw in pairs(enemyTowers or {}) do
        if tw and tw:IsAlive() then
            local dEnTw = GetUnitToLocationDistance(tw, eLoc)
            if dEnTw < minEnemyToHisTower then minEnemyToHisTower = dEnTw end
            if LN.IsBeyondTower(bot, tw, eLoc) then
                enemyDeepUnderHisT1 = true
                break
            end
            if dEnTw < (aggroRad - 525) and not H._hasTankCreepUnderTower(tw, allyCreeps) and myHp < 280 then
                enemyDeepUnderHisT1 = true
                break
            end
        end
    end
    if enemyDeepUnderHisT1 then return false end
    if underT1 then
        local t1Ref = H.GetEnemyT1Tower(enemyTowers)
        local shieldedOutside500 = t1Ref and GetUnitToLocationDistance(bot, t1Ref:GetLocation()) >= 575
            and LN.HasFirmTowerCreepShield and LN.HasFirmTowerCreepShield(t1Ref:GetLocation(), t1Ref, allyCreeps, bot:GetLocation(), 230)
            and myHp >= 210
        if H.TowerBurnActive() or (not shieldedOutside500 and (myHp < bot:GetMaxHealth() * 0.40 or myHp < 300)) then return false end
    end
    -- `v7.9.1` Kinematic Pursuit & Unshielded Enemy-T1 Dive Gate (`9071946472.dem` `02:39.2–02:42.9` Fix!)
    -- + `v7.9.18` (`9079381960.dem` `02:09.1..02:12.1` `38–46 HP` 1-Hit Escape Fix: `855u` enemy is hit from `>= 900u`!):
    local openRiverOneShotPress = (enDry or tankSafeOneShot)
        and dist <= ((bot:GetAttackRange() or 500) + 250)
        and minEnemyToHisTower >= 855
        and not underT1
    if not openRiverOneShotPress
        and not H.CanKinematicallyCatchForAttack(bot, enemyHero, enemyTowers, allyCreeps, 1.65) then
        return false
    end
    if dist <= attackRange then
        -- `W3a 04:00.7` (71 HP / 21 MP) & `W4 06:25.5` (15 HP / 63 MP) Fix:
        -- Issue direct `Action_AttackUnit` out to `960u` against a 1-hit OOM enemy WITHOUT routing through
        -- `ApproachEnemyPoint` -> `StackLeadStepSafe` / `ClampMinDistFromEnemy`, which aborted guaranteed kills!
        State.reverseFarUntil = 0
        H.ClearForcedRetreat()
        State.fleeUntil = 0
        State.survivalUntil = 0
        State.survivalLoc = nil
        State.commitKillUntil = GameTime() + 2.5
        if not (U.IsAttackingAction(bot) and bot:GetAttackTarget() == enemyHero) then
            bot:Action_AttackUnit(enemyHero, true)
            H.ClearMoveCache()
        end
        State.heroAttackTarget = enemyHero
        State.heroAttackTime = GameTime()
        State.lastHarassTime = GameTime()
        State.lastAggroTime = GameTime()
        State.aggroPullTime = GameTime() + 0.25
        State.actionTaken = true
        return true
    end
    if dist <= attackRange + 240 then
        local botLoc = bot:GetLocation()
        local dir = (eLoc - botLoc):Normalized()
        local approachLoc = botLoc + dir * math.min(dist - attackRange + 25, 250)
        if H.ApproachEnemyPoint(bot, enemyHero, approachLoc, 35, enemyTowers, allyCreeps) then
            return true
        end
    end
    return false
end

function H.HandleGuaranteedRazeKill(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local dNowRazeKill = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local inRangeOneShot = H.CanSafeInRangeOneShot(bot, enemyHero, enemyTowers, allyCreeps)
    local canKill, razeLabel = U.CanQuickTurnKillWithRaze(bot, enemyHero)

    -- CRITICAL (`9070149539.dem` Death #1 `tk=9652..9700` & Death #2 `tk=12312` Fix!):
    -- Immediately release `reverseFarUntil` the instant `inRangeOneShot` is true (never run away from a 1-hit kill!)
    -- OR `canKill` (`CanQuickTurnKillWithRaze`) is ALREADY true at `d >= 490u` (never keep sprinting to `565-575u`
    -- while already inside lethal `Shadowraze3` at `497..559u`!).
    if inRangeOneShot or canKill or dNowRazeKill >= 535 then
        State.reverseFarUntil = 0
    end

    -- In-Range 1-Hit Right-Click Precedence (`9070149539.dem` Death #2 `tk=12312` `26 HP` @ `507.5u` & `tk=12340` `31 HP` @ `515u`):
    -- When 1 auto-attack kills `enemyHero` right now (`d <= 550u`):
    --   * If `not canKill`, yield immediately to `HandleGuaranteedAttackKill` (`0` step-back!).
    --   * If we are already winding up our lethal right-click, OR our attack CD is ready (`<= 0.12s`) while low HP/mana
    --     (`hp <= 140` or `mana < 135`), yield to `HandleGuaranteedAttackKill` (`0` mana cost, `0` tree navmesh detour!).
    if inRangeOneShot then
        if not canKill then
            return false
        end
        if U.IsAttackingAction(bot) and bot:GetAttackTarget() == enemyHero then
            return false
        end
        local remAtkCd = math.max(0, ((bot:GetSecondsPerAttack() or 1.35) * 0.92) - (GameTime() - (bot:GetLastAttackTime() or -100)))
        if remAtkCd <= 0.12 and ((bot:GetHealth() or 0) <= 140 or (bot:GetMana() or 0) < 135) then
            return false
        end
    end

    if GameTime() < (State.reverseFarUntil or -1000) and dNowRazeKill < 535 then
        local stepBackLoc = H.ComputeSafeFarRazeStepBack(bot, enemyHero, 555)
        bot:Action_MoveToLocation(stepBackLoc)
        H.ClearMoveCache()
        State.actionTaken = true
        State.commitKillUntil = GameTime() + 2.0
        return true
    end

    if not canKill then
        -- Immortal Reverse Step-Back Far-Coil Finish (`Q -> W -> step-back E` at `200..495u`, PLUS `W6 07:59.0` 2-stack
        -- close Treads-disadvantage kite where `E` deals >= 62% of remaining enemy HP while `Q`/`W` are on CD!):
        local eAb = bot:GetAbilityByName("nevermore_shadowraze3")
        local qAb = bot:GetAbilityByName("nevermore_shadowraze1")
        local wAb = bot:GetAbilityByName("nevermore_shadowraze2")
        local qwOnCd = (not qAb or not qAb:IsCooldownReady()) and (not wAb or not wAb:IsCooldownReady())
        local enSt, enRem = U.GetShadowrazeDebuff(enemyHero)
        local nextRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
        local enHpNow = enemyHero:GetHealth() or 9999
        local stackedStepBack = qwOnCd and (enSt or 0) >= 2 and (enRem or 0) >= 1.85
            and nextRazeDmg >= enHpNow * 0.62
            and K.AttackDamageVs(enemyHero, bot) >= K.AttackDamageVs(bot, enemyHero) - 4
        if eAb and eAb:GetLevel() > 0 and eAb:IsCooldownReady()
            and (bot:GetMana() + U.GetMangoMana(bot) + U.GetStickCharges(bot) * 15) >= 75
            and not bot:IsSilenced() and dNowRazeKill >= 200 and dNowRazeKill < 495
            and (nextRazeDmg >= enHpNow or stackedStepBack) then
            State.reverseFarUntil = GameTime() + 1.05
            local stepBackLoc = H.ComputeSafeFarRazeStepBack(bot, enemyHero, 555)
            bot:Action_MoveToLocation(stepBackLoc)
            H.ClearMoveCache()
            State.actionTaken = true
            State.commitKillUntil = GameTime() + 2.0
            return true
        end
        return false
    end
    -- Do not cancel the swing of an attack that kills him anyway
    if H.IsHeroAttackWindupLocked(bot) then
        local oneShot = U.CanOneShotEnemyHero(bot, enemyHero)
        if oneShot then return false end
    end
    -- Pop Mango / Magic Stick immediately when lethal raze needs instant burst mana (`BAR 5:09` 27 MP + Mango vs 108 HP!)
    if (bot:GetMana() or 0) < 75 then
        if H.TryUseBurstManaItem(bot, true) then
            State.commitKillUntil = GameTime() + 2.5
            return true
        end
        return false
    end
    local ability = H.GetRazeAbilityByLabel(bot, razeLabel)
    if ability then
        local predLoc = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
        local angleDiff = U.GetAngleDifference(bot, predLoc)
        if angleDiff <= C.RAZE.MAX_ANGLE_TO_CAST then
            bot:Action_UseAbility(ability)
            H.StartRazeCast(ability, enemyHero, predLoc, C.RAZE.HIT_RADIUS)
            H.ClearMoveCache()
            -- "Finish" commitment: for the next seconds we do not run or twitch
            State.commitKillUntil = GameTime() + 2.5
            return true
        else
            local botLoc = bot:GetLocation()
            local dir = (predLoc - botLoc):Normalized()
            local stepLoc, blockedAhead = H.ComputeTreeSafeTurnStep(bot, botLoc, dir, U.DistanceBetweenLocations(botLoc, predLoc))
            -- Engine-Exact In-Place Turn (`9070149539.dem` `tk=12322..12348` Tree-Grove & `<515u` Inner-Edge Fix!):
            -- Inside `GetAttackRange()` (`<= 525u`), `Action_AttackUnit(enemyHero, true)` rotates SF at full `0.9` turn rate
            -- (`51.6 deg/tick`, `180 deg` in `3` ticks) with ZERO `(x, y)` displacement — so SF NEVER walks into adjacent
            -- trees (no C++ navmesh `110 deg` SW detour!) and NEVER steps `< 495u` inside `Shadowraze3`'s inner deadzone!
            if dNowRazeKill <= (bot:GetAttackRange() or 525)
                and (razeLabel == "far" or blockedAhead)
                and not H.IsBotUnderEnemyT1(bot, enemyTowers) then
                bot:Action_AttackUnit(enemyHero, true)
                H.ClearMoveCache()
                State.actionTaken = true
                State.commitKillUntil = GameTime() + 2.5
                return true
            end
            if inRangeOneShot and blockedAhead then
                return false
            end
            bot:Action_MoveToLocation(stepLoc)
            H.ClearMoveCache()
            State.actionTaken = true
            State.commitKillUntil = GameTime() + 2.5
            return true
        end
    end
    return false
end

function H.HandleRetaliationAttack(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local enemyIsHittingUs = false
    if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then
        enemyIsHittingUs = true
    end
    if not enemyIsHittingUs and bot.WasRecentlyDamagedByHero then
        enemyIsHittingUs = bot:WasRecentlyDamagedByHero(enemyHero, 1.5)
    end

    if not enemyIsHittingUs then return false end

    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local R = K._race

    -- I am weaker (level/souls/items/HP): the right-click trade is lost beforehand. Do not answer
    -- without support (my creeps/tower hitting him) - leave his attack radius toward our own
    -- creeps/tower. Chasing us while attacking, he loses distance (each attack = 0.5 s standing still)
    -- and his attack on a hero draws aggro from my creeps.
    if State.defensive and not H.HasTradeSupport(R) and not (R and R.valid and R.canKillSoon) then
        local enRange = (enemyHero:GetAttackRange() or 525) + ((C.DEFENSE and C.DEFENSE.KITE_PAD) or 140)
        if dist <= enRange then
            local botLoc = bot:GetLocation()
            local eLoc = enemyHero:GetLocation()
            local away = botLoc - eLoc
            if dist < 1 then away = P.GetT1Close(bot) - botLoc end
            away = away:Normalized()
            local toHome = (P.GetT1Close(bot) - botLoc):Normalized()
            local need = (enRange - dist) + 80
            local target = botLoc + (away * 0.6 + toHome * 0.4):Normalized() * need
            target = H.GetSafeApproach(bot, target, enemyTowers, allyCreeps)
            H.SmartMove(bot, target, 60)
            State.actionTaken = true
            return true
        end
        return false
    end

    if dist > bot:GetAttackRange() + 50 then return false end

    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    if myHpPct < 0.25 then return false end

    if not H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then return false end

    if not H.IssueHeroAttack(bot, enemyHero) then return false end
    State.lastHarassTime = GameTime()
    State.lastAggroTime = GameTime()
    State.aggroPullTime = GameTime() + 0.25
    return true
end


-- Raze dodging (any band), sticky tango, zoning, pushing, intents

-- Dodge: the enemy is in a raze cast phase and we are inside his circle -> leave the circle directly
-- (pathfinding movement) if we make it in time; otherwise counter-raze (trade) if his raze is not lethal.
function H.HandleEnemyRazeDodge(bot, enemyHero)
    local now = GameTime()
    local R_hero = (C.RAZE and C.RAZE.HERO_EFF_RADIUS) or 274
    -- Enemy `nevermore_requiem` `1.67s` self-root cast reaction (`v7.9.7-pro`: `0307 @ 10:03.5` `act=1515` Fix!):
    --   A) If a ready Shadowraze (`mana >= 75`) 1-shot KILLS the rooted enemy BEFORE `reqRem` finishes (`cancelling Requiem
    --      with 0 damage & 0 Fear!`), either fire immediately in place OR step straight into safe band range (`615u` for `W`)!
    --   B) Else if `reqRem >= 0.70s` and `dReq >= 680u`, fire any centered long-range `E`/`W` coil that hits right now!
    --   C) Otherwise (`non-lethal Requiem`), sprint outward to `965u` (`NOT 585u`, where `700u` lines still hit & Fear into free `E`!)!
    if enemyHero and U.CanQuery(enemyHero) and K.EnemyRequiemPhase then
        local reqInPhase, _, reqRem = K.EnemyRequiemPhase()
        if reqInPhase and reqRem > 0.12 then
            local bLocReq = bot:GetLocation()
            local eLocReq = enemyHero:GetLocation()
            local dReq = U.DistanceBetweenLocations(bLocReq, eLocReq)
            local fntReq = P.GetFountain(bot)
            local outDir = (dReq > 5) and (bLocReq - eLocReq):Normalized() or (fntReq - eLocReq):Normalized()
            local enHpReq = enemyHero:GetHealth() or 9999
            local oneRazeReq = K.MyRazeDamage(bot, enemyHero, 1)
            local canOneRazeKillReq = ((bot:GetMana() or 0) >= 75) and (not bot:IsSilenced()) and (enHpReq <= oneRazeReq)

            -- Keep an already-valid in-flight lethal raze finishing before Requiem lands!
            if bot:IsUsingAbility() and State.aimingRaze and canOneRazeKillReq and reqRem >= 0.18 then
                return false
            end

            if (bot:GetMana() or 0) >= 75 and not bot:IsSilenced() and not bot:IsUsingAbility() then
                -- A1 / B: Fire immediately if a ready raze hits the rooted enemy right now and finishes before Requiem!
                if (canOneRazeKillReq and reqRem >= C.RAZE.CAST_POINT + 0.04)
                    or (dReq >= 680 and reqRem >= C.RAZE.CAST_POINT + 0.14) then
                    for _, rLabel in ipairs(H.BestCenteredRazeOrder(bot, enemyHero)) do
                        local rAb = H.GetRazeAbilityByLabel(bot, rLabel)
                        if rAb and U.IsRazeAbilityCastable(bot, rAb) then
                            local actT, aimL = H.GetRazeActionType(bot, rAb, enemyHero)
                            if actT and H.CastOrTurnRaze(bot, rAb, actT, aimL, enemyHero) then
                                return true
                            end
                        end
                    end
                end
                -- A2: Step inward to execute `210 HP` frozen Requiem caster (`0307 @ 10:03.6`: `dReq=764u -> 615u` for `W`!)
                if canOneRazeKillReq then
                    local myMSReq = math.max(280, (bot.GetCurrentMovementSpeed and bot:GetCurrentMovementSpeed()) or 305)
                    local bandTargets = {
                        { label = "far",  holdDist = 855, maxHitDist = 900 },
                        { label = "mid",  holdDist = 610, maxHitDist = 660 },
                        { label = "near", holdDist = 345, maxHitDist = 400 },
                    }
                    for _, bt in ipairs(bandTargets) do
                        local rAb = H.GetRazeAbilityByLabel(bot, bt.label)
                        if rAb and U.IsRazeAbilityCastable(bot, rAb) and dReq > bt.maxHitDist then
                            local tWalk = (dReq - bt.maxHitDist + 25) / myMSReq
                            if tWalk + C.RAZE.CAST_POINT + 0.10 <= reqRem then
                                local stepIn = eLocReq + outDir * bt.holdDist
                                local safeTower = true
                                local enT1Req = W and W.s and W.s.enemyT1
                                if enT1Req and U.CanQuery(enT1Req) and enT1Req:IsAlive()
                                    and U.DistanceBetweenLocations(stepIn, enT1Req:GetLocation()) < 880
                                    and (bot:GetHealth() or 0) < 380 then
                                    safeTower = false
                                end
                                if safeTower then
                                    if bot.Action_MoveDirectly then bot:Action_MoveDirectly(stepIn) else bot:Action_MoveToLocation(stepIn) end
                                    State.lastMoveLoc = stepIn
                                    State.lastMoveTime = now
                                    State.actionTaken = true
                                    return true
                                end
                            end
                        end
                    end
                end
            end

            -- C: Non-lethal Requiem -> escape outward to `965u` (`strictly outside dangerous multi-line + Fear zone!`)
            if dReq < 925 then
                if bot:IsUsingAbility() and (dReq <= 760 or reqRem <= 0.62) then
                    bot:Action_ClearActions(true)
                    H.ClearRazeState()
                end
                local toFntDir = (fntReq - eLocReq):Normalized()
                local safeOutDir = (outDir + toFntDir * 0.35):Normalized()
                local escReq = eLocReq + safeOutDir * 965
                if bot.Action_MoveDirectly then bot:Action_MoveDirectly(escReq) else bot:Action_MoveToLocation(escReq) end
                State.lastMoveLoc = escReq
                State.lastMoveTime = now
                State.actionTaken = true
                return true
            end
        end
    end

    local label, elapsed, remaining = K.EnemyPhase()
    if State.dodgeLoc and now < State.dodgeUntil then
        -- While dodging we keep watching his cast: he may CANCEL the raze
        -- (we left the circle) and immediately cast another band - previously we blindly ran for 0.6 s toward
        -- the old point and took a new raze at point blank ("dodges slowly").
        local E = K._enemy
        local newCast = label and (label ~= State.dodgeLabel
            or math.abs((E.phaseStart or -1) - (State.dodgePhaseStart or -2)) > 0.01)
        local cancelled = (not label) and (now - (State.dodgePhaseStart or -10)) < (C.RAZE.CAST_POINT - 0.05)
        if newCast then
            State.dodgeLoc = nil -- Re-evaluated below
        elseif cancelled then
            State.dodgeLoc = nil
            State.dodgeUntil = 0
            return false
        elseif label and enemyHero and U.CanQuery(enemyHero) then
            local liveCenter = (K.EnemyThreatRazeCenter and K.EnemyThreatRazeCenter(bot, enemyHero, label))
                or K.EnemyRazeCenter(enemyHero, label)
            local bLocNow = bot:GetLocation()
            local dNowLive = U.DistanceBetweenLocations(bLocNow, liveCenter)
            local minStickyR = 282
            if dNowLive > R_hero + 64 then
                State.dodgeLoc = nil
                State.dodgeUntil = 0
                return false
            elseif U.DistanceBetweenLocations(State.dodgeLoc, liveCenter) < minStickyR then
                -- `v7.9.19` (`9080125239.dem` Sticky-Wipe Fix!):
                -- NEVER `return false` when `State.dodgeLoc` falls inside `liveCenter` while `bLocNow` is STILL inside
                -- the raze! Clear `State.dodgeLoc = nil` and fall through immediately to recompute a fresh escape ray!
                State.dodgeLoc = nil
            else
                local radOutSticky = (dNowLive > 1.0) and ((bLocNow - liveCenter):Normalized()) or nil
                local safeSticky = U.EnsurePassable(bot, State.dodgeLoc, radOutSticky)
                local sameHeightSticky = (type(GetHeightLevel) ~= "function")
                    or ((GetHeightLevel(safeSticky) or 0) == (GetHeightLevel(bLocNow) or 0))
                if sameHeightSticky and U.IsRayPassable(bLocNow, safeSticky) and bot.Action_MoveDirectly then
                    bot:Action_MoveDirectly(safeSticky)
                else
                    bot:Action_MoveToLocation(U.SteerAroundObstacles(bot, safeSticky, W.s))
                end
                State.lastMoveLoc = safeSticky
                State.lastMoveTime = now
                State.actionTaken = true
                return true
            end
        else
            State.dodgeLoc = nil
            State.dodgeUntil = 0
            return false
        end
    end
    State.dodgeLoc = nil
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not label then return false end
    local center = (K.EnemyThreatRazeCenter and K.EnemyThreatRazeCenter(bot, enemyHero, label))
        or K.EnemyRazeCenter(enemyHero, label)
    local botLoc = bot:GetLocation()
    local dFromCenter = U.DistanceBetweenLocations(botLoc, center)
    -- `v7.9.23` (`auto-20261108-0512` `00:30.90` `272.9u`, `01:18.17` `243u`, `01:31.70` `242.8u`, `02:16.90` `241.8u` Fix!):
    -- True Source 2 Shadowraze hit radius on Nevermore (`250u` raze + `24u` `m_flHullRadius`) is `274.0u` on ALL THREE bands!
    local R = R_hero
    if dFromCenter > R + 85 then return false end

    local dmg = K.EnemyRazeDamage(bot, enemyHero, 1)
    local myHp = bot:GetHealth()
    local lethal = (dmg >= myHp - 25) or (myHp <= 260)
    local ms = bot:GetCurrentMovementSpeed() or 305
    local inRealRazePhase = false
    for _, rNm in ipairs({ "nevermore_shadowraze1", "nevermore_shadowraze2", "nevermore_shadowraze3" }) do
        local rAb = bot:GetAbilityByName(rNm)
        if rAb and rAb:IsInAbilityPhase() then
            inRealRazePhase = true
            break
        end
    end
    local myPhaseElapsed = (inRealRazePhase and State.aimingStartTime and State.aimingStartTime > 0)
        and math.max(0, now - State.aimingStartTime) or 0
    local myPhaseRem = inRealRazePhase and math.max(0, C.RAZE.CAST_POINT - myPhaseElapsed) or 9.9
    local selfCasting = inRealRazePhase or bot:IsChanneling()

    -- `v7.9.19` (`9080125239.dem` `H#13..H#24` 10/20 Hits `closingForKill` False-Positive Fix!):
    -- Previously `enHpNow <= AttackDamageVs * 2.2 + myReadyRazeDmg` (`<= 450..760 HP`) evaluated `true` even at `dH = 828u`
    -- (`300u` outside right-click range!), FORBIDDING outward dodge (`postEnemyDist < curEnemyDist - 35`) and returning `false`
    -- so SF literally walked INTO `10` consecutive `W(450)`/`E(700)` coils!
    -- True `closingForKill` ONLY holds when `enemyHero` is 1 immediate fatal blow from death right now!
    local eLoc = enemyHero:GetLocation()
    local curEnemyDist = U.DistanceBetweenLocations(botLoc, eLoc)
    local enHpNow = enemyHero:GetHealth() or 9999
    local R_race0 = K._race
    local myOneAtkNow = K.AttackDamageVs(bot, enemyHero)
    local myAtkRangeNow = (bot:GetAttackRange() or 525)
    local myReadyRazeDmg = ((bot:GetMana() or 0) >= 75 and not bot:IsSilenced() and K.MyReadyRazeCount(bot, false) > 0)
        and K.MyRazeDamage(bot, enemyHero, 1) or 0
    local myStacksDodge = U.GetShadowrazeDebuff(bot) or 0
    local oneShotPhysicalNow = (curEnemyDist <= myAtkRangeNow + 35) and (enHpNow <= math.max(95, myOneAtkNow * 1.15))
    local oneCoilInstantKillNow = (myReadyRazeDmg > 0) and (curEnemyDist <= 735) and (enHpNow <= myReadyRazeDmg - 8)
        and (myHp > dmg + 265) and (myStacksDodge == 0)
    local closingForKill = (not lethal)
        and (myHp > dmg + 220)
        and not (R_race0 and R_race0.valid and (R_race0.heCanKillNow or R_race0.heCanKillSoon))
        and (oneShotPhysicalNow or oneCoilInstantKillNow)
    if closingForKill and label == "near" then
        return false
    end

    local fnt = P.GetFountain(bot)
    local homeDir = (fnt - botLoc):Normalized()
    local px, py = botLoc.x - center.x, botLoc.y - center.y
    local p2 = px * px + py * py
    local pNorm = math.sqrt(math.max(1e-6, p2))
    local radOutFromCenter = (dFromCenter > 1.0) and Vector(px / pNorm, py / pNorm, 0) or homeDir

    -- `v7.9.19` (`9080125239.dem` `H#06 @ 00:47.07` `128->54 MP` & `H#10 @ 01:38.73` `82->8 MP` Uncommitted In-Phase `75 MP` Fix!):
    -- Source 2 deducts `75 MP` at `0.55s` cast COMPLETION, NOT during `IsInAbilityPhase()`! Counting uncommitted mana made
    -- `enPotMp = 128 >= 75` mark `enQReady = true` and `enWReady = true`, blocking the `112u` inward dodge (`540 -> 425u`)
    -- when the enemy actually dropped to `54 MP` (`0` follow-up razes possible!) the instant `E(700)` finished!
    local enPotMpRaw = K.EnemyManaBudget(enemyHero, true)
    local enPotMp = math.max(0, enPotMpRaw - 75) -- Post-current-cast remaining mana!
    local myPotMp = K.MyManaBudget(bot, true)
    local enQReady = (label ~= "near") and K.EnemyRazeReady("near", 1.65) and (enPotMp >= 75)
    local enWReady = (label == "far") and K.EnemyRazeReady("mid", 1.65) and (enPotMp >= 75)
    local activelyRetreating = (State.forcedRetreatLoc ~= nil)
        or (now < (State.fleeUntil or 0) and now >= (State.commitKillUntil or 0))
        or (now < (State.critDangerHystUntil or 0))
        or (State.goingToFountain == true)
    local disadvantagedNow = activelyRetreating
        or lethal
        or ((myHp / math.max(1, bot:GetMaxHealth() or 1)) < 0.55)
        or H.IsDryVsEnemyRaze(bot, enemyHero)
        or (myPotMp < 75 and enPotMp >= 75)
        or ((myPotMp + 75 <= enPotMp) and myHp <= enHpNow + 90)
        or (#(W.s and W.s.enemyCreeps or {}) >= #(W.s and W.s.allyCreeps or {}) + 2 and myHp < enHpNow + 140)
    local forbidInwardStep = (not closingForKill) and (label ~= "near") and (disadvantagedNow or enQReady or enWReady)
    local sightLen0 = math.max(1.0, U.DistanceBetweenLocations(eLoc, center))
    local sdx0, sdy0 = (center.x - eLoc.x) / sightLen0, (center.y - eLoc.y) / sightLen0

    -- When ALREADY outside `R + 4` (`>= 278u`) and not `closingForKill`, hold/step safely outside `R + 46` (`>= 320u`)!
    -- `v7.9.23` (`auto-20261108-0512` `01:18.17` Inner-Rim Reversal Fix!):
    -- NEVER add `+ Vector(sdx0, sdy0, 0) * 50` when standing on the INNER side of `W`/`E` (`curEnemyDist < sightLen0`),
    -- which previously pushed SF `+50u` outward from `dHero = 457u` straight back INTO `E(700)` `66ms` before impact!
    if dFromCenter >= R + 4 then
        if closingForKill then return false end
        if selfCasting and not lethal then return false end
        local rawRimPt = center + radOutFromCenter * math.max(dFromCenter + 45, R + 46)
        if forbidInwardStep and U.DistanceBetweenLocations(rawRimPt, eLoc) < math.min(curEnemyDist - 10, 465) then
            local perpA = Vector(-sdy0, sdx0, 0)
            local perpB = Vector(sdy0, -sdx0, 0)
            local outFromCenterSign = (curEnemyDist >= sightLen0) and 1.0 or -1.0
            local bestRim, bestRimSc = nil, -1e9
            for _, pDir in ipairs({ perpA, perpB }) do
                local candRim = botLoc + pDir * 195 + Vector(sdx0 * outFromCenterSign, sdy0 * outFromCenterSign, 0) * 40
                if U.DistanceBetweenLocations(candRim, center) >= R + 36
                    and U.IsRayPassable(botLoc, candRim)
                    and not (W.s and W.s.enemyT1Loc and U.DistanceBetweenLocations(candRim, W.s.enemyT1Loc) < 880) then
                    local scRim = U.DistanceBetweenLocations(candRim, center) * 1.35
                        + (pDir.x * homeDir.x + pDir.y * homeDir.y) * 55.0
                    if scRim > bestRimSc then
                        bestRimSc, bestRim = scRim, candRim
                    end
                end
            end
            if bestRim then rawRimPt = bestRim end
        end
        local holdSafePt = U.EnsurePassable(bot, rawRimPt, radOutFromCenter)
        State.dodgeLoc = holdSafePt
        -- NEVER cap `State.dodgeUntil` at `0.32s` (`auto-20261107-2214` `tk=12718` `05:51.40` Fix: `0.32s` expired `7` ticks
        -- before the `0.55s` coil detonated, letting SF step `14u` back inside `E700` `66ms` before impact!):
        State.dodgeUntil = now + math.max(0.14, (remaining or 0.20) + 0.10)
        State.dodgeLabel = label
        State.dodgePhaseStart = K._enemy.phaseStart
        local sameHeightRim = (type(GetHeightLevel) ~= "function")
            or ((GetHeightLevel(holdSafePt) or 0) == (GetHeightLevel(botLoc) or 0))
        if sameHeightRim and U.IsRayPassable(botLoc, holdSafePt) and bot.Action_MoveDirectly then
            bot:Action_MoveDirectly(holdSafePt)
        else
            bot:Action_MoveToLocation(U.SteerAroundObstacles(bot, holdSafePt, W.s))
        end
        State.lastMoveLoc = holdSafePt
        State.lastMoveTime = now
        State.actionTaken = true
        return true
    end

    -- Exact 360-degree analytic ray-circle exit solver + EXACT Radial Normal (`k = -1`):
    -- Two-pass inward policy: Pass 1 prefers strictly outward/safe-pocket exits; if NO outward exit is kinematically
    -- reachable in `remaining` (`e.g. curEnemyDist = 540u vs E(700)`!), Pass 2 allows dodging laterally/inward outside
    -- armed `Q(200)` (`>= 462u`) or anywhere outside enemy T1 when `not enQReady` — dodging a 100%-certain live raze ALWAYS
    -- beats standing inside it!
    -- Pre-collect nearby lane creeps (`<= 280u`) so `SearchAnalyticEscape` penalizes/avoids creep-walled rays
    -- (`9080457787.dem` `08:58.00` `tk=19540` `W450` 3-Creep Body-Block Fix: `U.IsRayPassable` checks static navgrid
    -- ONLY, not dynamic `16..24u` creep hulls!).
    local liveBlockCreeps = {}
    if W.s then
        for _, lst in ipairs({ W.s.enemyCreeps, W.s.allyCreeps }) do
            for _, cr in pairs(lst or {}) do
                if cr and U.CanQuery(cr) and cr:IsAlive() then
                    local cL = cr:GetLocation()
                    local cdx, cdy = cL.x - botLoc.x, cL.y - botLoc.y
                    if (cdx * cdx + cdy * cdy) <= (280 * 280) then
                        liveBlockCreeps[#liveBlockCreeps + 1] = { dx = cdx, dy = cdy }
                    end
                end
            end
        end
    end

    local botFacingRad = math.rad((bot.GetFacing and bot:GetFacing()) or 0)
    local fwdUx, fwdUy = math.cos(botFacingRad), math.sin(botFacingRad)
    local bestEscapeLoc, bestScore = nil, -1e9

    local function SearchAnalyticEscape(relaxInwardVeto)
        local locBest, scBest = nil, -1e9
        for _, pad in ipairs({ 16, 8, 3 }) do
            local rSafe = R + pad
            local r2Diff = rSafe * rSafe - p2
            for k = -6, 35 do
                local ux, uy
                if k == -6 then
                    ux, uy = fwdUx, fwdUy
                elseif k == -5 then
                    ux, uy = px / pNorm, py / pNorm
                elseif k < 0 then
                    local bisOff = ((k == -4) and (math.pi * 0.25))
                        or ((k == -3) and (-math.pi * 0.25))
                        or ((k == -2) and (math.pi * 0.50))
                        or (-math.pi * 0.50)
                    local bAng = botFacingRad + bisOff
                    ux, uy = math.cos(bAng), math.sin(bAng)
                else
                    local ang = k * (2 * math.pi / 36)
                    ux, uy = math.cos(ang), math.sin(ang)
                end
                local pDotU = px * ux + py * uy
                local sExit = -pDotU + math.sqrt(math.max(0, pDotU * pDotU + r2Diff))
                local exitPt = Vector(botLoc.x + ux * (sExit + 10), botLoc.y + uy * (sExit + 10), botLoc.z)
                local cand = Vector(botLoc.x + ux * (sExit + 30), botLoc.y + uy * (sExit + 30), botLoc.z)
                local safeEnT1 = not (W.s and W.s.enemyT1Loc and U.DistanceBetweenLocations(cand, W.s.enemyT1Loc) < 860)
                if safeEnT1 and U.IsRayPassable(botLoc, cand) then
                    local creepBlocksOnRay = 0
                    local segLen = sExit + 24
                    for iCr = 1, #liveBlockCreeps do
                        local cr = liveBlockCreeps[iCr]
                        local along = cr.dx * ux + cr.dy * uy
                        if along > -12 and along < segLen then
                            local perp = math.abs(cr.dx * (-uy) + cr.dy * ux)
                            if perp < 58 then
                                creepBlocksOnRay = creepBlocksOnRay + 1
                            end
                        end
                    end
                    local turnAng = U.GetAngleDifference(bot, cand)
                    -- Realistic Source 2 Nevermore turn-deceleration model (`00:26.10` `180 deg` U-turn `0u` in `66ms` Fix!):
                    -- Rewards zero-turn forward/lateral-inward escape over slow `180 deg` turnbacks when margin is tight!
                    local turnTime = 0.033 * math.max(0, math.rad(turnAng - 16.0)) / 0.78
                    local creepDetourSec = relaxInwardVeto and (creepBlocksOnRay * 0.06) or (creepBlocksOnRay * 0.14)
                    local timeSlack = (remaining - turnTime - creepDetourSec - 0.008) - (sExit / ms)
                    if timeSlack >= 0 then
                        -- `v7.9.33-pro` (`auto-20261109-0306` `1:16.60` Rim-Exit Distance Fix!):
                        -- Evaluate `postEnemyDist` at the actual `274u` circle exit (`exitPt = sExit + 10`), NOT `+30..68u` past!
                        local postEnemyDist = U.DistanceBetweenLocations(exitPt, eLoc)
                        local violatesInwardLaw = false
                        if not closingForKill and label ~= "near" then
                            local safeInnerPocketVsFar = (label == "far") and (curEnemyDist <= 645)
                                and ((not enWReady and postEnemyDist >= (enQReady and 395 or 320))
                                    or (not enQReady and postEnemyDist <= 438 and postEnemyDist >= 265))
                            if relaxInwardVeto then
                                local minRelaxDist = (label == "far" and enQReady and not lethal) and 335 or 235
                                if postEnemyDist < minRelaxDist then
                                    violatesInwardLaw = true
                                end
                            else
                                if enQReady and curEnemyDist >= 430 and (not safeInnerPocketVsFar)
                                    and postEnemyDist < math.min(curEnemyDist - 12, 468) then
                                    violatesInwardLaw = true
                                elseif disadvantagedNow and (not safeInnerPocketVsFar) and postEnemyDist < curEnemyDist - 15 then
                                    violatesInwardLaw = true
                                elseif enWReady and curEnemyDist >= 640 and disadvantagedNow and postEnemyDist < 505 then
                                    violatesInwardLaw = true
                                end
                            end
                        end
                        if (not violatesInwardLaw) and (not closingForKill or postEnemyDist < curEnemyDist - 25) then
                            local homeAlign = ux * homeDir.x + uy * homeDir.y
                            local latFromRay = (curEnemyDist > 20)
                                and math.abs((exitPt.x - eLoc.x) * (-sdy0) + (exitPt.y - eLoc.y) * sdx0) or 0
                            local nextBandAdj = -creepBlocksOnRay * 260
                            if not closingForKill then
                                if label ~= "near" and enQReady and postEnemyDist < 468 then
                                    nextBandAdj = nextBandAdj - (safeInnerPocketVsFar and 120 or 360)
                                end
                                -- `v7.9.23` + `v7.9.33-pro`: Avoid dodging `W(450)` onto Enemy's `700u` sightline ONLY when
                                -- `timeSlack >= 0.085s` (`>= 26u` cushion); when `timeSlack < 0.085s`, pure exit speed wins!
                                local slackWeight = (timeSlack >= 0.085) and 1.0 or 0.15
                                if label ~= "far" and (enPotMp >= 75) and K.EnemyRazeReady("far", 1.25) then
                                    if math.abs(postEnemyDist - 700) <= 155 then
                                        nextBandAdj = nextBandAdj - (((latFromRay < 135) and 460 or 160) * slackWeight)
                                    end
                                    nextBandAdj = nextBandAdj + math.min(190, latFromRay * 0.90) * slackWeight
                                end
                                if label == "far" and curEnemyDist > 20 then
                                    nextBandAdj = nextBandAdj + math.min(185, latFromRay * 0.68) * slackWeight
                                end
                            end
                            -- Tight-margin survival priority (`01:31.70` `242.8u`, `01:12.53` `241.8u`, & `02:16.90` `241.8u` Fix!):
                            local survivalUrgency = (timeSlack < 0.14) and (timeSlack * 2400.0) or (180.0 + math.min(0.25, timeSlack) * 280.0)
                            local score = closingForKill
                                and (survivalUrgency - postEnemyDist - sExit * 0.45 - creepBlocksOnRay * 180)
                                or (survivalUrgency + postEnemyDist * 0.45 + homeAlign * 75 - sExit * 0.65 + nextBandAdj)
                            if score > scBest then
                                scBest = score
                                locBest = cand
                            end
                        end
                    end
                end
            end
            if locBest then return locBest, scBest end
        end
        return nil, -1e9
    end

    bestEscapeLoc, bestScore = SearchAnalyticEscape(false)
    if not bestEscapeLoc and not closingForKill and label ~= "near" then
        bestEscapeLoc, bestScore = SearchAnalyticEscape(true)
    end

    if closingForKill and not bestEscapeLoc then
        return false
    end

    -- `v7.9.33-pro` Exact Detonation-Clearance Near-Threshold Sprint Solver (`HIT#4 @ 1:12.53` & `HIT#5 @ 1:16.60` Fix!):
    --   1. Never apply `-280` `chainAdj` when `SearchAnalyticEscape` failed (`margin < 0`!) — maximizing actual distance from
    --      `center` at detonation (`dAtImpact`) beats diverting `+23.4u` onto a slower diagonal (`74.5°` vs `25.3°` at `1:12.53`)!
    --   2. Measure `postEnExit` at the true `274u` circle exit (`sExit + 10`), NOT `stepSpan = 253u` (`+68u` past the rim, which
    --      falsely rejected `180°` at `1:16.60` where `postEnExit = 443u` and Enemy `W450` was on `5.5s` cooldown!).
    if (not bestEscapeLoc) and (not closingForKill)
        and dFromCenter >= 55 and (R - dFromCenter) <= ((remaining or 0.35) * ms + 52) then
        local bestRadDir, bestRadDist = nil, -1e9
        local pxN = botLoc.x - center.x
        local pyN = botLoc.y - center.y
        local r2DiffN = R * R - (pxN * pxN + pyN * pyN)
        local farReadyNear = (label ~= "far") and (enPotMp >= 75) and K.EnemyRazeReady("far", 1.25)
        local remNear = remaining or 0.35
        for k = -2, 35 do
            local ux, uy
            if k == -2 then
                ux, uy = fwdUx, fwdUy
            elseif k == -1 then
                ux, uy = radOutFromCenter.x, radOutFromCenter.y
            else
                local ang = k * (2 * math.pi / 36)
                ux, uy = math.cos(ang), math.sin(ang)
            end
            local pDotUN = pxN * ux + pyN * uy
            local sExitN = -pDotUN + math.sqrt(math.max(0, pDotUN * pDotUN + r2DiffN))
            local exitPtN = Vector(botLoc.x + ux * (sExitN + 10), botLoc.y + uy * (sExitN + 10), botLoc.z)
            local stepSpan = math.max(210, sExitN + 36)
            local cand = Vector(botLoc.x + ux * stepSpan, botLoc.y + uy * stepSpan, botLoc.z)
            if U.IsRayPassable(botLoc, cand)
                and not (W.s and W.s.enemyT1Loc and U.DistanceBetweenLocations(cand, W.s.enemyT1Loc) < 865) then
                local postEnExit = U.DistanceBetweenLocations(exitPtN, eLoc)
                local minAllowEn = (label == "far" and not enWReady)
                    and (enQReady and 365 or 260)
                    or ((label ~= "near" and enQReady) and math.min(curEnemyDist - 15, 435) or 235)
                if postEnExit >= minAllowEn then
                    local turnNear = U.GetAngleDifference(bot, cand)
                    local turnSecN = 0.033 * math.max(0, math.rad(turnNear - 16.0)) / 0.78
                    local walkByImp = math.max(0, (remNear - turnSecN) * ms)
                    local impPt = Vector(botLoc.x + ux * walkByImp, botLoc.y + uy * walkByImp, botLoc.z)
                    local dAtImpact = U.DistanceBetweenLocations(impPt, center)
                    if dAtImpact >= dFromCenter + 65 then
                        local latNear = math.abs((exitPtN.x - eLoc.x) * (-sdy0) + (exitPtN.y - eLoc.y) * sdx0)
                        local tieBreak = (ux * homeDir.x + uy * homeDir.y) * 8.0
                        if farReadyNear and dAtImpact >= (R + 6.0) then
                            tieBreak = tieBreak + math.min(24.0, latNear * 0.15)
                        end
                        local dOut = dAtImpact * 10.0 - sExitN * 1.5 + tieBreak
                        if dOut > bestRadDist then
                            bestRadDist, bestRadDir = dOut, cand
                        end
                    end
                end
            end
        end
        bestEscapeLoc = bestRadDir
    end

    local keepMyNearlyDoneCast = selfCasting and (not lethal) and (myStacksDodge == 0)
        and (not disadvantagedNow) and (not enWReady) and (not enQReady)
        and (myPhaseRem <= (remaining or 0) + 0.05)
    if bestEscapeLoc and (not keepMyNearlyDoneCast) then
        if selfCasting or (State.aimingRaze ~= nil) or bot:IsUsingAbility() then
            bot:Action_ClearActions(true)
            H.ClearRazeState()
        end
        bestEscapeLoc = U.EnsurePassable(bot, bestEscapeLoc)
        State.dodgeLoc = bestEscapeLoc
        State.dodgeUntil = now + remaining + 0.06
        State.dodgeLabel = label
        State.dodgePhaseStart = K._enemy.phaseStart
        local sameHeightEsc = (type(GetHeightLevel) ~= "function")
            or ((GetHeightLevel(bestEscapeLoc) or 0) == (GetHeightLevel(botLoc) or 0))
        if sameHeightEsc and U.IsRayPassable(botLoc, bestEscapeLoc) and bot.Action_MoveDirectly then
            bot:Action_MoveDirectly(bestEscapeLoc)
        else
            bot:Action_MoveToLocation(U.SteerAroundObstacles(bot, bestEscapeLoc, W.s))
        end
        State.lastMoveLoc = bestEscapeLoc
        State.lastMoveTime = now
        State.actionTaken = true
        return true
    end

    -- `v7.9.19` (`9080125239.dem` `H#11 @ 02:22.40` Mirror-Coil Self-Root Fix!):
    -- NEVER self-root `0.55s` casting a Mirror-Coil inside a live enemy raze unless escape is 100% kinematically impossible
    -- (`dFromCenter + remaining * ms < R - 28`), `remaining >= 0.36s` (so our cast isn't 0.3s behind his!), AND we hold
    -- healthy HP with `0` stacks! Otherwise sprint radially out (even if enemy pump-cancels or turns slightly, moving
    -- outward maximizes survival and breaks follow-up spacing!).
    local maxPossibleReach = dFromCenter + (remaining or 0.25) * ms
    local trulyInescapableBullseye = (maxPossibleReach < R - 28) and ((remaining or 0) >= 0.36)
    local R_race = K._race
    local dHeroCast = U.DistanceBetweenLocations(botLoc, eLoc)
    local curMyStacks = U.GetShadowrazeDebuff(bot) or 0
    local outMatchedChase = ((enemyHero:GetLevel() or 1) > (bot:GetLevel() or 1))
        or (R_race and R_race.valid and (R_race.heCanKillSoon or R_race.heHasBootsLead))
    local enemyHasFollowupCoil = enWReady or enQReady
        or (label ~= "far" and (enPotMp >= 75) and K.EnemyRazeReady("far", 1.65))
    local safeFarMirror = (label == "far" and curMyStacks == 0 and not outMatchedChase and myHp > dmg + 185)
        and ((not enemyHasFollowupCoil and dHeroCast >= 680)
            or (dHeroCast >= 728 and dFromCenter <= 65))
    local unsafeCloseTrade = enemyHasFollowupCoil
        or ((myHp / math.max(1, bot:GetMaxHealth() or 1)) < 0.62)
        or (curMyStacks >= 1)
        or outMatchedChase
        or disadvantagedNow
        or (R_race and R_race.valid and R_race.losingHard)
    local unsafeToStandAndTrade = (not trulyInescapableBullseye)
        or (State.forcedRetreatLoc ~= nil)
        or (now < (State.fleeUntil or 0) and now >= (State.commitKillUntil or 0))
        or (not safeFarMirror and unsafeCloseTrade)
        or (R_race and R_race.valid and R_race.heCanKillNow)
    if not selfCasting and not lethal and not unsafeToStandAndTrade then
        if (bot:GetMana() or 0) < 75 and (K.MyReadyRazeCount(bot, false) >= 1) and H.TryUseBurstManaItem and H.TryUseBurstManaItem(bot, true) then
            return true
        end
        if (bot:GetMana() or 0) >= 75 then
            for _, lbl in ipairs(H.BestCenteredRazeOrder(bot, enemyHero)) do
                local ab = H.GetRazeAbilityByLabel(bot, lbl)
                if ab and U.IsRazeAbilityCastable(bot, ab) then
                    local actionType, aimLoc = H.GetRazeActionType(bot, ab, enemyHero)
                    if actionType and H.CastOrTurnRaze(bot, ab, actionType, aimLoc, enemyHero) then
                        return true
                    end
                end
            end
        end
    end

    -- `v7.9.19` Bullseye Escape Ray (with `dodgeLabel`/`dodgePhaseStart`, `>= R + 45` target outside sticky wipe, & cliff-safe pathing!):
    if not selfCasting then
        local farReadyBull = (label ~= "far") and (enPotMp >= 75) and K.EnemyRazeReady("far", 1.25)
        local function PickBullseyeEscapeRay(minOutGain, relaxInward)
            local bPt, bSc = nil, -1e9
            for i = 0, 23 do
                local a = i * (2.0 * math.pi / 24.0)
                local dir = Vector(math.cos(a), math.sin(a), 0)
                local span = math.max(245.0, (R + 48.0) - dFromCenter + 35.0)
                local cand = botLoc + dir * span
                local safeFromEnT1 = not (W.s and W.s.enemyT1Loc and U.DistanceBetweenLocations(cand, W.s.enemyT1Loc) < 880)
                local outGain = U.DistanceBetweenLocations(cand, center) - dFromCenter
                local postEnDist = U.DistanceBetweenLocations(cand, eLoc)
                local safeInnerBull = (label == "far") and (not enQReady) and (postEnDist <= 438 and postEnDist >= 265)
                local inwardBlocked = false
                if not closingForKill and label ~= "near" and not relaxInward then
                    if enQReady and curEnemyDist >= 420 and postEnDist < math.min(curEnemyDist - 10, 468) then
                        inwardBlocked = true
                    elseif disadvantagedNow and (not safeInnerBull) and postEnDist < curEnemyDist - 15 then
                        inwardBlocked = true
                    end
                elseif relaxInward and postEnDist < 235 then
                    inwardBlocked = true
                end
                if outGain >= minOutGain and not inwardBlocked and safeFromEnT1 and U.IsRayPassable(botLoc, cand) then
                    local latFromSight = math.abs((cand.x - eLoc.x) * (-sdy0) + (cand.y - eLoc.y) * sdx0)
                    local homeGain = dir.x * homeDir.x + dir.y * homeDir.y
                    local enDistGain = postEnDist - curEnemyDist
                    local turnBull = U.GetAngleDifference(bot, cand)
                    local chainTrapPen = 0.0
                    if farReadyBull and math.abs(postEnDist - 700.0) <= 155.0 then
                        chainTrapPen = (latFromSight < 135.0) and -420.0 or -140.0
                    end
                    local sc = outGain * 1.75 + math.min(240.0, latFromSight) * 1.05 + homeGain * 40.0
                        + enDistGain * 0.45 - turnBull * 0.55 + chainTrapPen
                    if sc > bSc then
                        bSc = sc
                        bPt = cand
                    end
                end
            end
            return bPt
        end
        local bestBullPt = PickBullseyeEscapeRay(140.0, false)
            or PickBullseyeEscapeRay(85.0, false)
            or PickBullseyeEscapeRay(85.0, true)
        local fallbackSpan = math.max(260.0, R + 52.0)
        local fallbackOut = center + radOutFromCenter * fallbackSpan
        if forbidInwardStep and U.DistanceBetweenLocations(fallbackOut, eLoc) < curEnemyDist - 10 and enQReady then
            local perp1 = Vector(-sdy0, sdx0, 0)
            local perp2 = Vector(sdy0, -sdx0, 0)
            local bestPerp = ((perp1.x * homeDir.x + perp1.y * homeDir.y) >= 0) and perp1 or perp2
            fallbackOut = center + (bestPerp * 0.88 + homeDir * 0.35):Normalized() * fallbackSpan
        end
        local stepOut = U.EnsurePassable(bot, bestBullPt or fallbackOut)
        State.dodgeLoc = stepOut
        State.dodgeUntil = now + math.max(0.14, (remaining or 0.25) + 0.10)
        State.dodgeLabel = label
        State.dodgePhaseStart = K._enemy.phaseStart
        local sameHeightBull = (type(GetHeightLevel) ~= "function")
            or ((GetHeightLevel(stepOut) or 0) == (GetHeightLevel(botLoc) or 0))
        if sameHeightBull and U.IsRayPassable(botLoc, stepOut) and bot.Action_MoveDirectly then
            bot:Action_MoveDirectly(stepOut)
        else
            bot:Action_MoveToLocation(U.SteerAroundObstacles(bot, stepOut, W.s))
        end
        State.lastMoveLoc = stepOut
        State.lastMoveTime = now
        State.actionTaken = true
        return true
    end
    return false
end

-- Sticky tango tree: pick once and keep it (COMMIT_TIME) until eaten / it became
-- dangerous / we got stuck. Filters: far from the enemy tower, not closer to the enemy, same height level.
function H.GetStickyTangoTree(bot, enemyHero, enemyTowers)
    -- Defensive C++ `HSCRIPT` userdata guard: NEVER allow `pairs(userdata)` if arguments were reversed!
    if type(enemyHero) == "table" and type(enemyHero.GetLocation) ~= "function" then
        enemyHero, enemyTowers = enemyTowers, enemyHero
    end
    local safeTowerList = (type(enemyTowers) == "table") and enemyTowers or {}
    local now = GameTime()
    local cfg = C.TANGO or {}
    local botLoc = bot:GetLocation()
    local enemyLoc = (enemyHero and U.CanQuery(enemyHero)) and enemyHero:GetLocation() or nil

    local enemyArmedMidOrFar = false
    local myStacksTango = 0
    if enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive() then
        local enPotTango = (U.GetPotentialManaForRaze and U.GetPotentialManaForRaze(enemyHero)) or (enemyHero:GetMana() or 0)
        myStacksTango = U.GetShadowrazeDebuff(bot) or 0
        if enPotTango >= 75 and (K.EnemyRazeReadyIn("mid") <= 1.6 or K.EnemyRazeReadyIn("far") <= 1.6) then
            enemyArmedMidOrFar = true
        end
    end
    local armedSafeTreeFloor = enemyArmedMidOrFar and ((myStacksTango >= 1) and 855 or 775) or ((cfg.ENEMY_MIN_DIST or 650) - 150)

    local fountain = P.GetFountain(bot)
    local allyT1Loc = (W.s and W.s.allyT1Loc) or P.GetT1Close(bot)
    local t1FntDist = allyT1Loc and U.DistanceBetweenLocations(allyT1Loc, fountain) or 6800
    local midSpine = allyT1Loc and (fountain - allyT1Loc):Normalized() or (fountain - botLoc):Normalized()
    local unshieldedCreepsChasing = false
    if W.s and #(W.s.allyCreeps or {}) == 0 and (W.s.allyT1Alive ~= false) and allyT1Loc then
        for _, ec in pairs(W.s.enemyCreeps or {}) do
            if ec and U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(botLoc, ec:GetLocation()) <= 640 then
                unshieldedCreepsChasing = true
                break
            end
        end
    end

    if State.tangoTree and State.tangoTreeLoc then
        local age = now - State.tangoChosenAt
        local d = U.DistanceBetweenLocations(botLoc, State.tangoTreeLoc)
        if d < State.tangoBestDist - 15 then
            State.tangoBestDist = d
            State.tangoProgressAt = now
        end
        local stuck = d > 165 and (now - (State.tangoProgressAt or State.tangoChosenAt)) > (cfg.STUCK_TIME or 4.0)
        local unsafe = enemyLoc and U.DistanceBetweenLocations(State.tangoTreeLoc, enemyLoc) < armedSafeTreeFloor
        -- `v7.9.30-pro` (`auto-20261109-0026` `2:33..2:48` `(1324,-355)` Off-Corridor River/Jungle Tango + 2-Creep Drag Fix!):
        -- Invalidate any sticky tree that strays `> 680u` laterally off the `allyT1 <-> fountain` mid spine OR fails to
        -- route past `allyT1` when unshielded enemy creeps are chasing us!
        local stickyOffCorridor = false
        if allyT1Loc then
            local relSt = State.tangoTreeLoc - allyT1Loc
            local latSt = math.abs(relSt.x * (-midSpine.y) + relSt.y * midSpine.x)
            local stFntD = U.DistanceBetweenLocations(State.tangoTreeLoc, fountain)
            local stT1D = U.DistanceBetweenLocations(State.tangoTreeLoc, allyT1Loc)
            if latSt > 680 or (unshieldedCreepsChasing and d > 205 and (stT1D > 680 or stFntD > t1FntDist + 140)) then
                stickyOffCorridor = true
            end
        end
        if age <= (cfg.COMMIT_TIME or 8.0) and not stuck and not unsafe and not stickyOffCorridor then
            return State.tangoTree, State.tangoTreeLoc
        end
        if stuck then
            State.tangoBadTree = State.tangoTree
            State.tangoBadTreeTime = now
        end
        State.tangoTree = nil
        State.tangoTreeLoc = nil
    end

    local trees = bot:GetNearbyTrees(math.max(cfg.SEARCH_RADIUS or 1400, 1600))
    if not trees or #trees == 0 then return nil, nil end
    local myH = nil
    local t1H = nil
    if type(GetHeightLevel) == "function" then
        myH = GetHeightLevel(botLoc)
        if allyT1Loc then t1H = GetHeightLevel(allyT1Loc) end
    end

    local best, bestLoc, bestScore = nil, nil, math.huge
    for pass = 1, 2 do
        for _, tree in ipairs(trees) do
            local bad = (State.tangoBadTree == tree) and (now - State.tangoBadTreeTime) < 20
            if not bad then
                local loc = GetTreeLocation(tree)
                local ok = true
                -- Strict Own-Side + Mid-Corridor Tango Invariant (`v3.9.0` + `v7.9.30` `2:40` River/Jungle Drag Fix):
                --   1. NEVER reject our own `allyT1` highground trees (`t1H`) in `pass == 1` just because SF currently
                --      stands in the river (`myH = 1`, which previously forced `pass == 1` to pick `(1324,-355)` down river!).
                --   2. Keep Tango trees strictly inside the Mid Lane corridor (`latSpine <= 680u`) and, when unshielded
                --      enemy creeps are chasing us (`#allyCreeps == 0`), strictly beside/behind `allyT1` (`<= 680u`) so
                --      walking to the tree strips creep aggro onto `allyT1`!
                local locFntDist = U.DistanceBetweenLocations(loc, fountain)
                local distAllyT1 = allyT1Loc and U.DistanceBetweenLocations(loc, allyT1Loc) or 0
                local dBotTree = U.DistanceBetweenLocations(botLoc, loc)
                local latSpine = 0
                if allyT1Loc then
                    local relT = loc - allyT1Loc
                    latSpine = math.abs(relT.x * (-midSpine.y) + relT.y * midSpine.x)
                end
                if locFntDist > t1FntDist + 760 then ok = false end
                if ok and allyT1Loc and distAllyT1 > 1060 then ok = false end
                if ok and allyT1Loc and latSpine > (dBotTree <= 205 and 760 or 660) then ok = false end
                if ok and unshieldedCreepsChasing and dBotTree > 205 and (distAllyT1 > 680 or locFntDist > t1FntDist + 140) then
                    ok = false
                end
                if ok then
                    for _, tower in pairs(safeTowerList) do
                        if tower:IsAlive() and GetUnitToLocationDistance(tower, loc) < (cfg.TOWER_MIN_DIST or 1125) then
                            ok = false
                            break
                        end
                    end
                end
                local baseTreeFloor = (allyT1Loc and distAllyT1 <= 720 and locFntDist <= t1FntDist + 160)
                    and 520 or (cfg.ENEMY_MIN_DIST or 650)
                local minEnTreeDist = enemyArmedMidOrFar and math.max(baseTreeFloor, armedSafeTreeFloor + 10) or baseTreeFloor
                if ok and enemyLoc and U.DistanceBetweenLocations(loc, enemyLoc) < minEnTreeDist then ok = false end
                if ok and pass == 1 and myH then
                    local hTree = GetHeightLevel(loc)
                    if hTree ~= myH and (not t1H or hTree ~= t1H) then ok = false end
                end
                if ok then
                    local score = dBotTree + locFntDist * 0.14 + latSpine * 0.45 + distAllyT1 * 0.22
                    if score < bestScore then
                        bestScore, best, bestLoc = score, tree, loc
                    end
                end
            end
        end
        if best then break end
    end
    if best then
        State.tangoTree = best
        State.tangoTreeLoc = bestLoc
        State.tangoChosenAt = now
        State.tangoBestDist = math.huge
        State.tangoProgressAt = now
    end
    return best, bestLoc
end

function H.ClearTangoState()
    State.tangoTree = nil
    State.tangoTreeLoc = nil
    State.tangoBadTree = nil
    State.tangoBadTreeTime = 0
    State.stickyTangoTree = nil
    State.lastTriedTreeId = nil
    State.lastTriedTreeAt = nil
    State.tangoCastAt = 0
end

-- Context + the intent FSM. Returns the intent.
-- "Hunt" (complaint: +400 HP against a low-HP enemy and the bot farms). Go for the kill when:
-- raze >= 2 points, absolute HP edge >= HUNT_HP_EDGE, my HP >= HUNT_MIN_HP_PCT, he is not under
-- his T1, his burst on me from mid range is not dangerous (HUNT_SAFETY_HP margin), my burst over
-- HUNT_HORIZON with an approach into the mid band (razes that come off cooldown; mana WITH mango;
-- 1-2 right clicks) covers his HP, and he is catchable. Hysteresis: while hunting the thresholds are softer.
function H.ComputeHunt(bot, s, race, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) or not race or not race.valid then return false end
    -- He is TPing back to his T1 (fresh, full) - do not fly in
    if (State.enemyTPIncomingUntil or 0) > s.now then return false end
    local cfg = C.INTENT or {}
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local razeLvl = (q and q:GetLevel()) or 0
    local earlyLowFinish = (razeLvl >= 1) and (race.enHp <= 310) and (K.EnemyManaBudget(enemyHero, true) < 150)
    if razeLvl < 2 and not earlyLowFinish then return false end
    local was = State.hunting and true or false
    local dmg, n = K.MyHuntBurst(bot, enemyHero, cfg.HUNT_HORIZON or 4.0)
    if dmg < race.enHp + (was and -20 or 10) then return false end
    local hisReady = K.EnemyReadyRazeCount(enemyHero, 1.5, true)
    local hisN = math.min(math.max(n, 1), hisReady)
    local enBurst = K.EnemyRazeDamage(bot, enemyHero, hisN)
    local myHp = race.myHp
    local cleanOverkill = (dmg >= race.enHp + 30) and ((myHp - enBurst) >= 150)
    local edgeNeed = cleanOverkill
        and (90 - (was and 45 or 0))
        or ((cfg.HUNT_HP_EDGE or 250) - (was and 60 or 0))
    if race.hpDiff < edgeNeed then return false end
    local minHpPct = (cfg.HUNT_MIN_HP_PCT or 0.40) - (was and 0.05 or 0)
    -- Bracer-invariant absolute HP allowance (`myHp >= 310` with `myHp - enBurst >= 150`) so `2x Bracer` MaxHP never blocks Hunt!
    if (myHp / math.max(1, bot:GetMaxHealth())) < minHpPct and not (cleanOverkill and myHp >= 310) then return false end
    if race.dist > ((cfg.HUNT_MAX_DIST or 1100) + (was and 150 or 0)) then return false end
    if race.heCanKillSoon then return false end
    local t1 = s and s.enemyT1
    if t1 then
        local okLoc, tLoc = pcall(t1.GetLocation, t1)
        if okLoc and tLoc and U.DistanceBetweenLocations(tLoc, enemyHero:GetLocation()) <= 760 then
            return false
        end
    end
    if enBurst >= myHp - (cfg.HUNT_SAFETY_HP or 80) then return false end
    if not K.CanCatch(bot, enemyHero, C.RAZE.MID_CENTER + 200, 2.5) then return false end
    return true
end

function H.UpdateIntent(bot, s, race)
    local ctx = IntentCtx
    local enemyHero = s.enemy
    ctx.enemy = enemyHero ~= nil
    ctx.race = race
    ctx.myHpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    ctx.myRazes = K.MyReadyRazeCount(bot, true)
    ctx.healing = U.IsActivelyHealing(bot)
    ctx.enemyDist = s.enemyDist
    ctx.enemyAbsentFor = (s and s.enemyAbsentFor) or 0
    ctx.enemyRespawningSoon = (s and s.enemyRespawnRemaining ~= nil and s.enemyRespawnRemaining <= 4.5)
        or (GameTime() < (State.freshEnemyTPArrivalUntil or -1000))
    ctx.enemyAbsent = W.EnemyAbsent((C.INTENT and C.INTENT.ENEMY_ABSENT_SEC) or 5.0)
    -- A live enemy disappeared near the lane (highground/trees/fog) - most likely he is
    -- lurking, not gone. Do not count him as "absent" before 12 s.
    if ctx.enemyAbsent and s.enemyAlive and s.enemyLastLoc and s.enemyAbsentFor < 12.0 then
        if U.DistanceBetweenLocations(s.enemyLastLoc, bot:GetLocation()) < 1400 then
            ctx.enemyAbsent = false
        end
    end
    if enemyHero then
        ctx.enemyDistToWave = LN.EnemyDistToAllyWave(enemyHero, s.allyCreeps)
    elseif s.enemyAlive ~= false and s.enemyLastLoc and (s.enemyAbsentFor or 99) <= 6.0 then
        local dBestFoW = 99999
        for _, ac in pairs(s.allyCreeps or {}) do
            if U.CanQuery(ac) and ac:IsAlive() then
                local dw = U.DistanceBetweenLocations(ac:GetLocation(), s.enemyLastLoc)
                if dw < dBestFoW then dBestFoW = dw end
            end
        end
        ctx.enemyDistToWave = dBestFoW
    else
        ctx.enemyDistToWave = 99999
    end
    ctx.enemyUnderHisTower = false
    ctx.underEnemyTower = false
    local t1 = s.enemyT1
    if t1 then
        local okLoc, tLoc = pcall(t1.GetLocation, t1)
        if okLoc and tLoc then
            if enemyHero then
                ctx.enemyUnderHisTower = U.DistanceBetweenLocations(tLoc, enemyHero:GetLocation()) <= 720
            end
            ctx.underEnemyTower = LN.TowerDanger(bot, t1, s.allyCreeps, nil) >= 2
        end
    end
    ctx.canCatch = enemyHero and K.CanCatch(bot, enemyHero, C.RAZE.FAR_CENTER, 2.0) or false
    ctx.defensive = State.defensive and not H.HasTradeSupport(race)
    ctx.waveAtMyTower = WV.AtMyTower(bot)
    ctx.waveNoPush = WV.BlockPush(bot, s)
    -- He is TPing to his T1 (channel visible / respawned after death)
    ctx.enemyTPIncoming = (State.enemyTPIncomingUntil or 0) > s.now
    ctx.enemyT1Dist = 99999
    if t1 then
        local okT1, t1Loc = pcall(t1.GetLocation, t1)
        if okT1 and t1Loc then
            ctx.enemyT1Dist = U.DistanceBetweenLocations(bot:GetLocation(), t1Loc)
        end
    end
    ctx.towerChaseBlocked = enemyHero ~= nil and State.towerChaseBlockedEnemy == enemyHero
    ctx.hunt = not ctx.towerChaseBlocked and H.ComputeHunt(bot, s, race, enemyHero)
    ctx.dominant = U.IsLaneDominant and U.IsLaneDominant(bot, s, race) or false
    ctx.deepChoke = ctx.dominant and (U.GetDeepEnemyT1ChokeSpot
        and U.GetDeepEnemyT1ChokeSpot(bot, s, race, s.allyCreeps, s.enemyCreeps) ~= nil) or false
    State.hunting = ctx.hunt
    local intent = I.Update(ctx, s.now)
    State.intent = intent
    if U.DEBUG and (s.now - State.lastIntentPrint) > 2.0 then
        State.lastIntentPrint = s.now
        print(string.format("[SF-BOT] intent=%s (%s) edge=%.0f myB=%.0f enB=%.0f dist=%.0f",
            intent, I.reason, race.valid and race.edge or 0, race.valid and race.myBurstSoon or 0,
            race.valid and race.enBurstSoon or 0, s.enemyDist))
    end
    return intent
end

-- Retreat under the RETREAT intent: get outside the enemy's ready bands toward our own T1.
-- If we are already far enough, do nothing (farming under the tower takes over).
function H.ExecuteRetreat(bot, enemyHero, race)
    -- We took the finish commitment - do not run
    if GameTime() < (State.commitKillUntil or 0) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local safeLoc = U.GetSafeDistancePosition(bot, enemyHero)
    if not safeLoc then return false end
    local hp = bot:GetHealth()
    local critical = race.valid and race.enBurstNow >= hp
    H.BeginForcedRetreat(bot, safeLoc, critical and 1.0 or 0.6)
    return true
end

-- Zoning: stand between the enemy and our wave at HOLD_DIST (outside his near band), right-click him
-- when he is in attack range; do not leave the wave; do not stand in his READY bands.
function H.ExecuteZoning(bot, enemyHero, race, allyCreeps, enemyTowers)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local deepChokeSpot = U.GetDeepEnemyT1ChokeSpot
        and U.GetDeepEnemyT1ChokeSpot(bot, W and W.s, race, allyCreeps, W and W.s and W.s.enemyCreeps) or nil
    if not enemyHero or not U.CanQuery(enemyHero) then
        if deepChokeSpot then
            local safePos = H.GetSafeApproachLoose(bot, deepChokeSpot, enemyTowers or {}, allyCreeps or {})
            if GetUnitToLocationDistance(bot, safePos) > 55 then
                return H.SmartMove(bot, safePos, 40)
            end
            State.holdPos = true
        end
        return false
    end
    local cfg = C.ZONE or {}
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    -- 0) if he is in a band I can cast and mana allows - the raze (pressure) outranks positioning
    local canPressure = H.ShouldTryRazePressure(bot, enemyHero, "AGGRESSIVE", 0)
    if canPressure and dist <= C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 20 then
        if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return true end
    end
    local isDominantZ = U.IsLaneDominant and U.IsLaneDominant(bot, nil, race) or false
    local hold = cfg.HOLD_DIST or 495
    -- Do not stand in his ready band when even; when `isDominantZ == true`, hold `495u` against an armed enemy SF
    -- (`> 474u` outside his `Shadowraze1` hull edge, yet inside our `573u` right-click & `450u` `R2`!).
    local minSafe = race.valid and race.minSafeDist or 0
    if isDominantZ then
        minSafe = (((enemyHero:GetMana() or 0) + U.GetMangoMana(enemyHero)) >= 75) and 495 or 280
    elseif H.IsDryVsEnemyRaze(bot, enemyHero) then
        minSafe = math.max(minSafe, (U.GetDrySafeStandoffDist and U.GetDrySafeStandoffDist(bot, enemyHero)) or 745)
    end
    if minSafe > hold then hold = minSafe end
    -- A right click if he is in hull-to-hull range (`525 + 45 = 570u <= 573u`) and it does not walk us into his ready band
    local attackRange = math.max(525, bot:GetAttackRange() or 525) + 45
    if not H.IsDryVsEnemyRaze(bot, enemyHero) and dist <= attackRange and dist >= minSafe - 20 then
        if H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) and not H.IsHeroAttackWindupLocked(bot) then
            if H.IssueHeroAttack(bot, enemyHero) then
                State.lastHarassTime = GameTime()
                State.lastAggroTime = GameTime()
                State.aggroPullTime = GameTime() + 0.25
                return true
            end
        end
    end
    local maxWaveOff = deepChokeSpot and 780 or (cfg.MAX_FROM_WAVE or 220)
    local pos = deepChokeSpot or LN.ZonePosition(bot, enemyHero, allyCreeps, hold, maxWaveOff)
    if not pos then return false end
    -- Stepping UP to our own wave's zoning line (or River-Wave Enemy-T1 Choke `deepChokeSpot`) is lane dominance!
    local waveCenterZ = LN.AllyWaveCenter(allyCreeps)
    local nearOurWave = (deepChokeSpot ~= nil)
        or (waveCenterZ and (U.DistanceBetweenLocations(pos, waveCenterZ) <= maxWaveOff + 45)) or false
    local dAfter = U.DistanceBetweenLocations(pos, enemyHero:GetLocation())
    if not nearOurWave and dAfter < dist - 60 and not K.CanCatch(bot, enemyHero, dAfter, 1.5) then
        return false
    end
    pos = H.GetSafeApproachLoose(bot, pos, enemyTowers or {}, allyCreeps or {})
    if GetUnitToLocationDistance(bot, pos) > 70 then
        return H.SmartMove(bot, pos, 45)
    end
    -- In place: hold the position (final positioning must not pull the bot away) but
    -- hand control over further on - items/regens must still run.
    State.holdPos = true
    return false
end

function H.HandleIncomingTeleport(bot, s)
    if bot:IsChanneling() then return false end
    local teleports = s and s.incomingEnemyTPs or {}
    if #teleports == 0 then return false end

    -- `v7.9.10-pro` (`2048 @ 04:24.93..04:27.93` `1006 HP / 204 MP` Unreacted Enemy TP -> `Q+W+E` Triple-Coil Fix!):
    -- An enemy hero channeling TP from Fountain lands with **100% HP, 100% Mana (`Q + W + E` ready = `500–850+` burst),
    -- Fountain regen buff, AND point-blank surprise at `300u`**! NEVER ignore an incoming enemy TP at `d = 301u` just because
    -- our own HP is `>= 80%` and mana is `>= 150`! Only skip evacuation if we are literally finishing off a `< 120 HP` Enemy T1
    -- (`<= 2` right-clicks) BEFORE `tp.time_remaining` completes!
    local curHp = bot:GetHealth() or 0
    local enemyT1Loc = (s and s.enemyT1Loc) or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1)
    local dEnemyT1 = enemyT1Loc and GetUnitToLocationDistance(bot, enemyT1Loc) or 9999
    local canFinishT1BeforeTP = false
    if s and s.enemyT1 and U.CanQuery(s.enemyT1) and s.enemyT1:IsAlive() and dEnemyT1 <= (bot:GetAttackRange() or 500) + 120 then
        local t1Hp = s.enemyT1:GetHealth() or 9999
        local botDmgToTower = math.max(25, (bot:GetAttackDamage() or 60) * 0.55)
        local firstTp = teleports[1]
        local remTp = (firstTp and firstTp.time_remaining) or 2.5
        if t1Hp <= botDmgToTower * 2.0 and remTp >= 1.4 and curHp >= 450 then
            canFinishT1BeforeTP = true
        end
    end

    -- Safe standoff outside ALL 3 Shadowrazes (`700 + 250 = 950u`) + walk-up buffer (`1,180u`)!
    local safeRadius = C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 230 -- 1,180u
    for _, tp in pairs(teleports) do
        State.freshEnemyTPArrivalUntil = math.max(State.freshEnemyTPArrivalUntil or 0, GameTime() + (tp.time_remaining or 3.0) + 5.5)
        local distance = GetUnitToLocationDistance(bot, tp.location)
        local nearEnemyT1 = (dEnemyT1 < 1260 and distance < 1480)
            or (s.enemyT1 and s.enemyT1:IsAlive() and GetUnitToLocationDistance(bot, s.enemyT1:GetLocation()) < 1180)
        -- `v7.9.21` (`auto-20261107-2214` `tk=8146..8204` `03:21` Uncontested `15 HP` Creep CS During Enemy TP Fix!):
        -- When the TP beacon is `>= 940u` away and still has `>= 1.15s` remaining on its channel, let SF finish any
        -- immediate 1-shot enemy creep (`hp <= myMin + 10`) already inside attack range BEFORE backing off!
        local finishingOneShotCreep = false
        if (tp.time_remaining or 0) >= 1.15 and distance >= 940 and curHp >= 280 then
            local atkR = (bot:GetAttackRange() or 525) + 30
            for _, ec in pairs((s and s.enemyCreeps) or {}) do
                if ec and U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) <= atkR then
                    local myMinTp = U.SFDamageRange(bot, ec).min
                    if (ec:GetHealth() or 9999) <= (myMinTp + 10) then
                        finishingOneShotCreep = true
                        break
                    end
                end
            end
        end
        if not canFinishT1BeforeTP and not finishingOneShotCreep and (distance < safeRadius or nearEnemyT1) then
            -- Start unlocking any Backpack `item_flask` immediately while running away during the 3.0s TP channel!
            if bot:FindItemSlot("item_flask") >= 6 and bot:FindItemSlot("item_flask") <= 8 then
                H.EnsureConsumableReady(bot, "item_flask")
            end
            local fountain = P.GetFountain(bot)
            local toFountain = (fountain - tp.location):Normalized()
            local point = tp.location + toFountain * (safeRadius + 140)
            point = H.GetSafeApproach(bot, point, s.enemyTowers, s.allyCreeps)
            if U.DistanceBetweenLocations(point, tp.location) < safeRadius then
                local away = bot:GetLocation() - tp.location
                if distance < 1 then away = toFountain end
                local dir = away:Normalized()
                for _, candDir in ipairs({ toFountain, dir, Vector(-dir.y, dir.x, 0), Vector(dir.y, -dir.x, 0) }) do
                    local candidate = H.GetSafeApproach(bot, tp.location + candDir * (safeRadius + 160), s.enemyTowers, s.allyCreeps)
                    if U.DistanceBetweenLocations(candidate, tp.location) >= safeRadius then
                        point = candidate
                        break
                    end
                end
            end
            State.noReenterEnemyT1Until = math.max(State.noReenterEnemyT1Until or 0, GameTime() + (tp.time_remaining or 2.8) + 3.2)
            State.enemyTPIncomingUntil = math.max(State.enemyTPIncomingUntil or 0, GameTime() + (tp.time_remaining or 2.8) + 2.5)
            State.prepTarget = nil
            State.lhAttackTarget = nil
            H.ClearRazeState()
            State.commitKillUntil = 0
            State.actionTaken = true
            return H.BeginForcedRetreat(bot, point, math.max(1.45, math.min(4.2, (tp.time_remaining or 2.5) + 1.25)))
        end
    end
    return false
end

-- `v7.9.30-pro` (`auto-20261109-0026` `7:35.50..7:46.20` `tk=16608..16930` Instant Enemy Buyback / FoW Respawn + Boots Pursuit Fix!):
-- In Source 2 Bot API, `GetIncomingTeleports()` returns `{}` when the enemy channels TP onto a Fog-of-War Mid T1 (`e.g. Night 800u`).
-- `world.lua` now detects the exact `IsHeroAlive(enemyPid): false -> true` Buyback / Respawn tick (`s.enemyRespawnedAt`, `s.enemyBoughtBackAt`)
-- at `0.000s` latency. Whenever the enemy just bought back or respawned (`<= 10.0s`, `100%` HP & MP + `3.0s` TP to Enemy T1):
--   1. Critically wounded (`<= 34% HP` or `<= 310 HP`) without Salve: lock `POST_KILL` Fountain recall and channel `item_tpscroll`
--      straight to Fountain (or sprint directly past `allyT1 -> Fountain` if TP is on CD / creeps hit us) BEFORE the Boots enemy crosses river!
--   2. Wounded or Boots-disadvantaged (`<= 58% HP`, or `enMS >= myMS + 20` & `<= 72% HP`, or `dEnemyT1 <= 1380u`):
--      evacuate immediately onto our Highground behind `allyT1` (`behindT1`), NEVER walking SW into `(290, 276)` to farm a lone creep!
function H.HandleEnemyBuybackAndRespawnThreat(bot, s, earlyRace)
    if bot:IsChanneling() or bot:IsUsingAbility() then return false end
    if not s or not s.enemyRespawnedAt then return false end
    local now = GameTime()
    local sinceRespawn = now - (s.enemyRespawnedAt or -100)
    if sinceRespawn < 0 or sinceRespawn > 10.0 then return false end
    if s.enemyAlive == false then return false end

    State.freshEnemyTPArrivalUntil = math.max(State.freshEnemyTPArrivalUntil or 0, s.enemyRespawnedAt + 9.5)
    local liveEnemy = (s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()) and s.enemy or nil
    if liveEnemy and (H.CanTwoHitRightClickKill(bot, liveEnemy, s) or (earlyRace and earlyRace.valid and earlyRace.canKillNow)) then
        return false
    end

    local myHp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local hpPct = myHp / maxHp
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enExpectedMS = liveEnemy and (liveEnemy:GetCurrentMovementSpeed() or 305)
        or math.max(s.enemyLastMS or 305, s.enemyHasBoots and 350 or 305)
    local bootDisadv = (enExpectedMS >= myMS + 20)
    local fountain = P.GetFountain(bot)
    local bLoc = bot:GetLocation()
    local allyT1Loc = (s.allyT1Alive ~= false and s.allyT1Loc) or P.GetT1Close(bot)
    local spine = allyT1Loc and (fountain - allyT1Loc):Normalized() or (fountain - bLoc):Normalized()
    local enemyT1Loc = s.enemyT1Loc or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1)
    local dEnemyT1 = enemyT1Loc and U.DistanceBetweenLocations(bLoc, enemyT1Loc) or 9999
    local dEnemyNow = liveEnemy and U.DistanceBetweenLocations(bLoc, liveEnemy:GetLocation()) or 9999

    -- Unlock any Backpack `item_flask` immediately at `t = 0.000s` of Buyback/Respawn!
    if bot:FindItemSlot("item_flask") >= 6 and bot:FindItemSlot("item_flask") <= 8 then
        H.EnsureConsumableReady(bot, "item_flask")
    end

    local hasSalve = U.HasItem(bot, "item_flask") or bot:HasModifier("modifier_flask_healing")
    local criticalWounded = (hpPct <= 0.34 or myHp <= 310) and not bot:HasModifier("modifier_flask_healing")
    if criticalWounded and not hasSalve then
        State.prepTarget = nil
        State.lhAttackTarget = nil
        H.ClearRazeState()
        State.commitKillUntil = 0
        State.goingToFountain = true
        State.fountainReason = "POST_KILL"
        local dFount = U.DistanceBetweenLocations(bLoc, fountain)
        local aggroCnt = (U.CountEnemyCreepsAggroedOnBot and U.CountEnemyCreepsAggroedOnBot(bot, s, State.myCreepChaseUntil)) or 0
        local safeToChannelTP = (dFount >= 2600)
            and (not liveEnemy or dEnemyNow >= 1120)
            and (dEnemyT1 >= 1320)
            and (aggroCnt == 0 or myHp >= 145 + aggroCnt * 48)
            and not H.HasEnemyProjectileIncoming(bot)
        if safeToChannelTP then
            local tp = U.GetTPScroll(bot)
            local okTp, castTp = false, false
            if tp and tp.IsFullyCastable then okTp, castTp = pcall(tp.IsFullyCastable, tp) end
            if okTp and castTp then
                bot:Action_UseAbilityOnLocation(tp, fountain)
                State.tpHomeTime = now
                State.goingToFountain = false
                State.actionTaken = true
                return true
            end
        end
        -- Route past `allyT1` if unshielded creeps are chasing us in front of `allyT1`, else sprint straight to Fountain!
        local retreatGoal = fountain
        if allyT1Loc and aggroCnt >= 1 and U.DistanceBetweenLocations(bLoc, fountain) > U.DistanceBetweenLocations(allyT1Loc, fountain) - 80 then
            retreatGoal = allyT1Loc + spine * 260
        elseif liveEnemy and dEnemyNow <= 1100 then
            State.critDangerHystUntil = math.max(State.critDangerHystUntil or 0, now + 0.85)
            if H.DisengageFromLethalTrade(bot, s, earlyRace) then
                return true
            end
        end
        State.actionTaken = true
        return H.BeginForcedRetreat(bot, retreatGoal, 0.90)
    end

    local needsHighgroundPullback = criticalWounded
        or (hpPct <= 0.56)
        or (bootDisadv and hpPct <= 0.72)
        or (dEnemyT1 <= 1380)
    if needsHighgroundPullback then
        if liveEnemy and dEnemyNow <= 1040 and (hpPct <= 0.45 or bootDisadv) then
            State.critDangerHystUntil = math.max(State.critDangerHystUntil or 0, now + 0.75)
            if H.DisengageFromLethalTrade(bot, s, earlyRace) then
                return true
            end
        end
        local safeHold = allyT1Loc and (allyT1Loc + spine * (hasSalve and 360 or 260))
            or (bLoc + (fountain - bLoc):Normalized() * 600)
        local alreadyBehindSafe = U.DistanceBetweenLocations(bLoc, fountain) <= U.DistanceBetweenLocations(safeHold, fountain) + 55
            and (not liveEnemy or dEnemyNow >= (bootDisadv and 1020 or 920))
        if not alreadyBehindSafe then
            State.prepTarget = nil
            State.lhAttackTarget = nil
            H.ClearRazeState()
            State.actionTaken = true
            return H.BeginForcedRetreat(bot, safeHold, 0.85)
        elseif hasSalve and not bot:HasModifier("modifier_flask_healing") then
            return false -- Let `HandleProactiveAndActiveSalve` pop the Salve right here behind `allyT1`!
        end
        -- Hold safe position behind `allyT1` while the freshly bought-back/respawned enemy finishes FoW TP & approaches!
        if U.IsAttackingAction(bot) and dEnemyNow > 950 and hpPct <= 0.38 then
            bot:Action_ClearActions(true)
            State.actionTaken = true
            return true
        end
    end
    return false
end

-- Post-TP Arrival Full-Combo Standoff (`R2_2044` `03:45.33..03:56.57` + `2048` `04:24` Blind Walk-to-Base TP Fix!):
-- 1) Pre-respawn (`enemyAlive == false`, `rem <= 4.0s`): pull back from `dEnemyT1 <= 1420u` unless healthy with creep vision shield.
-- 2) Long walk-to-base absence (`enemyAlive ~= false`, `enemyAbsentFor >= 22.0s`) with NO vision of `enemyT1` highground
--    (`s.enemyT1 == nil` & `shield == 0`): pull back from blind `dEnemyT1 <= 1280u` so a blind FoW TP onto T1 cannot land at `300u`!
function H.HandlePreRespawnOverextensionPullback(bot, s)
    if bot:IsChanneling() or bot:IsUsingAbility() then return false end
    if not s then return false end
    local enemyT1Loc = s.enemyT1Loc or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1)
    if not enemyT1Loc then return false end
    local dEnemyT1 = GetUnitToLocationDistance(bot, enemyT1Loc)

    local isPreRespawn = (s.enemyAlive == false) and s.enemyRespawnRemaining and s.enemyRespawnRemaining <= 4.0
    local shield = LN.TowerShieldCountLoc(enemyT1Loc, s.enemyT1, s.allyCreeps, bot:GetLocation())
    local hasT1Vision = (s.enemyT1 ~= nil and U.CanQuery(s.enemyT1)) or shield >= 1
    local isBlindLongAbsence = (s.enemyAlive ~= false) and ((s.enemyAbsentFor or 0) >= 22.0) and not hasT1Vision

    if not isPreRespawn and not isBlindLongAbsence then return false end
    local maxDangerDist = isPreRespawn and 1420 or 1280
    if dEnemyT1 > maxDangerDist then return false end

    local curHp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local hpPct = curHp / maxHp
    local healthyForSiege = (curHp >= 460 and hpPct >= 0.55)
        and not U.IsActivelyHealing(bot)
        and not U.HasItem(bot, "item_flask")
    if isPreRespawn and shield >= 1 and healthyForSiege then
        return false
    end

    local holdPad = isPreRespawn and ((s.enemyRespawnRemaining or 2.0) + 2.8) or 1.5
    State.noReenterEnemyT1Until = math.max(State.noReenterEnemyT1Until or 0, GameTime() + holdPad)
    local fnt = P.GetFountain(bot)
    local pullback = enemyT1Loc + (fnt - enemyT1Loc):Normalized() * (isPreRespawn and 1560 or 1360)
    State.prepTarget = nil
    State.lhAttackTarget = nil
    H.SmartMove(bot, pullback, 50)
    State.actionTaken = true
    return true
end

function H.HandleFreshEnemyTPArrival(bot, s, earlyRace)
    if bot:IsChanneling() or bot:IsUsingAbility() then return false end
    local now = GameTime()
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then
        if s and (s.enemyAlive == false or (s.enemyAbsentFor or 0) >= 18.0) then
            State.enemyWasDeadRecentlyUntil = now + 22.0
        end
        return false
    end
    -- Also detect hidden-trees post-respawn arrival (`90%+ HP` & `225+ MP` right after respawn) even if TP landed in deep FoW!
    if now < (State.enemyWasDeadRecentlyUntil or -1000) then
        State.enemyWasDeadRecentlyUntil = -1000
        if (enemy:GetHealth() / math.max(1, enemy:GetMaxHealth())) >= 0.88 and U.GetPotentialManaForRaze(enemy) >= 225 then
            State.freshEnemyTPArrivalUntil = math.max(State.freshEnemyTPArrivalUntil or 0, now + 5.0)
        end
    end
    if now >= (State.freshEnemyTPArrivalUntil or -1000) then return false end
    if H.CanTwoHitRightClickKill(bot, enemy, s) or (earlyRace and earlyRace.valid and earlyRace.canKillNow) then
        return false
    end
    local enHpPct = (enemy:GetHealth() or 0) / math.max(1, enemy:GetMaxHealth() or 1)
    local enPotMana = U.GetPotentialManaForRaze(enemy)
    if enHpPct < 0.72 or enPotMana < 150 then return false end

    local curHp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local hpPct = curHp / maxHp
    local myPotMana = U.GetPotentialManaForRaze(bot)
    local myReady = K.MyReadyRazeCount(bot, true)
    local myLvl = bot:GetLevel() or 1
    local enLvl = enemy:GetLevel() or 1
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    local enemyT1Loc = (s and s.enemyT1Loc) or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1)
    -- `9070869385.dem` `02:48.87–02:57.53` + `auto-20261108-0512` `01:00.57–01:05.20` Post-Kill Anti-Cowardice Fix:
    -- NEVER force a healthy (`>= 58% HP`, surviving 2 razes + auto) SF who is ALREADY off Enemy's ramp (`> 1180u` from
    -- Enemy T1, e.g. `534/692 HP` in neutral river at `01:00.57`!) to flee `1,065u` for `5.0s` and forfeit CS, denies,
    -- and defensive highground-breaker creep aggro-pulls!
    local overextendedEnemySide = enemyT1Loc and GetUnitToLocationDistance(bot, enemyT1Loc) <= 1180
    local outscaledByFreshFoe = (enLvl > myLvl) or (enMS >= myMS + 25)
        or (earlyRace and earlyRace.valid and earlyRace.heCanKillNow)
    local twoEnRaze = K.EnemyRazeDamage(bot, enemy, 2)
    local myAtk = K.AttackDamageVs(bot, enemy)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local survivesFreshEngage = (curHp >= twoEnRaze + enAtk + 85) and (hpPct >= 0.58 or curHp >= 510)
    if not overextendedEnemySide and not outscaledByFreshFoe and not U.IsActivelyHealing(bot)
        and survivesFreshEngage then
        State.freshEnemyTPArrivalUntil = 0
        return false
    end

    if bot:FindItemSlot("item_flask") >= 6 and bot:FindItemSlot("item_flask") <= 8 then
        H.EnsureConsumableReady(bot, "item_flask")
    end
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local standDist = (hpPct < 0.52 or outscaledByFreshFoe) and 980 or 865
    if d < standDist or overextendedEnemySide then
        local fnt = P.GetFountain(bot)
        local anchor = enemy:GetLocation() + (fnt - enemy:GetLocation()):Normalized() * (standDist + 65)
        State.prepTarget = nil
        State.lhAttackTarget = nil
        H.SmartMove(bot, anchor, 45)
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandleSeekAlliedWave(bot, s, race)
    State.waveScoutPoint = nil
    if #(s.allyCreeps or {}) > 0 then State.lastAlliedWaveSeen = GameTime(); return false end
    if GameTime() - (State.lastAlliedWaveSeen or -100) < 1.0 then return false end
    if State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc
        or GameTime() < (State.fleeUntil or 0) or bot:IsUsingAbility() or bot:IsChanneling()
        or U.IsActivelyHealing(bot) or bot:GetHealth() < bot:GetMaxHealth()*0.55 then return false end
    if (State.branchTango and GameTime()-State.branchTango.time<1.5)
        or State.needsTP or (GameTime()>20 and H.IsAtFountain(bot))
        or U.GetActiveItemByName(bot,"item_ward_observer")
        or (State.tangoTree and U.GetActiveItemByName(bot,"item_tango")) then return false end
    local scout = P.GetT1Close(bot, 500)
    for _, tp in pairs(s.incomingEnemyTPs or {}) do
        if GetUnitToLocationDistance(bot, tp.location) < 1300 or U.DistanceBetweenLocations(scout, tp.location) < 1300 then return false end
    end
    if s.enemyT1 and s.enemyT1:IsAlive() and GetUnitToLocationDistance(bot, s.enemyT1:GetLocation()) < 900 then return false end
    local point = scout
    if U.CanQuery(s.enemy) then
        if GetUnitToLocationDistance(s.enemy, point) < 1100 or GetUnitToLocationDistance(bot, s.enemy:GetLocation()) < 1100
            or (race and race.valid and race.heCanKillSoon) then return false end
    elseif s.enemyAlive and s.enemyLastLoc and (s.enemyAbsentFor or 0) < 5
        and U.DistanceBetweenLocations(point, s.enemyLastLoc) < 1200 then return false end
    if bot.GetIncomingTrackingProjectiles and #(bot:GetIncomingTrackingProjectiles() or {}) > 0 then return false end
    for _, creep in pairs(s.enemyCreeps or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then return false end
    end
    for _, tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(tower, point) < 900 then return false end
    end
    State.waveScoutPoint = point
    if GetUnitToLocationDistance(bot, point) > 45 then return H.SmartMove(bot, point, 30) end
    State.holdPos = true
    return false
end

function H.LaneEnemyAbsent(s)
    if s.enemyAlive == false then return true end
    if U.CanQuery(s.enemy) then return (s.enemyDist or 0) > 1800 and LN.EnemyDistToAllyWave(s.enemy, s.allyCreeps) > 1600 end
    local unseen = s.enemyAbsentFor or 0
    if unseen < 5 then return false end
    if unseen < 12 and s.enemyLastLoc and s.bot
        and U.DistanceBetweenLocations(s.enemyLastLoc, s.bot:GetLocation()) < 1400 then return false end
    return true
end

function H.PriorityPushAllowed(bot, s, race)
    if State.branchTango and GameTime()-State.branchTango.time<1.5 then return false end
    if State.needsTP or State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc or GameTime() < (State.fleeUntil or 0) then
        return false
    end
    -- Post-kill (`s.enemyAlive == false`, `HUD 09:01`!): lane creeps NEVER cancel Salve or Tango in Dota 2 7.41f,
    -- so shove the wave immediately while healing!
    if s.enemyAlive ~= false and (bot:GetHealth() < bot:GetMaxHealth()*0.5 or U.IsActivelyHealing(bot)) then
        return false
    end
    local teleports = s.incomingEnemyTPs or {}
    if #teleports == 0 and GameTime() < (State.enemyTPIncomingUntil or 0) then return false end
    for _, tp in pairs(teleports) do
        if GetUnitToLocationDistance(bot, tp.location) < 1800
            or (s.enemyT1 and GetUnitToLocationDistance(s.enemyT1, tp.location) < 1200) then return false end
    end
    if U.CanQuery(s.enemy) then
        local distance = GetUnitToLocationDistance(bot, s.enemy:GetLocation())
        if H.IsEnemyPressuring(bot, s.enemy) and distance < 1400 then return false end
        if K.HasRazeStackLead(bot,s.enemy) and K.EnemyBandsAcross(s.enemy,distance,distance,0.7)>0 then return false end
    end
    if (bot:GetHealth() / math.max(1, bot:GetMaxHealth())) < 0.28
        and #(s.allyCreeps or {}) <= 1
        and ((s.enemyT1 and U.CanQuery(s.enemyT1) and s.enemyT1:GetHealth()) or 9999) > 450 then
        return false
    end
    if H.LaneEnemyAbsent(s) then return true end
    return race and race.valid and not race.heCanKillSoon and race.edge >= (C.INTENT.PUSH_EDGE or 260)
        and s.enemyT1 ~= nil and GetUnitToLocationDistance(bot,s.enemyT1:GetLocation()) <= 1180
end

function H.HandleSiegeGlyph(bot, s, race)
    if not U.IsGlyphAvailable(bot) then return false end
    if U.ShouldUseGlyphDefensive(bot, s.allyTowers) then return U.UseGlyph(bot) end
    -- Wave-Freeze Defensive Glyph (`v7.9.0`): in 1v1 Sudden-Death T1 rules, if a heavy enemy double/catapult wave
    -- (`>= 5` creeps or `Siege + >= 3` creeps) is actively hitting our unshielded Mid T1 (`<= 1150 HP`), pop Glyph!
    local ownMidT1 = GetTower(bot:GetTeam(), TOWER_MID_1)
    if ownMidT1 and U.CanQuery(ownMidT1) and ownMidT1:IsAlive()
        and not ownMidT1:HasModifier("modifier_fountain_glyph")
        and (ownMidT1:GetHealth() or 1800) <= 1150
        and #(s and s.allyCreeps or {}) == 0 then
        local ownT1Loc = ownMidT1:GetLocation()
        local ownT1Reach = (C.BALLISTIC and C.BALLISTIC.TOWER_ATTACK_RANGE_C2C) or 870
        local enUnderT1, hasSiegeUnderT1 = 0, false
        for _, ec in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(ec:GetLocation(), ownT1Loc) <= ownT1Reach then
                enUnderT1 = enUnderT1 + 1
                if LN.IsSiege and LN.IsSiege(ec) then hasSiegeUnderT1 = true end
            end
        end
        if enUnderT1 >= 5 or (hasSiegeUnderT1 and enUnderT1 >= 3) then
            return U.UseGlyph(bot)
        end
    end
    local tower = s.enemyT1
    if not U.CanQuery(tower) or tower:HasModifier("modifier_fountain_glyph")
        or (not H.LaneEnemyAbsent(s) and not H.PriorityPushAllowed(bot, s, race))
        or GetUnitToLocationDistance(bot, tower:GetLocation()) > 1450 then return false end
    local tank = tower:GetAttackTarget()
    if not U.CanQuery(tank) or tank == bot or (tank.IsHero and tank:IsHero())
        or tank:HasModifier("modifier_fountain_glyph") then return false end
    local allied = false
    for _, c in pairs(s.allyCreeps or {}) do if c == tank then allied = true; break end end
    if not allied or GetUnitToLocationDistance(tank, tower:GetLocation()) > 900 then return false end
    local allyT1Hp = (ownMidT1 and U.CanQuery(ownMidT1) and ownMidT1:GetHealth()) or 1800
    if allyT1Hp < 850 then return false end
    local isSiegeTank = LN.IsSiege and LN.IsSiege(tank)
    local enemyTowerHp = tower:GetHealth() or 9999
    local towerLow = enemyTowerHp <= (isSiegeTank and 520 or 320)
    if not towerLow then return false end
    local hit = tank:GetActualIncomingDamage(tower:GetAttackDamage(), DAMAGE_TYPE_PHYSICAL)
    local threshold = isSiegeTank and (hit * 2.55) or (hit * 1.35)
    local imminent = tank:GetHealth() <= threshold
    for _, projectile in pairs(U.SafeGetIncomingProjectiles(tank)) do
        if projectile.caster == tower and projectile.is_attack and tank:GetHealth() <= threshold + hit * 0.65 then imminent = true end
    end
    if not imminent then return false end
    return U.UseGlyph(bot)
end

-- True geometric test whether `enemy` is behind `towerLoc` (toward Enemy T2 / Fountain) or too far to contest max-range chip.
-- `auto-20261102-0159-start-ShaNachnetsya.dem` Fix #7:
-- Previously `dist(enemy, tLoc) < dist(bot, tLoc) + 80` INVERTED whenever a low-HP enemy retreated `850..1,400u` behind
-- their own T1 toward T2 (`950 < 720 == false`!), causing SF to stop hitting an completely undefended Enemy T1!
function H.IsEnemyBehindOwnTower(bot, enemy, towerLoc)
    if not (enemy and U.CanQuery(enemy) and enemy:IsAlive() and towerLoc) then
        return true
    end
    local bLoc = bot:GetLocation()
    local eLoc = enemy:GetLocation()
    local dBotEnemy = U.DistanceBetweenLocations(bLoc, eLoc)
    if dBotEnemy >= 920 then
        return true
    end
    local pushVec = towerLoc - bLoc
    local pushLen = pushVec:Length2D()
    if pushLen < 25 then
        return dBotEnemy >= 760
    end
    local px, py = pushVec.x / pushLen, pushVec.y / pushLen
    local projBehind = (eLoc.x - towerLoc.x) * px + (eLoc.y - towerLoc.y) * py
    return projBehind >= -95 and dBotEnemy >= 680
end

function H.HandleSiegeTower(bot, race, s)
    local tower = s.enemyT1
    if not U.CanQuery(tower) or tower:HasModifier("modifier_fountain_glyph") then return false end
    local tLoc = tower:GetLocation()
    local distance = GetUnitToLocationDistance(bot, tLoc)
    local atkRange = math.max(500, (bot.GetAttackRange and bot:GetAttackRange()) or 500)
    -- Must strictly exceed `LN.TowerEscapePoint` (`1035u`, where `9055695956.dem` deadlocked forever at `dRT1 = 912u > 900u`!)
    if distance > math.max(1180, atkRange + 540) then return false end
    local nowSiege = GameTime()
    local finish = LN.IsTowerFinishable(bot, tower)
    local minCreepDistToT1 = math.huge
    local shieldCreeps, shieldHpTotal = 0, 0
    for _, ac in pairs(s.allyCreeps or {}) do
        if U.CanQuery(ac) and ac:IsAlive() then
            local dcT = U.DistanceBetweenLocations(ac:GetLocation(), tLoc)
            if dcT <= 780 then
                shieldCreeps = shieldCreeps + 1
                shieldHpTotal = shieldHpTotal + (ac:GetHealth() or 0)
                if dcT < minCreepDistToT1 then minCreepDistToT1 = dcT end
            end
        end
    end
    -- Dynamic siege standoff scaling with `atkRange` (`645u` at `500–525u` base range; `775u` with Dragon Lance `650u`,
    -- where center-to-center tower reach is `650 + 144 + 24 = 818u` — safely outside T1 `700u` range & enemy razes!).
    local baseSiegeStand = math.min(780, math.max(645, atkRange + 125))
    local desiredSiegeStand = baseSiegeStand
    if minCreepDistToT1 < 900 then
        desiredSiegeStand = math.min(math.max(670, baseSiegeStand + 10), math.max(baseSiegeStand - 5, minCreepDistToT1 + 45))
    end
    if not finish then
        -- `auto-20261031-0230` `01:43.4-01:44.4` (`tk=7230..7250`) 2nd-Tower-Shot Re-Entry Fix:
        -- NEVER let `HandleSiegeTower` reverse SF back into enemy T1 right after `HandleEnemyTowerSafety` evacuated us!
        if nowSiege < (State.noReenterEnemyT1Until or 0) then return false end
        if bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(2.0) then return false end
        local enemyBehindOwnT1 = H.IsEnemyBehindOwnTower(bot, s.enemy, tLoc)
        local enemyFarUncontested = (not U.CanQuery(s.enemy))
            or (GetUnitToLocationDistance(bot, s.enemy:GetLocation()) >= 960 and enemyBehindOwnT1)
        local enemyAbsent = H.LaneEnemyAbsent(s) or enemyFarUncontested
        local burnBlocks = H.TowerBurnActive() and not enemyAbsent
        local minSiegeHp = enemyAbsent and 240 or math.min(430, bot:GetMaxHealth() * 0.43)
        if bot:GetHealth() < minSiegeHp or burnBlocks or tower:GetAttackTarget() == bot then return false end
        -- Never siege on a single fragile creep (`<= 410 HP` lone creep or `<= 360` total HP, `9079381960.dem` `04:08..04:13`
        -- `684 <-> 786u` Oscillation & `640.9u` Trailing-Shot Fix!) when enemy hero contests close
        if not enemyAbsent and (shieldHpTotal <= 360 or (shieldCreeps <= 1 and shieldHpTotal <= 410)) then return false end
        local point = tLoc + (bot:GetLocation() - tLoc):Normalized() * desiredSiegeStand
        if U.CanQuery(s.enemy) and not enemyFarUncontested and not K.StackLeadStepSafe(bot, s.enemy, point) then return false end
        local activeTank = tower:GetAttackTarget()
        local hasLiveCreepTank = U.CanQuery(activeTank) and activeTank ~= bot and not (activeTank.IsHero and activeTank:IsHero())
        if not LN.CanHitTower(bot, tower, s.allyCreeps, 1)
            or (not hasLiveCreepTank and LN.TowerShieldCount(tower, s.allyCreeps, point) < 1) then return false end
        local enemyDryPassive = U.CanQuery(s.enemy)
            and ((s.enemy:GetMana() or 0) + U.GetMangoMana(s.enemy) < 75)
            and not H.IsEnemyPressuring(bot, s.enemy)
        local dominantHpLead = U.CanQuery(s.enemy)
            and (bot:GetHealth() or 0) >= math.max(650, (s.enemy:GetHealth() or 9999) + 320)
            and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) >= 620
        if U.CanQuery(s.enemy) and not enemyFarUncontested and (not race.valid or race.heCanKillSoon or H.IsEnemyPressuring(bot, s.enemy)
            or (not enemyDryPassive and not enemyBehindOwnT1 and not dominantHpLead
                and race.edge < (C.INTENT.PUSH_EDGE or 260) and not LN.EnemyBusyWithWave(bot, s.enemy)
                and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) <= 950)) then return false end
    end
    State.prepTarget = nil; State.lhAttackTarget = nil
    local lastAtkAge = nowSiege - (bot:GetLastAttackTime() or -100)
    if not finish and distance < desiredSiegeStand - 12 and (lastAtkAge < 0.75 or (minCreepDistToT1 < 900 and distance <= minCreepDistToT1 + 22)) then
        local standEdge = tLoc + (P.GetFountain(bot) - tLoc):Normalized() * desiredSiegeStand
        H.SmartMove(bot, standEdge, 22)
        State.actionTaken = true
        return true
    end
    -- Switch Power Treads to Agility (`FIGHT`: `+10 Damage & +10 AS`) before or between Enemy T1 right-clicks (`07:20–07:45` Fix)!
    if LN.TowerHitsToKill(bot, tower) > 1 and U.HasItem(bot, "item_power_treads") then
        local spaTw = math.max(0.65, bot:GetSecondsPerAttack() or 1.35)
        local apTw = (bot.GetAttackPoint and bot:GetAttackPoint()) or 0.50
        local notAttackingTowerYet = (bot:GetAttackTarget() ~= tower) or not U.IsAttackingAction(bot)
        local inTowerBackswing = (lastAtkAge >= 0.05) and ((spaTw - lastAtkAge) >= (apTw + 0.12))
        if (notAttackingTowerYet or inTowerBackswing) and H.TrySafeTreadsSwitch(bot, "FIGHT") then
            return true
        end
    end
    if bot:GetAttackTarget() ~= tower or not U.IsAttackingAction(bot) then
        bot:Action_AttackUnit(tower, false)
        H.ClearMoveCache()
    end
    State.actionTaken = true
    return true
end

-- ---------------------------------------------------------------------------
-- (towerLH) Under MY tower the tower is the last-hitter, and the bot never contests it: measured
-- 17.8 enemy-creep deaths per game go to our own tower, 11.8 of them within 700 of the bot and
-- 78 % of those WITHOUT the bot ever having hit the creep in the previous 2 s.  A human takes
-- those creeps by pre-swinging so that the hit lands right after the tower shot.  This runs at the
-- LOWEST priority (after every ordinary last hit/deny/punish), so it only uses otherwise idle
-- attack cycles, and asks for at most 2 tower shots of head-room.
function H.HandleTowerStealLastHit(bot, enemyCreeps, allyTowers, enemyTowers, allyCreeps)
    if C.LASTHIT.TOWER_STEAL_LH == false then return false end
    if State.actionTaken or not enemyCreeps then return false end
    local act = (bot.GetCurrentActionType and bot:GetCurrentActionType()) or 0
    if (act == BOT_ACTION_TYPE_ATTACK or (BOT_ACTION_TYPE_ATTACKUNIT ~= nil and act == BOT_ACTION_TYPE_ATTACKUNIT)) then return false end   -- already swinging at something
    local best, bestScore = nil, math.huge
    for _, c in ipairs(enemyCreeps) do
        if U.CanQuery(c) then
            local onTower = false
            for _, t in ipairs(allyTowers or {}) do
                if t and t:IsAlive() and t:GetAttackTarget() == c then onTower = true; break end
            end
            if onTower then
                local loc = c:GetLocation()
                local dist = GetUnitToLocationDistance(bot, loc)
                if dist <= (bot:GetAttackRange() or 525) + (C.LASTHIT.TOWER_STEAL_RANGE_PAD or 35) then
                    local hp = c:GetHealth()
                    -- one tower shot, as it will actually land on a creep
                    local shot = 90
                    for _, t in ipairs(allyTowers or {}) do
                        if t and t:IsAlive() and t:GetAttackTarget() == c and t.GetAttackDamage then
                            local ok, v = pcall(t.GetAttackDamage, t)
                            if ok and type(v) == "number" and v > 0 then shot = v end
                            break
                        end
                    end
                    local realShot = shot
                    if c.GetActualIncomingDamage then
                        local ok, v = pcall(c.GetActualIncomingDamage, c, shot, DAMAGE_TYPE_PHYSICAL)
                        if ok and type(v) == "number" and v > 0 then realShot = v end
                    end
                    local dr = U.SFDamageRange(bot, c)
                    local remNow = hp % math.max(1, realShot)
                    local alreadyCleanlyPrepped = (remNow >= 8 and remNow <= dr.min)
                    local remAfterOneHit = math.max(0, hp - dr.avg) % math.max(1, realShot)
                    -- Only pre-hit when the creep is NOT already cleanly landing in `[8 .. dr.min]` after tower shots,
                    -- AND one setup hit puts its post-tower remainder cleanly into `[8 .. dr.min + 6]`!
                    if not alreadyCleanlyPrepped
                        and hp <= realShot * (C.LASTHIT.TOWER_STEAL_SHOTS or 2.2) + 2.2 * dr.avg
                        and hp > realShot + 8
                        and remAfterOneHit >= 8 and remAfterOneHit <= (dr.min + 6) then
                        if H.IsSafeToAttack(bot, loc, enemyTowers, allyCreeps) then
                            local score = hp - realShot
                            if score < bestScore then bestScore, best = score, c end
                        end
                    end
                end
            end
        end
    end
    if best then
        bot:Action_AttackUnit(best, true)
        State.lhAttackTarget = best
        State.attackTarget = best
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
        H.ClearMoveCache()
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandlePriorityPush(bot, s, race)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() or not H.PriorityPushAllowed(bot,s,race) then return false end
    if H.HandleSiegeGlyph(bot,s,race) then State.actionTaken=true;return true end
    if H.HandleEnemyTowerSafety(bot,s,s.enemy) then return true end
    if H.HandleSiegeTower(bot,race,s) then return true end
    if not H.LaneEnemyAbsent(s) then return false end
    -- `ShaNachnetsya` `00:45–01:01` Post-Kill CS+Deny Equilibrium Fix:
    -- When the enemy hero is DEAD, do NOT auto-shove creeps unless `U.CanCrashWaveBeforeEnemyReturn(bot, s)` proves
    -- our wave will genuinely reach Enemy T1 before he respawns & TPs!
    if s.enemyAlive == false and U.CanCrashWaveBeforeEnemyReturn and not U.CanCrashWaveBeforeEnemyReturn(bot, s) then
        return false
    end
    -- Never displace any securable enemy CS or allied deny inside 1.85s (`L.PeekBestPlan` exact 30Hz check!)
    local bestPlanPush, bestEtaPush = L.PeekBestPlan(bot, s)
    if bestPlanPush and bestEtaPush <= 1.85 then return false end
    local enemyAttackers = U.MergeLists(s.enemyCreeps,s.enemyTowers)
    local allyAttackers = U.MergeLists(s.allyCreeps,s.allyTowers)
    local crashDenies = s.allyCreeps
    if s.enemyAlive == false and U.CanCrashWaveBeforeEnemyReturn and U.CanCrashWaveBeforeEnemyReturn(bot, s) then
        crashDenies = {}
        local tLocPush = s.enemyT1Alive and s.enemyT1Loc or nil
        local atkRPush = math.max(500, bot:GetAttackRange() or 500)
        for _, ac in pairs(s.allyCreeps or {}) do
            if U.CanQuery(ac) and ac:IsAlive()
                and (ac:GetHealth() or 9999) <= (U.SFDamageRange(bot, ac).min + 14)
                and (not tLocPush or (GetUnitToLocationDistance(ac, tLocPush) + atkRPush >= 895)) then
                crashDenies[#crashDenies + 1] = ac
            end
        end
    end
    local target, deny = L.GetBestTarget(bot,s.enemyCreeps,crashDenies,enemyAttackers,allyAttackers,false)
    if target and U.GetTimeToKillable(bot,target,deny and enemyAttackers or allyAttackers) <= 1.85 then return false end
    if not LN.BestPushCreep(bot,s.enemyCreeps,(C.PUSH and C.PUSH.PUSH_ATTACK_RANGE) or 700,s.allyCreeps) then return false end
    State.prepTarget=nil;State.lhAttackTarget=nil
    return H.ExecutePush(bot,s.enemy,race,s,true)
end

function H.ExecutePush(bot, enemyHero, race, s, priority)
    if State.actionTaken then return false end
    if not WV.AllowPush(bot, s) then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemyCreeps, allyCreeps, enemyTowers = s.enemyCreeps, s.allyCreeps, s.enemyTowers
    local t1 = s.enemyT1
    local myHpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    local now = GameTime()

    if priority and H.HandleSiegeTower(bot, race, s) then return true end

    -- 0) Post-Kill Wave-Shove Shadowraze (`s.enemyAlive == false` ONLY when `WV.ShoveAllowed` / `CanCrashWaveBeforeEnemyReturn` is true!)
    -- `auto-20261102-0139` `9:26.40` (`164 -> 90 MP` Close-`Q` on 2 Creeps While Enemy Dead) Fix:
    -- Require `>= 255 MP` (`>= 195 MP` with incoming courier Mango) AND (`hits >= 3` OR `kills >= 2`) so SF NEVER burns
    -- `75 MP` chipping 2 uncontested creeps and greets the respawned + TPing enemy dry!
    if WV.ShoveAllowed(bot, s) and #(enemyCreeps or {}) >= 2 then
        for _, label in ipairs({ "mid", "near", "far" }) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local rawDmg = U.GetRazeDamage(bot, ab, 0)
                local bCenter = (label == "near" and C.RAZE.NEAR_CENTER)
                    or (label == "mid" and C.RAZE.MID_CENTER)
                    or C.RAZE.FAR_CENTER
                for _, c in pairs(enemyCreeps) do
                    if U.CanQuery(c) and c:IsAlive() then
                        local cLoc = c:GetLocation()
                        local coilCtr = U.PointAlongLine(bot:GetLocation(), cLoc, bCenter)
                        local hits, kills = 0, 0
                        for _, c2 in pairs(enemyCreeps) do
                            if U.CanQuery(c2) and c2:IsAlive()
                                and U.DistanceBetweenLocations(coilCtr, c2:GetLocation()) <= C.RAZE.CREEP_EFF_RADIUS then
                                hits = hits + 1
                                local mDmg = c2.GetActualIncomingDamage
                                    and math.floor(c2:GetActualIncomingDamage(rawDmg, DAMAGE_TYPE_MAGICAL))
                                    or math.floor(rawDmg * 0.75)
                                if (c2:GetHealth() or 999) <= mDmg then
                                    kills = kills + 1
                                end
                            end
                        end
                        if hits >= 3 or kills >= 2 then
                            local action, aim = H.GetRazeActionType(bot, ab, c)
                            if action and H.CastOrTurnRaze(bot, ab, action, aim, c) then
                                WV.NoteShove(now)
                                return true
                            end
                        end
                    end
                end
            end
        end
        -- Strictly use `LN.BestPushCreep` (respecting `LN.PushHpFloor`!) so we NEVER whack a `79 HP` creep down to `19 HP`
        -- for allied melee creeps to steal (`ShaNachnetsya` `00:56.00` `#1126` Fix)!
        local safeShoveCreep = LN.BestPushCreep(bot, enemyCreeps, (C.PUSH and C.PUSH.PUSH_ATTACK_RANGE) or 700, allyCreeps)
        if safeShoveCreep and H.IsSafeToAttack(bot, safeShoveCreep:GetLocation(), enemyTowers, allyCreeps) then
            if H.TrySafeTreadsSwitch(bot, "FIGHT") then return true end
            if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= safeShoveCreep then
                bot:Action_AttackUnit(safeShoveCreep, false)
                H.ClearMoveCache()
            end
            State.actionTaken = true
            return true
        end
    end

    -- 1) enemy creeps nearby -> hit the "fat" ones (low HP is the last-hit zone, do not push-hit there)
    local pushCreep = LN.BestPushCreep(bot, enemyCreeps, (C.PUSH and C.PUSH.PUSH_ATTACK_RANGE) or 700, allyCreeps)
    -- The current push target dropped into the last-hit zone: stop attacking it continuously
    if not priority and U.IsAttackingAction(bot) then
        local cur = bot:GetAttackTarget()
        if cur and U.CanQuery(cur) and not (cur.IsHero and cur:IsHero()) and not (cur.IsTower and cur:IsTower())
            and State.lhAttackTarget ~= cur and (cur:GetHealth() or 0) <= LN.PushHpFloor(bot, cur, allyCreeps) then
            if pushCreep == cur then pushCreep = nil end
            if not pushCreep then
                bot:Action_ClearActions(false)
                H.ClearMoveCache()
                State.actionTaken = true
                return true
            end
        end
    end
    if pushCreep then
        if H.IsSafeToAttack(bot, pushCreep:GetLocation(), enemyTowers, allyCreeps) then
            if H.TrySafeTreadsSwitch(bot, "FIGHT") then return true end
            if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= pushCreep then
                bot:Action_AttackUnit(pushCreep, false)
                H.ClearMoveCache()
            end
            State.actionTaken = true
            return true
        end
    end

    if not priority and H.HandleSiegeTower(bot, race, s) then return true end

    -- 4) move forward with the wave (behind the front creep) if there are creeps
    local front = LN.FrontAllyCreep(bot, allyCreeps)
    if front then
        local fountain = P.GetFountain(bot)
        local dir = (fountain - front:GetLocation()):Normalized()
        local pos = front:GetLocation() + dir * 300
        pos = H.GetSafeApproach(bot, pos, enemyTowers, allyCreeps)
        -- "Moving with the wave" never walks under the T1: without a tower hit (item 2) there is nothing
        -- to do inside its radius (the creeps die - the tower switches to us). Stay >= 800.
        if t1 and t1:IsAlive() then
            local okTL, tl = pcall(t1.GetLocation, t1)
            if okTL and tl then
                local keep = ((C.TOWER and C.TOWER.SAFE_RADIUS) or 780) + 20
                if U.DistanceBetweenLocations(pos, tl) < keep then
                    pos = tl + (pos - tl):Normalized() * keep
                end
            end
        end
        if GetUnitToLocationDistance(bot, pos) > 120 then
            return H.SmartMove(bot, pos, 60)
        end
        State.holdPos = true -- In place behind the wave: do not let the final positioning pull us back
        return false
    end
    return false
end

-- Simulation-only probe (never used by the real client): the harness reads the last stage name
-- from the global namespace to attribute free-pressure orders. Zero cost outside the sim.

-- Helper: is friendly Mid T1 (`s.allyT1`) in critical 1v1 Sudden-Death danger (`HP <= 420` with enemy hero/wave nearby)?
-- In `DOTA_GAMEMODE_1V1MID`, friendly Mid T1 dying instantly destroys our Ancient (`tk=21442` BAR 9:10!).
function H.IsAllyT1InSuddenDeathDanger(bot, s)
    local t1 = s and s.allyT1
    if not t1 then return false, nil end
    local okA, alive = pcall(t1.IsAlive, t1)
    if not okA or not alive then return false, nil end
    local okH, tHp = pcall(t1.GetHealth, t1)
    local okL, tLoc = pcall(t1.GetLocation, t1)
    if not okH or not tHp or tHp > 420 or not okL or not tLoc then return false, nil end
    local enemy = s and s.enemy
    if enemy and U.CanQuery(enemy) and U.DistanceBetweenLocations(tLoc, enemy:GetLocation()) <= 1220 then
        return true, t1, tLoc
    end
    local creepPool = (s and s.enemyCreepsNearAllyT1 and #s.enemyCreepsNearAllyT1 > 0)
        and s.enemyCreepsNearAllyT1
        or ((s and s.enemyCreeps) or {})
    for _, c in pairs(creepPool) do
        if U.CanQuery(c) and c:IsAlive() and U.DistanceBetweenLocations(tLoc, c:GetLocation()) <= 1080 then
            return true, t1, tLoc
        end
    end
    for _, c in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(c) and c:IsAlive() and U.DistanceBetweenLocations(tLoc, c:GetLocation()) <= 1080 then
            return true, t1, tLoc
        end
    end
    return false, nil, nil
end

-- `v7.9.11-pro` (`2213 @ 10:54..12:59` Anti-Creep-Cut & Global `allyT1` Siege Awareness):
-- Detects:
--   1. `t1UnderCreepSiege`: Enemy lane creeps attacking or entering `allyT1` (`<= 1,180u`) with NO allied creeps in front
--      of `allyT1` tanking them (even when `bot` is `> 1,600u` away in river or jungle!).
--   2. `enemyCuttingBehindT1`: Enemy hero intercepting/proxy-farming our allied wave behind `allyT1` (between `allyT1` & `allyT2`),
--      plus `enemyFledDeepJungle` (`> 1,020u` lateral off the `allyT1 <-> fountain` spine with `0` allied creeps near them,
--      such as `(3094, 82)` at `11:36..11:48`!).
function H.GetEnemyCreepCutAndT1SiegeState(bot, s)
    local tLoc = (s and s.allyT1Loc)
        or (s and s.allyT1 and U.CanQuery(s.allyT1) and s.allyT1:GetLocation())
        or nil
    if not tLoc or (s and s.allyT1Alive == false) then
        return { valid = false }
    end
    local tHp = (s and s.allyT1Hp)
        or (s and s.allyT1 and U.CanQuery(s.allyT1) and s.allyT1:GetHealth())
        or 1800
    local fnt = P.GetFountain(bot)
    local dT1Fnt = U.DistanceBetweenLocations(tLoc, fnt)
    local spineVec = fnt - tLoc
    local spineLen = math.max(1.0, U.DistanceBetweenLocations(tLoc, fnt))
    local spx, spy = spineVec.x / spineLen, spineVec.y / spineLen

    local siegeCount = 0
    local minDistT1 = math.huge
    local nearestCreep = nil
    local seenCreep = {}
    local function ScanEnemyCreepList(list)
        for _, ec in pairs(list or {}) do
            if ec and not seenCreep[ec] and U.CanQuery(ec) and ec:IsAlive() then
                seenCreep[ec] = true
                local dc = U.DistanceBetweenLocations(ec:GetLocation(), tLoc)
                if dc <= 1180 then
                    siegeCount = siegeCount + 1
                    if dc < minDistT1 then
                        minDistT1 = dc
                        nearestCreep = ec
                    end
                end
            end
        end
    end
    ScanEnemyCreepList(s and s.enemyCreepsNearAllyT1)
    ScanEnemyCreepList(s and s.enemyCreeps)

    local allyFrontCount = 0
    for _, ac in pairs((s and s.allyCreeps) or {}) do
        if U.CanQuery(ac) and ac:IsAlive() then
            local acLoc = ac:GetLocation()
            if U.DistanceBetweenLocations(acLoc, tLoc) <= 820
                and U.DistanceBetweenLocations(acLoc, fnt) >= dT1Fnt - 220 then
                allyFrontCount = allyFrontCount + 1
            end
        end
    end
    -- Also check if global behind-T1 creeps are still far behind T1 (`allyFrontCount` stays 0 when wave was cut!)
    local t1UnderCreepSiege = (allyFrontCount == 0)
        and (siegeCount >= 1)
        and (minDistT1 <= 920 or (siegeCount >= 2 and minDistT1 <= 1180))

    local enemy = s and s.enemy
    local enemyVisible = enemy and U.CanQuery(enemy) and enemy:IsAlive()
    local enemyCuttingBehindT1 = false
    local enemyFledDeepJungle = false
    local cutTargetLoc = nil

    if enemyVisible then
        local eLoc = enemy:GetLocation()
        local dEnFnt = U.DistanceBetweenLocations(eLoc, fnt)
        local dEnT1 = U.DistanceBetweenLocations(eLoc, tLoc)
        if dEnFnt <= dT1Fnt - 120 and dEnT1 <= 2750 then
            local relX, relY = eLoc.x - tLoc.x, eLoc.y - tLoc.y
            local latFromSpine = math.abs(relX * (-spy) + relY * spx)
            local allyNearEnemy = 0
            for _, ac in pairs((s and s.allyCreepsBehindT1) or {}) do
                if U.CanQuery(ac) and ac:IsAlive() and U.DistanceBetweenLocations(ac:GetLocation(), eLoc) <= 680 then
                    allyNearEnemy = allyNearEnemy + 1
                end
            end
            for _, ac in pairs((s and s.allyCreeps) or {}) do
                if U.CanQuery(ac) and ac:IsAlive() and U.DistanceBetweenLocations(ac:GetLocation(), eLoc) <= 680 then
                    allyNearEnemy = allyNearEnemy + 1
                end
            end
            enemyCuttingBehindT1 = true
            cutTargetLoc = eLoc
            if latFromSpine > 1020 and allyNearEnemy == 0 and (enemy:GetHealth() or 9999) > 285 then
                enemyFledDeepJungle = true
            end
        end
    end

    -- `v7.9.32-pro` Dead-Enemy & Enemy-Creep Guard (`auto-20261109-0306` `3:44..3:50` `(836,836)<->(854,846)` 2-Tick Jitter Fix!):
    -- NEVER infer unseen-hero creep-cutting when `s.enemyAlive == false` (enemy hero is DEAD!) or when visible enemy lane
    -- creeps are what's fighting `allyCreepsBehindT1` unless `ac:WasRecentlyDamagedByAnyHero(1.8)`!
    if (not enemyCuttingBehindT1) and siegeCount == 0 and (s.enemyAlive ~= false) then
        local behindList = (s and s.allyCreepsBehindT1) or {}
        if #behindList >= 2 then
            for _, ac in pairs(behindList) do
                if U.CanQuery(ac) and ac:IsAlive() then
                    local cHp = ac:GetHealth() or 0
                    local cMax = math.max(1, ac:GetMaxHealth() or 1)
                    if cHp < cMax - 18 then
                        local hitByHero = ac.WasRecentlyDamagedByAnyHero and ac:WasRecentlyDamagedByAnyHero(1.8)
                        local enemyCreepFightingIt = false
                        if not hitByHero then
                            local acLoc = ac:GetLocation()
                            for _, ecB in pairs((s and s.enemyCreeps) or {}) do
                                if U.CanQuery(ecB) and ecB:IsAlive()
                                    and U.DistanceBetweenLocations(ecB:GetLocation(), acLoc) <= 420 then
                                    enemyCreepFightingIt = true
                                    break
                                end
                            end
                        end
                        if hitByHero or (not enemyCreepFightingIt) then
                            enemyCuttingBehindT1 = true
                            cutTargetLoc = ac:GetLocation()
                            break
                        end
                    end
                end
            end
        end
    end

    return {
        valid = true,
        allyT1Loc = tLoc,
        allyT1Hp = tHp,
        t1UnderCreepSiege = t1UnderCreepSiege,
        siegeCount = siegeCount,
        minDistT1 = minDistT1,
        nearestCreep = nearestCreep,
        enemyCuttingBehindT1 = enemyCuttingBehindT1,
        enemyFledDeepJungle = enemyFledDeepJungle,
        cutTargetLoc = cutTargetLoc,
    }
end

-- `v7.9.11-pro` Anti-Creep-Cut & Undefended `allyT1` Creep-Siege Defender (`2213 @ 10:54..12:59` Complete Fix):
--   Rule 1: Whenever enemy lane creeps are hitting or entering an undefended `allyT1` (`t1UnderCreepSiege`), NEVER push
--           empty river AND NEVER chase a proxy-cutter into deep jungle (`(3094, 82)`): snap back to `allyT1` and clear
--           the enemy creeps off `allyT1` (`0` uncontested tower chip!). Even during `modifier_flask_healing`, lane creeps
--           do NOT break Salve — walk back to `allyT1` if the enemy hero is safely away (`>= 1,180u`)!
--   Rule 2: When the enemy hero is cutting our wave behind `allyT1` (`enemyCuttingBehindT1`) while `allyT1` is clear of
--           enemy creeps, abort empty river push and collapse onto the cutter along the T1-T2 mid corridor (refusing
--           deep side-jungle baits `> 1,020u` off-spine)!
function H.HandleAntiCreepCutAndT1Defense(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if State.goingToFountain then return false end
    local info = H.GetEnemyCreepCutAndT1SiegeState(bot, s)
    if not info or not info.valid then return false end

    local nowCut = GameTime()
    local myHp = bot:GetHealth() or 0
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 1)
    local enemy = s and s.enemy
    local enemyVisible = enemy and U.CanQuery(enemy) and enemy:IsAlive()
    local dBotT1 = GetUnitToLocationDistance(bot, info.allyT1Loc)
    local hasSalve = bot:HasModifier("modifier_flask_healing")

    -- Never turn a fleeing/critically-endangered SF back into a pursuing stronger enemy hero (`10:07.53` Regression Guard!):
    -- Sudden-death `< 420 HP` throne defense is ALREADY handled above by `HandleCriticalAllyT1AndDivePunish`!
    local activeRetreatNow = (State.forcedRetreatLoc ~= nil and nowCut < (State.forcedRetreatUntil or 0))
        or (nowCut < (State.fleeUntil or 0))
        or (nowCut < (State.critDangerHystUntil or 0))
    if activeRetreatNow or H.InCriticalLethalDanger(bot, s, earlyRace)
        or (earlyRace and earlyRace.valid and (earlyRace.heCanKillNow or earlyRace.heCanKillSoon)) then
        return false
    end
    if enemyVisible and GetUnitToLocationDistance(bot, enemy:GetLocation()) <= 980
        and ((myHp / myMaxHp) <= 0.48 or H.InLosingHeroTrade(bot, s, earlyRace)) then
        return false
    end

    -- [RULE 1] UNDEFENDED `allyT1` CREEP-SIEGE PROTECTION
    -- `v7.9.21` (`auto-20261107-2214` `tk=15326` `07:18.80` `31 HP` Boots + FoW Kill-Abort Fix!):
    -- When `allyT1Hp > 650` (our T1 is NOT in sudden-death danger!), NEVER yank SF `2,800u` back to `allyT1` for 1–2 creeps
    -- while we are actively hunting a crippled visible OR recent-FoW (`<= 5.5s`) enemy (`<= 280 HP`, or `<= 365 HP` when
    -- holding a Boots MS lead `myMS >= enMS + 25`!) within `1,520u`!
    local myMsDef = bot:GetCurrentMovementSpeed() or 305
    local enMsDef = (enemyVisible and (enemy:GetCurrentMovementSpeed() or 305)) or (s.enemyLastMS or 305)
    local hasBootsSpeedLead = (myMsDef >= enMsDef + 25)
    local maxHuntHpDef = hasBootsSpeedLead and 365 or 280
    local huntingCrippledEnemy = false
    if info.allyT1Hp > 650 and myHp >= 380 and s.enemyAlive ~= false then
        if enemyVisible and (enemy:GetHealth() or 9999) <= maxHuntHpDef
            and GetUnitToLocationDistance(bot, enemy:GetLocation()) <= 1520 then
            huntingCrippledEnemy = true
        elseif (not enemyVisible) and s.enemyLastLoc
            and (s.enemyAbsentFor or 99) <= (hasBootsSpeedLead and 5.5 or 2.8)
            and (s.enemyLastHealth or 9999) <= maxHuntHpDef
            and GetUnitToLocationDistance(bot, s.enemyLastLoc) <= 1520 then
            huntingCrippledEnemy = true
        end
    end
    if huntingCrippledEnemy then
        return false
    end

    if info.t1UnderCreepSiege and info.nearestCreep and myHp >= 260 then
        -- Proactive Glyph before `allyT1` drops into sudden-death range!
        if info.allyT1Hp <= 650 and info.minDistT1 <= 420 and info.siegeCount >= 2 then
            if U.ShouldUseGlyphDefensive(bot, s.allyTowers) or (type(GetGlyphCooldown) == "function" and GetGlyphCooldown() == 0) then
                U.UseGlyph(bot)
            end
        end
        local finishingAdjacentKill = enemyVisible
            and (enemy:GetHealth() or 9999) <= 280
            and GetUnitToLocationDistance(bot, enemy:GetLocation()) <= 960
        if not finishingAdjacentKill then
            local fnt = P.GetFountain(bot)
            local defendSpot = info.allyT1Loc + (fnt - info.allyT1Loc):Normalized() * 185
            if hasSalve then
                local effEnLoc = enemyVisible and enemy:GetLocation()
                    or (((s.enemyAbsentFor or 99) < 4.5) and s.enemyLastLoc or nil)
                local dSpotToEn = effEnLoc and U.DistanceBetweenLocations(defendSpot, effEnLoc) or 9999
                if dSpotToEn >= 1180 and dBotT1 > 420 then
                    H.SmartMove(bot, defendSpot, 45, true)
                    return true
                end
                return false
            end

            -- Snap back from river or jungle to `allyT1` immediately!
            if dBotT1 > 780 then
                H.SmartMove(bot, defendSpot, 50, true)
                return true
            end

            -- `v7.9.12-pro` (`2319 @ 02:31..02:38` `(414, 337)` `-140 HP` Tanking & Tower-Missed CS Fix!):
            -- Once `bot` IS ALREADY at `allyT1` (`dBotT1 <= 780u`) and `allyT1Hp > 650` (not in sudden-death danger) and
            -- the enemy is NOT actively proxy-cutting behind `allyT1`, hand off 100% of under-tower wave farming to
            -- `L.RunSacredCS` + `P.GetLasthitPosition` (which kites `435u` behind `allyT1` so the tower tanks melee creeps
            -- for `0` hero HP cost and phase-locks every last-hit between tower bolts!).
            local urgentClear = (info.allyT1Hp <= 650)
                or (info.enemyCuttingBehindT1 and info.allyT1Hp <= 1350)
            if urgentClear and U.CanQuery(info.nearestCreep) and info.nearestCreep:IsAlive() then
                local allowRazeClear = ((bot:GetMana() or 0) >= 145)
                    or (info.allyT1Hp <= 980 and (bot:GetMana() or 0) >= 75)
                if allowRazeClear then
                    for _, lbl in ipairs({ "far", "mid", "near" }) do
                        local ab = H.GetRazeAbilityByLabel(bot, lbl)
                        if ab and U.IsRazeAbilityCastable(bot, ab) then
                            local act, aim = H.GetRazeActionType(bot, ab, info.nearestCreep)
                            if act and H.CastOrTurnRaze(bot, ab, act, aim, info.nearestCreep) then
                                return true
                            end
                        end
                    end
                end
                if GetUnitToLocationDistance(bot, info.nearestCreep:GetLocation()) <= (bot:GetAttackRange() or 525) + 120 then
                    if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= info.nearestCreep then
                        bot:Action_AttackUnit(info.nearestCreep, true)
                        H.ClearMoveCache()
                    end
                    State.actionTaken = true
                    return true
                end
                H.SmartMove(bot, info.nearestCreep:GetLocation(), 55, true)
                return true
            end
        end
    end

    -- [RULE 2] ANTI-CREEP-CUT COLLAPSE & JUNGLE-BAIT LEASH (When `allyT1` Has No Enemy Creeps Hitting It)
    if info.enemyCuttingBehindT1 and info.cutTargetLoc and not hasSalve then
        -- If the cutter fled deep off-spine into side-jungle (`> 1,020u` lateral with `0` allied creeps), DO NOT chase!
        -- Return to `allyT1` so we catch 100% of the next wave and protect our tower.
        if info.enemyFledDeepJungle then
            if dBotT1 > 520 then
                H.SmartMove(bot, info.allyT1Loc, 55, true)
                return true
            end
            return false
        end

        if myHp >= 370 and not (earlyRace and earlyRace.valid and earlyRace.heCanKillNow) then
            if enemyVisible then
                if (bot:GetMana() or 0) >= 75 then
                    for _, lbl in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                        local ab = H.GetRazeAbilityByLabel(bot, lbl)
                        if ab and U.IsRazeAbilityCastable(bot, ab) then
                            local act, aim = H.GetRazeActionType(bot, ab, enemy)
                            if act and H.CastOrTurnRaze(bot, ab, act, aim, enemy) then
                                return true
                            end
                        end
                    end
                end
                local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
                local enHasQ = K.EnemyRazeReady("near", 1.2) and (K.EnemyManaBudget(enemy, true) >= 75)
                if enHasQ and dHero < 485 and (enemy:GetHealth() or 9999) > 290 and myHp < (enemy:GetHealth() or 9999) + 120 then
                    local awayDir = (bot:GetLocation() - enemy:GetLocation()):Normalized()
                    H.SmartMove(bot, enemy:GetLocation() + awayDir * 510, 30, true)
                    return true
                end
                if dHero <= (bot:GetAttackRange() or 525) + 65 then
                    if H.IssueHeroAttack(bot, enemy) then
                        State.actionTaken = true
                        return true
                    end
                end
                local approachDir = (info.allyT1Loc - enemy:GetLocation()):Normalized()
                local standoff = enHasQ and 495 or 430
                H.SmartMove(bot, enemy:GetLocation() + approachDir * standoff, 45, true)
                return true
            else
                -- Yield to `RunSacredCS` whenever live enemy creeps are already inside `650u` of `bot`, and apply `65u`
                -- hysteresis (`> 385u` enter, `<= 320u` release) so `360u` boundary oscillation can NEVER occur!
                local hasNearbyEnemyCreep = false
                for _, ecNear in pairs((s and s.enemyCreeps) or {}) do
                    if U.CanQuery(ecNear) and ecNear:IsAlive()
                        and GetUnitToLocationDistance(bot, ecNear:GetLocation()) <= 650 then
                        hasNearbyEnemyCreep = true
                        break
                    end
                end
                local dCut = GetUnitToLocationDistance(bot, info.cutTargetLoc)
                local cutThresh = State._cutWalkActive and 320 or 385
                if (not hasNearbyEnemyCreep) and dCut > cutThresh then
                    State._cutWalkActive = true
                    H.SmartMove(bot, info.cutTargetLoc, 50, true)
                    return true
                else
                    State._cutWalkActive = false
                end
            end
        end
    end

    return false
end

-- Unified Top-Priority Executioner & Throne-Grade Mid T1 Defender (`BAR 4:10` + `BAR 5:09` + `BAR 6:12` + `BAR 9:10`):
--   1. `BAR 9:10` (`allyT1 <= 420 HP` Sudden-Death Defense): Glyph immediately, override Salve/Fountain flight,
--      pop Mango/Stick, nuke/kill any hero hitting our low-HP T1 (`552 HP` ShaNachnetsya @ `tk=21334`), and clear siege/creeps!
--   2. `BAR 4:10` (`ShaNachnetsya` `186 HP` Dire T1 Dive): Never run away while friendly T1 is shooting a tower diver —
--      pop Mango/Stick if needed, land covering Shadowraze + right-click under friendly T1 aura to execute 100% of divers!
--   3. `BAR 5:09` (`108 -> 212 HP`) & `BAR 6:12` (`283 HP` at `340u`): Immediately pop Mango/Stick and finish low-HP enemy SF!
function H.HandleCriticalAllyT1AndDivePunish(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local myHp = bot:GetHealth() or 0
    local enemy = s and s.enemy
    local t1Danger, allyT1, allyT1Loc = H.IsAllyT1InSuddenDeathDanger(bot, s)

    -- [1] THRONE-GRADE FRIENDLY MID T1 DEFENSE (`BAR 9:10`, `allyT1 HP <= 420` + `v7.9.30` `7:44` `114 HP` Anti-Suicide Fix!)
    if t1Danger and allyT1 and allyT1Loc then
        -- Instant `0`-tick Glyph works at ANY HP without turning or stopping our retreat!
        if U.ShouldUseGlyphDefensive(bot, s.allyTowers) then
            U.UseGlyph(bot)
        end
        local recentBuybackT1 = s and ((GameTime() - (s.enemyRespawnedAt or -100)) <= 10.0) or false
        local liveEnT1 = (enemy and U.CanQuery(enemy) and enemy:IsAlive()) and enemy or nil
        local dEnToMeT1 = liveEnT1 and GetUnitToLocationDistance(bot, liveEnT1:GetLocation()) or 9999
        local lrT1 = liveEnT1 and U.SolveLethalRace(bot, liveEnT1, s) or nil
        local winsHeroT1 = (lrT1 and lrT1.winsFirstKill and lrT1.tKillHim <= 2.4) or false
        local enBurst16T1 = liveEnT1 and K.EnemyBurstVs(bot, liveEnT1, math.min(dEnToMeT1, 680), 1.6, false) or 0
        local suddenDeathT1 = (s and s.suddenDeathDanger) or false
        local bootChasedLowHp = liveEnT1
            and ((liveEnT1:GetCurrentMovementSpeed() or 305) >= (bot:GetCurrentMovementSpeed() or 305) + 20)
            and (myHp < (liveEnT1:GetHealth() or 999) * 0.45)
        -- NEVER clear `goingToFountain`/`ForcedRetreat` or turn `180 deg` to self-root `E+W` at `114 HP` against a `1232 HP`
        -- Boots enemy (`auto-20261109-0026` `tk=16868` `0–2` Sudden-Death Loss Fix!):
        local canFightHeroForT1 = winsHeroT1 or (
            myHp >= (suddenDeathT1 and 365 or 275)
            and myHp > enBurst16T1 + (suddenDeathT1 and 130 or 75)
            and not bootChasedLowHp
        )
        local canClearCreepsForT1 = (myHp > 145)
            and (not liveEnT1 or (dEnToMeT1 > 1080 and myHp >= 240) or canFightHeroForT1)
            and (not recentBuybackT1 or myHp >= (suddenDeathT1 and 365 or 275))

        if canFightHeroForT1 or canClearCreepsForT1 then
            State.goingToFountain = false
            State.fountainReason = nil
            State.emergencyRetreat = nil
            H.ClearForcedRetreat()
            State.fleeUntil = 0
            if (bot:GetMana() or 0) < 75 and H.TryUseBurstManaItem(bot, true) then
                return true
            end
            -- Priority 1A: Enemy hero approaching/attacking our `< 420 HP` Mid T1 -> fight ONLY when `canFightHeroForT1`!
            if canFightHeroForT1 and liveEnT1 and U.DistanceBetweenLocations(allyT1Loc, liveEnT1:GetLocation()) <= 1220 then
                for _, label in ipairs({ "far", "mid", "near" }) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, liveEnT1)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, liveEnT1) then
                            State.commitKillUntil = GameTime() + 2.5
                            return true
                        end
                    end
                end
                local dHero = dEnToMeT1
                if dHero <= (bot:GetAttackRange() or 525) + 55 then
                    if H.IssueHeroAttack(bot, liveEnT1) then
                        State.actionTaken = true
                        return true
                    end
                end
                local stepTarget = liveEnT1:GetLocation() + (allyT1Loc - liveEnT1:GetLocation()):Normalized() * 440
                H.SmartMove(bot, stepTarget, 35, true)
                return true
            end
            -- Priority 1B: Enemy creeps threatening `< 420 HP` Mid T1 -> blast cluster with Raze & right-click!
            if canClearCreepsForT1 then
                local urgentCreep, urgentDist = nil, math.huge
                local t1CreepPool = (s and s.enemyCreepsNearAllyT1 and #s.enemyCreepsNearAllyT1 > 0)
                    and s.enemyCreepsNearAllyT1
                    or ((s and s.enemyCreeps) or {})
                for _, c in pairs(t1CreepPool) do
                    if U.CanQuery(c) and c:IsAlive() then
                        local dc = U.DistanceBetweenLocations(allyT1Loc, c:GetLocation())
                        if dc < urgentDist then
                            urgentDist, urgentCreep = dc, c
                        end
                    end
                end
                for _, c in pairs((s and s.enemyCreeps) or {}) do
                    if U.CanQuery(c) and c:IsAlive() then
                        local dc = U.DistanceBetweenLocations(allyT1Loc, c:GetLocation())
                        if dc < urgentDist then
                            urgentDist, urgentCreep = dc, c
                        end
                    end
                end
                if urgentCreep then
                    if (bot:GetMana() or 0) >= 75 then
                        for _, label in ipairs({ "far", "mid", "near" }) do
                            local ab = H.GetRazeAbilityByLabel(bot, label)
                            if ab and U.IsRazeAbilityCastable(bot, ab) then
                                local action, aim = H.GetRazeActionType(bot, ab, urgentCreep)
                                if action and H.CastOrTurnRaze(bot, ab, action, aim, urgentCreep) then
                                    return true
                                end
                            end
                        end
                    end
                    if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= urgentCreep then
                        bot:Action_AttackUnit(urgentCreep, true)
                        H.ClearMoveCache()
                    end
                    State.actionTaken = true
                    return true
                end
            end
        end
    end

    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end

    -- [2] ENEMY TOWER-DIVER EXECUTIONER (`BAR 4:10` + `auto-20261022-2237` `04:38` `(1808,1126)` & `05:45` Behind-T1 Dive Fix!)
    local myT1 = s and s.allyT1
    local enManaDive = K.EnemyManaBudget(enemy, true)
    local enemyZeroCoilDive = (enManaDive < 75) or (K.EnemyReadyRazeCount(enemy, 0.7, true) == 0)
    local minDivePunishHp = enemyZeroCoilDive and 115 or 195
    local myDryInTwoRazeLethal = (not enemyZeroCoilDive)
        and (K.MyManaBudget(bot, true) < 75)
        and ((enemy:GetHealth() or 9999) > 260)
        and (myHp <= K.EnemyCastableRazeDamage(bot, enemy, 2, nil, 2.2) + K.AttackDamageVs(enemy, bot) + 45)
    if myT1 and myHp >= minDivePunishHp and not myDryInTwoRazeLethal
        and not (earlyRace and earlyRace.valid and earlyRace.heCanKillNow and not enemyZeroCoilDive) then
        local okA, tAlive = pcall(myT1.IsAlive, myT1)
        local okL, tLoc = pcall(myT1.GetLocation, myT1)
        if okA and tAlive and okL and tLoc then
            local fnt = P.GetFountain(bot)
            local dEnT1 = U.DistanceBetweenLocations(tLoc, enemy:GetLocation())
            local pastOurT1 = U.DistanceBetweenLocations(enemy:GetLocation(), fnt) <= U.DistanceBetweenLocations(tLoc, fnt) + 95
                and dEnT1 <= 1650
            if dEnT1 <= 830 or pastOurT1 then
                local okT, tTgt = pcall(myT1.GetAttackTarget, myT1)
                local lrDive = U.SolveLethalRace(bot, enemy, s)
                -- `auto-20261023-0119` Death #1 (`04:24.97` `384 HP` vs `978 HP` + 7 creeps past Radiant T1) Fix:
                -- NEVER blindly stand and fight a near-full-HP enemy + full wave behind our T1 unless our T1 is ACTUALLY
                -- shooting him (`tTgt == enemy` with survival margin), OR `SolveLethalRace` wins, OR we match his HP!
                local safePastT1 = pastOurT1 and (
                    (okT and tTgt == enemy and myHp >= K.EnemyBurstVs(bot, enemy, dEnT1, 1.0, false) + 75)
                    or (lrDive and lrDive.winsFirstKill and lrDive.tKillHim <= 2.5)
                    or ((enemy:GetHealth() or 9999) <= 465 and myHp >= 250)
                    or (myHp >= 360 and myHp >= (enemy:GetHealth() or 9999) * 0.58)
                )
                -- `9069188041.dem` `02:11.8` + `auto-20261031-0230` `02:09.1` (`tk=8002`) Root-Cause Fix:
                --   1. When enemy creeps tank our T1 (`tTgt ~= enemy`), our T1 deals ZERO DPS to `enemy` — NEVER treat an
                --      enemy standing behind his creeps at `393u` as a "tower diver" when we are low HP (`< 260 HP`)!
                --   2. At low HP (`< 235 HP`), NEVER clear `ForcedRetreat` or self-root `0.55s` inside enemy attack range
                --      unless `SolveLethalRace` (`lrDive.winsFirstKill`) proves we kill him BEFORE his autos kill us!
                local winsDiveRace = (lrDive and lrDive.winsFirstKill and lrDive.tKillHim <= 2.5) or false
                local dHeroDive = GetUnitToLocationDistance(bot, enemy:GetLocation())
                local myMaxHpDive = math.max(1, (bot.GetMaxHealth and bot:GetMaxHealth()) or 600)
                local enBurstDive = K.EnemyBurstVs(bot, enemy, math.min(dHeroDive, 540), 1.35, false)
                local oneRazePlusAtkDive = K.MyRazeDamage(bot, enemy, 1) + K.AttackDamageVs(bot, enemy)
                -- `v7.9.15` (`auto-20261106-2139` `06:02.60` `260/1050 HP` vs `744 HP` Lvl-6 Boots SF Walk-Back Fix):
                -- NEVER wipe `ForcedRetreat` or walk backward into a high-HP chasing enemy walking past our T1 when we
                -- lose the burst/TTK race (`myHp <= enBurstDive + 65` or `heCanKillSoon` or `< 35% HP` vs healthy foe)!
                local lethalDiveDanger = (not winsDiveRace) and (not enemyZeroCoilDive) and (
                    (myHp <= enBurstDive + 65)
                    or (earlyRace and earlyRace.valid and earlyRace.heCanKillSoon and not earlyRace.canKillSoon)
                    or (myHp < math.max(335, myMaxHpDive * 0.35) and (enemy:GetHealth() or 9999) > oneRazePlusAtkDive + 90)
                )
                local towerActuallyOnEnemy = (okT and tTgt == enemy)
                    or (#(s.enemyCreeps or {}) == 0 and dEnT1 <= 695)
                local towerShootingHim = (not lethalDiveDanger) and (
                    (towerActuallyOnEnemy and (myHp >= 235 or winsDiveRace))
                    or safePastT1
                )
                local lowEnemyUnderT1 = (not lethalDiveDanger) and towerActuallyOnEnemy
                    and (myHp >= 255 or winsDiveRace)
                    and ((dEnT1 <= 755 and (enemy:GetHealth() or 9999) <= 465)
                        or (dEnT1 <= 830 and (((bot:GetMana() or 0) >= 75 and (enemy:GetHealth() or 9999) <= 420) or (enemy:GetHealth() or 9999) <= 260)))
                local farSafeDiveCoil = (not lethalDiveDanger) and (myHp >= 115)
                    and (dHeroDive >= (enemy:GetAttackRange() or 525) + 85)
                    and (winsDiveRace or (towerActuallyOnEnemy and myHp >= 185))
                if towerShootingHim or lowEnemyUnderT1 or farSafeDiveCoil then
                    H.ClearForcedRetreat()
                    State.fleeUntil = 0
                    if (bot:GetMana() or 0) < 75 and H.TryUseBurstManaItem(bot, true) then
                        State.commitKillUntil = GameTime() + 2.0
                        return true
                    end
                    local dHero = dHeroDive
                    local oneRazeDmg = K.MyRazeDamage(bot, enemy, 1)
                    local lastAtkDt = GameTime() - (bot:GetLastAttackTime() or -100)
                    local spa = bot:GetSecondsPerAttack() or 1.2
                    local alreadySwingingHero = (U.IsAttackingAction(bot) and bot:GetAttackTarget() == enemy)
                    -- `W5 07:07.5` (`265 HP / 67 MP` stepped to `304u` inside Lvl 4 `Q = 450u` under Dire T1!) Fix:
                    -- When enemy SF has `Q` (`near`, `0..450u`) available and `myHp` is in `Q + Auto` danger,
                    -- NEVER stand inside `< 495u` — kite to `515u` max attack range toward `fnt` while our T1 shoots him!
                    local enNearThreat = (not enemyZeroCoilDive)
                        and (K.EnemyRazeReadyIn("near") <= 1.2)
                        and (myHp <= K.EnemyRazeDamage(bot, enemy, 1) + K.AttackDamageVs(enemy, bot) + 65)
                    if enNearThreat and dHero < 495 and oneRazeDmg < (enemy:GetHealth() or 9999) then
                        local kiteDir = (fnt - enemy:GetLocation()):Normalized()
                        local kiteSpot = enemy:GetLocation() + kiteDir * 520
                        H.SmartMove(bot, kiteSpot, 25, true)
                        State.commitKillUntil = GameTime() + 1.5
                        return true
                    end
                    local swingRange = alreadySwingingHero
                        and ((bot:GetAttackRange() or 525) + 215)
                        or ((bot:GetAttackRange() or 525) + 35)
                    if myHp >= 235 and oneRazeDmg < (enemy:GetHealth() or 9999)
                        and dHero <= swingRange
                        and lastAtkDt >= spa * 0.80 then
                        if not alreadySwingingHero then
                            bot:Action_AttackUnit(enemy, true)
                            H.ClearMoveCache()
                        end
                        State.commitKillUntil = GameTime() + 2.0
                        State.actionTaken = true
                        return true
                    end
                    local enMSDive = enemy:GetCurrentMovementSpeed() or 305
                    local canSafelyCastDiveRaze = winsDiveRace
                        or (oneRazeDmg + K.AttackDamageVs(bot, enemy) >= (enemy:GetHealth() or 9999))
                        or (dHero >= (enemy:GetAttackRange() or 525) + 65 and myHp >= 185 and myHp > enBurstDive + 45)
                        or (myHp >= 245 and myHp > enBurstDive + 85 and (dHero - enMSDive * 0.58) >= (enemyZeroCoilDive and 240 or 485))
                    if canSafelyCastDiveRaze then
                        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                            local ab = H.GetRazeAbilityByLabel(bot, label)
                            if ab and U.IsRazeAbilityCastable(bot, ab) then
                                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                                    State.commitKillUntil = GameTime() + 2.0
                                    return true
                                end
                            end
                        end
                    end
                    if myHp >= 210 and dHero <= (bot:GetAttackRange() or 525) + 60 then
                        if H.IssueHeroAttack(bot, enemy) then
                            State.commitKillUntil = GameTime() + 2.0
                            State.actionTaken = true
                            return true
                        end
                    elseif myHp >= 260 and dHero <= 950 then
                        local safeHoldDist = (enNearThreat or (bot:GetMana() or 0) < 75 or myHp < 430) and 515 or 445
                        local refDir = (enNearThreat or safeHoldDist >= 500)
                            and (fnt - enemy:GetLocation()):Normalized()
                            or (tLoc - enemy:GetLocation()):Normalized()
                        local setup = enemy:GetLocation() + refDir * safeHoldDist
                        local bLocD = bot:GetLocation()
                        local myMSD = bot:GetCurrentMovementSpeed() or 305
                        local walksBackwardCloser = U.DistanceBetweenLocations(setup, fnt) > U.DistanceBetweenLocations(bLocD, fnt) + 20
                        if walksBackwardCloser and not winsDiveRace
                            and (myHp < (enemy:GetHealth() or 9999) * 0.75 or myHp < myMaxHpDive * 0.50 or enMSDive > myMSD + 15) then
                            return false
                        end
                        H.SmartMove(bot, setup, 35, true)
                        return true
                    end
                end
            end
        end
    end

    -- [3] CRITICAL LOW-HP ENEMY FINISH (`BAR 5:09`, `BAR 6:12`, `3:58` 2-Hit Zero-Mana Right-Click Kill, & `5:28` Centered `E`!)
    local enHp = enemy:GetHealth() or 9999
    local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local underUnsafeEnemyT1 = false
    local botInsideUnsafeEnemyT1 = false
    for _, tw in pairs((s and s.enemyTowers) or {}) do
        if tw and tw:IsAlive() and not H._hasTankCreepUnderTower(tw, s.allyCreeps) then
            if GetUnitToLocationDistance(tw, enemy:GetLocation()) < 740 then
                underUnsafeEnemyT1 = true
            end
            if GetUnitToLocationDistance(tw, bot:GetLocation()) <= 885 then
                botInsideUnsafeEnemyT1 = true
            end
        end
    end

    -- Pure TTK Race Lethal Override (`0119` `00:24.83` @ `42 HP` & `05:25.43` @ `90 HP` + `9055695956.dem` `3:58` @ `91 HP`):
    -- Uses exact `U.SolveLethalRace` `[0, tKillHim + 0.15s]` first-kill physics so SF NEVER aborts a winning kill at `< 195 HP`!
    local lrCrit = U.SolveLethalRace(bot, enemy, s)
    local myPhysHit = math.max(38, K.AttackDamageVs(bot, enemy))
    if not underUnsafeEnemyT1
        and ((lrCrit and lrCrit.winsFirstKill and lrCrit.tKillHim <= 2.35 and dHero <= math.max((bot:GetAttackRange() or 525) + 155, 880))
            or (enHp <= myPhysHit * 2.25
                and dHero <= (bot:GetAttackRange() or 525) + 135
                and myHp >= math.max(195, K.EnemyBurstVs(bot, enemy, dHero, 1.5, false) + 55))) then
        if H.HandleActiveLethalDuelFinish(bot, s, earlyRace) then
            return true
        end
    end

    local myPotMana = H.GetPotentialCombatMana(bot)
    local oneMyRaze = K.MyRazeDamage(bot, enemy, 1)
    local canFinishLow = (enHp <= math.max(275, oneMyRaze * 1.58) and myHp >= 290 and myPotMana >= 75)
        or (enHp <= 335 and myHp >= 420 and myPotMana >= 75 and dHero <= 680)
    -- Casting Shadowraze from outside tower range (`not botInsideUnsafeEnemyT1`) triggers ZERO tower aggro in Dota 2!
    if canFinishLow and dHero <= 965 and not botInsideUnsafeEnemyT1
        and not (earlyRace and earlyRace.valid and earlyRace.heCanKillNow) then
        H.ClearForcedRetreat()
        State.fleeUntil = 0
        if (bot:GetMana() or 0) < 75 and H.TryUseBurstManaItem(bot, true) then
            State.commitKillUntil = GameTime() + 2.0
            return true
        end
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    State.commitKillUntil = GameTime() + 2.0
                    return true
                end
            end
        end
        if not underUnsafeEnemyT1 and dHero <= (bot:GetAttackRange() or 525) + 55 then
            if H.IssueHeroAttack(bot, enemy) then
                State.commitKillUntil = GameTime() + 2.0
                State.actionTaken = true
                return true
            end
        elseif not underUnsafeEnemyT1 and K.CanCatch(bot, enemy, 660, 2.0) then
            local setup = U.GetRazeSetupPosition(bot, enemy)
            if setup and H.ApproachEnemyPoint(bot, enemy, setup, 35, s.enemyTowers, s.allyCreeps) then
                return true
            end
        end
    end

    return false
end

function H.CanTwoHitRightClickKill(bot, enemy, s)
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
    for _, tw in pairs((s and s.enemyTowers) or {}) do
        if tw and tw:IsAlive() and GetUnitToLocationDistance(tw, enemy:GetLocation()) < 740
            and not H._hasTankCreepUnderTower(tw, s.allyCreeps) then
            return false
        end
    end
    local lr = U.SolveLethalRace(bot, enemy, s)
    if lr and lr.winsFirstKill and lr.tKillHim <= 2.35 and dHero <= math.max((bot:GetAttackRange() or 525) + 155, 880) then
        return true
    end
    -- `v7.9.8-pro` (`1630 @ 01:32.6..01:36.2` `3–28 HP` 1-Shot vs `156 HP` Bot Fix!):
    -- Never let `InCriticalLethalDanger` force-retreat away from a literal 1-shot enemy within `<= 775u` when we tank his burst!
    if U.CanOneShotEnemyHero(bot, enemy)
        and dHero <= (bot:GetAttackRange() or 525) + 250
        and (bot:GetHealth() or 0) >= K.EnemyBurstVs(bot, enemy, math.min(dHero, 500), 1.15, false) + 8 then
        return true
    end
    if dHero > (bot:GetAttackRange() or 525) + 135 then return false end
    local myPhysHit = math.max(38, K.AttackDamageVs(bot, enemy))
    local enHp = enemy:GetHealth() or 9999
    if enHp > myPhysHit * 2.25 then return false end
    local enNoRaze = K.EnemyCastableRazeCount(enemy, 1.5) == 0
    local minSafeFloor = enNoRaze and 130 or 195
    return (bot:GetHealth() or 0) >= math.max(minSafeFloor, K.EnemyBurstVs(bot, enemy, dHero, 1.5, false) + 50)
end

-- Stage A (ABOVE RunSacredCS): Strictly prevents stopping/turning back for a creep last-hit when 1-2 hits
-- or an immediate enemy cast away from death while NEVER interrupting normal 0.000s-0.033s CS!
-- Uses Schmitt-trigger hysteresis (`+85u` exit margin) so we NEVER bang-bang stall at the boundary!
function H.InCriticalLethalDanger(bot, s, race)
    local myHp = bot:GetHealth() or 0
    local enemy = s and s.enemy
    local now = GameTime()

    -- Critical low-HP protection vs ACTUALLY AGGROED lane creeps (`R2_2044` `03:25..03:31.33` `@420u` Freeze Fix
    -- + `v7.9.18` `9079381960.dem` `04:42.73..04:44.87` `148 HP` Dead-Enemy Under-Own-T1 Missed-CS Fix!):
    -- When `s.enemyAlive == false` (enemy hero is DEAD!), 1–2 lane creeps deal ~14 DPS (`148 HP` = 10s+ survival next to our
    -- T1 & arriving wave!), whereas firing `critDangerHystUntil = now + 0.75` sent SF running `546u` behind T1 and missed CS!
    if myHp <= 155 then
        local nearAggroCreeps, hasSiegeAggro = 0, false
        local noAllyShield = #(s and s.allyCreeps or {}) == 0
        for _, c in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(c) and c:IsAlive() then
                if c:GetAttackTarget() == bot or (noAllyShield and GetUnitToLocationDistance(bot, c:GetLocation()) <= 230) then
                    nearAggroCreeps = nearAggroCreeps + 1
                    if (c:GetMaxHealth() or 0) >= 800 then hasSiegeAggro = true end
                end
            end
        end
        local enemyDeadSafeFarm = (s and s.enemyAlive == false)
            and (not hasSiegeAggro)
            and (myHp > 70)
            and (nearAggroCreeps <= 2 or myHp > 135)
        if nearAggroCreeps >= 1 and not enemyDeadSafeFarm then
            State.critDangerHystUntil = now + 0.75
            return true
        end
    end

    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then
        -- `9069188041.dem` `03:44.1` FoW Tree-Juke Persistence Fix:
        -- When a live enemy hero ducks behind SE trees within `<= 960u` for `<= 3.0s` while we are at `<= 215 HP`,
        -- DO NOT drop critical danger and walk back into the river/trees!
        if s and s.enemyAlive ~= false and (s.enemyAbsentFor or 99) <= 3.0 and s.enemyLastLoc
            and myHp <= 215 and GetUnitToLocationDistance(bot, s.enemyLastLoc) <= 960 then
            State.critDangerHystUntil = now + 0.55
            return true
        end
        return false
    end
    if H.CanTwoHitRightClickKill(bot, enemy, s) then return false end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local enRange = (enemy:GetAttackRange() or 525)
    local valid = race and race.valid
    local enCastable = K.EnemyCastableRazeCount(enemy, 2.2)
    if valid and (race.canKillNow
        or (race.canKillSoon and enCastable == 0 and dist > enRange + 30)
        or (race.canKillSoon and not race.heCanKillNow and myHp > K.EnemyBurstVs(bot, enemy, dist, 0.65, false) + 45)) then
        return false
    end
    local hystPad = (now < (State.critDangerHystUntil or -100)) and 85 or 0
    local oneRaze = K.EnemyCastableRazeDamage(bot, enemy, 1, nil, 2.2)
    local oneRazeSoon = K.EnemyCastableRazeDamage(bot, enemy, 1, nil, 3.8)
    local twoRaze = K.EnemyCastableRazeDamage(bot, enemy, 2, nil, 2.2)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local outMatched = valid and (race.heHasBootsLead or ((enemy:GetLevel() or 1) > (bot:GetLevel() or 1)))
    -- `9070869385.dem` `05:06.2–05:09.8` `685u` Bullseye Trap Fix + `auto-20261102-0007` `10:12.07` (`163 HP` @ `d=905u`,
    -- `raze3` CD `2.3s` -> `898u` Death) Fix:
    -- When literally ONE `Shadowraze3` (`950u` reach) kills us within `3.8s` (`oneRazeLethalSoon`), NEVER drop
    -- `safeRadiusForHp` below `1,065u` just because `far` still has `1.6..3.8s` left on cooldown!
    local farOnCdCrit = K.EnemyRazeReadyIn("far") > 1.5
    local midOnCdCrit = K.EnemyRazeReadyIn("mid") > 1.5
    local actualMaxRazeSafe = K.EnemyMinSafeDistance(enemy, 1.4)
    local farReadySoonLethal = (K.EnemyRazeReadyIn("far") <= 3.8)
        and (K.EnemyManaBudget(enemy, true) >= 75)
        and (myHp <= oneRazeSoon + 55)
    local safeRadiusForHp
    if enCastable == 0 and not farReadySoonLethal then
        -- Manaless/0-coil enemy (`10-18 MP` in `9069188041.dem` `03:39-03:49`): threat reach is ONLY his right-click!
        safeRadiusForHp = enRange + ((myHp <= 165) and 175 or 135) + hystPad
    elseif myHp <= 155 or farReadySoonLethal or (myHp <= oneRaze + 45 and not farOnCdCrit) then
        safeRadiusForHp = math.max(1065, enRange + 420, (race and race.minSafeDist or 960) + 60) + hystPad
    elseif myHp <= oneRaze + 45 then
        safeRadiusForHp = math.max(enRange + 135, actualMaxRazeSafe + 35) + hystPad
    elseif outMatched and myHp <= twoRaze + enAtk * 1.15 then
        safeRadiusForHp = (farOnCdCrit and math.min(735, math.max(enRange + 65, actualMaxRazeSafe + 20)) or 965) + hystPad
    elseif myHp <= twoRaze + 35 then
        safeRadiusForHp = (farOnCdCrit and math.min(725, math.max(enRange + 55, actualMaxRazeSafe + 15)) or 955) + hystPad
    else
        safeRadiusForHp = enRange + 145 + hystPad
    end

    -- Stage A runs BEFORE `RunSacredCS`: trigger ONLY on genuine short-horizon (`<= 1.25s`) lethal threat!
    -- Include ACTUAL aggroed enemy lane creep DPS (`auto-20261031-0230` `00:59.3-01:02.1` Fix: `3` Radiant creeps = `45 DPS`,
    -- and `177 HP > 175 HP` let Lvl-1 Bot re-enter `d=87u` vs Lvl-2 Human + 3 melee creeps!).
    local aggroCreepDps = 0
    local noAllyShieldCrit = #(s and s.allyCreeps or {}) == 0
    local closeEnCntCrit, hasSiegeCrit = 0, false
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(ec) and ec:IsAlive() then
            local dcCrit = GetUnitToLocationDistance(bot, ec:GetLocation())
            if dcCrit <= 265 then
                closeEnCntCrit = closeEnCntCrit + 1
                if (ec:GetMaxHealth() or 0) >= 800 then hasSiegeCrit = true end
            end
            if (ec.GetAttackTarget and ec:GetAttackTarget() == bot) or (noAllyShieldCrit and dcCrit <= 225) then
                local ecRange = (ec.GetAttackRange and ec:GetAttackRange()) or 100
                aggroCreepDps = aggroCreepDps + ((ecRange > 300) and 14 or 15)
            end
        end
    end
    if aggroCreepDps < 30 and (closeEnCntCrit >= 4 or (hasSiegeCrit and closeEnCntCrit >= 3)) then
        local allyTankHpCrit = 0
        for _, ac in pairs((s and s.allyCreeps) or {}) do
            if U.CanQuery(ac) and ac:IsAlive() and ((ac.GetAttackRange and ac:GetAttackRange()) or 100) < 250
                and GetUnitToLocationDistance(bot, ac:GetLocation()) <= 360 then
                allyTankHpCrit = allyTankHpCrit + (ac:GetHealth() or 0)
            end
        end
        if allyTankHpCrit < 160 then
            aggroCreepDps = math.max(aggroCreepDps, closeEnCntCrit * 12 + (hasSiegeCrit and 16 or 0))
        end
    end
    local myStNow, myRemNow = U.GetShadowrazeDebuff(bot)
    local enAppNow = U.EnemyApproachSpeed(bot, enemy)
    local burstHorizon = (dist >= 645 and enAppNow < 65 and (myStNow or 0) <= 1 and myHp >= 390 and K.EnemyRazeReadyIn("far") > 4.0) and 0.65 or 1.25
    local burst125 = K.EnemyBurstVs(bot, enemy, dist, burstHorizon, false) + aggroCreepDps * burstHorizon
    local burstSafetyMargin = enAtk * 0.90
    local enManaPoolCrit = (enemy:GetMana() or 0) + U.GetMangoMana(enemy)
    local domPostureCrit = K.HasDominantRightClickPosture and K.HasDominantRightClickPosture(bot, enemy, s)
    -- `v7.9.15` + `v7.9.30-pro` (`auto-20261109-0026` `3:41..3:43` `tk=9580..9636` `45 HP` `R1545` False-Panic CS Fix!):
    --   1. Compute `stackDangerRadius` from Enemy's ACTUAL off-cooldown Shadowraze reach (`K.EnemyMinSafeDistance(enemy, 1.5)`):
    --      when Enemy ALREADY spent BOTH `E(700)` and `W(450)` (`only Q(200) [450u] ready!`), `stackDangerRadius` is `515u`,
    --      NEVER `765u + 85u = 850u` (`which forced `523 HP` SF to flee to `848u` while `45 HP` `R1545` got denied!`)!
    --   2. Require `enCastable >= 2` before checking `twoRaze + 75`.
    local actualStackSafe = K.EnemyMinSafeDistance(enemy, 1.5)
    local stackDangerRadius = (actualStackSafe > 0) and math.min(965, actualStackSafe + 20) or 0
    if (myStNow or 0) >= 1 and (myRemNow or 0) > 0.25
        and enManaPoolCrit >= 75 and not domPostureCrit
        and stackDangerRadius > 0
        and ((myStNow or 0) >= 2
            or ((myRemNow or 0) <= 2.15 and enCastable >= 2 and myHp <= twoRaze + 145)
            or (enCastable >= 2 and enManaPoolCrit >= 150 and myHp <= twoRaze + 75)
            or (enCastable >= 1 and myHp <= oneRaze + enAtk * 1.45 + 55))
        and not (valid and (race.canKillNow or race.canKillSoon)) and dist < stackDangerRadius then
        State.critDangerHystUntil = now + 0.45
        return true
    end
    -- `v7.9.30-pro` (`auto-20261109-0026` `6:09.6..6:14.5` `tk=14032..14178` River Boots-Disadvantage Rundown Disengage!):
    -- When a `+25..45 MS` Boots enemy SF (`enMS >= myMS + 25`) with a `>= 180 HP` lead engages our bootless SF off our own
    -- Highground (`>= 780u` from `allyT1`), he lands `2–3` extra chase right-clicks up the ramp; disengage immediately once
    -- `myHp <= oneRaze + 3.0 * enAtk + 75` (`e.g. 481 HP vs 908 HP Boots SF`) instead of turning back in the river!
    local myMSCrit = bot:GetCurrentMovementSpeed() or 305
    local enMSCrit = enemy:GetCurrentMovementSpeed() or 305
    if enMSCrit >= myMSCrit + 25
        and ((enemy:GetHealth() or 999) >= myHp + 180)
        and not H.IsOnOwnMidHighground(bot, bot:GetLocation())
        and not (valid and (race.canKillNow or race.canKillSoon))
        and dist < 690 then
        local ownT1Crit = (s and s.allyT1Loc) or P.GetT1Close(bot)
        local dOwnT1Crit = ownT1Crit and U.DistanceBetweenLocations(bot:GetLocation(), ownT1Crit) or 9999
        if dOwnT1Crit >= 780 and myHp <= (oneRaze + enAtk * 3.0 + 75 + aggroCreepDps * 1.5) then
            State.critDangerHystUntil = now + 0.65
            return true
        end
    end
    local myPotManaCrit = (bot:GetMana() or 0) + U.GetMangoMana(bot)
    -- `v7.9.10-pro` (`2048 @ 04:41..04:56` `335 -> 179 HP` Dry-Mana `< 75 MP` Outer-`E` Standoff Fix!):
    -- 1. NEVER treat `dominatingOneCoilTrade` as true when we have `< 75 MP` (`0` coils) outside right-click range (`dist > enRange + 55`),
    --    where enemy SF gets a 100% free `700u` `Shadowraze3` without taking a single right-click back!
    -- 2. When we have `0` coils (`myPotManaCrit < 75`), enemy SF has `>= 75 MP` + `far` ready (`<= 1.5s`), and 1 coil + follow-up
    --    auto puts us into lethal (`myHp <= oneRaze + enAtk * 2.2 + 80`), maintain strict `>= 985u` outer-`E` standoff!
    if myPotManaCrit < 75 and enManaPoolCrit >= 75 and not farOnCdCrit
        and myHp <= (oneRaze + enAtk * 2.2 + 80)
        and not (valid and race.canKillNow)
        and dist < 985 then
        State.critDangerHystUntil = now + 0.55
        return true
    end
    local dominatingOneCoilTrade = (enManaPoolCrit < 150)
        and myHp >= 380
        and (myPotManaCrit >= 75 or dist <= enRange + 55)
        and aggroCreepDps <= 15
        and not outMatched
        and not (valid and race.heCanKillNow)
        and K.AttackDamageVs(bot, enemy) >= enAtk + 12
    if valid and not race.canKillSoon and not dominatingOneCoilTrade
        and (race.heCanKillNow or ((myHp - burst125) <= burstSafetyMargin))
        and dist < safeRadiusForHp then
        State.critDangerHystUntil = now + 0.55
        return true
    end
    local closeHpFloor = math.max(195, enAtk * (outMatched and 2.85 or 2.45) + aggroCreepDps * 1.65)
    if dist < safeRadiusForHp and (myHp <= closeHpFloor or farReadySoonLethal) then
        State.critDangerHystUntil = now + 0.65
        return true
    end
    -- `v7.9.12-pro` (`2319 @ 06:34.67..06:36.00` `345/1050 HP` Behind-`allyT1` Flank Cut-Off Protection!):
    -- When a healthier, armed enemy SF (`enManaPoolCrit + 8 >= 140` or `enCastable >= 1`) flanks around/past our `allyT1`
    -- (`d(eLoc, fnt) <= d(allyT1, fnt) + 450` and skirting outside `allyT1`'s `700u` range `d(eLoc, allyT1) > 685`) while we
    -- are wounded (`myHp <= 420` or `hpPct <= 0.40`), NEVER let `RunSacredCS` pull us SW into the flanker (`dist < 1,030u`)!
    if s and s.allyT1Alive and s.allyT1Loc and not (valid and (race.canKillNow or race.canKillSoon)) then
        local fntFlank = P.GetFountain(bot)
        local eLocFlank = enemy:GetLocation()
        local myMaxFlank = math.max(1, bot:GetMaxHealth() or 700)
        local dEnT1Flank = U.DistanceBetweenLocations(eLocFlank, s.allyT1Loc)
        local dEnFntFlank = U.DistanceBetweenLocations(eLocFlank, fntFlank)
        local dT1FntFlank = U.DistanceBetweenLocations(s.allyT1Loc, fntFlank)
        if (myHp <= 420 or (myHp / myMaxFlank) <= 0.40)
            and ((enemy:GetHealth() or 999) > myHp + 200)
            and (enManaPoolCrit + 8 >= 140 or enCastable >= 1)
            and dEnT1Flank > 685 and dEnT1Flank <= 1450
            and dEnFntFlank <= (dT1FntFlank + 780)
            and dist < 1030 then
            State.critDangerHystUntil = now + 0.65
            return true
        end
    end
    return false
end

-- Stage B (IMMEDIATELY BELOW RunSacredCS, ABOVE ALL OFFENSIVE COMBAT HANDLERS):
-- Also immediately kites back out of river lowground (`uphillPenalty`) / multi-creep aggro when enemy SF
-- auto-attacks us at early levels (`0:00` opening `HUD 01:01-01:08` 6-unanswered-autos fix)!
-- Stage B0 (`9055695956.dem` `0:00` `tk=4064` Even-Footing Anti-Conveyor Counter-Raze & `1:52` `tk=6360` Dry-Enemy Punish):
--   1. When enemy SF lands an opening coil/close trade (`myStacks >= 1` or close hero hit) while we are healthy on mana & HP
--      and behind on stacks (`enStacks < max(1, myStacks)`), NEVER run backward down his `200->450->700u` triple-raze ray
--      unanswered — immediately fire our best-centered counter-Shadowraze (`Q`/`W`/`E`) FIRST to equalize stacks!
--   2. When enemy hero is completely DRY on mana (`enemy:GetMana() < 75` => `0` counter-razes possible, `1:52` `SHA MP=20`)
--      and we hold `>= 135 MP` with no imminent creep CS, punish his walk-up immediately with our dead-center coil!
function H.HandleMirrorRazeCounterAndDryPunish(bot, s, earlyRace, csWaveBusy)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    -- Note: allow `< 75 MP` entry at top of `HandleMirrorRazeCounterAndDryPunish` so proactive `Mango`/`Wand` top-up & Salve break run!
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 2 then return false end

    local myHp = bot:GetHealth() or 0
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 1)
    local twoEnRaze = K.EnemyRazeDamage(bot, enemy, 2)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local unsafeSoon = earlyRace and earlyRace.valid and earlyRace.heCanKillSoon
    if earlyRace and earlyRace.valid and earlyRace.heCanKillNow then return false end

    local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    myStacks = myStacks or 0
    myRem = myRem or 0
    local enStacks = U.GetShadowrazeDebuff(enemy) or 0
    local recentlyHit = (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 1.35)) or false

    local myMana = bot:GetMana() or 0

    -- Immediate Enemy `modifier_flask_healing` Cancel (`0050` `01:44.5`: enemy healed `395 HP` right in front of us at `796u`!):
    if enemy:HasModifier("modifier_flask_healing") and danger == 0
        and myHp > K.EnemyBurstVs(bot, enemy, dHero, 0.9, false) + 85 then
        if dHero <= (bot:GetAttackRange() or 500) + 175 then
            if H.IssueHeroAttack(bot, enemy) then
                State.actionTaken = true
                return true
            end
        elseif dHero <= 935 then
            if myMana < 75 and K.MyReadyRazeCount(bot, true) >= 1 and H.TryUseBurstManaItem(bot, true) then
                return true
            end
            if myMana >= 75 then
                for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            return true
                        end
                    end
                end
            end
        end
    end

    if myMana < 75 and K.MyReadyRazeCount(bot, true) < 1 then return false end

    local outRazedTier = (earlyRace and earlyRace.valid and earlyRace.outRazedTier)
        or (U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy)) or false
    local nearSpike = (earlyRace and earlyRace.valid and earlyRace.nearLevelSpike)
        or (U.IsNearLevelSpike and U.IsNearLevelSpike(bot, enemy)) or false

    -- Even-footing mirror answer ONLY on a FRESH opening hit (`myRem > 2.2` for 6.0s 7.41f debuff, NEVER when out-razed in tier!)
    -- Bracer-invariant HP check (`0.44 * maxHp` instead of `0.66 * maxHp`, which demanded `697 HP` with `2x Bracer` at `03:14`!)
    local mirrorCounter = (not unsafeSoon)
        and (not outRazedTier)
        and (not nearSpike)
        and (myHp >= twoEnRaze + enAtk * 1.65 + 55)
        and (myHp >= myMaxHp * 0.44)
        and ((myStacks >= 1 and myRem > 2.2) or (recentlyHit and dHero <= 440))
        and (enStacks < math.max(1, myStacks))
        and myHp >= (enemy:GetHealth() or 9999) * 0.58
        and dHero <= 915

    local approachSpd = U.EnemyApproachSpeed(bot, enemy)
    local outMatchedRunDown = (((enemy:GetLevel() or 1) > (bot:GetLevel() or 1))
        or (earlyRace and earlyRace.valid and earlyRace.heHasBootsLead))
        and approachSpd >= 95
        and myHp < (twoEnRaze + enAtk * 1.6 + 65)

    local enImmediateBurst = K.EnemyBurstVs(bot, enemy, dHero, 0.80, false)
    -- `9080457787.dem` `04:52.67` (`tk=12180`) & `05:26.87` (`tk=13206`) Enemy Whiff Punish (`Q`/`W`/`E`):
    -- Previously ONLY `K.EnemyRazeReadyIn("far") > 4.5` triggered reciprocity, so when the Immortal SF whiffed `W(450)`
    -- right at `dHero = 415..550u`, Bot SF failed to punish his `10s` `W(450)` cooldown!
    local midWhiffPunish = (dHero >= 355 and dHero <= 685)
        and danger == 0
        and not outMatchedRunDown
        and (not outRazedTier or myHp >= twoEnRaze + 120)
        and myHp > enImmediateBurst + 75
        and (K.EnemyRazeReadyIn("mid") > 4.5)
    local nearWhiffPunish = (dHero <= 435)
        and danger == 0
        and not outMatchedRunDown
        and myHp > enImmediateBurst + 75
        and (K.EnemyRazeReadyIn("near") > 4.5)

    -- Patch 7.41f: `modifier_nevermore_shadowraze_debuff` starts at `6.000s` (`myRem > 4.35` = hit within last `1.65s`!)
    local farRazeReciprocity = (dHero >= 645 and dHero <= 925)
        and danger == 0
        and not outMatchedRunDown
        and (not outRazedTier or myHp >= twoEnRaze + 140)
        and myHp > enImmediateBurst + 95
        and ((K.EnemyRazeReadyIn("far") > 4.5 and (not csWaveBusy or (myStacks >= 1 and myRem > 4.35)))
            or (myStacks >= 1 and myRem > 4.35 and enStacks < myStacks))

    -- Case B (`Proactive Step-In Edge Intercept`): `U.FacingCos` now implemented in `utils.lua`!
    local enFacingMe = (U.FacingCos and U.FacingCos(enemy, bot:GetLocation()) or 0) >= 0.78
    local proactiveEdgeIntercept = (not csWaveBusy)
        and (not unsafeSoon)
        and (not outRazedTier)
        and (not nearSpike)
        and danger == 0
        and not outMatchedRunDown
        and myStacks == 0
        and dHero >= 695 and dHero <= 905
        and approachSpd > 50
        and enFacingMe
        and myHp > K.EnemyRazeDamage(bot, enemy, 1) + 155
        and enStacks >= myStacks

    -- `< 75 MP` enemy SF has ZERO coils available in reply (`9056469656.dem` `01:42–02:02` `SHA MP = 12..44`, `Bot MP = 97..131`!):
    -- punish any walk-up immediately with our dead-center coil whenever we hold `>= 75 MP` and survive physical reply!
    local enTotalMana = (enemy:GetMana() or 0) + U.GetMangoMana(enemy)
    local dryEnemyPunish = (not csWaveBusy)
        and (not unsafeSoon)
        and danger == 0
        and (enTotalMana < 75)
        and myMana >= 75
        and myHp >= math.max(215, enAtk * 2.7 + 45)
        and dHero <= 915

    -- Zero-turn facing-verified defensive stack equalizer (refines `hgfhgh` `HandleStackedDefensiveRaze` WITHOUT
    -- its blind backward-cast bug): when we ALREADY face `enemy` (`angleDiff <= MAX_ANGLE_TO_CAST`, `0` turn ticks!)
    -- with `>= 1` enemy stack (`myRem > 2.2s`) and `enStacks == 0`, answer immediately if safe from burst!
    local myAngleNow = U.GetAngleDifference(bot, U.PredictPosition(enemy, C.RAZE.CAST_POINT))
    local instantFacingStackReply = (not csWaveBusy)
        and (not unsafeSoon)
        and danger == 0
        and not outMatchedRunDown
        and myStacks >= 1 and myRem > 2.2
        and enStacks == 0
        and myAngleNow <= C.RAZE.MAX_ANGLE_TO_CAST
        and myHp > enImmediateBurst + 105
        and dHero <= 900

    if not mirrorCounter and not farRazeReciprocity and not midWhiffPunish and not nearWhiffPunish
        and not proactiveEdgeIntercept and not dryEnemyPunish and not instantFacingStackReply then
        return false
    end

    if myMana < 75 then
        -- `v7.9.25-pro` (`auto-20261108-1609` `00:42.13` Level-1 Starting-Mango Conservation):
        -- At Shadowraze Level 1 (`62` magic dmg!), NEVER pop an Enchanted Mango (`+100 MP`) for a non-lethal counter-raze!
        local wRefM = H.GetRazeAbilityByLabel(bot, "mid")
        local rLvlM = (wRefM and wRefM.GetLevel and wRefM:GetLevel()) or 1
        local enHpM = enemy:GetHealth() or 9999
        local allowMangoPop = (rLvlM >= 2)
            or (enHpM <= (U.GetNRazeDamage(bot, enemy, 1) + K.AttackDamageVs(bot, enemy) + 45))
            or dryEnemyPunish
        if not bot:HasModifier("modifier_flask_healing") and H.TryUseBurstManaItem(bot, allowMangoPop) then
            return true
        end
        return false
    end

    -- `auto-20261102-0007` (`4:37`, `8:22`, `10:02.7`) + `auto-20261102-0139` (`3:58.80` Courier-ETA & Low-HP Fix):
    -- Include incoming courier Mangoes (`K.MySustainedManaBudget(bot, 6.5)`) so we NEVER suppress coils when courier
    -- is `<= 6.5s` away with Mangoes, and NEVER block coils vs `< 150 MP` or `<= 1 Raze + 95 HP` enemy!
    local mySustainedMana = (K.MySustainedManaBudget and K.MySustainedManaBudget(bot, 6.5)) or K.MyManaBudget(bot, true)
    local singleCoilTrapRisk = (mySustainedMana < 145)
        and (enTotalMana >= 150)
        and ((enemy:GetHealth() or 9999) > U.GetNRazeDamage(bot, enemy, 1) + 95)
    local lastManaBehindRisk = (mySustainedMana < 145)
        and (enTotalMana >= 75)
        and ((enemy:GetHealth() or 9999) > (bot:GetHealth() or 0) + 110)
        and ((enemy:GetHealth() or 9999) > U.GetNRazeDamage(bot, enemy, 1) + 95)

    for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
        local enemyBandOnCd = (K.EnemyRazeReadyIn(label) or 0) > 4.5
        if (not singleCoilTrapRisk or enemyBandOnCd or (label == "far" and dHero >= 660))
            and (not lastManaBehindRisk or enemyBandOnCd or (label == "far" and dHero >= 775)) then
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab)
                and (dryEnemyPunish or not H.WouldBreakEarlyManaReserve(bot, enemy, ab)) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    return true
                end
            end
        end
    end
    return false
end

-- Stage B0.5 (`9056469656.dem` `01:36–02:02` Soul-Lead Passivity & `02:29–02:35` `284 HP / 15 MP` Dry-Enemy Free-Kill Fix):
-- Runs right AFTER `RunSacredCS` (never drops a 0.000s lane CS!) and BEFORE `InLosingHeroTrade` / `TryWaveSafeStaticTango`:
--   1. When enemy has `< 75 MP` (`0` Shadowrazes possible!) and we hold equal/superior damage or HP lead (`01:42–02:02`
--      `Bot 8–10 souls, Lvl 3` vs `Sha 4–5 souls, Lvl 2, 12–44 MP`; `02:32.92` `Bot 514 HP, 13S` vs `Sha 284 HP, 15 MP`),
--      NEVER let them right-click us for free (`0 vs 10` autos!) or walk away on `284 HP` — trade right-clicks decisively!
--   2. Also right BEFORE `RunSacredCS`, `H.HandleActiveLethalDuelFinish` prevents `RunSacredCS` from stealing our fatal
--      swing onto a lane creep (`04:07.32` `U315` creep hit when `Sha = 178 HP` at `d = 171.9u`!).
function H.HandleActiveLethalDuelFinish(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local enHp = enemy:GetHealth() or 9999
    -- `v7.9.29-pro` Fadeaway Lethal-In-Air Tower Peel (`auto-20261108-2131` `04:11` Zero-Tower-Hit Execution):
    -- Once a `0%`-miss lethal right-click projectile from `bot` is ALREADY in flight toward `enemy` near `enemyT1`,
    -- peel outside `920u` immediately instead of letting `Action_AttackUnit` walk SF inside `870u` tower range!
    if s.enemyT1Alive ~= false and s.enemyT1Loc then
        local bLocFade = bot:GetLocation()
        local eLocFade = enemy:GetLocation()
        if U.DistanceBetweenLocations(bLocFade, s.enemyT1Loc) <= 965 and ((bLocFade.z or 0) + 25 >= (eLocFade.z or 0)) then
            local inAirFade = (U.GetOwnInFlightDamageOnHero and U.GetOwnInFlightDamageOnHero(bot, enemy)) or 0
            if inAirFade >= enHp + 3 then
                local peelDir = (bLocFade - s.enemyT1Loc):Normalized()
                bot:Action_MoveToLocation(s.enemyT1Loc + peelDir * 920)
                State.actionTaken = true
                return true
            end
        end
    end
    local myHp = bot:GetHealth() or 0
    local myAtk = math.max(1, K.AttackDamageVs(bot, enemy))
    local enAtk = math.max(1, K.AttackDamageVs(enemy, bot))
    local enPotMana = U.GetPotentialManaForRaze(enemy)

    -- Exact First-Kill Time-To-Kill (`TTK_bot < TTK_enemy`) Solver (`auto-20261023-0119` `00:24.83` @ `42 HP` & `05:25.43` @ `90 HP`!):
    -- Runs BEFORE `InCriticalLethalDanger` so SF NEVER turns its back on a guaranteed kill when `tKillHim` resolves BEFORE enemy lethal!
    local lr = U.SolveLethalRace(bot, enemy, s)
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 2 and myHp < 340 and not (lr and lr.winsFirstKill and lr.tKillHim <= 1.25 and myHp >= 145) then
        return false
    end

    local creepsOnMeNow = 0
    for _, ec in pairs(s.enemyCreeps or {}) do
        if ec and U.CanQuery(ec) and ec:IsAlive() and ec.GetAttackTarget and ec:GetAttackTarget() == bot
            and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 260 then
            creepsOnMeNow = creepsOnMeNow + 1
        end
    end
    local oneShotDryKill = (enPotMana < 75)
        and (enHp <= myAtk * 1.08)
        and (myHp > enAtk + creepsOnMeNow * 12 + 12 or GameTime() < (State.oneShotFinishUntil or 0))
    -- `v7.9.7-pro` + `v7.9.8-pro` (`1630 @ 01:32.6..01:36.2` `3–28 HP` Escape at `156 HP` vs Unused Mango Fix!):
    local oneShotTankKill = U.CanOneShotEnemyHero(bot, enemy)
        and (myHp >= K.EnemyBurstVs(bot, enemy, math.min(d, 500), 1.15, false) + 8)
    local anyOneShotKill = oneShotDryKill or oneShotTankKill
    local bLocDuel = bot:GetLocation()
    local eLocDuel = enemy:GetLocation()
    local uphillOneShotChase = anyOneShotKill
        and (((bLocDuel.z or 0) + 25 < (eLocDuel.z or 0))
            or ((U.GetOwnInFlightDamageOnHero and U.GetOwnInFlightDamageOnHero(bot, enemy) or 0) > 0))
        and ((not s.enemyT1Alive) or (not s.enemyT1Loc) or U.DistanceBetweenLocations(bLocDuel, s.enemyT1Loc) >= 930)
    local oneShotReachPad = uphillOneShotChase and 330 or 250
    local extendedDryKillReach = anyOneShotKill and oneShotReachPad
        or ((enPotMana < 75 and enHp <= myAtk * 2.6 and myHp >= 185) and 175
            or ((lr and lr.winsFirstKill and lr.tKillHim <= 2.35) and 380 or 85))
    if d > (bot:GetAttackRange() or 500) + extendedDryKillReach then return false end

    local myOneRaze = U.GetNRazeDamage(bot, enemy, 1)
    local hasReadyRaze = K.MyReadyRazeCount(bot, true) >= 1
    local myShots = math.ceil(enHp / myAtk)
    local enShots = math.ceil(myHp / enAtk)
    local dryWinningFinish = myShots <= 4
        and (enPotMana < 75 or not (earlyRace and earlyRace.valid and (earlyRace.heCanKillNow or earlyRace.heCanKillSoon)))
        and (myShots + 1 <= enShots)
        and myHp >= 185
    local ttkFirstKillWin = (lr and lr.winsFirstKill and lr.tKillHim <= 2.35)
    local duelLethalNow = anyOneShotKill
        or ttkFirstKillWin
        or (enHp <= myAtk * 3.1 and myHp >= math.max(165, K.EnemyBurstVs(bot, enemy, d, 1.15, false) + 25))
        or (hasReadyRaze and enHp <= myOneRaze + myAtk * 1.65 and myHp >= math.max(165, K.EnemyBurstVs(bot, enemy, d, 0.95, false) + 20))
        or dryWinningFinish
    if not duelLethalNow then return false end
    if anyOneShotKill then
        State.oneShotFinishUntil = GameTime() + 1.15
    end

    -- Lock in kill commitment & clear ALL retreat/flee states immediately!
    H.ClearForcedRetreat()
    State.fleeUntil = 0
    State.critDangerHystUntil = 0
    State.survivalUntil = 0
    State.survivalLoc = nil

    -- Instant `0.00s` Emergency Burst EHP (`9058240714.dem` `1:54.03` Fix!):
    --   * `Magic Stick / Wand` (`0` attack damage loss!) fires at `lr.needStickHeal` or `<= 35% HP`.
    --   * `Faerie Fire` (`-2` permanent attack damage!) fires STRICTLY ONLY at `lr.needFaerieHeal` (`<= 0.85s` lethal) or `<= 15% HP`!
    local maxHpNow = math.max(1, bot:GetMaxHealth() or 1)
    if lr and (lr.needStickHeal or lr.needFaerieHeal or (myHp <= (lr.enDmgBeforeDeath or 0) + 75 and myHp <= maxHpNow * 0.35)) then
        local wand = U.GetActiveItemByName(bot, "item_magic_wand") or U.GetActiveItemByName(bot, "item_magic_stick")
        if wand and wand:IsFullyCastable() and U.GetStickCharges(bot) > 0 then
            bot:Action_UseAbility(wand)
            State.commitKillUntil = GameTime() + 2.5
            State.actionTaken = true
            return true
        end
        if lr.needFaerieHeal or myHp <= maxHpNow * 0.15 then
            local ff = U.GetActiveItemByName(bot, "item_faerie_fire")
            if ff and ff:IsFullyCastable() then
                bot:Action_UseAbility(ff)
                State.commitKillUntil = GameTime() + 2.5
                State.actionTaken = true
                return true
            end
        end
    end

    -- If a single right-click ALREADY kills the enemy (`enHp <= myAtk * 1.08`) inside reach, swing/step IMMEDIATELY (`~0.35s`)
    -- instead of spending `0.55s` + `75 MP` on a raze windup or flip-flopping at `d = 600u` (`9058240714.dem` `2:04.6` `50 HP` fix!):
    local minEnTwD = 9999
    for _, tw in pairs(s.enemyTowers or {}) do
        if tw and tw:IsAlive() then
            local dtTw = GetUnitToLocationDistance(tw, enemy:GetLocation())
            if dtTw < minEnTwD then minEnTwD = dtTw end
        end
    end
    local openRiver1Shot = anyOneShotKill and minEnTwD >= 1060 and danger < 2
    if enHp <= myAtk * 1.08 and d <= (bot:GetAttackRange() or 500) + (anyOneShotKill and oneShotReachPad or 95)
        and (openRiver1Shot or H.CanKinematicallyCatchForAttack(bot, enemy, s.enemyTowers, s.allyCreeps, 1.55)) then
        if H.IssueHeroAttack(bot, enemy) then
            State.prepTarget = nil
            State.lhAttackTarget = nil
            State.commitKillUntil = GameTime() + 2.4
            State.actionTaken = true
            return true
        end
    end

    -- `v7.9.33-pro` (`auto-20261109-0306` `2:39.80` `tk=7700` Pre-Raze Auto-Release Solo-Kill Lock!):
    -- When SF is `<= 0.22s` (`<= 6..7` ticks) from launching a hero bolt and 1 Raze alone does NOT 1-shot `enemy`,
    -- let the bolt release first (`0.000s` backswing cancel!) and snap Raze on the very next tick!
    if H.ShouldFinishNearLaunchHeroAutoBeforeRaze(bot, enemy, earlyRace) then
        State.commitKillUntil = GameTime() + 2.5
        State.actionTaken = true
        return true
    end

    -- Fire lethal/near-lethal centered raze if ready, otherwise lock right-click directly onto enemy hero!
    if (bot:GetMana() or 0) < 75 and K.MyManaBudget(bot, true) >= 75 and hasReadyRaze then
        if H.TryUseBurstManaItem(bot, true) then
            State.commitKillUntil = GameTime() + 2.5
            return true
        end
    end
    if (bot:GetMana() or 0) >= 75 then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    State.commitKillUntil = GameTime() + 2.5
                    return true
                end
            end
        end
        -- `Demo 2` `7:41` + `v7.9.8-pro` (`1630 @ 01:28.5..01:32.0` `155 HP` Auto-Weave Before `R3` Fix!):
        -- When `E(700)` ALONE does NOT kill `enemy` (`enHp > myOneRaze`, e.g. `155 > 116`) while `1 auto + E(700)` IS lethal
        -- (or enemy is OOM `< 75 MP`) AND our right-click is ALREADY off cooldown inside reach (`d <= atkRange + 35`),
        -- weave the `0.38s` auto-attack FIRST, then step back into `E(700)` during attack backswing/cooldown!
        local eAb = bot:GetAbilityByName("nevermore_shadowraze3")
        local _, enRemNow = U.GetShadowrazeDebuff(enemy)
        local mySpaWeave = math.max(0.65, bot:GetSecondsPerAttack() or 1.45)
        local atkReadyForWeave = (GameTime() - (bot:GetLastAttackTime() or -100)) >= (mySpaWeave * 0.85)
        local needAutoBeforeR3 = atkReadyForWeave
            and (enHp > myOneRaze)
            and (enHp <= myOneRaze + myAtk * 1.35 or (enemy:GetMana() or 0) < 75)
            and d <= ((bot:GetAttackRange() or 500) + 35)
            and ((enRemNow or 0) == 0 or (enRemNow or 0) >= 2.25)
        local appClose = math.max(0, U.EnemyApproachSpeed(bot, enemy))
        local myMsClose = math.max(280, (bot.GetCurrentMovementSpeed and bot:GetCurrentMovementSpeed()) or 310)
        local needDist = math.min(680, math.max(545, 505 + appClose * 0.62))
        local tWalkOut = math.max(0, needDist - d) / math.max(30, myMsClose - appClose)
        if eAb and U.IsRazeAbilityCastable(bot, eAb) and not needAutoBeforeR3 and d >= 200 and d < 620
            and myShots >= 3
            and tWalkOut <= 0.85
            and ((enRemNow or 0) == 0 or (enRemNow or 0) >= 0.85) then
            local away = (bot:GetLocation() - enemy:GetLocation()):Normalized()
            bot:Action_MoveToLocation(enemy:GetLocation() + away * (needDist + 65))
            H.ClearMoveCache()
            State.prepTarget = nil
            State.lhAttackTarget = nil
            State.commitKillUntil = GameTime() + 2.2
            State.actionTaken = true
            return true
        end
    end
    -- `v7.9.1` (`9071946472.dem` `02:46.93–02:50.20` 3.27s Stationary Freeze Fix!):
    -- NEVER set `State.actionTaken = true` or return `true` unless `CanKinematicallyCatchForAttack` AND `IssueHeroAttack`
    -- genuinely issued a live C++ attack order! (Previously `towerChaseBlockedEnemy` made `IssueHeroAttack` return `false`
    -- while `HandleActiveLethalDuelFinish` still set `actionTaken = true`, freezing SF for 95 ticks!)
    if not H.CanKinematicallyCatchForAttack(bot, enemy, s.enemyTowers, s.allyCreeps, 1.65) then
        return false
    end
    if H.IssueHeroAttack(bot, enemy) then
        State.prepTarget = nil
        State.lhAttackTarget = nil
        State.commitKillUntil = GameTime() + 2.2
        State.actionTaken = true
        return true
    end
    return false
end

-- `v4.2.0` Multi-Stack Combo Finisher & Anti-`Raze3`-Bait Counter-Geometry
-- Eliminates ALL FOUR replay outplays simultaneously:
--   * Mode A (`Demo 2` `7:41`): 2-stack/3-stack lethal execution INCLUDING `0.15s` step-back `[250..470u] -> 510u` for 3rd-stack `Raze3 (310 dmg)`!
--   * Mode B (`Demo 1` `1:20` & `Demo 2` `7:13.3`): Immediate 2nd/3rd-stack overlap chain (`E -> W` at `[455..670u]`, `Q -> W` at `[210..435u]`)
--     whenever enemy already carries our stack (`enStacks >= 1`) and we survive `0.72s` — NEVER aborting ready `W` to flee!
--   * Mode C (`Demo 2` `7:07` & `Demo 1` `1:40`): Anti-`Raze3`-Bait Outer Kite Punish! When enemy spends long `E (700u)` and runs forward
--     to land `2`-stack `W (450u)`, fire our `E` IN PLACE from `[725..895u]` (NEVER walking into `< 715u`!) and hold `[775..835u]` outside `W`!
function H.HandleMultiStackComboAndAntiBait(bot, s, earlyRace, lethalOrChainOnly)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() or bot:IsSilenced() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 2 then return false end

    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    local myMana = bot:GetMana() or 0
    local potMana = K.MyManaBudget(bot, true)
    local enHp = enemy:GetHealth() or 9999
    local enEffHp = enHp + (U.GetFaerieFireHeal and U.GetFaerieFireHeal(enemy) or 0) + (U.GetStickCharges(enemy, false) * 15)
    local enStacks, enRem = U.GetShadowrazeDebuff(enemy)
    enStacks, enRem = enStacks or 0, enRem or 0
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    myStacks, myRem = myStacks or 0, myRem or 0
    local myAtk = K.AttackDamageVs(bot, enemy)
    local myNextRaze = U.GetNRazeDamage(bot, enemy, 1)

    -- MODE A: Lethal Next-Stack Execution (including `[240..475u] -> 510u` step-back for 3rd-stack `Raze3`,
    -- PLUS `auto-20261102-0139` `3:58.80` Raw-HP Lethal / Faerie-Force Far `E` at `d >= 615u` vs `< 75 MP` enemy!)
    local enPotManaM = U.GetPotentialManaForRaze(enemy)
    local safeRawKillOrFaeriePop = (enHp <= myNextRaze + 10)
        and ((d >= 615 and enPotManaM < 75) or (myHp > K.EnemyBurstVs(bot, enemy, d, 0.70, false) + 45))
    if potMana >= 75 and myNextRaze > 0 and (enEffHp <= (myNextRaze + (d <= 540 and myAtk * 0.95 or 0)) or safeRawKillOrFaeriePop) then
        local inc065 = K.EnemyBurstVs(bot, enemy, d, 0.65, false)
        if myHp > inc065 + 25 or myNextRaze >= enEffHp or safeRawKillOrFaeriePop then
            H.ClearForcedRetreat()
            State.fleeUntil = 0
            State.critDangerHystUntil = 0
            State.survivalUntil = 0
            State.survivalLoc = nil
            if myMana < 75 and H.TryUseBurstManaItem(bot, true) then
                State.commitKillUntil = GameTime() + 2.5
                return true
            end
            if myMana >= 75 then
                for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            State.commitKillUntil = GameTime() + 2.5
                            return true
                        end
                    end
                end
                local eAb = bot:GetAbilityByName("nevermore_shadowraze3")
                local appClose = math.max(0, U.EnemyApproachSpeed(bot, enemy))
                local myMsClose = math.max(280, (bot.GetCurrentMovementSpeed and bot:GetCurrentMovementSpeed()) or 310)
                local needDist = math.min(680, math.max(545, 505 + appClose * 0.62))
                local tWalkOut = math.max(0, needDist - d) / math.max(30, myMsClose - appClose)
                if eAb and U.IsRazeAbilityCastable(bot, eAb) and d >= 200 and d < 620
                    and math.ceil(enHp / math.max(1, myAtk)) >= 3
                    and tWalkOut <= 0.85 and (enRem == 0 or enRem >= 0.85) then
                    local away = (bot:GetLocation() - enemy:GetLocation()):Normalized()
                    local stepBackPt = enemy:GetLocation() + away * (needDist + 65)
                    bot:Action_MoveToLocation(stepBackPt)
                    H.ClearMoveCache()
                    State.commitKillUntil = GameTime() + 2.2
                    State.actionTaken = true
                    return true
                end
            end
        end
    end

    -- MODE B: Immediate Overlap 2nd/3rd-Stack Chain (`Demo 1` `1:20` & `Demo 2` `7:13.3`!)
    -- Strictly requires either:
    --   * enemy ALREADY spent both `far` & `mid` razes (`Demo 1` `1:20` at `d >= 460u` -> `0` counter-razes possible!), OR
    --   * we survive the full `2.2s` combo (`not heCanKillSoon`, `not uphillPenalty`, `myHp > burst22 + 95`), so we NEVER
    --     self-root `0.55s` in river lowground into a lethal L4 triple-raze (`S8` safety preserved 100%!).
    if enStacks >= 1 and enRem >= 0.85 and potMana >= 75 and d <= 905 then
        local nowChain = GameTime()
        local burst22 = K.EnemyBurstVs(bot, enemy, d, 2.2, false)
        local oneHitPhys = bot:GetActualIncomingDamage(enemy:GetAttackDamage() or 55, DAMAGE_TYPE_PHYSICAL)
        local aggroCreeps = 0
        for _, ec in pairs(s.enemyCreeps or {}) do
            if ec and U.CanQuery(ec) and ec:IsAlive() and ec.GetAttackTarget and ec:GetAttackTarget() == bot
                and GetUnitToLocationDistance(bot, ec:GetLocation()) < 340 then
                aggroCreeps = aggroCreeps + 1
            end
        end
        local enAppChain = U.EnemyApproachSpeed(bot, enemy)
        local spinCastDanger = oneHitPhys * ((d <= 720 or enAppChain > 120) and 2.1 or 1.2)
            + aggroCreeps * 26
        local safeSpinHp = (myHp > math.max(225, spinCastDanger + 75))
            and (((enemy:GetLevel() or 1) <= (bot:GetLevel() or 1)) or myHp >= 340)
        local enemySpentMidAndFar = (K.EnemyRazeReadyIn("far") > 2.0 and K.EnemyRazeReadyIn("mid") > 2.0 and d >= 460)
        -- `auto-20261102-0007` `10:06.20` (`tk=51488`, `74.8->75.8 MP`, `610 HP` vs `995 HP` Pursuer `162 deg` Turn-Back Fix!):
        -- NEVER abort an active retreat or spin `> 65 deg` backward into a pursuing higher-HP SF for a non-lethal 2nd stack,
        -- and NEVER spend our last `75 MP` (`potMana < 145`) inside `< 665u` vs a `>= 150 MP` enemy!
        local activelyRetreatingNow = (State.forcedRetreatLoc ~= nil and nowChain < (State.forcedRetreatUntil or 0))
            or (nowChain < (State.fleeUntil or 0))
            or (nowChain < (State.critDangerHystUntil or 0))
            or H.InLosingHeroTrade(bot, s, earlyRace)
        local angToEnChain = U.GetAngleDifference(bot, enemy:GetLocation())
        local myMSChain = bot:GetCurrentMovementSpeed() or 305
        local enMSChain = enemy:GetCurrentMovementSpeed() or 305
        local closeWaveCnt, closeWaveSiege, allyMeleeHpChain = 0, false, 0
        for _, ec in pairs(s.enemyCreeps or {}) do
            if ec and U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 300 then
                closeWaveCnt = closeWaveCnt + 1
                if (ec:GetMaxHealth() or 0) >= 800 then closeWaveSiege = true end
            end
        end
        for _, ac in pairs(s.allyCreeps or {}) do
            if ac and U.CanQuery(ac) and ac:IsAlive() and ((ac.GetAttackRange and ac:GetAttackRange()) or 100) < 250
                and GetUnitToLocationDistance(bot, ac:GetLocation()) <= 360 then
                allyMeleeHpChain = allyMeleeHpChain + (ac:GetHealth() or 0)
            end
        end
        -- `v7.9.15` (`auto-20261106-2139` `05:53.20` `715 HP vs 814 HP` Lvl-5 Bootless vs Lvl-6 Boots + 5 Creeps + Siege Fix):
        -- Never spin backward for a non-lethal 2nd stack when carrying equal/worse stacks while out-leveled / out-booted / behind HP,
        -- or while standing inside an unshielded enemy super-wave (`>= 4` creeps or `3+` with Siege Catapult)!
        local superWaveCollapse = (closeWaveCnt >= 4 or (closeWaveSiege and closeWaveCnt >= 3)) and (allyMeleeHpChain < 180)
        local outMatchedEqualStack = (enStacks == 1 and myStacks >= 1 and myRem > 0.50)
            and (((enemy:GetLevel() or 1) > (bot:GetLevel() or 1)) or (enMSChain >= myMSChain + 25) or (myHp < enHp - 40))
        local unsafeBackwardSpin = (angToEnChain > 65 and enAppChain > 65 and myHp < enHp - 120)
            or (angToEnChain > 55 and (superWaveCollapse or outMatchedEqualStack))
            or (superWaveCollapse and outMatchedEqualStack)
        local singleCoilChainTrap = (enStacks == 1 and potMana < 145 and K.EnemyManaBudget(enemy, true) >= 150 and d < 665)
        local safeToChainHere = safeSpinHp
            and not unsafeBackwardSpin
            and not singleCoilChainTrap
            and (enemySpentMidAndFar
                or (not activelyRetreatingNow
                    and myHp > burst22 + 95
                    and myHp >= 260
                    and not (earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or earlyRace.uphillPenalty))))
        if safeToChainHere then
            if H.ShouldFinishNearLaunchHeroAutoBeforeRaze(bot, enemy, earlyRace) then
                State.actionTaken = true
                return true
            end
            if myMana < 75 and not bot:HasModifier("modifier_flask_healing") and H.TryUseBurstManaItem(bot, true) then
                return true
            end
            if myMana >= 75 then
                for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            H.ClearForcedRetreat()
                            State.fleeUntil = 0
                            State.actionTaken = true
                            return true
                        end
                    end
                end
            end
        end
    end

    -- `v7.9.9-pro` + `v7.9.17` (`1814 @ 07:53` & `0354 @ 00:28.60, 00:41.93, 01:12.80, 02:35.73, 02:42.40` Post-Coil & Spent-CD Spacing):
    -- Runs BEFORE `if lethalOrChainOnly then return false end` so `RunSacredCS` & harass handlers NEVER loiter inside `724u`
    -- `Shadowraze2` reach when BOTH our `W(450)` and `E(700)` are spent (`> 1.15s` CD or `< 75 MP`) while Enemy holds `W(450)` ready!
    --   * Subcase C0a (`Spent-Mid/Far Cooldown Disengage`, works for BOTH `myStacks >= 1` AND `myStacks == 0`!):
    --     Hold `>= 855u` (`myStacks >= 1`) or `>= 785u` (`myStacks == 0`, yielding only to `<= 0.26s` imminent last-hit or dominant
    --     right-click kill!) steered along `ownT1 + outward` so SF NEVER wraps around a ramp side-cliff (`(-173, -58)` at `02:35.73`!).
    --   * Subcase C0b (`Lethal Stack-Burst Survival`): `myStacks >= 1` (`myRem > 1.20`) and enemy's next stacked coil + `1.15` autos >= `myHp`!
    if enPotManaM >= 75 then
        local enAtkS = K.AttackDamageVs(enemy, bot)
        local lrStack = U.SolveLethalRace(bot, enemy, s)
        local fastKillOverride = (lrStack and lrStack.winsFirstKill and lrStack.tKillHim <= 1.30)
            or (enHp <= myAtk * 2.05 and d <= (bot:GetAttackRange() or 525) + 45)
        if not fastKillOverride then
            local qAbS = H.GetRazeAbilityByLabel(bot, "near")
            local wAbS = H.GetRazeAbilityByLabel(bot, "mid")
            local eAbS = H.GetRazeAbilityByLabel(bot, "far")
            local qReadyS = qAbS and qAbS:GetLevel() > 0 and (qAbS:GetCooldownTimeRemaining() or 0) <= 0.35 and (bot:GetMana() or 0) >= 75
            local wOnCdS = (not wAbS) or wAbS:GetLevel() == 0 or (wAbS:GetCooldownTimeRemaining() or 0) > 1.15 or (bot:GetMana() or 0) < 75
            local eOnCdS = (not eAbS) or eAbS:GetLevel() == 0 or (eAbS:GetCooldownTimeRemaining() or 0) > 1.15 or (bot:GetMana() or 0) < 75
            local enMidReadyS = K.EnemyRazeReadyIn("mid") <= 1.25
            local enNearReadyS = K.EnemyRazeReadyIn("near") <= 1.05
            local enFarSpentS = K.EnemyRazeReadyIn("far") > 2.0
            local hasLiveMyStack = (myStacks >= 1 and myRem > 1.20)
            local nextStackCoilDmg = hasLiveMyStack and K.EnemyRazeDamage(bot, enemy, 1) or 0
            local stackBurstLethal = hasLiveMyStack and (nextStackCoilDmg + enAtkS * 1.15 >= myHp)
                and ((enMidReadyS and d <= 805) or (enNearReadyS and d <= 515))

            -- `v7.9.28-pro` (`auto-20261108-2049` `0:39` `E774` `39 HP` & `E780` `5 HP` Under-Own-T1 Stack-1 CS Preservation!):
            --   1. Compute `csImmediateNow` and `lowestOwnT1Creep` (`<= 870u` true T1 range) for BOTH `hasLiveMyStack` and unstacked!
            --   2. When Enemy ALREADY spent `Shadowraze3 (far)` (`enFarSpentS == true`), `W(450)`'s max hit circle is `700u` (NOT `860u`!):
            --      - Never trigger `postComboSpentStacked` outside `715u` when `csImmediateNow` is active with a healthy HP cushion!
            --      - Clamp any `enFarSpentS` kite spot within `<= 455u` of `lowestOwnT1Creep` whenever that spot stays `>= 705u` from
            --        `enemy`, so SF stays simultaneously outside `W(450)` (`> 700u`) AND inside `500u` CS range of creeps under T1!
            local csImmediateNow = false
            if not stackBurstLethal then
                if L and L.PeekBestPlan then
                    local csP0, csE0 = L.PeekBestPlan(bot, s)
                    if csP0 and (not csP0.isDeny) and (csE0 or 99) <= 1.15 then
                        csImmediateNow = true
                    elseif (not hasLiveMyStack) and csP0 and (csE0 or 99) <= 1.15 then
                        csImmediateNow = true
                    end
                end
                if not csImmediateNow and L and L.HasImminentCreepCS then
                    local csB0, csEta0, oneHit0 = L.HasImminentCreepCS(bot, s, 0.95, hasLiveMyStack)
                    csImmediateNow = (csB0 and (csEta0 or 1) <= 0.95) or (oneHit0 == true)
                end
            end
            local ownT1LocS = (s and s.allyT1Alive ~= false and s.allyT1Loc) or P.GetT1Tower(bot)
            local twReachS = (C.BALLISTIC and C.BALLISTIC.TOWER_ATTACK_RANGE_C2C) or 870
            local lowestOwnT1Creep, lowestOwnT1Hp = nil, math.huge
            if ownT1LocS then
                for _, ecS in pairs((s and s.enemyCreeps) or {}) do
                    if U.CanQuery(ecS) and ecS:IsAlive() and U.DistanceBetweenLocations(ecS:GetLocation(), ownT1LocS) <= twReachS then
                        local chpS = ecS:GetHealth() or 9999
                        if chpS < lowestOwnT1Hp then
                            lowestOwnT1Hp, lowestOwnT1Creep = chpS, ecS
                        end
                    end
                end
            end
            local eLocNowS = enemy:GetLocation()
            local bLocNowS = bot:GetLocation()
            local healthyStack1Buffer = (not stackBurstLethal)
                and (myHp >= nextStackCoilDmg + enAtkS * 1.85 + 115)
                and (((bLocNowS.z or 0) >= (eLocNowS.z or 0) + 40 and myHp >= enHp + 135) or enFarSpentS)
            local stackedTrigDist = (enFarSpentS and healthyStack1Buffer)
                and ((csImmediateNow or lowestOwnT1Creep ~= nil) and 705 or 740)
                or 820
            local postComboSpentStacked = hasLiveMyStack and wOnCdS and eOnCdS and enMidReadyS
                and d <= stackedTrigDist and (d >= 355 or not qReadyS)
                and not (healthyStack1Buffer and csImmediateNow)
            local readyDefAggroPull0 = false
            if not hasLiveMyStack then
                local nowS0 = GameTime()
                if myHp >= 245 and d >= 540
                    and nowS0 >= (State.myCreepAggroCdUntil or 0)
                    and nowS0 >= (State.lastDefAggroPullAt or -100) + 3.15
                    and U.NeedsLowgroundEquilibriumPull and U.NeedsLowgroundEquilibriumPull(bot, s, earlyRace) then
                    for _, ec0 in pairs((s and s.enemyCreeps) or {}) do
                        if U.CanQuery(ec0) and ec0:IsAlive() and ((ec0.GetAttackRange and ec0:GetAttackRange()) or 100) <= 180
                            and (ec0:GetHealth() or 0) >= 180 and GetUnitToLocationDistance(bot, ec0:GetLocation()) <= 725 then
                            readyDefAggroPull0 = true
                            break
                        end
                    end
                end
            end
            local domRightClick0 = (not hasLiveMyStack) and K.HasDominantRightClickPosture and K.HasDominantRightClickPosture(bot, enemy, s) or false
            local postComboSpentUnstacked = (not hasLiveMyStack) and wOnCdS and eOnCdS and enMidReadyS
                and (not csImmediateNow) and (not readyDefAggroPull0) and (not domRightClick0)
                and d <= 750 and (d >= 365 or not qReadyS)
            if stackBurstLethal or postComboSpentStacked or postComboSpentUnstacked then
                if U.IsAttackingAction(bot) and (stackBurstLethal or d <= 700) then
                    bot:Action_ClearActions(false)
                end
                local eLocS = enemy:GetLocation()
                local bLocS = bot:GetLocation()
                local ownT1S = (s and s.allyT1Loc) or P.GetT1Close(bot) or P.GetFountain(bot)
                local outDirS = (U.DistanceBetweenLocations(bLocS, eLocS) > 1) and (bLocS - eLocS):Normalized() or (ownT1S - eLocS):Normalized()
                local fntS = P.GetFountain(bot)
                local kiteDistS = stackBurstLethal and 865
                    or ((postComboSpentStacked and enFarSpentS and healthyStack1Buffer) and 750
                        or (postComboSpentStacked and 860 or 858))
                local refHomeS = (U.DistanceBetweenLocations(ownT1S, eLocS) >= kiteDistS) and ownT1S or fntS
                local t1DirS = (U.DistanceBetweenLocations(refHomeS, eLocS) > 1) and (refHomeS - eLocS):Normalized() or outDirS
                local blendDirS = (outDirS * 0.45 + t1DirS * 0.55):Normalized()
                local rawKiteS = eLocS + blendDirS * kiteDistS
                if (not stackBurstLethal) and enFarSpentS and lowestOwnT1Creep then
                    local cLocKeepS = lowestOwnT1Creep:GetLocation()
                    local keepRangeS = math.max(415, (bot:GetAttackRange() or 500) - 45)
                    if U.DistanceBetweenLocations(rawKiteS, cLocKeepS) > keepRangeS then
                        local clampedS = cLocKeepS + (rawKiteS - cLocKeepS):Normalized() * keepRangeS
                        if U.DistanceBetweenLocations(clampedS, eLocS) >= 705 then
                            rawKiteS = clampedS
                        elseif U.DistanceBetweenLocations(cLocKeepS, eLocS) > 1 then
                            local collinS = cLocKeepS + (cLocKeepS - eLocS):Normalized() * keepRangeS
                            if U.DistanceBetweenLocations(collinS, eLocS) >= 705 then
                                rawKiteS = collinS
                            end
                        end
                    end
                end
                local kiteSpotS = U.EnsurePassable and U.EnsurePassable(bot, rawKiteS, blendDirS) or rawKiteS
                State.urgentMoveOverride = true
                H.SmartMove(bot, kiteSpotS, 25, true)
                State.urgentMoveOverride = false
                State.actionTaken = true
                return true
            end
        end
    end

    if lethalOrChainOnly then return false end

    -- MODE C: Anti-`Raze3`-Bait Outer Kite Punish (`Demo 2` `7:07`, `Demo 1` `1:40`, `1814 @ 07:53`, & `0210 @ 00:25..05:25` Fix!)
    -- Enemy just spent long `Shadowraze3` (`EnemyRazeReadyIn("far") > 4.0`) and still holds `Shadowraze2` (`<= 724u` hull edge) + mana:
    --   1. If in `[690..905u]` and our `far` raze is ready: fire `Shadowraze3` IN PLACE immediately!
    --   2. `v7.9.13-pro` Stand-Ground Parity Gate (`0210 @ 00:25, 00:53, 01:44, 02:53, 03:25, 03:55, 04:16, 05:23` Fix!):
    --      Previously, `MODE C` unconditionally ran backward to `815..900u` after EVERY `E(700)` trade whenever `myStacks >= 1`!
    --      When BOTH heroes traded `E` (`enStacks >= myStacks`, our `W(450)` is ready with `>= 75 MP`, not out-leveled on raze tier,
    --      and `myHp >= enHp * 0.85` & `myHp >= 400`), OR when we hold a decisive HP cushion (`myHp >= enHp + 150` & `myHp >= nextStackDmg + 210`),
    --      DO NOT retreat `815..900u` and surrender the wave — hold lane dominance and match his `W(450)` with our `W(450)` + right-clicks!
    local enFarSpent = K.EnemyRazeReadyIn("far") > 4.0
    local enMidThreat = K.EnemyRazeReadyIn("mid") <= 1.5 and K.EnemyManaBudget(enemy, true) >= 75
    if enFarSpent and d >= 355 and d <= 940 then
        local farAb = H.GetRazeAbilityByLabel(bot, "far")
        local midAbC = H.GetRazeAbilityByLabel(bot, "mid")
        local myMidReadyC = midAbC and U.IsRazeAbilityCastable(bot, midAbC)
        local myBothMidFarOnCd = (not (farAb and U.IsRazeAbilityCastable(bot, farAb)))
            and (not myMidReadyC)
        local realFastKill = (earlyRace and earlyRace.valid and earlyRace.canKillNow)
            or (not myBothMidFarOnCd and earlyRace and earlyRace.valid and earlyRace.canKillSoon)
            or (enHp <= myAtk * 2.05)
        local outRazedC = U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy) or false
        local nextStackDmgC = K.EnemyRazeDamage(bot, enemy, 1)
        local enAtkC = K.AttackDamageVs(enemy, bot)
        local canMatchWTrade = myMidReadyC and (not outRazedC)
            and (myHp > nextStackDmgC + enAtkC * 1.45 + 95)
            and (((enStacks or 0) >= myStacks and (enRem or 0) > 0.85 and myHp >= enHp * 0.85 and myHp >= 400)
                or (myHp >= enHp + 150 and myHp >= 440))
        local ownT1LocC = (s and s.allyT1Alive ~= false and s.allyT1Loc) or P.GetT1Tower(bot)
        local twReachC = (C.BALLISTIC and C.BALLISTIC.TOWER_ATTACK_RANGE_C2C) or 870
        local lowestOwnT1C, lowestHpC = nil, math.huge
        if ownT1LocC then
            for _, ecC in pairs((s and s.enemyCreeps) or {}) do
                if U.CanQuery(ecC) and ecC:IsAlive() and U.DistanceBetweenLocations(ecC:GetLocation(), ownT1LocC) <= twReachC then
                    local chpC = ecC:GetHealth() or 9999
                    if chpC < lowestHpC then
                        lowestHpC, lowestOwnT1C = chpC, ecC
                    end
                end
            end
        end
        local healthyOwnT1FarmC = (lowestOwnT1C ~= nil)
            and (myHp >= nextStackDmgC + enAtkC * 1.85 + 115)
        local appNow = math.max(0, U.EnemyApproachSpeed(bot, enemy))
        local enInCastNow = K.EnemyPhase() ~= nil
        local wTrigDistC = healthyOwnT1FarmC and 702 or 728
        local mustKiteWFirst = (myStacks >= 1 and myRem > 0.65 and enMidThreat)
            and (not realFastKill)
            and (not canMatchWTrade)
            and not (enInCastNow and d > wTrigDistC)
            and ((d - appNow * 0.62) < wTrigDistC)
        if mustKiteWFirst then
            local fnt = P.GetFountain(bot)
            local homeDir = (fnt - enemy:GetLocation()):Normalized()
            local kiteRing = enemy:GetLocation() + homeDir * (healthyOwnT1FarmC and 745 or 900)
            if healthyOwnT1FarmC and lowestOwnT1C then
                local cKeepC = lowestOwnT1C:GetLocation()
                local rKeepC = math.max(415, (bot:GetAttackRange() or 500) - 45)
                if U.DistanceBetweenLocations(kiteRing, cKeepC) > rKeepC then
                    local clC = cKeepC + (kiteRing - cKeepC):Normalized() * rKeepC
                    if U.DistanceBetweenLocations(clC, enemy:GetLocation()) >= 705 then
                        kiteRing = clC
                    elseif U.DistanceBetweenLocations(cKeepC, enemy:GetLocation()) > 1 then
                        local colC = cKeepC + (cKeepC - enemy:GetLocation()):Normalized() * rKeepC
                        if U.DistanceBetweenLocations(colC, enemy:GetLocation()) >= 705 then
                            kiteRing = colC
                        end
                    end
                end
            end
            H.SmartMove(bot, kiteRing, 35)
            State.actionTaken = true
            return true
        end
        if d >= 690 and farAb and U.IsRazeAbilityCastable(bot, farAb) and myHp > 195 then
            local action, aim = H.GetRazeActionType(bot, farAb, enemy)
            if action and H.CastOrTurnRaze(bot, farAb, action, aim, enemy) then
                State.actionTaken = true
                return true
            end
        elseif myStacks >= 1 and myRem > 0.65 and enMidThreat and (not realFastKill) and (not canMatchWTrade) then
            local outerHoldC = healthyOwnT1FarmC and 715 or 795
            if d < outerHoldC then
                local fnt = P.GetFountain(bot)
                local homeDir = (fnt - enemy:GetLocation()):Normalized()
                local kiteRing = enemy:GetLocation() + homeDir * (healthyOwnT1FarmC and 745 or 815)
                if healthyOwnT1FarmC and lowestOwnT1C then
                    local cKeepC = lowestOwnT1C:GetLocation()
                    local rKeepC = math.max(415, (bot:GetAttackRange() or 500) - 45)
                    if U.DistanceBetweenLocations(kiteRing, cKeepC) > rKeepC then
                        local clC = cKeepC + (kiteRing - cKeepC):Normalized() * rKeepC
                        if U.DistanceBetweenLocations(clC, enemy:GetLocation()) >= 705 then
                            kiteRing = clC
                        elseif U.DistanceBetweenLocations(cKeepC, enemy:GetLocation()) > 1 then
                            local colC = cKeepC + (cKeepC - enemy:GetLocation()):Normalized() * rKeepC
                            if U.DistanceBetweenLocations(colC, enemy:GetLocation()) >= 705 then
                                kiteRing = colC
                            end
                        end
                    end
                end
                H.SmartMove(bot, kiteRing, 35)
                State.actionTaken = true
                return true
            end
        end
    end

    return false
end

-- `v4.2.0` Close Duel Hero-Attack Lock (`Demo 2` `7:40.87` & `Demo 1` `3:55`) + Equal-State Stand-Ground Anti-Zoning (`Demo 2` 25x)
function H.HandleActiveCloseHeroBrawlAndAntiZone(bot, s, earlyRace, preSacredCS, imminentCreepCS)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 1 then return false end

    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 1)
    local enHp = enemy:GetHealth() or 9999
    local myAtk = K.AttackDamageVs(bot, enemy)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local enPotMana = U.GetPotentialManaForRaze(enemy)
    local enStacks, enRem = U.GetShadowrazeDebuff(enemy)
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    local fightingNow = (enemy.GetAttackTarget and enemy:GetAttackTarget() == bot)
        or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 1.8))

    if preSacredCS then
        -- STRICT Close-Duel Lock: fires ONLY inside active all-in hero duels (`d <= 555u`) so normal lane CS is NEVER touched!
        -- `9058240714.dem` `1:53.50..2:06.30` Root-Cause Fix (`-391 HP` tanking 4 enemy lane creeps + 25% uphill miss!):
        --   * Account explicitly for BOTH `uphillHitFactor` (`0.75` from river `z=0` into HG `z=128`) AND all live enemy creeps
        --     inside Source 2 `460u` aggro radius (`enemyCreepsInAggro * 13.0` DPS) + creeps already hitting `bot` (`creepsHittingBot`)!
        --   * When `creepsHittingBot >= 2` while enemy still needs `> 2` right-clicks (`enHp > myAtk * 2.15`), NEVER spam
        --     `IssueHeroAttack` in a 4-creep ring — immediately fire a 1-tick Source 2 Creep De-Aggro onto an allied creep
        --     and step back behind our allied wave!
        local bLocDuel = bot:GetLocation()
        local eLocDuel = enemy:GetLocation()
        local uphillHitFactor = ((eLocDuel.z or 0) - (bLocDuel.z or 0) >= 90) and 0.75 or 1.0
        local effMyAtk = math.max(1, myAtk * uphillHitFactor)
        local enemyCreepsInAggro, creepsHittingBot, bestDeaggAlly, bestDeaggDist = 0, 0, nil, math.huge
        for _, ec in pairs(s.enemyCreeps or {}) do
            if ec and U.CanQuery(ec) and ec:IsAlive() then
                local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                if dc <= 505 or U.DistanceBetweenLocations(eLocDuel, ec:GetLocation()) <= 460 then
                    enemyCreepsInAggro = enemyCreepsInAggro + 1
                end
                local cRng = (ec.GetAttackRange and ec:GetAttackRange()) or 100
                if dc <= math.max(260, cRng + 55) and ec.GetAttackTarget and ec:GetAttackTarget() == bot then
                    creepsHittingBot = creepsHittingBot + 1
                end
            end
        end
        bestDeaggAlly = H.FindSafeDeaggroAllyCreep(bot, s.allyCreeps, enemy)

        -- `v7.9.7-pro` (`0307 @ 00:53..01:01` `-170 HP` from `4` Radiant melee creeps at `d=303..445u` Fix!):
        -- Check whether a ready raze ACTUALLY covers `d` right now (having `E(700)` ready while standing at `313u` inside
        -- `4` melee creeps does NOT justify eating `52 DPS` of creep hits!), AND at `L1..L4` always de-aggro `3+` melee creeps!
        local hasInBandReadyRaze = false
        if (bot:GetMana() or 0) >= 75 and not bot:IsSilenced() then
            for _, bSpec in ipairs({
                { label = "near", c = 200 },
                { label = "mid",  c = 450 },
                { label = "far",  c = 700 },
            }) do
                local rAb = H.GetRazeAbilityByLabel(bot, bSpec.label)
                if rAb and U.IsRazeAbilityCastable(bot, rAb) and math.abs(d - bSpec.c) <= 258 then
                    hasInBandReadyRaze = true
                    break
                end
            end
        end
        local earlySwarmOverload = (creepsHittingBot >= 3)
            and ((bot:GetLevel() or 1) <= 4)
            and (enHp > myAtk * 2.15 + U.GetNRazeDamage(bot, enemy, 1))
        -- `v7.9.25-pro` (`auto-20261108-1609` `01:36..01:47` & `02:39..02:51` `11` Lost Own-T1 Creeps Root-Cause Fix!):
        --   `preSacredCS` is ONLY for active close hero brawls (`d <= 650u`), NEVER for kiting creeps under our own T1 when
        --   Enemy SF is `700..1100u` away (which preempted `RunSacredCS` every tick and walked SF to `(972, 974)` `870u` away!).
        local nearOwnT1Duel = s.allyT1Alive ~= false and s.allyT1Loc
            and U.DistanceBetweenLocations(bLocDuel, s.allyT1Loc) <= 780
        local allowPreCsCreepDeaggro = (d <= 650 or fightingNow)
            and not (imminentCreepCS and myHp > 210)
            and not (nearOwnT1Duel and not fightingNow and myHp > 210)
        if allowPreCsCreepDeaggro and creepsHittingBot >= 2 and enHp > myAtk * 2.15 and ((not hasInBandReadyRaze) or earlySwarmOverload) then
            local nowD = GameTime()
            local chaseLockedNow = nowD < ((State.myCreepChaseUntil or 0) - 0.08)
            if State.lastBrawlDeaggroAt and nowD < State.lastBrawlDeaggroAt then
                State.lastBrawlDeaggroAt = -100
            end
            if not chaseLockedNow and bestDeaggAlly and nowD >= (State.lastBrawlDeaggroAt or -100) + 1.35 then
                State.lastBrawlDeaggroAt = nowD
                bot:Action_AttackUnit(bestDeaggAlly, true)
                State.actionTaken = true
                return true
            end
            -- `v7.9.8-pro` + `v7.9.25-pro`: Step backward toward Fountain, clamped inside `<= 465u` CS orbit under own T1!
            local fnt = P.GetFountain(bot)
            local refBack = bLocDuel
            if bestDeaggAlly and U.DistanceBetweenLocations(bestDeaggAlly:GetLocation(), fnt) < U.DistanceBetweenLocations(bLocDuel, fnt) - 25 then
                refBack = bestDeaggAlly:GetLocation()
            end
            local safeStep = refBack + (fnt - refBack):Normalized() * 265
            if nearOwnT1Duel and myHp > 210 then
                local lowT1Cr, lowT1Hp = nil, math.huge
                for _, ecT1 in pairs(s.enemyCreeps or {}) do
                    if U.CanQuery(ecT1) and ecT1:IsAlive() and U.DistanceBetweenLocations(ecT1:GetLocation(), s.allyT1Loc) <= 840 then
                        local chp = ecT1:GetHealth() or 9999
                        if chp < lowT1Hp then lowT1Hp = chp; lowT1Cr = ecT1 end
                    end
                end
                if lowT1Cr then
                    local cLocT1 = lowT1Cr:GetLocation()
                    local keepR = math.max(390, (bot:GetAttackRange() or 500) - 35)
                    if U.DistanceBetweenLocations(safeStep, cLocT1) > keepR then
                        safeStep = cLocT1 + (fnt - cLocT1):Normalized() * keepR
                    end
                end
            end
            safeStep = U.SteerAroundObstacles(bot, safeStep, s)
            H.SmartMove(bot, safeStep, 25)
            State.actionTaken = true
            return true
        end

        local mySpaD = math.max(0.55, bot:GetSecondsPerAttack() or 1.25)
        local enSpaD = math.max(0.55, enemy:GetSecondsPerAttack() or 1.25)
        local incomingDpsWithCreeps = (enAtk / enSpaD) + enemyCreepsInAggro * 12.5
        local outgoingDpsTrue = effMyAtk / mySpaD
        local blockedByCreepPack = (enemyCreepsInAggro >= 3 or (enemyCreepsInAggro >= 2 and uphillHitFactor < 1.0))
            and enHp > myAtk * 2.15
        local winningDrySoulDuel = (enPotMana < 75)
            and not blockedByCreepPack
            and d <= (bot:GetAttackRange() or 500) + 120
            and (myHp >= 150 or enHp <= myAtk * 1.15)
            and myHp >= enHp * 0.76
            and (effMyAtk >= enAtk + 8 or (fightingNow and enHp <= effMyAtk * 3.1))
            and (enHp / math.max(1, outgoingDpsTrue)) + 0.15 <= (myHp / math.max(1, incomingDpsWithCreeps))
        -- `W6 07:58` Fix: NEVER brawl at point-blank right-click disadvantage (`72` vs `99` Treads autos!) with `Q`/`W` on CD!
        local closeCoilReadyHere = false
        if (bot:GetMana() or 0) >= 75 then
            for _, spec in ipairs({ { "nevermore_shadowraze1", 200 }, { "nevermore_shadowraze2", 450 } }) do
                local abC = bot:GetAbilityByName(spec[1])
                if abC and abC:GetLevel() > 0 and abC:IsCooldownReady() and math.abs(d - spec[2]) <= 220 then
                    closeCoilReadyHere = true
                    break
                end
            end
        end
        local myDryVsEnemyRaze = (K.MyManaBudget(bot, true) < 75) and (K.EnemyCastableRazeCount(enemy, 2.2) >= 1)
        -- `auto-20261102-0159-start-ShaNachnetsya.dem` `15:04.8..15:07.9` Point-Blank Melee Freeze Fix (#6):
        -- Previously `myHp <= myMaxHp * 0.86 or enHp <= 560` + `enStacks >= 1` FORBADE a `98.1% HP` (`1662/1694`) SF from
        -- punishing a `771 HP` rival who walked to `213.1u` (`dead-center inside Q(200)`) while `RunSacredCS` waited `2.13s`
        -- to deny a `123 HP` allied melee creep! Protect ONLY imminent `< 0.55s` ENEMY last-hits (`not bestPlan.isDeny`),
        -- never sacrifice a free point-blank `Q(200)` / self-rooted counter-coil for a slow allied creep deny!
        local bestPlanPre, bestEtaPre = L.PeekBestPlan(bot, s)
        local urgentEnemyCSNow = bestPlanPre and (not bestPlanPre.isDeny) and (bestEtaPre or 99) <= 0.55
        local enemySelfRootedClose = (d <= 535) and (K.EnemyPhase() ~= nil) and closeCoilReadyHere
        local pointBlankIntrusionPunish = (not urgentEnemyCSNow)
            and not myDryVsEnemyRaze
            and creepsHittingBot <= 1
            and not blockedByCreepPack
            and not H.InCriticalLethalDanger(bot, s, earlyRace)
            and (not earlyRace or not earlyRace.valid or (((earlyRace.edge or 0) >= -45 or myHp >= enHp * 1.20) and not earlyRace.heCanKillSoon))
            and (enemySelfRootedClose
                or (d <= 335 and (closeCoilReadyHere or (myHp >= enHp * 1.15 and effMyAtk >= enAtk - 6))))
        local activeStackedCloseDuel = d <= 545
            and not urgentEnemyCSNow
            and not myDryVsEnemyRaze
            and creepsHittingBot <= 1
            and not blockedByCreepPack
            and (closeCoilReadyHere or effMyAtk >= enAtk - 8 or enHp <= effMyAtk * 2.8)
            and (((enStacks or 0) >= 1 and (enRem or 0) > 1.5) or ((myStacks or 0) >= 1 and (myRem or 0) > 1.8 and fightingNow))
            and not (enHp >= myHp + 185 and (K.EnemyCastableRazeCount(enemy, 1.4) >= math.max(2, K.MyReadyRazeCount(bot, true))))
            and not H.InCriticalLethalDanger(bot, s, earlyRace)
            and (earlyRace and earlyRace.valid and ((earlyRace.edge or 0) >= -55 or earlyRace.canKillSoon))

        if not winningDrySoulDuel and not activeStackedCloseDuel and not pointBlankIntrusionPunish then
            return false
        end

        H.ClearForcedRetreat()
        State.fleeUntil = 0
        if not bot:IsSilenced() then
            if (bot:GetMana() or 0) < 75 and K.MyReadyRazeCount(bot, true) >= 1 and H.TryUseBurstManaItem(bot, true) then
                return true
            end
            if (bot:GetMana() or 0) >= 75 then
                for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            State.actionTaken = true
                            return true
                        end
                    end
                end
            end
        end
        if H.IssueHeroAttack(bot, enemy) then
            State.actionTaken = true
            return true
        end
        return false
    end

    -- Post-CS Equal-State Stand-Ground Anti-Zoning & `v7.5.0` Dominant Wave-Contest Punish:
    -- 1) Equal state: when rival steps forward (`d <= 685u`, `approach > 32` or past wave), stand ground & trade back.
    -- 2) Dominant state (`U.IsLaneDominant`): when we are winning the lane (`9070559899.dem` fix!) and the rival dares
    --    walk within `<= 790u` of our creep wave (`d <= 835u`) even WITHOUT running at us (`approach <= 32`), blast him
    --    with a centered `Shadowraze` / clean right-click so he CANNOT walk up and farm creeps for free!
    if imminentCreepCS then return false end
    local isDominantPunish = U.IsLaneDominant and U.IsLaneDominant(bot, s, earlyRace) or false
    local maxPunishDist = isDominantPunish and 835 or 685
    if d > maxPunishDist or myHp < 310 or (not isDominantPunish and myHp < enHp * 0.72) then return false end
    if U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy) then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or (earlyRace.edge or 0) < -65 or (not isDominantPunish and earlyRace.uphillPenalty)) then
        return false
    end

    local approach = U.EnemyApproachSpeed(bot, enemy)
    local fnt = P.GetFountain(bot)
    local waveCenter = LN.AllyWaveCenter(s.allyCreeps)
    local steppedPastWave = waveCenter ~= nil
        and U.DistanceBetweenLocations(enemy:GetLocation(), fnt) <= U.DistanceBetweenLocations(waveCenter, fnt) + 125
    local contestingOurWave = isDominantPunish and (LN.EnemyDistToAllyWave(enemy, s.allyCreeps) <= 790)
    if approach <= 32 and not steppedPastWave and not fightingNow and not contestingOurWave then
        return false
    end

    local nearSpikeNow = U.IsNearLevelSpike and U.IsNearLevelSpike(bot, enemy) or false
    local manaNow = bot:GetMana() or 0
    if isDominantPunish and manaNow < 75 and K.MyReadyRazeCount(bot, true) >= 1 and H.TryUseBurstManaItem(bot, true) then
        State.actionTaken = true
        return true
    end
    local enStacksNow = (U.GetShadowrazeDebuff and U.GetShadowrazeDebuff(enemy)) or 0
    local razeManaGate = (not contestingOurWave or enHp <= 360 or enStacksNow >= 1) and 75 or 135
    if not nearSpikeNow and not bot:IsSilenced() and manaNow >= razeManaGate then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    State.actionTaken = true
                    return true
                end
            end
        end
    end
    local allowAutoPunish = (not H.IsDryVsEnemyRaze(bot, enemy))
        and ((not contestingOurWave) or (approach > 32) or steppedPastWave or fightingNow
            or (#(s.enemyCreeps or {}) <= 2) or (d > 515))
    local movingAwayAuto = K.IsEnemyMovingAway(bot, enemy)
    local autoPunishReach = math.max(525, bot:GetAttackRange() or 525) + (movingAwayAuto and 22 or 45)
    if allowAutoPunish and d <= autoPunishReach then
        local prevPolicy, prevAllow = State.combatPolicyActive, State.heroCombatAllowed
        State.combatPolicyActive = false
        State.heroCombatAllowed = true
        local okAtk = H.IssueHeroAttack(bot, enemy)
        State.combatPolicyActive, State.heroCombatAllowed = prevPolicy, prevAllow
        if okAtk then
            State.actionTaken = true
            return true
        end
    end
    return false
end

function H.HandleDryEnemyAndSoulLeadHarass(bot, s, earlyRace, csWaveBusy)
    if State.actionTaken or csWaveBusy or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 1 then return false end
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local atkRange = bot:GetAttackRange() or 500
    local enHp = enemy:GetHealth() or 9999
    local myAtk = K.AttackDamageVs(bot, enemy)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local rawMyHp = bot:GetHealth() or 0
    local inFlightOnMe = 0
    if bot.GetIncomingTrackingProjectiles then
        local okP, projs = pcall(bot.GetIncomingTrackingProjectiles, bot)
        if okP and type(projs) == "table" then
            for _, pr in pairs(projs) do
                if pr then
                    local caster = pr.caster
                    if caster and caster.IsHero and caster:IsHero() then
                        inFlightOnMe = inFlightOnMe + enAtk
                    else
                        inFlightOnMe = inFlightOnMe + 18
                    end
                end
            end
        end
    end
    local myHp = math.max(1, rawMyHp - inFlightOnMe)
    local enTotalMana = (enemy:GetMana() or 0) + U.GetMangoMana(enemy)
    local enemyDry = (enTotalMana < 75) and (K.EnemyPhase() == nil)
    local uphill = earlyRace and earlyRace.valid and earlyRace.uphillPenalty

    local creepsOnMe = 0
    if U.CountEnemyCreepsAggroedOnBot then
        creepsOnMe = U.CountEnemyCreepsAggroedOnBot(bot, s, State.myCreepChaseUntil)
    else
        for _, c in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(c) and c:IsAlive() and c:GetAttackTarget() == bot then
                creepsOnMe = creepsOnMe + 1
            end
        end
    end
    local twoHitDryFinish = (enHp <= math.max(95, myAtk * 1.90))
    if (creepsOnMe >= 2 or (State.creepKiteUntil and GameTime() < State.creepKiteUntil)) and not twoHitDryFinish then
        return false
    end

    -- Case 1: Enemy has ZERO spell threat (`< 75 MP`) — right-click punish on our soul/HP advantage!
    local crushingSoulLead = (enTotalMana < 150 and myAtk >= enAtk + 12 and (myHp - K.EnemyRazeDamage(bot, enemy, 1)) >= 255)
        or (enTotalMana < 225 and myAtk >= enAtk + 18 and (myHp - K.EnemyRazeDamage(bot, enemy, 2)) >= 75)
    local winningHitTrade = (math.ceil(enHp / math.max(1, myAtk)) <= math.ceil(myHp / math.max(1, enAtk)))
        or (myHp >= enHp * 0.88)
        or ((bot:GetMana() or 0) >= 75 and myHp >= enHp * 0.60)
    local pressDryKill = enemyDry and myHp >= 225 and not uphill
        and ((myAtk >= enAtk - 2 and creepsOnMe <= 1 and winningHitTrade)
            or (myHp >= enHp + 110 and enHp <= 400 and creepsOnMe <= (twoHitDryFinish and 2 or 0)
                and (myAtk >= enAtk - 3 or twoHitDryFinish)))
    -- Case 2: Clear Soul/Attack-Damage Dominance (`>= +7` hero hit damage) with safe spell parity OR
    -- crushing `16 vs 7` soul + `2x Bracer` right-click dominance vs a `1`-coil (`< 150 MP`) enemy (`9056774541.dem` `02:35`!)
    -- NEVER walk dry (`< 75 MP`) into a `2+`-coil (`>= 150 MP`) enemy SF (`ShaNachnetsya` `02:22–02:40` `874 -> 159 HP` Fix),
    -- AND NEVER step in with `1+` raze stack while our `W`+`E` are spent (`1814 @ 07:58` Post-Combo Stack Safety)!
    local myStLead, myRemLead = U.GetShadowrazeDebuff(bot)
    local r2Lead = bot:GetAbilityByName("nevermore_shadowraze2")
    local r3Lead = bot:GetAbilityByName("nevermore_shadowraze3")
    local myWESpentLead = (not (r2Lead and U.IsRazeAbilityCastable(bot, r2Lead)))
        and (not (r3Lead and U.IsRazeAbilityCastable(bot, r3Lead)))
    local stackedSpentVsCoil = ((myStLead or 0) >= 1 and (myRemLead or 0) >= 0.8 and enTotalMana >= 75 and myWESpentLead)
    local dryVsMultiCoil = H.IsDryVsEnemyRaze(bot, enemy)
    local pressSoulLead = (not dryVsMultiCoil) and (not stackedSpentVsCoil) and myHp >= 300 and creepsOnMe <= 1
        and earlyRace and earlyRace.valid and not earlyRace.heCanKillSoon
        and ((myAtk >= enAtk + 7 and not uphill and (earlyRace.edge or 0) >= 45)
            or crushingSoulLead)

    local movingAwayLead = K.IsEnemyMovingAway(bot, enemy)
    local baseAtkR = math.max(525, atkRange)
    local allowForwardStep = (creepsOnMe == 0 or twoHitDryFinish) and (myAtk >= enAtk - 3 or twoHitDryFinish)
    local maxReach = (allowForwardStep and ((enemyDry and myHp >= enHp + 110 and enHp <= 400)
        or (enemyDry and myAtk >= enAtk + 12 and myHp >= 265)
        or (not dryVsMultiCoil and crushingSoulLead and enTotalMana < 150)))
        and (baseAtkR + 225) or (baseAtkR + (movingAwayLead and 22 or 45))
    if (pressDryKill or pressSoulLead) and d <= maxReach then
        if H.IssueHeroAttack(bot, enemy) then
            State.lastHarassTime = GameTime()
            return true
        end
    end
    return false
end

function H.InLosingHeroTrade(bot, s, race)
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if H.CanTwoHitRightClickKill(bot, enemy, s) then return false end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    local rawEnHp = enemy:GetHealth() or 9999
    local enHp = (U.GetEnemyEffectiveCombatHp and math.max(rawEnHp, U.GetEnemyEffectiveCombatHp(enemy, 2.5))) or rawEnHp
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 1)
    local hpPct = myHp / myMaxHp
    local enRange = (enemy:GetAttackRange() or 500)
    local valid = race and race.valid
    local outMatched = valid and (race.heHasBootsLead or ((enemy:GetLevel() or 1) > (bot:GetLevel() or 1)))
    if valid and (race.canKillNow
        or (not outMatched and race.canKillSoon and (race.edge or 0) >= -30)
        or (race.canKillSoon and not race.heCanKillSoon and (race.edge or 0) >= 60)) then
        return false
    end

    -- `9056469656.dem` `02:29–02:35` & `01:42–02:02` Fix + `v7.9.14` Courier-ETA & Asymmetric-Wave Guard:
    -- NEVER treat a pure dry-mana right-click trade on flat/allied ground as "losing" when the enemy has `< 75 MP`
    -- (`0` Shadowrazes AND no courier/backpack Mango arriving inside `1.85s`!) and we beat them in HP / TTK without
    -- tanking a massive one-sided enemy creep wave (`netCreepDisadv < 95`)!
    local enSoonManaExtra = 0
    if U.GetEnemyIncomingCourierMana then
        enSoonManaExtra = enSoonManaExtra + (U.GetEnemyIncomingCourierMana(bot, enemy, 1.85) or 0)
    end
    if U.GetUnlockingMangoMana then
        enSoonManaExtra = enSoonManaExtra + (U.GetUnlockingMangoMana(enemy, 2.2) or 0)
    end
    local enTotalPool = (enemy:GetMana() or 0) + U.GetMangoMana(enemy) + enSoonManaExtra
    local enemyDry = (enTotalPool < 75) and (K.EnemyPhase() == nil)
    local myAtkNow = K.AttackDamageVs(bot, enemy)
    local enAtkNow = K.AttackDamageVs(enemy, bot)
    local netCreep = (valid and math.max(0, race.netCreepDisadv or 0)) or 0
    local creepSafeForDryBrawl = (not valid)
        or ((myHp - (race.brawlCreepDmgMe or 0) - enAtkNow * 2.0) >= 75)
    local winningDryBrawl = valid and not race.uphillPenalty and creepSafeForDryBrawl
        and ((enemyDry and (myHp - netCreep) >= enHp + 95 and (race.ttkHim or 999) < (race.ttkMe or 999) * 0.82)
            or (enemyDry and myHp >= 300 and (myHp - netCreep) >= enHp - 35 and myAtkNow >= enAtkNow + 6)
            or (enTotalPool < 150 and not race.heCanKillSoon and (myHp - netCreep - K.EnemyRazeDamage(bot, enemy, 1)) >= 245
                and myAtkNow >= enAtkNow + 12))
    if winningDryBrawl then return false end

    -- `v7.9.13-pro` + `v7.9.14-pro` (`0210 @ 11:22..11:27.20` Death #1 + `16:13..16:19` + `10:02` Coil/HP-Deficit Bailout):
    local _, myReadyRaw = K.MyReadyRazeCount(bot, true)
    local myCastN = math.min(myReadyRaw or 0, (K.MyEffectiveRazeBudgetAt and K.MyEffectiveRazeBudgetAt(bot, true, 1.45)) or 0)
    local enCastN = K.EnemyCastableRazeCount and K.EnemyCastableRazeCount(enemy, 1.6) or 0
    local myStTr, myRemTr = U.GetShadowrazeDebuff(bot)
    local closeBrawlLim = math.max(595, enRange + 90)
    if enHp > myAtkNow * 2.15 then
        if myCastN == 0 and ((dist <= closeBrawlLim and enCastN >= 2 and (hpPct <= 0.72 or (myHp - K.EnemyRazeDamage(bot, enemy, 2)) < 380))
            or (dist <= 755 and enCastN >= 1 and (myStTr or 0) >= 1 and (myRemTr or 0) > 0.6 and myHp < 840)) then
            return true
        end
        if dist <= closeBrawlLim + 45 and enHp >= myHp + 215 and enCastN >= math.max(2, myCastN)
            and (myHp - K.EnemyRazeDamage(bot, enemy, math.min(2, enCastN))) < 340 then
            return true
        end
    end

    local lethalGuardDist = outMatched
        and math.max(845, enRange + 300, (race.minSafeDist or 0) + 90)
        or math.max(enRange + 280, (race.minSafeDist or 0) + 90)
    if valid and race.heCanKillSoon and dist <= lethalGuardDist then
        return true
    end

    local beingAttacked = (enemy.GetAttackTarget and enemy:GetAttackTarget() == bot)
        or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 1.1))
        or false
    -- Never stand on river lowground (`uphillPenalty`) or tanking >= 2 creeps eating enemy right-clicks!
    local creepAggroOnMe = 0
    for _, c in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(c) and c:IsAlive() and c:GetAttackTarget() == bot then
            creepAggroOnMe = creepAggroOnMe + 1
        end
    end
    if beingAttacked and dist <= enRange + 110 and valid and not race.spellWindow then
        if race.uphillPenalty or creepAggroOnMe >= 2
            or ((race.netCreepDisadv or 0) >= 65 and (race.edgeLong or 0) < -55 and not race.canKillSoon)
            or ((bot:GetLevel() or 1) <= 3 and (race.edgeLong or 0) < -65)
            or (enAtkNow >= myAtkNow + 8 and not race.canKillSoon and myHp <= enHp + 45) then
            return true
        end
    end
    if valid and race.losingHard and not race.spellWindow
        and (beingAttacked or (hpPct <= 0.55 and dist <= enRange + 240))
        and dist <= enRange + 295 then
        return true
    end

    return false
end

function H.DisengageFromLethalTrade(bot, s, race)
    local enemy = s and s.enemy
    State.commitKillUntil = 0
    State.prepTarget = nil
    State.lhAttackTarget = nil
    H.ManageTreads(bot, "SURVIVE")
    local fountain = P.GetFountain(bot)
    local bLoc = bot:GetLocation()

    -- `9069188041.dem` `03:38.8-03:49.5` Death #2 Counter-Raze & Dry-Enemy Finish Fix:
    -- Previously `if myHp <= 165` returned BEFORE checking ANY counter-Raze, causing `121 HP / 220 MP` Bot with
    -- `3/3` ready Razes to run away and die casting `0` Razes against a `10-18 MP` (`0`-Raze!) Human!
    if enemy and U.CanQuery(enemy) and enemy:IsAlive()
        and (bot:GetMana() or 0) >= 75 and not bot:IsSilenced() then
        local eLocNow = enemy:GetLocation()
        local curDist = U.DistanceBetweenLocations(bLoc, eLocNow)
        if curDist <= 915 then
            local myHpNow = bot:GetHealth() or 0
            local enAtkRange = (enemy:GetAttackRange() or 525)
            local enAtkNow = K.AttackDamageVs(enemy, bot)
            local enNoCoils = (K.EnemyCastableRazeCount(enemy, 0.8) == 0)
            local enSurvHp = (enemy:GetHealth() or 9999)
                + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(enemy)) or 0)
                + (U.GetStickCharges(enemy) or 0) * 15
            local oneMyRaze = U.GetNRazeDamage(bot, enemy, 1)
            local twoMyRaze = U.GetNRazeDamage(bot, enemy, 2)
            local myReadyN = K.MyReadyRazeCount(bot, true)
            local canOneRazeKill = (oneMyRaze >= enSurvHp)
            local canDryTwoRazeKill = enNoCoils and (myReadyN >= 2) and (twoMyRaze >= enSurvHp)
                and (curDist > enAtkRange + 30 or myHpNow > enAtkNow + 15)
            local enAppClose = math.max(0, U.EnemyApproachSpeed(bot, enemy))
            local angToEnemyNow = U.GetAngleDifference(bot, eLocNow)
            -- When critically low (`<= 225 HP`) and NOT lethal (`not canDryTwoRazeKill`), NEVER turn `180 deg` while
            -- fleeing (`0.20s` turn + `0.55s` cast = `~230u` gap lost -> enemy walks inside `525u` right-click range!):
            -- only fire a non-lethal `freeDryFarRaze` when ALREADY facing the enemy (`<= 35 deg`) at `>= 680u` (`+155u`)!
            local safeNonLethalFar = (myHpNow > 225)
                or (angToEnemyNow <= 35 and curDist >= enAtkRange + 155)
            local freeDryFarRaze = enNoCoils
                and (curDist >= enAtkRange + 65)
                and (curDist - enAppClose * 0.60 >= enAtkRange + 10)
                and (myHpNow > 105)
                and safeNonLethalFar
                and not H.HasEnemyProjectileIncoming(bot)
            -- `auto-20261031-0230` `02:09.1` Self-Root Death #2 Fix:
            -- NEVER turn `180 deg` + self-root `0.55s` (`~230u` gap lost!) at `(645, 517)` (`d=334u`) for a non-lethal
            -- `69`-damage coil when `myMS >= enMS` and running straight past our T1/wave saves our life!
            -- Fire a close last-stand coil ONLY when `raze + 1 hit` threatens lethal OR a faster Boots enemy
            -- (`enMS >= myMS + 25`) is already on top of us (`<= 420u`) with near-zero turn delay!
            local myMSClose = bot:GetCurrentMovementSpeed() or 305
            local enMSClose = enemy:GetCurrentMovementSpeed() or 305
            local razePlusHitKills = (oneMyRaze + K.AttackDamageVs(bot, enemy) >= enSurvHp)
                and (myHpNow > enAtkNow + 20)
            local inescapableClose = (enMSClose >= myMSClose + 25)
                and (curDist <= 420)
                and (myHpNow <= enAtkNow * 1.45)
                and (U.GetAngleDifference(bot, eLocNow) <= 30)
            local lastStandCloseRaze = (curDist <= enAtkRange + 25)
                and (razePlusHitKills or inescapableClose)
                and (not H.HasEnemyProjectileIncoming(bot) or myHpNow > enAtkNow + 12)
            if canOneRazeKill or canDryTwoRazeKill or freeDryFarRaze or lastStandCloseRaze then
                for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                    local ab = H.GetRazeAbilityByLabel(bot, label)
                    if ab and U.IsRazeAbilityCastable(bot, ab) then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            State.actionTaken = true
                            return true
                        end
                    end
                end
            end
        end
    end

    H.ClearRazeState()
    if not (enemy and U.CanQuery(enemy)) then
        -- `v7.9.30-pro` (`auto-20261109-0026` `2:43..2:50` `(1324,-355)->(1996,482)` East-Jungle 2-Creep Drag Fix!):
        -- When retreating from aggroed lane creeps with `enemy == nil` and `allyT1` alive, route directly to `behindT1`
        -- (`allyT1 + 240u toward Fountain`) whenever we are in front of `allyT1` OR laterally off the mid corridor (`> 340u`),
        -- so `allyT1`'s `870u` cannon immediately kills the chasing creeps and keeps us in mid XP/CS range!
        local wp = nil
        if s and s.allyT1Alive ~= false and s.allyT1Loc then
            local t1C = s.allyT1Loc
            local spC = (fountain - t1C):Normalized()
            local relBC = bLoc - t1C
            local latBC = math.abs(relBC.x * (-spC.y) + relBC.y * spC.x)
            local dMeFntC = U.DistanceBetweenLocations(bLoc, fountain)
            local dT1FntC = U.DistanceBetweenLocations(t1C, fountain)
            if dMeFntC > dT1FntC - 140 or latBC > 340 then
                wp = t1C + spC * 240
            end
        end
        wp = wp or (P.GetRetreatAnchor and P.GetRetreatAnchor(bot, 480, 340))
            or (bLoc + (fountain - bLoc):Normalized() * math.min(520, U.DistanceBetweenLocations(bLoc, fountain)))
        State.actionTaken = true
        return H.BeginForcedRetreat(bot, wp, 0.65)
    end
    -- Stamp anti-oscillation turnback hysteresis (`auto-20261102-0043` `2:33..2:36` `340 <-> 44 deg` spin fix!)
    State.noHarassTurnbackUntil = math.max(State.noHarassTurnbackUntil or 0, GameTime() + 0.85)

    -- CRITICAL `v7.9.5` ORDERING FIX (`auto-20261102-0139` `7:44.83..7:45.40` `220 HP` Straight-Line `Shadowraze3` Death!):
    -- `Immortal Coil-Ray Break` MUST execute ABOVE `myHp <= 165` AND ABOVE `HandleSurvivalRetreat` (`which previously
    -- intercepted `myHp <= oneRaze + 45` 30 lines higher and ran radially down `ShaNachnetsya`'s `700u` `E` sightline!)!
    if enemy and U.CanQuery(enemy) and enemy:IsAlive() then
        local eLocCast = enemy:GetLocation()
        local curDistCast = U.DistanceBetweenLocations(bLoc, eLocCast)
        local isEnemySFCast = (enemy:GetUnitName() == "npc_dota_hero_nevermore")
        local enNoCoilsCast = K.EnemyManaBudget(enemy, true) < 75 or K.EnemyReadyRazeCount(enemy, 0.7, true) == 0
        local inCastPhase = K.EnemyPhase()
        if isEnemySFCast and not enNoCoilsCast and inCastPhase ~= nil and curDistCast >= 180 and curDistCast <= 920 then
            if H.HandleEnemyRazeDodge and H.HandleEnemyRazeDodge(bot, enemy) then
                return true
            end
            local liveC = K.EnemyRazeCenter(enemy, inCastPhase)
            local dLiveC = U.DistanceBetweenLocations(bLoc, liveC)
            local radOutC = (dLiveC > 1.0) and (bLoc - liveC):Normalized() or (fountain - liveC):Normalized()
            local lateralPoint = U.EnsurePassable(bot, bLoc + radOutC * 320)
            State.actionTaken = true
            return H.BeginForcedRetreat(bot, lateralPoint, 0.45)
        end
    end

    local allyT1Ramp = (s and s.allyT1Loc) or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1)
    -- `v7.9.15` (`auto-20261106-2139` `05:13.4` `(466,187)->(465,350)` `yaw=90°` & `06:04.2` `yaw=119°` Fix):
    --   1. NEVER zig-zag inside `< 635u` (`Raze1` / `Raze2` / Right-Click zone): sprint straight radially out at 100% MS!
    --   2. In `[635..935u]` (`Shadowraze3` band), use compact `±14°` weave (`cos=0.97`) AND strictly require
    --      `candD · awayRef >= 0.86` so SF NEVER picks an inward leg that cuts across the `700u` `Shadowraze3` circle!
    local function pickPassableSerpentineDir(baseDir, weightBase, weightPerp, probeLen, awayRef)
        local perpV = Vector(-baseDir.y, baseDir.x, 0)
        local sgn = (math.floor(GameTime() / 0.65) % 2 == 0) and 1.0 or -1.0
        for _, trySgn in ipairs({ sgn, -sgn }) do
            local candD = (baseDir * weightBase + perpV * (trySgn * weightPerp)):Normalized()
            local radialOk = (not awayRef) or ((candD.x * awayRef.x + candD.y * awayRef.y) >= 0.86)
            local probe = bLoc + candD * probeLen
            local safeFromEnT1 = not (W.s and W.s.enemyT1Loc and U.DistanceBetweenLocations(probe, W.s.enemyT1Loc) < 880)
            if radialOk and safeFromEnT1 and U.IsRayPassable(bLoc, probe) then
                return candD
            end
        end
        -- Narrow river staircase (`e.g. (-449, -449)` in `2048 @ 07:47.60`): sprint straight along `baseDir` or up `allyT1` ramp!
        if U.IsRayPassable(bLoc, bLoc + baseDir * math.min(probeLen, 280)) then
            return baseDir
        end
        if allyT1Ramp and U.DistanceBetweenLocations(bLoc, allyT1Ramp) > 90 then
            local rampDir = (allyT1Ramp - bLoc):Normalized()
            if (not awayRef or (rampDir.x * awayRef.x + rampDir.y * awayRef.y) >= 0.72)
                and U.IsRayPassable(bLoc, bLoc + rampDir * math.min(probeLen, 280)) then
                return rampDir
            end
        end
        return baseDir
    end

    local allyT1Active = (s and s.allyT1Alive ~= false and s.allyT1Loc) and s.allyT1Loc or nil
    local inFrontOfOwnT1 = allyT1Active
        and (U.DistanceBetweenLocations(bLoc, fountain) > U.DistanceBetweenLocations(allyT1Active, fountain) + 140)
    local homeCorridorGoal = inFrontOfOwnT1
        and (allyT1Active + (fountain - allyT1Active):Normalized() * 260)
        or fountain
    local toHomeFromMe = (U.DistanceBetweenLocations(bLoc, homeCorridorGoal) > 15)
        and (homeCorridorGoal - bLoc):Normalized()
        or (fountain - bLoc):Normalized()
    -- `v7.9.30-pro` (`auto-20261109-0026` `6:10..6:23.90` `(-858,-338)->(-1559,+1482)` Top-River Dead-End Elimination):
    -- When `enemy` stands laterally or slightly homeward of `bLoc` (`away · toHome < 0.25`), `0.54 * away + 0.46 * toFnt`
    -- previously canceled out our homeward velocity and drove SF `2,250u` perpendicular down the river dead-end!
    -- Enforce strict Home-Corridor convergence: if `toHome` is clear of `enemy` (`toEnemy · toHome <= 0.62`), sprint straight
    -- toward `homeCorridorGoal` (`behindT1`); otherwise let `ComputeCutOffSafeRetreatTarget` arc on the Fountain-ward side!
    local function safeHomeBlend(awayVec, wAway, wHome)
        local dotAH = awayVec.x * toHomeFromMe.x + awayVec.y * toHomeFromMe.y
        if dotAH >= 0.25 then
            return (awayVec * wAway + toHomeFromMe * wHome):Normalized()
        end
        local toEn = Vector(-awayVec.x, -awayVec.y, 0)
        local enBlocksHome = (toEn.x * toHomeFromMe.x + toEn.y * toHomeFromMe.y) > 0.62
        if not enBlocksHome then
            return (toHomeFromMe * 0.90 + awayVec * 0.10):Normalized()
        end
        return toHomeFromMe
    end

    if (bot:GetHealth() or 0) <= 165 then
        -- Route past our allied T1 (`<= 430u` protective aggro radius when T1 is between us and Fountain) & obstacles!
        local eLocCrit = enemy:GetLocation()
        local dCrit = U.DistanceBetweenLocations(bLoc, eLocCrit)
        local awayCrit = (dCrit > 5) and (bLoc - eLocCrit):Normalized() or toHomeFromMe
        local dirFnt = safeHomeBlend(awayCrit, 0.52, 0.48)
        if enemy:GetUnitName() == "npc_dota_hero_nevermore"
            and dCrit >= 635 and dCrit <= 935
            and (enemy:GetMana() or 0) >= 75
            and K.EnemyRazeReady("far", 1.2) then
            local awayRefCrit = ((awayCrit.x * toHomeFromMe.x + awayCrit.y * toHomeFromMe.y) >= 0.25) and awayCrit or toHomeFromMe
            dirFnt = pickPassableSerpentineDir(dirFnt, 0.96, 0.24, 380, awayRefCrit)
        end
        local rawWp = bLoc + dirFnt * math.min(620, U.DistanceBetweenLocations(bLoc, homeCorridorGoal))
        local wp = H.ComputeCutOffSafeRetreatTarget(bot, enemy, rawWp, 480)
        if s and s.allyT1Alive and s.allyT1Loc then
            local dMeT1 = U.DistanceBetweenLocations(bLoc, s.allyT1Loc)
            local dT1Fnt = U.DistanceBetweenLocations(s.allyT1Loc, fountain)
            local dMeFnt = U.DistanceBetweenLocations(bLoc, fountain)
            if dMeT1 <= 520 and dMeFnt >= dT1Fnt - 120 then
                local hugT1 = s.allyT1Loc + (fountain - s.allyT1Loc):Normalized() * 360
                if U.DistanceBetweenLocations(hugT1, eLocCrit) > U.DistanceBetweenLocations(bLoc, eLocCrit) + 45 then
                    wp = hugT1
                end
            end
        end
        wp = U.EnsurePassable(bot, U.SteerAroundObstacles(bot, wp, s))
        State.actionTaken = true
        return H.BeginForcedRetreat(bot, wp, 0.75)
    end
    if enemy and U.CanQuery(enemy) then
        local eLoc = enemy:GetLocation()
        local myHp = bot:GetHealth() or 0
        local oneRaze = K.EnemyCastableRazeDamage(bot, enemy, 1, nil, 2.2)
        local twoRaze = K.EnemyCastableRazeDamage(bot, enemy, 2, nil, 2.2)
        local enAtk = K.AttackDamageVs(enemy, bot)
        local curDist = U.DistanceBetweenLocations(bLoc, eLoc)
        local isEnemySF = (enemy:GetUnitName() == "npc_dota_hero_nevermore")
        -- Only activate outer-`E` serpentine once clear of `< 635u` `Raze2`/attack range!
        local eThreatActive = isEnemySF
            and (K.EnemyManaBudget(enemy, true) >= 75)
            and K.EnemyRazeReady("far", 1.2)
            and curDist >= 635 and curDist <= 935
        if not eThreatActive and myHp <= math.max(175, oneRaze + 45) and H.HandleSurvivalRetreat(bot, enemy, race) then
            State.actionTaken = true
            return true
        end
        local homeDir = (fountain - eLoc):Normalized()
        local approach = U.EnemyApproachSpeed(bot, enemy)
        local baseDist = (myHp <= twoRaze + enAtk * 2.1 + 40) and 940 or 780
        local targetDist = math.min(1180, baseDist + math.min(220, approach * 0.8))
        -- 1. Defensive Snap-Coil Counter when being run down by a faster dry/0-coil enemy (`Death #1` `05:42..05:48` fix!):
        local myMS = bot:GetCurrentMovementSpeed() or 305
        local enMS = enemy:GetCurrentMovementSpeed() or 305
        local enNoCoils = K.EnemyManaBudget(enemy, true) < 75 or K.EnemyReadyRazeCount(enemy, 0.7, true) == 0
        if enNoCoils and enMS > myMS + 10 and curDist <= 520 and (bot:GetMana() or 0) >= 75
            and myHp >= enAtk + 45 and not H.HasEnemyProjectileIncoming(bot) then
            for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                local ab = H.GetRazeAbilityByLabel(bot, label)
                if ab and U.IsRazeAbilityCastable(bot, ab) then
                    local action, aim = H.GetRazeActionType(bot, ab, enemy)
                    if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                        State.actionTaken = true
                        return true
                    end
                end
            end
        end
        -- 2. Cliff-Safe Anti-`Shadowraze3` Serpentine + Tower-Umbrella Flank Retreat (`v7.9.12-pro` `2319 @ 06:33..06:43` Fix!):
        --   (a) When near/behind `allyT1` and `enemy` flanks laterally around `allyT1` (`latT1 >= 230u`), NEVER compute
        --       `eLoc + (fountain - eLoc):Normalized() * targetDist` (which walked `336 HP` SF `450u` SE from `(711,601)` to
        --       `(1080,438)` right out from behind Dire T1 into `ShaNachnetsya`'s southern flank!). Instead anchor through
        --       `allyT1`'s opposite shadow toward Fountain so `allyT1`'s `700u` attack circle blocks the flanker!
        --   (b) Even away from `allyT1`, when `eLoc` is laterally offset `>= 250u` from `bLoc -> fountain`, retreat along
        --       `bLoc -> fountain` blended with `(bLoc - eLoc)` instead of drifting sideways onto `eLoc -> fountain`!
        local toFntFromMe = (fountain - bLoc):Normalized()
        local awayFromEnemy = (curDist > 5) and (bLoc - eLoc):Normalized() or toFntFromMe
        local rawPoint = nil
        if s and s.allyT1Alive and s.allyT1Loc then
            local t1L = s.allyT1Loc
            local dMeT1 = U.DistanceBetweenLocations(bLoc, t1L)
            local dEnT1 = U.DistanceBetweenLocations(eLoc, t1L)
            local dMeFnt = U.DistanceBetweenLocations(bLoc, fountain)
            local dT1Fnt = U.DistanceBetweenLocations(t1L, fountain)
            local spineT1 = (fountain - t1L):Normalized()
            local relEnT1 = eLoc - t1L
            local latT1 = math.abs(relEnT1.x * (-spineT1.y) + relEnT1.y * spineT1.x)
            if dMeT1 <= 1100 and dMeFnt <= (dT1Fnt + 380) and dEnT1 <= 1380 and latT1 >= 230 then
                local oppT1Dir = (dEnT1 > 5) and (t1L - eLoc):Normalized() or spineT1
                local shadowDir = (oppT1Dir * 0.50 + spineT1 * 0.70):Normalized()
                local shadowDist = math.max(390, targetDist - dEnT1 + 125)
                local shadowPt = t1L + shadowDir * shadowDist
                local fntStepPt = bLoc + toFntFromMe * 320
                if U.DistanceBetweenLocations(shadowPt, fountain) > U.DistanceBetweenLocations(fntStepPt, fountain) then
                    shadowPt = (shadowPt * 0.45 + fntStepPt * 0.55)
                end
                if U.DistanceBetweenLocations(shadowPt, eLoc) > curDist + 35 then
                    rawPoint = shadowPt
                end
            end
        end
        if not rawPoint then
            local relEnMe = eLoc - bLoc
            local latMe = math.abs(relEnMe.x * (-toHomeFromMe.y) + relEnMe.y * toHomeFromMe.x)
            local radialFntBlend = safeHomeBlend(awayFromEnemy, 0.54, 0.46)
            local retreatDir = radialFntBlend
            if curDist < 635 then
                rawPoint = bLoc + radialFntBlend * 440
            elseif eThreatActive and myHp <= (oneRaze + 140) then
                local baseD = (latMe >= 200) and radialFntBlend or safeHomeBlend(awayFromEnemy, 0.45, 0.55)
                local awayRefS = ((awayFromEnemy.x * toHomeFromMe.x + awayFromEnemy.y * toHomeFromMe.y) >= 0.25) and awayFromEnemy or toHomeFromMe
                retreatDir = pickPassableSerpentineDir(baseD, 0.96, 0.24, 380, awayRefS)
                rawPoint = bLoc + retreatDir * 420
            elseif latMe >= 220 or inFrontOfOwnT1 then
                rawPoint = bLoc + radialFntBlend * math.max(420, targetDist - curDist + 260)
            else
                rawPoint = eLoc + homeDir * targetDist
            end
        end
        local point = H.ComputeCutOffSafeRetreatTarget(bot, enemy, rawPoint, 440)
        -- `auto-20261102-0007` `10:10.37` (`(2044, 1502)` `dAC=40u` `0.40s` Self-Creep Body-Block Fix!):
        -- When fleeing NE/SW straight into an oncoming allied creep wave (`>= 1` allied creep within `210u` in a `38 deg`
        -- forward cone), offset `165u` laterally around the wave so SF never stalls `0.4s` on its own melee creeps!
        if s and s.allyCreeps and #(s.allyCreeps) > 0 then
            local moveVec = point - bLoc
            local moveLen = math.sqrt(moveVec.x * moveVec.x + moveVec.y * moveVec.y)
            if moveLen > 45 then
                local fwd = moveVec:Normalized()
                local perpC = Vector(-fwd.y, fwd.x, 0)
                local blockCount, avgSide = 0, 0
                for _, ac in pairs(s.allyCreeps) do
                    if ac and U.CanQuery(ac) and ac:IsAlive() then
                        local relC = ac:GetLocation() - bLoc
                        local dc = math.sqrt(relC.x * relC.x + relC.y * relC.y)
                        if dc >= 18 and dc <= 215 then
                            local dotF = (relC.x * fwd.x + relC.y * fwd.y) / dc
                            if dotF >= 0.78 then
                                blockCount = blockCount + 1
                                avgSide = avgSide + (relC.x * perpC.x + relC.y * perpC.y)
                            end
                        end
                    end
                end
                if blockCount >= 1 then
                    local dodgeSign = (avgSide >= 0) and -1.0 or 1.0
                    point = bLoc + (fwd * 310) + (perpC * (dodgeSign * 165))
                end
            end
        end
        -- `v7.9.12-pro` (`2319 @ 06:42.33..06:43.00` Dire T2 `(2496, 2112)` `168u` Hull-Bonk Detour Fix!):
        -- Placed AFTER allied-creep lateral dodge so neither `rawPoint` nor `perpC * 165` ever routes the retreat segment
        -- across `allyT2`'s `168u` collision hull (`144u` tower + `24u` hero)! Tangent waypoint sits slightly in front/abreast
        -- of `t2L` (`-uToT2 * 45 + perpT2 * 245`) so the chord clears `t2L` by `>= 195u` cleanly!
        if s and s.allyT2Alive and s.allyT2Loc then
            local t2L = s.allyT2Loc
            local seg = point - bLoc
            local segLen = math.sqrt(seg.x * seg.x + seg.y * seg.y)
            if segLen > 35 then
                local sx, sy = seg.x / segLen, seg.y / segLen
                local rx2, ry2 = t2L.x - bLoc.x, t2L.y - bLoc.y
                local dToT2 = math.sqrt(rx2 * rx2 + ry2 * ry2)
                local proj2 = rx2 * sx + ry2 * sy
                if dToT2 > 25 and proj2 > -20 and proj2 < segLen + 60 then
                    local cx2 = bLoc.x + sx * math.max(0, math.min(segLen, proj2))
                    local cy2 = bLoc.y + sy * math.max(0, math.min(segLen, proj2))
                    local dSegT2 = math.sqrt((t2L.x - cx2) * (t2L.x - cx2) + (t2L.y - cy2) * (t2L.y - cy2))
                    if dSegT2 < 205 then
                        local ux2, uy2 = rx2 / dToT2, ry2 / dToT2
                        local pA = Vector(-uy2, ux2, 0)
                        local pB = Vector(uy2, -ux2, 0)
                        local pullLead = (dToT2 > 235) and -45 or 85
                        local cA = Vector(t2L.x + ux2 * pullLead + pA.x * 248, t2L.y + uy2 * pullLead + pA.y * 248, bLoc.z)
                        local cB = Vector(t2L.x + ux2 * pullLead + pB.x * 248, t2L.y + uy2 * pullLead + pB.y * 248, bLoc.z)
                        point = (U.DistanceBetweenLocations(cA, eLoc) >= U.DistanceBetweenLocations(cB, eLoc)) and cA or cB
                    end
                end
            end
        end
        State.actionTaken = true
        return H.BeginForcedRetreat(bot, point, 0.65)
    end
    return false
end

-- Find an item in slots `0..8`; if in Backpack `6..8`, swap it into the lowest-priority active slot `0..5`
-- cleanly (`branchTangoSwapUntil` holds `ManageInventorySlots` back until the 6.0s Backpack CD unlocks & casts!).
-- Multiple Backpack consumables (e.g. `item_flask` + `item_ward_observer`) swap into DISTINCT active slots on the same tick!
function H.EnsureConsumableReady(bot, itemName)
    local slot = bot:FindItemSlot(itemName)
    if slot < 0 or slot > 8 then return nil, false end
    if slot <= 5 then
        local it = bot:GetItemInSlot(slot)
        -- Hold `branchTangoSwapUntil` BOTH during the 6.0s Backpack CD AND during the short walk/turn to use it!
        State.branchTangoSwapUntil = math.max(State.branchTangoSwapUntil or -1000, GameTime() + 2.5)
        return it, (it ~= nil and it:IsFullyCastable())
    end
    local bestSlot, bestPrio = nil, math.huge
    for i = 0, 5 do
        local it = bot:GetItemInSlot(i)
        if not it then
            bestSlot = i
            break
        end
        local nm = it:GetName()
        -- Strictly respect unified `U.GetEffectiveItemPriority` AND NEVER displace another active consumable
        -- (`item_tango` / `item_enchanted_mango` / `item_flask` / `item_clarity` / `item_ward_observer`) — breaks 100% of swap loops!
        if nm ~= "item_boots" and nm ~= "item_power_treads"
            and nm ~= "item_flask" and nm ~= "item_clarity" and nm ~= "item_ward_observer"
            and nm ~= "item_tango" and nm ~= "item_enchanted_mango" then
            local salveStrBoost = 0
            if itemName == "item_flask" then
                if nm == "item_ogre_axe" or nm == "item_dragon_lance" or nm == "item_ultimate_orb" then salveStrBoost = 10
                elseif nm == "item_belt_of_strength" then salveStrBoost = 6
                elseif nm == "item_bracer" then salveStrBoost = 5
                elseif nm == "item_gauntlets" then salveStrBoost = 3
                elseif nm == "item_circlet" or nm == "item_wraith_band" or nm == "item_null_talisman" then salveStrBoost = 2
                elseif nm == "item_branches" then salveStrBoost = 1 end
            end
            local pr = (salveStrBoost > 0) and (-100 - salveStrBoost) or U.GetEffectiveItemPriority(bot, nm)
            if pr < bestPrio then
                bestPrio = pr
                bestSlot = i
            end
        end
    end
    if bestSlot ~= nil then
        bot:ActionImmediate_SwapItems(slot, bestSlot)
        U.InvalidateInvCache()
        State.branchTangoSwapUntil = GameTime() + 8.5
        local moved = bot:GetItemInSlot(bestSlot)
        return moved, (moved ~= nil and moved:IsFullyCastable())
    end
    return nil, false
end

-- Immediate Anti-Free-Harass Retaliation (`auto-20261023-1329-start-ShaNachnetsya.dem` `tk=6142..6326` & `tk=10644..10874` Fix!):
-- Whenever the live rival hero right-clicks us within `720u` outside an active final CS windup, NEVER stand idle or
-- auto-attack full-HP creeps while taking unanswered right-clicks! Immediately punish with a centered `Shadowraze` +
-- right-click (when healthy/even), OR step crisply outside his attack range (when low/outmatched)!
function H.HandleAntiFreeHarassRetaliation(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if d > 730 then return false end

    local activelyHittingMe = (enemy.GetAttackTarget and enemy:GetAttackTarget() == bot)
        or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 1.35))
    if not activelyHittingMe then return false end

    -- Never brawl inside enemy T1 attack range!
    for _, tw in pairs((s and s.enemyTowers) or {}) do
        if tw and tw:IsAlive() and GetUnitToLocationDistance(bot, tw:GetLocation()) <= 760 then
            return H.DisengageFromLethalTrade(bot, s, earlyRace)
        end
    end

    local enAtk = K.AttackDamageVs(enemy, bot)
    local myAtk = K.AttackDamageVs(bot, enemy)
    local inFlightOnMe = 0
    if bot.GetIncomingTrackingProjectiles then
        local okP, projs = pcall(bot.GetIncomingTrackingProjectiles, bot)
        if okP and type(projs) == "table" then
            for _, pr in pairs(projs) do
                if pr then
                    local caster = pr.caster
                    inFlightOnMe = inFlightOnMe + ((caster and caster.IsHero and caster:IsHero()) and enAtk or 18)
                end
            end
        end
    end
    local myEffHp = math.max(1, (bot:GetHealth() or 0) - inFlightOnMe)
    local enHp = enemy:GetHealth() or 9999
    local lr = U.SolveLethalRace(bot, enemy, s)
    local mySt, myRem = U.GetShadowrazeDebuff(bot)
    local r2Ret = bot:GetAbilityByName("nevermore_shadowraze2")
    local r3Ret = bot:GetAbilityByName("nevermore_shadowraze3")
    local myWESpentRet = (not (r2Ret and U.IsRazeAbilityCastable(bot, r2Ret)))
        and (not (r3Ret and U.IsRazeAbilityCastable(bot, r3Ret)))
    local enMpRet = (enemy:GetMana() or 0) + U.GetMangoMana(enemy)
    local stackedSpentRetal = ((mySt or 0) >= 1 and (myRem or 0) >= 0.8 and enMpRet >= 75 and myWESpentRet and (K.EnemyRazeReadyIn("mid") or 99) <= 1.2)

    -- If low HP or carrying dangerous fresh stacks without first-kill advantage, step clean outside his attack range!
    if not (lr and lr.winsFirstKill) then
        if myEffHp < 235 or stackedSpentRetal or ((mySt or 0) >= 2 and (myRem or 0) > 0.4) or H.InLosingHeroTrade(bot, s, earlyRace) then
            return H.DisengageFromLethalTrade(bot, s, earlyRace)
        end
    end

    -- 1. Punish brazen close/mid/far right-click harass immediately with a dead-center `Shadowraze` —
    --    STRICTLY gated by Raze-Tier / Level-Spike discipline so we NEVER self-root `0.55s` casting an `85`-dmg Raze
    --    into a Level 3/5/7 enemy SF's higher-tier double Raze when they merely tapped us with 1 right-click!
    local outRazedRet = (U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy)) or false
    local nearSpikeRet = (U.IsNearLevelSpike and U.IsNearLevelSpike(bot, enemy)) or false
    local allowRazeRetaliate = (lr and lr.winsFirstKill) or (not outRazedRet and not nearSpikeRet)
    local canPopMango = allowRazeRetaliate and (bot:GetMana() or 0) < 75 and myEffHp >= 260 and d <= 650
    if canPopMango and H.TryUseBurstManaItem(bot, true) then
        return true
    end
    if allowRazeRetaliate and not bot:IsSilenced() and (bot:GetMana() or 0) >= 75
        and not ((mySt or 0) == 1 and (myRem or 0) <= 2.0 and (myRem or 0) > 0.2) then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    State.actionTaken = true
                    return true
                end
            end
        end
    end

    -- 2. Return crisp right-click when trade is even/favorable (`myEffHp >= enHp * 0.62` or winning hit count), else kite back!
    local winningOrEvenClick = (lr and lr.winsFirstKill)
        or (math.ceil(enHp / math.max(1, myAtk)) <= math.ceil(myEffHp / math.max(1, enAtk)) + 1 and myEffHp >= 270)
        or (myEffHp >= enHp * 0.68 and myEffHp >= 260)
    if winningOrEvenClick and d <= (bot:GetAttackRange() or 500) + 95 then
        local prevPolicy = State.combatPolicyActive
        local prevAllow = State.heroCombatAllowed
        State.combatPolicyActive = false
        State.heroCombatAllowed = true
        local okAtk = H.IssueHeroAttack(bot, enemy)
        State.combatPolicyActive = prevPolicy
        State.heroCombatAllowed = prevAllow
        if okAtk then
            State.actionTaken = true
            return true
        end
    end

    return H.DisengageFromLethalTrade(bot, s, earlyRace)
end

-- Safe Enemy Observer/Sentry Deward (`A16` Team-Guarded Ward Check + Free Highground Vision Denial!):
-- Strictly requires `w:GetTeam() ~= bot:GetTeam()` so own/allied Observer Wards are NEVER attacked!
function H.HandleFreeEnemyWardDeward(bot, s)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if L._imminentCS then return false end
    if type(GetUnitList) ~= "function" or not UNIT_LIST_ENEMY_WARDS then return false end
    local enemy = s and s.enemy
    if enemy and U.CanQuery(enemy) and enemy:IsAlive() and (s.enemyDist or 9999) <= 760 then
        return false
    end
    local danger = LN.TowerDanger(bot, s and s.enemyT1 or nil, s and s.allyCreeps or nil, nil)
    if danger >= 1 then return false end
    local ok, wards = pcall(GetUnitList, UNIT_LIST_ENEMY_WARDS)
    if not ok or type(wards) ~= "table" then return false end
    local myTeam = bot:GetTeam()
    local maxReach = (bot:GetAttackRange() or 500) + 95
    for _, w in pairs(wards) do
        local wName = (w and w.GetUnitName and w:GetUnitName()) or ""
        if wName:find("ward") and U.CanQuery(w) and w:IsAlive() and w.GetTeam and w:GetTeam() ~= myTeam then
            if GetUnitToLocationDistance(bot, w:GetLocation()) <= maxReach then
                if not (U.IsAttackingAction(bot) and bot:GetAttackTarget() == w) then
                    bot:Action_AttackUnit(w, true)
                    H.ClearMoveCache()
                end
                State.actionTaken = true
                return true
            end
        end
    end
    return false
end

-- Dedicated Top-Priority Enemy Salve Breaker (`W5 07:01.7` Fix + `v7.9.10-pro` `2048 @ 07:46.00` `276 HP` Suicide Turnback Fix!)
function H.HandleBreakEnemySalve(bot, s, _earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if not enemy:HasModifier("modifier_flask_healing") then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 1 then return false end
    local dHero = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dHero > 960 then return false end
    local now = GameTime()
    local myHp = bot:GetHealth() or 0
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 1)
    local hpPct = myHp / myMaxHp
    local enHp = enemy:GetHealth() or 9999
    local oneMyCoilKills = (enHp <= K.MyRazeDamage(bot, enemy, 1) - 10) and ((bot:GetMana() or 0) + U.GetMangoMana(bot) >= 75)
    -- `2048 @ 07:46.00` (`276/1232 HP = 22.4%`): NEVER spin `180°` and self-root `0.55s` to break Salve when fleeing / in critical
    -- danger / losing hard (`letting a faster Boots enemy close from 959u -> 669u and kill us!`), unless 1 coil literally kills him!
    if not oneMyCoilKills then
        if State.forcedRetreatLoc or (now < (State.fleeUntil or 0) and now >= (State.commitKillUntil or 0)) then
            return false
        end
        if H.InCriticalLethalDanger and H.InCriticalLethalDanger(bot, s, _earlyRace) then
            return false
        end
        if hpPct < 0.34 or (_earlyRace and _earlyRace.valid and (_earlyRace.heCanKillNow or _earlyRace.heCanKillSoon or _earlyRace.losingHard)) then
            return false
        end
        -- Also evaluate burst at the distance the enemy can close to during our `0.15s turn + 0.55s cast = 0.70s` self-root!
        local postCastDist = math.max(200, dHero - (enemy:GetCurrentMovementSpeed() or 310) * 0.70)
        if myHp <= K.EnemyBurstVs(bot, enemy, postCastDist, 1.35, false) + 115 then
            return false
        end
    end
    if myHp <= K.EnemyBurstVs(bot, enemy, dHero, 0.85, false) + 75 then return false end
    if dHero <= (bot:GetAttackRange() or 525) + 175 then
        if H.IssueHeroAttack(bot, enemy) then
            State.actionTaken = true
            return true
        end
    elseif dHero <= 935 then
        local myMana = bot:GetMana() or 0
        if myMana < 75 and K.MyReadyRazeCount(bot, true) >= 1 and H.TryUseBurstManaItem(bot, true) then
            return true
        end
        if myMana >= 75 and not bot:IsSilenced() then
            for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
                local ab = H.GetRazeAbilityByLabel(bot, label)
                if ab and U.IsRazeAbilityCastable(bot, ab) then
                    local action, aim = H.GetRazeActionType(bot, ab, enemy)
                    if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- Uncontested Wave Creep-Tank Drop (`v5.2.0` `creep_tank` synthesis, strictly gated by `L.PeekBestPlan` so 0 CS are lost!):
-- When enemy lane creeps are hitting SF (`GetAttackTarget() == bot` or unshielded proximity) and no CS opens within `1.25s`,
-- drop aggro onto our allied wave or kite smoothly toward `behindT1` instead of tanking 300+ free creep damage!
function H.HandleCreepTankDrop(bot, s)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if L._imminentCS then return false end
    if L.PeekBestPlan then
        local _, etaSec = L.PeekBestPlan(bot, s)
        if etaSec <= 1.25 then return false end
    end
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(ec) and ec:IsAlive() and (ec:GetHealth() or 999) <= (U.SFDamageRange(bot, ec).min + 12) then
            return false
        end
    end
    local bLoc = bot:GetLocation()
    local hittingCount, rangedHitting, closestEnemyCreep = 0, false, nil
    local hasAllyShield = #(s and s.allyCreeps or {}) > 0
    if U.CountEnemyCreepsAggroedOnBot then
        hittingCount, rangedHitting, closestEnemyCreep = U.CountEnemyCreepsAggroedOnBot(bot, s, State.myCreepChaseUntil)
    else
        local closestDist = math.huge
        for _, ec in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(ec) and ec:IsAlive() then
                local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                local cRng = (ec.GetAttackRange and ec:GetAttackRange()) or 100
                local lockedOnMe = (ec.GetAttackTarget and ec:GetAttackTarget() == bot)
                    or (not hasAllyShield and dc <= math.max(195, cRng + 35))
                if lockedOnMe then
                    hittingCount = hittingCount + 1
                    if cRng > 300 and dc <= 525 then rangedHitting = true end
                    if dc < closestDist then closestDist, closestEnemyCreep = dc, ec end
                end
            end
        end
    end
    if hittingCount == 0 then return false end
    local now = GameTime()
    local chaseLocked = now < ((State.myCreepChaseUntil or 0) - 0.08)
    local enemy = s and s.enemy
    local hasLiveEnemy = enemy and U.CanQuery(enemy) and enemy:IsAlive()
    local dEnemy = hasLiveEnemy and U.DistanceBetweenLocations(bLoc, enemy:GetLocation()) or 9999
    local fnt = P.GetFountain(bot)
    local ownT1Loc = (s and s.allyT1Alive ~= false and s.allyT1Loc)
        or ((P and P.GetT1Tower and P.GetT1Tower(bot)) or nil)
    local lowestUnderOwnT1, lowHpOwnT1 = nil, math.huge
    local ownT1ReachK = (C.BALLISTIC and C.BALLISTIC.TOWER_ATTACK_RANGE_C2C) or 870
    if ownT1Loc then
        for _, ec in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(ec:GetLocation(), ownT1Loc) <= ownT1ReachK then
                local chp = ec:GetHealth() or 9999
                if chp < lowHpOwnT1 then
                    lowHpOwnT1, lowestUnderOwnT1 = chp, ec
                end
            end
        end
    end
    -- `v7.9.29-pro` (`auto-20261108-2131` `01:41.5..01:43.1` `E1967` `286 HP` Own-T1 Farm Immunity Fix!):
    -- Never panic-retreat behind T1 over a SINGLE enemy creep (`hittingCount == 1`) that is ALREADY inside our own
    -- `allyT1` `870u` zone being farmed by our T1 when we are healthy (`>= 260 HP`) and unthreatened (`dEnemy >= 720u`)!
    if hittingCount == 1 and hasAllyShield and (bot:GetHealth() or 0) > (bot:GetMaxHealth() or 600) * 0.65 then
        return false
    end
    if hittingCount == 1 and lowestUnderOwnT1 and (bot:GetHealth() or 0) >= 260 and dEnemy >= 720 then
        return false
    end
    local bestAlly, anyLiveAlly = H.FindSafeDeaggroAllyCreep(bot, s and s.allyCreeps, enemy)
    -- `v7.9.29-pro`: ONLY issue `Action_AttackUnit(bestAlly)` when `bestAlly` is ALREADY inside our attack acquisition
    -- reach (`<= atkRange + 55`), NEVER when `bestAlly` is `1,150u` behind T1 (which walks SF `650u` away from CS!)!
    local bestAllyInPlace = bestAlly
        and (U.DistanceBetweenLocations(bLoc, bestAlly:GetLocation()) <= ((bot:GetAttackRange() or 500) + 55))
    if not chaseLocked and not rangedHitting and bestAllyInPlace and (hittingCount < 2 or dEnemy >= 585)
        and now >= (State.lastTankDeaggroAt or -100) + 1.35 then
        State.lastTankDeaggroAt = now
        State.creepKiteUntil = nil
        if U.ClearCreepAggroMemory then U.ClearCreepAggroMemory() end
        bot:Action_AttackUnit(bestAlly, true)
        State.actionTaken = true
        return true
    end
    if hittingCount >= 2 then
        State.creepKiteUntil = math.max(State.creepKiteUntil or 0,
            math.min(((State.myCreepChaseUntil or (now + 0.65)) + 0.12), now + 0.72))
    end
    bestAlly = bestAlly or anyLiveAlly
    local anchor
    -- `v7.9.25-pro` (`auto-20261108-1609` `01:41, 02:42, 03:41` Own-T1 CS Orbit Preservation):
    -- When enemy creeps are already inside our own T1's `760u` zone (`lowestUnderOwnT1 ~= nil`), hand off at `ownT1Loc + 145u`
    -- clamped strictly within `<= 465u` of `lowestUnderOwnT1` (pivoted behind T1 away from `enemy`) instead of running
    -- `220 + 380u` behind T1 to `(972, 974)` `870u+` out of CS range!
    if lowestUnderOwnT1 and ownT1Loc then
        local lowLocT1 = lowestUnderOwnT1:GetLocation()
        local keepRangeT1 = math.max(405, (bot:GetAttackRange() or 500) - 35)
        anchor = ownT1Loc + (fnt - ownT1Loc):Normalized() * 145
        if hasLiveEnemy and U.DistanceBetweenLocations(anchor, enemy:GetLocation()) < 635 then
            local awayEnT1 = (ownT1Loc - enemy:GetLocation())
            if awayEnT1:Length2D() > 1 then
                anchor = lowLocT1 + (((fnt - lowLocT1):Normalized() * 0.50) + (awayEnT1:Normalized() * 0.70)):Normalized() * keepRangeT1
            end
        end
        if U.DistanceBetweenLocations(anchor, lowLocT1) > keepRangeT1 then
            anchor = lowLocT1 + (anchor - lowLocT1):Normalized() * keepRangeT1
        end
    elseif hittingCount >= 2 and P.GetBehindT1 then
        anchor = P.GetBehindT1(bot, 220)
    elseif bestAlly and U.DistanceBetweenLocations(bestAlly:GetLocation(), fnt) <= U.DistanceBetweenLocations(bLoc, fnt) + 45 then
        anchor = bestAlly:GetLocation() + (fnt - bestAlly:GetLocation()):Normalized() * (rangedHitting and 340 or 230)
    else
        anchor = (P.GetBehindT1 and P.GetBehindT1(bot, 195)) or (bLoc + (fnt - bLoc):Normalized() * 340)
    end
    if (not lowestUnderOwnT1) and hasLiveEnemy and U.DistanceBetweenLocations(anchor, enemy:GetLocation()) < 650 then
        anchor = bLoc + (fnt - bLoc):Normalized() * 380
    end
    if H.SmartMove(bot, anchor, 35) then
        return true
    end
    return false
end

-- Resolve live + fallback Patch 7.41f Mid Tower coordinates (`T1, T2, T3`) for both teams.
function H.GetMidTowerGeometry(bot)
    local isRad = (bot:GetTeam() == TEAM_RADIANT)
    local myTeam = bot:GetTeam()
    local enTeam = (type(GetOpposingTeam) == "function" and GetOpposingTeam()) or (isRad and TEAM_DIRE or TEAM_RADIANT)
    local myT1 = isRad and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1
    local myT2 = isRad and C.POSITIONS.RADIANT_T2 or C.POSITIONS.DIRE_T2
    local myT3 = isRad and C.POSITIONS.RADIANT_T3 or C.POSITIONS.DIRE_T3
    local enT1 = isRad and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
    local enT2 = isRad and C.POSITIONS.DIRE_T2 or C.POSITIONS.RADIANT_T2
    if type(GetTower) == "function" then
        local function qTw(tm, slot, fb)
            if slot == nil then return fb end
            local ok, tw = pcall(GetTower, tm, slot)
            if ok and tw and U.CanQuery(tw) and tw:IsAlive() then
                return tw:GetLocation() or fb
            end
            return fb
        end
        myT1 = qTw(myTeam, TOWER_MID_1, myT1)
        myT2 = qTw(myTeam, TOWER_MID_2, myT2)
        myT3 = qTw(myTeam, TOWER_MID_3, myT3)
        enT1 = qTw(enTeam, TOWER_MID_1, enT1)
        enT2 = qTw(enTeam, TOWER_MID_2, enT2)
    end
    return isRad, myT1, myT2, myT3, enT1, enT2
end

function H.EnsurePassableOutsideTowers(pt, twA, twB, minTowerDist)
    if not pt then return nil end
    local minD = minTowerDist or 960
    local function okPt(cand)
        if twA and U.DistanceBetweenLocations(cand, twA) < minD then return false end
        if twB and U.DistanceBetweenLocations(cand, twB) < minD then return false end
        if type(IsLocationPassable) == "function" and not IsLocationPassable(cand) then return false end
        return true
    end
    if okPt(pt) then return pt end
    for r = 70, 350, 70 do
        for k = 0, 11 do
            local a = (k * math.pi) / 6.0
            local cand = Vector(pt.x + math.cos(a) * r, pt.y + math.sin(a) * r, pt.z or 128)
            if okPt(cand) then return cand end
        end
    end
    return pt
end

-- `auto-20261102-0159-start-ShaNachnetsya.dem` Fix #2:
-- Guarantee `standPt` stays strictly within `<= maxWardDist` (`435u < 475u` cast gate) of `wardTarget` AFTER passability
-- nudging! Previously `EnsurePassableOutsideTowers` nudged `(1210, 1675)` to `(1120, 1760)` (`543.1u > 475u`), causing SF
-- to arrive at `standPt` in `ACT_DOTA_IDLE` while forever waiting for `dToWard2 <= 475`!
function H.EnsureWardStandPoint(prefPt, wardTarget, twA, twB, minTowerDist, maxWardDist)
    if not wardTarget then return prefPt end
    local minTw = minTowerDist or 955
    local maxWd = maxWardDist or 435
    local function okStand(cand)
        if not cand then return false end
        if U.DistanceBetweenLocations(cand, wardTarget) > maxWd then return false end
        if twA and U.DistanceBetweenLocations(cand, twA) < minTw then return false end
        if twB and U.DistanceBetweenLocations(cand, twB) < minTw then return false end
        if type(IsLocationPassable) == "function" and not IsLocationPassable(cand) then return false end
        return true
    end
    if prefPt and okStand(prefPt) then return prefPt end
    if prefPt then
        for r = 64, 420, 64 do
            for k = 0, 15 do
                local a = (k * math.pi) / 8.0
                local cand = Vector(prefPt.x + math.cos(a) * r, prefPt.y + math.sin(a) * r, prefPt.z or 128)
                if okStand(cand) then return cand end
            end
        end
    end
    if okStand(wardTarget) then return wardTarget end
    for r = 80, 400, 80 do
        for k = 0, 15 do
            local a = (k * math.pi) / 8.0
            local cand = Vector(wardTarget.x + math.cos(a) * r, wardTarget.y + math.sin(a) * r, wardTarget.z or 128)
            if okStand(cand) then return cand end
        end
    end
    return wardTarget
end

-- Check whether an alive allied Observer Ward already sits within `minDist` of `spot` (prevents double-warding!).
function H.HasAlliedObserverNear(spot, minDist)
    if not spot then return false end
    local rad = minDist or 880
    local now = GameTime()
    if State.lastPlacedWardLoc and State.lastPlacedWardAt and (now - State.lastPlacedWardAt) <= 340.0 then
        if U.DistanceBetweenLocations(State.lastPlacedWardLoc, spot) <= rad then
            -- Verify via `UNIT_LIST_ALLIED_WARDS` when available; if API unavailable, respect recent cache for 75s
            if type(GetUnitList) ~= "function" or not UNIT_LIST_ALLIED_WARDS then
                if (now - State.lastPlacedWardAt) <= 75.0 then return true end
            end
        end
    end
    if type(GetUnitList) == "function" and UNIT_LIST_ALLIED_WARDS then
        local okW, aWards = pcall(GetUnitList, UNIT_LIST_ALLIED_WARDS)
        if okW and aWards then
            for _, aw in pairs(aWards) do
                if aw and U.CanQuery(aw) and aw:IsAlive() then
                    local wn = (aw.GetUnitName and aw:GetUnitName()) or ""
                    if wn == "" or string.find(wn, "observer", 1, true) then
                        if U.DistanceBetweenLocations(aw:GetLocation(), spot) <= rad then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

-- Open-Ground Multi-Waypoint Corridor + Self-Recorded NavMesh Breadcrumb Reversal (`v7.9.3`,
-- fixes BOTH `auto-20261101-2135.dem` & `9072220529.dem` `(-2209,-663)` / `(-2143,-625)` / `(-1318,-452)` stalls!):
--   1. Outbound to Ward #2 walks the explicit open-ground northern/NW corridor (`WARD2_CORRIDOR_FOR_DIRE/RADIANT`,
--      `1,021u..1,480u` outside Enemy T1 with `0` radial `tangCand` walls!) AND records live navmesh breadcrumbs
--      `State.ward2Breadcrumbs` every `220u` along the actual path SF physically walked at `305 MS`.
--   2. Inbound from Ward #2 pops `State.ward2Breadcrumbs` strictly in reverse (`#list -> 1`), retracing the exact
--      100%-passable outbound footsteps back to `WARD_1` on the river, guarded by a `0.45s` real-velocity watchdog
--      that skips any dynamically body-blocked waypoint so SF can NEVER walk in place!
function H.GetSafeWardCastStandpoint(bot, wardLoc)
    if not wardLoc then return nil end
    if C.POSITIONS.WARD_RADIANT and C.POSITIONS.WARD_CAST_RADIANT
        and U.DistanceBetweenLocations(wardLoc, C.POSITIONS.WARD_RADIANT) <= 55 then
        return C.POSITIONS.WARD_CAST_RADIANT
    end
    if C.POSITIONS.WARD_DIRE and C.POSITIONS.WARD_CAST_DIRE
        and U.DistanceBetweenLocations(wardLoc, C.POSITIONS.WARD_DIRE) <= 55 then
        return C.POSITIONS.WARD_CAST_DIRE
    end
    return wardLoc
end

function H.RecordWard2Breadcrumb(bot)
    local bLoc = bot:GetLocation()
    if not bLoc then return end
    State.ward2Breadcrumbs = State.ward2Breadcrumbs or {}
    local crumbs = State.ward2Breadcrumbs
    if #crumbs == 0 then
        local isRad = (bot:GetTeam() == TEAM_RADIANT)
        local riverAnchor = isRad and (C.POSITIONS.WARD_CAST_RADIANT or C.POSITIONS.WARD_RADIANT)
            or (C.POSITIONS.WARD_CAST_DIRE or C.POSITIONS.WARD_DIRE)
        if riverAnchor then
            crumbs[#crumbs + 1] = Vector(riverAnchor.x, riverAnchor.y, riverAnchor.z or 128)
        end
    end
    local last = crumbs[#crumbs]
    if not last or U.DistanceBetweenLocations(bLoc, last) >= 220 then
        crumbs[#crumbs + 1] = Vector(bLoc.x, bLoc.y, bLoc.z or 128)
    end
end

function H.FollowWard2ReturnBreadcrumbs(bot)
    local crumbs = State.ward2Breadcrumbs
    if not crumbs or #crumbs == 0 then return false end
    local bLoc = bot:GetLocation()
    local now = GameTime()

    -- Pop all breadcrumbs already reached (`<= 155u`) OR already behind us toward Enemy T2
    while #crumbs > 0 and U.DistanceBetweenLocations(bLoc, crumbs[#crumbs]) <= 155 do
        table.remove(crumbs, #crumbs)
        State.crumbStuckCheckAt = nil
        State.crumbStuckRefLoc = nil
    end
    if #crumbs == 0 then return false end

    -- Real-velocity `0.45s` anti-stuck watchdog: if blocked by hero/trees (`moved < 24u` in `0.45s`), skip current crumb!
    if not State.crumbStuckCheckAt or not State.crumbStuckRefLoc then
        State.crumbStuckCheckAt = now
        State.crumbStuckRefLoc = bLoc
    elseif (now - State.crumbStuckCheckAt) >= 0.45 then
        if U.DistanceBetweenLocations(bLoc, State.crumbStuckRefLoc) < 24 then
            table.remove(crumbs, #crumbs)
        end
        State.crumbStuckCheckAt = now
        State.crumbStuckRefLoc = bLoc
    end
    if #crumbs == 0 then return false end

    local targetWp = crumbs[#crumbs]
    bot:Action_MoveToLocation(targetWp)
    State.lastMoveLoc = targetWp
    State.lastMoveTime = now
    State.actionTaken = true
    return true
end

function H.SafeArcMoveAroundEnemyTowers(bot, goalLoc)
    local isRad, _, _, _, enT1, enT2 = H.GetMidTowerGeometry(bot)
    local bLoc = bot:GetLocation()
    local now = GameTime()
    local corridor = isRad and C.POSITIONS.WARD2_CORRIDOR_FOR_RADIANT or C.POSITIONS.WARD2_CORRIDOR_FOR_DIRE

    local vx, vy = goalLoc.x - bLoc.x, goalLoc.y - bLoc.y
    local segLen2 = vx * vx + vy * vy
    local segMinDistEnT1 = U.DistanceBetweenLocations(bLoc, enT1)
    if segLen2 > 25 then
        local tSeg = math.max(0.0, math.min(1.0, ((enT1.x - bLoc.x) * vx + (enT1.y - bLoc.y) * vy) / segLen2))
        local cx, cy = bLoc.x + vx * tSeg, bLoc.y + vy * tSeg
        segMinDistEnT1 = math.sqrt((enT1.x - cx) * (enT1.x - cx) + (enT1.y - cy) * (enT1.y - cy))
    end

    -- `930u` clears both `700u` tower attack and `900u` True Sight while allowing the natural `951u` Dire river corridor!
    local nextWp = goalLoc
    local goalKey = math.floor(goalLoc.x * 0.1) .. "_" .. math.floor(goalLoc.y * 0.1)
    if segMinDistEnT1 < 930 and corridor and #corridor >= 2 then
        local bestGoalIdx, bestGoalD = #corridor, math.huge
        for i, wp in ipairs(corridor) do
            local dG = U.DistanceBetweenLocations(goalLoc, wp)
            if dG < bestGoalD then bestGoalD, bestGoalIdx = dG, i end
        end
        if State.arcGoalKey ~= goalKey or not State.arcWpIdx then
            local startIdx, bestCurD = 1, math.huge
            for i, wp in ipairs(corridor) do
                local dB = U.DistanceBetweenLocations(bLoc, wp)
                if dB < bestCurD then bestCurD, startIdx = dB, i end
            end
            State.arcGoalKey = goalKey
            State.arcWpIdx = startIdx
            State.arcCheckAt = now
            State.arcRefLoc = bLoc
        end
        local stepDir = (bestGoalIdx >= State.arcWpIdx) and 1 or -1
        while State.arcWpIdx ~= bestGoalIdx and U.DistanceBetweenLocations(bLoc, corridor[State.arcWpIdx]) <= 165 do
            State.arcWpIdx = math.max(1, math.min(#corridor, State.arcWpIdx + stepDir))
            State.arcCheckAt = now
            State.arcRefLoc = bLoc
        end
        if State.arcCheckAt and State.arcRefLoc and (now - State.arcCheckAt) >= 0.45 then
            if U.DistanceBetweenLocations(bLoc, State.arcRefLoc) < 24 and State.arcWpIdx ~= bestGoalIdx then
                State.arcWpIdx = math.max(1, math.min(#corridor, State.arcWpIdx + stepDir))
            end
            State.arcCheckAt = now
            State.arcRefLoc = bLoc
        end
        local candWp = (State.arcWpIdx == bestGoalIdx and U.DistanceBetweenLocations(bLoc, corridor[bestGoalIdx]) <= 165)
            and goalLoc
            or corridor[State.arcWpIdx]
        nextWp = H.EnsurePassableOutsideTowers(candWp, enT1, enT2, 925) or candWp
    else
        State.arcGoalKey = nil
        State.arcWpIdx = nil
    end
    bot:Action_MoveToLocation(nextWp)
    State.lastMoveLoc = nextWp
    State.lastMoveTime = now
    State.actionTaken = true
end

-- Count total `item_ward_observer` charges in active + backpack slots (`0..8`).
function H.CountInventoryObserverWardCharges(bot)
    local total = 0
    for sl = 0, 8 do
        local it = bot:GetItemInSlot(sl)
        if it and it:GetName() == "item_ward_observer" then
            total = total + math.max(1, (it.GetCurrentCharges and it:GetCurrentCharges()) or 1)
        end
    end
    return total
end

-- Top-Level 2-Ward Pre-Horn Choreographer + Post-Horn 3-Spot Anti-Deward Night Ward Planter (`v7.9.3`):
--   * Pre-Horn Ward #1 (`dtime < 0`): plants on the EXACT standard river highground spot (`WARD_RADIANT` / `WARD_DIRE`).
--   * Pre-Horn Ward #2 (`dtime < -31.0`): detours safely (`R >= 1,020u` outside Enemy T1) along the open corridor while
--     recording `State.ward2Breadcrumbs`, plants between Enemy Mid T1 and T2, and then retraces its exact breadcrumbs back!
function H.HandlePriorityWardPlant(bot, s)
    local now = GameTime()
    if now < (State.lastWardCheckAt or -100) then return false end
    local dtime = DotaTime()
    local totalWardCharges = H.CountInventoryObserverWardCharges(bot)
    if dtime < -84 and totalWardCharges >= 2 then
        State.preHornRiverWardDone = false
        State.preHornEnemyLaneWardDone = false
        State.preHornWard2Aborted = false
        State.riverWardStartCharges = nil
        State.enemyWardStartCharges = nil
        State.ward2Breadcrumbs = nil
    end
    if totalWardCharges <= 0 then
        return false
    end

    local isRad, _, _, _, enT1, enT2 = H.GetMidTowerGeometry(bot)

    -- ========================================================================
    -- PRE-HORN (`dtime < 0`): Ward #1 (own HG) -> Ward #2 (between Enemy T1 & T2)
    -- ========================================================================
    if dtime < 0 then
        -- Confirm Ward #1 completion via actual charge consumption (`2 -> 1` or `1 -> 0`)
        if not State.preHornRiverWardDone then
            if State.riverWardStartCharges and totalWardCharges < State.riverWardStartCharges then
                State.preHornRiverWardDone = true
                State.lastPlacedWardLoc = isRad and C.POSITIONS.WARD_RADIANT or C.POSITIONS.WARD_DIRE
                State.lastPlacedWardAt = now
                State.wardPlantCount = math.max(1, State.wardPlantCount or 0)
            end
        end
        if State.preHornRiverWardDone and not State.preHornEnemyLaneWardDone then
            if State.enemyWardStartCharges and totalWardCharges < State.enemyWardStartCharges then
                State.preHornEnemyLaneWardDone = true
                State.ward2StallCheckAt = nil
                State.ward2StallCount = 0
                State.wardPlantCount = (State.wardPlantCount or 1) + 1
                return false
            end
        end

        -- PHASE 1: Plant Ward #1 on our `.dem`-verified `z=128` highground spot
        if not State.preHornRiverWardDone then
            if dtime >= -16.0 then
                -- Too close to creep spawn — never miss the T3 opening block!
                State.preHornRiverWardDone = true
                State.preHornWard2Aborted = true
                return false
            end
            local ward1, castable1 = H.EnsureConsumableReady(bot, "item_ward_observer")
            local ward1Loc = isRad and C.POSITIONS.WARD_RADIANT or C.POSITIONS.WARD_DIRE
            if not ward1Loc then return false end
            local ward1StandLoc = H.GetSafeWardCastStandpoint(bot, ward1Loc) or ward1Loc
            State.riverWardStartCharges = State.riverWardStartCharges or totalWardCharges
            local d1 = GetUnitToLocationDistance(bot, ward1Loc)
            if castable1 and ward1 and d1 <= 492 then
                if now >= (State.lastWardCastCmdAt or -100) + 0.25 then
                    bot:Action_UseAbilityOnLocation(ward1, ward1Loc)
                    State.lastPlacedWardLoc = ward1Loc
                    State.lastPlacedWardAt = now
                    State.lastWardCastCmdAt = now
                end
                State.actionTaken = true
                return true
            end
            H.SmartMove(bot, ward1StandLoc, 28, true)
            State.actionTaken = true
            return true
        end

        -- PHASE 2: Plant Ward #2 between Enemy Mid T1 and Enemy Mid T2 (`R >= 1,020u` outside Enemy T1 & T2!)
        if not State.preHornEnemyLaneWardDone and not State.preHornWard2Aborted then
            local lowHpAbort = (bot:GetHealth() or 600) < (bot:GetMaxHealth() or 600) * 0.80
            local towerHitAbort = bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(2.0)
            local heroBrawlAbort = s and s.enemy and U.CanQuery(s.enemy) and (s.enemyDist or 9999) <= 560
                and bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(1.8)
            -- Strict `-31.0s` cutoff guarantees `>= 27.7s` return walk back to Own Mid T3 before `-3.3s` wave march!
            if dtime >= -31.0 or lowHpAbort or towerHitAbort or heroBrawlAbort then
                State.preHornWard2Aborted = true
                State.ward2StallCheckAt = nil
                return false
            end

            H.RecordWard2Breadcrumb(bot)
            local ward2, castable2 = H.EnsureConsumableReady(bot, "item_ward_observer")
            local prefWard2 = isRad and C.POSITIONS.ENEMY_T1T2_WARD_FOR_RADIANT or C.POSITIONS.ENEMY_T1T2_WARD_FOR_DIRE
            local rawMidT1T2 = prefWard2 or Vector(0.5 * (enT1.x + enT2.x), 0.5 * (enT1.y + enT2.y), 128)
            local ward2Target = H.EnsurePassableOutsideTowers(rawMidT1T2, enT1, enT2, 980)
            local arcPool = isRad and C.POSITIONS.ENEMY_T1T2_ARC_FOR_RADIANT or C.POSITIONS.ENEMY_T1T2_ARC_FOR_DIRE
            local standPt = H.EnsureWardStandPoint(arcPool and arcPool[2], ward2Target, enT1, enT2, 955, 435)
            State.enemyWardStartCharges = State.enemyWardStartCharges or totalWardCharges

            -- Real-velocity `1.35s` stall watchdog (`auto-20261102-0159` `-00:49.2..-00:31.0` `18s` Idle Fix!):
            --   * 1st stall (`1.35s` with `< 24u` displacement): bypass `standPt` and path straight to `ward2Target`!
            --   * 2nd stall (`2.70s` total): abort Ward #2 cleanly so SF returns to `T3_BLOCK` with `40s+` margin!
            local bLocW2 = bot:GetLocation()
            if not State.ward2StallCheckAt or not State.ward2StallRefLoc then
                State.ward2StallCheckAt = now
                State.ward2StallRefLoc = bLocW2
                State.ward2StallCount = 0
            elseif (now - State.ward2StallCheckAt) >= 1.35 then
                if U.DistanceBetweenLocations(bLocW2, State.ward2StallRefLoc) < 24 then
                    State.ward2StallCount = (State.ward2StallCount or 0) + 1
                    if State.ward2StallCount >= 2 then
                        State.preHornWard2Aborted = true
                        State.ward2StallCheckAt = nil
                        return false
                    end
                else
                    State.ward2StallCount = 0
                end
                State.ward2StallCheckAt = now
                State.ward2StallRefLoc = bLocW2
            end
            if (State.ward2StallCount or 0) >= 1 or GetUnitToLocationDistance(bot, standPt) <= 95 then
                standPt = ward2Target
            end

            local dToWard2 = GetUnitToLocationDistance(bot, ward2Target)
            local dToEnT1 = GetUnitToLocationDistance(bot, enT1)
            if castable2 and ward2 and dToWard2 <= 475 and dToEnT1 >= 905 then
                if now >= (State.lastWardCastCmdAt or -100) + 0.25 then
                    bot:Action_UseAbilityOnLocation(ward2, ward2Target)
                    State.lastWardCastCmdAt = now
                end
                State.actionTaken = true
                return true
            end
            H.SafeArcMoveAroundEnemyTowers(bot, standPt)
            State.actionTaken = true
            return true
        end

        return false
    end

    -- ========================================================================
    -- POST-HORN (`dtime >= 0`): Highground Anti-Deward Night Ward Planter (`v7.9.24-pro` Zero-Stall Upgrade!)
    -- ========================================================================
    -- NEVER interrupt Wave #1 opening creep block or initial wave clash (`dtime < 28.0s`)!
    if dtime < 28.0 then return false end
    if not U.HasItem(bot, "item_ward_observer") then return false end
    local enemyNear = s and s.enemy and U.CanQuery(s.enemy) and s.enemyDist <= 880
    if enemyNear then return false end

    local spotPool = isRad and C.POSITIONS.WARD_SPOTS_RADIANT or C.POSITIONS.WARD_SPOTS_DIRE
    local wardLoc = isRad and C.POSITIONS.WARD_RADIANT or C.POSITIONS.WARD_DIRE
    if spotPool and #spotPool > 0 then
        local baseIdx = ((State.wardPlantCount or 0) % #spotPool) + 1
        local unwardedSpot = nil
        for offset = 0, #spotPool - 1 do
            local cand = spotPool[((baseIdx - 1 + offset) % #spotPool) + 1]
            if not H.HasAlliedObserverNear(cand, 900) then
                unwardedSpot = cand
                break
            end
        end
        -- If ALL highground spots already have live allied Observer coverage (`e.g. Ward #1 is still alive!`),
        -- hold the spare Observer Ward in backpack until vision expires or gets dewarded — NEVER stack 2 wards!
        if not unwardedSpot then
            return false
        end
        wardLoc = unwardedSpot
        if type(GetUnitList) == "function" and UNIT_LIST_ENEMY_WARDS then
            local okW, eWards = pcall(GetUnitList, UNIT_LIST_ENEMY_WARDS)
            if okW and eWards and #eWards > 0 then
                local bestSpot, bestMinSentryD = nil, -1
                for offset = 0, #spotPool - 1 do
                    local candSpot = spotPool[((baseIdx - 1 + offset) % #spotPool) + 1]
                    if not H.HasAlliedObserverNear(candSpot, 900) then
                        local minSD = math.huge
                        for _, ew in pairs(eWards) do
                            if ew and U.CanQuery(ew) and ew:IsAlive() then
                                local sd = U.DistanceBetweenLocations(ew:GetLocation(), candSpot)
                                if sd < minSD then minSD = sd end
                            end
                        end
                        if minSD > 1010 then
                            bestSpot, bestMinSentryD = candSpot, minSD
                            break
                        elseif minSD > bestMinSentryD then
                            bestSpot, bestMinSentryD = candSpot, minSD
                        end
                    end
                end
                if bestSpot then
                    wardLoc = bestSpot
                end
                if bestMinSentryD >= 0 and bestMinSentryD <= 1010 then
                    local centerAnchor = spotPool[1]
                    local ridgeDir = (wardLoc - centerAnchor)
                    if ridgeDir:Length2D() < 10 then
                        ridgeDir = Vector(-0.7071, 0.7071, 0)
                    else
                        ridgeDir = ridgeDir:Normalized()
                    end
                    local safeOut = centerAnchor + ridgeDir * 1045
                    if not H.HasAlliedObserverNear(safeOut, 900)
                        and (type(IsLocationPassable) ~= "function" or IsLocationPassable(safeOut)) then
                        wardLoc = safeOut
                    end
                end
            end
        end
    end
    if not wardLoc or H.HasAlliedObserverNear(wardLoc, 900) then return false end

    local d = GetUnitToLocationDistance(bot, wardLoc)
    -- NOTE (`auto-20261108-1523.dem` `05:24.73..07:27.67` `123s` Ward Stall Fix!):
    --   1. Do NOT check `s.hasDistantMidWaveClash` here (`hasDistantMidWaveClash` stays `true` for unengaged allied creeps
    --      marching down an empty lane even when `0` enemy creeps exist on the map!). Check actual mid enemy creeps instead!
    --   2. Pre-swap `item_ward_observer` from Backpack into an active slot (`0`-tick `ActionImmediate_SwapItems`) whenever
    --      no enemy creeps are active OR `d <= 920u` OR an empty/branch/faerie slot is available, so the `6.0s` Backpack CD
    --      ticks down DURING the wave!
    --   3. `item_ward_observer` has `500u` cast range & `0.0s` cast point:
    --      * `d <= 495u`: `0`-walk `1`-tick instant plant even mid-wave whenever no CS fires inside `<= 0.38s`!
    --      * `d <= 880u`: quick `<= 1.1s` step during wave slack when no CS opens inside `walkSec * 1.8 + 0.95s`!
    --      * `d >  880u`: plant immediately between waves whenever `#enemyCreeps == 0 and #midActiveEnemyCreeps == 0`!
    local hasEnemyMidCreeps = s and (#(s.enemyCreeps or {}) > 0 or #(s.midActiveEnemyCreeps or {}) > 0) or false
    local hasLowPrioOrFreeSlot = false
    for i = 0, 5 do
        local itS = bot:GetItemInSlot(i)
        if not itS then
            hasLowPrioOrFreeSlot = true
            break
        end
        local nmS = itS:GetName()
        if nmS == "item_ward_observer" or nmS == "item_branches" or nmS == "item_faerie_fire" or nmS == "item_tpscroll" then
            hasLowPrioOrFreeSlot = true
            break
        end
    end
    if (not hasEnemyMidCreeps) or d <= 920 or hasLowPrioOrFreeSlot then
        local ward, castable = H.EnsureConsumableReady(bot, "item_ward_observer")
        if castable and ward then
            local curTickW = math.floor(now * 30.0 + 0.5)
            local recW = U._unitTrack and U._unitTrack[bot]
            local inWindupW = recW and recW.wasAnim == true and recW.launchTick and recW.launchTick >= curTickW
            if inWindupW then return false end

            local wardStandLoc = H.GetSafeWardCastStandpoint(bot, wardLoc) or wardLoc
            if not hasEnemyMidCreeps then
                if d <= 495 then
                    bot:Action_UseAbilityOnLocation(ward, wardLoc)
                    State.lastPlacedWardLoc = wardLoc
                    State.lastPlacedWardAt = now
                    State.wardPlantCount = (State.wardPlantCount or 0) + 1
                    State.lastWardCheckAt = now + 1.0
                    State.actionTaken = true
                    return true
                else
                    H.SmartMove(bot, wardStandLoc, 30)
                    State.actionTaken = true
                    return true
                end
            end

            -- Active enemy creeps exist on lane: check exact `L.PeekBestPlan` slack window!
            local csPlanW, csEtaW = nil, 99
            if L and L.PeekBestPlan then
                csPlanW, csEtaW = L.PeekBestPlan(bot, s)
            end
            if d <= 495 and (not csPlanW or (csEtaW or 99) > 0.38) then
                bot:Action_UseAbilityOnLocation(ward, wardLoc)
                State.lastPlacedWardLoc = wardLoc
                State.lastPlacedWardAt = now
                State.wardPlantCount = (State.wardPlantCount or 0) + 1
                State.lastWardCheckAt = now + 1.0
                State.actionTaken = true
                return true
            elseif d <= 880 then
                local msW = math.max(265, (bot.GetCurrentMovementSpeed and bot:GetCurrentMovementSpeed()) or 315)
                local walkSecW = math.max(0, d - 475) / msW
                local minEnemyHpW = math.huge
                for _, ecW in pairs((s and s.enemyCreeps) or {}) do
                    if ecW and U.CanQuery(ecW) and ecW:IsAlive() then
                        local hW = ecW:GetHealth() or 9999
                        if hW < minEnemyHpW then minEnemyHpW = hW end
                    end
                end
                local safeWaveHpFloor = ((bot.GetAttackDamage and bot:GetAttackDamage()) or 70) * 2.2 + 45
                if (not csPlanW or (csEtaW or 99) > (walkSecW * 1.8 + 0.95)) and minEnemyHpW > safeWaveHpFloor then
                    H.SmartMove(bot, wardStandLoc, 30)
                    State.actionTaken = true
                    return true
                end
            end
        end
    end
    return false
end

-- `v7.9.11-pro` Priority-Sorted Backpack Stat-Swapping Tables:
--   * `SALVE_AMP_STAT_RANK` (`+STR` / `+MaxHP` descending): `Ogre Axe / Dragon Lance / Ultimate Orb (10)` >
--     `Belt of Strength (6)` > `Bracer (5)` > `Crown (4)` > `Gauntlets / Wand (3)` > `Wraith / Null / Circlet / Diadem (2)` >
--     `Iron Branch (1)`.
--   * `MANGO_AMP_STAT_ITEMS` / `CLARITY_AMP_STAT_RANK` (`+INT` / `+MaxMP` descending): `Kaya (16)` >
--     `Staff of Wizardry / Ultimate Orb (10)` > `Robe of the Magi (6)` > `Null Talisman (5)` > `Crown (4)` >
--     `Mantle / Wand (3)` > `Bracer / Wraith / Circlet / Diadem (2)` > `Iron Branch (1)`.
local SALVE_AMP_STAT_RANK = {
    ["item_hurricane_pike"]    = 15,
    ["item_sange"]             = 16,
    ["item_sange_and_yasha"]   = 16,
    ["item_vitality_booster"]  = 12,
    ["item_point_booster"]     = 11,
    ["item_ogre_axe"]          = 10,
    ["item_dragon_lance"]      = 10,
    ["item_manta"]             = 10,
    ["item_black_king_bar"]    = 10,
    ["item_ultimate_orb"]      = 10,
    ["item_belt_of_strength"]  = 6,
    ["item_diadem"]            = 6,
    ["item_bracer"]            = 5,
    ["item_crown"]             = 4,
    ["item_gauntlets"]         = 3,
    ["item_magic_wand"]        = 3,
    ["item_wraith_band"]       = 2,
    ["item_null_talisman"]     = 2,
    ["item_circlet"]           = 2,
    ["item_branches"]          = 1,
}

local CLARITY_AMP_STAT_RANK = {
    ["item_mystic_staff"]      = 25,
    ["item_yasha_and_kaya"]    = 16,
    ["item_kaya"]              = 16,
    ["item_hurricane_pike"]    = 15,
    ["item_energy_booster"]    = 12,
    ["item_point_booster"]     = 11,
    ["item_staff_of_wizardry"] = 10,
    ["item_manta"]             = 10,
    ["item_ultimate_orb"]      = 10,
    ["item_robe"]              = 6,
    ["item_diadem"]            = 6,
    ["item_null_talisman"]     = 5,
    ["item_crown"]             = 4,
    ["item_mantle"]            = 3,
    ["item_magic_wand"]        = 3,
    ["item_bracer"]            = 2,
    ["item_wraith_band"]       = 2,
    ["item_circlet"]           = 2,
    ["item_branches"]          = 1,
}

local MANGO_AMP_STAT_ITEMS = CLARITY_AMP_STAT_RANK

-- `v7.9.13-pro`: Includes `item_circlet (+2 all stats)`, `item_magic_wand (+3)`, `item_crown (+4)`, `item_diadem (+6)`,
-- `item_wraith_band (+2)`, and `item_yasha_and_kaya (+16)` so safe in-lane `"INT_ONLY"` Mango pops NEVER skip `item_circlet`!
local MANGO_LOW_RISK_INT_ITEMS = {
    ["item_mystic_staff"]      = 25,
    ["item_yasha_and_kaya"]    = 16,
    ["item_kaya"]              = 16,
    ["item_energy_booster"]    = 12,
    ["item_point_booster"]     = 11,
    ["item_staff_of_wizardry"] = 10,
    ["item_robe"]              = 6,
    ["item_diadem"]            = 6,
    ["item_null_talisman"]     = 5,
    ["item_crown"]             = 4,
    ["item_mantle"]            = 3,
    ["item_magic_wand"]        = 3,
    ["item_wraith_band"]       = 2,
    ["item_circlet"]           = 2,
    ["item_branches"]          = 1,
}

-- Swap up to 3 highest-ranked stat items from active inventory (`0..5`) into free/dormant Backpack slots (`6..8`),
-- never displacing `protectedItemName` (e.g. `"item_flask"`, `"item_clarity"`, `"item_enchanted_mango"`).
-- Returns `(swapsTable, didAnySwap)` where `swapsTable = { { sSlot, bpSlot }, ... }`.
function H.SwapStatItemsToBackpack(bot, rankMap, protectedItemName, protectedHandle)
    local candidates = {}
    for sSlot = 0, 5 do
        local it = bot:GetItemInSlot(sSlot)
        if it and it ~= protectedHandle then
            local nm = it:GetName()
            local r = nm and rankMap[nm]
            if r and nm ~= protectedItemName then
                candidates[#candidates + 1] = { slot = sSlot, rank = r }
            end
        end
    end
    if #candidates == 0 then
        return {}, false
    end
    table.sort(candidates, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.slot < b.slot
    end)
    local swaps = {}
    local usedBp = {}
    for _, cand in ipairs(candidates) do
        local chosenBp = nil
        for bp = 6, 8 do
            if not usedBp[bp] and not bot:GetItemInSlot(bp) then
                chosenBp = bp
                break
            end
        end
        if not chosenBp then
            for bp = 6, 8 do
                local bpIt = bot:GetItemInSlot(bp)
                local bpNm = bpIt and bpIt:GetName() or ""
                if not usedBp[bp] and bpIt and bpNm ~= protectedItemName
                    and bpNm ~= "item_flask" and bpNm ~= "item_clarity"
                    and bpNm ~= "item_enchanted_mango" and bpNm ~= "item_tango" and bpNm ~= "item_ward_observer"
                    and not rankMap[bpNm] then
                    chosenBp = bp
                    break
                end
            end
        end
        -- `9080457787.dem` `12:15.80..12:28.80` (`tk=25474..25864`) Higher-STR Backpack Eviction Fix:
        -- If all 3 Backpack slots already contain lower-rank stat items (`e.g. item_branches`, `rank = 1`) while an
        -- active slot still holds a higher-rank stat item (`e.g. item_bracer` `rank = 5` or `item_belt_of_strength` `rank = 6`),
        -- swap `cand.slot` with the LOWEST-rank Backpack item (`bpRank < cand.rank`) so ALL 3 Backpack slots hold the TOP-3 STR items!
        if not chosenBp then
            local lowestBp, lowestRank = nil, cand.rank
            for bp = 6, 8 do
                local bpIt = bot:GetItemInSlot(bp)
                local bpNm = bpIt and bpIt:GetName() or ""
                local bpR = rankMap[bpNm]
                if not usedBp[bp] and bpIt and bpNm ~= protectedItemName and bpR and bpR < lowestRank then
                    lowestRank = bpR
                    lowestBp = bp
                end
            end
            chosenBp = lowestBp
        end
        if chosenBp then
            usedBp[chosenBp] = true
            bot:ActionImmediate_SwapItems(cand.slot, chosenBp)
            U.InvalidateInvCache()
            swaps[#swaps + 1] = { cand.slot, chosenBp }
        end
    end
    return swaps, (#swaps > 0)
end

-- Top-Level Proactive Salve Trigger & Active `modifier_flask_healing` Guard (ABOVE `RunSacredCS` & `holdSpot`!):
-- Eliminates Death #1 (`690/1034 HP` with unused `[0]Flask(1)`) & Death #2 (`614/1078 HP` idle for `12s` with `[0]Flask(1)`),
-- AND fixes `9056469656.dem` `02:03–02:18` (`tk=6668..7098`): when enemy SF has `< 75 MP` (cannot cast `Shadowraze3` at `950u`!),
-- `safeDist` drops from `1065u` to `enemyAttackRange + 185` (`685u`), letting our SF hold ground under own T1 and farm `4/4` CS!
function H.HandleProactiveAndActiveSalve(bot, s, _earlyRace)
    local enemy = s and s.enemy
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local curHp = bot:GetHealth() or 0
    local missingHp = maxHp - curHp
    local hpPct = curHp / maxHp
    local fountain = P.GetFountain(bot)
    local safeDist = 1120 -- Default clearance vs `Shadowraze3` (`950u`) + walk lead (`Demo 1` `2:47` & `4:10` Fix!)
    local enApproachSpd = 0
    if enemy and U.CanQuery(enemy) then
        enApproachSpd = U.EnemyApproachSpeed(bot, enemy)
        local enAtkR = (enemy.GetAttackRange and enemy:GetAttackRange()) or 500
        if K.EnemyManaBudget(enemy, true) < 75 or not U.EnemyHasRaze(enemy) then
            safeDist = math.max(690, enAtkR + 205 + math.min(180, enApproachSpd * 0.7))
        else
            safeDist = math.min(1290, math.max(1110, enAtkR + 240, K.EnemyMinSafeDistance(enemy, 1.0) + 95 + math.min(200, enApproachSpd * 0.85)))
        end
    end

    -- Also treat an enemy who dipped into river/highground FoW `< 4.5s` ago at `enemyLastLoc` as LIVE threat (`Demo 1` `2:45.4` Fix!)
    local fogEnemyLoc = (not (enemy and U.CanQuery(enemy)))
        and s and s.enemyAlive ~= false and s.enemyLastLoc and (s.enemyAbsentFor or 99) <= 4.5
        and s.enemyLastLoc or nil
    local effEnemyLoc = (enemy and U.CanQuery(enemy) and enemy:GetLocation()) or fogEnemyLoc
    local effEnemyDist = effEnemyLoc and GetUnitToLocationDistance(bot, effEnemyLoc) or 9999

    -- 1. Protect active Healing Salve ONLY against real Salve-breaking sources (Dota 2 7.00-7.41f rule:
    -- ONLY Hero / Tower / Player-Controlled / Roshan hits >= 20 dmg cancel `modifier_flask_healing`; lane creeps NEVER break Salve!).
    if bot:HasModifier("modifier_flask_healing") then
        local nowSalve = GameTime()
        if not State.salveBuffSeenAt or (nowSalve - State.salveBuffSeenAt) > 14.0 then
            State.salveBuffSeenAt = nowSalve
        end
        local salveElapsed = nowSalve - State.salveBuffSeenAt
        if hpPct >= 0.96 then
            State.branchTangoSwapUntil = 0
            State.salveBuffSeenAt = nil
            return false
        end
        -- `auto-20261102-0043` `7:11..7:24` + `v7.9.11` (`Belt of Strength` + `Bracer` + `Circlet` + `Iron Branch` Drop):
        -- Hold `AGI` Treads (`ManageTreads("FIGHT")`) across the Salve when safely out of threat (`>= 1220u` or enemy dead!),
        -- and keep highest-STR stat items in Backpack until `salveElapsed >= 6.85s` (`6.0s` Backpack CD unlocks right at `12.85s`!)!
        if (s and s.enemyAlive == false or effEnemyDist >= 1220) and not H.HasSalveBreakingProjectileIncoming(bot) then
            H.ManageTreads(bot, "FIGHT")
            local creepsOnBotSalve = 0
            for _, ecS in pairs((s and s.enemyCreeps) or {}) do
                if U.CanQuery(ecS) and ecS:IsAlive() and ecS.GetAttackTarget and ecS:GetAttackTarget() == bot then
                    creepsOnBotSalve = creepsOnBotSalve + 1
                end
            end
            if salveElapsed <= 5.5 and (s and s.enemyAlive == false or effEnemyDist >= 1250)
                and not (L and L._imminentCS) and creepsOnBotSalve == 0 then
                H.SwapStatItemsToBackpack(bot, SALVE_AMP_STAT_RANK, "item_flask", nil)
            end
            if salveElapsed < 6.85 then
                State.branchTangoSwapUntil = math.max(State.branchTangoSwapUntil or 0, State.salveBuffSeenAt + 6.90)
            else
                State.branchTangoSwapUntil = 0
            end
        elseif effEnemyDist < 1050 then
            State.branchTangoSwapUntil = 0
        end
        -- Never throw away a free hero kill OR late-Salve (`>= 78% HP`, `>= 480 HP`) anti-reaggro zone against a crippled enemy!
        if enemy and U.CanQuery(enemy) and enemy:IsAlive() and curHp >= 240
            and not (_earlyRace and _earlyRace.valid and _earlyRace.heCanKillSoon) then
            if U.CanOneShotEnemyHero(bot, enemy) or U.CanQuickTurnKillWithRaze(bot, enemy)
                or (curHp >= 300 and H.CanTwoHitRightClickKill(bot, enemy, s)) then
                return false
            end
            -- `v7.9.27-pro` (`auto-20261108-2026` `02:20` `574..618/670 HP` = `86..92%` vs `175..194 HP` Enemy Pulling Wave Fix!):
            -- Once Salve has already healed SF to `>= 78% HP` (`>= 480 HP`) with a `>= 280 HP` lead over a crippled (`<= 265 HP`)
            -- or `<= 1`-coil enemy contesting our wave (`dEnToAlly <= 765u`), stop retreating `1,140u` behind T1 so
            -- `HandlePressCriticallyLowEnemy` / `HandleDominantAntiReaggroZone` immediately screen & punish his aggro-pull!
            local enHpSalve = enemy:GetHealth() or 9999
            local enMpSalve = (enemy:GetMana() or 0) + U.GetMangoMana(enemy)
            if hpPct >= 0.78 and curHp >= 480 and curHp >= (enHpSalve + 280)
                and (enHpSalve <= 265 or enMpSalve < 150) then
                local dWaveSalve = (s and s.allyCreeps and LN and LN.EnemyDistToAllyWave)
                    and LN.EnemyDistToAllyWave(enemy, s.allyCreeps) or effEnemyDist
                if enHpSalve <= 235 or dWaveSalve <= 765 then
                    State.branchTangoSwapUntil = 0
                    return false
                end
            end
        end
        local needStepBack = H.HasSalveBreakingProjectileIncoming(bot)
        -- `auto-20261102-0007` `9:05..9:14` (`815..937 HP` Salving Behind Dire T1 While 2 Uncontested Creeps Died to T1 Fix!):
        -- Lane creeps NEVER break Healing Salve! Once healed to `>= 640 HP` (`>= 56% HP`), if enemy creeps are actively
        -- dying near our own `allyT1` (`<= 820u`), tighten `effSafeDist` to `985u` (`strictly outside 950u Shadowraze3`)
        -- without `+110u` hysteresis overshoot so SF farms under-tower CS safely while Salve finishes!
        local creepsUnderOwnT1 = false
        if curHp >= 640 and hpPct >= 0.56 and s and s.allyT1Alive and s.allyT1Loc then
            for _, ec in pairs(s.enemyCreeps or {}) do
                if ec and U.CanQuery(ec) and ec:IsAlive()
                    and U.DistanceBetweenLocations(ec:GetLocation(), s.allyT1Loc) <= 820 then
                    creepsUnderOwnT1 = true
                    break
                end
            end
            if not creepsUnderOwnT1 then
                for _, ec in pairs(s.enemyCreepsNearAllyT1 or {}) do
                    if ec and U.CanQuery(ec) and ec:IsAlive()
                        and U.DistanceBetweenLocations(ec:GetLocation(), s.allyT1Loc) <= 820 then
                        creepsUnderOwnT1 = true
                        break
                    end
                end
            end
        end
        local effSafeDist = creepsUnderOwnT1 and math.min(safeDist, 985) or safeDist
        local hystThreshold = (not creepsUnderOwnT1 and GameTime() < (State.salveStepBackHystUntil or -1000))
            and (effSafeDist + 110) or effSafeDist
        if effEnemyLoc and effEnemyDist < hystThreshold then
            needStepBack = true
        end
        -- Also step out of enemy creep vision (`< 540u`) while enemy mid is unseen in recent FoW (`Demo 1` `2:46.8` Fix!):
        if not (enemy and U.CanQuery(enemy)) and s and s.enemyAlive ~= false and (s.enemyAbsentFor or 0) <= 6.5 then
            for _, ec in pairs(s.enemyCreeps or {}) do
                if ec and U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) < 540 then
                    needStepBack = true
                    break
                end
            end
        end
        for _, tw in pairs((s and s.enemyTowers) or {}) do
            if tw and tw:IsAlive() and GetUnitToLocationDistance(bot, tw:GetLocation()) < 890 then
                needStepBack = true
                break
            end
        end
        if needStepBack then
            State.salveStepBackHystUntil = GameTime() + 1.05
            local behindT1 = (P.GetBehindT1 and P.GetBehindT1(bot, 520)) or (bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 320)
            local anchor = behindT1
            if effEnemyLoc then
                local rawAnchor = effEnemyLoc + (fountain - effEnemyLoc):Normalized() * (safeDist + 115)
                anchor = (P.ClampDeeperTowardFountain and P.ClampDeeperTowardFountain(bot, rawAnchor, 780)) or rawAnchor
            end
            local bLocNow = bot:GetLocation()
            local dBotFnt = U.DistanceBetweenLocations(bLocNow, fountain)
            if dBotFnt <= U.DistanceBetweenLocations(anchor, fountain) + 35 and dBotFnt > 450 then
                anchor = bLocNow + (fountain - bLocNow):Normalized() * math.min(380, dBotFnt - 420)
            end
            if dBotFnt > U.DistanceBetweenLocations(anchor, fountain) + 25 then
                H.SmartMove(bot, anchor, 40)
            end
            State.actionTaken = true
            return true
        end
        -- `v7.9.11` (`2213 @ 11:48..12:00` Off-Lane Jungle Salve Freeze & `07:40 / 08:38` Salve Creep-Block Fix!):
        --   1. NEVER freeze `2,600u` away in side-jungle (`(3094, 82)`) while `s.enemyCreepsNearAllyT1` are hitting our `allyT1`
        --      and the enemy hero is safely away (`effEnemyDist >= safeDist`)! Lane creeps NEVER break Salve!
        --   2. When safely behind/near own T1 (`s.enemyAlive == false` or `effEnemyDist >= safeDist + 240`), allow
        --      `HandleMidGameIdleCreepBlock` to body-block our outgoing wave (`07:40` & `08:38`) while Salve heals!
        if #(s and s.enemyCreeps or {}) == 0 then
            local siegeInfo = H.GetEnemyCreepCutAndT1SiegeState and H.GetEnemyCreepCutAndT1SiegeState(bot, s) or nil
            if siegeInfo and siegeInfo.valid and siegeInfo.t1UnderCreepSiege and effEnemyDist >= safeDist then
                local fntS = P.GetFountain(bot)
                local safeT1Spot = siegeInfo.allyT1Loc + (fntS - siegeInfo.allyT1Loc):Normalized() * 190
                local dSpotEn = effEnemyLoc and U.DistanceBetweenLocations(safeT1Spot, effEnemyLoc) or 9999
                if dSpotEn >= safeDist and GetUnitToLocationDistance(bot, safeT1Spot) > 360 then
                    H.SmartMove(bot, safeT1Spot, 45, true)
                    return true
                end
            end
            if (s and s.enemyAlive == false) or effEnemyDist >= safeDist + 240 then
                if H.HandleProactiveAndActiveClarity and not bot:HasModifier("modifier_clarity_potion")
                    and H.HandleProactiveAndActiveClarity(bot, s, _earlyRace) then
                    return true
                end
                if H.HandleMidGameIdleCreepBlock and H.HandleMidGameIdleCreepBlock(bot, s) then
                    return true
                end
            end
            if H.HandleProactiveAndActiveClarity and not bot:HasModifier("modifier_clarity_potion")
                and H.HandleProactiveAndActiveClarity(bot, s, _earlyRace) then
                return true
            end
            State.actionTaken = true
            return true
        end
        if H.HandleProactiveAndActiveClarity and not bot:HasModifier("modifier_clarity_potion")
            and H.HandleProactiveAndActiveClarity(bot, s, _earlyRace) then
            return true
        end
        return false
    end

    -- 2. Trigger owned Healing Salve (`missingHp >= 300` OR `hpPct <= 0.62`, slots `0..8`)
    if missingHp < 300 and hpPct > 0.62 then return false end
    if H.IsAtFountain(bot) then return false end
    -- `auto-20261102-0007` `12:09.90` (`555 HP` Bot chasing `108 HP` Human into 1-tick river FoW) Fix:
    -- Never pop Salve & abort a live kill-chase when a critically low (`<= 240 HP`) enemy dipped into FoW `< 2.8s` ago!
    if not (enemy and U.CanQuery(enemy)) and curHp >= 320 and s and s.enemyAlive ~= false
        and (s.enemyAbsentFor or 99) <= 2.8 and (s.enemyLastHp or 9999) <= 240
        and s.enemyLastLoc and GetUnitToLocationDistance(bot, s.enemyLastLoc) <= 1050 then
        return false
    end
    if enemy and U.CanQuery(enemy) and enemy:IsAlive() then
        local dEnNow = GetUnitToLocationDistance(bot, enemy:GetLocation())
        -- `W4 06:25.5` Fix: NEVER retreat to drink Salve when a 1-hit / quick-kill enemy stands within `980u`!
        if dEnNow <= 980 and curHp >= 140
            and (U.CanOneShotEnemyHero(bot, enemy) or U.CanQuickTurnKillWithRaze(bot, enemy)) then
            return false
        end
        if dEnNow <= safeDist then
            if H.CanTwoHitRightClickKill(bot, enemy, s) then return false end
            local dominatingLevel = ((bot:GetLevel() or 1) > (enemy:GetLevel() or 1))
                and curHp >= 460
                and not (_earlyRace and _earlyRace.valid and _earlyRace.heCanKillSoon)
            local winningCombat = _earlyRace and _earlyRace.valid
                and (_earlyRace.canKillNow or _earlyRace.canKillSoon
                    or (((_earlyRace.edge or 0) > 65) and curHp >= 450 and not _earlyRace.heCanKillSoon))
            if dominatingLevel or winningCombat then
                return false
            end
        end
    end
    local flaskSlot = bot:FindItemSlot("item_flask")
    if flaskSlot < 0 or flaskSlot > 8 then return false end

    local flask, castable = H.EnsureConsumableReady(bot, "item_flask")
    if (bot:GetMana() or 0) < 90 then
        H.EnsureConsumableReady(bot, "item_enchanted_mango")
    end
    -- `9080457787.dem` `06:43` & `12:15` Simultaneous Salve + Clarity Readiness:
    -- Ready `item_clarity` alongside `item_flask` so both `6.0s` Backpack swap timers run in parallel!
    if ((bot:GetMaxMana() or 300) - (bot:GetMana() or 0)) >= 135 and not bot:HasModifier("modifier_clarity_potion") then
        H.EnsureConsumableReady(bot, "item_clarity")
    end
    -- `9069188041.dem` `02:40.8-02:47.8` Death #1 Backpack-Salve Paralysis Fix:
    -- While `flask` is still on its `6.0s` Backpack swap cooldown (`not castable`) and NO `modifier_flask_healing`
    -- is active yet, if an enemy hero is wrapping/attacking within `<= 820u` (or just damaged us), DO NOT freeze or
    -- block survival/Mango/counter-Razes waiting for an unusable Salve!
    if not castable and enemy and U.CanQuery(enemy) and enemy:IsAlive() then
        local dEnThreat = GetUnitToLocationDistance(bot, enemy:GetLocation())
        local recentlyHit = bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(1.8)
        if dEnThreat <= 820 or recentlyHit then
            return false
        end
    end
    local unsafeHere = H.HasSalveBreakingProjectileIncoming(bot)
    -- `v7.9.11` (`2213 @ 08:31..08:38` Dead-Enemy `2,200u` T2 Walk Fix):
    -- When `s.enemyAlive == false`, ONLY enemy towers or live hero projectiles can break Salve — pop Salve right on the spot!
    if s and s.enemyAlive ~= false then
        if effEnemyLoc and effEnemyDist < (safeDist + 45) then
            unsafeHere = true
        end
        -- NEVER pop `Healing Salve` inside enemy lane creep vision (`< 540u`) while enemy mid is alive in recent FoW (`<= 6.5s`):
        -- enemy creeps grant shared vision directly to the unseen enemy SF right behind the wave (`Demo 1` `2:47` & `4:10` Fix!).
        if not (enemy and U.CanQuery(enemy)) and (s.enemyAbsentFor or 0) <= 6.5 then
            for _, ec in pairs(s.enemyCreeps or {}) do
                if ec and U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) < 540 then
                    unsafeHere = true
                    break
                end
            end
        end
    end
    for _, tw in pairs((s and s.enemyTowers) or {}) do
        if tw and tw:IsAlive() and GetUnitToLocationDistance(bot, tw:GetLocation()) < 890 then
            unsafeHere = true
            break
        end
    end
    if unsafeHere then
        local behindT1 = (P.GetBehindT1 and P.GetBehindT1(bot, 520)) or (bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 320)
        local anchor = behindT1
        if effEnemyLoc then
            local rawAnchor = effEnemyLoc + (fountain - effEnemyLoc):Normalized() * (safeDist + 95)
            anchor = (P.ClampDeeperTowardFountain and P.ClampDeeperTowardFountain(bot, rawAnchor, 780)) or rawAnchor
        end
        local bLocNow = bot:GetLocation()
        local dBotFnt = U.DistanceBetweenLocations(bLocNow, fountain)
        if dBotFnt <= U.DistanceBetweenLocations(anchor, fountain) + 35 and dBotFnt > 450 then
            anchor = bLocNow + (fountain - bLocNow):Normalized() * math.min(380, dBotFnt - 420)
        end
        if dBotFnt > U.DistanceBetweenLocations(anchor, fountain) + 25 then
            H.SmartMove(bot, anchor, 40)
        end
        State.actionTaken = true
        return true
    end

    -- `ShaNachnetsya` + `v7.9.11` Stat-Drop Salve Amplification (`Belt of Strength`, `Bracer`, `Circlet`, `Iron Branch`, etc.):
    -- Move highest-STR stat items into free/dormant Backpack slots BEFORE `Action_UseAbilityOnEntity(flask, bot)` and hold
    -- `State.branchTangoSwapUntil = GameTime() + 6.90` so `ManageInventorySlots` restores them at `6.90s` (`6.0s` CD finishes at `12.90s`!)
    if castable and flask and GameTime() > (State.lastSalveCastAt or -1000) + 0.25 then
        H.ManageTreads(bot, "FIGHT") -- AGI before healing so switching back to STR multiplies restored HP%
        local didSwap = false
        local safeOutOfCombat = (s and s.enemyAlive == false)
            or not (enemy and U.CanQuery(enemy) and GetUnitToLocationDistance(bot, enemy:GetLocation()) < safeDist)
        if safeOutOfCombat then
            local _, swappedAny = H.SwapStatItemsToBackpack(bot, SALVE_AMP_STAT_RANK, "item_flask", flask)
            didSwap = swappedAny
        end
        if didSwap then
            State.branchTangoSwapUntil = GameTime() + 6.90
        end
        State.salveBuffSeenAt = GameTime()
        bot:Action_UseAbilityOnEntity(flask, bot)
        State.lastSalveCastAt = GameTime()
        State.lastItemUseTime = GameTime()
        State.actionTaken = true
        return true
    end
    State.salveBuffSeenAt = nil
    -- `R2_2044` `04:21..04:26` `(1653, 1533) <-> (1450, 1334)` 1.00s Ping-Pong Fix:
    -- While an owned `item_flask` just moved out of Backpack (`flask ~= nil`, `not castable`) and no lane creeps exist,
    -- hold safely behind our T1 for the remaining Backpack unlock seconds so `holdSpot` & `EmergencyRetreat` NEVER fight!
    if flask and not castable and #(s and s.enemyCreeps or {}) == 0 then
        if H.TryInstantAdjacentTango and H.TryInstantAdjacentTango(bot, s) then
            return true
        end
        if (s and s.enemyAlive == false) or effEnemyDist >= safeDist + 240 then
            if H.HandleMidGameIdleCreepBlock and H.HandleMidGameIdleCreepBlock(bot, s) then
                return true
            end
        end
        local waitAnchor = (P.GetBehindT1 and P.GetBehindT1(bot, 420)) or bot:GetLocation()
        if U.DistanceBetweenLocations(bot:GetLocation(), fountain) > U.DistanceBetweenLocations(waitAnchor, fountain) then
            H.SmartMove(bot, waitAnchor, 45)
        end
        State.actionTaken = true
        return true
    end
    return false
end

-- Proactive & Active `modifier_clarity_potion` Outer-Raze Protector + `v7.9.11` Backpack INT Stat-Drop
-- (`Staff of Wizardry`, `Robe of the Magi`, `Iron Branch`, `Kaya`, `Null`, `Bracer`, `Circlet`):
--   * Before popping `item_clarity` and during `clarityElapsed < 18.8s` of the `25.0s` Clarity (when safely out of combat
--     and `not L._imminentCS`), swap highest-INT items into Backpack so flat `+6 MP/s` (`+150 MP`) restores a much higher
--     fraction of `MaxMP`, unlocking right at `18.8 + 6.0 = 24.8s`!
function H.HandleProactiveAndActiveClarity(bot, s, _earlyRace)
    if H.IsAtFountain(bot) or bot:IsChanneling() or bot:IsUsingAbility() then return false end
    -- `9080457787.dem` `06:43..06:56` (`+13.0s` delay) & `12:15..12:34` (`+19.1s` delay) Simultaneous Salve + Clarity Fix:
    -- `modifier_flask_healing` and `modifier_clarity_potion` are 100% independent in Dota 2 — drink BOTH concurrently!
    local salveActiveWithClarity = bot:HasModifier("modifier_flask_healing")
    local fountain = P.GetFountain(bot)
    local enemy = s and s.enemy
    local fogEnemyLoc = (not (enemy and U.CanQuery(enemy)))
        and s and s.enemyAlive ~= false and s.enemyLastLoc and (s.enemyAbsentFor or 99) <= 4.5
        and s.enemyLastLoc or nil
    local effEnemyLoc = (enemy and U.CanQuery(enemy) and enemy:GetLocation()) or fogEnemyLoc
    local effEnemyDist = effEnemyLoc and GetUnitToLocationDistance(bot, effEnemyLoc) or 9999
    local safeClarityDist = math.max(1055, (C.REGEN and C.REGEN.ENEMY_SAFE_DISTANCE) or 1055)
    local nowClarity = GameTime()

    -- 1. Active `modifier_clarity_potion` protection (`150 MP` over `25s` = `2` full coils!)
    if bot:HasModifier("modifier_clarity_potion") then
        if not State.clarityBuffSeenAt or (nowClarity - State.clarityBuffSeenAt) > 26.5 then
            State.clarityBuffSeenAt = nowClarity
        end
        local clarityElapsed = nowClarity - State.clarityBuffSeenAt
        local maxMp = math.max(1, bot:GetMaxMana() or 1)
        local mpPct = (bot:GetMana() or 0) / maxMp
        if mpPct >= 0.96 then
            if State.clarityHoldingBackpack then
                State.clarityHoldingBackpack = false
                if not State.mangoSeq then State.branchTangoSwapUntil = 0 end
            end
            State.clarityBuffSeenAt = nil
            return false
        end
        -- Never throw away a guaranteed hero kill right in front of us just to save a `50g` Clarity!
        if enemy and U.CanQuery(enemy) and enemy:IsAlive() and (bot:GetHealth() or 0) >= 260 then
            if U.CanOneShotEnemyHero(bot, enemy) or U.CanQuickTurnKillWithRaze(bot, enemy)
                or H.CanTwoHitRightClickKill(bot, enemy, s) then
                if State.clarityHoldingBackpack then
                    State.clarityHoldingBackpack = false
                    if not State.mangoSeq then State.branchTangoSwapUntil = 0 end
                end
                return false
            end
        end
        local needStepBack = H.HasSalveBreakingProjectileIncoming(bot)
        local hystDist = (nowClarity < (State.clarityStepBackHystUntil or -1000)) and (safeClarityDist + 85) or safeClarityDist
        if effEnemyLoc and effEnemyDist < hystDist then
            needStepBack = true
        end
        for _, tw in pairs((s and s.enemyTowers) or {}) do
            if tw and tw:IsAlive() and GetUnitToLocationDistance(bot, tw:GetLocation()) < 890 then
                needStepBack = true
                break
            end
        end

        -- `v7.9.11` Active Clarity Backpack INT Stat-Drop (`Staff of Wizardry`, `Robe of the Magi`, `Iron Branch`, etc.):
        -- Keep INT items in Backpack until `18.8s` (`6.0s` Backpack CD unlocks at `24.8s` of `25.0s` Clarity!) as long as
        -- SF is safely out of hero threat (`>= safeClarityDist + 75` or enemy dead) and not needing attack dmg for imminent CS!
        local safeForClarityDrop = (not needStepBack)
            and (not L._imminentCS)
            and ((s and s.enemyAlive == false) or effEnemyDist >= safeClarityDist + 75)
            and ((bot:GetHealth() / math.max(1, bot:GetMaxHealth() or 1)) >= 0.55)
            and (mpPct < 0.93)
            and (clarityElapsed < 18.8)
        if safeForClarityDrop and not salveActiveWithClarity then
            local creepsOnBotClar = 0
            for _, ecC in pairs((s and s.enemyCreeps) or {}) do
                if U.CanQuery(ecC) and ecC:IsAlive() and ecC.GetAttackTarget and ecC:GetAttackTarget() == bot then
                    creepsOnBotClar = creepsOnBotClar + 1
                end
            end
            if clarityElapsed <= 17.0 and creepsOnBotClar == 0 then
                H.SwapStatItemsToBackpack(bot, CLARITY_AMP_STAT_RANK, "item_clarity", nil)
            end
            State.clarityHoldingBackpack = true
            State.branchTangoSwapUntil = math.max(State.branchTangoSwapUntil or 0, nowClarity + 0.55)
        elseif State.clarityHoldingBackpack and not salveActiveWithClarity then
            State.clarityHoldingBackpack = false
            if not State.mangoSeq then State.branchTangoSwapUntil = 0 end
        end

        if needStepBack then
            State.clarityStepBackHystUntil = nowClarity + 0.95
            local behindT1 = (P.GetBehindT1 and P.GetBehindT1(bot, 460))
                or (bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 320)
            local anchor = behindT1
            if effEnemyLoc then
                local rawAnchor = effEnemyLoc + (fountain - effEnemyLoc):Normalized() * (safeClarityDist + 95)
                anchor = (P.ClampDeeperTowardFountain and P.ClampDeeperTowardFountain(bot, rawAnchor, 720)) or rawAnchor
            end
            H.ManageTreads(bot, "FIGHT") -- Hold AGI/STR so flat +6 MP/s restores higher % of maxMana!
            H.SmartMove(bot, anchor, 40)
            State.actionTaken = true
            return true
        end
        -- Safe (`>= 1,055u` from enemy hero): keep PT off INT for maximum % mana gain, and let `RunMainPipeline` farm safe CS!
        H.ManageTreads(bot, "FIGHT")
        return false
    elseif State.clarityHoldingBackpack then
        State.clarityHoldingBackpack = false
        State.clarityBuffSeenAt = nil
        if not State.mangoSeq and not bot:HasModifier("modifier_flask_healing") then
            State.branchTangoSwapUntil = 0
        end
    end

    -- 2. Proactive `item_clarity` activation (`missingMana >= 135`, runs concurrently with `modifier_flask_healing`!)
    if L._imminentCS then return false end
    local curMana = bot:GetMana() or 0
    local maxMana = math.max(1, bot:GetMaxMana() or 300)
    local minMissingMp = salveActiveWithClarity and 130 or 150
    if (maxMana - curMana) < minMissingMp or (curMana / maxMana) > 0.56 then return false end
    -- When already safely retreating under `modifier_flask_healing` (or `>= 1150u` from enemy), drink `item_clarity` FIRST
    -- and save any `item_enchanted_mango` for instant mid-fight burst mana!
    if U.HasItem(bot, "item_enchanted_mango") and not salveActiveWithClarity and effEnemyDist < 1150 then return false end
    local clarSlot = bot:FindItemSlot("item_clarity")
    if clarSlot < 0 or clarSlot > 8 then return false end
    local clarItem, clarReady = H.EnsureConsumableReady(bot, "item_clarity")
    if not clarReady or not clarItem then return false end
    if H.HasSalveBreakingProjectileIncoming(bot) or (effEnemyLoc and effEnemyDist < (safeClarityDist + 55)) then
        if #(s and s.enemyCreeps or {}) == 0 and effEnemyLoc then
            local rawAnchor = effEnemyLoc + (fountain - effEnemyLoc):Normalized() * (safeClarityDist + 95)
            local anchor = (P.ClampDeeperTowardFountain and P.ClampDeeperTowardFountain(bot, rawAnchor, 720)) or rawAnchor
            H.SmartMove(bot, anchor, 40)
            State.actionTaken = true
            return true
        end
        return false
    end
    H.ManageTreads(bot, "FIGHT")
    local safeClarityOutOfCombat = (not salveActiveWithClarity)
        and ((s and s.enemyAlive == false) or effEnemyDist >= safeClarityDist + 75)
        and ((bot:GetHealth() / math.max(1, bot:GetMaxHealth() or 1)) >= 0.55)
    if safeClarityOutOfCombat then
        local _, didClarSwap = H.SwapStatItemsToBackpack(bot, CLARITY_AMP_STAT_RANK, "item_clarity", clarItem)
        if didClarSwap then
            State.clarityHoldingBackpack = true
            State.branchTangoSwapUntil = math.max(State.branchTangoSwapUntil or 0, nowClarity + 0.65)
        end
    end
    State.clarityBuffSeenAt = nowClarity
    bot:Action_UseAbilityOnEntity(clarItem, bot)
    State.lastItemUseTime = nowClarity
    State.actionTaken = true
    return true
end

-- `v7.9.6` + `v7.9.11` Engine-Exact 3-Phase Multi-Tick Mango + Power Treads + Priority Stat-Item Backpack State Machine
-- (`Staff of Wizardry`, `Robe of the Magi`, `Iron Branch`, `Kaya`, `Null`, `Bracer`, `Circlet`, `Wand`, etc. sorted by `+INT`!):
--   Exact 3-Phase Multi-Tick Protocol:
--     * Phase 1 (`Tick T`): Toggle Power Treads off `INT (2) -> AGI (1)` (`1` unit order, NEVER overwritten!) AND
--       `ActionImmediate_SwapItems` highest-INT stat items to Backpack (`Staff (+10) > Robe (+6) > Bracer/Circlet (+2) > Branch (+1)`).
--     * Phase 2 (`Tick T+2`, once `GetMaxMana() < preMaxMana - 1` or `+0.066s`): Fire `Action_UseAbility(mango)` ALONE on
--       reduced `MaxMP`!
--     * Phase 3 (`Tick T+4`, once `charges < preCharges` or `+0.066s`): Swap all Backpack stat items back to exact slots!

function H.CountInventoryItemCharges(bot, itemName)
    local total = 0
    for sl = 0, 8 do
        local it = bot:GetItemInSlot(sl)
        if it and it:GetName() == itemName then
            total = total + math.max(1, (it.GetCurrentCharges and it:GetCurrentCharges()) or 1)
        end
    end
    return total
end

function H.RestoreMangoSwaps(bot, seq)
    if not seq or not seq.swaps then return end
    local swapped = false
    for i = #seq.swaps, 1, -1 do
        local pair = seq.swaps[i]
        if pair and pair[1] and pair[2] then
            bot:ActionImmediate_SwapItems(pair[1], pair[2])
            swapped = true
        end
    end
    if swapped then
        U.InvalidateInvCache()
    end
    seq.swaps = nil
end

function H.TickMangoStateMachine(bot, _s)
    local seq = State.mangoSeq
    if not seq then return false end
    local now = GameTime()
    if not bot:IsAlive() or bot:IsChanneling() or (now - (seq.startedAt or now)) > 0.65 then
        H.RestoreMangoSwaps(bot, seq)
        State.mangoSeq = nil
        State.branchTangoSwapUntil = 0
        return false
    end

    State.branchTangoSwapUntil = math.max(State.branchTangoSwapUntil or 0, now + 0.50)

    if seq.step == "WAIT_STAT_DROP" then
        -- Ensure Power Treads actually stepped off INT (`2`) before popping Mango
        local ptStat = U.GetCurrentPowerTreadsStat and U.GetCurrentPowerTreadsStat(bot) or nil
        if ptStat == ((C.TREADS and C.TREADS.INTELLIGENCE) or 2) and not bot:IsUsingAbility() then
            if U.SwitchTreadsTo(bot, (C.TREADS and C.TREADS.AGILITY) or 1, { urgent = true, hold = 0.85 }) then
                seq.prepAt = now
                State.actionTaken = true
                return true
            end
        end
        local curMaxMp = bot:GetMaxMana() or 0
        if curMaxMp >= (seq.preMaxMana or 0) - 1 and (now - (seq.prepAt or now)) < 0.066 then
            State.actionTaken = true
            return true
        end
        if bot:IsUsingAbility() then
            return false
        end
        local mangoNow = U.GetActiveItemByName(bot, "item_enchanted_mango")
        if not (mangoNow and mangoNow:IsFullyCastable()) then
            H.RestoreMangoSwaps(bot, seq)
            State.mangoSeq = nil
            State.branchTangoSwapUntil = 0
            return false
        end
        bot:Action_UseAbility(mangoNow)
        seq.castAt = now
        seq.step = "WAIT_CONSUME"
        State.lastItemUseTime = now
        State.actionTaken = true
        return true
    elseif seq.step == "WAIT_CONSUME" then
        local curCharges = H.CountInventoryItemCharges(bot, "item_enchanted_mango")
        if curCharges < (seq.preCharges or 0) or (now - (seq.castAt or now)) >= 0.066 then
            H.RestoreMangoSwaps(bot, seq)
            State.mangoSeq = nil
            State.branchTangoSwapUntil = 0
            return false
        end
        State.actionTaken = true
        return true
    end

    H.RestoreMangoSwaps(bot, seq)
    State.mangoSeq = nil
    State.branchTangoSwapUntil = 0
    return false
end

function H.StartMangoPop(bot, allowBackpackDrop, immediateEmergency)
    if State.mangoSeq then
        return H.TickMangoStateMachine(bot, nil)
    end
    local mango, castable = H.EnsureConsumableReady(bot, "item_enchanted_mango")
    if not castable or not mango then return false end
    local now = GameTime()

    -- True `< 0.03s` close-combat emergency (`< 75 MP` right next to rival): fire Mango immediately with ZERO conflicting PT order!
    if immediateEmergency then
        bot:Action_UseAbility(mango)
        State.lastItemUseTime = now
        State.branchTangoSwapUntil = 0
        State.actionTaken = true
        return true
    end

    local preMaxMana = bot:GetMaxMana() or 0
    local preCharges = H.CountInventoryItemCharges(bot, "item_enchanted_mango")
    local ptStat = U.GetCurrentPowerTreadsStat and U.GetCurrentPowerTreadsStat(bot) or nil
    local toggledPT = false
    if ptStat == ((C.TREADS and C.TREADS.INTELLIGENCE) or 2) then
        toggledPT = U.SwitchTreadsTo(bot, (C.TREADS and C.TREADS.AGILITY) or 1, { urgent = true, hold = 0.85 })
    end

    local swaps = {}
    if allowBackpackDrop then
        local rankMap = (allowBackpackDrop == "INT_ONLY") and MANGO_LOW_RISK_INT_ITEMS or MANGO_AMP_STAT_ITEMS
        swaps = H.SwapStatItemsToBackpack(bot, rankMap, "item_enchanted_mango", mango)
    end

    -- If neither PT was on INT nor any stat item swapped to Backpack, `MaxMP` will not change — pop Mango immediately!
    if not toggledPT and #swaps == 0 then
        bot:Action_UseAbility(mango)
        State.lastItemUseTime = now
        State.branchTangoSwapUntil = 0
        State.actionTaken = true
        return true
    end

    State.mangoSeq = {
        step       = "WAIT_STAT_DROP",
        startedAt  = now,
        prepAt     = now,
        preMaxMana = preMaxMana,
        preCharges = preCharges,
        swaps      = swaps,
    }
    State.branchTangoSwapUntil = math.max(State.branchTangoSwapUntil or 0, now + 0.65)
    State.actionTaken = true
    return true
end

function H.IsSafeForBackpackMangoDrop(bot, s)
    if (bot:GetHealth() / math.max(1, bot:GetMaxHealth())) < 0.62 then return false end
    if bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(2.5) then return false end
    if bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(2.5) then return false end
    local enVisible = s and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()
    local enDist = enVisible and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) or 9999
    if enVisible and enDist <= 1080 then
        return false
    end
    if s and s.enemyAlive ~= false then
        local myT1Obj = (s and s.allyT1) or (W and W.s and W.s.allyT1)
        local myT1Loc = (s and s.allyT1Loc)
            or (myT1Obj and U.CanQuery(myT1Obj) and myT1Obj:GetLocation())
            or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1)
        local fnt = P.GetFountain(bot)
        local safeT1Rad = (enVisible and enDist >= 1250) and 980 or 760
        -- `v7.9.11` Fix: Standing BEHIND `myT1Loc` toward `fountain` (`dBotFnt <= dT1Fnt`) is our own base territory
        -- and is ALWAYS safe from forward river exposure! Only reject when stepped `> safeT1Rad` forward past `myT1Loc`!
        if myT1Loc then
            local dBotFnt = U.DistanceBetweenLocations(bot:GetLocation(), fnt)
            local dT1Fnt = U.DistanceBetweenLocations(myT1Loc, fnt)
            if dBotFnt > dT1Fnt and GetUnitToLocationDistance(bot, myT1Loc) > safeT1Rad then
                return false
            end
        end
        if (not enVisible) and s.enemyLastLoc and (s.enemyAbsentFor or 99) <= 8.0
            and GetUnitToLocationDistance(bot, s.enemyLastLoc) <= 1320 then
            return false
        end
    end
    return true
end

-- Determine whether Mango can drop ALL stat items (`"FULL"`, including `Bracer`/`Circlet`),
-- pure-INT/minor items (`"INT_ONLY"` = `Staff of Wizardry`, `Robe of the Magi`, `Iron Branch`, `Kaya`, `Null`), or `false`.
function H.GetMangoDropMode(bot, s, immediateEmerg)
    if immediateEmerg then return false end
    if H.IsSafeForBackpackMangoDrop(bot, s) and #(s and s.enemyCreeps or {}) == 0 then
        return "FULL"
    end
    if L._imminentCS then return false end
    if (bot:GetHealth() / math.max(1, bot:GetMaxHealth() or 1)) < 0.48 then return false end
    if bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(2.0) then return false end
    if bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(2.0) then return false end
    local enVisible = s and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()
    local enDist = enVisible and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) or 9999
    if enVisible and enDist < 960 then return false end
    if (not enVisible) and s and s.enemyAlive ~= false and s.enemyLastLoc and (s.enemyAbsentFor or 99) <= 5.5
        and GetUnitToLocationDistance(bot, s.enemyLastLoc) < 1080 then
        return false
    end
    return "INT_ONLY"
end

function H.TryBackpackAmpMango(bot, s)
    if State.mangoSeq then
        return H.TickMangoStateMachine(bot, s)
    end
    local curManaNow = bot:GetMana() or 0
    local missManaNow = (bot:GetMaxMana() or 0) - curManaNow
    local closeEnemyDist = (s and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive())
        and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) or 9999
    local activeDualCoilPop = curManaNow < 145 and missManaNow >= 115
        and ((U.GetItemCount and U.GetItemCount(bot, "item_enchanted_mango") or 0) >= 2 or closeEnemyDist <= 950)
    if curManaNow < 90 or activeDualCoilPop then
        local immediateEmerg = (curManaNow < 75 and closeEnemyDist <= 680)
        local dropMode = H.GetMangoDropMode(bot, s, immediateEmerg)
        if H.StartMangoPop(bot, dropMode, immediateEmerg) then
            return true
        end
        if curManaNow < 90 then return false end
    end

    if missManaNow < 115 then return false end
    local idleDropMode = H.GetMangoDropMode(bot, s, false)
    if not idleDropMode then return false end
    if idleDropMode ~= "FULL" and s and #(s.enemyCreeps or {}) > 0 and missManaNow < 145 then
        return false
    end
    return H.StartMangoPop(bot, idleDropMode, false)
end

-- Opportunistic 0-tick / 1-step Tango Eat (`v7.9.1`, `9071946472.dem` `00:42–01:31` Early Tango Fix!):
-- Whenever SF has `item_tango` ready (`slot 0..5`), no `modifier_tango_heal` active, `missingHp >= 110`,
-- and is ALREADY passing within `<= 235u` of a safe own-side tree (e.g. retreating behind T1 or waiting for Salve),
-- eat that adjacent tree (`0.0s` cast point, `165u` cast range; Tango stacks cleanly with Salve in Dota 2!).
function H.TryInstantAdjacentTango(bot, s)
    if bot:HasModifier("modifier_tango_heal") or H.IsAtFountain(bot) then return false end
    -- Never cancel an active CS attack swing (`9080457787.dem` `02:04.47` `tk=7134` Safety Guard)
    if bot.GetAnimActivity and bot:GetAnimActivity() == 1504 then
        local atkTgt = bot.GetAttackTarget and bot:GetAttackTarget() or nil
        if atkTgt and U.CanQuery(atkTgt) and not (atkTgt.IsHero and atkTgt:IsHero()) and (atkTgt:GetHealth() or 999) <= 140 then
            return false
        end
    end
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local curHp = bot:GetHealth() or 0
    local missingHp = maxHp - curHp
    local hpPct = curHp / maxHp
    local minDeficit = (C.TANGO and C.TANGO.MIN_MISSING_HP) or 105
    local maxUsePct = (C.TANGO and C.TANGO.USE_HP_PCT) or 0.86
    if hpPct > maxUsePct or missingHp < minDeficit then return false end
    local tango = U.GetActiveItemByName(bot, "item_tango")
    if not tango or not tango:IsFullyCastable() then return false end
    local now = GameTime()
    if State.tangoCastAt and now < State.tangoCastAt then return false end
    local tree = H.GetStickyTangoTree(bot, s and s.enemy or nil, s and s.enemyTowers or {})
    if not tree then return false end
    local treeLoc = GetTreeLocation(tree)
    if not treeLoc then return false end
    local dist = GetUnitToLocationDistance(bot, treeLoc)
    if dist > 235 then return false end
    if dist <= 165 then
        bot:Action_UseAbilityOnTree(tango, tree)
        State.lastTriedTreeId = tree
        State.lastTriedTreeAt = now
        State.lastItemUseTime = now
        State.tangoCastAt = now + 0.45
        State.branchTangoSwapUntil = 0
        H.ClearMoveCache()
        State.actionTaken = true
        return true
    end
    H.SmartMove(bot, treeLoc, 35)
    State.actionTaken = true
    return true
end

-- `v7.9.26-pro` Exact `30 Hz` Round-Trip Zero-Missed-CS Tango Proof (`9081989180.dem` `01:25..01:45` Post-Kill Tango Fix!):
-- Proves mathematically that walking from `bLoc` to `152u` of `treeLoc`, eating `item_tango` (`0.00s` instant cast point),
-- and walking back within `atkRange` of EVERY living enemy lane creep `ec` finishes BEFORE any enemy creep can die to
-- allied creeps/tower (`0` enemy CS missed!). Unattacked low-HP creeps far away (`e.g. 66 HP` taking `0` DPS) and
-- allied denies (`plan.isDeny`) NEVER falsely block Tango!
function H.CanEatTreeWithoutMissingCS(bot, s, treeLoc)
    if not bot or not s or not treeLoc then return false end
    local bLoc = bot:GetLocation()
    if not bLoc then return false end
    local eCreeps = s.enemyCreeps or {}
    if #eCreeps == 0 then return true end

    local distToTree = U.DistanceBetweenLocations(bLoc, treeLoc)
    local myMs = math.max(280, bot:GetCurrentMovementSpeed() or 305)
    local atkR = math.max(380, (bot:GetAttackRange() or 500) - 25)
    local atkPt = bot:GetAttackPoint() or 0.50
    local walkToTree = math.max(0.0, distToTree - 152.0)
    local tToTree = (walkToTree / myMs) + 0.08
    local eatSpot = (distToTree > 152.0) and (treeLoc + (bLoc - treeLoc):Normalized() * 150.0) or bLoc
    local allyAtks = nil

    for _, ec in pairs(eCreeps) do
        if ec and U.CanQuery(ec) and ec:IsAlive() then
            local cLoc = ec:GetLocation()
            local curHp = ec:GetHealth() or 9999
            local dr = U.SFDamageRange(bot, ec)
            local dNow = U.DistanceBetweenLocations(bLoc, cLoc)
            -- If `ec` is ALREADY a 1-hit CS right inside our current reach, secure that instant CS first (`0.5s`), then eat Tango!
            if curHp <= (dr.min + 6) and dNow <= (atkR + 145) then
                return false
            end
            -- `v7.9.28-pro` (`auto-20261108-2049` `0:39` Under-Own-T1 Tango Walk Guard):
            -- Never walk `> 165u` away to a static tree while enemy creeps are dying inside our own T1's `870u` zone (`<= 360 HP`)!
            local ownT1Tg = (s and s.allyT1Alive ~= false and s.allyT1Loc) or (P and P.GetT1Tower and P.GetT1Tower(bot)) or nil
            local twReachTg = (C.BALLISTIC and C.BALLISTIC.TOWER_ATTACK_RANGE_C2C) or 870
            if tToTree > 0.35 and ownT1Tg and curHp <= 360 and U.DistanceBetweenLocations(cLoc, ownT1Tg) <= twReachTg then
                return false
            end
            local dBack = U.DistanceBetweenLocations(eatSpot, cLoc)
            local walkBack = math.max(0.0, dBack - atkR)
            local shotDist = math.min(dBack, atkR)
            local tArriveHit = tToTree + (walkBack / myMs) + atkPt + (shotDist / 1200.0) + 0.14
            allyAtks = allyAtks or U.MergeLists(s.allyCreeps, s.allyTowers)
            local ctx = U.GetTargetPredictionContext(ec, allyAtks)
            local predHp = U.PredictHPWithContext(ctx, ec, tArriveHit)
            -- Block whenever `ec` is actively losing HP and drops into/past 1-shot killable range (`<= dr.max + 18`) before our return!
            if predHp < (curHp - 1) and predHp <= math.max(dr.max + 18, dr.min + 22) then
                return false
            end
        end
    end
    return true
end

-- Wave-Safe Proactive Tango + Zero-CS-Loss Post-Kill / Lane Tango (`9080457787.dem` & `9081989180.dem` `01:12..01:45` Fix!)
function H.TryWaveSafeStaticTango(bot, s, csWaveBusy)
    if bot:HasModifier("modifier_tango_heal") or bot:HasModifier("modifier_flask_healing") then
        State.tangoCastAt = 0
        return false
    end
    -- NEVER cancel an active right-click windup (`ACT_DOTA_ATTACK = 1504`) on a low-HP lane creep (`02:04.47` `tk=7134` Fix!)
    if bot.GetAnimActivity and bot:GetAnimActivity() == 1504 then
        local atkTgt = bot.GetAttackTarget and bot:GetAttackTarget() or nil
        if atkTgt and U.CanQuery(atkTgt) and not (atkTgt.IsHero and atkTgt:IsHero()) and (atkTgt:GetHealth() or 999) <= 210 then
            return false
        end
    end
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local curHp = bot:GetHealth() or 0
    local missingHp = maxHp - curHp
    local hpPct = curHp / maxHp
    local minDeficit = (C.TANGO and C.TANGO.MIN_MISSING_HP) or 105
    local maxUsePct = (C.TANGO and C.TANGO.USE_HP_PCT) or 0.86
    if hpPct > maxUsePct or missingHp < minDeficit then return false end
    if H.IsAtFountain(bot) then return false end
    local tangoSlot = bot:FindItemSlot("item_tango")
    if tangoSlot < 0 or tangoSlot > 8 then return false end

    local now = GameTime()
    local dtime = (type(DotaTime) == "function") and DotaTime() or 0
    -- `9072220529.dem` `1:47.67` Fix: NEVER abort an active 4-creep body-block sideways into the trees for a non-urgent Tango (`> 52% HP`)!
    if hpPct > 0.52 and (now - (State.activeCreepBlockAt or -10)) <= 0.35 then
        return false
    end
    if State.tangoCastAt and now < State.tangoCastAt then
        State.actionTaken = true
        return true
    end

    local enemyLiveObj = (s and s.enemyAlive ~= false and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()) and s.enemy or nil
    local enemyDeadWindow = (s and s.enemyAlive == false) or false

    -- Static-tree Tango only (`v7.9.21`: NEVER plant `item_branches` — C++ `Action_UseAbilityOnTree` drops `CDOTA_TempTree`,
    -- so keeping `item_branches` in slots `0..5` preserves `+1 STR/AGI/INT` permanently while eating static trees cleanly!):
    local tree = H.GetStickyTangoTree(bot, enemyLiveObj, s and s.enemyTowers or {})
    if not tree then
        -- `v7.9.23` + `v7.9.31-pro` (`auto-20261109-0026` `1:03` `tk=4930..4974` `M1251` `37 HP` Tango-Walk CS Loss Fix!):
        -- NEVER walk `800u` toward `t1Back` for an out-of-horizon tree without proving `CanEatTreeWithoutMissingCS(bot, s, t1Back)`!
        local slackFallback = false
        if L and L.PeekBestPlan then
            local pFb, eFb = L.PeekBestPlan(bot, s)
            if pFb and pFb.isDeny then pFb, eFb = nil, 999 end
            slackFallback = (not pFb) or (eFb > 1.20)
        end
        if (hpPct <= 0.52 and missingHp >= 220 or (enemyDeadWindow and missingHp >= minDeficit)) and slackFallback
            and (not enemyLiveObj or GetUnitToLocationDistance(bot, enemyLiveObj:GetLocation()) > 735) then
            local t1Back = P.GetBehindT1 and P.GetBehindT1(bot, 180) or P.GetT1Close(bot)
            local waveNowFb = s and (#(s.enemyCreeps or {}) > 0) or false
            local safeCSBack = (not waveNowFb) or (hpPct <= 0.22) or (t1Back and H.CanEatTreeWithoutMissingCS(bot, s, t1Back))
            if t1Back and safeCSBack and GetUnitToLocationDistance(bot, t1Back) > 180 then
                H.SmartMove(bot, t1Back, 45)
                State.actionTaken = true
                return true
            end
        end
        return false
    end
    local treeLoc = GetTreeLocation(tree)
    if not treeLoc then return false end
    local dist = GetUnitToLocationDistance(bot, treeLoc)

    -- `v7.9.26-pro` (`9081989180.dem` `01:11..01:16` `32° NE <-> 165° SW` Tango-vs-Combat Spin Fix!):
    -- NEVER turn our back and start walking to a non-adjacent ramp tree (`dist > 215u`) while a live Enemy Hero stands
    -- within `<= 735u`! Adjacent `< 205u` trees are already eaten instantly by `TryInstantAdjacentTango`.
    if enemyLiveObj and dist > 215 and GetUnitToLocationDistance(bot, enemyLiveObj:GetLocation()) <= 735 then
        return false
    end

    local waveActive = s and (#(s.enemyCreeps or {}) > 0 or #(s.allyCreeps or {}) > 0)
    local unopposedEnemyWave = s and #(s.enemyCreeps or {}) > 0 and #(s.allyCreeps or {}) == 0
    -- `v7.9.30-pro` (`auto-20261109-0026` `2:33..2:48` 2-Creep Drag Fix!):
    -- When `#allyCreeps == 0` and enemy creeps are chasing/near us (`<= 620u`), NEVER walk off to a non-adjacent tree
    -- unless `treeLoc` lies right beside/behind `allyT1` so `allyT1` immediately strips creep aggro!
    if unopposedEnemyWave and dist > 205 then
        local nearUnoppCreep = false
        for _, ec in pairs(s.enemyCreeps or {}) do
            if ec and U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 620 then
                nearUnoppCreep = true
                break
            end
        end
        if nearUnoppCreep then
            local ownT1Tg2 = (s.allyT1Alive ~= false and s.allyT1Loc) or nil
            local fntTg2 = P.GetFountain(bot)
            local handsOffToT1 = ownT1Tg2
                and U.DistanceBetweenLocations(treeLoc, ownT1Tg2) <= 680
                and U.DistanceBetweenLocations(treeLoc, fntTg2) <= U.DistanceBetweenLocations(ownT1Tg2, fntTg2) + 140
            if not handsOffToT1 then
                return false
            end
        end
    end
    local enemyLive = (enemyLiveObj ~= nil)
    local planTg, etaTg = nil, 999
    if L and L.PeekBestPlan then
        planTg, etaTg = L.PeekBestPlan(bot, s)
        -- `v7.9.26-pro` (`01:30..01:36` Allied Deny Tango-Abort Fix): Allied denies NEVER block wounded/post-kill Tango!
        if planTg and planTg.isDeny and (enemyDeadWindow or hpPct <= 0.72 or dist <= 360) then
            planTg, etaTg = nil, 999
        end
    end
    local zeroMissedCS = H.CanEatTreeWithoutMissingCS(bot, s, treeLoc)
    -- If eating this tree right now would risk losing a dying enemy lane creep (`not zeroMissedCS`) and we aren't critical,
    -- let `RunSacredCS` secure that creep first, then eat Tango on the very next tick!
    if waveActive and (not zeroMissedCS) and hpPct > 0.22 then
        return false
    end

    local slackBetweenCS = zeroMissedCS and ((not planTg) or (etaTg > 1.15))
    local maxSafeTreeWalk = unopposedEnemyWave and (zeroMissedCS and 560 or 210)
        or (enemyDeadWindow and zeroMissedCS and 1180
            or ((slackBetweenCS and (missingHp >= 115 or hpPct <= 0.84)) and 860
                or ((not csWaveBusy and enemyLive and hpPct <= 0.86) and 520 or 280)))
    local allowedWalk = ((hpPct <= 0.68 and not unopposedEnemyWave) and math.max(980, maxSafeTreeWalk) or maxSafeTreeWalk)
    if waveActive and dist > allowedWalk then
        return false
    end
    -- `auto-20261102-0007` `3:57.40` XP Radius Guard with `+115u` Hysteresis (`1380u` start / `1495u` keep):
    if waveActive and hpPct > 0.38 and s and s.enemyCreeps then
        local minTreeToWave = 9999
        local anyWaveNear = false
        for _, ec in pairs(s.enemyCreeps) do
            if ec and U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 1650 then
                anyWaveNear = true
                local dTC = U.DistanceBetweenLocations(treeLoc, ec:GetLocation())
                if dTC < minTreeToWave then minTreeToWave = dTC end
            end
        end
        local maxXpTreeDist = (enemyDeadWindow or dist <= 380 or State.stickyTangoTree == tree) and 1495 or 1380
        if anyWaveNear and minTreeToWave > maxXpTreeDist then
            return false
        end
    end

    local tango, castable = H.EnsureConsumableReady(bot, "item_tango")
    if not tango then return false end
    if not castable then
        -- Pre-walk toward the safe ramp tree while Backpack CD counts down when no CS is active (or HP <= 55%)!
        if (not csWaveBusy and (not waveActive or hpPct <= 0.55)) and dist > 155 then
            H.SmartMove(bot, treeLoc, 40)
            State.actionTaken = true
            return true
        end
        return false
    end

    if dist <= 165 then
        if State.lastTriedTreeId == tree and State.lastTriedTreeAt and now - State.lastTriedTreeAt > 0.65 and now - State.lastTriedTreeAt < 3.0 then
            State.blacklistedTrees = State.blacklistedTrees or {}
            State.blacklistedTrees[tree] = now + 15.0
            State.tangoBadTree = tree
            State.tangoBadTreeTime = now
            State.stickyTangoTree = nil
            State.lastTriedTreeId = nil
            return false
        end
        bot:Action_UseAbilityOnTree(tango, tree)
        State.lastTriedTreeId = tree
        State.lastTriedTreeAt = now
        State.lastItemUseTime = now
        State.tangoCastAt = now + 0.55
        State.branchTangoSwapUntil = 0
        H.ClearMoveCache()
        State.actionTaken = true
        return true
    end
    if H.SmartMove(bot, treeLoc, 40) then
        State.actionTaken = true
        return true
    end
    return false
end

-- Pro 1v1 Mid Upgrade #1: Enemy CS-Windup Self-Root Punish (`~0.45s` guaranteed hit window!)
-- Whenever the rival SF swings at a lane creep (`GetAttackTarget() ~= bot`), he is locked in his attack windup:
--   * Punish with a safe centered `Shadowraze` when NOT out-razed in tier & NOT on a Raze-spike XP boundary, OR
--   * Fire an uncontested zero-aggro / cooldown-ready right-click while his attack cooldown is spent on the creep!
function H.HandleEnemyCSWindupPunish(bot, s, earlyRace, imminentCreepCS)
    if State.actionTaken or imminentCreepCS or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if GameTime() < (State.noHarassTurnbackUntil or 0) then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if not U.IsAttackingAction(enemy) then return false end
    local enTgt = enemy.GetAttackTarget and enemy:GetAttackTarget() or nil
    if not enTgt or enTgt == bot then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 1 then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or earlyRace.losingHard) then return false end

    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    if myHp < 285 or d > 915 then return false end

    local outRazed = (earlyRace and earlyRace.valid and earlyRace.outRazedTier)
        or (U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy)) or false
    local nearSpike = (earlyRace and earlyRace.valid and earlyRace.nearLevelSpike)
        or (U.IsNearLevelSpike and U.IsNearLevelSpike(bot, enemy)) or false
    local enStacks = U.GetShadowrazeDebuff(enemy) or 0
    local myStacks = U.GetShadowrazeDebuff(bot) or 0
    local enPotMana = U.GetPotentialManaForRaze(enemy)

    -- 1. Safe centered Shadowraze into enemy's self-rooted CS windup (when band reply is safe or we lead stacks / he is dry!)
    local mySustWindup = (K.MySustainedManaBudget and K.MySustainedManaBudget(bot, 6.5)) or K.MyManaBudget(bot, true)
    local singleCoilWindupTrap = (mySustWindup < 145)
        and (enPotMana >= 150)
        and ((enemy:GetHealth() or 9999) > U.GetNRazeDamage(bot, enemy, 1) + 95)
    local lastManaBehindWindup = (mySustWindup < 145)
        and (enPotMana >= 75)
        and ((enemy:GetHealth() or 9999) > myHp + 110)
        and ((enemy:GetHealth() or 9999) > U.GetNRazeDamage(bot, enemy, 1) + 95)
    if not outRazed and not nearSpike and not bot:IsSilenced() and (bot:GetMana() or 0) >= 75 and myStacks == 0 then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            if (not singleCoilWindupTrap or (label == "far" and d >= 660))
                and (not lastManaBehindWindup or (label == "far" and d >= 775)) then
                local ab = H.GetRazeAbilityByLabel(bot, label)
                if ab and U.IsRazeAbilityCastable(bot, ab) then
                    local bandSafe = K.BandSafeFromEnemy(enemy, label, 0.85) or (enPotMana < 75) or (enStacks >= 1 and myHp >= 380)
                    if bandSafe then
                        local action, aim = H.GetRazeActionType(bot, ab, enemy)
                        if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                            State.actionTaken = true
                            return true
                        end
                    end
                end
            end
        end
    end

    -- 2. Free right-click into enemy's CS windup when attack is ready and we draw 0/minimal creep aggro!
    local now = GameTime()
    local mySpa = math.max(0.65, bot:GetSecondsPerAttack() or 1.55)
    local atkReady = (now - (bot:GetLastAttackTime() or -100)) >= (mySpa * 0.88)
    local myRange = math.max(525, bot:GetAttackRange() or 525)
    if not H.IsDryVsEnemyRaze(bot, enemy) and atkReady and d <= myRange + 42 and not (earlyRace and earlyRace.valid and earlyRace.uphillPenalty) then
        local minCreepD, creepsHittingMe = 9999, 0
        for _, ec in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(ec) and ec:IsAlive() then
                local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                if dc < minCreepD then minCreepD = dc end
                if ec.GetAttackTarget and ec:GetAttackTarget() == bot then creepsHittingMe = creepsHittingMe + 1 end
            end
        end
        local zeroAggroWindow = (minCreepD > 502) or (now < (State.myCreepAggroCdUntil or 0) - 0.20 and creepsHittingMe == 0)
        if zeroAggroWindow or (creepsHittingMe == 0 and myHp >= 360 and minCreepD > 310) then
            local prevP, prevA = State.combatPolicyActive, State.heroCombatAllowed
            State.combatPolicyActive, State.heroCombatAllowed = false, true
            local ok = H.IssueHeroAttack(bot, enemy)
            State.combatPolicyActive, State.heroCombatAllowed = prevP, prevA
            if ok then
                State.lastHarassTime = now
                State.actionTaken = true
                return true
            end
        end
    end
    return false
end

-- Exact Patch 7.41f Own-Highground Detector (`z >= 112` on our side of the mid staircase, strictly before the river drop).
function H.IsOnOwnMidHighground(bot, pt)
    if not pt then return false end
    local _, myT1, _, _, enT1, _ = H.GetMidTowerGeometry(bot)
    local dMyT1 = U.DistanceBetweenLocations(pt, myT1)
    local dEnT1 = U.DistanceBetweenLocations(pt, enT1)
    if dMyT1 > 1035 or dMyT1 >= dEnT1 - 120 then
        return false
    end
    if type(GetHeightLevel) == "function" then
        local okP, hPt = pcall(GetHeightLevel, pt)
        local okT, hT1 = pcall(GetHeightLevel, myT1)
        if okP and okT and type(hPt) == "number" and type(hT1) == "number" then
            return hPt >= hT1
        end
    end
    return (pt.z or 128) >= 112
end

-- Pro Highground `25%` Uphill-Miss Harass with Strictly ZERO Enemy Creep Aggro (`v7.9.2`):
--   * Leverages our `z = 128` mid highground (`25%` enemy uphill miss + uphill vision) to right-click Enemy SF
--     WITHOUT ever pulling enemy creeps off the staircase equilibrium!
--   * Three exact engine-safe paths:
--       1. Direct Highground Strike when `minCreepDist >= 508u` OR `aggroCdPrimed` (`>= 0.50s` remaining on `3.00s` global CD).
--       2. Short Highground-Lip Step-Up (`<= 190u`, staying strictly on `IsOnOwnMidHighground(pokePt)` and `>= 505u` outside
--          enemy `Q`/`W`) to a `pokePt` where `minCreepDist(pokePt) >= 512u` OR `aggroCdPrimed`.
--       3. `>= 510u` Highground Aggro-CD Pre-Prime: when standing at `minCreepDist >= 510u` on our HG while `pokePt` is
--          `360..511u` from staircase creeps, tap 1 zero-aggro attack order to start the `3.00s` global aggro cooldown (`0` creeps
--          aggroed!), step in for `1` free uphill shot during `aggroCdPrimed`, and step back before CD expiry!
function H.HandleHighgroundZeroAggroHarass(bot, s, earlyRace, imminentCreepCS)
    if State.actionTaken or imminentCreepCS or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 1 then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or earlyRace.losingHard) then
        return false
    end

    local bLoc = bot:GetLocation()
    if not H.IsOnOwnMidHighground(bot, bLoc) then return false end

    local eLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(bLoc, eLoc)
    local myHp = bot:GetHealth() or 0
    local myRange = math.max(500, bot:GetAttackRange() or 500)

    -- Require true uphill elevation advantage (`eLoc` in river/stairs) OR safe lip posture
    local uphillAdvantage = ((bLoc.z or 128) - (eLoc.z or 0)) >= 30
    if type(GetHeightLevel) == "function" then
        local okB, hB = pcall(GetHeightLevel, bLoc)
        local okE, hE = pcall(GetHeightLevel, eLoc)
        if okB and okE and type(hB) == "number" and type(hE) == "number" then
            uphillAdvantage = uphillAdvantage or (hB > hE)
        end
    end
    local maxHgProbeDist = myRange + (uphillAdvantage and 310 or 215)
    if myHp < 280 or d > maxHgProbeDist then return false end
    if not uphillAdvantage and H.IsDryVsEnemyRaze(bot, enemy) then
        return false
    end

    local eCreepList = {}
    local seenEc = {}
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if ec and U.CanQuery(ec) and ec:IsAlive() then
            seenEc[ec] = true
            eCreepList[#eCreepList + 1] = ec
        end
    end
    if bot.GetNearbyLaneCreeps then
        for _, ec in pairs(bot:GetNearbyLaneCreeps(700, true) or {}) do
            if ec and not seenEc[ec] and U.CanQuery(ec) and ec:IsAlive() then
                seenEc[ec] = true
                eCreepList[#eCreepList + 1] = ec
            end
        end
    end

    local creepsHittingMe = 0
    local function minCreepDistAt(pt)
        local md = 9999
        for _, ec in ipairs(eCreepList) do
            local dc = U.DistanceBetweenLocations(pt, ec:GetLocation())
            if dc < md then md = dc end
        end
        return md
    end
    for _, ec in ipairs(eCreepList) do
        if ec.GetAttackTarget and ec:GetAttackTarget() == bot then
            creepsHittingMe = creepsHittingMe + 1
        end
    end
    if creepsHittingMe > 0 then return false end

    local now = GameTime()
    local minCreepNow = minCreepDistAt(bLoc)
    local cdRem = (State.myCreepAggroCdUntil or 0) - now
    local aggroCdPrimed = (cdRem >= 0.52) and (now >= (State.myCreepChaseUntil or 0))

    -- Pre-expiry lane-control guard: if our `3.00s` global aggro CD is about to expire (`< 0.45s`) while we stepped
    -- within `< 508u` of enemy creeps on our HG, step cleanly back to `>= 515u` BEFORE a 2nd auto-attack can pull aggro!
    if cdRem > -0.15 and cdRem < 0.45 and minCreepNow < 508 and State.hgSteppedInForPoke then
        State.hgSteppedInForPoke = false
        local _, myT1 = H.GetMidTowerGeometry(bot)
        local backPt = bLoc + (myT1 - bLoc):Normalized() * math.max(55, 520 - minCreepNow)
        if U.IsAttackingAction(bot) and bot:GetAttackTarget() == enemy then
            bot:Action_ClearActions(true)
        end
        H.SmartMove(bot, backPt, 24, true)
        State.actionTaken = true
        return true
    end

    if L.PeekBestPlan then
        local _, etaCs = L.PeekBestPlan(bot, s)
        if etaCs <= ((d <= myRange + 38) and 0.48 or 0.98) then
            return false
        end
    end

    local mySpa = math.max(0.65, bot:GetSecondsPerAttack() or 1.50)
    local atkReady = (now - (bot:GetLastAttackTime() or -100)) >= (mySpa * 0.88)
    local enPotMana = U.GetPotentialManaForRaze(enemy)
    local outRazed = (earlyRace and earlyRace.valid and earlyRace.outRazedTier)
        or (U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy)) or false
    local myStHG, myRemHG = U.GetShadowrazeDebuff(bot)
    local wAbHG = H.GetRazeAbilityByLabel(bot, "mid")
    local eAbHG = H.GetRazeAbilityByLabel(bot, "far")
    local myMidFarSpentHG = (not (wAbHG and U.IsRazeAbilityCastable(bot, wAbHG)))
        and (not (eAbHG and U.IsRazeAbilityCastable(bot, eAbHG)))
    -- `v7.9.9-pro` (`1814 @ 07:53.13` Fix): `Shadowraze2` reaches `450 + 274 = 724u` (NEVER `505u`, which is inside dead-center `W`!),
    -- and carrying `myStacks >= 1` while our `W`+`E` are spent makes walking `< 735u` for 1 poke auto feed a `287`-dmg 2nd-stack `W`!
    local midBandUnsafe = (enPotMana >= 75) and (K.EnemyRazeReadyIn("mid") <= 1.15)
        and (outRazed or (bot:GetMana() or 0) < 75 or ((myStHG or 0) >= 1 and (myRemHG or 0) > 1.20 and myMidFarSpentHG))
    local movingAway = K.IsEnemyMovingAway(bot, enemy)
    local strikeReach = myRange + (movingAway and 20 or 40)

    -- Path 1: Instant Highground Strike (`0` creep aggro guaranteed by `minCreepNow >= 508` OR `aggroCdPrimed`!)
    if atkReady and d <= strikeReach and (not midBandUnsafe or d >= 735) and (minCreepNow >= 508 or aggroCdPrimed) then
        local prevP, prevA = State.combatPolicyActive, State.heroCombatAllowed
        State.combatPolicyActive, State.heroCombatAllowed = false, true
        local ok = H.IssueHeroAttack(bot, enemy)
        State.combatPolicyActive, State.heroCombatAllowed = prevP, prevA
        if ok then
            State.hgSteppedInForPoke = (minCreepNow < 508)
            State.lastHarassTime = now
            State.actionTaken = true
            return true
        end
    end

    -- Path 1B (`v7.9.18` Proactive Highground Elevation-Asymmetry Right-Click Dominance):
    -- When we hold true Highground elevation (`uphillAdvantage == true`: `100%` hit vs enemy's `25%` uphill miss!)
    -- with `>= 1` allied creep nearby to absorb/drop aggro and `<= 2` non-siege enemy creeps in `500u`, punish any
    -- lowground/river enemy inside `strikeReach` even when staircase creeps sit at `330..507u`!
    if uphillAdvantage and atkReady and d <= strikeReach and (not midBandUnsafe or d >= 735)
        and (d >= 505 or enPotMana < 75) and myHp >= 340 and #(s and s.allyCreeps or {}) >= 1 then
        local creepsIn500, siegeIn500 = 0, false
        for _, ec in ipairs(eCreepList) do
            if U.DistanceBetweenLocations(bLoc, ec:GetLocation()) <= 500 then
                creepsIn500 = creepsIn500 + 1
                if (ec:GetMaxHealth() or 0) >= 800 then siegeIn500 = true end
            end
        end
        if creepsIn500 <= 2 and not siegeIn500 then
            local prevP, prevA = State.combatPolicyActive, State.heroCombatAllowed
            State.combatPolicyActive, State.heroCombatAllowed = false, true
            local ok = H.IssueHeroAttack(bot, enemy)
            State.combatPolicyActive, State.heroCombatAllowed = prevP, prevA
            if ok then
                State.hgSteppedInForPoke = true
                State.lastHarassTime = now
                State.actionTaken = true
                return true
            end
        end
    end

    -- Compute Highground-Lip `pokePt` (`<= 310u` step when `uphillAdvantage` holds on `IsOnOwnMidHighground`,
    -- `9080457787.dem` `11:26.93..11:31.27` `z=128 vs z=0..17` `@ d=660..773u` HG Advantage Fix!)
    local maxLipStepReach = myRange + (uphillAdvantage and 310 or 195)
    if atkReady and not movingAway and d > strikeReach and d <= maxLipStepReach then
        local dirToEn = (eLoc - bLoc):Normalized()
        local stepDist = math.max(24, d - (myRange + 14))
        local pokePt = Vector(bLoc.x + dirToEn.x * stepDist, bLoc.y + dirToEn.y * stepDist, bLoc.z or 128)
        local pokeDistEn = U.DistanceBetweenLocations(pokePt, eLoc)
        if H.IsOnOwnMidHighground(bot, pokePt) and (not midBandUnsafe or pokeDistEn >= 735) and (pokeDistEn >= 505 or enPotMana < 75) then
            local minCreepPoke = minCreepDistAt(pokePt)
            local creepsIn500Poke, siegeIn500Poke = 0, false
            for _, ec in ipairs(eCreepList) do
                if U.DistanceBetweenLocations(pokePt, ec:GetLocation()) <= 500 then
                    creepsIn500Poke = creepsIn500Poke + 1
                    if (ec:GetMaxHealth() or 0) >= 800 then siegeIn500Poke = true end
                end
            end
            local uphillLowCreepStepOk = uphillAdvantage and myHp >= 360
                and #(s and s.allyCreeps or {}) >= 1
                and creepsIn500Poke <= 3 and (not siegeIn500Poke) and minCreepPoke >= 250
            -- Path 2: Walk onto our Highground Lip & fire (`minCreepPoke >= 512`, `aggroCdPrimed`, OR `uphillLowCreepStepOk`!)
            if minCreepPoke >= 512 or (aggroCdPrimed and minCreepPoke >= 355) or uphillLowCreepStepOk then
                State.hgSteppedInForPoke = (minCreepPoke < 508)
                H.SmartMove(bot, pokePt, 22, true)
                State.actionTaken = true
                return true
            end
            -- Path 3: Pre-Prime `3.00s` Global Aggro CD from `minCreepNow >= 510u` (`0` creeps in `500u`!), unlocking Path 2 on next tick!
            if not aggroCdPrimed
                and now >= (State.myCreepAggroCdUntil or 0)
                and now >= (State.lastAggroPrimeAt or -100) + 3.40
                and minCreepNow >= 510
                and minCreepPoke >= 355 then
                bot:Action_AttackUnit(enemy, false)
                State.myCreepAggroCdUntil = now + 3.00
                State.myCreepChaseUntil = 0
                State.lastAggroPrimeAt = now
                State.actionTaken = true
                return true
            end
        end
    end

    return false
end

-- Pro 1v1 Mid Upgrade #2: Exact Source 2 `500u` Global Creep-Aggro Cooldown Abuse (`3.0s` zero-aggro harass window!)
--   * Phase 1 (`Prime`): Standing `>= 504u` from ALL enemy lane creeps (`0` creeps in `500u` trigger circle!), tap a 1-tick
--     attack order on `enemy` to start the `3.00s` global player aggro cooldown with ZERO creeps aggroed!
--   * Phase 2 (`Zero-Aggro Strike`): During `[now .. myCreepAggroCdUntil - 0.25]` with `0` creeps chasing us (OR whenever
--     `minCreepDist > 503u`), fire crisp uncontested right-clicks on `enemy` across the wave without drawing 1 creep hit!
-- Pro-Human `500u` Defensive Creep-Aggro Equilibrium Pull (`auto-20261102-0007`: `ShaNachnetsya = 92` pulls vs `Bot = 0`!):
-- When zoned by uphill miss penalty, low-mana disadvantage, or HP deficit while healthy enemy melee creeps (`>= 170 HP`)
-- stand within `220..490u` of us (`Dota 2 500u aggro radius`) and NO CS/deny opens within `<= 1.35s`:
--   * Tick 1: Issue 1-frame `Action_AttackUnit(enemy, true)` from safe standoff (`d >= 545u`), triggering `2.3s` creep leash
--             without walking into enemy `Q`/autos, and stamp `myCreepAggroCdUntil = now + 3.0`.
--   * Next `0.28s`: Step `210u` toward our allied ranged creep / Fountain so enemy melee creeps drag onto our highground!
function H.HandleDefensiveCreepAggroPull(bot, s, earlyRace, imminentCreepCS)
    if State.actionTaken or imminentCreepCS or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local now = GameTime()
    -- Complete active `0.42s` post-click leash drag (yielding immediately if an imminent CS/deny opens within `<= 0.60s`!)
    if now < (State.defAggroPullDragUntil or 0) and State.defAggroPullAnchor then
        local planNow, etaNow = L.PeekBestPlan(bot, s)
        if planNow and etaNow <= 0.60 then
            State.defAggroPullDragUntil = 0
            return false
        end
        H.SmartMove(bot, State.defAggroPullAnchor, 28)
        State.actionTaken = true
        return true
    end

    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if H.IsHeroWindupNow(bot, enemy) then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    -- `v7.9.25-pro` (`auto-20261108-1609` Dire-Side Staircase Asymmetry Fix!):
    -- Dire Mid T1 `(524, 652)` sits only `693u` from Dire's staircase lip `(120, 88)` (vs `903u` on Radiant!), so the old
    -- `H.IsNearOwnT1(bot, 780)` permanently disabled defensive/counter aggro-pulls on Dire Highground! Only block inside
    -- `515u` of `ownT1` or when `>= 2` enemy creeps are already under our T1 (`<= 660u`).
    if danger >= 1 or H.IsNearOwnT1(bot, 515) then return false end
    if s.allyT1Alive ~= false and s.allyT1Loc then
        local underMyT1 = 0
        for _, ecT1 in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(ecT1) and ecT1:IsAlive() and U.DistanceBetweenLocations(ecT1:GetLocation(), s.allyT1Loc) <= 660 then
                underMyT1 = underMyT1 + 1
            end
        end
        if underMyT1 >= 2 then return false end
    end
    -- Only block on true immediate lethal danger (`InCriticalLethalDanger`), NEVER `InLosingHeroTrade`
    -- (being down HP/MP or on lowground is the EXACT reason we 1-tick pull creep aggro & drag back `255u` instead of brawling!)
    if H.InCriticalLethalDanger(bot, s, earlyRace) then return false end
    if (State.forcedRetreatLoc ~= nil and now < (State.forcedRetreatUntil or 0))
        or now < (State.fleeUntil or 0) or now < (State.critDangerHystUntil or 0) then
        return false
    end
    if earlyRace and earlyRace.valid and (earlyRace.canKillNow or earlyRace.canKillSoon or earlyRace.heCanKillNow) then
        return false
    end
    -- Match Dota 2's `3.00s` `CDOTA_BaseNPC_Creep` hero-aggro cooldown (`3.15s` instead of `5.5s`!)
    if now < (State.myCreepAggroCdUntil or 0) or now < (State.lastDefAggroPullAt or -100) + 3.15 then
        return false
    end

    local eLoc = enemy:GetLocation()
    local d = GetUnitToLocationDistance(bot, eLoc)
    local myHp = bot:GetHealth() or 0
    -- Safe standoff `[485..1450u]` (`outside Q200 474u hull`): Dota 2 hero-attack order triggers `500u` creep aggro instantly
    -- at GLOBAL distance in `1` tick (`0.033s`, `0` self-root!), followed by immediate `255u` drag toward our ramp!
    if myHp < 235 or d < 485 or d > 1450 then return false end
    if K and K.EnemyBurstVs and myHp <= (K.EnemyBurstVs(bot, enemy, math.min(d, 580), 0.75, false) + 55) then
        return false
    end

    local wantEquilibriumPull = (U.NeedsLowgroundEquilibriumPull and U.NeedsLowgroundEquilibriumPull(bot, s, earlyRace))
        or (earlyRace and earlyRace.valid and earlyRace.uphillPenalty)
        or H.IsDryVsEnemyRaze(bot, enemy)
    if not wantEquilibriumPull then return false end

    -- Protect any imminent enemy CS or 1-shot allied deny within `<= 0.72s` (`~21` ticks)!
    local planSoon, etaSoon = L.PeekBestPlan(bot, s)
    if planSoon and etaSoon <= 0.72 then return false end

    local myAtkPull = math.max(55, bot:GetAttackDamage() or 55)
    local pullableMelee = 0
    local creepsAlreadyOnMe = 0
    local nearestStepMelee, minStepMeleeDist = nil, 9999
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(ec) and ec:IsAlive() then
            if ec.GetAttackTarget and ec:GetAttackTarget() == bot then
                creepsAlreadyOnMe = creepsAlreadyOnMe + 1
            end
            local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
            if dc <= 620 and (ec:GetHealth() or 999) <= (myAtkPull * 1.48) then
                return false
            end
            local ecRange = (ec.GetAttackRange and ec:GetAttackRange()) or 100
            if ecRange <= 180 and (ec:GetHealth() or 0) >= 180 then
                if dc >= 195 and dc <= 492 then
                    pullableMelee = pullableMelee + 1
                elseif dc > 492 and dc <= 725 and dc < minStepMeleeDist then
                    minStepMeleeDist = dc
                    nearestStepMelee = ec
                end
            end
        end
    end
    for _, ac in pairs((s and s.allyCreeps) or {}) do
        if ac and U.CanQuery(ac) and ac:IsAlive() and GetUnitToLocationDistance(bot, ac:GetLocation()) <= 600 then
            if (ac:GetHealth() or 999) <= (myAtkPull + 12) then
                return false
            end
        end
    end
    if creepsAlreadyOnMe > 0 then return false end

    local bLoc = bot:GetLocation()
    -- `v7.9.23` (`auto-20261108-0512` `01:00–01:32` River vs Radiant-HG `minEC = 548..689u` Step-In Fix!):
    -- When enemy melee creeps are frozen on enemy Highground/ramp `493..725u` away (`just outside Dota 2's 500u aggro radius`),
    -- step cleanly to `462u` of the nearest healthy enemy melee creep (staying `>= 540u` outside Enemy SF & `>= 900u` outside
    -- Enemy T1) so the very tick we cross `<= 492u` we trigger `Action_AttackUnit(enemy)` and drag the wave down into the river!
    if pullableMelee == 0 then
        if not nearestStepMelee then return false end
        local mcLoc = nearestStepMelee:GetLocation()
        local toBot = (bLoc - mcLoc):Normalized()
        local stepInPt = mcLoc + toBot * 462
        local minSafeHeroStep = H.IsDryVsEnemyRaze(bot, enemy) and 560 or 535
        if U.DistanceBetweenLocations(stepInPt, eLoc) < minSafeHeroStep then
            return false
        end
        if s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(stepInPt, s.enemyT1Loc) < 900 then
            return false
        end
        if type(IsLocationPassable) == "function" and not IsLocationPassable(stepInPt) then
            return false
        end
        H.SmartMove(bot, stepInPt, 24)
        State.actionTaken = true
        return true
    end

    -- `0.42s` / `255u` leash drag toward our allied ranged creep / Fountain so enemy melee creeps walk down off enemy HG!
    local fnt = P.GetFountain(bot)
    local pullTarget = bLoc + (fnt - bLoc):Normalized() * 255
    for _, ac in pairs((s and s.allyCreeps) or {}) do
        if ac and U.CanQuery(ac) and ac:IsAlive() and ((ac:GetAttackRange() or 100) > 300) then
            local acLoc = ac:GetLocation()
            if U.DistanceBetweenLocations(acLoc, fnt) < U.DistanceBetweenLocations(bLoc, fnt) + 80
                and U.DistanceBetweenLocations(bLoc, acLoc) <= 460 then
                pullTarget = acLoc + (fnt - acLoc):Normalized() * 95
                break
            end
        end
    end

    bot:Action_AttackUnit(enemy, true)
    State.myCreepAggroCdUntil = now + 3.00
    State.myCreepChaseUntil = now + 2.30
    State.lastDefAggroPullAt = now
    State.defAggroPullAnchor = pullTarget
    State.defAggroPullDragUntil = now + 0.42
    State.actionTaken = true
    return true
end

function H.HandleProAggroTrickHarass(bot, s, earlyRace, imminentCreepCS)
    if State.actionTaken or imminentCreepCS or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if H.IsDryVsEnemyRaze(bot, enemy) then return false end
    local danger = LN.TowerDanger(bot, s.enemyT1, s.allyCreeps, nil)
    if danger >= 1 then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or earlyRace.losingHard or earlyRace.uphillPenalty) then
        return false
    end

    local now = GameTime()
    local d = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    local myRange = math.max(525, bot:GetAttackRange() or 525)
    if myHp < 285 or d > 980 then return false end

    local minCreepDist = 9999
    local creepsHittingMe = 0
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(ec) and ec:IsAlive() then
            local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
            if dc < minCreepDist then minCreepDist = dc end
            if ec.GetAttackTarget and ec:GetAttackTarget() == bot then
                creepsHittingMe = creepsHittingMe + 1
            end
        end
    end
    if creepsHittingMe > 0 then return false end

    local mySpa = math.max(0.65, bot:GetSecondsPerAttack() or 1.55)
    local atkReady = (now - (bot:GetLastAttackTime() or -100)) >= (mySpa * 0.90)
    local aggroCdPrimed = (now < (State.myCreepAggroCdUntil or 0) - 0.25) and (now >= (State.myCreepChaseUntil or 0))
    local outRazed = (earlyRace and earlyRace.valid and earlyRace.outRazedTier)
        or (U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy)) or false
    local myStPA, myRemPA = U.GetShadowrazeDebuff(bot)
    local wAbPA = H.GetRazeAbilityByLabel(bot, "mid")
    local eAbPA = H.GetRazeAbilityByLabel(bot, "far")
    local myMidFarSpentPA = (not (wAbPA and U.IsRazeAbilityCastable(bot, wAbPA)))
        and (not (eAbPA and U.IsRazeAbilityCastable(bot, eAbPA)))
    local midBandDangerous = (U.GetPotentialManaForRaze(enemy) >= 75) and (K.EnemyRazeReadyIn("mid") <= 1.15)
        and (outRazed or ((myStPA or 0) >= 1 and (myRemPA or 0) > 1.20 and myMidFarSpentPA))
    local movingAway = K.IsEnemyMovingAway(bot, enemy)
    local strikeReach = myRange + (movingAway and 20 or 42)

    -- Phase 2: Strike cleanly with ZERO creep aggro when in hull-to-hull range (`aggroCdPrimed` OR `minCreepDist >= 504`)!
    if atkReady and d <= strikeReach and not midBandDangerous and (aggroCdPrimed or minCreepDist >= 504) then
        local prevP, prevA = State.combatPolicyActive, State.heroCombatAllowed
        State.combatPolicyActive, State.heroCombatAllowed = false, true
        local ok = H.IssueHeroAttack(bot, enemy)
        State.combatPolicyActive, State.heroCombatAllowed = prevP, prevA
        if ok then
            State.lastHarassTime = now
            State.actionTaken = true
            return true
        end
    end

    -- Phase 1: ONLY prime the `3.00s` global aggro cooldown when we are ALREADY actively closing into range (`d <= 635`
    -- and enemy is NOT walking away), preventing out-of-range attack-then-cancel stutters (`00:56–01:03` Fix)!
    if not aggroCdPrimed and now >= (State.myCreepAggroCdUntil or 0)
        and now >= (State.lastAggroPrimeAt or -100) + 4.50
        and not movingAway
        and (U.IsLaneDominant and U.IsLaneDominant(bot, s, earlyRace))
        and minCreepDist >= 506 and minCreepDist <= 680
        and d > strikeReach and d <= 625
        and atkReady and not midBandDangerous then
        bot:Action_AttackUnit(enemy, false)
        State.myCreepAggroCdUntil = now + 3.00
        State.myCreepChaseUntil = 0
        State.lastAggroPrimeAt = now
        State.actionTaken = true
        return true
    end
    return false
end

-- ============================================================================
-- UNIFIED WAR DIRECTOR BRIDGE (`v6.6.0`: Single-Authority, Zero-Jitter Scoped)
-- ============================================================================
function H._PrepareWarDirector(bot, s)
    if not WD.CFG.ENABLED then return nil, nil end
    local enemy = s and s.enemy
    local now = GameTime()
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then
        if WD.State.last then WD.Reset() end
        return nil, nil
    end
    local eDist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if eDist > WD.CFG.MAX_DIST then
        WD.Reset()
        return nil, nil
    end

    if State._warPreparedAt == now and State._warDec and State._warExec then
        return State._warDec, State._warExec
    end

    -- 1-Tick Micro-Memoization (`v7.9.31-pro` Zero-Lag State-Change-Invalidated Planner Cache):
    -- `WD.Decide` solves a 2.2s tactical horizon. When neither hero is casting (`K.EnemyPhase() == nil`),
    -- `dec.mode` is non-lethal (`~= KILL / PUNISH`), HP/MP changed `<= 3`, and relative separation shifted `<= 12u`
    -- within `0.045s` (`1` frame), refresh live coordinates on `State._warExec.state` and reuse `dec` (`0 ms` lag on any event!).
    if State._warDec and State._warExec and State._warExec.state
        and (now - (State._warFullAt or -10)) <= 0.045
        and State._warDec.mode ~= "KILL" and State._warDec.mode ~= "PUNISH"
        and K.EnemyPhase() == nil
        and not (bot.IsInAbilityPhase and bot:IsInAbilityPhase())
        and math.abs((bot:GetHealth() or 0) - (State._warPrevMyHp or -999)) <= 3
        and math.abs((enemy:GetHealth() or 0) - (State._warPrevEnHp or -999)) <= 3
        and math.abs((bot:GetMana() or 0) - (State._warPrevMyMp or -999)) <= 3
        and math.abs(eDist - (State._warPrevDist or -999)) <= 12 then
        local bLocNow, eLocNow = bot:GetLocation(), enemy:GetLocation()
        local stCached = State._warExec.state
        if bLocNow and stCached.me then stCached.me.x, stCached.me.y = bLocNow.x, bLocNow.y end
        if eLocNow and stCached.him then stCached.him.x, stCached.him.y = eLocNow.x, eLocNow.y end
        stCached.dist = eDist
        State._warExec.now = now
        State._warPreparedAt = now
        return State._warDec, State._warExec
    end

    local myRaze = bot:GetAbilityByName("nevermore_shadowraze1")
    local hisRaze = enemy:GetAbilityByName("nevermore_shadowraze1")
    local myReady = State._warMyReady or {}
    local hisReady = State._warHisReady or {}
    State._warMyReady, State._warHisReady = myReady, hisReady

    local razeNames = { "nevermore_shadowraze1", "nevermore_shadowraze2", "nevermore_shadowraze3" }
    for i = 1, 3 do
        local ab = bot:GetAbilityByName(razeNames[i])
        myReady[i] = now + ((ab and ab:GetCooldownTimeRemaining()) or 999)
    end
    local labels = { "near", "mid", "far" }
    for i = 1, 3 do
        local cd = K.EnemyRazeReadyIn(labels[i]) or 0
        hisReady[i] = now + math.max(0, cd)
    end

    local ownT1Handle = (s and s.allyT1) or P.GetT1Tower(bot)
    if ownT1Handle and U.CanQuery(ownT1Handle) then
        State._warOwnT1Loc = ownT1Handle:GetLocation()
    elseif not State._warOwnT1Loc then
        local t = P.GetT1Tower(bot)
        if t then State._warOwnT1Loc = t:GetLocation() end
    end

    local e = State._warEnv or {}
    State._warEnv = e
    e.now = now
    e.myDamageVsHim = K.AttackDamageVs(bot, enemy)
    e.enemyDamageVsMe = K.AttackDamageVs(enemy, bot)
    e.mySouls = S.GetSouls(bot)
    e.hisSouls = S.GetSouls(enemy)
    e.myRazeLevel = (myRaze and myRaze:GetLevel()) or 0
    e.hisRazeLevel = math.max((hisRaze and hisRaze:GetLevel()) or 0, (U.InferRazeLevel and U.InferRazeLevel(enemy)) or 0)
    local myTal10 = bot:GetAbilityByName("special_bonus_unique_nevermore_7")
    local hisTal10 = enemy:GetAbilityByName("special_bonus_unique_nevermore_7")
    e.myStackTalent = (myTal10 and myTal10:GetLevel() > 0) and 30 or 0
    e.hisStackTalent = (hisTal10 and hisTal10:GetLevel() > 0) and 30 or 0
    e.myRazeStacksOnMe = (U.GetShadowrazeDebuff and U.GetShadowrazeDebuff(bot)) or 0
    e.hisRazeStacksOnHim = (U.GetShadowrazeDebuff and U.GetShadowrazeDebuff(enemy)) or 0
    e.myRazeReady = myReady
    e.hisRazeReady = hisReady
    e.myRegen = (bot.GetHealthRegen and bot:GetHealthRegen()) or 1.5
    e.myManaRegen = (bot.GetManaRegen and bot:GetManaRegen()) or 1.0
    e.myStickCharges = U.GetStickCharges(bot) or 0
    e.hisStickCharges = U.GetStickCharges(enemy) or 0
    local myMangoes = U.GetMangoCharges(bot) or 0
    local hisMangoes = U.GetMangoCharges(enemy) or 0
    e.myMango = myMangoes > 0
    e.hisMango = hisMangoes > 0
    e.myMangoCharges = myMangoes
    e.hisMangoCharges = hisMangoes
    if U.GetUnlockingMangoMana then
        e.myUnlockingMangoMana, e.myUnlockEta = U.GetUnlockingMangoMana(bot, 3.0)
        e.hisUnlockingMangoMana, e.hisUnlockEta = U.GetUnlockingMangoMana(enemy, 3.0)
    end
    if U.GetIncomingCourierSupply then
        local myCS = U.GetIncomingCourierSupply(bot)
        e.myCourierMangoMana = myCS.mangoMana or 0
        e.myCourierFaerieHeal = myCS.faerieHeal or 0
        e.myCourierEta = myCS.etaSec or 999
    end
    if U.GetEnemyIncomingCourierSupply then
        local hisCS = U.GetEnemyIncomingCourierSupply(bot, enemy)
        e.hisCourierMangoMana = hisCS.mangoMana or 0
        e.hisCourierFaerieHeal = hisCS.faerieHeal or 0
        e.hisCourierEta = hisCS.etaSec or 999
    end
    e.myMagicResist = (U.GetEffectiveMagicResist and U.GetEffectiveMagicResist(bot)) or 0.25
    e.hisMagicResist = (U.GetEffectiveMagicResist and U.GetEffectiveMagicResist(enemy)) or 0.25
    e.mySpellAmp = (U.GetSpellAmpMult and U.GetSpellAmpMult(bot)) or 1.0
    e.hisSpellAmp = (U.GetSpellAmpMult and U.GetSpellAmpMult(enemy)) or 1.0
    e.myMagicBlock = (U.GetMagicBlockOnFirstRaze and U.GetMagicBlockOnFirstRaze(bot, 200)) or 0
    e.hisMagicBlock = (U.GetMagicBlockOnFirstRaze and U.GetMagicBlockOnFirstRaze(enemy, 200)) or 0
    e.myFaerie = U.GetActiveItemByName(bot, "item_faerie_fire") ~= nil
    e.hisFaerie = U.HasItem and U.HasItem(enemy, "item_faerie_fire") or false
    e.enemyT1Loc = (s.enemyT1Alive and s.enemyT1Loc) or nil
    e.enemyT1Alive = s.enemyT1Alive ~= false
    e.ownT1Loc = State._warOwnT1Loc
    e.enemyT1 = (s.enemyT1Alive ~= false and s.enemyT1) or nil
    e.ownT1 = ownT1Handle
    e.myAggroCdUntil = State.myCreepAggroCdUntil or 0
    local enHidden = (U.GetEnemyHiddenMaxHp and U.GetEnemyHiddenMaxHp(enemy)) or 0
    e.hisTrueMaxHp = (enemy:GetMaxHealth() or 1) + enHidden
    e.hisEffectiveCombatHp = (U.GetEnemyEffectiveCombatHp and U.GetEnemyEffectiveCombatHp(enemy, 2.5)) or (enemy:GetHealth() or 1)
    local rawSafeAnchor = (P.GetRetreatAnchor and P.GetRetreatAnchor(bot, 260, 320))
        or (P.GetBehindT1 and P.GetBehindT1(bot, 260))
        or State._warOwnT1Loc
    e.safeAnchorLoc = rawSafeAnchor and H.ComputeCutOffSafeRetreatTarget(bot, enemy, rawSafeAnchor, 440) or nil

    if not State._warCalibrated and e.enemyT1 then
        State._warCalibrated = true
        pcall(ET.CalibrateConstants, C, bot, { e.enemyT1 })
    end

    local towerShot = ET.FALLBACK.TOWER_APPLIED_DMG
    local towerLockedOnMe = false
    if e.enemyT1 then
        towerShot = ET.AppliedTowerDamage(e.enemyT1, bot)
        local tf = ET.TowerFacts(bot, e.enemyT1, 2, 1, C.TOWER and C.TOWER.HERO_AGGRO_RANGE)
        towerLockedOnMe = (tf and tf.targeting_me) or false
    end
    e.projectileDamage = function(p)
        if p and p.caster and p.caster.IsTower then
            local okTw, isTw = pcall(p.caster.IsTower, p.caster)
            if okTw and isTw then return towerShot end
        end
        if towerLockedOnMe then return math.max(towerShot, e.enemyDamageVsMe or 0) end
        return e.enemyDamageVsMe or 0
    end

    local phLabel, _phEl, phRemain = K.EnemyPhase()
    if phLabel then
        e.hisCastLeft = math.max(0, phRemain or 0)
        e.hisCastBand = nil
        for i = 1, 3 do
            if K.LABELS[i] == phLabel then e.hisCastBand = i; break end
        end
        e.hisCastCentre = (K.EnemyThreatRazeCenter and K.EnemyThreatRazeCenter(bot, enemy, phLabel))
            or K.EnemyRazeCenter(enemy, phLabel)
    else
        e.hisCastLeft = nil
        e.hisCastBand = nil
        e.hisCastCentre = nil
    end

    local st = WD.BuildState(bot, s, e)
    local dec = WD.Decide(st, now)
    if not dec then return nil, nil end

    local exec = {
        state = st,
        now = now,
        imminentCS = false,
        moveTo = function(loc, urgentDodge)
            if not loc then return false end
            local bz = (bot:GetLocation() and bot:GetLocation().z) or 128
            local safe = H.GetSafeApproach(bot, Vector(loc.x, loc.y, bz), s.enemyTowers, s.allyCreeps)
            return H.SmartMove(bot, safe, urgentDodge and 20 or 60, urgentDodge == true)
        end,
        approach = function(enemyHero)
            local loc = H.GetSafeApproach(bot, enemyHero:GetLocation(), s.enemyTowers, s.allyCreeps)
            return H.ApproachEnemyPoint(bot, enemyHero, loc, 60, s.enemyTowers, s.allyCreeps)
        end,
        attackHero = function()
            return H.IssueHeroAttack(bot, enemy)
        end,
        canSnapRaze = function(_bot, idx, target)
            local nm = razeNames[idx]
            local ab = nm and bot:GetAbilityByName(nm) or nil
            if not ab or ab:GetLevel() <= 0 or not ab:IsCooldownReady() then return false end
            if bot:GetMana() < 75 then return false end
            local actionType = H.GetRazeActionType(bot, ab, target)
            return actionType == "CAST"
        end,
        castRaze = function(_bot, idx, _aimLoc, target, allowMango)
            local nm = razeNames[idx]
            local ab = nm and bot:GetAbilityByName(nm) or nil
            if not ab or ab:GetLevel() <= 0 or not ab:IsCooldownReady() then return false end
            if bot:GetMana() < 75 then
                -- `v7.9.31-pro`: Only pop starting Mangoes in WarDirector when `allowMango ~= false` (lethal / `2+` stack / answer)!
                if allowMango ~= false and (U.GetMangoCharges(bot) or 0) > 0 then
                    local mg = U.GetActiveItemByName(bot, "item_enchanted_mango")
                    if mg and mg:IsFullyCastable() then
                        bot:Action_UseAbility(mg)
                        State.actionTaken = true
                        return true
                    end
                end
                return false
            end
            local actionType, aim = H.GetRazeActionType(bot, ab, target)
            if not actionType then return false end
            return H.CastOrTurnRaze(bot, ab, actionType, aim, target)
        end,
    }
    State._warPreparedAt = now
    State._warFullAt = now
    State._warPrevMyHp = bot:GetHealth() or 0
    State._warPrevEnHp = enemy:GetHealth() or 0
    State._warPrevMyMp = bot:GetMana() or 0
    State._warPrevDist = eDist
    State._warDec = dec
    State._warExec = exec
    return dec, exec
end

local function runWarDirectorPreCS(bot, s)
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    -- Exact Pre-CS Fast-Path (`v7.9.31-pro` Zero-Behavior-Change Optimization!):
    -- `WD.ExecuteKillOrCastLockOnly` ONLY acts when Enemy is actively mid-Raze-cast (`K.EnemyPhase() ~= nil`) OR inside
    -- `dec.mode == "KILL"` affordable burst (`<= 2` coils at `d > 480u`, `<= 3` coils at `d <= 480u`, plus `2.2x Auto + 30`).
    local phLabel = K.EnemyPhase()
    if not phLabel then
        local eDistPre = GetUnitToLocationDistance(bot, enemy:GetLocation())
        local maxGeomCoils = (eDistPre > 485) and 2 or 3
        local affCoils = math.min(maxGeomCoils, K.MyReadyRazeCount(bot, true))
        local razeCeil = (affCoils > 0) and U.GetNRazeDamage(bot, enemy, affCoils) or 0
        local maxKillCeiling = razeCeil + (K.AttackDamageVs(bot, enemy) * 2.25) + 35
        if (enemy:GetHealth() or 9999) > maxKillCeiling then
            return false
        end
    end
    local dec, exec = H._PrepareWarDirector(bot, s)
    if not dec or not exec then return false end
    return WD.ExecuteKillOrCastLockOnly(bot, s, dec, exec)
end

function H.WarDirectorPreCS(bot, s)
    local okRun, res = pcall(runWarDirectorPreCS, bot, s)
    return okRun and res == true
end

local function runWarDirectorPostCS(bot, s, imminentCreepCS)
    local dec, exec = H._PrepareWarDirector(bot, s)
    if not dec or not exec then return false end
    exec.imminentCS = imminentCreepCS and true or false
    return WD.ExecuteTactical(bot, s, dec, exec)
end

function H.WarDirectorPostCS(bot, s, imminentCreepCS)
    local okRun, res = pcall(runWarDirectorPostCS, bot, s, imminentCreepCS)
    return okRun and res == true
end

-- `auto-20261031-0230` `01:32.3-01:35.0` (`tk=6900..6980`) `102 HP / 4 MP` Enemy Escape Fix:
-- When the enemy hero is critically low (`<= 160 HP` or `<= 1 Raze + 45`) and retreating past `960u` (`WarDirector` hunt edge)
-- while we are healthy (`>= 380 HP`), `#enemyCreeps <= 1`, and NO CS is imminent, press smoothly up to the safe enemy T1
-- boundary (`>= 915u`, or `>= 660u` if `>= 2` allied creeps actively shield T1) instead of snapping NE back to `(-33,-26)`!
function H.HandlePressCriticallyLowEnemy(bot, s, earlyRace, imminentCreepCS)
    if State.actionTaken then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if H.TowerBurnActive() or (GameTime() < (State.noReenterEnemyT1Until or 0)) then return false end
    local myHp = bot:GetHealth() or 0
    local myEffHp = myHp
        + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(bot)) or 0)
        + ((U.GetStickCharges and U.GetStickCharges(bot)) or 0) * 15
    local inFlightPress = (U.GetOwnInFlightDamageOnHero and U.GetOwnInFlightDamageOnHero(bot, enemy)) or 0
    local enRawHp = math.max(1, (enemy:GetHealth() or 9999) - inFlightPress)
    local enHp = enRawHp + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(enemy)) or 0)
    local enPoolNow = (enemy:GetMana() or 0) + U.GetMangoMana(enemy)
    local enDryZeroCoil = enPoolNow < 75
    local myAtk = K.AttackDamageVs(bot, enemy)
    local enAtk = K.AttackDamageVs(enemy, bot)
    -- `9070869385.dem` `01:10.2` (`339 HP + Faerie = 424 EHP` vs `89 HP / 32 MP`), `02:01.4` (`154 HP` vs `82 HP / 61 MP`),
    -- and `04:04.2–04:06.2` (`75 -> 13 HP` execution) + `v7.9.27-pro` (`02:23..02:26.5` `90..97 HP` In-Flight & 2-Hit Chase) Fix:
    -- Never let a rigid `360 HP` floor or a non-1-hit creep block finishing a 1-2 hit / zero-coil enemy!
    local ultraCriticalTarget = (enHp <= math.max(115, myAtk * 1.98))
    if imminentCreepCS and not ultraCriticalTarget then return false end
    local minReqEffHp = (enDryZeroCoil and enHp <= 185) and math.max(145, enAtk * 2.55) or 340
    if enDryZeroCoil and (bot:GetMana() or 0) >= 75 and enRawHp <= 265 then
        minReqEffHp = math.min(minReqEffHp, 260)
    end
    if myEffHp < minReqEffHp then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillNow or (earlyRace.heCanKillSoon and not ultraCriticalTarget)) then return false end
    local oneRazeDmg = U.GetNRazeDamage(bot, enemy, 1)
    local bLocChk = bot:GetLocation()
    local eLocChk = enemy:GetLocation()
    local dChk = U.DistanceBetweenLocations(bLocChk, eLocChk)
    local atkReachChk = (bot:GetAttackRange() or 525) + 25
    local maxEnCoils = math.max(0, math.min(3, math.floor(enPoolNow / 75)))
    local enRealMaxBurst = (maxEnCoils > 0) and K.EnemyRazeDamage(bot, enemy, math.min(2, maxEnCoils)) or 0
    local localEnCreepsNear = 0
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if ec and U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(bLocChk, ec:GetLocation()) <= 640 then
            localEnCreepsNear = localEnCreepsNear + 1
        end
    end
    -- `v7.9.26-pro` (`9081989180.dem` `01:14..01:18` `475 HP` Dire HG SF vs `168..190 HP` Lowground SF Inside `500u` Fix!):
    -- When a crippled enemy (`enRawHp <= 225` / `<= 3.85x atk`, even holding an unused `Faerie Fire +85`) walks directly
    -- inside our attack range (`dChk <= atkReachChk`, ZERO foot-chase needed!) with `<= 1` enemy creep within `640u` and
    -- decisive HP surplus, punish immediately with crisp right-clicks instead of letting Enemy walk into `Q(200)` unhit!
    local inRangeCrippledPunish = (dChk <= atkReachChk)
        and (localEnCreepsNear <= 1)
        and (((eLocChk.z or 0) - (bLocChk.z or 0)) < 42)
        and (enRawHp <= math.max(225, myAtk * 3.85))
        and ((myHp - enRealMaxBurst) >= math.max(210, enRawHp + 95))

    local maxPressHp = math.max(160, oneRazeDmg + 45, myAtk * 2.15)
    if enDryZeroCoil and (bot:GetMana() or 0) >= 75 and enRawHp <= 265 then
        maxPressHp = math.max(maxPressHp, oneRazeDmg + myAtk * 2.35 + 65, 360)
    elseif enDryZeroCoil and enHp <= 185 then
        maxPressHp = math.max(maxPressHp, 185)
    elseif inRangeCrippledPunish then
        maxPressHp = math.max(maxPressHp, enHp + 10)
    end
    if enHp > maxPressHp then return false end

    local bLoc = bLocChk
    local eLoc = eLocChk
    local d = dChk
    local myMsPress = bot:GetCurrentMovementSpeed() or 305
    local enMsPress = enemy:GetCurrentMovementSpeed() or 305
    local hasBootsLeadPress = (myMsPress >= enMsPress + 25)
    local oneShotOOMPress = enDryZeroCoil and (enRawHp <= myAtk * 1.15)
    local maxChaseDist = ((hasBootsLeadPress and myHp >= 450) or (enRawHp <= 160 and myHp >= 450) or (oneShotOOMPress and myHp >= 250)) and 1520 or 1250
    if d > maxChaseDist then return false end

    -- `v7.9.33-pro` (`auto-20261109-0306` `2:39.80` `tk=7700` `12/14t` Pre-Raze Auto-Release Solo-Kill Fix!):
    if H.ShouldFinishNearLaunchHeroAutoBeforeRaze(bot, enemy, earlyRace) then
        State.commitKillUntil = GameTime() + 2.2
        State.actionTaken = true
        return true
    end

    -- 1. `v7.9.11` (`2204 @ 03:05` Fix) + `v7.9.18` (`9079381960.dem` Instant Burst-Mana Pop for Lethal Raze):
    -- Ready in-band Shadowraze fires BEFORE any `#enemyCreeps` foot-chase gate! If `< 75 MP` with ready Mango/Stick
    -- in inventory and an off-CD in-band Raze finishes or puts `enemy` into 1-auto range, pop Mango/Stick immediately!
    if (bot:GetMana() or 0) < 75 and not bot:IsSilenced() and H.GetPotentialCombatMana(bot) >= 75 and d <= 935
        and enHp <= (oneRazeDmg + (d <= 560 and myAtk * 0.95 or 0)) then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and ab:GetLevel() > 0 and ab:IsCooldownReady() then
                local dat = U.GetRazeAbilityData(ab)
                if dat and math.abs(d - dat.center) <= 255 and H.TryUseBurstManaItem(bot, true) then
                    State.commitKillUntil = GameTime() + 2.2
                    return true
                end
            end
        end
    end
    if (bot:GetMana() or 0) >= 75 and not bot:IsSilenced() then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                    State.actionTaken = true
                    return true
                end
            end
        end
    end

    -- `v7.9.16` + `v7.9.18` (`9079381960.dem` `01:30.6..01:36.6` Uphill + Faerie EHP & `03:11` `81 HP` Finish Fix):
    -- Account for `25%` uphill miss (`0.75x`) AND `enHp` (which already includes `Faerie Fire +85`!) in `twoHitFootKill`!
    local uphillPress = ((eLoc.z or 0) - (bLoc.z or 0)) >= 48
    local aggroPress = (U.CountEnemyCreepsAggroedOnBot and U.CountEnemyCreepsAggroedOnBot(bot, s, State.myCreepChaseUntil)) or 0
    local healthyTwoHitPress = (not uphillPress) and (myHp >= 460) and (aggroPress <= 2)
        and (enHp <= math.max(125, myAtk * 2.15))
        and (myHp >= enRealMaxBurst + 220)
    local twoHitFootKill = ((not uphillPress) and (enRawHp <= myAtk * 0.96))
        or healthyTwoHitPress
        or (enHp <= myAtk * (uphillPress and 1.42 or 1.92))
    if (aggroPress >= 2 or (uphillPress and aggroPress >= 1) or (State.creepKiteUntil and GameTime() < State.creepKiteUntil)) and not twoHitFootKill then
        return false
    end
    if not inRangeCrippledPunish then
        -- `v7.9.27-pro` (`auto-20261108-2034` `02:25.30` `74 -> 75 MP` Passive Mana Tick Chase-Abort Fix!):
        -- Keep `maxCreepsAllowPress = 3` when `healthyTwoHitPress` is active so passive enemy mana ticking from `74 -> 75 MP`
        -- NEVER aborts a `668 HP` vs `95 HP` chase `30u` outside attack range!
        local maxCreepsAllowPress = ((twoHitFootKill and (enDryZeroCoil or healthyTwoHitPress))
            or (hasBootsLeadPress and enRawHp <= 220 and myHp >= 500)) and 3 or 1
        if #(s.enemyCreeps or {}) > maxCreepsAllowPress then return false end
    end

    -- 2. If in right-click reach and safe from enemy T1, finish / punish with right-click!
    local atkReach = atkReachChk
    if d <= atkReach and H.IsSafeToAttack(bot, bLoc, s.enemyTowers, s.allyCreeps) then
        local prevPol = State.combatPolicyActive
        local prevAllow = State.heroCombatAllowed
        State.combatPolicyActive = false
        State.heroCombatAllowed = true
        local firedPress = H.IssueHeroAttack(bot, enemy)
        State.combatPolicyActive = prevPol
        State.heroCombatAllowed = prevAllow
        if not firedPress then
            bot:Action_AttackUnit(enemy, true)
            H.ClearMoveCache()
        end
        State.actionTaken = true
        return true
    end

    -- 3. Smoothly press toward `eLoc` (or 2D chord-intercept `chordPt` when cutting off a flanking fleeing enemy at `02:58..03:06`!)
    --    clamped strictly outside enemy T1 (`>= 915u` unshielded, `>= 585u` with firm creep shield
    --    outside Source 2's `500u` tower hero-aggro trigger when finishing a manaless `<= 2`-hit enemy at `03:11`!)
    local myManaPress = bot:GetMana() or 0
    local catchHorizonSec = (hasBootsLeadPress and myHp >= 450) and 5.50 or (oneShotOOMPress and 4.60 or 1.80)
    local canCatchPress, chordPtPress = true, nil
    if myManaPress < 75 then
        canCatchPress, chordPtPress = H.CanKinematicallyCatchForAttack(bot, enemy, s.enemyTowers, s.allyCreeps, catchHorizonSec)
        if not canCatchPress then
            return false
        end
    end
    local pressTarget = chordPtPress or eLoc
    if s.enemyT1Alive ~= false and s.enemyT1Loc then
        local tLoc = s.enemyT1Loc
        local shield = (s.enemyT1 and U.CanQuery(s.enemyT1))
            and LN.TowerShieldCountLoc(tLoc, s.enemyT1, s.allyCreeps, pressTarget) or 0
        local firmOneShield = enDryZeroCoil and twoHitFootKill and myHp >= 260
            and LN.HasFirmTowerCreepShield and LN.HasFirmTowerCreepShield(tLoc, s.enemyT1, s.allyCreeps, bLoc, 240)
        local minT1Dist = (firmOneShield and 585) or ((shield >= 2 and myHp >= 480) and 640 or 915)
        if U.DistanceBetweenLocations(pressTarget, tLoc) < minT1Dist then
            local awayT1 = (bLoc - tLoc)
            if awayT1:Length2D() < 1 then awayT1 = (P.GetFountain(bot) - tLoc) end
            pressTarget = tLoc + awayT1:Normalized() * minT1Dist
            if shield < 2 and not firmOneShield then
                local dPressToEn = U.DistanceBetweenLocations(pressTarget, eLoc)
                local canAutoFromPress = (dPressToEn <= ((bot:GetAttackRange() or 525) + 30))
                    and H.IsSafeToAttack(bot, eLoc, s.enemyTowers, s.allyCreeps)
                local qAbP = H.GetRazeAbilityByLabel(bot, "near")
                local wAbP = H.GetRazeAbilityByLabel(bot, "mid")
                local eAbP = H.GetRazeAbilityByLabel(bot, "far")
                local canRazeFromPress = (myManaPress >= 75) and (not bot:IsSilenced()) and (
                    (eAbP and (eAbP:GetCooldownTimeRemaining() or 99) <= 0.45 and eAbP:GetLevel() > 0 and dPressToEn >= 430 and dPressToEn <= 955)
                    or (wAbP and (wAbP:GetCooldownTimeRemaining() or 99) <= 0.45 and wAbP:GetLevel() > 0 and dPressToEn >= 200 and dPressToEn <= 705)
                    or (qAbP and (qAbP:GetCooldownTimeRemaining() or 99) <= 0.45 and qAbP:GetLevel() > 0 and dPressToEn <= 455)
                )
                if not canAutoFromPress and not canRazeFromPress then
                    if not enDryZeroCoil and (H.IsEnemyPressuring(bot, enemy) or d <= 615) then
                        local fntP = P.GetFountain(bot)
                        local resetPt = eLoc + (fntP - eLoc):Normalized() * 675
                        if U.DistanceBetweenLocations(resetPt, tLoc) < 980 then
                            resetPt = tLoc + (fntP - tLoc):Normalized() * 995
                        end
                        H.SmartMove(bot, resetPt, 30, true)
                        State.actionTaken = true
                        return true
                    end
                    return false
                end
            end
        end
    end
    if U.DistanceBetweenLocations(bLoc, pressTarget) > 38 then
        H.SmartMove(bot, pressTarget, 30)
        State.actionTaken = true
        return true
    end
    return false
end

-- First-Principles 30Hz Closed-Loop PD + Duty-Cycle Braking Creep-Block Engine (`v7.9.9-pro`):
--   1. Exact Hull Kinematics (`R_hero 24u + R_creep 16u = 40.0u` contact): tracks per-creep live velocity (`vFwd, vLat`)
--      across ticks so the instant Source 2 local avoidance nudges a creep sideways (`±120..185 u/s`) around SF's hull,
--      PD lateral lead (`latErr = creepLat + vLat * 0.10`) cuts across the creep's shoulder on the very first frame!
--   2. True S-Stop Braking Duty Cycle (`Action_ClearActions(true)` at `0°` down-lane yaw):
--      In Source 2, moving a destination from `+80u` to `+58u` STILL moves SF at `100%` MS (`305` base / `350` Boots, which
--      outruns `325 MS` creeps completely!). Our 4-regime closed-loop controller holds/brakes when centered at `fwdLead >= 51u`
--      (`0°` turn!), releases with crisp `36..44u` forward-angled steps on `40u` hull contact (`never turning > 60°`!), and
--      regulates effective wave speed to `~165..205 u/s` whether SF has `305 MS` or `350 MS` Power Treads!
--   3. Strict Slipped-Creep Wave Abort Law: if ANY creep in the wave slips past SF (`fwd < -16u`), immediately aborts
--      blocking trailing creeps (`abortedWaveBlockUntil`) so waves are NEVER split!
--   4. True `190u` Tower-Hull Clearance (`> 144u tower + 24u hero = 168u`!): prevents T2/T1 hull snagging (`1814 @ +7.33s`)!
function H.ExecuteDynamicCreepBlockStep(bot, corridorCreeps, myT1, myT2, enT1, desiredWaveSpeed)
    local now = GameTime()
    local bLoc = bot:GetLocation()
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local dtimeBlock = (type(DotaTime) == "function") and DotaTime() or 0
    local isMidGameWave = (dtimeBlock >= 20.0)
    local canOvertakeFromBehind = (myMS >= 338)
    local minCatchableFwd = canOvertakeFromBehind and (isMidGameWave and -135.0 or -110.0) or -18.0

    State.creepBlockTrack = State.creepBlockTrack or {}
    local trackTbl = State.creepBlockTrack

    local candidates = {}
    local minRawDEn = math.huge
    local minFwdAll = math.huge
    local maxFwdAll = -math.huge

    for _, ac in ipairs(corridorCreeps) do
        local cLoc = ac:GetLocation()
        local dEn = U.DistanceBetweenLocations(cLoc, enT1)
        if dEn < minRawDEn then minRawDEn = dEn end
        local mDir = (enT1 - cLoc):Normalized()
        local rx, ry = bLoc.x - cLoc.x, bLoc.y - cLoc.y
        local fwd = rx * mDir.x + ry * mDir.y
        local lx, ly = -mDir.y, mDir.x
        local creepLat = (-rx) * lx + (-ry) * ly

        local vx, vy = 0.0, 0.0
        local cv = (ac.GetVelocity and ac:GetVelocity()) or nil
        if cv and (math.abs(cv.x or 0) + math.abs(cv.y or 0)) > 5.0 then
            vx, vy = cv.x or 0, cv.y or 0
        else
            local tr = trackTbl[ac]
            if tr and (now - tr.t) >= 0.015 and (now - tr.t) <= 0.45 then
                local invDt = 1.0 / (now - tr.t)
                local rawVx, rawVy = (cLoc.x - tr.x) * invDt, (cLoc.y - tr.y) * invDt
                vx = (tr.vx or rawVx) * 0.35 + rawVx * 0.65
                vy = (tr.vy or rawVy) * 0.35 + rawVy * 0.65
            end
        end
        trackTbl[ac] = { x = cLoc.x, y = cLoc.y, t = now, vx = vx, vy = vy }

        local vFwd = vx * mDir.x + vy * mDir.y
        local vLat = vx * lx + vy * ly
        local isRanged = ((ac.GetAttackRange and ac:GetAttackRange()) or 100) > 300

        if fwd < minFwdAll then minFwdAll = fwd end
        if fwd > maxFwdAll then maxFwdAll = fwd end

        candidates[#candidates + 1] = {
            creep = ac, loc = cLoc, dEn = dEn,
            mDir = mDir, fwd = fwd, creepLat = creepLat,
            vFwd = vFwd, vLat = vLat, lx = lx, ly = ly, isRanged = isRanged,
        }
    end
    if #candidates == 0 then
        return false
    end

    local waveWasLatched = (now < (State.creepBlockWaveLatched or 0))
    if minFwdAll < -16.0 then
        local splitPackAbort = (not isMidGameWave or not canOvertakeFromBehind)
            and (maxFwdAll > 22.0 and minFwdAll < -20.0)
        if waveWasLatched or (not canOvertakeFromBehind) or (minFwdAll < minCatchableFwd - 6.0) or splitPackAbort then
            State.abortedWaveBlockUntil = now + (isMidGameWave and 4.5 or 9.5)
            State.creepBlockWaveLatched = 0
            return false
        end
    end
    if minFwdAll >= 16.0 and minFwdAll <= 220.0 then
        State.creepBlockWaveLatched = now + 1.35
    end

    -- Strict Min-Fwd Priority + Ranged-Flank Guard + 7.5u Target Hysteresis (`State.creepBlockLeadEnt`):
    --   1. If the ranged creep surges within `10u` of `minFwdAll` on an open flank (`|creepLat| >= 40u`, `2135 @ 0:12.20`),
    --      seal the ranged creep first so it never walks to the front of the wave and dies first!
    --   2. Otherwise keep `7.5u` target hysteresis to eliminate 30Hz left-right sawtooth jitter!
    for _, e in ipairs(candidates) do
        local rangedFlankUrgency = (e.isRanged and (e.fwd - minFwdAll) <= 10.0 and math.abs(e.creepLat) >= 40.0) and 9.5 or 0.0
        e.rankScore = e.fwd - rangedFlankUrgency
    end
    table.sort(candidates, function(a, b) return a.rankScore < b.rankScore end)
    local lead = candidates[1]
    if State.creepBlockLeadEnt then
        for _, e in ipairs(candidates) do
            if e.creep == State.creepBlockLeadEnt and (e.rankScore - candidates[1].rankScore) <= 7.5 then
                lead = e
                break
            end
        end
    end
    State.creepBlockLeadEnt = lead.creep

    local cLoc = lead.loc
    local marchDir = lead.mDir
    local fwdLead = lead.fwd
    local latX, latY = lead.lx, lead.ly

    -- Compute front-pack lateral centroid so SF can HERD drifting flankers INWARD (anti-snowplow physics!):
    --   1. Aim `3.5..11u` OUTSIDE `lead` (`same sign as driftFromPack`) when `fwdLead >= 44u` so once reached,
    --      `lead.creepLat` flips sign (`inward of hero`) and every bump herds `lead` BACK toward `packCenterLat`!
    --   2. Inward-Normal S-Stop Law: NEVER S-stop when `lead.creepLat` has the SAME sign as `driftFromPack` (which wedges
    --      `lead` further outward in an infinite escalator!). S-stop ONLY when dead-center (`|lead.creepLat| <= 4.5..5.5u`)
    --      OR already on the OUTSIDE shoulder (`lead.creepLat * driftFromPack < -5.5 and |lead.creepLat| <= 15.0`)!
    local sumLat, cntPack = 0.0, 0
    for _, e in ipairs(candidates) do
        if (e.fwd - minFwdAll) <= 95.0 then
            sumLat = sumLat + e.creepLat
            cntPack = cntPack + 1
        end
    end
    local packCenterLat = (cntPack > 0) and (sumLat / cntPack) or lead.creepLat
    local driftFromPack = lead.creepLat - packCenterLat

    local herdOutside = 0.0
    if fwdLead >= 44.0 and fwdLead <= 76.0 and math.abs(driftFromPack) >= 3.0 then
        herdOutside = (driftFromPack > 0 and 1.0 or -1.0) * math.min(11.0, 3.5 + math.abs(driftFromPack) * 0.42)
    end

    local latLead = math.max(-14.0, math.min(14.0, lead.vLat * 0.06))
    -- Dual-Frontline Flank Guard (`v7.9.15`): when a 2nd creep surges within `55u` behind `lead` on an open lateral shoulder,
    -- blend `25%` toward `#2` while `fwdLead >= 44u` so `#2` cannot slip past while `#1` is braked!
    local secondBias = 0.0
    if #candidates >= 2 and fwdLead >= 44.0 then
        local sec = (candidates[1] == lead) and candidates[2] or candidates[1]
        if sec and (sec.fwd - lead.fwd) <= 55.0 and math.abs(sec.creepLat - lead.creepLat) >= 24.0
            and math.abs(sec.creepLat - lead.creepLat) <= 92.0 then
            secondBias = (sec.creepLat - lead.creepLat) * 0.25
        end
    end
    local latErr = lead.creepLat + latLead + herdOutside + secondBias

    local targetSpd = desiredWaveSpeed or 215.0
    local maxBlock = (targetSpd <= 268.0)
    local deadCenterTol = (myMS >= 332) and 5.5 or 4.5
    local inwardOrDeadCenter = (math.abs(lead.creepLat) <= deadCenterTol)
        or ((lead.creepLat * driftFromPack) < -5.5 and math.abs(lead.creepLat) <= 15.0)
    local consecStops = State.creepBlockConsecStops or 0
    local canPulseStop = inwardOrDeadCenter and (consecStops == 0)
    local brakeFwd = maxBlock and ((myMS >= 332) and 44.0 or 54.0) or ((myMS >= 332) and 54.0 or 64.0)

    -- `v7.9.15`: Only suppress S-stops while actually approaching/abreast of a tower hull (`twFwd >= -15u` & `dTwBot <= 212u`),
    -- NEVER for `245u` AFTER already clearing the tower center (which leaked `0.85s` of unblocked creep sprint past T2 & T1!).
    local passingTower = false
    for _, twLoc in ipairs({ myT2, myT1 }) do
        if twLoc then
            local dTwBot = U.DistanceBetweenLocations(bLoc, twLoc)
            local twFwd = (twLoc.x - bLoc.x) * marchDir.x + (twLoc.y - bLoc.y) * marchDir.y
            if dTwBot <= 212.0 and twFwd >= -15.0 then
                passingTower = true
                break
            end
        end
    end

    local blockPt = nil
    local shouldHoldStop = false

    if minFwdAll < 16.0 then
        local sideClear = 0.0
        if fwdLead < 8.0 and math.abs(lead.creepLat) < 34.0 then
            sideClear = (lead.creepLat >= 0) and -42.0 or 42.0
        end
        blockPt = Vector(
            cLoc.x + marchDir.x * 92.0 + latX * sideClear,
            cLoc.y + marchDir.y * 92.0 + latY * sideClear,
            cLoc.z or 128
        )
    elseif fwdLead > 260.0 then
        -- REGIME A (`fwdLead > 260u`): Turn-angle-aware staging (`92u` when already aligned down-lane, scaling up to `225u`
        -- when walking `180°` up-lane to intercept an incoming mid-game wave with `0` turn-slips!).
        local downPtA = Vector(bLoc.x + marchDir.x * 160.0, bLoc.y + marchDir.y * 160.0, bLoc.z or 128)
        local turnAngA = U.GetAngleDifference(bot, downPtA)
        local aheadA = (turnAngA > 45.0) and math.min(225.0, 92.0 + (turnAngA - 45.0) * 1.0) or 92.0
        blockPt = Vector(
            cLoc.x + marchDir.x * aheadA,
            cLoc.y + marchDir.y * aheadA,
            cLoc.z or 128
        )
    elseif fwdLead > 76.0 then
        -- REGIME B (`76u < fwdLead <= 260u`, `v7.9.10-pro` Critically-Damped Pre-Contact Alignment):
        -- Smooth `0.72x` lateral gain (`max ±38u`, `0` `herdOutside`) + compact forward component (`max(14, |latStepB|*0.40)`)
        -- so SF glides onto centerline without `±80u` S-weave while `325 MS` creeps close `105u -> 52u` hull contact!
        local latErrB = lead.creepLat + latLead * 0.75
        if math.abs(latErrB) > 7.5 then
            local latStepB = math.max(-38.0, math.min(38.0, latErrB * 0.72))
            local fwdAlign = math.max(14.0, math.abs(latStepB) * 0.40)
            blockPt = Vector(
                bLoc.x + marchDir.x * fwdAlign + latX * latStepB,
                bLoc.y + marchDir.y * fwdAlign + latY * latStepB,
                bLoc.z or 128
            )
        else
            local downPt = Vector(bLoc.x + marchDir.x * 120.0, bLoc.y + marchDir.y * 120.0, bLoc.z or 128)
            if U.GetAngleDifference(bot, downPt) > 15.0 then
                blockPt = Vector(bLoc.x + marchDir.x * 24.0, bLoc.y + marchDir.y * 24.0, bLoc.z or 128)
            else
                shouldHoldStop = true
            end
        end
    elseif passingTower and myMS < 332 then
        local latTower = math.max(-40.0, math.min(40.0, latErr * 1.08))
        blockPt = Vector(
            bLoc.x + marchDir.x * 58.0 + latX * latTower,
            bLoc.y + marchDir.y * 58.0 + latY * latTower,
            bLoc.z or 128
        )
    elseif fwdLead >= 42.0 then
        -- REGIME C (`42u <= fwdLead <= 76u`): Full Outside-Shoulder Contact Herding + Pulsed 1-Tick Inward-Normal S-Stop!
        if fwdLead >= brakeFwd and canPulseStop then
            shouldHoldStop = true
        elseif math.abs(latErr) > 5.0 then
            local maxTan = (myMS >= 332) and 0.92 or ((fwdLead >= 54.0) and 0.68 or 0.50)
            local latStep = math.max(-48.0, math.min(48.0, latErr * 1.20))
            local fwdStep = math.max((myMS >= 332) and 20.0 or 28.0, math.abs(latStep) / maxTan)
            blockPt = Vector(
                bLoc.x + marchDir.x * fwdStep + latX * latStep,
                bLoc.y + marchDir.y * fwdStep + latY * latStep,
                bLoc.z or 128
            )
        else
            local relStep = (myMS >= 332) and 15.0 or 36.0
            blockPt = Vector(
                bLoc.x + marchDir.x * relStep + latX * latErr,
                bLoc.y + marchDir.y * relStep + latY * latErr,
                bLoc.z or 128
            )
        end
    else
        -- REGIME D (`16u <= fwdLead < 42u`): Tight Hull Recovery — pull `fwdLead -> 46..54u`!
        local maxTanTight = (myMS >= 332) and 0.65 or 0.42
        local latStep = math.max(-36.0, math.min(36.0, latErr * 1.10))
        local fwdStep = math.max((myMS >= 332) and 32.0 or 56.0, math.abs(latStep) / maxTanTight)
        blockPt = Vector(
            bLoc.x + marchDir.x * fwdStep + latX * latStep,
            bLoc.y + marchDir.y * fwdStep + latY * latStep,
            bLoc.z or 128
        )
    end

    if fwdLead <= 260.0 then
        State.activeCreepBlockAt = now
    end

    if shouldHoldStop then
        local nearTowerHull = false
        for _, twLoc in ipairs({ myT2, myT1 }) do
            if twLoc and U.DistanceBetweenLocations(bLoc, twLoc) < 188.0 then
                nearTowerHull = true
                blockPt = Vector(bLoc.x + marchDir.x * 42.0, bLoc.y + marchDir.y * 42.0, bLoc.z or 128)
                break
            end
        end
        if not nearTowerHull then
            State.creepBlockConsecStops = consecStops + 1
            if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_NONE then
                bot:Action_ClearActions(true)
            end
            State.actionTaken = true
            return true
        end
    end
    State.creepBlockConsecStops = 0

    for _, twLoc in ipairs({ myT2, myT1 }) do
        if twLoc then
            local dx, dy = blockPt.x - twLoc.x, blockPt.y - twLoc.y
            local dTw = math.sqrt(dx * dx + dy * dy)
            if dTw < 188.0 then
                if fwdLead > 185.0 then
                    local cx, cy = cLoc.x - twLoc.x, cLoc.y - twLoc.y
                    local cLen = math.max(1.0, math.sqrt(cx * cx + cy * cy))
                    local ux, uy = cx / cLen, cy / cLen
                    if dTw > 10.0 and ((dx * ux + dy * uy) > 0) then
                        ux, uy = dx / dTw, dy / dTw
                    end
                    blockPt = Vector(twLoc.x + ux * 190.0, twLoc.y + uy * 190.0, blockPt.z or 128)
                else
                    local tx, ty = -marchDir.y, marchDir.x
                    local cSide = (cLoc.x - twLoc.x) * tx + (cLoc.y - twLoc.y) * ty
                    if math.abs(cSide) < 8.0 then
                        cSide = (bLoc.x - twLoc.x) * tx + (bLoc.y - twLoc.y) * ty
                    end
                    local sideSign = (cSide >= 0) and 1.0 or -1.0
                    local rLen = math.max(1.0, dTw)
                    local rx, ry = dx / rLen, dy / rLen
                    if dTw <= 10.0 then
                        rx, ry = tx * sideSign, ty * sideSign
                    end
                    local gx = rx * 0.55 + (marchDir.x * 0.62 + tx * sideSign * 0.78) * 0.65
                    local gy = ry * 0.55 + (marchDir.y * 0.62 + ty * sideSign * 0.78) * 0.65
                    local gLen = math.max(1e-4, math.sqrt(gx * gx + gy * gy))
                    blockPt = Vector(twLoc.x + (gx / gLen) * 192.0, twLoc.y + (gy / gLen) * 192.0, blockPt.z or 128)
                end
            end
        end
    end

    -- `v7.9.19` (`9080125239.dem` `08:06.03–08:09.80` Dire-T1 `(368,578)<->(450,496)` `180°` Hull-Slam Oscillator Fix!):
    -- In Regime A (`fwdLead > 260u`, walking up-lane to meet a distant wave!) or when `myT1`/`myT2` lies near `bLoc`,
    -- raw `Action_MoveDirectly(blockPt)` slammed SF head-first into `myT1 (524, 652)`'s `172u` building hull!
    -- Only use raw `Action_MoveDirectly` during close contact body-blocking (`fwdLead <= 260u`) away from tower hulls!
    local towerBlocksDirect = false
    for _, twCheck in ipairs({ myT2, myT1 }) do
        if twCheck and U.DistanceBetweenLocations(bLoc, twCheck) < 265.0 and fwdLead > 155.0 then
            towerBlocksDirect = true
            break
        end
    end
    if fwdLead <= 260.0 and (not towerBlocksDirect) and bot.Action_MoveDirectly then
        bot:Action_MoveDirectly(blockPt)
    else
        bot:Action_MoveToLocation(U.SteerAroundObstacles(bot, blockPt, W.s))
    end
    State.lastMoveLoc = blockPt
    State.lastMoveTime = now
    State.actionTaken = true
    return true
end

-- Collect all alive mid-corridor lane creeps for `unitListConst` (`UNIT_LIST_ALLIED_CREEPS` or `UNIT_LIST_ENEMY_CREEPS`).
function H.CollectMidCorridorCreeps(fnt, enT1, unitListConst, fallbackList)
    local out = {}
    local seen = {}
    local laneAxis = (enT1 - fnt):Normalized()
    local function consider(c)
        if not (c and not seen[c] and U.CanQuery(c) and c:IsAlive()) then return end
        seen[c] = true
        local nm = (c.GetUnitName and c:GetUnitName()) or ""
        if nm ~= "" and not (string.find(nm, "creep", 1, true) or string.find(nm, "siege", 1, true)) then return end
        if string.find(nm, "neutral", 1, true) then return end
        local cLoc = c:GetLocation()
        local relF = cLoc - fnt
        local proj = relF.x * laneAxis.x + relF.y * laneAxis.y
        local perpX = relF.x - laneAxis.x * proj
        local perpY = relF.y - laneAxis.y * proj
        if (perpX * perpX + perpY * perpY) > (960 * 960) then return end
        out[#out + 1] = c
    end
    if type(GetUnitList) == "function" and unitListConst then
        local okL, list = pcall(GetUnitList, unitListConst)
        if okL and list then
            for _, c in pairs(list) do consider(c) end
        end
    end
    for _, c in pairs(fallbackList or {}) do
        consider(c)
    end
    return out
end

-- `v7.9.2` Closed-Loop T3-to-Staircase Opening Creep Block (`9072025270.dem` + Ward #2 Telemetry Solver!):
--   1. Immediately after pre-horn wards finish (`dtime >= -52s`), navigates safely around Enemy T1 (`R >= 1,040u`!) straight
--      back to `RADIANT_T3_BLOCK` / `DIRE_T3_BLOCK`, arriving `~14s` early and pre-aligning `0°` toward `myT2 -> myT1`!
--   2. Holds `T3_BLOCK` while Wave #1 sits frozen at spawn (`dtime < -3.35s`), intercepting all 4 creeps right at T3!
--   3. Reads live Enemy Wave #1 progress via Ward #2 (between Enemy T1 & T2) to modulate block speed (`240 .. 325 u/s`)
--      and release at the exact tick that lands the wave clash right on our highground staircase (`STAIRCASE_RADIANT/DIRE`)!
function H.HandleOpeningCreepBlock(bot, s)
    local dtime = (type(DotaTime) == "function") and DotaTime() or 99
    -- `v7.9.15` (`auto-20261106-2139` `00:19.53` Premature Abort Fix):
    -- Extend Wave-0 window from `19.5s` to `26.5s` (`5,460u / 230 u/s = 23.7s`!) so SF NEVER turns `180°` around at `myT1`
    -- (`t=19.53s`) while the opponent continues blocking until `24.8s`, carrying our wave all the way to `myWave1Meet`!
    if dtime < -52.0 or dtime > 26.5 then return false end
    -- `v7.9.7-pro` (`0307` Fast-Start / Skip-PreGame Fix): if the lobby host skips strategy time (`dtime` jumps straight
    -- to `0:00` while Ward #2 is still unfinished), abort Ward #2 immediately so Wave #1 block takes full priority!
    if dtime >= 0 and not State.preHornEnemyLaneWardDone then
        State.preHornWard2Aborted = true
    end
    -- Yield ONLY while pre-horn ward phases are still active (so an aborted 2nd ward in backpack NEVER skips the T3 block!)
    local wardCharges = H.CountInventoryObserverWardCharges(bot)
    if dtime < 0 and wardCharges > 0 then
        if (not State.preHornRiverWardDone and dtime < -16.0)
            or (State.preHornRiverWardDone and not State.preHornEnemyLaneWardDone and not State.preHornWard2Aborted and dtime < -31.0) then
            return false
        end
    end
    local isRad, myT1, myT2, _, enT1, _ = H.GetMidTowerGeometry(bot)
    local fnt = P.GetFountain(bot)
    local bLoc = bot:GetLocation()
    local myT3Block = isRad and C.POSITIONS.RADIANT_T3_BLOCK or C.POSITIONS.DIRE_T3_BLOCK
    local myStaircase = isRad and C.POSITIONS.RADIANT_STAIRCASE or C.POSITIONS.DIRE_STAIRCASE

    -- 1. ALWAYS finish retracing `State.ward2Breadcrumbs` back to our river anchor FIRST (both `< -3.35s` and if slightly delayed!),
    --    so SF NEVER cuts into Radiant/Dire forest or stops at `0:00.67` near Enemy T1 to swing a pointless attack!
    if State.ward2Breadcrumbs and #State.ward2Breadcrumbs > 0 then
        if H.FollowWard2ReturnBreadcrumbs(bot) then
            return true
        end
    end

    if dtime >= 0 and s and s.enemy and U.CanQuery(s.enemy) and (s.enemyDist or 9999) <= 740
        and U.DistanceBetweenLocations(bLoc, myT1) <= U.DistanceBetweenLocations(bLoc, enT1) then
        return false
    end

    -- Release cleanly once enemy creeps close within `620u` of `bot` (`~0.95s` before clash) so SF steps behind wave!
    for _, ec in pairs((s and s.enemyCreeps) or {}) do
        if ec and U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(bLoc, ec:GetLocation()) <= 620
            and U.DistanceBetweenLocations(bLoc, myT1) <= U.DistanceBetweenLocations(bLoc, enT1) then
            return false
        end
    end

    -- Pre-Wave Staging (`dtime < -3.35s`): return safely around Enemy T1 -> `myT3Block` and pre-rotate `0°` toward `myT2`!
    -- Includes a self-healing prop-stall detector so even if any map prop sits near `myT3Block`, SF NEVER gets stuck facing `225°`!
    local function stageAndFaceDownLane(anchorPt)
        local dStage = U.DistanceBetweenLocations(bLoc, anchorPt)
        local nowStage = GameTime()
        if State.stagePrevLoc and (nowStage - (State.stagePrevAt or 0)) >= 0.35 then
            if U.DistanceBetweenLocations(bLoc, State.stagePrevLoc) < 5.0 and dStage <= 185.0 then
                State.stagePropSettledAt = nowStage + 2.5
            end
            State.stagePrevLoc = bLoc
            State.stagePrevAt = nowStage
        elseif not State.stagePrevLoc then
            State.stagePrevLoc = bLoc
            State.stagePrevAt = nowStage
        end
        if dStage <= 34.0 then
            State.stageArrivedAnchor = true
        elseif dStage > 58.0 then
            State.stageArrivedAnchor = false
        end
        local settledAtAnchor = State.stageArrivedAnchor or (dStage <= 185.0 and nowStage < (State.stagePropSettledAt or 0))
        if not settledAtAnchor then
            if U.DistanceBetweenLocations(bLoc, enT1) < 1550 then
                H.SafeArcMoveAroundEnemyTowers(bot, anchorPt)
            else
                H.SmartMove(bot, anchorPt, 24, true)
            end
        else
            local angDown = U.GetAngleDifference(bot, enT1)
            if angDown > 12.0 then
                local alignPt = bLoc + (enT1 - bLoc):Normalized() * 16.0
                if bot.Action_MoveDirectly then
                    bot:Action_MoveDirectly(alignPt)
                else
                    bot:Action_MoveToLocation(alignPt)
                end
            elseif bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_NONE then
                bot:Action_ClearActions(true)
            end
        end
        State.actionTaken = true
        return true
    end

    if dtime < -3.35 then
        return stageAndFaceDownLane(myT3Block)
    end

    local allyCorridor = H.CollectMidCorridorCreeps(fnt, enT1, UNIT_LIST_ALLIED_CREEPS, s and s.allyCreeps)
    if #allyCorridor == 0 then
        if dtime <= 3.0 then
            return stageAndFaceDownLane(myT3Block)
        end
        return false
    end

    -- Find frontmost allied creep along the mid corridor
    local frontAllied, minAllyDistEn = nil, math.huge
    for _, ac in ipairs(allyCorridor) do
        local dE = U.DistanceBetweenLocations(ac:GetLocation(), enT1)
        if dE < minAllyDistEn then
            minAllyDistEn, frontAllied = dE, ac
        end
    end
    if not frontAllied then return false end

    -- Once ANY Wave-1 creep has slipped uncatchably ahead (`ExecuteDynamicCreepBlockStep` stamped `abortedWaveBlockUntil`),
    -- NEVER keep body-blocking trailing creeps AND NEVER linger behind them near T2/T3 — march straight to `myStaircase`!
    local stairToEnEarly = U.DistanceBetweenLocations(myStaircase, enT1)
    if dtime >= 0.5 and GameTime() < (State.abortedWaveBlockUntil or 0) then
        if U.DistanceBetweenLocations(bLoc, enT1) > stairToEnEarly + 180 then
            H.SmartMove(bot, myStaircase, 36, true)
            State.actionTaken = true
            return true
        end
        return false
    end

    -- `v7.9.9-pro` (`1814 @ 00:00..00:08` `.dem`-Verified Single-File Convergence Hold):
    -- Hold `myT3Block` (`(-3215, -2718)` Radiant / `(2848, 2121)` Dire — `.dem`-verified exact convergence coordinates
    -- where Valve's north/south barracks streams merge to `lat01 <= 7.6u`!) facing `0°` toward `enT1` until Wave #1 closes within `110u`!
    local t3BlockToEn = U.DistanceBetweenLocations(myT3Block, enT1)
    if dtime < 8.6 and U.DistanceBetweenLocations(bLoc, myT3Block) <= 460 and (minAllyDistEn - t3BlockToEn) > 110 then
        return stageAndFaceDownLane(myT3Block)
    end

    -- `v7.9.7-pro` + `v7.9.8-pro` (`0307` Fast-Start Wave-1 Mid-Lane Intercept, Strictly Down-Lane Only!):
    -- ONLY run when pre-game was skipped while SF was stranded down-lane (`> 480u` closer to `enT1` than `myT3Block`, e.g.
    -- near `myT2`/`myT1`), and clamp `meetPt` so it NEVER pulls SF behind `myT3Block` into T3's split flanks!
    local bDistEn = U.DistanceBetweenLocations(bLoc, enT1)
    if dtime >= 0.5 and dtime <= 14.5 and (t3BlockToEn - bDistEn) > 480 and (minAllyDistEn - bDistEn) > 520 then
        local fLoc = frontAllied:GetLocation()
        local meetPt = fLoc + (enT1 - fLoc):Normalized() * 180
        if U.DistanceBetweenLocations(meetPt, enT1) > t3BlockToEn then
            meetPt = myT3Block
        end
        H.SmartMove(bot, meetPt, 32, true)
        State.actionTaken = true
        return true
    end

    -- Release cleanly once our front creep arrives at `myWave1Meet` (`895u` outside `myT1`, `195u` outside 700u tower range!)
    local myWave1Meet = isRad
        and (C.POSITIONS.RADIANT_WAVE1_MEET or C.POSITIONS.RADIANT_STAIRCASE)
        or (C.POSITIONS.DIRE_WAVE1_MEET or C.POSITIONS.DIRE_STAIRCASE)
    local meetToEn = U.DistanceBetweenLocations(myWave1Meet, enT1)
    if minAllyDistEn <= meetToEn + 65 then
        return false
    end

    -- Piecewise lane-arc path helper (`creep -> towerRef -> meetPt`) so corner bends around `enT1`/`myT1` never skew ETA!
    local function laneArcDistToMeet(pt, viaTower)
        local dPtToMeet = U.DistanceBetweenLocations(pt, myWave1Meet)
        local dViaToMeet = U.DistanceBetweenLocations(viaTower, myWave1Meet)
        if dPtToMeet <= dViaToMeet + 40 then
            return dPtToMeet
        end
        return U.DistanceBetweenLocations(pt, viaTower) + dViaToMeet
    end

    -- `v7.9.13-pro` (`0210 @ 00:06.5..00:21.5` Ward #2 Closed-Loop Piecewise-Path + FoW Dead-Reckoning Early Release!):
    -- Fixes all 3 Wave #1 over-blocking root causes:
    --   1. Removes `dMyToStair <= 1750.0` gate (`at t=11.0..14.3s`, Ward #2 ALREADY proved unblocked `RC_front` at `325 u/s`
    --      would beat `DC_front` onto Dire's staircase even if released immediately at `dMy = 2,150..3,100u`!).
    --   2. Persists Ward #2 speed & path distance across the `~350u` `enT1`/river FoW gap (`dt <= 7.5s` dead-reckoning) so
    --      losing sight of `RC_front` at `t=15.8s` NEVER resets `desiredSpeed` back to `240.0` (max block)!
    --   3. The instant `etaMyUnblocked >= etaEnemy - 0.12` (or `desiredSpeed >= 318.0`), stamps `wave1ReleasedEarlyUntil`
    --      and steps SF `115u` laterally off `DC_front`'s march line (`305 MS` hero otherwise physically caps `325 MS` creeps
    --      at `~230 u/s`!) so our wave sprints at full `325 u/s` to meet `RC_front` on `myWave1Meet` (`895u` outside `myT1`)!
    local nowT = GameTime()
    local fAllyLoc = frontAllied:GetLocation()
    local dMyPathToMeet = laneArcDistToMeet(fAllyLoc, myT1)

    if nowT < (State.wave1ReleasedEarlyUntil or -100) then
        if U.DistanceBetweenLocations(bLoc, enT1) <= meetToEn + 160 then
            return false
        end
        local marchAxis = (myWave1Meet - fAllyLoc)
        if marchAxis:Length2D() < 1 then marchAxis = (enT1 - myT1) end
        marchAxis = marchAxis:Normalized()
        local perpSide = Vector(-marchAxis.y, marchAxis.x, 0)
        local relHero = bLoc - fAllyLoc
        local curLat = relHero.x * perpSide.x + relHero.y * perpSide.y
        if curLat < 0 then perpSide = Vector(-perpSide.x, -perpSide.y, 0) end
        local dHeroToCreep = U.DistanceBetweenLocations(bLoc, fAllyLoc)
        local laneSideTarget = (dHeroToCreep < 210)
            and (fAllyLoc + perpSide * 125 + marchAxis * 165)
            or (myWave1Meet + perpSide * 95)
        H.SmartMove(bot, laneSideTarget, 28, true)
        State.actionTaken = true
        return true
    end

    local desiredSpeed = 240.0 -- Default: max block (`~240 u/s`) from T3 until Ward #2 measures enemy wave
    local enemyCorridor = H.CollectMidCorridorCreeps(enT1, myT1, UNIT_LIST_ENEMY_CREEPS, s and s.enemyCreeps)
    local estEnPathDist = nil
    if #enemyCorridor > 0 then
        local frontEnemy, minEnPath = nil, math.huge
        for _, ec in ipairs(enemyCorridor) do
            local dP = laneArcDistToMeet(ec:GetLocation(), enT1)
            if dP < minEnPath then
                minEnPath, frontEnemy = dP, ec
            end
        end
        if frontEnemy then
            local estEnSpd = State.enWaveEstSpeed or 320.0
            if State.enWavePrevDist and State.enWavePrevTime then
                local dtObs = nowT - State.enWavePrevTime
                if dtObs >= 0.18 and dtObs <= 1.60 then
                    local instSpd = (State.enWavePrevDist - minEnPath) / dtObs
                    if instSpd >= 195.0 and instSpd <= 350.0 then
                        estEnSpd = estEnSpd * 0.58 + instSpd * 0.42
                    end
                end
            end
            State.enWaveEstSpeed = math.max(230.0, math.min(325.0, estEnSpd))
            State.enWavePrevDist = minEnPath
            State.enWavePrevTime = nowT
            estEnPathDist = minEnPath
        end
    elseif State.enWavePrevDist and State.enWavePrevTime and (nowT - State.enWavePrevTime) <= 7.5 then
        -- Dead-reckon Enemy Wave #1 across the `~350u` FoW gap between Ward #2's edge and river vision!
        local dtFow = math.max(0.0, nowT - State.enWavePrevTime)
        estEnPathDist = math.max(0.0, State.enWavePrevDist - dtFow * (State.enWaveEstSpeed or 320.0))
    end

    if estEnPathDist ~= nil then
        local effEnSpd = State.enWaveEstSpeed or 320.0
        local etaEnemy = math.max(0.30, estEnPathDist / effEnSpd)
        -- Unblocked allied creep runs at `325 u/s` after `~0.35s` lateral step-clear & corner turn:
        local etaMyUnblocked = (dMyPathToMeet / 323.0) + 0.35
        desiredSpeed = dMyPathToMeet / etaEnemy
        if etaMyUnblocked >= etaEnemy - 0.12 or desiredSpeed >= 318.0 then
            State.wave1ReleasedEarlyUntil = nowT + 12.0
            local marchAxis = (myWave1Meet - fAllyLoc)
            if marchAxis:Length2D() < 1 then marchAxis = (enT1 - myT1) end
            marchAxis = marchAxis:Normalized()
            local perpSide = Vector(-marchAxis.y, marchAxis.x, 0)
            local relHero = bLoc - fAllyLoc
            if (relHero.x * perpSide.x + relHero.y * perpSide.y) < 0 then
                perpSide = Vector(-perpSide.x, -perpSide.y, 0)
            end
            local stepClearPt = fAllyLoc + perpSide * 125 + marchAxis * 150
            H.SmartMove(bot, stepClearPt, 24, true)
            State.actionTaken = true
            return true
        end
    end

    if H.ExecuteDynamicCreepBlockStep(bot, allyCorridor, myT1, myT2, enT1, desiredSpeed) then
        return true
    end
    local stairToEn = U.DistanceBetweenLocations(myStaircase, enT1)
    if GameTime() < (State.abortedWaveBlockUntil or 0) and U.DistanceBetweenLocations(bLoc, enT1) > stairToEn + 180 then
        H.SmartMove(bot, myStaircase, 36, true)
        State.actionTaken = true
        return true
    end
    return false
end

-- Opportunistic Mid-Game Idle Creep Block (`v7.9.2` + `v7.9.11` Dire T2-T1 & Safe-Salve Wave Block Upgrade):
--   1. Allows blocking while `modifier_flask_healing` is active whenever completely safe from Salve-breaking sources
--      (`s.enemyAlive == false` or `effEnemyDist >= 1,380u`, `#enemyCreeps == 0`, no incoming projectiles — fixes
--      `2213 @ 07:40..07:50` & `08:38..08:50` Dire T2-T1 wave misses!).
--   2. Filters `blockGroup` to creeps that are still behind or overtakable by `bot` (`fwd >= -130u` at `>= 338 MS`,
--      `fwd >= 12u` at `< 338 MS`): if `1` front creep walked past SF while SF finished killing the last enemy creep
--      (`2213 @ 01:43, 02:16, 03:45`), SF still blocks the `2..3` remaining creeps (or overtakes all `4` with PT!)
--      cleanly between T2 and T1 and through T1 to the river staircase!
function H.HandleMidGameIdleCreepBlock(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local dtime = (type(DotaTime) == "function") and DotaTime() or 0
    if dtime < 20.0 then return false end
    if GameTime() < (State.abortedWaveBlockUntil or 0) then return false end
    if L._imminentCS then return false end
    if State.goingToFountain or State.emergencyRetreat then return false end

    local enemy = s and s.enemy
    local enemyVis = enemy and U.CanQuery(enemy) and enemy:IsAlive()
    local fogLoc = (not enemyVis) and s and s.enemyAlive ~= false and s.enemyLastLoc and (s.enemyAbsentFor or 99) <= 4.5
        and s.enemyLastLoc or nil
    local effEnLoc = (enemyVis and enemy:GetLocation()) or fogLoc
    local effEnDist = effEnLoc and GetUnitToLocationDistance(bot, effEnLoc) or 9999

    if bot:HasModifier("modifier_flask_healing") then
        if H.HasSalveBreakingProjectileIncoming(bot) then return false end
        if #((s and s.enemyCreeps) or {}) > 0 then return false end
        if not (s and s.enemyAlive == false) and effEnDist < 1380 then
            return false
        end
    else
        local myHp = bot:GetHealth() or 0
        local myMaxHp = math.max(1, bot:GetMaxHealth() or 600)
        if myHp < math.max(260, myMaxHp * 0.42) then return false end
    end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or earlyRace.canKillNow) then return false end

    local isRad, myT1, myT2, _, enT1, _ = H.GetMidTowerGeometry(bot)
    local myStaircase = isRad and C.POSITIONS.RADIANT_STAIRCASE or C.POSITIONS.DIRE_STAIRCASE
    local bLoc = bot:GetLocation()

    -- `v7.9.20` + `v7.9.28-pro` (`auto-20261108-2049` `01:15.24..01:19.60` `tk=4368..4494` Ward-2 Distant-Wave Creep-Block Abort Fix!):
    --   1. NEVER blindly abort on `s.hasDistantMidWaveClash`! Whenever our Ward #2 spots a newly spawned enemy `:00`/`:30`
    --      wave marching past `enT1` (`3,004u` from `myT1`!), `world.lua` sets `hasDistantMidWaveClash = true` even though
    --      `0` creeps are clashing! Instead, check ACTUAL wave engagement (`fighting` / missing `>= 15 HP` inside `<= 2,250u`)
    --      and true proximity (`< 1,680u` from `myT1` / `< 880u` from `bot` before latching, `< 1,220u` / `< 620u` while latched)
    --      so SF finishes body-blocking every incoming allied wave all the way down to `myStaircase`!
    local nowIdleBlk = GameTime()
    local idleLatched = nowIdleBlk < (State.idleBlockLatchedUntil or 0)
    local abortMyT1Dist = idleLatched and 1220 or 1680
    local abortBotDist  = idleLatched and 620  or 880
    local nearEnemyCreepCount = 0
    for _, lst in ipairs({ (s and s.enemyCreeps) or {}, (s and s.midActiveEnemyCreeps) or {} }) do
        for _, ec in pairs(lst) do
            if ec and U.CanQuery(ec) and ec:IsAlive() then
                local ecLoc = ec:GetLocation()
                local dMyT1 = U.DistanceBetweenLocations(ecLoc, myT1)
                local dBotEc = U.DistanceBetweenLocations(ecLoc, bLoc)
                local ecFighting = (ec.GetAttackTarget and ec:GetAttackTarget() ~= nil)
                    or ((ec:GetHealth() or 550) < (ec:GetMaxHealth() or 550) - 15)
                if dMyT1 < abortMyT1Dist or dBotEc < abortBotDist or (ecFighting and dMyT1 < 2250) then
                    return false
                end
                if dMyT1 < (idleLatched and 1380 or 1820) then
                    nearEnemyCreepCount = nearEnemyCreepCount + 1
                end
            end
        end
    end
    for _, acM in pairs((s and s.midActiveAllyCreeps) or {}) do
        if acM and U.CanQuery(acM) and acM:IsAlive() then
            local dAcT1 = U.DistanceBetweenLocations(acM:GetLocation(), myT1)
            local acFighting = (acM.GetAttackTarget and acM:GetAttackTarget() ~= nil)
                or ((acM:GetHealth() or 550) < (acM:GetMaxHealth() or 550) - 15)
            if acFighting and dAcT1 < 2250 then
                return false
            end
        end
    end
    if nearEnemyCreepCount >= 1 then
        return false
    end
    local noEnemyCreepsNow = (nearEnemyCreepCount == 0)
    local minEnemyBlockDist = noEnemyCreepsNow and 520 or 820
    if enemyVis and (s.enemyDist or 9999) <= minEnemyBlockDist then
        return false
    end
    if L.PeekBestPlan then
        local _, etaSec = L.PeekBestPlan(bot, s)
        if etaSec <= 2.6 then return false end
    end

    local fnt = P.GetFountain(bot)
    local allMidAllies = H.CollectMidCorridorCreeps(fnt, enT1, UNIT_LIST_ALLIED_CREEPS, s and s.allyCreeps)
    if #allMidAllies < 2 then return false end

    local t1ToEn = U.DistanceBetweenLocations(myT1, enT1)
    local stairToEn = U.DistanceBetweenLocations(myStaircase, enT1)
    local dBotFnt = U.DistanceBetweenLocations(bLoc, fnt)
    local dMyT1Fnt = U.DistanceBetweenLocations(myT1, fnt)
    local botAlreadyBehindT1 = (dBotFnt < dMyT1Fnt - 160)
    local effectivelyClearLane = noEnemyCreepsNow
    local enterDistCap = idleLatched and 2750 or 2550
    local maxBotDist = (effectivelyClearLane and botAlreadyBehindT1) and 3250 or (effectivelyClearLane and enterDistCap or 1550)
    local maxBehindT1 = (effectivelyClearLane and botAlreadyBehindT1) and 2850 or (effectivelyClearLane and 2350 or 1350)
    local myMSNow = bot:GetCurrentMovementSpeed() or 305
    local minBlockableFwd = (myMSNow >= 338) and -130.0 or 12.0

    local blockGroup = {}
    for _, ac in ipairs(allMidAllies) do
        local cHp = ac:GetHealth() or 0
        local cMax = math.max(1, ac:GetMaxHealth() or 550)
        local cLoc = ac:GetLocation()
        local dEn = U.DistanceBetweenLocations(cLoc, enT1)
        local dBot = U.DistanceBetweenLocations(cLoc, bLoc)
        local notFighting = not (ac.GetAttackTarget and ac:GetAttackTarget() ~= nil)
        local mDir = (enT1 - cLoc):Normalized()
        local fwd = (bLoc.x - cLoc.x) * mDir.x + (bLoc.y - cLoc.y) * mDir.y
        local catchableFromRiver = noEnemyCreepsNow and (dEn > U.DistanceBetweenLocations(bLoc, enT1) + 45)
        if cHp >= cMax * 0.75
            and notFighting
            and dBot <= maxBotDist
            and dEn <= (t1ToEn + maxBehindT1)
            and dEn >= (stairToEn + 65)
            and (fwd >= minBlockableFwd or catchableFromRiver) then
            blockGroup[#blockGroup + 1] = ac
        end
    end
    if #blockGroup < 2 then return false end

    State.idleBlockLatchedUntil = nowIdleBlk + 1.85
    return H.ExecuteDynamicCreepBlockStep(bot, blockGroup, myT1, myT2, enT1, 240.0)
end

-- `v7.9.0` Night-Vision Asymmetric Sniping (`800u` Night Vision vs our Highground Ward / Creep Vision):
function H.HandleNightVisionAdvantagePoke(bot, s, earlyRace)
    if not (s and s.isNight and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()) then return false end
    if (bot:GetMana() or 0) < 135 or (bot:GetHealth() or 0) < 340 then return false end
    if earlyRace and earlyRace.valid and earlyRace.heCanKillSoon then return false end
    local bLoc = bot:GetLocation()
    local eLoc = s.enemy:GetLocation()
    local d = U.DistanceBetweenLocations(bLoc, eLoc)
    -- At night (`800u` hero vision), `Shadowraze3` (`700 ± 274 = [426, 974]`) reaches up to `174u` BEYOND enemy night sight!
    if d < 785 or d > 945 then return false end
    local unseenOrUphill = (d >= 805) or (((bLoc.z or 0) - (eLoc.z or 0)) >= 85)
    if not unseenOrUphill then return false end
    for _, ec in pairs(s.enemyCreeps or {}) do
        if ec and U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(bLoc, ec:GetLocation()) <= 575 then
            return false -- Enemy lane creep grants vision of SF
        end
    end
    local r3 = bot:GetAbilityByName("nevermore_shadowraze3")
    if r3 and U.IsRazeAbilityCastable(bot, r3) then
        local actT, aimL = H.GetRazeActionType(bot, r3, s.enemy)
        if actT and H.CastOrTurnRaze(bot, r3, actT, aimL, s.enemy) then
            return true
        end
    end
    return false
end

-- `v7.9.0` + `v7.9.8-pro` (`1630 @ 04:10.27` & `04:37.27` Bullseye Self-Cancel Fix!):
-- Deliberate `0.28s` Pro `Shadowraze3` Pump-Fake Bait ONLY on the outer bait rim (`d = [855 .. 975u]`), NEVER inside
-- `[700 .. 850u]` where a real `E(700)` is already a high-probability / guaranteed centered hit!
function H.HandlePumpFakeBait(bot, s, earlyRace)
    if not (s and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()) then return false end
    local now = GameTime()
    if now < (State.nextPumpFakeAt or 0) then return false end
    if (bot:GetMana() or 0) < 150 or (bot:GetHealth() or 0) < 440 then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillSoon or earlyRace.canKillNow) then return false end
    local d = U.DistanceBetweenLocations(bot:GetLocation(), s.enemy:GetLocation())
    if d < 855 or d > 975 then return false end
    if K.EnemyPhase and K.EnemyPhase() ~= nil then return false end
    local r3 = bot:GetAbilityByName("nevermore_shadowraze3")
    if not (r3 and r3:GetLevel() >= 2 and r3:IsCooldownReady()) then return false end
    if not H.RazeFacingOK(bot, s.enemy:GetLocation()) then return false end
    State.nextPumpFakeAt = now + 16.5
    State.pumpFakeCancelAt = now + 0.28
    bot:Action_UseAbility(r3)
    H.StartRazeCast(r3, s.enemy, s.enemy:GetLocation(), C.RAZE.HIT_RADIUS, false)
    H.ClearMoveCache()
    return true
end

-- ============================================================================
-- `v7.9.17` PROACTIVE OUTER-COIL ZONE DENIAL, FEINT & ZERO-TICK HIT-AND-RUN
-- ============================================================================
function H.UpdateMyRazeDetonationTracker(bot, s)
    local firstInit = (State._prevMyRazeCd == nil)
    State._prevMyRazeCd = State._prevMyRazeCd or {}
    local map = {
        { label = "near", name = "nevermore_shadowraze1", range = (C.RAZE and C.RAZE.NEAR_CENTER) or 200 },
        { label = "mid",  name = "nevermore_shadowraze2", range = (C.RAZE and C.RAZE.MID_CENTER)  or 450 },
        { label = "far",  name = "nevermore_shadowraze3", range = (C.RAZE and C.RAZE.FAR_CENTER)  or 700 },
    }
    local now = GameTime()
    local hasVisEnemy = (not firstInit) and s and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()
    local enemyNear = hasVisEnemy
        and (U.DistanceBetweenLocations(bot:GetLocation(), s.enemy:GetLocation()) <= 1080)
    for _, info in ipairs(map) do
        local ab = bot:GetAbilityByName(info.name)
        local cd = (ab and ab:GetLevel() > 0 and ab:GetCooldownTimeRemaining()) or 0
        local prev = State._prevMyRazeCd[info.label] or 0
        if cd > 6.5 and prev <= 1.0 then
            if enemyNear then
                State.justDetonatedHeroRazeLabel = info.label
                State.justDetonatedHeroRazeAt = now
            elseif (not firstInit) and s and s.enemyAlive ~= false and s.enemyLastLoc
                and (s.enemyAbsentFor or 99) <= 0.90 then
                -- `v7.9.29-pro` (`auto-20261108-2131` `04:10.23` `tk=11698` `216 -> 31 HP` Highground-FoW Blind-Raze Fix!):
                -- When the enemy hero slips into Highground Fog of War `< 0.90s` before our already-winding Shadowraze
                -- detonates dead-center on `s.enemyLastLoc`, deduct the exact magical raze damage from `s.enemyLastHealth`
                -- so SF IMMEDIATELY knows the enemy is at `~31 HP` (1-hit lethal!) instead of `216 HP`!
                local fwd = U.GetFacingVector(bot)
                local bLocR = bot:GetLocation()
                local rCenter = bLocR + fwd * info.range
                local dtAbs = math.min(0.60, math.max(0.0, s.enemyAbsentFor or 0))
                local eVel = s.enemyLastVel or Vector(0, 0, 0)
                local estEn = s.enemyLastLoc + eVel * dtAbs
                if U.DistanceBetweenLocations(rCenter, estEn) <= 245 then
                    local lvlR = ab:GetLevel() or 1
                    local baseR = ({ 90, 160, 230, 300 })[lvlR] or 90
                    local stkBonusR = ({ 50, 60, 70, 80 })[lvlR] or 50
                    local prevStacks = ((s.enemyLastRazeRem or 0) > dtAbs) and (s.enemyLastRazeStacks or 0) or 0
                    local mr = s.enemyLastMagicResist or 0.25
                    local estMagicDmg = math.floor((baseR + prevStacks * stkBonusR) * (1.0 - mr))
                    s.enemyLastHealth = math.max(1, (s.enemyLastHealth or 999) - estMagicDmg)
                    s.enemyLastRazeStacks = prevStacks + 1
                    s.enemyLastRazeRem = 7.0
                    State.justDetonatedHeroRazeLabel = info.label
                    State.justDetonatedHeroRazeAt = now
                end
            end
        end
        State._prevMyRazeCd[info.label] = cd
    end

    -- Deduct `-75 MP` from `s.enemyLastMana` when `bot` receives a new Shadowraze debuff stack from FoW (`04:10.23` `93 -> 18 MP`):
    local myStNow, myStRem = U.GetShadowrazeDebuff(bot)
    local curSelfStacks = (myStRem and myStRem > 0.1) and (myStNow or 0) or 0
    local prevSelfStacks = State._prevSelfRazeStacks or 0
    if (not firstInit) and (not hasVisEnemy) and s and s.enemyAlive ~= false
        and (s.enemyAbsentFor or 99) <= 1.5 and curSelfStacks > prevSelfStacks then
        s.enemyLastMana = math.max(0, (s.enemyLastMana or 0) - 75)
    end
    State._prevSelfRazeStacks = curSelfStacks
end

function H.HandlePostRazeDisengage(bot, s, earlyRace)
    if State.actionTaken or bot:IsChanneling() or bot:IsUsingAbility() then return false end
    -- Yield to active `2-for-1` Turn-Rate Asymmetry Combo until Coil #2 fires (`v7.9.26-pro`)!
    if State.turnAbuseCombo and GameTime() < (State.turnAbuseCombo.expireAt or 0) then
        return false
    end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then
        State.postRazeDisengageUntil = nil
        return false
    end

    local now = GameTime()
    local bLoc = bot:GetLocation()
    local eLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(bLoc, eLoc)
    local enPot = U.GetPotentialManaForRaze(enemy)
    local myAtk = K.AttackDamageVs(bot, enemy)
    local enEffHp = (enemy:GetHealth() or 9999) + (U.GetStickCharges(enemy) * 15) + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(enemy)) or 0)
    local lr = U.SolveLethalRace(bot, enemy, s)
    local myRangePost = (bot:GetAttackRange() or 525)
    local myManaPost = bot:GetMana() or 0
    -- `v7.9.18` (`9079381960.dem` `05:47.0..05:47.7` `13 MP` Post-`W` Walk-In Into Enemy `E(700)` Fix):
    -- When `< 75 MP` (`0` coils left!) against an armed rival (`enPot >= 75`), ONLY override post-raze disengage
    -- for a genuine 1-hit immediate auto (`<= 1.05 * myAtk` inside `myRange + 15`), NEVER for a 2-swing chase into `E(700)`!
    local physFinishMult = (myManaPost < 75 and enPot >= 75) and 1.05 or 2.05
    local physFinishPad  = (myManaPost < 75 and enPot >= 75) and 15 or 55
    local canFinishFast = (enEffHp <= myAtk * physFinishMult and d <= myRangePost + physFinishPad)
        or (earlyRace and earlyRace.valid and earlyRace.canKillNow and (myManaPost >= 75 or enEffHp <= myAtk * 1.05))
        or (lr and lr.winsFirstKill and lr.tKillHim <= ((myManaPost < 75 and enPot >= 75) and 0.65 or 1.50))

    -- Check if an already-castable in-band raze kills Enemy right now (`1`-coil lethal follow-up):
    if not canFinishFast and (bot:GetMana() or 0) >= 75 and not bot:IsSilenced() then
        local oneCoilKillDmg = U.GetNRazeDamage(bot, enemy, 1)
        if enEffHp <= oneCoilKillDmg + 5 then
            for _, lbl in ipairs({ "near", "mid", "far" }) do
                local abK = H.GetRazeAbilityByLabel(bot, lbl)
                local datK = abK and U.GetRazeAbilityData(abK)
                if abK and datK and U.IsRazeAbilityCastable(bot, abK) and math.abs(d - datK.center) <= 252 then
                    canFinishFast = true
                    break
                end
            end
        end
    end

    if canFinishFast or enPot < 75 then
        State.postRazeDisengageUntil = nil
        return false
    end

    -- Initialize zero-tick Hit-and-Run Disengage on the exact frame our coil detonates (`<= 0.14s` age):
    if State.justDetonatedHeroRazeAt and (now - State.justDetonatedHeroRazeAt) <= 0.14 then
        local detLabel = State.justDetonatedHeroRazeLabel
        State.justDetonatedHeroRazeAt = nil
        State.justDetonatedHeroRazeLabel = nil

        local wAb = H.GetRazeAbilityByLabel(bot, "mid")
        local eAb = H.GetRazeAbilityByLabel(bot, "far")
        local myWSpent = (not wAb) or wAb:GetLevel() == 0 or (wAb:GetCooldownTimeRemaining() or 0) > 1.2 or (bot:GetMana() or 0) < 75
        local myESpent = (not eAb) or eAb:GetLevel() == 0 or (eAb:GetCooldownTimeRemaining() or 0) > 1.2 or (bot:GetMana() or 0) < 75
        local myStacks = U.GetShadowrazeDebuff(bot) or 0

        local enNearReady = K.EnemyRazeReadyIn("near") <= 1.55
        local enMidReady  = K.EnemyRazeReadyIn("mid")  <= 1.55
        local enFarReady  = K.EnemyRazeReadyIn("far")  <= 1.55

        local targetDist, counterBand = nil, nil
        if myManaPost < 75 and myESpent and enFarReady and d >= 385 and d <= 988 then
            -- `v7.9.18` + `v7.9.33-pro` (`auto-20261109-0306` `1:14.60 -> 1:16.60` `d=434u` `70 MP` Post-`W` Into `E(700)` Fix!):
            -- Spent our LAST coil (`< 75 MP`) at `385..988u` while Enemy holds live `E(700)` (`426..974u`):
            -- step immediately away past BOTH `W(450)` and `E(700)` to `1010u` (diagonal off Enemy's `700u` sightline below!)
            targetDist = 1010
            counterBand = "far"
        elseif enMidReady and myWSpent and d <= 758 and d >= 295 then
            -- Just spent `W` (or `E`/`Q` with `W` down) inside/near Enemy's `W(450)` (`724u` hull): step straight out!
            targetDist = (myStacks >= 1) and 845 or 790
            counterBand = "mid"
        elseif detLabel == "far" and enFarReady and myESpent and d >= 780 and d <= 988 then
            -- Outer `E(700)` hit-and-run: step past `974u` hull before Enemy's `0.55s` `E` can answer!
            targetDist = 1010
            counterBand = "far"
        elseif detLabel == "near" and enNearReady and (not enMidReady) and (not enFarReady) and d <= 488 then
            -- Outer `Q(200)` hit-and-run when Enemy's `W` & `E` are spent: step past `474u` `Q` hull!
            targetDist = 528
            counterBand = "near"
        end

        if targetDist and counterBand then
            State.postRazeDisengageUntil = now + 0.80
            State.postRazeDisengageSafeDist = targetDist - 22
            State.postRazeDisengageTargetDist = targetDist
            State.postRazeDisengageBand = counterBand
        end
    end

    if not State.postRazeDisengageUntil or now >= State.postRazeDisengageUntil then
        State.postRazeDisengageUntil = nil
        return false
    end

    local cBand = State.postRazeDisengageBand
    local safeDist = State.postRazeDisengageSafeDist or 768
    local enemyCastingNow = (K.EnemyPhase and K.EnemyPhase() ~= nil) or false
    if d >= safeDist or (cBand and K.EnemyRazeReadyIn(cBand) > 1.85 and not enemyCastingNow) then
        State.postRazeDisengageUntil = nil
        return false
    end

    -- Yield for safe enemy lane-creep last-hits when not carrying lethal stacks (`v7.9.27-pro` `R1 01:10` `14 HP` `E1796` +
    -- `v7.9.28-pro` `R3 0:39` `tk=3244..3272` `39 HP` `E774` & `5 HP` `E780` Fix!):
    -- When `myStNow <= 1`, Enemy's `far` coil is spent (`cBand == "mid"` & `EnemyRazeReadyIn("far") > 2.0`), and SF holds a
    -- huge HP cushion (`myHpDis >= burstDis + 175`), NEVER forfeit a `0.40s` 1-hit enemy CS (`39 HP` `E774`), and NEVER kite
    -- outside `500u` attack range of enemy creeps dying under our own T1 (`<= 870u`) once safely outside `W(450)` (`>= 705u`)!
    local myStNow = U.GetShadowrazeDebuff(bot) or 0
    local myHpDis = bot:GetHealth() or 0
    local enHpDis = enemy:GetHealth() or 9999
    local enFarDownDis = K.EnemyRazeReadyIn("far") > 2.0
    local burstDis = K.EnemyBurstVs(bot, enemy, math.max(250, d - 80), 1.35, false)
    local hgDomDis = (((bLoc.z or 0) - (eLoc.z or 0)) >= 42) and (myHpDis >= enHpDis + 125) and (myHpDis >= burstDis + 210)
    local safeStack1FarmDis = (myStNow <= 1) and enFarDownDis and (myHpDis >= burstDis + 175)
        and ((((bLoc.z or 0) - (eLoc.z or 0)) >= 40 and myHpDis >= enHpDis + 125) or d >= 640)
    if myStNow == 0 and hgDomDis and d >= 475 then
        State.postRazeDisengageUntil = nil
        return false
    end
    if safeStack1FarmDis and d >= 708 then
        State.postRazeDisengageUntil = nil
        return false
    end
    local allowImminentCSDis = (myStNow == 0 and myHpDis >= 360) or safeStack1FarmDis
    local csWinDis = ((myStNow == 0 and (myHpDis >= burstDis + 165)) or safeStack1FarmDis) and 0.78 or 0.18
    if allowImminentCSDis and L and L.HasImminentCreepCS then
        local csNow, csEtaNow, oneHitNow = L.HasImminentCreepCS(bot, s, csWinDis, true)
        if (csNow and (csEtaNow or 1) <= csWinDis) or oneHitNow then
            return false
        end
    end

    if U.IsAttackingAction(bot) then
        bot:Action_ClearActions(false)
    end
    local fntDis = P.GetFountain(bot)
    local ownT1 = (s and s.allyT1Loc) or P.GetT1Close(bot) or fntDis
    local tgtDist = (safeStack1FarmDis and cBand == "mid") and 745 or (State.postRazeDisengageTargetDist or (safeDist + 24))
    local refHome = (U.DistanceBetweenLocations(ownT1, eLoc) >= tgtDist) and ownT1 or fntDis
    local outDir = (d > 1) and (bLoc - eLoc):Normalized() or (refHome - eLoc):Normalized()
    local t1Dir = (U.DistanceBetweenLocations(refHome, eLoc) > 1) and (refHome - eLoc):Normalized() or outDir
    -- `v7.9.26-pro`: Pure radial escape (`dd/dt = +1.00 * myMs`) after a `1-for-0` turn-asymmetry rim slip-coil!
    local pureRadial = now < (State.postRazeDisengagePureRadialUntil or 0)
    local escDir = pureRadial and outDir or (outDir * 0.55 + t1Dir * 0.45):Normalized()
    local rawEscSpot = eLoc + escDir * tgtDist
    -- `v7.9.33-pro` (`auto-20261109-0306` `1:16.60` `HIT#5` Diagonal Anti-`E(700)` Disengage Deflection!):
    -- When retreating outward from `< 735u` while Enemy holds `E(700)` ready (`not enFarDownDis`), deflect `rawEscSpot`
    -- `220u` perpendicular to Enemy's live facing ray so SF crosses the `700u` band at `d_ctr >= 165u` (millisecond-dodgeable!)
    -- instead of sprinting straight down Enemy's pre-aimed `700u` sightline!
    if (not pureRadial) and (not enFarDownDis) and enPot >= 75 and d >= 360 and d <= 735 then
        local enYawDis = math.rad((enemy.GetFacing and enemy:GetFacing()) or 0)
        local fxD, fyD = math.cos(enYawDis), math.sin(enYawDis)
        local enFarCtrD = Vector(eLoc.x + fxD * 700, eLoc.y + fyD * 700, eLoc.z)
        local p1D = Vector(-fyD, fxD, 0)
        local p2D = Vector(fyD, -fxD, 0)
        local bestDiagDis, bestScDis = nil, -1e9
        for _, pSide in ipairs({ p1D, p2D }) do
            local dSpot = eLoc + escDir * math.max(785, tgtDist - 45) + pSide * 220
            if type(IsLocationPassable) ~= "function" or IsLocationPassable(dSpot) then
                local midDis = (bLoc + dSpot) * 0.5
                local scDis = U.DistanceBetweenLocations(midDis, enFarCtrD)
                    + U.DistanceBetweenLocations(dSpot, enFarCtrD) * 0.35
                    - U.DistanceBetweenLocations(bLoc, dSpot) * 0.08
                if scDis > bestScDis then
                    bestScDis, bestDiagDis = scDis, dSpot
                end
            end
        end
        if bestDiagDis then
            rawEscSpot = bestDiagDis
        end
    end
    if safeStack1FarmDis and ownT1 then
        local twRDis = (C.BALLISTIC and C.BALLISTIC.TOWER_ATTACK_RANGE_C2C) or 870
        local keepCreepDis, keepHpDis = nil, math.huge
        for _, ecDis in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(ecDis) and ecDis:IsAlive() and U.DistanceBetweenLocations(ecDis:GetLocation(), ownT1) <= twRDis then
                local chpDis = ecDis:GetHealth() or 9999
                if chpDis < keepHpDis then
                    keepHpDis, keepCreepDis = chpDis, ecDis
                end
            end
        end
        if keepCreepDis then
            local cKeepDis = keepCreepDis:GetLocation()
            local rKeepDis = math.max(415, (bot:GetAttackRange() or 500) - 45)
            if U.DistanceBetweenLocations(rawEscSpot, cKeepDis) > rKeepDis then
                local clDis = cKeepDis + (rawEscSpot - cKeepDis):Normalized() * rKeepDis
                if U.DistanceBetweenLocations(clDis, eLoc) >= 705 then
                    rawEscSpot = clDis
                elseif U.DistanceBetweenLocations(cKeepDis, eLoc) > 1 then
                    local colDis = cKeepDis + (cKeepDis - eLoc):Normalized() * rKeepDis
                    if U.DistanceBetweenLocations(colDis, eLoc) >= 705 then
                        rawEscSpot = colDis
                    end
                end
            end
        end
    end
    local escSpot = U.EnsurePassable and U.EnsurePassable(bot, rawEscSpot, escDir) or rawEscSpot
    State.urgentMoveOverride = true
    H.SmartMove(bot, escSpot, 20, true)
    State.actionTaken = true
    return true
end

function H.CastOrTurnProactiveZoneRaze(bot, ab, enemy, pImp, commitHit)
    State._proactiveZoneCastMode = true
    local aim = pImp or U.PredictPosition(enemy, C.RAZE.CAST_POINT or 0.55)
    local isFacing = H.RazeFacingOK(bot, aim)
    local action = isFacing and "CAST" or "TURN"
    local ok = H.CastOrTurnRaze(bot, ab, action, aim, enemy)
    State._proactiveZoneCastMode = nil
    if ok then
        if action == "CAST" and State.aimingRaze == ab then
            State.aimingProactiveZone = true
            if not commitHit then
                -- Pure zero-mana `0.34s` animation feint (forces enemy off `500u` creep re-aggro / CS for `0` MP & `0` CD!):
                State.pumpFakeCancelAt = GameTime() + 0.34
            end
        end
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandleProactiveZoneCoilAndFeint(bot, s, earlyRace, imminentCreepCS)
    if State.actionTaken or imminentCreepCS then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() or bot:IsSilenced() or H.TowerBurnActive() then return false end
    if bot.HasModifier and bot:HasModifier("modifier_flask_healing") then return false end
    if (bot:GetMana() or 0) < 75 then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if earlyRace and earlyRace.valid and earlyRace.heCanKillNow and not earlyRace.canKillNow then return false end

    local myHp = bot:GetHealth() or 0
    if myHp < 310 then return false end
    local bLoc = bot:GetLocation()
    if not H.IsSafeToAttack(bot, bLoc, s.enemyTowers or {}, s.allyCreeps or {}) then return false end

    -- Strictly protect imminent Sacred CS (`<= 0.65s`, 1-hit creep, OR nearby `< myMin + 26` dying creep at `00:41.60`!):
    if L and L.HasImminentCreepCS then
        local csBusyZ, csEtaZ, oneHitZ = L.HasImminentCreepCS(bot, s, 0.65)
        if (csBusyZ and (csEtaZ or 1) <= 0.65) or oneHitZ then
            return false
        end
    end
    for _, ecZ in pairs((s and s.enemyCreeps) or {}) do
        if U.CanQuery(ecZ) and ecZ:IsAlive() and U.DistanceBetweenLocations(bLoc, ecZ:GetLocation()) <= 440 then
            local drZ = U.SFDamageRange(bot, ecZ)
            if (ecZ:GetHealth() or 9999) <= (drZ.min + 26) then
                return false
            end
        end
    end

    local now = GameTime()
    local eLoc = enemy:GetLocation()
    local dNow = U.DistanceBetweenLocations(bLoc, eLoc)
    if dNow < 160 or dNow > 1015 then return false end

    -- Anti-cancel-loop throttle (`1.05s` after a defensive S-cancel unless enemy stepped `42u+` closer or inside `655u`):
    if now < (State.proactiveZoneCancelUntil or 0) then
        local prevCancelD = State.proactiveZoneCancelDist or 9999
        if dNow > prevCancelD - 42 and dNow > 655 then
            return false
        end
    end

    local vIn = U.EnemyApproachSpeed(bot, enemy)
    local vAway = (U.EnemyOutwardSpeed and U.EnemyOutwardSpeed(bot, enemy)) or 0
    local pImp = U.PredictPosition(enemy, C.RAZE.CAST_POINT or 0.55)
    local dImp = U.DistanceBetweenLocations(bLoc, pImp)

    local enStacks, enRem = U.GetShadowrazeDebuff(enemy)
    local myStacks = U.GetShadowrazeDebuff(bot) or 0
    local enHp = enemy:GetHealth() or 999
    local myPotMana = (bot:GetMana() or 0) + U.GetMangoMana(bot) + (U.GetStickCharges(bot) * 15)
    local enPotMana = U.GetPotentialManaForRaze(enemy)

    local enNearReady = (K.EnemyRazeReadyIn("near") <= 1.45) and (enPotMana >= 75)
    local enMidReady  = (K.EnemyRazeReadyIn("mid")  <= 1.45) and (enPotMana >= 75)
    local enFarReady  = (K.EnemyRazeReadyIn("far")  <= 1.45) and (enPotMana >= 75)

    -- Trigger T1: `500u` Allied-Creep Re-Aggro Perimeter Defense (`00:22..00:28`, `02:41..02:44`)
    local canGuard, guardMode, frontAlly = U.CanGuardWaveReaggro(bot, s, earlyRace)
    local reaggroThreat = false
    if canGuard and frontAlly and U.CanQuery(frontAlly) then
        local dEnWave = GetUnitToLocationDistance(frontAlly, eLoc)
        local vToWave = (U.EnemyApproachSpeedToPoint and U.EnemyApproachSpeedToPoint(enemy, frontAlly:GetLocation())) or 0
        if (dEnWave <= 585 and vAway <= 50) or (dEnWave <= 705 and vToWave >= 45) then
            reaggroThreat = true
        end
    end

    -- Trigger T2: Unanswerable Stack-Extension / Post-`E` Cooldown Punish (`00:39..00:42`, `02:32..02:34`)
    local stackOrCdPunish = (vAway <= 45) and (
        ((enStacks or 0) >= 1 and (enRem or 0) >= 0.68)
        or ((not enFarReady) and myHp >= 355 and (myPotMana >= 135 or enPotMana < 140 or enHp <= 420))
    )

    -- Trigger T3: Contested Dying-Creep Approach Denial
    local contestedCreepApproach = false
    if vAway <= 35 then
        local lowThr = math.max(95, (bot:GetAttackDamage() or 54) * 2.25)
        for _, list in ipairs({ s.enemyCreeps or {}, s.allyCreeps or {} }) do
            for _, cr in pairs(list) do
                if cr and U.CanQuery(cr) and cr:IsAlive() and (cr:GetHealth() or 999) <= lowThr then
                    local crLoc = cr:GetLocation()
                    if U.DistanceBetweenLocations(crLoc, eLoc) <= 640
                        and (vIn >= 40 or (U.EnemyApproachSpeedToPoint and U.EnemyApproachSpeedToPoint(enemy, crLoc) >= 40)) then
                        contestedCreepApproach = true
                        break
                    end
                end
            end
            if contestedCreepApproach then break end
        end
    end

    -- Trigger T4: Proactive Outer-Ring Approach Punish (`vIn >= 55 u/s`)
    local outerApproachPunish = (vIn >= 55 and vAway <= 20)
        and (myPotMana >= 135 or (enStacks or 0) >= 1 or enPotMana < 140)

    if not (reaggroThreat or stackOrCdPunish or contestedCreepApproach or outerApproachPunish) then
        return false
    end

    -- `v7.9.19` + `v7.9.25-pro` (`auto-20261108-1609` `00:25..01:02` `101 -> 27 MP` Last-Coil & Lvl-1 Mana-Reserve Guard!):
    --   1. Never burn our LAST `75 MP` (`leaving < 75 MP` OOM!) or spam `0`-stack Level-1 (`62` dmg) hero-only pokes below
    --      `190 MP` against an armed rival unless directly near-lethal or landing a multi-stack combo!
    --   2. Never start `W(450)` at `699u` (`B#21`) or `E(700)` at `915..932u` (`B#19, B#25`) on a stationary/retreating enemy!
    if H.ShouldFinishNearLaunchHeroAutoBeforeRaze(bot, enemy, earlyRace) then
        return false
    end
    if H.WouldBreakEarlyManaReserve(bot, enemy, nil) then
        return false
    end

    local commitHit = (myPotMana >= 150) or ((enStacks or 0) >= 1) or (enHp <= 390) or (enPotMana < 120)
    local toBotYawZ = math.deg(math.atan2(bLoc.y - eLoc.y, bLoc.x - eLoc.x))
    local enFaceYawZ = (enemy.GetFacing and enemy:GetFacing()) or toBotYawZ
    local thetaEnFaceZ = math.abs((toBotYawZ - enFaceYawZ + 180.0) % 360.0 - 180.0)
    local function hasDualValueCreepKillAt(bandCenter)
        local dirZ = (pImp - bLoc)
        if dirZ:Length2D() <= 1 then return false end
        local aimZ = bLoc + dirZ:Normalized() * bandCenter
        for _, ecD in pairs((s and s.enemyCreeps) or {}) do
            if ecD and U.CanQuery(ecD) and ecD:IsAlive() and U.DistanceBetweenLocations(aimZ, ecD:GetLocation()) <= 250 then
                local crDmg = U.GetNRazeDamage(bot, ecD, 1)
                if crDmg > 0 and (ecD:GetHealth() or 9999) <= crDmg then
                    return true
                end
            end
        end
        return false
    end

    -- 1. Unanswerable Outer `W(450)` (radial-velocity + enemy-facing gated so `0`-stack pokes never self-root into aligned `W`!):
    local wAb = H.GetRazeAbilityByLabel(bot, "mid")
    if wAb and U.IsRazeAbilityCastable(bot, wAb) and vAway <= 18 then
        local safeVsEnemyE = (not enFarReady)
            or ((enStacks or 0) > myStacks and myHp >= 395)
            or (reaggroThreat and guardMode == "HIGHGROUND" and myStacks == 0 and myHp >= 440)
        local dualKillW = hasDualValueCreepKillAt(450)
        local alignedArmedW = enMidReady and ((enStacks or 0) <= myStacks) and (not dualKillW) and (thetaEnFaceZ < 55.0)
        local minDNowW = alignedArmedW and (635 + math.min(45, math.max(0, vIn) * 0.16))
            or (dualKillW and 405 or (enMidReady and 575 or 385))
        local maxDNowW = (vIn >= 55) and 708 or 662
        local maxDImpW = (reaggroThreat and vIn >= 55) and 684 or 668
        if safeVsEnemyE and dNow >= minDNowW and dNow <= maxDNowW and dImp >= 435 and dImp <= maxDImpW
            and not (U.ShouldHoldEarlyNonLethalPokeRaze and U.ShouldHoldEarlyNonLethalPokeRaze(bot, enemy, s, 450))
            and not U.HeroRazeRuinsCreepCS(bot, wAb, pImp, enemy, s) then
            if H.CastOrTurnProactiveZoneRaze(bot, wAb, enemy, pImp, commitHit) then
                return true
            end
        end
    end

    -- 2. Unanswerable Outer `E(700)` (`v7.9.33-pro` `0:21.87` `HIT#1` Anti-Mutual-`E700` Alignment Law!):
    -- When Enemy `E(700)` is armed, `(enStacks <= myStacks)`, no Dual-Value CS is secured, and Enemy is ALREADY facing
    -- directly down our barrel (`thetaEnFaceZ < 55°`), starting `E(700)` inside `800..885u` (`tk=3562 @ 800u`) lets Enemy
    -- walk `35u` forward and cast `E(700)` dead-center while we are still rooted, guaranteeing a `1-for-1` mutual hit + wave nuke!
    local eAb = H.GetRazeAbilityByLabel(bot, "far")
    if eAb and U.IsRazeAbilityCastable(bot, eAb) and vAway <= 18 then
        local dualKillE = hasDualValueCreepKillAt(700)
        local alignedArmedE = enFarReady and ((enStacks or 0) <= myStacks) and (not dualKillE) and (thetaEnFaceZ < 55.0)
        local minDNowE = alignedArmedE and (895 + math.min(55, math.max(0, vIn) * 0.18))
            or (dualKillE and 655 or (enFarReady and 825 or ((vIn >= 60) and 655 or 635)))
        local maxDNowE = (vIn >= 60) and 958 or 902
        local maxDImpE = (reaggroThreat and vIn >= 55) and 928 or 912
        if dNow >= minDNowE and dNow <= maxDNowE and dImp >= 675 and dImp <= maxDImpE
            and not (U.ShouldHoldEarlyNonLethalPokeRaze and U.ShouldHoldEarlyNonLethalPokeRaze(bot, enemy, s, 700))
            and not U.HeroRazeRuinsCreepCS(bot, eAb, pImp, enemy, s) then
            if H.CastOrTurnProactiveZoneRaze(bot, eAb, enemy, pImp, commitHit) then
                return true
            end
        end
    end

    -- 3. Unanswerable Outer `Q(200)` when Enemy `W` & `E` are spent:
    local qAb = H.GetRazeAbilityByLabel(bot, "near")
    if qAb and U.IsRazeAbilityCastable(bot, qAb) and (not enMidReady) and (not enFarReady) and vAway <= 15 then
        local minDNowQ = enNearReady and 330 or 150
        if dNow >= minDNowQ and dNow <= 465 and dImp >= 175 and dImp <= 438
            and not (U.ShouldHoldEarlyNonLethalPokeRaze and U.ShouldHoldEarlyNonLethalPokeRaze(bot, enemy, s, 200))
            and not U.HeroRazeRuinsCreepCS(bot, qAb, pImp, enemy, s) then
            if H.CastOrTurnProactiveZoneRaze(bot, qAb, enemy, pImp, true) then
                return true
            end
        end
    end

    return false
end

-- `v7.9.11-pro` (`2204 @ 02:20, 02:53, 03:22, 03:30, 03:49` Dominant Anti-Reaggro Wave-Shield & Punish!):
-- When our SF is significantly stronger than the enemy SF (`U.IsLaneDominant(bot, s, earlyRace) == true`) and no CS/deny
-- requires an immediate swing (`<= 0.55s`), NEVER allow a weaker opponent to walk up within `<= 665u` of our allied creeps
-- to touch the `500u` creep-aggro circle and pull our melee creeps back onto his ranged creep!
--   1. If a ready `W(450)` or `E(700)` coil hits him cleanly right now (`mana >= 75`), blast him immediately!
--   2. Otherwise right-click him immediately (`H.IssueHeroAttack`) OR step onto the forward intercept screen between
--      `frontAlly` and `enemy` (`standoff >= 495u` if enemy has `>= 150 MP` + `Q`, `>= 380u` otherwise, `>= 920u` from `enemyT1`)!
function H.HandleDominantAntiReaggroZone(bot, s, earlyRace, imminentCreepCS)
    if State.actionTaken or imminentCreepCS then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() or H.TowerBurnActive() then return false end
    if GameTime() < (State.noReenterEnemyT1Until or 0) then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    local allyCreeps = s and s.allyCreeps
    if not allyCreeps or #allyCreeps == 0 then return false end
    if not (U.IsLaneDominant and U.IsLaneDominant(bot, s, earlyRace)) then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillNow or earlyRace.heCanKillSoon) then return false end
    local myHp = bot:GetHealth() or 0
    if myHp < 375 then return false end

    local dEnToAlly, frontAlly = LN.EnemyDistToAllyWave(enemy, allyCreeps)
    if not frontAlly then
        for _, ac in pairs(allyCreeps) do
            if ac and U.CanQuery(ac) and ac:IsAlive() then
                frontAlly = ac
                break
            end
        end
    end
    if dEnToAlly > 785 or not frontAlly or not U.CanQuery(frontAlly) then return false end

    local bLoc = bot:GetLocation()
    local eLoc = enemy:GetLocation()
    local dHero = U.DistanceBetweenLocations(bLoc, eLoc)
    if s.enemyT1Alive ~= false and s.enemyT1Loc then
        -- Do not try to zone an enemy already standing deep under his own T1 (`< 720u` from `enemyT1Loc`)!
        if U.DistanceBetweenLocations(eLoc, s.enemyT1Loc) < 720 then
            return false
        end
    end

    local myMana = bot:GetMana() or 0
    local enPotMp = K.EnemyManaBudget(enemy, true)
    local enHp = enemy:GetHealth() or 999
    local allowSingleCoilPunish = (enPotMp < 75) or (myMana >= 145)
        or (enHp <= U.GetNRazeDamage(bot, enemy, 1) + K.AttackDamageVs(bot, enemy) + 25)
    if myMana >= 75 and allowSingleCoilPunish and not bot:IsSilenced() then
        for _, label in ipairs(H.BestCenteredRazeOrder(bot, enemy)) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if ab and U.IsRazeAbilityCastable(bot, ab) and not H.WouldBreakEarlyManaReserve(bot, enemy, ab) then
                local action, aim = H.GetRazeActionType(bot, ab, enemy)
                if action == "CAST" or (action == "TURN" and dEnToAlly <= 625) then
                    if H.CastOrTurnRaze(bot, ab, action, aim, enemy) then
                        State.actionTaken = true
                        return true
                    end
                end
            end
        end
    end

    local enQArmed = (enPotMp >= 75) and K.EnemyRazeReady("near", 1.2)
    local minSafeStand = (enQArmed and enPotMp >= 150 and myHp < enHp + 220) and 495 or 385
    local atkR = (bot:GetAttackRange() or 525)
    if dHero <= atkR + 35 and dHero >= minSafeStand - 25
        and H.IsSafeToAttack(bot, bLoc, s.enemyTowers, allyCreeps) then
        if H.IssueHeroAttack(bot, enemy) then
            State.actionTaken = true
            return true
        end
    elseif dHero <= atkR + 585 and dEnToAlly <= 765 then
        -- `v7.9.13-pro` (`0210 @ 00:00..06:00` Proactive Anti-Reaggro Screen):
        -- Position `195u` IN FRONT of `frontAlly` toward `enemy` (clamped `>= minSafeStand` from `enemy` and `>= 920u`
        -- outside `enemyT1`) BEFORE `enemy` reaches the `500u` creep-aggro circle — even when `eLoc` stands `730..865u`
        -- in front of his own T1 (`screenPt` itself is strictly `>= 920u` outside `enemyT1`, so moving there NEVER aggros T1)!
        local faLoc = frontAlly:GetLocation()
        local toEnemyFromAlly = (eLoc - faLoc)
        if toEnemyFromAlly:Length2D() < 1 then toEnemyFromAlly = (eLoc - bLoc) end
        toEnemyFromAlly = toEnemyFromAlly:Normalized()
        local screenPt = faLoc + toEnemyFromAlly * math.min(205, math.max(95, dEnToAlly - minSafeStand))
        if U.DistanceBetweenLocations(screenPt, eLoc) < minSafeStand then
            local awayFromEn = (faLoc - eLoc)
            if awayFromEn:Length2D() < 1 then awayFromEn = (bLoc - eLoc) end
            screenPt = eLoc + awayFromEn:Normalized() * minSafeStand
        end
        if s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(screenPt, s.enemyT1Loc) < 920 then
            local fntRef = P.GetFountain(bot)
            screenPt = s.enemyT1Loc + (fntRef - s.enemyT1Loc):Normalized() * 920
        end
        if U.DistanceBetweenLocations(bLoc, screenPt) > 40
            and U.DistanceBetweenLocations(screenPt, eLoc) >= minSafeStand - 15 then
            H.SmartMove(bot, screenPt, 32, true)
            State.actionTaken = true
            return true
        end
    end
    return false
end

-- `v7.9.12-pro` (`2319 @ 00:54..01:12, 02:20..02:26, 02:55..03:12` Staircase Wave-Freeze Blindness Fix!):
-- When the enemy holds/freezes the wave on his own staircase (`1,601..2,750u` from our T1), C++ `GetNearbyLaneCreeps(1600)`
-- returns `{}` (`#s.enemyCreeps == 0` & `#s.allyCreeps == 0`), which previously trapped `RealThink` inside `holdSpot` at
-- `P.GetT1Close(bot)` (`(632, 518)` — `0` CS, `0` XP!). Using `s.activeMidClashLoc` (`GetUnitList` mid-battle-corridor scan),
-- advance cleanly to safe contested/XP standoff (`~475u`, or `dryStand` when dry) until `<= 1,600u` `RunSacredCS` takes over!
function H.HandleAdvanceToDistantMidWave(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not (s and s.hasDistantMidWaveClash and s.activeMidClashLoc) then return false end
    if State.goingToFountain or State.emergencyRetreat then return false end
    local nowAdv = GameTime()
    if (State.forcedRetreatLoc ~= nil and nowAdv < (State.forcedRetreatUntil or 0))
        or (nowAdv < (State.fleeUntil or 0))
        or (nowAdv < (State.critDangerHystUntil or 0)) then
        return false
    end
    if bot:HasModifier("modifier_flask_healing") or H.TowerBurnActive() then return false end
    if nowAdv < (State.noReenterEnemyT1Until or 0) then return false end

    local myHp = bot:GetHealth() or 0
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 600)
    if myHp < math.max(245, myMaxHp * 0.36) then return false end
    if H.InCriticalLethalDanger(bot, s, earlyRace)
        or (earlyRace and earlyRace.valid and (earlyRace.heCanKillNow or earlyRace.heCanKillSoon)) then
        return false
    end

    -- Only needed when local `1,600u` `RunSacredCS` cannot yet reach/see the active wave clash (`#s.enemyCreeps == 0`
    -- or `bot` is still `> 1,280u` from `s.activeMidClashLoc` with `0` local enemy creeps inside `1,280u`)!
    local bLoc = bot:GetLocation()
    local clashLoc = s.activeMidClashLoc
    local dClash = U.DistanceBetweenLocations(bLoc, clashLoc)
    for _, ecLocal in pairs(s.enemyCreeps or {}) do
        if ecLocal and U.CanQuery(ecLocal) and ecLocal:IsAlive()
            and U.DistanceBetweenLocations(bLoc, ecLocal:GetLocation()) <= 1150 then
            return false
        end
    end
    if dClash <= 520 or dClash > 2950 then
        return false
    end
    -- `v7.9.28-pro` (`auto-20261108-2049` `01:15.47` `tk=4374` Anti-Cross-River Whiplash Guard):
    -- When Ward #2 spots a newly spawned, unengaged enemy wave still marching near `enemyT1` (`> 2,050u` from `allyT1` with
    -- `0` engaged creeps), NEVER march SF across the river onto the enemy ramp (`(-600, -466)`) away from our own wave!
    if s.allyT1Loc and U.DistanceBetweenLocations(clashLoc, s.allyT1Loc) > 2050 then
        local anyEngagedClash = false
        for _, ecD in pairs(s.midActiveEnemyCreeps or {}) do
            if ecD and U.CanQuery(ecD) and ecD:IsAlive()
                and ((ecD.GetAttackTarget and ecD:GetAttackTarget() ~= nil)
                    or ((ecD:GetHealth() or 550) < (ecD:GetMaxHealth() or 550) - 15)) then
                anyEngagedClash = true
                break
            end
        end
        if not anyEngagedClash then
            return false
        end
    end

    local fnt = P.GetFountain(bot)
    local dirHome = (fnt - clashLoc):Normalized()
    local standDist = 475
    local enemy = s.enemy
    local enemyVis = enemy and U.CanQuery(enemy) and enemy:IsAlive()
    if enemyVis and U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, enemy, s) then
        standDist = math.max(standDist, U.GetDrySafeStandoffDist(bot, enemy))
    end
    local targetSpot = clashLoc + dirHome * standDist

    if enemyVis then
        local eLoc = enemy:GetLocation()
        local minHeroGap = (U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, enemy, s))
            and math.max(745, U.GetDrySafeStandoffDist(bot, enemy))
            or 515
        if U.DistanceBetweenLocations(targetSpot, eLoc) < minHeroGap then
            targetSpot = eLoc + (fnt - eLoc):Normalized() * minHeroGap
        end
    end
    if s.enemyT1Alive ~= false and s.enemyT1Loc then
        local shieldUnderEnT1 = 0
        for _, ac in pairs(s.midActiveAllyCreeps or {}) do
            if U.CanQuery(ac) and ac:IsAlive() and (ac:GetHealth() or 0) > 135
                and U.DistanceBetweenLocations(ac:GetLocation(), s.enemyT1Loc) <= 755 then
                shieldUnderEnT1 = shieldUnderEnT1 + 1
            end
        end
        if shieldUnderEnT1 < 1 and U.DistanceBetweenLocations(targetSpot, s.enemyT1Loc) < 930 then
            targetSpot = s.enemyT1Loc + (fnt - s.enemyT1Loc):Normalized() * 930
        end
    end

    if U.DistanceBetweenLocations(bLoc, targetSpot) > 55 then
        H.SmartMove(bot, targetSpot, 45)
        State.actionTaken = true
        return true
    end
    return false
end

-- `v7.9.21` (`auto-20261107-2214` `0/52` Early Creep Aggro-Pull Punish Fix!):
-- Whenever the enemy hero steps up to aggro-pull our creeps (`s.enemyAggroPullUntil > now`, or early lane `dtime <= 270s`
-- within `<= 555u` of our front allied creep while within `atkRange + 65u` of `bot`), punish immediately with a crisp
-- right-click (and ready centered `W`/`E` when mana/tier-favorable) WITHOUT requiring `U.IsLaneDominant` (`00:50..04:30`
-- souls/levels start even!) so the opponent NEVER gets 52 free uncontested aggro-pulls!
function H.HandleEarlyAggroPullPunish(bot, s, earlyRace, imminentCreepCS)
    if State.actionTaken or imminentCreepCS then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() or H.TowerBurnActive() then return false end
    local rightClickLocksCS = L and L.WouldRightClickLockoutCS and L.WouldRightClickLockoutCS(bot, s) or false
    local nowP = GameTime()
    if nowP < (State.noReenterEnemyT1Until or 0) or nowP < (State.fleeUntil or 0) then return false end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if earlyRace and earlyRace.valid and (earlyRace.heCanKillNow or earlyRace.heCanKillSoon) then return false end

    local myHp = bot:GetHealth() or 0
    local myMaxHp = math.max(1, bot:GetMaxHealth() or 600)
    if myHp < math.max(260, myMaxHp * 0.42) then return false end
    local mySt = U.GetShadowrazeDebuff(bot) or 0
    if mySt >= 2 then return false end
    local aggroOnMe = (U.CountEnemyCreepsAggroedOnBot and U.CountEnemyCreepsAggroedOnBot(bot, s, State.myCreepChaseUntil)) or 0
    if aggroOnMe >= 2 then return false end

    local allyCreeps = s and s.allyCreeps
    if not allyCreeps or #allyCreeps == 0 then return false end
    local dEnToAlly, frontAlly = LN.EnemyDistToAllyWave(enemy, allyCreeps)
    local bLoc = bot:GetLocation()
    local eLoc = enemy:GetLocation()
    local faLoc = (frontAlly and U.CanQuery(frontAlly) and frontAlly:GetLocation()) or nil
    local hgStaircaseGuard = faLoc and (faLoc.z or 0) >= 100 and ((faLoc.z or 0) - (eLoc.z or 0)) >= 22
    local dtime = (type(DotaTime) == "function" and DotaTime()) or 999
    local serverPullActive = (s.enemyAggroPullUntil or 0) > nowP
    local earlyStepPull = (dtime <= 270) and (dEnToAlly <= (hgStaircaseGuard and 615 or 555))
    if not serverPullActive and not earlyStepPull then return false end

    local dHero = U.DistanceBetweenLocations(bLoc, eLoc)
    local atkR = bot:GetAttackRange() or 525
    local dryPull = U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, enemy, s) or false
    local outRazedPull = U.IsOutRazedTier and U.IsOutRazedTier(bot, enemy) or false
    local maxPunishReach = ((not dryPull) and (not outRazedPull) and myHp >= 360 and dEnToAlly <= 585)
        and (atkR + 195) or (atkR + 105)
    if dHero > maxPunishReach then return false end

    -- Never step inside enemy T1 attack range or inside point-blank `Q(200)` (`< 365u`) against an armed enemy!
    if s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(bLoc, s.enemyT1Loc) < 880 then
        return false
    end
    local enPotMp = K.EnemyManaBudget(enemy, true)
    local enQArmed = (enPotMp >= 75) and K.EnemyRazeReady("near", 1.2)
    if enQArmed and dHero < 365 and myHp < (enemy:GetHealth() or 600) + 120 then
        return false
    end
    if not H.IsSafeToAttack(bot, bLoc, s.enemyTowers, allyCreeps) then
        return false
    end

    -- `v7.9.33-pro` (`auto-20261109-0306` `0:24..0:36` Unanswerable Staircase Shadowraze Aggro-Pull Punish!):
    -- When Enemy steps up our staircase (`dEnToAlly <= 575`) to pull our highground wave into the river while his
    -- matching counter-band is on cooldown (`e.g. 0:30..0:36`), he carries a stack, or he turns `>= 65°` after pulling,
    -- snap an immediate `1-for-0` `W(450)` / `Q(200)` punish before he escapes down the ramp!
    local csBusyRazeP = false
    if L and L.HasImminentCreepCS then
        local bzP, etaP, ohP = L.HasImminentCreepCS(bot, s, 0.65)
        csBusyRazeP = (bzP and (etaP or 1) <= 0.65) or (ohP == true)
    end
    if (not csBusyRazeP) and dEnToAlly <= 575 and (bot:GetMana() or 0) >= 75 and (not bot:IsSilenced())
        and (not H.ShouldFinishNearLaunchHeroAutoBeforeRaze(bot, enemy, earlyRace))
        and (not H.WouldBreakEarlyManaReserve(bot, enemy, nil)) then
        local enStacksP = U.GetShadowrazeDebuff(enemy) or 0
        local toBotYawP = math.deg(math.atan2(bLoc.y - eLoc.y, bLoc.x - eLoc.x))
        local enFaceP = (enemy.GetFacing and enemy:GetFacing()) or toBotYawP
        local thetaEnP = math.abs((toBotYawP - enFaceP + 180.0) % 360.0 - 180.0)
        for _, pSpec in ipairs({ { lbl = "mid", c = 450 }, { lbl = "near", c = 200 } }) do
            local abP = H.GetRazeAbilityByLabel(bot, pSpec.lbl)
            if abP and U.IsRazeAbilityCastable(bot, abP) then
                local enMatchDown = (enPotMp < 75) or (K.EnemyRazeReadyIn(pSpec.lbl) > 1.85)
                local safeNearVsArmed = (pSpec.lbl ~= "near")
                    or (enPotMp < 75)
                    or (K.EnemyRazeReadyIn("mid") > 1.85 and K.EnemyRazeReadyIn("far") > 1.85)
                if safeNearVsArmed and (enMatchDown or (enStacksP >= 1 and mySt == 0) or thetaEnP >= 65.0) then
                    local actP, aimP = H.GetRazeActionType(bot, abP, enemy)
                    if (actP == "CAST" or (actP == "TURN" and aimP and U.GetAngleDifference(bot, aimP) <= 38))
                        and not (U.ShouldHoldEarlyNonLethalPokeRaze and U.ShouldHoldEarlyNonLethalPokeRaze(bot, enemy, s, pSpec.c))
                        and not U.HeroRazeRuinsCreepCS(bot, abP, aimP or eLoc, enemy, s) then
                        if H.CastOrTurnRaze(bot, abP, actP, aimP, enemy) then
                            State.actionTaken = true
                            return true
                        end
                    end
                end
            end
        end
    end

    if rightClickLocksCS then return false end

    -- `v7.9.25-pro` + `v7.9.33-pro`: If Enemy SF stepped toward our wave (`dEnToAlly <= 585`) while we sit at `555..715u`,
    -- step cleanly to `atkR - 10` (`>= 505u` outside `Q200`, staying on our `z=128` highground plateau!) and punish!
    if dHero > (atkR + 28) and (not dryPull) and (not outRazedPull) then
        local stepPt = eLoc + (bLoc - eLoc):Normalized() * math.max(505, atkR - 10)
        local keepsHG = ((bLoc.z or 0) < 100) or P.IsSameOrHigherElevation(stepPt, bLoc, nil)
        if keepsHG
            and not (s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(stepPt, s.enemyT1Loc) < 915)
            and (type(IsLocationPassable) ~= "function" or IsLocationPassable(stepPt)) then
            H.SmartMove(bot, stepPt, 24, true)
            State.actionTaken = true
            return true
        end
    end

    -- Fire immediate right-click punish (bypassing `combatPolicyActive` gate cleanly via `IssueHeroAttack` override):
    local prevPol = State.combatPolicyActive
    local prevAllow = State.heroCombatAllowed
    State.combatPolicyActive = false
    State.heroCombatAllowed = true
    local fired = H.IssueHeroAttack(bot, enemy)
    State.combatPolicyActive = prevPol
    State.heroCombatAllowed = prevAllow
    if fired then
        State.actionTaken = true
        return true
    end
    return false
end

-- ========================================================================================================
-- `v7.9.26-pro` Empirical `30 Hz` Millimeter / Millisecond Turn-Rate Asymmetry Engine (`9081989180.dem`):
--   * Calibrated Source 2 SF Physics: `ω_SF = 738.0 deg/s` (`24.60 deg` per `1/30s` tick), `17`-tick (`0.567s`)
--     Shadowraze cast phase, `1`-tick (`0.033s`) post-cast move-start offset, and exact Law-of-Cosines off-axis
--     hit cone `cos(θ_max(d, C, R)) = (d^2 + C^2 - R^2) / (2 * d * C)` (`R = 250u` engine blast radius).
--   * Mode 1 (`1-for-0` Rim Slip-Coil): When Enemy stands turned sideways/away (`θ_en >= 72°`), fire `E(700)`,
--     `W(450)`, or `Q(200)` whenever our post-cast radial slip clears EVERY ready Enemy coil (`C_en + 266u`)
--     before Enemy can react + rotate into his off-axis hit cone + complete his `0.567s` cast point!
--   * Mode 2 (`2-for-1` / `2-for-0` Overlap-Boundary Double-Stack Combo): When Enemy stands turned away
--     (`θ_en >= 95°`) inside `W(450)`'s outer overlap `[595..678u]` with `W + E` ready (`>= 150 MP`) — OR inside
--     `Q(200)`'s outer overlap `[355..434u]` with `Q + W` ready while Enemy's `E(700)` is on CD (`>= 2.8s`) —
--     land Coil #1, step radially past the inner blast boundary (`728u` / `478u`) BEFORE Enemy's inner coil can
--     detonate (locking Enemy out of his matching inner coil!), and snap Coil #2 (`2` stacked coils vs `<= 1`!).
-- ========================================================================================================
local TURN_DT_TICK        = 1.0 / 30.0
local SF_TURN_DEG_TICK    = 24.60       -- 738.0 deg/s empirical Source 2 Shadow Fiend turn speed
local RAZE_CAST_PHASE_SEC = 17.0 / 30.0 -- 0.5667s (`0.55s` cast point snapped to 30Hz server grid)
local POST_CAST_MOVE_SEC  = 1.0 / 30.0  -- 1 tick post-cast movement acceleration offset

local function MaxOffAxisHitDeg(distHero, bandCenter, effRadius)
    if distHero <= 1.0 or bandCenter <= 1.0 then return 180.0 end
    if math.abs(distHero - bandCenter) >= effRadius then
        return -1.0
    end
    local num = (distHero * distHero) + (bandCenter * bandCenter) - (effRadius * effRadius)
    local den = 2.0 * distHero * bandCenter
    local cosV = math.max(-1.0, math.min(1.0, num / den))
    return math.deg(math.acos(cosV))
end

local function SignedAngleDiffDeg(fromDeg, toDeg)
    local diff = (toDeg - fromDeg + 180.0) % 360.0 - 180.0
    return diff
end

function H.GetTurnAsymmetryMetrics(bot, enemy)
    if not bot or not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return nil end
    local bLoc = bot:GetLocation()
    local eLoc = enemy:GetLocation()
    if not bLoc or not eLoc then return nil end
    local d = U.DistanceBetweenLocations(bLoc, eLoc)
    if d < 40 or d > 1050 then return nil end

    local toBotYaw = math.deg(math.atan2(bLoc.y - eLoc.y, bLoc.x - eLoc.x))
    local toEnYaw  = math.deg(math.atan2(eLoc.y - bLoc.y, eLoc.x - bLoc.x))
    local enFace   = (enemy.GetFacing and enemy:GetFacing()) or toBotYaw
    local myFace   = (bot.GetFacing and bot:GetFacing()) or toEnYaw

    local signedEnToBot = SignedAngleDiffDeg(enFace, toBotYaw)
    local thetaEnNow    = math.abs(signedEnToBot)
    local thetaMyNow    = math.abs(SignedAngleDiffDeg(myFace, toEnYaw))

    local es = (K.EnemyState and K.EnemyState()) or K._enemy
    local angVel = (es and es.angularVelDeg) or 0.0
    local liveVel = (enemy.GetVelocity and enemy:GetVelocity()) or (es and es.vel) or Vector(0, 0, 0)
    local turningTowardUs = (angVel * signedEnToBot > 0.0) and (math.abs(angVel) >= 115.0)
    local enemyCasting = (K.EnemyPhase and K.EnemyPhase() ~= nil) or false
    local appSpd = (U.EnemyApproachSpeed and U.EnemyApproachSpeed(bot, enemy)) or 0.0

    local tReact
    if enemyCasting or turningTowardUs then
        tReact = TURN_DT_TICK -- Already reacting / mid-turn (`0.033s`)
    elseif thetaEnNow >= 130.0 and appSpd < -60.0 then
        tReact = 3.0 * TURN_DT_TICK -- Walking away with back turned (`0.100s`)
    else
        tReact = 2.0 * TURN_DT_TICK -- Sideways / neutral stance (`0.067s`)
    end

    return {
        bLoc = bLoc,
        eLoc = eLoc,
        d = d,
        thetaEnNow = thetaEnNow,
        thetaMyNow = thetaMyNow,
        tReact = tReact,
        appSpd = appSpd,
        enemyCasting = enemyCasting,
        myMs = math.max(280.0, bot:GetCurrentMovementSpeed() or 305.0),
        enMs = math.max(280.0, enemy:GetCurrentMovementSpeed() or 305.0),
        vel = liveVel,
        es = es,
    }
end

-- Executes active Phase 1/2/3 of `State.turnAbuseCombo` (`W -> Step 728 -> E` or `Q -> Step 478 -> W`) with 0-tick loss!
function H.HandleTurnRateAsymmetryCombo(bot, s, earlyRace)
    local combo = State.turnAbuseCombo
    if not combo then return false end
    local now = GameTime()
    local enemy = s and s.enemy
    if now >= (combo.expireAt or 0)
        or not enemy or not U.CanQuery(enemy) or not enemy:IsAlive()
        or bot:IsSilenced() or H.TowerBurnActive() then
        State.turnAbuseCombo = nil
        return false
    end
    if State.actionTaken then return true end
    if bot:IsCastingAbility() or bot:IsChanneling() then
        State.actionTaken = true
        return true
    end

    local bLoc = bot:GetLocation()
    local eLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(bLoc, eLoc)
    local ab1 = H.GetRazeAbilityByLabel(bot, combo.firstLabel)
    local ab2 = H.GetRazeAbilityByLabel(bot, combo.secondLabel)
    if not ab2 or ab2:GetLevel() <= 0 then
        State.turnAbuseCombo = nil
        return false
    end

    -- Phase 1 (`WAIT_FIRST`): finish turning/casting Coil #1; the exact tick `ab1` enters CD, advance to `STEP_OUT`!
    if combo.phase == "WAIT_FIRST" then
        if ab1 and not ab1:IsCooldownReady() then
            combo.phase = "STEP_OUT"
            combo.stepStartedAt = now
        elseif ab1 and U.IsRazeAbilityCastable(bot, ab1) and d <= (combo.firstCenter + 235) and d >= math.max(45, combo.firstCenter - 235) then
            local act1, aim1 = H.GetRazeActionType(bot, ab1, enemy)
            if act1 and H.CastOrTurnRaze(bot, ab1, act1, aim1, enemy) then
                State.actionTaken = true
                return true
            end
            State.turnAbuseCombo = nil
            return false
        else
            State.turnAbuseCombo = nil
            return false
        end
    end

    -- Phase 2 (`STEP_OUT`): step radially past Enemy's inner blast boundary (`>= combo.stepDist`) BEFORE snapping Coil #2!
    if combo.phase == "STEP_OUT" then
        if d > (combo.secondCenter + 225) then
            -- Enemy sprinted too far outside Coil #2; clear combo cleanly
            State.turnAbuseCombo = nil
            return false
        end
        if d >= (combo.stepDist - 6.0) then
            combo.phase = "FIRE_SECOND"
        else
            local outDir = (d > 1.0) and (bLoc - eLoc):Normalized() or ((P.GetFountain(bot) - eLoc):Normalized())
            local stepGoal = U.EnsurePassable(bot, eLoc + outDir * (combo.stepDist + 24.0), outDir)
            if s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(stepGoal, s.enemyT1Loc) < 885 then
                State.turnAbuseCombo = nil
                return false
            end
            H.SmartMove(bot, stepGoal, 8, true)
            State.actionTaken = true
            return true
        end
    end

    -- Phase 3 (`FIRE_SECOND`): pop instant Mango if needed, then snap Coil #2 (`Stack 2`) and arm clean radial disengage!
    if combo.phase == "FIRE_SECOND" then
        if not ab2:IsCooldownReady() then
            -- Coil #2 already fired! Let `HandlePostRazeDisengage` slip us out cleanly!
            State.postRazeDisengagePureRadialUntil = now + 1.15
            State.turnAbuseCombo = nil
            return false
        end
        if (bot:GetMana() or 0) < 75 then
            if H.TryUseBurstManaItem and H.TryUseBurstManaItem(bot, true) then
                State.actionTaken = true
                return true
            end
            State.turnAbuseCombo = nil
            return false
        end
        if d < (combo.secondCenter - 228) or d > (combo.secondCenter + 222) then
            State.turnAbuseCombo = nil
            return false
        end
        local act2, aim2 = H.GetRazeActionType(bot, ab2, enemy)
        if act2 and H.CastOrTurnRaze(bot, ab2, act2, aim2, enemy) then
            State.postRazeDisengagePureRadialUntil = now + 1.25
            if act2 == "CAST" then
                -- Keep combo alive only until `ab2` enters cooldown on completion, then auto-release to disengage
                combo.expireAt = math.min(combo.expireAt, now + 0.72)
            end
            State.actionTaken = true
            return true
        end
        State.turnAbuseCombo = nil
        return false
    end

    State.turnAbuseCombo = nil
    return false
end

function H.HandleTurnRateAsymmetryCoil(bot, s, earlyRace, imminentCS)
    if State.actionTaken or imminentCS or bot:IsUsingAbility() or bot:IsChanneling() or bot:IsSilenced() then
        return false
    end
    if State.turnAbuseCombo then
        return H.HandleTurnRateAsymmetryCombo(bot, s, earlyRace)
    end
    local enemy = s and s.enemy
    if not enemy or not U.CanQuery(enemy) or not enemy:IsAlive() then return false end
    if H.TowerBurnActive() or (GameTime() < (State.noReenterEnemyT1Until or 0)) then return false end

    local m = H.GetTurnAsymmetryMetrics(bot, enemy)
    if not m or m.enemyCasting or m.thetaEnNow < 72.0 then
        return false
    end

    local now = GameTime()
    local bLoc, eLoc, d = m.bLoc, m.eLoc, m.d
    if s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(bLoc, s.enemyT1Loc) < 885 then
        return false
    end
    local aggroOnMe = (U.CountEnemyCreepsAggroedOnBot and U.CountEnemyCreepsAggroedOnBot(bot, s, State.myCreepChaseUntil)) or 0
    if aggroOnMe >= 2 then return false end

    local myMana = bot:GetMana() or 0
    local myPotMana = H.GetPotentialCombatMana and H.GetPotentialCombatMana(bot) or myMana
    if myPotMana < 75 then return false end

    local myHp = bot:GetHealth() or 0
    local enHp = (enemy:GetHealth() or 9999) + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(enemy)) or 0)
    local enPotMana = K.EnemyManaBudget(enemy, true)
    local enStacks = U.GetShadowrazeDebuff(enemy) or 0
    local myStacks = U.GetShadowrazeDebuff(bot) or 0

    -- Helper: exact time (`sec` from `now`) for OUR `bandCenter` (`200/450/700`) to detonate + hit-reliability check:
    local function evalMyCoilHit(label, bandCenter)
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if not ab or ab:GetLevel() <= 0 or not ab:IsCooldownReady() then return nil end
        local coneMy = MaxOffAxisHitDeg(d, bandCenter, 228.0)
        if coneMy < 0.0 then return nil end
        local myTurnDeg = math.max(0.0, m.thetaMyNow - math.min(C.RAZE.MAX_ANGLE_TO_CAST, coneMy))
        local myTurnTicks = math.ceil(myTurnDeg / SF_TURN_DEG_TICK)
        local tMyHit = (myTurnTicks * TURN_DT_TICK) + RAZE_CAST_PHASE_SEC
        -- Predict Enemy displacement during `min(tMyHit, 0.42s)` using live velocity so fleeing enemies at rims don't walk out!
        local vel = m.vel or Vector(0, 0, 0)
        local predELoc = eLoc + vel * math.min(tMyHit, 0.42)
        local dPred = U.DistanceBetweenLocations(bLoc, predELoc)
        if math.abs(dPred - bandCenter) > 228.0 then
            return nil
        end
        return ab, tMyHit, myTurnTicks
    end

    -- Helper: earliest time (`sec` from `now`) Enemy can rotate into his hit cone (`effR = 258u`) and finish casting `enCenter`:
    local function earliestEnemyBandHitSec(enLabel, enCenter, distRef)
        if enPotMana < 75 then return 999.0 end
        local cdRem = K.EnemyRazeReadyIn(enLabel)
        if cdRem > 0.95 then return 999.0 end
        local coneEn = MaxOffAxisHitDeg(distRef, enCenter, 258.0)
        local reqFaceDeg = (coneEn > 0.0) and math.min(28.0, coneEn) or 15.0
        local enTurnDeg = math.max(0.0, m.thetaEnNow - reqFaceDeg)
        local enTurnTicks = math.ceil(enTurnDeg / SF_TURN_DEG_TICK)
        local tReadyStart = math.max(m.tReact, cdRem)
        return tReadyStart + (enTurnTicks * TURN_DT_TICK) + RAZE_CAST_PHASE_SEC
    end

    -- ====================================================================================================
    -- MODE 2 FIRST (`Higher Reward: 2 Stacks vs <= 1!`): `2-for-1` / `2-for-0` Overlap-Boundary Combo
    --   * Pair A: `W(450) -> Step 728u -> E(700)` from `d in [595 .. 678u]` when `W + E` ready (`>= 150 MP`)
    --   * Pair B: `Q(200) -> Step 478u -> W(450)` from `d in [355 .. 434u]` when `Q + W` ready & Enemy `E` on CD (`>= 2.8s`)
    -- ====================================================================================================
    if m.thetaEnNow >= 95.0 and myPotMana >= 150 and myStacks <= 1 then
        local twoCoilDmg = U.GetNRazeDamage(bot, enemy, 2)
        local enOneCoilDmg = (enPotMana >= 75) and K.EnemyRazeDamage(bot, enemy, 1) or 0
        local enAtk = K.AttackDamageVs(enemy, bot)
        local hpSafeFor2v1 = (twoCoilDmg >= enHp)
            or (myHp >= enOneCoilDmg + math.max(185, enAtk * 2.25) and (twoCoilDmg >= enOneCoilDmg + 65 or enStacks >= 1))

        if hpSafeFor2v1 then
            local pairs2v1 = {
                { first = "mid",  fC = 450.0, second = "far", sC = 700.0, minD = 595.0, maxD = 678.0, stepD = 728.0, reqEnFarDown = false },
                { first = "near", fC = 200.0, second = "mid", sC = 450.0, minD = 355.0, maxD = 434.0, stepD = 478.0, reqEnFarDown = true  },
            }
            for _, pr in ipairs(pairs2v1) do
                if (not pr.reqEnFarDown) or (K.EnemyRazeReadyIn("far") >= 2.80) then
                    local ab2Check = H.GetRazeAbilityByLabel(bot, pr.second)
                    if ab2Check and ab2Check:GetLevel() > 0 and ab2Check:IsCooldownReady() then
                        if d >= pr.minD and d <= pr.maxD then
                            local ab1, tMy1 = evalMyCoilHit(pr.first, pr.fC)
                            if ab1 and tMy1 then
                                local tEnInner = earliestEnemyBandHitSec(pr.first, pr.fC, d)
                                local freeEnClose = (m.appSpd > 20.0)
                                    and (math.max(0.0, (tMy1 + POST_CAST_MOVE_SEC) - m.tReact) * m.enMs * 0.45) or 0.0
                                local myEscSec = math.max(0.0, tEnInner - (tMy1 + POST_CAST_MOVE_SEC))
                                local dAtEnInner = d - freeEnClose + (m.myMs * myEscSec)
                                -- Millimeter Lockout Proof: we cross `fC + 258u` (`708u` for W, `458u` for Q) BEFORE Enemy's inner coil lands!
                                if dAtEnInner >= (pr.fC + 258.0) then
                                    if myMana < 75 then
                                        if twoCoilDmg >= (enHp - 35) and H.TryUseBurstManaItem and H.TryUseBurstManaItem(bot, true) then
                                            State.actionTaken = true
                                            return true
                                        end
                                        return false
                                    end
                                    local act1, aim1 = H.GetRazeActionType(bot, ab1, enemy)
                                    if act1 and H.CastOrTurnRaze(bot, ab1, act1, aim1, enemy) then
                                        State.turnAbuseCombo = {
                                            phase        = "WAIT_FIRST",
                                            firstLabel   = pr.first,
                                            firstCenter  = pr.fC,
                                            secondLabel  = pr.second,
                                            secondCenter = pr.sC,
                                            stepDist     = pr.stepD,
                                            startedAt    = now,
                                            expireAt     = now + 1.85,
                                        }
                                        State.actionTaken = true
                                        return true
                                    end
                                end
                            end
                        elseif pr.first == "mid" and d > 678.0 and d <= 724.0
                            and m.thetaEnNow >= 108.0 and m.appSpd <= 15.0 and myMana >= 150 then
                            -- Silent `15..46u` Pre-Alignment Micro-Step onto `658u` facing Enemy (`thetaMy -> 0°` => `0`-tick snap next frame!)
                            local ab1Pre = H.GetRazeAbilityByLabel(bot, "mid")
                            if ab1Pre and ab1Pre:GetLevel() > 0 and ab1Pre:IsCooldownReady() then
                                local alignSpot = U.EnsurePassable(bot, eLoc + (bLoc - eLoc):Normalized() * 658.0)
                                if not (s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(alignSpot, s.enemyT1Loc) < 900) then
                                    H.SmartMove(bot, alignSpot, 8, true)
                                    State.actionTaken = true
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- ====================================================================================================
    -- MODE 1: `1-for-0` Unanswered Rim Slip-Coil (`E` @ `835..908u`, `W` @ `605..658u`, `Q` @ `355..408u`)
    -- Fires ONLY when our post-cast radial slip clears EVERY ready Enemy Shadowraze (`C_en + 266u`) before
    -- Enemy can turn + finish casting (`100%` mathematically unanswered `1-for-0` coil!).
    -- ====================================================================================================
    local dtime = (type(DotaTime) == "function" and DotaTime()) or 999
    -- Respect Early Mana Reserve (`< 01:25`) ONLY when sitting below `130 MP` against a 0-stack full-HP enemy:
    if dtime < 85 and myMana < 130 and enStacks == 0 and enHp > 280 then
        return false
    end

    local slipCandidates = {
        { label = "far",  c = 700.0, minD = 825.0, maxD = 926.0, slipTarget = 992.0 },
        { label = "mid",  c = 450.0, minD = 595.0, maxD = 676.0, slipTarget = 742.0 },
        { label = "near", c = 200.0, minD = 345.0, maxD = 426.0, slipTarget = 492.0 },
    }
    local enBandsAll = {
        { label = "near", c = 200.0 },
        { label = "mid",  c = 450.0 },
        { label = "far",  c = 700.0 },
    }

    for _, cand in ipairs(slipCandidates) do
        if d >= cand.minD and d <= cand.maxD and myMana >= 75
            and not (U.ShouldHoldEarlyNonLethalPokeRaze and U.ShouldHoldEarlyNonLethalPokeRaze(bot, enemy, s, cand.c)) then
            local ab, tMyHit = evalMyCoilHit(cand.label, cand.c)
            if ab and tMyHit then
                local outDir = (bLoc - eLoc):Normalized()
                local escTest = U.EnsurePassable(bot, eLoc + outDir * cand.slipTarget, outDir)
                local canStepOutPassable = U.DistanceBetweenLocations(escTest, eLoc) >= (cand.c + 262.0)
                if canStepOutPassable then
                    local unansweredAll = true
                    local freeEnClose = (m.appSpd > 20.0)
                        and (math.max(0.0, (tMyHit + POST_CAST_MOVE_SEC) - m.tReact) * m.enMs * 0.50) or 0.0
                    for _, eb in ipairs(enBandsAll) do
                        local tEnHit = earliestEnemyBandHitSec(eb.label, eb.c, d)
                        if tEnHit < 50.0 then
                            local myEscSec = math.max(0.0, tEnHit - (tMyHit + POST_CAST_MOVE_SEC))
                            local dEscaped = d - freeEnClose + (m.myMs * myEscSec)
                            if dEscaped < (eb.c + 258.0) then
                                unansweredAll = false
                                break
                            end
                        end
                    end
                    if unansweredAll then
                        local act, aim = H.GetRazeActionType(bot, ab, enemy)
                        if act and H.CastOrTurnRaze(bot, ab, act, aim, enemy) then
                            State.postRazeDisengagePureRadialUntil = now + 1.25
                            State.postRazeDisengageUntil = now + tMyHit + 0.65
                            State.postRazeDisengageSafeDist = cand.c + 270.0
                            State.postRazeDisengageTargetDist = cand.slipTarget
                            State.postRazeDisengageBand = cand.label
                            State.actionTaken = true
                            return true
                        end
                    end
                end
            end
        end
    end

    return false
end

-- `v7.9.21` (`auto-20261107-2214` `tk=15294..15420` `07:17..07:22` `31 HP` Boots + Tree/Ramp FoW Escape Pursuit!):
-- When a crippled enemy (`<= 180 HP`, or `<= 340 HP` when SF holds a Boots MS advantage `myMS >= enMS + 25`!) ducks behind
-- trees or uphill into Fog of War (`s.enemy == nil`, `enemyAbsentFor <= 5.5s` with Boots lead or `<= 2.6s` without),
-- extrapolate `s.enemyLastLoc` along `(0.55 * lastVel + 0.45 * towardEnemyFountain)` clamped strictly outside Enemy T1
-- (`>= 920u`) and sprint to re-acquire vision and finish the kill!
function H.HandleFoWLowHpAndBootsPursuit(bot, s, earlyRace)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not s or (s.enemy and U.CanQuery(s.enemy)) or s.enemyAlive == false then return false end
    if not s.enemyLastLoc or H.TowerBurnActive() then return false end
    local nowF = GameTime()
    if nowF < (State.noReenterEnemyT1Until or 0) or nowF < (State.fleeUntil or 0) then return false end
    if State.goingToFountain or State.emergencyRetreat then return false end
    if earlyRace and earlyRace.valid and earlyRace.heCanKillNow then return false end

    local myHp = bot:GetHealth() or 0
    if myHp < 340 then return false end
    local myMs = bot:GetCurrentMovementSpeed() or 305
    local enMs = s.enemyLastMS or 305
    local hasBootsLead = (myMs >= enMs + 25)
    local absentSec = s.enemyAbsentFor or 99
    local maxAbsent = hasBootsLead and 5.5 or 2.8
    if absentSec > maxAbsent then return false end

    local enLastHp = s.enemyLastHealth or 9999
    local enLastMp = s.enemyLastMana or 999
    local myAtk = bot:GetAttackDamage() or 65
    local hasReadyRazeFow = ((bot:GetMana() or 0) >= 75) and (K.MyReadyRazeCount(bot, false) >= 1)
    local qFow = bot:GetAbilityByName("nevermore_shadowraze1")
    local rLvlFow = (qFow and qFow:GetLevel()) or 0
    local oneRazeFow = (rLvlFow > 0) and math.floor((({ 90, 160, 230, 300 })[rLvlFow] or 90) * (1.0 - (s.enemyLastMagicResist or 0.25))) or 0
    local maxTargetHp = hasBootsLead and math.max(320, myAtk * 3.2) or math.max(135, myAtk * 1.65)
    if enLastMp < 75 and myHp >= 420 then
        maxTargetHp = math.max(maxTargetHp, myAtk * 1.90, 160)
    end
    if hasReadyRazeFow and myHp >= 400 then
        maxTargetHp = math.max(maxTargetHp, oneRazeFow + 25)
    end
    if enLastHp > maxTargetHp then return false end

    local bNow = bot:GetLocation()
    local lastLoc = s.enemyLastLoc
    local dLast = U.DistanceBetweenLocations(bNow, lastLoc)
    local maxChase = hasBootsLead and 1520 or (hasReadyRazeFow and 960 or 680)
    if dLast > maxChase then return false end

    -- Do not chase if `lastLoc` was already deep under Enemy T1 (`< 620u`)!
    if s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(lastLoc, s.enemyT1Loc) < 620 then
        return false
    end

    -- `v7.9.29-pro` (`04:10.23` Instant Highground Vision Reveal):
    -- If SF is on river lowground (`z < 105`), the crippled 1-2 hit enemy is in Highground FoW (`z >= 115`, `dLast <= 760u`),
    -- and SF holds an active `item_ward_observer`, plant it (`0.0s` cast point!) onto highground for instant vision + 1-shot!
    local climbingHighground = ((bNow.z or 0) < 105) and ((lastLoc.z or 0) >= 115)
    if climbingHighground and dLast <= 760 and enLastHp <= math.max(135, myAtk * 1.65) then
        local obsFow = U.GetActiveItemByName(bot, "item_ward_observer")
        if obsFow and obsFow:IsFullyCastable() then
            local wardPt = bNow + (lastLoc - bNow):Normalized() * math.min(540, math.max(240, dLast - 60))
            wardPt = U.EnsurePassable(bot, wardPt)
            bot:Action_UseAbilityOnLocation(obsFow, wardPt)
            State.commitKillUntil = nowF + 1.8
            State.actionTaken = true
            return true
        end
    end

    -- Extrapolate along blended `(lastVelocity, towardEnemyFountain)` so tree-jukes and straight retreats are both caught:
    local enFnt = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.MID_FOUNTAIN_DIRE or C.POSITIONS.MID_FOUNTAIN_RADIANT
    local toEnFnt = (enFnt - lastLoc):Normalized()
    local escapeDir = toEnFnt
    if s.enemyLastVel and s.enemyLastVel:Length2D() >= 45 then
        local vDir = s.enemyLastVel:Normalized()
        escapeDir = (vDir * 0.58 + toEnFnt * 0.42):Normalized()
    end
    local extrapDist = math.min(680, enMs * math.min(absentSec, 2.2) * 0.72)
    local huntPt
    if climbingHighground and dLast <= 640 then
        -- Step decisively onto the `z = 128` highground plateau (`>= 125u` past `lastLoc` or directly onto `lastLoc`)
        -- so SF never stalls on `z = 95` stairs short of `1,800u` highground vision (`04:10.3..04:11.4` Fix!):
        huntPt = lastLoc + escapeDir * math.max(95, extrapDist * 0.75)
    else
        huntPt = (dLast <= 140) and (lastLoc + escapeDir * math.max(180, extrapDist)) or (lastLoc + escapeDir * (extrapDist * 0.55))
    end
    local safeT1Margin = (climbingHighground and enLastHp <= myAtk * 1.35 and myHp >= 420) and 895 or 925
    if s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(huntPt, s.enemyT1Loc) < safeT1Margin then
        local awayT1Vec = (huntPt - s.enemyT1Loc)
        if awayT1Vec:Length2D() < 1 then awayT1Vec = (bNow - s.enemyT1Loc) end
        huntPt = s.enemyT1Loc + awayT1Vec:Normalized() * safeT1Margin
    end
    huntPt = U.EnsurePassable(bot, huntPt)
    if U.DistanceBetweenLocations(bNow, huntPt) >= 40 then
        H.SmartMove(bot, huntPt, 25, true)
        if enLastHp <= myAtk * 1.35 then
            State.commitKillUntil = math.max(State.commitKillUntil or 0, nowF + 1.2)
        end
        State.actionTaken = true
        return true
    end
    return false
end

function H.RealThink()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then return end

    State.actionTaken = false
    State.combatPolicyActive = false
    State.holdPos = false
    State.trySafeTreadsCb = H.TrySafeTreadsSwitch
    L._imminentCS = false -- Always reset per-tick so early-return frames never leave stale `_imminentCS = true`!
    _G.__lastCombatStage = nil
    FDBG("think")
    U.BeginPredictionFrame()

    -- World snapshot + enemy raze tracker + live attack animation state (must run BEFORE windup holds!)
    local s = W.Update(bot)
    -- `v7.9.24-pro`: Immediately expire stale or arrived `State.forcedRetreatLoc` at the top of every tick so early
    -- `RunSacredCS` returns NEVER leave a zombie `forcedRetreatLoc` locking Power Treads on `STR` across whole waves!
    if State.forcedRetreatLoc ~= nil then
        if s.now >= (State.forcedRetreatUntil or 0)
            or GetUnitToLocationDistance(bot, State.forcedRetreatLoc) <= 68 then
            H.ClearForcedRetreat()
        end
    end
    K.UpdateEnemyTracker(bot, s.enemy)
    H.UpdateMyRazeDetonationTracker(bot, s)
    H.UpdateAttackActivity(bot)
    H._enemyHeroNear = s.enemy -- GetSafeApproach & HandleActiveRazeValidation read live enemy hero
    -- The hit/miss tracker for his razes - before decisions (the instant mirror reads it)
    if s.enemy then U.UpdateEnemyRazeMissTracker(bot, s.enemy) end

    -- A visible channel/respawn gives a conservative arrival warning only when
    -- no actual visible landing point is available. It is not a known destination.
    if #(s.incomingEnemyTPs or {}) == 0 and s.enemy and U.IsEnemyTPChanneling(s.enemy) then
        State.enemyTPIncomingUntil = s.now + 3.0
    end
    if #(s.incomingEnemyTPs or {}) == 0 and s.enemyAlive and State.enemyWasAlive == false then
        State.enemyTPIncomingUntil = math.max(State.enemyTPIncomingUntil or 0, s.now + 6.0)
    end
    State.enemyWasAlive = s.enemyAlive

    -- A TP channel is running - no orders (any order cancels the teleport to the T1)
    if bot:IsChanneling() then
        State.actionTaken = true
        return
    end

    H.LevelUpAbilities(bot)
    -- Keep active inventory organized UNLESS a Backpack consumable or 3-phase Mango sequence is active
    if not State.mangoSeq and GameTime() >= (State.branchTangoSwapUntil or -1000) then
        U.ManageInventorySlots(bot)
    end
    local earlyRace = K.Race(bot, s.enemy, false, s)

    -- Emergency survival consumables WITH full earlyRace context (Faerie Fire +85, Stick/Wand, Mango)
    if H.HandleEmergencyConsumables(bot, earlyRace, s) then return end
    -- Advance any active 3-phase Multi-Tick Mango + PT/Backpack state machine BEFORE regular Treads/lane orders!
    if H.TickMangoStateMachine(bot, s) then return end
    -- Instant `+220 HP` Strength Power Treads survival lock BEFORE emergency retreats/disengages!
    -- `0`-tick Instant Defensive Glyph (`ActionImmediate_Glyph()` never interrupts TP channel, cast, or retreat!):
    if s and s.allyTowers and U.ShouldUseGlyphDefensive(bot, s.allyTowers) then
        U.UseGlyph(bot)
    end
    if H.ShouldLockStrengthTreads(bot) and H.TrySafeTreadsSwitch(bot, "SURVIVE") then return end
    if H.HandleIncomingTeleport(bot, s) then return end
    if H.HandleEnemyBuybackAndRespawnThreat(bot, s, earlyRace) then return end
    if H.HandlePreRespawnOverextensionPullback(bot, s) then return end
    if H.HandleFreshEnemyTPArrival(bot, s, earlyRace) then return end

    -- FOUNTAIN RESPAWN / HEAL + IMMEDIATE TP TO MID T1 (runs BEFORE RunSacredCS and empty-wave holdSpot!)
    if H.HandleReturnTP(bot) then return end

    -- =========================================================================
    -- SACRED 30.000 Hz BALLISTIC CS & IMMORTAL LANE SUSTAIN PRIORITY GATE
    -- =========================================================================
    if H.HandleActiveRazeValidation(bot) then return end
    if bot:IsUsingAbility() then
        -- `v7.9.0` 0.00s Post-Cast Raze Backswing Cancel:
        -- In Source 2 C++, `bot:IsUsingAbility()` stays `true` during the `0.30–0.45s` cosmetic post-cast backswing AFTER
        -- `IsInAbilityPhase()` becomes `false` and the coil has already detonated (`cd > 8.1s`)! Cancel backswing immediately!
        local inRealCastPhase = false
        for _, rName in ipairs({ "nevermore_shadowraze1", "nevermore_shadowraze2", "nevermore_shadowraze3" }) do
            local rAb = bot:GetAbilityByName(rName)
            if rAb and rAb:IsInAbilityPhase() then
                inRealCastPhase = true
                break
            end
        end
        local curActive = bot.GetCurrentActiveAbility and bot:GetCurrentActiveAbility() or nil
        if not inRealCastPhase and curActive and curActive.IsInAbilityPhase and curActive:IsInAbilityPhase() then
            inRealCastPhase = true
        end
        if inRealCastPhase then
            return
        end
        bot:Action_ClearActions(false)
        H.ClearRazeState()
    end
    if s.enemy then
        local lrQuick = U.SolveLethalRace(bot, s.enemy, s)
        if lrQuick and lrQuick.winsFirstKill and lrQuick.needEmergencyHeal then
            local wandQuick = U.GetActiveItemByName(bot, "item_magic_wand") or U.GetActiveItemByName(bot, "item_magic_stick")
            if wandQuick and wandQuick:IsFullyCastable() and U.GetStickCharges(bot) > 0 then
                bot:Action_UseAbility(wandQuick)
                State.actionTaken = true
                return
            end
            local ffQuick = U.GetActiveItemByName(bot, "item_faerie_fire")
            if ffQuick and ffQuick:IsFullyCastable() and (bot:GetHealth() or 999) <= math.max(95, (bot:GetMaxHealth() or 600) * 0.15) then
                bot:Action_UseAbility(ffQuick)
                State.actionTaken = true
                return
            end
        end
        if H.HandleGuaranteedRazeKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
        if H.HandleGuaranteedAttackKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
    end
    if H.HandleEnemyRazeDodge(bot, s.enemy) then return end
    -- Instant `0`-tick Siege Glyph check runs BEFORE `HandleEnemyTowerSafety` (`9055695956.dem` `tk=14412` fix:
    -- `ActionImmediate_Glyph` does NOT consume our hero's unit order and works even while SF stands back at `912u`!)
    H.HandleSiegeGlyph(bot, s, earlyRace)
    if H.HandleEnemyTowerSafety(bot, s, s.enemy) then return end

    -- Throne-Grade Mid T1 Sudden-Death Defense (`BAR 9:10`), Tower-Diver Execution (`BAR 4:10`), & Low-HP Finish (`BAR 5:09`/`6:12`)
    if H.HandleCriticalAllyT1AndDivePunish(bot, s, earlyRace) then return end

    -- Top-Level Post-Kill Check BEFORE `goingToFountain` clear so an actual low-HP 0-gold reset never aborts halfway!
    if H.HandlePostKillReset(bot, s) then return end

    -- `v7.9.17` Zero-Tick Post-Raze Hit-and-Run Disengage (`auto-20261107-0354` `00:28.60, 00:41.93, 02:33.47, 02:42.40`):
    -- Immediately step straight outside Enemy's ready counter-coil (`W: 790u`, `E: 1010u`, `Q: 528u`) on tick `0` after
    -- releasing a non-lethal hero coil (`0.00s` post-cast freeze!), before `RunSacredCS` or `WarDirector` can hold `495..565u`!
    if H.HandlePostRazeDisengage(bot, s, earlyRace) then return end

    -- Urgent `< 75 MP` Combat Mango Unlock & `v7.5.0` Active-Lane Dual-Coil (`< 145 MP`) Mango Pop:
    -- `L.RunSacredCS` returns early whenever lane creeps are alive, which previously prevented `TryBackpackAmpMango`
    -- (`:8552`) from ever firing during waves! Pop 1 Mango here whenever `< 75 MP` in combat OR `< 145 MP` (`missing >= 115`)
    -- when no last-hit swing is imminent and either `enemy <= 950u` or we carry `2+` Mangoes!
    do
        local topMana = bot:GetMana() or 0
        local topMissing = (bot:GetMaxMana() or 0) - topMana
        local enDistTop = (s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive())
            and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) or 9999
        local urgentCombatPop = topMana < 75
            and (enDistTop <= 1050 or (s.enemyAlive ~= false and (s.enemyAbsentFor or 99) <= 4.0))
        -- `v7.9.21` (`auto-20261107-2214` `tk=10012` `04:22` Mango Pop During Imminent Creep CS Fix!):
        -- `L._imminentCS` was reset to `false` at `L13503` at the top of `RealThink` BEFORE `RunSacredCS` ran, so checking
        -- `not L._imminentCS` here was ALWAYS `true` and popped/walked for Mango right as a `29 HP` creep died!
        -- Query `L.HasImminentCreepCS(bot, s, 1.40)` directly!
        local hasLiveCSSoon = (L.HasImminentCreepCS and L.HasImminentCreepCS(bot, s, 1.40)) or false
        -- `v7.9.32-pro` Pro Mango Regen Discipline (`auto-20261109-0306` `0:34.63` Lvl-1 & `4:21.14` `2,400u` Waste Fix!):
        -- Keep Enchanted Mango in inventory for free `+0.4 HP/sec` passive regen whenever `topMana >= 75`, ONLY pre-popping
        -- `dualCoilLanePop` (`75 <= topMana < 145`) when `Level >= 2` with `>= 2` ready Shadowrazes inside `<= 850u` AND
        -- either `s.enemy` already carries a Shadowraze stack or sits inside 2-coil lethal/combo range (and NEVER mid-swing!).
        local dualCoilWindowNow = false
        if (not hasLiveCSSoon) and (not U.IsAttackingAction(bot)) and topMana < 145 and topMissing >= 115
            and (s.enemyAlive ~= false) and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()
            and enDistTop <= 850 and ((bot:GetLevel() or 1) >= 2) then
            local _, readyCoilsTop = K.MyReadyRazeCount(bot, false)
            if (readyCoilsTop or 0) >= 2 then
                local enStTop, enRemTop = U.GetShadowrazeDebuff(s.enemy)
                local twoCoilDmgTop = (U.GetNRazeDamage and U.GetNRazeDamage(bot, s.enemy, 2)) or 320
                local myAtkTop = K.AttackDamageVs(bot, s.enemy)
                if ((enStTop or 0) >= 1 and (enRemTop or 0) >= 1.2)
                    or ((s.enemy:GetHealth() or 9999) <= (twoCoilDmgTop + myAtkTop * 2.0 + 45)) then
                    dualCoilWindowNow = true
                end
            end
        end
        local dualCoilLanePop = dualCoilWindowNow
        if (urgentCombatPop or dualCoilLanePop) and (not U.IsAttackingAction(bot) or urgentCombatPop)
            and not bot:IsChanneling() and not bot:IsUsingAbility() then
            local immediateEmerg = urgentCombatPop and enDistTop <= 680
            local dropMode = H.GetMangoDropMode and H.GetMangoDropMode(bot, s, immediateEmerg)
                or ((not immediateEmerg) and H.IsSafeForBackpackMangoDrop(bot, s) and #(s.enemyCreeps or {}) == 0)
            if H.StartMangoPop(bot, dropMode, immediateEmerg) then
                return
            end
        end
    end

    -- Top-Level Salve Trigger & Active `modifier_flask_healing` Protection (`missingHp >= 300` -> full 100% HP!)
    if H.HandleProactiveAndActiveSalve(bot, s, earlyRace) then return end
    -- Top-Level Clarity Trigger & Active `modifier_clarity_potion` `1,055u` Outer-Raze Protection (`auto-20261102-0139` `11:46..11:50` Fix!)
    if H.HandleProactiveAndActiveClarity and H.HandleProactiveAndActiveClarity(bot, s, earlyRace) then return end

    -- Immediate Enemy `modifier_flask_healing` Breaker (`W5 07:01.7` fix: never let enemy heal +400 HP in front of us!)
    if not (L.HasImminentCreepCS and L.HasImminentCreepCS(bot, s, 1.15)) and H.HandleBreakEnemySalve(bot, s, earlyRace) then return end

    -- `0:00` Creep Wave Body-Block runs BEFORE `HandlePriorityWardPlant` (`auto-20261102-0159` `00:00..00:18` Fix #2:
    -- `HandleOpeningCreepBlock` already yields to pre-horn Ward #1 / Ward #2 while `dtime < -31.0`, and running it FIRST
    -- guarantees a leftover/aborted 2nd ward NEVER hijacks Wave #1 block at `00:00`!).
    if H.HandleOpeningCreepBlock(bot, s) then return end
    if H.HandlePriorityWardPlant(bot, s) then return end

    -- Unified WarDirector Pre-CS Reflex: ONLY guaranteed `KILL` or 0.55s pinned enemy cast-lock `PUNISH` / `ANSWER`
    -- (NEVER steals Sacred CS or blocks Salve/Retreat!)
    if H.WarDirectorPreCS(bot, s) then return end

    -- CRITICAL `v4.0.0`–`v4.2.0` FIRST-KILL `TTK` & MULTI-STACK COMBO OVERRIDE:
    -- MUST execute ABOVE `InCriticalLethalDanger` so lethal 3rd-stack `Raze3` (`Demo 2` `7:41`), 2nd-stack overlap chains
    -- (`Demo 1` `1:20` & `Demo 2` `7:13.3`), and dominant dry-mana duels (`Demo 1` `3:55`) NEVER abort to flee!
    if H.HandleActiveLethalDuelFinish(bot, s, earlyRace) then return end
    if H.HandleTurnRateAsymmetryCombo(bot, s, earlyRace) then return end
    if H.HandleMultiStackComboAndAntiBait(bot, s, earlyRace, true) then return end

    -- Stage A: Critical life & Outer-Hedge `Shadowraze3` Bait/Dodge Protection
    -- `auto-20261022-2237-start-ShaNachnetsya.dem` `05:42` (`Death #1`) Fix:
    -- If an enemy SF already closed inside point-blank `Shadowraze1` (`115..325u`), our stack timer is fresh (`> 2.5s`,
    -- preserving `S43` last-second expiry sprint!), and enemy carries `0` raze stacks while we have `>= 180 HP` and `Q` ready,
    -- fire ONE instant defensive `Snap-Q` BEFORE disengaging so we never die with `297 MP` unused (`0` inward steps)!
    if H.InCriticalLethalDanger(bot, s, earlyRace) then
        if s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive() and not bot:IsSilenced() then
            local dClose = GetUnitToLocationDistance(bot, s.enemy:GetLocation())
            local mySt, myRemT = U.GetShadowrazeDebuff(bot)
            local enSt = U.GetShadowrazeDebuff(s.enemy) or 0
            local qAb = bot:GetAbilityByName("nevermore_shadowraze1")
            local nearCrSnap = 0
            for _, ec in pairs(s.enemyCreeps or {}) do
                if U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 235 then
                    nearCrSnap = nearCrSnap + 1
                end
            end
            local outMatchedSnap = ((s.enemy:GetLevel() or 1) > (bot:GetLevel() or 1))
            local minHpSnapQ = (outMatchedSnap or nearCrSnap >= 2) and 295 or 215
            if dClose >= 115 and dClose <= 325
                and (mySt == 0 or (myRemT or 0) > 2.5)
                and enSt == 0
                and (bot:GetHealth() or 0) >= minHpSnapQ
                and (bot:GetMana() or 0) >= 75
                and qAb and qAb:GetLevel() > 0 and qAb:IsCooldownReady() then
                local eLocNow = U.PredictPosition(s.enemy, C.RAZE.CAST_POINT)
                -- Only snap-cast `Q` when ALREADY roughly facing the enemy (`<= 48 deg`) or when enemy outruns us;
                -- NEVER turn `180 deg` inside creep aggro at low HP (`auto-20261031-0230` `01:02` & `02:09` Fix!)
                local angSnap = U.GetAngleDifference(bot, eLocNow)
                local enFasterSnap = (s.enemy:GetCurrentMovementSpeed() or 305) >= (bot:GetCurrentMovementSpeed() or 305) + 20
                if angSnap <= C.RAZE.MAX_ANGLE_TO_CAST then
                    H.ManageTreads(bot, "CAST")
                    bot:Action_UseAbility(qAb)
                    H.StartRazeCast(qAb, s.enemy, eLocNow, C.RAZE.HIT_RADIUS, false)
                    H.ClearMoveCache()
                    return
                elseif angSnap <= 48 or enFasterSnap then
                    local bSnap = bot:GetLocation()
                    bot:Action_MoveToLocation(bSnap + (eLocNow - bSnap):Normalized() * 32)
                    State.actionTaken = true
                    return
                end
            end
        end
        if H.DisengageFromLethalTrade(bot, s, earlyRace) then return end
    end

    -- `auto-20261102-0007` (`8:29.57`, `10:03.97`, `10:07.53`, `10:12.07`) Zero-Turnback Retreat Continuity Gate:
    -- While critical-danger hysteresis (`critDangerHystUntil`) OR an active wounded/dry losing-trade retreat is running,
    -- NEVER fall through into `RunSacredCS` or Stage `B0` (`HandleMirrorRazeCounter` / `WarDirectorPostCS`) and spin
    -- `162..180 deg` backward toward a pursuing SF for a lane creep or poke!
    do
        local nowRet = GameTime()
        local myHpRet = bot:GetHealth() or 999
        local myMaxRet = math.max(1, bot:GetMaxHealth() or 700)
        local activeForcedFlee = (State.forcedRetreatLoc ~= nil and nowRet < (State.forcedRetreatUntil or 0))
            or (nowRet < (State.fleeUntil or 0))
        local critHystActive = nowRet < (State.critDangerHystUntil or 0)
        local severeLosingFlee = activeForcedFlee
            and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()
            and H.InLosingHeroTrade(bot, s, earlyRace)
            and ((myHpRet / myMaxRet) <= 0.48 or myHpRet <= 540 or H.IsDryVsEnemyRaze(bot, s.enemy))
        -- `v7.9.18` (`9079381960.dem` `04:19.3..04:20.3` Post-Tower-Escape River Turnback Fix):
        -- After evacuating Enemy T1 (`<= 5.0s` ago), finish crossing the river onto our own Highground before turning
        -- `180 deg` back into a higher-HP pursuing SF!
        local postT1RiverClimb = (nowRet - (State.lastTowerEscapeAt or -100)) <= 5.0
            and s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()
            and not H.IsOnOwnMidHighground(bot, bot:GetLocation())
            and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) <= 820
            and (myHpRet < (s.enemy:GetHealth() or 0) - 55 or myHpRet <= 585)
            and H.InLosingHeroTrade(bot, s, earlyRace)
        if (critHystActive or severeLosingFlee or postT1RiverClimb)
            and not (earlyRace and earlyRace.valid and (earlyRace.canKillNow or earlyRace.canKillSoon)) then
            if s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()
                and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) <= 1040 then
                if H.DisengageFromLethalTrade(bot, s, earlyRace) then return end
            end
            if H.TickForcedRetreat(bot, s) then return end
        end
    end

    -- `v7.9.11` (`2213 @ 10:54..12:59` Global Anti-Creep-Cut & Undefended `allyT1` Creep-Siege Defender!):
    -- Placed right AFTER `InCriticalLethalDanger` + `Zero-Turnback Retreat Continuity Gate` (so wounded retreats NEVER
    -- turn back into a pursuing SF!) and BEFORE `RunSacredCS`, jungle chasing, or empty-river `holdSpot`!
    if H.HandleAntiCreepCutAndT1Defense(bot, s, earlyRace) then return end

    -- `v7.9.23` (`auto-20261108-0512` `01:53.97–02:25.70` Wounded Tango Chain-Eat + Active `0.42s` Aggro-Pull Leash Drag):
    --   1. Complete an active `0.42s` defensive creep-aggro leash drag (`defAggroPullDragUntil`) BEFORE `RunSacredCS` can
    --      immediately step SF back toward the river on tick 2 (yielding instantly if any CS/deny opens within `<= 0.58s`!).
    --   2. When `modifier_tango_heal` expires while SF is still wounded (`<= 64% HP` and `missing >= 145 HP`, e.g. `317/874 HP`
    --      with `2` Tangos sitting unused for `32s`!), eat the next Tango BEFORE `RunSacredCS` / `WarDirector` hijack the tick!
    if GameTime() < (State.defAggroPullDragUntil or 0) and State.defAggroPullAnchor
        and not bot:IsUsingAbility() and not bot:IsChanneling() then
        local planDrag, etaDrag = L.PeekBestPlan(bot, s)
        if planDrag and etaDrag <= 0.58 then
            State.defAggroPullDragUntil = 0
        else
            H.SmartMove(bot, State.defAggroPullAnchor, 28)
            State.actionTaken = true
            return
        end
    end
    if not bot:IsUsingAbility() and not bot:IsChanneling()
        and not bot:HasModifier("modifier_tango_heal") and not bot:HasModifier("modifier_flask_healing")
        and not (earlyRace and earlyRace.valid and earlyRace.canKillNow) then
        local maxHpTgPre = math.max(1, bot:GetMaxHealth() or 1)
        local curHpTgPre = bot:GetHealth() or 0
        local hpPctTgPre = curHpTgPre / maxHpTgPre
        local missTgPre  = maxHpTgPre - curHpTgPre
        local minTgDef   = (C.TANGO and C.TANGO.MIN_MISSING_HP) or 105
        if missTgPre >= minTgDef and hpPctTgPre <= 0.86 and bot:FindItemSlot("item_tango") >= 0 then
            if not (L.HasImminentCreepCS and L.HasImminentCreepCS(bot, s, 0.70, true))
                and H.TryInstantAdjacentTango(bot, s) then
                return
            end
            -- `v7.9.26-pro` (`9081989180.dem` `01:25..01:45` Post-Kill Zero-CS-Loss Tango + `01:12..01:16` No-Spin Gate):
            -- Eat nearest safe tree immediately when Enemy is DEAD (`s.enemyAlive == false`) OR when wounded (`<= 64% HP`),
            -- ignoring allied denies (`ignoreDenies = true`) and proving `0` missed enemy CS via `CanEatTreeWithoutMissingCS`!
            local underOwnT1WaveTg = false
            local twReachTg = (C.BALLISTIC and C.BALLISTIC.TOWER_ATTACK_RANGE_C2C) or 870
            for _, ecTg in pairs(s.enemyCreeps or {}) do
                if ecTg and U.CanQuery(ecTg) and ecTg:IsAlive() and H.IsNearOwnT1(ecTg, twReachTg + 50) then
                    underOwnT1WaveTg = true
                    break
                end
            end
            local postKillTangoOk = (s.enemyAlive == false) and (not underOwnT1WaveTg)
                and (missTgPre >= minTgDef) and (hpPctTgPre <= 0.86)
                and not (L.HasImminentCreepCS and L.HasImminentCreepCS(bot, s, 2.20, true))
            local woundedTangoOk  = (hpPctTgPre <= 0.64) and (missTgPre >= 145)
            if (postKillTangoOk or woundedTangoOk)
                and not (L.HasImminentCreepCS and L.HasImminentCreepCS(bot, s, 0.78, true))
                and H.TryWaveSafeStaticTango(bot, s, false) then
                return
            end
        end
    end

    -- Post-Kill Rapid Wave Crash (`HUD 09:01`, `s.enemyAlive == false`) vs Equilibrium CS+Deny (`ShaNachnetsya` `00:45–01:01`):
    -- ONLY shove before `RunSacredCS` when `U.CanCrashWaveBeforeEnemyReturn(bot, s)` proves our wave will genuinely reach
    -- Enemy T1 before he respawns & TPs AND no enemy CS / instant 1-hit allied deny opens within `1.85s`!
    local waveUnderOwnT1 = false
    local ownT1ReachPK = (C.BALLISTIC and C.BALLISTIC.TOWER_ATTACK_RANGE_C2C) or 870
    for _, ec in pairs(s.enemyCreeps or {}) do
        if ec and ec:IsAlive() and H.IsNearOwnT1(ec, ownT1ReachPK) then
            waveUnderOwnT1 = true
            break
        end
    end
    local canCrashPostKill = (U.CanCrashWaveBeforeEnemyReturn and U.CanCrashWaveBeforeEnemyReturn(bot, s)) or false
    if s.enemyAlive == false and canCrashPostKill
        and not waveUnderOwnT1 and #(s.enemyCreeps or {}) > 0 then
        local planNowPK, etaNowPK = L.PeekBestPlan(bot, s)
        local eAtk = U.MergeLists(s.enemyCreeps, s.enemyTowers)
        local aAtk = U.MergeLists(s.allyCreeps, s.allyTowers)
        local oneHitDeniesPK = {}
        local tLocPK = s.enemyT1Alive and s.enemyT1Loc or nil
        local atkRPK = math.max(500, bot:GetAttackRange() or 500)
        for _, ac in pairs(s.allyCreeps or {}) do
            if U.CanQuery(ac) and ac:IsAlive()
                and (ac:GetHealth() or 9999) <= (U.SFDamageRange(bot, ac).min + 14)
                and (not tLocPK or (GetUnitToLocationDistance(ac, tLocPK) + atkRPK >= 895)) then
                oneHitDeniesPK[#oneHitDeniesPK + 1] = ac
            end
        end
        local lhNow, isDeny = L.GetBestTarget(bot, s.enemyCreeps, oneHitDeniesPK, eAtk, aAtk, false)
        local imminentCS = (planNowPK ~= nil and etaNowPK <= 1.85)
            or (lhNow ~= nil and U.GetTimeToKillable(bot, lhNow, isDeny and eAtk or aAtk) <= 1.85)
        if not imminentCS and H.HandlePriorityPush(bot, s, earlyRace) then
            return
        end
    end

    -- `v7.9.29-pro` Fadeaway Lethal-In-Air Tower Peel (`auto-20261108-2131` `04:11` Zero-Tower-Hit Execution):
    -- The instant a `0%`-miss lethal right-click projectile from `bot` is ALREADY flying toward `s.enemy` (`inFlight >= enHp + 3`
    -- from same/higher elevation) near `enemyT1` (`<= 960u`), peel back outside `915u` immediately instead of keeping
    -- `Action_AttackUnit` active and getting dragged inside `870u` tower range during projectile flight!
    if s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()
        and s.enemyT1Alive ~= false and s.enemyT1Loc then
        local bLocFade = bot:GetLocation()
        local eLocFade = s.enemy:GetLocation()
        local dT1Fade = U.DistanceBetweenLocations(bLocFade, s.enemyT1Loc)
        if dT1Fade <= 960 and ((bLocFade.z or 0) + 25 >= (eLocFade.z or 0)) then
            local inAirFade = (U.GetOwnInFlightDamageOnHero and U.GetOwnInFlightDamageOnHero(bot, s.enemy)) or 0
            if inAirFade >= (s.enemy:GetHealth() or 9999) + 3 then
                local peelDir = (bLocFade - s.enemyT1Loc):Normalized()
                bot:Action_MoveToLocation(s.enemyT1Loc + peelDir * 920)
                State.actionTaken = true
                return
            end
        end
    end

    -- Never let `RunSacredCS` steal our fatal swing onto a lane creep mid-duel (`9056469656.dem` `04:07.32` `U315` &
    -- `Demo 2` `7:40.87` `50 HP` melee creep mid-duel at `d = 355u` & `Demo 1` `3:55` `20 vs 11` soul brawl!)
    if H.HandleActiveLethalDuelFinish(bot, s, earlyRace) then return end
    if H.HandleActiveCloseHeroBrawlAndAntiZone(bot, s, earlyRace, true, false) then return end

    -- `01:35.1–01:36.5` (`tk=6288..6332` `214 HP / 9 MP`) + `2204 @ 03:05` (`188..207 HP / 65 MP` with `ec = 3`)
    -- + `2204 @ 02:20..03:49` Dominant Anti-Reaggro Wave-Shield Fix:
    --   1. Ready in-band Shadowraze on a crippled OOM enemy (`<= 265 HP`, `< 75 MP`) fires BEFORE `RunSacredCS` regardless
    --      of `#enemyCreeps` (spells do NOT pull creep aggro, whereas `RunSacredCS` otherwise kites creeps & returns `true`!).
    --   2. When dominating the lane (`U.IsLaneDominant`) and no CS/deny needs our swing within `<= 0.55s`, immediately
    --      punish & screen any weaker enemy SF stepping within `<= 665u` of our allied wave to pull creep aggro!
    if s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive() then
        local myHpPre = bot:GetHealth() or 0
        local myEffPre = myHpPre + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(bot)) or 0)
        local inFlightPre = (U.GetOwnInFlightDamageOnHero and U.GetOwnInFlightDamageOnHero(bot, s.enemy)) or 0
        local enHpDry = math.max(1, (s.enemy:GetHealth() or 9999) - inFlightPre)
        local enMpDry = (s.enemy:GetMana() or 0) + U.GetMangoMana(s.enemy)
        local dDry = GetUnitToLocationDistance(bot, s.enemy:GetLocation())
        local myAtkPre = K.AttackDamageVs(bot, s.enemy)
        local oneHitCreep = false
        for _, ec in pairs(s.enemyCreeps or {}) do
            if U.CanQuery(ec) and ec:IsAlive() and (ec:GetHealth() or 999) <= (U.SFDamageRange(bot, ec).min + 12) then
                oneHitCreep = true
                break
            end
        end
        local myBootsLeadPre = (bot:GetCurrentMovementSpeed() or 305) >= ((s.enemy:GetCurrentMovementSpeed() or 305) + 25)
        local oneShotDryPre = (enMpDry < 75) and (enHpDry <= myAtkPre * 1.15)
        local healthyTwoHitPre = (myHpPre >= 460) and (enHpDry <= math.max(115, myAtkPre * 1.98))
        local dryFinishOk = myEffPre >= 260 and (bot:GetMana() or 0) >= 75
            and enHpDry <= 265 and enMpDry < 75 and dDry <= 965
        local ultraCritFinishOk = (#(s.enemyCreeps or {}) <= ((myBootsLeadPre or oneShotDryPre or healthyTwoHitPre) and 3 or 2))
            and (enHpDry <= math.max(115, myAtkPre * (myBootsLeadPre and 2.45 or 1.98)))
            and dDry <= ((myBootsLeadPre or oneShotDryPre) and 1520 or 1180)
            and ((enMpDry < 75 and myEffPre >= math.max(150, K.AttackDamageVs(s.enemy, bot) * 2.55))
                or (myHpPre >= K.EnemyBurstVs(bot, s.enemy, dDry, 1.0, false) + 125 and myHpPre >= 360))
        local inRangeCrippledOk = (dDry <= ((bot:GetAttackRange() or 500) + 25))
            and (enHpDry <= math.max(225, myAtkPre * 3.85))
            and (myHpPre >= math.max(360, enHpDry + 185))
        if (not oneHitCreep or enHpDry <= myAtkPre) and (dryFinishOk or ultraCritFinishOk or inRangeCrippledOk) then
            if H.HandlePressCriticallyLowEnemy(bot, s, earlyRace, false) then
                return
            end
        end

        if not oneHitCreep then
            local csPlanDom, csEtaDom = nil, 99
            if L.PeekBestPlan then
                csPlanDom, csEtaDom = L.PeekBestPlan(bot, s)
            end
            local rightClickLocksCS = (L.WouldRightClickLockoutCS and L.WouldRightClickLockoutCS(bot, s)) or false
            local csUrgentDom = rightClickLocksCS or ((csPlanDom ~= nil) and (csEtaDom <= 0.65))
            local csUrgentPro = rightClickLocksCS or ((csPlanDom ~= nil) and (csEtaDom <= 0.72))
            local csUrgentPull = rightClickLocksCS or ((csPlanDom ~= nil) and (csEtaDom <= 0.75))
            if not csUrgentPull and H.HandleEarlyAggroPullPunish(bot, s, earlyRace, false) then
                return
            end
            if not csUrgentDom and H.HandleDominantAntiReaggroZone(bot, s, earlyRace, false) then
                return
            end
            if not csUrgentPro and H.HandleTurnRateAsymmetryCoil(bot, s, earlyRace, false) then
                return
            end
            if not csUrgentPro and H.HandleProactiveZoneCoilAndFeint(bot, s, earlyRace, false) then
                return
            end
        end
    elseif s.enemyAlive ~= false and (s.enemyLastHealth or 9999) <= 265 then
        local oneHitCreepFow = false
        for _, ec in pairs(s.enemyCreeps or {}) do
            if U.CanQuery(ec) and ec:IsAlive() and (ec:GetHealth() or 999) <= (U.SFDamageRange(bot, ec).min + 10) then
                oneHitCreepFow = true
                break
            end
        end
        -- `v7.9.29-pro` (`auto-20261108-2131` `04:10.23..04:11.8` `32 HP` Enemy Hero vs `46 HP` Ranged Creep `E1662` Fix!):
        -- At equal `305` MS, stopping `0.50s` for a creep last-hit permanently surrenders `+152u` of separation and lets a
        -- `32..135 HP` enemy hero escape alive! Never let `oneHitCreepFow` block pursuing a lethal/1-2-hit enemy within `640u`!
        local myAtkFowPre = bot:GetAttackDamage() or 65
        local dLastFowPre = s.enemyLastLoc and U.DistanceBetweenLocations(bot:GetLocation(), s.enemyLastLoc) or 9999
        local urgentKillFow = ((s.enemyLastHealth or 9999) <= math.max(145, myAtkFowPre * 1.75))
            and (dLastFowPre <= 640)
            and ((s.enemyAbsentFor or 99) <= 1.8)
            and ((bot:GetHealth() or 0) >= 340)
        if (not oneHitCreepFow or (s.enemyLastHealth or 9999) <= myAtkFowPre * 1.15 or urgentKillFow)
            and H.HandleFoWLowHpAndBootsPursuit(bot, s, earlyRace) then
            return
        end
    end

    -- Never cancel an active near-launch hero right-click (`ShouldHoldForHeroWindup`) UNLESS an enemy lane creep CS
    -- genuinely needs firing inside `<= 0.24s` (`L.PeekBestPlan` exact 30Hz check — fixes `00:55.80–01:03.27` 8x cancels)!
    if s.enemy and U.CanQuery(s.enemy) and H.ShouldHoldForHeroWindup(bot, s, s.enemy, earlyRace) then
        local csPlanHold, csEtaHold = L.PeekBestPlan(bot, s)
        local myAtkHold = K.AttackDamageVs(bot, s.enemy)
        local heroNearLethal = (s.enemy:GetHealth() or 9999) <= (myAtkHold * 2.35)
        local criticalCreepNow = (not heroNearLethal)
            and (csPlanHold ~= nil) and (not csPlanHold.isDeny) and (csEtaHold <= 0.24)
        if not criticalCreepNow then
            State.actionTaken = true
            return
        end
    end

    -- `v7.9.24-pro` (`auto-20261108-1523` `07:22.47..07:50.73` `14 HP` Radiant T1 Endgame Finish):
    -- Finishing a `<= 3`-hit Enemy T1 (visible OR FoW `s.enemyT1LastHp`) wins the 1v1 game immediately and MUST
    -- outrank `RunSacredCS` so fresh creep spawns NEVER pull SF off a `14 HP` (`1`-hit) tower!
    if H.HandleEnemyTowerFinish(bot, s, s.enemy) then return end

    local csRazeHook = function(ab, targetCreep, rSpot, radius, isCS, mustHitHero)
        H.ManageTreads(bot, "CAST")
        bot:Action_UseAbility(ab)
        H.StartRazeCast(ab, targetCreep, rSpot, radius or C.RAZE.HIT_RADIUS, isCS ~= false, mustHitHero)
        H.ClearMoveCache()
    end
    local csActed, csWaveBusy = L.RunSacredCS(bot, s, earlyRace, P, csRazeHook)
    if csActed then
        if not H.IsAtFountain(bot) and State.fountainReason ~= "POST_KILL" then
            State.goingToFountain = false
        end
        State.actionTaken = true
        return
    end

    -- Shielded Enemy T1 Siege Priority (`9056774541.dem` `01:45` + `auto-20261102-0159.dem` Fix #7):
    -- Whenever `RunSacredCS` has NO active CS/deny window right now (`not csActed`), hit enemy T1 under creep shield EVEN IF
    -- fresh full-HP enemy creeps just spawned behind T1 (`#enemyCreeps > 0`) OR the enemy hero retreated `850..1,400u` behind T1!
    if U.CanQuery(s.enemyT1) and #(s.allyCreeps or {}) >= 1 then
        local enemyBehindT1 = H.IsEnemyBehindOwnTower(bot, s.enemy, s.enemyT1:GetLocation())
            and (not (s.enemy and U.CanQuery(s.enemy)) or s.enemy:GetHealth() > U.GetNRazeDamage(bot, s.enemy, 1) + 40)
        local dominantChip = s.enemy and U.CanQuery(s.enemy)
            and (bot:GetHealth() or 0) >= math.max(700, (s.enemy:GetHealth() or 9999) + 360)
            and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) >= 640
        if (enemyBehindT1 or dominantChip) and H.HandleSiegeTower(bot, earlyRace, s) then
            State.actionTaken = true
            return
        end
    end

    -- Hold active hero windup BEFORE lower combat stages (`9056774541.dem` `03:29–03:33` `tk=13526..13628`):
    if s.enemy and U.CanQuery(s.enemy) and H.ShouldHoldForHeroWindup(bot, s, s.enemy, earlyRace) then
        return
    end

    -- Stage B0 (`v6.6.0`: Multi-Stack Combo, Mirror Counter-Raze, WarDirector Post-CS Tactical, Enemy CS-Windup Punish,
    -- `500u` Zero-Aggro Harass Trick, Stand-Ground Anti-Zoning, Dry-Enemy/Soul-Lead Harass, Retaliation, & Deward):
    local imminentCreepCS = L._imminentCS and true or false
    if H.HandleBreakEnemySalve(bot, s, earlyRace) then return end
    if H.HandleEarlyAggroPullPunish(bot, s, earlyRace, imminentCreepCS) then return end
    if not imminentCreepCS and H.HandleFoWLowHpAndBootsPursuit(bot, s, earlyRace) then return end
    if H.HandleDominantAntiReaggroZone(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleTurnRateAsymmetryCoil(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleProactiveZoneCoilAndFeint(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleMultiStackComboAndAntiBait(bot, s, earlyRace, false) then return end
    if H.HandleMirrorRazeCounterAndDryPunish(bot, s, earlyRace, imminentCreepCS) then return end
    -- `v7.9.18` Stage B0 Highground Right-Click Dominance (`100%` hit vs lowground enemy's `25%` uphill miss!):
    if H.HandleHighgroundZeroAggroHarass(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleDefensiveCreepAggroPull(bot, s, earlyRace, imminentCreepCS) then return end
    -- `v7.9.16` (`auto-20261107-0255` `01:04.80..01:08.87` Multi-Creep Aggro Shield Priority):
    -- When `>= 2` enemy lane creeps are actively aggroed on SF (or `State.creepKiteUntil` is active), execute
    -- `HandleCreepTankDrop` BEFORE `WarDirectorPostCS` / `HandlePressCriticallyLowEnemy` unless the enemy hero
    -- is in immediate 2-hit physical or 1-coil lethal execution range!
    do
        local aggroB0 = (U.CountEnemyCreepsAggroedOnBot and U.CountEnemyCreepsAggroedOnBot(bot, s, State.myCreepChaseUntil)) or 0
        local kiteLockB0 = (State.creepKiteUntil and GameTime() < State.creepKiteUntil) or false
        if aggroB0 >= 2 or kiteLockB0 then
            local immediateKillB0 = false
            if s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive() then
                local inFlightB0 = (U.GetOwnInFlightDamageOnHero and U.GetOwnInFlightDamageOnHero(bot, s.enemy)) or 0
                local enEffB0 = math.max(1, (s.enemy:GetHealth() or 9999) - inFlightB0) + (U.GetStickCharges(s.enemy) * 15)
                local myAtkB0 = K.AttackDamageVs(bot, s.enemy)
                local myHpB0 = bot:GetHealth() or 0
                local killMultB0 = (myHpB0 >= 460 and aggroB0 <= 2) and 2.25 or 1.90
                local oneCoilB0 = ((bot:GetMana() or 0) >= 75 and not bot:IsSilenced() and K.MyReadyRazeCount(bot, false) >= 1)
                    and U.GetNRazeDamage(bot, s.enemy, 1) or 0
                immediateKillB0 = (enEffB0 <= math.max(115, myAtkB0 * killMultB0))
                    or (oneCoilB0 > 0 and enEffB0 <= oneCoilB0 + myAtkB0 * 0.90
                        and GetUnitToLocationDistance(bot, s.enemy:GetLocation()) <= 835)
            end
            if not immediateKillB0 and H.HandleCreepTankDrop(bot, s) then return end
        end
    end
    if H.WarDirectorPostCS(bot, s, imminentCreepCS) then return end
    if H.HandlePressCriticallyLowEnemy(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleCreepTankDrop(bot, s) then return end

    -- Stage B: Losing trade / dry-mana / uphill-aggro disengage — MUST gate ALL right-click harass handlers below
    -- (`9069188041.dem` `02:11.8` + `9071946472.dem` `03:39–03:45` Fix: honor active `TickForcedRetreat` BEFORE poke/harass!)
    if not imminentCreepCS and H.TryInstantAdjacentTango(bot, s) then return end
    if H.InLosingHeroTrade(bot, s, earlyRace) then
        if H.DisengageFromLethalTrade(bot, s, earlyRace) then return end
    end
    if s.enemy and H.HandleDryManaMidRazeAvoidance(bot, s.enemy) then
        H.TickForcedRetreat(bot, s)
        return
    end
    if H.TickForcedRetreat(bot, s) then return end

    if H.HandleEnemyCSWindupPunish(bot, s, earlyRace, imminentCreepCS) then return end
    if not imminentCreepCS and H.HandleNightVisionAdvantagePoke(bot, s, earlyRace) then return end
    if H.HandleHighgroundZeroAggroHarass(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleProAggroTrickHarass(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleActiveCloseHeroBrawlAndAntiZone(bot, s, earlyRace, false, imminentCreepCS) then return end
    if H.HandleDryEnemyAndSoulLeadHarass(bot, s, earlyRace, imminentCreepCS) then return end
    if H.HandleAntiFreeHarassRetaliation(bot, s, earlyRace) then return end
    if not imminentCreepCS and H.HandlePumpFakeBait(bot, s, earlyRace) then return end
    if H.HandleFreeEnemyWardDeward(bot, s) then return end

    -- Instant `0`-tick Mango pop FIRST, then Wave-safe Static-Tree Tango (run BEFORE empty-wave `holdSpot`!)
    if H.TryBackpackAmpMango(bot, s) then return end
    if H.TryWaveSafeStaticTango(bot, s, csWaveBusy) then return end

    -- Preserve active forced/survival retreat BEFORE empty-wave holdSpot WITH Zero-Stall Arrival check!
    if H.TickForcedRetreat(bot, s) then return end
    if State.survivalLoc and GameTime() < (State.survivalUntil or 0) then
        if U.DistanceBetweenLocations(bot:GetLocation(), State.survivalLoc) <= 65 then
            if U.IsAttackingAction(bot) then
                bot:Action_ClearActions(true)
            end
            State.actionTaken = true
            return
        else
            H.SmartMove(bot, State.survivalLoc, 60)
            return
        end
    end

    -- Deep-Retreat Fountain Commitment (`auto-20261031-1939` `07:13` `(2393, 2251)` behind Dire T2 at `212/1100 HP` Fix!):
    -- When ALREADY `>= 1500u` behind Mid T1 toward Fountain at `<= 36% HP` with 0 Salve/Tango (and live non-crippled enemy),
    -- finish the short ~10s walk into Fountain aura for a FREE 100% HP/MP heal instead of wiping `goingToFountain` at `>= 105 HP`
    -- and letting empty `1600u` creep lists march SF `2,500u` back to mid at `249 HP` to die!
    H.ShouldCommitDeepFountainWalk(bot, s)
    if State.emergencyRetreat == "FOUNTAIN" and H.HandleEmergencyRetreat(bot, s.enemy) then
        return
    end

    -- Outside Fountain: never abandon mid lane on a 7,000-unit walk from the river unless critically `< max(115, 18% MaxHP)`
    -- (`0210 @ 10:40` `182/1408 HP = 12.9% HP` Scaling Fix!), committed `POST_KILL`, `EMERGENCY`, or `DEEP_LOW_HP`!
    local critFlatFloor = math.max(115, (bot:GetMaxHealth() or 600) * 0.18)
    if not H.IsAtFountain(bot) and (bot:GetHealth() or 0) >= critFlatFloor
        and State.fountainReason ~= "POST_KILL"
        and State.fountainReason ~= "DEEP_LOW_HP"
        and State.fountainReason ~= "EMERGENCY" then
        State.goingToFountain = false
    end
    if State.goingToFountain and (State.fountainReason == "DEEP_LOW_HP" or State.fountainReason == "EMERGENCY" or State.fountainReason == "HP") then
        if H.HandleFountainRecall(bot) then return end
    end

    -- Between waves (0 visible lane creeps): hold crisp mid equilibrium / T1 highground instead of walking to base —
    -- UNLESS we are actively dominating / finishing a live enemy hero right in front of us after wave clear
    -- (`9055695956.dem` `7:05` `tk=15836`: waves just died to razes at `519u` while BOT was Level 7 vs Level 5 —
    -- returning early here walked BOT `1,300u` back to `Vector(395, 405)` mid-fight instead of killing `ShaNachnetsya`!)
    -- `9070869385.dem` `04:05.8–04:06.6` (`13 HP` Uphill FoW Ramp Escape) Fix:
    -- When a 1-hit enemy hero (`<= 95 HP`) just stepped onto the enemy river ramp into highground FoW (`s.enemy == nil`,
    -- `enemyAbsentFor <= 2.4s`, `enemyLastLoc` strictly outside Enemy T1 `>= 915u`), step toward `enemyLastLoc` to
    -- regain highground vision and land the fatal attack/raze instead of walking back to `holdSpot`!
    if H.HandleFoWLowHpAndBootsPursuit(bot, s, earlyRace) then
        return
    end

    local enemyUnreachableUnderT1 = s.enemy and U.CanQuery(s.enemy)
        and (State.towerChaseBlockedEnemy == s.enemy
            or (s.enemyT1Alive ~= false and s.enemyT1Loc
                and U.DistanceBetweenLocations(s.enemy:GetLocation(), s.enemyT1Loc) < 520
                and #(s.allyCreeps or {}) == 0
                and (s.enemyDist or 9999) > ((bot:GetAttackRange() or 525) + 30)))
    local fightingEnemyInLane = s.enemy and U.CanQuery(s.enemy) and s.enemy:IsAlive()
        and (not enemyUnreachableUnderT1)
        and (s.enemyDist or 9999) <= (((s.enemy:GetHealth() or 9999) <= 115 and (bot:GetHealth() or 0) >= 420) and 1320 or 1050)
        and (H.CanTwoHitRightClickKill(bot, s.enemy, s)
            or ((s.enemy:GetHealth() or 9999) <= 115 and (bot:GetHealth() or 0) >= 420)
            or (((bot:GetLevel() or 1) > (s.enemy:GetLevel() or 1)) and (bot:GetHealth() or 0) >= 620
                and not (earlyRace and earlyRace.valid and earlyRace.heCanKillSoon))
            or (earlyRace and earlyRace.valid and (earlyRace.canKillNow
                or (earlyRace.canKillSoon and not earlyRace.heCanKillSoon and (earlyRace.edge or 0) >= 40)
                or ((s.enemyDist or 9999) <= 560 and not earlyRace.heCanKillSoon and (earlyRace.edge or 0) >= 25))))
    if not fightingEnemyInLane and H.HandleMidGameIdleCreepBlock(bot, s, earlyRace) then
        return
    end
    -- `v7.9.12-pro` (`2319` Staircase Wave-Freeze Advance):
    -- MUST run BEFORE the `#s.enemyCreeps == 0 and #s.allyCreeps == 0` (`1,600u` engine cap!) `holdSpot` early return!
    if H.HandleAdvanceToDistantMidWave(bot, s, earlyRace) then
        return
    end
    if not fightingEnemyInLane and not State.emergencyRetreat and not State.goingToFountain
        and #(s.enemyCreeps or {}) == 0 and #(s.allyCreeps or {}) == 0
        and not s.hasDistantMidWaveClash
        and (bot:GetHealth() or 0) >= critFlatFloor then
        if H.TrySafeTreadsSwitch(bot, nil) then return end
        local curHpPctHold = (bot:GetHealth() or 0) / math.max(1, bot:GetMaxHealth() or 600)
        local holdSpot
        if s.enemyAlive ~= false and curHpPctHold <= 0.28 and not U.HasAnyHealing(bot) then
            holdSpot = (P.GetBehindT1 and P.GetBehindT1(bot, 380)) or P.GetLasthitPosition(bot, {}, {}, nil, "NEUTRAL")
        else
            holdSpot = P.GetLasthitPosition(bot, {}, {}, nil, "NEUTRAL")
        end
        if holdSpot and U.DistanceBetweenLocations(bot:GetLocation(), holdSpot) > 55 then
            H.SmartMove(bot, holdSpot, 45)
        end
        State.actionTaken = true
        return
    end

    if H.HandleSurvivalRetreat(bot, s.enemy, earlyRace) then return end

    if H.HandleShortCombatCast(bot,s.enemy,s) then return end
    if H.HandleSafeRazeReply(bot,s.enemy,s) then return end
    if H.HandleReplyFarFollowup(bot,s.enemy,s) then return end
    if H.HandleManaCycleContinuation(bot,s.enemy,s) then return end
    if H.HandleContactTrade(bot,s.enemy,s) then return end
    -- Free pressure: both handlers veto themselves in every risky or busy situation
    -- (retreat, fountain, low HP, tower, lethal burst, imminent last hit, aimed raze).
    if H.HandleFreeRazeAnswer(bot,s,earlyRace,true) then return end
    if H.HandleFreeRightClick(bot,s,earlyRace) then return end

    -- A committed retreat owns the tick WITH Zero-Stall Arrival check!
    if H.TickForcedRetreat(bot, s) then return end

    if (bot:GetHealth() or 0) < critFlatFloor and H.HandleSurvivalRetreat(bot, s.enemy, earlyRace) then return end
    if H.HandleSeekAlliedWave(bot, s, earlyRace) then return end
    if (not csWaveBusy or s.enemyAlive == false) and H.HandlePriorityPush(bot, s, earlyRace) then return end
    if H.UpdateTowerChase(bot, s) then return end
    local stackChaseSafe = not (earlyRace and earlyRace.valid
        and (earlyRace.losingHard or earlyRace.heHasBootsLead or ((s.enemy and s.enemy:GetLevel() or 1) > (bot:GetLevel() or 1))))
        and (bot:GetHealth() or 0) >= (bot:GetMaxHealth() or 1) * 0.55
    if stackChaseSafe and H.HandleStackLead(bot, s, earlyRace) then return end
    H.UpdateDefensive(bot, s, earlyRace)
    State.enemyAggroCount = 0
    for _, creep in pairs(s.allyCreeps or {}) do
        if s.enemy and U.CanQuery(creep) and creep:GetAttackTarget() == s.enemy then
            State.enemyAggroCount = State.enemyAggroCount + 1
        end
    end
    State.combatPolicyActive = true
    local xchAllowsVoluntaryEngage = GameTime() >= (WD.State.refuseTradeUntil or -100)
    State.heroCombatAllowed = State.towerChaseBlockedEnemy ~= s.enemy
        and ((xchAllowsVoluntaryEngage and H.ShouldEngageHero(bot, s.enemy, earlyRace))
            or H.IsEnemyPressuring(bot, s.enemy)
            or (earlyRace.valid and earlyRace.canKillNow))
    if H.HandleIncomingHeroPressure(bot, s, earlyRace) then return end
    if State.heroCombatAllowed and not State.goingToFountain
        and GameTime() >= (State.fleeUntil or 0) then
        local previous = State.intent
        State.intent = I.TRADE
        local acted = H.RunCombatPriority(bot, s, earlyRace)
        State.intent = previous
        if acted then return end
    end

    if H.HandleActiveRazeValidation(bot) then return end

    -- A guaranteed finish comes before dodging and everything else: if we can kill
    -- him with a raze/click right now - kill immediately, do not postpone it for seconds
    if s.enemy then
        if H.HandleGuaranteedRazeKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
        if H.HandleGuaranteedAttackKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
    end

    -- Dodging the enemy raze outranks even our own cast (if the raze is lethal)
    if H.HandleEnemyRazeDodge(bot, s.enemy) then return end

    if bot:IsUsingAbility() then return end

    H.ProcessTelemetry(bot)

    -- Power Treads are handled by H.ManageTreads - on an idle tick (end of RealThink),
    -- on the first retreat tick (strength) and on the tick before a raze cast (intelligence). The old call
    -- here issued a switch order EVERY tick and overrode the combat orders.

    local enemyHero = s.enemy

    -- The race (absolute HP, razes available to both sides) and the intent for the tick
    local race = earlyRace
    local intent = H.UpdateIntent(bot, s, race)

    -- A swing at the hero is in progress - let it land (see ShouldHoldForHeroWindup)
    H.UpdateAttackActivity(bot)
    if enemyHero and H.ShouldHoldForHeroWindup(bot, s, enemyHero, race) then
        State.actionTaken = true
        return
    end

    -- Emergency consumables (faerie/wand/mango for a finish) - right after the swing,
    -- before salves and retreats
    if H.HandleEmergencyConsumables(bot, race) then return end

    if H.HandleActiveSalveSafety(bot, enemyHero) then return end
    if H.HandleEnemyNearRazeCounter(bot, enemyHero) then return end
    if enemyHero and H.HandleInstantMirrorRaze(bot, enemyHero, race, s) then return end

    if bot:GetLevel() >= 2 then
        State.enemyReachedLevel2First = false
    end
    if enemyHero and U.CanQuery(enemyHero) and U.EnemyHasRaze(enemyHero) then
        if bot:GetLevel() < 2 and enemyHero:GetLevel() >= 2 then
            State.enemyReachedLevel2First = true
        end
    end

    -- (Guaranteed finishes moved up - before dodging and the swing)
    if H.HandleReturnTP(bot) then return end

    -- Defence against the enemy T1 - before everything else
    if H.HandleEnemyTowerSafety(bot, s, enemyHero) then return end

    -- The enemy T1 is nearly down - finish it before any retreat or last hit
    if H.HandleEnemyTowerFinish(bot, s, enemyHero) then return end

    if H.HandleEmergencyRetreat(bot, enemyHero) then return end

    -- RETREAT intent: get out of the enemy's ready bands (his available burst is lethal)
    if intent == I.RETREAT and enemyHero then
        if H.ExecuteRetreat(bot, enemyHero, race) then return end
    end

    if H.HandleForcedSalve(bot) then return end
    if H.HandleFountainRecall(bot) then return end

    -- The intent is still RETREAT but we are already at a safe distance (ExecuteRetreat
    -- returned false). Previously control fell through to last hits/prehit - those turned
    -- the bot toward the creep pack, the enemy caught up, run again - a crooked zigzag instead of leaving.
    -- Keep a clean step straight away from the enemy while he is near.
    if intent == I.RETREAT and enemyHero and U.CanQuery(enemyHero) and not State.actionTaken then
        local bLoc, eLoc = bot:GetLocation(), enemyHero:GetLocation()
        local d = U.DistanceBetweenLocations(bLoc, eLoc)
        if d < 1100 and d >= 1 then
            H.SmartMove(bot, bLoc + (bLoc - eLoc):Normalized() * 160, 60)
            return
        end
    end

    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    local mpPct = bot:GetMana() / bot:GetMaxMana()
    local flask = U.GetActiveItemByName(bot, "item_flask")
    local clarity = U.GetActiveItemByName(bot, "item_clarity")
    local hasMango = U.HasItem(bot, "item_enchanted_mango")
    local isHealing = bot:HasModifier("modifier_flask_healing")
    local returnHpPct = (C.TP and C.TP.RETURN_HP_PCT) or 0.50

    if bot:HasModifier("modifier_clarity_potion") and not bot:HasModifier("modifier_flask_healing") and myHpPct >= returnHpPct then
        H.ClearForcedRetreat()
    end

    -- `H.HandleProactiveAndActiveSalve` and `H.HandleProactiveAndActiveClarity` now govern 100% of Salve/Clarity usage & protection!
    local needsFlask = false
    local needsClarity = false

    if isHealing or needsFlask or needsClarity then
        local fountain = P.GetFountain(bot)
        local dangerRange = 850
        if enemyHero and enemyHero:GetUnitName() == "npc_dota_hero_nevermore" then
            if bot:HasModifier("modifier_flask_healing") or needsFlask then
                dangerRange = C.REGEN.FLASK_SAFE_DISTANCE or 1150
            else
                dangerRange = C.REGEN.ENEMY_SAFE_DISTANCE or 1100
            end
        end
        if H.IsInDangerForRegen(bot, dangerRange) then
            local moveLoc = P.GetT1Close(bot)
            if enemyHero then
                local dir = (fountain - enemyHero:GetLocation()):Normalized()
                moveLoc = enemyHero:GetLocation() + dir * dangerRange
            end
            H.BeginForcedRetreat(bot, moveLoc, 0.85)
            return
        end
        if needsFlask and GameTime() > State.lastItemUseTime + 0.3 then
            if H.HasEnemyProjectileIncoming(bot) then
                local safeLoc = H.GetSalveSafeRetreatLocation(bot, enemyHero)
                H.BeginForcedRetreat(bot, safeLoc, 0.65)
                return
            end
            bot:Action_UseAbilityOnEntity(flask, bot)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return
        elseif needsClarity and GameTime() > State.lastItemUseTime + 0.3 then
            bot:Action_UseAbilityOnEntity(clarity, bot)
            State.lastItemUseTime = GameTime()
            return
        elseif isHealing then
            -- Lists from the world snapshot (filtered through CanQuery - no creeps in fog)
            local enemyCreepsNearby = s.enemyCreeps or {}
            local allyCreepsNearby = s.allyCreeps or {}
            if #allyCreepsNearby == 0 then
                local targetPos = P.GetT1Close(bot)
                if GetUnitToLocationDistance(bot, targetPos) > 45 then
                    H.SmartMove(bot, targetPos, 60)
                end
            elseif bot:HasModifier("modifier_flask_healing") then
                local safeLoc = P.GetLasthitPosition(bot, enemyCreepsNearby, allyCreepsNearby, nil, "PASSIVE")
                if enemyHero and U.CanQuery(enemyHero) then
                    local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
                    if distToEnemy < dangerRange then
                        local dir = (fountain - enemyHero:GetLocation()):Normalized()
                        safeLoc = enemyHero:GetLocation() + dir * dangerRange
                    end
                end
                if not H.IsInDangerForRegen(bot, dangerRange) then
                    H.SmartMove(bot, safeLoc, 60)
                end
            end
            if State.actionTaken or #allyCreepsNearby == 0 or bot:HasModifier("modifier_flask_healing") then return end
        end
    end

    local enemyCreeps = s.enemyCreeps
    local allyCreeps = s.allyCreeps
    local enemyTowers = s.enemyTowers
    local allyTowers = s.allyTowers
    local enemyAttackers = U.MergeLists(enemyCreeps, enemyTowers)
    local allyAttackers = U.MergeLists(allyCreeps, allyTowers)
    -- The enemy hero also hits creeps (finishes his own = deny, finishes mine). His attack
    -- is accounted for in the target HP forecast (GetAttackTarget() == target): the "safe" last-hit window
    -- closes with his attack -> hit earlier/immediately instead of waiting for a moment he takes.
    if enemyHero and U.CanQuery(enemyHero) then
        table.insert(enemyAttackers, enemyHero)
        table.insert(allyAttackers, enemyHero)
    end
    local enemyNearWave = enemyHero ~= nil and s.enemyDist <= 1300

    U.UpdateAllyCreepHealthTracking(allyCreeps)


    local current_mode = U.GetPlaystyle(bot, enemyHero, allyCreeps, enemyCreeps)
    if State.defensive then current_mode = "PASSIVE" end
    local enemyMissed = U.HasEnemyMissedRazeRecently()
    local enemyMissedAggro = enemyMissed and bot:GetLevel() > 1
    if bot:GetLevel() <= 1 and enemyMissed and current_mode == "AGGRESSIVE" then
        current_mode = "NEUTRAL"
    end

    if H.HandleGlyph(bot, enemyHero, enemyTowers, allyTowers, allyCreeps) then return end
    if H.HandleEnemyT1WaveDriftRetreat(bot, enemyHero, enemyTowers, allyCreeps, enemyCreeps) then return end

    local inKillThreat = U.IsInEnemyRazeKillThreat(bot, enemyHero)
    local secondStackActive, secondStackLabel = false, nil
    if enemyHero then
        secondStackActive, secondStackLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    end

    if enemyHero and secondStackActive and secondStackLabel == "near" then
        if H.HandleNearRazeReplyPressure(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if inKillThreat then
        if H.HandleSafeDistanceFromEnemy(bot, enemyHero) then return end
    end

    U._midFear = (enemyHero ~= nil) and H.MidRazeFearActive(bot, enemyHero) or false
    if enemyHero and H.HandleEnemyLevel2FirstMidRazeFear(bot, enemyHero) then return end
    if enemyHero and H.HandleDryManaMidRazeAvoidance(bot, enemyHero) then return end

    -- Stacks on us: the decision is based on the enemy's available burst and absolute HP (not "2 stacks = run").
    -- If his razes are on cooldown / out of mana / the band is out of reach - keep pressing.
    if enemyHero then
        local shouldFear, fearLoc = U.ShouldRetreatFromEnemyRazeStack(bot, enemyHero)
        if shouldFear and fearLoc then
            H.BeginForcedRetreat(bot, fearLoc, 0.80)
            return
        end
    end

    if enemyHero and H.HandleBootDisadvantageMidRazeFear(bot, enemyHero) then return end

    local mustRetreatFromT1Soon = U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero)
    if not mustRetreatFromT1Soon and s.enemyT1 then
        -- The shield is gone (creeps ran off after the enemy / died) and we are still inside the tower radius
        local okLoc, tLoc = pcall(s.enemyT1.GetLocation, s.enemyT1)
        if okLoc and tLoc and U.DistanceBetweenLocations(tLoc, bot:GetLocation()) <= ((C.TOWER and C.TOWER.SAFE_RADIUS) or 780) then
            if LN.TowerDanger(bot, s.enemyT1, allyCreeps, nil) >= 2 then
                mustRetreatFromT1Soon = true
            end
        end
    end
    if mustRetreatFromT1Soon and not H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps)
        and not (s.enemyT1 and LN.IsTowerFinishable(bot, s.enemyT1)) then
        -- Do NOT spend the glyph just to get out of the tower (an accidental entry into the T1 radius without a finish
        -- burned the glyph for 5 minutes) - just walk out
        local safeLoc = H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
        H.BeginForcedRetreat(bot, safeLoc, 0.85)
        return
    end

    if enemyHero and not inKillThreat then
        if H.HandleImmediateNearRazePunish(bot, enemyHero, current_mode, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and H.GetPotentialCombatMana(bot) >= 150 and not inKillThreat then
        local q = bot:GetAbilityByName("nevermore_shadowraze1")
        if q and q:GetLevel() > 0 then
            local dmg2 = U.GetTwoRazeDamage(bot, enemyHero)
            local lethal = dmg2 >= enemyHero:GetHealth()
            local Rr = K._race
            if Rr and Rr.valid then
                -- Only razes that are REALLY available (cooldowns/mana), not "two razes by formula"
                lethal = Rr.canKillSoon
            end
            if intent == I.RETREAT then lethal = false end
            if lethal then
                local myBoots = U.HasItem(bot, "item_boots") or U.HasItem(bot, "item_power_treads")
                local eBoots = U.HasItem(enemyHero, "item_boots") or U.HasItem(enemyHero, "item_power_treads")
                local canChase = myBoots and not eBoots
                local chaseTargetLoc = enemyHero:GetLocation()
                local isSafeChase = true
                for _, tower in pairs(enemyTowers) do
                    if tower:IsAlive() then
                        local name = tower:GetUnitName() or ""
                        if name:find("tower2") or name:find("tower3") or name:find("tower4") then
                            if GetUnitToLocationDistance(tower, chaseTargetLoc) < 850 then
                                isSafeChase = false
                                break
                            end
                        end
                    end
                end
                local glyphActive = State.glyphUsedForDive and (GameTime() - State.glyphDiveTime) < 5.0
                local normalSafe = (H.GetSafeApproachLoose(bot, chaseTargetLoc, enemyTowers, allyCreeps) == chaseTargetLoc)
                -- His T1 is busy with our creep (>= 2 shots), HP >= 50%, his burst is not lethal:
                -- razes under the tower give no aggro - the finish is allowed
                local towerLockedSafe = isSafeChase and H.TowerLockedOnCreep(s.enemyT1)
                    and myHpPct >= 0.5 and not (Rr and Rr.valid and Rr.heCanKillSoon)
                    and not H.TowerBurnActive()
                if (canChase and isSafeChase) or normalSafe or glyphActive or towerLockedSafe then
                    if H.HandleLethalTwoRazeSequence(bot, enemyHero, enemyTowers, allyCreeps) then
                        return
                    end
                    if H.HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps) then
                        return
                    end
                    if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, true, false) then
                        return
                    end
                end
            end
        end
    end

    if enemyHero and not inKillThreat then
        if H.HandleMirrorRazeTrade(bot, enemyHero, enemyTowers, allyCreeps, allyCreeps, enemyCreeps) then return end
    end

    if enemyHero and not inKillThreat and secondStackActive then
        if secondStackLabel == "mid" then
            if H.HandleMidStackSpacing(bot, enemyHero, enemyTowers, allyCreeps) then return end
        elseif secondStackLabel == "near" then
            if H.HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps) then return end
        end
    end

    if enemyHero and not inKillThreat then
        if H.HandleCloseAttackFinish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not inKillThreat and not secondStackActive then
        if H.HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not inKillThreat and not secondStackActive then
        if H.ForceExtendEnemyStack(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    local ward = U.GetActiveItemByName(bot, "item_ward_observer")
    if ward and not H.ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero) then
        local wardLoc = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.WARD_RADIANT or C.POSITIONS.WARD_DIRE
        local standLoc = H.GetSafeWardCastStandpoint(bot, wardLoc) or wardLoc
        local distToWard = GetUnitToLocationDistance(bot, wardLoc)
        if distToWard > 490 then
            H.SmartMove(bot, standLoc, 35)
        else
            bot:Action_UseAbilityOnLocation(ward, wardLoc)
            H.ClearMoveCache()
        end
        return
    end

    local aggroCount = 0
    local closeCreepsCount = 0
    local hasRangedAggro = false
    local is_taking_damage = bot:WasRecentlyDamagedByCreep(1.5)
    -- How many of MY creeps are hitting the enemy hero (support in the trade)
    local enemyAggroCount = 0
    if enemyHero and U.CanQuery(enemyHero) then
        for _, c in pairs(allyCreeps) do
            if U.CanQuery(c) and c:GetAttackTarget() == enemyHero then enemyAggroCount = enemyAggroCount + 1 end
        end
    end
    State.enemyAggroCount = enemyAggroCount
    for _, c in pairs(enemyCreeps) do
        if c:IsAlive() then
            if U.CanQuery(c) and c:GetAttackTarget() == bot then
                aggroCount = aggroCount + 1
                local name = c:GetUnitName() or ""
                if name:find("ranged") or name:find("siege") then hasRangedAggro = true end
            end
            if GetUnitToLocationDistance(bot, c:GetLocation()) < 350 then
                closeCreepsCount = closeCreepsCount + 1
            end
        end
    end

    if U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero) then
        local safeLoc = H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
        H.BeginForcedRetreat(bot, safeLoc, 0.85)
        return
    end

    local is_under_my_tower = false
    for _, t in pairs(allyTowers) do
        if GetUnitToLocationDistance(bot, t:GetLocation()) < 850 then
            is_under_my_tower = true
            break
        end
    end

    if not csWaveBusy and GameTime() > State.deaggroTime and GameTime() >= (State.myCreepChaseUntil or 0) then
        local should_deaggro = false
        if allyCreeps and #allyCreeps > 0 then
            -- Drop aggro only when the creeps are REALLY hitting us (>= 2 creeps, or 1 + damage, or
            -- a ranged + damage). The old condition "2 enemy creeps closer than 350" triggered on any
            -- last hit near the wave: CLEAR + "attack own creep" + a 400 back-off every 1.2 s ->
            -- lost last hits and twitching toward the tower.
            if aggroCount >= 2 or (aggroCount >= 1 and is_taking_damage) or (hasRangedAggro and is_taking_damage) then
                should_deaggro = true
            end
        else
            if is_under_my_tower and bot:GetHealth() > 300 then
                if aggroCount >= 2 or (aggroCount >= 1 and is_taking_damage) then
                    should_deaggro = true
                end
            else
                if aggroCount >= 2 or (aggroCount >= 1 and bot:GetHealth() < 450) or hasRangedAggro then
                    should_deaggro = true
                end
            end
        end
        -- Suppress deaggro `400u` backward flee when healthy (`> 320 HP`) and either:
        --   (a) a creep is dying right now (`hp <= 155`), OR
        --   (b) we are executing a winning hero finish (`enHp <= 340` / `canKillSoon`)!
        if should_deaggro and (bot:GetHealth() or 0) > 320 then
            local R = K._race
            if enemyHero and U.CanQuery(enemyHero) and (
                (enemyHero:GetHealth() or 9999) <= 340
                or (R and R.valid and not R.heCanKillSoon and (R.canKillNow or R.canKillSoon or (R.edge or 0) >= 95))
            ) then
                should_deaggro = false
            end
            if should_deaggro then
                for _, c in pairs(enemyCreeps or {}) do
                    if c and c:IsAlive() and c:GetHealth() <= 155 then
                        should_deaggro = false
                        break
                    end
                end
            end
        end
        if should_deaggro then
            bot:Action_ClearActions(false)
            H.ClearMoveCache()
            State.heroAttackTarget = nil
            State.heroAttackTime = 0
            local fountain = P.GetFountain(bot)
            local safeCloseAlly, safeFbAlly = H.FindSafeDeaggroAllyCreep(bot, allyCreeps, enemyHero)
            local chosenSafeAlly = safeCloseAlly or safeFbAlly
            if chosenSafeAlly then
                local safe_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 400
                if bot.ActionQueue_AttackUnit and bot.ActionQueue_MoveToLocation then
                    bot:ActionQueue_AttackUnit(chosenSafeAlly, true)
                    bot:ActionQueue_MoveToLocation(safe_pos)
                else
                    bot:Action_AttackUnit(chosenSafeAlly, true)
                end
                State.deaggroTime = GameTime() + 1.2
            else
                local kite_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 300
                bot:Action_MoveToLocation(kite_pos)
                State.deaggroTime = GameTime() + 0.6
            end
            return
        end
    end

    if GameTime() < State.aggroPullTime then
        if H.IsHeroAttackWindupLocked(bot) then return end
        if H.IsInHeroAttackAnimation(bot) then return end
        H.SmartMove(bot, P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode), 60)
        return
    end

    local bestTarget, isDeny = L.GetBestTarget(bot, enemyCreeps, allyCreeps, enemyAttackers, allyAttackers, enemyNearWave)
    -- Do not take a last hit that requires entering his ready band in a bad trade:
    -- otherwise it is an endless "approach for the creep - get scared - back off", and every approach is his raze on us.
    if bestTarget and enemyHero and U.CanQuery(enemyHero) then
        local fearMin = U.GetFearMinDist(bot, enemyHero)
        if fearMin > 0 then
            local eLoc = enemyHero:GetLocation()
            local cLoc = bestTarget:GetLocation()
            local botD = U.DistanceBetweenLocations(bot:GetLocation(), eLoc)
            local inRangeNow = GetUnitToLocationDistance(bot, cLoc) <= bot:GetAttackRange() + 20
            local creepD = U.DistanceBetweenLocations(cLoc, eLoc)
            if not (inRangeNow and botD >= fearMin - 40) and creepD < fearMin - bot:GetAttackRange() + 40 then
                bestTarget, isDeny = nil, false
            end
        end
    end
    -- Do not walk for a creep into a point where his available burst (ready bands + right clicks)
    -- kills me: otherwise "approached for the creep -> became lethal -> RETREAT for 1 s -> came back"
    -- in a loop every 2-3 s (twitching). Take only what is reachable from a non-lethal distance.
    if bestTarget and enemyHero and U.CanQuery(enemyHero) and race.valid and not race.canKillNow then
        local eLoc = enemyHero:GetLocation()
        local cLoc = bestTarget:GetLocation()
        local bLoc = bot:GetLocation()
        local myRange = bot:GetAttackRange()
        local atkPos = bLoc
        if U.DistanceBetweenLocations(bLoc, cLoc) > myRange - 20 then
            atkPos = cLoc + (bLoc - cLoc):Normalized() * (myRange - 30)
        end
        local atkD = U.DistanceBetweenLocations(atkPos, eLoc)
        local curD = U.DistanceBetweenLocations(bLoc, eLoc)
        if atkD < curD - 30 then
            local burst = K.EnemyBurstVs(bot, enemyHero, atkD, 2.5, false)
            if burst >= bot:GetHealth() - 20 then
                bestTarget, isDeny = nil, false
            end
        end
    end
    -- Defence (clearly weaker, no creep/tower support): do not enter his attack
    -- radius for a last hit - every entry is 1-2 of his hits (70+ per hit with 20 souls and bracers), a creep
    -- is not worth that. Take only what is reachable from outside his radius, or while he is busy with the wave.
    local myHpPctNow = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    if bestTarget and enemyHero and State.defensive and race.valid and race.weakerSustained
        and U.CanQuery(enemyHero) and not H.HasTradeSupport(race) then
        local eLoc = enemyHero:GetLocation()
        local cLoc = bestTarget:GetLocation()
        local bLoc = bot:GetLocation()
        local myRange = bot:GetAttackRange()
        local hisReach = (enemyHero:GetAttackRange() or 525) + ((C.DEFENSE and C.DEFENSE.CONTEST_PAD) or 80)
        local atkPos = bLoc
        if U.DistanceBetweenLocations(bLoc, cLoc) > myRange - 20 then
            atkPos = cLoc + (bLoc - cLoc):Normalized() * (myRange - 30)
        end
        -- Skip a creep only if it is really pressuring us (hitting us / hit us in the last
        -- 3 s) or we are low with his raze ready. Merely "standing by the wave" is no reason to give up
        -- all the farm: previously a weaker bot with that rule took not a single creep.
        local pressing = false
        if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then pressing = true end
        if not pressing and bot.WasRecentlyDamagedByHero then
            pressing = bot:WasRecentlyDamagedByHero(enemyHero, 3.0) and true or false
        end
        if not pressing and myHpPctNow <= 0.45 and (race.enRazesSoon or 0) >= 1 then
            pressing = true
        end
        if pressing and U.DistanceBetweenLocations(atkPos, eLoc) <= hisReach and not LN.EnemyBusyWithWave(bot, enemyHero) then
            bestTarget, isDeny = nil, false
        end
    end
    local bestTargetTime = 999
    if bestTarget then
        bestTargetTime = U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers)
    end
    local lasthitImminent = bestTarget ~= nil and bestTargetTime >= 0 and bestTargetTime <= 1.2

    local am_i_tanking_too_much = false
    if not allyCreeps or #allyCreeps == 0 then
        if aggroCount >= 2 or (aggroCount >= 1 and bot:GetHealth() < 450) then am_i_tanking_too_much = true end
    else
        if aggroCount >= 3 or (aggroCount >= 2 and bot:GetHealth() < 400) then am_i_tanking_too_much = true end
    end

    if is_under_my_tower and bot:GetHealth() > 300 then
        if aggroCount <= 1 then am_i_tanking_too_much = false end
    end

    if am_i_tanking_too_much then
        if not (bestTarget and U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers) <= 0.6) then
            local fountain = P.GetFountain(bot)
            local safe_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 250
            H.SmartMove(bot, safe_pos, 60)
            return
        end
    end

    if is_under_my_tower and bot:GetHealth() > 300 then am_i_tanking_too_much = false end

    if am_i_tanking_too_much then
        if not (bestTarget and U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers) <= 0.6) then
            H.SmartMove(bot, P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode), 60)
            return
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive then
        if H.HandleRazeRangedCreepWithHero(bot, enemyHero, enemyCreeps, allyAttackers, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive and U.IsEnemyHighValueRegen(enemyHero) then
        local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if bot:GetMana() >= 75 and distToEnemy <= 1100 then
            if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
        local attackRange = bot:GetAttackRange() + 60
        if distToEnemy <= attackRange then
            if myHpPct > 0.30 and H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then
                if H.IssueHeroAttack(bot, enemyHero) then
                    State.lastHarassTime = GameTime()
                    State.lastAggroTime = GameTime()
                    State.aggroPullTime = GameTime() + 0.25
                    return
                end
            end
        elseif distToEnemy <= C.HARASS.INTERRUPT_APPROACH and myHpPct > 0.40 and H.GetPotentialCombatMana(bot) >= 75 then
            local botLoc = bot:GetLocation()
            local dir = (enemyHero:GetLocation() - botLoc):Normalized()
            local approachLoc = botLoc + dir * math.min(distToEnemy - attackRange + 50, 400)
            approachLoc = U.ClampMinDistFromEnemy(bot, enemyHero, approachLoc)
            if H.ApproachEnemyPoint(bot, enemyHero, approachLoc, 60, enemyTowers, allyCreeps) then
                return
            end
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive then
        local eStacks, eRem = U.GetShadowrazeDebuff(enemyHero)
        -- Extending 2 stacks is a combo continuation: allowed with a favourable trade or by the mana reserve
        local extendOk = (race.valid and race.edge >= 0 and bot:GetMana() >= 75) or H.HarassManaOK(bot, race)
        if eStacks >= 2 and eRem <= C.RAZE.EXTEND_AT + 0.6 and extendOk and not State.defensive then
            if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive and enemyMissedAggro
        and H.HarassManaOK(bot, race) and not State.defensive then
        local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if distToEnemy <= 950 then
            if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
    end

    -- ZONE: keep the enemy away from our wave (or hold River-Wave Enemy-T1 Choke even when he backs into FoW!)
    if intent == I.ZONE and not lasthitImminent and not am_i_tanking_too_much and not inKillThreat then
        if H.ExecuteZoning(bot, enemyHero, race, allyCreeps, enemyTowers) then return end
    end

    if H.HandleItemsAndConsumables(bot, bestTarget, enemyCreeps, allyAttackers, enemyTowers, enemyHero) then return end

    -- prepTarget (the creep for a "pre-hit") was NEVER reset (except by ForceExtend):
    -- after the first pre-hit, harass, push and the pre-hit itself were disabled forever while the dead handle
    -- was queried every tick. Reset when: the target is dead/invisible, the hit landed, or > 2.5 s passed.
    if State.prepTarget then
        local pt = State.prepTarget
        local age = GameTime() - (State.prepTargetTime or 0)
        if not U.CanQuery(pt) or age > 2.5
            or (not U.IsAttackingAction(bot) and age > 0.6) then
            State.prepTarget = nil
            State.prepTargetTime = 0
        end
    end

    -- The enemy projectile is already flying at the creep, his hit is not enough to finish it, and after
    -- it lands the creep becomes mine - send our attack RIGHT AFTER his projectile.
    if H.HandleProjectileSnipe(bot, enemyCreeps, enemyHero, enemyTowers, allyCreeps) then return end

    local is_free_to_prehit = true
    if bestTarget then
        local t_killable = U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers)
        if t_killable < (bot:GetSecondsPerAttack() + 0.3) then is_free_to_prehit = false end
    end

    local prehit_target = nil
    if is_free_to_prehit and not State.prepTarget and not am_i_tanking_too_much then
        local attack_cd = bot:GetSecondsPerAttack()
        for _, c in pairs(enemyCreeps) do
            if U.CanQuery(c) then
                local in_tower_range = false
                local twPrepR = (C.BALLISTIC and C.BALLISTIC.TOWER_ATTACK_RANGE_C2C) or 870
                for _, t in pairs(allyTowers) do
                    if GetUnitToLocationDistance(t, c:GetLocation()) <= twPrepR + 15 then
                        in_tower_range = true
                        break
                    end
                end
                -- `v7.9.29-pro` (`auto-20261108-2131` `01:44` Legacy Under-Tower Prehit Override Fix!):
                -- `L.TryUnderTowerPrep` inside `RunSacredCS` is the sole authoritative ballistic+reload solver for enemy
                -- creeps under `allyTowers` (`<= 885u`). NEVER let this legacy fallback override `TryUnderTowerPrep`'s
                -- reload-safety veto on under-tower creeps!
                local prehit_ok = false
                if (not in_tower_range) and (C.LASTHIT.PREHIT_ANYWHERE ~= false) and not inKillThreat and not State.defensive then
                    local eFar = true
                    if enemyHero and U.CanQuery(enemyHero) then
                        local dce = U.DistanceBetweenLocations(c:GetLocation(), enemyHero:GetLocation())
                        local R = K._race
                        eFar = dce > 850 or LN.EnemyBusyWithWave(bot, enemyHero) or (R and R.valid and R.enRazesSoon == 0)
                    end
                    local underEnemyTower = false
                    for _, t in pairs(enemyTowers) do
                        if t:IsAlive() and GetUnitToLocationDistance(t, c:GetLocation()) < 800 then underEnemyTower = true break end
                    end
                    prehit_ok = eFar and not underEnemyTower
                end
                if prehit_ok then
                    local myDmg = U.SFDamageRange(bot, c).min
                    local hp = c:GetHealth()
                    if hp > (myDmg * 1.5) then
                        local ctx_normal = U.GetTargetPredictionContext(c, allyAttackers)
                        if not U.HasLasthitWindow(ctx_normal, c, myDmg, 0) then
                            local ctx_prehit = U.WithHypotheticalDamage(ctx_normal, myDmg)
                            if U.HasLasthitWindow(ctx_prehit, c, myDmg, attack_cd) then
                                prehit_target = c
                                break
                            end
                        end
                    end
                end
            end
        end

        if not prehit_target then
            for _, c in pairs(allyCreeps) do
                if c:IsAlive() and (c:GetHealth() / c:GetMaxHealth()) < 0.5 then
                    local in_enemy_tower_range = false
                    for _, t in pairs(enemyTowers) do
                        if GetUnitToLocationDistance(t, c:GetLocation()) < 750 then
                            in_enemy_tower_range = true
                            break
                        end
                    end
                    if in_enemy_tower_range then
                        local eSF = enemyHero
                        local eDmg = eSF and U.CanQuery(eSF) and eSF:GetAttackDamage() or U.SFDamageRange(bot, c).min
                        local myDmg = U.SFDamageRange(bot, c).min
                        local hp = c:GetHealth()
                        if hp > myDmg then
                            local ctx_normal = U.GetTargetPredictionContext(c, enemyAttackers)
                            if U.HasLasthitWindow(ctx_normal, c, eDmg, 0) then
                                local ctx_prehit = U.WithHypotheticalDamage(ctx_normal, myDmg)
                                if not U.HasLasthitWindow(ctx_prehit, c, eDmg, 0) then
                                    prehit_target = c
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end

        if prehit_target then
            local tower_proj_flying = false
            local projs = U.SafeGetIncomingProjectiles(prehit_target)
            if projs then
                for _, p in pairs(projs) do
                    if p.is_attack and p.caster and p.caster:IsTower() then
                        tower_proj_flying = true
                        break
                    end
                end
            end
            if not tower_proj_flying then
                State.prepTarget = prehit_target
                State.prepTargetTime = GameTime()
                if H.IsSafeToAttack(bot, prehit_target:GetLocation(), enemyTowers, allyCreeps) then
                    if not U.IsAttackingAction(bot) or bot:GetAttackTarget() ~= prehit_target then
                        -- ONE attack (previously a continuous attack: the second hit cut the creep into the zone
                        -- where our own creeps finished it)
                        bot:Action_AttackUnit(prehit_target, true)
                        H.ClearMoveCache()
                    end
                else
                    H.SmartMove(bot, H.GetSafeApproach(bot, bot:GetLocation(), enemyTowers, allyCreeps), 60)
                end
                return
            end
        end
    end

    -- Finishing a stack on the enemy does not wait for the 1.9 s "free window" before a last hit: the cast is 0.55 s,
    -- we only yield to a last hit that must be taken within the next 0.7 s.
    -- A stack-finishing raze outranks a last hit when the last hit is not "right now" (<= 0.45 s):
    -- a raze on a stacked hero (~120-160 damage + stack extension) is worth more than one creep
    local followUpNow = enemyHero and H.IsRazeFollowUp(bot, enemyHero) and (bestTargetTime < 0 or bestTargetTime > 0.45)
    -- Hunting (State.hunting) outranks the last hit and is not blocked by a stack on us (his burst on us
    -- was already checked in ComputeHunt with the stack taken into account)
    local hunting = (State.hunting and enemyHero ~= nil) or false
    -- The enemy walked up close and we have mana for two razes - the trade beats waiting for the
    -- last hit (previously is_free_to_prehit = false here and the bot silently stood by the creep)
    local punishWindow = enemyHero ~= nil
        and (s.enemyDist <= ((C.RAZE and C.RAZE.PUNISH_CLOSE_RANGE) or 520))
        and H.GetPotentialCombatMana(bot) >= ((C.RAZE and C.RAZE.PUNISH_MIN_POT_MANA) or 150)
    local allowHarass = (is_free_to_prehit or enemyMissedAggro or followUpNow or hunting or punishWindow) and not State.prepTarget and not inKillThreat and (not secondStackActive or hunting or punishWindow)
    -- "Stack finish only" window (a last hit in 0.45-1.9 s): only razes are allowed (0.55 s cast),
    -- while a right click on the hero (0.5 s swing + 1.6 s cooldown) would cost the last hit.
    local razeOnlyWindow = followUpNow and not (is_free_to_prehit or enemyMissedAggro or hunting)
    -- No aggression under RETREAT; under FARM - no closing on the enemy (only if he came to us)
    if intent == I.RETREAT then allowHarass = false end
    local allowApproach = (intent == I.TRADE or intent == I.ALLIN)
    
    if H.HandleRetaliationAttack(bot, enemyHero, enemyTowers, allyCreeps) then return end

    if allowHarass and enemyHero then
        local canRazePressure, razeMode = H.ShouldTryRazePressure(bot, enemyHero, current_mode, aggroCount)
        if canRazePressure then
            if H.TryRazeEnemy(bot, enemyHero, razeMode, enemyTowers, allyCreeps, false, false) then return end
        end
        if razeOnlyWindow then
            -- The stack finish did not work (no coverage/mana) - go back to the last hit
        elseif H.ShouldAttackHarassEnemy(bot, enemyHero, current_mode, aggroCount, enemyTowers, allyCreeps) then
            if H.IssueHeroAttack(bot, enemyHero) then
                State.lastHarassTime = GameTime()
                State.lastAggroTime = GameTime()
                State.aggroPullTime = GameTime() + 0.25
                return
            end
        end

        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local approachThreshold = H.GetEnemyApproachDistance(enemyMissedAggro)
        local minHpPct = enemyMissedAggro and C.HARASS.MIN_HP_PCT_MISS or C.HARASS.MIN_HP_PCT
        local effectiveMode = enemyMissedAggro and "AGGRESSIVE" or current_mode
        if hunting then
            approachThreshold = (C.INTENT and C.INTENT.HUNT_MAX_DIST or 1100) + 150
            minHpPct = (C.INTENT and C.INTENT.HUNT_MIN_HP_PCT) or 0.40
            effectiveMode = "AGGRESSIVE"
        end
        if allowApproach and not razeOnlyWindow
            and (effectiveMode == "AGGRESSIVE" or (effectiveMode == "NEUTRAL" and enemyMissedAggro))
            and aggroCount <= 1
            and myHpPct >= minHpPct
            and dist > bot:GetAttackRange() + 50
            and dist < approachThreshold then
            local botLoc = bot:GetLocation()
            local dir = (enemyHero:GetLocation() - botLoc):Normalized()
            local stepIn = math.min(dist - bot:GetAttackRange() + 30, 350)
            local rawApproach = botLoc + dir * stepIn
            local futureDist = U.DistanceBetweenLocations(rawApproach, enemyHero:GetLocation())
            local fearMidBlock = U.ShouldFearBootsMidRaze(bot, enemyHero) and math.abs(futureDist - C.RAZE.MID_CENTER) <= 220
            if not fearMidBlock then
                local rawApproachClamped = U.ClampMinDistFromEnemy(bot, enemyHero, rawApproach)
                -- `auto-20261102-0139` `0:48..0:52` Fix: when `ClampMinDistFromEnemy` rejects stepping closer to `enemyHero`,
                -- skip `ApproachEnemyPoint` WITHOUT early `return` so `GetLasthitPosition` below still positions SF at the wave!
                if U.DistanceBetweenLocations(rawApproachClamped, enemyHero:GetLocation()) < dist - 20 then
                    if H.ApproachEnemyPoint(bot, enemyHero, rawApproachClamped, 60, enemyTowers, allyCreeps) then
                        return
                    end
                end
            end
        end
    end

    local isAttacking = U.IsAttackingAction(bot)
    local target = bot:GetAttackTarget()
    -- The target went into fog/died: it must not be queried (otherwise "[Developer] ... cannot be seen" every tick)
    if isAttacking and target and not U.CanQuery(target) then
        State.attackTarget = nil
        State.attackStartTime = 0
        State.firedThisAttack = false
        isAttacking = false
        target = nil
    end
    local lhFallThrough = false
    if isAttacking and target and State.lhAttackTarget==target and not (target.IsHero and target:IsHero()) then
        local last=bot:GetLastAttackTime() or -100
        local released=false
        if State.attackTarget==target and State.attackStartTime>0
            and last>State.attackStartTime+0.01 and last<=GameTime() then
            for _,projectile in pairs(U.SafeGetIncomingProjectiles(target)) do
                if projectile.is_attack and projectile.caster==bot then released=true;break end
            end
        end
        local waitingForCooldown=bestTarget and bestTarget~=target and last>0
            and last<State.attackStartTime
            and last+bot:GetSecondsPerAttack()-GameTime()>(bot:GetAttackPoint() or 0.5)+0.08
        if released or waitingForCooldown then
            State.lhAttackTarget=nil;State.prepTarget=nil;State.attackTarget=nil
            State.attackStartTime=0;State.firedThisAttack=false
            lhFallThrough=true
        end
    end
    if isAttacking and target and not lhFallThrough then
        if State.attackTarget ~= target then
            State.attackTarget = target
            State.attackStartTime = GameTime()
            State.firedThisAttack = false
        end
        if State.prepTarget == target then return end
        local targetIsHero = target.IsHero and target:IsHero()
        local elapsed = GameTime() - State.attackStartTime
        local ap = bot:GetAttackPoint()
        local remaining_windup = math.max(0, ap - elapsed)
        if targetIsHero then return end
        -- The attack is not a "last hit" (push/clearing the wave): the cancel logic does not apply to it - previously
        -- it cancelled EVERY such attack 0.08 s before the attack point (the creep was "too alive") and the bot
        -- twitched endlessly without dealing damage. If a real last hit ripens meanwhile - yield to it.
        if State.lhAttackTarget ~= target then
            if target == bestTarget then
                -- A continuous (push) attack on a creep that became a last-hit candidate:
                -- if it is killable right now - let the attack land; otherwise stop attacking,
                -- the last-hit logic below takes over the timing
                if bestTargetTime <= 0.05 then return end
                bot:Action_ClearActions(true)
                H.ClearMoveCache()
                State.attackTarget = nil
                State.attackStartTime = 0
                State.firedThisAttack = false
                isAttacking = false
                target = nil
                lhFallThrough = true
            elseif bestTarget and bestTargetTime >= 0 and bestTargetTime <= (bot:GetSecondsPerAttack() + 0.4) then
                lhFallThrough = true
            else
                return
            end
        end
    end
    if isAttacking and target and not lhFallThrough then
        local elapsed = GameTime() - State.attackStartTime
        local ap = bot:GetAttackPoint()
        local remaining_windup = math.max(0, ap - elapsed)
        local dist = GetUnitToLocationDistance(bot, target:GetLocation())
        local projSpeed = bot:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED
        local impact_time = remaining_windup + (dist / projSpeed)
        local isAlly = (target:GetTeam() == bot:GetTeam())
        local attackers = isAlly and enemyAttackers or allyAttackers
        local ctx = U.GetTargetPredictionContext(target, attackers)
        local predHP = U.PredictHPWithContext(ctx, target, impact_time, "avg")
        local atkCount = 0
        for _, atk in pairs(attackers) do
            if atk and U.CanQuery(atk) and atk:GetAttackTarget() == target then atkCount = atkCount + 1 end
        end
        local dmg, safety_margin = U.GetEffectiveDamageAndMargin(bot, target, atkCount)
        local kill_threshold = dmg - safety_margin
        local dmgRange = U.SFDamageRange(bot, target)
        local commit_threshold = math.max(kill_threshold, dmgRange.avg)
        local commit_buffer = C.LASTHIT.COMMIT_HP_BUFFER or 8
        local cancel_window = C.LASTHIT.CANCEL_WINDOW or math.max(0.03, math.min(0.08, ap * 0.20))
        local shouldCancel = H.ShouldCancelCommittedLastHit(predHP, commit_threshold, commit_buffer, remaining_windup, cancel_window)
        if shouldCancel then
            if remaining_windup > 0.01 and remaining_windup <= cancel_window then
                bot:Action_ClearActions(true)
                H.ClearMoveCache()
                State.attackTarget = nil
                State.attackStartTime = 0
                State.firedThisAttack = false
            end
            return
        else
            if remaining_windup <= 0.05 and not State.firedThisAttack then
                State.firedThisAttack = true
            end
            return
        end
    else
        State.attackTarget = nil
        State.attackStartTime = 0
        State.firedThisAttack = false
    end

    -- The enemy walked up close - punish him without waiting for a last-hit window
    if enemyHero and not am_i_tanking_too_much and not State.prepTarget then
        if H.HandleCloseEnemyPunish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    -- Never let legacy `DESIRED_ATK_RANGE = 450` CS override `L.RunSacredCS` slack-weaving ticks (`csWaveBusy == true`)!
    if bestTarget and not csWaveBusy then
        local targetLoc = bestTarget:GetLocation()
        local botLoc = bot:GetLocation()
        local dist = GetUnitToLocationDistance(bot, targetLoc)
        local projSpeed = bot:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED
        local ap = bot:GetAttackPoint()
        local ms = bot:GetCurrentMovementSpeed() or 305
        local earliest_t_attack,current_t_attack=U.GetAttackImpactWindow(bot,bestTarget)
        local DESIRED_ATK_RANGE = 450
        local time_to_walk = math.max(0, dist - DESIRED_ATK_RANGE) / ms
        local ranged_t_attack = ap + (DESIRED_ATK_RANGE / projSpeed) + C.LASTHIT.NET_LATENCY
        local attackers = isDeny and enemyAttackers or allyAttackers
        local t_killable, t_window_end = U.GetTimeToKillable(bot, bestTarget, attackers)
        -- My hit must land AFTER the creep becomes killable (with the IMPACT_LEAD margin
        -- for jitter), and BEFORE our own creeps finish it. Previously a hit was allowed
        -- 0.05 s BEFORE the threshold -> systematic "hit too early, the creep survived".
        if t_killable < 0 then
            -- No window: our own creeps kill it first. If it is nearly killable - hit now (a chance).
            local hpNow = bestTarget:GetHealth()
            local dr = U.SFDamageRange(bot, bestTarget)
            if hpNow <= dr.avg + 4 and not (isAttacking and target == bestTarget) then
                if H.IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps) then
                    bot:Action_AttackUnit(bestTarget, true)
                    State.lhAttackTarget = bestTarget
                    State.attackTarget = bestTarget
                    State.attackStartTime = GameTime()
                    State.firedThisAttack = false
                    H.ClearMoveCache()
                    return
                end
            end
            t_killable = 999
        end
        if (time_to_walk + ranged_t_attack + 0.1) < t_killable then
            if dist > DESIRED_ATK_RANGE then
                local dir = (botLoc - targetLoc):Normalized()
                local moveTarget = H.GetSafeApproach(bot, targetLoc + dir * DESIRED_ATK_RANGE, enemyTowers, allyCreeps)
                H.SmartMove(bot, moveTarget, 60)
            else
                if isAttacking then
                    bot:Action_ClearActions(true)
                    H.ClearMoveCache()
                end
            end
            return
        elseif U.LastHitImpactFits(earliest_t_attack, current_t_attack, t_killable, t_window_end) then
            if not (isAttacking and target == bestTarget) then
                if H.IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps) then
                    bot:Action_AttackUnit(bestTarget, true)
                    State.lhAttackTarget = bestTarget
                    State.attackTarget = bestTarget
                    State.attackStartTime = GameTime()
                    State.firedThisAttack = false
                    H.ClearMoveCache()
                else
                    H.SmartMove(bot, H.GetSafeApproach(bot, botLoc, enemyTowers, allyCreeps), 60)
                end
            end
            return
        else
            if dist > 500 then
                local dir = (botLoc - targetLoc):Normalized()
                local moveTarget = H.GetSafeApproach(bot, targetLoc + dir * 480, enemyTowers, allyCreeps)
                H.SmartMove(bot, moveTarget, 60)
            end
            return
        end
    end

    -- AGGRO PULL (chapter 18): drag his wave back to my side with an attack order + a step back
    if WV.PULL ~= "off" and not State.actionTaken then
        if WV.PullTick(bot, s, enemyHero, GameTime()) then return end
    end

    -- WAVE SHOVE (chapter 18): raze the creep wave to crash it now - the stock bot never razes
    -- creeps.  Fires after the last-hit block, so a cs is never traded for a shove.
    if WV.SHOVE ~= "off" and not State.actionTaken and WV.ShoveAllowed(bot, s, enemyHero) then
        local tgt, abName = WV.FindShove(bot, s)
        if tgt then
            local ab = bot:GetAbilityByName(abName)
            if ab and ab:GetLevel() > 0 and U.IsRazeAbilityCastable(bot, ab) then
                local actionType, aimLoc = H.GetRazeActionType(bot, ab, tgt)
                if actionType and H.CastOrTurnRaze(bot, ab, actionType, aimLoc, tgt) then
                    WV.NoteShove()
                    return
                end
            end
        end
    end

    if H.HandleTowerStealLastHit(bot, enemyCreeps, allyTowers, enemyTowers, allyCreeps) then return end

    -- PUSH: push the wave / hit the T1 under a shield (last hits have higher priority - we get here
    -- only when no last hit is imminent)
    -- Siege as a fallback plan: the intent is aggressive (ALLIN/ZONE/TRADE) but the enemy hides
    -- under his T1 and is unreachable while our edge is large and the wave is at the tower - hit the tower/creeps
    -- under a shield instead of standing around. (ExecutePush checks the shield, HP and enemy threat itself.)
    local siegeFallback = false
    if intent ~= I.PUSH and intent ~= I.RETREAT and intent ~= I.FARM and not State.defensive
        and race.valid and s.enemyT1 and myHpPct >= ((C.INTENT and C.INTENT.PUSH_MIN_HP_PCT) or 0.55)
        and race.edge >= ((C.INTENT and C.INTENT.PUSH_EDGE) or 260) and not race.heCanKillSoon then
        local okTL, tLoc = pcall(s.enemyT1.GetLocation, s.enemyT1)
        if okTL and tLoc and GetUnitToLocationDistance(bot, tLoc) <= ((C.PUSH and C.PUSH.T1_ATTACK_RANGE) or 900) then
            siegeFallback = true
        end
    end
    if (intent == I.PUSH or siegeFallback) and not State.prepTarget and not am_i_tanking_too_much then
        if H.ExecutePush(bot, enemyHero, race, s) then return end
    end

    -- No creeps: walk to the lane (to the centre if far; otherwise to our own T1)
    local hasCreeps = (#allyCreeps > 0) or (#enemyCreeps > 0)
    -- Time hysteresis - creep lists are taken within 1200 of the bot, and when moving past
    -- that boundary "no creeps -> walk to the T1 (closer to the wave) -> creeps again -> back off"
    -- twitched 20 times a second. "No creeps" = not seen for >= 1.5 s.
    local nowC = GameTime()
    if hasCreeps then State.lastCreepsSeenTime = nowC end
    if not hasCreeps and (nowC - (State.lastCreepsSeenTime or -1e9)) < 1.5 then hasCreeps = true end
    if not hasCreeps and not U.IsActivelyHealing(bot) and not fightingEnemyInLane then
        -- No creeps (early game / the wave died): wait at our own T1 (the T1_CLOSE point).
        -- One target without "centre/T1" thresholds (they twitched at the 1500-from-centre boundary);
        -- the "between the T1 and the centre" point was removed - for Dire it landed in the river.
        local targetPos = State.waveScoutPoint or P.GetT1Close(bot)
        -- Do not route through the enemy T1 radius
        targetPos = H.GetSafeApproach(bot, targetPos, enemyTowers, allyCreeps)
        if GetUnitToLocationDistance(bot, targetPos) > 45 then
            H.SmartMove(bot, targetPos, 80)
        end
        return
    end

    if State.holdPos then return end

    local pos = P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode)
    if enemyHero and U.CanQuery(enemyHero) then
        pos = U.ClampMinDistFromEnemy(bot, enemyHero, pos) -- Do not enter his band under "fear"
    end
    pos = H.GetSafeApproach(bot, pos, enemyTowers, allyCreeps)
    if GetUnitToLocationDistance(bot, pos) > 100 then
        H.SmartMove(bot, pos, 60)
    end

    -- `v7.9.9-pro` (`1814 @ 08:42.40..08:45.07` End-of-Tick Zero-Order Anti-Freeze Guard):
    -- NEVER finish `RealThink` stationary (`not State.actionTaken`) while `enemyHero` is actively right-clicking/pressuring us
    -- within `615u` and `towerChaseBlockedEnemy` prevented retaliation! Step `190u` back outside `573u` attack reach!
    if not State.actionTaken and enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive() then
        local dEnd = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if dEnd <= 615 and (enemyHero:GetAttackTarget() == bot or H.IsEnemyPressuring(bot, enemyHero)) then
            local fntEnd = P.GetFountain(bot)
            local stepOutEnd = enemyHero:GetLocation() + (fntEnd - enemyHero:GetLocation()):Normalized() * 680
            if s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(stepOutEnd, s.enemyT1Loc) < 980 then
                stepOutEnd = s.enemyT1Loc + (fntEnd - s.enemyT1Loc):Normalized() * 995
            end
            H.SmartMove(bot, stepOutEnd, 28, true)
        end
    end

    -- The tick stayed free - switch the Power Treads for the current task
    if not State.actionTaken then
        H.ManageTreads(bot, nil)
    end
end

local function runFailSafeRetreat(bot)
    local maxHpFs = math.max(1, bot:GetMaxHealth() or 1)
    local hpPctFs = (bot:GetHealth() or 0) / maxHpFs
    local hitByHero = (bot.WasRecentlyDamagedByAnyHero and bot:WasRecentlyDamagedByAnyHero(1.8)) or false
    local safeAnchor = nil
    if hpPctFs <= 0.35 or hitByHero then
        safeAnchor = P.GetFountain(bot)
    else
        safeAnchor = (P.GetBehindT1 and P.GetBehindT1(bot, 480)) or P.GetFountain(bot)
    end
    if safeAnchor and GetUnitToLocationDistance(bot, safeAnchor) > 55 then
        bot:Action_MoveToLocation(safeAnchor)
    end
end

function Think()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then
        State.heroCombatEnemy = nil
        State.heroCombatUntil = 0
        State.survivalUntil = 0
        State.survivalLoc = nil
        State.needsTP = true
        State.emergencyRetreat = nil
        State.emergencyRetreatStartTime = 0
        State.emergencyTPQueued = false
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        State.goingToFountain = false
        State.fountainReason = nil
        State.enemyReachedLevel2First = false
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        State.heroAttackCommitUntil = 0
        State.heroAttackStartLAT = -100
        H.ClearForcedRetreat()
        H.ClearTowerEscape()
        H.ClearRazeState()
        H.ClearMoveCache()
        H.ClearTangoState()
        State.dodgeLoc = nil
        State.dodgeUntil = 0
        State.turnAbuseCombo = nil
        State.postRazeDisengagePureRadialUntil = 0
        State.intent = "FARM"
        I.Reset()
        return
    end

    local now = GameTime()
    if now - (State.lastThinkTick or -100) < 0.015 then return end
    State.lastThinkTick = now
    U.BeginThinkTick(now)
    local success, err = pcall(H.RealThink)
    U.EndThinkTick()
    if not success then
        _G.__SF_RUNTIME_ERRORS = (_G.__SF_RUNTIME_ERRORS or 0) + 1
        _G.__SF_LAST_RUNTIME_ERROR = tostring(err)
        if _G.__SF_STRICT_ASSERT then
            error("[SF-BOT STRICT ASSERT] " .. tostring(err), 0)
        end
        if now - (State.lastErrorLog or -100) >= 1.0 then
            State.lastErrorLog = now
            print("[SF-BOT CRITICAL ERROR] " .. tostring(err))
        end
        -- Zero-Freeze Fail-Safe Recovery (`auto-20261031-1939` `tk=14068..14298` `(255.0, 384.1)` Fix!):
        -- NEVER walk `380u` IN FRONT of T1 (`P.GetT1Close(bot, 380)`) and freeze within `<= 65u` under enemy attack!
        -- Retreat BEHIND allied Mid T1 (`P.GetBehindT1(bot, 480)`), or all the way to Fountain when wounded / taking hero hits!
        pcall(runFailSafeRetreat, bot)
    end
end

if _G.BOT_SIM_PROBE then
    _G.__NEVERMORE_H = H
    _G.__NEVERMORE_STATE = State
end
