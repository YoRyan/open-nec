/** @noSelfInFile */

import * as frp from "./frp";
import * as rw from "./railworks";

/**
 * Continously display the value of an event stream to aid in FRP debugging.
 */
export function debug(eventStream: frp.Stream<any>) {
    const frequency = 0.5;
    frp.throttle(frequency * 1000)(eventStream)(value => {
        rw.ScenarioManager.ShowInfoMessageExt(
            "Event Stream",
            `${value}`,
            frequency,
            rw.MessageBoxPosition.Centre,
            rw.MessageBoxSize.Small,
            false
        );
    });
}

/**
 * Creates a state machine that records the last and current values of the event
 * stream.
 * @param initState The initial value of the state machine.
 */
export function fsm<T>(initState: T): (eventStream: frp.Stream<T>) => frp.Stream<[from: T, to: T]> {
    return frp.fold<[T, T], T>((accum, value) => [accum[1], value], [initState, initState]);
}

/**
 * Filters out undefined values from an event stream.
 */
export function rejectUndefined<T>(): (eventStream: frp.Stream<T | undefined>) => frp.Stream<T> {
    return frp.reject<T | undefined>(value => value === undefined) as (
        eventStream: frp.Stream<T | undefined>
    ) => frp.Stream<T>;
}

/**
 * Maps a behavior onto all events of a stream.
 */
export function mapBehavior<T>(behavior: frp.Behavior<T>): (eventStream: frp.Stream<any>) => frp.Stream<T> {
    return frp.map(_ => frp.snapshot(behavior));
}

/**
 * Creates a moving average computer with the specified capacity.
 */
export function movingAverage(capacity: number): (eventStream: frp.Stream<number>) => frp.Stream<number> {
    type AverageAccum = [number[], number];

    return eventStream =>
        frp.compose(
            eventStream,
            frp.fold(
                ([data, ptr], v): AverageAccum => {
                    data[ptr] = v;
                    return [data, (ptr + 1) % capacity];
                },
                [[], 0] as AverageAccum
            ),
            frp.map(([data]) => {
                let sum = 0;
                for (const n of data) {
                    sum += n;
                }
                return sum / data.length;
            })
        );
}
