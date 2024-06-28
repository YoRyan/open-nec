/**
 * Constants, enums, and lookup tables for cab signalling on the Northeast
 * Corridor.
 */

import * as c from "lib/constants";
import * as frp from "lib/frp";
import { Cheat, FrpEngine } from "lib/frp-engine";
import { nullStream, rejectUndefined } from "lib/frp-extra";

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
 * @template A The cab signal aspects enum.
 */
export interface AtcSystem<A> {
    /**
     * The initial aspect to display before any signal message has been
     * received.
     */
    restricting: A;

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
    restricting: AmtrakAspect.Restricting,
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
 * A cab signal aspect for trains that use basic 4-aspect cab signaling.
 */
export enum FourAspect {
    Restricting,
    Approach,
    ApproachLimited,
    Clear,
}

/**
 * ATC for trains that can only communicate four aspects. (For newer,
 * PRR-incompatible codes, we present Approach Limited rather than Restricting
 * as would occur in real life.)
 */
export const fourAspectAtc: AtcSystem<FourAspect> = {
    restricting: FourAspect.Restricting,
    fromPulseCode(pc: PulseCode) {
        return {
            [PulseCode.C_0_0]: FourAspect.Restricting,
            [PulseCode.C_75_0]: FourAspect.Approach,
            [PulseCode.C_75_75]: FourAspect.Approach,
            [PulseCode.C_120_0]: FourAspect.ApproachLimited,
            [PulseCode.C_120_120]: FourAspect.ApproachLimited,
            [PulseCode.C_180_0]: FourAspect.Clear,
            [PulseCode.C_180_180]: FourAspect.Clear,
            [PulseCode.C_270_0]: FourAspect.ApproachLimited,
            [PulseCode.C_270_270]: FourAspect.ApproachLimited,
            [PulseCode.C_420_0]: FourAspect.ApproachLimited,
        }[pc];
    },
    getSuperiority(aspect: FourAspect) {
        return {
            [FourAspect.Restricting]: 0,
            [FourAspect.Approach]: 1,
            [FourAspect.ApproachLimited]: 2,
            [FourAspect.Clear]: 3,
        }[aspect];
    },
    getSpeedMps(aspect: FourAspect) {
        return (
            {
                [FourAspect.Restricting]: 20,
                [FourAspect.Approach]: 30,
                [FourAspect.ApproachLimited]: 45,
                [FourAspect.Clear]: 125,
            }[aspect] * c.mph.toMps
        );
    },
    restartFlash(_from: FourAspect, _to: FourAspect) {
        return false;
    },
};

/**
 * ATC for Metro-North trains. (We assume we can only represent 4 aspects.)
 */
export const metroNorthAtc: AtcSystem<FourAspect> = {
    restricting: FourAspect.Restricting,
    fromPulseCode(pc: PulseCode) {
        return {
            [PulseCode.C_0_0]: FourAspect.Restricting,
            [PulseCode.C_75_0]: FourAspect.Approach,
            [PulseCode.C_75_75]: FourAspect.Approach,
            [PulseCode.C_120_0]: FourAspect.ApproachLimited,
            [PulseCode.C_120_120]: FourAspect.ApproachLimited,
            [PulseCode.C_180_0]: FourAspect.Clear,
            [PulseCode.C_180_180]: FourAspect.Clear,
            [PulseCode.C_270_0]: FourAspect.ApproachLimited,
            [PulseCode.C_270_270]: FourAspect.ApproachLimited,
            [PulseCode.C_420_0]: FourAspect.Restricting,
        }[pc];
    },
    getSuperiority(aspect: FourAspect) {
        return {
            [FourAspect.Restricting]: 0,
            [FourAspect.Approach]: 1,
            [FourAspect.ApproachLimited]: 2,
            [FourAspect.Clear]: 3,
        }[aspect];
    },
    getSpeedMps(aspect: FourAspect) {
        return (
            {
                [FourAspect.Restricting]: 15,
                [FourAspect.Approach]: 30,
                [FourAspect.ApproachLimited]: 45,
                [FourAspect.Clear]: 80,
            }[aspect] * c.mph.toMps
        );
    },
    restartFlash(_from: FourAspect, _to: FourAspect) {
        return false;
    },
};

/**
 * A cab signal aspect for NJ Transit trains. (We assume we cannot represent
 * Clear 100.)
 */
export enum NjTransitAspect {
    Restricting,
    Approach,
    ApproachMedium,
    ApproachLimited,
    CabSpeed60,
    CabSpeed80,
    Clear,
}

/**
 * ATC for NJ Transit trains.
 */
export const njTransitAtc: AtcSystem<NjTransitAspect> = {
    restricting: NjTransitAspect.Restricting,
    fromPulseCode(pc: PulseCode) {
        return {
            [PulseCode.C_0_0]: NjTransitAspect.Restricting,
            [PulseCode.C_75_0]: NjTransitAspect.Approach,
            [PulseCode.C_75_75]: NjTransitAspect.ApproachMedium,
            [PulseCode.C_120_0]: NjTransitAspect.ApproachLimited,
            [PulseCode.C_120_120]: NjTransitAspect.CabSpeed80,
            [PulseCode.C_180_0]: NjTransitAspect.Clear,
            [PulseCode.C_180_180]: NjTransitAspect.Clear,
            [PulseCode.C_270_0]: NjTransitAspect.CabSpeed60,
            [PulseCode.C_270_270]: NjTransitAspect.CabSpeed80, // Improvising for the Clear 100 aspect.
            [PulseCode.C_420_0]: NjTransitAspect.Restricting,
        }[pc];
    },
    getSuperiority(aspect: NjTransitAspect) {
        return {
            [NjTransitAspect.Restricting]: 0,
            [NjTransitAspect.Approach]: 1,
            [NjTransitAspect.ApproachMedium]: 2,
            [NjTransitAspect.ApproachLimited]: 3,
            [NjTransitAspect.CabSpeed60]: 4,
            [NjTransitAspect.CabSpeed80]: 5,
            [NjTransitAspect.Clear]: 6,
        }[aspect];
    },
    getSpeedMps(aspect: NjTransitAspect) {
        return (
            {
                [NjTransitAspect.Restricting]: 20,
                [NjTransitAspect.Approach]: 30,
                [NjTransitAspect.ApproachMedium]: 30,
                [NjTransitAspect.ApproachLimited]: 45,
                [NjTransitAspect.CabSpeed60]: 60,
                [NjTransitAspect.CabSpeed80]: 80,
                [NjTransitAspect.Clear]: 125,
            }[aspect] * c.mph.toMps
        );
    },
    restartFlash(_from: NjTransitAspect, _to: NjTransitAspect) {
        return false;
    },
};

/**
 * Attempt to convert a signal message to a pulse code.
 * @param signalMessage The custom signal message.
 * @returns The pulse code, if one matches.
 */
export function toPulseCode(signalMessage: string) {
    // Signals scripted by Brandon Phelan.
    {
        const [, , sig, speed] = string.find(signalMessage, "^sig(%d)speed(%d+)$");
        switch (sig) {
            case "1":
                switch (speed) {
                    case "150":
                        return PulseCode.C_180_180;
                    case "100":
                        return PulseCode.C_270_270;
                    default:
                        return PulseCode.C_180_0;
                }
            case "2":
                return PulseCode.C_120_120;
            case "3":
                return PulseCode.C_270_0;
            case "4":
                return PulseCode.C_120_0;
            case "5":
                return PulseCode.C_75_75;
            case "6":
                return PulseCode.C_75_0;
            case "7":
                switch (speed) {
                    case "60":
                        return PulseCode.C_420_0;
                    default:
                        return PulseCode.C_0_0;
                }
        }

        const [, , stop] = string.find(signalMessage, "^sig7stop(%d+)$");
        if (stop !== undefined) {
            return PulseCode.C_0_0;
        }
    }

    // Signals scripted by DTG for Amtrak and NJ Transit DLC's.
    {
        const [, , sig] = string.find(signalMessage, "^sig(%d+)");
        switch (sig) {
            case "1":
                return PulseCode.C_180_0;
            case "2":
                return PulseCode.C_120_120;
            case "3":
                return PulseCode.C_270_0;
            case "4":
                return PulseCode.C_120_0;
            case "5":
                return PulseCode.C_75_75;
            case "6":
                return PulseCode.C_75_0;
            case "7":
                return PulseCode.C_0_0;
        }
    }

    // Signals scripted by DTG for Metro-North DLC's.
    {
        const [, , code] = string.find(signalMessage, "^[MN](%d%d)");
        switch (code) {
            case "10":
                return PulseCode.C_180_0;
            case "11":
                return PulseCode.C_120_0;
            case "12":
                return PulseCode.C_75_0;
            case "13":
            case "14":
            case "15":
                return PulseCode.C_0_0;
        }
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
    {
        const [, , sig, speed] = string.find(signalMessage, "^sig(%d)speed(%d+)$");
        if (sig !== undefined) {
            return false;
        }

        const [, , stop] = string.find(signalMessage, "^sig7stop(%d+)$");
        if (stop !== undefined) {
            return (tonumber(stop as string) ?? 0) * c.ft.toM;
        }
    }

    // Signals scripted by DTG for Amtrak and NJ Transit DLC's.
    {
        const [, , sig] = string.find(signalMessage, "^sig(%d+)");
        if (sig !== undefined) {
            return false;
        }
    }

    // Signals scripted by DTG for Metro-North DLC's.
    {
        const [, , code] = string.find(signalMessage, "^[MN](%d%d)");
        if (code !== undefined) {
            return false;
        }
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
    {
        const [, , sig] = string.find(signalMessage, "^sig(%d)speed(%d+)$");
        if (sig !== undefined) {
            return false;
        }

        const [, , stop] = string.find(signalMessage, "^sig7stop(%d+)$");
        if (stop !== undefined) {
            return false;
        }
    }

    // Signals scripted by DTG for Amtrak and NJ Transit DLC's.
    {
        const [, , sig] = string.find(signalMessage, "^sig(%d+)");
        if (sig !== undefined) {
            return false;
        }
    }

    // Signals scripted by DTG for Metro-North DLC's.
    {
        const [, , code] = string.find(signalMessage, "^[MN](%d%d)");
        if (code !== undefined) {
            return true;
        }
    }

    return undefined;
}

/**
 * Read cab signal aspects from custom signal messages, from the rest of the
 * consist, and from a save state.
 * @template A The set of signal aspects to use for the ATC system.
 * @param atc The description of the ATC system.
 * @param e The player's engine.
 * @param pulseCodeControlValue The name of the control value to use to persist
 * the cab signal pulse code across the consist and between save states.
 * @returns The new stream.
 */
export function createCabSignalBehavior<A>(
    atc: AtcSystem<A>,
    e: FrpEngine,
    pulseCodeControlValue?: string
): frp.Behavior<A> {
    const cheatPulseCode$ = frp.compose(
        e.createCheatsStream(),
        frp.map(cheat => {
            switch (cheat) {
                case Cheat.PulseCode_0_0:
                    return PulseCode.C_0_0;
                case Cheat.PulseCode_75_0:
                    return PulseCode.C_75_0;
                case Cheat.PulseCode_75_75:
                    return PulseCode.C_75_75;
                case Cheat.PulseCode_120_0:
                    return PulseCode.C_120_0;
                case Cheat.PulseCode_120_120:
                    return PulseCode.C_120_120;
                case Cheat.PulseCode_180_0:
                    return PulseCode.C_180_0;
                case Cheat.PulseCode_180_180:
                    return PulseCode.C_180_180;
                case Cheat.PulseCode_270_0:
                    return PulseCode.C_270_0;
                case Cheat.PulseCode_270_270:
                    return PulseCode.C_270_270;
                case Cheat.PulseCode_420_0:
                    return PulseCode.C_420_0;
                default:
                    return undefined;
            }
        })
    );
    const newPulseCode$ = frp.compose(
        e.createOnSignalMessageStream(),
        frp.map(toPulseCode),
        frp.merge(cheatPulseCode$),
        rejectUndefined()
    );

    let currentPulseCode: frp.Behavior<PulseCode>;
    if (pulseCodeControlValue !== undefined) {
        newPulseCode$(pc => {
            e.rv.SetControlValue(pulseCodeControlValue, pulseCodeToSaveValue(pc));
        });
        currentPulseCode = frp.liftN(
            v => pulseCodeFromResumeValue(v),
            () => e.rv.GetControlValue(pulseCodeControlValue) as number
        );
    } else {
        currentPulseCode = frp.stepper(newPulseCode$, PulseCode.C_0_0);
    }
    return frp.liftN(pc => atc.fromPulseCode(pc), currentPulseCode);
}

/**
 * Converts a pulse code into a numeric value suitable for saving into a
 * control value.
 * @param pc The pulse code.
 * @returns The numeric value, between 0 an 1.
 */
function pulseCodeToSaveValue(pc: PulseCode) {
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
function pulseCodeFromResumeValue(cv: number) {
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
