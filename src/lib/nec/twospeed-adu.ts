/** @noSelfInFile */
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
    aspect: adu.AduAspect | A;
    aspectFlashOn: boolean;
    masEnforcing: MasEnforcing;
    trackSpeedMph?: number;
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
        const aspect = input.aspect;
        return aspect === adu.AduAspect.Stop ? -1 : atc.getSuperiority(aspect);
    }

    // ADU computation
    const getDowngrades = (eventStream: frp.Stream<[AduInput, AduInput]>) =>
        frp.compose(
            eventStream,
            frp.map(([from, to]) => {
                if (frp.snapshot(atcCutIn) && aspectSuperiority(from) > aspectSuperiority(to)) {
                    return adu.AduEvent.AtcDowngrade;
                } else if (
                    from.acses !== undefined &&
                    to.acses !== undefined &&
                    from.acses.visibleSpeedMps > to.acses.visibleSpeedMps
                ) {
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
    const initialOutput: adu.AduOutput<A> = {
        aspect: atc.initialAspect,
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

    // Cab aspect flash
    const aspectFlashStart$ = frp.compose(
        output$,
        frp.map(output => (output.aspect !== adu.AduAspect.Stop ? output.aspect : undefined)),
        rejectUndefined(),
        fsm(atc.initialAspect),
        frp.filter(([from, to]) => from !== to),
        frp.filter(([from, to]) => atc.restartFlash(from, to))
    );
    const aspectFlash$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        fx.eventStopwatchS(aspectFlashStart$),
        frp.map(stopwatchS => stopwatchS !== undefined && stopwatchS % (aspectFlashS * 2) < aspectFlashS)
    );
    const aspectFlashOn = frp.stepper(aspectFlash$, false);

    // Enforcing light flash
    const enforcingFlash$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        fx.behaviorStopwatchS(isAlarm),
        frp.map(stopwatchS => stopwatchS !== undefined && stopwatchS % (enforcingFlashS * 2) > enforcingFlashS)
    );
    const enforcingFlashOn = frp.stepper(enforcingFlash$, false);

    const state$ = frp.compose(
        output$,
        frp.map((output): AduState<A> => {
            const alarm = frp.snapshot(isAlarm);

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

            const trackSpeedMps = output.acses?.visibleSpeedMps;
            const trackSpeedMph = trackSpeedMps === undefined ? undefined : trackSpeedMps * c.mps.toMph;

            let penaltyBrake: boolean;
            if (output.state === adu.AduMode.Normal) {
                penaltyBrake = false;
            } else {
                const [mode] = output.state;
                penaltyBrake = mode === adu.AduMode.AtcPenalty || mode === adu.AduMode.AcsesPenalty;
            }

            return {
                aspect: output.aspect,
                aspectFlashOn: frp.snapshot(aspectFlashOn),
                masEnforcing,
                trackSpeedMph,
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
                from.acses !== undefined &&
                to.acses !== undefined &&
                from.acses.visibleSpeedMps < to.acses.visibleSpeedMps
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
