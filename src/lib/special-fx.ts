/** @noSelfInFile */
/**
 * "Junk drawer" of special effect stuff.
 */

import * as c from "./constants";
import * as frp from "./frp";
import { FrpEngine } from "./frp-engine";
import { fsm, mapBehavior } from "./frp-extra";
import { AiUpdate, FrpVehicle, PlayerUpdate } from "./frp-vehicle";
import * as ps from "./power-supply";
import * as rw from "./railworks";

const sparkTickS = 0.2;
const brakeLightMessageId = 10101;

/**
 * Track the time that has elapsed since a condition began to be true.
 * @param condition The condition to check.
 * @returns A transformer that emits the time, in seconds, since the condition
 * was true, or undefined if the condition is false.
 */
export function behaviorStopwatchS(
    condition: frp.Behavior<boolean>
): (eventStream: frp.Stream<AiUpdate | PlayerUpdate>) => frp.Stream<number | undefined> {
    return eventStream => {
        return frp.compose(
            eventStream,
            frp.fold((stopwatchS: number | undefined, update) => {
                if (!frp.snapshot(condition)) {
                    return undefined;
                } else if (stopwatchS === undefined) {
                    return 0;
                } else {
                    return stopwatchS + update.dt;
                }
            }, undefined)
        );
    };
}

/**
 * Track the time that has elapsed since an event stream has emitted an event.
 * @param stream The input event stream.
 * @returns A transformer that emits the time, in seconds, since the last event
 * was emitted, or undefined if no event has been emitted.
 */
export function eventStopwatchS(
    stream: frp.Stream<any>
): (eventStream: frp.Stream<AiUpdate | PlayerUpdate>) => frp.Stream<number | undefined> {
    return eventStream =>
        frp.compose(
            stream,
            frp.map(_ => undefined),
            frp.merge(eventStream),
            frp.fold((stopwatchS: number | undefined, update) => {
                if (update === undefined) {
                    return 0;
                } else if (stopwatchS !== undefined) {
                    return stopwatchS + update.dt;
                } else {
                    return undefined;
                }
            }, undefined)
        );
}

/**
 * Create a looping sound out of a sound that isn't configured to loop.
 * @param loopS The time to play the sound for.
 * @param isPlaying A behavior to play or halt the sound.
 * @returns A transformer that accepts any update stream.
 */
export function loopSound(
    loopS: number,
    isPlaying: frp.Behavior<boolean>
): (eventStream: frp.Stream<AiUpdate | PlayerUpdate>) => frp.Stream<boolean> {
    type LoopAccum = number | undefined;

    return eventStream => {
        return frp.compose(
            eventStream,
            frp.fold((accum: LoopAccum, update) => {
                if (accum !== undefined && accum > loopS) {
                    // Return false once, so that the sound loops.
                    return undefined;
                } else if (frp.snapshot(isPlaying)) {
                    return accum === undefined ? 0 : accum + update.dt;
                } else {
                    return undefined;
                }
            }, undefined),
            frp.map(accum => accum !== undefined)
        );
    };
}

/**
 * Create a one-shot sound from a stream of events.
 * @param playS The time to play the sound for.
 * @param trigger The stream of events to trigger the sound.
 * @returns A transformer that accepts any update stream.
 */
export function triggerSound(
    playS: number,
    trigger: frp.Stream<any>
): (eventStream: frp.Stream<AiUpdate | PlayerUpdate>) => frp.Stream<boolean> {
    const trigger$ = frp.map(_ => undefined)(trigger);
    return eventStream => {
        return frp.compose(
            eventStream,
            frp.merge(trigger$),
            frp.fold((remainingS, input) => {
                if (input === undefined) {
                    return playS;
                } else {
                    return Math.max(remainingS - input.dt, 0);
                }
            }, 0),
            // Checking against playS gives us one frame to reset the sound for
            // repeated triggers.
            frp.map(remainingS => remainingS > 0 && remainingS !== playS)
        );
    };
}

/**
 * Create a stream of pantograph spark effects for a pure electric engine. For
 * player engines, a behavior tells us the status of the pantograph. For AI
 * engines, we assume that if the train is moving, we should show sparks.
 * @param v The engine or wagon with a pantograph.
 * @param electrification A behavior that returns the current electrification
 * state.
 * @param isPlayerContact A behavior that is true when the pantograph is
 * connected to the electrification system and drawing power.
 * @returns The boolean stream, which is true when the spark should be drawn.
 */
