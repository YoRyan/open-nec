/** @noSelfInFile */

import * as c from "./constants";
import * as frp from "./frp";
import { FrpEntity, FrpSource } from "./frp-entity";
import { rejectUndefined } from "./frp-extra";
import * as rw from "./railworks";

/**
 * Indicates whether the rail vehicle's front and/or rear couplers are engaged.
 */
export type VehicleCouplings = [front: boolean, rear: boolean];

export type VehicleDoors = [left: boolean, right: boolean];

export type PlayerUpdate = {
    dt: number;
    speedMps: number;
    isStopped: boolean;
    couplings: VehicleCouplings;
    doorsOpen: VehicleDoors;
};

export type AiUpdate = {
    dt: number;
    speedMps: number;
    isStopped: boolean;
    direction: SensedDirection;
    couplings: VehicleCouplings;
};

export enum SensedDirection {
    /**
     * This rail vehicle is is moving in the reverse direction (unless it is
     * flipped, in which case it is moving forward).
     */
    Backward,
    /**
     * This rail vehicle has not moved.
     */
    None,
    /**
     * This rail vehicle is moving in the forward direction (unless it is
     * flipped, in which case it is reversing).
     */
    Forward,
}

/**
 * Represents an OnControlValueChange() event.
 */
export type ControlValueChange = [name: string, index: number, value: number];

/**
 * Represents an OnConsistMessage() event.
 */
export type ConsistMessage = [id: number, content: string, direction: rw.ConsistDirection];

/**
 * Represents the state of the camera view passed to OnCameraEnter() and
 * OnCameraLeave().
 */
export enum VehicleCamera {
    Outside,
    Carriage,
    FrontCab,
    RearCab,
}

const coupleSenseMessage: [message: number, argument: string] = [10001, ""];
const maxCouplingUpdateS = 3;

/**
 * A rail vehicle is a scripted entity that has control values, a physics
 * simulation, and callbacks to track simulator state and the player's actions.
 */
export class FrpVehicle extends FrpEntity {
    /**
     * Convenient access to the methods for a rail vehicle.
     */
    public rv = new rw.RailVehicle("");
    /**
     * A behavior that returns true if the controls have settled after initial
     * startup.
     */
    public areControlsSettled: frp.Behavior<boolean> = () =>
        this.initTimeS === undefined ? false : this.e.GetSimulationTime() > this.initTimeS + 0.5;

    private playerUpdateSource = new FrpSource<PlayerUpdate>();
    private aiUpdateSource = new FrpSource<AiUpdate>();
    private cvChangeSource = new FrpSource<ControlValueChange>();
    private consistMessageSource = new FrpSource<ConsistMessage>();
    private vehicleCameraSource = new FrpSource<VehicleCamera>();

    private initTimeS: number | undefined = undefined;
    private direction = SensedDirection.None;
    private aiCouplings: undefined | VehicleCouplings = undefined;
    private playerCouplings: [nextUpdateS: number, couplings: VehicleCouplings] = [0, [false, false]];

