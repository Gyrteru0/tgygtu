-- Optional Server GameMode VScript Bridge for Dota 2 7.41f Bot Attribute Bonus (`special_bonus_attributes`)
-- =========================================================================================================
-- WHY THIS FILE EXISTS:
--   In Dota 2 7.41f (`9080457787.dem`), `special_bonus_attributes` (`m_vecAbilities.0015`) has `m_bHidden = true`.
--   Human Panorama UI upgrades it via protobuf `DOTA_CM_SpecialAbility = 358` (`CDOTAClientMsg_SpecialAbility`).
--   The restricted Bot Script VM (`bot_nevermore.lua`) only exposes `ActionImmediate_LevelAbility(name)`, which
--   dispatches `DOTA_UNIT_ORDER_TRAIN_ABILITY = 11` and is rejected by `server.dll` with error `60: Ability is hidden`.
--
--   * In normal lobbies (`sv_cheats 0`): `bot_nevermore.lua` checks `ab:IsHidden()`, producing ZERO console errors
--     and cleanly training core abilities (`L1-L8`) + visible Talents (`L10/15/20/25`, `m_bHidden = false`).
--   * In local `sv_cheats 1` lobbies: running `script_execute bots/attr_helper` once in console registers a 0.5s
--     thinker in the Server GameMode VScript VM (`HeroList` + `CDOTABaseAbility:SetLevel`) that spends stranded L9+
--     Ability Points on `special_bonus_attributes` (`+2 All Attributes` per rank, up to `7/7`) automatically!

if GameRules and GameRules.GetGameModeEntity and HeroList then
    local gm = GameRules:GetGameModeEntity()
    if gm and gm.SetContextThink then
        gm:SetContextThink("SFBotAttrBonusBridge", function()
            local heroes = HeroList:GetAllHeroes() or {}
            for _, h in pairs(heroes) do
                if h and not h:IsNull() and h:IsRealHero()
                    and h:GetUnitName() == "npc_dota_hero_nevermore"
                    and PlayerResource and PlayerResource:IsFakeClient(h:GetPlayerOwnerID()) then
                    local ap = h:GetAbilityPoints() or 0
                    local lvl = h:GetLevel() or 1
                    if lvl >= 9 and ap > 0 then
                        local q = h:FindAbilityByName("nevermore_shadowraze1")
                        local p = h:FindAbilityByName("nevermore_dark_lord")
                        local attr = h:FindAbilityByName("special_bonus_attributes")
                        local qMax = (not q) or (q:GetLevel() >= 4)
                        local pMax = (not p) or (p:GetLevel() >= 4)
                        if qMax and pMax and attr and attr:GetLevel() < 7 then
                            attr:SetLevel(attr:GetLevel() + 1)
                            h:SetAbilityPoints(ap - 1)
                            if h.CalculateStatBonus then
                                h:CalculateStatBonus(true)
                            end
                        end
                    end
                end
            end
            return 0.50
        end, 0.50)
        print("[SF-BOT] Server VScript Attribute Bonus bridge active (`special_bonus_attributes` L9+ enabled).")
    end
end
