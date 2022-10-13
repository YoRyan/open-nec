/** @noSelfInFile */
/**
 * Base logic for a safety systems controller with ATC and ACSES subsystems.
 */

import * as acses from "./acses";
import * as c from "lib/constants";
import * as cs from "./cabsignals";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { fsm, rejectUndefined } from "lib/frp-extra";

/**
 * Represents events consumed by the ADU's enforcement logic.
 */
export enum AduEvent {
    AtcDowngrade,
    AcsesDowngrade,
}

/**
 * A safety system supplies a set of braking curves, plus informational state
 * for the engineer.
 */
export interface SafetySystem {
    alertCurveMps: number;
    penaltyCurveMps: number;
    visibleSpeedMps: number;
    timeToPenaltyS?: number;
}

/**
 * Combines information from the ATC and ACSES subsystems.
 */
export type AduInput<A> = {
    aspect: AduAspect.Stop | A;
    atc?: SafetySystem;
    acses?: SafetySystem;
    enforcing?: SafetySystem;
};

/**
 * Represents irregular, non-ATC aspects.
 */
export enum AduAspect {
    Stop = -1,
}

/**
 * Combines information from the ATC and ACSES subsystems, plus the ADU's
 * enforcing state.
 */
export type AduOutput<A> = AduInput<A> & {
    state: AduState;
};

/**
 * Represents the current enforcement action the ADU is taking.
 */
export type AduState =
    | AduMode.Normal
    | [mode: AduMode.AtcOverspeed | AduMode.AcsesOverspeed, startS: number, acknowledged: boolean]
    | [mode: AduMode.AtcPenalty | AduMode.AcsesPenalty, acknowledged: boolean];

export enum AduMode {
    Normal,
    AtcOverspeed,
    AcsesOverspeed,
    AtcPenalty,
    AcsesPenalty,
}

/**
 * Creates a new ADU instance.
 * @template A The set of signal aspects to use for the ATC system.
 * @param atc The description of the ATC system.
 * @param getEvents A transformer that maps transitions between ADU input states
 * to ADU input events.
 * @param violationForcesAlarm If true, exceeding the visible speed limit at
 * any time violates the alert curve.
 * @param equipmentSpeedMps The maximum consist speed limit.
 * @param e The player's engine.
 * @param acknowledge A behavior that indicates the state of the safety systems
 * acknowledge control.
 * @param suppression A behavior that indicates whether suppression has been
 * achieved.
 * @param atcCutIn A behavior that indicates the state of the ATC cut in
 * control.
 * @param acsesCutIn A behavior that indicates the state of the ACSES cut in
 * control.
 * @param pulseCodeControlValue The name and index of the control value to use
 * to persist the cab signal pulse code between save states.
 * @returns A stream that communicates the ADU's state.
 */
