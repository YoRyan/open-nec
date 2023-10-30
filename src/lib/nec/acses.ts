/**
 * Advanced Civil Speed Enforcement System for the Northeast Corridor.
 */

import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { rejectUndefined } from "lib/frp-extra";
import { VehicleUpdate } from "lib/frp-vehicle";
import * as rw from "lib/railworks";
import * as cs from "./cabsignals";

export type AcsesState = {
    /**
     * The "true" braking curve speed, without any margin or miscellaneous speed
     * enforcement applied.
     */
    curveSpeedMps: number;
    /**
     * The alert curve speed.
     */
    alertCurveMps: number;
    /**
     * The penalty curve speed.
     */
    penaltyCurveMps: number;
    /**
     * The speed presented to the engineer for ACSES-I systems with no advance
     * braking curve countdown.
     */
    stepSpeedMps: number;
    /**
     * The speed limit in effect for the current section of track.
     */
    currentLimitMps: number;
    /**
     * The speed limit that will go into effect after the current downward
     * slope, if any.
     */
    nextLimitMps?: number;
    /**
     * The time to penalty displayed to the engineer.
     */
    timeToPenaltyS?: number;
};

const minTrackSpeedUpgradeDistM = 350 * c.ft.toM; // about 4 car lengths
// Taken from NJT documentation.
const alertMarginMps = 3 * c.mph.toMps;
const penaltyMarginMps = 6 * c.mph.toMps;

/**
 * Distance traveled since the last search along with a collection of
 * statelessly sensed objects.
 */
type Reading<T> = [traveledM: number, sensed: Sensed<T>[]];
/**
 * A distance relative to the rail vehicle along with the object sensed.
 */
type Sensed<T> = [distanceM: number, object: T];
type SpeedPost = { type: rw.SpeedLimitType; speedMps: number };
type TwoSidedSpeedPost = { before: SpeedPost | undefined; after: SpeedPost | undefined };
type Signal = { proState: rw.ProSignalState };

const penaltyCurveMps2 = -1 * c.mph.toMps;
const stopReleaseMps = 15 * c.mph.toMps;
const iterateStepM = 0.01;

/**
 * Create a new ACSES instance.
 * @param e The player's engine.
 * @param cutIn A behavior that indicates ACSES is cut in.
 * @param stepsDown If true, exceeding the alert curve at any time reveals the
 * advance speed limit and lowers the curve accordingly.
 * @param equipmentSpeedMps The maximum consist speed limit.
 * @param atcCutIn A behavior that indicates the state of the ATC cut in
 * control.
 * @returns An event stream that communicates all state for this system.
 */
