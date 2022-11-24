/**
 * Amtrak Bombardier HHP-8
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine, PlayerLocation } from "lib/frp-engine";
import { mapBehavior, movingAverage, rejectRepeats } from "lib/frp-extra";
import { SensedDirection } from "lib/frp-vehicle";
import { AduAspect } from "lib/nec/adu";
import * as cs from "lib/nec/cabsignals";
import * as adu from "lib/nec/twospeed-adu";
import * as m from "lib/math";
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
    const isFanRailer = me.rv.ControlExists("NewVirtualThrottle", 0);

    // Electric power supply
    const electrification = ps.createElectrificationBehaviorWithLua(me, ps.Electrification.Overhead);
    const isPowerAvailable = () => ps.uniModeEngineHasPower(ps.EngineMode.Overhead, electrification);
    // Pantograph control
    // Note: PantographControl is not transmitted to the rest of the consist,
    // but SelPanto is.
    const pantographsUp = () => (me.rv.GetControlValue("PantographControl", 0) as number) > 0.5;
    const pantographSelect = () => {
        const cv = me.rv.GetControlValue("SelPanto", 0) as number;
        if (cv < 0.5) {
            return PantographSelect.Front;
        } else if (cv < 1.5) {
            return PantographSelect.Both;
        } else {
            return PantographSelect.Rear;
        }
    };
    const pantographAnims = [new fx.Animation(me, "frontPanto", 2), new fx.Animation(me, "rearPanto", 2)];
    const pantographUpdate$ = me.createUpdateStream();
    pantographUpdate$(_ => {
        let frontUp: boolean;
        let rearUp: boolean;
        const raise = frp.snapshot(pantographsUp);
        switch (frp.snapshot(pantographSelect)) {
            case PantographSelect.Both:
                frontUp = rearUp = raise;
                break;
            case PantographSelect.Front:
                frontUp = raise;
                rearUp = false;
                break;
            case PantographSelect.Rear:
                frontUp = false;
                rearUp = raise;
                break;
        }

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
            for (const node of nodes) {
                me.rv.ActivateNode(node, on);
            }
        });
    });

    // Safety systems cut in/out
    const atcCutIn = () => (me.rv.GetControlValue("ATCCutIn", 0) as number) > 0.5;
    const acsesCutIn = () => (me.rv.GetControlValue("ACSESCutIn", 0) as number) > 0.5;
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("TrainBrakeControl", 0) as number) > 0.3;
    const [aduState$, aduEvents$] = adu.create(
        cs.amtrakAtc,
        me,
        acknowledge,
        suppression,
        atcCutIn,
        acsesCutIn,
        125 * c.mph.toMps,
        ["CurrentAmtrakSignal", 0]
    );
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(state => {
        me.rv.SetControlValue(
            "SigGreen",
            0,
            ((state.aspect === cs.AmtrakAspect.CabSpeed60 || state.aspect === cs.AmtrakAspect.CabSpeed80) &&
                state.aspectFlashOn) ||
                state.aspect === cs.AmtrakAspect.Clear100 ||
                state.aspect === cs.AmtrakAspect.Clear125 ||
                state.aspect === cs.AmtrakAspect.Clear150
                ? 1
                : 0
        );
        me.rv.SetControlValue(
            "SigYellow",
            0,
            state.aspect === cs.AmtrakAspect.Approach ||
                state.aspect === cs.AmtrakAspect.ApproachMedium ||
                state.aspect === cs.AmtrakAspect.ApproachLimited
                ? 1
                : 0
        );
        me.rv.SetControlValue(
            "SigRed",
            0,
            state.aspect === AduAspect.Stop || state.aspect === cs.AmtrakAspect.Restricting ? 1 : 0
        );
        me.rv.SetControlValue(
            "SigLowerGreen",
            0,
            state.aspect === cs.AmtrakAspect.ApproachMedium ||
                (state.aspect === cs.AmtrakAspect.ApproachLimited && state.aspectFlashOn)
                ? 1
                : 0
        );
        me.rv.SetControlValue("SigLowerGrey", 0, state.aspect === cs.AmtrakAspect.Restricting ? 1 : 0);
        me.rv.SetControlValue(
            "CabSpeed",
            0,
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
            }[state.aspect]
        );

        if (state.trackSpeedMph !== undefined) {
            const [[h, t, u]] = m.digits(state.trackSpeedMph, 3);
            me.rv.SetControlValue("TSHundreds", 0, h);
            me.rv.SetControlValue("TSTens", 0, t);
            me.rv.SetControlValue("TSUnits", 0, u);
        } else {
            me.rv.SetControlValue("TSHundreds", 0, -1);
            me.rv.SetControlValue("TSTens", 0, -1);
            me.rv.SetControlValue("TSUnits", 0, -1);
        }

        me.rv.SetControlValue(
            "MinimumSpeed",
            0,
            {
                [adu.MasEnforcing.Off]: -1,
                [adu.MasEnforcing.Atc]: 0,
                [adu.MasEnforcing.Acses]: 1,
            }[state.masEnforcing]
        );
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
    const alerterState = frp.stepper(ale.create(me, acknowledge, alerterReset$, alerterCutIn), undefined);
    // Safety system sounds
    const alarmOn$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (aduState, alerterState) => (aduState?.alarm || alerterState?.alarm) ?? false,
                aduState,
                alerterState
            )
        )
    );
    alarmOn$(on => {
        me.rv.SetControlValue("AWSWarnCount", 0, on ? 1 : 0);
    });
    const upgradeEvents$ = frp.compose(
        aduEvents$,
        frp.filter(evt => evt === adu.AduEvent.Upgrade)
    );
    const upgradeSound$ = frp.compose(me.createPlayerWithKeyUpdateStream(), fx.triggerSound(1, upgradeEvents$));
    upgradeSound$(play => {
        me.rv.SetControlValue("SpeedIncreaseAlert", 0, play ? 1 : 0);
    });

    // Cruise control
    const cruiseTargetMps = () => {
        const targetMph = (me.rv.GetControlValue("SpeedSetControl", 0) as number) * 10;
        return targetMph * c.mph.toMps;
    };
    const cruiseOn = frp.liftN(
        (targetMps, cruiseOn) => targetMps > 0 && cruiseOn,
        cruiseTargetMps,
        () => (me.rv.GetControlValue("CruiseControl", 0) as number) > 0.5
    );
    const cruiseOutput = frp.stepper(me.createCruiseControlStream(cruiseOn, cruiseTargetMps), 0);

    // Throttle, air brake, and dynamic brake controls
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
    const airBrake = () => me.rv.GetControlValue("TrainBrakeControl", 0) as number;
    // There's no virtual train brake, so just move the braking handle.
    const fullService = 0.6;
    const setPenaltyBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.filter(_ => frp.snapshot(isPenaltyBrake)),
        frp.map(_ => fullService)
    );
    setPenaltyBrake$(v => {
        me.rv.SetControlValue("TrainBrakeControl", 0, v);
    });
    // DTG's "blended braking" algorithm
    const dynamicBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(pu => (pu.speedMps >= 10 ? frp.snapshot(airBrake) * 0.3 : 0))
    );
    dynamicBrake$(v => {
        me.rv.SetControlValue("DynamicBrake", 0, v);
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
        () => me.rv.GetControlValue(isFanRailer ? "NewVirtualThrottle" : "VirtualThrottle", 0) as number
    );
    const throttle$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(throttle));
    throttle$(v => {
        me.rv.SetControlValue("Regulator", 0, v);
    });

    // Cab dome light
    const cabLight = new rw.Light("CabLight");
    const cabLightPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("CabLight", 0),
        frp.map(v => v > 0.5)
    );
    const cabLight$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.merge(me.createAiUpdateStream()),
        frp.map(_ => false),
        frp.merge(cabLightPlayer$),
        rejectRepeats()
    );
    cabLight$(on => {
        cabLight.Activate(on);
    });

    // Horn rings the bell.
    const bellControl$ = frp.compose(
        me.createOnCvChangeStreamFor("Horn", 0),
        frp.filter(v => v === 1),
        me.mapAutoBellStream()
    );
    bellControl$(v => {
        me.rv.SetControlValue("Bell", 0, v);
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
        const cv = me.rv.GetControlValue("Headlights", 0) as number;
        return cv > 0.5 && cv < 1.5;
    };
    const ditchLightControl = () => {
        const cv = me.rv.GetControlValue("GroundLights", 0) as number;
        if (cv < 0.5) {
            return DitchLights.Off;
        } else if (cv < 1.5) {
            return DitchLights.Fixed;
        } else {
            return DitchLights.Flash;
        }
    };
    const ditchLightsHorn$ = frp.compose(
        me.createOnCvChangeStreamFor("Horn", 0),
        frp.filter(v => v === 1),
        frp.map(_ => true)
    );
    const ditchLightsAutoFlash$ = frp.compose(
        me.createPlayerUpdateStream(),
        me.mapGetCvStream("Bell", 0),
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
    const playerLocation = me.createPlayerLocationBehavior();
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
        frp.map(([l, r]): [boolean, boolean] =>
            frp.snapshot(playerLocation) === PlayerLocation.InFrontCab ? [l, r] : [false, false]
        ),
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
        frp.map(([l, r]): [boolean, boolean] =>
            frp.snapshot(playerLocation) === PlayerLocation.InRearCab ? [l, r] : [false, false]
        ),
        frp.merge(ditchLightsRearNonPlayer$)
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
    const displayUpdate$ = me.createPlayerWithKeyUpdateStream();
    displayUpdate$(_ => {
        const vehicleOn = (me.rv.GetControlValue("Startup", 0) as number) > 0;
        me.rv.SetControlValue("ControlScreenIzq", 0, vehicleOn ? 0 : 1);
        me.rv.SetControlValue("ControlScreenDer", 0, vehicleOn ? 0 : 1);

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
        me.rv.SetControlValue("PantoIndicator", 0, pantoIndicator);

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
        me.rv.SetControlValue("SelectLights", 0, ditchLights);

        const speedoMph = me.rv.GetControlValue("SpeedometerMPH", 0) as number;
        const [[h, t, u], guide] = m.digits(Math.round(speedoMph), 3);
        me.rv.SetControlValue("SPHundreds", 0, h);
        me.rv.SetControlValue("SPTens", 0, t);
        me.rv.SetControlValue("SPUnits", 0, u);
        me.rv.SetControlValue("SpeedoGuide", 0, guide);

        me.rv.SetControlValue(
            "PowerState",
            0,
            frp.snapshot(cruiseOn) ? 8 : Math.floor(frp.snapshot(throttle) * 6 + 0.5)
        );
    });
    const tractiveEffortKlbs$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => me.eng.GetTractiveEffort() * 71),
        movingAverage(nDisplaySamples)
    );
    tractiveEffortKlbs$(effortKlbs => {
        me.rv.SetControlValue("Effort", 0, effortKlbs);
    });

    // Process OnControlValueChange events.
    const onCvChange$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.reject(([name]) => name === "Bell")
    );
    onCvChange$(([name, index, value]) => {
        me.rv.SetControlValue(name, index, value);
    });
    if (isFanRailer) {
        // Fix Xbox and Raildriver controls.
        const virtualThrottle$ = me.createOnCvChangeStreamFor("VirtualThrottle", 0);
        virtualThrottle$(v => {
            me.rv.SetControlValue("NewVirtualThrottle", 0, v);
        });
    }

    // Set consist brake lights.
    fx.createBrakeLightStreamForEngine(me);

    // Enable updates.
    me.activateUpdatesEveryFrame(true);
});
me.setup();
