# NJ Transit Arrow III

The Arrow III is an electric multiple unit operated by NJ Transit.

## Controls

### Ceiling

#### StepsLight

The step lights switch.

#### CabLight

The cab dome light switch.

### Left panel

#### PantoOn

The pantograph raise button.

#### PantographControl

The true pantograph raise control, operated by the P key and shown on the HUD.

#### Wipers

The wiper knob, also operated by the V key and shown on the HUD.

#### Headlights

The headlights knob, also operated by the H/Shift+H keys and shown on the HUD.

### Control stand

#### VirtualThrottle

The master controller. Ranges from -5 to 5.

| Value | Meaning |
| --- | --- |
| -5.0 | Reverse P-3 |
| -4.0 | Reverse P-2 |
| -3.0 | Reverse P-1 |
| -2.0 | Reverse Switch |
| -1.0 | Reverse Off |
| 0.0 | Safety |
| 1.0 | Forward Off |
| 2.0 | Forward Switch |
| 3.0 | Forward P-1 |
| 4.0 | Forward P-2 |
| 5.0 | Forward P-3 |

#### Regulator

The true throttle value used by the physics model. Ranges from 0 to 1.

#### VirtualDynamicBrake

The dynamic brake control, operated by the ,/. keys and shown on the HUD. Ranges from 0 to 1.

#### DynamicBrake

The true dynamic brake value used by the physics model. Ranges from 0 to 1.

#### Reverser

The true reverser state used by the physics model. Ranges from -1 to 1.

#### Horn

The horn switch, also operated by the Spacebar and shown on the HUD.

#### VirtualBrake

The air brake lever, also operated by the ;/' keys and shown on the HUD. Ranges from 0 to 1.

#### TrainBrakeControl

The true air brake value used by the physics model. Ranges from 0 to 1.

| Value | Meaning |
| --- | --- |
| 0.0 | Release |
| 0.0 < x < 0.5 | Graduated Self Lap |
| 0.5 ≤ x < 1.0 | Full Service |
| 1.0 | Emergency |

### Right panel

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

### Doors and windows

#### Left_CabDoor

The position of the left door. Ranges from 0 to 1.

#### Right_CabDoor

The position of the right door. Ranges from 0 to 2.

#### CabWindow

The position of the right door window. Ranges from 0 to 1.

### Sounds

#### ACSES_Alert

Plays a continuous, rapid beep-beep sound.

#### ACSES_AlertIncrease

Plays a short upgrade tone.

#### ACSES_AlertDecrease

Plays a short downgrade tone.

### Keyboard shortcuts

#### AWSWarnCount

The exclamation mark indicator on the HUD.

#### ATC

The Ctrl+F ATC on/off toggle. The default state is 0.

#### ACSES

The Ctrl+D ACSES on/off toggle. The default state is 0.

#### InstrumentLights

The air pressure gauge lights, operated by the I key.

## Model nodes

#### ditch

The ditch light bulbs.

#### lighthead

The headlight bulbs.

#### lighttail

The taillight bulbs.

#### numbers_lit

Illuminates the car number backboard.

#### st_red

The red brake indicator light.

#### st_green

The green brake indicator light.

#### st_yellow

The yellow brake indicator light.

#### left_door_light

#### right_door_light

The door open indicator lights.

## Lights

#### StepLight_01

#### StepLight_02

#### StepLight_03

#### StepLight_04

The step lights.

#### CabLight

The cab dome light.

#### Ditch_L

#### Ditch_R

The ditch lights.

#### Headlight_Dim_1

#### Headlight_Dim_2

The headlights in the dim state.

#### Headlight_Bright_1

#### Headlight_Bright_2

The headlights in the bright state.

#### MarkerLight_1

#### MarkerLight_2

#### MarkerLight_3

The number board lights.

## Animations

#### panto

On A cars, raises the pantograph. The duration is 0.5 seconds.

#### left_cabdoor

#### right_cabdoor

Opens the cab doors. The duration is 2 seconds.

#### cabwindow

Opens the right cab door window. The duration is 2 seconds.