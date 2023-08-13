/**
 * Base logic for a safety systems controller with ATC and ACSES subsystems.
 */

import * as acses from "./acses";
import * as c from "lib/constants";
import * as cs from "./cabsignals";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { fsm, mapBehavior, rejectUndefined } from "lib/frp-extra";
import * as fx from "lib/special-fx";

/**
 * Combines information from the ATC and ACSES subsystems. Consumed by
 * subclasses.
 */
export type AduInput<A> = {
    atcAspect: A;
    acsesState?: acses.AcsesState;
    enforcing: AduEnforcing;
};

export enum AduEnforcing {
    None,
    Atc,
    Acses,
}

/**
 * Represents events consumed by the ADU enforcement logic. Produced by
 * subclasses.
 */
export enum AduEvent {
    AtcDowngrade,
    AcsesDowngrade,
}

/**
 * Represents irregular, non-pulse code aspects.
 */
export enum AduAspect {
    Stop = -1,
}

/**
 * Combines information from the ATC and ACSES subsystems, plus the ADU's
 * enforcing state.
 */
export type AduOutput<A> = AduInput<A> & {
    aspect: A | AduAspect;
    atcAlarm: boolean;
    atcLamp: boolean;
    acsesAlarm: boolean;
    acsesLamp: boolean;
    penaltyBrake: boolean;
    vZero: boolean;
};

type TimerAccum = TimerMode.NotStarted | [mode: TimerMode.Running, leftS: number] | TimerMode.Expired;

enum TimerMode {
    NotStarted,
    Running,
    Expired,
}

const ignoreEventsOnLoadS = 5;
const acknowledgeCountdownS = 6;
const aspectFlashS = 0.5;
const lampFlashS = 0.5;

// Taken from NJT documentation.
const atcSetPointMps = 1 * c.mph.toMps;
const atcCountdownS = 5;
const vZeroMps = 2.5 * c.mph.toMps;

/**
 * Creates a new ADU instance.
 * @template A The set of signal aspects to use for the ATC system.
 * @param atc The description of the ATC system.
 * @param getEvents A transformer that maps transitions between ADU input states
 * to ADU input events.
 * @param acsesStepsDown If true, exceeding the ACSES alert curve at any time
 * reveals the advance speed limit and lowers the curve accordingly.
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
 * @returns An event stream that communicates the ADU's state.
 */
