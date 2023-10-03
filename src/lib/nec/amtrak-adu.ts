/**
 * A contemporary, single-speed Amtrak ADU with ATC and ACSES-II.
 */

import * as adu from "./adu";
import * as c from "lib/constants";
import * as cs from "./cabsignals";
import * as frp from "lib/frp";
import { fsm, rejectUndefined } from "lib/frp-extra";

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
    masSpeedMph?: number;
    timeToPenaltyS?: number;
    atcAlarm: boolean;
    atcLamp: boolean;
    acsesAlarm: boolean;
    acsesLamp: boolean;
    penaltyBrake: boolean;
};

/**
 * Represents a discrete event emitted by the ADU.
 */
export enum AduEvent {
    Upgrade,
}

type AduInput = adu.AduInput<cs.AmtrakAspect>;

/**
 * Creates a contemporary Amtrak-style ADU.
 */
export function create({
    e,
    acknowledge,
    suppression,
    atcCutIn,
    acsesCutIn,
    equipmentSpeedMps,
    pulseCodeControlValue,
}: adu.CommonAduOptions): [frp.Stream<AduState>, frp.Stream<AduEvent>] {
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
        adu.create({
            atc: cs.amtrakAtc,
            getEvents: getDowngrades,
            acsesStepsDown: false,
            equipmentSpeedMps,
            e,
            acknowledge,
            suppression,
            atcCutIn,
            acsesCutIn,
            pulseCodeControlValue,
        }),
        frp.hub()
    );
    const output = frp.stepper(output$, undefined);

    // Aspect display, including aspect flash
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
        frp.stepper(frp.compose(output$, adu.mapAspectFlashOn(cs.amtrakAtc, e)), false)
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
                masSpeedMph: frp.snapshot(masSpeedMph),
                timeToPenaltyS: output.acsesState?.timeToPenaltyS,
                atcAlarm: output.atcAlarm,
                atcLamp: output.atcLamp,
                acsesAlarm: output.acsesAlarm,
                acsesLamp: output.acsesLamp,
                penaltyBrake: output.penaltyBrake,
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

function aspectSuperiority(input: AduInput) {
    return adu.getAspectSuperiority(cs.amtrakAtc, input);
}

function authorizedSpeedMps(input: AduInput, atcCutIn: boolean, acsesCutIn: boolean) {
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
