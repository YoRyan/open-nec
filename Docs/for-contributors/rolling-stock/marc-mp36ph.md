# MARC MP36PH

The MPI MP36PH is a diesel locomotive included with the Washington to Baltimore route. As Dovetail Games was unable to obtain a MARC license, the locomotive is unbranded. It includes a cab signaling display.

## Controls

### Secondman's desk

#### EmergencyBrake

The emergency brake lever.

The default position is 0.

### Left panel

#### Sander

The sander button.

The default position is 0.

#### Rearlights

The rear headlights dial. 0 = off, 1 = dim, 2 = bright.

The default position is 0.

#### Headlights

The forward headlights dial. 0 = off, 0.44 = dim, 1.49 = bright, 3 = bright with crossing light.

The default position is 0.

#### DitchLights

The crossing light pulse button.

The default position is 0.

### Control desk

#### Horn

The horn plunger.

The default position is 0.

#### Bell

The bell button.

The default position is 0.

#### Reverser

The reverser. -1 = reverse, 0 = neutral, 1 = forward.

The default position is 0.

#### ThrottleAndBrake

The combined throttle and dynamic brake lever. Ranges from -1 to 1.

| Value | Meaning |
| --- | --- |
| <0 | Dynamic brake |
| 0 | Coast |
| 0.125 | Notch 1 |
| 0.25 | Notch 2 |
| 0.375 | Notch 3 |
| 0.5 | Notch 4 |
| 0.625 | Notch 5 |
| 0.75 | Notch 6 |
| 0.875 | Notch 7 |
| 1 | Notch 8 |

#### VirtualBrake

The player's Expert Mode train brake control. Ranges from 0 to 1.

#### TrainBrakeControl

The true train brake control used by the physics model. Ranges from 0 to 1.

#### VirtualEngineBrakeControl

The player's Expert Mode independent (locomotive) brake control. Ranges from 0 to 1.

#### EngineBrakeControl

The true independent brake control used by the physics model. Ranges from 0 to 1.

#### AWSReset

The safety systems acknowledge button.

The default position is 0.

### Instruments

#### SpeedoDots

Turns on the circular dots on the speedometer. Ranges from 0 (0 mph) to 60 (120 mph).

#### SpeedoHundreds

Sets the hundreds digit on the speedometer number. 0 hides the digit.

#### SpeedoTens

Sets the tens digit on the speedometer number. -1 hides the digit.

#### SpeedoUnits

Sets the ones digit on the speedometer number.

#### SigN

Turns on the green lights on the upper cab signal aspect head.

#### SigL

Turns on the yellow lights on the upper cab signal aspect head.

#### SigS

Turns on the red lights on the upper cab signal aspect head.

#### SigM

Turns on the green lights on the lower cab signal aspect head.

#### SigR

Turns on the lunar lights on the lower cab signal aspect head.

#### SignalSpeed

Sets the displayed signal speed limit. Only the following values are supported:

- 15
- 20
- 30
- 45
- 60
- 80

All other values will blank the display.

#### TSHundreds

Sets the hundreds digit on the track speed limit display. 0 hides the digit.

#### TSTens

Sets the tens digit on the track speed limit display.

#### TSUnits

Sets the ones digit on the track speed limit display. -1 hides the digit.

#### MaximumSpeedLimitIndicator

Illuminates one of the squares next to the signal speed and track speed limits. -1 = neither square, 0 = signal speed square, 1 = track speed square.

### Overhead panel

#### GaugeLights

The gauge lights switch.

The default position is 0.

#### HEP

The HEP on button.

The default position is 1.

#### HEP_Off

The HEP off button.

The default position is 1.

#### Wipers_02

The center-right pane wiper switch.

The default position is 0.

#### Wipers_01

The right pane wiper switch.

The default position is 0.

### Sounds

#### TMS

Plays a continuous beeping sound.

## Lights

#### Cablight

The cab dome light.

#### Headlight_01_Bright

#### Headlight_02_Bright

The bright set of headlights.

#### Headlight_01_Dim

#### Headlight_02_Dim

The dim set of headlights.

#### Ditch_L

The left ditch light.

#### Ditch_R

The right ditch light.

#### Rearlight_01_Bright

#### Rearlight_02_Bright

The bright set of rear lights.

#### Rearlight_01_Dim

#### Rearlight_02_Dim

The dim set of rear lights.

#### Carriage Light 1

#### Carriage Light 2

#### Carriage Light 3

#### Carriage Light 4

#### Carriage Light 5

#### Carriage Light 6

#### Carriage Light 7

#### Carriage Light 8

The trailing carriage lights when powered by HEP.

## Model nodes

#### ditch_left

The left ditch light.

#### ditch_right

The right ditch light.

#### lights_dim

Should be turned on when the ditch lights are on.

#### 1_1000_LitInteriorLights

Should be turned on when HEP is available.