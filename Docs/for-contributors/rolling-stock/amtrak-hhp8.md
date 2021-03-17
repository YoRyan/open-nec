# Amtrak HHP-8

The Bombardier HHP-8 is a high-horsepower electric locomotive sold as a separate addon to the New York to Philadelphia and New York to New Haven routes. Its styling is intentionally similar to that of the Acela's.

## Controls

### Left panel

#### SelPanto

The pantograph selection switch. 0 = front, 1 = both, 2 = rear.

The default setting is 0.

#### PantographControl

The pantograph lower/raise switch. 0 = lower, 1 = raise.

The default setting is 1.

#### CruiseControl

The cruise control switch. Turning this on illuminates the "cruise system" indicator.

The default setting is 0.

#### Wipers

The wiper off/on switch.

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

#### EmergencyBrake

The emergency brake button.

### Control desk

#### Reverser

The player's Expert Mode reverser control. 1 = forward, 0 = neutral, -1 = reverse.

#### SpeedSetControl

The setting of the cruise control lever. Ranges from 0.0 (0 mph) to 16.0 (160 mph).

#### VirtualThrottle

The player's Expert Mode throttle control. Ranges from 0 to 1.

#### Regulator

The true throttle control used by the physics model. Ranges from 0 to 1.

#### TrainBrakeControl

The player's Expert Mode train brake control. Ranges from 0 to 1.

| Value | Meaning |
| --- | --- |
| 1.0 | Emergency |
| 0.8 | Handle off |
| 0.6 | Full service |
| 0.4 | Suppression |
| 0.2 | Minimum application |
| 0.0 | Release |

#### EngineBrakeControl

The player's Expert Mode locomotive brake control. Ranges from 0 to 1.

#### AWSReset

The acknowledgement plunger.

#### Sander

The sander button.

#### Bell

The bell button.

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

#### Status

The currently selected train status display page. 0 = primary page, 1 = secondary page.

The default setting is 0.

#### Effort

Sets the positions of both tractive effort displays. Ranges from -80 to 160 lbs x 1000.

#### PantoIndicator

Sets the status of the "pantographs" indicator. -1 = neither pantograph up, 0 = front pantograph up, 1 = both pantographs up, 2 = rear pantograph up.

The default setting is 0.

#### SelectLights

Sets the status of the "lighting" indicator. -1 = off, 0 = headlights, 1 = headlights and ground lights, 2 = head lights and flashing ground lights.

The default setting is 0.

#### SpeedometerMPH

The position of the speedometer dial. This is not controlled by scripting.

#### SpeedoGuide

Number of digits to offset the speedometer number to center it on screen. 0 = no digits (for ones), 1 = one digit (for tens), 2 = two digits (for hundreds).

Note that the "1" position is incorrectly rendered the same as the "2" position.

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

#### SigGreen

Controls the green lights on the upper cab signal head. Any value above 0.5 turns on the lights.

#### SigYellow

Controls the yellow lights on the upper cab signal head. Any value above 0.5 turns on the lights.

#### SigRed

Controls the red lights on the upper cab signal head. Any value above 0.5 turns on the lights.

#### SigLowerGreen

Controls the green lights on the lower cab signal head. Any value above 0.5 turns on the lights.

#### SigLowerGrey

Controls the lunar lights on the lower cab signal head. Any value above 0.5 turns on the lights.

#### CabSpeed

Sets the displayed signal speed limit. Only the following values are supported:

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

#### MinimumSpeed

Turns on one of the red squares next to the signal and track speed limit displays. -1 = both off, 0 = signal speed square on, 1 = track speed square on.

#### Handbrake

The handbrake dial. Setting this to the maximum illuminates the "parking brakes" indicator.

The default setting is 0.

### Sounds

#### AWSWarnCount

Plays a British AWS warning horn and illuminates the exclamation mark on the HUD when set to 1.

#### SpeedIncreaseAlert

Plays a short electronic beep when set to 1.

### Keyboard shortcuts

#### ATCCutIn

Toggles between 0 and 1 with Ctrl+D. Should not be set by Lua; otherwise the value will desync from the keyboard shortcut.

The default setting is 1.

#### ACSESCutIn

Toggles between 0 and 1 with Ctrl+F. Should not be set by Lua; otherwise the value will desync from the keyboard shortcut.

The default setting is 1.