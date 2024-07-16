/**
 * A simple alerter safety system.
 */

import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "./frp-engine";

/**
 * Represents the state of the alerter subsystem.
 */
export type AlerterState = {
    alarm: boolean;
    penaltyBrake: boolean;
};

const defaultCountdownS = 60;
const defaultPenaltyS = 10;

/**
 * Create a new alerter instance.
 * @param e The player's engine.
 * @param acknowledge A behavior that, when true, resets the alerter.
 * @param acknowledgeStream A stream, when it emits events, resets the alerter.
 * @param cutIn A behavior that indicates the state of the cut in control.
 * @param countdownS The time to wait until sounding the alarm.
 * @param penaltyS The time to wait, once the alarm has sounded, until applying
 * the brakes.
 */
export function create({
    e,
    acknowledge,
    acknowledgeStream,
    cutIn,
    countdownS,
    penaltyS,
}: {
    e: FrpEngine;
    acknowledge: frp.Behavior<boolean>;
    acknowledgeStream: frp.Stream<any>;
    cutIn: frp.Behavior<boolean>;
    countdownS?: number;
    penaltyS?: number;
}): frp.Stream<AlerterState> {
    countdownS ??= defaultCountdownS;
    penaltyS ??= defaultPenaltyS;

    const acknowledgeStream$ = frp.compose(
        acknowledgeStream,
        frp.map(_ => undefined)
    );
    const vZero = e.createVZeroBehavior();
    const startS = countdownS + penaltyS;
    return frp.compose(
        e.createPlayerWithKeyUpdateStream(),
        frp.merge(acknowledgeStream$),
        frp.fold((remainingS, input) => {
            if (!frp.snapshot(cutIn)) return startS;

            const ack = input === undefined || frp.snapshot(acknowledge);
            if (remainingS <= 0) {
                if (ack && frp.snapshot(vZero)) {
                    return startS;
                } else {
                    return 0;
                }
            } else if (ack) {
                return startS;
            } else if (frp.snapshot(vZero)) {
                return startS;
            } else {
                return Math.max(remainingS - input.dt, 0);
            }
        }, startS),
        frp.map(remainingS => {
            return {
                alarm: remainingS < (penaltyS as number),
                penaltyBrake: remainingS <= 0,
            };
        })
    );
}
