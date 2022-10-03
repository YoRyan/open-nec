/**
 * Amtrak Siemens ACS-64
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { mapBehavior, movingAverage } from "lib/frp-extra";
import { SensedDirection, VehicleCamera } from "lib/frp-vehicle";
import * as adu from "lib/nec/amtrak-adu";
import * as m from "lib/math";
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
    MovedHeadlight,
}

const nDisplaySamples = 30;
const displayRefreshMs = 100;

const me = new FrpEngine(() => {
    // Electric power supply
    const electrification = ps.createElectrificationBehaviorWithLua(me, ps.Electrification.Overhead);
    const frontSparkLight = new rw.Light("Spark1");
    const rearSparkLight = new rw.Light("Spark2");
    const frontPantoSpark$ = fx.createUniModePantographSparkStream(
        me,
        electrification,
        () => me.rv.GetControlValue("PantographControl", 0) === 1
    );
    const rearPantoSpark$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => false)
    );
    frontPantoSpark$(spark => {
        me.rv.SetControlValue("Spark", 0, spark ? 1 : 0);

        frontSparkLight.Activate(spark);
        me.rv.ActivateNode("PantoAsparkA", spark);
        me.rv.ActivateNode("PantoAsparkB", spark);
        me.rv.ActivateNode("PantoAsparkC", spark);
        me.rv.ActivateNode("PantoAsparkD", spark);
        me.rv.ActivateNode("PantoAsparkE", spark);
        me.rv.ActivateNode("PantoAsparkF", spark);
    });
    rearPantoSpark$(spark => {
        rearSparkLight.Activate(spark);
        me.rv.ActivateNode("PantoBsparkA", spark);
        me.rv.ActivateNode("PantoBsparkB", spark);
        me.rv.ActivateNode("PantoBsparkC", spark);
        me.rv.ActivateNode("PantoBsparkD", spark);
        me.rv.ActivateNode("PantoBsparkE", spark);
        me.rv.ActivateNode("PantoBsparkF", spark);
    });

    // ATC cut in/out
    const atcCutIn = () => (me.rv.GetControlValue("ATCCutIn", 0) as number) > 0.5;
    const acsesCutIn = () => (me.rv.GetControlValue("ACSESCutIn", 0) as number) > 0.5;
    const updateCutIns$ = me.createPlayerWithKeyUpdateStream();
    updateCutIns$(_ => {
        const atc = frp.snapshot(atcCutIn);
        me.rv.SetControlValue("SigATCCutIn", 0, atc ? 1 : 0);
        me.rv.SetControlValue("SigATCCutOut", 0, atc ? 0 : 1);
        const acses = frp.snapshot(acsesCutIn);
        me.rv.SetControlValue("SigACSESCutIn", 0, acses ? 1 : 0);
        me.rv.SetControlValue("SigACSESCutOut", 0, acses ? 0 : 1);
    });
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("VirtualBrake", 0) as number) > 0.66;
    const [aduState$, aduEvents$] = adu.create(me, acknowledge, suppression, atcCutIn, acsesCutIn);
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(state => {
        me.rv.SetControlValue(
            "SigAspectTopGreen",
            0,
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
            0,
            state.aspect === adu.AduAspect.Approach ||
                state.aspect === adu.AduAspect.ApproachMedium30 ||
                state.aspect === adu.AduAspect.ApproachMedium45
                ? 1
                : 0
        );
        me.rv.SetControlValue(
            "SigAspectTopRed",
            0,
            state.aspect === adu.AduAspect.Stop || state.aspect === adu.AduAspect.Restrict ? 1 : 0
        );
        me.rv.SetControlValue("SigAspectTopWhite", 0, 0);
        me.rv.SetControlValue(
            "SigAspectBottomGreen",
            0,
            state.aspect === adu.AduAspect.ApproachMedium30 || state.aspect === adu.AduAspect.ApproachMedium45 ? 1 : 0
        );
        me.rv.SetControlValue("SigAspectBottomYellow", 0, 0);
        me.rv.SetControlValue("SigAspectBottomWhite", 0, state.aspect === adu.AduAspect.Restrict ? 1 : 0);

        me.rv.SetControlValue(
            "SigText",
            0,
            {
                [adu.AduAspect.Stop]: 12,
                [adu.AduAspect.Restrict]: 11,
                [adu.AduAspect.Approach]: 8,
                [adu.AduAspect.ApproachMedium30]: 13,
                [adu.AduAspect.ApproachMedium45]: 13,
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
            me.rv.SetControlValue("SigS", 0, state.aspect === adu.AduAspect.Stop ? 1 : 0);
            me.rv.SetControlValue("SigR", 0, state.aspect === adu.AduAspect.Restrict ? 1 : 0);
            me.rv.SetControlValue("SigM", 0, state.aspect === adu.AduAspect.Approach ? 1 : 0);
            me.rv.SetControlValue("SigL", 0, state.aspect === adu.AduAspect.ApproachMedium45 ? 1 : 0);
            me.rv.SetControlValue(
                "Sig60",
                0,
                state.aspect === adu.AduAspect.CabSpeed60 || state.aspect === adu.AduAspect.CabSpeed60Off ? 1 : 0
            );
            me.rv.SetControlValue(
                "Sig80",
                0,
                state.aspect === adu.AduAspect.CabSpeed80 || state.aspect === adu.AduAspect.CabSpeed80Off ? 1 : 0
            );
            me.rv.SetControlValue("SigN", 0, state.aspect === adu.AduAspect.Clear125 ? 1 : 0);
        } else {
            for (const cv of ["SigS", "SigR", "SigM", "SigL", "Sig60", "Sig80", "SigN"]) {
                me.rv.SetControlValue(cv, 0, 0);
            }
        }

        me.rv.SetControlValue("SigModeATC", 0, state.masEnforcing === adu.MasEnforcing.Atc ? 1 : 0);
        me.rv.SetControlValue("SigModeACSES", 0, state.masEnforcing === adu.MasEnforcing.Acses ? 1 : 0);

        if (state.masSpeedMph !== undefined) {
            const [[h, t, u]] = m.digits(state.masSpeedMph, 3);
            me.rv.SetControlValue("SpeedLimit_hundreds", 0, h);
            me.rv.SetControlValue("SpeedLimit_tens", 0, t);
            me.rv.SetControlValue("SpeedLimit_units", 0, u);
        } else {
            me.rv.SetControlValue("SpeedLimit_hundreds", 0, 0);
            me.rv.SetControlValue("SpeedLimit_tens", 0, -1);
            me.rv.SetControlValue("SpeedLimit_units", 0, -1);
        }

        if (state.timeToPenaltyS !== undefined) {
            const [[h, t, u]] = m.digits(state.timeToPenaltyS, 3);
            me.rv.SetControlValue("Penalty_hundreds", 0, h);
            me.rv.SetControlValue("Penalty_tens", 0, t);
            me.rv.SetControlValue("Penalty_units", 0, u);
        } else {
            me.rv.SetControlValue("Penalty_hundreds", 0, 0);
            me.rv.SetControlValue("Penalty_tens", 0, -1);
            me.rv.SetControlValue("Penalty_units", 0, -1);
        }
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterReset$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.filter(([name]) => name === "ThrottleAndBrake" || name === "VirtualBrake")
    );
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);
    const alerter$ = frp.compose(ale.create(me, acknowledge, alerterReset$, alerterCutIn), frp.hub());
    const alerterState = frp.stepper(alerter$, undefined);
    // Safety system sounds
    const isAlarm = frp.liftN(
        (aduState, alerterState) => (aduState?.alarm || alerterState?.alarm) ?? false,
        aduState,
        alerterState
    );
    const alarmHud$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(isAlarm));
    alarmHud$(on => {
        me.rv.SetControlValue("AWSWarnCount", 0, on ? 1 : 0);
    });
    const alarmSound$ = frp.compose(me.createPlayerWithKeyUpdateStream(), fx.loopSound(0.5, isAlarm));
    alarmSound$(play => {
        me.rv.SetControlValue("SpeedReductionAlert", 0, play ? 1 : 0);
    });
    const upgradeEvents$ = frp.compose(
        aduEvents$,
        frp.filter(evt => evt === adu.AduEvent.Upgrade)
    );
    const upgradeSound$ = frp.compose(me.createPlayerWithKeyUpdateStream(), fx.triggerSound(1, upgradeEvents$));
    upgradeSound$(play => {
        me.rv.SetControlValue("SpeedIncreaseAlert", 0, play ? 1 : 0);
    });

    // Throttle, dynamic brake, and air brake controls
    const isPowerAvailable = () => ps.uniModeEngineHasPower(ps.EngineMode.Overhead, electrification);
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
    // It's necessary to probe the minimum and maximum limits for Fan Railer's mod.
    const throttleRange = [
        me.rv.GetControlMinimum("ThrottleAndBrake", 0) as number,
        me.rv.GetControlMaximum("ThrottleAndBrake", 0) as number,
    ];
    // Scaled from -1 (full dynamic braking) to 1 (full power).
    const throttleAndDynBrakeInput = () => {
        const input = me.rv.GetControlValue("ThrottleAndBrake", 0) as number;
        const [min, max] = throttleRange;
        return ((input - min) / (max - min)) * 2 - 1;
    };
    const throttleAndDynBrake = frp.liftN(
        (isPowerAvailable, isPenaltyBrake, input) => {
            if (isPenaltyBrake) {
                return 0;
            } else if (!isPowerAvailable) {
                return Math.min(input, 0);
            } else {
                return input;
            }
        },
        isPowerAvailable,
        isPenaltyBrake,
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
        me.rv.SetControlValue("Regulator", 0, throttleAndBrake);
        me.rv.SetControlValue("DynamicBrake", 0, -throttleAndBrake);
    });
    const airBrakeInput = () => me.rv.GetControlValue("VirtualBrake", 0) as number;
    const airBrake = frp.liftN(
        (isPenaltyBrake, input) => {
            const fullService = 0.85;
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
        airBrakeInput
    );
    const airBrakeOutput$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(airBrake));
    airBrakeOutput$(brake => {
        me.rv.SetControlValue("TrainBrakeControl", 0, brake);
    });

    // Driving screen
    const displayUpdate$ = frp.compose(me.createPlayerWithKeyUpdateStream(), frp.throttle(displayRefreshMs));
    const tractiveEffortKlbs$ = frp.compose(
        displayUpdate$,
        frp.map(_ => (me.eng.GetTractiveEffort() * 71 * 71) / 80.5),
        movingAverage(nDisplaySamples)
    );
    tractiveEffortKlbs$(effortKlbs => {
        const [[t, u], guide] = m.digits(Math.round(effortKlbs), 2);
        me.rv.SetControlValue("effort_tens", 0, t);
        me.rv.SetControlValue("effort_units", 0, u);
        me.rv.SetControlValue("effort_guide", 0, guide);
        me.rv.SetControlValue("AbsTractiveEffort", 0, (effortKlbs * 365) / 80);
    });
    const accelerationMphMin$ = frp.compose(
        displayUpdate$,
        frp.map(_ => Math.abs(me.rv.GetAcceleration() * 134.2162)),
        movingAverage(nDisplaySamples),
        frp.throttle(displayRefreshMs)
    );
    accelerationMphMin$(accelMphMin => {
        const [[h, t, u], guide] = m.digits(Math.round(accelMphMin), 3);
        me.rv.SetControlValue("accel_hundreds", 0, h);
        me.rv.SetControlValue("accel_tens", 0, t);
        me.rv.SetControlValue("accel_units", 0, u);
        me.rv.SetControlValue("accel_guide", 0, guide);
        me.rv.SetControlValue("AccelerationMPHPM", 0, accelMphMin);
    });
    displayUpdate$(_ => {
        const speedoMph = me.rv.GetControlValue("SpeedometerMPH", 0) as number;
        const [[h, t, u], guide] = m.digits(Math.round(speedoMph), 3);
        me.rv.SetControlValue("SpeedDigit_hundreds", 0, h);
        me.rv.SetControlValue("SpeedDigit_tens", 0, t);
        me.rv.SetControlValue("SpeedDigit_units", 0, u);
        me.rv.SetControlValue("SpeedDigit_guide", 0, guide);

        const isWheelSlip = (me.rv.GetControlValue("Wheelslip", 0) as number) > 1;
        me.rv.SetControlValue("ScreenWheelslip", 0, isWheelSlip ? 1 : 0);
        const isParkingBrake = (me.rv.GetControlValue("HandBrake", 0) as number) > 0;
        me.rv.SetControlValue("ScreenParkingBrake", 0, isParkingBrake ? 1 : 0);
        me.rv.SetControlValue("ScreenSuppression", 0, frp.snapshot(suppression) ? 1 : 0);
    });
    alerter$(state => {
        me.rv.SetControlValue("ScreenAlerter", 0, state.alarm ? 1 : 0);
    });

    // Camera state for interior lights
    const vehicleCamera = frp.stepper(me.createOnCameraStream(), VehicleCamera.Outside);
    const isPlayerInside$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.merge(me.createAiUpdateStream()),
        frp.map(_ => false)
    );
    const isPlayerInFrontCab$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => frp.snapshot(vehicleCamera) === VehicleCamera.FrontCab),
        frp.merge(isPlayerInside$),
        frp.hub()
    );
    const isPlayerInRearCab$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => frp.snapshot(vehicleCamera) === VehicleCamera.RearCab),
        frp.merge(isPlayerInside$),
        frp.hub()
    );

    // Cab dome lights, front and rear
    // (Yes, these lights are reversed!)
    const cabLightFront = new rw.Light("RearCabLight");
    const cabLightRear = new rw.Light("FrontCabLight");
    const cabLightControl = () => (me.rv.GetControlValue("CabLight", 0) as number) > 0.5;
    const cabLightFront$ = frp.compose(
        isPlayerInFrontCab$,
        frp.map(player => player && frp.snapshot(cabLightControl))
    );
    const cabLightRear$ = frp.compose(
        isPlayerInRearCab$,
        frp.map(player => player && frp.snapshot(cabLightControl))
    );
    cabLightFront$(on => {
        cabLightFront.Activate(on);
    });
    cabLightRear$(on => {
        cabLightRear.Activate(on);
    });

    // Desk and console lights, front and rear
    const deskLightsFront = [new rw.Light("Front_ConsoleLight_01"), new rw.Light("Front_ConsoleLight_03")];
    const deskLightsRear = [new rw.Light("Rear_ConsoleLight_01"), new rw.Light("Rear_ConsoleLight_03")];
    const consoleLightsFront = [new rw.Light("Front_ConsoleLight_02")];
    const consoleLightsRear = [new rw.Light("Rear_ConsoleLight_02")];
    // Secondman's desk light, front and rear (has an independent switch IRL)
    const secondmanLightsFront = [new rw.Light("Front_DeskLight_01")];
    const secondmanLightsRear = [new rw.Light("Rear_DeskLight_01")];
    const deskConsoleLightControl = () => {
        const cv = me.rv.GetControlValue("DeskConsoleLight", 0) as number;
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
    const deskLightsFront$ = frp.compose(
        isPlayerInFrontCab$,
        frp.map(player => (player ? frp.snapshot(deskConsoleLightControl) : DeskConsoleLight.Off))
    );
    const deskLightsRear$ = frp.compose(
        isPlayerInRearCab$,
        frp.map(player => (player ? frp.snapshot(deskConsoleLightControl) : DeskConsoleLight.Off))
    );
    deskLightsFront$(state => {
        for (const light of deskLightsFront) {
            light.Activate(state === DeskConsoleLight.DeskOnly || state === DeskConsoleLight.DeskAndConsole);
        }
        for (const light of [...consoleLightsFront, ...secondmanLightsFront]) {
            light.Activate(state === DeskConsoleLight.DeskAndConsole || state === DeskConsoleLight.ConsoleOnly);
        }
    });
    deskLightsRear$(state => {
        for (const light of deskLightsRear) {
            light.Activate(state === DeskConsoleLight.DeskOnly || state === DeskConsoleLight.DeskAndConsole);
        }
        for (const light of [...consoleLightsRear, ...secondmanLightsRear]) {
            light.Activate(state === DeskConsoleLight.DeskAndConsole || state === DeskConsoleLight.ConsoleOnly);
        }
    });

    // Horn rings the bell.
    const bellOn$ = frp.compose(
        me.createOnCvChangeStreamFor("Horn", 0),
        frp.filter(v => v > 0),
        frp.map(_ => 1)
    );
    const bellControl$ = frp.compose(
        me.createOnCvChangeStreamFor("Bell", 0),
        frp.map(v => {
            const outOfSync = (v === 0 || v === 1) && v === me.rv.GetControlValue("Bell", 0);
            return outOfSync ? 1 - v : v;
        }),
        frp.merge(bellOn$),
        frp.filter(_ => me.eng.GetIsEngineWithKey()),
        frp.hub()
    );
    bellControl$(v => {
        me.rv.SetControlValue("Bell", 0, v);
    });

    // Camera state for ditch lights
    const isPlayerUsingFrontCab$ = frp.compose(
        me.createOnCameraStream(),
        frp.filter(cam => cam === VehicleCamera.FrontCab || cam === VehicleCamera.RearCab),
        frp.map(cam => cam === VehicleCamera.FrontCab)
    );
    const isPlayerUsingFrontCab = frp.stepper(isPlayerUsingFrontCab$, true);

    // Ditch lights, front and rear
    const ditchLightsFront = [new rw.Light("FrontDitchLightL"), new rw.Light("FrontDitchLightR")];
    const ditchLightsRear = [new rw.Light("RearDitchLightL"), new rw.Light("RearDitchLightR")];
    const areHeadLightsOn = () => {
        const cv = me.rv.GetControlValue("Headlights", 0) as number;
        return cv > 0.5 && cv < 1.5;
    };
    const ditchLightControl = frp.liftN(headLights => {
        if (!headLights) {
            return DitchLight.Off;
        } else {
            const cv = me.rv.GetControlValue("DitchLight", 0) as number;
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
        me.createOnCvChangeStreamFor("Horn", 0),
        frp.filter(v => v === 1),
        frp.merge(ditchLightBell$),
        frp.map(_ => DitchLightEvent.HornOrBell)
    );
    const ditchLightMovedHeadlight$ = frp.compose(
        me.createOnCvChangeStreamFor("Headlights", 0),
        frp.map(_ => DitchLightEvent.MovedHeadlight)
    );
    const ditchLightsPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.merge(ditchLightHornOrBell$),
        frp.merge(ditchLightMovedHeadlight$),
        frp.fold((accum: DitchLightAccum, e): DitchLightAccum => {
            const control = frp.snapshot(ditchLightControl);
            const nowS = me.e.GetSimulationTime();

            if (accum === DitchLightState.Off || accum === DitchLightState.On) {
                if (e === DitchLightEvent.HornOrBell) {
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
                if (e === DitchLightEvent.HornOrBell) {
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
    const ditchLightsFrontAi$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map((au): [boolean, boolean] => {
            const [frontCoupled] = au.couplings;
            const ditchOn = !frontCoupled && au.direction === SensedDirection.Forward;
            return [ditchOn, ditchOn];
        })
    );
    const ditchLightsFrontHelper$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.map((_): [boolean, boolean] => [false, false])
    );
    const ditchLightsFront$ = frp.compose(
        ditchLightsPlayer$,
        frp.map(([l, r]): [boolean, boolean] => (frp.snapshot(isPlayerUsingFrontCab) ? [l, r] : [false, false])),
        frp.merge(ditchLightsFrontAi$),
        frp.merge(ditchLightsFrontHelper$)
    );
    const ditchLightsRearNonPlayer$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.merge(me.createAiUpdateStream()),
        frp.map((_): [boolean, boolean] => [false, false])
    );
    const ditchLightsRear$ = frp.compose(
        ditchLightsPlayer$,
        frp.map(([l, r]): [boolean, boolean] => (frp.snapshot(isPlayerUsingFrontCab) ? [false, false] : [l, r])),
        frp.merge(ditchLightsRearNonPlayer$)
    );
    ditchLightsFront$(([l, r]) => {
        const [lightL, lightR] = ditchLightsFront;
        lightL.Activate(l);
        lightR.Activate(r);
        me.rv.ActivateNode("ditch_fwd_l", l);
        me.rv.ActivateNode("ditch_fwd_r", r);
    });
    ditchLightsRear$(([l, r]) => {
        const [lightL, lightR] = ditchLightsRear;
        lightL.Activate(l);
        lightR.Activate(r);
        me.rv.ActivateNode("ditch_rev_l", l);
        me.rv.ActivateNode("ditch_rev_r", r);
    });

    // Process OnControlValueChange events.
    const onCvChange$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.reject(([name]) => name === "Bell")
    );
    onCvChange$(([name, index, value]) => {
        me.rv.SetControlValue(name, index, value);
    });

    // Pantograph up/down buttons
    const pantographUp$ = frp.compose(
        me.createOnCvChangeStreamFor("PantographUpButton", 0),
        frp.filter(v => v >= 1)
    );
    const pantographUpDown$ = frp.compose(
        me.createOnCvChangeStreamFor("PantographDownButton", 0),
        frp.filter(v => v >= 1),
        frp.map(_ => 0),
        frp.merge(pantographUp$)
    );
    pantographUpDown$(v => {
        me.rv.SetControlValue("PantographControl", 0, v);
    });

    // Shift+' suppression hotkey
    const autoSuppression$ = frp.compose(
        me.createOnCvChangeStreamFor("AutoSuppression", 0),
        frp.filter(v => v > 0)
    );
    autoSuppression$(_ => {
        me.rv.SetControlValue("VirtualBrake", 0, 0.75);
    });

    // Set consist brake lights.
    fx.createBrakeLightStreamForEngine(me);

    // Enable updates.
    me.activateUpdatesEveryFrame(true);
});
me.setup();
