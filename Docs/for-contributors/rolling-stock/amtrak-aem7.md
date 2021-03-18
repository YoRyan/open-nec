# Amtrak AEM-7

The EMD AEM-7 is the sole locomotive included with the Northeast Corridor: New York - Philadelphia DLC.

## Controls

### Warning devices

#### CabSignal

Sets the upper (signal) speed limit display and the cab signal aspect displays. However, this control is incapable of rendering any green signal heads, which must be rendered by the `CabSignal1` and `CabSignal2` controls.

| Value | Signal Speed | Aspect |
|---|---|---|
| 0-1 | `--` | Blank over blank |
| 2 | `80` | Blank over blank |
| 3 | `60` | Blank over blank |
| 4-5 | `45` | Yellow over blank |
| 6 | `30` | Yellow over blank |
| 7 | `20` | Red over white |
| 8-10 | `  ` | Blank over blank |

#### CabSignal1

Toggles the green lights on the upper cab signal head. Set to 1 to turn the lights on, and 0 to turn the lights off. These lights are independent of the lights displayed by the `CabSignal` control.

#### CabSignal2

Toggles the green lights on the lower cab signal head. Set to 1 to turn the lights on, and 0 to turn the lights off. These lights are independent of the lights displayed by the `CabSignal` control.

#### TrackSpeed

Sets the lower (track) speed limit display. The track speed indicator supports the following speeds:

* 0 (which displays `--`)
* 10
* 15
* 25
* 30
* 35
* 45
* 50
* 55
* 60
* 65
* 70
* 75
* 80
* 90
* 100
* 105
* 110
* 120
* 125
* 150

All other values will display the highest supported speed that is less than the requested value. For example, setting the value to 20 will display `15`, and setting it to 85 will display `80`.

However, if the value is set to (s - 1) < v < s where s is any supported speed, the display will turn blank (`  `). For example, you can set the value to 9.5 to achieve this effect.

#### AWS

Illuminates the red "Alert Indicator" light above the cab signal display. Set to 1 to turn the light on, and 0 to turn the light off.

#### AWSWarnCount

Plays a "whoop whoop" warning sound and triggers the alerter display on the HUD. Set to 1 to play the sound and flash the warning, and 0 to turn them off.

#### OverSpeedAlert

Plays a "beep beep" warning sound. Set to 1 to play the sound, and 0 to turn it off.

### Buttons and switches

#### SpeedControl

The position of the "Speed Control" button above the cab signal display. It is 1 when depressed and 0 when released.

#### AlertControl

The position of the "Alerter Enable" button above the cab signal display. It is 1 when depressed and 0 when released.

#### CruiseSet

The position of the cruise control speed dial on the dash. It ranges from 10 (off) to 120.

#### AWSReset

The position of the acknowledge (Q) button. It is 1 when depressed and 0 when released.