export function create({
    e,
    cutIn,
    stepsDown,
    equipmentSpeedMps,
    atcCutIn,
}: {
    e: FrpEngine;
    cutIn: frp.Behavior<boolean>;
    stepsDown: boolean;
    equipmentSpeedMps: number;
    atcCutIn: frp.Behavior<boolean>;
}): frp.Stream<AcsesState> {
    type PiecesAccum = {
        speedPostViolated: Map<number, boolean>;
        piecesByCurveSpeed: Piece[];
    };

    const authorizedMps = frp.liftN(
        atcCutIn => (atcCutIn ? equipmentSpeedMps : Math.min(equipmentSpeedMps, 79 * c.mph.toMps)),
        atcCutIn
    );
    const speedoMps = () => (e.rv.GetControlValue("SpeedometerMPH") as number) * c.mph.toMps;

    // Process positive stop signal messages.
    const ptsDistanceM = frp.stepper(
        frp.compose(
            e.createOnSignalMessageStream(),
            frp.map(msg => cs.toPositiveStopDistanceM(msg)),
            rejectUndefined()
        ),
        false
    );
    const enablePts = frp.stepper(
        frp.compose(
            e.createOnSignalMessageStream(),
            frp.map(cs.toPulseCode),
            rejectUndefined(),
            frp.map(pc => cs.fourAspectAtc.fromPulseCode(pc)),
            frp.map(aspect => aspect === cs.FourAspect.Restricting)
        ),
        true
    );

    // Speed post and signal trackers
    const speedPostIndex$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        mapSpeedPostsStream(e),
        indexObjectsSensedByDistance(cutIn),
        frp.hub()
    );
    const speedPostIndex = frp.stepper(speedPostIndex$, new Map<number, Sensed<SpeedPost>>());
    const signalIndex = frp.stepper(
        frp.compose(e.createPlayerWithKeyUpdateStream(), mapSignalStream(e), indexObjectsSensedByDistance(cutIn)),
        new Map<number, Sensed<Signal>>()
    );

    return frp.compose(
        speedPostIndex$,
        createTrackSpeedStream(
            e,
            () => e.rv.GetCurrentSpeedLimit()[0],
            () => e.rv.GetConsistLength(),
            cutIn
        ),
        frp.fold<PiecesAccum | undefined, number | undefined>((accum, trackSpeedMps) => {
            if (trackSpeedMps === undefined) return undefined;

            const playerSpeedMps = frp.snapshot(speedoMps);
            const curveMps2 = penaltyCurveMps2 * brakingCurveGradientFactor(e.rv.GetGradient());

            let pieces: Piece[] = [];

            // Add track and equipment speed limit.
            const currentMps = Math.min(trackSpeedMps, frp.snapshot(authorizedMps));
            pieces.push(constantSpeedPiece(currentMps));

            // Add advance speed limits.
            let speedPostViolated = new Map<number, boolean>();
            for (const [id, [distanceM, post]] of frp.snapshot(speedPostIndex)) {
                if (isHazardRightWay(distanceM, playerSpeedMps)) {
                    const previouslyViolated = accum?.speedPostViolated.get(id) ?? false;
                    const makePiece =
                        stepsDown && previouslyViolated ? advanceLimitViolatedPiece : advanceLimitNotViolatedPiece;
                    const slope = makePiece([distanceM, post], curveMps2);
                    pieces.push(slope);

                    const violated = Math.abs(playerSpeedMps) > slope.alertCurveMps;
                    speedPostViolated.set(id, previouslyViolated || violated);
                }
            }

            // Add stop signals if the cab signals are at Restricting.
            if (frp.snapshot(enablePts)) {
                for (const [, [distanceM, signal]] of frp.snapshot(signalIndex)) {
                    const isStopSignal = signal.proState === rw.ProSignalState.Red;
                    if (isStopSignal && isHazardRightWay(distanceM, playerSpeedMps)) {
                        const slope = positiveStopPiece(
                            [distanceM, signal],
                            curveMps2,
                            frp.snapshot(ptsDistanceM),
                            playerSpeedMps
                        );
                        pieces.push(slope);
                    }
                }
            }

            // Sort by curve speed.
            pieces.sort((a, b) => a.curveSpeedMps - b.curveSpeedMps);
            return { speedPostViolated, piecesByCurveSpeed: pieces };
        }, undefined),
        frp.map((accum): AcsesState => {
            if (accum !== undefined) {
                const pieces = accum.piecesByCurveSpeed;
                const inForce = pieces[0];
                return {
                    curveSpeedMps: inForce.curveSpeedMps,
                    alertCurveMps: inForce.alertCurveMps,
                    penaltyCurveMps: inForce.penaltyCurveMps,
                    stepSpeedMps: firstDefinedProperty(pieces, p => p.stepSpeedMps) ?? Infinity,
                    currentLimitMps: firstDefinedProperty(pieces, p => p.currentLimitMps) ?? Infinity,
                    nextLimitMps: firstDefinedProperty(pieces, p => p.nextLimitMps),
                    timeToPenaltyS: firstDefinedProperty(pieces, p => p.timeToPenaltyS),
                };
            } else {
                // Sane values for when ACSES is cut out
                return {
                    curveSpeedMps: 0,
                    alertCurveMps: Infinity,
                    penaltyCurveMps: Infinity,
                    stepSpeedMps: 0,
                    currentLimitMps: 0,
                };
            }
        })
    );
}

/**
 * Create a continuous stream of searches for speed limit changes.
 * @param e The rail vehicle to sense objects with.
 * @returns The new event stream of speed post readings.
 */
