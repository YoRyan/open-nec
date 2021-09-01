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
- [NJ Transit Comet V Cab Car](https://store.steampowered.com/app/325970/Train_Simulator_North_Jersey_Coast_Line_Route_AddOn/)
- [NJ Transit/MARC Bombardier Multilevel Cab Car](https://store.steampowered.com/app/325970/Train_Simulator_North_Jersey_Coast_Line_Route_AddOn/)
- [MARC MPI MP36PH](https://store.steampowered.com/app/1429754/Train_Simulator_Northeast_Corridor_Washington_DC__Baltimore_Route_AddOn/)
- [Metro-North GE P32AC-DM](https://store.steampowered.com/app/258655/Train_Simulator_MetroNorth_P32_ACDM_Genesis_Loco_AddOn/)

Demonstrations:

- [Video demo #1](https://youtu.be/EFRsUOw1sGo)
- [Video demo #2](https://youtu.be/MjvzT8cTnnE)

## Overview

This website is divided into several sections. In the [Get the mod](installation) chapter, you can find information on obtaining and installing the mod and when you can expect the next release. In the [For players](for-players) chapter, you can learn how to navigate the newly improved Northeast Corridor with your newly upgraded equipment. In the [For contributors](for-contributors) chapter, developers can find information on how to contribute to the project, as well as technical documentation on Dovetail's content.

## Release history

The current stable release is Open NEC version **0.6.0**.

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
    - Critical: Fix broken destination signs and MU pantograph operation.

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