# NJ Transit Comet V Cab Car

The Comet V is a single-level coach operated by NJ Transit. It includes an NJ Transit-style cab signaling display. The Comet V is equipped with cab signaling, ATC, and (unlike the Comet IV cab car) ACSES.

## Controls

### Control desk

#### DitchLightSwitch

The crossing lights switch. 0 = off, 1 = manual, 2 = auto.

#### HeadlightSwitch

The headlights switch. 0 = off, 1 = dim, 2 = full.

#### ThrottleAndBrake

The player's combined power and brake handle. -1 = full dynamic brake, 0 = coast, 1 = full power.

#### Regulator

The true throttle position used by the physics model. Ranges from 0 to 1.

#### DynamicBrake

The true dynamic brake position used by the physics model. Ranges from 0 to 1.

#### UserVirtualReverser

The player's reverser control. -1 = reverse, 0 = neutral, 1 = forward.

#### Reverser

THe true reverser position used by the physics model.

#### VirtualHorn

The player's horn control.

#### VirtualBrake

The player's train brake lever. Ranges from 0 to 1.

| Value | Meaning |
| --- | --- |
| 1 | Emergency |
| 0.8 | Handle off |
| 0.6 | Service |
| 0.4 | Lap |
| 0.2 | E-hold |
| 0 | Release |

#### TrainBrakeControl

The true train brake position used by the physics model.

#### VirtualSander

The sander plunger.

#### Sander

The true sander state used by the physics model. Also illuminates the "Sanding" indicator light.

### Dashboard

#### AWSReset

The safety systems acknowledge button.

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

#### ACSES_Node

Illuminates the "SES" indicator light.

#### ATC_Node

Illuminates the "CSS" indicator light.

### Left panel

#### HEP_State

Illuminates the "HEP On" indicator light.

#### Handbrake

When set, the "Handbrake" indicator illuminates.

#### FaultReset

The fault reset button.

#### InstrumentLights

The instrument lights switch.

#### VirtualBell

The player's bell button.

### Upper panel

#### EmergencyBrake

The emergency brake pull cord.

#### CabLight

The cab dome light switch.

#### VirtualWipers

The player's wipers control.

#### Wipers

The true wipers state used by the model.

#### PantographSwitch

The pantograph switch. Ranges from -1 to 1. Note that although the control is clickable, it is not animated.

#### UN_thousands

The thousands digit in the unit number.

#### UN_hundreds

The hundreds digit in the unit number.

#### UN_tens

The tens digit in the unit number.

#### UN_units

The ones digit in the unit number.

### Sounds

#### Horn

Sounds the horn.

#### Bell

Rings the bell.

#### AWS

Plays a continuous beep-beep sound.

### Keyboard shortcuts

#### DitchLights

The J ditch lights toggle.

#### Headlights

The H/Shift+H headlights toggle. 0 = off, 1 = tail lights, 2 = dim, 3 = bright.

#### VirtualPantographControl

The P pantograph toggle. 0 = down, 1 = up.

#### AWSWarnCount

Illuminates the exclamation mark on the HUD.

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

## Animations

#### Doors_L

#### Doors_R

Opens the passenger boarding doors. The durations are 2 seconds long.