    /**
     * Construct a new rail vehicle.
     * @param onInit The callback to run after the game has called
     * Initialise().
     */
    constructor(onInit: () => void) {
        super(() => {
            this.initTimeS = this.e.GetSimulationTime();
            onInit();
        });

        const update$ = this.createUpdateStream();
        update$(dt => {
            const isPlayer = this.rv.GetIsPlayer();
            const speedMps = this.rv.GetSpeed();
            const isStopped = Math.abs(speedMps) < c.stopSpeed;

            // Coupling status (only check it once for AI trains)
            let couplings;
            if (isPlayer) {
                const [nextUpdateS, saved] = this.playerCouplings;
                if (nextUpdateS <= 0) {
                    couplings = [
                        this.rv.SendConsistMessage(...coupleSenseMessage, rw.ConsistDirection.Forward),
                        this.rv.SendConsistMessage(...coupleSenseMessage, rw.ConsistDirection.Backward),
                    ] as VehicleCouplings;
                    this.playerCouplings = [Math.random() * maxCouplingUpdateS, couplings];
                } else {
                    couplings = saved;
                    this.playerCouplings = [nextUpdateS - dt, saved];
                }
                this.aiCouplings = undefined;
            } else {
                this.playerCouplings = [0, [false, false]];
                this.aiCouplings ??= [
                    this.rv.SendConsistMessage(...coupleSenseMessage, rw.ConsistDirection.Forward),
                    this.rv.SendConsistMessage(...coupleSenseMessage, rw.ConsistDirection.Backward),
                ] as VehicleCouplings;
                couplings = this.aiCouplings;
            }

            // Sensed direction
            if (speedMps > c.stopSpeed) {
                this.direction = SensedDirection.Forward;
            } else if (speedMps < -c.stopSpeed) {
                this.direction = SensedDirection.Backward;
            }

            if (isPlayer) {
                // Door status
                const doorsOpen = [
                    (this.rv.GetControlValue("DoorsOpenCloseLeft", 0) ?? 0) > 0.5,
                    (this.rv.GetControlValue("DoorsOpenCloseRight", 0) ?? 0) > 0.5,
                ] as VehicleDoors;

                this.playerUpdateSource.call({
                    dt,
                    speedMps,
                    isStopped,
                    couplings,
                    doorsOpen,
                });
            } else {
                // To save frames, don't update AI trains that are far away from the
                // camera.
                const [x, y, z] = this.rv.getNearPosition();
                const distanceM2 = x * x + y * y + z + z;
                const thresholdM = 2 * c.mi.toKm * 1000;
                if (distanceM2 < thresholdM * thresholdM) {
                    this.aiUpdateSource.call({
                        dt,
                        speedMps,
                        isStopped,
                        direction: this.direction,
                        couplings,
                    });
                }
            }
        });
    }

    /**
     * Create an event stream that fires while the current rail vehicle is being
     * controlled by the player, either as an engine, helper, or wagon.
     * @returns The new stream, which contains some useful vehicle state.
     */
    createPlayerUpdateStream() {
        return this.playerUpdateSource.createStream();
    }

    /**
     * Create an event stream that fires while the current rail vehicle is
     * under the control of the simulation, as opposed to the player.
     * @returns The new stream, which contains some useful vehicle state.
     */
    createAiUpdateStream() {
        return this.aiUpdateSource.createStream();
    }

    /**
     * Create an event stream from the OnControlValueChange() callback, which
     * fires when the player manipulates any control value.
     * @returns The new stream of control value change events.
     */
    createOnCvChangeStream() {
        return this.cvChangeSource.createStream();
    }

    /**
     * Create an event stream from the OnConsistMessage() callback, which fires
     * when a neighboring vehicle in a player train sends a message.
     * @returns The new stream of consist messages.
     */
    createOnConsistMessageStream() {
        return this.consistMessageSource.createStream();
    }

    /**
     * Create an event stream from the OnCameraEnter() and OnCameraLeave()
     * callbacks, which fire when the player is controlling this vehicle and
     * changes the current camera view.
     * @returns The new stream of camera states.
     */
    createOnCameraStream() {
        return this.vehicleCameraSource.createStream();
    }

    /**
     * Transform a player or AI update into a continuously updating stream of
     * controlvalues. Nil values are filtered out, so nonexistent controlvalues
     * will simply never fire their callbacks. To account for initial control
     * movements, values will not be produced until a brief period after the
     * simulation has initialized.
     * @param name The name of the controlvalue.
     * @param index The index of the controlvalue, usually 0.
     * @returns The new stream of numbers.
     */
    mapGetCvStream(
        name: string,
        index: number
    ): (eventStream: frp.Stream<PlayerUpdate | AiUpdate>) => frp.Stream<number> {
        return eventStream =>
            frp.compose(
                eventStream,
                frp.filter(_ => frp.snapshot(this.areControlsSettled)),
                frp.map(_ => this.rv.GetControlValue(name, index)),
                rejectUndefined()
            );
    }

