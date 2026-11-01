--[[
  AzerothGPS: APR Bridge (Config.lua)
  Options panel integrated into AzerothGPS settings, plus slash commands.
]]

local addonName, ns = ...

local registered = false
-- Register options page in AzerothGPS options window
local function RegisterOptionsPage()
    if registered then return end
    if not _G.AzerothGPS or not _G.AzerothGPS.AddOptionsPage then
        return
    end
    registered = true
    _G.AzerothGPS.AddOptionsPage("AzerothGPS_APR", "APR Integration", function(ui)
        ui.header("Azeroth Pilot Reloaded Integration",
            "Automatically routes active APR waypoints along roads and paths using AzerothGPS.")

        ui.check("Enable APR Routing",
            "Create navigation routes from APR waypoints in AzerothGPS.",
            function() return ns.DB and ns.DB.enabled end,
            function(v) if ns.OnToggle then ns:OnToggle(v) end end)

        ui.choice("Waypoint Mode", {
            { value = "chain", text = "Upcoming Route Steps (Recommended)",
              tip = "Routes through the upcoming steps and waypoints along your active APR route." },
            { value = "single", text = "Single Active Target",
              tip = "Routes only to the immediate active objective or arrow destination." },
            { value = "preview", text = "Full Travel Preview",
              tip = "Routes through all planned travel guidance segments and preview steps." },
        }, function()
            return ns.DB and ns.DB.waypointMode or "chain"
        end, function(v)
            if ns.DB then
                ns.DB.waypointMode = v
                ns:RequestSync(true)
            end
        end, function()
            return ns.DB and ns.DB.enabled
        end)
        ui.choice("Marker Style", {
            { value = "apr_numbered", text = "APR Numbered Pins (Recommended)",
              tip = "Uses APR's circular pin style with step numbers on the main map, Minimap, and Directions panel." },
            { value = "apr_plain", text = "APR Circular Pins (No Numbers)",
              tip = "Uses APR's circular badge pin without numbers." },
        }, function()
            return ns.DB and ns.DB.markerStyle or "apr_numbered"
        end, function(v)
            if ns.DB then
                ns.DB.markerStyle = v
                ns:RequestSync(true)
            end
        end, function()
            return ns.DB and ns.DB.enabled
        end)

        ui.choice("Pin & Path Color", {
            { value = "theme", text = "Match APR Theme (Recommended)",
              tip = "Uses the map pin color configured in your APR appearance profile." },
            { value = "gradient", text = "Dynamic Scale (Green -> Yellow -> Orange -> Red)",
              tip = "Dynamically colors pins and paths by proximity: Green for immediate stop, Yellow on deck, Orange in distance, Red furthest ahead." },
            { value = "rainbow", text = "Rainbow Pins (Deterministic per APR Step)",
              tip = "Each APR step receives a consistent distinct color based on its absolute guide step, so colors never reshuffle when you advance." },
            { value = "blue", text = "Vibrant Blue",
              tip = "Classic vibrant navigation blue pin and path." },
            { value = "green", text = "Emerald Green",
              tip = "Vibrant emerald green pin and path." },
            { value = "gold", text = "Classic Gold",
              tip = "Warm gold pin and path." },
            { value = "purple", text = "Royal Purple",
              tip = "Vibrant royal purple tone." },
            { value = "orange", text = "Sunset Orange",
              tip = "Warm sunset orange tone." },
            { value = "red", text = "Crimson Red",
              tip = "High visibility crimson red tone." },
            { value = "cyan", text = "Teal / Cyan",
              tip = "Bright teal / cyan tone." },
            { value = "pink", text = "Hot Pink",
              tip = "High visibility hot pink tone." },
        }, function()
            return ns.DB and ns.DB.pinColor or "theme"
        end, function(v)
            if ns.DB then
                ns.DB.pinColor = v
                ns:UpdateStopPinBadges()
                ns:UpdateMinimapPin()
                ns:RequestSync(true)
            end
        end, function()
            return ns.DB and ns.DB.enabled
        end)

        ui.choice("Directions Panel Icon", {
            { value = "marker", text = "Match Marker Style (Recommended)",
              tip = "Uses the same icon style configured in Marker Style (APR Numbered Pins, APR Circular Pins, or Raid Icons)." },
            { value = "quest", text = "Quest Status Icons (! and ?)",
              tip = "Shows yellow exclamation mark (!) for quests to accept and yellow question mark (?) for turn-ins in the arrow readout." },
            { value = "raid", text = "Colored Raid Target Symbols",
              tip = "Shows colored raid marker symbols (Square, Circle, Diamond, etc.) next to steps." },
        }, function()
            return ns.DB and ns.DB.stepIconType or "marker"
        end, function(v)
            if ns.DB then
                ns.DB.stepIconType = v
                ns:UpdateStopPinBadges()
                ns:UpdateMinimapPin()
                ns:RequestSync(true)
            end
        end, function()
            return ns.DB and ns.DB.enabled
        end)

        ui.choice("Step Numbering", {
            { value = "ordered", text = "Ordered Numbers (1, 2, 3...) (Recommended)",
              tip = "Numbers the upcoming route steps sequentially starting at 1 for the current destination." },
            { value = "apr", text = "APR Step Numbers (104, 105, 106...)",
              tip = "Displays the actual step numbers from your active Azeroth Pilot Reloaded guide." },
        }, function()
            return ns.DB and ns.DB.stepNumbering or "ordered"
        end, function(v)
            if ns.DB then
                ns.DB.stepNumbering = v
                ns:UpdateStopPinBadges()
                ns:UpdateMinimapPin()
                ns:RequestSync(true)
            end
        end, function()
            return ns.DB and ns.DB.enabled
        end)

        ui.check("Show Quest Name in Steps",
            "Display the actual quest name (e.g. Accept: A Threat Within, Turn in: Kobold Candles) in directions, step list, and pin tooltips.",
            function() return ns.DB and ns.DB.showQuestName end,
            function(v)
                if ns.DB then
                    ns.DB.showQuestName = v
                    ns:RequestSync(true)
                end
            end,
            function() return ns.DB and ns.DB.enabled end)

        ui.check("Show APR Step in Name",
            "Prefix the step number from APR (e.g. 104. Accept: A Threat Within) so destinations match your APR guide. The directions panel already numbers turns starting at 1.",
            function() return ns.DB and ns.DB.showStepNumber end,
            function(v)
                if ns.DB then
                    ns.DB.showStepNumber = v
                    ns:RequestSync(true)
                end
            end,
            function() return ns.DB and ns.DB.enabled end)

        ui.slider("Max Waypoints Ahead", 1, 8, 1, "%d",
            function() return ns.DB and ns.DB.maxStops or 4 end,
            function(v)
                if ns.DB then
                    ns.DB.maxStops = v
                    ns:RequestSync(true)
                end
            end,
            function() return ns.DB and ns.DB.enabled and ns.DB.waypointMode ~= "single" end)


        ui.check("Hide APR Arrow",
            "Hide APR's default navigation arrow while an AzerothGPS route is active, so only AzerothGPS guides you.",
            function() return ns.DB and ns.DB.hideAPRArrow end,
            function(v)
                if ns.DB then
                    ns.DB.hideAPRArrow = v
                    ns:UpdateArrowVisibility()
                end
            end,
            function() return ns.DB and ns.DB.enabled end)

        ui.check("Auto-Clear Route",
            "Clear the GPS route when APR has no active arrow or the route is completed/paused.",
            function() return ns.DB and ns.DB.autoClear end,
            function(v) if ns.DB then ns.DB.autoClear = v end end,
            function() return ns.DB and ns.DB.enabled end)
        ui.check("Minimap Button",
            "Show the APR waypoint toggle button on the Minimap. Left-click toggles APR waypoints; Right-click opens these options.",
            function() return ns.DB and ns.DB.minimap and not ns.DB.minimap.hide end,
            function(v)
                if ns.DB then
                    ns.DB.minimap = ns.DB.minimap or {}
                    ns.DB.minimap.hide = not v
                    if ns.UpdateMinimapButton then
                        ns:UpdateMinimapButton()
                    end
                end
            end)

        ui.check("Debug Logging",
            "Print route synchronization and coordinate debug messages to the chat frame.",
            function() return ns.DB and ns.DB.debug end,
            function(v) if ns.DB then ns.DB.debug = v end end,
            function() return ns.DB and ns.DB.enabled end)

        ui.button("Sync Route Now", 140, function()
            ns:RequestSync(true)
        end)

        ui.note("Tip: AzerothGPS will calculate the optimal road/terrain path to your APR waypoints, showing turn-by-turn directions and a minimap line.")
    end)
