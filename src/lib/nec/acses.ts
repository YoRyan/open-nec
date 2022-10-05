/** @noSelfInFile */
/**
 * Advanced Civil Speed Enforcement System for the Northeast Corridor.
 */

import * as cs from "./cabsignals";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { rejectUndefined } from "lib/frp-extra";
import { PlayerUpdate } from "lib/frp-vehicle";
import * as rw from "lib/railworks";

export type AcsesState = {
    alertCurveMps: number;
    penaltyCurveMps: number;
    targetSpeedMps: number;
    visibleSpeedMps: number;
    timeToPenaltyS?: number;
};

type TrackSpeedChangeAccum = undefined | [savedSpeedMps: number, upgradeAfterM: number];
const minTrackSpeedUpgradeDistM = 350 * c.ft.toM; // about 4 car lengths

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
const iterateStepM = 0.01;

/**
 * Create a new ACSES instance.
 * @param e The player's engine.
 * @param isActive A behavior that indicates the unit is making computations.
 * @param violationForcesAlarm If true, exceeding the visible speed limit at
 * any time violates the alert curve.
 * @returns An event stream that communicates all state for this system.
 */
export function create(
    e: FrpEngine,
    isActive: frp.Behavior<boolean>,
    violationForcesAlarm: boolean
): frp.Stream<AcsesState> {
    type HazardsAccum = { advanceLimits: Map<number, AdvanceLimitHazard>; hazards: Hazard[] };

    const isInactive = frp.liftN(isActive => !isActive, isActive);

    const pts$ = frp.compose(
        e.createOnSignalMessageStream(),
        frp.map(msg => cs.toPositiveStopDistanceM(msg)),
        rejectUndefined()
    );
    const pts = frp.stepper(pts$, false);

    const speedPostIndex$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        mapSpeedPostsStream(e),
        indexObjectsSensedByDistance(isInactive),
        frp.hub()
    );
    const speedPostIndex = frp.stepper(speedPostIndex$, new Map<number, Sensed<SpeedPost>>());

    const signalIndex$ = frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        mapSignalStream(e),
        indexObjectsSensedByDistance(isInactive)
    );
    const signalIndex = frp.stepper(signalIndex$, new Map<number, Sensed<Signal>>());

    return frp.compose(
        speedPostIndex$,
        createTrackSpeedStream(
            e,
            () => e.rv.GetCurrentSpeedLimit()[0],
            () => e.rv.GetConsistLength(),
            isInactive
        ),
        frp.fold<HazardsAccum, number>(
            (accum, trackSpeedMps) => {
                const speedoMps = (e.rv.GetControlValue("SpeedometerMPH", 0) as number) * c.mph.toMps;
                const thePts = frp.snapshot(pts);

                let hazards: Hazard[] = [];
                const brakingCurveMps2 = penaltyCurveMps2 * brakingCurveGradientFactor(e.rv.GetGradient());
                // Add advance speed limits.
                let advanceLimits = new Map<number, AdvanceLimitHazard>();
                for (const [id, sensed] of frp.snapshot(speedPostIndex)) {
                    const hazard = accum.advanceLimits.get(id) || new AdvanceLimitHazard(violationForcesAlarm);
                    advanceLimits.set(id, hazard);
                    hazard.update(brakingCurveMps2, speedoMps, sensed);
                    hazards.push(hazard);
                }
                // Add stop signals if a positive stop is imminent.
                if (typeof thePts === "number") {
                    for (const [id, [distanceM, signal]] of frp.snapshot(signalIndex)) {
                        if (signal.proState === rw.ProSignalState.Red) {
                            const cushionM = 40 * c.ft.toM;
                            const hazard = new StopSignalHazard(
                                brakingCurveMps2,
                                speedoMps,
                                thePts + cushionM,
                                distanceM
                            );
                            hazards.push(hazard);
                        }
                    }
                }
                // Add current track speed limit.
                hazards.push(new TrackSpeedHazard(trackSpeedMps));
                // Sort by penalty curve speed.
                hazards.sort((a, b) => a.penaltyCurveMps - b.penaltyCurveMps);
                return { advanceLimits, hazards };
            },
            { advanceLimits: new Map(), hazards: [] }
        ),
        frp.map((accum): AcsesState => {
            const inForce = accum.hazards[0];
            const lowestVisible = accum.hazards.reduce((previous, current) =>
                previous.visibleSpeedMps !== undefined ? previous : current
            );
            return {
                alertCurveMps: inForce.alertCurveMps,
                penaltyCurveMps: inForce.penaltyCurveMps,
                targetSpeedMps: inForce.targetSpeedMps,
                visibleSpeedMps: lowestVisible.visibleSpeedMps ?? inForce.targetSpeedMps,
                timeToPenaltyS: inForce.timeToPenaltyS,
            };
        })
    );
}

