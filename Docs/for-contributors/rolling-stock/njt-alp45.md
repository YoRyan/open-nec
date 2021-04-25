# NJ Transit ALP-45DP

The Bombardier ALP-45DP is a dual-mode locomotive used by NJ Transit to provide direct service from the unelectrified portions of its network to New York Penn Station.

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

#### DeskLight

The desk light click toggle, also operated by the Ctrl+L key. 0 = off, 1 = on.

#### VirtualHorn

The horn plunger, also operated by the Spacebar. Plays the beginning of the horn sequence.

#### Horn

Plays the continuous horn sequence.

#### FaultReset

The fault reset button.

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

#### Wipers

When set to 1, the wipers move and complete one cycle. Resets back to 0 after the animation completes.

#### SanderSwitch

The model position for the sander switch. Ranges from -1 to 1.

#### VirtualSander

The sander click toggle, also operated by the X key.

#### Sander

The true sander state used by the physics model.

#### BellSwitch

The model position for the bell switch. Ranges from -1 to 1.

#### VirtualSander

The bell click toggle, also operated by the B key.

#### Bell

The true bell state used by the physics model.

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

#### AWSReset

The safety systems acknowledge button.

### Indicators

#### SpeedH

The hundreds digit on the speedometer display. -1 hides the digit.

#### SpeedT

The tens digit on the speedometer display. -1 hides the digit.

#### SpeedU

The ones digit on the speedometer display. -1 hides the digit.

#### ACSES_SpeedH

The hundreds digit on the ACSES speed limit display. -1 hides the digit.

#### ACSES_SpeedT

The tens digit on the ACSES speed limit display. -1 or 0 hides the digit.

#### ACSES_SpeedU

The ones digit on the ACSES speed limit display. The only valid values are 0, 5, and -1 (which hides the digit).

#### ACSES_SignalDisplay

The signal speed limit display.

| Value | Meaning |
| --- | --- |
| 8 | Stop |
| 7 | Restricting |
| 6 | Approach |
| 5 | 30 mph |
| 4 | 45 mph |
| 3 | 60 mph |
| 2 | 80 mph |
| 1 | MAS |

All other values extinguish all lamps.

#### ATC_Node

The ATC indicator light.

#### ATC_CutOut

The ATC cut out light.

#### ACSES_Node

The ACSES indicator light.

#### ACSES_CutOut

The ACSES cut out light.

#### ACSES_CutIn

The ACSES cut in light.

### Miscellaneous

#### VirtualEmergencyBrake

The emergency brake lever.

#### EmergencyBrake

The true emergency brake state used by the physics model.

#### FuelPump

The fuel pump indicator light.

#### HEP

The HEP switch. The default state is 1 (on).

### Keyboard shortcuts

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

#### PowerSwitch

The Y change power button. Value resets to 0 after one frame.

#### PowerSwitchAuto

The Ctrl+Y automatic power change toggle. The default state is 0 (off).

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

#### ditch_left

#### ditch_right

The ditch lights.

#### LightsYellow

#### LightsBlue

#### LightsGreen

The external brake indicator lights.

## Lights

#### CabLight

The cab dome light.

#### DeskLight

The control desk light.

#### DitchLight_Left

#### DitchLight_Right

The ditch lights.

## Animations

#### Pantograph

Raises the pantograph. The duration is 2 seconds.

#### Fans

Spins the exhaust fans.

## Consist messages

#### 10100

Communicates the currently displayed destination sign to the passenger coaches. The argument is the ID of the destination.

## Emitters

#### Exhaust1

#### Exhaust2

#### Exhaust3

#### Exhaust4

Diesel engine exhaust.