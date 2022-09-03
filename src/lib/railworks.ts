/** @noSelfInFile */

/**
 * A direction used by signals to send consist and signal messages.
 */
export enum SignalDirection {
    Forward = 1,
    Backward = -1,
}

export enum CameraEnterCabEnd {
    None = 0,
    Front = 1,
    Rear = 2,
}

export enum CameraEnterView {
    Cab = 0,
    Carriage = 1,
}

export type AllNodes = "all";

/**
 * A direction used by rail vehicles to send consist messages and search for
 * track features.
 */
export enum ConsistDirection {
    Forward = 0,
    Backward = 1,
}

export enum BrakeFailure {
    /* Fade in the braking as a result of excess heat. */
    Fade = "BRAKE_FADE",

    /** Brake is stuck due to locking on the wheel. */
    Lock = "BRAKE_LOCK",
}

export enum SearchFailed {
    NothingFound = -1,
    EndOfTrack = 0,
}

export enum BasicSignalState {
    Invalid = -1,
    Go = 0,
    Warning = 1,
    Red = 2,
}

/** 2D map's "pro" signal state for more detailed aspect information. */
export enum ProSignalState {
    Invalid = -1,
    Yellow = 1,
    DoubleYellow = 2,
    Red = 3,
    FlashingYellow = 10,
    FlashingDoubleYellow = 11,
}

export enum SpeedLimitType {
    UnsignedTrack = 1,
    SignedTrack = 2,
    Signal = 3,
}

export enum TrainType {
    Special = 0,
    LightEngine = 1,
    ExpressPassenger = 2,
    StoppingPassenger = 3,
    HighSpeedFreight = 4,
    ExpressFreight = 5,
    StandardFreight = 6,
    LowSpeedFreight = 7,
    OtherFreight = 8,
    EmptyStock = 9,
    International = 10,
}

export type AllPowerUnits = -1;

export enum ConditionStatus {
    NotYetMet = 0,
    Succeeded = 1,
    Failed = 2,
}

export enum MessageBox {
    Info = 0,
    Alert = 1,
}

export type Indefinite = 0;

export enum MessageBoxPosition {
    Top = 1,
    VerticalCentre = 2,
    Bottom = 4,
    Left = 8,
    Centre = 16,
    Right = 32,
}

export enum MessageBoxSize {
    Small = 0,
    Regular = 1,
    Large = 2,
}

export enum Season {
    Spring = 0,
    Summer = 1,
    Autumn = 2,
    Winter = 3,
}

export enum VideoMode {
    Fullscreen = 0,
    FrontAndCentred = 1,
    VideoCall = 2,
}

export enum VideoControls {
    Play = 1,
    Pause = 2,
    Stop = 4,
    Seek = 8,
}

export enum Precipitation {
    Rain = 0,
    Sleet = 1,
    Hail = 2,
    Snow = 3,
}

export enum DefaultCamera {
    Cab = "CabCamera",
    External = "ExternalCamera",
    HeadOut = "HeadOutCamera",
    TrackSide = "TrackSideCamera",
    Carriage = "CarriageCamera",
    Coupling = "CouplingCamera",
    Yard = "YardCamera",
    Free = "FreeCamera",
}

export type NoRevert = 0;

/**
 * Signal message types that are provided by the core game code.
 */
export enum SignalMessage {
    ResetSignalState = 0,
    InitialiseSignalToBlocked = 1,
    JunctionStateChange = 2,
    InitialiseToPrepared = 3,
    RequestToPassDanger = 4,
    OccupationIncrement = 10,
    OccupationDecrement = 11,
}

export enum ConsistMessage {
    SigmsgCustom = 15,
}

export type JunctionAgainstOrEndOfTrack = -1;

/**
 * A context, such as a rail vehicle or child node, on which scripting functions
 * can be invoked.
 */
export class Entity {
    private id: string = "";

    constructor(id: string) {
        this.id = id;
    }

    protected fn = (name: string) => (this.id === "" ? name : `${this.id}:${name}`);
}

/**
 * Scripted entities are aware of game time and can request an update every
 * frame.
 */
export class ScriptedEntity extends Entity {
    /** Request script to get update call once per frame */
    BeginUpdate() {
        Call(this.fn("BeginUpdate"));
    }

    /** Request script to end update call once per frame */
    EndUpdate() {
        Call(this.fn("EndUpdate"));
    }

    /**
     * Get the simulation time in seconds
     * @returns Integer of the simulation time in seconds
     */
    GetSimulationTime() {
        const [r] = Call(this.fn("GetSimulationTime"));
        return r as number;
    }

    /**
     * Is the game using expert mode controls
     * @returns 1 = if the controls are in expert mode, 0 = if the controls are
     * not in expert mode
     */
    IsExpertMode() {
        const [r] = Call(this.fn("IsExpertMode"));
        return r === 1;
    }
}

