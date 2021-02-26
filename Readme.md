![Project logo](Docs/OpenNec.svg)

# Open Northeast Corridor Project

The Open NEC Project is a heavily work-in-progress systems overhaul mod for Northeast Corridor content for Train Simulator 20xx, in the style of the [A32NX Project](https://github.com/flybywiresim/a32nx). The objectives are to fix the control bugs, permit every locomotive to run on every route, and create as realistic an experience as possible. Particular attention will be paid to ATC and ACSES systems in use on the real-life Northeast Corridor.

To make this happen, this project will be replacing the Lua scripts included with Dovetail's rolling stock. Train Simulator uses Lua 5.0, and the scripts distributed by Dovetail can be partially reverse-engineered with [unluac](https://sourceforge.net/projects/unluac/). Using a compatible Lua compiler, and using Dovetail's code as a reference, we can build our own fully open-source engine simulations.

This project will also be documenting the controls specific to each locomotive and the signaling systems employed by Dovetail on each rendition of the Northeast Corridor. You can browse this documentation in the [Docs](Docs/) folder.

## Current Status

This mod is tested and working on the following routes:
- [Northeast Corridor: New York - Philadelphia](https://store.steampowered.com/app/65232/Train_Simulator_Northeast_Corridor_New_York__Philadelphia_Route_AddOn/)
- [NEC: New York - New Haven](https://store.steampowered.com/app/258643/Train_Simulator_NEC_New_YorkNew_Haven_Route_AddOn/)
- [North Jersey Coast Line](https://store.steampowered.com/app/325970/Train_Simulator_North_Jersey_Coast_Line_Route_AddOn/)
- [North Jersey Coast & Morristown Lines](https://store.steampowered.com/app/500218/Train_Simulator_North_Jersey_Coast__Morristown_Lines_Route_AddOn/)

Amtrak's ATC and ACSES safety systems have been implemented with a high degree of realism--including braking curve calculation for ACSES, so the engineer will be notified of speed restrictions ahead of time. Locomotives will also cut their power if they enter a section of incompatible track, for example if the AEM-7 enters a section without overhead catenary.

The following locomotives have been successfully overhauled:

- [Amtrak EMD AEM-7](https://store.steampowered.com/app/65232/Train_Simulator_Northeast_Corridor_New_York__Philadelphia_Route_AddOn/)
  - Fixed cruise control functionality. Turn the dial to your desired speed and set throttle to activate.
  - Fixed the cab signals to display 30 mph for Medium Clear, not 45 mph.

To-do list:
- [ ] ACSES positive stop functionality

## Build Instructions

This project uses MSBuild, which is included with Visual Studio. [Open](https://docs.microsoft.com/en-us/dotnet/framework/tools/developer-command-prompt-for-vs) a developer console to gain access to the command. Then ensure `luac50.exe` (the Lua 5.0 [compiler](https://sourceforge.net/projects/luabinaries/files/5.0.3/Tools%20Executables/)) and `luacheck.exe` (the [Luacheck](https://github.com/mpeterv/luacheck) linter) are in your PATH and run `msbuild Source\OpenNec.proj /t:Build` to compile the project. The compiled files will be output to the Mod folder, from which they can be copied into Train Simulator's Assets folder.

## Legal

All content in this repository is [licensed](License.md) under the GNU General Public License, version 3.