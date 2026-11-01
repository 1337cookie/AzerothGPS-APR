# AzerothGPS: APR Bridge (`AzerothGPS-APR`)

A companion bridge addon for World of Warcraft connecting **Azeroth Pilot Reloaded (APR)** with **AzerothGPS (AGPS)** without modifying either addon.

## Overview

When questing or leveling with Azeroth Pilot Reloaded, APR provides optimal waypoints for route steps, travel, and quest objectives. 
This bridge connects those waypoints directly into AzerothGPS's road network, obstacle avoidance router:
The path is drawn on AzerothGPS's map window and the game's Minimap and provides readable steps thought its directions panel. As you complete steps or arrive at waypoints, this bridge addon advances the GPS route to the next waypoints seamlessly.
Consecutive waypoints can be grouped into single pins on the map when they are close.

## Installation

1. Copy the `AzerothGPS-APR` folder into your World of Warcraft addons directory:
   `World of Warcraft\_retail_\Interface\AddOns\AzerothGPS-APR` (or `_classic_` / `_classic_era_`)
2. Ensure both **Azeroth Pilot Reloaded** and **AzerothGPS** are installed and enabled.
3. Log in to the game. The bridge activates automatically.

## Configuration & Options

The addon integrates directly into AzerothGPS's options window:
- Type `/agps` and navigate to the **APR Integration** tab, or type `/aprgps`.

### Available Settings
- **Enable APR Routing**: Master toggle for waypoint synchronization.
- **Waypoint Mode**:
  - `Upcoming Route Steps (Recommended)`: Routes through the upcoming steps and waypoints along your active APR route (up to Max Waypoints Ahead).
  - `Single Active Target`: Routes strictly to the immediate active objective or arrow destination.
  - `Full Travel Preview`: Routes through all planned travel guidance segments and preview steps.
- **Marker Style**:
  - `APR Numbered Pins (Recommended)`: Uses APR's circular pin badge (`Icon.tga`) with centered step numbers matching the active numbering mode on the main map, the Minimap, and in the Directions panel.
  - `APR Circular Pins (No Numbers)`: Clean APR badge pins without numbers on the main map, Minimap, and Directions panel.
- **Pin & Path Color**:
  - Every path section automatically matches the color of the pin it heads to.
  - `Match APR Theme (Recommended)`: Automatically matches the map pin color configured in your APR appearance profile.
  - `Dynamic Scale (Green -> Yellow -> Orange -> Red)`: Dynamically colors pins and paths by proximity—Green for your immediate destination, Yellow on deck, Orange in the distance, and Red furthest out.
  - `Rainbow Pins (Deterministic per APR Step)`: Assigns a consistent, distinct color from a rich 12-color wheel based on the absolute APR guide step. Step 70 stays the exact same color throughout your journey, even when using sequential ordered numbering (1, 2, 3...) so colors never reshuffle when steps complete.
  - Dedicated vibrant presets: `Vibrant Blue`, `Emerald Green`, `Classic Gold`, `Royal Purple`, `Sunset Orange`, `Crimson Red`, `Teal / Cyan`, `Hot Pink`.
- **Step Numbering**:
  - `Ordered Numbers (1, 2, 3...) (Recommended)`: Numbers route stops sequentially starting at 1 for the current step.
  - `APR Step Numbers (104, 105, 106...)`: Uses the APR guide step number from the Quest Order List.
- **Directions Panel Icon**:
  - `Match Marker Style (Recommended)`: Uses numbered colored circle badges (matching Marker Style) next to turn-by-turn directions.
  - `Quest Status Icons (! and ?)`: Displays yellow exclamation marks (`!`) for quests to accept and yellow question marks (`?`) for turn-ins in the directions panel.
  - `Colored Raid Target Symbols`: Uses raid marker symbols next to direction steps.
- **Show APR Step in Name**:
  - Prefixes the APR guide step number (e.g. `104. Accept: A Threat Within`) in destination names and tooltips. The directions panel continues to provide ordered turn-by-turn numbers starting at 1 (`1. Walk 50 yd to... 104. Accept: A Threat Within`).
- **Hide APR Arrow**: Optional setting to hide APR's default arrow so only AzerothGPS's arrow directs you.
- **Auto-Clear Route**: Automatically clears the GPS route when APR has no active arrow or the route finishes.
### Slash Commands
- `/aprgps` - Open the APR Integration options in AzerothGPS
- `/aprgps toggle` - Enable or disable APR waypoint synchronization
- `/aprgps sync` - Force immediate route recalculation
- `/aprgps marker [apr_numbered|apr_plain]` - Change marker visual style
- `/aprgps color [theme|gradient|rainbow|blue|green|gold|purple|orange|red|cyan|pink]` - Set pin & path color
- `/aprgps numbering [ordered|apr]` - Switch between sequential (1, 2, 3) and guide (104, 105...) step numbers
- `/aprgps panelicon [marker|quest|raid]` - Change directions panel icon style
- `/aprgps clear` - Clear the active route
- `/aprgps debug` - Toggle debug logs in chat
- `/aprgps help` - List available commands

## Architecture

The bridge operates strictly through public and companion extension APIs:
1. **AzerothGPS Hooking**: Uses `AzerothGPS_Extend` and `AzerothGPS` public APIs (`MapToWorld`, `OnArrive`, `AddOptionsPage`).
2. **APR Observation**: Observes `APR_MAP_UPDATE`, step transitions, and arrow updates via `hooksecurefunc` and AceEvent messages.
3. **Coordinate Translation**: Converts between APR/HereBeDragons coordinates (North-South on Y, East-West on X) and AzerothGPS world yard coordinates (North-South on X, East-West on Y), ensuring accurate placement across all continents and zones.
4. **Non-Intrusive**: Neither APR nor AzerothGPS is modified.
