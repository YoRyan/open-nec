# Metro-North Shoreliner Cab Car

The Shoreliner is a single-level coach operated by Metro-North. Its model includes a four-aspect cab signaling display, but not a speed limit indicator, meaning it can only support ATC.

## Controls

### Left panel

#### Headlights

The headlights switch. 0 = off, 1 = headlights, 2 = taillights.

#### PowerMode

The dual power mode switch. 0 = diesel, 1 = third rail.

#### Startup

The engine run switch. -1 = off, 1 = on.

#### AWSReset

The safety systems acknowledge button.

#### Power3rdRail

Illuminates or extinguishes the "electric mode not available" lamp.

### Control stand

#### Reverser

The reverser key. -1 = reverse, 0 = neutral, 1 = forward.

#### VirtualThrottle

The throttle lever. Ranges from 0 to 1, with 8 detents.

#### Regulator

The true throttle state, which is transmitted to helper units. Ranges from 0 to 1.

#### DynamicBrake

The true dynamic brake position used by the physics model. Ranges from 0 to 1.

#### Horn

The horn plunger.

#### TrainBrakeControl

The air brake control. Ranges from 0 to 1.

| Value | Meaning |
| --- | --- |
| 1 | Emergency |
| 0.51 | Full Service |
| 0.01 | Graduated Self Lap |
| 0 | Release |

### Right panel

#### Sander

The sander button.

#### EmergencyBrake

The emergency brake button. Seems to be under the purview of another simulation script.

#### Wipers

The wipers button.

#### Bell

The bell button.

#### SigN

The "N" cab signal lamp.

#### SigL

The "L" cab signal lamp.

#### SigM

The "M" cab signal lamp.

#### SigR

The "R" cab signal lamp.

#### SpeedoUnits

The ones digit of the digital speedometer.

#### SpeedoTens

The tens digit of the digital speedometer.

#### SpeedoHundreds

The hundreds digit of the digital speedometer.

### Miscellaneous

#### Window Left

The position of the left window. Ranges from 0 to 1.

#### Window Right

The position of the right window. Ranges from 0 to 1.

#### AWSWarnCount

Illuminates the exclamation mark icon on the HUD.

### Sounds

#### AWS

Plays a continuous beep-beep warning sound.

#### SpeedReductionAlert

Plays a single electronic warning chrip.

#### SpeedIncreaseAlert

Plays a short electronic upgrade chirp.

### Keyboard shortcuts

#### ATCCutIn

The Ctrl+D ATC cut in toggle. Defaults to 1 (cut in).

#### ACSESCutIn

The Ctrl+F ACSES cut in toggle. Defaults to 1 (cut in).

#### CabLight

The L cab dome light toggle.

#### ExpertPowerMode

The Ctrl+Shift+A automatic power change toggle. Defaults to 0 (off).

## Lights

#### CabLight

The cab dome light.

## Model nodes

#### ditch_left

#### ditch_right

The ditch lights.

#### brakelight

The red status lights on both sides of the coach.

## Animations

#### LeftWindow

#### RightWindow

Moves the cab windows on the exterior model. The transition time is 2 seconds.