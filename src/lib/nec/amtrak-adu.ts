/** @noSelfInFile */
/**
 * A contemporary, single-speed Amtrak ADU with ATC and ACSES-II.
 */

import * as acses from "./acses";
import * as c from "lib/constants";
import * as cs from "./cabsignals";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { fsm, rejectUndefined } from "lib/frp-extra";
import * as fx from "lib/special-fx";

/**
 * Represents the in-cab signal aspect, including flashing when displaying a Cab
 * Signal aspect.
 */
export enum AduAspect {
    Stop,
    Restrict,
    Approach,
    ApproachMedium30,
    ApproachMedium45,
    CabSpeed60,
    CabSpeed60Off,
    CabSpeed80,
    CabSpeed80Off,
    Clear100,
    Clear125,
    Clear150,
}

/**
 * Represents the state of the ADU and the safety systems it is attached to.
 */
export type AduState = {
    aspect: AduAspect;
    isMnrrAspect: boolean;
    masEnforcing: MasEnforcing;
    masSpeedMph?: number;
    timeToPenaltyS?: number;
    alarm: boolean;
    penaltyBrake: boolean;
};

/**
 * Represents the safety system status lights, including flashing during an
 * alarm state.
 */
export enum MasEnforcing {
    Off,
    Atc,
    Acses,
}

/**
 * Represents a discrete event emitted by the ADU.
 */
export enum AduEvent {
    Upgrade,
}

enum OrderedAspect {
    Stop = 0,
    Restrict = 1,
    Approach = 2,
    ApproachMedium30 = 3,
    ApproachMedium45 = 4,
    CabSpeed60 = 5,
    CabSpeed80 = 6,
    Clear100 = 7,
    Clear125 = 8,
    Clear150 = 9,
}

type AduInputEvent =
    | AduInputEventType.AtcDowngrade
    | AduInputEventType.AcsesDowngrade
    | [type: AduInputEventType.Update, dt: number];

enum AduInputEventType {
    AtcDowngrade,
    AcsesDowngrade,
    Update,
}

type AduInputState = {
    aspect: OrderedAspect;
    envelope?: SafetyEnvelope;
};

const aduInputInitState: AduInputState = {
    aspect: OrderedAspect.Stop,
    envelope: undefined,
};

type SafetyEnvelope = {
    system: SafetySystem;
    visibleSpeedMps: number;
    alertCurveMps: number;
    penaltyCurveMps: number;
    timeToPenaltyS?: number;
};

enum SafetySystem {
    Atc,
    Acses,
}

type AduAccum =
    | AduMode.Normal
    | [mode: AduMode.AtcOverspeed | AduMode.AcsesOverspeed, countdownS: number, acknowledged: boolean]
    | [mode: AduMode.AtcPenalty | AduMode.AcsesPenalty, acknowledged: boolean];

enum AduMode {
    Normal,
    AtcOverspeed,
    AcsesOverspeed,
    AtcPenalty,
    AcsesPenalty,
}

const cabSpeedFlashS = 0.5;
const enforcingFlashS = 0.5;

/**
 * Create a new ADU instance.
 * @param e The player's engine.
 * @param acknowledge A behavior that indicates the state of the safety systems
 * acknowledge control.
 * @param suppression A behavior that indicates whether suppression has been
 * achieved.
 * @param atcCutIn A behavior that indicates the state of the ATC cut in
 * control.
 * @param acsesCutIn A behavior that indicates the state of the ACSES cut in
 * control.
 */
