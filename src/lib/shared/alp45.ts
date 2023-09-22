/**
 * NJ Transit Bombardier ALP-45DP
 */

import { EngineMode } from "lib/power-supply";

export const dualModeOrder: [EngineMode.Diesel, EngineMode.Overhead] = [EngineMode.Diesel, EngineMode.Overhead];
export const dualModeSwitchS = 100;
export const pantographLowerPosition = 0.03;
export const dieselPowerPct = 3600 / 5900;
