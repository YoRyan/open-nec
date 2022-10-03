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
 * A cab signal aspect for Amtrak and NJ Transit trains.
 */
export enum AmtrakAspect {
    Restricting = 0,
    Approach = 1,
    ApproachMedium30 = 2,
    ApproachMedium45 = 3,
    CabSpeed60 = 4,
    CabSpeed80 = 5,
    Clear100 = 6,
    Clear125 = 7,
    Clear150 = 8,
}

/**
 * A cab signal aspect for Long Island Rail Road trains.
 */
export enum LirrAspect {
    Speed15 = 0,
    Speed30 = 1,
    Speed40 = 2,
    Speed60 = 3,
    Speed70 = 4,
    Speed80 = 5,
}

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
 * Convert a pulse code to a cab signal aspect for Amtrak and NJ Transit
 * equipment.
 * @param pulseCode The pulse code.
 * @returns The cab signal aspect.
 */
export function toAmtrakAspect(pulseCode: PulseCode) {
    return {
        [PulseCode.C_0_0]: AmtrakAspect.Restricting,
        [PulseCode.C_75_0]: AmtrakAspect.Approach,
        [PulseCode.C_75_75]: AmtrakAspect.ApproachMedium30,
        [PulseCode.C_120_0]: AmtrakAspect.ApproachMedium45,
        [PulseCode.C_120_120]: AmtrakAspect.CabSpeed80,
        [PulseCode.C_180_0]: AmtrakAspect.Clear125,
        [PulseCode.C_180_180]: AmtrakAspect.Clear150,
        [PulseCode.C_270_0]: AmtrakAspect.CabSpeed60,
        [PulseCode.C_270_270]: AmtrakAspect.Clear100,
        [PulseCode.C_420_0]: AmtrakAspect.Restricting,
    }[pulseCode];
}

/**
 * Convert a pulse code to a cab signal aspect for Long Island Rail Road
 * equipment.
 * @param pulseCode The pulse code.
 * @returns The cab signal aspect.
 */
export function toLirrAspect(pulseCode: PulseCode) {
    return {
        [PulseCode.C_0_0]: LirrAspect.Speed15,
        [PulseCode.C_75_0]: LirrAspect.Speed30,
        [PulseCode.C_75_75]: LirrAspect.Speed30,
        [PulseCode.C_120_0]: LirrAspect.Speed40,
        [PulseCode.C_120_120]: LirrAspect.Speed40,
        [PulseCode.C_180_0]: LirrAspect.Speed80,
        [PulseCode.C_180_180]: LirrAspect.Speed80,
        [PulseCode.C_270_0]: LirrAspect.Speed70,
        [PulseCode.C_270_270]: LirrAspect.Speed70,
        [PulseCode.C_420_0]: LirrAspect.Speed60,
    }[pulseCode];
}