function mapSpeedPostsStream(e: FrpEngine): (eventStream: frp.Stream<VehicleUpdate>) => frp.Stream<Reading<SpeedPost>> {
    type FilterAccum = [hasTypeTwoLimits: boolean, reading: Reading<SpeedPost>];

    const nLimits = 3;
    const hugeSpeed = 999;
    return eventStream => {
        return frp.compose(
            eventStream,
            frp.map((pu): Reading<SpeedPost> => {
                const speedMpS = e.rv.GetSpeed(); // Must be as precise as possible.
                const traveledM = speedMpS * pu.dt;
                let posts: Sensed<SpeedPost>[] = [];
                for (const [distanceM, post] of iterateSpeedLimitsBackward(e, nLimits)) {
                    if (post.speedMps < hugeSpeed) {
                        posts.push([-distanceM, post]);
                    }
                }
                for (const [distanceM, post] of iterateSpeedLimitsForward(e, nLimits)) {
                    if (post.speedMps < hugeSpeed) {
                        posts.push([distanceM, post]);
                    }
                }
                return [traveledM, posts];
            }),
            // Pick out type 1 limits *unless* we encounter a type 2 (used for
            // Philadelphia - New York), at which point we'll filter for type 2
            // limits instead.
            frp.fold(
                ([hasTypeTwoLimits], [traveledM, posts]): FilterAccum => {
                    if (!hasTypeTwoLimits) {
                        for (const [, post] of posts) {
                            if (post.type === rw.SpeedLimitType.SignedTrack) {
                                hasTypeTwoLimits = true;
                                break;
                            }
                        }
                    }

                    const filtered: Sensed<SpeedPost>[] = [];
                    for (const [distanceM, post] of posts) {
                        if (
                            (hasTypeTwoLimits && post.type === rw.SpeedLimitType.SignedTrack) ||
                            (!hasTypeTwoLimits && post.type === rw.SpeedLimitType.UnsignedTrack)
                        ) {
                            filtered.push([distanceM, post]);
                        }
                    }
                    return [hasTypeTwoLimits, [traveledM, filtered]];
                },
                [false, [0, []]] as FilterAccum
            ),
            frp.map(([, reading]) => reading)
        );
    };
}

function iterateSpeedLimitsForward(e: FrpEngine, nLimits: number): Sensed<SpeedPost>[] {
    return iterateSpeedLimits(rw.ConsistDirection.Forward, e, nLimits, 0);
}

function iterateSpeedLimitsBackward(e: FrpEngine, nLimits: number): Sensed<SpeedPost>[] {
    return iterateSpeedLimits(rw.ConsistDirection.Backward, e, nLimits, 0);
}

function iterateSpeedLimits(
    dir: rw.ConsistDirection,
    e: FrpEngine,
    nLimits: number,
    minDistanceM: number
): Sensed<SpeedPost>[] {
    if (nLimits <= 0) {
        return [];
    } else {
        const nextLimit = e.rv.GetNextSpeedLimit(dir, minDistanceM);
        if (typeof nextLimit === "number") {
            // Search failed, and further searching would be futile.
            return [];
        } else {
            const [type, speedMps, distanceM] = nextLimit;
            const result: Sensed<SpeedPost>[] = [[distanceM, { type: type, speedMps: speedMps }]];
            result.push(...iterateSpeedLimits(dir, e, nLimits - 1, distanceM + iterateStepM));
            return result;
        }
    }
}

/**
 * Create a continuous stream of searches for restrictive signals.
 * @param e The rail vehicle to sense objects with.
 * @returns The new event stream of signal readings.
 */
function mapSignalStream(e: FrpEngine): (eventStream: frp.Stream<VehicleUpdate>) => frp.Stream<Reading<Signal>> {
    const nSignals = 3;
    return eventStream => {
        return frp.compose(
            eventStream,
            frp.map(pu => {
                const speedMpS = e.rv.GetSpeed(); // Must be as precise as possible.
                const traveledM = speedMpS * pu.dt;
                let signals: Sensed<Signal>[] = [];
                for (const [distanceM, signal] of iterateSignalsBackward(e, nSignals)) {
                    signals.push([-distanceM, signal]);
                }
                signals.push(...iterateSignalsForward(e, nSignals));
                return [traveledM, signals];
            })
        );
    };
}

function iterateSignalsForward(e: FrpEngine, nSignals: number): Sensed<Signal>[] {
    return iterateRestrictiveSignals(rw.ConsistDirection.Forward, e, nSignals, 0);
}

function iterateSignalsBackward(e: FrpEngine, nSignals: number): Sensed<Signal>[] {
    return iterateRestrictiveSignals(rw.ConsistDirection.Backward, e, nSignals, 0);
}

