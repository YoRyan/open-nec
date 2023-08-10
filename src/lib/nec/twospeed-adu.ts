/**
 * A generic two-speed ADU with separate ATC and ACSES speeds.
 */

import * as adu from "./adu";
import * as c from "lib/constants";
import * as cs from "./cabsignals";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { fsm, rejectUndefined } from "lib/frp-extra";
import * as fx from "lib/special-fx";

/**
 * Represents the state of the ADU and the safety systems it is attached to.
 */
export type AduState<A> = {
    aspect: A | adu.AduAspect;
    aspectFlashOn: boolean;
    masEnforcing: MasEnforcing;
    trackSpeedMph?: number;
    atcAlarm: boolean;
    acsesAlarm: boolean;
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
    const alarmPlaying = frp.liftN(output => (output?.atcAlarm || output?.acsesAlarm) ?? false, output);

    // Aspect display, including cab speed flash
    const aspectFlashStart$ = frp.compose(
        output$,
        frp.map(output => (output.aspect !== adu.AduAspect.Stop ? output.aspect : undefined)),
        rejectUndefined(),
        fsm(atc.restricting),
        frp.filter(([from, to]) => from !== to),
        frp.filter(([from, to]) => atc.restartFlash(from, to))
    );
    const aspectFlashOn = frp.stepper(
        frp.compose(
            e.createPlayerWithKeyUpdateStream(),
            fx.eventStopwatchS(aspectFlashStart$),
            frp.map(stopwatchS => stopwatchS !== undefined && stopwatchS % (aspectFlashS * 2) < aspectFlashS)
        ),
        false
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
                masEnforcing: frp.snapshot(masEnforcing),
                trackSpeedMph: frp.snapshot(trackSpeedMph),
                atcAlarm: output.atcAlarm,
                acsesAlarm: output.acsesAlarm,
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
