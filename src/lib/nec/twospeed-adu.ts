/**
 * A generic two-speed ADU with separate ATC and ACSES speeds.
 */

import * as adu from "./adu";
import * as c from "lib/constants";
import * as cs from "./cabsignals";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { fsm, rejectUndefined } from "lib/frp-extra";

/**
 * Represents the state of the ADU and the safety systems it is attached to.
 */
export type AduState<A> = {
    aspect: A | adu.AduAspect;
    aspectFlashOn: boolean;
    trackSpeedMph?: number;
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

/**
 * Creates a two-speed ADU.
 */
export function create<A>(
    atc: cs.AtcSystem<A>,
    e: FrpEngine,
    acknowledge: frp.Behavior<boolean>,
    suppression: frp.Behavior<boolean>,
    atcCutIn: frp.Behavior<boolean>,
    acsesCutIn: frp.Behavior<boolean>,
    equipmentSpeedMps: number,
    pulseCodeControlValue?: [name: string, index: number]
): [frp.Stream<AduState<A>>, frp.Stream<AduEvent>] {
    type AduInput = adu.AduInput<A>;

    function aspectSuperiority(input: adu.AduInput<A>) {
        return adu.getAspectSuperiority(atc, input);
    }

    // ADU computation
    const getDowngrades = (eventStream: frp.Stream<[AduInput, AduInput]>) =>
        frp.compose(
            eventStream,
            frp.map(([from, to]) => {
                const acsesFromMps = from.acsesState?.stepSpeedMps;
                const acsesToMps = to.acsesState?.stepSpeedMps;
                const acsesValid = acsesFromMps !== undefined && acsesToMps !== undefined;

                if (frp.snapshot(atcCutIn) && aspectSuperiority(from) > aspectSuperiority(to)) {
                    return adu.AduEvent.AtcDowngrade;
                } else if (acsesValid && acsesFromMps > acsesToMps) {
                    return adu.AduEvent.AcsesDowngrade;
                } else {
                    return undefined;
                }
            }),
            rejectUndefined()
        );
    const output$ = frp.compose(
        adu.create(
            atc,
            getDowngrades,
            true,
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

    // Aspect display flash
    const aspectFlashOn = frp.stepper(frp.compose(output$, adu.mapAspectFlashOn(atc, e)), false);

    // ACSES track speed
    const trackSpeedMph = frp.liftN(output => {
        const mps = output?.acsesState?.stepSpeedMps;
        return mps !== undefined ? mps * c.mps.toMph : undefined;
    }, output);

    // Output state and events
    const state$ = frp.compose(
        output$,
        frp.map((output): AduState<A> => {
            return {
                aspect: output.aspect,
                aspectFlashOn: frp.snapshot(aspectFlashOn),
                trackSpeedMph: frp.snapshot(trackSpeedMph),
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
        fsm<adu.AduOutput<A> | undefined>(undefined),
        frp.map(([from, to]) => {
            if (from === undefined || to === undefined) return undefined;

            const acsesFromMps = from.acsesState?.currentLimitMps;
            const acsesToMps = to.acsesState?.currentLimitMps;
            const acsesValid = acsesFromMps !== undefined && acsesToMps !== undefined;

            if (frp.snapshot(atcCutIn) && aspectSuperiority(from) < aspectSuperiority(to)) {
                return AduEvent.Upgrade;
            } else if (acsesValid && acsesFromMps < acsesToMps) {
                return AduEvent.Upgrade;
            } else {
                return undefined;
            }
        }),
        rejectUndefined()
    );
    return [state$, events$];
}