end

-- Slash commands
SLASH_AZEROTHGPSAPR1 = "/aprgps"
SLASH_AZEROTHGPSAPR2 = "/apr-gps"
SlashCmdList.AZEROTHGPSAPR = function(msg)
    msg = strtrim(msg or ""):lower()
    local cmd, arg = strsplit(" ", msg, 2)

    if cmd == "toggle" then
        if ns.DB then
            ns:OnToggle(not ns.DB.enabled)
        end
    elseif cmd == "sync" or cmd == "refresh" then
        ns:RequestSync(true)
        ns.Print("Route synchronization triggered.")
    elseif cmd == "mode" then
        if arg == "single" or arg == "chain" or arg == "preview" then
            if ns.DB then
                ns.DB.waypointMode = arg
                ns:RequestSync(true)
                ns.Print("Waypoint mode set to: " .. arg)
            end
        else
            ns.Print("Usage: /aprgps mode [single|chain|preview]")
        end
    elseif cmd == "marker" or cmd == "style" then
        if arg == "apr_numbered" or arg == "apr_plain" or arg == "nostar" or arg == "default" then
            if ns.DB then
                ns.DB.markerStyle = arg
                ns:RequestSync(true)
                ns.Print("Marker style set to: " .. arg)
            end
        else
            ns.Print("Usage: /aprgps marker [apr_numbered|apr_plain|nostar|default]")
        end
    elseif cmd == "panelicon" or cmd == "directionicon" then
        if arg == "marker" or arg == "quest" or arg == "raid" then
            if ns.DB then
                ns.DB.stepIconType = arg
                ns:UpdateStopPinBadges()
                ns:UpdateMinimapPin()
                ns:RequestSync(true)
                ns.Print("Directions panel icon style set to: " .. arg)
            end
        else
            ns.Print("Usage: /aprgps panelicon [marker|quest|raid]")
        end
    elseif cmd == "color" or cmd == "pincolor" then
        local valid = { theme = true, gradient = true, rainbow = true, blue = true, green = true, gold = true, purple = true, orange = true, red = true, cyan = true, pink = true }
        if valid[arg] then
            if ns.DB then
                ns.DB.pinColor = arg
                ns:UpdateStopPinBadges()
                ns:UpdateMinimapPin()
                ns:RequestSync(true)
                ns.Print("Pin & path color set to: " .. arg)
            end
        else
            ns.Print("Usage: /aprgps color [theme|gradient|rainbow|blue|green|gold|purple|orange|red|cyan|pink]")
        end
    elseif cmd == "numbering" or cmd == "numbers" then
        if arg == "ordered" or arg == "apr" then
            if ns.DB then
                ns.DB.stepNumbering = arg
                ns:UpdateStopPinBadges()
                ns:UpdateMinimapPin()
                ns:RequestSync(true)
                ns.Print("Step numbering set to: " .. (arg == "ordered" and "Ordered (1, 2, 3...)" or "APR Guide Numbers"))
            end
        else
            ns.Print("Usage: /aprgps numbering [ordered|apr]")
        end
    elseif cmd == "debug" then
        if ns.DB then
            ns.DB.debug = not ns.DB.debug
            ns.Print("Debug logging " .. (ns.DB.debug and "enabled." or "disabled."))
        end
    elseif cmd == "minimap" then
        if ns.DB then
            ns.DB.minimap = ns.DB.minimap or {}
            if arg == "on" or arg == "show" then
                ns.DB.minimap.hide = false
            elseif arg == "off" or arg == "hide" then
                ns.DB.minimap.hide = true
            else
                ns.DB.minimap.hide = not ns.DB.minimap.hide
            end
            if ns.UpdateMinimapButton then
                ns:UpdateMinimapButton()
            end
            ns.Print("Minimap button " .. (ns.DB.minimap.hide and "hidden." or "shown."))
        end
    elseif cmd == "clear" then
        if ns.agps and ns.agps.Nav then
            ns.agps.Nav.Clear()
            ns.ownsRoute = false
            ns.lastStops = {}
            ns.Print("Route cleared.")
        end
    elseif cmd == "help" then
        ns.Print("Commands:")
        ns.Print("  /aprgps - Open settings in AzerothGPS options")
        ns.Print("  /aprgps toggle - Enable or disable APR waypoint synchronization")
        ns.Print("  /aprgps sync - Force immediate route synchronization")
        ns.Print("  /aprgps marker [apr_numbered|apr_plain] - Set marker visual style")
        ns.Print("  /aprgps color [theme|gradient|rainbow|blue|green|gold|purple|orange|red|cyan|pink] - Set pin & path color")
        ns.Print("  /aprgps numbering [ordered|apr] - Switch between Ordered (1, 2, 3) and APR step numbers")
        ns.Print("  /aprgps panelicon [marker|quest|raid] - Set directions panel icon style")
        ns.Print("  /aprgps clear - Clear active route")
        ns.Print("  /aprgps minimap [on|off] - Toggle or set minimap button visibility")
        ns.Print("  /aprgps debug - Toggle debug logging")
    else
        -- Open AzerothGPS options window at the APR Integration page
        if _G.AzerothGPS and _G.AzerothGPS.ShowOptions then
            local opened = _G.AzerothGPS.ShowOptions("APR Integration", "AzerothGPS_APR")
            if not opened then
                _G.AzerothGPS.ShowOptions()
            end
        else
            ns.Print("AzerothGPS options window not available. Use '/aprgps help' for commands.")
        end
    end
end

-- Initialize options page when ready
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    RegisterOptionsPage()
end)
