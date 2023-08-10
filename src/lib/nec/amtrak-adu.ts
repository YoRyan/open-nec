/**
 * A contemporary, single-speed Amtrak ADU with ATC and ACSES-II.
 */

import * as adu from "./adu";
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
    ApproachMedium,
    ApproachLimited,
    ApproachLimitedOff,
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

const aspectFlashS = 0.5;
const enforcingFlashS = 0.5;

/**
 * Creates a contemporary Amtrak-style ADU.
 */
export function create(
    e: FrpEngine,
    acknowledge: frp.Behavior<boolean>,
    suppression: frp.Behavior<boolean>,
    atcCutIn: frp.Behavior<boolean>,
    acsesCutIn: frp.Behavior<boolean>,
    equipmentSpeedMps: number,
    pulseCodeControlValue?: [name: string, index: number]
): [frp.Stream<AduState>, frp.Stream<AduEvent>] {
    type AduInput = adu.AduInput<cs.AmtrakAspect>;

    // MNRR aspect indicators
    const isMnrrAspect = frp.stepper(
        frp.compose(e.createOnSignalMessageStream(), frp.map(cs.isMnrrAspect), rejectUndefined()),
        false
    );

    // ADU computation
    const getDowngrades = (eventStream: frp.Stream<[AduInput, AduInput]>) =>
        frp.compose(
            eventStream,
            frp.map(([from, to]) => {
                // Emit events for cab signal drops regardless of MAS.
                const atcActive = frp.snapshot(atcCutIn);
                if (atcActive && aspectSuperiority(from) > aspectSuperiority(to)) {
                    return adu.AduEvent.AtcDowngrade;
                }

                // For MAS drops, emit a downgrade event for the enforcing system.
                const acsesActive = frp.snapshot(acsesCutIn);
                const fromMps = authorizedSpeedMps(from, atcActive, acsesActive);
                const toMps = authorizedSpeedMps(to, atcActive, acsesActive);
                if (fromMps !== undefined && toMps !== undefined && fromMps > toMps) {
                    return {
                        [adu.AduEnforcing.Atc]: adu.AduEvent.AtcDowngrade,
                        [adu.AduEnforcing.Acses]: adu.AduEvent.AcsesDowngrade,
                        [adu.AduEnforcing.None]: undefined,
                    }[to.enforcing];
                }

                return undefined;
            }),
            rejectUndefined()
        );
    const output$ = frp.compose(
        adu.create(
            cs.amtrakAtc,
            getDowngrades,
            false,
            equipmentSpeedMps,
            e,
            acknowledge,
            suppression,
            atcCutIn,
            acsesCutIn,
            pulseCodeControlValue
        ),
        frp.hub()
    );
    const output = frp.stepper(output$, undefined);
    const alarmPlaying = frp.liftN(output => (output?.atcAlarm || output?.acsesAlarm) ?? false, output);

    // Aspect display, including cab speed flash
    const aspectFlashStart$ = frp.compose(
        output$,
        frp.map(output => output.aspect),
        fsm<cs.AmtrakAspect | adu.AduAspect>(cs.amtrakAtc.restricting),
        frp.filter(([from, to]) => from !== to),
        frp.filter(([from, to]) => to === cs.AmtrakAspect.ApproachLimited || (!isCabSpeed(from) && isCabSpeed(to)))
    );
    const aspectFlashOn = frp.stepper(
        frp.compose(
            e.createPlayerWithKeyUpdateStream(),
            fx.eventStopwatchS(aspectFlashStart$),
            frp.map(stopwatchS => stopwatchS !== undefined && stopwatchS % (aspectFlashS * 2) < aspectFlashS)
        ),
        false
    );
    const aspect = frp.liftN(
        (output, flashOn) => {
            const outputAspect = output?.aspect ?? cs.AmtrakAspect.Restricting;
            return {
                [adu.AduAspect.Stop]: AduAspect.Stop,
                [cs.AmtrakAspect.Restricting]: AduAspect.Restrict,
                [cs.AmtrakAspect.Approach]: AduAspect.Approach,
                [cs.AmtrakAspect.ApproachMedium]: AduAspect.ApproachMedium,
                [cs.AmtrakAspect.ApproachLimited]: flashOn ? AduAspect.ApproachLimited : AduAspect.ApproachLimitedOff,
                [cs.AmtrakAspect.CabSpeed60]: flashOn ? AduAspect.CabSpeed60 : AduAspect.CabSpeed60Off,
                [cs.AmtrakAspect.CabSpeed80]: flashOn ? AduAspect.CabSpeed80 : AduAspect.CabSpeed80Off,
                [cs.AmtrakAspect.Clear100]: AduAspect.Clear100,
                [cs.AmtrakAspect.Clear125]: AduAspect.Clear125,
                [cs.AmtrakAspect.Clear150]: AduAspect.Clear150,
            }[outputAspect];
        },
        output,
        aspectFlashOn
    );

    // ATC & ACSES enforcing lights, including alarm flash
    const enforcingFlashOn = frp.stepper(
        frp.compose(
            e.createPlayerWithKeyUpdateStream(),
            fx.behaviorStopwatchS(alarmPlaying),
            frp.map(stopwatchS => stopwatchS !== undefined && stopwatchS % (enforcingFlashS * 2) > enforcingFlashS)
        ),
        false
    );
    const masEnforcing = frp.liftN(
        (output, flashOn) => {
            if (output?.atcAlarm) {
                return flashOn ? MasEnforcing.Atc : MasEnforcing.Off;
            } else if (output?.acsesAlarm) {
                return flashOn ? MasEnforcing.Acses : MasEnforcing.Off;
            } else {
                const enforcing = output?.enforcing ?? adu.AduEnforcing.None;
                return {
                    [adu.AduEnforcing.Atc]: MasEnforcing.Atc,
                    [adu.AduEnforcing.Acses]: MasEnforcing.Acses,
                    [adu.AduEnforcing.None]: MasEnforcing.Off,
                }[enforcing];
            }
        },
        output,
        enforcingFlashOn
    );

    // Combined MAS
    const masSpeedMph = frp.liftN(
        (output, atcCutIn, acsesCutIn) => {
            const atcMps = cs.amtrakAtc.getSpeedMps(output?.atcAspect ?? cs.AmtrakAspect.Restricting);
            const acsesMps = output?.acsesState?.curveSpeedMps ?? Infinity;
            let mps: number | undefined = undefined;
            if (atcCutIn && acsesCutIn) {
                mps = Math.min(atcMps, acsesMps);
            } else if (atcCutIn) {
                mps = atcMps;
            } else if (acsesCutIn) {
                mps = acsesMps;
            }
            return mps !== undefined ? Math.round(mps * c.mps.toMph) : undefined;
        },
        output,
        atcCutIn,
        acsesCutIn
    );

    // Output state and events
    const state$ = frp.compose(
        output$,
        frp.map((output): AduState => {
            return {
                aspect: frp.snapshot(aspect),
                isMnrrAspect: frp.snapshot(isMnrrAspect),
                masEnforcing: frp.snapshot(masEnforcing),
                masSpeedMph: frp.snapshot(masSpeedMph),
                timeToPenaltyS: output?.acsesState?.timeToPenaltyS,
                alarm: frp.snapshot(alarmPlaying),
                penaltyBrake: output?.penaltyBrake ?? false,
            };
        })
    );
    const events$ = frp.compose(
        output$,
        fsm<adu.AduOutput<cs.AmtrakAspect> | undefined>(undefined),
        frp.map(([from, to]) => {
            if (from === undefined || to === undefined) return undefined;

            // Emit events for cab signal upgrades regardless of MAS.
            const atcActive = frp.snapshot(atcCutIn);
            if (atcActive && aspectSuperiority(from) < aspectSuperiority(to)) {
                return AduEvent.Upgrade;
            }

            // Emit events for MAS increases too.
            const acsesActive = frp.snapshot(acsesCutIn);
            const fromMps = authorizedSpeedMps(from, atcActive, acsesActive);
            const toMps = authorizedSpeedMps(to, atcActive, acsesActive);
            if (fromMps !== undefined && toMps !== undefined && fromMps < toMps) {
                return AduEvent.Upgrade;
            }

            return undefined;
        }),
        rejectUndefined()
    );
    return [state$, events$];
}

function authorizedSpeedMps(input: adu.AduInput<cs.AmtrakAspect>, atcCutIn: boolean, acsesCutIn: boolean) {
    const atcMps = cs.amtrakAtc.getSpeedMps(input.atcAspect);
    const acsesMps = input.acsesState?.currentLimitMps ?? 0;
    if (atcCutIn && acsesCutIn) {
        return Math.min(atcMps, acsesMps);
    } else if (atcCutIn) {
        return atcMps;
    } else if (acsesCutIn) {
        return acsesMps;
    } else {
        return undefined;
    }
}

function aspectSuperiority(input: adu.AduInput<cs.AmtrakAspect>) {
    return adu.getAspectSuperiority(cs.amtrakAtc, input);
}

function isCabSpeed(aspect: cs.AmtrakAspect | adu.AduAspect) {
    return aspect === cs.AmtrakAspect.CabSpeed60 || aspect === cs.AmtrakAspect.CabSpeed80;
}