export function create<A>(
    atc: cs.AtcSystem<A>,
    getEvents: (eventStream: frp.Stream<[from: AduInput<A>, to: AduInput<A>]>) => frp.Stream<AduEvent>,
    acsesStepsDown: boolean,
    equipmentSpeedMps: number,
    e: FrpEngine,
    acknowledge: frp.Behavior<boolean>,
    suppression: frp.Behavior<boolean>,
    atcCutIn: frp.Behavior<boolean>,
    acsesCutIn: frp.Behavior<boolean>,
    pulseCodeControlValue?: [name: string, index: number]
): frp.Stream<AduOutput<A>> {
    const atcAspect = frp.stepper(cs.createCabSignalStream(atc, e, pulseCodeControlValue), atc.restricting);
    const aSpeedoMps = () => Math.abs(e.rv.GetControlValue("SpeedometerMPH", 0) as number) * c.mph.toMps;
    const vZero = frp.liftN(aSpeedoMps => aSpeedoMps < vZeroMps, aSpeedoMps);

    const acsesState = frp.stepper(acses.create(e, acsesCutIn, acsesStepsDown, equipmentSpeedMps, atcCutIn), undefined);

    // Phase 1, input state and events.
    const enforcing = frp.liftN(
        (atcCutIn, acsesCutIn, atcAspect, acsesState) => {
            if (atcCutIn && acsesCutIn) {
                const atcMps = atc.getSpeedMps(atcAspect);
                const acsesMps = (acsesStepsDown ? acsesState?.stepSpeedMps : acsesState?.curveSpeedMps) ?? Infinity;
                if (atcMps >= Math.floor(150 * c.mph.toMps)) {
                    return AduEnforcing.Acses;
                } else if (acsesMps <= 0) {
                    return AduEnforcing.Atc;
                } else {
                    return atcMps <= acsesMps ? AduEnforcing.Atc : AduEnforcing.Acses;
                }
            } else if (atcCutIn) {
                return AduEnforcing.Atc;
            } else if (acsesCutIn) {
                return AduEnforcing.Acses;
            } else {
                return AduEnforcing.None;
            }
        },
        atcCutIn,
        acsesCutIn,
        atcAspect,
        acsesState
    );
    const input$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (atcAspect, acsesCutIn, acsesState, enforcing): AduInput<A> => {
                    return {
                        atcAspect,
                        acsesState: acsesCutIn ? acsesState : undefined,
                        enforcing,
                    };
                },
                atcAspect,
                acsesCutIn,
                acsesState,
                enforcing
            )
        ),
        frp.hub()
    );
    const initialInput: AduInput<A> = { atcAspect: atc.restricting, enforcing: AduEnforcing.None };
    const events$ = frp.compose(
        input$,
        fsm(initialInput),
        getEvents,
        frp.filter(_ => e.e.GetSimulationTime() > ignoreEventsOnLoadS),
        frp.hub()
    );

    // Phase 2, acknowledgement timer accumulators.
    const atcAcknowledgeAccum = createAcknowledgeAccum(
        e,
        frp.compose(
            events$,
            frp.filter(e => e === AduEvent.AtcDowngrade),
            frp.map(_ => undefined)
        ),
        acknowledge,
        atcCutIn
    );
    const acsesAcknowledgeAccum = createAcknowledgeAccum(
        e,
        frp.compose(
            events$,
            frp.filter(e => e === AduEvent.AcsesDowngrade),
            frp.map(_ => undefined)
        ),
        acknowledge,
        acsesCutIn
    );

    // Phase 3a, ATC overspeed accumulator.
    const atcOverspeed = frp.liftN(
        (aSpeedoMps, atcAspect, suppress) => {
            const overspeed = aSpeedoMps >= atc.getSpeedMps(atcAspect) + atcSetPointMps;
            return overspeed && !suppress;
        },
        aSpeedoMps,
        atcAspect,
        suppression
    );
    const atcPenaltyAccum = frp.stepper(
        frp.compose(
            e.createPlayerWithKeyUpdateStream(),
            frp.fold((accum: TimerAccum, vu): TimerAccum => {
                if (!frp.snapshot(atcCutIn)) return TimerMode.NotStarted;

                const overspeed = frp.snapshot(atcOverspeed);
                switch (accum) {
                    case TimerMode.NotStarted:
                        return overspeed ? [TimerMode.Running, atcCountdownS] : TimerMode.NotStarted;
                    case TimerMode.Expired:
                        return overspeed ? TimerMode.Expired : TimerMode.NotStarted;
                    default:
                        if (overspeed) {
                            const [, leftS] = accum;
                            const nextS = leftS - vu.dt;
                            return nextS <= 0 ? TimerMode.Expired : [TimerMode.Running, nextS];
                        } else {
                            return TimerMode.NotStarted;
                        }
                }
            }, TimerMode.NotStarted)
        ),
        TimerMode.NotStarted
    );

    // Phase 3b, ACSES overspeed accumulator.
    const acsesAbovePenaltyCurve = frp.liftN(
        (aSpeedoMps, acsesState) => aSpeedoMps >= (acsesState?.penaltyCurveMps ?? Infinity),
        aSpeedoMps,
        acsesState
    );
    const acsesBelowTargetSpeed = frp.liftN(
        (aSpeedoMps, acsesState) => {
            const targetSpeedMps = acsesState?.nextLimitMps ?? acsesState?.currentLimitMps;
            return aSpeedoMps >= (targetSpeedMps ?? Infinity);
        },
        aSpeedoMps,
        acsesState
    );
    const acsesPenaltyAccum = frp.stepper(
        frp.compose(
            e.createPlayerWithKeyUpdateStream(),
            frp.fold((isPenalty: boolean, _): boolean => {
                if (!frp.snapshot(acsesCutIn)) return false;

                if (isPenalty) {
                    const belowTarget = frp.snapshot(acsesBelowTargetSpeed);
                    const suppress = frp.snapshot(suppression);
                    return !(belowTarget && suppress);
                } else {
                    const aboveCurve = frp.snapshot(acsesAbovePenaltyCurve);
                    return aboveCurve;
                }
            }, false)
        ),
        false
    );

    // Phase 4, combined input + output state.
    const atcAlarm = frp.liftN(
        (ackAccum, penaltyAccum) => ackAccum !== TimerMode.NotStarted || penaltyAccum !== TimerMode.NotStarted,
        atcAcknowledgeAccum,
        atcPenaltyAccum
    );
    const atcLamp = createFlashingLampBehavior(e, atcAlarm);
    const atcPenalty = frp.liftN(
        (ackAccum, penaltyAccum) => ackAccum === TimerMode.Expired || penaltyAccum === TimerMode.Expired,
        atcAcknowledgeAccum,
        atcPenaltyAccum
    );
    const acsesAboveAlertCurve = frp.liftN(
        (aSpeedoMps, acsesState) => aSpeedoMps >= (acsesState?.alertCurveMps ?? Infinity),
        aSpeedoMps,
        acsesState
    );
    const acsesAlarm = frp.liftN(
        (aboveAlert, ackAccum, penalty) => aboveAlert || ackAccum !== TimerMode.NotStarted || penalty,
        acsesAboveAlertCurve,
        acsesAcknowledgeAccum,
        acsesPenaltyAccum
    );
    const acsesLamp = createFlashingLampBehavior(e, acsesAlarm);
    const acsesPenalty = frp.liftN(
        (ackAccum, penalty) => ackAccum === TimerMode.Expired || penalty,
        acsesAcknowledgeAccum,
        acsesPenaltyAccum
    );
    return frp.compose(
        input$,
        frp.map((input): AduOutput<A> => {
            return {
                atcAspect: input.atcAspect,
                acsesState: input.acsesState,
                enforcing: input.enforcing,
                aspect: isPositiveStop(atc, input) ? AduAspect.Stop : input.atcAspect,
                atcAlarm: frp.snapshot(atcAlarm),
                atcLamp: frp.snapshot(atcLamp) ?? input.enforcing === AduEnforcing.Atc,
                acsesAlarm: frp.snapshot(acsesAlarm),
                acsesLamp: frp.snapshot(acsesLamp) ?? input.enforcing === AduEnforcing.Acses,
                penaltyBrake: frp.snapshot(atcPenalty) || frp.snapshot(acsesPenalty),
                vZero: frp.snapshot(vZero),
            };
        })
    );
}

