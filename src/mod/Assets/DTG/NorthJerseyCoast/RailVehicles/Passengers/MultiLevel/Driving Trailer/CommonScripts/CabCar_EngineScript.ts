/**
 * NJ Transit/MARC MultiLevel Cab Car
 */

import { FrpEngine } from "lib/frp-engine";
import { Version, onInit } from "lib/shared/multilevel";

const me: FrpEngine = new FrpEngine(() => onInit(me, Version.Alp45));
me.setup();
