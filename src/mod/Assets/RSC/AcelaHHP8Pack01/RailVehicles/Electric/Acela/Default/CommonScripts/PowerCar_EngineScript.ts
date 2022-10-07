/**
 * Amtrak Bombardier HHP-8
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { mapBehavior, movingAverage } from "lib/frp-extra";
import { SensedDirection, VehicleCamera } from "lib/frp-vehicle";
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

const ditchLightFlashS = 0.5;
const nDisplaySamples = 30;

const me = new FrpEngine(() => {
    const isFanRailer = me.rv.ControlExists("NewVirtualThrottle", 0);

    // Electric power supply
    const electrification = ps.createElectrificationBehaviorWithLua(me, ps.Electrification.Overhead);
    const frontSparkLight = new rw.Light("Spark");
    const rearSparkLight = new rw.Light("Spark2");
    const pantographsUp = () => (me.rv.GetControlValue("PantographControl", 0) as number) > 0.5;
    const pantographsUpAllStates = frp.liftN(playerUp => !me.eng.GetIsEngineWithKey() || playerUp, pantographsUp);
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
    const pantoSpark$ = fx.createUniModePantographSparkStream(me, electrification, pantographsUpAllStates);
    pantoSpark$(spark => {
        const pantosUp = frp.snapshot(pantographsUpAllStates);
        const selected = frp.snapshot(pantographSelect);
        const frontSpark = spark && pantosUp && selected !== PantographSelect.Rear;
        const rearSpark = spark && pantosUp && selected !== PantographSelect.Front;

        frontSparkLight.Activate(frontSpark);
        me.rv.ActivateNode("front_spark01", frontSpark);
        me.rv.ActivateNode("front_spark02", frontSpark);

        rearSparkLight.Activate(rearSpark);
        me.rv.ActivateNode("rear_spark01", rearSpark);
        me.rv.ActivateNode("rear_spark02", rearSpark);
    });

    // Pantograph control
    // PantographControl is not transmitted to the rest of the consist, but
    // SelPanto is.
    const pantographStateNonPlayer$ = frp.compose(
        me.createAiUpdateStream(),
        frp.merge(me.createPlayerWithoutKeyUpdateStream()),
        frp.map(_ => true)
    );
    const pantographState$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(pantographsUp),
        frp.merge(pantographStateNonPlayer$)
    );
    const pantographState = frp.stepper(pantographState$, false);
    const pantographUpdate$ = me.createUpdateStream();
    pantographUpdate$(dt => {
        let front: number;
        let rear: number;
        const raise = frp.snapshot(pantographState);
        switch (frp.snapshot(pantographSelect)) {
            case PantographSelect.Both:
                front = rear = raise ? 1 : -1;
                break;
            case PantographSelect.Front:
            default:
                front = raise ? 1 : -1;
                rear = -1;
                break;
            case PantographSelect.Rear:
                front = -1;
                rear = raise ? 1 : -1;
                break;
        }
        me.rv.AddTime("frontPanto", front * dt);
        me.rv.AddTime("rearPanto", rear * dt);
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
    const [aduState$, aduEvents$] = adu.create(cs.amtrakAtc, me, acknowledge, suppression, atcCutIn, acsesCutIn, [
        "CurrentAmtrakSignal",
        0,
    ]);
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
                state.aspect === cs.AmtrakAspect.ApproachMedium30 ||
                state.aspect === cs.AmtrakAspect.ApproachMedium45
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
            state.aspect === cs.AmtrakAspect.ApproachMedium30 ||
                (state.aspect === cs.AmtrakAspect.ApproachMedium45 && state.aspectFlashOn)
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
                [cs.AmtrakAspect.ApproachMedium30]: 30,
                [cs.AmtrakAspect.ApproachMedium45]: 45,
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
    const alerter$ = frp.compose(ale.create(me, acknowledge, alerterReset$, alerterCutIn), frp.hub());
    const alerterState = frp.stepper(alerter$, undefined);
    // Safety system sounds
    const isAlarm = frp.liftN(
        (aduState, alerterState) => (aduState?.alarm || alerterState?.alarm) ?? false,
        aduState,
        alerterState
    );
    const alarmOn$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(isAlarm));
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
        targetMps => targetMps > 0 && (me.rv.GetControlValue("CruiseControl", 0) as number) > 0.5,
        cruiseTargetMps
    );
    const cruiseOutput = frp.stepper(me.createCruiseControlStream(cruiseOn, cruiseTargetMps), 0);

    // Throttle, air brake, and dynamic brake controls
    const isPowerAvailable = () => ps.uniModeEngineHasPower(ps.EngineMode.Overhead, electrification);
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
    const throttle = frp.liftN(
        (isPowerAvailable, isPenaltyBrake, cruiseOn, cruiseOutput, input) => {
            if (isPenaltyBrake || !isPowerAvailable) {
                return 0;
            } else if (cruiseOn) {
                return Math.min(cruiseOutput, input);
            } else {
                return input;
            }
        },
        isPowerAvailable,
        isPenaltyBrake,
        cruiseOn,
        cruiseOutput,
        () => me.rv.GetControlValue(isFanRailer ? "NewVirtualThrottle" : "VirtualThrottle", 0) as number
    );
    const throttle$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(throttle));
    throttle$(v => {
        me.rv.SetControlValue("Regulator", 0, v);
    });
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
        frp.map(pu => {
            const airBrake = frp.snapshot(isPenaltyBrake)
                ? fullService
                : (me.rv.GetControlValue("TrainBrakeControl", 0) as number);
            return pu.speedMps >= 10 ? airBrake * 0.3 : 0;
        })
    );
    dynamicBrake$(v => {
        me.rv.SetControlValue("DynamicBrake", 0, v);
    });

    // Cab dome light
    const cabLight = new rw.Light("CabLight");
    const cabLightPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("CabLight", 0) as number) > 0.5)
    );
    const cabLight$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.merge(me.createAiUpdateStream()),
        frp.map(_ => false),
        frp.merge(cabLightPlayer$)
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

    // Camera state for ditch lights
    const isPlayerUsingFrontCab$ = frp.compose(
        me.createOnCameraStream(),
        frp.filter(cam => cam === VehicleCamera.FrontCab || cam === VehicleCamera.RearCab),
        frp.map(cam => cam === VehicleCamera.FrontCab)
    );
    const isPlayerUsingFrontCab = frp.stepper(isPlayerUsingFrontCab$, true);

    // Ditch lights, front and rear
    const ditchLightsFront = [new rw.Light("Fwd_DitchLightLeft"), new rw.Light("Fwd_DitchLightRight")];
    const ditchLightsRear = [new rw.Light("Bwd_DitchLightLeft"), new rw.Light("Bwd_DitchLightRight")];
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
    const ditchLightsState = frp.liftN(
        (headLights, ditchLights, bell) => {
            if (headLights) {
                return bell && ditchLights === DitchLights.Fixed ? DitchLights.Flash : ditchLights;
            } else {
                return DitchLights.Off;
            }
        },
        areHeadLightsOn,
        ditchLightControl,
        () => (me.rv.GetControlValue("Bell", 0) as number) > 0.5
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
        me.rv.ActivateNode("ditch_bwd_l", l);
        me.rv.ActivateNode("ditch_bwd_r", r);
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
