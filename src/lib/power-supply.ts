/** @noSelfInFile */
/**
 * Power supply logic for electric and dual-mode locomotives.
 */

import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { fsm, rejectUndefined } from "lib/frp-extra";
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

const powerSwitchMessageId = 10002;

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
 * Create a timed transition for a dual-mode locomotive, complete with popups
 * that indicate the transition progress for the player.
 * @param e The player engine.
 * @param modeA The first operating mode.
 * @param modeB The second operating mode.
 * @param getMode A behavior that returns the player-selected operating mode.
 * @param getAutoSwitch A behavior that, when true, allows the engine to switch
 * modes according to the power change signal messages.
 * @param getCanTransition A behavior that, when true, allows the player to
 * change modes.
 * @param transitionS The time it takes to transition between the modes.
 * @returns A stream that emits the current power state of the locomotive, as a
 * number scaled from 0 (operating in mode #1) to 1 (operating in mode #2), and
 * a stream that emits the new selected operating mode if automatic switching is
 * used.
 */
export function createDualModeEngineStream<A extends EngineMode, B extends EngineMode>(
    e: FrpEngine,
    modeA: A,
    modeB: B,
    getMode: frp.Behavior<A | B>,
    getAutoSwitch: frp.Behavior<boolean>,
    getCanTransition: frp.Behavior<boolean>,
    transitionS: number
): [position: frp.Stream<number>, autoMode: frp.Stream<EngineMode>] {
    const isEngineStarted = () => (e.rv.GetControlValue("Startup", 0) as number) > 0;
    const autoSwitch$ = createDualModeAutoSwitchStream(e, modeA, modeB, getAutoSwitch);
    const playerPosition$ = frp.compose(
        e.createPlayerUpdateStream(),
        frp.merge(autoSwitch$),
        frp.fold((position, input) => {
            // Automatic switch
            if (typeof input === "string") {
                return input === modeA ? 0 : 1;
            }
            // Clock update
            const pu = input;
            const selectedMode = frp.snapshot(getMode);
            if (!frp.snapshot(e.areControlsSettled)) {
                return selectedMode === modeA ? 0 : 1;
            } else if (!frp.snapshot(isEngineStarted)) {
                // Don't transition while shut down.
                return position;
            } else if ((position === 0 || position === 1) && !frp.snapshot(getCanTransition)) {
                return position;
            } else {
                let direction: number;
                switch (selectedMode) {
                    case modeA:
                        direction = -1;
                        break;
                    case modeB:
                        direction = 1;
                        break;
                    default:
                        direction = 0;
                        break;
                }
                return Math.max(Math.min(position + (direction * pu.dt) / transitionS, 1), 0);
            }
        }, 0),
        frp.hub()
    );
    const position$ = frp.compose(
        e.createAiUpdateStream(),
        frp.map(_ => (frp.snapshot(getMode) === modeA ? 0 : 1)),
        frp.merge(playerPosition$)
    );

    const playerChange$ = frp.compose(
        playerPosition$,
        fsm(0),
        frp.filter(_ => frp.snapshot(e.areControlsSettled)),
        frp.filter(([from, to]) => from !== to),
        frp.map(([, to]) => to),
        frp.hub()
    );
    const playerProgress$ = frp.compose(
        playerChange$,
        frp.filter(position => position > 0 && position < 1)
    );
    const playerComplete$ = frp.compose(
        playerChange$,
        frp.filter(position => position === 0 || position === 1),
        frp.map(position => (position === 0 ? modeA : modeB))
    );
    playerProgress$(position => {
        ui.showProgressPopup(
            "Dual-Mode Power Change",
            "Switch in progress...",
            engineModeName(modeA),
            engineModeName(modeB),
            position
        );
    });
    playerComplete$(mode => {
        rw.ScenarioManager.ShowInfoMessageExt(
            "Dual-Mode Power Change",
            `${engineModeName(mode)} switch complete.`,
            ui.popupS,
            rw.MessageBoxPosition.Bottom + rw.MessageBoxPosition.Left,
            rw.MessageBoxSize.Small,
            false
        );
    });

    return [position$, autoSwitch$];
}

/**
 * Determine whether a dual-mode locomotive is capable of providing power.
 * @param position The switchable power state of the locomotive.
 * @param modeA The first operating mode.
 * @param modeB The second operating mode.
 * @param electrification The current electrification state.
 * @returns True if the locomotive has power available.
 */
export function dualModeEngineHasPower<A extends EngineMode, B extends EngineMode>(
    position: number,
    modeA: A,
    modeB: B,
    electrification: frp.Behavior<Set<Electrification>>
) {
    if (position === 0) {
        return modeA === EngineMode.Diesel || uniModeEngineHasPower(modeA, electrification);
    } else if (position === 1) {
        return modeB === EngineMode.Diesel || uniModeEngineHasPower(modeB, electrification);
    } else {
        return false;
    }
}

/**
 * Process custom signal messages that communicate the automatically selected
 * power mode, and transmit that information to the rest of the consist via
 * consist messages.
 * @param e The player engine.
 * @param modeA The first operating mode.
 * @param modeB The second operating mode.
 * @param getAutoSwitch This behavior must be true to process power change
 * messages.
 * modes according to the power change signal messages.
 * @returns A stream that emits the new selected operating mode if automatic
 * switching is used.
 */
export function createDualModeAutoSwitchStream<A extends EngineMode, B extends EngineMode>(
    e: FrpEngine,
    modeA: A,
    modeB: B,
    getAutoSwitch: frp.Behavior<boolean>
): frp.Stream<A | B> {
    const forward$ = frp.compose(
        e.createOnConsistMessageStream(),
        frp.filter(([id]) => id === powerSwitchMessageId)
    );
    forward$(msg => {
        e.eng.SendConsistMessage(...msg);
    });

    const signal$ = frp.compose(
        e.createOnSignalMessageStream(),
        frp.filter(_ => frp.snapshot(getAutoSwitch)),
        frp.map(parseModeSwitchMessage),
        frp.map(mode => (mode === modeA || mode === modeB ? (mode as A | B) : undefined)),
        rejectUndefined(),
        frp.hub()
    );
    signal$(mode => {
        e.eng.SendConsistMessage(powerSwitchMessageId, mode, rw.ConsistDirection.Forward);
        e.eng.SendConsistMessage(powerSwitchMessageId, mode, rw.ConsistDirection.Backward);
    });
    return frp.compose(
        e.createOnConsistMessageStream(),
        frp.filter(([id]) => id === powerSwitchMessageId),
        frp.map(([, msg]) => msg),
        frp.map(mode => (mode === modeA || mode === modeB ? (mode as A | B) : undefined)),
        rejectUndefined(),
        frp.merge(signal$)
    );
}

/**
 * Create a behavior that represents the current electrification state, backed
 * by control values, which are saved and resumed and can be transmitted across
 * the consist. Also creates status popups for the player.
 * @param e The player engine.
 * @param cvs A mapping of electrification types to control values.
 * @returns The new behavior.
 */
export function createElectrificationBehaviorWithControlValues(
    e: FrpEngine,
    cvs: Record<Electrification, [name: string, index: number] | undefined>
): frp.Behavior<Set<Electrification>> {
    const behavior = () => {
        const set = new Set<Electrification>();
        for (const p in cvs) {
            const el = p as Electrification;
            const cv = cvs[el];
            if (cv !== undefined && (e.rv.GetControlValue(...cv) ?? 0) > 0.5) {
                set.add(el);
            }
        }
        return set;
    };
    const stream$ = createElectrificationDeltaStream(e);
    stream$(([el, state]) => {
        const cv = cvs[el];
        if (cv !== undefined) {
            e.rv.SetControlValue(...cv, state ? 1 : 0);
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

function engineModeName(mode: EngineMode) {
    switch (mode) {
        case EngineMode.Diesel:
            return "Diesel";
        case EngineMode.Overhead:
            return "Overhead";
        case EngineMode.ThirdRail:
            return "Third rail";
    }
}
