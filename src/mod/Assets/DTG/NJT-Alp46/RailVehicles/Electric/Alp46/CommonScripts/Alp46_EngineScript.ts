/**
 * NJ Transit Bombardier ALP-46
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine, PlayerLocation } from "lib/frp-engine";
import { mapBehavior, rejectRepeats, rejectUndefined } from "lib/frp-extra";
import { SensedDirection, VehicleCamera } from "lib/frp-vehicle";
import * as m from "lib/math";
import * as njt from "lib/nec/nj-transit";
import * as adu from "lib/nec/njt-adu";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

const ditchLightsFadeS = 0.3;
const wipeTimeS = 1.5;
const intWipeTimeS = 3;

const me = new FrpEngine(() => {
    const playerLocation = me.createPlayerLocationBehavior();
    const playerCamera = frp.stepper(me.createOnCameraStream(), VehicleCamera.Outside);

    // Electric power supply
    const electrification = ps.createElectrificationBehaviorWithLua(me, ps.Electrification.Overhead);
    const isPowerAvailable = () => ps.uniModeEngineHasPower(ps.EngineMode.Overhead, electrification);

    // Safety systems cut in/out
    // ATC and ACSES controls are reversed for NJT DLC.
    const atcCutIn = () => !((me.rv.GetControlValue("ACSES", 0) as number) > 0.5);
    const acsesCutIn = () => !((me.rv.GetControlValue("ATC", 0) as number) > 0.5);
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("VirtualBrake", 0) as number) > 0.5;
    const aSpeedoMph = () => Math.abs(me.rv.GetControlValue("SpeedometerMPH", 0) as number);
    const [aduState$, aduEvents$] = adu.create(me, acknowledge, suppression, atcCutIn, acsesCutIn, 100 * c.mph.toMps, [
        "ACSES_SpeedSignal",
        0,
    ]);
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(state => {
        const [[h, t, u], guide] = m.digits(Math.round(frp.snapshot(aSpeedoMph)), 3);
        me.rv.SetControlValue("SpeedH", 0, state.clearAspect ? h : -1);
        me.rv.SetControlValue("SpeedT", 0, state.clearAspect ? t : -1);
        me.rv.SetControlValue("SpeedU", 0, state.clearAspect ? u : -1);
        me.rv.SetControlValue("Speed2H", 0, !state.clearAspect ? h : -1);
        me.rv.SetControlValue("Speed2T", 0, !state.clearAspect ? t : -1);
        me.rv.SetControlValue("Speed2U", 0, !state.clearAspect ? u : -1);
        me.rv.SetControlValue("SpeedP", 0, guide);

        me.rv.SetControlValue("ACSES_SpeedGreen", 0, state.masSpeedMph ?? 0);
        me.rv.SetControlValue("ACSES_SpeedRed", 0, state.excessSpeedMph ?? 0);
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterReset$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.filter(([name]) => name === "ThrottleAndBrake" || name === "VirtualBrake")
    );
    const alerterState = frp.stepper(ale.create(me, acknowledge, alerterReset$, alerterCutIn), undefined);
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
        mapBehavior(
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
    alarmsUpdate$(cvs => {
        me.rv.SetControlValue("AWSWarnCount", 0, cvs.awsWarnCount ? 1 : 0);
        me.rv.SetControlValue("ACSES_Alert", 0, cvs.acsesAlert ? 1 : 0);
        me.rv.SetControlValue("ACSES_AlertIncrease", 0, cvs.acsesIncrease ? 1 : 0);
        me.rv.SetControlValue("ACSES_AlertDecrease", 0, cvs.acsesDecrease ? 1 : 0);
    });

    // Throttle, dynamic brake, and air brake controls
    const pantographUp = () => (me.rv.GetControlValue("VirtualPantographControl", 0) as number) > 0.5;
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
    const throttle$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (isPenaltyBrake, isPowerAvailable, input) => (isPenaltyBrake || !isPowerAvailable ? 0 : input),
                isPenaltyBrake,
                isPowerAvailable,
                () => Math.max(me.rv.GetControlValue("ThrottleAndBrake", 0) as number, 0)
            )
        )
    );
    throttle$(v => {
        me.rv.SetControlValue("Regulator", 0, v);
    });
    const airBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (isPenaltyBrake, input) => (isPenaltyBrake ? 0.6 : input),
                isPenaltyBrake,
                () => me.rv.GetControlValue("VirtualBrake", 0) as number
            )
        )
    );
    airBrake$(v => {
        me.rv.SetControlValue("TrainBrakeControl", 0, v);
    });
    // DTG's "blended braking" algorithm
    const dynamicBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (bpPsi, input) => {
                    const blended = Math.min((110 - bpPsi) / 16, 1);
                    return Math.max(blended, input);
                },
                () => me.rv.GetControlValue("AirBrakePipePressurePSI", 0) as number,
                () => -Math.min(me.rv.GetControlValue("ThrottleAndBrake", 0) as number, 0)
            )
        )
    );
    dynamicBrake$(v => {
        me.rv.SetControlValue("DynamicBrake", 0, v);
    });

    // Cab lights
    const cabLightsNonPlayer$ = frp.compose(
        me.createAiUpdateStream(),
        frp.merge(me.createPlayerWithoutKeyUpdateStream()),
        frp.map(_ => false)
    );
    const domeLightsFront = [new rw.Light("ScreenLight"), new rw.Light("CabLight1"), new rw.Light("CabLight2")];
    const domeLightsRear = [new rw.Light("CabLight3"), new rw.Light("CabLight4")];
    const domeLightOn = () => (me.rv.GetControlValue("CabLight", 0) as number) > 0.5;
    const domeLightFront$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN((location, on) => location === PlayerLocation.InFrontCab && on, playerLocation, domeLightOn)
        ),
        frp.merge(cabLightsNonPlayer$),
        rejectRepeats()
    );
    const domeLightRear$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN((location, on) => location === PlayerLocation.InRearCab && on, playerLocation, domeLightOn)
        ),
        frp.merge(cabLightsNonPlayer$),
        rejectRepeats()
    );
    domeLightFront$(on => {
        domeLightsFront.forEach(light => light.Activate(on));
    });
    domeLightRear$(on => {
        domeLightsRear.forEach(light => light.Activate(on));
    });
    // Gauge lights
    const instrumentLightsFront = [
        new rw.Light("FDialLight01"),
        new rw.Light("FDialLight02"),
        new rw.Light("FDialLight03"),
        new rw.Light("FDialLight04"),
        new rw.Light("FBDialLight01"),
        new rw.Light("FBDialLight02"),
        new rw.Light("FBDialLight03"),
        new rw.Light("FBDialLight04"),
    ];
    const instrumentLightsRear = [
        new rw.Light("RDialLight01"),
        new rw.Light("RDialLight02"),
        new rw.Light("RDialLight03"),
        new rw.Light("RDialLight04"),
        new rw.Light("RBDialLight01"),
        new rw.Light("RBDialLight02"),
        new rw.Light("RBDialLight03"),
        new rw.Light("RBDialLight04"),
    ];
    const instrumentLightsOn = () => (me.rv.GetControlValue("InstrumentLights", 0) as number) > 0.5;
    const instrumentLightsFront$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN((camera, on) => camera === VehicleCamera.FrontCab && on, playerCamera, instrumentLightsOn)
        ),
        frp.merge(cabLightsNonPlayer$),
        rejectRepeats()
    );
    const instrumentLightsRear$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN((camera, on) => camera === VehicleCamera.RearCab && on, playerCamera, instrumentLightsOn)
        ),
        frp.merge(cabLightsNonPlayer$),
        rejectRepeats()
    );
    instrumentLightsFront$(on => {
        instrumentLightsFront.forEach(light => light.Activate(on));
    });
    instrumentLightsRear$(on => {
        instrumentLightsRear.forEach(light => light.Activate(on));
    });

    // Ditch lights
    const ditchLightsFront = [
        new fx.FadeableLight(me, ditchLightsFadeS, "ForwardDitch1"),
        new fx.FadeableLight(me, ditchLightsFadeS, "ForwardDitch2"),
    ];
    const ditchLightsRear = [
        new fx.FadeableLight(me, ditchLightsFadeS, "BackwardDitch1"),
        new fx.FadeableLight(me, ditchLightsFadeS, "BackwardDitch2"),
    ];
    const areHeadLightsOn = () => {
        const cv = me.rv.GetControlValue("Headlights", 0) as number;
        return cv > 0.5 && cv < 1.5;
    };
    const areDitchLightsOn = frp.liftN(
        (headLights, cv) => headLights && cv > 0.5,
        areHeadLightsOn,
        () => me.rv.GetControlValue("DitchLights", 0) as number
    );
    const ditchLightsHelper$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.map(_ => false)
    );
    const ditchLightsFront$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN((on, location) => on && location === PlayerLocation.InFrontCab, areDitchLightsOn, playerLocation)
        ),
        frp.merge(ditchLightsHelper$),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.map(au => {
                    const [frontCoupled] = au.couplings;
                    return !frontCoupled && au.direction === SensedDirection.Forward;
                })
            )
        ),
        rejectRepeats()
    );
    const ditchLightsRear$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN((on, location) => on && location === PlayerLocation.InRearCab, areDitchLightsOn, playerLocation)
        ),
        frp.merge(ditchLightsHelper$),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.map(au => {
                    const [, rearCoupled] = au.couplings;
                    return !rearCoupled && au.direction === SensedDirection.Backward;
                })
            )
        ),
        rejectRepeats()
    );
    ditchLightsFront$(on => {
        ditchLightsFront.forEach(light => light.setOnOff(on));
    });
    ditchLightsRear$(on => {
        ditchLightsRear.forEach(light => light.setOnOff(on));
    });
    const ditchNodesFront$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => {
            const [light] = ditchLightsFront;
            return light.getIntensity() > 0.5;
        }),
        rejectRepeats()
    );
    const ditchNodesRear$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => {
            const [light] = ditchLightsRear;
            return light.getIntensity() > 0.5;
        }),
        rejectRepeats()
    );
    ditchNodesFront$(on => {
        me.rv.ActivateNode("FrontDitchLights", on);
    });
    ditchNodesRear$(on => {
        me.rv.ActivateNode("RearDitchLights", on);
    });

    // Pantograph animation
    const pantographAnims = [new fx.Animation(me, "Pantograph1", 2), new fx.Animation(me, "Pantograph2", 2)];
    const raisePantographs$ = frp.compose(
        me.createPlayerUpdateStream(),
        mapBehavior(
            frp.liftN(
                (location, up): [boolean, boolean] => {
                    if (!up) {
                        return [false, false];
                    } else {
                        const reversed = location === PlayerLocation.InRearCab;
                        return [reversed, !reversed];
                    }
                },
                playerLocation,
                pantographUp
            )
        ),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.map((au): [boolean, boolean] => {
                    switch (au.direction) {
                        case SensedDirection.Forward:
                            return [false, true];
                        case SensedDirection.Backward:
                            return [true, false];
                        case SensedDirection.None:
                            return [false, false];
                    }
                })
            )
        )
    );
    raisePantographs$(([frontUp, rearUp]) => {
        const [frontAnim, rearAnim] = pantographAnims;
        frontAnim.setTargetPosition(frontUp ? 1 : 0);
        rearAnim.setTargetPosition(rearUp ? 1 : 0);
    });

    // Horn rings the bell.
    const virtualBellControl$ = frp.compose(
        me.createOnCvChangeStreamFor("VirtualHorn", 0),
        frp.filter(v => v === 1),
        me.mapAutoBellStream(true),
        frp.hub()
    );
    virtualBellControl$(v => {
        me.rv.SetControlValue("VirtualBell", 0, v);
    });
    const bellControl$ = frp.compose(me.createPlayerWithKeyUpdateStream(), me.mapGetCvStream("VirtualBell", 0));
    bellControl$(v => {
        me.rv.SetControlValue("Bell", 0, v);
    });
    // Sync the bell control with the cockpit switch.
    const setVirtualBell$ = me.createOnCvChangeStreamFor("BellSwitch", 0);
    setVirtualBell$(v => {
        me.rv.SetControlValue("VirtualBell", 0, v);
    });
    virtualBellControl$(v => {
        me.rv.SetControlTargetValue("BellSwitch", 0, v);
    });

    // Wiper controls, including intermittent mode
    const wipersOn = () => (me.rv.GetControlValue("VirtualWipers", 0) as number) > 0.5;
    const wipersInt = () => (me.rv.GetControlValue("WipersInt", 0) as number) > 0.5;
    const wiperBlades$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        // Positive times for a fast wipe cycle, negative times for a slow one.
        frp.fold((cycleS: number, pu) => {
            if (cycleS < 0) {
                return cycleS < -intWipeTimeS ? 0 : cycleS - pu.dt;
            } else if (cycleS > 0) {
                return cycleS > wipeTimeS ? 0 : cycleS + pu.dt;
            } else {
                if (frp.snapshot(wipersOn)) {
                    return frp.snapshot(wipersInt) ? -pu.dt : pu.dt;
                } else {
                    return 0;
                }
            }
        }, 0),
        frp.map(cycleS => {
            const wipePct = Math.min(Math.abs(cycleS) / wipeTimeS, 1);
            const bladePos = (wipePct >= 0.5 ? 1 - wipePct : wipePct) * 2;
            return bladePos;
        }),
        frp.hub()
    );
    wiperBlades$(pos => {
        me.rv.SetControlValue("WipersInterior", 0, pos);
    });
    const wiperBladesFront$ = frp.compose(
        wiperBlades$,
        frp.map(pos => (frp.snapshot(playerLocation) === PlayerLocation.InFrontCab ? pos : 0)),
        frp.map(pos => pos / 2),
        rejectRepeats()
    );
    const wiperBladesRear$ = frp.compose(
        wiperBlades$,
        frp.map(pos => (frp.snapshot(playerLocation) === PlayerLocation.InRearCab ? pos : 0)),
        frp.map(pos => pos / 2),
        rejectRepeats()
    );
    wiperBladesFront$(t => {
        me.rv.SetTime("WipersFront", t);
    });
    wiperBladesRear$(t => {
        me.rv.SetTime("WipersRear", t);
    });

    // Head-end power
    const hep$ = ps.createHepStream(me, () => (me.rv.GetControlValue("HEP", 0) as number) > 0.5);
    hep$(on => {
        me.rv.SetControlValue("HEP_State", 0, on ? 1 : 0);
    });
    njt.createHepPopup(me);

    // Step lights
    const stepLights = [
        new rw.Light("StepLight1"),
        new rw.Light("StepLight2"),
        new rw.Light("StepLight3"),
        new rw.Light("StepLight4"),
    ];
    const stepLights$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.merge(me.createAiUpdateStream()),
        frp.map(_ => false),
        frp.merge(
            frp.compose(
                me.createPlayerWithKeyUpdateStream(),
                me.mapGetCvStream("StepLights", 0),
                frp.map(v => v > 0.5)
            )
        ),
        rejectRepeats()
    );
    stepLights$(on => {
        stepLights.forEach(light => light.Activate(on));
    });

    // Window opening sounds
    const windowOpen$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (left, right) => Math.max(left, right),
                () => me.rv.GetControlValue("WindowLeft", 0) as number,
                () => me.rv.GetControlValue("WindowRight", 0) as number
            )
        )
    );
    windowOpen$(v => {
        me.rv.SetControlValue("ExteriorSounds", 0, v);
    });

    // Link the various virtual controls.
    const hornControl$ = me.createOnCvChangeStreamFor("VirtualHorn", 0);
    hornControl$(v => {
        me.rv.SetControlValue("Horn", 0, v);
    });
    const startupControl$ = me.createOnCvChangeStreamFor("VirtualStartup", 0);
    startupControl$(v => {
        me.rv.SetControlValue("Startup", 0, v);
    });
    const sanderControl$ = me.createOnCvChangeStreamFor("VirtualSander", 0);
    sanderControl$(v => {
        me.rv.SetControlValue("Sander", 0, v);
    });
    const locoBrakeControl$ = me.createOnCvChangeStreamFor("VirtualEngineBrakeControl", 0);
    locoBrakeControl$(v => {
        me.rv.SetControlValue("EngineBrakeControl", 0, v);
    });
    const eBrakeControl$ = me.createOnCvChangeStreamFor("VirtualEmergencyBrake", 0);
    eBrakeControl$(v => {
        me.rv.SetControlValue("EmergencyBrake", 0, v);
    });

    // Link the control desk switches.
    const setHeadlights$ = frp.compose(
        me.createOnCvChangeStreamFor("HeadlightSwitch", 0),
        frp.map(v => {
            switch (v) {
                case -1:
                    return 2;
                case 0:
                    return 0;
                case 1:
                    return 1;
                default:
                    return undefined;
            }
        }),
        rejectUndefined()
    );
    const moveHeadlightSwitch$ = frp.compose(
        me.createOnCvChangeStreamFor("Headlights", 0),
        frp.map(v => {
            switch (v) {
                case 0:
                    return 0;
                case 1:
                    return 1;
                case 2:
                    return -1;
                default:
                    return undefined;
            }
        }),
        rejectUndefined()
    );
    setHeadlights$(v => {
        me.rv.SetControlValue("Headlights", 0, v);
    });
    moveHeadlightSwitch$(v => {
        me.rv.SetControlTargetValue("HeadlightSwitch", 0, v);
    });
    const moveWipersSwitch$ = frp.compose(
        me.createOnCvChangeStreamFor("VirtualWipers", 0),
        frp.merge(me.createOnCvChangeStreamFor("WipersInt", 0)),
        frp.filter(v => v === 0 || v === 1),
        mapBehavior(
            frp.liftN(
                (wipersOn, wipersInt) => {
                    if (wipersOn) {
                        return wipersInt ? 0 : 1;
                    } else {
                        return -1;
                    }
                },
                wipersOn,
                wipersInt
            )
        )
    );
    moveWipersSwitch$(v => {
        me.rv.SetControlTargetValue("WipersSwitch", 0, v);
    });
    const setPantograph$ = frp.compose(
        me.createOnCvChangeStreamFor("PantographSwitch", 0),
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
        rejectUndefined()
    );
    setPantograph$(v => {
        me.rv.SetControlValue("VirtualPantographControl", 0, v);
        me.rv.SetControlTargetValue("PantographSwitch", 0, 0);
    });
    const setHandBrake$ = frp.compose(
        me.createOnCvChangeStreamFor("HandBrakeSwitch", 0),
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
        rejectUndefined()
    );
    setHandBrake$(v => {
        me.rv.SetControlValue("HandBrake", 0, v);
        me.rv.SetControlTargetValue("HandBrakeSwitch", 0, 0);
    });
    const moveDitchLightsSwitch$ = me.createOnCvChangeStreamFor("DitchLights", 0);
    const setDitchLights$ = me.createOnCvChangeStreamFor("DitchLightsSwitch", 0);
    moveDitchLightsSwitch$(v => {
        me.rv.SetControlTargetValue("DitchLightsSwitch", 0, v);
    });
    setDitchLights$(v => {
        me.rv.SetControlValue("DitchLights", 0, v);
    });
    const moveCabLightSwitch$ = me.createOnCvChangeStreamFor("CabLight", 0);
    const setCabLight$ = me.createOnCvChangeStreamFor("CabLightSwitch", 0);
    moveCabLightSwitch$(v => {
        me.rv.SetControlTargetValue("CabLightSwitch", 0, v);
    });
    setCabLight$(v => {
        me.rv.SetControlValue("CabLight", 0, v);
    });
    const moveInstrumentLightsSwitch$ = me.createOnCvChangeStreamFor("InstrumentLights", 0);
    const setInstrumentLights$ = me.createOnCvChangeStreamFor("InstrumentLightsSwitch", 0);
    moveInstrumentLightsSwitch$(v => {
        me.rv.SetControlTargetValue("InstrumentLightsSwitch", 0, v);
    });
    setInstrumentLights$(v => {
        me.rv.SetControlValue("InstrumentLights", 0, v);
    });

    // Process OnControlValueChange events.
    const onCvChange$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.reject(([name]) => name === "VirtualBell")
    );
    onCvChange$(([name, index, value]) => {
        me.rv.SetControlValue(name, index, value);
    });

    // Set consist brake lights.
    const brakesAppliedLight$ = frp.compose(
        fx.createBrakeLightStreamForEngine(me, () => (me.rv.GetControlValue("TrainBrakeControl", 0) as number) > 0),
        rejectRepeats()
    );
    brakesAppliedLight$(on => {
        me.rv.ActivateNode("LightsGreen", !on);
        me.rv.ActivateNode("LightsYellow", on);
    });
    const handBrakeLight$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("HandBrake", 0) as number) > 0),
        rejectRepeats()
    );
    handBrakeLight$(on => {
        me.rv.ActivateNode("LightsBlue", on);
    });

    // Set platform door height.
    fx.setLowPlatformDoorsForEngine(me, false);

    // Miscellaneous NJT features
    njt.createDestinationSignSelector(me);
    njt.createManualDoorsPopup(me);

    // Set in-cab vehicle number.
    readRvNumber();

    // Enable updates.
    me.e.BeginUpdate();
});
me.setup();

function readRvNumber() {
    const [, , unit] = string.find(me.rv.GetRVNumber(), "(%d+)");
    if (unit !== undefined) {
        const [[t, u]] = m.digits(tonumber(unit) as number, 2);
        me.rv.SetControlValue("UnitT", 0, t);
        me.rv.SetControlValue("UnitU", 0, u);
    }
}
