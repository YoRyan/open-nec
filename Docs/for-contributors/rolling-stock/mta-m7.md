# Metro-North M7

The Bombardier M7 is an electric multiple-unit that serves Metro-North's Hudson Line and the Long Island Rail Road.

## Controls

### Left panel

#### Headlights

The headlights dial. 0 = off, 1 = headlights, 2 = taillights.

#### GaugeLight

The gauge lights toggle. Defaults to 0 (off).

#### Cablight

The cab ceiling light switch. Defaults to 0 (off).

#### Wipers

The wipers switch. Defaults to 0 (off).

#### Horn

The horn plunger, which activates the horn.

### Control desk

#### AWSReset

The safety systems acknowledge button.

#### Reverser

The reverser control. -1 = reverse, 0 = neutral, 1 = forward.

The default position is neutral.

#### ThrottleAndBrake

The combined power and brake handle. Values range from -1 to 1; negative values apply braking, while positive values apply power.

The default position is 20% braking.

#### SigN

Illuminates the "N" cab signal aspect lamp.

#### SigL

Illuminates the "L" cab signal aspect lamp.

#### SigM

Illuminates the "M" cab signal aspect lamp.

#### SigR

Illuminates the "R" cab signal aspect lamp.

### Displays

#### Cars

Number of additional multiple units to display on the operating screen behind the driving one. Ranges from 0 to 7.

#### Doors_2

#### Doors_3

#### Doors_4

#### Doors_5

#### Doors_6

#### Doors_7

#### Doors_8

Sets the door indicators of the trailing multiple units. -1 left doors open, 0 = no doors open, 1 = right doors open.

Note that every other multiple unit is flipped, so the positions of the doors also alternate.

#### Motor_2

#### Motor_3

#### Motor_4

#### Motor_5

#### Motor_6

#### Motor_7

#### Motor_8

Sets the motor indicators of the trailing multiple units. -1 = braking, 0 = coasting, 1 = applying power.

#### SpeedoHundreds

Sets the hundreds digit on the speedometer. 0 hides the digit.

#### SpeedoTens

Sets the tens digit on the speedometer. -1 hides the digit.

#### SpeedoUnits

Sets the ones digit on the speedometer.

#### SpeedoGuide

Number of digits to offset the speedometer number to center it on screen. 0 = no digits (for ones), 1 = one digit (for tens), 2 = two digits (for hundreds).

#### PipeHundreds

Sets the hundreds digit on the BP pressure indicator. 0 hides the digit.

#### PipeTens

Sets the tens digit on the BP pressure indicator. -1 hides the digit.

#### PipeUnits

Sets the ones digit on the BP pressure indicator.

#### PipeGuide

Number of digits to offset the BP number to center it on screen. 0 = no digits (for ones), 1 = one digit (for tens), 2 = two digits (for hundreds).

#### CylinderHundreds

Sets the hundreds digit on the BC pressure indicator. 0 hides the digit.

#### CylinderTens

Sets the tens digit on the BC pressure indicator. -1 hides the digit.

#### CylinderUnits

Sets the ones digit on the BC pressure indicator.

#### CylGuide

Number of digits to offset the BC number to center it on screen. 0 = no digits (for ones), 1 = one digit (for tens), 2 = two digits (for hundreds).

#### PenaltyIndicator

The penalty brake status indicator.

#### DoorsState

The door status indicator. 0 = doors closed, 1 = doors open.

#### AWS

The alerter status indicator.

### Sounds

#### SpeedIncreaseAlert

Plays a short electronic chirp.

#### SpeedReductionAlert

Plays a continuous beep-beep warning sound.

#### AWSWarnCount

Plays a continuous whoop-whoop warning sound and illuminates the exclamation mark on the HUD.

#### FanSound

Plays a low, droning sound. The volume is scaled from 0 to 1.

## Keyboard shortcuts

#### ATCCutIn

The Ctrl+D ATC cut in toggle. Defaults to 1 (cut in).

### ACSESCutIn

The Ctrl+F ACSES cut in toggle. Defaults to 1 (cut in).

## Lights

#### Cablight

The cab dome light.

#### RoomLight_PassView

#### HallLight_001

#### HallLight_002

The passenger cabin lights.

## Model nodes

#### SL_green

The green marker light.

#### SL_yellow

The yellow marker light.

#### SL_blue

The blue marker light.

#### SL_doors_L

The lefthand door indicator lights.

#### SL_doors_R

The righthand door indicator lights.

## Animations

#### ribbons

Extends the pantograph gate that connects to another car on the front end. The duration is 1 second.