/** @noSelfInFile */
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

const cabSpeedFlashS = 0.5;
const enforcingFlashS = 0.5;

/**
 * Creates a contemporary Amtrak-style ADU.
 */
export function create(
    e: FrpEngine,
    acknowledge: frp.Behavior<boolean>,
    suppression: frp.Behavior<boolean>,
    atcCutIn: frp.Behavior<boolean>,
    acsesCutIn: frp.Behavior<boolean>
): [frp.Stream<AduState>, frp.Stream<AduEvent>] {
    type AduInput = adu.AduInput<cs.AmtrakAspect>;

    // MNRR aspect indicators
    const isMnrrAspect$ = frp.compose(e.createOnSignalMessageStream(), frp.map(cs.isMnrrAspect), rejectUndefined());
    const isMnrrAspect = frp.stepper(isMnrrAspect$, false);

    // ADU computation
    const getDowngrades = (eventStream: frp.Stream<[AduInput, AduInput]>) =>
        frp.compose(
            eventStream,
            frp.map(([from, to]) => {
                if (frp.snapshot(atcCutIn) && aspectSuperiority(from) > aspectSuperiority(to)) {
                    return adu.AduEvent.AtcDowngrade;
                } else if (
                    from.enforcing !== undefined &&
                    to.enforcing !== undefined &&
                    from.enforcing.visibleSpeedMps > to.enforcing.visibleSpeedMps
                ) {
                    return to.enforcing === to.atc ? adu.AduEvent.AtcDowngrade : adu.AduEvent.AcsesDowngrade;
                } else {
                    return undefined;
                }
            }),
            rejectUndefined()
        );
    const output$ = frp.compose(
        adu.create(cs.amtrakAtc, getDowngrades, true, e, acknowledge, suppression, atcCutIn, acsesCutIn),
        frp.hub()
    );
    const initialOutput: adu.AduOutput<cs.AmtrakAspect> = {
        aspect: cs.amtrakAtc.initialAspect,
        state: adu.AduMode.Normal,
    };
    const output = frp.stepper(output$, initialOutput);

    const isAlarm = frp.liftN(output => {
        if (output.state === adu.AduMode.Normal) {
            return false;
        } else {
            const [mode] = output.state;
            if (mode === adu.AduMode.AtcOverspeed) {
                const [, startS] = output.state;
                // Check for suppression.
                return startS !== Infinity;
            } else {
                return true;
            }
        }
    }, output);

    // Cab speed flash
    const cabSpeedFlash$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        fx.stopwatchS(
            frp.liftN(
                output => output.aspect === cs.AmtrakAspect.CabSpeed60 || output.aspect === cs.AmtrakAspect.CabSpeed80,
                output
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
        output$,
        frp.map((output): AduState => {
            const alarm = frp.snapshot(isAlarm);

            const cabSpeedOn = frp.snapshot(cabSpeedFlashOn);
            const aspect = {
                [adu.AduAspect.Stop]: AduAspect.Stop,
                [cs.AmtrakAspect.Restricting]: AduAspect.Restrict,
                [cs.AmtrakAspect.Approach]: AduAspect.Approach,
                [cs.AmtrakAspect.ApproachMedium30]: AduAspect.ApproachMedium30,
                [cs.AmtrakAspect.ApproachMedium45]: AduAspect.ApproachMedium45,
                [cs.AmtrakAspect.CabSpeed60]: cabSpeedOn ? AduAspect.CabSpeed60 : AduAspect.CabSpeed60Off,
                [cs.AmtrakAspect.CabSpeed80]: cabSpeedOn ? AduAspect.CabSpeed80 : AduAspect.CabSpeed80Off,
                [cs.AmtrakAspect.Clear100]: AduAspect.Clear100,
                [cs.AmtrakAspect.Clear125]: AduAspect.Clear125,
                [cs.AmtrakAspect.Clear150]: AduAspect.Clear150,
            }[output.aspect];

            const enforcingOn = frp.snapshot(enforcingFlashOn);
            let masEnforcing: MasEnforcing;
            if (output.state === adu.AduMode.Normal) {
                if (output.enforcing === undefined) {
                    masEnforcing = MasEnforcing.Off;
                } else if (output.enforcing === output.atc) {
                    masEnforcing = MasEnforcing.Atc;
                } else {
                    masEnforcing = MasEnforcing.Acses;
                }
            } else if (alarm && !enforcingOn) {
                masEnforcing = MasEnforcing.Off;
            } else {
                const [mode] = output.state;
                masEnforcing =
                    mode === adu.AduMode.AtcOverspeed || mode === adu.AduMode.AtcPenalty
                        ? MasEnforcing.Atc
                        : MasEnforcing.Acses;
            }

            const masSpeedMps = output.enforcing?.visibleSpeedMps;
            const masSpeedMph = masSpeedMps === undefined ? undefined : masSpeedMps * c.mps.toMph;

            let penaltyBrake: boolean;
            if (output.state === adu.AduMode.Normal) {
                penaltyBrake = false;
            } else {
                const [mode] = output.state;
                penaltyBrake = mode === adu.AduMode.AtcPenalty || mode === adu.AduMode.AcsesPenalty;
            }

            return {
                aspect,
                isMnrrAspect: frp.snapshot(isMnrrAspect),
                masEnforcing,
                masSpeedMph,
                timeToPenaltyS: output.enforcing?.timeToPenaltyS,
                alarm,
                penaltyBrake,
            };
        })
    );
    const events$ = frp.compose(
        output$,
        fsm(initialOutput),
        frp.map(([from, to]) => {
            if (frp.snapshot(atcCutIn) && aspectSuperiority(from) < aspectSuperiority(to)) {
                return AduEvent.Upgrade;
            } else if (
                from.enforcing !== undefined &&
                to.enforcing !== undefined &&
                from.enforcing.visibleSpeedMps < to.enforcing.visibleSpeedMps
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

function aspectSuperiority(input: adu.AduInput<cs.AmtrakAspect>) {
    const aspect = input.aspect;
    return aspect === adu.AduAspect.Stop ? -1 : cs.amtrakAtc.getSuperiority(aspect);
}
