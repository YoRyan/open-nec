/**
 * "Junk drawer" of special effect stuff.
 */

import * as c from "./constants";
import * as frp from "./frp";
import { FrpEngine } from "./frp-engine";
import { FrpEntity } from "./frp-entity";
import { fsm, mapBehavior, rejectRepeats } from "./frp-extra";
import { FrpVehicle, VehicleUpdate } from "./frp-vehicle";
import * as ps from "./power-supply";
import * as rw from "./railworks";

const sparkTickS = 0.2;
const brakeLightMessageFrequencyS = 1;
const brakeLightMessageId = 10101;
const lowPlatformMessageId = 10146;

/**
 * Track the time that has elapsed since a condition began to be true.
 * @param condition The condition to check.
 * @returns A transformer that emits the time, in seconds, since the condition
 * was true, or undefined if the condition is false.
 */
export function behaviorStopwatchS(
    condition: frp.Behavior<boolean>
): (eventStream: frp.Stream<VehicleUpdate>) => frp.Stream<number | undefined> {
    return eventStream =>
        frp.compose(
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
}

/**
 * Track the time that has elapsed since an event stream has emitted an event.
 * @param stream The input event stream.
 * @returns A transformer that emits the time, in seconds, since the last event
 * was emitted, or undefined if no event has been emitted.
 */
export function eventStopwatchS(
    stream: frp.Stream<any>
): (eventStream: frp.Stream<VehicleUpdate>) => frp.Stream<number | undefined> {
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
): (eventStream: frp.Stream<VehicleUpdate>) => frp.Stream<boolean> {
    type LoopAccum = number | undefined;

    return eventStream =>
        frp.compose(
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
): (eventStream: frp.Stream<VehicleUpdate>) => frp.Stream<boolean> {
    const trigger$ = frp.map(_ => undefined)(trigger);
    return eventStream =>
        frp.compose(
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
}

/**
 * Create a stream of pantograph spark effects.
 * @param v The engine or wagon with a pantograph.
 * @param electrification A behavior that returns the current electrification
 * state.
 * @returns The boolean stream, which is true when the spark should be drawn.
 */
export function createPantographSparkStream(
    v: FrpVehicle,
    electrification: frp.Behavior<Set<ps.Electrification>>
): frp.Stream<boolean> {
    return frp.compose(
        v.createPlayerUpdateStream(),
        frp.merge(v.createAiUpdateStream()),
        frp.map(u => Math.abs(u.speedMps)),
        frp.throttle(sparkTickS * 1000),
        frp.map(contactMps => {
            // Calibrated for 100 mph = 30 s, with a rapid falloff for lower speeds.
            const meanTimeBetweenS = 1341 / contactMps;
            return contactMps > c.stopSpeed && Math.random() < sparkTickS / meanTimeBetweenS;
        }),
        frp.map(spark => spark && ps.uniModeEngineHasPower(ps.EngineMode.Overhead, electrification))
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
    const brakePipePsi = () => eng.rv.GetControlValue("AirBrakePipePressurePSI", 0) as number;
    isPlayerBraking ??= frp.liftN(psi => psi < 100, brakePipePsi);

    // When under player control, send consist messages.
    const brakeMessage = frp.liftN(
        (applied, psi) => `${applied ? "1" : "0"}.10101${string.format("%03d", psi)}`,
        isPlayerBraking,
        brakePipePsi
    );
    const playerSend$ = frp.compose(
        eng.createPlayerWithKeyUpdateStream(),
        frp.throttle(brakeLightMessageFrequencyS * 1000),
        mapBehavior(brakeMessage)
    );
    playerSend$(msg => {
        eng.rv.SendConsistMessage(brakeLightMessageId, msg, rw.ConsistDirection.Forward);
        eng.rv.SendConsistMessage(brakeLightMessageId, msg, rw.ConsistDirection.Backward);
    });

    // When under player control, set our own brake lights; when under AI
    // control, read consist messages.
    return frp.compose(
        eng.createPlayerWithKeyUpdateStream(),
        mapBehavior(isPlayerBraking),
        frp.merge(createBrakeLightStreamForWagon(eng)),
        rejectRepeats()
    );
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
        frp.map(([, content]) => parseFloat(content) > 0.167)
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

/**
 * Set the the low- and high-platform modes of the Amfleet I enhancement pack
 * (and future compatible equipment).
 * @param eng The engine.
 * @param aiLow Use low-platform doors for AI trains.
 * @param playerLow A behavior that indicates the player selected low-platform
 * doors.
 */
export function setLowPlatformDoorsForEngine(eng: FrpEngine, aiLow: boolean, playerLow?: frp.Behavior<boolean>) {
    playerLow ??= () => (eng.rv.GetControlValue("Reverser", 0) as number) === 0;

    // Send consist messages.
    const playerSend$ = frp.compose(eng.createPlayerWithKeyUpdateStream(), mapBehavior(playerLow));
    const send$ = frp.compose(
        eng.createAiUpdateStream(),
        frp.map(_ => aiLow),
        frp.merge(playerSend$),
        rejectRepeats(),
        frp.map(low => (low ? "1" : "0"))
    );
    send$(msg => {
        eng.rv.SendConsistMessage(lowPlatformMessageId, msg, rw.ConsistDirection.Forward);
        eng.rv.SendConsistMessage(lowPlatformMessageId, msg, rw.ConsistDirection.Backward);
    });

    // Also forward messages in case other engines separate the player's engine
    // from the rest of the consist.
    const forward$ = frp.compose(
        eng.createOnConsistMessageStream(),
        frp.filter(([id]) => id === lowPlatformMessageId)
    );
    forward$(([, content, direction]) => {
        eng.rv.SendConsistMessage(lowPlatformMessageId, content, direction);
    });
}

/**
 * An animation wrapper that manages and tracks its current position.
 */
export class Animation {
    private target?: number = undefined;
    private readonly current: frp.Behavior<number>;

    constructor(e: FrpEntity, name: string, durationS: number) {
        const position$ = frp.compose(
            e.createUpdateStream(),
            frp.fold((current: number | undefined, dt) => {
                const target = this.target;
                if (current === undefined) {
                    // Jump instantaneously to the first value.
                    return target;
                } else if (target === undefined) {
                    return undefined;
                } else if (current > target) {
                    return Math.max(target, current - dt / durationS);
                } else if (current < target) {
                    return Math.min(target, current + dt / durationS);
                } else {
                    return current;
                }
            }, undefined),
            frp.map(current => current ?? 0),
            frp.hub()
        );
        this.current = frp.stepper(position$, 0);

        const setTime$ = frp.compose(
            position$,
            rejectRepeats(),
            frp.map(pos => pos * durationS)
        );
        setTime$(t => {
            e.re.SetTime(name, t);
        });
    }

    /**
     * Set the target position for this animation, scaled from 0 to 1.
     */
    setTargetPosition(position: number) {
        this.target = position;
    }

    /**
     * Get the current position of this animation, scaled from 0 to 1.
     */
    getPosition() {
        return frp.snapshot(this.current);
    }
}

/**
 * A light with a fade effect processed in the Update() callback.
 */
export class FadeableLight {
    private target?: number = undefined;
    private readonly current: frp.Behavior<number>;

    constructor(e: FrpEntity, fadeTimeS: number, id: string) {
        const light = new rw.Light(id);
        const [r, g, b] = light.GetColour();

        const intensity$ = frp.compose(
            e.createUpdateStream(),
            frp.fold((current: number | undefined, dt) => {
                const target = this.target;
                if (current === undefined) {
                    // Jump instantaneously to the first value.
                    return target;
                } else if (target === undefined) {
                    return undefined;
                } else if (current > target) {
                    return Math.max(target, current - dt / fadeTimeS);
                } else if (current < target) {
                    return Math.min(target, current + dt / fadeTimeS);
                } else {
                    return current;
                }
            }, undefined),
            frp.map(current => current ?? 0),
            rejectRepeats(),
            frp.hub()
        );
        this.current = frp.stepper(intensity$, 0);
        intensity$(i => {
            light.SetColour(i * r, i * g, i * b);
        });
    }

    /**
     * Set the target on/off state for this light.
     */
    setOnOff(onOff: boolean) {
        this.target = onOff ? 1 : 0;
    }

    /**
     * Get the current rendered intensity of this light, scaled from 0 to 1.
     */
    getIntensity() {
        return frp.snapshot(this.current);
    }
}
