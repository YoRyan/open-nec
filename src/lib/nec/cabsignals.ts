/** @noSelfInFile */
/**
 * Constants, enums, and lookup tables for cab signalling on the Northeast
 * Corridor.
 */

import * as c from "lib/constants";

export const alertMarginMps = 3 * c.mph.toMps;
export const penaltyMarginMps = 6 * c.mph.toMps;
export const alertCountdownS = 6;

/**
 * A pulse code frequency combination in use on the Northeast Corridor.
 */
export enum PulseCode {
    C_0_0,
    C_75_0,
    C_75_75,
    C_120_0,
    C_120_120,
    C_180_0,
    C_180_180,
    C_270_0,
    C_270_270,
    C_420_0,
}

/**
 * Defines the behavior for an ATC system.
 * @template A The enum that represents the signal aspects used by the system.
 */
export interface AtcSystem<A> {
    /**
     * The initial aspect to display before any signal message has been
     * received.
     */
    initialAspect: A;

    /**
     * Maps a pulse code to a signal aspect.
     * @param pc The pulse code.
     */
    fromPulseCode(this: void, pc: PulseCode): A;

    /**
     * Orders signal aspects, informing ATC of the relationship (superior or
     * inferior to) between a pair of aspects.
     * @param aspect The cab signal aspect.
     */
    getSuperiority(this: void, aspect: A): number;

    /**
     * Maps an aspect to a speed limit.
     * @param aspect The cab signal aspect.
     */
    getSpeedMps(this: void, aspect: A): number;

    /**
     * Returns true if a transition between two cab signal aspects should
     * restart the flash cycle.
     * @param from The aspect being transitioned from.
     * @param to The aspect being transitioned to.
     */
    restartFlash(this: void, from: A, to: A): boolean;
}

/**
 * A cab signal aspect for Amtrak trains.
 */
export enum AmtrakAspect {
    Restricting,
    Approach,
    ApproachMedium,
    ApproachLimited,
    CabSpeed60,
    CabSpeed80,
    Clear100,
    Clear125,
    Clear150,
}

/**
 * The Amtrak ATC system.
 */
export const amtrakAtc: AtcSystem<AmtrakAspect> = {
    initialAspect: AmtrakAspect.Restricting,
    fromPulseCode(pc: PulseCode) {
        return {
            [PulseCode.C_0_0]: AmtrakAspect.Restricting,
            [PulseCode.C_75_0]: AmtrakAspect.Approach,
            [PulseCode.C_75_75]: AmtrakAspect.ApproachMedium,
            [PulseCode.C_120_0]: AmtrakAspect.ApproachLimited,
            [PulseCode.C_120_120]: AmtrakAspect.CabSpeed80,
            [PulseCode.C_180_0]: AmtrakAspect.Clear125,
            [PulseCode.C_180_180]: AmtrakAspect.Clear150,
            [PulseCode.C_270_0]: AmtrakAspect.CabSpeed60,
            [PulseCode.C_270_270]: AmtrakAspect.Clear100,
            [PulseCode.C_420_0]: AmtrakAspect.Restricting,
        }[pc];
    },
    getSuperiority(aspect: AmtrakAspect) {
        return {
            [AmtrakAspect.Restricting]: 0,
            [AmtrakAspect.Approach]: 1,
            [AmtrakAspect.ApproachMedium]: 2,
            [AmtrakAspect.ApproachLimited]: 3,
            [AmtrakAspect.CabSpeed60]: 4,
            [AmtrakAspect.CabSpeed80]: 5,
            [AmtrakAspect.Clear100]: 6,
            [AmtrakAspect.Clear125]: 7,
            [AmtrakAspect.Clear150]: 8,
        }[aspect];
    },
    getSpeedMps(aspect: AmtrakAspect) {
        return (
            {
                [AmtrakAspect.Restricting]: 20,
                [AmtrakAspect.Approach]: 30,
                [AmtrakAspect.ApproachMedium]: 30,
                [AmtrakAspect.ApproachLimited]: 45,
                [AmtrakAspect.CabSpeed60]: 60,
                [AmtrakAspect.CabSpeed80]: 80,
                [AmtrakAspect.Clear100]: 100,
                [AmtrakAspect.Clear125]: 125,
                [AmtrakAspect.Clear150]: 150,
            }[aspect] * c.mph.toMps
        );
    },
    restartFlash(from: AmtrakAspect, to: AmtrakAspect) {
        const isCabSignal = (aspect: AmtrakAspect) =>
            aspect === AmtrakAspect.CabSpeed60 || aspect === AmtrakAspect.CabSpeed80;
        return to === AmtrakAspect.ApproachLimited || (!isCabSignal(from) && isCabSignal(to));
    },
};

/**
 * Attempt to convert a signal message to a pulse code.
 * @param signalMessage The custom signal message.
 * @returns The pulse code, if one matches.
 */
