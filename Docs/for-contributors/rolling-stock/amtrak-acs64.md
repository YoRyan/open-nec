# Amtrak ACS-64

The Siemens ACS-64 is an electric locomotive included with the New York to New Haven and Washington to Baltimore routes. It is currently the only conventional electric locomotive operated by Amtrak.

## Controls

### Control desk

#### CabLight

The cab dome light switch.

The default position is 0.

#### DeskConsoleLight

The desk and console lights switch. 0 = off, 1 = desk light only, 2 = both lights, 3 = console light only.

The default position is 0.

#### PantographDownButton

The pantograph lower button. 0 = released, 1 = depressed.

The default position is 0.

#### PantographUpButton

The pantograph raise button. 0 = released, 1 = depressed.

The default position is 0.

#### AWSReset

The safety systems acknowledge button.

The default position is 0.

#### Reverser

The reverser lever. -1 = reverse, 0 = neutral, 1 = forward.

The default position is 0.

#### ThrottleAndBrake

The combined throttle/dynamic brake lever. Ranges from 0 to 1, where <0.5 applies braking, 0.5 coasts, and >0.5 applies power.

The default position is 0.5.

#### VirtualBrake

The player's Expert Mode train brake control. Ranges from 0 to 1.

| Value | Meaning |
| --- | --- |
| 1.0 | Emergency |
| 0.85 | Full service |
| 0.75 | Suppression |
| 0.575 | Service 95% |
| 0.55 | Service 85% |
| 0.525 | Service 75% |
| 0.5 | Service 65% |
| 0.475 | Service 55% |
| 0.45 | Service 45% |
| 0.425 | Service 35% |
| 0.4 | Service 25% |
| 0.375 | Service 15% |
| 0.35 | Service 5% |
| 0.1 | Minimum |
| 0 | Release |

#### TrainBrakeControl

The true train brake control used by the physics model. Ranges from 0 to 1.

The default position is 0.75.

#### EngineBrakeControl

The player's Expert Mode independent (locomotive) brake control. Ranges from 0 to 1.

The default position is 0.

#### Sander

The sander switch.

The default position is 0.

#### Headlights

The forward headlight switch. 0 = off, 1 = forward headlights, 2 = reverse headlights.

The default position is 0.

#### DitchLight

The ditch light switch. 0 = off, 1 = on, 2 = flash.

The default position is 0.

#### Bell

The bell button.

The default position is 0.

#### Horn

The horn joystick.

The default position is 0.

### Dashboard

#### SigAspectTopGreen

Illuminates the upper green cab signal aspect lamp.

#### SigAspectTopYellow

Illuminates the upper yellow cab signal aspect lamp.

#### SigAspectTopYellow

Illuminates the upper yellow cab signal aspect lamp.

#### SigAspectTopRed

Illuminates the upper red cab signal aspect lamp.

#### SigAspectTopWhite

Illuminates the upper white cab signal aspect lamp.

#### SigAspectBottomGreen

Illuminates the lower green cab signal aspect lamp.

#### SigAspectBottomYellow

Illuminates the lower yellow cab signal aspect lamp.

#### SigAspectBottomWhite

Illuminates the lower white cab signal aspect lamp.

#### SigText

Selects one of the predefined texts for the cab signal aspect display.

| Value | Result |
| --- | --- |
| 1 | CLEAR |
| 2 | CAB SPEED |
| 3 | APPROACH LIMITED |
| 4 | LIMITED CLEAR |
| 5 | ADVANCE APPROACH |
| 6 | MEDIUM CLEAR |
| 7 | SLOW APPROACH |
| 8 | APPROACH |
| 9 | MEDIUM APPROACH |
| 10 | STOP AND PROCEED |
| 11 | RESTRICTING |
| 12 | STOP |
| 13 | APPROACH MEDIUM |

All other values blank the display.

#### SigS

Illuminates the "S" cab signal aspect lamp.

#### SigS

Illuminates the "S" cab signal aspect lamp.

#### SigR

Illuminates the "R" cab signal aspect lamp.

#### SigM

Illuminates the "M" cab signal aspect lamp.

#### SigL

Illuminates the "L" cab signal aspect lamp.

#### Sig60

Illuminates the "60" cab signal aspect lamp.

#### Sig80

Illuminates the "80" cab signal aspect lamp.

#### SigN

Illuminates the "N" cab signal aspect lamp.

#### SigModeATC

Illuminates the "ATC" lamp to the left of the maximum authorized speed indicator.

#### SigModeACSES

Illuminates the "ACSES" lamp to the right of the maximum authorized speed indicator.

#### SpeedLimit_hundreds

Sets the hundreds digit on the maximum authorized speed indicator. 0 hides the digit.

#### SpeedLimit_tens

Sets the tens digit on the maximum authorized speed indicator. -1 hides the digit.

#### SpeedLimit_units

