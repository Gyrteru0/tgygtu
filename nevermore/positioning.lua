local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")

local P = {}

function P.GetFountain(bot)
    return bot:GetTeam() == TEAM_RADIANT and C.POSITIONS.MID_FOUNTAIN_RADIANT or C.POSITIONS.MID_FOUNTAIN_DIRE
end

function P.GetT1Tower(bot)
    if type(GetTower) == "function" and TOWER_MID_1 ~= nil then
        local tower = GetTower(bot:GetTeam(), TOWER_MID_1)
        if tower and tower:IsAlive() and (not tower.CanBeSeen or tower:CanBeSeen()) then
            return tower:GetLocation()
        end
    end
    return bot:GetTeam() == TEAM_RADIANT and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1
end

function P.GetT1Close(bot, distance)
    local tower = P.GetT1Tower(bot)
    local enemyTeam = bot:GetTeam() == TEAM_RADIANT and TEAM_DIRE or TEAM_RADIANT
    local enemyLoc = bot:GetTeam() == TEAM_RADIANT and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
    if type(GetTower) == "function" and TOWER_MID_1 ~= nil then
        local enemyTower = GetTower(enemyTeam, TOWER_MID_1)
        if enemyTower and enemyTower:IsAlive() and (not enemyTower.CanBeSeen or enemyTower:CanBeSeen()) then
            enemyLoc = enemyTower:GetLocation() or enemyLoc
        end
    end
    local home = (enemyLoc - tower):Normalized()
    return tower + home * (distance or 180)
end

-- True defensive point BEHIND allied T1 toward Fountain (never forward into river — fixes `R2_2044` `04:16..04:26`
-- `(1653, 1533) <-> (1450, 1334)` Salve oscillation where `GetT1Close(bot, 420)` pointed SW toward enemy!).
function P.GetBehindT1(bot, distance, fallbackDist)
    local dist = (type(distance) == "number" and distance)
        or (type(fallbackDist) == "number" and fallbackDist)
        or 400
    local tower = P.GetT1Tower(bot)
    local fnt = P.GetFountain(bot)
    local back = (fnt - tower):Normalized()
    return tower + back * dist
end