export function create(
    e: FrpEngine,
    acknowledge: frp.Behavior<boolean>,
    suppression: frp.Behavior<boolean>,
    atcCutIn: frp.Behavior<boolean>,
    acsesCutIn: frp.Behavior<boolean>
): [frp.Stream<AduState>, frp.Stream<AduEvent>] {
    const speedMps = () => (e.rv.GetControlValue("SpeedometerMPH", 0) as number) * c.mph.toMps;
    const atcAspect$ = frp.compose(
        e.createOnSignalMessageStream(),
        frp.map(cs.toPulseCode),
        rejectUndefined(),
        frp.map(cs.toAmtrakAspect)
    );
    const atcAspect = frp.stepper(atcAspect$, cs.AmtrakAspect.Restricting);
    const isMnrrAspect$ = frp.compose(e.createOnSignalMessageStream(), frp.map(cs.isMnrrAspect), rejectUndefined());
    const isMnrrAspect = frp.stepper(isMnrrAspect$, false);

    // We can count on the ACSES stream to update continuously.
    const inputState$ = frp.compose(
        acses.create(e, acsesCutIn),
        frp.map((acsesState): AduInputState => {
            const atcActive = frp.snapshot(atcCutIn);
            const acsesActive = frp.snapshot(acsesCutIn);
            const theAtcAspect = frp.snapshot(atcAspect);

            const isPositiveStop = acsesActive && acsesState.targetSpeedMps === 0;
            const aspect = isPositiveStop
                ? OrderedAspect.Stop
                : {
                      [cs.AmtrakAspect.Restricting]: OrderedAspect.Restrict,
                      [cs.AmtrakAspect.Approach]: OrderedAspect.Approach,
                      [cs.AmtrakAspect.ApproachMedium30]: OrderedAspect.ApproachMedium30,
                      [cs.AmtrakAspect.ApproachMedium45]: OrderedAspect.ApproachMedium45,
                      [cs.AmtrakAspect.CabSpeed60]: OrderedAspect.CabSpeed60,
                      [cs.AmtrakAspect.CabSpeed80]: OrderedAspect.CabSpeed80,
                      [cs.AmtrakAspect.Clear100]: OrderedAspect.Clear100,
                      [cs.AmtrakAspect.Clear125]: OrderedAspect.Clear125,
                      [cs.AmtrakAspect.Clear150]: OrderedAspect.Clear150,
                  }[theAtcAspect];

            let enforcing: SafetySystem | undefined;
            let envelope: SafetyEnvelope | undefined;
            if (atcActive && acsesActive) {
                enforcing =
                    theAtcAspect !== cs.AmtrakAspect.Clear150 &&
                    getAtcSpeedMps(theAtcAspect) <= acsesState.visibleSpeedMps
                        ? SafetySystem.Atc
                        : SafetySystem.Acses;
            } else if (atcActive) {
                enforcing = SafetySystem.Atc;
            } else if (acsesActive) {
                enforcing = SafetySystem.Acses;
            } else {
                enforcing = undefined;
            }

            switch (enforcing) {
                case SafetySystem.Atc:
                    const atcSpeedMps = getAtcSpeedMps(theAtcAspect);
                    envelope = {
                        system: SafetySystem.Atc,
                        visibleSpeedMps: atcSpeedMps,
                        alertCurveMps: atcSpeedMps + cs.alertMarginMps,
                        penaltyCurveMps: Infinity,
                        timeToPenaltyS: undefined,
                    };
                    break;
                case SafetySystem.Acses:
                    const isPositiveStop = acsesState.targetSpeedMps === 0;
                    envelope = {
                        system: SafetySystem.Acses,
                        visibleSpeedMps: acsesState.visibleSpeedMps,
                        alertCurveMps: isPositiveStop
                            ? acsesState.alertCurveMps
                            : acsesState.visibleSpeedMps + cs.alertMarginMps,
                        penaltyCurveMps: acsesState.penaltyCurveMps,
                        timeToPenaltyS: acsesState.timeToPenaltyS,
                    };
                    break;
                case undefined:
                    envelope = undefined;
                    break;
            }

            return {
                aspect,
                envelope,
            };
        }),
        frp.hub()
    );
    const inputDowngrade$ = frp.compose(
        inputState$,
        fsm(aduInputInitState),
        frp.map(([from, to]) => {
            if (frp.snapshot(atcCutIn) && from.aspect > to.aspect) {
                return AduInputEventType.AtcDowngrade;
            } else if (
                from.envelope !== undefined &&
                to.envelope !== undefined &&
                from.envelope.visibleSpeedMps > to.envelope.visibleSpeedMps
            ) {
                return to.envelope.system === SafetySystem.Atc
                    ? AduInputEventType.AtcDowngrade
                    : AduInputEventType.AcsesDowngrade;
            } else {
                return undefined;
            }
        }),
        rejectUndefined()
    );
    const inputState = frp.stepper(inputState$, aduInputInitState);

    const aduState$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        frp.map((pu): AduInputEvent => [AduInputEventType.Update, pu.dt]),
        frp.merge(inputDowngrade$),
        frp.fold((accum: AduAccum, input): AduAccum => {
            const theInputState = frp.snapshot(inputState);
            const theSpeedMps = frp.snapshot(speedMps);
            const theAck = frp.snapshot(acknowledge);

            if (accum === AduMode.Normal) {
                // Process downgrade events.
                if (input === AduInputEventType.AtcDowngrade) {
                    return [AduMode.AtcOverspeed, cs.alertCountdownS, false];
                }
                if (input === AduInputEventType.AcsesDowngrade) {
                    return [AduMode.AcsesOverspeed, cs.alertCountdownS, false];
                }

                // Move to the penalty or overspeed state if speeding.
                const envelope = theInputState.envelope;
                if (envelope !== undefined && theSpeedMps > envelope.penaltyCurveMps) {
                    return [envelope.system === SafetySystem.Atc ? AduMode.AtcPenalty : AduMode.AcsesPenalty, false];
                }
                if (envelope !== undefined && theSpeedMps > envelope.alertCurveMps) {
                    return [
                        envelope.system === SafetySystem.Atc ? AduMode.AtcOverspeed : AduMode.AcsesOverspeed,
                        cs.alertCountdownS,
                        false,
                    ];
                }

                // Nothing to do.
                return AduMode.Normal;
            }

            const [mode] = accum;
            if (mode === AduMode.AtcPenalty) {
                // Only release an ATC penalty brake when stopped.
                const [, acked] = accum;
                return theSpeedMps < c.stopSpeed && acked ? AduMode.Normal : [AduMode.AtcPenalty, acked || theAck];
            }

            if (mode === AduMode.AcsesPenalty) {
                // Allow a running release for ACSES.
                const [, acked] = accum;
                const envelope = theInputState.envelope;
                return acked && (envelope === undefined || theSpeedMps <= envelope.visibleSpeedMps)
                    ? AduMode.Normal
                    : [AduMode.AcsesPenalty, acked || theAck];
            }

            if (mode === AduMode.AtcOverspeed || mode === AduMode.AcsesOverspeed) {
                const [, countdownS, acked] = accum;

                // Prioritize an ATC downgrade for the harsher penalty.
                if (input === AduInputEventType.AtcDowngrade) {
                    return [AduMode.AtcOverspeed, countdownS, acked || theAck];
                }

                // Ignore further ACSES downgrade events.
                if (input === AduInputEventType.AcsesDowngrade) {
                    return [mode, countdownS, acked || theAck];
                }

                // Clock update; check if below safe speed.
                const envelope = theInputState.envelope;
                if (acked && (envelope === undefined || theSpeedMps < envelope.alertCurveMps)) {
                    return AduMode.Normal;
                }

                // Clock update; set the timer to infinity if suppression has
                // been achieved. If no longer in suppression, restart the
                // countdown.
                if (acked && frp.snapshot(suppression)) {
                    return [mode, Infinity, true];
                } else if (countdownS === Infinity) {
                    return [mode, cs.alertCountdownS, false];
                }

                // Clock update; decrement the timer.
                const [, dt] = input;
                const nextS = countdownS - dt;
                if (nextS <= 0) {
                    return [mode === AduMode.AtcOverspeed ? AduMode.AtcPenalty : AduMode.AcsesPenalty, acked || theAck];
                } else {
                    return [mode, nextS, acked || theAck];
                }
            }

            // We should never get here, but the type checker needs help
            // recognizing that.
            return AduMode.Normal;
        }, AduMode.Normal),
        frp.hub()
    );
    const aduAccum = frp.stepper(aduState$, AduMode.Normal);
    const isAlarm = frp.liftN(accum => {
        if (accum === AduMode.Normal) {
            return false;
        } else {
            const [mode] = accum;
            if (mode === AduMode.AtcOverspeed) {
                const [, countdownS] = accum;
                // Check for suppression.
                return countdownS !== Infinity;
            } else {
                return true;
            }
        }
    }, aduAccum);

    // Cab speed flash
    const cabSpeedFlash$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        fx.stopwatchS(
            frp.liftN(
                input => input.aspect === OrderedAspect.CabSpeed60 || input.aspect === OrderedAspect.CabSpeed80,
                inputState
            )
        ),
        frp.map(stopwatchS => stopwatchS !== undefined && stopwatchS % (cabSpeedFlashS * 2) < cabSpeedFlashS)
    );
    const cabSpeedFlashOn = frp.stepper(cabSpeedFlash$, false);

    // Enforcing light flash
    const enforcingFlash$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        fx.stopwatchS(isAlarm),
        frp.map(stopwatchS => stopwatchS !== undefined && stopwatchS % (enforcingFlashS * 2) > enforcingFlashS)
    );
    const enforcingFlashOn = frp.stepper(enforcingFlash$, false);

    const state$ = frp.compose(
        aduState$,
        frp.map((accum): AduState => {
            const input = frp.snapshot(inputState);
            const alarm = frp.snapshot(isAlarm);

            const cabSpeedOn = frp.snapshot(cabSpeedFlashOn);
            const aspect = {
                [OrderedAspect.Stop]: AduAspect.Stop,
                [OrderedAspect.Restrict]: AduAspect.Restrict,
                [OrderedAspect.Approach]: AduAspect.Approach,
                [OrderedAspect.ApproachMedium30]: AduAspect.ApproachMedium30,
                [OrderedAspect.ApproachMedium45]: AduAspect.ApproachMedium45,
                [OrderedAspect.CabSpeed60]: cabSpeedOn ? AduAspect.CabSpeed60 : AduAspect.CabSpeed60Off,
                [OrderedAspect.CabSpeed80]: cabSpeedOn ? AduAspect.CabSpeed80 : AduAspect.CabSpeed80Off,
                [OrderedAspect.Clear100]: AduAspect.Clear100,
                [OrderedAspect.Clear125]: AduAspect.Clear125,
                [OrderedAspect.Clear150]: AduAspect.Clear150,
            }[input.aspect];

            const enforcingOn = frp.snapshot(enforcingFlashOn);
            let masEnforcing: MasEnforcing;
            if (accum === AduMode.Normal) {
                if (input.envelope === undefined) {
                    masEnforcing = MasEnforcing.Off;
                } else if (input.envelope.system === SafetySystem.Atc) {
                    masEnforcing = MasEnforcing.Atc;
                } else {
                    masEnforcing = MasEnforcing.Acses;
                }
            } else if (alarm && !enforcingOn) {
                masEnforcing = MasEnforcing.Off;
            } else {
                const [mode] = accum;
                masEnforcing =
                    mode === AduMode.AtcOverspeed || mode === AduMode.AtcPenalty
                        ? MasEnforcing.Atc
                        : MasEnforcing.Acses;
            }

            const masSpeedMps = input.envelope?.visibleSpeedMps;
            const masSpeedMph = masSpeedMps === undefined ? undefined : masSpeedMps * c.mps.toMph;

            let penaltyBrake: boolean;
            if (accum === AduMode.Normal) {
                penaltyBrake = false;
            } else {
                const [mode] = accum;
                penaltyBrake = mode === AduMode.AtcPenalty || mode === AduMode.AcsesPenalty;
            }

            return {
                aspect,
                isMnrrAspect: frp.snapshot(isMnrrAspect),
                masEnforcing,
                masSpeedMph,
                alarm,
                penaltyBrake,
            };
        })
    );
    const events$ = frp.compose(
        inputState$,
        fsm(aduInputInitState),
        frp.map(([from, to]) => {
            if (frp.snapshot(atcCutIn) && from.aspect < to.aspect) {
                return AduEvent.Upgrade;
            } else if (
                from.envelope !== undefined &&
                to.envelope !== undefined &&
                from.envelope.visibleSpeedMps < to.envelope.visibleSpeedMps
            ) {
                return AduEvent.Upgrade;
            } else {
                return undefined;
            }
        }),
        rejectUndefined()
    );
    return [state$, events$];
}

function getAtcSpeedMps(aspect: cs.AmtrakAspect) {
    return (
        {
            [cs.AmtrakAspect.Restricting]: 20,
            [cs.AmtrakAspect.Approach]: 30,
            [cs.AmtrakAspect.ApproachMedium30]: 30,
            [cs.AmtrakAspect.ApproachMedium45]: 45,
            [cs.AmtrakAspect.CabSpeed60]: 60,
            [cs.AmtrakAspect.CabSpeed80]: 80,
            [cs.AmtrakAspect.Clear100]: 100,
            [cs.AmtrakAspect.Clear125]: 125,
            [cs.AmtrakAspect.Clear150]: 150,
        }[aspect] * c.mph.toMps
    );
}
