# Open Northeast Corridor Project

The Open NEC Project is a heavily work-in-progress systems overhaul mod for Dovetail Games' Northeast Corridor content for Train Simulator 20xx. The objectives are to fix the control bugs, permit every locomotive to run on every route, and create as realistic an experience as possible. Particular attention will be paid to ATC and ACSES systems in use on the real-life Northeast Corridor.

To make this happen, this project will be replacing the Lua scripts included with Dovetail's rolling stock. Train Simulator uses Lua 5.0, and the scripts distributed by Dovetail can be partially reverse-engineered with [unluac](https://sourceforge.net/projects/unluac/). Using a compatible Lua [compiler](https://sourceforge.net/projects/luabinaries/files/5.0.3/Tools%20Executables/), and using Dovetail's code as a reference, we can build our own fully open-source engine simulations.

This project will also be documenting the controls specific to each locomotive and the signaling systems employed by Dovetail on each rendition of the Northeast Corridor. You can browse this documentation in the [Docs](Docs/) folder.

## Build Instructions

This project uses MSBuild, which is included with Visual Studio. [Open](https://docs.microsoft.com/en-us/dotnet/framework/tools/developer-command-prompt-for-vs) a developer console to gain access to the command. Then ensure `luac50.exe` is in your PATH and run `msbuild Source\OpenNec.proj /t:Build` to compile the project. The compiled files will be output to the Mod folder, from which they can be copied into Train Simulator's Assets folder.

## Legal

All content in this repository is [licensed](License.md) under the GNU General Public License, version 3.