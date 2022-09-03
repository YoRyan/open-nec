/** @noSelfInFile */
/**
 * Functional reactive programming library.
 * Straight port of https://github.com/santoshrajan/frpjs to TypeScript.
 */

import * as rw from "./railworks";

export type Stream<T> = (next: (value: T) => void) => void;
export type Behavior<T> = (() => T) | T;

const e = new rw.ScriptedEntity("");

/**
 * Takes an eventStream and a function that transforms the value of the Event.
 * Returns a new Event that emits the transformed Value
 */
export function map<T, U>(valueTransform: (value: T) => U): (eventStream: Stream<T>) => Stream<U> {
    return function (eventStream) {
        return function (next) {
            eventStream(function (value) {
                next(valueTransform(value));
            });
        };
    };
}

/**
 * Binds an eventStream to a new EventStream. Function valueToEvent is called
 * with the event value. Returns a new Event Stream.
 */
export function bind<T, U>(valueToEvent: (value: T) => Stream<U>): (eventStream: Stream<T>) => Stream<U> {
    return function (eventStream) {
        return function (next) {
            eventStream(function (value) {
                valueToEvent(value)(next);
            });
        };
    };
}

/**
 * Filters an Event Stream. Predicate is called with every value.
 */
export function filter<T>(predicate: (value: T) => boolean): (eventStream: Stream<T>) => Stream<T> {
    return function (eventStream) {
        return function (next) {
            eventStream(function (value) {
                if (predicate(value)) {
                    next(value);
                }
            });
        };
    };
}

/**
 * Opposite of filter
 */
export function reject<T>(predicate: (value: T) => boolean): (eventStream: Stream<T>) => Stream<T> {
    return function (eventStream) {
        return function (next) {
            eventStream(function (value) {
                if (!predicate(value)) {
                    next(value);
                }
            });
        };
    };
}

/**
 * Is the 'reduce' function for every event in the stream. The step function
 * is called with the accumulator and the current value. The parameter initial
 * is the initial value of the accumulator
 */
export function fold<TAccum, TValue>(
    step: (accumulated: TAccum, value: TValue) => TAccum,
    initial: TAccum
): (eventStream: Stream<TValue>) => Stream<TAccum> {
    return function (eventStream) {
        return function (next) {
            let accumulated = initial;
            eventStream(function (value) {
                next((accumulated = step(accumulated, value)));
            });
        };
    };
}

/**
 * Takes two eventStreams, combines them and returns a new eventStream
 */
export function merge<A, B>(eventStreamA: Stream<A>): (eventStreamB: Stream<B>) => Stream<A | B> {
    return function (eventStreamB) {
        return function (next) {
            eventStreamA(value => next(value));
            eventStreamB(value => next(value));
        };
    };
}

/**
 * Takes an eventStream, performs a series of operations on it and returns
 * a modified stream. All FRP operations are curried by default.
 */
export function compose<A, B>(eventStream: Stream<A>, op0: (eventStream: Stream<A>) => Stream<B>): Stream<B>;
export function compose<A, B, C>(
    eventStream: Stream<A>,
    op0: (eventStream: Stream<A>) => Stream<B>,
    op1: (eventStream: Stream<B>) => Stream<C>
): Stream<C>;
export function compose<A, B, C, D>(
    eventStream: Stream<A>,
    op0: (eventStream: Stream<A>) => Stream<B>,
    op1: (eventStream: Stream<B>) => Stream<C>,
    op2: (eventStream: Stream<C>) => Stream<D>
): Stream<D>;
export function compose<A, B, C, D, E>(
    eventStream: Stream<A>,
    op0: (eventStream: Stream<A>) => Stream<B>,
    op1: (eventStream: Stream<B>) => Stream<C>,
    op2: (eventStream: Stream<C>) => Stream<D>,
    op3: (eventStream: Stream<D>) => Stream<E>
): Stream<E>;
export function compose<A, B, C, D, E, F>(
    eventStream: Stream<A>,
    op0: (eventStream: Stream<A>) => Stream<B>,
    op1: (eventStream: Stream<B>) => Stream<C>,
    op2: (eventStream: Stream<C>) => Stream<D>,
    op3: (eventStream: Stream<D>) => Stream<E>,
    op4: (eventStream: Stream<E>) => Stream<F>
): Stream<F>;
export function compose<A, B, C, D, E, F, G>(
    eventStream: Stream<A>,
    op0: (eventStream: Stream<A>) => Stream<B>,
    op1: (eventStream: Stream<B>) => Stream<C>,
    op2: (eventStream: Stream<C>) => Stream<D>,
    op3: (eventStream: Stream<D>) => Stream<E>,
    op4: (eventStream: Stream<E>) => Stream<F>,
    op5: (eventStream: Stream<F>) => Stream<G>
): Stream<G>;
export function compose<A, B, C, D, E, F, G, H>(
    eventStream: Stream<A>,
    op0: (eventStream: Stream<A>) => Stream<B>,
    op1: (eventStream: Stream<B>) => Stream<C>,
    op2: (eventStream: Stream<C>) => Stream<D>,
    op3: (eventStream: Stream<D>) => Stream<E>,
    op4: (eventStream: Stream<E>) => Stream<F>,
    op5: (eventStream: Stream<F>) => Stream<G>,
    op6: (eventStream: Stream<G>) => Stream<H>
): Stream<H>;
export function compose<A, B, C, D, E, F, G, H, I>(
    eventStream: Stream<A>,
    op0: (eventStream: Stream<A>) => Stream<B>,
    op1: (eventStream: Stream<B>) => Stream<C>,
    op2: (eventStream: Stream<C>) => Stream<D>,
    op3: (eventStream: Stream<D>) => Stream<E>,
    op4: (eventStream: Stream<E>) => Stream<F>,
    op5: (eventStream: Stream<F>) => Stream<G>,
    op6: (eventStream: Stream<G>) => Stream<H>,
    op7: (eventStream: Stream<H>) => Stream<I>
): Stream<I>;
export function compose(
    eventStream: Stream<any>,
    ...operations: ((eventStream: Stream<any>) => Stream<any>)[]
): Stream<any> {
    let operation = operations.shift();
    // @ts-ignore
    return operation === undefined ? eventStream : compose(operation(eventStream), ...operations);
}