function iterateRestrictiveSignals(
    dir: rw.ConsistDirection,
    e: FrpEngine,
    nSignals: number,
    minDistanceM: number
): Sensed<Signal>[] {
    if (nSignals <= 0) {
        return [];
    } else {
        const nextSignal = e.rv.GetNextRestrictiveSignal(dir, minDistanceM);
        if (typeof nextSignal === "number") {
            // Search failed, and further searching would be futile.
            return [];
        } else {
            const [, distanceM, proState] = nextSignal;
            const result: Sensed<Signal>[] = [[distanceM, { proState: proState }]];
            result.push(...iterateRestrictiveSignals(dir, e, nSignals - 1, distanceM + iterateStepM));
            return result;
        }
    }
}

/**
 * Create a continuous event stream that tracks the current track speed limit as
 * sensed by the head-end unit.
 * @param e The player's engine.
 * @param gameTrackSpeedLimitMps A behavior to obtain the game-provided track
 * speed limit, which changes when the rear of the train clears the last
 * restriction.
 * @param consistLengthM A behavior to obtain the length of the player's
 * consist.
 * @param cutIn Reset the tracker's state if this behavior is false.
 * @returns The new event stream of track speed in m/s.
 */
function createTrackSpeedStream(
    e: FrpEngine,
    gameTrackSpeedLimitMps: frp.Behavior<number>,
    consistLengthM: frp.Behavior<number>,
    cutIn: frp.Behavior<boolean>
): (eventStream: frp.Stream<Map<number, Sensed<SpeedPost>>>) => frp.Stream<number | undefined> {
    type TrackSpeedChangeAccum = undefined | [savedSpeedMps: number, upgradeAfterM: number];

    return indexStream => {
        const twoSidedPosts = frp.stepper(trackSpeedPostSpeeds(indexStream), new Map<number, TwoSidedSpeedPost>());
        return frp.compose(
            indexStream,
            frp.fold<number | undefined, Map<number, Sensed<SpeedPost>>>((accum, index) => {
                if (!frp.snapshot(cutIn)) return undefined;

                // Locate the adjacent speed posts.
                const justBefore = bestScoreOfMapEntries(index, (_, [distanceM]) =>
                    distanceM < 0 ? distanceM : undefined
                );
                const justAfter = bestScoreOfMapEntries(index, (_, [distanceM]) =>
                    distanceM > 0 ? -distanceM : undefined
                );

                // If we're on the other side of a recorded speed post, we can infer
                // the current speed limit.
                let inferredSpeedMps: number | undefined = undefined;
                if (justBefore !== undefined) {
                    const twoPost = frp.snapshot(twoSidedPosts).get(justBefore) as TwoSidedSpeedPost;
                    inferredSpeedMps = twoPost.after?.speedMps;
                }
                if (inferredSpeedMps === undefined && justAfter !== undefined) {
                    const twoPost = frp.snapshot(twoSidedPosts).get(justAfter) as TwoSidedSpeedPost;
                    inferredSpeedMps = twoPost.before?.speedMps;
                }
                // If inference fails, stick with the previous speed...
                if (inferredSpeedMps === undefined) {
                    inferredSpeedMps = accum ?? Infinity;
                }

                const gameSpeedMps = frp.snapshot(gameTrackSpeedLimitMps);
                if (gameSpeedMps > inferredSpeedMps) {
                    // The game speed limit is strictly lower than the track speed
                    // limit we're after, so if that is higher, then we should use it.
                    return gameSpeedMps;
                } else if (justBefore !== undefined) {
                    // If the previous speed post is behind the end of our train, then
                    // we can also use the game speed limit.
                    const [justBeforeDistanceM] = index.get(justBefore) as Sensed<SpeedPost>;
                    if (-justBeforeDistanceM > frp.snapshot(consistLengthM)) {
                        return gameSpeedMps;
                    }
                }
                return inferredSpeedMps;
            }, undefined),
            // To smooth out frequent track speed changes, i.e. through
            // crossovers, impose a distance-based delay before upgrading the
            // track speed.
            frp.merge(e.createPlayerWithKeyUpdateStream()),
            frp.fold<TrackSpeedChangeAccum, number | undefined | VehicleUpdate>((accum, input) => {
                if (!frp.snapshot(cutIn) || input === undefined) return undefined;

                // New speed
                if (typeof input === "number") {
                    const speedMps = input;
                    if (accum === undefined) {
                        return [speedMps, 0];
                    }

                    const [savedSpeedMps, upgradeAfterM] = accum;
                    if (speedMps < savedSpeedMps || (speedMps > savedSpeedMps && upgradeAfterM <= 0)) {
                        return [speedMps, minTrackSpeedUpgradeDistM];
                    } else {
                        return [savedSpeedMps, upgradeAfterM];
                    }
                }

                // Clock update
                if (accum === undefined) {
                    return [frp.snapshot(gameTrackSpeedLimitMps), 0];
                } else {
                    const pu = input;
                    const traveledM = pu.dt * Math.abs(e.rv.GetSpeed());
                    const [savedSpeedMps, upgradeAfterM] = accum;
                    return [savedSpeedMps, Math.max(upgradeAfterM - traveledM, 0)];
                }
            }, undefined),
            frp.map(accum => {
                if (accum !== undefined) {
                    const [savedSpeedMps] = accum;
                    return savedSpeedMps;
                } else {
                    return undefined;
                }
            })
        );
    };
}

