/** @noSelfInFile */
/**
 * Helpers for UI popups and controls.
 */

import * as frp from "./frp";
import { FrpEngine } from "./frp-engine";
import { fsm, mapBehavior, rejectUndefined } from "./frp-extra";
import * as rw from "./railworks";

export const popupS = 5;

/**
 * Use popups to communicate the status of a behavior. Intended for invisible
 * controls such as safety systems cut in/out, etc.
 * @param e The player's engine.
 * @param behavior The behavior to monitor.
 * @param title The title shared by all popups.
 * @param status A map of possible behavior states to popup messages.
 */
export function createStatusPopup<T>(e: FrpEngine, behavior: frp.Behavior<T>, title: string, status: Map<T, string>) {
    const stream$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        frp.filter(_ => frp.snapshot(e.areControlsSettled)),
        mapBehavior(behavior),
        fsm<undefined | T>(undefined),
        // Ignore the first transition from undefined to false, which is usually spurious.
        frp.filter(([from, to]) => from !== to && !(from === undefined && !to)),
        frp.map(([, to]) => to),
        rejectUndefined()
    );
    stream$(to => {
        rw.ScenarioManager.ShowAlertMessageExt(title, status.get(to) ?? "Unknown", popupS, "");
    });
}

/**
 * Create popups for an ATC cut in/out control.
 * @param e The player's engine.
 * @param behavior The cut in/out behavior.
 */
export function createAtcStatusPopup(e: FrpEngine, behavior: frp.Behavior<boolean>) {
    createStatusPopup(
        e,
        behavior,
        "ATC Signal Speed Enforcement",
        new Map([
            [true, "Cut In"],
            [false, "Cut Out"],
        ])
    );
}

/**
 * Create popups for an ACSES cut in/out control.
 * @param e The player's engine.
 * @param behavior The cut in/out behavior.
 */
export function createAcsesStatusPopup(e: FrpEngine, behavior: frp.Behavior<boolean>) {
    createStatusPopup(
        e,
        behavior,
        "ACSES Track Speed Enforcement",
        new Map([
            [true, "Cut In"],
            [false, "Cut Out"],
        ])
    );
}

/**
 * Create popups for an alerter cut in/out control.
 * @param e The player's engine.
 * @param behavior The cut in/out behavior.
 */
export function createAlerterStatusPopup(e: FrpEngine, behavior: frp.Behavior<boolean>) {
    createStatusPopup(
        e,
        behavior,
        "Alerter Vigilance System",
        new Map([
            [true, "Cut In"],
            [false, "Cut Out"],
        ])
    );
}
