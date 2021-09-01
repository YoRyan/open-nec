# NJ Transit ALP-46

The Bombardier ALP-46 is an electric locomotive used by NJ Transit.

## Controls

### Control desk

#### HeadlightSwitch

The headlight switch. Ranges from -1 to 1.

#### DitchLightsSwitch

The model position for the ditch lights switch. Ranges from -1 to 1.

#### DitchLights

The ditch lights click toggle, also operated by the J key. 0 = off, 1 = on.

#### CabLightSwitch

The model position for the cab light switch. Ranges from -1 to 1.

#### CabLight

The cab light click toggle, also operated by the L key. 0 = off, 1 = on.

#### InstrumentLightsSwitch

The model position for the instrument lights switch. Ranges from -1 to 1.

#### InstrumentLights

The instrument lights click toggle, also operated by the I key. 0 = off, 1 = on.

#### DeskLightSwitch

The model position for the desk light switch. Ranges from -1 to 1.

#### FaultReset

The fault reset button.

#### VirtualHorn

The horn plunger, also operated by the Spacebar.

#### Horn

Plays the horn sound.

#### ThrottleAndBrake

The combined power and brake handle.

#### Regulator

The true throttle value used by the physics model.

#### DynamicBrake

The true dynamic braking value used by the physics model.

#### Reverser

The reverser lever. -1 = reverse, 0 = neutral, 1 = forward.

#### WipersSwitch

The model position for the wipers switch. Ranges from -1 to 1.

#### VirtualWipers

The wipers click toggle, also toggled with the V key.

#### WipersInterior

Sets the relative position of the interior wipers. Ranges from 0 to 1.

#### SanderSwitch

The model position for the sander switch. Ranges from -1 to 1.

#### VirtualSander

The sander click toggle, also operated by the X key.

#### Sander

The true sander state used by the physics model.

#### BellSwitch

The model position for the bell switch. Ranges from -1 to 1.

#### VirtualBell

The bell click toggle, also operated by the B key.

#### Bell

The true bell state used by the physics model.

#### VirtualBell

The bell click toggle, also operated by the B key. Plays the bell sound.

#### HandbrakeSwitch

The handbrake switch. Ranges from -1 to 1.

#### PantographSwitch

The pantograph switch. Ranges from -1 to 1.

#### VirtualBrake

The player's Expert Mode train brake control. Ranges from 0 to 1.

| Value | Meaning |
| --- | --- |
| 1.0 | Emergency |
| 0.8 | Handle off |
| 0.6 | Service |
| 0.4 | Lap |
| 0.2 | E-Hold |
| 0.0 | Release |

#### TrainBrakeControl

The true train brake control used by the physics model. Ranges from 0 to 1.

#### VirtualEngineBrakeControl

The player's independent brake control. Ranges from 0 to 1.

#### EngineBrakeControl

The true independent brake control used by the physics model. Ranges from 0 to 1.

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

### Sounds

#### ACSES_Alert

Plays a continuous, rapid beep-beep sound.

#### ACSES_AlertIncrease

Plays a short upgrade tone.

#### ACSES_AlertDecrease

Plays a short downgrade tone.

#### ExteriorSounds

Plays some background noise.

### Miscellaneous

#### VirtualEmergencyBrake

The emergency brake lever.

#### EmergencyBrake

The true emergency brake state used by the physics model.

#### UnitT

#### UnitU

Sets the digits of the unit number in the center pillar. The "46-" digits at the beginning of the number are static textures.

#### WindowLeft

#### WindowRight

The positions of the openable windows, from 0 (closed) to 1 (open).

### Keyboard shortcuts

#### AWSWarnCount

The exclamation mark indicator on the HUD.

#### ATC

The Ctrl+F ATC on/off toggle. The default state is 0.

#### ACSES

The Ctrl+D ACSES on/off toggle. The default state is 0.

#### DoorsManual

The Ctrl+Shift+T manual doors on/off toggle. The default state is 0.

#### DoorsManualClose

The Ctrl+T manual doors close button. Value resets to 0 after one frame.

#### WipersInt

The Ctrl+V interminnent wipers toggle. The default state is 0.

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

#### FrontDitchLights

#### RearDitchLights

The ditch lights.

## Lights

#### CabLight1

#### CabLight2

#### CabLight3

#### CabLight4

The cab dome lights.

#### ForwardDitch1

The right-forward ditch light.

#### ForwardDitch2

The left-forward ditch light.

#### BackwardDitch1

The right-backward ditch light.

#### BackwardDitch2

The left-backward ditch light.

#### FDialLight01

#### FDialLight02

#### FDialLight03

#### FDialLight04

The lights for the front brake reservoir pressure gauge.

#### FBDialLight01

#### FBDialLight02

#### FBDialLight03

#### FBDialLight04

The lights for the front brake cylinder pressure gauge.

#### RDialLight01

#### RDialLight02

#### RDialLight03

#### RDialLight04

The lights for the rear brake reservoir pressure gauge.

#### RBDialLight01

#### RBDialLight02

#### RBDialLight03

#### RBDialLight04

The lights for the rear brake cylinder pressure gauge.

## Animations

#### Pantograph1

Raises the front pantograph.

#### Pantograph2

Raises the rear pantograph.

#### WipersFront

Operates the front cab wipers on the exterior model.

#### WipersRear

Operates the rear cab wipers on the exterior model.

## Consist messages

#### 10100

Communicates the currently displayed destination sign to the passenger coaches. The argument is the ID of the destination.