/**
 * Rendered entities are world objects that have a location, a set of
 * animations, and a set of descendant nodes.
 */
export class RenderedEntity extends ScriptedEntity {
    /**
     * Get the position in the current world frame of the object (local
     * coordinates are local to a moving origin centred on teh camera's current
     * tile)
     * @returns The position x, y, z in metres relative to the origin
     */
    getNearPosition(): [x: number, y: number, z: number] {
        const [x, y, z] = Call(this.fn("getNearPosition"));
        return [x as number, y as number, z as number];
    }

    /**
     * Activate/Deactivate a node in a model
     * @param name name of the node (use "all" for all nodes)
     * @param activate 1 = show, 0 = hide
     */
    ActivateNode(name: AllNodes | string, activate: boolean) {
        Call(this.fn("ActivateNode"), name, activate ? 1 : 0);
    }

    /**
     * Add time to an animation
     * @param name name of the animation
     * @param time the amount of time in seconds, either positive or negative
     * @returns The remaining time in the animation
     */
    AddTime(name: string, time: number) {
        const [r] = Call(this.fn("AddTime"), name, time);
        return r as number | undefined;
    }

    /**
     * Reset an animation
     * @param name name of the animation
     */
    Reset(name: string) {
        Call(this.fn("Reset"), name);
    }

    /**
     * Set the time of an animation
     * @param name name of the animation
     * @param time the amount of time in seconds, either positive or negative
     * @returns The remaining time in the animation
     */
    SetTime(name: string, time: number) {
        const [r] = Call(this.fn("SetTime"), name, time);
        return r as number | undefined;
    }

    /**
     * Set the position in the current world frame of the object (local
     * coordinates are local to a moving origin centred on the camera's current
     * tile)
     * @param x The x coordinate
     * @param y The y coordinate
     * @param z The z coordinate
     */
    setNearPosition(x: number, y: number, z: number) {
        Call(this.fn("setNearPosition"), x, y, z);
    }
}

/**
 * Rail vehicles can query their location relative to the track and trackside
 * features and have a set of controls.
 */
export class RailVehicle extends RenderedEntity {
    /**
     * Is the rail vehicle controlled by the player
     * @returns 1 = if the train is player controlled, 0 = if the train is AI
     * controlled
     */
    GetIsPlayer() {
        const [r] = Call(this.fn("GetIsPlayer"));
        return r === 1;
    }

    /**
     * Gets the rail vehicle's current speed
     * @returns The speed in metres per second
     */
    GetSpeed() {
        const [r] = Call(this.fn("GetSpeed"));
        return r as number;
    }

    /**
     * Get the rail vehicle's acceleration
     * @returns The acceleration in metres per second squared
     */
    GetAcceleration() {
        const [r] = Call(this.fn("GetAcceleration"));
        return r as number;
    }

    /**
     * Get the total mass of the rail vehicle including cargo
     * @returns The mass in kilograms
     */
    GetTotalMass() {
        const [r] = Call(this.fn("GetTotalMass"));
        return r as number;
    }

    /**
     * Get the total mass of the entire consist including cargo
     * @returns The mass in kilograms
     */
    GetConsistTotalMass() {
        const [r] = Call(this.fn("GetConsistTotalMass"));
        return r as number;
    }

    /**
     * Get the consist length
     * @returns The length in metres
     */
    GetConsistLength() {
        const [r] = Call(this.fn("GetConsistLength"));
        return r as number;
    }

    /**
     * Get the gradient at the front of the consist
     * @returns The gradient as a percentage
     */
    GetGradient() {
        const [r] = Call(this.fn("GetGradient"));
        return r as number;
    }

    /**
     * Get the rail vehicle's number
     * @returns The rail vehicle number
     */
    GetRVNumber() {
        const [r] = Call(this.fn("GetRVNumber"));
        return r as string;
    }

    /**
     * Sets the rail vehicle's number (used for changing destination boards)
     * @param number The new number for the vehicle
     */
    SetRVNumber(number: string) {
        Call(this.fn("SetRVNumber"), number);
    }

    /**
     * Get the curvature (radius of curve) at the front of the consist
     * @returns The radius of the curve in metres
     */
    GetCurvature() {
        const [r] = Call(this.fn("GetCurvature"));
        return r as number;
    }

    /**
     * Send a message to the next or previous rail vehicle in the consist. Calls
     * the script function OnConsistMessage ( message, argument, direction ) in
     * the next or previous rail vehicle
     * @param message the ID of a message to send (IDs 0 to 100 are reserved,
     * please use IDs greater than 100)
     * @param argument a string argument
     * @param direction 0 = sends a message to the vehicle in front, 1 = sends a
     * message to the vehicle behind
     * @returns 1 = if there was a next/previous rail vehicle
     */
    SendConsistMessage(message: number, argument: string, direction: ConsistDirection) {
        const [r] = Call(this.fn("SendConsistMessage"), message, argument, direction);
        return r === 1;
    }