Sets the ones digit on the maximum authorized speed indicator. -1 hides the digit.

#### Penalty_hundreds

Sets the hundreds digit on the time to penalty indicator. 0 hides the digit.

#### Penalty_tens

Sets the tens digit on the time to penalty indicator. -1 hides the digit.

#### Penalty_units

Sets the ones digit on the time to penalty indicator. -1 hides the digit.

#### SigATCCutIn

Illuminates the green "ATC Cut-In" lamp.

#### SigATCCutOut

Illuminates the red "ATC Cut-Out" lamp.

#### SigACSESCutIn

Illuminates the green "ACSES Cut-In" lamp.

#### SigACSESCutOut

Illuminates the red "ACSES Cut-Out" lamp.

#### Wipers

The wiper switch.

The default position is 0.

### Display

#### effort_tens

Sets the tens digit on the kLBS effort indicator. -1 hides the digit.

#### effort_units

Sets the ones digit on the kLBS effort indicator. -1 hides the digit.

#### effort_guide

Moves the effort indicator digits by the supplied number of places to compensate for a smaller number.

The effect is so small as to be useless.

#### AbsTractiveEffort

Fills the kLBS effort indicator bar. Ranges from 0 (0) to 365 (80 kLBS).

#### SpeedometerMPH

The current position of the speedometer dial. This value is set by the simulator, not by Lua.

#### SpeedDigit_hundreds

Sets the hundreds digit on the speedometer. 0 hides the digit.

#### SpeedDigit_tens

Sets the tens digit on the speedometer. -1 hides the digit.

#### SpeedDigit_units

Sets the ones digit on the speedometer.

#### SpeedDigit_guide

Moves the speedometer digits by the supplied number of places to compensate for a smaller number.

#### accel_hundreds

Sets the hundreds digit on the mph/min accelerometer. 0 hides the digit.

#### accel_tens

Sets the tens digit on the mph/min accelerometer. -1 hides the digit.

#### accel_units

Sets the ones digit on the mph/min accelerometer. -1 hides the digit.

#### accel_guide

Moves the accelerometer digits by the supplied number of places to compensate for a smaller number.

#### AccelerationMPHPM

Fills the mph/min accelerometer indicator bar. Ranges from 0 to 150.

#### ScreenAlerter

Illuminates the large, yellow "Alerter" indicator and plays a continuous beeping sound.

#### ScreenWheelslip

Illuminates the yellow "Wheel Slip" indicator.

#### ScreenDoorsBypassed

Illuminates the yellow "Doors Bypassed" indicator.

#### ScreenSuppression

Illuminates the yellow "Suppression" indicator.

#### ScreenParkingBrake

Illuminates the yellow "Parking Brake Applied" indicator.

#### ScreenNoPowerbrake

Illuminates the red "No Power Brake" indicator.

#### ScreenFireSuppressionDisabled

Illuminates the red "Fire Suppression Disabled" indicator.

### Sounds

#### SpeedReductionAlert

Plays a single speed reduction beep sound that lasts for a couple of seconds.

#### SpeedIncreaseAlert

Plays a single, brief speed increase beep sound.

### Keyboard shortcuts

#### ATCCutIn

Toggles between 0 and 1 with Ctrl+D. Should not be set by Lua; otherwise the value will desync from the keyboard shortcut.

The default setting is 1.

#### ACSESCutIn

Toggles between 0 and 1 with Ctrl+F. Should not be set by Lua; otherwise the value will desync from the keyboard shortcut.

The default setting is 1.

## Lights

#### FrontCabLight

The forward cab dome light.

#### RearCabLight

The rear cab dome light.

#### Front_ConsoleLight_01

#### Front_ConsoleLight_02

#### Front_ConsoleLight_03

The forward cab console lights.

#### Rear_ConsoleLight_01

#### Rear_ConsoleLight_02

#### Rear_ConsoleLight_03

The rear cab console lights.

#### Front_DeskLight_01

#### Rear_DeskLight_01

The rear cab desk lights.

#### Spark1

The forward pantograph spark.

#### Spark2

The rear pantograph spark.

#### FrontDitchLightL

The forward left ditch light.

#### FrontDitchLightR

The forward right ditch light.

#### RearDitchLightL

The rear left ditch light.

#### RearDitchLightR

The rear right ditch light.

## Model nodes

#### PantoBsparkA

#### PantoBsparkB

#### PantoBsparkC

#### PantoBsparkD

#### PantoBsparkE

#### PantoBsparkF

The forward pantograph spark.

#### PantoAsparkA

#### PantoAsparkB

#### PantoAsparkC

#### PantoAsparkD

#### PantoAsparkE

#### PantoAsparkF

The rear pantograph spark.

#### ditch_fwd_l

The forward left ditch light.

#### ditch_fwd_r

The forward right ditch light.

#### ditch_rev_l

The rear ditch light.

#### ditch_rev_r

The rear right ditch light.