/**
 * Metro-North/Amtrak GE P32AC-DM
 */

import { FrpEngine } from "lib/frp-engine";
import { onInit } from "lib/shared/p32";

// Sadly, it's not possible to distinguish between a Hudson Line Metro-North
// P32 and a Hudson Line Amtrak P32.
const isAmtrak = true;
const me: FrpEngine = new FrpEngine(() => onInit(me, isAmtrak));
me.setup();
