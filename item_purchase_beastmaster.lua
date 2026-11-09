-- scripts/vscripts/bots/item_purchase_beastmaster.lua

-- Strict purchase queue: 6 rings of protection for armor
local PurchaseTable = {
    "item_ring_of_protection",
    "item_ring_of_protection",
    "item_ring_of_protection",
    "item_ring_of_protection",
    "item_ring_of_protection",
    "item_ring_of_protection"
}

local currentItemIndex = 1
local lastCourierCheckAt = -100

function ItemPurchaseThink()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then return end

    local gold = bot:GetGold()

    -- 1. BUY RINGS (verify shop success before advancing index!)
    if currentItemIndex <= #PurchaseTable then
        local nextItem = PurchaseTable[currentItemIndex]
        if gold >= GetItemCost(nextItem) then
            local result = bot:ActionImmediate_PurchaseItem(nextItem)
            if result == (PURCHASE_ITEM_SUCCESS or 0) then
                currentItemIndex = currentItemIndex + 1
            end
        end
    end

    -- 2. PERSONAL COURIER (`9080457787.dem` `invalid order (0). Unit is not controllable by the ordering player.` Fix):
    -- In Source 2 Dota 2 (`7.23+`), `GetCourier(0 .. numCouriers - 1)` is ordered by courier entity spawn index, NOT
    -- `GetTeamPlayers(GetTeam())` slot order! Always match `c:GetPlayerID() == myPlayerId` so Beastmaster bots NEVER
    -- issue `ActionImmediate_Courier` onto another player's personal courier.
    local now = (type(GameTime) == "function") and GameTime() or 0
    if now - lastCourierCheckAt < 0.50 then return end
    lastCourierCheckAt = now

    if (bot:GetStashValue() or 0) <= 0 then return end

    local numCouriers = (type(GetNumCouriers) == "function") and GetNumCouriers() or 0
    if numCouriers <= 0 then return end

    local myPlayerId = bot:GetPlayerID()
    if not myPlayerId or myPlayerId < 0 then return end

    local myCourier = nil
    for i = 0, numCouriers - 1 do
        local c = GetCourier(i)
        if c and not c:IsNull() and c.GetPlayerID and c:GetPlayerID() == myPlayerId then
            myCourier = c
            break
        end
    end

    if myCourier then
        local state = GetCourierState(myCourier)
        if state == COURIER_STATE_IDLE or state == COURIER_STATE_AT_BASE then
            bot:ActionImmediate_Courier(myCourier, COURIER_ACTION_TAKE_AND_TRANSFER_ITEMS)
        end
    end
end