    /**
     * Get the curvature relative to the front of the vehicle
     * @param displacement If positive, gets curvature this number of metres
     * ahead of the front of the vehicle. If negative, gets curvature this
     * number of metres behind the rear of the vehicle.
     * @returns The radius of the curve in metres positive if curving to the
     * right, negative if curving to the left, relative to the way the vehicle
     * is facing.
     */
    GetCurvatureAhead(displacement: number) {
        const [r] = Call(this.fn("GetCurvatureAhead"), displacement);
        return r as number;
    }

    /**
     * Sets a failure value on the train brake system for this vehicle
     * @param name The name of the failure type.
     * @param value The value (proportion) of the failure dependent on failure
     * type
     */
    SetBrakeFailureValue(name: BrakeFailure, value: number) {
        Call(this.fn("SetBrakeFailureValue"), name, value);
    }

    /**
     * Get the next restrictive signal's distance and state
     * @param direction 0 = forwards, 1 = backwards.
     * @param minDistance How far ahead in metres to start searching.
     * @param maxDistance How far ahead in metres to stop searching.
     * @returns The basic and "pro" signal states and the distance, in metres,
     * to the signal.
     */
    GetNextRestrictiveSignal(
        direction: ConsistDirection = ConsistDirection.Forward,
        minDistance: number = 0,
        maxDistance: number = 10000
    ): SearchFailed | [basicState: BasicSignalState, distance: number, proState: ProSignalState] {
        const [p1, p2, p3, p4] = Call(this.fn("GetNextRestrictiveSignal"), direction, minDistance, maxDistance);
        if (p1 === -1) {
            return SearchFailed.NothingFound;
        } else if (p1 === 0) {
            return SearchFailed.EndOfTrack;
        } else {
            return [p2 as BasicSignalState, p3 as number, p4 as ProSignalState];
        }
    }

    /**
     * Get the next restrictive signal's distance and state
     * @param direction 0 = forwards, 1 = backwards.
     * @param minDistance How far ahead in metres to start searching.
     * @param maxDistance How far ahead in metres to stop searching.
     * @returns The type of speed limit, the speed restriction in metres per
     * second, and the distance to it in metres.
     */
    GetNextSpeedLimit(
        direction: ConsistDirection = ConsistDirection.Forward,
        minDistance: number = 0,
        maxDistance: number = 10000
    ): SearchFailed | [found: SpeedLimitType, speed: number, distance: number] {
        const [p1, p2, p3] = Call(this.fn("GetNextSpeedLimit"), direction, minDistance, maxDistance);
        if (p1 === -1) {
            return SearchFailed.NothingFound;
        } else if (p2 === 0) {
            return SearchFailed.EndOfTrack;
        } else {
            return [p1 as SpeedLimitType, p2 as number, p3 as number];
        }
    }

    /**
     * Get the current speed limit for the consist
     * @returns Two values are returned for track and signal limits respectively
     */
    GetCurrentSpeedLimit(): [track: number, signal: number] {
        const [r1, r2] = Call(this.fn("GetCurrentSpeedLimit"), 1);
        return [r1 as number, r2 as number];
    }

    /**
     * Get the class of the consist
     */
    GetConsistType() {
        const [r] = Call(this.fn("GetConsistType"));
        return r as TrainType;
    }

    /**
     * Evaluates if the camera is near this vehicle ( < 4km)
     * @returns True if near
     */
    GetIsNearCamera() {
        const [r] = Call(this.fn("GetIsNearCamera"));
        return r as boolean;
    }

    /**
     * Evaluates if the vehicle is in a tunnel
     * @returns True if in a tunnel
     */
    GetIsInTunnel() {
        const [r] = Call(this.fn("GetIsInTunnel"));
        return r as boolean;
    }

    /**
     * Evaluates whether a control with a specific name exists
     * @param name name of the control
     * @param index the index of the control (usually 0 unless there are
     * multiple controls with the same name)
     * @returns True if the control exists
     */
    ControlExists(name: string, index: number) {
        const [r] = Call(this.fn("ControlExists"), name, index);
        return r as boolean;
    }

    /**
     * Get the value for a control
     * @param name name of the control
     * @param index the index of the control (usually 0 unless there are
     * multiple controls with the same name)
     * @returns The value for the control
     */
    GetControlValue(name: string, index: number) {
        const [r] = Call(this.fn("GetControlValue"), name, index);
        return r as number | undefined;
    }

    /**
     * Sets a value for a control
     * @param name name of the control
     * @param index the index of the control (usually 0 unless there are
     * multiple controls with the same name)
     * @param value the value to set the control to
     */
    SetControlValue(name: string, index: number, value: number) {
        Call(this.fn("SetControlValue"), name, index, value);
    }

