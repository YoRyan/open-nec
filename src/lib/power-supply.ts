/**
 * Power supply logic for electric and dual-mode locomotives.
 */

import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { fsm, mapBehavior, once, rejectUndefined } from "lib/frp-extra";
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
 * Create a timed transition for a dual-mode locomotive, complete with popups
 * that indicate the transition progress for the player.
 * @param e The player engine.
 * @param modeA The first operating mode.
 * @param modeB The second operating mode.
 * @param getPlayerMode A behavior that returns the player-selected operating
 * mode.
 * @param getAiMode: A behavior that returns the mode a non-player train should
 * operate in.
 * @param getPlayerCanSwitch A behavior that, when true, allows the player to
 * change modes.
 * @param transitionS The time it takes to transition between the modes.
 * @param instantSwitch An event stream that instantly switches the power mode
 * due to, e.g., power change signal messages.
 * @param positionFromSaveOrConsist Read the current power state from a control
 * value to persist it between save states or to read it from the rest of the
 * consist.
 * @returns A behavior that returns the current power state of the locomotive as
 * a number scaled from 0 (operating in mode #1) to 1 (operating in mode #2).
 */
export function createDualModeEngineBehavior<A extends EngineMode, B extends EngineMode>(
    e: FrpEngine,
    modeA: A,
    modeB: B,
    getPlayerMode: frp.Behavior<A | B>,
    getAiMode: frp.Behavior<A | B>,
    getPlayerCanSwitch: frp.Behavior<boolean>,
    transitionS: number,
    instantSwitch: frp.Stream<A | B>,
    positionFromSaveOrConsist: frp.Behavior<number>
): frp.Behavior<number> {
    // Start from the first selected mode, or load a saved transition position.
    const playerInitFresh$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        frp.filter(_ => frp.snapshot(e.areControlsSettled)),
        mapBehavior(getPlayerMode),
        frp.map(mode => (mode === modeA ? 0 : 1))
    );
    const playerInitFromSave$ = frp.compose(e.createOnResumeStream(), mapBehavior(positionFromSaveOrConsist));
    const playerInit$ = frp.compose(playerInitFresh$, frp.merge(playerInitFromSave$), once());

    const isEngineStarted = () => (e.rv.GetControlValue("Startup", 0) as number) > 0;
    const playerPosition$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        frp.merge(playerInit$),
        frp.merge(instantSwitch),
        frp.fold((position: number | undefined, input) => {
            // Automatic switch
            if (typeof input === "string") {
                return input === modeA ? 0 : 1;
            }
            // Initialize position
            if (typeof input === "number") {
                return input;
            }
            // Do nothing if not yet initialized.
            if (position === undefined) {
                return undefined;
            }
            // Clock update
            const pu = input;
            const selectedMode = frp.snapshot(getPlayerMode);
            if (!frp.snapshot(isEngineStarted)) {
                // Halt the transition if shut down.
                return position;
            } else if ((position === 0 || position === 1) && !frp.snapshot(getPlayerCanSwitch)) {
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
        }, undefined),
        frp.hub()
    );

    // Player status popups
    const playerChange$ = frp.compose(
        playerPosition$,
        fsm<number | undefined>(undefined),
        frp.map(([from, to]) => (from !== undefined && from !== to ? to : undefined)),
        rejectUndefined(),
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
            "Power Mode Change",
            "Switch in progress...",
            engineModeName(modeA),
            engineModeName(modeB),
            position
        );
    });
    playerComplete$(mode => {
        rw.ScenarioManager.ShowInfoMessageExt(
            "Power Mower Change",
            `${engineModeName(mode)} switch complete.`,
            ui.popupS,
            rw.MessageBoxPosition.Bottom + rw.MessageBoxPosition.Left,
            rw.MessageBoxSize.Small,
            false
        );
    });

    const playerPosition = frp.stepper(playerPosition$, undefined);
    return frp.liftN(
        (isEngineWithKey, isPlayer) => {
            if (isEngineWithKey) {
                return frp.snapshot(playerPosition) ?? 0;
            } else if (isPlayer) {
                return frp.snapshot(positionFromSaveOrConsist);
            } else {
                const aiMode = frp.snapshot(getAiMode);
                return aiMode === modeA ? 0 : 1;
            }
        },
        () => e.eng.GetIsEngineWithKey(),
        () => e.rv.GetIsPlayer()
    );
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
 * power mode.
 * @param e The player engine.
 * @param modeA The first operating mode.
 * @param modeB The second operating mode.
 * @param getAutoSwitch This behavior must be true to process power change
 * messages.
 * @returns A stream that emits the new selected operating mode if automatic
 * switching is used.
 */
export function createDualModeAutoSwitchStream<A extends EngineMode, B extends EngineMode>(
    e: FrpEngine,
    modeA: A,
    modeB: B,
    getAutoSwitch: frp.Behavior<boolean>
): frp.Stream<A | B> {
    return frp.compose(
        e.createOnSignalMessageStream(),
        frp.filter(_ => frp.snapshot(getAutoSwitch)),
        frp.map(parseModeSwitchMessage),
        frp.map(mode => (mode === modeA || mode === modeB ? (mode as A | B) : undefined)),
        rejectUndefined()
    );
}

/**
 * Create a behavior that represents the current electrification state, backed
 * by control values, which are saved and resumed. Also creates status popups
 * for the player.
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

        showElectrificationAlert(frp.snapshot(behavior));
    });
    return behavior;
}

/**
 * Create a behavior that represents the current electrification state, backed
 * by an in-memory Lua table that is not currently saved. Also creates status
 * popups for the player.
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

        showElectrificationAlert(set);
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

/**
 * Simulate head-end power with a flickering effect during startup/shutdown. To
 * avoid rendering unnecessary amounts of lights, AI trains will always run
 * without HEP.
 * @param e The player engine.
 * @param hepOn A behavior that, when true, indicates the player has activated
 * HEP.
 * @returns A stream that indicates HEP is available.
 */
export function createHepStream(e: FrpEngine, hepOn?: frp.Behavior<boolean>): frp.Stream<boolean> {
    hepOn ??= () => (e.rv.GetControlValue("Startup", 0) as number) > 0;

    const startupS = 10;
    const player$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        frp.fold((position, pu) => {
            if (!frp.snapshot(e.areControlsSettled)) {
                return frp.snapshot(hepOn) ? 1 : 0;
            } else {
                const dt = (frp.snapshot(hepOn) ? 1 : -1) * pu.dt;
                return Math.max(Math.min(position + dt / startupS, 1), 0);
            }
        }, 0),
        frp.map(position => (position > 0.85 && position < 0.9) || position === 1)
    );
    return frp.compose(
        e.createAiUpdateStream(),
        frp.map(_ => false),
        frp.merge(player$)
    );
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
