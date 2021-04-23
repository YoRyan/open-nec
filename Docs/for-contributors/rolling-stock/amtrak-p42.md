# Amtrak P42DC

The GE P42DC is a diesel-electric locomotive that forms of the backbone of Amtrak's long-haul fleet. Occasionally, due to shortages of electric locomotives or due to catenary maintenance, P42's can be seen pulling trains even on the electrified Northeast Corridor. However, they are prohibited from operating into New York's Penn Station.

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

### Regulator

The combined power lever (and the player's Expert throttle control) when within the power range. Ranges from 0 to 1.

### DynamicBrake

The combined power lever (and the player's Expert throttle control) when within the brake range. Ranges from 0 to 1.

#### TrainBrakeControl

The player's Expert automatic brake control. Ranges from 0 to 1.

#### EngineBrakeControl

The independent brake control. Ranges from 0 to 1.

#### AWSReset

The alerter acknowledge button.

#### Startup

The engine start/stop buttons. -1 = engine stop, 1 = engine run. The default setting is 1.

#### Headlights

The headlight controls. 0 = off, 1 = front headlights, 2 = rearlights.

#### CrossingLight

The crossing light on/off switch.

### Miscellaneous

#### Wipers

The wipers button.

#### ADU00

The ex-PRR aspect display "Clear" lamp.

#### ADU01

#### ADU02

The ex-PRR aspect display "Approach Medium" lamps.

#### ADU03

The ex-PRR aspect display "Approach" lamp.

#### ADU04

The ex-PRR aspect display "Restricting" lamp.

#### ADU05

#### ADU06a

#### ADU06b

#### ADU07

#### ADU08

#### ADU09

The ex-CBQ aspect display lamps.

#### CabLight1

The engineer's forward task light, which can be clicked on/off.

#### CabLight2

The secondman's forward task light, which can be clicked on/off.

#### CabLight3

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

#### LocoHundreds

The hundreds digit of the cab model's locomotive number. -1 hides the digit.

#### LocoTens

The tens digit of the cab model's locomotive number. -1 hides the digit.

#### LocoUnits

The ones digit of the cab model's locomotive number. -1 hides the digit.

### Sounds

#### AlerterAudible

Plays a continuous beep-beep sound.

#### Buzzer

Plays a buzzing sound. Intended to be used for control lockouts.

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