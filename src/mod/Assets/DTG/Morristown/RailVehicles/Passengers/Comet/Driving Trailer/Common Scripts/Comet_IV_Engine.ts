/**
 * NJ Transit Comet IV Cab Car
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import * as xt from "lib/frp-extra";
import { SensedDirection, VehicleCamera } from "lib/frp-vehicle";
import * as m from "lib/math";
import * as njt from "lib/nec/nj-transit";
import * as adu from "lib/nec/njt-adu";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import { dieselPowerPct, dualModeOrder, dualModeSwitchS, pantographLowerPosition } from "lib/shared/alp45";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

enum DitchLights {
    Off,
    Fixed,
    Flash,
}

enum StrobeLights {
    Off,
    ManualOn,
    AutoBell,
}

const ditchLightsFadeS = 0.3;
const ditchLightFlashS = 0.65;
const strobeLightFlashS = 0.08;
const strobeLightCycleS = 0.8;
const strobeLightBellS = 30;

const me = new FrpEngine(() => {
    // Dual-mode power supply
    // (Yes, hilariously, this is the only way to tell the versions apart.)
    const binPowerMode = me.rv.ControlExists("WindowRightExt") ? ps.EngineMode.Overhead : ps.EngineMode.Diesel;
    const electrification = ps.createElectrificationBehaviorWithControlValues(me, {
        [ps.Electrification.Overhead]: "PowerState",
        [ps.Electrification.ThirdRail]: undefined,
    });
    const modeAuto = () => (me.rv.GetControlValue("PowerSwitchAuto") as number) > 0.5;
    ui.createAutoPowerStatusPopup(me, modeAuto);
    const modeAutoSwitch$ = ps.createDualModeAutoSwitchStream(me, ...dualModeOrder, modeAuto);
    modeAutoSwitch$(mode => {
        me.rv.SetControlValue("PowerMode", mode === ps.EngineMode.Overhead ? 1 : 0);
    });
    // (Yes, that means we have to fix this control value too.)
    const firstSettledUpdate$ = frp.compose(me.createFirstUpdateAfterControlsSettledStream(), frp.hub());
    const fixPowerMode$ = frp.compose(
        firstSettledUpdate$,
        frp.filter(resumeFromSave => !resumeFromSave)
    );
    fixPowerMode$(_ => {
        me.rv.SetControlValue("PowerMode", binPowerMode === ps.EngineMode.Overhead ? 1 : 0);
    });
    const modeSelect = frp.liftN(
        (firstUpdate, cv) => {
            if (firstUpdate === undefined) {
                // Avoid any potential timing issues.
                return binPowerMode;
            } else {
                return cv > 0.5 ? ps.EngineMode.Overhead : ps.EngineMode.Diesel;
            }
        },
        frp.stepper(firstSettledUpdate$, undefined),
        () => me.rv.GetControlValue("PowerMode") as number
    );
    const modePosition = ps.createDualModeEngineBehavior({
        e: me,
        modes: dualModeOrder,
        getPlayerMode: modeSelect,
        getAiMode: ps.EngineMode.Diesel,
        getPlayerCanSwitch: () => true,
        transitionS: dualModeSwitchS,
        instantSwitch: modeAutoSwitch$,
        positionFromSaveOrConsist: () => me.rv.GetControlValue("PowerSwitchState") as number,
    });
    const setModePosition$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        xt.mapBehavior(modePosition),
        xt.rejectRepeats()
    );
    setModePosition$(position => {
        me.rv.SetControlValue("PowerSwitchState", position);
    });
    // Power mode switch
    // (The Comet IV lacks a working fault reset control, so we don't simulate
    // the manual sequence.)
    const canSwitchModes = frp.liftN(
        (controlsSettled, isStopped, throttle) => controlsSettled && isStopped && throttle <= 0,
        me.areControlsSettled,
        () => me.rv.GetSpeed() < c.stopSpeed,
        () => me.rv.GetControlValue("VirtualThrottle") as number
    );
    const playerSwitchModesEasy$ = frp.compose(
        me.createOnCvChangeStreamFor("PowerSwitch"),
        frp.filter(v => v === 1),
        frp.map(_ => 1 - (me.rv.GetControlValue("PowerMode") as number)),
        frp.filter(_ => frp.snapshot(canSwitchModes)),
        frp.hub()
    );
    playerSwitchModesEasy$(v => {
        me.rv.SetControlValue("PowerMode", v);
    });
    // Lower the pantograph near the end of the transition to diesel. Raise it
    // when switching to electric using the power switch hotkey.
    const setPantographAuto$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        xt.mapBehavior(modePosition),
        xt.fsm(0),
        frp.filter(([from, to]) => from > pantographLowerPosition && to <= pantographLowerPosition),
        frp.map(_ => 0),
        frp.merge(
            frp.compose(
                playerSwitchModesEasy$,
                frp.filter(v => v === 1)
            )
        )
    );
    setPantographAuto$(v => {
        me.rv.SetControlValue("VirtualPantographControl", v);
    });
    const pantographUp = () => (me.rv.GetControlValue("VirtualPantographControl") as number) > 0.5;
    const powerAvailable = frp.liftN(
        (modePosition, pantographUp) => {
            if (modePosition === 0) {
                return dieselPowerPct;
            } else if (modePosition === 1) {
                const haveElectrification = ps.uniModeEngineHasPower(ps.EngineMode.Overhead, electrification);
                return haveElectrification && pantographUp ? 1 : 0;
            } else {
                return 0;
            }
        },
        modePosition,
        pantographUp
    );
    // Keep the pantograph lowered if spawning in diesel mode.
    if (binPowerMode === ps.EngineMode.Diesel) {
        const pantographDefault$ = frp.compose(
            me.createFirstUpdateAfterControlsSettledStream(),
            frp.filter(resumeFromSave => !resumeFromSave),
            frp.map(_ => 0)
        );
        pantographDefault$(v => {
            me.rv.SetControlValue("VirtualPantographControl", v);
        });
    }

    // Safety systems cut in/out
    // ATC and ACSES controls are reversed for NJT DLC.
    const atcCutIn = () => !((me.rv.GetControlValue("ACSES") as number) > 0.5);
    const acsesCutIn = () => !((me.rv.GetControlValue("ATC") as number) > 0.5);
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = frp.liftN(
        (bp, lever) => bp || lever,
        me.createBrakePressureSuppressionBehavior(),
        () => (me.rv.GetControlValue("VirtualBrake") as number) > 0.5
    );
    const [aduState$, aduEvents$] = adu.create({
        e: me,
        acknowledge,
        suppression,
        atcCutIn,
        acsesCutIn,
        equipmentSpeedMps: 100 * c.mph.toMps,
        pulseCodeControlValue: "ACSES_SpeedSignal",
    });
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(({ masSpeedMph }) => {
        // Almost nothing works with this ADU; we only have the green digits to
        // manipulate.
        if (masSpeedMph !== undefined) {
            const [[h, t, u], guide] = m.digits(Math.round(masSpeedMph), 3);
            me.rv.SetControlValue("SpeedH", h);
            me.rv.SetControlValue("SpeedT", t);
            me.rv.SetControlValue("SpeedU", u);
            me.rv.SetControlValue("SpeedP", guide);
        } else {
            me.rv.SetControlValue("SpeedH", -1);
            me.rv.SetControlValue("SpeedT", -1);
            me.rv.SetControlValue("SpeedU", -1);
        }

        // This keeps the gray bar underneath the current speed visible.
        me.rv.SetControlValue("ACSES_SpeedGreen", 0);
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterState = frp.stepper(ale.create({ e: me, acknowledge, cutIn: alerterCutIn }), undefined);
    // Safety system sounds
    const upgradeSound$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        fx.triggerSound(
            1,
            frp.compose(
                aduEvents$,
                frp.filter(evt => evt === adu.AduEvent.Upgrade)
            )
        )
    );
    const safetyAlarmSound$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        fx.loopSound(
            0.5,
            frp.liftN(aduState => (aduState?.atcAlarm || aduState?.acsesAlarm) ?? false, aduState)
        )
    );
    const alarmsUpdate$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        xt.mapBehavior(
            frp.liftN(
                (aduState, alerterState, upgradeSound, alarmSound) => {
                    return {
                        awsWarnCount: (aduState?.atcAlarm || aduState?.acsesAlarm || alerterState?.alarm) ?? false,
                        acsesAlert: alerterState?.alarm ?? false,
                        acsesIncrease: upgradeSound,
                        acsesDecrease: alarmSound,
                    };
                },
                aduState,
                alerterState,
                frp.stepper(upgradeSound$, false),
                frp.stepper(safetyAlarmSound$, false)
            )
        )
    );
    alarmsUpdate$(({ awsWarnCount, acsesAlert, acsesIncrease, acsesDecrease }) => {
        me.rv.SetControlValue("AWSWarnCount", awsWarnCount ? 1 : 0);
        me.rv.SetControlValue("ACSES_Alert", acsesAlert ? 1 : 0);
        me.rv.SetControlValue("ACSES_AlertIncrease", acsesIncrease ? 1 : 0);
        me.rv.SetControlValue("ACSES_AlertDecrease", acsesDecrease ? 1 : 0);
    });

    // Manual door control
    njt.createManualDoorsPopup(me);
    const passengerDoors = njt.createManualDoorsBehavior(me);
    const areDoorsOpen = frp.liftN(([left, right]) => left > 0 || right > 0, passengerDoors);
    const leftDoor$ = frp.compose(
        me.createUpdateStream(),
        xt.mapBehavior(passengerDoors),
        frp.map(([left]) => left),
        xt.rejectRepeats()
    );
    const rightDoor$ = frp.compose(
        me.createUpdateStream(),
        xt.mapBehavior(passengerDoors),
        frp.map(([, right]) => right),
        xt.rejectRepeats()
    );
    leftDoor$(position => {
        me.rv.SetTime("Doors_l", position * 2);
    });
    rightDoor$(position => {
        me.rv.SetTime("Doors_r", position * 2);
    });

    // Throttle, dynamic brake, and air brake controls
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
    const throttle$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        xt.mapBehavior(
            frp.liftN(
                (isPenaltyBrake, available, input) => (isPenaltyBrake ? 0 : available * input),
                isPenaltyBrake,
                powerAvailable,
                () => me.rv.GetControlValue("VirtualThrottle") as number
            )
        )
    );
    throttle$(v => {
        me.rv.SetControlValue("Regulator", v);
    });
    const airBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        xt.mapBehavior(
            frp.liftN(
                (isPenaltyBrake, areDoorsOpen, input) => (isPenaltyBrake || areDoorsOpen ? 0.6 : input),
                isPenaltyBrake,
                areDoorsOpen,
                () => me.rv.GetControlValue("VirtualBrake") as number
            )
        )
    );
    airBrake$(v => {
        me.rv.SetControlValue("TrainBrakeControl", v);
    });
    // DTG's "blended braking" algorithm
    const brakePipePsi = () => me.rv.GetControlValue("AirBrakePipePressurePSI") as number;
    const dynamicBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        xt.mapBehavior(frp.liftN(bpPsi => Math.min((110 - bpPsi) / 16, 1), brakePipePsi))
    );
    dynamicBrake$(v => {
        me.rv.SetControlValue("DynamicBrake", v);
    });

    // Cab lights
    const domeLight = new rw.Light("CabLight");
    const cabLightsNonPlayer$ = frp.compose(
        me.createAiUpdateStream(),
        frp.merge(me.createPlayerWithoutKeyUpdateStream()),
        frp.map(_ => false)
    );
    const domeLight$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("CabLight") as number) > 0.5),
        frp.merge(cabLightsNonPlayer$),
        xt.rejectRepeats()
    );
    domeLight$(on => {
        domeLight.Activate(on);
    });

    // Gauge lights
    const inCab = frp.liftN(
        camera => camera === VehicleCamera.FrontCab,
        frp.stepper(me.createOnCameraStream(), VehicleCamera.Outside)
    );
    const instrumentLights = [new rw.Light("ConsoleLight_Guage01"), new rw.Light("ConsoleLight_Guage02")];
    const instrumentLights$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        xt.mapBehavior(
            frp.liftN(
                (inCab, cv) => inCab && cv > 0.9,
                inCab,
                () => me.rv.GetControlValue("InstrumentLights") as number
            )
        ),
        frp.merge(cabLightsNonPlayer$),
        xt.rejectRepeats()
    );
    instrumentLights$(on => {
        instrumentLights.forEach(light => light.Activate(on));
    });

    // Status panel lights
    const statusLights: [turnOn: frp.Behavior<boolean>, light: rw.Light][] = [
        [() => (me.rv.GetControlValue("VirtualSander") as number) > 0.5, new rw.Light("AlertLight_Sanding")],
        [() => (me.rv.GetControlValue("Wheelslip") as number) >= 2, new rw.Light("AlertLight_WheelSlip")],
        [() => (me.rv.GetControlValue("HEP") as number) > 0.5, new rw.Light("AlertLight_HEPOn")],
        [() => (me.rv.GetControlValue("AWSWarnCount") as number) > 0.5, new rw.Light("AlertLight_Alarm")],
        [pantographUp, new rw.Light("AlertLight_PantographUp")],
        [frp.liftN(pantographUp => !pantographUp, pantographUp), new rw.Light("AlertLight_PantographDown")],
        [() => (me.rv.GetControlValue("HandBrake") as number) > 0.5, new rw.Light("AlertLight_Handbreak")],
    ];
    statusLights.forEach(([turnOn, light]) => {
        const lightOn$ = frp.compose(
            me.createPlayerWithKeyUpdateStream(),
            xt.mapBehavior(frp.liftN((inCab, on) => inCab && on, inCab, turnOn)),
            frp.merge(cabLightsNonPlayer$),
            xt.rejectRepeats()
        );
        lightOn$(on => {
            light.Activate(on);
        });
    });

    // Ditch lights
    const ditchLights = [
        new fx.FadeableLight(me, ditchLightsFadeS, "Ditch_L"),
        new fx.FadeableLight(me, ditchLightsFadeS, "Ditch_R"),
    ];
    const areHeadLightsOn = () => (me.rv.GetControlValue("Headlights") as number) > 1.5;
    const ditchLightsSetting = frp.liftN(
        (headLights, cv) => {
            if (!headLights || cv < 0.5) {
                return DitchLights.Off;
            } else if (cv < 1.5) {
                return DitchLights.Fixed;
            } else {
                return DitchLights.Flash;
            }
        },
        areHeadLightsOn,
        () => me.rv.GetControlValue("DitchLightSwitch") as number
    );
    const ditchLightsPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        fx.behaviorStopwatchS(frp.liftN(setting => setting === DitchLights.Flash, ditchLightsSetting)),
        frp.map((stopwatchS): [boolean, boolean] => {
            if (stopwatchS === undefined) {
                const ditchFixed = frp.snapshot(ditchLightsSetting) === DitchLights.Fixed;
                return [ditchFixed, ditchFixed];
            } else {
                const flashLeft = stopwatchS % (ditchLightFlashS * 2) < ditchLightFlashS;
                return [flashLeft, !flashLeft];
            }
        })
    );
    const ditchLightsAi$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map((au): [boolean, boolean] => {
            const ditchOn = au.direction === SensedDirection.Forward;
            return [ditchOn, ditchOn];
        })
    );
    const ditchLights$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.map((_): [boolean, boolean] => [false, false]),
        frp.merge(ditchLightsPlayer$),
        frp.merge(ditchLightsAi$)
    );
    ditchLights$(([l, r]) => {
        const [left, right] = ditchLights;
        left.setOnOff(l);
        right.setOnOff(r);
    });
    const ditchNodeLeft$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => {
            const [light] = ditchLights;
            return light.getIntensity() > 0.5;
        }),
        xt.rejectRepeats()
    );
    const ditchNodeRight$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => {
            const [, light] = ditchLights;
            return light.getIntensity() > 0.5;
        }),
        xt.rejectRepeats()
    );
    ditchNodeLeft$(on => {
        me.rv.ActivateNode("ditch_left", on);
    });
    ditchNodeRight$(on => {
        me.rv.ActivateNode("ditch_right", on);
    });

    // Strobe lights
    const strobeLights = [new rw.Light("Strobe_L"), new rw.Light("Strobe_R")];
    const strobeLightsSetting = frp.liftN(
        (cv, controlsSettled) => {
            if (!controlsSettled) {
                return StrobeLights.Off;
            } else if (cv < 0.5) {
                return StrobeLights.Off;
            } else if (cv < 1.5) {
                return StrobeLights.ManualOn;
            } else {
                return StrobeLights.AutoBell;
            }
        },
        () => me.rv.GetControlValue("StrobeLights") as number,
        me.areControlsSettled
    );
    const strobeLightsBell = frp.stepper(
        frp.compose(
            me.createPlayerWithKeyUpdateStream(),
            fx.eventStopwatchS(
                frp.compose(
                    me.createPlayerWithKeyUpdateStream(),
                    me.mapGetCvStream("VirtualBell"),
                    frp.filter(v => v > 0.5),
                    frp.filter(_ => frp.snapshot(strobeLightsSetting) === StrobeLights.AutoBell)
                )
            ),
            frp.map(t => t !== undefined && t < strobeLightBellS)
        ),
        false
    );
    const strobeLights$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        fx.behaviorStopwatchS(
            frp.liftN(
                (setting, bell) => setting === StrobeLights.ManualOn || bell,
                strobeLightsSetting,
                strobeLightsBell
            )
        ),
        frp.map((elapsedS): [boolean, boolean] => {
            if (elapsedS === undefined) {
                return [false, false];
            } else {
                const t = elapsedS % strobeLightCycleS;
                if (t < strobeLightFlashS) {
                    return [true, false];
                } else if (t > 2 * strobeLightFlashS && t < 3 * strobeLightFlashS) {
                    return [false, true];
                } else {
                    return [false, false];
                }
            }
        }),
        frp.merge(
            frp.compose(
                me.createPlayerWithoutKeyUpdateStream(),
                frp.merge(me.createAiUpdateStream()),
                frp.map((_): [boolean, boolean] => [false, false])
            )
        ),
        frp.hub()
    );
    const strobeLightLeft$ = frp.compose(
        strobeLights$,
        frp.map(([left]) => left),
        xt.rejectRepeats()
    );
    const strobeLightRight$ = frp.compose(
        strobeLights$,
        frp.map(([, right]) => right),
        xt.rejectRepeats()
    );
    strobeLightLeft$(on => {
        const [light] = strobeLights;
        light.Activate(on);
        me.rv.ActivateNode("strobe_L_on", on);
        me.rv.ActivateNode("strobe_L_off", !on);
    });
    strobeLightRight$(on => {
        const [, light] = strobeLights;
        light.Activate(on);
        me.rv.ActivateNode("strobe_R_on", on);
        me.rv.ActivateNode("strobe_R_off", !on);
    });
    // The control defaults to "manual" for some reason.
    const strobeLightsDefault$ = frp.compose(
        me.createFirstUpdateAfterControlsSettledStream(),
        frp.filter(resumeFromSave => !resumeFromSave),
        frp.map(_ => 2)
    );
    strobeLightsDefault$(v => {
        me.rv.SetControlValue("StrobeLights", v);
    });

    // Horn rings the bell.
    const virtualBellControl$ = frp.compose(
        me.createOnCvChangeStreamFor("VirtualHorn"),
        frp.filter(v => v === 1),
        me.mapAutoBellStream(true)
    );
    virtualBellControl$(v => {
        me.rv.SetControlValue("VirtualBell", v);
    });
    const bellControl$ = frp.compose(me.createPlayerWithKeyUpdateStream(), me.mapGetCvStream("VirtualBell"));
    bellControl$(v => {
        me.rv.SetControlValue("Bell", v);
    });

    // Head-end power
    const hepLights: rw.Light[] = [];
    for (let i = 0; i < 8; i++) {
        hepLights.push(new rw.Light(`Carriage Light ${i + 1}`));
    }
    const hep$ = frp.compose(
        ps.createHepStream(me, () => (me.rv.GetControlValue("HEP") as number) > 0.5),
        xt.rejectRepeats()
    );
    hep$(on => {
        hepLights.forEach(light => light.Activate(on));
        me.rv.ActivateNode("1_1000_LitInteriorLights", on);
        me.rv.SetControlValue("HEP_State", on ? 1 : 0);
    });
    njt.createHepPopup(me);

    // Link the various virtual controls.
    const reverserControl$ = me.createOnCvChangeStreamFor("UserVirtualReverser");
    reverserControl$(v => {
        me.rv.SetControlValue("Reverser", v);
    });
    const hornControl$ = me.createOnCvChangeStreamFor("VirtualHorn");
    hornControl$(v => {
        me.rv.SetControlValue("Horn", v);
    });
    const startupControl$ = me.createOnCvChangeStreamFor("VirtualStartup");
    startupControl$(v => {
        me.rv.SetControlValue("Startup", v);
    });
    const sanderControl$ = me.createOnCvChangeStreamFor("VirtualSander");
    sanderControl$(v => {
        me.rv.SetControlValue("Sander", v);
    });
    const eBrakeControl$ = me.createOnCvChangeStreamFor("VirtualEmergencyBrake");
    eBrakeControl$(v => {
        me.rv.SetControlValue("EmergencyBrake", v);
    });

    // Link the control desk switches.
    const setHeadlights$ = frp.compose(
        me.createOnCvChangeStreamFor("HeadlightSwitch"),
        frp.map(v => {
            switch (v) {
                case 0:
                    return 0;
                case 1:
                    return 2;
                case 2:
                    return 3;
                default:
                    return undefined;
            }
        }),
        xt.rejectUndefined()
    );
    const moveHeadlightSwitch$ = frp.compose(
        me.createOnCvChangeStreamFor("Headlights"),
        frp.map(v => {
            switch (v) {
                case 0:
                    return 0;
                case 2:
                    return 1;
                case 3:
                    return 2;
                default:
                    return undefined;
            }
        }),
        xt.rejectUndefined()
    );
    setHeadlights$(v => {
        me.rv.SetControlValue("Headlights", v);
    });
    moveHeadlightSwitch$(v => {
        me.rv.SetControlTargetValue("HeadlightSwitch", v);
    });
    const setDitchLights$ = frp.compose(
        me.createOnCvChangeStreamFor("DitchLightSwitch"),
        frp.map(v => {
            switch (v) {
                case 0:
                    return 0;
                case 1:
                    return 1;
                default:
                    return undefined;
            }
        }),
        xt.rejectUndefined()
    );
    const moveDitchLightSwitch$ = frp.compose(
        me.createOnCvChangeStreamFor("DitchLights"),
        frp.map(v => {
            switch (v) {
                case 0:
                    return 0;
                case 1:
                    return 1;
                default:
                    return undefined;
            }
        }),
        xt.rejectUndefined()
    );
    setDitchLights$(v => {
        me.rv.SetControlValue("DitchLights", v);
    });
    moveDitchLightSwitch$(v => {
        me.rv.SetControlTargetValue("DitchLightSwitch", v);
    });
    const setPantograph$ = frp.compose(
        me.createOnCvChangeStreamFor("PantographSwitch"),
        frp.map(v => {
            switch (v) {
                case -1:
                    return 0;
                case 1:
                    return 1;
                default:
                    return undefined;
            }
        }),
        xt.rejectUndefined()
    );
    setPantograph$(v => {
        me.rv.SetControlValue("VirtualPantographControl", v);
        me.rv.SetControlTargetValue("PantographSwitch", 0);
    });
    const setWipers$ = me.createOnCvChangeStreamFor("WiperSwitch");
    const moveWipersSwitch$ = me.createOnCvChangeStreamFor("Wipers");
    setWipers$(v => {
        me.rv.SetControlValue("Wipers", v);
    });
    moveWipersSwitch$(v => {
        me.rv.SetControlTargetValue("WiperSwitch", v);
    });

    // Process OnControlValueChange events.
    const onCvChange$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.reject(([name]) => name === "VirtualBell")
    );
    onCvChange$(([name, value]) => {
        me.rv.SetControlValue(name, value);
    });

    // Set consist brake lights.
    const brakesAppliedLight$ = frp.compose(
        fx.createBrakeLightStreamForEngine(me, () => (me.rv.GetControlValue("TrainBrakeControl") as number) > 0),
        xt.rejectRepeats()
    );
    brakesAppliedLight$(on => {
        me.rv.ActivateNode("LightsGreen", !on);
        me.rv.ActivateNode("LightsYellow", on);
    });
    const handBrakeLight$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("HandBrake") as number) > 0),
        xt.rejectRepeats()
    );
    handBrakeLight$(on => {
        me.rv.ActivateNode("LightsBlue", on);
    });
    const doorsOpenLight$ = frp.compose(me.createUpdateStream(), xt.mapBehavior(areDoorsOpen), xt.rejectRepeats());
    doorsOpenLight$(on => {
        me.rv.ActivateNode("LightsRed", on);
    });

    // Sync exterior animations.
    const leftWindow$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => me.rv.GetControlValue("WindowLeft") as number),
        xt.rejectRepeats()
    );
    leftWindow$(pos => {
        me.rv.SetTime("WindowLeft", pos);
    });
    const rightWindow$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => me.rv.GetControlValue("WindowRight") as number),
        xt.rejectRepeats()
    );
    rightWindow$(pos => {
        me.rv.SetTime("WindowRight", pos);
    });
    const driverDoor$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => me.rv.GetControlValue("DriverDoor") as number),
        xt.rejectRepeats()
    );
    driverDoor$(pos => {
        me.rv.SetTime("DriverDoor", pos);
    });

    // These "marker lights" are just regular headlights that are completely
    // inappropriate for the task.
    const markerLights = [new rw.Light("MarkerLight1"), new rw.Light("MarkerLight2")];
    const disableMarkerLights$ = frp.compose(me.createUpdateStream(), xt.once());
    disableMarkerLights$(() => {
        markerLights.forEach(l => l.Activate(false));
    });

    // Set platform door height.
    fx.createLowPlatformStreamForEngine(me);

    // Destination signs
    njt.createDestinationSignSelector(me);

    // Set in-cab vehicle number.
    readRvNumber();

    // Enable updates.
    me.e.BeginUpdate();
});
me.setup();

function readRvNumber() {
    const [, , unit] = string.find(me.rv.GetRVNumber(), "(%d+)");
    if (unit !== undefined) {
        const [[tt, h, t, u]] = m.digits(tonumber(unit) as number, 4);
        me.rv.SetControlValue("UN_thousands", tt);
        me.rv.SetControlValue("UN_hundreds", h);
        me.rv.SetControlValue("UN_tens", t);
        me.rv.SetControlValue("UN_units", u);
    }
}
