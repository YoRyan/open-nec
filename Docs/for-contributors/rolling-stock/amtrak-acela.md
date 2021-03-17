# Amtrak Acela Express

The Acela Express is a high-speed electric trainset sold as a standalone addon to the New York to Philadelphia and New York to New Haven routes. Another version is distributed with the Washington to Baltimore route.

## Controls

### Left panel

#### SelPanto

The pantograph selection switch. 0 = front, 1 = both, 2 = rear. Note that the dial is not actually animated. Also, the dial will not snap to the intermediate "both" setting.

The default setting is 0.

#### PantographControl

The pantograph lower/raise switch. 0 = lower, 1 = raise. Note that the dial is not actually animated.

The default setting is 0.

#### CruiseControl

The cruise control switch. Turning this on illuminates the "cruise system" indicator.

The default setting is 0.

#### Handbrake

The handbrake dial. Setting this to the maximum illuminates the "parking brakes" indicator.

The default setting is 0.

#### Sander

The sander switch.

#### AutoBrakes

The "auto dynamic brakes" switch. Turning this on illuminates the "auto brakes" indicator.

The default setting is 0.

#### ScreenDer

The off/on switch for the righthand speedometer display.

The default setting is 1.

#### ScreenIzq

The off/on switch for the lefthand train status display.

The default setting is 1.

#### Dimmer

Turns on the control desk light. 0 = light off, 1 = light on.

The default setting is 0.

#### Reset

The "reset throttle/cruise" button.

#### TiltIsolate

The "tilt isolate" switch. Deactivating this also deactivates the "tilt system" indicator.

The default setting is 1.

#### EmergencyBrake

The emergency brake button.

### Control desk

#### Reverser

The player's Expert Mode reverser control. 1 = forward, 0 = neutral, -1 = reverse.

#### CruiseControlSpeed

The setting of the cruise control lever. Ranges from 0 to 160 mph.

#### VirtualThrottle

The player's Expert Mode throttle control. Ranges from 0 to 1.

#### Regulator

The true throttle control used by the physics model. Ranges from 0 to 1.

#### VirtualBrake

The player's Expert Mode train brake control. Ranges from 0 to 1.

| Value | Meaning |
| --- | --- |
| 1.0 | Emergency (applying) |
| 0.99 | Emergency |
| 0.8 | Handle off |
| 0.6 | Full service |
| 0.4 | Suppression |
| 0.2 | Minimum application |
| 0.0 | Release |

#### TrainBrakeControl

The true train brake control used by the physics model. Ranges from 0 to 1.

#### AWSReset

The acknowledgement plunger. On the Acela, this is *not* mapped to Q.

#### Startup

The engine on/off button. 1 = depressed (on), -1 = released (off).

The default setting is 1.

#### Headlights

The headlights dial. 0 = off, 1 = front headlights, 2 = rear headlights.

The default setting is 0.

#### GroundLights

The ground lights dial. 0 = off, 1 = fixed, 2 = flash.

The default setting is 0.

### Displays

#### ControlScreenIzq

Replaces the train status display with an Amtrak logo. Any value except 0 shows the logo.

The default setting is 0.

#### ControlScreenDer

Replaces the speedometer display with an Amtrak logo. Any value except 0 shows the logo.

The default setting is 0.

#### Doors

Sets the status of the "doors" indicator. 0 = extinguished, 1 = illuminated.

The default setting is 0.

#### Effort

Sets the positions of both tractive effort displays. Ranges from -80 to 160 lbs x 1000.

#### PantoIndicator

Sets the status of the "pantographs" indicator. -1 = neither pantograph up, 0 = front pantograph up, 1 = both pantographs up, 2 = rear pantograph up.

The default setting is 0.

#### LightsIndicator

Sets the status of the "lighting" indicator. -1 = off, 0 = headlights, 1 = headlights and ground lights, 2 = head lights and flashing ground lights.

The default setting is 0.

#### SpeedometerMPH

The position of the speedometer dial. This is not controlled by scripting.

#### SpeedoGuide

Number of digits to offset the speedometer number to center it on screen. 0 = no digits (for ones), 1 = one digit (for tens), 2 = two digits (for hundreds).

#### SPHundreds

The speedometer digit to display in the hundreds position. -1 to hide the digit.

#### SPTens

The speedometer digit to display in the tens position. -1 to hide the digit.

#### SPUnits