/**
 * Save both "ends" of speed posts as seen by the rail vehicle as it overtakes
 * them.
 */
const trackSpeedPostSpeeds = frp.fold<Map<number, TwoSidedSpeedPost>, Map<number, Sensed<SpeedPost>>>(
    (accum, index) => {
        let newAccum = new Map<number, TwoSidedSpeedPost>();
        for (const [id, [distanceM, post]] of index) {
            const sides = accum.get(id);
            let newSides: TwoSidedSpeedPost;
            if (sides !== undefined) {
                if (distanceM < 0) {
                    newSides = { before: post, after: sides.after };
                } else if (distanceM > 0) {
                    newSides = { before: sides.before, after: post };
                } else {
                    newSides = sides;
                }
            } else {
                newSides = distanceM >= 0 ? { before: undefined, after: post } : { before: post, after: undefined };
            }
            newAccum.set(id, newSides);
        }
        return newAccum;
    },
    new Map()
);

/**
 * Tags objects that can only be sensed by distance statelessly with
 * persistent ID's.
 *
 * Track objects will briefly disappear before they reappear in the reverse
 * direction - the exact distance is possibly the locomotive length? We call
 * this area the "passing" zone.
 *
 * d < 0|invisible|d > 0
 * ---->|_________|<----
 *
 * @param cutIn Reset the tracker's state if this behavior is false.
 * @returns An stream of mappings from unique identifier to sensed object.
 */
function indexObjectsSensedByDistance<T>(
    cutIn: frp.Behavior<boolean>
): (eventStream: frp.Stream<Reading<T>>) => frp.Stream<Map<number, Sensed<T>>> {
    type ObjectIndexAccum<T> = { counter: number; sensed: Map<number, Sensed<T>>; passing: Map<number, Sensed<T>> };

    const maxPassingM = 28.5; // 1.1*85 ft
    const senseMarginM = 4;
    return eventStream => {
        const accumStart: ObjectIndexAccum<T> = {
            counter: -1,
            sensed: new Map(),
            passing: new Map(),
        };
        return frp.compose(
            eventStream,
            frp.fold<ObjectIndexAccum<T>, Reading<T>>((accum, reading) => {
                if (!frp.snapshot(cutIn)) return accumStart;

                const [traveledM, objects] = reading;
                let counter = accum.counter;
                let sensed = new Map<number, Sensed<T>>();
                let passing = new Map<number, Sensed<T>>();
                for (const [distanceM, obj] of objects) {
                    // First, try to match a sensed object with a previously sensed
                    // object.
                    const bestSensed = bestScoreOfMapEntries(accum.sensed, (id, [sensedDistanceM]) => {
                        if (sensed.has(id)) {
                            return undefined;
                        } else {
                            const inferredM = sensedDistanceM - traveledM;
                            const differenceM = Math.abs(inferredM - distanceM);
                            return differenceM > senseMarginM ? undefined : -differenceM;
                        }
                    });
                    if (bestSensed !== undefined) {
                        sensed.set(bestSensed, [distanceM, obj]);
                        continue;
                    }

                    // Next, try to match with a passing object.
                    let bestPassing: number | undefined;
                    if (distanceM <= 0 && distanceM > -senseMarginM) {
                        bestPassing = bestScoreOfMapEntries(accum.passing, (id, [passingDistanceM]) => {
                            const inferredM = passingDistanceM - traveledM;
                            return sensed.has(id) ? undefined : -inferredM;
                        });
                    } else if (distanceM >= 0 && distanceM < senseMarginM) {
                        bestPassing = bestScoreOfMapEntries(accum.passing, (id, [passingDistanceM]) => {
                            const inferredM = passingDistanceM - traveledM;
                            return sensed.has(id) ? undefined : inferredM;
                        });
                    }
                    if (bestPassing !== undefined) {
                        sensed.set(bestPassing, [distanceM, obj]);
                        continue;
                    }

                    // If neither strategy matched, then this is a new object.
                    sensed.set(++counter, [distanceM, obj]);
                }

                // Cull objects in the passing zone that have exceeded the
                // maximum passing distance.
                for (const [id, [distanceM, obj]] of accum.passing) {
                    if (!sensed.has(id)) {
                        const inferredM = distanceM - traveledM;
                        if (Math.abs(inferredM) <= maxPassingM) {
                            passing.set(id, [inferredM, obj]);
                            sensed.set(id, [inferredM, obj]);
                        }
                    }
                }

                // Add back objects that haven't been matched to anything
                // else and are in the passing zone.
                for (const [id, [distanceM, obj]] of accum.sensed) {
                    if (!sensed.has(id) && !passing.has(id)) {
                        const inferredM = distanceM - traveledM;
                        if (Math.abs(inferredM) <= maxPassingM) {
                            passing.set(id, [inferredM, obj]);
                            sensed.set(id, [inferredM, obj]);
                        }
                    }
                }

                return { counter, sensed, passing };
            }, accumStart),
            frp.map(accum => accum.sensed)
        );
    };
}

