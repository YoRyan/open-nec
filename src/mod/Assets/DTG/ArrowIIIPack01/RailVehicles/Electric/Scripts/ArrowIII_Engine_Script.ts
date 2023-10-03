/**
 * NJ Transit GE Arrow III
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { mapBehavior, rejectRepeats } from "lib/frp-extra";
import { SensedDirection } from "lib/frp-vehicle";
import * as adu from "lib/nec/njt-adu";
import * as m from "lib/math";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

enum DirectionLockout {
    Forward = "f",
    Unlocked = "n",
    Reverse = "r",
}

enum HeadLights {
    Off,
    Dim,
    Bright,
}

const headLightsFadeS = 0.3;
const mcLockoutThreshold = 0.1;
// Match the ramp time present in stock physics.
const throttleRampS = 5;

const me = new FrpEngine(() => {
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
    const suppression = () => (me.rv.GetControlValue("VirtualBrake", 0) as number) >= 0.5;
    const aSpeedoMph = () => Math.abs(me.rv.GetControlValue("SpeedometerMPH", 0) as number);
    const [aduState$, aduEvents$] = adu.create({
        e: me,
        acknowledge,
        suppression,
        atcCutIn,
        acsesCutIn,
        equipmentSpeedMps: 80 * c.mph.toMps,
        pulseCodeControlValue: ["ACSES_SpeedSignal", 0],
    });
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

        // The green speed zone behaves like a speedometer, so use the red zone
        // to show MAS.
        me.rv.SetControlValue("ACSES_SpeedRed", 0, state.masSpeedMph ?? 0);

        me.rv.SetControlValue("ATC_Node", 0, state.atcLamp ? 1 : 0);
        me.rv.SetControlValue("ACSES_Node", 0, state.acsesLamp ? 1 : 0);
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterReset$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.filter(([name]) => name === "VirtualThrottle" || name === "VirtualBrake")
    );
    const alerterState = frp.stepper(
        ale.create({ e: me, acknowledge, acknowledgeStream: alerterReset$, cutIn: alerterCutIn }),
        undefined
    );
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

    // Directional lockout for the master controller
    const isStopped = () => Math.abs(me.rv.GetSpeed()) < c.stopSpeed;
    const masterControllerLockout$ = frp.compose(
        me.createGetCvAndOnCvChangeStreamFor("VirtualThrottle", 0),
        frp.merge(
            frp.compose(
                me.createOnResumeStream(),
                frp.map(() => {
                    const trueMps = me.rv.GetSpeed();
                    if (trueMps < -c.stopSpeed) {
                        return DirectionLockout.Reverse;
                    } else if (trueMps > c.stopSpeed) {
                        return DirectionLockout.Forward;
                    } else {
                        return DirectionLockout.Unlocked;
                    }
                })
            )
        ),
        frp.fold<[lockout: DirectionLockout, position: number], DirectionLockout | number>(
            ([lockout], input) => {
                // Resume from save
                switch (input) {
                    case DirectionLockout.Forward:
                    case DirectionLockout.Unlocked:
                    case DirectionLockout.Reverse:
                        return [input, 0];
                }

                if (frp.snapshot(isStopped)) {
                    return [DirectionLockout.Unlocked, input];
                } else if (lockout === DirectionLockout.Unlocked) {
                    let next: DirectionLockout;
                    if (input < -0.5) {
                        next = DirectionLockout.Reverse;
                    } else if (input < 0.5) {
                        next = DirectionLockout.Unlocked;
                    } else {
                        next = DirectionLockout.Forward;
                    }
                    return [next, input];
                } else if (lockout === DirectionLockout.Forward) {
                    return [DirectionLockout.Forward, Math.max(input, -mcLockoutThreshold)];
                } else {
                    return [DirectionLockout.Reverse, Math.min(input, mcLockoutThreshold)];
                }
            },
            [DirectionLockout.Unlocked, 0]
        ),
        frp.map(([, position]) => position)
    );
    masterControllerLockout$(v => {
        me.rv.SetControlValue("VirtualThrottle", 0, v);
    });

    // Throttle, dynamic brake, and air brake controls
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
    const masterController = () => me.rv.GetControlValue("VirtualThrottle", 0) as number;
    const throttle = frp.liftN(
        (isPenaltyBrake, isPowerAvailable, mc) => {
            if (isPenaltyBrake || !isPowerAvailable) {
                return 0;
            } else {
                const aMc = Math.abs(mc);
                return aMc < 1.5 ? 0 : (aMc - 1) / 4;
            }
        },
        isPenaltyBrake,
        isPowerAvailable,
        masterController
    );
    const throttle$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.fold((last, pu) => {
            const target = frp.snapshot(throttle);
            if (target > last) {
                return Math.min(last + pu.dt / throttleRampS, target);
            } else if (target < last) {
                return Math.max(last - pu.dt / throttleRampS, target);
            } else {
                return last;
            }
        }, 0)
    );
    throttle$(v => {
        me.rv.SetControlValue("Regulator", 0, v);
    });
    const reverser$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(mc => {
                if (mc < -0.5) {
                    return -1;
                } else if (mc < 0.5) {
                    return 0;
                } else {
                    return 1;
                }
            }, masterController)
        )
    );
    reverser$(v => {
        me.rv.SetControlValue("Reverser", 0, v);
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
                () => me.rv.GetControlValue("VirtualDynamicBrake", 0) as number
            )
        )
    );
    dynamicBrake$(v => {
        me.rv.SetControlValue("DynamicBrake", 0, v);
    });

    // Pantograph control
    const pantographAnim = new fx.Animation(me, "panto", 0.5);
    const pantographUp$ = frp.compose(
        me.createPlayerUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("PantographControl", 0) as number) > 0.5),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.map(au => au.direction !== SensedDirection.None)
            )
        )
    );
    pantographUp$(up => {
        pantographAnim.setTargetPosition(up ? 1 : 0);
    });
    const setPantograph$ = frp.compose(
        me.createOnCvChangeStreamFor("PantoOn", 0),
        frp.filter(v => v === 0 || v === 1)
    );
    const movePantographSwitch$ = frp.compose(
        me.createOnCvChangeStreamFor("PantographControl", 0),
        frp.filter(v => v === 0 || v === 1)
    );
    setPantograph$(v => {
        me.rv.SetControlValue("PantographControl", 0, v);
    });
    movePantographSwitch$(v => {
        me.rv.SetControlTargetValue("PantoOn", 0, v);
    });

    // Headlights and taillights
    const headLightsDim = [
        new fx.FadeableLight(me, headLightsFadeS, "Headlight_Dim_1"),
        new fx.FadeableLight(me, headLightsFadeS, "Headlight_Dim_2"),
    ];
    const headLightsBright = [
        new fx.FadeableLight(me, headLightsFadeS, "Headlight_Bright_1"),
        new fx.FadeableLight(me, headLightsFadeS, "Headlight_Bright_2"),
        new fx.FadeableLight(me, headLightsFadeS, "Ditch_L"),
        new fx.FadeableLight(me, headLightsFadeS, "Ditch_R"),
    ];
    const tailLights = [
        new fx.FadeableLight(me, headLightsFadeS, "MarkerLight_1"),
        new fx.FadeableLight(me, headLightsFadeS, "MarkerLight_2"),
        new fx.FadeableLight(me, headLightsFadeS, "MarkerLight_3"),
    ];
    const headLightsSetting = frp.liftN(
        cv => {
            if (cv < 0.5) {
                return HeadLights.Off;
            } else if (cv < 1.5) {
                return HeadLights.Dim;
            } else {
                return HeadLights.Bright;
            }
        },
        () => me.rv.GetControlValue("Headlights", 0) as number
    );
    const haveDriver = frp.stepper(
        frp.compose(
            me.createFirstUpdateAfterControlsSettledStream(),
            frp.map(_ => (me.rv.GetControlValue("Driver", 0) as number) > 0.5)
        ),
        false
    );
    const showHeadLights$ = frp.compose(
        me.createPlayerUpdateStream(),
        frp.map(pu => {
            const [frontCoupled] = pu.couplings;
            const isHead = !frontCoupled && frp.snapshot(haveDriver);
            return isHead ? frp.snapshot(headLightsSetting) : HeadLights.Off;
        }),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.map(au => {
                    const [frontCoupled] = au.couplings;
                    const isHead = !frontCoupled && au.direction === SensedDirection.Forward;
                    return isHead ? HeadLights.Bright : HeadLights.Off;
                })
            )
        )
    );
    const showTailLights$ = frp.compose(
        me.createPlayerUpdateStream(),
        frp.map(pu => {
            const [frontCoupled] = pu.couplings;
            const isTail = !frontCoupled && !frp.snapshot(haveDriver);
            return isTail && frp.snapshot(headLightsSetting) !== HeadLights.Off;
        }),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.map(au => {
                    const [frontCoupled] = au.couplings;
                    return !frontCoupled && au.direction === SensedDirection.Backward;
                })
            )
        )
    );
    showHeadLights$(show => {
        headLightsDim.forEach(light => light.setOnOff(show === HeadLights.Dim));
        headLightsBright.forEach(light => light.setOnOff(show === HeadLights.Bright));
    });
    showTailLights$(on => {
        tailLights.forEach(light => light.setOnOff(on));
    });
    const headLightsNode$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => {
            const [dim] = headLightsDim;
            const [bright] = headLightsBright;
            return Math.max(dim.getIntensity(), bright.getIntensity()) > 0.5;
        }),
        rejectRepeats()
    );
    const ditchLightsNode$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => {
            const [bright] = headLightsBright;
            return bright.getIntensity() > 0.5;
        }),
        rejectRepeats()
    );
    const tailLightsNode$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => {
            const [tail] = tailLights;
            return tail.getIntensity() > 0.5;
        }),
        rejectRepeats()
    );
    headLightsNode$(on => {
        me.rv.ActivateNode("lighthead", on);
    });
    ditchLightsNode$(on => {
        me.rv.ActivateNode("ditch", on);
    });
    tailLightsNode$(on => {
        me.rv.ActivateNode("lighttail", on);
    });

    // Number lights
    const numberLight$ = frp.compose(
        me.createPlayerUpdateStream(),
        mapBehavior(headLightsSetting),
        frp.map(headLights => headLights !== HeadLights.Off),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.map(au => au.direction !== SensedDirection.None)
            )
        ),
        rejectRepeats()
    );
    numberLight$(on => {
        me.rv.ActivateNode("numbers_lit", on);
    });

    // Cab dome light
    const domeLight = new rw.Light("CabLight");
    const domeLight$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("CabLight", 0),
        frp.map(v => v > 0.9),
        frp.merge(
            frp.compose(
                me.createPlayerWithoutKeyUpdateStream(),
                frp.merge(me.createAiUpdateStream()),
                frp.map(_ => false)
            )
        ),
        rejectRepeats()
    );
    domeLight$(on => {
        domeLight.Activate(on);
    });

    // Step lights
    const stepLights = [
        new rw.Light("StepLight_01"),
        new rw.Light("StepLight_02"),
        new rw.Light("StepLight_03"),
        new rw.Light("StepLight_04"),
    ];
    const stepLight$ = frp.compose(
        me.createPlayerUpdateStream(),
        me.mapGetCvStream("StepsLight", 0),
        frp.map(v => v > 0.5),
        frp.merge(
            frp.compose(
                frp.merge(me.createAiUpdateStream()),
                frp.map(_ => false)
            )
        ),
        rejectRepeats()
    );
    stepLight$(on => {
        stepLights.forEach(light => light.Activate(on));
    });

    // Consist brake and door status lights
    const brakesAppliedLight$ = frp.compose(fx.createBrakeLightStreamForEngine(me), rejectRepeats());
    brakesAppliedLight$(on => {
        me.rv.ActivateNode("st_green", !on);
        me.rv.ActivateNode("st_yellow", on);
    });
    const doorLights$ = frp.compose(
        me.createVehicleUpdateStream(),
        frp.map((vu): [boolean, boolean] => vu.doorsOpen)
    );
    const doorLightLeft$ = frp.compose(
        doorLights$,
        frp.map(([l]) => l),
        rejectRepeats()
    );
    const doorLightRight$ = frp.compose(
        doorLights$,
        frp.map(([, r]) => r),
        rejectRepeats()
    );
    doorLightLeft$(on => {
        me.rv.ActivateNode("left_door_light", on);
    });
    doorLightRight$(on => {
        me.rv.ActivateNode("right_door_light", on);
    });
    // Unknown function
    const hideRedBrakeLight$ = me.createFirstUpdateStream();
    hideRedBrakeLight$(_ => {
        me.rv.ActivateNode("st_red", false);
    });

    // Sync exterior animations.
    const leftCabDoor$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("Left_CabDoor", 0) as number) * 2),
        rejectRepeats()
    );
    const rightCabDoor$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => me.rv.GetControlValue("Right_CabDoor", 0) as number),
        rejectRepeats()
    );
    const cabWindow$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("CabWindow", 0) as number) * 2),
        rejectRepeats()
    );
    leftCabDoor$(t => {
        me.rv.SetTime("left_cabdoor", t);
    });
    rightCabDoor$(t => {
        me.rv.SetTime("right_cabdoor", t);
    });
    cabWindow$(t => {
        me.rv.SetTime("cabwindow", t);
    });

    // Process OnControlValueChange events.
    const onCvChange$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.reject(([name]) => name === "VirtualThrottle")
    );
    onCvChange$(([name, index, value]) => {
        me.rv.SetControlValue(name, index, value);
    });

    // Enable updates.
    me.e.BeginUpdate();
});
me.setup();
