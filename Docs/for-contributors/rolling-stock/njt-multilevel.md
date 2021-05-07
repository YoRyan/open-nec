# NJ Transit/MARC Multilevel Cab Car

The Bombardier Multilevel is a bilevel coach operated by NJ Transit and MARC. As Dovetail Games was unable to obtain a MARC license, the MARC version is unbranded. Both variants include an NJ Transit-style cab signaling display.

## Controls

### Control desk

#### ThrottleAndBrake

The combined power and dynamic braking lever. Ranges from -1 to 1. Negative values apply dynamic braking, while positive values apply power.

#### UserVirtualReverser

The player's Expert Mode reverser lever. -1 = reverse, 0 = neutral, 1 = forward.

#### Reverser

The true reverser used by the physics model. -1 = reverse, 0 = neutral, 1 = forward.

#### VirtualHorn

The horn plunger.

The default position is 0.

#### Horn

Sounds the horn.

#### VirtualBrake

The player's Expert Mode train brake lever. Ranges from 0 to 1.

| Value | Meaning |
| --- | --- |
| 1 | Emergency |
| 0.8 | Handle off |
| 0.6 | Service |
| 0.4 | Lap |
| 0.2 | E-hold |
| 0 | Release |

#### TrainBrakeControl

The true train brake setting used by the physics model.

### Left panel

#### Sander

When set, the "Sanding" indicator illuminates.

#### HEP_State

Turns on the "HEP On" indicator.

#### PantographControl

When set to 0, the "Pantograph Down" indicator illuminates. When set to 1, the "Pantograph Up" indicator illuminates.

#### Handbrake

When set, the "Handbrake" indicator illuminates.

#### VirtualBell

The bell button.

The default position is 0.

#### Bell

Sounds the bell.

### Dashboard

#### AWSReset

The safety systems acknowledge button.

The default position is 0.

#### Speed2H

Sets the black hundreds digit on the speedometer display. -1 hides the digit.

#### Speed2T

Sets the black tens digit on the speedometer display. -1 hides the digit.

#### Speed2U

Sets the black ones digit on the speedometer display. -1 hides the digit.

#### SpeedH

Sets the green hundreds digit on the speedometer display. -1 hides the digit.

#### SpeedT

Sets the green tens digit on the speedometer display. -1 hides the digit.

#### SpeedU

Sets the green ones digit on the speedometer display. -1 hides the digit.

#### SpeedP

Moves the speedometer digits 0, 1, or 2 places over to compensate for a smaller number.

#### ACSES_SpeedGreen

Sets the green region of the circular speed limit bar. Ranges from 0 to 120 mph.

#### ACSES_SpeedRed

Sets the red region of the circular speed limit bar. Ranges from 0 to 120 mph.

### Right panel

#### PantographSwitch

The pantograph up/down switch. -1 = down, 0 = neutral, 1 = up.

The default position is 0.

#### InstrumentLights

The air gauge lights switch.

The default position is 0.

#### CabLight

The cab light switch.

The default position is 0.

#### VirtualWipers

The wiper switch.

The default position is 0.

#### Wipers

Turns on the wipers.

#### VirtualSander

The sander switch.

The default position is 0.

#### HeadlightSwitch

The headlight switch. 0 = off, 1 = dim, 2 = bright.

The default position is 0.

#### Headlights

Sets the current configuration of the headlights. 0 = off, 1 = tail lights, 2 = dim headlights, 3 = bright headlights.

### Sounds

#### ACSES_Alert

Plays a continuous beep-beep sound.

#### ACSES_AlertIncrease

Plays a brief speed upgrade sound.

#### ACSES_AlertDecrease

Plays a brief speed downgrade sound.

## Lights

#### Ditch_L

The left ditch light.

#### Ditch_R

The right ditch light.

#### CabLight

#### CabLight2

The cab dome light.

## Model nodes

#### ditch_left

The left ditch light.

#### ditch_right

The right ditch right.

#### cablights

The cab dome light.

#### LightsYellow

The yellow coach status light.

#### LightsBlue

The blue coach status light.

#### LightsGreen

The green coach status light.

#### LightsRed

The red coach status light.

#### NumberLights

The number plate lights.

## Animations

#### Doors_L

#### Doors_R

Opens the passenger boarding doors. The durations are 1 second long.