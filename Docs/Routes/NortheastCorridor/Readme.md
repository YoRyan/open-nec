# Northeast Corridor - New York to Philadelphia

This route covers the stretch of the NEC from New York Penn to Philadelphia 30th St. This was the first NEC route released by Dovetail Games, so it has the sparsest scenery and the least developed signaling implementation.

## Signaling

Signal messages are in the form of `sigNspdS`, where N is a numeric code that communicates the signal aspect and S is the current track speed limit.

The following table, derived from the AEM-7's engine script, shows the meanings of these codes:

| Code | Aspect |
| --- | --- |
| 0 | "None" |
| 1 | Clear |
| 2 | Cab Speed 80 |
| 3 | Cab Speed 60 |
| 4 | Approach Limited |
| 5 | Approach Medium |
| 6 | Approach |
| 7 | Restricting |
| 8 | "Ignore" |

These aspects are mostly true to real life, but there are some differences compared to [the real thing](https://en.wikipedia.org/wiki/Pulse_code_cab_signaling). On the real NEC, the Clear aspect can be amended with 100, 125, and 150 mph speeds. Since these are not present in Dovetail's signals, we have to assume all Clear aspects actually mean "Clear 125 mph".

Dovetail also programmed two different "Approach Medium 45 mph" aspects into the AEM-7: a yellow-over-green aspect (for the Approach Medium and Medium Clear aspects) and a yellow-over-flashing-green (for the Approach Limited, Limited Clear, and Advance Approach aspects). This makes little sense, since there is only one 45 mph code used by the real pulse code signaling system.