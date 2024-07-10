/**
 * Amtrak Bombardier HHP-8
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine, PlayerLocation } from "lib/frp-engine";
import { mapBehavior, movingAverage, rejectRepeats } from "lib/frp-extra";
import { SensedDirection, VehicleCamera } from "lib/frp-vehicle";
import * as m from "lib/math";
import { AduAspect } from "lib/nec/adu";
import * as cs from "lib/nec/cabsignals";
import * as adu from "lib/nec/twospeed-adu";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

enum PantographSelect {
    Front,
    Both,
    Rear,
}

enum DitchLights {
    Off,
    Fixed,
    Flash,
}

const ditchLightsFadeS = 0.3;
const ditchLightFlashS = 0.5;
const nDisplaySamples = 30;

const me = new FrpEngine(() => {
    const isFanRailer = me.rv.ControlExists("NewVirtualThrottle");
    const playerLocation = me.createPlayerLocationBehavior();
    const playerCamera = frp.stepper(me.createOnCameraStream(), VehicleCamera.Outside);

    // Electric power supply
    const electrification = ps.createElectrificationBehaviorWithLua(me, ps.Electrification.Overhead);
    const isPowerAvailable = () => ps.uniModeEngineHasPower(ps.EngineMode.Overhead, electrification);
    // Pantograph control
    // Note: PantographControl is not transmitted to the rest of the consist,
    // but SelPanto is.
    const pantographsUp = () => (me.rv.GetControlValue("PantographControl") as number) > 0.5;
    const pantographSelect = () => {
        const cv = me.rv.GetControlValue("SelPanto") as number;
        if (cv < 0.5) {
            return PantographSelect.Front;
        } else if (cv < 1.5) {
            return PantographSelect.Both;
        } else {
            return PantographSelect.Rear;
        }
    };
    // The pantograph animations are reversed.
    const pantographAnims = [new fx.Animation(me, "rearPanto", 2), new fx.Animation(me, "frontPanto", 2)];
    const raisePantographs$ = frp.compose(
        me.createPlayerUpdateStream(),
        mapBehavior(
            frp.liftN(
                (location, up, select): [boolean, boolean] => {
                    if (!up) {
                        return [false, false];
                    } else if (select === PantographSelect.Front) {
                        const reversed = location === PlayerLocation.InRearCab;
                        return [!reversed, reversed];
                    } else if (select === PantographSelect.Rear) {
                        const reversed = location === PlayerLocation.InRearCab;
                        return [reversed, !reversed];
                    } else {
                        return [true, true];
                    }
                },
                playerLocation,
                pantographsUp,
                pantographSelect
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
    // Pantograph sparks
    const pantographAnimsAndSparks: [animation: fx.Animation, light: rw.Light, nodes: string[]][] = [
        [pantographAnims[0], new rw.Light("Spark"), ["front_spark01", "front_spark02"]],
        [pantographAnims[1], new rw.Light("Spark2"), ["rear_spark01", "rear_spark02"]],
    ];
    const pantographSpark$ = frp.compose(fx.createPantographSparkStream(me, electrification), frp.hub());
    pantographAnimsAndSparks.forEach(([anim, light, nodes]) => {
        const sparkOnOff$ = frp.compose(
            pantographSpark$,
            frp.map(on => on && anim.getPosition() >= 1),
            rejectRepeats()
        );
        sparkOnOff$(on => {
            light.Activate(on);
            nodes.forEach(node => me.rv.ActivateNode(node, on));
        });
    });
    // In the blueprints, the pantograph select defaults to the front one, which
    // is weird.
    const pantographSelectDefault$ = frp.compose(
        me.createFirstUpdateAfterControlsSettledStream(),
        frp.filter(resumeFromSave => !resumeFromSave),
        frp.map(_ => 2)
    );
    pantographSelectDefault$(v => {
        me.rv.SetControlValue("SelPanto", v);
    });

    // Safety systems cut in/out
    const atcCutIn = () => (me.rv.GetControlValue("ATCCutIn") as number) > 0.5;
    const acsesCutIn = () => (me.rv.GetControlValue("ACSESCutIn") as number) > 0.5;
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("TrainBrakeControl") as number) > 0.3;
    const [aduState$, aduEvents$] = adu.create({
        atc: cs.amtrakAtc,
        e: me,
        acknowledge,
        suppression,
        atcCutIn,
        acsesCutIn,
        equipmentSpeedMps: 125 * c.mph.toMps,
        pulseCodeControlValue: "CurrentAmtrakSignal",
    });
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(({ aspect, aspectFlashOn, trackSpeedMph, atcLamp, acsesLamp }) => {
        me.rv.SetControlValue(
            "SigGreen",
            ((aspect === cs.AmtrakAspect.CabSpeed60 || aspect === cs.AmtrakAspect.CabSpeed80) && aspectFlashOn) ||
                aspect === cs.AmtrakAspect.Clear100 ||
                aspect === cs.AmtrakAspect.Clear125 ||
                aspect === cs.AmtrakAspect.Clear150
                ? 1
                : 0
        );
        me.rv.SetControlValue(
            "SigYellow",
            aspect === cs.AmtrakAspect.Approach ||
                aspect === cs.AmtrakAspect.ApproachMedium ||
                aspect === cs.AmtrakAspect.ApproachLimited
                ? 1
                : 0
        );
        me.rv.SetControlValue("SigRed", aspect === AduAspect.Stop || aspect === cs.AmtrakAspect.Restricting ? 1 : 0);
        me.rv.SetControlValue(
            "SigLowerGreen",
            aspect === cs.AmtrakAspect.ApproachMedium || (aspect === cs.AmtrakAspect.ApproachLimited && aspectFlashOn)
                ? 1
                : 0
        );
        me.rv.SetControlValue("SigLowerGrey", aspect === cs.AmtrakAspect.Restricting ? 1 : 0);
        me.rv.SetControlValue(
            "CabSpeed",
            {
                [AduAspect.Stop]: 0,
                [cs.AmtrakAspect.Restricting]: 20,
                [cs.AmtrakAspect.Approach]: 30,
                [cs.AmtrakAspect.ApproachMedium]: 30,
                [cs.AmtrakAspect.ApproachLimited]: 45,
                [cs.AmtrakAspect.CabSpeed60]: 60,
                [cs.AmtrakAspect.CabSpeed80]: 80,
                [cs.AmtrakAspect.Clear100]: 0,
                [cs.AmtrakAspect.Clear125]: 0,
                [cs.AmtrakAspect.Clear150]: 0,
            }[aspect]
        );

        if (trackSpeedMph !== undefined) {
            const [[h, t, u]] = m.digits(trackSpeedMph, 3);
            me.rv.SetControlValue("TSHundreds", h);
            me.rv.SetControlValue("TSTens", t);
            me.rv.SetControlValue("TSUnits", u);
        } else {
            me.rv.SetControlValue("TSHundreds", -1);
            me.rv.SetControlValue("TSTens", -1);
            me.rv.SetControlValue("TSUnits", -1);
        }

        let lamp: number;
        if (atcLamp) {
            lamp = 0;
        } else if (acsesLamp) {
            lamp = 1;
        } else {
            lamp = -1;
        }
        me.rv.SetControlValue("MinimumSpeed", lamp);
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterReset$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.filter(
            ([name]) =>
                name === (isFanRailer ? "NewVirtualThrottle" : "VirtualThrottle") || name === "TrainBrakeControl"
        )
    );
    const alerterState = frp.stepper(
        ale.create({ e: me, acknowledge, acknowledgeStream: alerterReset$, cutIn: alerterCutIn }),
        undefined
    );
    // Safety system sounds
    const alarmOn$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (aduState, alerterState) =>
                    (aduState?.atcAlarm || aduState?.acsesAlarm || alerterState?.alarm) ?? false,
                aduState,
                alerterState
            )
        )
    );
    alarmOn$(on => {
        me.rv.SetControlValue("AWSWarnCount", on ? 1 : 0);
    });
    const upgradeEvents$ = frp.compose(
        aduEvents$,
        frp.filter(evt => evt === adu.AduEvent.Upgrade)
    );
    const upgradeSound$ = frp.compose(me.createPlayerWithKeyUpdateStream(), fx.triggerSound(1, upgradeEvents$));
    upgradeSound$(play => {
        me.rv.SetControlValue("SpeedIncreaseAlert", play ? 1 : 0);
    });

    // Cruise control
    const cruiseTargetMps = () => {
        const targetMph = (me.rv.GetControlValue("SpeedSetControl") as number) * 10;
        return targetMph * c.mph.toMps;
    };
    const cruiseOn = frp.liftN(
        (targetMps, cruiseOn) => targetMps > 0 && cruiseOn,
        cruiseTargetMps,
        () => (me.rv.GetControlValue("CruiseControl") as number) > 0.5
    );
    const cruiseOutput = frp.stepper(me.createCruiseControlStream(cruiseOn, cruiseTargetMps), 0);

    // Throttle, air brake, and dynamic brake controls
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
    const airBrake = () => me.rv.GetControlValue("TrainBrakeControl") as number;
    // There's no virtual train brake, so just move the braking handle.
    const fullService = 0.6;
    const setPenaltyBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.filter(_ => frp.snapshot(isPenaltyBrake)),
        frp.map(_ => fullService)
    );
    setPenaltyBrake$(v => {
        me.rv.SetControlValue("TrainBrakeControl", v);
    });
    // DTG's "blended braking" algorithm
    const dynamicBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(pu => (pu.speedMps >= 10 ? frp.snapshot(airBrake) * 0.3 : 0))
    );
    dynamicBrake$(v => {
        me.rv.SetControlValue("DynamicBrake", v);
    });
    const throttle = frp.liftN(
        (isPowerAvailable, isPenaltyBrake, airBrake, cruiseOn, cruiseOutput, input) => {
            if (!isPowerAvailable || isPenaltyBrake || airBrake > 0) {
                return 0;
            } else if (cruiseOn) {
                return Math.min(cruiseOutput, input);
            } else {
                return input;
            }
        },
        isPowerAvailable,
        isPenaltyBrake,
        airBrake,
        cruiseOn,
        cruiseOutput,
        () => me.rv.GetControlValue(isFanRailer ? "NewVirtualThrottle" : "VirtualThrottle") as number
    );
    const throttle$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(throttle));
    throttle$(v => {
        me.rv.SetControlValue("Regulator", v);
    });

    // Cab dome light
    const cabLights = [new rw.Light("CabLight"), new rw.Light("CabLight2")];
    const cabLightOn = () => (me.rv.GetControlValue("CabLight") as number) > 0.5;
    const cabLightNonPlayer$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.merge(me.createAiUpdateStream()),
        frp.map(_ => false),
        frp.hub()
    );
    const cabLightFront$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN((location, on) => location === PlayerLocation.InFrontCab && on, playerLocation, cabLightOn)
        ),
        frp.merge(cabLightNonPlayer$),
        rejectRepeats()
    );
    const cabLightRear$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN((location, on) => location === PlayerLocation.InRearCab && on, playerLocation, cabLightOn)
        ),
        frp.merge(cabLightNonPlayer$),
        rejectRepeats()
    );
    cabLightFront$(on => {
        const [light] = cabLights;
        light.Activate(on);
    });
    cabLightRear$(on => {
        const [, light] = cabLights;
        light.Activate(on);
    });

    // Dashboard light
    const dashLights = [new rw.Light("DashLight1"), new rw.Light("DashLight2")];
    const dashLightOn = () => (me.rv.GetControlValue("Dimmer") as number) > 0.9;
    const dashLightFront$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(frp.liftN((camera, on) => camera === VehicleCamera.FrontCab && on, playerCamera, dashLightOn)),
        frp.merge(cabLightNonPlayer$),
        rejectRepeats()
    );
    const dashLightRear$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(frp.liftN((camera, on) => camera === VehicleCamera.RearCab && on, playerCamera, dashLightOn)),
        frp.merge(cabLightNonPlayer$),
        rejectRepeats()
    );
    dashLightFront$(on => {
        const [light] = dashLights;
        light.Activate(on);
    });
    dashLightRear$(on => {
        const [, light] = dashLights;
        light.Activate(on);
    });

    // Horn rings the bell.
    const bellControl$ = frp.compose(
        me.createOnCvChangeStreamFor("Horn"),
        frp.filter(v => v === 1),
        me.mapAutoBellStream()
    );
    bellControl$(v => {
        me.rv.SetControlValue("Bell", v);
    });

    // Ditch lights, front and rear
    const ditchLightsFront = [
        new fx.FadeableLight(me, ditchLightsFadeS, "Fwd_DitchLightLeft"),
        new fx.FadeableLight(me, ditchLightsFadeS, "Fwd_DitchLightRight"),
    ];
    const ditchLightsRear = [
        new fx.FadeableLight(me, ditchLightsFadeS, "Bwd_DitchLightLeft"),
        new fx.FadeableLight(me, ditchLightsFadeS, "Bwd_DitchLightRight"),
    ];
    const areHeadLightsOn = () => {
        const cv = me.rv.GetControlValue("Headlights") as number;
        return cv > 0.5 && cv < 1.5;
    };
    const ditchLightControl = () => {
        const cv = me.rv.GetControlValue("GroundLights") as number;
        if (cv < 0.5) {
            return DitchLights.Off;
        } else if (cv < 1.5) {
            return DitchLights.Fixed;
        } else {
            return DitchLights.Flash;
        }
    };
    const ditchLightsHorn$ = frp.compose(
        me.createOnCvChangeStreamFor("Horn"),
        frp.filter(v => v === 1),
        frp.map(_ => true)
    );
    const ditchLightsAutoFlash$ = frp.compose(
        me.createPlayerUpdateStream(),
        me.mapGetCvStream("Bell"),
        frp.filter(v => v === 0),
        frp.map(_ => false),
        frp.merge(ditchLightsHorn$)
    );
    const ditchLightsState = frp.liftN(
        (headLights, ditchLights, autoFlash) => {
            if (headLights) {
                return autoFlash && ditchLights === DitchLights.Fixed ? DitchLights.Flash : ditchLights;
            } else {
                return DitchLights.Off;
            }
        },
        areHeadLightsOn,
        ditchLightControl,
        frp.stepper(ditchLightsAutoFlash$, false)
    );
    const ditchLightsPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        fx.behaviorStopwatchS(frp.liftN(state => state === DitchLights.Flash, ditchLightsState)),
        frp.map((flashS): [boolean, boolean] => {
            if (flashS === undefined) {
                const ditchOn = frp.snapshot(ditchLightsState) === DitchLights.Fixed;
                return [ditchOn, ditchOn];
            } else {
                const showLeft = flashS % (ditchLightFlashS * 2) < ditchLightFlashS;
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
    ditchLightsFront$(([l, r]) => {
        const [lightL, lightR] = ditchLightsFront;
        lightL.setOnOff(l);
        lightR.setOnOff(r);
    });
    ditchLightsRear$(([l, r]) => {
        const [lightL, lightR] = ditchLightsRear;
        lightL.setOnOff(l);
        lightR.setOnOff(r);
    });
    const ditchNodes: [fx.FadeableLight, string][] = [
        [ditchLightsFront[0], "ditch_fwd_l"],
        [ditchLightsFront[1], "ditch_fwd_r"],
        [ditchLightsRear[0], "ditch_bwd_l"],
        [ditchLightsRear[1], "ditch_bwd_r"],
    ];
    ditchNodes.forEach(([light, node]) => {
        const setOnOff$ = frp.compose(
            me.createUpdateStream(),
            frp.map(_ => light.getIntensity() > 0.5),
            rejectRepeats()
        );
        setOnOff$(on => {
            me.rv.ActivateNode(node, on);
        });
    });

    // Driving displays
    const speedoDigitsMph = me.createSpeedometerDigitsMphBehavior(3);
    const displayUpdate$ = me.createPlayerWithKeyUpdateStream();
    displayUpdate$(_ => {
        const vehicleOn = (me.rv.GetControlValue("Startup") as number) > 0;
        me.rv.SetControlValue("ControlScreenIzq", vehicleOn ? 0 : 1);
        me.rv.SetControlValue("ControlScreenDer", vehicleOn ? 0 : 1);

        let pantoIndicator: number;
        if (!frp.snapshot(pantographsUp)) {
            pantoIndicator = -1;
        } else {
            const selected = frp.snapshot(pantographSelect);
            if (selected === PantographSelect.Front) {
                pantoIndicator = 0;
            } else if (selected === PantographSelect.Rear) {
                pantoIndicator = 2;
            } else {
                pantoIndicator = 1;
            }
        }
        me.rv.SetControlValue("PantoIndicator", pantoIndicator);

        let ditchLights: number;
        switch (frp.snapshot(ditchLightsState)) {
            case DitchLights.Off:
            default:
                ditchLights = frp.snapshot(areHeadLightsOn) ? 0 : -1;
                break;
            case DitchLights.Fixed:
                ditchLights = 1;
                break;
            case DitchLights.Flash:
                ditchLights = 2;
                break;
        }
        me.rv.SetControlValue("SelectLights", ditchLights);

        const [[h, t, u], guide] = frp.snapshot(speedoDigitsMph);
        me.rv.SetControlValue("SPHundreds", h);
        me.rv.SetControlValue("SPTens", t);
        me.rv.SetControlValue("SPUnits", u);
        me.rv.SetControlValue("SpeedoGuide", guide);

        me.rv.SetControlValue("PowerState", frp.snapshot(cruiseOn) ? 8 : Math.floor(frp.snapshot(throttle) * 6 + 0.5));
    });
    const tractiveEffortKlbs$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => me.eng.GetTractiveEffort() * 71),
        movingAverage(nDisplaySamples)
    );
    tractiveEffortKlbs$(effortKlbs => {
        me.rv.SetControlValue("Effort", effortKlbs);
    });

    // Process OnControlValueChange events.
    const onCvChange$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.reject(([name]) => name === "Bell")
    );
    onCvChange$(([name, value]) => {
        me.rv.SetControlValue(name, value);
    });
    if (isFanRailer) {
        // Fix Xbox and Raildriver controls.
        const virtualThrottle$ = me.createOnCvChangeStreamFor("VirtualThrottle");
        virtualThrottle$(v => {
            me.rv.SetControlValue("NewVirtualThrottle", v);
        });
    }

    // Set consist brake lights.
    fx.createBrakeLightStreamForEngine(me);

    // Set platform door height.
    fx.setLowPlatformDoorsForEngine(me, false);

    // Enable updates.
    me.e.BeginUpdate();
});
me.setup();