    /**
     * Get the minimum value for a control
     * @param name name of the control
     * @param index the index of the control (usually 0 unless there are
     * multiple controls with the same name)
     * @returns The control's minimum value
     */
    GetControlMinimum(name: string, index: number) {
        const [r] = Call(this.fn("GetControlMinimum"), name, index);
        return r as number | undefined;
    }

    /**
     * Get the maximum value for a control
     * @param name name of the control
     * @param index the index of the control (usually 0 unless there are
     * multiple controls with the same name)
     * @returns The control's maximum value
     */
    GetControlMaximum(name: string, index: number) {
        const [r] = Call(this.fn("GetControlMaximum"), name, index);
        return r as number | undefined;
    }

    /**
     * Get the normalised value of a wiper animation current frame
     * @param index index of the wiper pair
     * @param wiper the wiper to get the value of in the wiper pair
     * @returns A value between 0.0 and 1.0 of the wiper's current position in
     * the animation
     */
    GetWiperValue(index: number, wiper: number) {
        const [r] = Call(this.fn("GetWiperValue"), index, wiper);
        return r as number | undefined;
    }

    /**
     * Set the normalised value of a wiper's animation
     * @param index index of the wiper pair
     * @param wiper the wiper to set the value of in the wiper pair
     * @param value the value to set the wiper to
     */
    SetWiperValue(index: number, wiper: number, value: number) {
        Call(this.fn("SetWiperValue"), index, wiper, value);
    }

    /**
     * Get the number of wiper pairs this control container has
     * @returns Number of wiper pairs in the control container
     */
    GetWiperPairCount() {
        const [r] = Call(this.fn("GetWiperPairCount"));
        return r as number;
    }

    /**
     * Evaluate whether or not a control is locked
     * @param name name of the control
     * @param index the index of the control (usually 0 unless there are
     * multiple controls with the same name)
     * @returns 0 = unlocked, 1 = locked
     */
    IsControlLocked(name: string, index: number) {
        const [r] = Call(this.fn("IsControlLocked"), name, index);
        if (r === 1) {
            return true;
        } else if (r === 0) {
            return false;
        } else {
            return undefined;
        }
    }

    /**
     * Locks a control so the user can no longer affect it e.g. to simulate a
     * failure
     * @param name name of the control
     * @param index the index of the control (usually 0 unless there are
     * multiple controls with the same name)
     * @param locked True = lock a control, False = unlock a control
     */
    LockControl(name: string, index: number, locked: boolean) {
        Call(this.fn("LockControl"), name, index, locked);
    }
}

/**
 * Sound entities represent audio proxies.
 */
export class Sound extends Entity {
    /**
     * Set a parameter on an audio proxy
     * @param name name of the parameter
     * @param value the value
     */
    SetParameter(name: string, value: number) {
        Call(this.fn("SetParameter"), name, value);
    }
}

/**
 * Engines are powered rail vehicles.
 */
export class Engine extends RailVehicle {
    /**
     * Get the proportion of tractive effort being used
     * @returns The proportion of tractive effort between 0 and 100%
     */
    GetTractiveEffort() {
        const [r] = Call(this.fn("GetTractiveEffort"));
        return r as number;
    }

    /**
     * Is this the player controlled primary engine
     * @returns True if this is the engine the player is controlling
     */
    GetIsEngineWithKey() {
        const [r] = Call(this.fn("GetIsEngineWithKey"));
        return r === 1;
    }

    /**
     * Evaluate whether this engine is disabled
     * @returns True if this engine is disabled
     */
    GetIsDeadEngine() {
        const [r] = Call(this.fn("GetIsDeadEngine"));
        return r === 1;
    }

    /**
     * Set the proportion of normal power a diesel unit should output
     * @param index index of the power unit (use -1 for all power units)
     * @param value the proportion of normal power output between 0.0 and 1.0
     */
    SetPowerProportion(index: AllPowerUnits | number, value: number) {
        Call(this.fn("SetPowerProportion"), index, value);
    }

    /**
     * Get the proportion of full firebox mass
     * @returns The mass of the firebox as a proportion of max in the range 0.0
     * to 1.0
     */
    GetFireboxMass() {
        const [r] = Call(this.fn("GetFireboxMass"));
        return r as number;
    }
}

/**
 * Emitter entities represent particle emitters.
 */
export class Emitter extends Entity {
    /**
     * Sets the emitter colour multiplier
     * @param red red
     * @param green green
     * @param blue blue
     * @param alpha optionally, alpha
     */
    SetEmitterColour(red: number, green: number, blue: number, alpha?: number) {
        const fn = this.fn("SetEmitterColour");
        if (alpha !== undefined) {
            Call(fn, red, green, blue, alpha);
        } else {
            Call(fn, red, green, blue);
        }
    }

    /**
     * Set the emitter rate multiplier
     * @param rate the rate. Defaults to 1
     */
    SetEmitterRate(rate: number = 1) {
        Call(this.fn("SetEmitterRate"), rate);
    }

