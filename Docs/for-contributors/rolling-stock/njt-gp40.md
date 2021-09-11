# NJ Transit GP40PH

The GP40PH is a diesel locomotive operated by NJ Transit.

## Controls

### Fuse panel

#### EngineStart

The engine start push button.

#### EngineStop

The emergency engine cutoff push button.

### Control stand

#### VirtualBrake

The train brake control, also operated by the ;/' keys and the HUD. Ranges from 0 to 1.

| Value | Meaning |
| --- | --- |
| 0.0 | Release |
| 0.0 < x < 0.5 | Graduated Self Lap |
| 0.5 ≤ x < 1.0 | Full Service |
| 1.0 | Emergency |

#### VirtualEngineBrakeControl

The engine brake control, also operated by the [/] keys and the HUD. Ranges from 0 to 1.

#### VirtualSander

The sander push button, also operated by the X key and the HUD.

#### VirtualBell

The bell push button, also operated by the B key and the HUD.

#### VirtualHorn

The horn plunger, also operated by the Spacebar and the HUD.

#### VirtualWipers

The wiper switch, also operated by the V key and the HUD.

#### InstrumentLights

The gauge lights switch, also operated by the I key.

#### DitchLights

The ditch lights knob. 0 = off, 1 = flash, 2 = full.

#### ApplicationPipe

The suppression brake pressure gauge, in psi.

#### SuppressionPipe

The suppression brake reservoir gauge, in psi.

#### VirtualThrottle

The throttle control, also operated by the A/D keys and the HUD. Ranges from 0 to 1.

#### UserVirtualReverser

The reverser control, also operated by the W/S keys and the HUD. Ranges from -1 to 1.

#### StepsLight

The steps light switch.

#### NumberLights

The number lights switch.

#### Headlights

The headlights knob, also operated by the H/Shift+H keys and the HUD. Ranges from 0 to 2.

### ADU

#### ACSES_Node

Illuminates the "SES" indicator light.

#### ATC_Node

Illuminates the "CSS" indicator light.

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

#### AWSReset

The safety systems acknowledge button, also operated by the Q key and shown on the HUD.

### Sounds

#### ACSES_Alert

Plays a continuous, rapid beep-beep sound.

#### ACSES_AlertIncrease

Plays a short upgrade tone.

#### ACSES_AlertDecrease

Plays a short downgrade tone.

#### AWSWarnCount

Plays an alarm whistle and illuminates the exclamation mark on the HUD.

### Keyboard shortcuts

#### ATC

The Ctrl+F ATC on/off toggle. The default state is 0.

#### ACSES

The Ctrl+D ACSES on/off toggle. The default state is 0.

#### CabLight

The L cab dome light toggle. The default state is 0.

#### DoorsManual

The Ctrl+Shift+T manual doors on/off toggle. The default state is 0.

#### DoorsManualClose

The Ctrl+T manual doors close button. Value resets to 0 after one frame.

#### VirtualStartup

The Z engine start/stop toggle. The default state is 1 (run).

#### Destination

Cycles up/down with the Ctrl+Shift+5 and Ctrl+Shift+6 keys.

| Value | Destination |
| --- | --- |
| 1 | Trenton |
| 2 | New York |
| 3 | Long Branch |
| 4 | Hoboken |
| 5 | Dover |
| 6 | Bay Head |

## Model nodes

#### ditch_front_left

#### ditch_front_right

#### ditch_rear_left

#### ditch_rear_right

The ditch light bulbs.

#### strobe_front_left

#### strobe_front_right

#### strobe_rear_left

#### strobe_rear_right

The strobe light bulbs.

#### lamp_on_left

#### lamp_on_right

The cab dome lamps (on the exterior model).

#### numbers_lit

The number board lights.

#### status_green

#### status_yellow

#### status_red

The brake indicator lights.

## Lights

#### DitchFrontLeft

#### DitchFrontRight

#### DitchRearLeft

#### DitchRearRight

The ditch lights.

#### StrobeFrontLeft

#### StrobeFrontRight

#### StrobeRearLeft

#### StrobeRearRight

The strobe lights.

#### CabLight

The cab dome light.

#### Steplight_FL

#### Steplight_FR

#### Steplight_RL

#### Steplight_RR

The step lights.

## Animations

#### Fans

Spins the exhaust fans.

## Emitters

#### Exhaust

#### Exhaust2

#### Exhaust3

The exhaust emitters.

## Consist messages

#### 10100

Communicates the currently displayed destination sign to the passenger coaches. The argument is the ID of the destination.
