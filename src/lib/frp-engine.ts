/** @noSelfInFile */

import * as c from "lib/constants";
import * as frp from "./frp";
import { FrpSource } from "./frp-entity";
import { rejectUndefined } from "./frp-extra";
import { FrpVehicle, PlayerUpdate, VehicleCamera } from "./frp-vehicle";
import * as rw from "./railworks";

/**
 * Represents the in-game "location" of the player.
 */
export enum PlayerLocation {
    /**
     * The player is not inside this engine.
     */
    Away,
    /**
     * The player is seated in the front cab.
     */
    InFrontCab,
    /**
     * The player is seated in the rear cab.
     */
    InRearCab,
}

export class FrpEngine extends FrpVehicle {
    /**
     * Convenient acces to the methods for an engine.
     */
    public eng = new rw.Engine("");

    private playerWithKeyUpdateSource = new FrpSource<PlayerUpdate>();
    private playerWithoutKeyUpdateSource = new FrpSource<PlayerUpdate>();
    private signalMessageSource = new FrpSource<string>();

    constructor(onInit: () => void) {
        super(onInit);

        const playerUpdate$ = this.createPlayerUpdateStream();
        playerUpdate$(pu => {
            if (this.eng.GetIsEngineWithKey()) {
                this.playerWithKeyUpdateSource.call(pu);
            } else {
                this.playerWithoutKeyUpdateSource.call(pu);
            }
        });
    }

    /**
     * Create an event stream that fires while the current rail vehicle is the
     * player-controlled engine.
     * @returns The new stream, which contains some useful vehicle state.
     */
    createPlayerWithKeyUpdateStream() {
        return this.playerWithKeyUpdateSource.createStream();
    }

    /**
     * Create an event stream that fires while the current rail vehicle is a
     * helper in the player train.
     * @returns The new stream, which contains some useful vehicle state.
     */
    createPlayerWithoutKeyUpdateStream() {
        return this.playerWithoutKeyUpdateSource.createStream();
    }

    /**
     * Create an event stream from the OnCustomSignalMessage() callback, which
     * fires when the player-controlled engine receives a custom message from
     * a lineside signal.
     * @returns The new stream of signal messages.
     */
    createOnSignalMessageStream() {
        return this.signalMessageSource.createStream();
    }

    /**
     * Create a behavior for the player's current "location" relative to the
     * engine.
     */
    createPlayerLocationBehavior() {
        const isAway$ = frp.compose(
            this.createAiUpdateStream(),
            frp.merge(this.createPlayerWithoutKeyUpdateStream()),
            frp.map(_ => PlayerLocation.Away)
        );
        const location$ = frp.compose(
            this.createOnCameraStream(),
            frp.map(vc => {
                switch (vc) {
                    case VehicleCamera.FrontCab:
                        return PlayerLocation.InFrontCab;
                    case VehicleCamera.RearCab:
                        return PlayerLocation.InRearCab;
                    default:
                        return undefined;
                }
            }),
            rejectUndefined(),
            frp.merge(isAway$)
        );
        return frp.stepper(location$, PlayerLocation.InFrontCab);
    }

    /**
     * Create a behavior for the safety systems acknowledge (Q) control.
     */
    createAcknowledgeBehavior() {
        const cameraView = frp.stepper(this.createOnCameraStream(), VehicleCamera.FrontCab);
        return frp.liftN(
            (awsReset, cameraView) => {
                const isOutside = cameraView === VehicleCamera.Outside || cameraView === VehicleCamera.Carriage;
                return awsReset || isOutside;
            },
            () => (this.rv.GetControlValue("AWSReset", 0) as number) > 0.5,
            cameraView
        );
    }

    /**
     * A convenience stream for a bell that can be automatically turned on, by
     * e.g. a blast of the horn. The keyboard bell toggle will be kept in sync
     * with the control value.
     * @returns A transformer that maps bell triggers to the final bell state.
     * control value.
     */
    mapAutoBellStream(): (eventStream: frp.Stream<any>) => frp.Stream<number> {
        return eventStream => {
            const turnOn$ = frp.compose(
                eventStream,
                frp.filter(_ => this.eng.GetIsEngineWithKey()),
                frp.map(_ => 1)
            );
            return frp.compose(
                this.createOnCvChangeStreamFor("Bell", 0),
                frp.map(v => {
                    const outOfSync = (v === 0 || v === 1) && v === this.rv.GetControlValue("Bell", 0);
                    return outOfSync ? 1 - v : v;
                }),
                frp.filter(_ => this.eng.GetIsEngineWithKey()),
                frp.merge(turnOn$)
            );
        };
    }

    /**
     * Create a PID-based cruise control. For now, it only outputs throttle.
     * @param onOff A behavior that indicates cruise control is turned on.
     * @param targetSpeedMps A behavior that communicates the target speed.
     * @param kpid The Kp, Ki, and Kd factors.
     * @returns A transformer that maps update events to cruise control output,
     * scaled from 0 to 1.
     */
    createCruiseControlStream(
        onOff: frp.Behavior<boolean>,
        targetSpeedMps: frp.Behavior<number>,
        kpid?: [number, number, number]
    ): frp.Stream<number> {
        const [kp, ki, kd] = kpid ?? [1, 0, 0];

        type Accum = {
            previousError: number;
            integral: number;
            output: number;
        };
        const initAccum: Accum = { output: 0, previousError: 0, integral: 0 };
        return frp.compose(
            this.createPlayerWithKeyUpdateStream(),
            frp.fold((accum, pu) => {
                if (!frp.snapshot(onOff)) {
                    return initAccum;
                }
                // See https://en.wikipedia.org/wiki/PID_controller#Pseudocode
                const speedoMps = (this.rv.GetControlValue("SpeedometerMPH", 0) as number) * c.mph.toMps;
                const error = frp.snapshot(targetSpeedMps) - speedoMps;
                const proportional = error;
                const integral = accum.integral + error * pu.dt;
                const derivative = (error - accum.previousError) / pu.dt;
                const output = kp * proportional + ki * integral + kd * derivative;
                return { previousError: error, integral, output };
            }, initAccum),
            frp.map(accum => accum.output)
        );
    }

    setup() {
        super.setup();

        OnCustomSignalMessage = msg => {
            this.signalMessageSource.call(msg);
        };
    }
}