/**
 * Returns a behaviour. Call the behaviour for the last value of the event.
 */
export function stepper<T>(eventStream: Stream<T>, initial: T): Behavior<T> {
    let valueAtLastStep = initial;

    eventStream(function nextStep(value) {
        valueAtLastStep = value;
    });

    return function behaveAtLastStep() {
        return valueAtLastStep;
    };
}

/**
 * Throttle an EventStream to every ms milliseconds
 *
 * @description Note that unlike Santosh Rajan's original version of the
 * function, this one is curried.
 */
export function throttle<T>(ms: number): (eventStream: Stream<T>) => Stream<T> {
    return function (eventStream) {
        return function (next) {
            let last = 0;
            eventStream(function (value) {
                let now = e.GetSimulationTime() * 1000;
                if (last === 0 || now - last > ms) {
                    next(value);
                    last = now;
                }
            });
        };
    };
}

export function snapshot<T>(behavior: Behavior<T>): T {
    if (typeof behavior === "function") {
        return (behavior as () => T)();
    }
    return behavior;
}

export function liftN<A, T>(combine: (arg0: A) => T, b0: Behavior<A>): Behavior<T>;
export function liftN<A, B, T>(combine: (arg0: A, arg1: B) => T, b0: Behavior<A>, b1: Behavior<B>): Behavior<T>;
export function liftN<A, B, C, T>(
    combine: (arg0: A, arg1: B, arg2: C) => T,
    b0: Behavior<A>,
    b1: Behavior<B>,
    b2: Behavior<C>
): Behavior<T>;
export function liftN<A, B, C, D, T>(
    combine: (arg0: A, arg1: B, arg2: C, arg3: D) => T,
    b0: Behavior<A>,
    b1: Behavior<B>,
    b2: Behavior<C>,
    b3: Behavior<D>
): Behavior<T>;
export function liftN<A, B, C, D, E, T>(
    combine: (arg0: A, arg1: B, arg2: C, arg3: D, arg4: E) => T,
    b0: Behavior<A>,
    b1: Behavior<B>,
    b2: Behavior<C>,
    b3: Behavior<D>,
    b4: Behavior<E>
): Behavior<T>;
export function liftN<A, B, C, D, E, F, T>(
    combine: (arg0: A, arg1: B, arg2: C, arg3: D, arg4: E, arg5: F) => T,
    b0: Behavior<A>,
    b1: Behavior<B>,
    b2: Behavior<C>,
    b3: Behavior<D>,
    b4: Behavior<E>,
    b5: Behavior<F>
): Behavior<T>;
export function liftN<A, B, C, D, E, F, G, T>(
    combine: (arg0: A, arg1: B, arg2: C, arg3: D, arg4: E, arg5: F, arg6: G) => T,
    b0: Behavior<A>,
    b1: Behavior<B>,
    b2: Behavior<C>,
    b3: Behavior<D>,
    b4: Behavior<E>,
    b5: Behavior<F>,
    b6: Behavior<G>
): Behavior<T>;
export function liftN<A, B, C, D, E, F, G, H, T>(
    combine: (arg0: A, arg1: B, arg2: C, arg3: D, arg4: E, arg5: F, arg6: G, arg7: H) => T,
    b0: Behavior<A>,
    b1: Behavior<B>,
    b2: Behavior<C>,
    b3: Behavior<D>,
    b4: Behavior<E>,
    b5: Behavior<F>,
    b6: Behavior<G>,
    b7: Behavior<H>
): Behavior<T>;
export function liftN<T>(combine: (...args: any[]) => T, ...behaviors: Behavior<any>[]): Behavior<T> {
    return function () {
        let values = behaviors.map(value => snapshot(value));
        return combine(...values);
    };
}

export function hub<T>(): (eventStream: Stream<T>) => Stream<T> {
    return function (eventStream) {
        let nexts: ((value: T) => void)[] = [];
        let isStarted = false;

        return function (next) {
            nexts.push(next);
            if (!isStarted) {
                eventStream(function (value) {
                    nexts.forEach(next => next(value));
                });
                isStarted = true;
            }
        };
    };
}