export function toPulseCode(signalMessage: string) {
    // Signals scripted by Brandon Phelan.
    const [, , sig, speed] = string.find(signalMessage, "^sig(%d)speed(%d+)$");
    if (sig === "1" && speed == "150") {
        return PulseCode.C_180_180;
    } else if (sig === "1" && speed == "100") {
        return PulseCode.C_270_270;
    } else if (sig === "1") {
        return PulseCode.C_180_0;
    } else if (sig === "2") {
        return PulseCode.C_120_120;
    } else if (sig === "3") {
        return PulseCode.C_270_0;
    } else if (sig === "4") {
        return PulseCode.C_120_0;
    } else if (sig === "5") {
        return PulseCode.C_75_75;
    } else if (sig === "6") {
        return PulseCode.C_75_0;
    } else if (sig === "7" && speed === "60") {
        return PulseCode.C_420_0;
    } else if (sig === "7") {
        return PulseCode.C_0_0;
    }
    const [, , stop] = string.find(signalMessage, "^sig7stop(%d+)$");
    if (stop !== undefined) {
        return PulseCode.C_0_0;
    }

    // Signals scripted by DTG for Amtrak and NJ Transit DLC's.
    const [, , sig2] = string.find(signalMessage, "^sig(%d+)");
    if (sig2 === "1") {
        return PulseCode.C_180_0;
    } else if (sig2 === "2") {
        return PulseCode.C_120_120;
    } else if (sig2 === "3") {
        return PulseCode.C_270_0;
    } else if (sig2 === "4") {
        return PulseCode.C_120_0;
    } else if (sig2 === "5") {
        return PulseCode.C_75_75;
    } else if (sig2 === "6") {
        return PulseCode.C_75_0;
    } else if (sig2 === "7") {
        return PulseCode.C_0_0;
    }

    // Signals scripted by DTG for Metro-North DLC's.
    const [, , code] = string.find(signalMessage, "^[MN](%d%d)");
    if (code === "10") {
        return PulseCode.C_180_0;
    } else if (code === "11") {
        return PulseCode.C_120_0;
    } else if (code === "12") {
        return PulseCode.C_75_0;
    } else if (code === "13" || code === "14") {
        return PulseCode.C_0_0;
    } else if (code === "15") {
        return PulseCode.C_0_0;
    }

    return undefined;
}

/**
 * Attempt to extract information about positive stop enforcement from a signal
 * message.
 * @param signalMessage The custom signal message.
 * @returns The positive stop distance if a positive stop is imminent, or false
 * if there is definitively not an upcoming positive stop, or undefined if this
 * message provides no information.
 */
export function toPositiveStopDistanceM(signalMessage: string): number | false | undefined {
    // Signals scripted by Brandon Phelan.
    const [, , sig, speed] = string.find(signalMessage, "^sig(%d)speed(%d+)$");
    if (sig !== undefined) {
        return false;
    }
    const [, , stop] = string.find(signalMessage, "^sig7stop(%d+)$");
    if (stop !== undefined) {
        return parseInt(stop as string) * c.ft.toM;
    }

    // Signals scripted by DTG for Amtrak and NJ Transit DLC's.
    const [, , sig2] = string.find(signalMessage, "^sig(%d+)");
    if (sig2 !== undefined) {
        return false;
    }

    // Signals scripted by DTG for Metro-North DLC's.
    const [, , code] = string.find(signalMessage, "^[MN](%d%d)");
    if (code !== undefined) {
        return false;
    }

    return undefined;
}

/**
 * Attempt to determine whether or not the train is in Metro-North territory
 * from a signal message.
 * @param signalMessage The custom signal message.
 * @returns A boolean that indicates we are in Metro-North territory, or
 * undefined if this message provides no information.
 */
export function isMnrrAspect(signalMessage: string): boolean | undefined {
    // Signals scripted by Brandon Phelan.
    const [, , sig] = string.find(signalMessage, "^sig(%d)speed(%d+)$");
    if (sig !== undefined) {
        return false;
    }
    const [, , stop] = string.find(signalMessage, "^sig7stop(%d+)$");
    if (stop !== undefined) {
        return false;
    }

    // Signals scripted by DTG for Amtrak and NJ Transit DLC's.
    const [, , sig2] = string.find(signalMessage, "^sig(%d+)");
    if (sig2 !== undefined) {
        return false;
    }

    // Signals scripted by DTG for Metro-North DLC's.
    const [, , code] = string.find(signalMessage, "^[MN](%d%d)");
    if (code !== undefined) {
        return true;
    }

    return undefined;
}

/**
 * Converts a pulse code into a numeric value suitable for saving into a
 * control value.
 * @param pc The pulse code.
 * @returns The numeric value, between 0 an 1.
 */
export function pulseCodeToSaveValue(pc: PulseCode) {
    return {
        [PulseCode.C_0_0]: 0.1,
        [PulseCode.C_75_0]: 0.2,
        [PulseCode.C_75_75]: 0.3,
        [PulseCode.C_120_0]: 0.4,
        [PulseCode.C_120_120]: 0.5,
        [PulseCode.C_180_0]: 0.6,
        [PulseCode.C_180_180]: 0.7,
        [PulseCode.C_270_0]: 0.8,
        [PulseCode.C_270_270]: 0.9,
        [PulseCode.C_420_0]: 1,
    }[pc];
}

/**
 * Converts a saved control value into a pulse code.
 * @param cv The value of the control value.
 * @returns The pulse code.
 */
export function pulseCodeFromResumeValue(cv: number) {
    if (cv < 0.15) {
        return PulseCode.C_0_0;
    } else if (cv < 0.25) {
        return PulseCode.C_75_0;
    } else if (cv < 0.35) {
        return PulseCode.C_75_75;
    } else if (cv < 0.45) {
        return PulseCode.C_120_0;
    } else if (cv < 0.55) {
        return PulseCode.C_120_120;
    } else if (cv < 0.65) {
        return PulseCode.C_180_0;
    } else if (cv < 0.75) {
        return PulseCode.C_180_180;
    } else if (cv < 0.85) {
        return PulseCode.C_270_0;
    } else if (cv < 0.95) {
        return PulseCode.C_270_270;
    } else {
        return PulseCode.C_420_0;
    }
}
