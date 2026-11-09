local L = {}

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")

local lhMemoEpoch = -1
local lhMemoInvRev = -1
local creepSolveMemo = {}
local sharedSetupMemo = nil
local peekResultMemo = nil
local lockoutCSMemo = nil

local function syncLHMemo()
    if lhMemoEpoch ~= U._tickEpoch or lhMemoInvRev ~= U._invRev then
        lhMemoEpoch = U._tickEpoch
        lhMemoInvRev = U._invRev
        for k in pairs(creepSolveMemo) do creepSolveMemo[k] = nil end
        sharedSetupMemo = nil
        peekResultMemo = nil
        lockoutCSMemo = nil
    end
end

L._prepCreep = nil
L._prepStartLAT = -100
L._prepExpire = 0

local RAZE_SPECS = {
    { slot = "nevermore_shadowraze1", idx = 0, dist = 200, radius = 250 },
    { slot = "nevermore_shadowraze2", idx = 1, dist = 450, radius = 250 },
    { slot = "nevermore_shadowraze3", idx = 2, dist = 700, radius = 250 },
}

local function BuildAllAttackers(bot, enemyCreeps, allyCreeps, enemyTowers, allyTowers, enemyHero)
    local enemySide = {} -- Units attacking OUR creeps (for denies)
    local allySide  = {} -- Units attacking ENEMY creeps (for last hits)
    for _, c in pairs(enemyCreeps or {}) do
        if U.CanQuery(c) then enemySide[#enemySide + 1] = c end
    end
    for _, t in pairs(enemyTowers or {}) do
        if U.CanQuery(t) then enemySide[#enemySide + 1] = t end
    end
    if enemyHero and U.CanQuery(enemyHero) then
        enemySide[#enemySide + 1] = enemyHero
        allySide[#allySide + 1]   = enemyHero -- Rival denies count on contested enemy creeps!
    end
    for _, c in pairs(allyCreeps or {}) do
        if U.CanQuery(c) then allySide[#allySide + 1] = c end
    end
    for _, t in pairs(allyTowers or {}) do
        if U.CanQuery(t) then allySide[#allySide + 1] = t end
    end
    return allySide, enemySide
end
L.BuildAllAttackers = BuildAllAttackers

-- True when the opposing mid hero has zero coil mana (`< 75`), is not mid-cast, and stands well outside
-- physical right-click reach (`> enAtkRange + 150 = 675u`) while we hold enough HP (`>= max(135, 1.6x auto)`):
-- prevents conceding uncontested CS or under-tower prep when the enemy literally cannot punish us!
function L.EnemyCannotPunishLane(bot, enemyHero, hp)
    if not enemyHero or not U.CanQuery(enemyHero) or not enemyHero:IsAlive() then return false end
    local enPotMana = U.GetPotentialManaForRaze(enemyHero) or 0
    if enPotMana >= 75 then return false end
    if enemyHero.IsUsingAbility and enemyHero:IsUsingAbility() then return false end
    local d = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local enAtkRange = (enemyHero.GetAttackRange and enemyHero:GetAttackRange()) or 525
    if d <= enAtkRange + 150 then return false end
    local raw = ((enemyHero.GetAttackDamage and enemyHero:GetAttackDamage()) or 55) + 4
    local enOneAuto = bot.GetActualIncomingDamage and bot:GetActualIncomingDamage(raw, DAMAGE_TYPE_PHYSICAL) or raw
    return (hp or bot:GetHealth() or 0) >= math.max(135, enOneAuto * 1.6)
end

local function IsPositionLethalFromEnemy(bot, checkLoc, enemyHero, race, isDeny)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local hp = bot:GetHealth()
    local maxHP = math.max(1, bot:GetMaxHealth())
    local hpPct = hp / maxHP
    local bLoc = bot:GetLocation()
    local eLoc = enemyHero:GetLocation()
    local d = U.DistanceBetweenLocations(checkLoc, eLoc)
    local dNow = U.DistanceBetweenLocations(bLoc, eLoc)
    local enPotMana = U.GetPotentialManaForRaze(enemyHero)
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    myStacks = myStacks or 0
    myRem = myRem or 0

    -- 0. Shadowraze Debuff Stack Discipline (`R1_2039` `01:59.73` + `auto-20261022-2237` Death #1 `05:39.03` Root Cause!):
    --   (a) With >= 2 active stacks (`myRem > 0.35s`) and enemy `enPotMana >= 75` (INCLUDING Mango/Stick!),
    --       a 3rd coil hits for `210..380+` magic damage up to `950u` — NEVER turn around toward a creep inside `965u`!
    --   (b) With 1 active stack (`myRem > 0.20s` — INCLUDING fresh `7.8s` stack right after `Shadowraze3` hit at `05:38.80`!):
    --       NEVER step forward inside enemy's READY remaining bands (`W <= 715u` / `Q <= 475u` when `enPotMana >= 75`)!
    --       Conversely, if enemy just spent `Z` (`700u` on `10s` CD), `[720u..900u]` is 100% safe for ranged CS!
    local lrCheck = U.SolveLethalRace(bot, enemyHero, U._W and U._W.s or nil)
    if lrCheck and lrCheck.winsFirstKill then
        return false
    end

    local K = U._K
    local myPotManaEarly = (K and K.MyManaBudget and K.MyManaBudget(bot, true)) or (bot:GetMana() or 0)
    if myStacks >= 2 and myRem > 0.35 and enPotMana >= 75 and not (race and race.valid and race.canKillNow) then
        -- `v7.9.19` (`9080125239.dem` `08:02.60 & 08:04.00` `994 HP` Lvl-8 vs Lvl-6 Missed CS Fix):
        -- Respect the enemy's ACTUAL off-cooldown raze reach (`readyReach2`: e.g. `725u` right after enemy cast `E(700)`!)
        -- AND only treat a 3rd stack as lethal CS-veto when a 3rd coil + follow-up genuinely threatens our current HP!
        local readyReach2 = (K and K.EnemyMinSafeDistance and K.EnemyMinSafeDistance(enemyHero, 0.90)) or 980
        local enOneAuto2 = (K and K.AttackDamageVs and K.AttackDamageVs(enemyHero, bot)) or 58
        local thirdRazeEst = (K and K.EnemyRazeDamage and K.EnemyRazeDamage(bot, enemyHero, 1)) or 240
        local twoStackThreatensLife = (hp <= thirdRazeEst + enOneAuto2 * 2.2 + 215) or (hpPct <= 0.64)
        if twoStackThreatensLife and d < math.min(980, math.max(500, readyReach2)) then
            return true
        end
    end
    if myStacks == 1 and myRem > 0.20 and enPotMana >= 75 and not (race and race.valid and race.canKillNow) then
        local readyReach = (K and K.EnemyMinSafeDistance and K.EnemyMinSafeDistance(enemyHero, 0.8)) or 760
        -- `v7.9.28-pro` (`auto-20261108-2049` `0:39` `E774` `39 HP` & `E780` `5 HP` Stack-1 Highground CS Fix!):
        --   * When Enemy ALREADY spent `Shadowraze3 (far)` (`enFarOnCd1 == true`), his ONLY remaining mid/close razes are
        --     `W(450)` (`<= 700u` circle) and `Q(200)` (`<= 450u`). If we hold a decisive non-lethal HP cushion on equal/higher
        --     elevation (`healthyStack1Cushion`), cap `forbidDist` at `685u` (outside `W(450)`!) or `515u` when standing on
        --     our own Highground above a lowground rival with `myHp >= enHp + 145`, NEVER surrendering creeps under our T1!
        local enFarOnCd1 = (K and K.EnemyRazeReadyIn and K.EnemyRazeReadyIn("far") > 2.0) or false
        local nextStackEst1 = (K and K.EnemyRazeDamage and K.EnemyRazeDamage(bot, enemyHero, 1)) or 150
        local enAutoEst1 = (K and K.AttackDamageVs and K.AttackDamageVs(enemyHero, bot)) or 54
        local enHpNow1 = enemyHero:GetHealth() or 9999
        local hgOverEnemy1 = ((checkLoc.z or 0) >= (eLoc.z or 0) + 40)
        local healthyStack1Cushion = enFarOnCd1 and (not isDeny)
            and (hp >= nextStackEst1 + enAutoEst1 * 2.0 + 135)
            and (hgOverEnemy1 or hp >= enHpNow1 + 125)
        local forbidDist
        if healthyStack1Cushion then
            forbidDist = (hgOverEnemy1 and hp >= enHpNow1 + 145 and hp >= nextStackEst1 + enAutoEst1 * 2.5 + 175)
                and 515
                or math.min(685, readyReach)
        else
            -- When we are ALSO dry (`myPotManaEarly < 75` = 0 coils to answer!), respect the FULL `readyReach` (`~980u` if R3 ready)
            -- immediately instead of capping at `725u` and eating a free stacked `R3` (`ShaNachnetsya` `02:23–02:40` Fix)!
            forbidDist = (myPotManaEarly < 75 or myRem <= 2.15) and math.max(760, readyReach) or math.min(735, readyReach)
        end
        if d < forbidDist then return true end
    end

    -- 1. NEVER walk into an actively casting enemy Shadowraze circle when raze puts us in combo range or < 55% HP!
    if enemyHero:IsUsingAbility() then
        local eFace = (enemyHero.GetFacing and enemyHero:GetFacing()) or 0
        local rad = math.rad(eFace)
        for _, rz in ipairs({ 200, 450, 700 }) do
            local spot = Vector(eLoc.x + math.cos(rad) * rz, eLoc.y + math.sin(rad) * rz, eLoc.z or 128)
            if U.DistanceBetweenLocations(checkLoc, spot) <= 255 then
                local oneR = (race and race.valid and race.oneRaze) or 220
                if hp <= oneR * 1.85 or hpPct <= 0.58 or myStacks >= 1 then
                    return true
                end
            end
        end
    end
    -- 2. Exact Reachable Burst Check at `checkLoc` over the CS strike window (`0.85s` — NEVER false-blocking safe CS at `700..850u`!):
    if K and K.EnemyBurstVs and not (race and race.valid and race.canKillNow) then
        local burstAtCheck = K.EnemyBurstVs(bot, enemyHero, d, 0.85, false)
        if burstAtCheck + 35 >= hp then
            return true
        end
    end
    local myPotMana = (K and K.MyManaBudget and K.MyManaBudget(bot, true)) or (bot:GetMana() or 0)
    local rawEnCastable = (K and K.EnemyCastableRazeCount and K.EnemyCastableRazeCount(enemyHero, 2.5)) or 0
    local maxManaCastable = math.max(0, math.floor((enPotMana or 0) / 75))
    local enCastable = math.min(rawEnCastable, maxManaCastable)
    local enOneAuto = (K and K.AttackDamageVs and K.AttackDamageVs(enemyHero, bot)) or 52

    -- 2B. Dry-Mana vs Multi-Raze Execution Guard (`9069188041.dem` `02:01.0`, `9070886384.dem` `03:54.40` & `ShaNachnetsya` `02:22–02:40` Fix!):
    -- When we have `< 75` potential mana (ZERO Razes to trade back!), NEVER walk inside `R1` (`< 500u`) against ANY armed SF,
    -- NEVER walk inside `R2` (`< 705u` for denies or `< 665u` for melee CS) against a `2+`-coil (`>= 150 MP`) SF even at full HP
    -- (`874 -> 159 HP` 4-coil shred at `02:22`!), and keep lethal burst thresholds strict. Ranged/max-range CS at `>= 705u` stays open!
    if U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, enemyHero, U._W and U._W.s) and not (race and race.valid and race.canKillNow) then
        local nearReady = not (K and K.EnemyRazeReadyIn) or K.EnemyRazeReadyIn("near") <= 1.4
        local midReady  = not (K and K.EnemyRazeReadyIn) or K.EnemyRazeReadyIn("mid") <= 1.4
        if nearReady and d < 500 then
            return true
        end
        if enCastable >= 2 and midReady then
            local twoCastDry = (K and K.EnemyCastableRazeDamage and K.EnemyCastableRazeDamage(bot, enemyHero, 2, nil, 2.5)) or 220
            local myStacksDry = (U.GetShadowrazeDebuff and U.GetShadowrazeDebuff(bot)) or 0
            local enHighTierDry = ((enemyHero.GetLevel and enemyHero:GetLevel()) or 1) >= 5
            -- `auto-20261108-0512` `01:08–02:25` `0`-Deny Paralysis Fix:
            -- Only hard-ban max-range CS (`< 665u`) / denies (`< 735u`) when 2 coils + 2 autos actually threaten low HP,
            -- we already carry a raze stack, or Lvl 5+ Raze-3 shred requires stepping inward (`d < dNow - 14`)!
            if myStacksDry >= 1 or hp <= (twoCastDry + enOneAuto * 2.0 + 135) or (enHighTierDry and d < dNow - 14) then
                if isDeny and d < 735 then return true end
                if d < 665 then return true end
            end
        end
    end
    if myPotMana < 75 and enCastable >= 2 and not (race and race.valid and race.canKillNow) then
        local twoCastR = (K and K.EnemyCastableRazeDamage and K.EnemyCastableRazeDamage(bot, enemyHero, 2, nil, 2.5)) or 0
        if hp <= twoCastR + enOneAuto + 30 and d < 745 then
            return true
        end
        if enCastable >= 3 then
            local threeCastR = (K and K.EnemyCastableRazeDamage and K.EnemyCastableRazeDamage(bot, enemyHero, 3, nil, 2.5)) or 0
            if hp <= threeCastR + enOneAuto + 25 and d < 680 then
                return true
            end
        end
    end

    if race and race.valid and not race.canKillNow and not (race.canKillSoon and (race.edge or 0) >= -25) then
        if race.heCanKillNow then
            if d < math.max(780, (race.minSafeDist or 860) - 55) then return true end
        elseif race.heCanKillSoon and not race.canKillSoon then
            local twoR = race.twoRaze or ((race.oneRaze or 180) * 2.2)
            local outLeveledOrBootless = race.heHasBootsLead or ((enemyHero:GetLevel() or 1) > (bot:GetLevel() or 1))
            if outLeveledOrBootless and hp <= twoR + 95 then
                if d < 715 then return true end
            elseif hp <= twoR + 40 and d < 640 then
                return true
            end
        end
    end

    -- 2C. Level-Spike & Out-Razed Tier Respect (`auto-20261031-0230` `00:59.3` Lvl 1 vs Lvl 2, `01:51.1` & `02:00.4` Lvl 2 vs Lvl 3 Fix!):
    --   * At Lvl 1 vs Lvl 2+, enemy has `Necromastery + Raze` while we have 0 Necromastery (`43` dmg) — NEVER step into `d < 605`
    --     when below `430 HP` or surrounded by enemy creeps!
    --   * When down a Raze tier (`Lvl 2 vs Lvl 3` = `69` vs `124+161 = 285` dmg!), NEVER walk forward into `R2` (`d < 720u`)
    --     to deny an allied creep (`isDeny == true`), nor enter `d < 695u` when enemy holds `>= 2` castable Razes!
    local myLvlNow = (bot.GetLevel and bot:GetLevel()) or 1
    local enLvlNow = (enemyHero.GetLevel and enemyHero:GetLevel()) or 1
    local outLeveledNow = enLvlNow > myLvlNow
    -- `v7.9.27-pro` (`auto-20261108-2026` `01:10` `E1796` `14 HP` Fix):
    -- Hero Level 2 CANNOT skill Level 2 Shadowraze in Dota 2 (basic ability Lvl 2 requires Hero Level 3!).
    local outRazedNow = (U.IsOutRazedTier and U.IsOutRazedTier(bot, enemyHero)) or (myLvlNow == 1 and enLvlNow >= 3)
    if outLeveledNow and not (race and race.valid and race.canKillNow) then
        local wsCheck = U._W and U._W.s
        local nearEnemyCreeps = 0
        for _, ec in pairs((wsCheck and wsCheck.enemyCreeps) or {}) do
            if U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(checkLoc, ec:GetLocation()) <= 285 then
                nearEnemyCreeps = nearEnemyCreeps + 1
            end
        end
        if myLvlNow == 1 and (hp <= 430 or nearEnemyCreeps >= 2) and d < 605 then
            return true
        end
        if outRazedNow and enCastable >= 1 then
            local twoCastOut = (K and K.EnemyCastableRazeDamage and K.EnemyCastableRazeDamage(bot, enemyHero, 2, nil, 2.5))
                or ((K and K.EnemyRazeDamage and K.EnemyRazeDamage(bot, enemyHero, 2)) or 260)
            if isDeny and d < dNow - 12 and d < 725 and hp <= twoCastOut + enOneAuto * 1.5 + 150 then
                return true
            end
            if enCastable >= 2 and d < 695 and hp <= twoCastOut + enOneAuto + 265 then
                return true
            end
        end
    end

    -- 2D. `v7.9.25-pro` (`auto-20261108-1609` `02:27..02:31` River Lowground vs Highground Enemy Pulled-Deny Trap Fix!):
    -- NEVER walk onto river lowground (`eZ - checkZ >= 42`, `25%` uphill miss!) within right-click reach (`<= enRange + 75`)
    -- of a healthy Highground Enemy SF (`100%` downhill hit!) just to right-click-deny a pulled allied creep (`isDeny == true`)
    -- when the enemy holds a soul/damage lead (`enOneAuto >= myAtk + 4`) or our HP is `<= 465`!
    local enRangeCheck = (enemyHero.GetAttackRange and enemyHero:GetAttackRange()) or 525
    if isDeny and not (race and race.valid and race.canKillNow) then
        local eZNow = (eLoc and eLoc.z) or 0
        local cZNow = (checkLoc and checkLoc.z) or 0
        local uphillDeny = (eZNow - cZNow) >= 42
        if not uphillDeny and type(GetHeightLevel) == "function" then
            local okE, hE = pcall(GetHeightLevel, eLoc)
            local okC, hC = pcall(GetHeightLevel, checkLoc)
            if okE and okC and type(hE) == "number" and type(hC) == "number" and hE > hC then
                uphillDeny = true
            end
        end
        if uphillDeny and d <= (enRangeCheck + 75) and (enemyHero:GetHealth() or 999) > 185 then
            local myAtkCheck = (bot.GetAttackDamage and bot:GetAttackDamage()) or 55
            if enOneAuto >= (myAtkCheck + 4) or hp <= 465 then
                return true
            end
        end
    end

    -- 3. Low-HP lethal burst & close physical execution fallback (`auto-20261031-0230` `02:08.3` `180 HP` vs `68 MP` Lvl-3 SF Fix!):
    --    Even if `enPotMana < 75`, walking inside `<= 665u` at `<= 3.25` right-clicks of HP in the open river hands enemy
    --    lethal physical autos — EXCEPT (`v7.9.31-pro` `auto-20261109-0026` `1:43` `tk=6038..6056` `50 HP` `M159` Own-T1 Fix!)
    --    when `checkLoc` sits directly under our own alive T1 (`<= 540u` from `allyT1Loc`) while a `0`-coil (`enPotMana < 75`)
    --    enemy stands outside right-click range (`d >= enRangeCheck + 35`) and outside our T1 (`>= 660u`), where our T1 umbrella
    --    prevents him from walking in to right-click us!
    local wsSafeT1 = U._W and U._W.s or nil
    local ownT1Umbrella = (not isDeny)
        and (enPotMana < 75)
        and (hp >= math.max(155, enOneAuto * 2.15))
        and (d >= enRangeCheck + 35)
        and wsSafeT1 and wsSafeT1.allyT1Alive ~= false and wsSafeT1.allyT1Loc
        and (U.DistanceBetweenLocations(checkLoc, wsSafeT1.allyT1Loc) <= 540)
        and (U.DistanceBetweenLocations(eLoc, wsSafeT1.allyT1Loc) >= 660)
    if hp <= math.max(210, enOneAuto * 3.25) and not ownT1Umbrella and not (race and race.valid and race.canKillNow) then
        if d < enRangeCheck + 145 then return true end
    end
    if hpPct <= 0.36 and enPotMana >= 150 then
        if d < 595 then return true end
    end
    -- 4. No Walk-Through-Enemy for Out-of-Range Back-Wave Creep (`R1_2039` `02:35`, `R2_2044` `02:31`,
    --    & `9081989180.dem` `01:16.10..01:19.17` `d=197u` Walk-Past-Enemy-Into-`Q(200)`-For-Ranged-Deny Fix!):
    -- Compute exact 2D point-to-segment distance `minPathDist` from `eLoc` to `[bLoc, checkLoc]`!
    --   * NEVER walk past/through an enemy hero (`minPathDist < 455` or `d < 435`) for an allied DENY (`isDeny == true`)!
    --   * NEVER walk straight through `enemyHero`'s `Q(200)` body (`minPathDist < 345`) for a back-row creep (even if
    --     `enHp <= 205`, unless `enemy` is 1-shot OOM and we are killing `enemy`, NOT walking past `enemy` to hit a creep!).
    local moveDist = U.DistanceBetweenLocations(bLoc, checkLoc)
    local enHp = enemyHero:GetHealth() or 999
    local minPathDist = d
    if moveDist > 1.0 then
        local vx, vy = checkLoc.x - bLoc.x, checkLoc.y - bLoc.y
        local wx, wy = eLoc.x - bLoc.x, eLoc.y - bLoc.y
        local lenSq = vx * vx + vy * vy
        local tSeg = (lenSq > 1.0) and math.max(0.0, math.min(1.0, (wx * vx + wy * vy) / lenSq)) or 1.0
        local px, py = bLoc.x + tSeg * vx, bLoc.y + tSeg * vy
        minPathDist = math.sqrt((eLoc.x - px) * (eLoc.x - px) + (eLoc.y - py) * (eLoc.y - py))
    end
    -- `auto-20261102-0007` `10:07.53` (`325 HP` @ `d=414u`) In-Range Flee Turn-Back Fix:
    -- Even when `moveDist == 0` (creep ALREADY inside `525u` range), stopping `0.55s` + spinning `162 deg` backward
    -- while actively fleeing a healthy pursuing hero (`dNow < 760` & `hp <= 360` & `hp < enHp - 180`) is lethal!
    local stNow = U._State
    local nowG = GameTime()
    local activeCritFlee = stNow and (nowG < (stNow.critDangerHystUntil or 0) or nowG < (stNow.fleeUntil or 0))
    if (activeCritFlee or (hp <= 360 and hp < enHp - 180)) and enHp > 240 and dNow < 760
        and not (race and race.valid and (race.canKillNow or race.canKillSoon)) then
        local beingChasedOrHit = (enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.8))
            or ((U.EnemyApproachSpeed and U.EnemyApproachSpeed(bot, enemyHero) or 0) > 55)
        if beingChasedOrHit then
            return true
        end
    end
    if moveDist > 25 and d < dNow - 12 then
        if isDeny and not (race and race.valid and race.canKillNow) then
            -- Never walk past/into an enemy hero (`< 455u` path or `< 435u` endpoint) just to deny an allied creep!
            if minPathDist < 455 or d < 435 then
                return true
            end
        end
        local myAtkWalk = (bot.GetAttackDamage and bot:GetAttackDamage()) or 55
        local oneShotOOMEnemy = (enHp <= myAtkWalk * 1.05) and (enPotMana < 75)
        if not oneShotOOMEnemy then
            if minPathDist < 345 or d < 340 then return true end
            local beingHit = (enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
                or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.5))
            -- `v4.2.0` Equal-State Stand-Ground Rule (`Demo 2` 25-concession fix!):
            -- NEVER abandon every creep in `560u` on EVEN or WINNING HP (`hp >= enHp - 95` or `hp > 430`)!
            if beingHit and d < 560 and ((hp < enHp - 95 and hp <= 430) or hp <= 285) then
                return true
            end
        end
    end
    return false
end
L.IsPositionLethalFromEnemy = IsPositionLethalFromEnemy

-- Evaluate every enemy & ally creep on exact 30 Hz integer trajectory ticks
function L.ScanCreepCandidates(bot, enemyCreeps, allyCreeps, allySideAttackers, enemySideAttackers, enemyHero, race)
    local candidates = {}
    local useMemo = U._inThink
    if useMemo then syncLHMemo() end

    local function evalList(list, isDeny, attackers)
        local curTickScan = math.floor(GameTime() * 30.0 + 0.5)
        local ownRec = U._unitTrack[bot]
        local curAtkTarget = (bot.GetAttackTarget and bot:GetAttackTarget()) or nil
        local bLoc = bot:GetLocation()
        local maxR = (bot:GetAttackRange() or 525) + 42
        local wsEval = U._W and U._W.s or nil
        local enT1Eval = (wsEval and wsEval.enemyT1Alive ~= false) and wsEval.enemyT1Loc or nil
        local botOutsideEnT1 = enT1Eval and (U.DistanceBetweenLocations(bLoc, enT1Eval) > 880) or false
        local liveEnStrong = enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive() and ((enemyHero:GetHealth() or 0) > 220)
        for _, c in pairs(list or {}) do
            if U.CanQuery(c) and c:GetHealth() > 0 then
                -- `v7.9.25-pro` (`auto-20261108-1609` `02:13..02:18` Behind-Enemy-T1 Pulled-Wave Ignore):
                -- When the enemy SF drags an allied creep deep under/behind his T1 (`< 760u` from `enemyT1`) while we are
                -- outside (`> 880u`) and he is healthy (`> 220 HP`), skip that doomed allied creep so SF never marches across
                -- the river onto Enemy Highground with `0` enemy creeps!
                local skipPulledDeepAlly = isDeny and botOutsideEnT1 and liveEnStrong
                    and (U.DistanceBetweenLocations(c:GetLocation(), enT1Eval) < 760)
                if not skipPulledDeepAlly then
                local kOpen, kTargetImpact, effClose, gamble, ctx
                local totalT, launchT, wT, fT, turnT, walkT, cdT
                local cm = useMemo and creepSolveMemo[c] or nil
                if cm and cm.attackers == attackers then
                    kOpen = cm.kOpen
                    if kOpen ~= -2 then
                        kTargetImpact, effClose, gamble, ctx = cm.kTargetImpact, cm.effClose, cm.gamble, cm.ctx
                        totalT, launchT, wT, fT, turnT, walkT, cdT = cm.totalT, cm.launchT, cm.wT, cm.fT, cm.turnT, cm.walkT, cm.cdT
                    end
                else
                    kOpen, kTargetImpact, effClose, gamble, ctx = U.GetExactKillableInfo(bot, c, attackers)
                    if kOpen ~= -2 then
                        totalT, launchT, wT, fT, turnT, walkT, cdT = U.GetExactBallisticTicks(bot, c)
                    end
                    if useMemo then
                        creepSolveMemo[c] = {
                            attackers = attackers,
                            kOpen = kOpen,
                            kTargetImpact = kTargetImpact,
                            effClose = effClose,
                            gamble = gamble,
                            ctx = ctx,
                            totalT = totalT,
                            launchT = launchT,
                            wT = wT,
                            fT = fT,
                            turnT = turnT,
                            walkT = walkT,
                            cdT = cdT,
                        }
                    end
                end
                if kOpen ~= -2 then -- -2 = already fatally struck by our own mid-air projectile!
                    -- `A01` + `v7.9.16` Pre-Release Mid-Swing Preservation (`auto-20261107-0255` `02:34.60` Flagbearer & `03:48.33` Melee Fix):
                    -- Keep remaining `math.max(0, launchTick - curTick) + fT` across `[curTick - 4 .. launchTick]` while `wasAnim` is active
                    -- so integer windup rounding NEVER drops `activeRemT` to `nil` 1 tick before projectile release!
                    local activeRemT = nil
                    local nearRelease = false
                    if ownRec and ownRec.wasAnim and ownRec.launchTick and curTickScan <= (ownRec.launchTick + 4) and curAtkTarget == c then
                        local remWind = math.max(0, ownRec.launchTick - curTickScan)
                        activeRemT = remWind + fT
                        nearRelease = (remWind <= 2)
                    end
                    local cLoc = c:GetLocation()
                    local dxC, dyC = cLoc.x - bLoc.x, cLoc.y - bLoc.y
                    local distNow = math.sqrt(dxC * dxC + dyC * dyC)
                    local reqLoc = bLoc
                    if (not (ownRec and ownRec.wasAnim and curAtkTarget == c)) and distNow > maxR and distNow > 0.01 then
                        reqLoc = cLoc + (bLoc - cLoc):Normalized() * (maxR - 12)
                    end
                    local shotYaw = (distNow > 0.01) and (math.deg(math.atan2(dyC, dxC)) % 360) or ((bot.GetFacing and bot:GetFacing()) or 0)
                    local lethalRightClick = IsPositionLethalFromEnemy(bot, reqLoc, enemyHero, race, isDeny)
                    local nm = (c:GetUnitName() or ""):lower()
                    local isRangedCreep = nm:find("ranged") ~= nil
                    local isSiegeCreep  = nm:find("siege") ~= nil
                    local isFlagbearer  = U.IsFlagbearerCreep and U.IsFlagbearerCreep(c) or (nm:find("flagbearer") ~= nil)
                    candidates[#candidates + 1] = {
                        creep = c,
                        isDeny = isDeny,
                        isRanged = isRangedCreep,
                        isSiege = isSiegeCreep,
                        isFlagbearer = isFlagbearer,
                        nearRelease = nearRelease,
                        shotLoc = reqLoc,
                        shotYaw = shotYaw,
                        enemyHero = enemyHero,
                        kOpen = kOpen,
                        kTargetImpact = kTargetImpact,
                        effClose = effClose,
                        gamble = gamble,
                        ctx = ctx,
                        totalT = totalT,
                        activeRemT = activeRemT,
                        launchT = launchT,
                        wT = wT,
                        fT = fT,
                        turnT = turnT,
                        walkT = walkT,
                        cdT = cdT,
                        distNow = distNow,
                        lethalRightClick = lethalRightClick,
                    }
                end
                end
            end
        end
    end

    evalList(enemyCreeps, false, allySideAttackers)
    evalList(allyCreeps, true, enemySideAttackers)
    return candidates
end

-- Select optimal right-click target with strict Last-Hit > Deny collision arbitration
-- `v7.9.16` (`auto-20261107-0255` `02:34.93` Flagbearer + `02:41.73` & `03:40.33` Sequential Deny->LH Solver):
--   1. Exact Source 2 two-target sequential cooldown solver (`launchE = denyLaunch + max(spaTicks, walkAE + turnAE + wT_E)`):
--      movement & turning overlap with the `(spaTicks - wT_E)` reload phase after `denyLaunch`, and denying `cand.creep`
--      removes `cand.creep`'s future DPS on `ecand.creep` (`U.PredictCloseAfterRemovingAttacker`)!
--   2. When a ready-now deny (`freshDelta <= 5`) is 100% proven NOT to block ANY reachable enemy CS (`blocksEnemyLH == false`)
--      and every enemy CS is still in future waiting slack (`freshDelta_E > 6`), take the free deny NOW and chain into the
--      enemy CS on reload instead of standing idle watching the allied creep die!
--   3. First-class Flagbearer priority (`+38.0` enemy CS / `+20.0` deny) + `nearRelease` pre-launch commit shield (`+95.0`).
function L.SelectBestRightClickPlan(bot, candidates, siegingEnemyT1)
    local spaTicks = math.ceil((bot:GetSecondsPerAttack() or 1.25) * 30.0 - 1e-4)
    local atkRange = (bot:GetAttackRange() or 525) + 24
    local ms = math.max(100, (bot.GetCurrentMovementSpeed and bot:GetCurrentMovementSpeed()) or 305)
    local pSpeed = math.max(1, U.GetProjectileSpeedOf(bot))
    local cone = (C.BALLISTIC and C.BALLISTIC.ATTACK_FACING_CONE) or 11.5
    local degPerTick = (C.BALLISTIC and C.BALLISTIC.SF_DEG_PER_TICK)
        or math.deg(((C.BALLISTIC and C.BALLISTIC.SF_TURN_RATE) or 0.90) / 0.03 * (1.0 / 30.0))

    -- Collect all reachable enemy last-hit candidates so a deny is tested against EVERY upcoming enemy CS!
    local enemyLHCands = {}
    for _, cand in ipairs(candidates) do
        if not cand.isDeny and not cand.lethalRightClick and cand.kOpen >= 0 and cand.kOpen <= 80 then
            local effT = cand.activeRemT or cand.totalT
            local reachPad = cand.nearRelease and 3 or 1
            if effT <= cand.effClose + reachPad then
                enemyLHCands[#enemyLHCands + 1] = cand
            end
        end
    end

    local best = nil
    local bestScore = -1e9

    local wsSel = U._W and U._W.s or nil
    local enemyDeadSel = wsSel and wsSel.enemyAlive == false
    local enemyHero = (wsSel and wsSel.enemy) or (candidates[1] and candidates[1].enemyHero) or nil
    local isDominantCS = (not siegingEnemyT1) and U.IsLaneDominant and U.IsLaneDominant(bot, nil, nil) or false
    local denyMaxSlack = siegingEnemyT1 and 3 or (enemyDeadSel and 22 or (isDominantCS and 16 or 12))
    for _, cand in ipairs(candidates) do
        local effT = cand.activeRemT or cand.totalT
        local myMinNow = (cand.creep and U.CanQuery(cand.creep)) and U.SFDamageRange(bot, cand.creep).min or 0
        local oneShotNow = (cand.creep and U.CanQuery(cand.creep)) and ((cand.creep:GetHealth() or 9999) <= (myMinNow + 2)) or false
        local oneShotEnemyInRange = oneShotNow and (not cand.isDeny) and cand.kOpen == 0 and (cand.distNow or 9999) <= (atkRange + 35)
        local activeSwingOnEnemyOneShot = (cand.activeRemT ~= nil) and oneShotNow and (not cand.isDeny)
        local commitNearRelease = cand.nearRelease and oneShotNow
        -- `v7.9.29-pro` + `v7.9.31-pro` (`auto-20261108-2131` `01:43` `8 HP` `E1967` + `auto-20261109-0026` `R714` Anti-Stutter Fix):
        -- When an enemy creep is ALREADY 1-shottable (`kOpen == 0`) inside range and about to die (`effClose <= 26`),
        -- race the free 0-mana swing ONLY when `effT <= effClose + 8` (or `"max"` mode still leaves a real low-roll survival
        -- chance at `effT - 2`), preventing impossible `15`-tick-late swings from starving adjacent under-T1 prep (`M1392`)!
        local freeLastChanceSwing = false
        if oneShotEnemyInRange and (cand.effClose or 999) <= 28 then
            local canSurviveLowRoll = cand.ctx
                and (U.PredictHPWithContext(cand.ctx, cand.creep, math.max(0, effT - 2) / 30.0, "max") > 0)
                or false
            if effT <= (cand.effClose or 999) + 8 or canSurviveLowRoll then
                freeLastChanceSwing = true
                for _, oc in ipairs(enemyLHCands) do
                    if oc.creep ~= cand.creep and (oc.effClose or 999) <= (effT + spaTicks + 14) then
                        freeLastChanceSwing = false
                        break
                    end
                end
            end
        end
        local reachPad = (freeLastChanceSwing and 10)
            or (activeSwingOnEnemyOneShot and 8)
            or (((commitNearRelease or oneShotEnemyInRange) and not cand.isDeny) and 6 or (commitNearRelease and 3 or 1))
        local horizonOk = (not cand.isDeny and cand.kOpen >= 0 and cand.kOpen <= 68)
            or (cand.isDeny and cand.kOpen >= 0 and (cand.kTargetImpact - effT) <= denyMaxSlack)
        if not cand.lethalRightClick and (horizonOk or commitNearRelease) then
            if effT <= cand.effClose + reachPad then
                local blocksEnemyLH = false
                if cand.isDeny and #enemyLHCands > 0 then
                    local denyLaunch = (cand.activeRemT ~= nil)
                        and math.max(0, cand.activeRemT - cand.fT)
                        or math.max(cand.launchT, cand.kTargetImpact - cand.fT)
                    local denyImpact = denyLaunch + cand.fT
                    local shotLocA = cand.shotLoc or bot:GetLocation()
                    local yawA = cand.shotYaw or ((bot.GetFacing and bot:GetFacing()) or 0)

                    for _, ecand in ipairs(enemyLHCands) do
                        local ecLoc = ecand.creep:GetLocation()
                        local dx, dy = ecLoc.x - shotLocA.x, ecLoc.y - shotLocA.y
                        local dAE = math.sqrt(dx * dx + dy * dy)
                        local walkAE = 0
                        local shotLocE = shotLocA
                        if dAE > atkRange and dAE > 0.01 then
                            walkAE = math.ceil((dAE - atkRange + 8) / (ms / 30.0))
                            local ux, uy = dx / dAE, dy / dAE
                            shotLocE = Vector(ecLoc.x - ux * (atkRange - 8), ecLoc.y - uy * (atkRange - 8), shotLocA.z or 128)
                        end
                        local wantYawE = (dAE > 0.01) and (math.deg(math.atan2(dy, dx)) % 360) or yawA
                        local angDiffE = math.abs(((wantYawE - yawA + 180) % 360) - 180)
                        local turnAE = (walkAE == 0 and angDiffE > degPerTick + cone)
                            and math.ceil((angDiffE - degPerTick - cone) / degPerTick) or 0
                        local fTAE = U.CalcLaunchFlightTicks(shotLocE, ecand.creep, pSpeed)
                        local launchE = denyLaunch + math.max(spaTicks, walkAE + turnAE + (ecand.wT or 11))
                        local nextReadyImpact = launchE + fTAE

                        local effCloseAfterDeny = (U.PredictCloseAfterRemovingAttacker
                            and U.PredictCloseAfterRemovingAttacker(ecand.ctx, cand.creep, denyImpact, ecand.effClose))
                            or ecand.effClose
                        local latestSafeEnemyImpact = math.max(ecand.kOpen + 1, effCloseAfterDeny - 2)
                        if enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive() then
                            local enReach = ((enemyHero.GetAttackRange and enemyHero:GetAttackRange()) or 525) + 155
                            if U.DistanceBetweenLocations(enemyHero:GetLocation(), ecLoc) <= enReach then
                                local myMinE = U.SFDamageRange(bot, ecand.creep).min
                                local enDenyAvg = U.SFDamageRange(enemyHero, ecand.creep).avg
                                local contestWindow = (enDenyAvg >= myMinE + 4) and 14 or 22
                                latestSafeEnemyImpact = math.max(ecand.kOpen + 2, math.min(latestSafeEnemyImpact, ecand.kOpen + contestWindow))
                            end
                        end

                        if nextReadyImpact > latestSafeEnemyImpact then
                            blocksEnemyLH = true
                            break
                        end
                    end
                end

                local denyMustGoFirstForBoth = false
                if not blocksEnemyLH and cand.isDeny and #enemyLHCands > 0 then
                    -- Check if shooting ANY enemy creep `ecand` FIRST would cause `cand` (this deny) to die before our
                    -- post-LH attack can land on `cand` (`E -> A` = 1/2, whereas `A -> E` was just proven 2/2 above!):
                    for _, ecand in ipairs(enemyLHCands) do
                        local eLaunch = (ecand.activeRemT ~= nil)
                            and math.max(0, ecand.activeRemT - ecand.fT)
                            or math.max(ecand.launchT, ecand.kTargetImpact - ecand.fT)
                        local denyAfterEnemyImpact = eLaunch + spaTicks + (cand.fT or 6) + 2
                        if denyAfterEnemyImpact > ((cand.effClose or 999) - 2) then
                            denyMustGoFirstForBoth = true
                            break
                        end
                    end
                end

                if not blocksEnemyLH then
                    -- Exact Pareto-Optimal Two-Target Urgency Score (`v7.9.16`):
                    -- 1. If `blocksEnemyLH == true`, `cand` was ALREADY rejected above -> Enemy Last-Hit is 100% sacred!
                    -- 2. If `blocksEnemyLH == false` (we PROVED `Deny -> Enemy LH` secures BOTH `2/2`!) AND `cand` is ready
                    --    to fire right now (`freshDelta <= 5`), check `denyMustGoFirstForBoth`:
                    --      * If `Enemy LH -> Deny` ALSO secures both (`denyMustGoFirstForBoth == false`) and `Enemy LH` is
                    --        already open (`freshDelta_E <= 6`), `Enemy LH` (`400.0`) beats `Deny` (`260.0`) so Gold+Soul bank first!
                    --      * If waiting/shooting `Enemy LH` first would let `cand` die (`denyMustGoFirstForBoth == true`, e.g.
                    --        `02:41.73` `1095` at `d=176u` vs `897` at `d=662u`), `Deny` (`460.0`) fires NOW and chains into `Enemy LH` (`2/2` vs `1/2`)!
                    local freshDelta = cand.kTargetImpact - effT
                    local typePrio
                    if not cand.isDeny then
                        local readyToSwingEnemy = (cand.kOpen <= effT + 4) and (freshDelta <= 6 or cand.nearRelease)
                        typePrio = readyToSwingEnemy and 400.0 or 120.0
                    else
                        if freshDelta <= 5 or cand.nearRelease then
                            typePrio = denyMustGoFirstForBoth and 460.0 or 260.0
                        else
                            typePrio = 0.0
                        end
                    end
                    local valueBonus = 0.0
                    if cand.isFlagbearer then
                        valueBonus = cand.isDeny and 20.0 or 38.0
                    elseif cand.isSiege then
                        valueBonus = cand.isDeny and 18.0 or 34.0
                    elseif cand.isRanged then
                        valueBonus = cand.isDeny and 16.0 or 24.0
                    end
                    local releaseBonus = commitNearRelease and 95.0 or 0.0
                    local gamblePen = cand.gamble and -6.0 or 0.0
                    local soulBonus = 0.0
                    if not cand.isDeny then
                        local S = U._S
                        if S and S.GetSouls then
                            local mySouls = S.GetSouls(bot) or 0
                            local cap = (S.GetMaxSouls and S.GetMaxSouls(bot)) or ((C.LASTHIT and C.LASTHIT.SOUL_CAP) or 20)
                            if mySouls < cap then
                                soulBonus = ((C.LASTHIT and C.LASTHIT.SOUL_LH_BONUS) or 14.0)
                                    * (1.0 - math.min(1.0, mySouls / math.max(1, cap)) * 0.5)
                            end
                        end
                    end
                    local score = typePrio + valueBonus + releaseBonus + gamblePen + soulBonus - (cand.kTargetImpact * 3.0)
                    if score > bestScore then
                        bestScore = score
                        best = cand
                    end
                end
            end
        end
    end

    return best
end

-- Backwards-compatible public helper used by legacy callers in bot_nevermore.lua
function L.GetBestTarget(bot, enemyCreeps, allyCreeps, enemyAttackers, allyAttackers, enemyNearWave)
    U.BeginPredictionFrame()
    local cands = L.ScanCreepCandidates(bot, enemyCreeps, allyCreeps, allyAttackers, enemyAttackers, nil, nil)
    local best = L.SelectBestRightClickPlan(bot, cands, true)
    if best then
        return best.creep, best.isDeny, best
    end
    return nil, false, nil
end

-- Dual-Value Shadowraze CS (`Enemy Hero + Creep in Same 250u Coil`) + Exact Pre-Impact Alive Check:
-- Verified on live replay `auto-20261021-1713-start-ShaNachnetsya.dem` (`tk=14946 -> 14950 -> 14964`):
--   1. NEVER waste Shadowraze on a solo creep when the enemy hero is NOT inside that same 250u coil!
--   2. ONLY cast Shadowraze for CS when:
--      (A) PRIMARY DUAL-VALUE COIL (`heroInSameCoil == true`): `enemyHero` is alive, visible,
--          AND inside `235u` of `rSpot` BOTH right now AND at impact (`+0.55s`), taking BOTH
--          the +43g creep last-hit AND full Hero Shadowraze nuke + stack in a single 75-mana cast!
--      (B) SIMULTANEOUS MULTI-CREEP RESCUE (`multiKills >= 2` with `mana >= 165`): 2+ enemy creeps
--          dying simultaneously in the same 250u circle that right-click cooldown CANNOT reach both.
--   3. STRICT PRE-IMPACT ALIVE CHECK: `hpAlive > 10` at `(castTotalT - 1)` ticks is MANDATORY
--      (NO `or cand.effClose >= castTotalT` bypass!) so we NEVER start a 0.55s coil on a creep
--      already doomed to an incoming tower/creep projectile (`tk=14950`), AND every cast invokes
--      `startRazeCb(ab, c, rSpot, 250, true)` for 0-tick `Action_ClearActions(true)` S-cancel!
function L.TryRazeSecureCS(bot, candidates, enemyHero, startRazeCb)
    local mana = bot:GetMana() or 0
    if mana < 75 then return false end
    local razeCastTicks = (C.BALLISTIC and C.BALLISTIC.RAZE_CAST_TICKS) or 17
    local bLoc = bot:GetLocation()
    local curYaw = (bot.GetFacing and bot:GetFacing()) or 0
    local degPerTick = math.deg((C.BALLISTIC and C.BALLISTIC.SF_TURN_RATE) or 0.90)
    local hasHero = enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
    -- Stack-Discipline Self-Root Guard (`R1_2039` `01:59.73` Fix!):
    -- NEVER self-root `0.55s` casting a non-hero-kill creep raze when:
    --   (a) we carry `>= 2` enemy raze stacks (`myRem > 0.3s`), OR
    --   (b) our 1st enemy raze stack is `<= 2.20s` from expiring completely while enemy can follow up with `W`/`Q`!
    local enemyStackedForFollowup = false
    local enemyOutwardSpd = 0
    local WmodCS = package.loaded["bots/nevermore/world"]
    local ws = (WmodCS and WmodCS.s) or (U._W and U._W.s) or nil
    if hasHero then
        local mySt, myRem = U.GetShadowrazeDebuff(bot)
        local enSt, enRem = U.GetShadowrazeDebuff(enemyHero)
        local enPotMana = U.GetPotentialManaForRaze(enemyHero)
        local dHero = U.DistanceBetweenLocations(bLoc, enemyHero:GetLocation())
        if U.EnemyOutwardSpeed then
            enemyOutwardSpd = U.EnemyOutwardSpeed(bot, enemyHero) or 0
        end
        -- `9072025270.dem` `05:48.53` (`#41`) Fix: NEVER burn `Shadowraze1` / `Shadowraze2` on creep-only double-kills
        -- right after landing a stack on `enemyHero` (`enSt >= 1`) or when `enemyHero` is in active kill range!
        if dHero <= 1050 and (((enSt or 0) >= 1 and (enRem or 0) >= 1.40)
            or ((enemyHero:GetHealth() or 9999) <= 470 and dHero <= 940)) then
            enemyStackedForFollowup = true
        end
        if enPotMana >= 75 then
            if (mySt or 0) >= 2 and (myRem or 0) > 0.30 and dHero < 1020 then
                return false
            end
            -- `v7.9.15` (`auto-20261106-2139` `05:11.20` `463 HP, mySt=1, myRem=5.6s, d=478u` Self-Root Fix):
            -- ANY live stack (`myRem > 0.30s`) amplifies enemy's next Shadowraze RIGHT NOW (`myRem = 5.6s` is MORE dangerous
            -- than `1.5s`, not safer!). Never self-root `0.55s` for a non-hero-kill CS raze inside `< 785u` while stacked
            -- when wounded (`<= 560 HP`) or when `myRem <= 2.20s`!
            if (mySt or 0) == 1 and (myRem or 0) > 0.30 and dHero < 810
                and ((myRem or 0) <= 2.20 or (bot:GetHealth() or 999) <= 560 or enPotMana >= 150) then
                return false
            end
            -- `9080457787.dem` `06:05.87` (`tk=14376`, `79 -> 5 MP` @ `d=618u` vs `304 MP` Immortal SF `W+E`) Fix:
            -- NEVER self-root `0.55s` inside `< 765u` burning our LAST Shadowraze (`myPotMana < 145`, leaving `0` razes!)
            -- when the rival holds `>= 150 MP` and `>= 2` ready coils and isn't lethal to 1 coil!
            local myPotManaCS = mana + (U.GetMangoMana(bot) or 0)
            local enReadyCoils = (U._K and U._K.EnemyCastableRazeCount and U._K.EnemyCastableRazeCount(enemyHero, 1.5)) or 2
            local oneRazeDmgHero = (U.GetNRazeDamage and U.GetNRazeDamage(bot, enemyHero, 1)) or 220
            if myPotManaCS < 145 and dHero < 765 and enPotMana >= 150 and enReadyCoils >= 2
                and (enemyHero:GetHealth() or 9999) > (oneRazeDmgHero + 65) then
                return false
            end
        end
        if IsPositionLethalFromEnemy(bot, bLoc, ws) then
            local oneHeroRaze = (U.GetNRazeDamage and U.GetNRazeDamage(bot, enemyHero, 1)) or 0
            if (enemyHero:GetHealth() or 9999) > oneHeroRaze then
                return false
            end
        end
    end

    local bestAb, bestCand, bestSpot, bestAng, bestScore = nil, nil, nil, 0, -1
    local bestSpecDist, bestMustHitHero = 450, false
    local outRazed = hasHero and U.IsOutRazedTier and U.IsOutRazedTier(bot, enemyHero) or false
    for _, cand in ipairs(candidates) do
        if not cand.isDeny and cand.creep and U.CanQuery(cand.creep)
            and cand.creep:IsAlive() and cand.creep:GetHealth() > 0 then
            local c = cand.creep
            local cLoc = c:GetLocation()
            local d = U.DistanceBetweenLocations(bLoc, cLoc)

            for _, spec in ipairs(RAZE_SPECS) do
                if math.abs(d - spec.dist) <= (spec.radius - 16) then
                    local ab = bot:GetAbilityByName(spec.slot)
                    if ab and ab:IsFullyCastable() then
                        local baseDmg = U.GetRazeDamage(bot, ab)
                        local magicDmg = math.floor(c:GetActualIncomingDamage(baseDmg, DAMAGE_TYPE_MAGICAL))

                        -- Solve BOTH direct creep yaw AND 2D Dual-Value midpoint yaw (`0.5 * (cLoc + hPred)`)
                        -- so off-axis `Creep + Hero` pairs inside the same 250u Shadowraze circle are NEVER missed!
                        local aimYaws = {}
                        local creepYaw = math.deg(math.atan2(cLoc.y - bLoc.y, cLoc.x - bLoc.x)) % 360
                        if hasHero then
                            local roughPred = U.PredictPosition(enemyHero, razeCastTicks / 30.0)
                            local mx = 0.5 * (cLoc.x + roughPred.x)
                            local my = 0.5 * (cLoc.y + roughPred.y)
                            if math.abs(mx - bLoc.x) > 1 or math.abs(my - bLoc.y) > 1 then
                                aimYaws[#aimYaws + 1] = math.deg(math.atan2(my - bLoc.y, mx - bLoc.x)) % 360
                            end
                        end
                        aimYaws[#aimYaws + 1] = creepYaw

                        for _, wantYaw in ipairs(aimYaws) do
                            local ang = math.abs(((wantYaw - curYaw + 180) % 360) - 180)
                            local turnT = (ang > 11.5) and math.ceil((ang - 11.5) / degPerTick) or 0
                            local castTotalT = turnT + razeCastTicks
                            local tImpact = castTotalT / 30.0
                            local tBefore = math.max(0.033, (castTotalT - 1) / 30.0)
                            local hpAtCast = U.PredictHPWithContext(cand.ctx, c, tImpact, "max")
                            local hpAlive  = U.PredictHPWithContext(cand.ctx, c, tBefore, "min")
                            local rad = math.rad(wantYaw)
                            local rSpot = Vector(bLoc.x + math.cos(rad) * spec.dist, bLoc.y + math.sin(rad) * spec.dist, bLoc.z or 128)

                            local creepHitLim = ((C.RAZE and C.RAZE.CREEP_EFF_RADIUS) or 266) - 12 -- 254u (12u inside 266u creep hull)
                            local heroHitLim  = ((C.RAZE and C.RAZE.HERO_EFF_RADIUS) or 274) - 16  -- 258u (16u inside 274u hero hull)
                            -- `auto-20261102-0159-start-ShaNachnetsya.dem` `11:05.3` Whiff #1 Fix:
                            -- Verify BOTH current `cLoc` AND extrapolated `cPred` (`tImpact = 0.55s+`) lie inside `rSpot`
                            -- so an unengaged creep marching inward toward Enemy T1 NEVER walks out of our coil during cast!
                            local cPred = U.PredictPosition(c, tImpact)
                            if hpAlive > 14 and hpAtCast > 0 and hpAtCast <= magicDmg
                                and U.DistanceBetweenLocations(rSpot, cLoc) <= creepHitLim
                                and U.DistanceBetweenLocations(rSpot, cPred) <= (creepHitLim - 6) then
                                local heroInSameCoil = false
                                if hasHero then
                                    local hNow = enemyHero:GetLocation()
                                    local hPred = U.PredictPosition(enemyHero, tImpact)
                                    local dHeroNow = U.DistanceBetweenLocations(bLoc, hNow)
                                    -- `9072025270.dem` `02:49.73` (`#24` `dStart=912.3u -> dEnd=999.1u`) Fix:
                                    -- When `enemyHero` is actively walking away (`enemyOutwardSpd >= 40`) OR already standing on
                                    -- the outer rim (`dHeroNow >= spec.dist + 185`), require `<= 205u` / `198u` so we NEVER commit
                                    -- a 1-melee-creep dual-value raze onto a hero who walks out in `0.3s`!
                                    local onOuterEscapeRim = (enemyOutwardSpd >= 40) or (dHeroNow >= spec.dist + 185)
                                    local effHeroNowLim  = onOuterEscapeRim and 205 or heroHitLim
                                    local effHeroPredLim = onOuterEscapeRim and 198 or (heroHitLim - 12)
                                    if U.DistanceBetweenLocations(rSpot, hNow) <= effHeroNowLim
                                        and U.DistanceBetweenLocations(rSpot, hPred) <= effHeroPredLim then
                                        heroInSameCoil = true
                                    end
                                end

                                -- AoE Splash Safety + Multi-Creep Kill Count across all enemy creeps (`266u` exact creep hull!)
                                local splashCheckRad = (C.RAZE and C.RAZE.CREEP_EFF_RADIUS) or 266
                                local twReachSplash = (C.BALLISTIC and C.BALLISTIC.TOWER_ATTACK_RANGE_C2C) or 870
                                local ruinsOtherCreep = false
                                local multiKills = 1
                                for _, oc in ipairs(candidates) do
                                    if not oc.isDeny and oc.creep ~= c and U.CanQuery(oc.creep) and oc.creep:IsAlive() then
                                        local ocLoc = oc.creep:GetLocation()
                                        if U.DistanceBetweenLocations(rSpot, ocLoc) <= splashCheckRad then
                                            local oDmg = math.floor(oc.creep:GetActualIncomingDamage(baseDmg, DAMAGE_TYPE_MAGICAL))
                                            local oRem = oc.creep:GetHealth() - oDmg
                                            local oMin = U.SFDamageRange(bot, oc.creep).min
                                            if oRem <= 0 then
                                                multiKills = multiKills + 1
                                            elseif oRem > 0 and oRem <= oMin + 28 then
                                                ruinsOtherCreep = true
                                                break
                                            elseif oRem > 0 and ws and ws.allyT1Alive and ws.allyT1Loc
                                                and U.DistanceBetweenLocations(ocLoc, ws.allyT1Loc) <= twReachSplash then
                                                local tObj = ws.allyT1
                                                local tStealDmg = (tObj and U.CanQuery(tObj))
                                                    and U.CalcExactIntDamage(tObj, oc.creep, 90)
                                                    or 100
                                                if oRem > (oMin + 4) and oRem <= (tStealDmg + 2) then
                                                    ruinsOtherCreep = true
                                                    break
                                                end
                                            end
                                        end
                                    end
                                end

                                local rightClickImpossible = cand.lethalRightClick
                                    or (cand.kOpen == -1 and cand.effClose >= castTotalT)
                                    or (cand.kOpen >= 0 and cand.totalT > cand.effClose + 1)
                                local holdFollowupBand = enemyStackedForFollowup
                                    and (spec.slot == "nevermore_shadowraze1" or spec.slot == "nevermore_shadowraze2")
                                -- `v7.9.13-pro` (`0210 @ 16:40..16:41` Multi-Coil Creep Dump Near Armed Rival SF Fix!):
                                -- When a live armed rival SF (`enHp > 380`, `enPotMana >= 140`) is within `1,550u`, NEVER spend
                                -- a pure creep-only raze (`not heroInSameCoil`) if `W` or `E` is ALREADY on cooldown (`> 2.5s`)
                                -- OR if mid/late-game (`level >= 7`) casting would drop us below `150 MP` (`< 2` combat coils)!
                                local armedRivalCloseForReserve = false
                                local otherMidFarAlreadyOnCd = false
                                if hasHero and not heroInSameCoil then
                                    local dHeroRes = U.DistanceBetweenLocations(bLoc, enemyHero:GetLocation())
                                    if dHeroRes <= 1550 and (enemyHero:GetHealth() or 0) > 380
                                        and U.GetPotentialManaForRaze(enemyHero) >= 140 then
                                        armedRivalCloseForReserve = true
                                        local wRes = bot:GetAbilityByName("nevermore_shadowraze2")
                                        local eRes = bot:GetAbilityByName("nevermore_shadowraze3")
                                        local wOnCdRes = wRes and wRes:GetLevel() > 0 and (wRes:GetCooldownTimeRemaining() or 0) > 2.5
                                        local eOnCdRes = eRes and eRes:GetLevel() > 0 and (eRes:GetCooldownTimeRemaining() or 0) > 2.5
                                        otherMidFarAlreadyOnCd = (wOnCdRes or eOnCdRes) and true or false
                                    end
                                end
                                -- `9079381960.dem` `05:02.93` (`154 -> 79 MP` `E(700)` on creep vs `476 MP` Lvl-5 Rival) Fix:
                                -- At Lvl 5+ (`Lvl 3+` Shadowraze era), NEVER spend `75 MP` on a pure non-hero creep raze
                                -- when doing so drops us below `140 MP` (`< 2` hero coils) without reserve Mangoes/Clarity
                                -- while a live rival SF holds `>= 150 MP` (`2+` coils)!
                                local myMaxMpRaze = math.max(250, (bot.GetMaxMana and bot:GetMaxMana()) or 350)
                                local hasMangoOrClarity = ((U.GetMangoMana and U.GetMangoMana(bot) or 0) >= 75)
                                    or (bot.HasModifier and bot:HasModifier("modifier_clarity_potion"))
                                local preserveTwoCoilsVsRival = ((bot:GetLevel() or 1) >= 5)
                                    and (not hasMangoOrClarity)
                                    and (mana < myMaxMpRaze * 0.72)
                                    and hasHero
                                    and ((U.GetPotentialManaForRaze(enemyHero) or 0) >= 150)
                                local minCreepRazeMana = ((armedRivalCloseForReserve and (bot:GetLevel() or 1) >= 7) and 225)
                                    or (preserveTwoCoilsVsRival and 215 or 165)
                                local unsafeLethalCloseRescue = cand.lethalRightClick and hasHero
                                    and spec.dist < 650
                                    and U.DistanceBetweenLocations(bLoc, enemyHero:GetLocation()) < 745
                                    and U.GetPotentialManaForRaze(enemyHero) >= 75
                                local allowDoubleCreepRescue = (not heroInSameCoil)
                                    and (not unsafeLethalCloseRescue)
                                    and (not holdFollowupBand)
                                    and (not otherMidFarAlreadyOnCd)
                                    and multiKills >= 2
                                    and rightClickImpossible
                                    and mana >= minCreepRazeMana
                                -- Pro Anti-Freeze & Contested-Deny Ranged/Flagbearer-Creep Rescue (`v7.9.31-pro` `M143` Fix!):
                                --   1. When rival SF is dry (`< 75 MP`, `0` coils!), securing a Flagbearer (`+120g`) or Ranged
                                --      creep (`+54g / +69 XP`) with a `75..95 MP` coil carries `0` coil-punish risk!
                                --   2. When rival SF stands inside deny reach (`<= 565u`) with a physical damage lead (`enDenyAvg >= myMin + 8`),
                                --      start `17`-tick (`0.55s`, `0` flight!) Raze BEFORE/AS the creep enters rival's deny zone —
                                --      EVEN IF `hpAtCast <= myMin + 3` whenever rival stands `>= 85u` closer (`beating our bolt flight!`)!
                                local rivalPotManaCS = hasHero and U.GetPotentialManaForRaze(enemyHero) or 0
                                local rivalDryCS = (not hasHero) or (rivalPotManaCS < 75)
                                local isFlagCS = (cand.isFlagbearer or U.IsFlagbearerCreep(c)) and true or false
                                local minRangedRazeMana
                                if rivalDryCS then
                                    minRangedRazeMana = isFlagCS and 75 or 95
                                elseif armedRivalCloseForReserve and otherMidFarAlreadyOnCd then
                                    minRangedRazeMana = isFlagCS and 150 or 225
                                elseif preserveTwoCoilsVsRival then
                                    minRangedRazeMana = isFlagCS and 135 or 215
                                else
                                    minRangedRazeMana = isFlagCS and 105 or 125
                                end
                                local highValueSingleCreep = (cand.isRanged or isFlagCS) and true or false
                                local allowZonedRangedRescue = (not heroInSameCoil)
                                    and highValueSingleCreep
                                    and (spec.slot == "nevermore_shadowraze3"
                                        or (spec.slot == "nevermore_shadowraze2" and (d >= 520 or (rivalDryCS and d >= 380))))
                                    and rightClickImpossible
                                    and (outRazed or d >= 520 or (isFlagCS and rivalDryCS))
                                    and mana >= minRangedRazeMana
                                -- `v7.9.24-pro` (`auto-20261108-1523` `01:13.60` `1511` Ranged Creep Post-Deny CD Rescue!):
                                -- When SF's basic attack is on cooldown (`cand.cdT > 0`) so right-click CANNOT reach a dying
                                -- high-value Enemy Ranged (`+54g / +69 XP`) or Flagbearer creep before `effClose`, rescue it
                                -- with ANY ready safe Raze band (`Q`, `W`, or `E`) whenever `mana >= minRangedRazeMana`!
                                local allowCooldownRangedRescue = (not heroInSameCoil)
                                    and (not unsafeLethalCloseRescue)
                                    and (not holdFollowupBand)
                                    and (isFlagCS or not otherMidFarAlreadyOnCd)
                                    and highValueSingleCreep
                                    and rightClickImpossible
                                    and ((cand.cdT or 0) > 0)
                                    and mana >= minRangedRazeMana
                                local allowContestedRangedDenySteal = false
                                local minStealMana = rivalDryCS and (isFlagCS and 75 or 95) or (isFlagCS and 105 or 125)
                                if (not heroInSameCoil) and hasHero and mana >= minStealMana
                                    and (highValueSingleCreep or ((bot:GetLevel() or 1) <= 3 and mana >= 150))
                                    and (spec.slot == "nevermore_shadowraze2" or spec.slot == "nevermore_shadowraze3") then
                                    local cHpNow = c:GetHealth() or 999
                                    local cMaxHp = math.max(1, c:GetMaxHealth() or 300)
                                    local dEnCreep = U.DistanceBetweenLocations(enemyHero:GetLocation(), cLoc)
                                    if (cHpNow * 2 < cMaxHp + 45) and dEnCreep <= 565 then
                                        local myMinR = U.SFDamageRange(bot, c).min
                                        local enDenyAvg = U.SFDamageRange(enemyHero, c).avg
                                        local rivalFlightLead = (dEnCreep + 85 < d)
                                        if enDenyAvg >= myMinR + 7
                                            and (hpAtCast > myMinR + 3 or rivalFlightLead or rightClickImpossible)
                                            and hpAtCast <= math.max(enDenyAvg + 14, isFlagCS and 95 or 0) then
                                            allowContestedRangedDenySteal = true
                                        end
                                    end
                                end

                                -- `v7.9.21` + `v7.9.28-pro` + `v7.9.32-pro` (`870u` Under-Own-Tower Raze CS Rescue!):
                                -- Fixes `ws == nil` undefined global (`auto-20261109-0306` `M#488`, `M#851`, `R#1997`)!
                                local allowUnderOwnTowerRescue = false
                                local isFlagbearerRescue = isFlagCS
                                local minRescueMana = (isFlagbearerRescue or ((not hasHero) and cand.isRanged)) and 75
                                    or (rivalDryCS and 95 or 115)
                                if (not heroInSameCoil) and (not cand.isDeny) and rightClickImpossible and mana >= minRescueMana
                                    and ws and ws.allyT1Alive and ws.allyT1Loc then
                                    local twReachR = (C.BALLISTIC and C.BALLISTIC.TOWER_ATTACK_RANGE_C2C) or 870
                                    if U.DistanceBetweenLocations(cLoc, ws.allyT1Loc) <= twReachR then
                                        local dEnemyRescue = hasHero and U.DistanceBetweenLocations(bLoc, enemyHero:GetLocation()) or 9999
                                        local safeFromRivalHere = (not hasHero)
                                            or dEnemyRescue >= 920
                                            or (rivalDryCS and dEnemyRescue >= 540)
                                        if safeFromRivalHere and (isFlagbearerRescue or rivalDryCS or not otherMidFarAlreadyOnCd or mana >= 175) then
                                            allowUnderOwnTowerRescue = true
                                        end
                                    end
                                end

                                -- `v7.9.8-pro` (`1630 @ 02:35.87` `111 MP` & `1638 @ 02:16.00` `92 MP` 1-Coil Mana-Trap Fix!):
                                -- NEVER spend our ONLY coil (`mySustainedMana < 145` -> `< 70 MP` dry after cast!) on a close
                                -- `Q(200)` / `W(450)` dual-value coil (`spec.dist < 650` at `dHero < 660u`) against an enemy SF
                                -- holding `>= 150 MP` (`2+` counter-coils: `W + auto + E = -280..-340 HP` punish!) unless lethal!
                                local singleCoilCloseTrap = false
                                if heroInSameCoil and hasHero and spec.dist < 650 then
                                    local mySustainedM = (U._K and U._K.MySustainedManaBudget and U._K.MySustainedManaBudget(bot, 6.5))
                                        or (mana + (U.GetMangoMana and U.GetMangoMana(bot) or 0) + (U.GetStickCharges and U.GetStickCharges(bot) or 0) * 15)
                                    local enPotM = U.GetPotentialManaForRaze(enemyHero) or 0
                                    local dHeroTrap = U.DistanceBetweenLocations(bLoc, enemyHero:GetLocation())
                                    local oneRazeDmg = (U.GetNRazeDamage and U.GetNRazeDamage(bot, enemyHero, 1)) or magicDmg
                                    if mySustainedM < 145 and enPotM >= 150 and dHeroTrap < 660
                                        and (enemyHero:GetHealth() or 9999) > (oneRazeDmg + 95) then
                                        singleCoilCloseTrap = true
                                    end
                                end

                                if not ruinsOtherCreep and not singleCoilCloseTrap
                                    and (heroInSameCoil or allowDoubleCreepRescue or allowZonedRangedRescue or allowCooldownRangedRescue or allowContestedRangedDenySteal or allowUnderOwnTowerRescue) then
                                    local creepOnlyLegal = allowDoubleCreepRescue or allowZonedRangedRescue or allowCooldownRangedRescue or allowContestedRangedDenySteal or allowUnderOwnTowerRescue
                                    local score = (heroInSameCoil and 1000 or (allowDoubleCreepRescue and 240 or 180))
                                        + multiKills * 90
                                        + (cand.isRanged and 55 or 20)
                                        - turnT * 8
                                    if score > bestScore then
                                        bestAb = ab
                                        bestCand = cand
                                        bestSpot = rSpot
                                        bestAng = ang
                                        bestScore = score
                                        bestSpecDist = spec.dist
                                        bestMustHitHero = heroInSameCoil and (not creepOnlyLegal)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if bestAb and bestCand and bestSpot then
        -- Exact Current-Yaw Circle Verification (`v7.9.2`, `TWO_ANALYSES_REVIEW_RU.md` `P0-01` + `9072025270` `#24` Fix!):
        -- NEVER fire `Action_UseAbility` on a blind `t+1` assumption; verify directly on `curYaw` that `curSpot` covers
        -- `bestCand.creep` (and `enemyHero` when `bestMustHitHero == true`, corresponding to exact `cos θ_max = (r^2+d^2-R^2)/(2rd)`)!
        local curRad = math.rad(curYaw)
        local curSpot = Vector(
            bLoc.x + math.cos(curRad) * bestSpecDist,
            bLoc.y + math.sin(curRad) * bestSpecDist,
            bLoc.z or 128
        )
        local creepHitLimNow = ((C.RAZE and C.RAZE.CREEP_EFF_RADIUS) or 266) - 12
        local heroHitLimNow  = (enemyOutwardSpd >= 45) and 212 or (((C.RAZE and C.RAZE.HERO_EFF_RADIUS) or 274) - 22)
        local cPredNow = U.PredictPosition(bestCand.creep, razeCastTicks / 30.0)
        local curCoversCreep = U.DistanceBetweenLocations(curSpot, bestCand.creep:GetLocation()) <= creepHitLimNow
            and U.DistanceBetweenLocations(curSpot, cPredNow) <= (creepHitLimNow - 6)
        local curCoversHero  = true
        if bestMustHitHero and hasHero then
            local hPredNow = U.PredictPosition(enemyHero, razeCastTicks / 30.0)
            curCoversHero = U.DistanceBetweenLocations(curSpot, enemyHero:GetLocation()) <= (heroHitLimNow + 8)
                and U.DistanceBetweenLocations(curSpot, hPredNow) <= heroHitLimNow
        end
        if curCoversCreep and curCoversHero and bestAng <= 24.0 then
            L._razeTurnStampAt = nil
            local valRad = (C.RAZE and C.RAZE.CREEP_EFF_RADIUS) or 266
            local mustHeroArg = (bestMustHitHero and hasHero) and enemyHero or nil
            if startRazeCb then
                startRazeCb(bestAb, bestCand.creep, curSpot, valRad, true, mustHeroArg)
            else
                bot:Action_UseAbility(bestAb)
            end
        else
            L._razeTurnStampAt = GameTime()
            local turnPt = bLoc + (bestSpot - bLoc):Normalized() * 36
            if bot.Action_MoveDirectly then
                bot:Action_MoveDirectly(turnPt)
            else
                bot:Action_MoveToLocation(turnPt)
            end
        end
        return true
    end
    return false
end

-- Exact Algebraic Under-Tower HP Prep Solver (Zero Over-Attack Guarantee via m_flLastAttackTime lock)
function L.TryUnderTowerPrep(bot, enemyCreeps, allyCreeps, allySideAttackers, enemySideAttackers, allyTowers, enemyTowers, candidates, enemyHero, race)
    local curLAT = (bot.GetLastAttackTime and bot:GetLastAttackTime()) or -100
    if L._prepExpire and GameTime() < L._prepExpire - 2.0 then
        L._prepCreep = nil
        L._prepExpire = 0
    end
    -- CRITICAL (`9056469656.dem` `01:20` Root Cause!):
    -- Valve C++ `CDOTA_BaseNPC::StartAttack` stamps `m_flLastAttackTime` on TICK 1 of windup (`0.46s` BEFORE launch!),
    -- so checking `curLAT > L._prepStartLAT` S-cancelled 100% of under-tower prep swings on frame 2 without firing 1 bolt!
    -- Instead, detect actual projectile release directly from `L._prepCreep:GetIncomingTrackingProjectiles()` (`p.caster == bot`)!
    -- `9071946472.dem` `03:41.47–03:43.10` Dry-Mana Retreat Turnback Fix:
    -- NEVER let a non-lethal under-tower prep swing (`143 HP` melee creep) abort an active forced/dry-mana retreat
    -- or drag a `< 75 MP` SF `230u` forward (`782u -> 546u`) back into an armed enemy SF's right-clicks & Shadowrazes!
    local nowPrep = GameTime()
    local retreatLockedPrep = U._State and (nowPrep < (U._State.forcedRetreatUntil or 0)
        or nowPrep < (U._State.dryRetreatHystUntil or 0))
    local dryThreatPrep = enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
        and U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, enemyHero, nil)
        and GetUnitToLocationDistance(bot, enemyHero:GetLocation()) <= 860
    if retreatLockedPrep or dryThreatPrep then
        if L._prepCreep then
            L._prepCreep = nil
            L._prepExpire = 0
        end
        return false
    end

    if L._prepCreep then
        local launched = false
        -- `v7.9.32-pro` Reliable Prep-Release Detection (`auto-20261109-0306` `7.41f` Empty Creep Projectiles Fix!):
        -- Source 2 `c:GetIncomingTrackingProjectiles()` returns `{}` on lane creeps, so supplement it with exact
        -- `curLAT > L._prepStartLAT + 0.004` gated by `nowPrep >= (L._prepIssuedAt or 0) + 0.24` (after windup!).
        if L._prepStartLAT ~= nil and curLAT > (L._prepStartLAT + 0.004)
            and nowPrep >= ((L._prepIssuedAt or 0) + 0.24) then
            launched = true
        end
        if (not launched) and U.CanQuery(L._prepCreep) then
            for _, p in pairs(U.SafeGetIncomingProjectiles(L._prepCreep)) do
                if p.is_attack and p.caster == bot then
                    launched = true
                    break
                end
            end
        end
        -- `v7.9.29-pro` + `v7.9.32-pro` (`auto-20261109-0306` `0:36 M#1092` & `3:46 M#488` Pre-Launch Sliver Abort!):
        -- Re-verify every tick during walk/windup (`not launched`) across ALL in-flight bolts (`maxBoltEtaChk`) AND
        -- active tower targeting (`even between bolts!`) that our prep will NOT leave `hpAfter1Chk <= tDmgChk + 1`
        -- before SF can reload (`mySpaChk`).
        local abortStalePrep = false
        if (not launched) and U.CanQuery(L._prepCreep) and L._prepCreep:IsAlive() then
            local sfChk = U.SFDamageRange(bot, L._prepCreep)
            local _, launchChk, _, fTChk = U.GetExactBallisticTicks(bot, L._prepCreep)
            local mySpaChk = (bot.GetSecondsPerAttack and bot:GetSecondsPerAttack()) or 1.25
            local twReachChk = (C.BALLISTIC and C.BALLISTIC.TOWER_ATTACK_RANGE_C2C) or 870
            for _, twChk in pairs(allyTowers or {}) do
                if U.CanQuery(twChk) and GetUnitToLocationDistance(twChk, L._prepCreep:GetLocation()) <= twReachChk then
                    local _, _, twRawChk = U.SampleRawDamageRange(twChk)
                    local tDmgChk = U.CalcExactIntDamage(twChk, L._prepCreep, twRawChk)
                    local tSpaChk = (twChk.GetSecondsPerAttack and twChk:GetSecondsPerAttack()) or 0.85
                    if tSpaChk <= 0.1 then tSpaChk = 0.85 end
                    if string.find(twChk:GetUnitName() or "", "tower1", 1, true) and tSpaChk > 0.85 then
                        tSpaChk = 0.85
                    end
                    local hpLeftChk = L._prepCreep:GetHealth() or 0
                    local hasBoltChk, maxBoltEtaChk = false, 0.0
                    local engBoltTicksChk = {}
                    for _, pChk in pairs(U.SafeGetIncomingProjectiles(L._prepCreep)) do
                        if pChk.is_attack and pChk.caster == twChk then
                            hpLeftChk = hpLeftChk - tDmgChk
                            hasBoltChk = true
                            local pLoc = pChk.location
                            local dRem = pLoc and GetUnitToLocationDistance(L._prepCreep, pLoc) or 350
                            local etaP = dRem / 750.0
                            maxBoltEtaChk = math.max(maxBoltEtaChk, etaP)
                            engBoltTicksChk[#engBoltTicksChk + 1] = math.floor(etaP * 30.0 + 0.5)
                        end
                    end
                    if U.GetSyntheticTowerBoltsOn then
                        for _, sbChk in ipairs(U.GetSyntheticTowerBoltsOn(L._prepCreep)) do
                            if sbChk.caster == twChk then
                                local sbK = sbChk.kRem or 18
                                local dupChk = false
                                for ei = 1, #engBoltTicksChk do
                                    if math.abs(engBoltTicksChk[ei] - sbK) <= 6 then
                                        dupChk = true
                                        break
                                    end
                                end
                                if not dupChk then
                                    hpLeftChk = hpLeftChk - tDmgChk
                                    hasBoltChk = true
                                    maxBoltEtaChk = math.max(maxBoltEtaChk, sbK / 30.0)
                                end
                            end
                        end
                    end
                    local twActivelyTargeting = (twChk.GetAttackTarget and twChk:GetAttackTarget() == L._prepCreep)
                        or (U._unitTrack and U._unitTrack[twChk] and U._unitTrack[twChk].inferredTowerTarget == L._prepCreep)
                    if (hasBoltChk or twActivelyTargeting) and tDmgChk > 0 then
                        local hpAfter1Chk = hpLeftChk - sfChk.avg
                        local remAfter1Chk = (hpAfter1Chk > 0) and (hpAfter1Chk % tDmgChk) or 0
                        if remAfter1Chk == 0 and hpAfter1Chk > 0 then remAfter1Chk = tDmgChk end
                        local extraSurvChk = (hpAfter1Chk >= tDmgChk + 2)
                            and math.max(1, math.floor((hpAfter1Chk - remAfter1Chk) / tDmgChk + 0.5))
                            or 0
                        local baseStealEtaChk
                        if hasBoltChk then
                            baseStealEtaChk = maxBoltEtaChk + (extraSurvChk + 1) * tSpaChk
                        else
                            local tLatChk = (twChk.GetLastAttackTime and twChk:GetLastAttackTime()) or -100
                            local nextTwLaunch = math.max(0.05, tSpaChk - math.max(0.0, nowPrep - tLatChk))
                            local dTwPrep = GetUnitToLocationDistance(twChk, L._prepCreep:GetLocation())
                            baseStealEtaChk = nextTwLaunch + (dTwPrep / 750.0) + extraSurvChk * tSpaChk
                        end
                        local dBotPrepChk = math.max(0.0, GetUnitToLocationDistance(bot, L._prepCreep:GetLocation()) - 48.0)
                        local inSwingRangeChk = dBotPrepChk <= ((bot:GetAttackRange() or 500) + 25.0)
                        if inSwingRangeChk then
                            L._prepInRangeAt = L._prepInRangeAt or nowPrep
                        else
                            L._prepInRangeAt = nil
                        end
                        local elapsedSwingSec = L._prepInRangeAt and math.max(0.0, nowPrep - L._prepInRangeAt) or 0.0
                        local remLaunchSec = math.max(0.0, ((launchChk or 14) / 30.0) - elapsedSwingSec)
                        local needSec = remLaunchSec + mySpaChk + ((fTChk or 10) / 30.0) + 0.04
                        if hpLeftChk <= sfChk.min + 6 or hpAfter1Chk <= 1 or baseStealEtaChk < needSec then
                            abortStalePrep = true
                            break
                        end
                    end
                end
            end
        end
        if not U.CanQuery(L._prepCreep) or GameTime() > L._prepExpire or launched or abortStalePrep then
            if launched or abortStalePrep or GameTime() > (L._prepExpire or 0) then
                bot:Action_ClearActions(true)
            end
            L._prepCreep = nil
            L._prepStartLAT = nil
            L._prepIssuedAt = nil
            L._prepInRangeAt = nil
            L._prepExpire = 0
            if abortStalePrep then return false end
        else
            -- Keep finishing the single locked prep swing unless an urgent CS just opened
            return true
        end
    end

    local spaTicks = math.ceil((bot:GetSecondsPerAttack() or 1.25) * 30.0)
    -- Never start a prep hit if ANY creep needs a real last hit / deny within spaTicks + 16 ticks!
    for _, cand in ipairs(candidates) do
        if cand.kOpen >= 0 and cand.kOpen <= spaTicks + 16 and not cand.lethalRightClick then
            return false
        end
    end

    -- Never distract SF from executing a low-HP enemy hero (`<= 350 HP`, e.g. `S29` `02:32.92` `284 HP` ramp brawl!),
    -- nor swing prep hits while low HP & being poked (`2:48` fix!)
    if enemyHero and U.CanQuery(enemyHero) and (enemyHero:GetHealth() or 9999) <= 350
        and GetUnitToLocationDistance(bot, enemyHero:GetLocation()) <= 700 then
        return false
    end
    local beingPokedNow = enemyHero and U.CanQuery(enemyHero)
        and ((enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.8)))
    if beingPokedNow and (bot:GetHealth() or 9999) <= 380 then
        return false
    end

    -- Exact 1- & 2-Step Ballistic Modular Under-Tower Prep (`9056469656.dem` `01:20` Lvl 2 `58..64` vs `550 HP` Fix!):
    -- Why `k in {1, 2}` prep steps is mandatory under T1:
    --   - At Lvl 2 (`myMin = 58, myAvg = 61`) vs `550 HP` melee under T1 (`tDmg = 97`):
    --     * `0` preps -> `550 - 5*97 = 65 HP > 58` (T1 steals 3/3 melee creeps at `01:20`!).
    --     * `1` prep  -> `550 - 61 - 4*97 = 101 HP` -> `101 - 97 = 4 HP` (still needs a 2nd prep!).
    --     * `2` preps -> `550 - 2*61 - 4*97 = 40 HP` inside `[5, 56]` -> `100%` clean 1-shot CS!
    --   - Meanwhile, on Ranged creeps (`300 - 2*109 = 82 <= 84` or `300 - 3*97 = 9 <= 58`), `rem0` ALREADY lies in
    --     `[1, myMin]`, so `remNow > myMin` is `false` -> `0` preps fired, NEVER breaking an already clean 1-shot!
    local mySpa = (bot.GetSecondsPerAttack and bot:GetSecondsPerAttack()) or 1.25
    for _, t in pairs(allyTowers or {}) do
        if U.CanQuery(t) then
            local _, _, towerRawAvg = U.SampleRawDamageRange(t)
            local tSpa = (t.GetSecondsPerAttack and t:GetSecondsPerAttack()) or 0.818
            if tSpa <= 0.1 then tSpa = 0.818 end
            if string.find(t:GetUnitName() or "", "tower1", 1, true) and tSpa > 0.85 then
                tSpa = 0.85
            end
            local okTT, tCurTarget = false, nil
            if t.GetAttackTarget then okTT, tCurTarget = pcall(t.GetAttackTarget, t) end
            if not okTT then tCurTarget = nil end
            if not tCurTarget then
                local curTickPrep = math.floor(GameTime() * 30.0 + 0.5)
                local tRec = U._unitTrack and U._unitTrack[t]
                if tRec and tRec.inferredTowerTarget and U.CanQuery(tRec.inferredTowerTarget)
                    and tRec.inferredTowerTarget:IsAlive() and curTickPrep <= (tRec.inferredTowerTargetUntil or -1) then
                    tCurTarget = tRec.inferredTowerTarget
                end
            end
            local tLastFireSec = GameTime() - ((t.GetLastAttackTime and t:GetLastAttackTime()) or -100)
            local towerActivelyFiring = (tCurTarget ~= nil and tCurTarget ~= enemyHero)
                or (tLastFireSec >= 0 and tLastFireSec <= 2.25 and tCurTarget ~= enemyHero)
            if not towerActivelyFiring then
                for _, c in pairs(enemyCreeps or {}) do
                    if U.CanQuery(c) then
                        for _, p in pairs(U.SafeGetIncomingProjectiles(c)) do
                            if p.is_attack and p.caster == t then towerActivelyFiring = true; break end
                        end
                    end
                    if towerActivelyFiring then break end
                end
            end

            -- CRITICAL (`9056469656.dem` `01:20` Fix!): NEVER prep unless `t` is ACTUALLY firing at creeps,
            -- and sort strictly by C++ `CDOTA_BaseNPC_Tower` kill order (`tCurTarget` first, then closest to `t`)!
            local orderedUnderT1 = {}
            local twPrepReach = (C.BALLISTIC and C.BALLISTIC.TOWER_ATTACK_RANGE_C2C) or 870
            if towerActivelyFiring then
                for _, c in pairs(enemyCreeps or {}) do
                    if U.CanQuery(c) then
                        local dT = GetUnitToLocationDistance(t, c:GetLocation())
                        if dT <= twPrepReach then
                            orderedUnderT1[#orderedUnderT1 + 1] = { c = c, d = dT, active = (c == tCurTarget) }
                        end
                    end
                end
            end
            table.sort(orderedUnderT1, function(a, b)
                if a.active ~= b.active then return a.active end
                return a.d < b.d
            end)

            for _, entry in ipairs(orderedUnderT1) do
                local c = entry.c
                -- `auto-20261023-1329-start-ShaNachnetsya.dem` `tk=6182..6240` Fix:
                -- NEVER ignore an enemy hero right-clicking us inside `<= 640u` while our T1 is busy shooting creeps
                -- (`tCurTarget ~= enemyHero`)! Yield immediately so `HandleAntiFreeHarassRetaliation` punishes him!
                local enemyFreeHittingUs = enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
                    and tCurTarget ~= enemyHero
                    and GetUnitToLocationDistance(bot, enemyHero:GetLocation()) <= 640
                    and ((enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
                        or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.35)))
                local safePrepPos = L.EnemyCannotPunishLane(bot, enemyHero, bot:GetHealth())
                    or not IsPositionLethalFromEnemy(bot, bot:GetLocation(), enemyHero, race)
                if not enemyFreeHittingUs and safePrepPos then
                    local tDmg = U.CalcExactIntDamage(t, c, towerRawAvg)
                    local sfRange = U.SFDamageRange(bot, c)
                    local myMin, myAvg = sfRange.min, sfRange.avg
                    -- Account for ALL projectiles ALREADY in flight (`tower` engine + synthetic bolts AND `bot` prep bolt!)
                    local hpEff = c:GetHealth()
                    local hasTowerBoltInAir = false
                    local seenEngineTwBolt = false
                    local maxInAirBoltEta = 0.0
                    local engBoltTicks = {}
                    for _, p in pairs(U.SafeGetIncomingProjectiles(c)) do
                        if p.is_attack then
                            if p.caster == t then
                                hpEff = hpEff - tDmg
                                hasTowerBoltInAir = true
                                local pLoc = p.location
                                local dRem = pLoc and GetUnitToLocationDistance(c, pLoc) or (entry.d * 0.6)
                                local etaP = dRem / 750.0
                                maxInAirBoltEta = math.max(maxInAirBoltEta, etaP)
                                engBoltTicks[#engBoltTicks + 1] = math.floor(etaP * 30.0 + 0.5)
                            elseif p.caster == bot then
                                hpEff = hpEff - myAvg
                            end
                        end
                    end
                    if U.GetSyntheticTowerBoltsOn then
                        local synthB = U.GetSyntheticTowerBoltsOn(c)
                        for si = 1, #synthB do
                            if synthB[si].caster == t then
                                local sbK = synthB[si].kRem or 18
                                local dupB = false
                                for ei = 1, #engBoltTicks do
                                    if math.abs(engBoltTicks[ei] - sbK) <= 6 then
                                        dupB = true
                                        break
                                    end
                                end
                                if not dupB then
                                    hpEff = hpEff - tDmg
                                    hasTowerBoltInAir = true
                                    maxInAirBoltEta = math.max(maxInAirBoltEta, sbK / 30.0)
                                end
                            end
                        end
                    end
                    if tDmg > 0 and hpEff > myMin + 6 then
                        local kShotsRaw = math.max(1, math.floor(hpEff / tDmg))
                        -- Exact Stochastic Drift + Creep Regen Margin (`+0.5 HP/s` regen + T1 min-roll spread over `kShots`!):
                        --   1. Upper edge (`remNow > safeNoPrepCeil`): `+regen` + low T1 rolls push post-T1 HP above `myMin`!
                        --   2. Lower edge (`remNow <= minSafeNoPrepFloor`, `v7.9.28-pro` `auto-20261108-2049` `3:10` `E1033`
                        --      `302 -> 201 -> 102 -> 0 HP` Fix!): `302 % 100 = 2` and `201 % 100 = 1` previously passed
                        --      `remNow <= safeNoPrepCeil` with `0` preps, so T1's `101`-dmg roll killed `102 -> 0` directly!
                        --      Prepping `1x` at `302 -> 215` (`rem1 = 15`) or `201 -> 114` (`rem1 = 14`) leaves a rock-solid
                        --      `14..15 HP` 1-shot window after T1!
                        local driftMargin = math.min(18, kShotsRaw * 2 + 4)
                        local safeNoPrepCeil = math.max(8, myMin - driftMargin)
                        local minSafeNoPrepFloor = math.min(10, kShotsRaw * 3 + 2)
                        local remNow = hpEff % tDmg
                        if remNow == 0 then remNow = tDmg end
                        if remNow > safeNoPrepCeil or remNow <= minSafeNoPrepFloor then
                            local totalTicksNow, launchTicksNow, _, fTNow = U.GetExactBallisticTicks(bot, c)
                            local upperClean = math.max(8, myMin - math.min(12, kShotsRaw * 2 + 2))
                            local tLastAtkNow = (t.GetLastAttackTime and t:GetLastAttackTime()) or -100
                            local tNextLaunchSec = math.max(0.05, tSpa - math.max(0.0, GameTime() - tLastAtkNow))
                            local tFirstBoltLand = hasTowerBoltInAir
                                and math.min(1.30, maxInAirBoltEta)
                                or ((entry.active and tNextLaunchSec or math.max(tNextLaunchSec, tSpa * 0.85)) + (entry.d / 750.0))
                            local lTicks = launchTicksNow or math.max(12, (totalTicksNow or 22) - (fTNow or 8))
                            -- Cross-Creep Tower Cooldown Reservation (`v7.9.29-pro` `auto-20261108-2131` `01:43` `E1967` + `E1996` Fix!):
                            -- NEVER spend SF's `1.42s` attack cooldown prepping a secondary creep `c` (`not entry.active`) if `t`
                            -- is currently killing `tCurTarget` (`otherStealSec`) before SF can reload and land the killing blow on `tCurTarget`!
                            local otherStealSec = 999.0
                            if (not entry.active) and tCurTarget and tCurTarget ~= c and U.CanQuery(tCurTarget) and tCurTarget:IsAlive() then
                                local otherTDmg = math.max(1, U.CalcExactIntDamage(t, tCurTarget, towerRawAvg))
                                local otherHpEff = tCurTarget:GetHealth() or 0
                                local otherBoltEta = nil
                                local seenEngOther = false
                                for _, op in pairs(U.SafeGetIncomingProjectiles(tCurTarget)) do
                                    if op.is_attack and op.caster == t then
                                        otherHpEff = otherHpEff - otherTDmg
                                        seenEngOther = true
                                        local opLoc = op.location
                                        local odRem = opLoc and GetUnitToLocationDistance(tCurTarget, opLoc) or 300
                                        otherBoltEta = math.min(otherBoltEta or 99.0, odRem / 750.0)
                                    end
                                end
                                if (not seenEngOther) and U.GetSyntheticTowerBoltsOn then
                                    for _, osb in ipairs(U.GetSyntheticTowerBoltsOn(tCurTarget)) do
                                        if osb.caster == t then
                                            otherHpEff = otherHpEff - otherTDmg
                                            otherBoltEta = math.min(otherBoltEta or 99.0, (osb.kRem or 18) / 30.0)
                                        end
                                    end
                                end
                                local remShotsOther = (otherHpEff <= 0) and 0 or math.ceil(otherHpEff / otherTDmg)
                                if otherBoltEta then
                                    otherStealSec = (remShotsOther <= 0) and otherBoltEta or (otherBoltEta + remShotsOther * tSpa)
                                else
                                    local dOtherT = GetUnitToLocationDistance(t, tCurTarget:GetLocation())
                                    otherStealSec = tNextLaunchSec + (dOtherT / 750.0) + math.max(0, remShotsOther - 1) * tSpa
                                end
                            end
                            local blocksActiveTargetCS = ((lTicks / 30.0) + mySpa + 0.36) >= otherStealSec
                            local bestPrep = false
                            if not blocksActiveTargetCS then
                                for nPreps = 1, 2 do
                                    local hpAfterN = hpEff - nPreps * myAvg
                                    -- STRICT INVARIANT (`v4.2.0` `Demo 2` `0:45.37` `550/150/50 HP` @ `tDmg=100, myAvg=47` Fix!):
                                    -- `hpAfterN >= tDmg + 2` and `remN >= 2` unlock exact algebraic preps on BOTH `550 -> 503`
                                    -- (`503 % 100 = 3 + regen = 5..8 HP`) AND `150 -> 103` (`103 - 98 = 5 HP`) while still guaranteeing
                                    -- at least `1` full non-lethal T1 bolt survives (`EarlyHit == 0`)!
                                    if hpAfterN >= tDmg + 2 then
                                        local remN = hpAfterN % tDmg
                                        if remN == 0 then remN = tDmg end
                                        if remN >= 2 and remN <= upperClean then
                                            -- `v7.9.24-pro` + `v7.9.29-pro` (`auto-20261108-2131` `01:44` `E1996` `185 HP` Walk+Reload Fix!):
                                            -- Compute exact physical `timeUntilSteal` from live tower cooldown + flight, and exact
                                            -- `reloadNeed = launchTicksNow/30 + nPreps*mySpa + fTNow/30 + 0.06` (including walk-into-range
                                            -- ticks!) so SF NEVER commits to a long-walk prep that leaves SF on reload when T1 Bolt #2 lands!
                                            local towerShotsToOpen = math.max(1, math.floor((hpAfterN - remN) / tDmg + 0.5))
                                            local extraCyclesToSteal = hasTowerBoltInAir and (towerShotsToOpen + 1) or towerShotsToOpen
                                            local timeUntilSteal = tFirstBoltLand + extraCyclesToSteal * tSpa
                                            local reloadNeed = (lTicks / 30.0) + nPreps * mySpa + ((fTNow or 8) / 30.0) + 0.06
                                            if timeUntilSteal >= reloadNeed then
                                                bestPrep = true
                                                break
                                            end
                                        end
                                    end
                                end
                            end
                            -- `v7.9.21` (`auto-20261107-2214` `00:58` `78 HP`, `02:01` `92 HP`, `05:40` `87 HP`, `07:28` `154 HP` Fix!):
                            -- Before `allyT1` begins attacking `c` (`not entry.active` and `not hasTowerBoltInAir`), if `c` has
                            -- `myMin + 6 < hpEff <= tDmg + 6` (`1` T1 shot WILL 1-hit-steal `c`, especially with Presence `-2/-4` armor!),
                            -- `1` or `2` direct SF preps (`hpEff - nPreps * myAvg` -> `[4 .. myMin]`) set up a clean 1-shot right-click,
                            -- PROVIDED `t` will NOT switch onto `c` and steal `remAvg` before `(nDir)` preps + 1 kill reload finish!
                            if not bestPrep and not blocksActiveTargetCS and (not entry.active) and (not hasTowerBoltInAir) and hpEff <= (tDmg + myAvg + 6) then
                                local cSwitchStealSec = ((otherStealSec < 900.0) and otherStealSec or 0.0) + tSpa + (entry.d / 750.0)
                                for nDir = 1, 2 do
                                    local remAvg = hpEff - nDir * myAvg
                                    local remWorst = hpEff - nDir * sfRange.max
                                    local dirKillNeed = (lTicks / 30.0) + nDir * mySpa + ((fTNow or 8) / 30.0) + 0.08
                                    if remWorst >= 4 and remAvg <= myMin and cSwitchStealSec >= dirKillNeed then
                                        bestPrep = true
                                        break
                                    end
                                end
                            end
                            if bestPrep then
                                L._prepCreep = c
                                L._prepStartLAT = curLAT
                                L._prepIssuedAt = GameTime()
                                L._prepInRangeAt = (math.max(0.0, GetUnitToLocationDistance(bot, c:GetLocation()) - 48.0) <= ((bot:GetAttackRange() or 500) + 25.0)) and GameTime() or nil
                                L._prepExpire = GameTime() + 1.1
                                bot:Action_AttackUnit(c, true)
                                return true
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

-- Exact 30.000 Hz Zero-Cancel Phase-Locked Ballistic Controller (`0–1` Tick Arrival, `0` Fake Swing Cancels!)
function L.ExecutePhaseLockedCS(bot, plan, s, P)
    local target = plan.creep
    local curTick = math.floor(GameTime() * 30.0 + 0.5)    local rec = U._unitTrack[bot]
    local dmgRange = U.SFDamageRange(bot, target)
    local myMinDmg = dmgRange.min
    local maxHP = math.max(1, target:GetMaxHealth())

    -- 1. If our bot is ALREADY mid-windup on `target`, inspect exact arrival tick of THIS active swing!
    -- CRITICAL SOURCE 2 INTRA-TICK LAW (`9058240714.dem` `2:50`, `2:59` & `val = 1..18 HP` slivers fix!):
    -- `CProjectileManager` delivers SF's bolt AT THE START of tick `predImpact` BEFORE same-tick creep melee hits,
    -- so true HP upon bolt impact is the HP at the end of tick `(predImpact - 1)` (`hpBeforeSameTickHits`)!
    -- `v7.9.16` (`auto-20261107-0255` `02:34.60` Flagbearer & `03:48.33` Melee Fix):
    -- Preserve active windup across `curTick <= rec.launchTick + 4` (`remWind = max(0, rec.launchTick - curTick)`) and NEVER
    -- S-cancel a `<= 2`-tick-from-release bolt on a live 1-shot-killable enemy creep against a close allied projectile race!
    if rec and rec.wasAnim and rec.launchTick and curTick <= (rec.launchTick + 4) and bot:GetAttackTarget() == target then
        local remWind = math.max(0, rec.launchTick - curTick)
        local predImpact = remWind + plan.fT
        local hpNow = target:GetHealth() or 0
        local hpAtPred = (predImpact <= 0)
            and hpNow
            or U.PredictHPWithContext(plan.ctx, target, (predImpact - 1) / 30.0, "max")
        local hpAtPredMin = U.PredictHPWithContext(plan.ctx, target, predImpact / 30.0, "min")
        local legalDeny = (not plan.isDeny) or (hpAtPred * 2 < maxHP)

        -- If target is ALREADY provably dead BEFORE our projectile arrives (`hpAtPred == 0`), S-cancel on tick 0 (`S11`)
        -- EXCEPT (`v7.9.31-pro` `R714` Level 1-3 `14..15`-Tick Windup Anti-Stutter Fix!) when we are inside our active
        -- windup (`remWind <= max(15, wT + 1)`) on a live 1-shot-killable enemy creep (`predImpact <= effClose + 9`)!
        -- Previously `remWind <= 9` caused Lvl 1-3 SF (`wT = 13..15` ticks) to start `freeLastChanceSwing` on tick 0 and
        -- self-cancel on tick 2 (`remWind = 11..13 > 9` -> `3x` `1504->1500` oscillation on `8 HP` `R714` at `tk=6132..6142`)!
        local maxRaceWind = math.max(15, (plan.wT or 14) + 1)
        local closeRaceCommit = (not plan.isDeny) and remWind <= maxRaceWind and hpNow > 0
            and ((hpNow <= myMinDmg and predImpact <= ((plan.effClose or 999) + 10))
                or (hpNow <= (dmgRange.max or myMinDmg) and predImpact <= ((plan.effClose or 999) + 8)))
        if hpAtPred <= 0 and hpAtPredMin <= 0 then
            if closeRaceCommit then
                return true
            end
            bot:Action_ClearActions(true)
            return true
        end

        -- `v7.9.31-pro` (`auto-20261109-0026` `M1818 @ tk=4824`, `M1392 @ tk=6170`, `M602 @ tk=6454` 2-Tick Pre-Release Guard!):
        -- In Source 2 C++, `CDOTA_BaseNPC::StudioFrameAdvance()` spawns the attack projectile BEFORE Bot Lua `Think()` runs on
        -- `curTick == launchTick` (and VScript can step by `2` ticks!). Checking `remWind <= 2` (`0.033..0.067s` pre-release)
        -- guarantees 100% of premature `0%`-kill / sliver bolts are S-cancelled BEFORE `AnimEvent_Attack` fires!
        local onFinalLaunchTick = (remWind <= 2)
        local liveFT = math.max(1, U.CalcLaunchFlightTicks(bot:GetLocation(), target, math.max(1, U.GetProjectileSpeedOf(bot))))
        local liveImpact = remWind + math.min(plan.fT or liveFT, liveFT)
        local hpAfterRestartNow = onFinalLaunchTick
            and U.PredictHPWithContext(plan.ctx, target, ((plan.totalT or 20) + 1) / 30.0, "max")
            or 0
        local hpAfterRestartAvg = onFinalLaunchTick
            and U.PredictHPWithContext(plan.ctx, target, ((plan.totalT or 20) + 1) / 30.0, "avg")
            or 0
        local hpAtPredPlus1 = onFinalLaunchTick
            and U.PredictHPWithContext(plan.ctx, target, (predImpact + 1) / 30.0, "avg")
            or hpAtPred
        -- `v7.9.27-pro` + `v7.9.31-pro` (`M1818 @ tk=4824` Reverse-Slot & Non-Lethal Enemy Deny Bolt Guard!):
        --   1. Use `liveImpact - 1` (strictly `< liveImpact`) because any already-in-flight projectile arriving on `ph.k == liveImpact`
        --      sits in an OLDER `m_Projectiles` slot than our not-yet-launched bolt (`our newer bolt resolves FIRST on pre-hit HP!`).
        --   2. NEVER set `contestedProjCommit` from an ENEMY HERO's non-lethal projectile (`ph.isHero` with `hpNow - ph.dmgHi > 0`),
        --      because racing BEFORE/WITH an enemy hero's non-lethal bolt assists their deny (`61 -> 14 -> 0`), whereas waiting `+1..2t`
        --      lets their bolt chip `61 -> 11 HP` onto our blade!
        local contestedProjCommit = false
        local optimisticAlliedDropBefore = 0
        if onFinalLaunchTick and (not plan.isDeny) and plan.ctx then
            local kLimProj = math.max(0, liveImpact - 1)
            local inFlightLoDrop = 0
            for _, ph in ipairs(plan.ctx.projectileHits or {}) do
                if (not ph.isOwnBot) and (ph.k or 999) >= 0 and (ph.k or 999) <= kLimProj then
                    if not ph.isHero then
                        inFlightLoDrop = inFlightLoDrop + (ph.dmgLo or ph.dmg or 0)
                        optimisticAlliedDropBefore = optimisticAlliedDropBefore + (ph.dmgHi or ph.dmg or 0)
                    elseif (hpNow - (ph.dmgHi or ph.dmg or 0)) <= 0 then
                        -- Enemy hero's bolt WILL kill the creep at `ph.k < liveImpact` -> only commit if `hpNow` is already killable!
                        optimisticAlliedDropBefore = optimisticAlliedDropBefore + 0
                    end
                end
            end
            for _, h in ipairs(plan.ctx.hits or {}) do
                if (not h.hero) and h.certain and (h.k or 999) >= 0 and (h.k or 999) <= kLimProj then
                    optimisticAlliedDropBefore = optimisticAlliedDropBefore + (h.dmgHi or 0)
                end
            end
            local hpIfInFlightHits = hpNow - inFlightLoDrop
            if inFlightLoDrop > 0 and hpIfInFlightHits > 0 and hpIfInFlightHits <= (myMinDmg + 1) then
                local enHeroRace = s and s.enemy
                if enHeroRace and U.CanQuery(enHeroRace) and enHeroRace:IsAlive() then
                    local enReachRace = ((enHeroRace.GetAttackRange and enHeroRace:GetAttackRange()) or 500) + 175
                    if U.DistanceBetweenLocations(enHeroRace:GetLocation(), target:GetLocation()) <= enReachRace then
                        contestedProjCommit = true
                    end
                end
            end
        end
        -- Zero-Probability Sliver Gate (`M602` `83->22 HP` & `M1392` `129->33 HP` Fix!):
        -- If even after ALL optimistic allied projectiles + certain allied/tower swings strictly before `liveImpact`,
        -- `hpBeforeOurBoltBest > dmgRange.max + 1`, releasing our bolt has `0.00%` kill probability, serves a `14..33 HP`
        -- sliver, AND locks `1.60s` reload through the real kill window! S-cancel immediately EVEN IF `hpAfterRestartNow <= 0`!
        local hpBeforeOurBoltBest = hpNow - optimisticAlliedDropBefore
        local zeroKillProbSliver = onFinalLaunchTick
            and (not plan.isDeny)
            and (not contestedProjCommit)
            and (hpBeforeOurBoltBest > ((dmgRange.max or myMinDmg) + 1))
        local raceWinPlus1 = onFinalLaunchTick and (not plan.isDeny) and (not zeroKillProbSliver)
            and (contestedProjCommit or (hpAfterRestartAvg <= 0 and hpAtPredPlus1 > 0 and hpAtPredPlus1 <= myMinDmg))
        local earlySliverGuaranteed = onFinalLaunchTick
            and (not plan.isDeny)
            and (not raceWinPlus1)
            and (zeroKillProbSliver or ((hpAtPred > myMinDmg) and (hpAfterRestartNow > 0)))
        if ((predImpact >= plan.kTargetImpact and predImpact <= (plan.effClose or 999) + 1) and not earlySliverGuaranteed)
            or (hpAtPred > 0 and hpAtPred <= myMinDmg and legalDeny and not zeroKillProbSliver)
            or raceWinPlus1 then
            return true
        end

        -- ONLY abort an already-started swing if the creep unexpectedly stopped taking damage and our bolt
        -- would genuinely arrive BEFORE killable threshold (`hpAtPred > myMinDmg`)!
        if onFinalLaunchTick then
            local doNotAbortLastChance = (not plan.isDeny) and (not zeroKillProbSliver)
                and (raceWinPlus1 or (hpAfterRestartNow <= 0
                    and hpAtPred > 0
                    and hpAtPred <= ((dmgRange.max or myMinDmg) + 1)))
            if not doNotAbortLastChance then
                bot:Action_ClearActions(true)
            end
            return true
        end
        return true
    end

    -- 2. Not mid-windup on `target` right now: compute exact integer slack `freshDelta`
    local freshDelta = plan.kTargetImpact - plan.totalT
    local nowG = GameTime()
    local liveEnemy = s and s.enemy
    local hasLiveEnemy = liveEnemy and U.CanQuery(liveEnemy) and liveEnemy:IsAlive()
    local dLiveEnemy = hasLiveEnemy and GetUnitToLocationDistance(bot, liveEnemy:GetLocation()) or 9999

    -- Two-Phase CS Slack Weaving (`v5.0.0` Pro Mid Upgrade — fixes `1000+` right-click deficit & silent `E` coils):
    --   * COMMIT PHASE (`freshDelta <= 18` for enemy CS, `<= 10` for ally deny): 100% sacred phase-lock (`0` missed CS!).
    --   * SLACK PHASE (`freshDelta >= 19` for enemy CS, `>= 11` for ally deny): compute `freeSlackSec = (freshDelta - 4) / 30`
    --     and yield (`return false` with `L._imminentCS == false`) whenever ANY safe combat/punish action fits inside the
    --     slack window BEFORE we must pre-align & start our CS swing!
    local enemyPokingDuringWait = hasLiveEnemy and dLiveEnemy <= 965
        and ((liveEnemy.GetAttackTarget and liveEnemy:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(liveEnemy, 1.45)))
    local alreadySwingingAtHero = hasLiveEnemy and U.IsAttackingAction(bot) and bot:GetAttackTarget() == liveEnemy
    local commitCutoff = plan.isDeny and 10 or 18
    local mySpaNow = math.max(0.65, bot:GetSecondsPerAttack() or 1.55)
    if freshDelta > commitCutoff and hasLiveEnemy then
        local freeSlackSec = (freshDelta - 4) / 30.0
        local enemySalving = U.IsEnemyHighValueRegen and U.IsEnemyHighValueRegen(liveEnemy) and dLiveEnemy <= 965
        -- Shadowraze weave does NOT put basic attack on cooldown (`0.55s` cast point), so `freeSlackSec >= 0.72` suffices!
        local enemyRootedCS = U.IsAttackingAction(liveEnemy)
            and (not liveEnemy.GetAttackTarget or liveEnemy:GetAttackTarget() ~= bot)
            and dLiveEnemy <= 740 and freeSlackSec >= 0.72 and (bot:GetMana() or 0) >= 130
        local myAtkReady = (nowG - (bot:GetLastAttackTime() or -100)) >= (mySpaNow * 0.90)
        local aggroCdActive = nowG < (((U._State and U._State.myCreepAggroCdUntil) or 0) - 0.25)
        local nearestEnemyCreepD = 9999
        for _, ec in pairs((s and s.enemyCreeps) or {}) do
            if U.CanQuery(ec) and ec:IsAlive() then
                local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                if dc < nearestEnemyCreepD then nearestEnemyCreepD = dc end
            end
        end
        -- `v7.0.0` CS-Preservation Fix (`ShaNachnetsya.dem` 16 CS vs 17 Dire-T1 CS root cause!):
        -- Right-clicking the enemy hero puts SF's basic attack on its FULL `mySpaNow` (~1.45s) cooldown,
        -- so hero right-click weaves MUST require `freeSlackSec >= mySpaNow + 0.38` (NEVER `mySpaNow * 0.45`!)
        -- AND zero creep-aggro pull (`aggroCdActive or nearestEnemyCreepD > 502`, NEVER overridden by `enMana < 75`!).
        local dryPokeBlock = U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, liveEnemy, s) or false
        local enemyMovingAwayPoke = U._K and U._K.IsEnemyMovingAway and U._K.IsEnemyMovingAway(bot, liveEnemy) or false
        local myAtkRangeSlack = (bot:GetAttackRange() or 525)
        local zeroAggroPokeReady = (not dryPokeBlock) and myAtkReady and freeSlackSec >= (mySpaNow + 0.35)
            and dLiveEnemy <= myAtkRangeSlack + (enemyMovingAwayPoke and 35 or 75)
            and (aggroCdActive or nearestEnemyCreepD > 502
                or (#((s and s.enemyCreeps) or {}) <= 3 and (bot:GetHealth() or 0) >= 380))
            and not (U.IsOutRazedTier and U.IsOutRazedTier(bot, liveEnemy))
            and (bot:GetHealth() or 0) >= 280
        local dominantZonePunish = false
        if not dryPokeBlock and freeSlackSec >= 0.80 and dLiveEnemy <= 835
            and U.IsLaneDominant and U.IsLaneDominant(bot, s, nil) then
            local eLocSlack = liveEnemy:GetLocation()
            local dWaveSlack = 9999
            for _, ac in pairs((s and s.allyCreeps) or {}) do
                if U.CanQuery(ac) and ac:IsAlive() then
                    local dw = U.DistanceBetweenLocations(ac:GetLocation(), eLocSlack)
                    if dw < dWaveSlack then dWaveSlack = dw end
                end
            end
            if dWaveSlack <= 790 then
                local manaSlack = bot:GetMana() or 0
                local razeInBand = false
                if manaSlack >= 135 or (manaSlack >= 75 and (liveEnemy:GetHealth() or 999) <= 360) then
                    for _, spec in ipairs({
                        { "nevermore_shadowraze1", 200 },
                        { "nevermore_shadowraze2", 450 },
                        { "nevermore_shadowraze3", 700 },
                    }) do
                        local abS = bot:GetAbilityByName(spec[1])
                        if abS and abS:GetLevel() > 0 and abS:IsCooldownReady() and math.abs(dLiveEnemy - spec[2]) <= 195 then
                            razeInBand = true
                            break
                        end
                    end
                end
                local lightWavePoke = myAtkReady and freeSlackSec >= (mySpaNow + 0.38)
                    and dLiveEnemy <= (bot:GetAttackRange() or 525) + (enemyMovingAwayPoke and 20 or 38)
                    and #((s and s.enemyCreeps) or {}) <= 2
                if razeInBand or lightWavePoke then
                    dominantZonePunish = true
                end
            end
        end
        local safePokeAnswer = (not dryPokeBlock) and enemyPokingDuringWait and (freeSlackSec >= (mySpaNow + 0.32) or (bot:GetHealth() or 999) <= 245)
        if safePokeAnswer or enemySalving or enemyRootedCS or zeroAggroPokeReady or dominantZonePunish then
            return false
        end
    end
    local heroSwingCommitted = hasLiveEnemy and U._State
        and nowG < (U._State.heroAttackCommitUntil or 0)
        and U._State.heroAttackTarget == liveEnemy
        and U.IsAttackingAction(bot)
        and dLiveEnemy <= 795
    if (enemyPokingDuringWait and (bot:GetHealth() or 999) <= 245)
        or ((alreadySwingingAtHero or heroSwingCommitted) and freshDelta >= 8) then
        return false
    end

    -- Source 2 Lane Creep Aggro & Ranged-Creep Reset Physics (`v5.0.0`):
    --   1. During the `2.30s` forced protective chase (`nowG < myCreepChaseUntil`), A-clicking an allied creep CANNOT drop
    --      aggro in Source 2 — kite back `435u` instead of wasting a tick attacking our own creep!
    --   2. An enemy ranged creep (`500u` range) NEVER re-evaluates `Condition 1/3` unless forced to move (`dc > 505u`)!
    local creepsAggroOnMeDuringWait = false
    local rangedAggroCreep = nil
    local recentCreepHitWait = (bot.WasRecentlyDamagedByCreep and bot:WasRecentlyDamagedByCreep(0.85)) or false
    if s and s.enemyCreeps then
        for _, ec in pairs(s.enemyCreeps) do
            if U.CanQuery(ec) and ec:IsAlive() then
                local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                if (ec.GetAttackTarget and ec:GetAttackTarget() == bot) or (recentCreepHitWait and dc <= 215) then
                    creepsAggroOnMeDuringWait = true
                    local ecRange = (ec.GetAttackRange and ec:GetAttackRange()) or 100
                    if ecRange > 300 and dc <= 505 then
                        rangedAggroCreep = ec
                    end
                end
            end
        end
    end
    local chaseLockedNow = nowG < (((U._State and U._State.myCreepChaseUntil) or 0) - 0.08)
    if creepsAggroOnMeDuringWait and not chaseLockedNow and freshDelta >= 8 and s and s.allyCreeps then
        if rangedAggroCreep and freshDelta >= 18 then
            local rcLoc = rangedAggroCreep:GetLocation()
            local fnt = P.GetFountain(bot)
            local stepOut = rcLoc + (fnt - rcLoc):Normalized() * 520
            if U.DistanceBetweenLocations(stepOut, target:GetLocation()) <= (bot:GetAttackRange() or 525) + 45 then
                bot:Action_MoveToLocation(stepOut)
                return true
            end
        end
        if L._lastDeaggroAt and nowG < L._lastDeaggroAt then
            L._lastDeaggroAt = -100
        end
        if nowG >= (L._lastDeaggroAt or -100) + 1.30 then
            local maxDeaggroReach = (bot:GetAttackRange() or 525) + 35
            local bestAlly, bestAllyDist = nil, math.huge
            local fallbackAlly, fallbackDist = nil, math.huge
            -- Prefer `hp * 2 > maxHp + 20` (`> 50% HP`) allied creeps so `Action_AttackUnit` resets creep aggro
            -- in `0.00s` WITHOUT starting a legal `< 50% HP` deny swing (`1.14s` attack cooldown)!
            for _, ac in pairs(s.allyCreeps) do
                if U.CanQuery(ac) and ac:IsAlive() and ac ~= target then
                    local aHp = ac:GetHealth() or 0
                    local aMax = ac:GetMaxHealth() or 550
                    local da = GetUnitToLocationDistance(bot, ac:GetLocation())
                    if da <= maxDeaggroReach then
                        if aHp * 2 > aMax + 20 and da < bestAllyDist then
                            bestAllyDist, bestAlly = da, ac
                        elseif aHp > 95 and freshDelta >= 22 and da < fallbackDist then
                            fallbackDist, fallbackAlly = da, ac
                        end
                    end
                end
            end
            local chosenAlly = bestAlly or fallbackAlly
            if chosenAlly then
                L._lastDeaggroAt = nowG
                bot:Action_AttackUnit(chosenAlly, true)
                return true
            end
        end
    end

    -- Helper: ensure slack positioning (`optPos`) NEVER pulls SF forward into lethal enemy range or onto enemy ramp
    -- (`auto-20261031-0230` `01:00.3`, `01:51.7`, `02:01.4`, `02:08.3` Root-Cause Fix!)
    local function sanitizeSlackOptPos(optPos)
        if not optPos then return nil end
        local bCur = bot:GetLocation()
        local cCur = target:GetLocation()
        local fnt = P.GetFountain(bot)
        if (enemyPokingDuringWait or creepsAggroOnMeDuringWait) then
            optPos = cCur + (fnt - cCur):Normalized() * math.min(460, (bot:GetAttackRange() or 525) - 40)
        end
        if s and s.enemyT1Alive ~= false and s.enemyT1Loc then
            local shieldCnt, shieldHp = 0, 0
            for _, ac in pairs(s.allyCreeps or {}) do
                if U.CanQuery(ac) and ac:IsAlive() and U.DistanceBetweenLocations(ac:GetLocation(), s.enemyT1Loc) <= 755 then
                    local ahp = ac:GetHealth() or 0
                    shieldHp = shieldHp + ahp
                    if ahp > 190 then
                        shieldCnt = shieldCnt + 1
                    end
                end
            end
            local fragileSingleShield = hasLiveEnemy and (shieldCnt < 2) and (shieldHp < 310)
            if (shieldCnt < 1 or fragileSingleShield) and U.DistanceBetweenLocations(optPos, s.enemyT1Loc) < 905 then
                local safeOut = s.enemyT1Loc + (fnt - s.enemyT1Loc):Normalized() * 905
                if U.DistanceBetweenLocations(safeOut, cCur) <= (bot:GetAttackRange() or 525) - 5 then
                    optPos = safeOut
                end
            elseif #(s.enemyCreeps or {}) == 0 and U.DistanceBetweenLocations(optPos, s.enemyT1Loc) < 660 then
                optPos = s.enemyT1Loc + (fnt - s.enemyT1Loc):Normalized() * 660
            end
        end
        if hasLiveEnemy then
            local eCur = liveEnemy:GetLocation()
            local dNowE = U.DistanceBetweenLocations(bCur, eCur)
            local dOptE = U.DistanceBetweenLocations(optPos, eCur)
            local inReachAlready = U.DistanceBetweenLocations(bCur, cCur) <= (bot:GetAttackRange() or 525) - 18
            local enHasCoilMana = ((liveEnemy:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(liveEnemy) or 0)) >= 75
            local dryVsEnemy = U.IsDryVsArmedEnemySF and U.IsDryVsArmedEnemySF(bot, liveEnemy, s) or false
            local cautiousState = dryVsEnemy
                or ((bot:GetHealth() or 999) <= 390)
                or ((liveEnemy:GetLevel() or 1) > (bot:GetLevel() or 1))
                or (U.IsOutRazedTier and U.IsOutRazedTier(bot, liveEnemy))
                or (((U.GetShadowrazeDebuff and U.GetShadowrazeDebuff(bot)) or 0) >= 1)
                or (enHasCoilMana and (bot:GetMana() or 0) < 135)
            if inReachAlready and cautiousState and dOptE < dNowE - 14 then
                return nil
            end
            if dryVsEnemy then
                local dryStand = U.GetDrySafeStandoffDist(bot, liveEnemy)
                if dOptE < dryStand then
                    local maxBackDry = cCur + (fnt - cCur):Normalized() * math.max(430, (bot:GetAttackRange() or 525) - 16)
                    local dBackE = U.DistanceBetweenLocations(maxBackDry, eCur)
                    local curRaceRef = (U._K and (U._K._race or U._K._lastRace)) or nil
                    local minStrikeDry = (freshDelta <= 15) and 525 or math.min(dryStand, 858)
                    if dBackE >= minStrikeDry and not IsPositionLethalFromEnemy(bot, maxBackDry, liveEnemy, curRaceRef, plan.isDeny) then
                        optPos = maxBackDry
                        dOptE = dBackE
                    elseif freshDelta > 15 then
                        -- Never park slack wait at `695u` (`E700` bullseye!): hold safely at `858u` until `freshDelta <= 15`!
                        local safeDryWait = eCur + (fnt - eCur):Normalized() * math.max(858, dryStand)
                        if not IsPositionLethalFromEnemy(bot, safeDryWait, liveEnemy, curRaceRef, plan.isDeny) then
                            optPos = safeDryWait
                            dOptE = U.DistanceBetweenLocations(optPos, eCur)
                        else
                            return nil
                        end
                    else
                        return nil
                    end
                end
            end
            -- `9070869385.dem` `03:13.2–03:14.5` + `9070886384.dem` `03:54.40` (`474u` `R1` hull edge!) Fix:
            -- NEVER let CS slack positioning walk SF inside an enemy SF's `Shadowraze1 (200+250+24 = 474u)` while waiting
            -- for a creep when the enemy has coil mana and `Raze1` off cooldown!
            if enHasCoilMana and dOptE < 495 and dOptE < dNowE - 10
                and not (U._K and U._K.EnemyRazeReadyIn and U._K.EnemyRazeReadyIn("near") > 2.0) then
                return nil
            end
            local raceRef = (U._K and (U._K._race or U._K._lastRace)) or nil
            if IsPositionLethalFromEnemy(bot, optPos, liveEnemy, raceRef, plan.isDeny) then
                local maxBack = cCur + (fnt - cCur):Normalized() * math.max(415, (bot:GetAttackRange() or 525) - 20)
                if not IsPositionLethalFromEnemy(bot, maxBack, liveEnemy, raceRef, plan.isDeny) then
                    optPos = maxBack
                else
                    return nil
                end
            end
        end
        return optPos
    end

    -- Move off river lowground (`25%` uphill miss!) or to contested safe stance (`415–480u` behind allied wave) while we have slack —
    -- UNLESS low-HP (`<= 42%` & `< 410 HP`) vs a spell-ready enemy during early slack (`freshDelta >= 14`), where holding safe spacing avoids edge-dance oscillation!
    local lowHpHoldBack = hasLiveEnemy
        and ((bot:GetHealth() or 999) <= math.min(410, (bot:GetMaxHealth() or 600) * 0.42))
        and ((liveEnemy:GetMana() or 0) >= 75)
        and (freshDelta >= 14)
    -- Only use `"AGGRESSIVE"` forward CS stance (`250u` past wave) when enemy is dry (`< 75 MP`) OR we hold both high HP (`>= 620`) & `2+` coils (`>= 150 MP`)!
    local enPoolForStance = hasLiveEnemy and ((liveEnemy:GetMana() or 0) + (U.GetMangoMana and U.GetMangoMana(liveEnemy) or 0)) or 0
    local allowAggroSlackStance = (U.IsLaneDominant and U.IsLaneDominant(bot, s, nil))
        and (not hasLiveEnemy or enPoolForStance < 75 or ((bot:GetHealth() or 0) >= 620 and (bot:GetMana() or 0) >= 150))
    local slackPosMode = allowAggroSlackStance and "AGGRESSIVE" or "NEUTRAL"
    -- `9070869385.dem` `03:13.87` + `v7.9.8-pro` (`1630` `2 vs 23` & `1638` `6 vs 13` Right-Clicks + `00:28.6` Mirror `E` Fix!):
    -- Yield CS slack (`return false` so `Stage B0/B` combat, mirror counter-raze, & zero-aggro right-click harass can fire
    -- WITHOUT ever missing the creep!) in three strictly CS-safe windows:
    --   (a) Close-duel or recent enemy raze/hit (`freshDelta >= 19` ticks = `>= 0.63s` > `0.55s` raze cast): allows instant
    --       `E(700)` mirror counter-raze (`00:28.60`) and close `Q`/`W` counter-coils (`d <= 475u`).
    --   (b) Full hero right-click weave (`freshDelta >= spaTicks + 7` & attack off CD & `d <= atkRange + 75`): SF completes a
    --       full hero right-click AND recovers 100% of attack cooldown BEFORE `freshDelta == 0` on the creep!
    --   (c) Waiting on an allied deny (`plan.isDeny` & `freshDelta >= 14`) while enemy swings at a creep or hits us within `565u`.
    if hasLiveEnemy then
        local dLiveE = U.DistanceBetweenLocations(bot:GetLocation(), liveEnemy:GetLocation())
        local spaTicksYield = math.ceil((bot:GetSecondsPerAttack() or 1.45) * 30.0)
        local atkReadyYield = ((GameTime() - (bot:GetLastAttackTime() or -100)) >= ((bot:GetSecondsPerAttack() or 1.45) * 0.90))
        local recentHitByEnemy = (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(liveEnemy, 1.35))
            or (((U.GetShadowrazeDebuff and U.GetShadowrazeDebuff(bot)) or 0) >= 1)
        local enemySwinging = (U.IsAttackingAction and U.IsAttackingAction(liveEnemy)) or false
        if freshDelta >= 18 and (bot:GetMana() or 0) >= 75
            and (dLiveE <= 475 or (freshDelta >= 19 and dLiveE <= 865 and recentHitByEnemy)) then
            return false
        end
        -- `v7.9.17`: Yield slack (`freshDelta >= 19` ticks = `>= 0.633s > 0.55s` coil cast point!) whenever `liveEnemy`
        -- steps into our `500u` creep re-aggro perimeter or outer-edge `W(450)`/`E(700)` punish band!
        if freshDelta >= 19 and U.ShouldYieldSlackForProactiveZone and U.ShouldYieldSlackForProactiveZone(bot, liveEnemy, s) then
            return false
        end
        if freshDelta >= (spaTicksYield + 12) and atkReadyYield and dLiveE <= ((bot:GetAttackRange() or 525) + 45) then
            return false
        end
        -- `v7.9.21` + `v7.9.31-pro` (`auto-20261109-0026` `0:37` `tk=4110` `M544` Reload-Lockout Fix!):
        -- A hero right-click spends `wT_hero + spaTicks + turnBack` (`>= spaTicks + 10` ticks!). Previously yielding on
        -- enemy CS at `spaTicks - 3` (`13..15` ticks short!) locked SF's `1.60s` reload straight through `M544`'s death!
        local aggroPullActive = s and (s.enemyAggroPullUntil or 0) > GameTime()
        local earlyLanePullWindow = (((type(DotaTime) == "function" and DotaTime()) or 999) <= 270)
            and dLiveE <= ((bot:GetAttackRange() or 525) + 35)
            and (bot:GetHealth() or 0) >= 360
        if (aggroPullActive or earlyLanePullWindow) and atkReadyYield and dLiveE <= ((bot:GetAttackRange() or 525) + 45) then
            if (plan.isDeny and freshDelta >= 18)
                or (not plan.isDeny and freshDelta >= (spaTicksYield + 11)
                    and ((plan.effClose or 999) - (plan.totalT or 0)) >= 5) then
                return false
            end
        end
        -- `v7.9.18` Proactive Highground Right-Click Dominance Yield:
        -- When holding `z >= +45` Highground over a river/lowground rival with attack ready and ample CS slack,
        -- yield so `HandleHighgroundZeroAggroHarass` fires a `100%`-accuracy downhill shot (`enemy suffers 25% miss`)!
        if freshDelta >= (spaTicksYield + 10) and atkReadyYield and dLiveE <= ((bot:GetAttackRange() or 525) + 65)
            and ((bot:GetLocation().z or 128) - (liveEnemy:GetLocation().z or 0)) >= 45 then
            return false
        end
        if plan.isDeny and freshDelta >= 14 and atkReadyYield and dLiveE <= ((bot:GetAttackRange() or 525) + 55)
            and (enemySwinging or recentHitByEnemy) then
            return false
        end
        -- `v7.9.23` + `v7.9.25-pro` (`auto-20261108-1609` `00:27..02:34` Counter-Pull & Highground-Breaker Yield!):
        -- Yield CS slack (`freshDelta >= 20` ticks = `>= 0.67s` for a `1`-tick aggro click + drag!) whenever our equilibrium /
        -- counter-aggro pull is ready (`dLiveE >= 485`), breaking enemy aggro-pulls & highground freezes!
        if freshDelta >= 20 and dLiveE >= 485 and dLiveE <= 1450 and (bot:GetHealth() or 0) >= 235 then
            local nowPullY = GameTime()
            local stPullY = U._State
            if (not stPullY or (nowPullY >= (stPullY.myCreepAggroCdUntil or 0)
                    and nowPullY >= (stPullY.lastDefAggroPullAt or -100) + 3.15))
                and U.NeedsLowgroundEquilibriumPull and U.NeedsLowgroundEquilibriumPull(bot, s, nil) then
                return false
            end
        end
    end
    if freshDelta >= 9 and U._State and U._State.trySafeTreadsCb then
        if U._State.trySafeTreadsCb(bot, "FIGHT", true) then
            return true
        end
    end
    -- `9071946472.dem` `03:09.33–03:12.43` Post-Kill Slack Whiplash Fix + `v7.9.24-pro` True `z=128` Plateau Check:
    -- When the enemy hero is DEAD (`s.enemyAlive == false`) and SF is already comfortably in attack range (`<= atkRange - 28`)
    -- ON EQUAL/HIGHER WORLD ELEVATION (`IsSameOrHigherElevation`, never stopping on mid-stairs at `z=45..76`!)
    -- and safely outside Enemy T1 (`>= 905u`), hold clean firing stance instead of walking `400u` backward & forward!
    local bNowPre = bot:GetLocation()
    local cNowPre = target:GetLocation()
    local trueSameOrHigherZ = (P and P.IsSameOrHigherElevation)
        and P.IsSameOrHigherElevation(bNowPre, cNowPre, bNowPre)
        or ((type(GetHeightLevel) ~= "function" or ((GetHeightLevel(bNowPre) or 0) >= (GetHeightLevel(cNowPre) or 0)))
            and ((bNowPre.z or 0) >= (cNowPre.z or 0) - 12))
    local deadEnemyAlreadyInRange = (not hasLiveEnemy) and (s and s.enemyAlive == false)
        and trueSameOrHigherZ
        and U.DistanceBetweenLocations(bNowPre, cNowPre) <= ((bot:GetAttackRange() or 525) - 28)
        and not (s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(bNowPre, s.enemyT1Loc) < 905)
    -- `v7.9.19` Pre-Shot Ballistic Stillness (`9080125239.dem` `06:07` & `02:34` Pre-Fire Jitter Fix):
    -- Within `<= 14` ticks (`<= 0.47s`) of launching a CS bolt, if SF is ALREADY comfortably in attack range (`<= atkRange - 25`),
    -- on equal/higher terrain (`trueSameOrHigherZ`, `0%` uphill miss!), and safe from enemy hero & enemy T1, hold firing stance!
    local steadyInRangePreShot = false
    if freshDelta <= 14 then
        local safeEnT1S = not (s and s.enemyT1Alive ~= false and s.enemyT1Loc and U.DistanceBetweenLocations(bNowPre, s.enemyT1Loc) < 905)
        local safeHeroS = (not hasLiveEnemy) or not IsPositionLethalFromEnemy(bot, bNowPre, liveEnemy, (U._K and (U._K._race or U._K._lastRace)) or nil, plan.isDeny)
        if trueSameOrHigherZ and safeEnT1S and safeHeroS
            and (not creepsAggroOnMeDuringWait) and (not enemyPokingDuringWait)
            and U.DistanceBetweenLocations(bNowPre, cNowPre) <= ((bot:GetAttackRange() or 525) - 25) then
            steadyInRangePreShot = true
        end
    end
    local degTickSlack = (C.BALLISTIC and C.BALLISTIC.SF_DEG_PER_TICK) or 24.0
    local function canMoveAndTurnBackInSlack(curB, curC, candOpt, remSlack)
        if not candOpt then return false end
        local mvYaw = math.deg(math.atan2(candOpt.y - curB.y, candOpt.x - curB.x)) % 360
        local tgYaw = math.deg(math.atan2(curC.y - candOpt.y, curC.x - candOpt.x)) % 360
        local retAng = math.abs(((tgYaw - mvYaw + 180) % 360) - 180)
        local retTurnT = (retAng > 11.5) and math.ceil((retAng - 11.5) / degTickSlack) or 0
        return remSlack >= (retTurnT + 9)
    end
    local minSlackForMove = math.max(7, (plan.turnT or 0) + 4)
    if freshDelta >= minSlackForMove and not lowHpHoldBack and not deadEnemyAlreadyInRange and not steadyInRangePreShot and P and P.GetLasthitPosition then
        local optPos = sanitizeSlackOptPos(P.GetLasthitPosition(bot, s.enemyCreeps, s.allyCreeps, target, slackPosMode))
        if optPos and U.DistanceBetweenLocations(bot:GetLocation(), optPos) > 32
            and canMoveAndTurnBackInSlack(bNowPre, cNowPre, optPos, freshDelta) then
            bot:Action_MoveToLocation(optPos)
            return true
        end
    end

    -- Exact firing tick (`freshDelta <= 0` AND `A04` `< 50% HP` legal deny check): ONE clean swing -> ZERO self-cancels!
    local denyLegalRightNow = (not plan.isDeny) or ((target:GetHealth() or maxHP) * 2 < maxHP)
    if freshDelta <= 0 and denyLegalRightNow then
        bot:Action_AttackUnit(target, true)
        return true
    end

    -- Pre-align hero yaw to `0.00 deg` toward `target` smoothly WITHOUT fake attack-swing spam (`0` `SCancel`!):
    -- Align strictly at `freshDelta >= 3` down to `<= 2.5 deg` so on ticks `freshDelta == 2, 1, 0` hero stands dead-still at `0.0 deg`!
    local bLoc = bot:GetLocation()
    local cLoc = target:GetLocation()
    local wantYaw = math.deg(math.atan2(cLoc.y - bLoc.y, cLoc.x - bLoc.x)) % 360
    local curYaw = (bot.GetFacing and bot:GetFacing()) or wantYaw
    local angErr = math.abs(((wantYaw - curYaw + 180) % 360) - 180)

    if freshDelta >= 2 and angErr > 5.5 and U.DistanceBetweenLocations(bLoc, cLoc) > 125 then
        bot:Action_MoveToLocation(bLoc + (cLoc - bLoc):Normalized() * 15)
        return true
    end

    if freshDelta >= math.max(4, (plan.turnT or 0) + 3) and not deadEnemyAlreadyInRange and not steadyInRangePreShot and P and P.GetLasthitPosition then
        local optPos = sanitizeSlackOptPos(P.GetLasthitPosition(bot, s.enemyCreeps, s.allyCreeps, target, slackPosMode))
        if optPos and U.DistanceBetweenLocations(bLoc, optPos) > 28
            and canMoveAndTurnBackInSlack(bLoc, cLoc, optPos, freshDelta) then
            bot:Action_MoveToLocation(optPos)
            return true
        end
    end

    if U.IsAttackingAction(bot) then
        bot:Action_ClearActions(true)
    end
    return true
end

-- Shared Enemy-T1 & Post-Kill Ally-Deny Filter (`v7.8.0`):
--   1. `ShaNachnetsya` `00:45–01:01` Fix: When the enemy hero is DEAD (`s.enemyAlive == false`) and our wave CANNOT
--      crash into Enemy T1 before he respawns (`not U.CanCrashWaveBeforeEnemyReturn`), ALWAYS deny allied `< 50% HP`
--      creeps for Necromastery souls + wave equilibrium so he does NOT TP back to a 6-creep double-wave under his T1!
--   2. `9070886384.dem` `02:40.87–02:42.53` Ranged-Creep Deny Fix: Distinguish `activelySiegingEnemyT1` (`dBotT1 <= 885`
--      with live creep shield) from standing safely OUTSIDE Enemy T1 (`dBotT1 > 885`), allowing 100% of tower-safe
--      outside-range denies (`dCreepToT1 + atkRange >= 900`, e.g. ranged creep `#1030` at `613u` + `525u = 1138u >= 900u`)!
local function ResolveDenyListAndSiegeFlag(bot, s, allyCreeps)
    local fastPostKillCrash = (s and s.enemyAlive == false)
        and (U.CanCrashWaveBeforeEnemyReturn and U.CanCrashWaveBeforeEnemyReturn(bot, s)) or false
    local nearEnT1 = (s and s.enemyT1Alive and s.enemyT1Loc
        and GetUnitToLocationDistance(bot, s.enemyT1Loc) <= 1180) and true or false
    if fastPostKillCrash then
        local dT1 = (s and s.enemyT1Alive and s.enemyT1Loc) and GetUnitToLocationDistance(bot, s.enemyT1Loc) or 9999
        -- `v7.9.23` (`auto-20261108-0512` `00:46–00:48` Uncontested `38 HP` & `52 HP` Deny Fix!):
        -- Even during a genuine post-kill crash, NEVER ignore a 1-hit / near-1-hit allied creep (`hp <= myMin + 14`)
        -- reachable outside unshielded T1 danger — taking `1` swing to deny a `38 HP` dying creep costs ~0 push!
        local instantDenies = {}
        local atkR = math.max(500, bot:GetAttackRange() or 500)
        local tLoc = s and s.enemyT1Alive and s.enemyT1Loc or nil
        for _, ac in pairs(allyCreeps or {}) do
            if U.CanQuery(ac) and ac:IsAlive() then
                local myMinD = U.SFDamageRange(bot, ac).min
                if (ac:GetHealth() or 9999) <= (myMinD + 14)
                    and (not tLoc or (GetUnitToLocationDistance(ac, tLoc) + atkR >= 895)) then
                    instantDenies[#instantDenies + 1] = ac
                end
            end
        end
        return instantDenies, (dT1 <= 885)
    end
    if not nearEnT1 then
        return allyCreeps or {}, false
    end

    local tLoc = s.enemyT1Loc
    local dBotT1 = GetUnitToLocationDistance(bot, tLoc)
    local shieldCreeps = 0
    for _, ac in pairs(allyCreeps or {}) do
        if U.CanQuery(ac) and ac:IsAlive() and (ac:GetHealth() or 0) > 25
            and GetUnitToLocationDistance(ac, tLoc) <= 755 then
            shieldCreeps = shieldCreeps + 1
        end
    end

    local activelySieging = (dBotT1 <= 885) and (shieldCreeps >= 1)
    if activelySieging then
        if shieldCreeps >= 2 then
            return allyCreeps or {}, true
        end
        -- Last lone creep under T1: still allow denying if reachable from outside `900u`!
        local safeLast = {}
        local atkR = math.max(525, bot:GetAttackRange() or 525)
        for _, ac in pairs(allyCreeps or {}) do
            if U.CanQuery(ac) and ac:IsAlive()
                and (GetUnitToLocationDistance(ac, tLoc) + atkR >= 900) then
                safeLast[#safeLast + 1] = ac
            end
        end
        return safeLast, true
    end

    -- Bot is OUTSIDE Enemy T1 (`dBotT1 > 885`): allow every allied creep reachable from a tower-safe spot (`>= 895u` from T1)!
    local outSafe = {}
    local atkR = math.max(525, bot:GetAttackRange() or 525)
    for _, ac in pairs(allyCreeps or {}) do
        if U.CanQuery(ac) and ac:IsAlive()
            and (GetUnitToLocationDistance(ac, tLoc) + atkR >= 895) then
            outSafe[#outSafe + 1] = ac
        end
    end
    return outSafe, false
end

-- Non-mutating peek at the highest-priority securable CS plan (`v5.2.0` helper for `HandleCreepTankDrop` & `war_director`):
-- Returns `bestPlan, etaSec` when an enemy CS or ally deny opens within the sacred window.
local function GetSharedWaveSetup(bot, s, enemyCreeps, allyCreeps)
    if U._inThink and s == (U._W and U._W.s) then
        syncLHMemo()
        if sharedSetupMemo then
            return sharedSetupMemo[1], sharedSetupMemo[2], sharedSetupMemo[3], sharedSetupMemo[4]
        end
        local allySideAtk, enemySideAtk = BuildAllAttackers(
            bot, enemyCreeps, allyCreeps, s.enemyTowers, s.allyTowers, s.enemy
        )
        local denyList, siegingEnemyT1 = ResolveDenyListAndSiegeFlag(bot, s, allyCreeps)
        sharedSetupMemo = { allySideAtk, enemySideAtk, denyList, siegingEnemyT1 }
        return allySideAtk, enemySideAtk, denyList, siegingEnemyT1
    end
    local allySideAtk, enemySideAtk = BuildAllAttackers(
        bot, enemyCreeps, allyCreeps, s.enemyTowers, s.allyTowers, s.enemy
    )
    local denyList, siegingEnemyT1 = ResolveDenyListAndSiegeFlag(bot, s, allyCreeps)
    return allySideAtk, enemySideAtk, denyList, siegingEnemyT1
end

function L.PeekBestPlan(bot, s)
    if not bot or not s then return nil, 999 end
    local isLiveS = U._inThink and (s == (U._W and U._W.s))
    if isLiveS then
        syncLHMemo()
        if peekResultMemo then
            return peekResultMemo.plan, peekResultMemo.eta
        end
    end
    local enemyCreeps = s.enemyCreeps or {}
    local allyCreeps  = s.allyCreeps or {}
    if #enemyCreeps == 0 and #allyCreeps == 0 then
        if isLiveS then peekResultMemo = { plan = nil, eta = 999 } end
        return nil, 999
    end
    U.BeginPredictionFrame()
    local allySideAtk, enemySideAtk, denyList, siegingEnemyT1 = GetSharedWaveSetup(bot, s, enemyCreeps, allyCreeps)
    local candidates = L.ScanCreepCandidates(
        bot, enemyCreeps, denyList, allySideAtk, enemySideAtk, s.enemy, nil
    )
    local plan = L.SelectBestRightClickPlan(bot, candidates, siegingEnemyT1)
    if not plan then
        if isLiveS then peekResultMemo = { plan = nil, eta = 999 } end
        return nil, 999
    end
    local deltaTicks = math.max(0, (plan.kTargetImpact or 0) - (plan.totalT or 0))
    local eta = deltaTicks / 30.0
    if isLiveS then peekResultMemo = { plan = plan, eta = eta } end
    return plan, eta
end

function L.HasImminentCreepCS(bot, s, windowSec, ignoreDenies)
    if not bot or not s then return false, 999, false end
    local win = windowSec or 0.55
    local oneHit = false
    local bLocNow = bot:GetLocation()
    local atkRNow = (bot:GetAttackRange() or 500) + 185
    local allyAtks = nil
    for _, ec in pairs(s.enemyCreeps or {}) do
        if ec and U.CanQuery(ec) and ec:IsAlive() then
            local dr = U.SFDamageRange(bot, ec)
            local ecHp = ec:GetHealth() or 9999
            if ecHp <= (dr.min + 8) then
                -- `v7.9.26-pro` (`9081989180.dem` `01:25..01:30` `66 HP` Unattacked Far Ranged-Creep Tango Freeze Fix!):
                -- Only flag `oneHit` immediately if `ec` is near attack reach (`<= atkR + 185`) OR actually taking DPS!
                if bLocNow and U.DistanceBetweenLocations(bLocNow, ec:GetLocation()) <= atkRNow then
                    oneHit = true
                    break
                else
                    allyAtks = allyAtks or U.MergeLists(s.allyCreeps, s.allyTowers)
                    local ctx = U.GetTargetPredictionContext(ec, allyAtks)
                    if U.PredictHPWithContext(ctx, ec, 1.8) < ecHp - 1 then
                        oneHit = true
                        break
                    end
                end
            end
        end
    end
    local plan, eta = L.PeekBestPlan(bot, s)
    if plan and ignoreDenies and plan.isDeny then
        plan, eta = nil, 999
    end
    if plan and eta <= win then
        return true, eta, oneHit
    end
    return oneHit, (oneHit and 0.0 or eta), oneHit
end

-- `v7.9.31-pro` (`auto-20261109-0026` `0:15` `tk=3794` `M535` Active-Swing Abort & `0:37` `tk=4110` `M544` `1.60s` Reload Lockout Fix!):
-- Returns `true` whenever issuing a hero right-click (or stepping toward the enemy hero above `RunSacredCS`) right now would:
--   1. Cancel an ALREADY active right-click windup on a dying lane creep (`M535 @ 57 HP`), OR
--   2. Lock SF's attack cooldown (`spa + atkPt + flight`) straight through an enemy creep's death window (`M544 @ 145->34->0 HP`)!
function L.WouldRightClickLockoutCS(bot, s)
    if not bot or not s then return false end
    local isLiveLock = U._inThink and U._W and (s == U._W.s)
    if isLiveLock then
        syncLHMemo()
        if lockoutCSMemo ~= nil then return lockoutCSMemo end
    end
    -- 1. Never abort an active CS windup on a lane creep!
    local animAct = (bot.GetAnimActivity and bot:GetAnimActivity()) or 0
    local recSelf = U._unitTrack and U._unitTrack[bot] or nil
    local activeSwingNow = (U.IsAttackingAction and U.IsAttackingAction(bot))
        or (animAct >= 1503 and animAct <= 1505)
        or (recSelf and recSelf.wasAnim)
    if activeSwingNow then
        local curTgt = (bot.GetAttackTarget and bot:GetAttackTarget()) or (recSelf and recSelf.target) or nil
        if curTgt and U.CanQuery(curTgt) and curTgt:IsAlive() and not (curTgt.IsHero and curTgt:IsHero()) then
            local drCur = U.SFDamageRange(bot, curTgt)
            if (curTgt:GetHealth() or 9999) <= ((drCur.max or drCur.min) + 55) then
                if isLiveLock then lockoutCSMemo = true end
                return true
            end
        end
    end
    local eCreeps = s.enemyCreeps
    if not eCreeps or #eCreeps == 0 then
        if isLiveLock then lockoutCSMemo = false end
        return false
    end
    local bLoc = bot:GetLocation()
    if not bLoc then return false end
    local maxScanDist = (bot:GetAttackRange() or 500) + 340
    local spa = bot:GetSecondsPerAttack() or 1.60
    local atkPt = bot:GetAttackPoint() or 0.50
    local lockWindow = spa + atkPt + 0.28
    local closeWindow = spa + atkPt + 0.45
    local allyAtks = nil
    for _, ec in pairs(eCreeps) do
        if ec and U.CanQuery(ec) and ec:IsAlive() then
            local dC = U.DistanceBetweenLocations(bLoc, ec:GetLocation())
            if dC <= maxScanDist then
                local dr = U.SFDamageRange(bot, ec)
                local ecHp = ec:GetHealth() or 9999
                if ecHp <= (dr.min + 14) then
                    if isLiveLock then lockoutCSMemo = true end
                    return true
                end
                if ecHp <= (dr.min + 185) then
                    if not allyAtks then
                        U.BeginPredictionFrame()
                        allyAtks = (GetSharedWaveSetup(bot, s, eCreeps, s.allyCreeps or {}))
                    end
                    local ctx = U.GetTargetPredictionContext(ec, allyAtks)
                    local hpAtLock = U.PredictHPWithContext(ctx, ec, lockWindow, "avg")
                    if hpAtLock < (ecHp - 2) then
                        local hpDuringCd = U.PredictHPWithContext(ctx, ec, spa * 0.92, "avg")
                        local hpAtClose  = U.PredictHPWithContext(ctx, ec, closeWindow, "avg")
                        if hpDuringCd <= 0 or (hpAtLock <= (dr.min + 8) and hpAtClose <= 0) then
                            if isLiveLock then lockoutCSMemo = true end
                            return true
                        end
                    end
                end
            end
        end
    end
    if isLiveLock then lockoutCSMemo = false end
    return false
end

-- Master Top-Priority 30.000 Hz Sacred CS & Spacing Entry Point
function L.RunSacredCS(bot, s, race, P, startRazeCb)
    L._imminentCS = false
    local enemyCreeps = s.enemyCreeps or {}
    local allyCreeps  = s.allyCreeps or {}
    local enemyHero   = s.enemy
    if #enemyCreeps == 0 and #allyCreeps == 0 then
        return false, false
    end

    U.BeginPredictionFrame()
    local allySideAtk, enemySideAtk, denyCreepsList, siegingEnemyT1 = GetSharedWaveSetup(bot, s, enemyCreeps, allyCreeps)
    local allowAllyDenies = #denyCreepsList > 0
    local candidates = L.ScanCreepCandidates(
        bot, enemyCreeps, denyCreepsList, allySideAtk, enemySideAtk, enemyHero, race
    )

    -- 1. First execute Dual-Value Hero+Creep Shadowraze (or 2+ simultaneous creep rescue) with S-cancel hook!
    if L.TryRazeSecureCS(bot, candidates, enemyHero, startRazeCb) then
        return true, true
    end

    L._imminentCS = false
    for _, cand in ipairs(candidates) do
        if not cand.isDeny and cand.kOpen ~= nil and cand.kOpen >= 0 and (cand.kTargetImpact - cand.totalT) <= 18 then
            L._imminentCS = true
            break
        end
    end

    -- 2. Select highest-priority right-click last-hit / deny within the sacred horizon
    local bestPlan = L.SelectBestRightClickPlan(bot, candidates, siegingEnemyT1)
    if bestPlan then
        local planDelta = bestPlan.kTargetImpact - bestPlan.totalT
        local recNow = U._unitTrack and U._unitTrack[bot]
        local midSwingOnPlan = recNow and recNow.wasAnim and bot:GetAttackTarget() == bestPlan.creep
        local spaSlackTicks = math.ceil(((bot.GetSecondsPerAttack and bot:GetSecondsPerAttack()) or 1.25) * 30.0) + 16
        -- `v7.9.24-pro` + `v7.9.28-pro` (`lasthit.lua:1917` undefined-globals dead-code fix!):
        -- Never let a distant slack `bestPlan` (`planDelta >= spaTicks + 16`) starve an urgent under-tower prep!
        if (not midSwingOnPlan) and planDelta >= spaSlackTicks and #(s.allyTowers or {}) > 0 then
            if L.TryUnderTowerPrep(bot, enemyCreeps, allyCreeps, allySideAtk, enemySideAtk, s.allyTowers, s.enemyTowers, candidates, enemyHero, race) then
                return true, true
            end
        elseif L._prepCreep ~= nil then
            L._prepCreep = nil
            L._prepExpire = 0
        end
        local planCommitCutoff = bestPlan.isDeny and 10 or 18
        local actedCS = L.ExecutePhaseLockedCS(bot, bestPlan, s, P)
        L._imminentCS = midSwingOnPlan or (actedCS and planDelta <= planCommitCutoff) or false
        if actedCS then
            return true, true
        end
        return false, true
    end

    -- Between killable CS windows on an active wave (`bestPlan == nil`): switch Power Treads to `AGI` (`+10` dmg, `+10` AS)
    -- immediately so every subsequent last-hit, deny, under-tower prep, and push hit lands with full Agility damage!
    if (not L._imminentCS) and (#(enemyCreeps or {}) > 0 or #(allyCreeps or {}) > 0)
        and U._State and U._State.trySafeTreadsCb then
        if U._State.trySafeTreadsCb(bot, "FIGHT", true) then
            return true, true
        end
    end

    -- 3. Low-HP Safe Lane Spacing (Strict One-Sided Minimum-Distance Floor -> ZERO Oscillation!):
    --   * FoW Low-HP / Active-Salve Guard (`v5.2.0`): when wounded (`<= 28% HP`) or actively healing with Salve while
    --     the live enemy SF is unseen in highground FoW, anchor behind `allyT1` instead of walking into river coils!
    --   * One-Sided Floor (`targetGap = 810..860 < war_director.RELEASE_DIST = 950`):
    --     - When `d < targetGap`: step back cleanly toward fixed `P.GetBehindT1` anchor!
    --     - When `d >= targetGap`: NEVER pull inward to `eLoc + dir * 900` (eliminates the `29.5 rev/min` oscillator!).
    local hp = bot:GetHealth()
    local hpPctNow = hp / math.max(1, bot:GetMaxHealth() or 600)
    if (not enemyHero or not U.CanQuery(enemyHero)) and s.enemyAlive ~= false
        and (#enemyCreeps > 0 or #allyCreeps > 0)
        and (bot:HasModifier("modifier_flask_healing") or (hpPctNow <= 0.28 and (s.enemyAbsentFor or 99) <= 8.0)) then
        -- `9069188041.dem` `03:44.1` Death #2 Fix: NEVER walk 620u backward SW toward `GetBehindT1(210)` when already deeper!
        local nearbyFogThreat = s.enemyLastLoc and ((s.enemyAbsentFor or 99) <= 3.5)
            and (U.DistanceBetweenLocations(bot:GetLocation(), s.enemyLastLoc) <= 980)
        local safeT1
        if P and P.GetRetreatAnchor then
            safeT1 = P.GetRetreatAnchor(bot, nearbyFogThreat and 480 or 210, nearbyFogThreat and 280 or 0)
        else
            safeT1 = (P and P.GetBehindT1 and P.GetBehindT1(bot, 210)) or P.GetFountain(bot)
        end
        if safeT1 and U.DistanceBetweenLocations(bot:GetLocation(), safeT1) > 35 then
            bot:Action_MoveToLocation(safeT1)
        elseif U.IsAttackingAction(bot) then
            bot:Action_ClearActions(true)
        end
        return true, false
    end
    local enemyManaAvail = (enemyHero and U.CanQuery(enemyHero))
        and ((enemyHero:GetMana() or 0) + U.GetMangoMana(enemyHero)) or 0
    local canFinishEnemy = enemyHero and U.CanQuery(enemyHero)
        and (U.SolveLethalRace(bot, enemyHero, s).winsFirstKill
            or U.CanQuickTurnKillWithRaze(bot, enemyHero)
            or U.CanOneShotEnemyHero(bot, enemyHero)
            or (enemyHero:GetHealth() <= U.GetNRazeDamage(bot, enemyHero, 1) + 75 and (bot:GetMana() or 0) >= 75)
            or (enemyManaAvail < 75 and (enemyHero:GetHealth() or 999) <= 145 and hp >= 140)
            or (race and race.valid and (race.canKillNow or (race.canKillSoon and not race.heCanKillNow))))
    local enAtkAdv = (enemyHero and U.CanQuery(enemyHero) and U._K and U._K.AttackDamageVs and U._K.AttackDamageVs(enemyHero, bot)) or 54
    local enManaRegenSoon = (enemyHero and U.CanQuery(enemyHero) and enemyHero.GetManaRegen and (enemyHero:GetManaRegen() or 1.0) * 2.5) or 2.5
    local myDomSoulAtk = enemyHero and U.CanQuery(enemyHero) and hp >= math.max(230, enAtkAdv * 4.0) and U._K and U._K.AttackDamageVs
        and U._K.AttackDamageVs(bot, enemyHero) >= U._K.AttackDamageVs(enemyHero, bot) + 10
        and hp >= (enemyHero:GetHealth() or 999) * 0.76
    -- `auto-20261031-0230` `02:08.1` Death #2 Fix:
    -- NEVER claim `weHoldDryAdvantage` at `180 HP` vs `334 HP / 68 MP` Lvl-3 SF (`3` right-clicks from death, or `2.5s` from `75 MP`!)!
    local weHoldDryAdvantage = (enemyManaAvail + enManaRegenSoon < 75)
        and (hp >= math.max(255, enAtkAdv * 4.2))
        and (myDomSoulAtk
            or canFinishEnemy
            or (hp >= math.max(260, (enemyHero and U.CanQuery(enemyHero) and enemyHero:GetHealth() or 999) * 0.82)
                and (bot:GetMana() or 0) >= 75))
    local pokedLow = enemyHero and U.CanQuery(enemyHero) and hp >= 155 and hp <= 345
        and not canFinishEnemy and not weHoldDryAdvantage
        and ((enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot)
            or (bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.8)))
    local myStacksNow, myStacksRemNow = U.GetShadowrazeDebuff(bot)
    local twoStackLethalWait = enemyHero and U.CanQuery(enemyHero) and not canFinishEnemy
        and (myStacksNow or 0) >= 2 and (myStacksRemNow or 0) > 0.35 and enemyManaAvail >= 75
        and hp <= ((race and race.valid and race.oneRaze) or 200) + 110
    local bLocWait = bot:GetLocation()
    local enRangeWait = (enemyHero and U.CanQuery(enemyHero) and enemyHero.GetAttackRange and enemyHero:GetAttackRange()) or 500
    local ownT1DryUmbrellaWait = (not twoStackLethalWait)
        and (enemyManaAvail < 75)
        and s.allyT1Alive ~= false and s.allyT1Loc
        and bLocWait and (U.DistanceBetweenLocations(bLocWait, s.allyT1Loc) <= 560)
        and enemyHero and U.CanQuery(enemyHero)
        and (U.DistanceBetweenLocations(bLocWait, enemyHero:GetLocation()) >= enRangeWait + 40)
        and (U.DistanceBetweenLocations(enemyHero:GetLocation(), s.allyT1Loc) >= 660)
    if enemyHero and U.CanQuery(enemyHero) and not canFinishEnemy and not weHoldDryAdvantage
        and not ownT1DryUmbrellaWait
        and not (not twoStackLethalWait and L.EnemyCannotPunishLane(bot, enemyHero, hp))
        and ((hp >= 165 and hp <= 295) or pokedLow or twoStackLethalWait) and (#enemyCreeps > 0 or #allyCreeps > 0) then
        local lethalRace = race and race.valid and (race.heCanKillSoon or race.losingHard)
        if not lethalRace or pokedLow or twoStackLethalWait then
            local eLoc = enemyHero:GetLocation()
            local bLoc = bot:GetLocation()
            local d = U.DistanceBetweenLocations(bLoc, eLoc)
            local KrefW = U._K
            local readyReachWait = (KrefW and KrefW.EnemyMinSafeDistance and KrefW.EnemyMinSafeDistance(enemyHero, 1.1)) or 955
            local targetGap = twoStackLethalWait and math.min(955, math.max(520, readyReachWait + 20)) or (pokedLow and 810 or 860)
            if d < targetGap then
                local behindT1 = (P and P.GetRetreatAnchor and P.GetRetreatAnchor(bot, 210, 0))
                    or (P and P.GetBehindT1 and P.GetBehindT1(bot, 210))
                    or P.GetFountain(bot)
                local safeAnchor
                if U.DistanceBetweenLocations(behindT1, eLoc) > d + 40 and U.DistanceBetweenLocations(bLoc, behindT1) > 35 then
                    safeAnchor = behindT1
                else
                    local away = (bLoc - eLoc)
                    if away:Length2D() < 1 then away = (P.GetFountain(bot) - bLoc) end
                    safeAnchor = bLoc + away:Normalized() * (targetGap - d + 85)
                end
                safeAnchor = U.SteerAroundObstacles(bot, safeAnchor, s)
                if U.DistanceBetweenLocations(bLoc, safeAnchor) > 32 then
                    bot:Action_MoveToLocation(safeAnchor)
                elseif U.IsAttackingAction(bot) then
                    bot:Action_ClearActions(true)
                end
                return true, false
            else
                -- `v7.9.12-pro` (`2319 @ 06:29.33..06:33.33` `(645,530) <-> (530,480)` Ping-Pong Fix!):
                -- Strictly ONE-SIDED minimum-distance floor! NEVER pull a low-HP / `2`-stack wounded SF inward to `1,040u`
                -- toward `enemyHero` when `d >= targetGap` (which immediately re-triggers `DisengageFromLethalTrade`!).
                if U.IsAttackingAction(bot) then
                    bot:Action_ClearActions(true)
                end
                return true, false
            end
        end
    end

    -- 4. No CS needed in next ~1.70s and safe from low-HP hero focus: solve exact algebraic Under-Tower HP Prep hits!
    if L.TryUnderTowerPrep(bot, enemyCreeps, allyCreeps, allySideAtk, enemySideAtk, s.allyTowers, s.enemyTowers, candidates, enemyHero, race) then
        return true, false
    end

    -- 4.25. Pro Dual-Value Ranged-Creep Prep (`1` auto -> `Shadowraze` kills ranged creep + hits rival SF!):
    -- When no CS is imminent, we have `>= 90` mana + ready `W`/`E`, and an unattacked enemy ranged creep stands near
    -- `enemyHero` (`<= 360u`) with `razeDmg < hp <= razeDmg + myAvgDmg + 12`, land ONE setup right-click from behind
    -- our wave so the very next tick/second `TryRazeSecureCS` scores a guaranteed +54g/+69XP + Hero Stack Dual Coil!
    if enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
        and (bot:GetMana() or 0) >= 90 and (bot:GetHealth() or 0) >= 340 then
        local nowPrep = GameTime()
        local mySpa = math.max(0.65, bot:GetSecondsPerAttack() or 1.55)
        if (nowPrep - (bot:GetLastAttackTime() or -100)) >= mySpa * 0.95 then
            local wAb = bot:GetAbilityByName("nevermore_shadowraze2")
            local eAb = bot:GetAbilityByName("nevermore_shadowraze3")
            local refAb = (wAb and wAb:IsFullyCastable() and wAb) or (eAb and eAb:IsFullyCastable() and eAb) or nil
            if refAb then
                local rRaw = U.GetRazeDamage(bot, refAb, 0)
                local eLoc = enemyHero:GetLocation()
                for _, ec in pairs(enemyCreeps) do
                    if U.CanQuery(ec) and ec:IsAlive() then
                        local nm = ec:GetUnitName() or ""
                        local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                        if string.find(nm, "ranged", 1, true) and dc <= (bot:GetAttackRange() or 525) + 25
                            and U.DistanceBetweenLocations(ec:GetLocation(), eLoc) <= 360 then
                            local rMagic = math.floor(ec:GetActualIncomingDamage(rRaw, DAMAGE_TYPE_MAGICAL))
                            local myAvg = U.SFDamageRange(bot, ec).avg
                            local cHp = ec:GetHealth() or 999
                            if cHp > rMagic + 8 and cHp <= rMagic + myAvg + 10 then
                                bot:Action_AttackUnit(ec, true)
                                return true, true
                            end
                        end
                    end
                end
            end
        end
    end

    -- 4.5. `v5.0.0` Source 2 Creep-Aggro Reset & Kite-Back During Idle Wait (respects `2.3s` chase lock & `515u` ranged reset!):
    do
        local chaseUntilIdle = (U._State and U._State.myCreepChaseUntil) or nil
        local creepsHittingMe, hasRangedAggro, closestAggroCreep = 0, false, nil
        if U.CountEnemyCreepsAggroedOnBot then
            creepsHittingMe, hasRangedAggro, closestAggroCreep = U.CountEnemyCreepsAggroedOnBot(bot, s, chaseUntilIdle)
        else
            local recentCreepHit = (bot.WasRecentlyDamagedByCreep and bot:WasRecentlyDamagedByCreep(0.95)) or false
            local minAggroDist = math.huge
            for _, ec in pairs(enemyCreeps) do
                if U.CanQuery(ec) and ec:IsAlive() then
                    local dc = GetUnitToLocationDistance(bot, ec:GetLocation())
                    if (ec.GetAttackTarget and ec:GetAttackTarget() == bot) or (recentCreepHit and dc <= 215) then
                        creepsHittingMe = creepsHittingMe + 1
                        if dc < minAggroDist then
                            minAggroDist, closestAggroCreep = dc, ec
                        end
                        if ((ec.GetAttackRange and ec:GetAttackRange()) or 100) > 300 and dc <= 505 then
                            hasRangedAggro = true
                        end
                    end
                end
            end
        end
        local allyShieldNear = 0
        for _, ac in pairs(allyCreeps) do
            if U.CanQuery(ac) and ac:IsAlive() and GetUnitToLocationDistance(bot, ac:GetLocation()) <= 360 then
                allyShieldNear = allyShieldNear + 1
            end
        end
        -- Do NOT kite away from a 1-shot / near-1-shot enemy creep (`hp <= myMin + 28` within `560u`) when `creepsHittingMe <= 1`
        -- and SF has `>= 45% HP` (`auto-20261107-2214` `tk=15754` `12 HP` creep abandoned behind Dire T1 Fix!)
        local hasImmediateOneShotCreep = false
        if creepsHittingMe <= 1 and (bot:GetHealth() or 0) >= (bot:GetMaxHealth() or 1) * 0.45 then
            for _, ec in pairs(enemyCreeps) do
                if U.CanQuery(ec) and ec:IsAlive() and GetUnitToLocationDistance(bot, ec:GetLocation()) <= 560 then
                    local myMinIdle = U.SFDamageRange(bot, ec).min
                    if (ec:GetHealth() or 9999) <= (myMinIdle + 28) then
                        hasImmediateOneShotCreep = true
                        break
                    end
                end
            end
        end
        -- `v7.9.27-pro` (`auto-20261108-2034` `02:23.70` `tk=7384..7394` Post-Release Chase Kite-Back Fix):
        -- NEVER let idle creep-aggro kiting (`creepsHittingMe <= 2`) walk a healthy SF (`>= 450 HP`, `>= 48%`) `110u`
        -- BACKWARD away from a critically low enemy hero (`enPostFlightEff <= 2.25x myAtk` within `680u`)!
        local pressingCritHeroIdle = false
        if creepsHittingMe <= 2 and (not hasRangedAggro)
            and enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
            and (bot:GetHealth() or 0) >= 450
            and (bot:GetHealth() or 0) >= (bot:GetMaxHealth() or 1) * 0.48
            and GetUnitToLocationDistance(bot, enemyHero:GetLocation()) <= 680 then
            local inFlightHeroIdle = (U.GetOwnInFlightDamageOnHero and U.GetOwnInFlightDamageOnHero(bot, enemyHero)) or 0
            local enEffIdle = math.max(1, (enemyHero:GetHealth() or 9999) - inFlightHeroIdle)
                + ((U.GetFaerieFireHeal and U.GetFaerieFireHeal(enemyHero)) or 0)
                + ((U.GetStickCharges and U.GetStickCharges(enemyHero)) or 0) * 15
            local myAtkIdle = (U._K and U._K.AttackDamageVs and U._K.AttackDamageVs(bot, enemyHero)) or (bot:GetAttackDamage() or 60)
            if enEffIdle <= math.max(125, myAtkIdle * 2.25) then
                pressingCritHeroIdle = true
            end
        end
        local lowOrMultiTank = (not hasImmediateOneShotCreep) and (not pressingCritHeroIdle) and ((creepsHittingMe >= 2)
            or (creepsHittingMe >= 1 and ((bot:GetHealth() or 999) < (bot:GetMaxHealth() or 999) * 0.85 or allyShieldNear == 0)))
        if lowOrMultiTank and closestAggroCreep then
            local nowT = GameTime()
            local chaseLocked = nowT < (((U._State and U._State.myCreepChaseUntil) or 0) - 0.08)
            local maxDeaggroReachIdle = (bot:GetAttackRange() or 525) + 35
            local bestAlly, bestAllyDist = nil, math.huge
            -- `v7.9.32-pro` (`auto-20261109-0306` `2:40` `#1102` `87 -> 9 HP` Non-Lethal Deny Lockout Fix!):
            -- Strictly prefer an allied creep ABOVE `50%` HP so `Action_AttackUnit(bestAlly, true)` drops creep aggro
            -- in `0.00s` WITHOUT starting a real attack animation or consuming SF's `1.40s` attack cooldown!
            for _, ac in pairs(allyCreeps) do
                if U.CanQuery(ac) and ac:IsAlive() and (ac:GetHealth() or 0) > (ac:GetMaxHealth() or 1) * 0.50 then
                    local da = GetUnitToLocationDistance(bot, ac:GetLocation())
                    local safeFromHero = true
                    if enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive() and creepsHittingMe >= 2 then
                        safeFromHero = U.DistanceBetweenLocations(bot:GetLocation(), enemyHero:GetLocation()) >= 585
                    end
                    if safeFromHero and da <= maxDeaggroReachIdle and da < bestAllyDist then
                        bestAllyDist, bestAlly = da, ac
                    end
                end
            end
            if L._lastDeaggroAt and nowT < L._lastDeaggroAt then
                L._lastDeaggroAt = -100
            end
            if not chaseLocked and not hasRangedAggro and bestAlly and nowT >= (L._lastDeaggroAt or -100) + 1.35 then
                L._lastDeaggroAt = nowT
                if U.ClearCreepAggroMemory then U.ClearCreepAggroMemory() end
                if U._State then U._State.creepKiteUntil = nil end
                bot:Action_AttackUnit(bestAlly, true)
                return true, true
            end
            if U._State and creepsHittingMe >= 2 then
                U._State.creepKiteUntil = math.max(U._State.creepKiteUntil or 0,
                    math.min(((U._State.myCreepChaseUntil or (nowT + 0.65)) + 0.12), nowT + 0.72))
            end
            local fnt = P.GetFountain(bot)
            local bLocNow = bot:GetLocation()
            local ownT1Loc = (s and s.allyT1Alive ~= false and s.allyT1Loc)
                or ((P and P.GetT1Tower and P.GetT1Tower(bot)) or nil)
            local lowestUnderT1, lowHpT1 = nil, math.huge
            local ownT1Reach = (C.BALLISTIC and C.BALLISTIC.TOWER_ATTACK_RANGE_C2C) or 870
            if ownT1Loc then
                for _, ec in pairs(enemyCreeps) do
                    if U.CanQuery(ec) and ec:IsAlive() and U.DistanceBetweenLocations(ec:GetLocation(), ownT1Loc) <= ownT1Reach then
                        local chp = ec:GetHealth() or 9999
                        if chp < lowHpT1 then
                            lowHpT1, lowestUnderT1 = chp, ec
                        end
                    end
                end
            end
            local rawGoal
            -- `v7.9.25-pro` (`auto-20261108-1609` `00:46..00:49`, `01:41`, `02:42`, `03:41` — 11 Lost Own-T1 CS Fix!):
            --   1. When enemy creeps are already inside our own T1's `760u` zone (`lowestUnderT1 ~= nil`), NEVER sprint
            --      `220..525u + 380u` behind T1 to `(972, 974)` `870u+` out of CS range! Hand off right at `ownT1Loc + 135u`
            --      clamped strictly within `<= 465u` of `lowestUnderT1` (pivoted behind T1 away from `enemyHero`)!
            --   2. When ONLY `1` melee creep hits a healthy (`>= 420 HP`, `>= 62%`) SF and an incoming allied creep is
            --      marching `360..980u` behind us, step a short `145u` toward that incoming wave instead of `355u` back!
            if lowestUnderT1 and ownT1Loc then
                local lowLocT1 = lowestUnderT1:GetLocation()
                local keepRangeT1 = math.max(405, (bot:GetAttackRange() or 500) - 35)
                rawGoal = ownT1Loc + (fnt - ownT1Loc):Normalized() * 145
                if enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive() then
                    local eLocNow = enemyHero:GetLocation()
                    if U.DistanceBetweenLocations(rawGoal, eLocNow) < 635 then
                        local awayEnT1 = (ownT1Loc - eLocNow)
                        if awayEnT1:Length2D() > 1 then
                            rawGoal = lowLocT1 + (((fnt - lowLocT1):Normalized() * 0.50) + (awayEnT1:Normalized() * 0.70)):Normalized() * keepRangeT1
                        end
                    end
                end
                if U.DistanceBetweenLocations(rawGoal, lowLocT1) > keepRangeT1 then
                    rawGoal = lowLocT1 + (rawGoal - lowLocT1):Normalized() * keepRangeT1
                end
            elseif creepsHittingMe == 1 and (not hasRangedAggro)
                and (bot:GetHealth() or 0) >= 420
                and (bot:GetHealth() or 0) >= (bot:GetMaxHealth() or 650) * 0.60 then
                local incomingAlly, minIncD = nil, 999
                for _, ac in pairs(allyCreeps) do
                    if U.CanQuery(ac) and ac:IsAlive() then
                        local dA = U.DistanceBetweenLocations(bLocNow, ac:GetLocation())
                        if dA > 320 and dA <= 980 and dA < minIncD
                            and U.DistanceBetweenLocations(ac:GetLocation(), fnt) < U.DistanceBetweenLocations(bLocNow, fnt) then
                            minIncD, incomingAlly = dA, ac
                        end
                    end
                end
                if incomingAlly then
                    rawGoal = bLocNow + (incomingAlly:GetLocation() - bLocNow):Normalized() * math.min(155, minIncD * 0.55)
                else
                    local refLoc = bestAlly and bestAlly:GetLocation() or closestAggroCreep:GetLocation()
                    rawGoal = refLoc + (fnt - refLoc):Normalized() * 245
                end
            elseif P.GetBehindT1 and (creepsHittingMe >= 2 or hasRangedAggro) then
                rawGoal = P.GetBehindT1(bot, 220)
            else
                local refLoc = bestAlly and bestAlly:GetLocation() or closestAggroCreep:GetLocation()
                local padBack = hasRangedAggro and 525 or (bestAlly and 265 or 355)
                rawGoal = refLoc + (fnt - refLoc):Normalized() * padBack
            end
            -- Ensure kite vector pulls outside rival SF's right-click range (`>= 645u`), WITHOUT breaking `lowestUnderT1` CS orbit!
            if (not lowestUnderT1) and enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive() then
                local eLocNow = enemyHero:GetLocation()
                if U.DistanceBetweenLocations(rawGoal, eLocNow) < 650 then
                    rawGoal = bLocNow + (fnt - bLocNow):Normalized() * 380
                end
            end
            local kiteAnchor = U.SteerAroundObstacles(bot, rawGoal, s)
            if lowestUnderT1 and kiteAnchor then
                local cLocKeep = lowestUnderT1:GetLocation()
                local keepR = math.max(390, (bot:GetAttackRange() or 500) - 35)
                if U.DistanceBetweenLocations(kiteAnchor, cLocKeep) > keepR then
                    kiteAnchor = cLocKeep + (kiteAnchor - cLocKeep):Normalized() * keepR
                end
            end
            if kiteAnchor and U.DistanceBetweenLocations(bLocNow, kiteAnchor) > 25 then
                bot:Action_MoveToLocation(kiteAnchor)
                return true, true
            end
        end
    end

    -- 4.75. Dominance & Post-Kill Equilibrium Freeze (`v7.5.0` + `v7.8.0` `ShaNachnetsya` `00:45–01:01` Fix):
    -- When dominating the lane (or when the enemy hero is DEAD and we are holding wave equilibrium instead of shoving!)
    -- with no enemy CS closing inside `mySpa + 0.55s`, chip any `< 50% HP` allied creep safely to pull equilibrium & build souls!
    local postKillFreeze = (s and s.enemyAlive == false)
        and not (U.CanCrashWaveBeforeEnemyReturn and U.CanCrashWaveBeforeEnemyReturn(bot, s))
    if allowAllyDenies and not siegingEnemyT1 and (postKillFreeze or (U.IsLaneDominant and U.IsLaneDominant(bot, s, race))) then
        local enemyFarEnough = postKillFreeze or (not enemyHero) or (not U.CanQuery(enemyHero))
            or (GetUnitToLocationDistance(bot, enemyHero:GetLocation()) > 830)
        if enemyFarEnough then
            local nowPD = GameTime()
            local mySpaPD = math.max(0.65, bot:GetSecondsPerAttack() or 1.35)
            local needClearTicks = math.ceil((mySpaPD + 0.55) * 30.0)
            local enemyCSOpeningSoon = false
            for _, cand in ipairs(candidates) do
                if not cand.isDeny and cand.kOpen ~= nil and cand.kOpen >= 0
                    and ((cand.effClose or 999) - 4) < needClearTicks then
                    enemyCSOpeningSoon = true
                    break
                end
            end
            if not enemyCSOpeningSoon and (nowPD - (bot:GetLastAttackTime() or -100)) >= mySpaPD * 0.95 then
                local enHeroRawDmg = postKillFreeze and 0
                    or ((enemyHero and U.CanQuery(enemyHero) and enemyHero:GetAttackDamage())
                        or (s and s.enemyLastAttackDmg) or 82)
                for _, ac in pairs(denyCreepsList) do
                    if U.CanQuery(ac) and ac:IsAlive() then
                        local hpA = ac:GetHealth() or 999
                        local maxHpA = math.max(1, ac:GetMaxHealth() or 550)
                        local da = GetUnitToLocationDistance(bot, ac:GetLocation())
                        if (hpA * 2 < maxHpA) and da <= (bot:GetAttackRange() or 525) + 15 then
                            local myDmgRange = U.SFDamageRange(bot, ac)
                            local enHeroDmg = postKillFreeze and 0 or ac:GetActualIncomingDamage(enHeroRawDmg + 6, DAMAGE_TYPE_PHYSICAL)
                            local incomingCreepDps = 0
                            for _, ec in pairs(enemyCreeps) do
                                if U.CanQuery(ec) and ec:IsAlive() and ec.GetAttackTarget and ec:GetAttackTarget() == ac then
                                    incomingCreepDps = incomingCreepDps + 22
                                end
                            end
                            local hpAfterReload = hpA - myDmgRange.max - incomingCreepDps * (mySpaPD + 0.25)
                            local minSafeFloor = postKillFreeze and math.max(24, myDmgRange.min * 0.55)
                                or math.max(enHeroDmg + 28, myDmgRange.min + 14)
                            if hpA > myDmgRange.min + 6 and hpAfterReload >= minSafeFloor then
                                bot:Action_AttackUnit(ac, true)
                                return true, true
                            end
                        end
                    end
                end
            end
        end
    end

    -- 5. Uncontested Wave Equilibrium Stance Discipline:
    -- When uncontested (enemy absent / dead / TPing), hold crisp 175u highground CS anchor
    -- across the entire wave so walkTicks == 0 and fTicks == 4 on 100% of creeps; when an
    -- enemy hero IS live in lane and no creep opens within 68 ticks, yield to combat/spacing!
    local siegingEnemyT1Now = s.enemyT1Alive and s.enemyT1Loc and #allyCreeps >= 1
        and GetUnitToLocationDistance(bot, s.enemyT1Loc) <= 1120
    local damagedAllyDenySoon = false
    if allowAllyDenies then
        for _, ac in pairs(allyCreeps) do
            if U.CanQuery(ac) and (ac:GetHealth() or 0) > 0 and ac:GetHealth() < ac:GetMaxHealth() * 0.58 then
                damagedAllyDenySoon = true
                break
            end
        end
    end
    -- Also step up toward `GetLasthitPosition` when `enemyHero` IS visible if SF was stranded `> 690u` from the active wave clash (`0:48..0:52` fix!)
    local minWaveCreepDist = 9999
    for _, ec in pairs(enemyCreeps) do
        if U.CanQuery(ec) and ec:IsAlive() then
            local dcw = GetUnitToLocationDistance(bot, ec:GetLocation())
            if dcw < minWaveCreepDist then minWaveCreepDist = dcw end
        end
    end
    local beingPokedWhileBehind = enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
        and ((bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemyHero, 1.85))
            or (enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot))
        and ((bot:GetHealth() or 999) < (enemyHero:GetHealth() or 0) - 35 or (bot:GetHealth() or 999) <= 360)
    local readyLowgroundPull = enemyHero and U.CanQuery(enemyHero) and enemyHero:IsAlive()
        and (not U._State or (GameTime() >= (U._State.myCreepAggroCdUntil or 0)
            and GameTime() >= (U._State.lastDefAggroPullAt or -100) + 3.15))
        and U.NeedsLowgroundEquilibriumPull and U.NeedsLowgroundEquilibriumPull(bot, s, race)
    local strandedFromClash = (minWaveCreepDist > 690 and minWaveCreepDist <= 1550)
        and (not beingPokedWhileBehind)
        and (not readyLowgroundPull)
        and not (U.IsDryVsArmedEnemySF and enemyHero and U.CanQuery(enemyHero) and U.IsDryVsArmedEnemySF(bot, enemyHero, s))
    if not siegingEnemyT1Now and ((not enemyHero or not U.CanQuery(enemyHero)) or strandedFromClash)
        and (#enemyCreeps >= 2 or damagedAllyDenySoon) and P and P.GetLasthitPosition then
        -- `v7.9.12-pro` (`2319` Fix): 4th argument of `P.GetLasthitPosition` is `prepareTarget` (creep), NEVER `enemyHero`!
        local anchor = P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, "NEUTRAL")
        if anchor then anchor = U.SteerAroundObstacles(bot, anchor, s) end
        if anchor and U.DistanceBetweenLocations(bot:GetLocation(), anchor) > 32 then
            bot:Action_MoveToLocation(anchor)
        elseif U.IsAttackingAction(bot) then
            bot:Action_ClearActions(true)
        end
        return true, true
    end

    -- Check whether any creep is below 72% HP so `HandlePriorityPush` does NOT blind-auto-attack mid-wave!
    local waveHasDamagedCreep = false
    for _, c in pairs(enemyCreeps) do
        if U.CanQuery(c) and c:GetHealth() < c:GetMaxHealth() * 0.72 then
            waveHasDamagedCreep = true
            break
        end
    end
    for _, c in pairs(allyCreeps) do
        if U.CanQuery(c) and c:GetHealth() < c:GetMaxHealth() * 0.65 then
            waveHasDamagedCreep = true
            break
        end
    end
    return false, waveHasDamagedCreep
end

return L