The speedometer digit to display in the ones position. -1 to hide the digit.

#### PowerState

The power setting to display in the green box.

| Value | Meaning |
| --- | --- |
| 0 | 0 |
| 1 | 1 |
| 2 | 2 |
| 3 | 3 |
| 4 | 4 |
| 5 | 5 |
| 6 | 6 |
| 8 | C |

All other values blank the box.

### Right panel

#### Horn

The horn plunger.

#### SigN

Controls the green lights on the upper cab signal head. Any value above 0.5 turns on the lights.

#### SigL

Controls the yellow lights on the upper cab signal head. Any value above 0.5 turns on the lights.

#### SigS

Controls the red lights on the upper cab signal head. Any value above 0.5 turns on the lights.

#### SigM

Controls the green lights on the lower cab signal head. Any value above 0.5 turns on the lights.

#### SigR

Controls the lunar lights on the lower cab signal head. Any value above 0.5 turns on the lights.

#### SignalSpeed

Sets the displayed signal speed limit. Only the following values are supported:

- 0
- 15
- 20
- 30
- 45
- 60
- 80

All other values will blank the display.

#### TSHundreds

The track speed digit to display in the hundreds place. -1 to hide the digit.

#### TSTens

The track speed digit to display in the tens place. -1 to hide the digit.

#### TSUnits

The track speed digit to display in the ones place. -1 to hide the digit.

#### MaximumSpeedLimitIndicator

Turns on one of the red squares next to the signal and track speed limit displays. -1 = both off, 0 = signal speed square on, 1 = track speed square on.

#### Wipers

The wipers switch.

#### FrontCone

The front hatch button. 0 = closed (released), 1 = open (depressed).

The default setting is 0.

#### Bell

The bell switch.

#### DestOnOff

The destination display off/on button.

The default setting is 0.

#### DestJoy

The destination display setting joystick. -1 = left, 0 = centered, 1 = right.

### Sounds

#### AWSWarnCount

Plays a British AWS warning horn and illuminates the exclamation mark on the HUD when set to 1.

#### AWSClearCount

Plays a British AWS informational tone when its value is changed.

### Keyboard shortcuts

#### ATCCutIn

Toggles between 0 and 1 with Ctrl+D. Should not be set by Lua; otherwise the value will desync from the keyboard shortcut.

The default setting is 0.

#### ACSESCutIn

Toggles between 0 and 1 with Ctrl+F. Should not be set by Lua; otherwise the value will desync from the keyboard shortcut.

The default setting is 0.

### Model nodes

#### Front_spark01

One of the white billboards for the front pantograph spark.

#### Front_spark02

One of the white billboards for the front pantograph spark.

#### Rear_spark01

One of the white billboards for the rear pantograph spark.

#### Rear_spark02

One of the white billboards for the rear pantograph spark.

### Lights

#### Spark

The blue light for the front pantograph spark.

#### Spark2

The blue light for the rear pantograph spark.

### Animations

#### frontPanto

Raises the front pantograph and its spark. Duration is 2 seconds.

#### rearPanto

Raises the rear pantograph and its spark. Duration is 2 seconds.

#### cone

Opens the nose cone that shrouds the front coupler. Duration is 2 seconds.

### Consist messages

#### 1209

Communicates the position of the tilt isolate control, to tell the coaches to tilt or not to tilt. The argument is its current setting.

#### 1210

Communicates the currently displayed destination sign to the passenger coaches. The argument is the ID of the destination:

| Argument | Destination |
| --- | --- |
| 1 | (blank) |
| 2 | Philadelphia |
| 3 | North Philadelphia |
| 4 | Holmesburg |
| 5 | Torresdale |
| 6 | Cornwell |
| 7 | Eddington |
| 8 | Croydon |
| 9 | Bristol |
| 10 | Levittown |
| 11 | Trenton |
| 12 | Hamilton |
| 13 | Princeton |
| 14 | Jersey Avenue | 
| 15 | New Brunswick |
| 16 | Edison |
| 17 | Metuchen |
| 18 | Metropark |
| 19 | Rahway |
| 20 | Linden |
| 21 | Elizabeth |
| 22 | North Elizabeth |
| 23 | Newark Liberty |
| 24 | Newark Penn |
| 25 | Harrison |
| 26 | Secaucus |
| 27 | New York Penn |

These are only available stations, even for the Washington to Baltimore version of the Acela.