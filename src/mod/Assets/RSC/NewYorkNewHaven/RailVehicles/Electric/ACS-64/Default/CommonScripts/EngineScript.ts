/**
 * Amtrak Siemens ACS-64
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine, PlayerLocation } from "lib/frp-engine";
import { fsm, mapBehavior, movingAverage, nullStream, rejectRepeats, rejectUndefined } from "lib/frp-extra";
import { SensedDirection } from "lib/frp-vehicle";
import * as m from "lib/math";
import * as adu from "lib/nec/amtrak-adu";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

enum DeskConsoleLight {
    Off,
    DeskOnly,
    DeskAndConsole,
    ConsoleOnly,
}

enum DitchLight {
    Off,
    On,
    Flash,
}

const ditchLightFlashS = 0.5;
const ditchLightHornFlashS = 30;

type DitchLightAccum =
    | DitchLightState.Off
    | DitchLightState.On
    | [state: DitchLightState.SelectedFlashing | DitchLightState.HornOrBellFlashing, clockS: number];

enum DitchLightState {
    Off,
    On,
    SelectedFlashing,
    HornOrBellFlashing,
}

enum DitchLightEvent {
    HornOrBell,
    HornOrBellWithRestart,
    MovedHeadlight,
}

const nDisplaySamples = 30;
const displayRefreshS = 0.1;

const me = new FrpEngine(() => {
    const isCtslEnhancedPack = me.rv.ControlExists("TAPRBYL");

    // Electric power supply
    const electrification = ps.createElectrificationBehaviorWithLua(me, ps.Electrification.Overhead);
    const isPowerAvailable = () => ps.uniModeEngineHasPower(ps.EngineMode.Overhead, electrification);
    const sparkLights = [new rw.Light("Spark1"), new rw.Light("Spark2")];
    const frontPantoSpark$ = frp.compose(
        fx.createPantographSparkStream(me, electrification),
        frp.map(spark => spark && me.rv.GetControlValue("PantographControl") === 1),
        rejectRepeats()
    );
    const rearPantoSpark$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => false),
        rejectRepeats()
    );
    frontPantoSpark$(spark => {
        me.rv.SetControlValue("Spark", spark ? 1 : 0);

        const [light] = sparkLights;
        light.Activate(spark);
        me.rv.ActivateNode("PantoAsparkA", spark);
        me.rv.ActivateNode("PantoAsparkB", spark);
        me.rv.ActivateNode("PantoAsparkC", spark);
        me.rv.ActivateNode("PantoAsparkD", spark);
        me.rv.ActivateNode("PantoAsparkE", spark);
        me.rv.ActivateNode("PantoAsparkF", spark);
    });
    rearPantoSpark$(spark => {
        const [, light] = sparkLights;
        light.Activate(spark);
        me.rv.ActivateNode("PantoBsparkA", spark);
        me.rv.ActivateNode("PantoBsparkB", spark);
        me.rv.ActivateNode("PantoBsparkC", spark);
        me.rv.ActivateNode("PantoBsparkD", spark);
        me.rv.ActivateNode("PantoBsparkE", spark);
        me.rv.ActivateNode("PantoBsparkF", spark);
    });

    // Safety systems cut in/out
    const atcCutIn = () => (me.rv.GetControlValue("ATCCutIn") as number) > 0.5;
    const acsesCutIn = () => (me.rv.GetControlValue("ACSESCutIn") as number) > 0.5;
    const updateCutIns$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN((atcCutIn, acsesCutIn): [boolean, boolean] => [atcCutIn, acsesCutIn], atcCutIn, acsesCutIn)
        )
    );
    updateCutIns$(([atc, acses]) => {
        me.rv.SetControlValue("SigATCCutIn", atc ? 1 : 0);
        me.rv.SetControlValue("SigATCCutOut", atc ? 0 : 1);
        me.rv.SetControlValue("SigACSESCutIn", acses ? 1 : 0);
        me.rv.SetControlValue("SigACSESCutOut", acses ? 0 : 1);
    });
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("VirtualBrake") as number) > (isCtslEnhancedPack ? 0.4 : 0.66);
    const [aduState$, aduEvents$] = adu.create({
        e: me,
        acknowledge,
        suppression,
        atcCutIn,
        acsesCutIn,
        equipmentSpeedMps: 125 * c.mph.toMps,
        pulseCodeControlValue: "CabSignal",
    });
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(state => {
        me.rv.SetControlValue(
            "SigAspectTopGreen",
            state.aspect === adu.AduAspect.CabSpeed60 ||
                state.aspect === adu.AduAspect.CabSpeed80 ||
                state.aspect === adu.AduAspect.Clear100 ||
                state.aspect === adu.AduAspect.Clear125 ||
                state.aspect === adu.AduAspect.Clear150
                ? 1
                : 0
        );
        me.rv.SetControlValue(
            "SigAspectTopYellow",
            state.aspect === adu.AduAspect.Approach ||
                state.aspect === adu.AduAspect.ApproachMedium ||
                state.aspect === adu.AduAspect.ApproachLimited ||
                state.aspect === adu.AduAspect.ApproachLimitedOff
                ? 1
                : 0
        );
        me.rv.SetControlValue(
            "SigAspectTopRed",
            state.aspect === adu.AduAspect.Stop || state.aspect === adu.AduAspect.Restrict ? 1 : 0
        );
        me.rv.SetControlValue("SigAspectTopWhite", 0);
        me.rv.SetControlValue(
            "SigAspectBottomGreen",
            state.aspect === adu.AduAspect.ApproachMedium || state.aspect === adu.AduAspect.ApproachLimited ? 1 : 0
        );
        me.rv.SetControlValue("SigAspectBottomYellow", 0);
        me.rv.SetControlValue("SigAspectBottomWhite", state.aspect === adu.AduAspect.Restrict ? 1 : 0);

        me.rv.SetControlValue(
            "SigText",
            {
                [adu.AduAspect.Stop]: 12,
                [adu.AduAspect.Restrict]: 11,
                [adu.AduAspect.Approach]: 8,
                [adu.AduAspect.ApproachMedium]: 13,
                [adu.AduAspect.ApproachLimited]: 3,
                [adu.AduAspect.ApproachLimitedOff]: 3,
                [adu.AduAspect.CabSpeed60]: 2,
                [adu.AduAspect.CabSpeed60Off]: 2,
                [adu.AduAspect.CabSpeed80]: 2,
                [adu.AduAspect.CabSpeed80Off]: 2,
                [adu.AduAspect.Clear100]: 1,
                [adu.AduAspect.Clear125]: 1,
                [adu.AduAspect.Clear150]: 1,
            }[state.aspect]
        );

        if (state.isMnrrAspect) {
            me.rv.SetControlValue("SigS", state.aspect === adu.AduAspect.Stop ? 1 : 0);
            me.rv.SetControlValue("SigR", state.aspect === adu.AduAspect.Restrict ? 1 : 0);
            me.rv.SetControlValue("SigM", state.aspect === adu.AduAspect.Approach ? 1 : 0);
            me.rv.SetControlValue(
                "SigL",
                state.aspect === adu.AduAspect.ApproachLimited || state.aspect === adu.AduAspect.ApproachLimitedOff
                    ? 1
                    : 0
            );
            me.rv.SetControlValue(
                "Sig60",
                state.aspect === adu.AduAspect.CabSpeed60 || state.aspect === adu.AduAspect.CabSpeed60Off ? 1 : 0
            );
            me.rv.SetControlValue(
                "Sig80",
                state.aspect === adu.AduAspect.CabSpeed80 || state.aspect === adu.AduAspect.CabSpeed80Off ? 1 : 0
            );
            me.rv.SetControlValue("SigN", state.aspect === adu.AduAspect.Clear125 ? 1 : 0);
        } else {
            for (const cv of ["SigS", "SigR", "SigM", "SigL", "Sig60", "Sig80", "SigN"]) {
                me.rv.SetControlValue(cv, 0);
            }
        }

        me.rv.SetControlValue("SigModeATC", state.atcLamp ? 1 : 0);
        me.rv.SetControlValue("SigModeACSES", state.acsesLamp ? 1 : 0);

        if (state.masSpeedMph !== undefined) {
            const [[h, t, u]] = m.digits(state.masSpeedMph, 3);
            me.rv.SetControlValue("SpeedLimit_hundreds", h);
            me.rv.SetControlValue("SpeedLimit_tens", t);
            me.rv.SetControlValue("SpeedLimit_units", u);
        } else {
            me.rv.SetControlValue("SpeedLimit_hundreds", 0);
            me.rv.SetControlValue("SpeedLimit_tens", -1);
            me.rv.SetControlValue("SpeedLimit_units", -1);
        }

        if (state.timeToPenaltyS !== undefined) {
            const [[h, t, u]] = m.digits(state.timeToPenaltyS, 3);
            me.rv.SetControlValue("Penalty_hundreds", h);
            me.rv.SetControlValue("Penalty_tens", t);
            me.rv.SetControlValue("Penalty_units", u);
        } else {
            me.rv.SetControlValue("Penalty_hundreds", 0);
            me.rv.SetControlValue("Penalty_tens", -1);
            me.rv.SetControlValue("Penalty_units", -1);
        }
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterReset$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.filter(([name]) => name === "ThrottleAndBrake" || name === "VirtualBrake")
    );
    const alerter$ = frp.compose(
        ale.create({ e: me, acknowledge, acknowledgeStream: alerterReset$, cutIn: alerterCutIn }),
        frp.hub()
    );
    const alerterState = frp.stepper(alerter$, undefined);
    // Safety system sounds
    const isAlarm = frp.liftN(
        (aduState, alerterState) => (aduState?.atcAlarm || aduState?.acsesAlarm || alerterState?.alarm) ?? false,
        aduState,
        alerterState
    );
    const alarmOn$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(isAlarm));
    if (isCtslEnhancedPack) {
        // There's no need to modulate CTSL's improved sound.
        alarmOn$(on => {
            me.rv.SetControlValue("AWSWarnCount", on ? 1 : 0);
            me.rv.SetControlValue("SpeedReductionAlert", on ? 1 : 0);
        });
    } else {
        alarmOn$(on => {
            me.rv.SetControlValue("AWSWarnCount", on ? 1 : 0);
        });
        const alarmLoop$ = frp.compose(me.createPlayerWithKeyUpdateStream(), fx.loopSound(0.5, isAlarm));
        alarmLoop$(play => {
            me.rv.SetControlValue("SpeedReductionAlert", play ? 1 : 0);
        });
    }
    const upgradeEvents$ = frp.compose(
        aduEvents$,
        frp.filter(evt => evt === adu.AduEvent.Upgrade)
    );
    const upgradeSound$ = frp.compose(me.createPlayerWithKeyUpdateStream(), fx.triggerSound(1, upgradeEvents$));
    upgradeSound$(play => {
        me.rv.SetControlValue("SpeedIncreaseAlert", play ? 1 : 0);
    });

    // Throttle, dynamic brake, and air brake controls
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
    const airBrake = frp.liftN(
        (isPenaltyBrake, input, fullService) => {
            const cmd = isPenaltyBrake ? fullService : input;
            // DTG's nonlinear air brake algorithm
            if (cmd < 0.1) {
                return 0;
            } else if (cmd < 0.35) {
                return 0.07;
            } else if (cmd < 0.75) {
                return 0.07 + ((cmd - 0.35) / (0.6 - 0.35)) * 0.1;
            } else if (cmd < 0.85) {
                return 0.17;
            } else if (cmd < 1) {
                return 0.24;
            } else {
                return 1;
            }
        },
        isPenaltyBrake,
        () => me.rv.GetControlValue("VirtualBrake") as number,
        0.85
    );
    const airBrakeOutput$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(airBrake));
    airBrakeOutput$(brake => {
        me.rv.SetControlValue("TrainBrakeControl", brake);
    });
    // It's necessary to probe the minimum and maximum limits for Fan Railer's mod.
    const throttleRange = [
        me.rv.GetControlMinimum("ThrottleAndBrake") as number,
        me.rv.GetControlMaximum("ThrottleAndBrake") as number,
    ];
    // Scaled from -1 (full dynamic braking) to 1 (full power).
    const throttleAndDynBrakeInput = () => {
        const input = me.rv.GetControlValue("ThrottleAndBrake") as number;
        const [min, max] = throttleRange;
        return ((input - min) / (max - min)) * 2 - 1;
    };
    const throttleAndDynBrake = frp.liftN(
        (isPowerAvailable, isPenaltyBrake, airBrake, input) => {
            if (isPenaltyBrake) {
                return 0;
            } else if (!isPowerAvailable || airBrake > 0) {
                return Math.min(input, 0);
            } else {
                return input;
            }
        },
        isPowerAvailable,
        isPenaltyBrake,
        airBrake,
        throttleAndDynBrakeInput
    );
    const throttleAndDynBrakeOutput$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(pu => {
            const throttleAndBrake = frp.snapshot(throttleAndDynBrake);
            if (throttleAndBrake < 0) {
                // Cease dynamic braking below 2 mph.
                return throttleAndBrake * Math.min(Math.abs(pu.speedMps) / (2 * c.mph.toMps), 1);
            } else {
                return throttleAndBrake;
            }
        })
    );
    throttleAndDynBrakeOutput$(throttleAndBrake => {
        me.rv.SetControlValue("Regulator", throttleAndBrake);
        me.rv.SetControlValue("DynamicBrake", -throttleAndBrake);
    });

    // Driving screen
    const displayUpdate$ = frp.compose(me.createPlayerWithKeyUpdateStream(), frp.throttle(displayRefreshS));
    const tractiveEffortKlbs$ = frp.compose(
        displayUpdate$,
        frp.map(_ => (me.eng.GetTractiveEffort() * 71 * 71) / 80.5),
        movingAverage(nDisplaySamples)
    );
    tractiveEffortKlbs$(effortKlbs => {
        const [[t, u], guide] = m.digits(Math.round(effortKlbs), 2);
        me.rv.SetControlValue("effort_tens", t);
        me.rv.SetControlValue("effort_units", u);
        me.rv.SetControlValue("effort_guide", guide);
        me.rv.SetControlValue("AbsTractiveEffort", (effortKlbs * 365) / 80);
    });
    const accelerationMphMin$ = frp.compose(
        displayUpdate$,
        frp.map(_ => Math.abs(me.rv.GetAcceleration() * 134.2162)),
        movingAverage(nDisplaySamples),
        frp.throttle(displayRefreshS)
    );
    accelerationMphMin$(accelMphMin => {
        const [[h, t, u], guide] = m.digits(Math.round(accelMphMin), 3);
        me.rv.SetControlValue("accel_hundreds", h);
        me.rv.SetControlValue("accel_tens", t);
        me.rv.SetControlValue("accel_units", u);
        me.rv.SetControlValue("accel_guide", guide);
        me.rv.SetControlValue("AccelerationMPHPM", accelMphMin);
    });
    displayUpdate$(_ => {
        const speedoMph = me.rv.GetControlValue("SpeedometerMPH") as number;
        const [[h, t, u], guide] = m.digits(Math.round(speedoMph), 3);
        me.rv.SetControlValue("SpeedDigit_hundreds", h);
        me.rv.SetControlValue("SpeedDigit_tens", t);
        me.rv.SetControlValue("SpeedDigit_units", u);
        me.rv.SetControlValue("SpeedDigit_guide", guide);

        const isWheelSlip = (me.rv.GetControlValue("Wheelslip") as number) > 1;
        me.rv.SetControlValue("ScreenWheelslip", isWheelSlip ? 1 : 0);
        const isParkingBrake = (me.rv.GetControlValue("HandBrake") as number) > 0;
        me.rv.SetControlValue("ScreenParkingBrake", isParkingBrake ? 1 : 0);
        me.rv.SetControlValue("ScreenSuppression", frp.snapshot(suppression) ? 1 : 0);
    });
    alerter$(state => {
        me.rv.SetControlValue("ScreenAlerter", state.alarm ? 1 : 0);
    });

    // Player location for interior lights
    const playerLocation = me.createPlayerLocationBehavior();

    // Cab dome lights, front and rear
    const cabLightControl = () => (me.rv.GetControlValue("CabLight") as number) > 0.5;
    const allCabLights: [location: PlayerLocation, light: rw.Light][] = [
        // (Yes, these lights are reversed!)
        [PlayerLocation.InFrontCab, new rw.Light("RearCabLight")],
        [PlayerLocation.InRearCab, new rw.Light("FrontCabLight")],
    ];
    const cabLightNonPlayer$ = frp.compose(
        me.createAiUpdateStream(),
        frp.merge(me.createPlayerWithoutKeyUpdateStream()),
        frp.map(_ => false)
    );
    allCabLights.forEach(([location, light]) => {
        const setOnOff$ = frp.compose(
            me.createPlayerWithKeyUpdateStream(),
            frp.map(_ => (frp.snapshot(playerLocation) === location ? frp.snapshot(cabLightControl) : false)),
            frp.merge(cabLightNonPlayer$),
            rejectRepeats()
        );
        setOnOff$(on => {
            light.Activate(on);
        });
    });

    // Desk and console lights, front and rear
    const deskConsoleLightControl = () => {
        const cv = me.rv.GetControlValue("DeskConsoleLight") as number;
        if (cv > 2.5) {
            return DeskConsoleLight.ConsoleOnly;
        } else if (cv > 1.5) {
            return DeskConsoleLight.DeskAndConsole;
        } else if (cv > 0.5) {
            return DeskConsoleLight.DeskOnly;
        } else {
            return DeskConsoleLight.Off;
        }
    };
    const allDeskLights: [location: PlayerLocation, desk: rw.Light[], console: rw.Light[], secondman: rw.Light[]][] = [
        [
            PlayerLocation.InFrontCab,
            [new rw.Light("Front_ConsoleLight_01"), new rw.Light("Front_ConsoleLight_03")],
            [new rw.Light("Front_ConsoleLight_02")],
            [new rw.Light("Front_DeskLight_01")],
        ],
        [
            PlayerLocation.InRearCab,
            [new rw.Light("Rear_ConsoleLight_01"), new rw.Light("Rear_ConsoleLight_03")],
            [new rw.Light("Rear_ConsoleLight_02")],
            [new rw.Light("Rear_DeskLight_01")],
        ],
    ];
    const deskLightsNonPlayer$ = frp.compose(
        me.createAiUpdateStream(),
        frp.merge(me.createPlayerWithoutKeyUpdateStream()),
        frp.map(_ => DeskConsoleLight.Off)
    );
    allDeskLights.forEach(([location, desk, console, secondman]) => {
        const setLights$ = frp.compose(
            me.createPlayerWithKeyUpdateStream(),
            frp.map(_ =>
                frp.snapshot(playerLocation) === location ? frp.snapshot(deskConsoleLightControl) : DeskConsoleLight.Off
            ),
            frp.merge(deskLightsNonPlayer$),
            rejectRepeats()
        );
        setLights$(setting => {
            for (const light of desk) {
                light.Activate(setting === DeskConsoleLight.DeskOnly || setting === DeskConsoleLight.DeskAndConsole);
            }
            // Secondman's desk light has an independent switch IRL.
            for (const light of [...console, ...secondman]) {
                light.Activate(setting === DeskConsoleLight.DeskAndConsole || setting === DeskConsoleLight.ConsoleOnly);
            }
        });
    });

    // Horn rings the bell.
    const bellControl$ = frp.compose(
        me.createOnCvChangeStreamFor("Horn"),
        // The quill, for Fan Railer and CTSL Railfan's mods
        frp.merge(me.createOnCvChangeStreamFor("HornHB")),
        frp.filter(v => v === 1),
        me.mapAutoBellStream(),
        frp.hub()
    );
    bellControl$(v => {
        me.rv.SetControlValue("Bell", v);
    });

    // Horn sequencer for CTSL Railfan's enhanced pack
    let ctslDitchLightEvents$: frp.Stream<DitchLightEvent>;
    if (isCtslEnhancedPack) {
        const ctslHornSequenceS = 13;
        const ctslHornSequenceSpeedMph = 3;
        const ctslHornSequenceBellOnOff$ = frp.compose(
            me.createPlayerWithKeyUpdateStream(),
            frp.filter(_ => isCtslEnhancedPack),
            frp.fold((remainingS, pu) => {
                const keyPressed = (me.rv.GetControlValue("HornSequencer") as number) > 0.5;
                const speedOk = Math.abs(me.rv.GetControlValue("SpeedometerMPH") as number) >= ctslHornSequenceSpeedMph;
                return keyPressed && speedOk && remainingS <= 0 ? ctslHornSequenceS : Math.max(remainingS - pu.dt, 0);
            }, 0),
            fsm(0),
            frp.map(([from, to]) => {
                if (to > 0) {
                    // Force the bell on for the duration of the sequence.
                    return true;
                } else if (from > 0 && to <= 0) {
                    // Turn the bell off at the end of the sequence.
                    return false;
                } else {
                    return undefined;
                }
            }),
            rejectUndefined(),
            frp.hub()
        );
        ctslDitchLightEvents$ = frp.compose(
            ctslHornSequenceBellOnOff$,
            frp.map(_ => DitchLightEvent.HornOrBellWithRestart)
        );
        ctslHornSequenceBellOnOff$(onOff => {
            me.rv.SetControlValue("Bell", onOff ? 1 : 0);
        });
    } else {
        ctslDitchLightEvents$ = nullStream;
    }

    // Ditch lights, front and rear
    const areHeadLightsOn = () => {
        const cv = me.rv.GetControlValue("Headlights") as number;
        return cv > 0.8 && cv < 1.2;
    };
    const ditchLightControl = frp.liftN(headLights => {
        if (!headLights) {
            return DitchLight.Off;
        } else {
            const cv = me.rv.GetControlValue("DitchLight") as number;
            if (cv > 1.5) {
                return DitchLight.Flash;
            } else if (cv > 0.5) {
                return DitchLight.On;
            } else {
                return DitchLight.Off;
            }
        }
    }, areHeadLightsOn);
    const ditchLightBell$ = frp.compose(
        bellControl$,
        frp.filter(_ => frp.snapshot(ditchLightControl) !== DitchLight.Off),
        frp.filter(v => v === 1)
    );
    const ditchLightHornOrBell$ = frp.compose(
        me.createOnCvChangeStreamFor("Horn"),
        // The quill, for Fan Railer and CTSL Railfan's mods
        frp.merge(me.createOnCvChangeStreamFor("HornHB")),
        frp.filter(v => v > 0.5),
        frp.merge(ditchLightBell$),
        frp.map(_ => DitchLightEvent.HornOrBell)
    );
    const ditchLightMovedHeadlight$ = frp.compose(
        me.createOnCvChangeStreamFor("Headlights"),
        frp.merge(me.createOnCvChangeStreamFor("DitchLight")),
        frp.map(_ => DitchLightEvent.MovedHeadlight)
    );
    const ditchLightsPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.merge(ditchLightHornOrBell$),
        frp.merge(ditchLightMovedHeadlight$),
        frp.merge(ctslDitchLightEvents$),
        frp.fold((accum: DitchLightAccum, e): DitchLightAccum => {
            const control = frp.snapshot(ditchLightControl);
            const nowS = me.e.GetSimulationTime();

            if (accum === DitchLightState.Off || accum === DitchLightState.On) {
                if (e === DitchLightEvent.HornOrBell || e === DitchLightEvent.HornOrBellWithRestart) {
                    return [DitchLightState.HornOrBellFlashing, nowS];
                } else if (control === DitchLight.Off) {
                    return DitchLightState.Off;
                } else if (control === DitchLight.On) {
                    return DitchLightState.On;
                } else {
                    return [DitchLightState.SelectedFlashing, nowS];
                }
            }

            const [state, clockS] = accum;
            if (state === DitchLightState.SelectedFlashing) {
                if (e === DitchLightEvent.HornOrBell || e === DitchLightEvent.HornOrBellWithRestart) {
                    // Preserve the progress through the cycle so that the
                    // transition is seamless.
                    const cycleS = (nowS - clockS) % (ditchLightFlashS * 2);
                    return [DitchLightState.HornOrBellFlashing, nowS - cycleS];
                } else if (control === DitchLight.Off) {
                    return DitchLightState.Off;
                } else if (control === DitchLight.On) {
                    return DitchLightState.On;
                } else {
                    return accum;
                }
            } else {
                // When in horn or bell mode, we should stay put until the timer
                // elapses, or the engineer cancels the sequence.
                if (e === DitchLightEvent.MovedHeadlight || nowS - clockS > ditchLightHornFlashS) {
                    if (control === DitchLight.Off) {
                        return DitchLightState.Off;
                    } else if (control === DitchLight.On) {
                        return DitchLightState.On;
                    } else {
                        return [DitchLightState.SelectedFlashing, clockS];
                    }
                } else if (e === DitchLightEvent.HornOrBellWithRestart) {
                    // Preserve the progress through the cycle so that the
                    // transition is seamless.
                    const cycleS = (nowS - clockS) % (ditchLightFlashS * 2);
                    return [DitchLightState.HornOrBellFlashing, nowS - cycleS];
                } else {
                    return accum;
                }
            }
        }, DitchLightState.Off),
        frp.map((accum): [boolean, boolean] => {
            if (accum === DitchLightState.Off) {
                return [false, false];
            } else if (accum === DitchLightState.On) {
                return [true, true];
            } else {
                const [, clockS] = accum;
                const nowS = me.e.GetSimulationTime();
                const showLeft = (nowS - clockS) % (ditchLightFlashS * 2) < ditchLightFlashS;
                return [showLeft, !showLeft];
            }
        })
    );
    const ditchLightsHelper$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.map((_): [boolean, boolean] => [false, false])
    );
    const ditchLightsFront$ = frp.compose(
        ditchLightsPlayer$,
        frp.map(([l, r]): [boolean, boolean] =>
            frp.snapshot(playerLocation) === PlayerLocation.InFrontCab ? [l, r] : [false, false]
        ),
        frp.merge(ditchLightsHelper$),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.map((au): [boolean, boolean] => {
                    const [frontCoupled] = au.couplings;
                    const ditchOn = !frontCoupled && au.direction === SensedDirection.Forward;
                    return [ditchOn, ditchOn];
                })
            )
        )
    );
    const ditchLightsRear$ = frp.compose(
        ditchLightsPlayer$,
        frp.map(([l, r]): [boolean, boolean] =>
            frp.snapshot(playerLocation) === PlayerLocation.InRearCab ? [l, r] : [false, false]
        ),
        frp.merge(ditchLightsHelper$),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.map((au): [boolean, boolean] => {
                    const [, rearCoupled] = au.couplings;
                    const ditchOn = !rearCoupled && au.direction === SensedDirection.Backward;
                    return [ditchOn, ditchOn];
                })
            )
        )
    );
    const allDitchLights: [
        onOff$: frp.Stream<[boolean, boolean]>,
        lights: [rw.Light, rw.Light],
        nodes: [string, string]
    ][] = [
        [
            ditchLightsFront$,
            [new rw.Light("FrontDitchLightL"), new rw.Light("FrontDitchLightR")],
            ["ditch_fwd_l", "ditch_fwd_r"],
        ],
        [
            ditchLightsRear$,
            [new rw.Light("RearDitchLightL"), new rw.Light("RearDitchLightR")],
            ["ditch_rev_l", "ditch_rev_r"],
        ],
    ];
    allDitchLights.forEach(([onOff$, [lightL, lightR], [nodeL, nodeR]]) => {
        const setLeft$ = frp.compose(
            onOff$,
            frp.map(([l]) => l),
            rejectRepeats()
        );
        const setRight$ = frp.compose(
            onOff$,
            frp.map(([, r]) => r),
            rejectRepeats()
        );
        setLeft$(on => {
            lightL.Activate(on);
            me.rv.ActivateNode(nodeL, on);
        });
        setRight$(on => {
            lightR.Activate(on);
            me.rv.ActivateNode(nodeR, on);
        });
    });

    // Process OnControlValueChange events.
    const onCvChange$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.reject(([name]) => name === "Bell")
    );
    onCvChange$(([name, value]) => {
        me.rv.SetControlValue(name, value);
    });

    // Pantograph up/down buttons
    const pantographUp$ = frp.compose(
        me.createOnCvChangeStreamFor("PantographUpButton"),
        frp.filter(v => v >= 1)
    );
    const pantographUpDown$ = frp.compose(
        me.createOnCvChangeStreamFor("PantographDownButton"),
        frp.filter(v => v >= 1),
        frp.map(_ => 0),
        frp.merge(pantographUp$)
    );
    pantographUpDown$(v => {
        me.rv.SetControlValue("PantographControl", v);
    });

    // Shift+' suppression hotkey
    const autoSuppression$ = frp.compose(
        me.createOnCvChangeStreamFor("AutoSuppression"),
        frp.filter(v => v > 0)
    );
    autoSuppression$(_ => {
        me.rv.SetControlValue("VirtualBrake", isCtslEnhancedPack ? 0.5 : 0.75);
    });

    // Set consist brake lights.
    fx.createBrakeLightStreamForEngine(me);

    // Set platform door height.
    fx.setLowPlatformDoorsForEngine(me, false);

    // Enable updates.
    me.e.BeginUpdate();
});
me.setup();
