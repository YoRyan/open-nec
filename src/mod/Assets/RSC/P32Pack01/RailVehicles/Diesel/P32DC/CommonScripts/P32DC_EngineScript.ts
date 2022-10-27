/**
 * Metro-North GE P32AC-DM
 */

import { FrpEngine } from "lib/frp-engine";
import { onInit } from "lib/shared/p32";

const me: FrpEngine = new FrpEngine(() => onInit(me, false));
me.setup();