    /**
     * Activate an emitter
     * @param active 1 = activate, 0 = deactivate
     */
    SetEmitterActive(active: boolean) {
        Call(this.fn("SetEmitterActive"), active ? 1 : 0);
    }

    /**
     * Gets the current emitter colour
     * @returns The colour in rgba with components r, g, b, a
     */
    GetEmitterColour(): [red: number, green: number, blue: number, alpha: number] {
        const [r, g, b, a] = Call(this.fn("GetEmitterColour"));
        return [r as number, g as number, b as number, a as number];
    }

    /**
     * Gets the emitter rate multiplier. 1.0 is default, 0.0 is no emission.
     * @returns The emitter rate
     */
    GetEmitterRate() {
        const [r] = Call(this.fn("GetEmitterRate"));
        return r as number;
    }

    /**
     * Gets whether the emitter is active
     * @returns True if active
     */
    GetEmitterActive() {
        const [r] = Call(this.fn("GetEmitterActive"));
        return r === 1;
    }

    /**
     * Restart the emitter
     */
    RestartEmitter() {
        Call(this.fn("RestartEmitter"));
    }

    /**
     * Multiply the initial velocity by a given value. Default value is 1.0
     * @param value Multiplier to scale X, Y, Z velocity components
     */
    SetInitialVelocityMultiplier(value: number) {
        Call(this.fn("SetInitialVelocityMultiplier"), value);
    }
}

/**
 * Light entities represent Spot and Point lights.
 */
export class Light extends Entity {
    /**
     * Turn the light on or off
     * @param value 1 = on, 0 = off
     */
    Activate(value: boolean) {
        Call(this.fn("Activate"), value ? 1 : 0);
    }

    /**
     * Set the colour of the light
     * @param red red component of the colour
     * @param green green component of the colour
     * @param blue blue component of the colour
     */
    SetColour(red: number, green: number, blue: number) {
        Call(this.fn("SetColour"), red, green, blue);
    }

    /**
     * Get the colour of the light
     * @returns the red, green and blue components of the colour
     */
    GetColour(): [red: number, green: number, blue: number] {
        const [r, g, b] = Call(this.fn("GetColour"));
        return [r as number, g as number, b as number];
    }

    /**
     * Sets the range of the light
     * @param range The range of the light in metres
     */
    SetRange(range: number) {
        Call(this.fn("SetRange"), range);
    }

    /**
     * Get the range of the light
     * @returns The range of the light in metres
     */
    GetRange() {
        const [r] = Call(this.fn("GetRange"));
        return r as number;
    }

    /**
     * Sets the umbra of a spot light
     * @param umbra the angle of the outer cone in degrees
     */
    SetUmbraAngle(umbra: number) {
        Call(this.fn("SetUmbraAngle"), umbra);
    }

    /**
     * Gets the umbra of a spot light
     * @returns The angle of the outer cone in degrees
     */
    GetUmbraAngle() {
        const [r] = Call(this.fn("GetUmbraAngle"));
        return r as number;
    }

    /**
     * Sets the penumbra of a spot light
     * @param penumbra the angle of the inner cone in degrees
     */
    SetPenumbraAngle(penumbra: number) {
        Call(this.fn("SetPenumbraAngle"), penumbra);
    }

    /**
     * Gets the penumbra of a spot light
     * @returns The angle of the inner cone in degrees
     */
    GetPenumbraAngle() {
        const [r] = Call(this.fn("GetPenumbraAngle"));
        return r as number;
    }
}

/**
 * The core scenario scripting module.
 */
