/**
 * An NJ Transit ADU with ATC and ASES-I.
 */

import * as c from "lib/constants";
import * as frp from "lib/frp";
import { fsm, rejectUndefined } from "lib/frp-extra";
import * as adu from "./adu";
import * as cs from "./cabsignals";

/**
 * Represents the state of the ADU and the safety systems it is attached to.
 */
export type AduState = {
    clearAspect: boolean;
    masSpeedMph?: number;
    excessSpeedMph?: number;
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

type AduInput = adu.AduInput<cs.NjTransitAspect>;

/**
 * Creates an NJ Transit ADU.
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
    // Adu computation
    const getDowngrades = (eventStream: frp.Stream<[AduInput, AduInput]>) =>
        frp.compose(
            eventStream,
            frp.map(([from, to]) => {
                // Emit a downgrade event for the enforcing system.
                const cutIns: [boolean, boolean] = [frp.snapshot(atcCutIn), frp.snapshot(acsesCutIn)];
                const fromMps = authorizedSpeedMps(from, ...cutIns);
                const toMps = authorizedSpeedMps(to, ...cutIns);
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
            atc: cs.njTransitAtc,
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

    // Clear aspect indicator for ATC-only mode
    const clearAspect = frp.liftN(
        (output, acsesCutIn) => !acsesCutIn && output?.aspect === cs.NjTransitAspect.Clear,
        output,
        acsesCutIn
    );

    // Combined MAS (green tape)
    const masSpeedMph = frp.liftN(
        (output, atcCutIn, acsesCutIn) => {
            const atcMps = cs.njTransitAtc.getSpeedMps(output?.atcAspect ?? cs.NjTransitAspect.Restricting);
            const acsesMps = output?.acsesState?.curveSpeedMps ?? Infinity;
            let mps: number | undefined = undefined;
            if (atcCutIn && acsesCutIn) {
                mps = Math.min(atcMps, acsesMps);
            } else if (atcCutIn) {
                // Don't show the tape with a clear aspect in ATC-only mode.
                mps = output?.aspect === cs.NjTransitAspect.Clear ? undefined : atcMps;
            } else if (acsesCutIn) {
                mps = acsesMps;
            }
            return mps !== undefined ? mps * c.mps.toMph : undefined;
        },
        output,
        atcCutIn,
        acsesCutIn
    );

    // Excess speed (red tape)
    const excessSpeedMph = frp.liftN(
        (masSpeedMph, speedoMps) => {
            if (masSpeedMph === undefined) {
                return undefined;
            } else {
                const aSpeedoMph = Math.abs(speedoMps * c.mps.toMph);
                return aSpeedoMph > masSpeedMph ? aSpeedoMph : undefined;
            }
        },
        masSpeedMph,
        e.createSpeedometerMpsBehavior()
    );

    // Output state and events
    const state$ = frp.compose(
        output$,
        frp.map((output): AduState => {
            return {
                clearAspect: frp.snapshot(clearAspect),
                masSpeedMph: frp.snapshot(masSpeedMph),
                excessSpeedMph: frp.snapshot(excessSpeedMph),
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
        fsm<adu.AduOutput<cs.NjTransitAspect> | undefined>(undefined),
        frp.map(([from, to]) => {
            if (from === undefined || to === undefined) return undefined;

            const cutIns: [boolean, boolean] = [frp.snapshot(atcCutIn), frp.snapshot(acsesCutIn)];
            const fromMps = authorizedSpeedMps(from, ...cutIns);
            const toMps = authorizedSpeedMps(to, ...cutIns);
            if (fromMps !== undefined && toMps !== undefined && fromMps < toMps) {
                return AduEvent.Upgrade;
            }

            return undefined;
        }),
        rejectUndefined()
    );
    return [state$, events$];
}

function authorizedSpeedMps(input: AduInput, atcCutIn: boolean, acsesCutIn: boolean) {
    const atcMps = cs.njTransitAtc.getSpeedMps(input.atcAspect);
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