export function createUniModePantographSparkStream(
    v: FrpVehicle,
    electrification: frp.Behavior<Set<ps.Electrification>>,
    isPlayerContact: frp.Behavior<boolean>
): frp.Stream<boolean> {
    const playerSparks = () =>
        ps.uniModeEngineHasPower(ps.EngineMode.Overhead, electrification) && frp.snapshot(isPlayerContact);
    return createPantographSparkStream(v, playerSparks, () => true);
}

function createPantographSparkStream(
    v: FrpVehicle,
    showPlayerSparks: frp.Behavior<boolean>,
    showAiSparks: frp.Behavior<boolean>
): frp.Stream<boolean> {
    const playerSparkSpeed$ = frp.compose(
        v.createPlayerUpdateStream(),
        frp.map(pu => (frp.snapshot(showPlayerSparks) ? Math.abs(pu.speedMps) : 0))
    );
    return frp.compose(
        v.createAiUpdateStream(),
        frp.map(au => (frp.snapshot(showAiSparks) ? Math.abs(au.speedMps) : 0)),
        frp.merge(playerSparkSpeed$),
        frp.throttle(sparkTickS * 1000),
        frp.map(contactMps => {
            // Calibrated for 100 mph = 30 s, with a rapid falloff for lower speeds.
            const meanTimeBetweenS = 1341 / contactMps;
            return contactMps > c.stopSpeed && Math.random() < sparkTickS / meanTimeBetweenS;
        })
    );
}

/**
 * Create a brake status indicator stream for driveable rail vehicles.
 * Transmits and forwards brake status across the consist.
 * @param eng The engine.
 * @param isPlayerBraking A behavior that, when true, indicates the brake lights
 * should show "applied."
 * @returns The new stream, which emits true if the brake light should show
 * "applied."
 */
export function createBrakeLightStreamForEngine(
    eng: FrpEngine,
    isPlayerBraking?: frp.Behavior<boolean>
): frp.Stream<boolean> {
    isPlayerBraking ??= () => (eng.rv.GetControlValue("AirBrakePipePressurePSI", 0) as number) < 100;
    const playerStatus$ = frp.compose(eng.createPlayerWithKeyUpdateStream(), mapBehavior(isPlayerBraking), frp.hub());

    // When under player control, send consist messages.
    const playerSend$ = frp.compose(
        playerStatus$,
        fsm(false),
        frp.filter(([from, to]) => from !== to)
    );
    playerSend$(([, applied]) => {
        const content = applied ? "1" : "0";
        eng.rv.SendConsistMessage(brakeLightMessageId, content, rw.ConsistDirection.Forward);
        eng.rv.SendConsistMessage(brakeLightMessageId, content, rw.ConsistDirection.Backward);
    });

    return frp.compose(playerStatus$, frp.merge(createBrakeLightStreamForWagon(eng)));
}

/**
 * Create a brake status indicator stream for undriveable rail vehicles.
 * Forwards brake status across the consist.
 * @param v The rail vehicle.
 * @returns The new stream, which emits true if the brake light should show
 * "applied."
 */
export function createBrakeLightStreamForWagon(v: FrpVehicle): frp.Stream<boolean> {
    // For player trains, parse and forward consist messages.
    const consistMessage$ = frp.compose(
        v.createOnConsistMessageStream(),
        frp.filter(([id]) => id === brakeLightMessageId)
    );
    const fromConsist$ = frp.compose(
        consistMessage$,
        frp.map(([, content]) => parseInt(content) > 0.5)
    );
    consistMessage$(([, content, direction]) => {
        v.rv.SendConsistMessage(brakeLightMessageId, content, direction);
    });

    return frp.compose(
        v.createAiUpdateStream(),
        // For AI trains, use a simple speed check.
        frp.map(au => Math.abs(au.speedMps) < 4 * c.mph.toMps),
        // It may take another state change for the brake status to be
        // transmitted by the player engine, but that's acceptable.
        frp.merge(fromConsist$)
    );
}