/**
 * Create a continuous stream of searches for speed limit changes.
 * @param e The rail vehicle to sense objects with.
 * @returns The new event stream of speed post readings.
 */
function mapSpeedPostsStream(e: FrpEngine): (eventStream: frp.Stream<PlayerUpdate>) => frp.Stream<Reading<SpeedPost>> {
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
function mapSignalStream(e: FrpEngine): (eventStream: frp.Stream<PlayerUpdate>) => frp.Stream<Reading<Signal>> {
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
 * @param reset A behavior that can be used to reset this tracker.
 * @returns The new event stream of track speed in m/s.
 */
function createTrackSpeedStream(
    e: FrpEngine,
    gameTrackSpeedLimitMps: frp.Behavior<number>,
    consistLengthM: frp.Behavior<number>,
    reset: frp.Behavior<boolean>
): (eventStream: frp.Stream<Map<number, Sensed<SpeedPost>>>) => frp.Stream<number> {
    return indexStream => {
        const twoSidedPosts = frp.stepper(trackSpeedPostSpeeds(indexStream), new Map<number, TwoSidedSpeedPost>());
        return frp.compose(
            indexStream,
            frp.fold<number, Map<number, Sensed<SpeedPost>>>(
                (accum, index) => {
                    if (frp.snapshot(reset)) {
                        return 0;
                    }

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
                        inferredSpeedMps = accum;
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
                },
                0 // Should get instantly replaced by the game-calculated speed.
            ),
            // To smooth out frequent track speed changes, i.e. through
            // crossovers, impose a distance-based delay before upgrading the
            // track speed.
            frp.merge(e.createPlayerWithKeyUpdateStream()),
            frp.fold<TrackSpeedChangeAccum, number | PlayerUpdate>((accum, input) => {
                if (frp.snapshot(reset)) {
                    return undefined;
                }

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
                const [savedSpeedMps] = accum ?? [0];
                return savedSpeedMps;
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
 * @param reset A behavior that can be used to reset this tracker.
 * @returns An stream of mappings from unique identifier to sensed object.
 */
function indexObjectsSensedByDistance<T>(
    reset: frp.Behavior<boolean>
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
                if (frp.snapshot(reset)) {
                    return accumStart;
                }

                const [traveledM, objects] = reading;
                let counter = accum.counter;
                let sensed = new Map<number, Sensed<T>>();
                let passing = new Map<number, Sensed<T>>();
                for (const [distanceM, obj] of objects) {
                    // There's no continue in Lua 5.0, but we do have break...
                    while (true) {
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
                            break;
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
                            break;
                        }

                        // If neither strategy matched, then this is a new object.
                        sensed.set(++counter, [distanceM, obj]);
                        break;
                    }
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

                return { counter: counter, sensed: sensed, passing: passing };
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

/**
 * Describes any piece of the ACSES braking curve.
 */
interface Hazard {
    /**
     * The current alert curve speed.
     */
    alertCurveMps: number;
    /**
     * The current penalty curve speed.
     */
    penaltyCurveMps: number;
    /**
     * The track speed at the end of this piece of the braking curve.
     */
    targetSpeedMps: number;
    /**
     * The track speed to display to the engineer depending on the current state
     * of the hazard.
     */
    visibleSpeedMps?: number;
    /**
     * The time to penalty displayed to the engineer, if any.
     */
    timeToPenaltyS?: number;
}

/**
 * A stateless hazard that represents the current track speed limit.
 */
class TrackSpeedHazard implements Hazard {
    alertCurveMps: number;
    penaltyCurveMps: number;
    targetSpeedMps: number;
    visibleSpeedMps: number;
    timeToPenaltyS = undefined;

    constructor(speedMps: number) {
        this.alertCurveMps = speedMps + cs.alertMarginMps;
        this.penaltyCurveMps = speedMps + cs.penaltyMarginMps;
        this.targetSpeedMps = this.visibleSpeedMps = speedMps;
    }
}

/**
 * An advance speed limit tracks the distance at which it is violated, and
 * reveals itself to the engineer.
 */
class AdvanceLimitHazard implements Hazard {
    alertCurveMps: number = Infinity;
    penaltyCurveMps: number = Infinity;
    targetSpeedMps: number = Infinity;
    visibleSpeedMps?: number = undefined;
    timeToPenaltyS = undefined;

    private violationForcesAlarm: boolean;
    private violatedAtM: number | undefined = undefined;

    constructor(vfa: boolean) {
        this.violationForcesAlarm = vfa;
    }

    update(curveMps2: number, playerSpeedMps: number, sensed: Sensed<SpeedPost>) {
        const [distanceM, post] = sensed;
        const aDistanceM = Math.abs(distanceM);

        // Reveal this limit if the advance braking curve has been violated.
        let revealTrackSpeed: boolean;
        if (this.violatedAtM !== undefined) {
            if (distanceM > 0 && playerSpeedMps > 0) {
                revealTrackSpeed = distanceM > 0 && distanceM < this.violatedAtM;
            } else if (distanceM < 0 && playerSpeedMps < 0) {
                revealTrackSpeed = distanceM < 0 && distanceM > this.violatedAtM;
            } else {
                revealTrackSpeed = false;
            }
        } else {
            revealTrackSpeed = false;
        }

        const rightWay = (distanceM > 0 && playerSpeedMps >= 0) || (distanceM < 0 && playerSpeedMps <= 0);
        if (rightWay) {
            this.alertCurveMps =
                this.violationForcesAlarm && revealTrackSpeed
                    ? post.speedMps + cs.alertMarginMps
                    : Math.max(
                          getBrakingCurve(curveMps2, post.speedMps, aDistanceM, cs.alertCountdownS),
                          post.speedMps + cs.alertMarginMps
                      );
            this.penaltyCurveMps = Math.max(
                getBrakingCurve(curveMps2, post.speedMps, aDistanceM, 0),
                post.speedMps + cs.penaltyMarginMps
            );
        } else {
            this.alertCurveMps = this.penaltyCurveMps = Infinity;
        }
        this.targetSpeedMps = post.speedMps;
        this.visibleSpeedMps = revealTrackSpeed ? post.speedMps : undefined;
        if (this.violatedAtM === undefined && Math.abs(playerSpeedMps) > this.alertCurveMps) {
            this.violatedAtM = distanceM;
        }
    }
}

/**
 * A stateless hazard that represents a signal at Danger.
 */
class StopSignalHazard implements Hazard {
    alertCurveMps: number;
    penaltyCurveMps: number;
    targetSpeedMps = 0;
    visibleSpeedMps = undefined;
    timeToPenaltyS?: number;

    constructor(curveMps2: number, playerSpeedMps: number, targetM: number, distanceM: number) {
        const rightWay = (distanceM > 0 && playerSpeedMps >= 0) || (distanceM < 0 && playerSpeedMps <= 0);
        if (rightWay) {
            const curveDistanceM = Math.max(Math.abs(distanceM) - targetM, 0);
            this.alertCurveMps = getBrakingCurve(curveMps2, 0, curveDistanceM, cs.alertCountdownS);
            this.penaltyCurveMps = getBrakingCurve(curveMps2, 0, curveDistanceM, 0);
            const ttpS = getTimeToPenaltyS(curveMps2, 0, playerSpeedMps, curveDistanceM);
            this.timeToPenaltyS = ttpS < 0 || ttpS > 60 ? undefined : ttpS;
        } else {
            this.alertCurveMps = Infinity;
            this.penaltyCurveMps = Infinity;
            this.timeToPenaltyS = undefined;
        }
    }
}

function getBrakingCurve(a: number, vf: number, d: number, t: number) {
    return Math.max(Math.pow(Math.pow(a * t, 2) - 2 * a * d + Math.pow(vf, 2), 0.5) + a * t, vf);
}

function getTimeToPenaltyS(a: number, vf: number, vi: number, d: number) {
    return (d - (Math.pow(vf, 2) - Math.pow(vi, 2)) / (2 * a)) / vi;
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
