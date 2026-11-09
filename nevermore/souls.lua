
local C = require("bots/nevermore/constants")

local S = {}

local soulsEpoch = -1
local soulsMemo = {}

function S.GetSouls(bot)
    if not bot then return 0 end
    local ep = _G.__SF_TICK_EPOCH
    if ep then
        if soulsEpoch ~= ep then
            soulsEpoch = ep
            for k in pairs(soulsMemo) do soulsMemo[k] = nil end
        else
            local cached = soulsMemo[bot]
            if cached ~= nil then return cached end
        end
    end
    local res = 0
    if bot.GetModifierByName and bot.HasModifier and bot:HasModifier("modifier_nevermore_necromastery") then
        local idx = bot:GetModifierByName("modifier_nevermore_necromastery")
        if idx and idx >= 0 then
            res = bot:GetModifierStackCount(idx) or 0
            if ep then soulsMemo[bot] = res end
            return res
        end
    end
    local numModifiers = bot:NumModifiers()
    if numModifiers and numModifiers > 0 then
        for i = 0, numModifiers - 1 do
            local modName = bot:GetModifierName(i)
            if modName == "modifier_nevermore_necromastery" then
                res = bot:GetModifierStackCount(i) or 0
                break
            end
        end
    end
    if ep then soulsMemo[bot] = res end
    return res
end

-- 7.41f: 1 damage per soul, +0.8 every 6 hero levels (an estimate; the real damage is GetAttackDamage()).
function S.GetDamagePerSoul(bot)
    local level = (bot and bot:GetLevel()) or 1
    -- KV: "hero_levelup +0.8, levelup_interval 6" -> the bonus at levels 6, 12, 18, 24
    local steps = math.floor(math.max(0, level) / 6)
    return (C.NECROMASTERY.BASE_DMG_PER_SOUL or 1.0)
        + (C.NECROMASTERY.DMG_PER_SOUL_PER_6_LEVELS or 0.8) * steps
end

function S.GetSoulDamageBonus(bot)
    return S.GetSouls(bot) * S.GetDamagePerSoul(bot)
end

return S
