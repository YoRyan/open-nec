# Introduction

![Cover image](opennec-cover.jpg)

The Open NEC Project is a massive, work-in-progress systems overhaul mod for [Train Simulator 20xx](https://live.dovetailgames.com/live/train-simulator) that encompasses Amtrak's Northeast Corridor locale from Washington, DC to Boston. The mod is planned to include enhancements for all of the Amtrak, NJ Transit, Metro-North, and other equipment that Dovetail Games has released for the Northeast Corridor. It will also include upgrades for the signaling systems of the various routes.

To make this all possible, the project provides drop-in replacements for Dovetail's Lua bytecode. With control of the Lua scripting, we have complete control over the behavior of locomotive's systems, as well as the route's signaling system. Thus, we can fix bugs and make dramatic improvements to the gameplay experience.

Currently, the project enhances most of the Northeast Corridor locomotives available for Train Simulator, adding complete Automatic Train Control (ATC) and Advanced Civil Speed Enforcement System (ACSES) implementations.

Locomotives overhauled by the Open NEC project include:

- [Amtrak EMD AEM-7](https://store.steampowered.com/app/65232/Train_Simulator_Northeast_Corridor_New_York__Philadelphia_Route_AddOn/)
- [Amtrak Acela Express](https://store.steampowered.com/app/65231/Train_Simulator_Amtrak_Acela_Express_EMU_AddOn/)
- [Amtrak Bombardier HHP-8](https://store.steampowered.com/app/222558/Train_Simulator_Amtrak_HHP8_Loco_AddOn/)
- [Amtrak Siemens ACS-64](https://store.steampowered.com/app/258643/Train_Simulator_NEC_New_YorkNew_Haven_Route_AddOn/)
- [Amtrak GE P32AC-DM](https://store.steampowered.com/app/896719/Train_Simulator_Hudson_Line_New_York__CrotonHarmon_Route_AddOn/)
- [Amtrak GE P42DC](https://store.steampowered.com/app/1429754/Train_Simulator_Northeast_Corridor_Washington_DC__Baltimore_Route_AddOn/)
- [NJ Transit Bombardier ALP-45DP](https://store.steampowered.com/app/325970/Train_Simulator_North_Jersey_Coast_Line_Route_AddOn/)
- [NJ Transit Bombardier ALP-46](https://store.steampowered.com/app/258658/Train_Simulator_NJ_TRANSIT_ALP46_Loco_AddOn/)
- [NJ Transit GE Arrow III](https://store.steampowered.com/app/500247/Train_Simulator_NJ_TRANSIT_Arrow_III_EMU_AddOn/)
- [NJ Transit EMD GP40PH-2B](https://store.steampowered.com/app/325991/Train_Simulator_NJ_TRANSIT_GP40PH2B_Loco_AddOn/)
- [NJ Transit Comet V Cab Car](https://store.steampowered.com/app/325970/Train_Simulator_North_Jersey_Coast_Line_Route_AddOn/)
- [NJ Transit Bombardier Multilevel Cab Car](https://store.steampowered.com/app/325970/Train_Simulator_North_Jersey_Coast_Line_Route_AddOn/)
- [MARC MPI MP36PH](https://store.steampowered.com/app/1429754/Train_Simulator_Northeast_Corridor_Washington_DC__Baltimore_Route_AddOn/)
- [MARC Bombardier Multilevel Cab Car](https://store.steampowered.com/app/1429754/Train_Simulator_Northeast_Corridor_Washington_DC__Baltimore_Route_AddOn/)
- [Metro-North GE P32AC-DM](https://store.steampowered.com/app/258655/Train_Simulator_MetroNorth_P32_ACDM_Genesis_Loco_AddOn/)
- [Metro-North Shoreliner Cab Car](https://store.steampowered.com/app/258655/Train_Simulator_MetroNorth_P32_ACDM_Genesis_Loco_AddOn/)
- [Metro-North Kawasaki M8](https://store.steampowered.com/app/258647/Train_Simulator_MetroNorth_Kawasaki_M8_EMU_AddOn/)

Demonstrations:

- [Video demo #1](https://youtu.be/EFRsUOw1sGo)
- [Video demo #2](https://youtu.be/MjvzT8cTnnE)

## Overview

This website is divided into several sections. In the [Get the mod](installation) chapter, you can find information on obtaining and installing the mod and when you can expect the next release. In the [For players](for-players) chapter, you can learn how to navigate the newly improved Northeast Corridor with your newly upgraded equipment. In the [For contributors](for-contributors) chapter, developers can find information on how to contribute to the project, as well as technical documentation on Dovetail's content.


## FAQ

##### Does this mod include any route or model improvements?

No. Currently, this project only includes improvements to the Lua scripting. Everything has been carefully constructed to avoid conflicting with other mods, especially Fan Railer's physics and sound mods.

##### Does this mod merge any routes together?

No.

##### Help! I was driving in an external view and now my train is stuck in a penalty brake.

Open NEC enables all safety systems by default, which must be responded to, even when not driving inside the cab. On most locomotives, you can press Ctrl+D to disable ATC, and Ctrl+F to disable ACSES. Furthermore, Open NEC also adds an alerter subsystem that will sound an alarm if the controls are not manipulated within a certain period of time. There is no cab or keyboard control to disable the alerter, but you can press the exclamation mark on the HUD to "stick" the acknowledge button in the pressed position, which will prevent the alerter from activating.

## Release history

The current stable release is Open NEC version **1.0.0**.

#### v1.0.0 (January 27, 2022)

- Support for the Metro-North M8.
    - Includes a notched master controller and, when used with Fan Railer's physics mod, blended braking.
- ATC:
    - Fixed duplicate enforcement alarms.
- ACSES:
    - Added acknowledgement for all civil speed drops.
    - Increased alert and penalty curve margins to 3 and 6 mph.
    - Cab displays now show a Stop aspect when nearing a Stop signal with a Restricting pulse code in force, to simulate a positive stop. There is a braking curve for the detection of positive stops, but there is no enforcement of the positive stop. Scripting limitations require OpenNEC to show a positive stop for *all* stop signals, not just ones at interlockings.
    - Reduced instances of "forgetting" the upcoming speed limit on heavier routes like New York-New Haven and Washington-Baltimore.
- Acela Express:
    - Added a destination sign for New Carrollton, which Acela stopped at during its first few years of service.
- EMD GP40PH-2B:
    - Changed strobe light pattern to be more prototypical.
- GE Arrow III:
    - Restored ability to lower the pantograph using the cab control.
    - AI trains now turn on their bright headlights.
- Amtrak locomotives:
    - Changed ditch lights to flash at a prototypical frequency.
- NJ Transit locomotives:
    - Speed drop alarms can now be acknowledged and silenced.
    - Speed drop sounds now play at the beginning of the braking curve, not the end.
- All locomotives:
    - For locomotives for which it would be unrealistic, sounding the horn no longer flashes the ditch lights.
    - Train brake status is now sent via consist message 10101, which enables the brake lights on Dovetail's Superliners and Ragno's Viewliner to work.

#### v0.7.0 (September 16, 2021)

- Support for the NJ Transit Arrow III and GP40PH-2B.
- Bombardier HHP-8:
    - **Critical**: Fixed nil error in script.
- Bombardier ALP-45DP:
    - Reinstated exhaust fans.
    - Exhaust particles now increase or decrease depending on power output.
- Siemens ACS-64:
    - Fixed wheelslip indicator being perpetually illuminated.

#### v0.6.0 (September 1, 2021)

- Support for the NJ Transit ALP-45DP and ALP-46.
- ATC:
    - Removed target deceleration rate requirement to achieve Suppression.
    - Fixed occasional failure to detect Suppression in locomotives with notched controllers.
    - Added support for Brandon Phelan's new Washington-Baltimore signal scripts.
- Bombardier Comet V and Multilevel:
    - Changed speed bars to show the ACSES braking curve at all times.
    - Reinstated power mode changing when MU'ing with an ALP-45DP (see notes).
    - Reinstated blended braking and safety systems cut in/out.
    - Fixed HEP status and destination sign not being synced to other coaches.
- MPI MP36PH:
    - Reinstated safety systems cut in/out.
- All locomotives:
    - Removed the acknowledge auto-reset feature. Clicking the exclamation mark icon in the HUD now sticks the acknowledge control in the pressed state, as with other equipment in TS1.

#### v0.5.0 (May 22, 2021)

- Support for the NJ Transit Comet V and Multilevel Cab Car.
- ATC:
    - Logic has been changed to require target deceleration rate AND brake lever in suppression.
- Amtrak ACS-64:
    - Fix overpowered train brakes.
- Amtrak P32/P42 and MNRR P32:
    - Ditch lights will now flash when switched on.
    - Equipment speed limit raised to 110 mph for Amtrak locos.
- Bombardier Multilevel:
    - Brake light indicators reinstated.
    - Manual door control reinstated.
    - Destination sign control reinstated.
    - MARC Multilevel destination signs texture swapped for MARC destinations.

#### v0.4.0 (April 23, 2021)

- Support for the Amtrak and Metro-North P32AC-DM.
- Support for the Amtrak P42DC (paths are set for the Washington-Baltimore version).
- Official support for the Hudson Line route.
- Amtrak Acela:
    - **Critical**: Fix broken destination signs and MU pantograph operation.

#### v0.3.0 (April 17, 2021)

- Support for the Amtrak ACS-64.
- Support for the MARC MP36PH and Multilevel Cab Car.
- ACSES:
    - Temporarily disable positive stop as it is a nuisance in yards and stations.
- Amtrak Acela:
    - Fix ditch lights rendering even when turned off.
- Amtrak HHP-8:
    - Fix ditch lights rendering even when turned off.
    - Fix Xbox and Raildriver controls when running with Fan Railer's mod.

#### v0.2.0 (March 17, 2021)

- Support for the Amtrak Acela Express.
- Support for the Amtrak HHP-8.

#### v0.1.0-beta (March 9, 2021)

The first public release!

- Support for the Amtrak AEM-7.
- Support for all Dovetail Northeast Corridor routes.
- Complete CSS, ATC, and ACSES implementations.

![Project logo](opennec-logo.svg)