-- Ensures `candidate` is AT LEAST as deep toward Fountain as `P.GetBehindT1(bot, minBehindT1)`
-- (`9069188041.dem` Death #1 Fix: NEVER pull a deeper anchor outward away from Fountain via inverted `<`!).
function P.ClampDeeperTowardFountain(bot, candidate, minBehindT1)
    local minSpot = P.GetBehindT1(bot, minBehindT1 or 400)
    if not candidate then return minSpot end
    local fnt = P.GetFountain(bot)
    if U.DistanceBetweenLocations(candidate, fnt) > U.DistanceBetweenLocations(minSpot, fnt) then
        return minSpot
    end
    return candidate
end

-- Monotonic Fountain-ward retreat anchor (`9069188041.dem` `03:44.1-03:47.5` Death #2 Fix):
-- When `bot` is ALREADY deeper toward Fountain than `P.GetBehindT1(bot, minBehindT1)` (e.g. `(1304, 1095)` vs
-- `(675, 798)`), NEVER pull `bot` 620u backward SW toward the river/enemy! Either hold current deep position
-- (`stepWhenDeep <= 0`) or continue retreating `stepWhenDeep` units closer to Fountain (`stepWhenDeep > 0`).
function P.GetRetreatAnchor(bot, minBehindT1, stepWhenDeep)
    local base = P.GetBehindT1(bot, minBehindT1 or 260)
    local bLoc = bot:GetLocation()
    local fnt = P.GetFountain(bot)
    local dBotFnt = U.DistanceBetweenLocations(bLoc, fnt)
    local dBaseFnt = U.DistanceBetweenLocations(base, fnt)
    if dBotFnt > dBaseFnt + 35 then
        return base
    end
    local extra = tonumber(stepWhenDeep) or 0
    if extra <= 0 then
        return bLoc
    end
    local step = math.min(extra, math.max(0, dBotFnt - 420))
    if step <= 5 then return bLoc end
    return bLoc + (fnt - bLoc):Normalized() * step
end

-- Upgrade river points (height level 1) onto Highground when attacking Highground creeps,
-- eliminating the 25% Source 2 uphill miss rate completely whenever safe (`v7.9.21`: climbs BOTH onto allied HG
-- AND onto target's HG staircase/lip whenever enemy hero is dead, absent, distant, dry, crippled, or outmatched!).
function P.CanSafelyClimbToTargetHG(bot, testPos)
    local WmodUp = package.loaded["bots/nevermore/world"]
    local wsUp = WmodUp and WmodUp.s
    local enT1Loc = (wsUp and wsUp.enemyT1Alive ~= false and wsUp.enemyT1Loc) or nil
    if enT1Loc then
        local LNmod = package.loaded["bots/nevermore/lane"]
        local firmShield = LNmod and LNmod.HasFirmTowerCreepShield and wsUp.allyCreeps
            and LNmod.HasFirmTowerCreepShield(enT1Loc, wsUp.enemyT1, wsUp.allyCreeps, testPos, 280) or false
        local minT1 = firmShield and 660 or 905
        if U.DistanceBetweenLocations(testPos, enT1Loc) < minT1 then
            return false
        end
    end
    if wsUp and wsUp.enemyAlive == false then
        return true
    end
    local eh = wsUp and wsUp.enemy
    local myHp = bot:GetHealth() or 0
    if eh and U.CanQuery(eh) and eh:IsAlive() then
        local ehLoc = eh:GetLocation()
        local dEh = U.DistanceBetweenLocations(testPos, ehLoc)
        if dEh >= 835 then return true end
        local enHp = eh:GetHealth() or 999
        local enPotMp = (U.GetPotentialManaForRaze and U.GetPotentialManaForRaze(eh)) or (eh:GetMana() or 0)
        local mySt = (U.GetShadowrazeDebuff and U.GetShadowrazeDebuff(bot)) or 0
        if enHp <= 265 and myHp >= 370 and mySt == 0 and dEh >= 490 then
            return true
        end
        if enPotMp < 75 and myHp >= 320 and myHp >= (enHp - 45) and dEh >= 440 then
            return true
        end
        if U.IsLaneDominant and U.IsLaneDominant(bot, wsUp, nil) and myHp >= 420 and mySt == 0 and dEh >= 515 then
            return true
        end
        return false
    end
    local absentFor = (wsUp and wsUp.enemyAbsentFor) or 99
    if absentFor >= 3.5 and myHp >= 360 then
        return true
    end
    if wsUp and wsUp.enemyLastLoc then
        return U.DistanceBetweenLocations(testPos, wsUp.enemyLastLoc) >= 850
    end
    return true
end

-- Exact empirical Source 2 Mid Corridor Terrain Elevation Model (`v7.9.24-pro`, verified on `auto-20261108-1523.dem`):
-- Valve's C++ `GetHeightLevel(pt)` already increments partway up the mid staircases (`z = 25..76`, e.g. `(-740,-616,z=45.3)`
-- and `(-818,-614,z=76.5)`), whereas Dota 2's C++ `CDOTA_BaseNPC::PerformAttack` applies the `25%` uphill miss penalty
-- whenever `target.z - attacker.z > 16`! Using exact Source 2 Mid staircase transition coordinates:
--   * Radiant `z = 128.0` plateau: `x + y <= -1570` (`-1570 < x + y < -1245` is Radiant ramp `z = 16..127`)
--   * Mid River `z = 0..16`:       `-1245 <= x + y <= -555`
--   * Dire `z = 128.0` plateau:    `x + y >= -225`  (`-555 < x + y < -225` is Dire ramp `z = 16..127`)
function P.EstimateMidZ(pt, exactRefLoc)
    if not pt then return 0 end
    if exactRefLoc and exactRefLoc.z then
        local dx = (pt.x or 0) - (exactRefLoc.x or 0)
        local dy = (pt.y or 0) - (exactRefLoc.y or 0)
        if (dx * dx + dy * dy) <= 625 then -- <= 25u from live queried unit -> exact C++ float `.z`!
            return exactRefLoc.z
        end
    end
    local x, y = pt.x or 0, pt.y or 0
    if x >= -1650 and x <= 750 and y >= -1550 and y <= 850 and math.abs(x - y) <= 720 then
        local s = x + y
        if s <= -1570 then
            return 128.0
        elseif s < -1245 then
            return 16.0 + 112.0 * ((-1245.0 - s) / 325.0)
        elseif s <= -555 then
            return 6.0
        elseif s < -225 then
            return 16.0 + 112.0 * ((s - (-555.0)) / 330.0)
        else
            return 128.0
        end
    end
    return pt.z or 0
end

function P.IsSameOrHigherElevation(candidatePos, targetLoc, botNowLoc)
    if not candidatePos or not targetLoc then return true end
    if type(GetHeightLevel) == "function" then
        if (GetHeightLevel(candidatePos) or 0) < (GetHeightLevel(targetLoc) or 0) then
            return false
        end
    end
    local tgtZ = (targetLoc.z and targetLoc.z > 1) and targetLoc.z or P.EstimateMidZ(targetLoc, nil)
    local candZ = P.EstimateMidZ(candidatePos, botNowLoc)
    local tolZ = (tgtZ >= 124) and 0.2 or 8.0
    if tgtZ >= 24 and candZ < (tgtZ - tolZ) then
        return false
    end
    return true
end

function P.AvoidUphillMiss(bot, candidatePos, targetLoc, maxRange)
    if not candidatePos or not targetLoc then
        return candidatePos
    end
    local bNow = bot and bot.GetLocation and bot:GetLocation() or nil
    if P.IsSameOrHigherElevation(candidatePos, targetLoc, bNow) then
        return candidatePos
    end

    local fountain = P.GetFountain(bot)
    local toFountain = (fountain - candidatePos):Normalized()
    maxRange = maxRange or ((bot:GetAttackRange() or 525) - 20)

    -- 1. First search toward our own Highground bank if `targetLoc` is still comfortably in attack range from our HG
    for step = 50, 340, 35 do
        local test = candidatePos + toFountain * step
        local dx, dy = test.x - targetLoc.x, test.y - targetLoc.y
        if math.sqrt(dx * dx + dy * dy) <= maxRange
            and P.IsSameOrHigherElevation(test, targetLoc, nil)
            and (type(IsLocationPassable) ~= "function" or IsLocationPassable(test)) then
            return test
        end
    end

    -- 2. Otherwise (`auto-20261108-1523.dem` `02:27..07:09` `13x` Uphill Miss Zero-Penalty Plateau Climb!):
    --    Step ALL THE WAY onto the target's `z = 128` Highground plateau (`IsSameOrHigherElevation == true`, NEVER stopping
    --    halfway up the stairs at `z = 45..76`!), probing both forward from `candidatePos` AND radially around `targetLoc`
    --    along the safe Highground lip (`d(EnemyT1) >= 905u` unshielded or `>= 660u` shielded)!
    local baseDir = (targetLoc - candidatePos):Normalized()
    local c22, s22 = math.cos(math.rad(22)), math.sin(math.rad(22))
    local c42, s42 = math.cos(math.rad(42)), math.sin(math.rad(42))
    local dirL22 = Vector(baseDir.x * c22 - baseDir.y * s22, baseDir.x * s22 + baseDir.y * c22, 0)
    local dirR22 = Vector(baseDir.x * c22 + baseDir.y * s22, -baseDir.x * s22 + baseDir.y * c22, 0)
    local dirL42 = Vector(baseDir.x * c42 - baseDir.y * s42, baseDir.x * s42 + baseDir.y * c42, 0)
    local dirR42 = Vector(baseDir.x * c42 + baseDir.y * s42, -baseDir.x * s42 + baseDir.y * c42, 0)
    local probeDirs = { baseDir, dirL22, dirR22, dirL42, dirR42 }
    for step = 45, 560, 35 do
        for _, dVec in ipairs(probeDirs) do
            local test = candidatePos + dVec * step
            local dx, dy = test.x - targetLoc.x, test.y - targetLoc.y
            local distTgt = math.sqrt(dx * dx + dy * dy)
            if distTgt >= 115 and distTgt <= maxRange
                and P.IsSameOrHigherElevation(test, targetLoc, nil)
                and (type(IsLocationPassable) ~= "function" or IsLocationPassable(test))
                and P.CanSafelyClimbToTargetHG(bot, test) then
                return test
            end
        end
    end

    -- 3. Direct radial Highground-lip search around `targetLoc` toward our Fountain (`±28°` & `±52°` along the cliff edge,
    --    e.g. `(-905..-945, -675..-720, z = 128)` at `d(RADIANT_T1) = 925..980u` when `targetLoc = (-1055, -867)`!):
    local fromTgt = (fountain - targetLoc):Normalized()
    local c28, s28 = math.cos(math.rad(28)), math.sin(math.rad(28))
    local c52, s52 = math.cos(math.rad(52)), math.sin(math.rad(52))
    local radDirs = {
        fromTgt,
        Vector(fromTgt.x * c28 - fromTgt.y * s28, fromTgt.x * s28 + fromTgt.y * c28, 0),
        Vector(fromTgt.x * c28 + fromTgt.y * s28, -fromTgt.x * s28 + fromTgt.y * c28, 0),
        Vector(fromTgt.x * c52 - fromTgt.y * s52, fromTgt.x * s52 + fromTgt.y * c52, 0),
        Vector(fromTgt.x * c52 + fromTgt.y * s52, -fromTgt.x * s52 + fromTgt.y * c52, 0),
    }
    for r = 135, math.min(maxRange, 465), 40 do
        for _, rVec in ipairs(radDirs) do
            local test = targetLoc + rVec * r
            if P.IsSameOrHigherElevation(test, targetLoc, nil)
                and (type(IsLocationPassable) ~= "function" or IsLocationPassable(test))
                and P.CanSafelyClimbToTargetHG(bot, test) then
                return test
            end
        end
    end
    return candidatePos
end

-- `v7.6.0` Own-T1 Highground Anti-Miss Discipline (`auto-20261101-0031-start-ShaNachnetsya.dem`):
-- When the creep wave clashes near our allied T1 (`ClassifyWaveZone == "OWN_T1"`), hold our own T1 highground
-- (`GetHeightLevel(pos) >= GetHeightLevel(ownT1)`) whenever any wave creep is reachable from our highground lip,
-- eliminating the 25% Source 2 uphill miss penalty on creeps completely!
function P.HoldOwnT1Highground(bot, candidatePos, enemyCreeps, allyCreeps)
    if not bot or not candidatePos then return candidatePos end
    local waveZone = U.ClassifyWaveZone and U.ClassifyWaveZone(bot, allyCreeps, enemyCreeps) or "NONE"
    if waveZone ~= "OWN_T1" then return candidatePos end

    local ownT1 = P.GetT1Tower(bot)
    if not ownT1 then return candidatePos end
    local fnt = P.GetFountain(bot)
    local maxReach = (bot:GetAttackRange() or 525) - 12

    local refCreepLoc, minD = nil, math.huge
    for _, list in ipairs({ enemyCreeps or {}, allyCreeps or {} }) do
        for _, c in pairs(list) do
            if c and c:IsAlive() then
                local cl = c:GetLocation()
                local d = U.DistanceBetweenLocations(ownT1, cl)
                if d < minD then
                    minD, refCreepLoc = d, cl
                end
            end
        end
    end
    if not refCreepLoc then return candidatePos end

    if type(GetHeightLevel) == "function" then
        local ownHg = GetHeightLevel(ownT1)
        if ownHg and (GetHeightLevel(candidatePos) or 0) < ownHg then
            local toT1 = (ownT1 - candidatePos)
            local dirT1 = (toT1:Length2D() > 1) and toT1:Normalized() or (fnt - candidatePos):Normalized()
            local dirFnt = (fnt - candidatePos):Normalized()
            for step = 40, 440, 35 do
                for _, dir in ipairs({ dirT1, dirFnt }) do
                    local test = candidatePos + dir * step
                    if (GetHeightLevel(test) or 0) >= ownHg
                        and U.DistanceBetweenLocations(test, refCreepLoc) <= maxReach then
                        return test
                    end
                end
            end
        end
    end
    return candidatePos
end

function P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, prepareTarget, mode)
    local fountain = P.GetFountain(bot)

    -- Farm cleanly under our T1 WITHOUT letting unshielded enemy melee creeps beat on our hero body
    -- (`9056469656.dem` `01:20` `(90, 981)` 9 free melee creep hits & `02:34` `(293, 374)` stationary tanking!):
    -- When `#allyCreeps == 0` and any live non-killable enemy creep under our T1 is aggroed onto `bot` (`GetAttackTarget() == bot`),
    -- step 435u back past our own T1 toward Fountain so Dire/Radiant T1 tanks & damages the melee creeps for 0 HP cost!
    do
        local t1 = P.GetT1Tower(bot)
        if t1 and enemyCreeps and #enemyCreeps > 0 then
            local lowestCreep, lowestHP = nil, math.huge
            local meleeBeatingBot, beatingCount, minFntDist = nil, 0, math.huge
            local killThresh = (bot:GetAttackDamage() or 55) + 22
            local hpDamaged = (bot:GetHealth() or 999) < (bot:GetMaxHealth() or 999) * 0.72
            for _, c in pairs(enemyCreeps) do
                if c and c:IsAlive() then
                    local d = GetUnitToLocationDistance(c, t1)
                    if d <= 920 then
                        local hp = c:GetHealth()
                        if hp < lowestHP then
                            lowestHP, lowestCreep = hp, c
                        end
                        if (not allyCreeps or #allyCreeps == 0) and hp > killThresh
                            and c.GetAttackTarget and c:GetAttackTarget() == bot then
                            beatingCount = beatingCount + 1
                            local dFnt = GetUnitToLocationDistance(c, fountain)
                            if dFnt < minFntDist then
                                minFntDist, meleeBeatingBot = dFnt, c
                            end
                        end
                    end
                end
            end
            -- Stop kiting back as soon as the lowest under-T1 creep is within `1` tower hit (`killThresh + 115`),
            -- AND (`9079381960.dem` `04:42.7..04:44.9` Fix) anchor the handoff strictly near `t1` (`<= atkRange - 65` from
            -- `lowestCreep`) instead of `cLoc + dir * 435`, which ran `809u` behind T1 (`546u` out of attack range!) as a
            -- lone creep chased SF while the enemy hero was DEAD!
            local WmodKite = package.loaded["bots/nevermore/world"]
            local wsKite = WmodKite and WmodKite.s
            local enemyDeadUnderT1 = (wsKite and wsKite.enemyAlive == false) or false
            local skipSingleCreepKiteWhenDead = enemyDeadUnderT1 and beatingCount <= 1
                and (bot:GetHealth() or 0) >= 110 and lowestCreep and lowestHP <= (killThresh + 220)
            if not skipSingleCreepKiteWhenDead and meleeBeatingBot and (hpDamaged or beatingCount >= 2)
                and lowestCreep and lowestHP > (killThresh + 115) then
                local t1Loc = (t1 and t1.x ~= nil) and t1 or t1:GetLocation()
                local dirHome = (fountain - t1Loc):Normalized()
                local handoffPos = t1Loc + dirHome * 165
                local lowLoc = lowestCreep:GetLocation()
                local maxKeepInRange = math.max(410, (bot:GetAttackRange() or 500) - 35)
                -- `v7.9.25-pro` (`auto-20261108-1609` `01:41, 02:42, 03:41` Own-T1 CS Orbit Preservation):
                -- ALWAYS clamp `handoffPos` within `maxKeepInRange` (`~465u`) of `lowestCreep` (even when `enemyDeadUnderT1 == false`!)
                -- so handing unshielded creeps to our T1 NEVER parks SF `750..870u` behind T1 while T1 steals the wave!
                if U.DistanceBetweenLocations(handoffPos, lowLoc) > maxKeepInRange then
                    local shieldDir = (fountain - lowLoc):Normalized()
                    if wsKite and wsKite.enemy and U.CanQuery(wsKite.enemy) and wsKite.enemy:IsAlive() then
                        local awayEnH = (t1Loc - wsKite.enemy:GetLocation())
                        if awayEnH:Length2D() > 1 then
                            shieldDir = (shieldDir * 0.55 + awayEnH:Normalized() * 0.65):Normalized()
                        end
                    end
                    handoffPos = lowLoc + shieldDir * maxKeepInRange
                end
                return handoffPos
            end
            -- `v7.9.31-pro` (`auto-20261109-0026` Dire-River `805u`-From-T1 Standoff Override Fix!):
            -- Dire T1 `(524, 612)` sits only `805u` from `(0, 0)` in the river (`<= 920u`!), which previously caused EVERY Dire
            -- river wave to hit this under-T1 fallback and get locked at `460u` whenever `outLvlT1 == true` — even against a
            -- `15.5 MP` (`0`-coil!) rival! When `prepareTarget` is specified and `lowestCreep` is `> 660u` out from `t1`,
            -- delegate to the authoritative `prepareTarget` wave-stance solver below!
            local dLowToT1 = lowestCreep and GetUnitToLocationDistance(lowestCreep, t1) or 9999
            if lowestCreep and (not prepareTarget or dLowToT1 <= 660) then
                local cLoc = lowestCreep:GetLocation()
                local dir = (fountain - cLoc):Normalized()
                local stand = (C.BALLISTIC and C.BALLISTIC.CLOSE_STAND_DIST) or 175
                -- `auto-20261031-0230` `02:08.3` Death #2 Root-Cause Fix:
                -- When a live enemy hero pressures near our T1 while we are wounded (`<= 420 HP` / `< 65%`) or out-leveled by
                -- an ARMED (`>= 75 MP`) rival, hold safe spacing (`<= 460u`) instead of pulling SW to `175u` into right-clicks!
                local WmodT1 = package.loaded["bots/nevermore/world"]
                local wsT1 = WmodT1 and WmodT1.s
                local ehT1 = (wsT1 and wsT1.enemy and U.CanQuery(wsT1.enemy) and wsT1.enemy:IsAlive() and wsT1.enemy) or nil
                local ehLocT1 = (ehT1 and ehT1:GetLocation())
                    or ((wsT1 and wsT1.enemyAlive ~= false and (wsT1.enemyAbsentFor or 99) <= 3.0) and wsT1.enemyLastLoc or nil)
                if ehLocT1 and U.DistanceBetweenLocations(ehLocT1, cLoc) <= 960 then
                    local myHpT1 = bot:GetHealth() or 999
                    local myMaxT1 = math.max(1, bot:GetMaxHealth() or 600)
                    local enArmedT1 = ehT1 and (((ehT1:GetMana() or 0) + ((U.GetMangoMana and U.GetMangoMana(ehT1)) or 0)) >= 75) or false
                    local outLvlArmedT1 = enArmedT1 and ehT1 and ((ehT1:GetLevel() or 1) > (bot:GetLevel() or 1)) or false
                    -- `v7.9.19` (`9080125239.dem` `01:18–01:46` Own-T1 Side-Flank Harass Shield):
                    local t1LocShield = (t1 and t1.x ~= nil) and t1 or t1:GetLocation()
                    if t1LocShield and U.DistanceBetweenLocations(ehLocT1, t1LocShield) > 705 then
                        local rawCandT1 = cLoc + dir * stand
                        if U.DistanceBetweenLocations(rawCandT1, ehLocT1) < (enArmedT1 and 645 or 515) then
                            local awayFlank = (t1LocShield - ehLocT1):Normalized()
                            local shieldDist = enArmedT1 and math.min((bot:GetAttackRange() or 525) - 25, 465) or 315
                            local shieldCand = cLoc + (dir * 0.45 + awayFlank * 0.75):Normalized() * shieldDist
                            if U.DistanceBetweenLocations(shieldCand, ehLocT1) > U.DistanceBetweenLocations(rawCandT1, ehLocT1) + 25 then
                                return P.AvoidUphillMiss(bot, shieldCand, cLoc)
                            end
                        end
                    end
                    if myHpT1 <= 355 or (myHpT1 / myMaxT1) < 0.58 or outLvlArmedT1 then
                        local safeMaxStand = math.min((bot:GetAttackRange() or 525) - 40, 470)
                        local bLocT1 = bot:GetLocation()
                        if U.DistanceBetweenLocations(bLocT1, cLoc) <= (bot:GetAttackRange() or 525) - 15
                            and U.DistanceBetweenLocations(bLocT1, fountain) < U.DistanceBetweenLocations(cLoc + dir * safeMaxStand, fountain) then
                            return bLocT1
                        end
                        stand = safeMaxStand
                    elseif not enArmedT1 and myHpT1 >= 330 then
                        stand = 275
                    end
                end
                return P.AvoidUphillMiss(bot, cLoc + dir * stand, cLoc)
            end
        end
    end

    local function safeNoShieldCS(p)
        if not p then return p end
        local Wmod = package.loaded["bots/nevermore/world"]
        local ws = Wmod and Wmod.s
        if ws and ws.enemyT1Alive ~= false and ws.enemyT1Loc and #(allyCreeps or {}) == 0 then
            local tLoc = ws.enemyT1Loc
            local safeRad = math.max((C.TOWER and C.TOWER.SAFE_RADIUS) or 890, 925)
            if U.DistanceBetweenLocations(p, tLoc) < safeRad then
                return tLoc + (fountain - tLoc):Normalized() * safeRad
            end
        end
        return p
    end

    if prepareTarget and prepareTarget:IsAlive() then
        local Wmod = package.loaded["bots/nevermore/world"]
        local ws = Wmod and Wmod.s
        local enemyDead = ws and ws.enemyAlive == false
        local dominant = (mode ~= "PASSIVE") and (not enemyDead)
            and U.IsLaneDominant and U.IsLaneDominant(bot, ws, nil) or false
        local ehPrep = (not enemyDead and ws and ws.enemy and U.CanQuery(ws.enemy) and ws.enemy:IsAlive() and ws.enemy) or nil
        local enemyUncontestedPrep = enemyDead
            or (ws and (not ehPrep) and ((ws.enemyAbsentFor or 99) >= 3.5) and (bot:GetHealth() or 0) >= 360)
        local cLoc = prepareTarget:GetLocation()
        local dir = (fountain - cLoc):Normalized()
        local stand
        if enemyDead then
            stand = (C.BALLISTIC and C.BALLISTIC.CLOSE_STAND_DIST) or 175
        elseif enemyUncontestedPrep and mode ~= "PASSIVE" then
            stand = 195
        elseif mode == "PASSIVE" then
            stand = 455
        elseif dominant then
            -- Commanding `210u` forward CS/Deny stance when dominating (`0.175s` bolt flight vs `0.42s` at `505u`!):
            -- snipes both contested CS and denies 7 ticks faster while holding our body at the wave front!
            stand = 210
        elseif ehPrep then
            local enPotMpPrep = (ehPrep:GetMana() or 0) + ((U.GetMangoMana and U.GetMangoMana(ehPrep)) or 0)
            local myHpPrep = bot:GetHealth() or 999
            local myStacksPrep = (U.GetShadowrazeDebuff and U.GetShadowrazeDebuff(bot)) or 0
            -- `v7.9.31-pro` (`auto-20261109-0026` Waves 1-5 Flight-Time Deficit Fix):
            -- When the rival SF is completely OOM (`< 75 MP`, `0` coils!) and we have `>= 330 HP` with `0` stacks,
            -- step up to `275u` (`7`-tick flight instead of `12..14` ticks at `480u`!) even if down 1 level!
            -- Only retreat to `475u` max-range spacing when low HP (`<= 355`), carrying an active raze stack vs armed rival,
            -- or out-leveled / out-razed by an ARMED (`>= 75 MP`) rival!
            if enPotMpPrep < 75 and myHpPrep >= 330 and myStacksPrep == 0 then
                stand = 275
            elseif myHpPrep <= 355
                or (myStacksPrep >= 1 and enPotMpPrep >= 75)
                or (enPotMpPrep >= 75 and (
                    ((ehPrep:GetLevel() or 1) > (bot:GetLevel() or 1))
                    or (U.IsOutRazedTier and U.IsOutRazedTier(bot, ehPrep))
                )) then
                stand = math.min((bot:GetAttackRange() or 525) - 35, 475)
            else
                stand = (C.BALLISTIC and C.BALLISTIC.CONTESTED_STAND_DIST) or 335
                -- `v7.9.33-pro` (`auto-20261109-0306` `0:24..0:36` Highground Staircase Lip Guard!):
                -- When our allied wave holds our `z=128` highground plateau (`faLoc.z >= 100`) and the rival SF stands
                -- in the river/stairs (`eLoc.z < faLoc.z - 22`, `d <= 685u`), tighten `stand` to `235u` (still clamped
                -- `>= 505u` from `ehPrep` below!) so SF screens the `500u` creep-aggro lip with uphill autos + `W(450)`
                -- instead of parking `335..440u` back and gifting free staircase aggro pulls into the river!
                if myHpPrep >= 360 and myStacksPrep == 0 and allyCreeps and #allyCreeps > 0 then
                    local eLocSt = ehPrep:GetLocation()
                    for _, acSt in pairs(allyCreeps) do
                        if acSt and acSt:IsAlive() then
                            local acLocSt = acSt:GetLocation()
                            if (acLocSt.z or 0) >= 100
                                and ((acLocSt.z or 0) - (eLocSt.z or 0)) >= 22
                                and U.DistanceBetweenLocations(acLocSt, eLocSt) <= 685 then
                                stand = 235
                                break
                            end
                        end
                    end
                end
            end
        else
            stand = (C.BALLISTIC and C.BALLISTIC.CONTESTED_STAND_DIST) or 335
        end
        local anchor = cLoc + dir * stand
        if dominant and not enemyDead and allyCreeps and #allyCreeps > 0
            and (prepareTarget:GetHealth() or 0) > ((bot:GetAttackDamage() or 60) * 1.85 + 25) then
            local enemyT1RefD = (ws and ws.enemyT1Loc)
                or ((bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1)
            local frontAllyD, minT1D = nil, math.huge
            for _, ac in pairs(allyCreeps) do
                if ac and ac:IsAlive() then
                    local dT = GetUnitToLocationDistance(ac, enemyT1RefD)
                    if dT < minT1D then minT1D, frontAllyD = dT, ac end
                end
            end
            if frontAllyD and minT1D > 1060 then
                local faLocD = frontAllyD:GetLocation()
                -- `v7.9.13-pro` (`0210 @ 00:00..06:00` 27x Creep-Reaggro Screen):
                -- Stand `185u` IN FRONT of `frontAllyD` toward `enemyT1` (clamped `>= 920u` outside `enemyT1`) so the
                -- enemy SF CANNOT step within `500u` of `frontAllyD` to pull creep aggro without crossing inside `315..495u`
                -- of our SF and eating immediate right-clicks + centered `Shadowraze2`!
                local bullyStep = (((DotaTime and DotaTime()) or 0) <= 390) and 185 or 145
                local shieldAnchor = faLocD - dir * bullyStep
                local maxReachD = math.max(380, (bot:GetAttackRange() or 525) - 30)
                if U.DistanceBetweenLocations(shieldAnchor, cLoc) <= maxReachD
                    and (not enemyT1RefD or U.DistanceBetweenLocations(shieldAnchor, enemyT1RefD) >= 920) then
                    anchor = shieldAnchor
                end
            end
        end
        -- Never walk ahead of our front allied melee line toward enemy creeps/hero when `cLoc` is already
        -- comfortably reachable from behind our allied creeps (`<= maxReach = atkRange - 35`), EXCEPT when
        -- `dominant == true` or `enemyUncontestedPrep == true` where standing on the creep's HG avoids 25% miss!
        if not enemyUncontestedPrep and not dominant and allyCreeps and #allyCreeps > 0 then
            local enemyT1Ref = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
            local frontAlly, minT1 = nil, math.huge
            for _, ac in pairs(allyCreeps) do
                if ac and ac:IsAlive() then
                    local dT = GetUnitToLocationDistance(ac, enemyT1Ref)
                    if dT < minT1 then minT1, frontAlly = dT, ac end
                end
            end
            if frontAlly then
                local faLoc = frontAlly:GetLocation()
                local behindFront = faLoc + dir * 95
                local maxReach = math.max(380, (bot:GetAttackRange() or 525) - 35)
                local fntToAnchor = U.DistanceBetweenLocations(fountain, anchor)
                local fntToBehind = U.DistanceBetweenLocations(fountain, behindFront)
                -- Do NOT drag `anchor` down into the river behind `frontAlly` if `cLoc` is on Highground and `behindFront`
                -- drops elevation while `anchor` (or `AvoidUphillMiss`) can safely stand on `cLoc`'s Highground (`25%` miss fix)!
                local dropsOffTargetHG = (not P.IsSameOrHigherElevation(behindFront, cLoc, nil))
                    and P.CanSafelyClimbToTargetHG(bot, cLoc + dir * 215)
                if not dropsOffTargetHG and fntToAnchor > fntToBehind and U.DistanceBetweenLocations(behindFront, cLoc) <= maxReach then
                    anchor = behindFront
                end
            end
        end
        -- If `ehPrep` stands near `anchor`, pull `anchor` back toward Fountain up to `maxSafeReach` (`atkRange - 20`)
        -- when even/losing; when `dominant`, only avoid standing point-blank inside an armed enemy's `200u` Q band!
        -- `v7.9.21` (`auto-20261107-2214` `tk=4500, 8474, 9826, 10658, 12856` Anti-Bullseye Band-Center Fix!):
        -- NEVER park contested stance at `715u` (`15u` from `E(700)` bullseye!) or `450u` (`W(450)` bullseye!):
        --   * Use `830u` (`130u` outside `700u` center -> `100%` dodgeable even bootless at `305 MS`!) instead of `715u`,
        --   * AND whenever `anchor` still lands inside an armed `E` (`640..760u`) or `W` (`395..505u`) bullseye ring,
        --     apply a `115u` lateral sidestep perpendicular to `(anchor - eLocP)` (still within `maxSafeReach` of `cLoc`!)
        --     so `dFromCenter` starts `>= 115u` off-axis BEFORE the enemy ever starts his `0.55s` raze cast!
        if ehPrep then
            local eLocP = ehPrep:GetLocation()
            if dominant then
                local enArmed = ((ehPrep:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(ehPrep) or 0)) >= 75
                if enArmed and U.DistanceBetweenLocations(anchor, eLocP) < 495 then
                    local r1Safe = eLocP + dir * 505
                    local reachLim = (bot:GetAttackRange() or 525) - 18
                    local farPrep = cLoc + dir * reachLim
                    if U.DistanceBetweenLocations(r1Safe, cLoc) <= reachLim then
                        anchor = r1Safe
                    elseif U.DistanceBetweenLocations(farPrep, eLocP) > U.DistanceBetweenLocations(anchor, eLocP) + 15 then
                        anchor = farPrep
                    end
                end
            else
                local dryNow = U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, ehPrep, ws) or false
                local salvingPrep = bot.HasModifier and bot:HasModifier("modifier_flask_healing") or false
                local myHpPrep = bot:GetHealth() or 999
                local myLvlPrep = bot:GetLevel() or 1
                local enLvlPrep = ehPrep:GetLevel() or 1
                local myStPrep, myRemPrep = 0, 0
                local enStPrep = 0
                if U.GetShadowrazeDebuff then
                    myStPrep, myRemPrep = U.GetShadowrazeDebuff(bot)
                    enStPrep = U.GetShadowrazeDebuff(ehPrep) or 0
                end
                local enArmedPrep = ((ehPrep:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(ehPrep) or 0)) >= 75
                local outRazedPrep = enArmedPrep and (
                    (U.IsOutRazedTier and U.IsOutRazedTier(bot, ehPrep)) or (myLvlPrep == 1 and enLvlPrep >= 2)
                )
                local stackedDisadvPrep = enArmedPrep and (myStPrep or 0) >= 1 and (myRemPrep or 0) > 0.45
                    and ((myStPrep or 0) >= 2 or (myStPrep or 0) > (enStPrep or 0))
                local waveGuardPrep = (not dryNow) and (not salvingPrep)
                    and U.CanGuardWaveReaggro and U.CanGuardWaveReaggro(bot, ws, nil) or false
                -- `v7.9.25-pro` + `v7.9.31-pro` (`auto-20261109-0026` Dry-Rival & Even-Wave Standoff Fix!):
                --   1. `outRazedPrep` ONLY applies when `enArmedPrep == true` (`a 15.5 MP 0-coil Lvl-3 SF cannot cast Razes!`).
                --   2. Against an OOM (`< 75 MP`) rival when `myHp >= 330`, hold `510u` hero gap (`outside 500u right-click!`)
                --      instead of `858u`/`575u` so `stand = 275u` (`7`-tick CS flight!) is NEVER overwritten to `480u`!
                --   3. On an even healthy armed wave, `515u` clears `Q(200)`'s `474u` hull by `+41u` while preserving `335u` CS reach!
                local cautiousBackoff = dryNow or salvingPrep or outRazedPrep or (myHpPrep <= 355) or stackedDisadvPrep
                local KrefSt = package.loaded["bots/nevermore/combat"]
                local stackOnlyFloor = 858
                if stackedDisadvPrep and not (dryNow or salvingPrep or outRazedPrep or myHpPrep <= 355) and KrefSt and KrefSt.EnemyMinSafeDistance then
                    stackOnlyFloor = math.min(858, math.max(540, KrefSt.EnemyMinSafeDistance(ehPrep, 1.4) + 25))
                end
                local normalArmedFloor = waveGuardPrep and 510 or 520
                local dryRivalFloor = (myHpPrep >= 330 and not salvingPrep) and 508 or 620
                local minEnemyDist = (not enArmedPrep) and dryRivalFloor
                    or (dryNow and math.max(858, U.GetDrySafeStandoffDist(bot, ehPrep))
                        or (cautiousBackoff and stackOnlyFloor or normalArmedFloor))
                local maxSafeReach = math.max(415, (bot:GetAttackRange() or 525) - (dryNow and 15 or 20))
                local farAnchor = cLoc + dir * maxSafeReach
                if U.DistanceBetweenLocations(anchor, eLocP) < minEnemyDist then
                    if U.DistanceBetweenLocations(farAnchor, eLocP) >= minEnemyDist then
                        anchor = farAnchor
                    elseif cautiousBackoff and (prepareTarget:GetHealth() or 999) > ((bot:GetAttackDamage() or 60) * 1.55) then
                        anchor = eLocP + (fountain - eLocP):Normalized() * minEnemyDist
                    elseif U.DistanceBetweenLocations(farAnchor, eLocP) > U.DistanceBetweenLocations(anchor, eLocP) + 12 then
                        anchor = farAnchor
                    end
                    -- `v7.9.33-pro` (`auto-20261109-0306` `1:16.60` `HIT#5` `434u -> 612u` Anti-Barrel Retreat Deflection!):
                    -- Whenever `anchor` retreats outward to `>= 800u` while SF currently stands at `[350..715u]` and Enemy holds
                    -- `E(700)` ready (`whether via farAnchor or cautiousBackoff!`), check if the straight walk `bNowC -> anchor`
                    -- passes within `< 150u` of Enemy's live `700u` barrel (`enCtrC`); if so, deflect diagonally (`+220u` perp)!
                    local bNowC = bot:GetLocation()
                    local dBotEnC = U.DistanceBetweenLocations(bNowC, eLocP)
                    local dAncPost = U.DistanceBetweenLocations(anchor, eLocP)
                    local enFarArmedC = enArmedPrep and (not KrefSt or KrefSt.EnemyRazeReadyIn("far") <= 1.45)
                    if enFarArmedC and dBotEnC >= 350 and dBotEnC <= 715 and dAncPost >= 800 then
                        local enYawC = math.rad((ehPrep.GetFacing and ehPrep:GetFacing()) or 0)
                        local fxC, fyC = math.cos(enYawC), math.sin(enYawC)
                        local enCtrC = Vector(eLocP.x + fxC * 700, eLocP.y + fyC * 700, eLocP.z)
                        local curMidClear = U.DistanceBetweenLocations((bNowC + anchor) * 0.5, enCtrC)
                        if curMidClear < 150 then
                            local backDirC = (anchor - eLocP):Normalized()
                            local p1C = Vector(-fyC, fxC, 0)
                            local p2C = Vector(fyC, -fxC, 0)
                            local diagA = eLocP + backDirC * (dAncPost - 30) + p1C * 220
                            local diagB = eLocP + backDirC * (dAncPost - 30) + p2C * 220
                            local bestDiag, bestDiagScore = nil, -1e9
                            local mustStayInCSRange = (prepareTarget:GetHealth() or 999) <= ((bot:GetAttackDamage() or 60) * 1.55)
                            local csReachLim = (bot:GetAttackRange() or 525) - 10
                            for _, dCand in ipairs({ diagA, diagB }) do
                                if (type(IsLocationPassable) ~= "function" or IsLocationPassable(dCand))
                                    and (not mustStayInCSRange or U.DistanceBetweenLocations(dCand, cLoc) <= csReachLim) then
                                    local midPt = (bNowC + dCand) * 0.5
                                    local scD = U.DistanceBetweenLocations(midPt, enCtrC)
                                        + U.DistanceBetweenLocations(dCand, enCtrC) * 0.35
                                        - U.DistanceBetweenLocations(bNowC, dCand) * 0.08
                                    if scD > bestDiagScore then
                                        bestDiagScore, bestDiag = scD, dCand
                                    end
                                end
                            end
                            if bestDiag then
                                anchor = bestDiag
                            end
                        end
                    end
                end
            end
            -- Anti-Bullseye Sightline Offset (applies in BOTH `even` AND `dominant` stances — `v7.9.21` + `v7.9.33-pro`!):
            -- Evaluates `±18°`, `±27°`, `±36°` arc candidates around `cLoc` against Enemy's LIVE `E(700)`/`W(450)` facing
            -- barrel (`enLiveCtr`), maximizing off-axis clearance (`d_ctr >= 150..210u` instead of `9.5u` `HIT#3 @ 1:00.73`!)!
            local enPotBull = ((ehPrep:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(ehPrep) or 0))
            if enPotBull >= 75 then
                local KrefB = package.loaded["bots/nevermore/combat"]
                local dAncE = U.DistanceBetweenLocations(anchor, eLocP)
                local inFarBull = (not KrefB or KrefB.EnemyRazeReadyIn("far") <= 1.4) and (dAncE >= 605 and dAncE <= 795)
                local inMidBull = (not KrefB or KrefB.EnemyRazeReadyIn("mid") <= 1.4) and (dAncE >= 365 and dAncE <= 535)
                if (inFarBull or inMidBull) and dAncE > 20 then
                    local bNowB = bot:GetLocation()
                    local bandCB = inFarBull and 700 or 450
                    local enYawB = math.rad((ehPrep.GetFacing and ehPrep:GetFacing()) or 0)
                    local enLiveCtr = Vector(eLocP.x + math.cos(enYawB) * bandCB, eLocP.y + math.sin(enYawB) * bandCB, eLocP.z)
                    local curCtrClear = U.DistanceBetweenLocations(anchor, enLiveCtr)
                    if curCtrClear < 168 then
                        local arcR = math.min(U.DistanceBetweenLocations(anchor, cLoc), (bot:GetAttackRange() or 525) - 18)
                        local baseVec = (anchor - cLoc):Normalized() * math.max(320, arcR)
                        local bestArcPt, bestArcSc = anchor, curCtrClear
                        for _, degB in ipairs({ 18, -18, 27, -27, 36, -36 }) do
                            local ca, sa = math.cos(math.rad(degB)), math.sin(math.rad(degB))
                            local sPt = cLoc + Vector(baseVec.x * ca - baseVec.y * sa, baseVec.x * sa + baseVec.y * ca, 0)
                            local dSEn = U.DistanceBetweenLocations(sPt, eLocP)
                            local passOk = (type(IsLocationPassable) ~= "function" or IsLocationPassable(sPt))
                                and P.IsSameOrHigherElevation(sPt, anchor, nil)
                                and (dSEn >= math.min(dAncE - 25, 495))
                            if passOk then
                                local cClear = U.DistanceBetweenLocations(sPt, enLiveCtr)
                                local bandEdgeBonus = math.abs(dSEn - bandCB) * 0.35
                                local scArc = cClear + bandEdgeBonus - U.DistanceBetweenLocations(bNowB, sPt) * 0.08
                                if cClear >= curCtrClear + 18 and scArc > bestArcSc then
                                    bestArcSc, bestArcPt = scArc, sPt
                                end
                            end
                        end
                        anchor = bestArcPt
                    end
                end
            end
        end
        -- Honor `GetDeepEnemyT1ChokeSpot` EVEN when `prepareTarget ~= nil` whenever `cLoc` is reachable from the river-lip choke!
        if (mode ~= "PASSIVE") and (not enemyDead) and U.GetDeepEnemyT1ChokeSpot then
            local prepChoke = U.GetDeepEnemyT1ChokeSpot(bot, ws, nil, allyCreeps, enemyCreeps)
            if prepChoke and U.DistanceBetweenLocations(prepChoke, cLoc) <= (bot:GetAttackRange() or 525) - 20
                and U.DistanceBetweenLocations(fountain, prepChoke) < U.DistanceBetweenLocations(fountain, anchor) - 20 then
                anchor = prepChoke
            end
        end
        if ws and ws.enemyT1Alive ~= false and ws.enemyT1Loc then
            local tLoc = ws.enemyT1Loc
            local LNmod = package.loaded["bots/nevermore/lane"]
            local firmShield = LNmod and LNmod.HasFirmTowerCreepShield
                and LNmod.HasFirmTowerCreepShield(tLoc, ws.enemyT1, allyCreeps, anchor, 320) or false
            local minSafeAnchorT1 = firmShield and 665 or 915
            if U.DistanceBetweenLocations(anchor, tLoc) < minSafeAnchorT1 then
                anchor = tLoc + (fountain - tLoc):Normalized() * minSafeAnchorT1
            end
        end
        local finalPrepPos = safeNoShieldCS(P.HoldOwnT1Highground(bot, P.AvoidUphillMiss(bot, anchor, cLoc), enemyCreeps, allyCreeps))
        -- Final Post-HG Anti-Bullseye Sanitizer (`tk=4500, 8474, 9826, 10658, 12856` + `auto-20261108-0512` `01:05, 01:41, 02:19` Fix!):
        -- `AvoidUphillMiss` / `HoldOwnT1Highground` can step a `600u` river anchor `140u` back onto our Highground lip
        -- right into `d = 695..745u` (`E700` inescapable bullseye!).
        --   1. When NOT yet in immediate swing range (`hp > atk * 1.55`) and `not dominant`, push radial standoff outside `858u`
        --      (`158u` outside `E700` center -> `100%` bootless dodgeable in `0.38s`!) instead of loitering at `700u`!
        --   2. Always rotate off the sightline arc AFTER HG adjustments!
        if ehPrep and finalPrepPos then
            local eLocF = ehPrep:GetLocation()
            local enPotF = ((ehPrep:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(ehPrep) or 0))
            if enPotF >= 75 then
                local KrefF = package.loaded["bots/nevermore/combat"]
                local dFinE = U.DistanceBetweenLocations(finalPrepPos, eLocF)
                local farRdyF = (not KrefF or KrefF.EnemyRazeReadyIn("far") <= 1.4)
                local midRdyF = (not KrefF or KrefF.EnemyRazeReadyIn("mid") <= 1.4)
                local dryF = U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, ehPrep, ws) or false
                local salvingF = bot.HasModifier and bot:HasModifier("modifier_flask_healing") or false
                local outRazedF = (U.IsOutRazedTier and U.IsOutRazedTier(bot, ehPrep))
                    or ((bot:GetLevel() or 1) == 1 and (ehPrep:GetLevel() or 1) >= 2)
                local myStF, myRemF = 0, 0
                local enStF = 0
                if U.GetShadowrazeDebuff then
                    myStF, myRemF = U.GetShadowrazeDebuff(bot)
                    enStF = U.GetShadowrazeDebuff(ehPrep) or 0
                end
                local cautiousF = dryF or salvingF or outRazedF or ((bot:GetHealth() or 999) <= 360)
                    or ((myStF or 0) >= 1 and (myRemF or 0) > 0.45 and ((myStF or 0) >= 2 or (myStF or 0) > (enStF or 0)))
                local creepSlackWait = (not dominant)
                    and ((prepareTarget:GetHealth() or 999) > ((bot:GetAttackDamage() or 60) * 1.55))
                if creepSlackWait and farRdyF and dFinE >= 575 and dFinE < 855 then
                    local outStand = eLocF + (fountain - eLocF):Normalized() * 858
                    local maxReachF = (bot:GetAttackRange() or 500) - 15
                    -- `v7.9.25-pro`: Only step out beyond attack range (`858u`) when genuinely `cautiousF` (dry/wounded/out-razed/stacked);
                    -- when healthy & armed, never self-zone outside `maxReachF` of `cLoc` (step to `585u` between `W450` & `E700` instead!).
                    if cautiousF or U.DistanceBetweenLocations(outStand, cLoc) <= maxReachF then
                        if type(IsLocationPassable) ~= "function" or IsLocationPassable(outStand) then
                            finalPrepPos = outStand
                            dFinE = U.DistanceBetweenLocations(finalPrepPos, eLocF)
                        end
                    elseif dFinE >= 640 and dFinE <= 765 then
                        local betweenStand = eLocF + (fountain - eLocF):Normalized() * 585
                        if U.DistanceBetweenLocations(betweenStand, cLoc) <= maxReachF
                            and P.IsSameOrHigherElevation(betweenStand, cLoc, bot:GetLocation())
                            and (type(IsLocationPassable) ~= "function" or IsLocationPassable(betweenStand)) then
                            finalPrepPos = betweenStand
                            dFinE = U.DistanceBetweenLocations(finalPrepPos, eLocF)
                        end
                    end
                end
                local inFarF = farRdyF and (dFinE >= 630 and dFinE <= 775)
                local inMidF = midRdyF and (dFinE >= 390 and dFinE <= 515)
                if (inFarF or inMidF) and dFinE > 20 then
                    local bNowF = bot:GetLocation()
                    local wantH = (type(GetHeightLevel) == "function") and GetHeightLevel(finalPrepPos) or nil
                    local arcRF = math.min(U.DistanceBetweenLocations(finalPrepPos, cLoc), (bot:GetAttackRange() or 500) - 16)
                    local baseVF = (finalPrepPos - cLoc):Normalized() * math.max(300, arcRF)
                    for _, degF in ipairs({ 18, 25 }) do
                        local caF, saF = math.cos(math.rad(degF)), math.sin(math.rad(degF))
                        local sAF = cLoc + Vector(baseVF.x * caF - baseVF.y * saF, baseVF.x * saF + baseVF.y * caF, 0)
                        local sBF = cLoc + Vector(baseVF.x * caF + baseVF.y * saF, -baseVF.x * saF + baseVF.y * caF, 0)
                        local candsF = (U.DistanceBetweenLocations(bNowF, sAF) <= U.DistanceBetweenLocations(bNowF, sBF))
                            and { sAF, sBF } or { sBF, sAF }
                        local pickedF = nil
                        for _, ptF in ipairs(candsF) do
                            local okHF = (not wantH) or ((GetHeightLevel(ptF) or 0) >= wantH)
                            if okHF and (type(IsLocationPassable) ~= "function" or IsLocationPassable(ptF)) then
                                pickedF = ptF
                                break
                            end
                        end
                        if pickedF then
                            finalPrepPos = pickedF
                            break
                        end
                    end
                end
            end
        end
        return finalPrepPos
    end

    -- `v7.9.29-pro` (`auto-20261108-2131` `01:43` `E1967` + `E1996` Under-Own-T1 Spawn-Wave Walk-Back Fix!):
    -- When enemy creeps are already dying at/under our own T1 (`<= 980u` of `ownT1`), NEVER treat a newly spawned
    -- allied wave that is still marching BEHIND `ownT1` (`d(ally, fnt) < d(ownT1, fnt) - 60` and `> 420u` from enemy creeps)
    -- as the engaged frontline! Anchoring `+365u` behind that spawn wave walked SF `800u` backward toward T2 (`(1251, 989)`)
    -- right in the middle of last-hitting melee + ranged creeps under our own T1!
    local engagedAllyCreeps = allyCreeps
    if allyCreeps and #allyCreeps > 0 and enemyCreeps and #enemyCreeps > 0 then
        local ownT1Chk = P.GetT1Tower(bot)
        local closestEnemyUnderT1 = nil
        local minEnT1Dist = math.huge
        for _, ec in pairs(enemyCreeps) do
            if ec and ec:IsAlive() then
                local dET = U.DistanceBetweenLocations(ec:GetLocation(), ownT1Chk)
                if dET <= 980 and dET < minEnT1Dist then
                    minEnT1Dist = dET
                    closestEnemyUnderT1 = ec
                end
            end
        end
        if closestEnemyUnderT1 then
            local dOwnT1Fnt = U.DistanceBetweenLocations(ownT1Chk, fountain)
            local ecLocT1 = closestEnemyUnderT1:GetLocation()
            local filt = {}
            for _, ac in pairs(allyCreeps) do
                if ac and ac:IsAlive() then
                    local acLoc = ac:GetLocation()
                    local behindOwnT1 = U.DistanceBetweenLocations(acLoc, fountain) < (dOwnT1Fnt - 60)
                    local farFromEnemyWave = U.DistanceBetweenLocations(acLoc, ecLocT1) > 420
                    if not (behindOwnT1 and farFromEnemyWave) then
                        filt[#filt + 1] = ac
                    end
                end
            end
            engagedAllyCreeps = filt
        end
    end

    if not engagedAllyCreeps or #engagedAllyCreeps == 0 then
        if enemyCreeps and #enemyCreeps > 0 then
            -- Kite/hold safely toward our tower without losing sight or missing dying low-HP enemy creeps.
            -- Under our own T1 (`<= 880u`), hold a tight `275u` highground CS stance (`fT = 5..6` ticks) so SF can
            -- prep + reload + finish full-HP ranged creeps before T1 Bolt #2 lands!
            local ownT1Hold = P.GetT1Tower(bot)
            local bestC, bestHP = nil, math.huge
            for _, c in pairs(enemyCreeps) do
                if c and c:IsAlive() and c:GetHealth() < bestHP then
                    bestHP, bestC = c:GetHealth(), c
                end
            end
            if bestC then
                local cLoc = bestC:GetLocation()
                local dir = (fountain - cLoc):Normalized()
                local holdDist = (ownT1Hold and U.DistanceBetweenLocations(cLoc, ownT1Hold) <= 880) and 275 or 430
                local rawHold = cLoc + dir * holdDist
                -- `v7.9.15` (`auto-20261106-2139` `05:08.0` Unshielded River Walk-Up Fix):
                -- When `#allyCreeps == 0` and `bestC` is NOT imminently dying (`bestHP > atkDmg + 35`), NEVER walk off our
                -- T1 highground into `< 765u` of an armed live enemy hero just to stand `430u` from unengaged enemy creeps
                -- that are ALREADY marching straight to our T1!
                local WmodNoAlly = package.loaded["bots/nevermore/world"]
                local wsNoAlly = WmodNoAlly and WmodNoAlly.s
                local ehNoAlly = (wsNoAlly and wsNoAlly.enemy and U.CanQuery(wsNoAlly.enemy) and wsNoAlly.enemy:IsAlive() and wsNoAlly.enemy) or nil
                local killReadyNow = bestHP <= ((bot:GetAttackDamage() or 60) + 35)
                if ehNoAlly and not killReadyNow then
                    local eLocNA = ehNoAlly:GetLocation()
                    local enPotNA = ((ehNoAlly:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(ehNoAlly) or 0))
                    if enPotNA >= 75 and U.DistanceBetweenLocations(eLocNA, cLoc) <= 980 then
                        local safeStandNA = math.max(765, (U.GetDrySafeStandoffDist and U.GetDrySafeStandoffDist(bot, ehNoAlly)) or 765)
                        if U.DistanceBetweenLocations(rawHold, eLocNA) < safeStandNA then
                            local safeFromEn = eLocNA + (fountain - eLocNA):Normalized() * safeStandNA
                            local t1Close = P.GetT1Close(bot)
                            if t1Close and U.DistanceBetweenLocations(t1Close, fountain) <= U.DistanceBetweenLocations(safeFromEn, fountain) + 180
                                and U.DistanceBetweenLocations(t1Close, eLocNA) >= safeStandNA then
                                return t1Close
                            end
                            return safeNoShieldCS(safeFromEn)
                        end
                    end
                end
                return safeNoShieldCS(P.AvoidUphillMiss(bot, rawHold, cLoc))
            end
        end
        return P.GetT1Close(bot)
    end

    local enemyT1 = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
    local frontAlly = engagedAllyCreeps[1]
    local minDist = math.huge
    for _, c in pairs(engagedAllyCreeps) do
        if c and c:IsAlive() then
            local d = GetUnitToLocationDistance(c, enemyT1)
            if d < minDist then
                minDist = d
                frontAlly = c
            end
        end
    end
    local fLoc = frontAlly:GetLocation()
    local dir = (fountain - fLoc):Normalized()
    local WmodLive = package.loaded["bots/nevermore/world"]
    local wsLive = WmodLive and WmodLive.s
    local enemyDeadIdle = wsLive and wsLive.enemyAlive == false
    local waveZone = U.ClassifyWaveZone and U.ClassifyWaveZone(bot, allyCreeps, enemyCreeps) or "NONE"
    local deepChokeSpot = (mode ~= "PASSIVE") and (not enemyDeadIdle)
        and U.GetDeepEnemyT1ChokeSpot
        and U.GetDeepEnemyT1ChokeSpot(bot, wsLive, nil, allyCreeps, enemyCreeps) or nil
    if deepChokeSpot then
        return deepChokeSpot
    end
    local dominantIdle = (mode ~= "PASSIVE") and (not enemyDeadIdle)
        and U.IsLaneDominant and U.IsLaneDominant(bot, wsLive, nil) or false
    local salvingIdle = bot.HasModifier and bot:HasModifier("modifier_flask_healing") or false
    local waveGuardIdle = (not salvingIdle) and (not enemyDeadIdle) and (not dominantIdle)
        and U.CanGuardWaveReaggro and U.CanGuardWaveReaggro(bot, wsLive, nil) or false
    -- `v7.9.19` (`9080125239.dem` `06:04–06:18` `540u` FoW Dominance Whiplash Fix!):
    -- Only project `-175u` AHEAD of `frontAlly` when a live enemy hero is actually within `<= 1,180u` of `frontAlly`
    -- (capable of stepping up to pull creep aggro!). When the enemy stands `> 1,180u` away or flickers across the
    -- highground FoW boundary (`1,400..1,900u`), hold a steady `210u` CS stance so `wsLive.enemy` FoW flicker NEVER
    -- flips our anchor `+365u <-> -175u` (`540u` `180°` reversal!) every `0.5s`!
    local ehNearWaveForScreen = false
    if dominantIdle and wsLive then
        local ehCheck = (wsLive.enemy and U.CanQuery(wsLive.enemy) and wsLive.enemy:IsAlive() and wsLive.enemy:GetLocation())
            or (((wsLive.enemyAbsentFor or 99) <= 2.5) and wsLive.enemyLastLoc) or nil
        if ehCheck and U.DistanceBetweenLocations(fLoc, ehCheck) <= 1180 then
            ehNearWaveForScreen = true
        end
    end
    local enemyUncontestedIdle = enemyDeadIdle
        or (wsLive and (not wsLive.enemy) and ((wsLive.enemyAbsentFor or 99) >= 3.5) and (bot:GetHealth() or 0) >= 360)
    local dist_from_creeps = enemyUncontestedIdle and 205 or 365
    if dominantIdle then
        dist_from_creeps = (waveZone == "OWN_T1") and 135 or (ehNearWaveForScreen and -175 or 210)
    elseif waveGuardIdle then
        -- `v7.9.17` (`auto-20261107-0354` `00:22..00:28` & `02:41` Highground / Cooldown Wave-Perimeter Guard):
        -- Hold `135u` behind `frontAlly` on our highground lip (even if `State.defensive` passed `mode == "PASSIVE"`!) so the
        -- `500u` creep-aggro perimeter in front of `frontAlly` sits at `dHero = 615..665u` — dead inside outer `W(450)`!
        dist_from_creeps = 135
    elseif mode == "PASSIVE" then
        dist_from_creeps = 465
    elseif mode == "AGGRESSIVE" then
        dist_from_creeps = enemyUncontestedIdle and 175 or 305
    end
    if not dominantIdle and not waveGuardIdle and not enemyUncontestedIdle then
        local WV = package.loaded["bots/nevermore/wave"]
        if WV then dist_from_creeps = WV.WaveDist(bot, dist_from_creeps, mode) end
    end
    local aimRef = fLoc
    if prepareTarget and prepareTarget.GetLocation then
        aimRef = prepareTarget:GetLocation()
    elseif enemyCreeps then
        -- Prefer the lowest-HP active enemy creep (`<= 320 HP` or closest to dying) as `aimRef` so `AvoidUphillMiss`
        -- climbs onto THAT creep's Highground when safe, without getting distracted by a fresh 300 HP creep 950u away!
        local lowEc, lowHpEc = nil, math.huge
        for _, ec in pairs(enemyCreeps) do
            if ec and ec:IsAlive() then
                local chp = ec:GetHealth() or 9999
                if chp < lowHpEc then
                    lowHpEc, lowEc = chp, ec
                end
            end
        end
        if lowEc then
            aimRef = lowEc:GetLocation()
        end
    end
    local baseIdle = fLoc + dir * dist_from_creeps
    -- `v7.9.24-pro`: Whenever `aimRef` sits on higher elevation (`z = 128` plateau or upper staircase) than `baseIdle`,
    -- run the full multi-angle `P.AvoidUphillMiss` solver so SF steps ALL THE WAY onto `z = 128` Highground BEFORE the
    -- CS window opens (fixes the old `aimRef + dir * 245` cliff-drop into the river at `05:45..07:09` -> `0%` uphill miss!)
    if aimRef and not P.IsSameOrHigherElevation(baseIdle, aimRef, bot:GetLocation()) then
        baseIdle = P.AvoidUphillMiss(bot, baseIdle, aimRef)
    end
    -- `v7.9.17`: When holding `waveGuardIdle` against an armed `W(450)`-ready enemy (`enPot >= 75`), maintain a `>= 595u`
    -- standoff floor (up to `310u` behind `frontAlly`) so SF stays in the unanswerable outer `W` band (`595..685u`) and
    -- NEVER stands inside `< 575u` where enemy `W(450)` could trade back!
    if waveGuardIdle and wsLive and wsLive.enemy and U.CanQuery(wsLive.enemy) and wsLive.enemy:IsAlive() then
        local ehIdle = wsLive.enemy
        local enPotIdle = (U.GetPotentialManaForRaze and U.GetPotentialManaForRaze(ehIdle)) or (ehIdle:GetMana() or 0)
        local KrefIdle = package.loaded["bots/nevermore/combat"]
        local enMidReadyIdle = KrefIdle and KrefIdle.EnemyRazeReadyIn and (KrefIdle.EnemyRazeReadyIn("mid") <= 1.5) or true
        if enPotIdle >= 75 and enMidReadyIdle then
            local eLocWG = ehIdle:GetLocation()
            local dBaseEn = U.DistanceBetweenLocations(baseIdle, eLocWG)
            if dBaseEn < 595 then
                local stepBack = math.min(310, dist_from_creeps + (595 - dBaseEn))
                baseIdle = fLoc + dir * stepBack
            end
        end
    end
    -- Dry-Mana Idle Coil Guard (`v7.8.0`): never park idle wave stance inside enemy `R1`/`R2` (`745u`) or stacked `R3` (`990u`) when `< 75 MP`!
    if wsLive and wsLive.enemy and U.CanQuery(wsLive.enemy) and wsLive.enemy:IsAlive()
        and U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, wsLive.enemy, wsLive) then
        local dryStand = U.GetDrySafeStandoffDist(bot, wsLive.enemy)
        local eLocIdle = wsLive.enemy:GetLocation()
        if dryStand > 0 and U.DistanceBetweenLocations(baseIdle, eLocIdle) < dryStand then
            baseIdle = eLocIdle + (fountain - eLocIdle):Normalized() * dryStand
        end
    end
    -- Never step into unengaged marching enemy melee creeps before our wave meets them, and keep `>= 920u` off enemy T1!
    if dominantIdle then
        for _, ec in pairs(enemyCreeps or {}) do
            if ec and ec:IsAlive() and ((ec.GetAttackRange and ec:GetAttackRange()) or 100) < 250 then
                local okT, tgt = false, nil
                if ec.GetAttackTarget then okT, tgt = pcall(ec.GetAttackTarget, ec) end
                if not okT or tgt == nil then
                    local ecLoc = ec:GetLocation()
                    if U.DistanceBetweenLocations(baseIdle, ecLoc) < 235 then
                        baseIdle = ecLoc + dir * 235
                    end
                end
            end
        end
        if wsLive and wsLive.enemyT1Alive ~= false and wsLive.enemyT1Loc then
            local tLoc = wsLive.enemyT1Loc
            if U.DistanceBetweenLocations(baseIdle, tLoc) < 920 then
                baseIdle = tLoc + (fountain - tLoc):Normalized() * 920
            end
        end
    end
    -- Hold calm, rock-steady contested stance (`math.sin(GameTime()*2.15)*58` removed -> eliminates 116u artificial pacing reversals!)
    local res = P.AvoidUphillMiss(bot, baseIdle, aimRef)
    -- Forward-Zoning Enemy Guard (`R2_2044` `02:39` `A464(-348,-215)` & `03:53` `A300(-541,-360)` Root Cause!):
    -- Uses Beastmaster-filtered `wsLive.enemy` first, and holds `495u` (strictly outside `[176, 474]` `Q+W` overlap!)
    local eh = (wsLive and wsLive.enemy and U.CanQuery(wsLive.enemy) and wsLive.enemy:IsAlive() and wsLive.enemy) or nil
    if not eh and bot.GetNearbyHeroes then
        local nearEnemies = bot:GetNearbyHeroes(1500, true, BOT_MODE_NONE)
        for _, candH in pairs(nearEnemies or {}) do
            if candH and (not WmodLive or not WmodLive.IsFillerBeastmasterUnit or not WmodLive.IsFillerBeastmasterUnit(candH)) then
                eh = candH
                break
            end
        end
    end
    if eh and (not eh.CanBeSeen or eh:CanBeSeen()) and eh:IsAlive() and (eh:GetHealth() or 999) > 220 then
        local eLoc = eh:GetLocation()
        local dxE, dyE = fountain.x - eLoc.x, fountain.y - eLoc.y
        local dxR, dyR = fountain.x - res.x, fountain.y - res.y
        local eFntDist = math.sqrt(dxE * dxE + dyE * dyE)
        local rFntDist = math.sqrt(dxR * dxR + dyR * dyR)
        if rFntDist > eFntDist - 80 then
            local myHpNow = bot:GetHealth() or 0
            local ehHpNow = eh:GetHealth() or 999
            local canStandGround = (myHpNow >= 320 and myHpNow >= ehHpNow * 0.78 and mode ~= "PASSIVE")
            local standPad = canStandGround and 495 or ((mode == "PASSIVE") and 565 or 505)
            local homeDir = (fountain - eLoc):Normalized()
            res = P.AvoidUphillMiss(bot, eLoc + homeDir * standPad, eLoc)
        end
    end
    -- XP-Range Tether (`<= 1380u` inside Dota 2 `1500u` XP radius when an enemy creep is dying `<= 160 HP` and we are `>= 220 HP`!):
    if (bot:GetHealth() or 0) >= 220 and enemyCreeps and #enemyCreeps > 0 then
        local dyingCreep, minChp = nil, 161
        for _, ec in pairs(enemyCreeps) do
            if ec and U.CanQuery(ec) and ec:IsAlive() then
                local chp = ec:GetHealth() or 999
                if chp < minChp then minChp, dyingCreep = chp, ec end
            end
        end
        if dyingCreep then
            local dcLoc = dyingCreep:GetLocation()
            if U.DistanceBetweenLocations(res, dcLoc) > 1380 then
                local xpSpot = dcLoc + (fountain - dcLoc):Normalized() * 1360
                local safeT1 = not (wsLive and wsLive.enemyT1Alive ~= false and wsLive.enemyT1Loc
                    and U.DistanceBetweenLocations(xpSpot, wsLive.enemyT1Loc) < 900)
                if safeT1 then
                    res = xpSpot
                end
            end
        end
    end
    -- Fog-of-War Enemy T1 No-Shield Guard (`v3.9.0` + `v7.9.0` FoW `ws.enemy == nil` Fix!):
    -- MUST check `ws.enemyAlive ~= false` (NOT `ws.enemy`, which is `nil` when highground T1 drops into Fog of War!)
    local Wmod = package.loaded["bots/nevermore/world"]
    local ws = Wmod and Wmod.s
    if ws and ws.enemyT1Alive ~= false and ws.enemyT1Loc and ws.enemyAlive ~= false and #(allyCreeps or {}) == 0 then
        local tLoc = ws.enemyT1Loc
        local dT1 = U.DistanceBetweenLocations(res, tLoc)
        if dT1 < 895 then
            res = tLoc + (fountain - tLoc):Normalized() * 895
        end
    end
    return P.HoldOwnT1Highground(bot, res, enemyCreeps, allyCreeps)
end

return P