/**
 * Score the entries of a map and return the best-scoring one.
 * @param map The map to search.
 * @param score A function that scores an entry in a map. It may also return
 * undefined, in which case this entry will be excluded.
 * @returns The highest-scoring key, if any.
 */
function bestScoreOfMapEntries<K, V>(map: Map<K, V>, score: (key: K, value: V) => number | undefined): K | undefined {
    let best: K | undefined = undefined;
    let bestScore: number | undefined = undefined;
    for (const [k, v] of map) {
        const s = score(k, v);
        if (s !== undefined && (bestScore === undefined || s > bestScore)) {
            best = k;
            bestScore = s;
        }
    }
    return best;
}

function isHazardRightWay(distanceM: number, playerSpeedMps: number) {
    return (distanceM > 0 && playerSpeedMps >= 0) || (distanceM < 0 && playerSpeedMps <= 0);
}

function firstDefinedProperty<V, P>(arr: V[], callbackfn: (value: V) => P | undefined) {
    for (const value of arr) {
        const property = callbackfn(value);
        switch (property) {
            case undefined:
            case null:
            case {}:
                break;
            default:
                return property;
        }
    }
    return undefined;
}

/**
 * Describes any piece of the ACSES braking curve.
 */
type Piece = {
    /**
     * The "true" curve speed for this piece, without any margin or
     * miscellaneous speed enforcement applied. Pieces are sorted by this speed.
     */
    curveSpeedMps: number;
    /**
     * The alert curve speed for this piece.
     */
    alertCurveMps: number;
    /**
     * The penalty curve speed for this piece.
     */
    penaltyCurveMps: number;
    /**
     * The speed presented to the engineer for ACSES-I systems with no advance
     * braking curve countdown. This is defined only for constant speed pieces,
     * advance speed limit slopes that have been violated, and stop signal
     * slopes.
     */
    stepSpeedMps?: number;
    /**
     * The speed limit in effect for the current section of track. This is
     * defined only for constant speed pieces.
     */
    currentLimitMps?: number;
    /**
     * The speed limit that will go into effect after this downward slope.
     * This is defined only for advance speed limit and stop signal slopes.
     */
    nextLimitMps?: number;
    /**
     * The time to penalty displayed to the engineer. This is defined only
     * for stop signal slopes.
     */
    timeToPenaltyS?: number;
};

function constantSpeedPiece(limitMps: number): Piece {
    return {
        curveSpeedMps: limitMps,
        alertCurveMps: limitMps + alertMarginMps,
        penaltyCurveMps: limitMps + penaltyMarginMps,
        stepSpeedMps: limitMps,
        currentLimitMps: limitMps,
    };
}

