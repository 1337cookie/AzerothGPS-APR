--[[
  AzerothGPS: APR Bridge (Core.lua)
  Connects Azeroth Pilot Reloaded (APR) waypoints into AzerothGPS navigation paths.
  Without modifying either addon.
]]

local addonName, ns = ...
_G.AzerothGPS_APR = ns

-- Default configuration
ns.DEFAULTS = {
    enabled = true,
    waypointMode = "chain",      -- "chain" (consecutive waypoints / upcoming steps), "single" (immediate 1 stop), "preview" (all travel preview points)
    markerStyle = "apr_numbered",-- "apr_numbered" (APR circle with step #), "apr_plain" (APR circle without #), "nostar" (raid icons skipping star), "default" (standard AGPS star)
    stepNumbering = "ordered",   -- "ordered" (sequential 1, 2, 3... from current stop), "apr" (guide step numbers 104, 105, 106...)
    pinColor = "theme",          -- "theme" (match APR theme), "blue", "green", "gold", "match_leg"
    routeColorMode = "uniform",  -- "uniform" (all legs same color), "multi" (each leg different color)
    fastestOrder = false,        -- false: guide author order (TSP optimization removed)
    maxStops = 4,                -- max stops ahead (1 to 8)
    includeQuests = true,        -- always true: include quest objectives/turnins/pickups as destinations
    showQuestName = true,        -- include actual quest name in step title
    showStepNumber = true,       -- "Show APR Step in Name": prefix APR guide step number in destination title (e.g. "104. Accept: A Threat Within")
    stepIconType = "marker",     -- "marker" (match Marker Style: numbered/colored circular pins or raid icons), "quest" (yellow ! and ?), "raid" (colored raid symbols)
    hideAPRArrow = false,        -- hide APR's default arrow while AGPS route is active
    autoClear = true,            -- clear route when APR has no active arrow/waypoint
    debug = false,               -- debug logging in chat
}

ns.DB = nil
ns.agps = nil
ns.started = false
ns.ownsRoute = false
ns.inCombat = false
ns.pendingSync = false
ns.syncTimer = nil
ns.lastStops = {}
ns.lastStepIndex = nil
ns.lastRouteKey = nil

local function Print(...)
    local text = "|cff33ccff[AGPS-APR]|r " .. strjoin(" ", tostringall(...))
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(text)
    end
end
ns.Print = Print

local function Debug(...)
    if ns.DB and ns.DB.debug then
        Print("|cffff9900[DEBUG]|r", ...)
    end
end
ns.Debug = Debug

-----------------------------------------------------------------------------------------
-- Coordinate Conversion Helpers
-----------------------------------------------------------------------------------------

--[[
  Converts an APR point/coordinate into AzerothGPS world yards (x = North, y = West, cont = continentID).
  In Blizzard/HereBeDragons (used by APR):
    Coord.x is West-East (corresponds to AGPS world Y)
    Coord.y is North-South (corresponds to AGPS world X)
  In AzerothGPS:
    worldX is North-South (UnitPosition 1st return value)
    worldY is West-East (UnitPosition 2nd return value)
    cont is continent / instance ID (UnitPosition 5th return value)
]]
local function ConvertToWorld(point, fallbackMapID)
    if not point then return nil end

    -- Direct AzerothGPS stop format: { x, y, cont }
    if type(point.x) == "number" and type(point.y) == "number" and type(point.cont) == "number" then
        return point.x, point.y, point.cont
    end

    local mapID = point.uiMapID or point.mapID or fallbackMapID

    -- Case 1: Normalized map coordinates (u, v in 0..1 or 0..100)
    if mapID and (point.u or point.mapX) and (point.v or point.mapY) then
        local u = point.u or point.mapX
        local v = point.v or point.mapY
        if u > 1 then u = u / 100 end
        if v > 1 then v = v / 100 end
        if _G.AzerothGPS and _G.AzerothGPS.MapToWorld then
            local wx, wy, cont = _G.AzerothGPS.MapToWorld(mapID, u, v)
            if wx and wy and cont then
                return wx, wy, cont
            end
        end
    end

    -- Case 2: LibAPRNavigation worldPosition table: { instanceID, x, y } (x = North, y = West)
    if point.worldPosition and type(point.worldPosition.x) == "number" and type(point.worldPosition.y) == "number" then
        local wp = point.worldPosition
        local cont = wp.instanceID
        if not cont and mapID and ns.agps and ns.agps.Geo then
            cont = ns.agps.Geo.MapCont(mapID)
        end
        if not cont and _G.AzerothGPS and _G.AzerothGPS.PlayerWorld then
            _, _, cont = _G.AzerothGPS.PlayerWorld()
        end
        if cont then
            return wp.x, wp.y, cont
        end
    end

    -- Case 3: APR Coord table: { x = East/West, y = North/South }
    local coord = point.Coord or point.coord or (type(point.x) == "number" and type(point.y) == "number" and point)
    if coord and type(coord.x) == "number" and type(coord.y) == "number" then
        -- In APR, coord.y is North-South (AGPS worldX), coord.x is East-West (AGPS worldY)
        local worldX = coord.y
        local worldY = coord.x
        local cont = point.instanceID or coord.instanceID

        if not cont and mapID and ns.agps and ns.agps.Geo then
            cont = ns.agps.Geo.MapCont(mapID)
        end
        if not cont and mapID and _G.APR and _G.APR.navigationPreview and _G.APR.navigationPreview.GetMapInstance then
            cont = _G.APR.navigationPreview:GetMapInstance(mapID)
        end
        if not cont and _G.AzerothGPS and _G.AzerothGPS.PlayerWorld then
            _, _, cont = _G.AzerothGPS.PlayerWorld()
        end

        if worldX and worldY and cont then
            return worldX, worldY, cont
        end
    end

    -- Case 4: Map projection using APR navigationPreview:ProjectPoint
    if _G.APR and _G.APR.navigationPreview and _G.APR.navigationPreview.ProjectPoint and mapID and coord then
        local u, v = _G.APR.navigationPreview:ProjectPoint(point, mapID)
        if u and v and _G.AzerothGPS and _G.AzerothGPS.MapToWorld then
            local wx, wy, cont = _G.AzerothGPS.MapToWorld(mapID, u, v)
            if wx and wy and cont then
                return wx, wy, cont
            end
        end
    end

    return nil
end
ns.ConvertToWorld = ConvertToWorld

local function ResolveQuestTitle(questID)
    if not questID or type(questID) ~= "number" or questID <= 0 then return nil end
    if _G.APR and _G.APR.GetQuestTitle then
        local ok, title = pcall(_G.APR.GetQuestTitle, _G.APR, questID)
        if ok and title and title ~= "" then return title end
    end
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local ok, title = pcall(C_QuestLog.GetTitleForQuestID, questID)
        if ok and title and title ~= "" then return title end
    end
    return nil
end
ns.ResolveQuestTitle = ResolveQuestTitle
-- Retrieves the display step number as shown on APR's Quest Order List.
local function GetQoLStepNumber(rawIndex, step)
    local APR = _G.APR
    if not APR or not rawIndex then return rawIndex end

    -- 1. Query APR's Quest Order List module directly if containers are rendered
    if APR.questOrderList and APR.questOrderList.rawStepContainers then
        local container = APR.questOrderList.rawStepContainers[rawIndex]
        if container and container.displayIndex then
            return container.displayIndex
        end
    end

    -- 2. Fallback calculation matching Quest Order List visibility logic
    local routeSteps = nil
    if APR.GetCurrentStep then
        local _, _, activeSteps = APR:GetCurrentStep()
        routeSteps = activeSteps
    end
    if not routeSteps and APR.ActiveRoute and APR.RouteQuestStepList then
        routeSteps = APR.RouteQuestStepList[APR.ActiveRoute]
    end
    if not routeSteps or type(routeSteps) ~= "table" then
        return rawIndex
    end

    local sojournerSkip = APR.IsSojournerSkipActive and APR:IsSojournerSkipActive()
    local displayIndex = 0
    for idx = 1, math.min(rawIndex, #routeSteps) do
        local s = routeSteps[idx]
        if s then
            local visible = true
            if APR.StepFilterQoL and not APR:StepFilterQoL(s) then
                visible = false
            elseif sojournerSkip and APR.IsStepCampaignQuest and APR:IsStepCampaignQuest(s) then
                visible = false
            end
            if visible then
                displayIndex = displayIndex + 1
            end
        end
    end

    return displayIndex > 0 and displayIndex or rawIndex
end
ns.GetQoLStepNumber = GetQoLStepNumber

-- Computes the display step number based on configured stepNumbering ("ordered" or "apr")
local function GetStopNumber(index, d, step)
    if ns.DB and ns.DB.stepNumbering == "apr" then
        local qol = (d and (d.qolIndex or d.stepNum))
            or (step and (step._qolNum or (step._index and GetQoLStepNumber(step._index, step))))
            or (d and tonumber(d.name and d.name:match("^(%d+)%.%s*")))
            or index
            or 1
        return qol
    end
    return index or 1
end
ns.GetStopNumber = GetStopNumber

-- Retrieves a human-readable title for an APR step or guidance point.
local function GetStepTitle(step, index, stopNum, qolNum)
    if not step then return "Waypoint" end

    local questID = nil
    if step.PickUp and step.PickUp[1] then
        questID = tonumber(step.PickUp[1])
    elseif step.Done and step.Done[1] then
        questID = tonumber(step.Done[1])
    elseif step.Qpart and type(step.Qpart) == "table" then
        for qid in pairs(step.Qpart) do
            if tonumber(qid) and tonumber(qid) > 0 then
                questID = tonumber(qid)
                break
            end
        end
    elseif step.DropQuest then
        questID = tonumber(step.DropQuest)
    elseif step.Waypoint and tonumber(step.Waypoint) and tonumber(step.Waypoint) > 100 then
        questID = tonumber(step.Waypoint)
    end

    local questTitle = ResolveQuestTitle(questID)
    local title = nil

    if questTitle and (ns.DB == nil or ns.DB.showQuestName ~= false) then
        if step.PickUp then
            title = "Accept: " .. questTitle
        elseif step.Done then
            title = "Turn in: " .. questTitle
        elseif step.Qpart then
            title = "Objective: " .. questTitle
        elseif step.Waypoint then
            title = "Waypoint: " .. questTitle
        else
            title = questTitle
        end
    end

    if not title then
        if step.label and step.label ~= "" then
            title = step.label
        elseif step.instruction and step.instruction ~= "" then
            title = step.instruction
        elseif step.title and step.title ~= "" then
            title = step.title
        elseif step.Waypoint and _G.APR and _G.APR.CheckWaypointText then
            local ok, wpText = pcall(_G.APR.CheckWaypointText, _G.APR)
            if ok and wpText and wpText ~= "" then title = wpText end
        end
    end

    if not title and _G.APR and _G.APR.GetStepString then
        local ok, text = pcall(_G.APR.GetStepString, _G.APR, step)
        if ok and text and text ~= "" then title = text end
    end

    if not title and step.ExtraLineText then
        title = tostring(step.ExtraLineText)
    end

    -- Resolves the guide's step number from APR
    local aprNum = qolNum
        or (step and (step._qolNum or (step._index and GetQoLStepNumber(step._index, step)) or step._index or step.rawIndex))
        or index
        or 1
    title = title or (step.Waypoint and ("Waypoint " .. tostring(step.Waypoint)) or ("Step " .. tostring(aprNum or 1)))

    if ns.DB and ns.DB.showStepNumber and aprNum then
        if not title:match("^%d+%.%s*") then
            title = tostring(aprNum) .. ". " .. title
        end
    elseif ns.DB and ns.DB.showStepNumber == false then
        title = title:gsub("^%d+%.%s*", "")
    end

    return title
end
ns.GetStepTitle = GetStepTitle

-----------------------------------------------------------------------------------------
-- Stop Construction & Marker Styling
-----------------------------------------------------------------------------------------

local APR_ICON_TEX = "Interface\\Addons\\APR\\APR-Core\\assets\\Icon.tga"
local QUEST_ACCEPT_ICON = "Interface\\GossipFrame\\AvailableQuestIcon"
local QUEST_TURNIN_ICON = "Interface\\GossipFrame\\ActiveQuestIcon"
local QUEST_INCOMPLETE_ICON = "Interface\\GossipFrame\\IncompleteQuestIcon"
local NO_STAR_RAID_ICONS = { 6, 2, 4, 3, 5 } -- Square, Circle, Triangle, Diamond, Moon (no star!)

local DETERMINISTIC_RAINBOW = {
    { 0.95, 0.22, 0.22 }, -- 1: Red
    { 1.00, 0.45, 0.10 }, -- 2: Coral / Red-Orange
    { 1.00, 0.65, 0.10 }, -- 3: Orange
    { 1.00, 0.85, 0.10 }, -- 4: Amber / Gold
    { 0.70, 0.90, 0.15 }, -- 5: Lime
    { 0.20, 0.85, 0.35 }, -- 6: Green
    { 0.10, 0.85, 0.70 }, -- 7: Teal / Cyan
    { 0.15, 0.65, 1.00 }, -- 8: Sky Blue
    { 0.30, 0.45, 1.00 }, -- 9: Royal Blue
    { 0.60, 0.35, 0.95 }, -- 10: Purple / Violet
    { 0.85, 0.30, 0.85 }, -- 11: Magenta
    { 1.00, 0.25, 0.60 }, -- 12: Rose / Pink
}
ns.DETERMINISTIC_RAINBOW = DETERMINISTIC_RAINBOW

local DYNAMIC_GRADIENT = {
    { 0.20, 0.85, 0.30 }, -- 1: Green (immediate destination)
    { 1.00, 0.85, 0.10 }, -- 2: Yellow (next target)
    { 1.00, 0.52, 0.10 }, -- 3: Orange (in distance)
    { 0.95, 0.22, 0.20 }, -- 4+: Red (furthest out)
}
ns.DYNAMIC_GRADIENT = DYNAMIC_GRADIENT

local function GetPinColor(index, d, step)
    index = tonumber(index) or 1
    local style = ns.DB and ns.DB.pinColor or "theme"

    -- Resolve stop and step if omitted
    if not d and ns.agps and ns.agps.Nav and ns.agps.Nav.stops then
        d = ns.agps.Nav.stops[index]
    end
    step = step or (d and d.step)

    -- Dynamic Scale: Green -> Yellow -> Orange -> Red
    if style == "gradient" then
        local idx = math.max(1, math.min(index, #DYNAMIC_GRADIENT))
        local c = DYNAMIC_GRADIENT[idx]
        return c[1], c[2], c[3], 1.0
    end

    -- Rainbow / Deterministic per absolute APR route step
    if style == "rainbow" or style == "match_leg" then
        local absoluteStep = (d and (d.qolIndex or d.stepIndex or d.stepNum))
            or (step and (step._qolNum or step._index or step.rawIndex))
            or (d and tonumber(d.name and d.name:match("^(%d+)%.")))
            or index
            or 1
        local colorIdx = ((math.floor(math.abs(tonumber(absoluteStep) or 1)) - 1) % #DETERMINISTIC_RAINBOW) + 1
        local c = DETERMINISTIC_RAINBOW[colorIdx]
        return c[1], c[2], c[3], 1.0
    end

    -- Match APR Theme
    if style == "theme" then
        local APR = _G.APR
        if APR and APR.settings and APR.settings.profile then
            local c = APR.settings.profile.mapshowNextStepsColor or APR.settings.profile.minimapshowNextStepsColor
            if c and type(c) == "table" then
                local r = c[1] or c.r
                local g = c[2] or c.g
                local b = c[3] or c.b
                if r and g and b then
                    return r, g, b, 1.0
                end
            end
        end
        if APR and APR.Color and APR.Color.lightGreen then
            local c = APR.Color.lightGreen
            return c[1], c[2], c[3], 1.0
        end
        return 0.25, 0.78, 0.35, 1.0
    end

    -- Static color presets
    if style == "blue" then
        return 0.18, 0.58, 0.95, 1.0
    elseif style == "green" then
        return 0.25, 0.78, 0.35, 1.0
    elseif style == "gold" then
        return 1.00, 0.82, 0.00, 1.0
    elseif style == "purple" then
        return 0.65, 0.35, 0.95, 1.0
    elseif style == "orange" then
        return 1.00, 0.55, 0.10, 1.0
    elseif style == "red" then
        return 0.92, 0.20, 0.20, 1.0
    elseif style == "cyan" then
        return 0.10, 0.82, 0.82, 1.0
    elseif style == "pink" then
        return 0.98, 0.35, 0.70, 1.0
    end

    return 0.18, 0.58, 0.95, 1.0
end
ns.GetPinColor = GetPinColor

local function GetMarkerLook(index, step, qolNum)
    local style = ns.DB and ns.DB.markerStyle or "apr_numbered"
    local iconType = ns.DB and ns.DB.stepIconType or "marker"
    local routeColorMode = ns.DB and ns.DB.routeColorMode or "uniform"

    -- Determine raid icon index for route coloring
    local iconId
    if routeColorMode == "uniform" then
        iconId = (style == "nostar" or style == "apr_numbered" or style == "apr_plain") and 6 or 1
    else
        if style == "nostar" then
            iconId = NO_STAR_RAID_ICONS[((index or 1) - 1) % #NO_STAR_RAID_ICONS + 1]
        else
            iconId = ((index or 1) - 1) % 8 + 1
        end
    end

    -- If iconType is "marker", adopt the Marker Style
    local resolvedIconType = iconType
    if iconType == "marker" then
        if style == "apr_numbered" or style == "apr_plain" then
            resolvedIconType = "pin"
        elseif style == "nostar" or style == "default" then
            resolvedIconType = "raid"
        end
    end

    -- Determine texture file path
    local tex = nil
    if resolvedIconType == "quest" and step then
        if step.PickUp or step.PickUpDB then
            tex = QUEST_ACCEPT_ICON
        elseif step.Done or step.DoneDB then
            tex = QUEST_TURNIN_ICON
        elseif step.Qpart or step.QpartDB or step.QpartPart then
            tex = QUEST_INCOMPLETE_ICON
        end
    elseif resolvedIconType == "pin" then
        tex = APR_ICON_TEX
    elseif resolvedIconType == "raid" then
        tex = nil
    end

    return iconId, tex
end
ns.GetMarkerLook = GetMarkerLook

-- Builds the rich inline texture tag for text strings (directions panel & arrow readout)
local function GetStopInlineTag(index, d, size)
    size = size or 14
    local style = ns.DB and ns.DB.markerStyle or "apr_numbered"
    local iconType = ns.DB and ns.DB.stepIconType or "marker"
    local step = d and (d.step or (d.source == "APR_SINGLE" and _G.APR and _G.APR.GetCurrentStep and select(1, _G.APR:GetCurrentStep())))

    local resolvedIconType = iconType
    if iconType == "marker" then
        if style == "apr_numbered" or style == "apr_plain" then
            resolvedIconType = "pin"
        elseif style == "nostar" or style == "default" then
            resolvedIconType = "raid"
        end
    end

    if resolvedIconType == "quest" then
        local questTex = QUEST_ACCEPT_ICON
        if step then
            if step.PickUp or step.PickUpDB then
                questTex = QUEST_ACCEPT_ICON
            elseif step.Done or step.DoneDB then
                questTex = QUEST_TURNIN_ICON
            elseif step.Qpart or step.QpartDB or step.QpartPart then
                questTex = QUEST_INCOMPLETE_ICON
            end
        elseif d and d.tex and (d.tex:find("QuestIcon") or d.tex:find("GossipFrame")) then
            questTex = d.tex
        end
        return string.format("|T%s:%d:%d:0:0|t", questTex, size, size)
    elseif resolvedIconType == "raid" then
        local iconId
        if style == "nostar" then
            iconId = (d and d.icon) or NO_STAR_RAID_ICONS[((index or 1) - 1) % #NO_STAR_RAID_ICONS + 1]
        else
            iconId = (d and d.icon) or (((index or 1) - 1) % 8 + 1)
        end
        return string.format("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%d:%d:%d:0:0|t", iconId, size, size)
    elseif resolvedIconType == "pin" then
        local r, g, b = GetPinColor(index, d, step)
        local R, G, B = math.floor(r * 255), math.floor(g * 255), math.floor(b * 255)
        if style == "apr_numbered" then
            local num = GetStopNumber(index, d, step)
            if num and num >= 1 and num <= 25 then
                local col = (num - 1) % 8
                local row = math.floor((num - 1) / 8)
                local left = col * 32
                local right = left + 32
                local top = row * 32
                local bottom = top + 32
                return string.format("|TInterface\\WorldMap\\UI-QuestPoi-NumberIcons:%d:%d:0:0:256:256:%d:%d:%d:%d:%d:%d:%d|t",
                    size + 2, size + 2, left, right, top, bottom, R, G, B)
            else
                return string.format("|TInterface\\Addons\\APR\\APR-Core\\assets\\Icon.tga:%d:%d:0:0:64:64:0:64:0:64:%d:%d:%d|t",
                    size, size, R, G, B)
            end
        else
            return string.format("|TInterface\\Addons\\APR\\APR-Core\\assets\\Icon.tga:%d:%d:0:0:64:64:0:64:0:64:%d:%d:%d|t",
                size, size, R, G, B)
        end
    end

    local iconId = (d and d.icon) or (((index or 1) - 1) % 8 + 1)
    return string.format("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%d:%d:%d:0:0|t", iconId, size, size)
end
ns.GetStopInlineTag = GetStopInlineTag

-- Extracts the candidate waypoints/stops from APR based on configured mode.
local function CollectStops()
    local APR = _G.APR
    if not APR or not APR.settings or not APR.settings.profile then
        return {}
    end
    if not APR.settings.profile.enableAddon or not APR.ActiveRoute then
        return {}
    end

    -- Check player status
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then
        return {}
    end

    local mode = ns.DB.waypointMode or "chain"
    local maxStops = math.max(1, math.min(8, ns.DB.maxStops or 4))
    local stops = {}

    -- Handle LibAPRNavigation travel guidance if active
    local navigation = APR.navigation
    local isGuiding = navigation and navigation.IsNavigating and navigation:IsNavigating()

    if isGuiding and (mode == "preview" or mode == "chain") then
        local preview = APR.navigationPreview
        local points = preview and preview.GetPoints and preview:GetPoints()
        if points and #points > 0 then
            local pX, pY, playerCont = nil, nil, nil
            if _G.AzerothGPS and _G.AzerothGPS.PlayerWorld then
                pX, pY, playerCont = _G.AzerothGPS.PlayerWorld()
            end

            for i, pt in ipairs(points) do
                if #stops >= maxStops then break end
                local wx, wy, cont = ConvertToWorld(pt)
                if wx and wy and cont then
                    -- Discontinuity check: break if crossing continent boundaries
                    if #stops > 0 and stops[#stops].cont ~= cont then
                        break
                    end
                    -- Only include stops on the player's current continent
                    if not playerCont or cont == playerCont then
                        local qolIndex = (pt.step and (pt.step._index or pt.step.rawIndex) and GetQoLStepNumber(pt.step._index or pt.step.rawIndex, pt.step)) or (#stops + 1)
                        local stopIdx = #stops + 1
                        local stopNum = GetStopNumber(stopIdx, nil, pt.step)
                        local title = pt.label or pt.instruction or pt.title or ("Guidance " .. stopNum)
                        local mIcon, mTex = GetMarkerLook(stopIdx, pt.step, qolIndex)
                        stops[#stops + 1] = {
                            x = wx,
                            y = wy,
                            cont = cont,
                            name = title,
                            icon = mIcon or stopIdx,
                            tex = mTex,
                            step = pt.step,
                            stepNum = qolIndex,
                            qolIndex = qolIndex,
                            stepIndex = pt.step and (pt.step._index or pt.step.rawIndex),
                            source = "APR_NAV",
                        }
                    end
                end
            end
            if #stops > 0 then
                return stops
            end
        end
    end

    -- Authored Route Steps
    local questStep, currentStepIndex, routeSteps = nil, nil, nil
    if APR.GetCurrentStep then
        questStep, currentStepIndex, routeSteps = APR:GetCurrentStep()
    end

    if not questStep and not isGuiding then
        return {}
    end

    -- Mode 1: "single" (Active immediate destination)
    if mode == "single" then
        local arrow = APR.Arrow
        local targetX, targetY, targetCont = nil, nil, nil
        local qolIndex = GetQoLStepNumber(currentStepIndex, questStep)
        local stopNum = GetStopNumber(1, nil, questStep)
        local title = GetStepTitle(questStep, 1, stopNum, qolIndex)
        if arrow and arrow.Active and (arrow.x ~= 0 or arrow.y ~= 0) then
            -- Arrow coordinates: arrow.y is North-South (AGPS worldX), arrow.x is West-East (AGPS worldY)
            targetX = arrow.y
            targetY = arrow.x
            if _G.AzerothGPS and _G.AzerothGPS.PlayerWorld then
                _, _, targetCont = _G.AzerothGPS.PlayerWorld()
            end
        elseif questStep then
            local _, routeMap = APR.GetCurrentRouteMapIDsAndName and APR:GetCurrentRouteMapIDsAndName() or nil
            local hint = APR.GetPlayerParentMapID and APR:GetPlayerParentMapID() or nil
            local coord, zone = APR:GetStepCoord(questStep, routeMap, hint)
            if coord then
                targetX, targetY, targetCont = ConvertToWorld({ Coord = coord, uiMapID = zone or questStep.Zone or routeMap, instanceID = questStep.instanceID })
            end
        end

        if targetX and targetY and targetCont then
            local mIcon, mTex = GetMarkerLook(1, questStep, qolIndex)
            stops[1] = {
                x = targetX,
                y = targetY,
                cont = targetCont,
                name = title,
                icon = mIcon or 1,
                tex = mTex,
                step = questStep,
                stepNum = qolIndex,
                qolIndex = qolIndex,
                stepIndex = currentStepIndex,
                source = "APR_SINGLE",
            }
        end
        return stops
    end

    -- Mode 2: "chain" (Consecutive waypoints chain up to next quest objective)
    if mode == "chain" and routeSteps and currentStepIndex then
        local _, routeMap = APR.GetCurrentRouteMapIDsAndName and APR:GetCurrentRouteMapIDsAndName() or nil
        local hint = APR.GetPlayerParentMapID and APR:GetPlayerParentMapID() or nil
        local cursor = currentStepIndex
        local playerCont = nil
        if _G.AzerothGPS and _G.AzerothGPS.PlayerWorld then
            _, _, playerCont = _G.AzerothGPS.PlayerWorld()
        end

        while cursor <= #routeSteps and #stops < maxStops do
            local step = (cursor == currentStepIndex) and questStep or routeSteps[cursor]
            if not step then break end

            local visible = not APR.StepFilterQoL or APR:StepFilterQoL(step)
            if visible then
                -- Skip steps that shouldn't show arrow if looking ahead
                if not (step.NoArrow and cursor > currentStepIndex) then
                    local allowed = true -- Include quest objectives is always on

                    if allowed then
                        local coord, zone = APR:GetStepCoord(step, routeMap, hint)
                        if coord then
                            local wx, wy, cont = ConvertToWorld({
                                Coord = coord,
                                uiMapID = coord.mapID or zone or step.Zone or routeMap,
                                instanceID = coord.instanceID or step.instanceID,
                            }, routeMap)

                            if wx and wy and cont then
                                -- Discontinuity / continent check
                                if #stops > 0 and stops[#stops].cont ~= cont then
                                    break
                                end
                                if playerCont and cont ~= playerCont then
                                    break
                                end

                                local qolIndex = GetQoLStepNumber(step._index or cursor, step)
                                local stopIdx = #stops + 1
                                local stopNum = GetStopNumber(stopIdx, nil, step)

                                -- Deduplicate coincident stops (within 5 yards, e.g. same NPC)
                                local isCoincident = false
                                if #stops > 0 then
                                    local prev = stops[#stops]
                                    if math.abs(prev.x - wx) < 5.0 and math.abs(prev.y - wy) < 5.0 then
                                        isCoincident = true
                                        local title = GetStepTitle(step, #stops, stopNum, qolIndex)
                                        if not prev.name:find(title, 1, true) then
                                            prev.name = prev.name .. " / " .. title
                                        end
                                    end
                                end

                                if not isCoincident then
                                    local title = GetStepTitle(step, stopIdx, stopNum, qolIndex)
                                    local mIcon, mTex = GetMarkerLook(stopIdx, step, qolIndex)
                                    stops[#stops + 1] = {
                                        x = wx,
                                        y = wy,
                                        cont = cont,
                                        name = title,
                                        icon = mIcon or stopIdx,
                                        tex = mTex,
                                        step = step,
                                        stepNum = qolIndex,
                                        qolIndex = qolIndex,
                                        stepIndex = cursor,
                                        source = "APR_CHAIN",
                                        isWaypoint = (step.Waypoint ~= nil),
                                    }
                                end
                            end
                        end
                    end
                end
            end
            cursor = cursor + 1
        end

        return stops
    end

    -- Mode 3: "preview" (Full navigation preview points)
    if mode == "preview" and APR.navigationPreview and APR.navigationPreview.GetPoints then
        local points = APR.navigationPreview:GetPoints()
        local playerCont = nil
        if _G.AzerothGPS and _G.AzerothGPS.PlayerWorld then
            _, _, playerCont = _G.AzerothGPS.PlayerWorld()
        end

        for i, pt in ipairs(points or {}) do
            if #stops >= maxStops then break end
            local wx, wy, cont = ConvertToWorld(pt)
            if wx and wy and cont then
                if #stops > 0 and stops[#stops].cont ~= cont then
                    break
                end
                if not playerCont or cont == playerCont then
                    local qolIndex = (pt.step and (pt.step._index or pt.step.rawIndex) and GetQoLStepNumber(pt.step._index or pt.step.rawIndex, pt.step)) or (#stops + 1)
                    local stopIdx = #stops + 1
                    local stopNum = GetStopNumber(stopIdx, nil, pt.step)
                    local title = pt.label or pt.instruction or pt.title or ("Stop " .. stopNum)
                    local mIcon, mTex = GetMarkerLook(stopIdx, pt.step, qolIndex)
                    stops[#stops + 1] = {
                        x = wx,
                        y = wy,
                        cont = cont,
                        name = title,
                        icon = mIcon or stopIdx,
                        tex = mTex,
                        step = pt.step,
                        stepNum = qolIndex,
                        qolIndex = qolIndex,
                        stepIndex = pt.step and (pt.step._index or pt.step.rawIndex),
                        source = "APR_PREVIEW",
                    }
                end
            end
        end
        return stops
    end

    return stops
end
ns.CollectStops = CollectStops

-----------------------------------------------------------------------------------------
-- Synchronization Engine
-----------------------------------------------------------------------------------------

local function SameStop(a, b)
    if not a or not b then return false end
    if a.cont ~= b.cont then return false end
    if a.name ~= b.name then return false end
    if a.qolIndex ~= b.qolIndex then return false end
    if a.tex ~= b.tex then return false end
    if a.icon ~= b.icon then return false end
    return math.abs(a.x - b.x) < 1.0 and math.abs(a.y - b.y) < 1.0
end

local function StopsEqual(listA, listB)
    if #listA ~= #listB then return false end
    for i = 1, #listA do
        if not SameStop(listA[i], listB[i]) then
            return false
        end
    end
    return true
end

function ns:UpdateArrowVisibility()
    local APR = _G.APR
    if not APR or not APR.ArrowFrame then return end
    if self.ownsRoute and self.DB.hideAPRArrow then
        if APR.ArrowFrame:IsShown() then
            APR.ArrowFrame:Hide()
        end
    end
end

function ns:UpdateStopPinBadges()
    local canvas = _G.AzerothGPS and _G.AzerothGPS.MapCanvas and _G.AzerothGPS.MapCanvas()
    if not canvas or not canvas.GetChildren then return end

    local style = self.DB and self.DB.markerStyle or "apr_numbered"
    local iconType = self.DB and self.DB.stepIconType or "marker"
    local showNumbers = (style == "apr_numbered")
    local isAprStyle = (style == "apr_numbered" or style == "apr_plain")
    local stops = self.agps and self.agps.Nav and self.agps.Nav.stops

    for _, layer in ipairs({ canvas:GetChildren() }) do
        if layer and layer.GetChildren then
            for _, btn in ipairs({ layer:GetChildren() }) do
                if btn and btn.stopIndex and btn.icon then
                    local d = stops and stops[btn.stopIndex]
                    local num = GetStopNumber(btn.stopIndex, d, d and d.step)
                    local r, g, b = GetPinColor(btn.stopIndex, d, d and d.step)
                    -- Elevate frame level and strata above route lineLayer (sooner stops on top)
                    btn:SetFrameStrata("HIGH")
                    btn:SetFrameLevel(math.max(50, 150 - math.min(50, btn.stopIndex or 1)))

                    if not btn.aprBadge then
                        btn.aprBadge = btn:CreateFontString(nil, "OVERLAY")
                        btn.aprBadge:SetPoint("CENTER", btn, "CENTER", 0, 0)
                    end
                    btn.aprBadge:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")

                    if self.ownsRoute and btn:IsShown() then
                        if isAprStyle then
                            -- Tint the white Icon.tga circle with APR theme or chosen color
                            btn.icon:SetTexture(APR_ICON_TEX)
                            btn.icon:SetVertexColor(r, g, b, 1.0)
                            btn:SetSize(22, 22)

                            if showNumbers then
                                btn.aprBadge:SetTextColor(1, 1, 1, 1)
                                btn.aprBadge:SetText(tostring(num))
                                btn.aprBadge:Show()
                            else
                                btn.aprBadge:Hide()
                            end
                        else
                            local iconId
                            if style == "nostar" then
                                iconId = (d and d.icon) or NO_STAR_RAID_ICONS[((btn.stopIndex or 1) - 1) % #NO_STAR_RAID_ICONS + 1]
                            else
                                iconId = (d and d.icon) or (((btn.stopIndex or 1) - 1) % 8 + 1)
                            end
                            btn.icon:SetTexture(string.format("Interface\\TargetingFrame\\UI-RaidTargetingIcon_%d", iconId))
                            btn.icon:SetVertexColor(1, 1, 1, 1)
                            btn:SetSize(18, 18)
                            btn.aprBadge:Hide()
                        end
                    else
                        btn.aprBadge:Hide()
                    end
                end
            end
        end
    end
end

ns.minimapPins = ns.minimapPins or {}

local function HideAllMinimapPins()
    for _, pin in ipairs(ns.minimapPins) do
        pin:Hide()
    end
end

function ns:GetMinimapPin(i, parent)
    local pin = self.minimapPins[i]
    if not pin and CreateFrame then
        pin = CreateFrame("Button", "AzerothGPS_APR_MinimapPin" .. i, parent)
        pin:SetSize(18, 18)
        pin:SetFrameStrata("HIGH")
        pin:SetFrameLevel(math.max(10, 200 - i)) -- Sooner waypoints layered higher than later ones
        pin.icon = pin:CreateTexture(nil, "BACKGROUND")
        pin.icon:SetAllPoints(pin)
        pin.icon:SetTexture(APR_ICON_TEX)

        pin.text = pin:CreateFontString(nil, "OVERLAY")
        pin.text:SetPoint("CENTER", pin, "CENTER", 0, 0)
        pin.text:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        pin.text:SetTextColor(1, 1, 1, 1)

        self.minimapPins[i] = pin
        if i == 1 then
            self.minimapPin = pin
        end
    end
    return pin
end

function ns:UpdateMinimapPins()
    local agps = self.agps
    local mm = agps and agps.GPS and (agps.GPS.minimapRoute or agps.GPS.mm)
    local f = (mm and mm.frame) or Minimap
    local stops = agps and agps.Nav and agps.Nav.stops

    if not self.ownsRoute or not self.DB or not self.DB.enabled or not stops or #stops == 0 or not f or not Minimap or (Minimap.IsShown and not Minimap:IsShown()) then
        HideAllMinimapPins()
        if mm and mm.stop then
            mm.stop:SetAlpha(1)
        end
        return
    end

    local Geo = agps.Geo
    if not Geo or not Geo.PlayerWorld then return end
    local px, py, cont = Geo.PlayerWorld()
    if not px or not cont then return end

    local width = (Minimap.GetWidth and Minimap:GetWidth()) or 140
    local yards = (agps.Layers and agps.Layers.MinimapYards and agps.Layers.MinimapYards()) or 400
    local facing = (GetCVar and GetCVar("rotateMinimap") == "1") and (Geo.Facing and Geo.Facing() or 0) or 0
    local rad = width / 2 - 1
    local square = GetMinimapShape and GetMinimapShape() == "SQUARE"
    local edge = rad - 6

    local style = self.DB.markerStyle or "apr_numbered"
    local iconType = self.DB.stepIconType or "marker"
    local isAprStyle = (style == "apr_numbered" or style == "apr_plain")
    local showNumbers = (style == "apr_numbered")

    -- Hide native single stop texture mm.stop to avoid uncolored white circle
    if mm and mm.stop then
        mm.stop:SetAlpha(0)
        mm.stop:Hide()
    end

    -- Match minimap route line color with main map route color
    local r1, g1, b1 = GetPinColor(1, stops and stops[1])
    if agps.GPS then
        agps.GPS.MINIMAP_ROUTE_COLOR = { r1, g1, b1 }
    end

    -- Hook mm.frame OnUpdate to keep all pins updated as player moves
    if not ns.minimapWatcher and CreateFrame then
        local w = CreateFrame("Frame", "AzerothGPS_APR_MinimapWatcher", Minimap or UIParent)
        w:SetScript("OnUpdate", function()
            if ns.ownsRoute and ns.DB and ns.DB.enabled then
                ns:UpdateMinimapPins()
            end
        end)
        ns.minimapWatcher = w
    end

    for i, d in ipairs(stops) do
        local pin = self:GetMinimapPin(i, f)
        if pin then
            local x, y = d.x, d.y
            if Geo.ToContinent then
                x, y = Geo.ToContinent(d.cont, d.x, d.y, cont)
            elseif d.cont and cont and d.cont ~= cont then
                x, y = nil, nil
            end
            if x and agps.GPS and agps.GPS.MinimapPoint then
                local sx, sy = agps.GPS.MinimapPoint(px, py, x, y, yards, width, facing)
                local dist = math.sqrt(sx * sx + sy * sy)
                if square then dist = math.max(math.abs(sx), math.abs(sy)) end

                if dist > edge then
                    sx, sy = sx * edge / dist, sy * edge / dist
                end
                local shouldShow = true
                if shouldShow then
                    pin:SetFrameLevel(math.max(10, 200 - i))
                    pin:ClearAllPoints()
                    pin:SetPoint("CENTER", f, "CENTER", sx, sy)
                    local num = GetStopNumber(i, d, d.step)

                    if isAprStyle then
                        local r, g, b = GetPinColor(i, d, d.step)
                        pin.icon:SetTexture(APR_ICON_TEX)
                        pin.icon:SetVertexColor(r, g, b, 1.0)
                        pin.icon:SetSize(18, 18)
                        pin:SetSize(18, 18)
                        if showNumbers then
                            pin.text:SetText(tostring(num))
                            pin.text:Show()
                        else
                            pin.text:Hide()
                        end
                    else
                        pin.icon:SetSize(16, 16)
                        pin:SetSize(16, 16)
                        local iconId
                        if style == "nostar" then
                            iconId = (d and d.icon) or NO_STAR_RAID_ICONS[((i - 1) % #NO_STAR_RAID_ICONS) + 1]
                        else
                            iconId = (d and d.icon) or (((i - 1) % 8) + 1)
                        end
                        pin.icon:SetTexture(string.format("Interface\\TargetingFrame\\UI-RaidTargetingIcon_%d", iconId))
                        pin.icon:SetVertexColor(1, 1, 1, 1)
                        pin.text:Hide()
                    end
                    pin:Show()
                else
                    pin:Hide()
                end
            else
                pin:Hide()
            end
        end
    end

    for i = #stops + 1, #self.minimapPins do
        self.minimapPins[i]:Hide()
    end
end
ns.UpdateMinimapPin = ns.UpdateMinimapPins

function ns:UpdateDirectionsPanelBadges()
    -- No-op: numbered colored circles are rendered directly via UI-QuestPoi-NumberIcons in d.tex
end
function ns:SyncRoute(force)
    self.syncTimer = nil

    if not self.DB or not self.DB.enabled then
        if self.ownsRoute and self.agps and self.agps.Nav then
            self.agps.Nav.Clear()
            self.ownsRoute = false
            self.lastStops = {}
        end
        return
    end

    if self.inCombat then
        self.pendingSync = true
        return
    end

    if not self.agps or not self.agps.Nav then
        return
    end

    local newStops = CollectStops()

    -- Check if stops are identical to the last applied stops
    if not force and StopsEqual(newStops, self.lastStops) then
        self:UpdateArrowVisibility()
        return
    end

    -- If no stops collected:
    if #newStops == 0 then
        if self.ownsRoute and self.DB.autoClear then
            Debug("Clearing AGPS route (no active APR waypoints)")
            self.agps.Nav.Clear()
            self.ownsRoute = false
            self.lastStops = {}
        end
        return
    end

    -- Apply new stops to AzerothGPS
    Debug("Setting", #newStops, "stops from APR into AzerothGPS:")
    for i, s in ipairs(newStops) do
        Debug("  ", i, s.name, string.format("(%.1f, %.1f cont=%d)", s.x, s.y, s.cont))
    end
    -- Sync Route Look & Minimap line color
    local r, g, b = GetPinColor(1, newStops and newStops[1])
    if _G.AzerothGPS and _G.AzerothGPS.SetRouteLook then
        _G.AzerothGPS.SetRouteLook("AzerothGPS_APR", { color = { r, g, b } })
        if self.agps and self.agps.GPS then
            self.agps.GPS.MINIMAP_ROUTE_COLOR = { r, g, b }
        end
    end

    -- SetStops(stops, fastest, force)
    -- fastest = false preserves the exact author order of waypoints!
    -- force = true overrides dungeon lock
    local success = self.agps.Nav.SetStops(newStops, false, true)
    if success then
        self.ownsRoute = true
        self.lastStops = newStops
        -- Preserve custom APR stop metadata across AGPS Nav.Copy
        if self.agps.Nav.stops then
            for i, stop in ipairs(self.agps.Nav.stops) do
                local src = newStops[i]
                if src then
                    stop.step = src.step
                    stop.stepNum = src.stepNum
                    stop.qolIndex = src.qolIndex
                    stop.stepIndex = src.stepIndex
                    stop.isWaypoint = src.isWaypoint
                end
            end
        end
        self:UpdateArrowVisibility()

        -- Trigger AGPS map redraw and badge update
        if _G.AzerothGPS and _G.AzerothGPS.Redraw then
            _G.AzerothGPS.Redraw()
        end
        self:UpdateStopPinBadges()
        self:UpdateMinimapPin()
        self:UpdateDirectionsPanelBadges()
    else
        Debug("agps.Nav.SetStops returned false")
    end
end

function ns:RequestSync(force)
    if not self.DB or not self.DB.enabled then return end

    if force then
        if self.syncTimer then
            self.syncTimer:Cancel()
            self.syncTimer = nil
        end
        self:SyncRoute(true)
        return
    end

    if self.syncTimer then return end
    self.syncTimer = C_Timer.NewTimer(0.05, function()
        ns:SyncRoute(false)
    end)
end

function ns:OnToggle(enabled)
    self.DB.enabled = enabled
    if enabled then
        Print("APR sync enabled.")
        self:RequestSync(true)
    else
        Print("APR sync disabled.")
        if self.ownsRoute and self.agps and self.agps.Nav then
            self.agps.Nav.Clear()
            self.ownsRoute = false
            self.lastStops = {}
        end
        -- Restore APR arrow if it was hidden
        local APR = _G.APR
        if APR and APR.Arrow and APR.Arrow.RefreshVisibility then
            APR.Arrow:RefreshVisibility()
        end
    end
end

-----------------------------------------------------------------------------------------
-- Hooks and Events
-----------------------------------------------------------------------------------------

local function OnAPRUpdate()
    if not ns.DB or not ns.DB.enabled then return end
    ns:RequestSync(false)
end

local function OnStopArrive(info)
    if not ns.ownsRoute or not ns.DB or not ns.DB.enabled then return end
    Debug("Arrived at stop:", info.name, "last:", info.last)

    local APR = _G.APR
    if not APR then return end

    -- When arriving at a stop, refresh APR arrow and steps so APR can transition if ready
    if APR.Arrow and APR.Arrow.RefreshVisibility then
        APR.Arrow:RefreshVisibility()
    end
    if info.last and APR.UpdateStep then
        APR:UpdateStep()
    end
end

local function HookAzerothGPSInternal()
    if not ns.agps then return end

    if ns.agps.GPS and not ns.agps.GPS._aprHooked then
        ns.agps.GPS._aprHooked = true
        if ns.agps.GPS.Redraw then
            hooksecurefunc(ns.agps.GPS, "Redraw", function()
                ns:UpdateStopPinBadges()
                ns:UpdateMinimapPin()
                ns:UpdateDirectionsPanelBadges()
            end)
        end
        if ns.agps.GPS.Update then
            hooksecurefunc(ns.agps.GPS, "Update", function()
                ns:UpdateStopPinBadges()
                ns:UpdateDirectionsPanelBadges()
            end)
        end
        if ns.agps.GPS.EachSegmentNear and not ns.agps.GPS._aprEachSegmentNearHooked then
            ns.agps.GPS._aprEachSegmentNearHooked = true
            local origEachSegmentNear = ns.agps.GPS.EachSegmentNear
            ns.agps.GPS.EachSegmentNear = function(route, view, x, y, radius, fn)
                if ns.ownsRoute and ns.DB and ns.DB.enabled and type(fn) == "function" then
                    local wrappedFn = function(x1, y1, x2, y2, kind, stop, partCont, along, fz1, fz2)
                        ns.currentDrawStop = stop
                        local r1, r2, r3 = fn(x1, y1, x2, y2, kind, stop, partCont, along, fz1, fz2)
                        ns.currentDrawStop = nil
                        return r1, r2, r3
                    end
                    return origEachSegmentNear(route, view, x, y, radius, wrappedFn)
                end
                return origEachSegmentNear(route, view, x, y, radius, fn)
            end
        end

        if ns.agps.GPS.RouteLegLook and not ns.agps.GPS._aprRouteLegLookHooked then
            ns.agps.GPS._aprRouteLegLookHooked = true
            local origRouteLegLook = ns.agps.GPS.RouteLegLook
            ns.agps.GPS.RouteLegLook = function(l, col, width, dotted, kind, along, multi, own)
                if ns.ownsRoute and ns.DB and ns.DB.enabled and own and kind ~= 3 then
                    local stop = ns.currentDrawStop or 1
                    local stops = ns.agps and ns.agps.Nav and ns.agps.Nav.stops
                    local d = stops and stops[stop]
                    local r, g, b = GetPinColor(stop, d, d and d.step)
                    local ride = kind ~= 0 and kind ~= 1
                    local shade = ride and 0.7 or 1.0
                    local legColor = { r * shade, g * shade, b * shade }
                    local w = math.max(1, width * ((l and l.width) or 1))
                    local dDot = dotted or ((l and l.dotted) or false)
                    return legColor, w, dDot
                end
                return origRouteLegLook(l, col, width, dotted, kind, along, multi, own)
            end
        end

        if ns.agps.GPS.UpdateMinimapRoute and not ns.agps.GPS._aprMinimapRouteHooked then
            ns.agps.GPS._aprMinimapRouteHooked = true
            local origUpdateMinimapRoute = ns.agps.GPS.UpdateMinimapRoute
            ns.agps.GPS.UpdateMinimapRoute = function(force)
                local ret = origUpdateMinimapRoute(force)
                if ns.ownsRoute and ns.DB and ns.DB.enabled then
                    local mm = ns.agps.GPS.minimapRoute or ns.agps.GPS.mm
                    if mm and mm.stop then
                        mm.stop:Hide()
                        mm.stop:SetAlpha(0)
                    end
                    -- Match route leg colors on minimap lines to destination pin
                    if mm and mm.lines and ns.agps.Nav and ns.agps.Nav.route then
                        local r = ns.agps.Nav.route
                        local px, py, cont
                        if ns.agps.Geo and ns.agps.Geo.PlayerWorld then
                            px, py, cont = ns.agps.Geo.PlayerWorld()
                        end
                        local yards = (ns.agps.Layers and ns.agps.Layers.MinimapYards and ns.agps.Layers.MinimapYards()) or 400
                        local stops = ns.agps.Nav and ns.agps.Nav.stops
                        if r and px and cont and ns.agps.GPS.EachSegmentNear then
                            local lineIdx = 0
                            ns.agps.GPS.EachSegmentNear(r, cont, px, py, yards, function(x1, y1, x2, y2, kind, stop)
                                lineIdx = lineIdx + 1
                                local l = mm.lines[lineIdx]
                                if l and l:IsShown() then
                                    local d = stops and stops[stop or 1]
                                    local cr, cg, cb = GetPinColor(stop or 1, d, d and d.step)
                                    l:SetColorTexture(cr, cg, cb, kind == 0 and 0.95 or 0.6)
                                end
                            end)
                        end
                    end
                    ns:UpdateMinimapPins()
                end
                return ret
            end
        end
    end

    if ns.agps.Nav then
        if ns.agps.Nav.StepsText and not ns.agps.Nav._aprStepsTextWrapped then
            ns.agps.Nav._aprStepsTextWrapped = true
            local origStepsText = ns.agps.Nav.StepsText
            ns.agps.Nav.StepsText = function(shown)
                local text = origStepsText(shown)
                if not (ns.ownsRoute and ns.DB and ns.DB.enabled) or not text or text == "" then
                    return text
                end
                local stops = ns.agps.Nav.stops
                local lines = {}
                for line in text:gmatch("([^\r\n]+)") do
                    local i = #lines + 1
                    local d = stops and stops[i]
                    if d then
                        local num = GetStopNumber(i, d, d.step)
                        -- Replace leading number prefix (1. vs 104.)
                        line = line:gsub("^(|c%x%x%x%x%x%x%x%x)%d+%.%s*", "%1" .. num .. ". ")
                        line = line:gsub("^%d+%.%s*", num .. ". ")
                        -- Replace placeholder stop icon with full GetStopInlineTag
                        local tag = GetStopInlineTag(i, d, 14)
                        line = line:gsub("|T.-|t", tag, 1)
                        -- Clean up duplicate numbers if title already had step number
                        line = line:gsub("(to%s+)" .. num .. "%.%s*" .. num .. "%.%s*", "%1" .. num .. ". ")
                        line = line:gsub("(|T.-|t%s*)" .. num .. "%.%s*", "%1")
                    end
                    table.insert(lines, line)
                end

                return table.concat(lines, "\n")
            end
        end

        if ns.agps.Nav.Status and not ns.agps.Nav._aprStatusWrapped then
            ns.agps.Nav._aprStatusWrapped = true
            local origStatus = ns.agps.Nav.Status
            ns.agps.Nav.Status = function(px, py, cont)
                local status = origStatus(px, py, cont)
                if not (ns.ownsRoute and ns.DB and ns.DB.enabled) or not status then
                    return status
                end
                local stops = ns.agps.Nav.stops
                local d = stops and stops[1]
                if d then
                    local tag = GetStopInlineTag(1, d, 14)
                    status = status:gsub("^|T.-|t", tag, 1)
                end
                return status
            end
        end
    end

    local function HookArrowLines()
        local arrowFrame = _G.AzerothGPSArrow or (ns.agps and ns.agps.Arrow and ns.agps.Arrow.frame)
        if arrowFrame then
            local updatingLine = false
            local function HookRegion(region)
                if region and region.GetObjectType and region:GetObjectType() == "FontString" and not region._aprTextHooked then
                    region._aprTextHooked = true
                    hooksecurefunc(region, "SetText", function(self, text)
                        if updatingLine then return end
                        if ns.ownsRoute and type(text) == "string" and text:find("|T") then
                            local stops = ns.agps and ns.agps.Nav and ns.agps.Nav.stops
                            if not stops or #stops == 0 then return end
                            local newText = text
                            local rowIdx = tonumber(text:match("^%s*(%d+)%."))
                            if rowIdx and stops[rowIdx] then
                                local d = stops[rowIdx]
                                local num = GetStopNumber(rowIdx, d, d.step)
                                local tag = GetStopInlineTag(rowIdx, d, 12)
                                newText = newText:gsub("^%s*%d+%.%s*", tostring(num) .. ". ")
                                newText = newText:gsub("|T.-|t", tag, 1)
                            else
                                local d = stops[1]
                                local tag = GetStopInlineTag(1, d, 14)
                                newText = newText:gsub("|T.-|t", tag, 1)
                            end

                            if newText ~= text then
                                updatingLine = true
                                self:SetText(newText)
                                updatingLine = false
                            end
                        end
                    end)
                end
            end

            for _, region in ipairs({ arrowFrame:GetRegions() }) do
                HookRegion(region)
            end
            arrowFrame._aprHookRegion = HookRegion
        end
    end

    HookArrowLines()
    if _G.AzerothGPS and _G.AzerothGPS.Arrow and _G.AzerothGPS.Arrow.Init then
        hooksecurefunc(_G.AzerothGPS.Arrow, "Init", HookArrowLines)
    end
    if ns.agps.Arrow and ns.agps.Arrow.Init then
        hooksecurefunc(ns.agps.Arrow, "Init", HookArrowLines)
    end
    if ns.agps.Arrow and ns.agps.Arrow.Update and not ns.agps.Arrow._aprUpdateHooked then
        ns.agps.Arrow._aprUpdateHooked = true
        hooksecurefunc(ns.agps.Arrow, "Update", function()
            local arrowFrame = _G.AzerothGPSArrow or (ns.agps and ns.agps.Arrow and ns.agps.Arrow.frame)
            if arrowFrame and arrowFrame._aprHookRegion then
                for _, region in ipairs({ arrowFrame:GetRegions() }) do
                    arrowFrame._aprHookRegion(region)
                end
            end
        end)
    end
end

local function InitBridge()
    if ns.started then return end

    local APR = _G.APR
    local AzerothGPS = _G.AzerothGPS

    if not APR or not AzerothGPS then
        return
    end

    ns.started = true

    -- Hook APR step and arrow updates
    if APR.UpdateStep then
        hooksecurefunc(APR, "UpdateStep", OnAPRUpdate)
    end
    if APR.NextQuestStep then
        hooksecurefunc(APR, "NextQuestStep", OnAPRUpdate)
    end
    if APR.Arrow and APR.Arrow.SetCoord then
        hooksecurefunc(APR.Arrow, "SetCoord", OnAPRUpdate)
    end
    if APR.Arrow and APR.Arrow.SetArrowActive then
        hooksecurefunc(APR.Arrow, "SetArrowActive", OnAPRUpdate)
    end
    if APR.navigation and APR.navigation.Notify then
        hooksecurefunc(APR.navigation, "Notify", OnAPRUpdate)
    end
    if APR.routeconfig and APR.routeconfig.SendCustomPathUpdate then
        hooksecurefunc(APR.routeconfig, "SendCustomPathUpdate", OnAPRUpdate)
    end
    -- Hook APR Quest Order List updates
    if APR.questOrderList then
        if APR.questOrderList.AdvanceRenderedStep then
            hooksecurefunc(APR.questOrderList, "AdvanceRenderedStep", OnAPRUpdate)
        end
        if APR.questOrderList.AddStepFromRoute then
            hooksecurefunc(APR.questOrderList, "AddStepFromRoute", OnAPRUpdate)
        end
    end


    -- Register APR AceEvent messages
    if APR.RegisterMessage then
        APR.RegisterMessage(ns, "APR_MAP_UPDATE", OnAPRUpdate)
        APR.RegisterMessage(ns, "APR_Custom_Path_Update", OnAPRUpdate)
    end

    -- Register arrival hook with AzerothGPS
    if AzerothGPS.OnArrive then
        AzerothGPS.OnArrive("AzerothGPS_APR", OnStopArrive)
    end

    -- Hook Redraw on AzerothGPS to update numbered pin badges
    if AzerothGPS.Redraw then
        hooksecurefunc(AzerothGPS, "Redraw", function()
            ns:UpdateStopPinBadges()
            ns:UpdateMinimapPin()
            ns:UpdateDirectionsPanelBadges()
        end)
    end
    -- Hook AzerothGPS internal features
    HookAzerothGPSInternal()
    -- Hide APR arrow hook if user enabled it
    if APR.Arrow and APR.Arrow.UpdatePosition then
        hooksecurefunc(APR.Arrow, "UpdatePosition", function()
            ns:UpdateArrowVisibility()
        end)
    end

    Debug("Bridge initialized and hooked successfully.")

    -- Initial sync
    C_Timer.After(0.5, function()
        ns:RequestSync(true)
    end)
end

-- Extension hook for AzerothGPS internal namespace
if _G.AzerothGPS_Extend then
    _G.AzerothGPS_Extend(function(agps_ns)
        ns.agps = agps_ns
        Debug("Received AzerothGPS internal namespace.")
        HookAzerothGPSInternal()
        if _G.APR then
            InitBridge()
        end
    end)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("ZONE_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_ALIVE")
eventFrame:RegisterEvent("PLAYER_UNGHOST")

eventFrame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == addonName then
        _G.AzerothGPS_APR_DB = _G.AzerothGPS_APR_DB or {}
        ns.DB = _G.AzerothGPS_APR_DB
        for k, v in pairs(ns.DEFAULTS) do
            if ns.DB[k] == nil then
                ns.DB[k] = v
            end
        end
    elseif event == "PLAYER_LOGIN" then
        InitBridge()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" then
        if ns.started then
            ns:RequestSync(true)
        else
            InitBridge()
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        ns.inCombat = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        ns.inCombat = false
        if ns.pendingSync then
            ns.pendingSync = false
            ns:RequestSync(true)
        end
    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        ns:RequestSync(true)
    end
end)