export function create<A>(
    atc: cs.AtcSystem<A>,
    getEvents: (eventStream: frp.Stream<[from: AduInput<A>, to: AduInput<A>]>) => frp.Stream<AduEvent>,
    violationForcesAlarm: boolean,
    equipmentSpeedMps: number,
    e: FrpEngine,
    acknowledge: frp.Behavior<boolean>,
    suppression: frp.Behavior<boolean>,
    atcCutIn: frp.Behavior<boolean>,
    acsesCutIn: frp.Behavior<boolean>,
    pulseCodeControlValue?: [name: string, index: number]
): frp.Stream<AduOutput<A>> {
    // Cab signaling system
    const pulseCodeFromResume$: frp.Stream<cs.PulseCode> =
        pulseCodeControlValue !== undefined
            ? frp.compose(
                  e.createOnResumeStream(),
                  frp.map(() => e.rv.GetControlValue(...pulseCodeControlValue) as number),
                  frp.map(cs.pulseCodeFromResumeValue)
              )
            : _ => {};
    const pulseCodeFromMessage$ = frp.compose(
        e.createOnSignalMessageStream(),
        frp.map(cs.toPulseCode),
        rejectUndefined()
    );
    const atcAspect$ = frp.compose(pulseCodeFromResume$, frp.merge(pulseCodeFromMessage$), frp.map(atc.fromPulseCode));
    const atcAspect = frp.stepper(atcAspect$, atc.initialAspect);

    // Persist the current pulse code between save states.
    if (pulseCodeControlValue !== undefined) {
        const pulseCodeSave$ = frp.compose(pulseCodeFromMessage$, frp.map(cs.pulseCodeToSaveValue));
        pulseCodeSave$(cv => {
            e.rv.SetControlValue(...pulseCodeControlValue, cv);
        });
    }

    // ATC speed limits
    const atcSystem = frp.liftN(
        (cutIn, cabAspect): SafetySystem | undefined => {
            if (!cutIn) {
                return undefined;
            } else {
                const limitMps = atc.getSpeedMps(cabAspect);
                return {
                    visibleSpeedMps: limitMps,
                    alertCurveMps: limitMps + cs.alertMarginMps,
                    penaltyCurveMps: Infinity,
                    timeToPenaltyS: undefined,
                };
            }
        },
        atcCutIn,
        atcAspect
    );

    // Phase 1, input state.
    // We can count on the ACSES stream to update continuously.
    const input$ = frp.compose(
        acses.create(e, acsesCutIn, violationForcesAlarm, equipmentSpeedMps),
        frp.map((acsesState): AduInput<A> => {
            const isPositiveStop = frp.snapshot(acsesCutIn) && acsesState.targetSpeedMps <= 0;
            const aspect = isPositiveStop ? AduAspect.Stop : frp.snapshot(atcAspect);
            const atc = frp.snapshot(atcSystem);

            let acses: SafetySystem | undefined;
            if (!frp.snapshot(acsesCutIn)) {
                acses = undefined;
            } else {
                acses = acsesState;
            }

            let enforcing: SafetySystem | undefined;
            if (atc !== undefined && acses !== undefined) {
                const atcEnforcing =
                    atc.visibleSpeedMps <= acsesState.visibleSpeedMps &&
                    atc.visibleSpeedMps < Math.floor(150 * c.mph.toMps);
                enforcing = atcEnforcing ? atc : acses;
            } else if (atc === undefined && acses !== undefined) {
                enforcing = acses;
            } else if (atc !== undefined && acses === undefined) {
                enforcing = atc;
            } else {
                enforcing = undefined;
            }

            return {
                aspect,
                atc,
                acses,
                enforcing,
            };
        }),
        frp.hub()
    );
    const initialInput: AduInput<A> = { aspect: atc.initialAspect };
    const input = frp.stepper(input$, initialInput);
    const events$ = frp.compose(input$, fsm(initialInput), getEvents);

    // Phase 2, accumulator and combined input + output state.
    return frp.compose(
        input$,
        frp.merge(events$),
        frp.fold((accum: AduState, input): AduState => {
            const speedoMps = (e.rv.GetControlValue("SpeedometerMPH", 0) as number) * c.mph.toMps;
            const nowS = e.e.GetSimulationTime();
            const ack = frp.snapshot(acknowledge);

            if (accum === AduMode.Normal) {
                // Process downgrade events.
                if (input === AduEvent.AtcDowngrade) {
                    return [AduMode.AtcOverspeed, nowS, false];
                }
                if (input === AduEvent.AcsesDowngrade) {
                    return [AduMode.AcsesOverspeed, nowS, false];
                }

                // Move to the penalty or overspeed state if speeding.
                const enforcing = input.enforcing;
                if (enforcing !== undefined && speedoMps > enforcing.penaltyCurveMps) {
                    return [enforcing === input.atc ? AduMode.AtcPenalty : AduMode.AcsesPenalty, false];
                }
                if (enforcing !== undefined && speedoMps > enforcing.alertCurveMps) {
                    return [enforcing === input.atc ? AduMode.AtcOverspeed : AduMode.AcsesOverspeed, nowS, false];
                }

                // Nothing to do.
                return AduMode.Normal;
            }

            const [mode] = accum;
            // Release penalty or overspeed state if the player toggles the cut in control.
            if ((mode === AduMode.AtcOverspeed || mode === AduMode.AtcPenalty) && !frp.snapshot(atcCutIn)) {
                return AduMode.Normal;
            }
            if ((mode === AduMode.AcsesOverspeed || mode === AduMode.AcsesPenalty) && !frp.snapshot(acsesCutIn)) {
                return AduMode.Normal;
            }

            if (mode === AduMode.AtcPenalty) {
                // Only release an ATC penalty brake when stopped.
                const [, acked] = accum;
                return speedoMps < c.stopSpeed && acked ? AduMode.Normal : [AduMode.AtcPenalty, acked || ack];
            }

            if (mode === AduMode.AcsesPenalty) {
                const [, acked] = accum;
                if (input === AduEvent.AtcDowngrade) {
                    return [AduMode.AcsesPenalty, acked || ack];
                }
                if (input === AduEvent.AcsesDowngrade) {
                    return [AduMode.AcsesPenalty, acked || ack];
                }

                // Allow a running release for ACSES.
                const enforcing = input.enforcing;
                return acked && (enforcing === undefined || speedoMps <= enforcing.visibleSpeedMps)
                    ? AduMode.Normal
                    : [AduMode.AcsesPenalty, acked || ack];
            }

            if (mode === AduMode.AtcOverspeed || mode === AduMode.AcsesOverspeed) {
                const [, clockS, acked] = accum;

                // Prioritize an ATC downgrade for the harsher penalty.
                if (input === AduEvent.AtcDowngrade) {
                    return [AduMode.AtcOverspeed, clockS, acked || ack];
                }

                // Ignore further ACSES downgrade events.
                if (input === AduEvent.AcsesDowngrade) {
                    return [mode, clockS, acked || ack];
                }

                // State update; check if below safe speed.
                const enforcing = input.enforcing;
                if (acked && (enforcing === undefined || speedoMps < enforcing.alertCurveMps)) {
                    return AduMode.Normal;
                }

                // State update; set the timer to infinity if suppression has
                // been achieved. If no longer in suppression, restart the
                // countdown.
                if (acked && frp.snapshot(suppression)) {
                    return [mode, Infinity, true];
                } else if (clockS === Infinity) {
                    return [mode, nowS, false];
                }

                // State update; decrement the timer.
                if (nowS - clockS > cs.alertCountdownS) {
                    return [mode === AduMode.AtcOverspeed ? AduMode.AtcPenalty : AduMode.AcsesPenalty, acked || ack];
                } else {
                    return [mode, clockS, acked || ack];
                }
            }

            // We should never get here, but the type checker needs help
            // recognizing that.
            return AduMode.Normal;
        }, AduMode.Normal),
        frp.map((accum): AduOutput<A> => {
            const theInput = frp.snapshot(input);
            return {
                aspect: theInput.aspect,
                atc: theInput.atc,
                acses: theInput.acses,
                enforcing: theInput.enforcing,
                state: accum,
            };
        })
    );
}
