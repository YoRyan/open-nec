# Northeast Corridor - New York to New Haven

This route covers the stretch of the Northeast Corridor from New York City to New Haven, Connecticut. It includes both Metro-North's New Haven Line out of Grand Central Terminal and Amtrak's main line out of Penn Station, which converge together at New Rochelle, New York.

## Signaling

Dovetail developed two separate signal scripts for the Metro-North portion of the line (from Grand Central to New Haven via New Rochelle) and the Amtrak portion (from Penn Station to New Rochelle), a curious decision given that both railroads share the same Pennsylvania Railroad-derived pulse code signaling system in real life.

### Penn Station to New Rochelle

The signals on the Amtrak portion of the route send messages in the form of `sigN`, where N is a numeric code that communicates the aspect. The codes seem to be the same codes used by the Philadelphia to New York, North Jersey Coast Line, and Morristown-Essex Line renditions of the Northeast Corridor.

### Grand Central to New Haven

The signals on the Metro-North portion of the route send messages in the form of `Mcc`, `MccRcc`, or `Ncc`, where cc is a numeric code that communicates the aspect. The following codes are used:

| Code | Aspect | Speed
| --- | --- | --- |
| 10 | Clear | MAS |
| 11 | Approach Limited | 45 |
| 12 | Approach Medium | 30 |
| 13-14 | Restricting | 15 |
| 15 | Stop | 0 |

The different meanings of the `M..`, `M..R..`, and `N..` message types are unclear. It seems that most of the time, you will get `M..` messages, unless you encounter a downgrade, in which case you'll get a `M..R..` message, or an upgrade back to Clear, in which case you'll get a `N..` message.

## Power changes

To simulate power changeovers, Dovetail marked the end points of the route's third rail and overhead catenary systems with special signals. These emit the following messages:

| Message | Meaning |
| --- | --- |
| `P-OverheadStart` | Overhead catenary start |
| `P-OverheadEnd` | Overhead catenary end |
| `P-ThirdRailStart` | Third rail start |
| `P-ThirdRailEnd` | Third rail end |
| `P-AIOverheadToThirdNow` | AI overhead to third rail switch |
| `P-AIThirdToOverheadNow` | AI third rail to overhead switch |

## Speed limits

Type 1 speed limits represent visible speed posts. Type 3 limits represent signal speeds. There are no type 2 limits.