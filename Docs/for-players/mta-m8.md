# Notes for the Metro-North M8

The Kawasaki M8 is a dual-mode electric multiple-unit operated by Metro-North. It operates on overhead power on the New Haven Line and third-rail power within the vicinity of Grand Central Terminal. Open NEC equips the M8 with universal cab signaling, ATC, and ACSES.

### Mod compatibility

The Open NEC mod for the M8 is fully compatible and tested with Fan Railer's M8 physics and sound [mod](https://youtu.be/WQzPOthQP08), but Fan Railer's mod must be installed *first* because it contains a script file that conflicts with the one supplied by Open NEC.

### New features

- Press Ctrl+D to disable and enable ATC, and Ctrl+F to disable and enable ACSES. Both systems are turned on by default.
- If running with Fan Railer's physics mod, realistic blended braking logic will be applied. Above 8 mph, almost all braking effort will come from the dynamic brakes. Beneath 8 mph, the dynamic brakes will fade out, and air brakes will be used.
- "Notches" have been added to the master controller for the minimum power, coast, minimum brake, and maximum brake settings. The controller will snap to one of these settings if it is within a nearby region.
- The automatic power change function using the P key, HUD, or Xbox controller has been removed. Instead, all pantograph controls now function as a simple power cutoff switch. To switch between power modes, you should use the in-cab "mode of operation" knob.
- A 10-second delay has been imposed for the power switch. During this time, the unit will produce no power, and the power indicators on the driving screen will be colored yellow.

### Errata

- The signal speed limit display on the center ADU cannot display signal speeds above 45 mph, so the track speed display is used to display these speeds.