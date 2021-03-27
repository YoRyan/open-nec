# Metro-North M8

The Kawasaki M8 is an electric multiple-unit that serves Metro-North's New Haven Line. It is also proposed to run to Penn Station as part of the Penn Station Access project.

## Controls

### Left panel

#### Cablight

The cab dome light switch.

#### Wipers

The wipers switch, which activates the wiper sequence.

#### Headlights

The headlights switch, which controls the model headlights. 0 = off, 1 = headlights, 2 = taillights.

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

Illuminates the "N" signal cab aspect lamp.

#### SigL

Illuminates the "L" signal cab aspect lamp.

#### SigM

Illuminates the "M" signal cab aspect lamp.

#### SigR

Illuminates the "R" signal cab aspect lamp.

#### SigS

Illuminates the "S" signal cab aspect lamp.

#### SignalSpeed

Sets the displayed signal speed limit. Only the following speeds are supported:

- 0
- 15
- 30
- 45

All other values will blank the display.

#### TrackSpeedHundreds

Sets the hundreds digit on the track speed limit display. 0 hides the digit.

#### TrackSpeedTens

Sets the tens digit on the track speed limit display. -1 hides the digit.

#### TrackSpeedUnits

Sets the ones digit on the track speed limit display. -1 hides the digit.

#### ATCCutIn

The status of the ATC cut in/out lamps, which reflect the state of Ctrl-D, the ATC cut in/out keyboard toggle.

The default position is 1 (cut in).

### Right panel

#### Panto

The mode of operation switch. 0 = AC pantograph down, 1 = AC pantograph up, 2 = DC mode.

The default position is AC pantograph down.

#### PantographControl

The energy on/off switch, which when turned on also illuminates the "line" lamp.

The default position is 1.

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

#### PipeHundreds

Sets the hundreds digit on the BP pressure indicator. 0 hides the digit.

#### PipeTens

Sets the tens digit on the BP pressure indicator. -1 hides the digit.

#### PipeUnits

Sets the ones digit on the BP pressure indicator.

#### CylinderHundreds

Sets the hundreds digit on the BC pressure indicator. 0 hides the digit.

#### CylinderTens

Sets the tens digit on the BC pressure indicator. -1 hides the digit.

#### CylinderUnits

Sets the ones digit on the BC pressure indicator.

#### PowerAC

Sets the AC power indicator. 0 = unlit, 1 = yellow, 2 = green.

#### PowerDC

Sets the DC power indicator. 0 = unlit, 1 = yellow, 2 = green.

#### AWS

Illuminates the alerter indicator and plays a continuous beeping sound.

### Sounds

#### SpeedIncreaseAlert

Plays a short electronic chirp.

#### SpeedReductionAlert

Plays an electronic warning tone for a couple of seconds.

#### FanSound

Plays a low, droning sound. The volume is scaled from 0 to 1.

## Keyboard shortcuts

#### ACSESCutIn

The status of the Ctrl-F ACSES cut in/out keyboard toggle. (ACSES cut in/out lamps are present in the model, but not functional.)

The default position is 1.