    /**
     * Create an event stream that fires for the OnControlValueChange()
     * callback for a particular control. To account for initial control
     * movements, values will not be produced until a brief period after the
     * simulation has initialized.
     * @param name The name of the control.
     * @param index The index of the control, usually 0.
     * @returns The new stream of values.
     */
    createOnCvChangeStreamFor(name: string, index: number): frp.Stream<number> {
        return frp.compose(
            this.createOnCvChangeStream(),
            frp.filter(_ => frp.snapshot(this.areControlsSettled)),
            frp.filter(([cvcName, cvcIndex]) => cvcName === name && cvcIndex === index),
            frp.map(([, , value]) => value)
        );
    }

    /**
     * Create a continuously updating stream of controlvalues that also fires
     * for the OnControlValueChange() callback. This is the closest a script
     * can get to intercepting every possible change of the controlvalue.
     * @param name The name of the control.
     * @param index The index of the control, usually 0.
     * @returns The new stream of values.
     */
    createGetCvAndOnCvChangeStreamFor(name: string, index: number): frp.Stream<number> {
        const onUpdate$ = frp.compose(this.createPlayerUpdateStream(), this.mapGetCvStream(name, index));
        const onCvChange$ = this.createOnCvChangeStreamFor(name, index);
        return frp.compose(onUpdate$, frp.merge(onCvChange$));
    }

    /**
     * Like the ordinary fold(), except this version takes a behavior that
     * returns the initial value, and does not produce events until the
     * controls have settled.
     */
    foldAfterSettled<TAccum, TValue>(
        step: (accumulated: TAccum, value: TValue) => TAccum,
        initial: frp.Behavior<TAccum>
    ): (eventStream: frp.Stream<TValue>) => frp.Stream<TAccum> {
        return eventStream => next => {
            let accumulated = frp.snapshot(initial);
            let firstRead = false;
            eventStream(value => {
                if (frp.snapshot(this.areControlsSettled) && firstRead) {
                    next((accumulated = step(accumulated, value)));
                } else {
                    accumulated = frp.snapshot(initial);
                    firstRead = true;
                }
            });
        };
    }

    /**
     * Transform any event stream into a stream that produces false, unless the
     * original stream produces an event, in which case it produces true for a
     * specified amount of time. Can be used to drive one-shot special effects
     * like beeps, tones, messages, etc.
     * @param durationS The length of the post-event timer.
     * @returns A curried function that will produce the new event stream.
     */
    mapEventStreamTimer(durationS: number = 1): (eventStream: frp.Stream<any>) => frp.Stream<boolean> {
        return eventStream =>
            frp.compose(
                eventStream,
                frp.map(_ => undefined),
                frp.merge(this.createPlayerUpdateStream()),
                frp.fold((accum, e) => {
                    if (e === undefined) {
                        return durationS;
                    } else {
                        return Math.max(accum - e.dt, 0);
                    }
                }, 0),
                frp.map(t => t > 0)
            );
    }

    setup() {
        super.setup();

        OnControlValueChange = (name, index, value) => {
            this.cvChangeSource.call([name, index, value]);
        };
        OnConsistMessage = (id, content, dir) => {
            this.consistMessageSource.call([id, content, dir]);
        };
        OnCameraEnter = (cabEnd, carriageCam) => {
            let vc;
            if (carriageCam === rw.CameraEnterView.Cab) {
                vc = cabEnd === rw.CameraEnterCabEnd.Rear ? VehicleCamera.RearCab : VehicleCamera.FrontCab;
            } else {
                vc = VehicleCamera.Carriage;
            }
            this.vehicleCameraSource.call(vc);
        };
        OnCameraLeave = () => {
            this.vehicleCameraSource.call(VehicleCamera.Outside);
        };
    }
}
