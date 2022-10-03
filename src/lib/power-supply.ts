/** @noSelfInFile */
/**
 * Power supply logic for electric and dual-mode locomotives.
 */

import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { rejectUndefined } from "lib/frp-extra";
import * as rw from "lib/railworks";
import * as ui from "lib/ui";

/**
 * Represents a form of lineside electrification that can be present along any
 * portion of the route.
 */
export enum Electrification {
    ThirdRail = "t",
    Overhead = "o",
}

/**
 * Represents an operating mode of an uni- or multi-mode locomotive.
 */
export enum EngineMode {
    Diesel = "D",
    ThirdRail = "T",
    Overhead = "O",
}

/**
 * Represents a change in the presence of route electrification.
 */
export type ElectrificationDelta = [el: Electrification, state: boolean];

/**
 * Determine whether a uni-mode electric locomotive has power available from
 * the electrification system.
 * @param mode The type of electric locomotive.
 * @param electrification A behavior that returns the current electrification
 * state.
 * @returns True if power is available for the player's use.
 */
export function uniModeEngineHasPower(
    mode: EngineMode.ThirdRail | EngineMode.Overhead,
    electrification: frp.Behavior<Set<Electrification>>
): boolean {
    const available = frp.snapshot(electrification);
    const supply = mode === EngineMode.ThirdRail ? Electrification.ThirdRail : Electrification.Overhead;
    return available.has(supply);
}

/**
 * Create a behavior that represents the current electrification state, backed
 * by control values, which are saved and resumed and can be transmitted across
 * the consist. Also creates status popups for the player.
 * @param e The player engine.
 * @param cvs A mapping of electrification types to control value names.
 * @returns The new behavior.
 */
export function createElectrificationBehaviorWithControlValues(
    e: FrpEngine,
    cvs: Record<Electrification, string | undefined>
): frp.Behavior<Set<Electrification>> {
    const behavior = () => {
        const set = new Set<Electrification>();
        for (const p in cvs) {
            const el = p as Electrification;
            const cv = cvs[el];
            if (cv !== undefined && (e.rv.GetControlValue(cv, 0) ?? 0) > 0.5) {
                set.add(el);
            }
        }
        return set;
    };
    const stream$ = createElectrificationDeltaStream(e);
    stream$(([el, state]) => {
        const cv = cvs[el];
        if (cv !== undefined) {
            e.rv.SetControlValue(cv, 0, state ? 1 : 0);
        }

        if (e.eng.GetIsEngineWithKey()) {
            showElectrificationAlert(frp.snapshot(behavior));
        }
    });
    return behavior;
}

/**
 * Create a behavior that represents the current electrification state, backed
 * by an in-memory Lua table that is not currently synced across the consist.
 * Also creates status popups for the player.
 * @param e The player engine.
 * @param init A list of electrification types that are available at startup.
 * @returns The new behavior.
 */
export function createElectrificationBehaviorWithLua(
    e: FrpEngine,
    ...init: Electrification[]
): frp.Behavior<Set<Electrification>> {
    const set = new Set<Electrification>(init);
    const stream$ = createElectrificationDeltaStream(e);
    stream$(([el, state]) => {
        if (state) {
            set.add(el);
        } else {
            set.delete(el);
        }

        if (e.eng.GetIsEngineWithKey()) {
            showElectrificationAlert(set);
        }
    });
    return () => set;
}

/**
 * Create a stream of electrification state changes. Can be used to update
 * control values that track the presence of electrification.
 * @param e The player engine.
 * @returns The new stream of electrification updates.
 */
export function createElectrificationDeltaStream(e: FrpEngine): frp.Stream<ElectrificationDelta> {
    return frp.compose(e.createOnSignalMessageStream(), frp.map(parseElectrificationMessage), rejectUndefined());
}

function parseElectrificationMessage(msg: string): ElectrificationDelta | undefined {
    const [, , p] = string.find(msg, "^P%-(%a+)");
    switch (p) {
        case "OverheadStart":
            return [Electrification.Overhead, true];
        case "OverheadEnd":
            return [Electrification.Overhead, false];
        case "ThirdRailStart":
            return [Electrification.ThirdRail, true];
        case "ThirdRailEnd":
        case "DieselRailStart":
            return [Electrification.ThirdRail, false];
        default:
            return undefined;
    }
}

function parseModeSwitchMessage(msg: string) {
    const [, , p] = string.find(msg, "^P%-(%a+)");
    switch (p) {
        case "AIOverheadToThirdNow":
            return EngineMode.ThirdRail;
        case "AIThirdToOverheadNow":
        case "AIDieselToOverheadNow":
            return EngineMode.Overhead;
        case "AIOverheadToDieselNow":
            return EngineMode.Diesel;
        default:
            return undefined;
    }
}

function showElectrificationAlert(set: Set<Electrification>) {
    let abbreviated, message: string;
    if (set.has(Electrification.Overhead) && set.has(Electrification.ThirdRail)) {
        abbreviated = "T_";
        message = "Third rail and overhead power are available.";
    } else if (set.has(Electrification.Overhead)) {
        abbreviated = "T";
        message = "Overhead power is available.";
    } else if (set.has(Electrification.ThirdRail)) {
        abbreviated = "_";
        message = "Third rail power is available.";
    } else {
        abbreviated = " ";
        message = "Electric power is not available.";
    }
    rw.ScenarioManager.ShowAlertMessageExt(`Electrification [${abbreviated}]`, message, ui.popupS, "");
}