function advanceLimitNotViolatedPiece(sensed: Sensed<SpeedPost>, curveMps2: number): Piece {
    const [distanceM, post] = sensed;
    const aDistanceM = Math.abs(distanceM);
    const curveSpeedMps = getBrakingCurve(curveMps2, post.speedMps, aDistanceM, 0);
    return {
        curveSpeedMps,
        alertCurveMps: curveSpeedMps + alertMarginMps,
        penaltyCurveMps: curveSpeedMps + penaltyMarginMps,
        nextLimitMps: post.speedMps,
    };
}

function advanceLimitViolatedPiece(sensed: Sensed<SpeedPost>, curveMps2: number): Piece {
    const [distanceM, post] = sensed;
    const aDistanceM = Math.abs(distanceM);
    const curveSpeedMps = getBrakingCurve(curveMps2, post.speedMps, aDistanceM, 0);
    return {
        curveSpeedMps,
        alertCurveMps: post.speedMps + alertMarginMps,
        penaltyCurveMps: curveSpeedMps + penaltyMarginMps,
        stepSpeedMps: post.speedMps,
        nextLimitMps: post.speedMps,
    };
}

function positiveStopPiece(
    sensed: Sensed<Signal>,
    curveMps2: number,
    ptsDistanceM: number | false,
    playerSpeedMps: number
): Piece {
    const [distanceM] = sensed;
    const enforceStop = ptsDistanceM !== false;

    const cushionM = 85 * c.ft.toM;
    const targetDistanceM = (enforceStop ? ptsDistanceM : 0) + cushionM;
    const curveDistanceM = Math.max(Math.abs(distanceM) - targetDistanceM, 0);
    const penaltyCurveMps = getBrakingCurve(curveMps2, 0, curveDistanceM, 0);
    const isImminent = penaltyCurveMps <= 20 * c.mph.toMps + penaltyMarginMps;

    if (enforceStop || !isImminent) {
        // For fully positive stop-aware routes like LIRR, let the curve take
        // the player all the way down to a stop.
        const minAlarmSpeedMps = 0.5 * c.mph.toMps;
        const timeToPenaltyS = getTimeToPenaltyS(curveMps2, 0, Math.abs(playerSpeedMps), curveDistanceM);
        return {
            curveSpeedMps: Math.max(penaltyCurveMps - penaltyMarginMps, minAlarmSpeedMps),
            alertCurveMps: Math.max(penaltyCurveMps - (penaltyMarginMps - alertMarginMps), minAlarmSpeedMps),
            penaltyCurveMps,
            stepSpeedMps: isImminent ? 0 : undefined,
            nextLimitMps: isImminent ? 0 : undefined,
            timeToPenaltyS: isImminent ? timeToPenaltyS : undefined,
        };
    } else {
        // For all other routes, use a "soft" positive stop that only enforces
        // the interlocking speed.
        return {
            curveSpeedMps: stopReleaseMps,
            alertCurveMps: stopReleaseMps + alertMarginMps,
            penaltyCurveMps: stopReleaseMps + penaltyMarginMps,
            stepSpeedMps: stopReleaseMps,
            nextLimitMps: 0,
        };
    }
}

function getBrakingCurve(a: number, vf: number, d: number, t: number) {
    return Math.max(Math.pow(Math.pow(a * t, 2) - 2 * a * d + Math.pow(vf, 2), 0.5) + a * t, vf);
}

function getTimeToPenaltyS(a: number, vf: number, vi: number, d: number) {
    if (Math.abs(vf - vi) < c.stopSpeed) {
        return undefined;
    } else {
        const ttpS = (d - (Math.pow(vf, 2) - Math.pow(vi, 2)) / (2 * a)) / vi;
        return ttpS >= 0 && ttpS <= 60 ? ttpS : undefined;
    }
}

function brakingCurveGradientFactor(gradientPct: number): number {
    if (gradientPct > 0) {
        return 1 + (1 - brakingCurveGradientFactor(-gradientPct));
    } else if (gradientPct < -2.96) {
        return 1 - 0.7;
    } else if (gradientPct < -2.64) {
        return 1 - 0.6;
    } else if (gradientPct < -2.26) {
        return 1 - 0.5;
    } else if (gradientPct < -1.83) {
        return 1 - 0.4;
    } else if (gradientPct < -1.32) {
        return 1 - 0.3;
    } else if (gradientPct < -0.72) {
        return 1 - 0.2;
    } else if (gradientPct < -0.3) {
        return 1 - 0.1;
    } else {
        return 1;
    }
}