export const ScenarioManager = {
    /**
     * Triggers the failure of the scenario
     * @param message The message to show indicating why the scenario failed
     */
    TriggerScenarioFailure(message: string) {
        SysCall("ScenarioManager:TriggerScenarioFailure", message);
    },

    /**
     * Triggers the successful completion of the scenario
     * @param message The message to show indicating why the scenario succeeded
     */
    TriggerScenarioComplete(message: string) {
        SysCall("ScenarioManager:TriggerScenarioComplete", message);
    },

    /**
     * Triggers a deferred event
     * @param event The name of the event
     * @param time The time in seconds until the event should trigger
     * @returns false if the event was already scheduled
     */
    TriggerDeferredEvent(event: string, time: number) {
        const [r] = SysCall("ScenarioManager:TriggerDeferredEvent", event, time);
        return r !== 0;
    },

    /**
     * Cancels a deferred event
     * @param event The name of the event
     * @returns false if the event was no longer scheduled
     */
    CancelDeferredEvent(event: string) {
        const [r] = SysCall("ScenarioManager:CancelDeferredEvent", event);
        return r !== 0;
    },

    /**
     * Begins testing of a condition
     * @param condition The name of the condition
     * @returns false if the condition was already scheduled
     * @note As soon as the condition is completed as either
     * CONDITION_SUCCEEDED(1) or CONDITION_FAILED(2), the condition will cease
     * to be tested. If the condition was already complete at hte time of the
     * call, no CheckCondition will be generated.
     */
    BeginConditionCheck(condition: string) {
        const [r] = SysCall("ScenarioManager:BeginConditionCheck", condition);
        return r !== 0;
    },

    /**
     * Removes a condition from checking per frame
     * @param condition The name of the condition
     * @returns false if the condition was no longer scheduled
     * @note Cannot be called from within TestCondition
     */
    EndConditionCheck(condition: string) {
        const [r] = SysCall("ScenarioManager:EndConditionCheck", condition);
        return r !== 0;
    },

    /**
     * Get the status of a script condition
     * @param condition The name of the condition
     * @returns CONDITION_NOT_YET_MET(0), CONDITION_SUCCEEDED(1) or
     * CONDITION_FAILED(2)
     * @note The call only tests the saved status of a condition, it does not
     * generate a call to CheckCondition
     */
    GetConditionStatus(condition: string) {
        const [r] = SysCall("ScenarioManager:GetConditionStatus", condition);
        return r as ConditionStatus;
    },

    /**
     * Shows a dialogue box with a message
     * @param title The title for the message box
     * @param message The text for the message
     * @param type The type of message box INFO(0) or ALERT(1)
     * @note If title or message are in UUID format, then they are used as keys
     * into the language table
     */
    ShowMessage(title: string, message: string, type: MessageBox) {
        SysCall("ScenarioManager:ShowMessage", title, message, type);
    },

    /**
     * Shows an info dialogue box with a message and extended attributes
     * @param title The title for the message box
     * @param message The text for the message
     * @param time The time to show the message, 0.0 for indefinite
     * @param pos The position of the message box (MSG_TOP(1), MSG_VCENTRE(2),
     * MSG_BOTTOM(4), MSG_LEFT(8), MSG_CENTRE(16), MSG_RIGHT(32))
     * @param size The size of the message box (MSG_SMALL(0), MSG_REG(1),
     * MSG_LRG(2))
     * @param pause If true pause the game while the message is shown
     * @note If title or message are in UUID format, then they are used as keys
     * into the language table
     */
    ShowInfoMessageExt(
        title: string,
        message: string,
        time: Indefinite | number,
        pos: MessageBoxPosition,
        size: MessageBoxSize,
        pause: boolean
    ) {
        SysCall("ScenarioManager:ShowInfoMessageExt", title, message, time, pos, size, pause ? 1 : 0);
    },

    /**
     * Shows an info dialogue box with a message and extended attributes
     * @param title The title for the message box
     * @param message The text for the message
     * @param time The time to show the message, 0.0 for indefinite
     * @param event Event name triggered on click of message
     * @note If title or message are in UUID format, then they are used as keys
     * into the language table
     */
    ShowAlertMessageExt(title: string, message: string, time: Indefinite | number, event: string) {
        SysCall("ScenarioManager:ShowAlertMessageExt", title, message, time, event);
    },

    /**
     * Check if a service is at a specific destination.
     * @param service The name of the service.
     * @param dest The name of the station stop.
     */
    IsAtDestination(service: string, dest: string) {
        const [r] = SysCall("ScenarioManager:IsAtDestination", service, dest);
        return r === 1;
    },

    /**
     * Gets the time since the scenario start in seconds
     * @returns The time since the scenario start in seconds
     */
    GetScenarioTime() {
        const [r] = SysCall("ScenarioManager:GetScenarioTime");
        return r as number;
    },

    /**
     * Gets the time since midnight in seconds
     * @returns The time since midnight in seconds
     */
    GetTimeOfDay() {
        const [r] = SysCall("ScenarioManager:GetTimeOfDay");
        return r as number;
    },

    /**
     * Locks out controls and keyboard
     */
    LockControls() {
        SysCall("ScenarioManager:LockControls");
    },

    /**
     * Unlocks controls and keyboard
     */
    UnlockControls() {
        SysCall("ScenarioManager:UnlockControls");
    },

    /**
     * Gets the season
     * @returns SEASON_SPRING = 0, SEASON_SUMMER = 1, SEASON_AUTUMN = 2,
     * SEASON_WINTER = 3
     */
    GetSeason() {
        const [r] = SysCall("ScenarioManager:GetSeason");
        return r as Season;
    },

    /**
     * Plays a video message during the scenario.
     * @param name The filename of the video.
     * @param mode The manner in which to display the video.
     * @param pause Pause the game while playing the video.
     * @param controls A bitfield that sets the controls available to the player.
     * @see https://trainsimlive.blogspot.com/2015/02/ts2015-scenario-scripting-in-lua-part_21.html
     */
    PlayVideoMessage(name: string, mode: VideoMode, pause: boolean, controls: VideoControls | number) {
        SysCall("ScenarioManager:PlayVideoMessage", name, mode, pause ? 1 : 0, controls, 0);
    },

    /**
     * Checks if the named video message is still playing.
     * @param name The filename of the video.
     * @returns Whether or not the video is still playing.
     * @see https://trainsimlive.blogspot.com/2015/02/ts2015-scenario-scripting-in-lua-part_21.html
     */
    IsVideoMessagePlaying(name: string) {
        const [r] = SysCall("ScenarioManager:IsVideoMessagePlaying", name);
        return r === 1;
    },
};

