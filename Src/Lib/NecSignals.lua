-- Constants and lookup tables for Northeast Corridor signaling systems.
local P = {}
Nec = P

P.pulsecode = {restrict=0,
               approach=1,
               approachmed=2,
               cabspeed60=3,
               cabspeed80=4,
               clear100=5,
               clear125=6,
               clear150=7}

P.cabspeedflash_s = 0.5

return P