/**
 * Convert the displayed ADU aspect into a numeric identifier suitable for
 * comparison.
 * @template A The set of signal aspects to use for the ATC system.
 * @param atc The description of the ATC system.
 * @param input The combined ATC/ACSES input state.
 * @returns The numeric value.
 */
export function getAspectSuperiority<A>(atc: cs.AtcSystem<A>, input: AduInput<A>) {
    return isPositiveStop(atc, input) ? -1 : atc.getSuperiority(input.atcAspect);
}

/**
 * Drive the flash effect for a cab signal display. The cycle restarts when the
 * cab signal changes from an aspect that doesn't require flashing to one that
 * does.
 * @template A The set of signal aspects to use for the ATC system.
 * @param atc The description of the ATC system.
 * @param e The player's engine.
 * @returns A stream that emits the flash state at all times (even if the
 * current aspect does not actually require flashing).
 */
export function mapAspectFlashOn<A>(
    atc: cs.AtcSystem<A>,
    e: FrpEngine
): (eventStream: frp.Stream<AduOutput<A>>) => frp.Stream<boolean> {
    return eventStream => {
        const restart$ = frp.compose(
            eventStream,
            frp.map(output => (output.aspect === AduAspect.Stop ? undefined : output.aspect)),
            rejectUndefined(),
            fsm(atc.restricting),
            frp.filter(([from, to]) => from !== to),
            frp.filter(([from, to]) => atc.restartFlash(from, to))
        );
        return frp.compose(
            e.createPlayerWithKeyUpdateStream(),
            fx.eventStopwatchS(restart$),
            frp.map(stopwatchS => stopwatchS !== undefined && stopwatchS % (aspectFlashS * 2) < aspectFlashS)
        );
    };
}

function createAcknowledgeAccum(
    e: FrpEngine,
    eventStream: frp.Stream<void>,
    acknowledge: frp.Behavior<boolean>,
    cutIn: frp.Behavior<boolean>
): frp.Behavior<TimerAccum> {
    const events$ = frp.compose(
        eventStream,
        frp.map(_ => undefined)
    );
    const accum$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        frp.merge(events$),
        frp.fold((accum: TimerAccum, input): TimerAccum => {
            if (!frp.snapshot(cutIn)) return TimerMode.NotStarted;

            // Got a triggering event; start the timer if not already running.
            if (input === undefined) {
                return accum === TimerMode.NotStarted ? [TimerMode.Running, acknowledgeCountdownS] : accum;
            }
            // Otherwise, decrement the timer.
            switch (accum) {
                case TimerMode.NotStarted:
                    return TimerMode.NotStarted;
                case TimerMode.Expired:
                    return frp.snapshot(acknowledge) ? TimerMode.NotStarted : TimerMode.Expired;
                default:
                    if (frp.snapshot(acknowledge)) {
                        return TimerMode.NotStarted;
                    } else {
                        const [, leftS] = accum;
                        const nextS = leftS - input.dt;
                        return nextS <= 0 ? TimerMode.Expired : [TimerMode.Running, nextS];
                    }
            }
        }, TimerMode.NotStarted)
    );
    return frp.stepper(accum$, TimerMode.NotStarted);
}

function isPositiveStop<A>(atc: cs.AtcSystem<A>, input: AduInput<A>) {
    const nextLimitMps = input.acsesState?.nextLimitMps ?? Infinity;
    return input.atcAspect === atc.restricting && nextLimitMps <= 0;
}

function createFlashingLampBehavior(e: FrpEngine, flash: frp.Behavior<boolean>): frp.Behavior<boolean | undefined> {
    const flashOn = frp.stepper(
        frp.compose(
            e.createPlayerWithKeyUpdateStream(),
            fx.behaviorStopwatchS(flash),
            frp.map(stopwatchS => stopwatchS !== undefined && stopwatchS % (lampFlashS * 2) > lampFlashS)
        ),
        false
    );
    return frp.liftN((flash, on) => (flash ? on : undefined), flash, flashOn);
}