/**
 * The weather control module.
 */
export const WeatherController = {
    /**
     * Gets the current type of precipitation
     * @returns 0 = rain, 1 = sleet, 2 = hail, 3 = snow
     */
    GetCurrentPrecipitationType() {
        const [r] = SysCall("WeatherController:GetCurrentPrecipitationType");
        return r as Precipitation;
    },

    /**
     * Gets the density of the precipitation
     * @returns A value between 0 and 1 for the density of precipitation
     */
    GetPrecipitationDensity() {
        const [r] = SysCall("WeatherController:GetPrecipitationDensity");
        return r as number;
    },

    /**
     * Gets the speed of the precipitation
     * @returns The vertical fall speed of precipitation in metres per second
     */
    GetPrecipitationSpeed() {
        const [r] = SysCall("WeatherController:GetPrecipitationSpeed");
        return r as number;
    },
};

/**
 * The camera control module.
 */
export const CameraManager = {
    /**
     * Switch to a named camera
     * @param name The name of the camera
     * @param time The time in seconds before reverting back to previous camera.
     * Use 0 for no revert
     * @note The camera can be any of hte standard cameras or a user-defined
     * camera.
     */
    ActivateCamera(name: DefaultCamera | string, time: NoRevert | number) {
        SysCall("CameraManager:ActivateCamera", name, time);
    },

    /**
     * Have the camera look at an objection
     * @param name The name of the object to look at
     * @returns True if the named object was found
     * @note If name is a rail vehicle number, then the camera will look at that
     * rail vehicle. If the name is that of a named object, then only the free
     * camera will look at the object
     */
    LookAt(name: string) {
        const [r] = SysCall("CameraManager:LookAt", name);
        return r === 1;
    },

    /**
     * Move the camera to a location
     * @param longitude The longitude of the position
     * @param latitude The latitude of the position
     * @param height The height above sea level
     * @returns True if the camera could move to the location
     */
    JumpTo(longitude: number, latitude: number, height: number) {
        const [r] = SysCall("CameraManager:JumpTo", longitude, latitude, height);
        return r === 1;
    },
};

/**
 * Signals have access to the signalling functions.
 */
export class Signal extends RenderedEntity {
    /**
     * Send a message along the track to the next/previous signal link on the
     * track (ignoring links of the same signal). See Signal Message Types for a
     * description of messages.
     * @param message The message type
     * @param argument An optional string argument passed with the message.
     * @param direction The direction the script sends the message relative to
     * the link. 1 = forwards, -1 = backwards
     * @param link The direction of the link that the message should be sent to,
     * relative to the link
     * @param index The index of the link to send the message from
     * @returns Signal Found - was a signal found, End Of Track - was the end of
     * the track encountered (rather than a circuit)
     * @usage Used to communicate between signals
     * @specialCases Where argument is set to the special value "DoNotForward"
     * the receiving signal is expected not to pass forward the message.
     */
    SendSignalMessage(
        message: SignalMessage | number,
        argument: string,
        direction: SignalDirection,
        link: SignalDirection = SignalDirection.Forward,
        index: number = 0
    ) {
        const [r] = Call(this.fn("SendSignalMessage"), message, argument, direction, link, index);
        if (r === -1) {
            return SearchFailed.NothingFound;
        } else if (r === 0) {
            return SearchFailed.EndOfTrack;
        } else {
            return true;
        }
    }

    /**
     * Send a message to passing consists. See consist message types for a list
     * of valid types
     * @param message The message type. SIGMSG_CUSTOM - While the other message
     * types are handled directly by the app, custom messages are passed on to
     * the engine script using the script method OnCustomSignalMessage passing
     * the argument to the engine script.
     * @param argument An optional string argument passed with the message
     * @usage Only safe to use from OnConsistPassed. Used to indicate SPADs,
     * AWS, TPWS, etc.
     * @specialCases SIGMSG_CUSTOM - While the other message types are handled
     * directly by the app, custom messages are passed on to the engine script
     * using the script method OnCustomSignalMessage passing the argument to the
     * engine script.
     */
    SendConsistMessage(message: ConsistMessage, argument: string) {
        Call(this.fn("SendConsistMessage"), message, argument);
    }

