# Metro-North P32AC-DM

The GE P32AC-DM is a dual-mode electric and diesel locomotive that provides express service from Grand Central Terminal to Metro-North's various unelectrified branch lines.

Unfortunately, some of the P32's scenarios and quick drive consists incorrectly set the P32 for diesel mode at startup—even when the scenario begins in Grand Central Terminal, or when the consist is labeled "Third Rail."

It's not clear how much horsepower is available to the P32 in electric mode. Intuitively, there would be less power available, since the locomotive's top speed in this mode is lower. One educated [guess](https://www.nyctransitforums.com/topic/22340-p32ac-dm-question/?tab=comments#comment-312459) by Fan Railer is 2200 hp, versus about 2900 hp in diesel mode (less HEP). However, another [source](https://www.trainsim.com/vbts/showthread.php?181917-P32AC-DM-Speed-Limits) claims the full power of the locomotive is available in electric mode, and that the top speed is limited only to avoid arcing the 3rd rail.

Metro-North [practice](https://www.reddit.com/r/nycrail/comments/f617cx/are_the_p32_ac_dm_locomotives_good_in_electric/fi2jp2z/) is to keep the P32 in diesel mode for as long as possible, which means switching to electric when entering the platforms at Grand Central and switching to diesel when exiting the Park Avenue Tunnel - contrary to Dovetail's manual (evidently copied from that of the M8), which suggests the changeover occurs at the end of the overhead catenary between Pelham and Mount Vernon East.

## Controls

### Control desk

#### Horn

The engineer's and secondman's horn buttons.

#### EmergencyBrake

The secondman's emergency brake button.

#### CabLight5

The cab dome light on/off switch.

#### Sander

The sander on/off button.

#### Bell

The bell on/off button.

#### Reverser

The reverser lever. 1 = forward, 0 = neutral, -1 = reverse.

#### VirtualThrottle

The combined power lever, and the player's Expert throttle control. Ranges from 0 to 1. Note that it is not possible to enter the dynamic brake region.

#### Regulator

The true throttle setting used by the physics model.

#### TrainBrakeControl

The player's Expert automatic brake control. Ranges from 0 to 1.

#### EngineBrakeControl

The independent brake control. Ranges from 0 to 1.

#### AWSReset

The alerter acknowledge button.

#### PowerMode

The power change switch. 1 = diesel, 0 = DC. The default setting reflects the mode the locomotive starts in.

#### Power3rdRail

The DC power availability light.

#### Startup

The engine start/stop buttons. -1 = engine stop, 1 = engine run. The default setting is 1.

#### Headlights

The headlight controls. 0 = off, 1 = front headlights, 2 = rearlights.

#### CrossingLight

The crossing light on/off switch.

### Miscellaneous

#### Wipers

The wipers button.

#### SigN

The aspect display "N" lamp.

#### SigL

The aspect display "L" lamp.

#### SigM

The aspect display "M" lamp.

#### SigR

The aspect display "R" lamp.

#### SignalSpeed

The aspect display speed limit indicator. Only the following values are supported:

- 0
- 15
- 30
- 45

All other values blank the display.

#### CabLight1

The engineer's forward task light, which can be clicked on/off.

#### CabLight2

The secondman's forward task light, which can be clicked on/off.

#### CabLight

The engineer's side task light, which can be clicked on/off.

#### CabLight4

The secondman's side task light, which can be clicked on/off.

#### SpeedoHundreds

The hundreds digit on the digital speedometer display. -1 hides the digit.

#### SpeedoTens

The tens digit on the digital speedometer display. -1 hides the digit.

#### SpeedoUnits

The ones digit on the digital speedometer display.

#### SpeedoDecimal

The tenths digit on the digital speedometer display.

#### TrackHundreds

The hundreds digit on the overspeed display. -1 hides the digit.

#### TrackTens

The tens digit on the overspeed display. -1 hides the digit.

#### TrackUnits

The ones digit on the overspeed display. -1 hides the digit.

#### AlerterVisual

The visual alerter on the driving screen.

#### AWSWarnCount

Illuminates the exclamation mark on the HUD.

### Sounds

#### AWS

Plays a continuous beep-beep sound.

### Keyboard shortcuts

#### ATCCutIn

Toggles on/off with Ctrl+D. The default setting is 1.

#### ACSESCutIn

Toggles on/off with Ctrl+F. The default setting is 1.

## Model nodes

### ditch_right

### ditch_left

The ditch lights.

## Lights

### DitchLight_R

### DitchLight_L

The ditch lights.

### CabLight_R

The engineer's side task light.

### CabLight_M

The rear cab dome light.

### CabLight_L

The secondman's side task light.

### TaskLight_R

The engineer's forward task light.

### TaskLight_L

The secondman's forward task light.

## Emitters

### DieselExhaust

Diesel engine exhaust.