/** @noSelfInFile */

import * as rw from "../lib/railworks";

export {};

declare global {
    /**
     * Log a message to LogMate under the Script Manager category. Arguments
     * will be concatenated without a separator, and nil values will be
     * represented with `<nil>`.
     * @param args The arguments to print.
     */
    export function Print(...args: (string | number | boolean | undefined)[]): void;

    /**
     * Access a function made available to an engine or signalling script.
     * @param fn The name of the function.
     * @param args The arguments to pass to the function.
     * @returns The result of the call.
     */
    export function Call(
        fn: string,
        ...args: (string | number | boolean)[]
    ): LuaMultiReturn<(string | number | boolean | undefined)[]>;

    /**
     * Access a function made available to a scenario script.
     * @param fn The name of the function.
     * @param args The arguments to pass to the function.
     * @returns The result of the call.
     */
    export function SysCall(
        fn: string,
        ...args: (string | number | boolean)[]
    ): LuaMultiReturn<(string | number | boolean | undefined)[]>;

    /**
     * True if the game is running using the RailWorks64.exe executable.
     * @returns Whether the game is running in 64-bit mode.
     */
    export function Is64Bit(): boolean;

    const mEntityAddress: number;

    const mScriptAddress: number;

    /**
     * A function that is called after the scenario is initialized, but before
     * the route is loaded.
     */
    var Initialise: () => void;

    /**
     * A function that is called every frame if BeginUpdate() has been called.
     * @param interval The time, in seconds, since the last update.
     */
    var Update: (interval: number) => void;

    /**
     * A function that is called when the rail vehicle receives a message that
     * has been sent by SendConsistMessage().
     * @param id The unique identifier of the message.
     * @param content The content of the message.
     * @param direction The direction the message was sent, relative to the
     * sender.
     */
    var OnConsistMessage: (id: number, content: string, direction: rw.ConsistDirection) => void;

    /**
     * A function that is called when the engine receives a new message from a
     * signal on the route.
     * @param message The message received from the signalling system.
     */
    var OnCustomSignalMessage: (message: string) => void;

    /**
     * A function that is called when the player enters a cab or passenger
     * camera view.
     * @param cabEnd The end of the vehicle that the player entered.
     * @param carriageCam The kind of camera view.
     */
    var OnCameraEnter: (cabEnd: rw.CameraEnterCabEnd, carriageCam: rw.CameraEnterView) => void;

    /**
     * A function that is called when the player changes camera views.
     */
    var OnCameraLeave: () => void;

    /**
     * Called by the game when a control is manipulated by some means other
     * than SetControlValue() method in lieu of actually changing the control
     * value.
     */
    var OnControlValueChange: (name: string, index: number, value: number) => void;

    /**
     * This is the event handler function it handles any event calls from the
     * scenario system.
     * @param event The name of the event as defined in the instruction, trigger
     * or TriggerDeferredEvent call.
     * @returns TRUE(1) if the event is handled or FALSE(0) if the event is
     * unknown.
     */
    var OnEvent: (event: string) => 1 | 0;

    /**
     * This is the condition checker function, it is used to test whether the
     * player has met additional conditions for an instruction.
     * @param condition The name of the condition as defined in the instruction
     * or BeginConditonCheck call.
     * @returns One of CONDITION_NOT_YET_MET(0), CONDITION_SUCCEEDED(1) or
     * CONDITION_FAILED(2).
     */
    var TestCondition: (condition: string) => rw.ConditionStatus;
}