    /**
     * Get the signal state of the next/previous signal up/down the line.
     * @param direction The direction from the link. 1 = forwards,
     * -1 = backwards
     * @param link The direction of the signal link 0 to look for
     * @param index The index of the link to start the search from
     * @returns The state of the next signal along the line. Where no signal is
     * found "Go" is returned
     */
    GetNextSignalState(direction: SignalDirection, link: SignalDirection = SignalDirection.Forward, index: number = 0) {
        const [r] = Call(this.fn("GetNextSignalState"), "", direction, link, index);
        return r as BasicSignalState;
    }

    /**
     * Sets the 2D map displayed state of the signal.
     * @param state The state to set from (go, warning, stop)
     */
    Set2DMapSignalState(state: BasicSignalState) {
        Call(this.fn("Set2DMapSignalState"), state);
    }

    /**
     * Get the index of the link currently connected by the track network to the
     * link. If no link is connected then -1 is returned. Only finds links owned
     * by the same signal
     * @param index The link to start at when looking for the next connected
     * link. Usually 0.
     * @returns The index of the next link within the same signal connected via
     * the track network, if a converging junction set against the direction of
     * the start link is found or the end of track then -1 is returned.
     * @usage This is used as a method for testing which path ahead is set,
     * usually in response to a junction change message or when initialising.
     * @specialCases For slips and crossings (where the junction has two
     * simultaneous legal paths) the dispatcher holds an internal state for the
     * junction and as such a signal will get -1 as with a converging junction.
     * In Freeroam and for slips set to the player's path, the state is always
     * set for the player's route.
     */
    GetConnectedLink(index: number = 0): JunctionAgainstOrEndOfTrack | number {
        const [r] = Call(this.fn("GetConnectedLink"), "", SignalDirection.Forward, index);
        return r as number;
    }

    /**
     * Get the number of links in the signal. Blueprint::NumberOfTrackLinks
     * @returns The number of links the signal has in the range of 1 to 10
     * @usage To find the number of links in the signal
     */
    GetLinkCount() {
        const [r] = Call(this.fn("GetLinkCount"));
        return r as number;
    }

    /**
     * Get the speed in metres per second of the consist currently passing the
     * signal link
     * @returns The speed in metres per second
     * @usage Only safe to use from OnConsistPassed. Typically used for TPWS
     * like systems
     */
    GetConsistSpeed() {
        const [r] = Call(this.fn("GetConsistSpeed"));
        return r as number;
    }

    /**
     * Get the track speed limit at the link
     * @param index The index of the signal link
     * @returns The speed in metres per second
     * @usage Used to test for speeding conditions in TPWS like systems
     */
    GetTrackSpeedLimit(index: number) {
        const [r] = Call(this.fn("GetTrackSpeedLimit"), index);
        return r as number;
    }

    /**
     * Get the class of the consist currently passing the signal link
     * @returns The class of the consist.
     * @usage Only safe to use from OnConsistPassed. Typically used for TPWS
     * like systems
     */
    GetConsistType() {
        const [r] = Call(this.fn("GetConsistType"));
        return r as TrainType;
    }

    /**
     * Get the state of the signal link's "approach control" checkbox.
     * @param index The index of the link to check.
     * @returns True if the checkbox is checked.
     * @see https://forums.dovetailgames.com/threads/missing-signaling-functions-in-developer-docs.16740/
     */
    GetLinkApproachControl(index: number) {
        const [r] = Call(this.fn("GetLinkApproachControl"), index);
        return r === 1;
    }

    /**
     * Get the state of the signal link's "limited aspect" checkbox.
     * @param index The index of the link to check.
     * @returns True if the checkbox is checked.
     * @see https://forums.dovetailgames.com/threads/missing-signaling-functions-in-developer-docs.16740/
     */
    GetLinkLimitedToYellow(index: number) {
        const [r] = Call(this.fn("GetLinkLimitedToYellow"), index);
        return r === 1;
    }

    /**
     * Get the contents of the signal link's "name of route" field.
     * @param index The index of the link to check.
     * @returns The ASCII code of the first character of the field.
     * @see https://forums.dovetailgames.com/threads/missing-signaling-functions-in-developer-docs.16740/
     */
    GetLinkFeatherChar(index: number) {
        const [r] = Call(this.fn("GetLinkFeatherChar"), index);
        return r as number;
    }

    /**
     * Get the contents of the signal link's "speed of route" field.
     * @param index The index of the link to check.
     * @returns The number entered into the field.
     * @see https://forums.dovetailgames.com/threads/missing-signaling-functions-in-developer-docs.16740/
     */
    GetLinkSpeedLimit(index: number) {
        const [r] = Call(this.fn("GetLinkSpeedLimit"), index);
        return r as number;
    }

    /**
     * Get the contents of the signal's ID field.
     * @returns The string entered into the field.
     * @see https://forums.dovetailgames.com/threads/missing-signaling-functions-in-developer-docs.16740/
     */
    GetId() {
        const [r] = Call(this.fn("GetId"));
        return r as string;
    }
}
