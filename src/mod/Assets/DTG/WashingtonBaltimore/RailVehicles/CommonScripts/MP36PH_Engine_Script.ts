/**
 * MARC MPI MP36PH
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { mapBehavior, rejectRepeats } from "lib/frp-extra";
import { SensedDirection } from "lib/frp-vehicle";
import * as m from "lib/math";
import { AduAspect } from "lib/nec/adu";
import * as cs from "lib/nec/cabsignals";
import * as adu from "lib/nec/twospeed-adu";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

enum HeadLights {
    Off,
    Dim,
    Bright,
    BrightCross,
}

enum DitchLights {
    Off,
    Fixed,
    Flash,
}

enum RearLights {
    Off,
    Dim,
    Bright,
}

const headlightFadeS = 0.5;
const ditchLightFlashS = 0.5;

const me = new FrpEngine(() => {
    // Safety systems cut in/out
    const advancedBraking = () => me.rv.GetControlValue("BrakeDifficulty") as number;
    const atcCutIn = frp.liftN(ab => ab > 1.5 && ab < 3.5, advancedBraking);
    const acsesCutIn = frp.liftN(ab => (ab > 1.5 && ab < 2.5) || ab > 3.5, advancedBraking);
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("VirtualBrake") as number) >= 0.6;
    const [aduState$, aduEvents$] = adu.create({
        atc: cs.amtrakAtc,
        e: me,
        acknowledge,
        suppression,
        atcCutIn,
        acsesCutIn,
        equipmentSpeedMps: 100 * c.mph.toMps,
        pulseCodeControlValue: "SignalSpeedLimit",
    });
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(({ aspect, aspectFlashOn, trackSpeedMph, atcLamp, acsesLamp }) => {
        me.rv.SetControlValue(
            "SigN",
            ((aspect === cs.AmtrakAspect.CabSpeed60 || aspect === cs.AmtrakAspect.CabSpeed80) && aspectFlashOn) ||
                aspect === cs.AmtrakAspect.Clear100 ||
                aspect === cs.AmtrakAspect.Clear125 ||
                aspect === cs.AmtrakAspect.Clear150
                ? 1
                : 0
        );
        me.rv.SetControlValue(
            "SigL",
            aspect === cs.AmtrakAspect.Approach ||
                aspect === cs.AmtrakAspect.ApproachMedium ||
                aspect === cs.AmtrakAspect.ApproachLimited
                ? 1
                : 0
        );
        me.rv.SetControlValue("SigS", aspect === AduAspect.Stop || aspect === cs.AmtrakAspect.Restricting ? 1 : 0);
        me.rv.SetControlValue(
            "SigM",
            aspect === cs.AmtrakAspect.ApproachMedium || (aspect === cs.AmtrakAspect.ApproachLimited && aspectFlashOn)
                ? 1
                : 0
        );
        me.rv.SetControlValue("SigR", aspect === cs.AmtrakAspect.Restricting ? 1 : 0);
        me.rv.SetControlValue(
            "SignalSpeed",
            {
                [AduAspect.Stop]: 0,
                [cs.AmtrakAspect.Restricting]: 20,
                [cs.AmtrakAspect.Approach]: 30,
                [cs.AmtrakAspect.ApproachMedium]: 30,
                [cs.AmtrakAspect.ApproachLimited]: 45,
                [cs.AmtrakAspect.CabSpeed60]: 60,
                [cs.AmtrakAspect.CabSpeed80]: 80,
                [cs.AmtrakAspect.Clear100]: 99,
                [cs.AmtrakAspect.Clear125]: 99,
                [cs.AmtrakAspect.Clear150]: 99,
            }[aspect]
        );

        if (trackSpeedMph !== undefined) {
            const [[h, t, u]] = m.digits(trackSpeedMph, 3);
            me.rv.SetControlValue("TSHundreds", h);
            me.rv.SetControlValue("TSTens", t);
            me.rv.SetControlValue("TSUnits", u);
        } else {
            me.rv.SetControlValue("TSHundreds", 0);
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
        me.rv.SetControlValue("MaximumSpeedLimitIndicator", lamp);
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterState = frp.stepper(ale.create({ e: me, acknowledge, cutIn: alerterCutIn }), undefined);
    // Safety system sounds
    const upgradeEvents$ = frp.compose(
        aduEvents$,
        frp.filter(evt => evt === adu.AduEvent.Upgrade)
    );
    const upgradeSound$ = frp.compose(me.createPlayerWithKeyUpdateStream(), fx.triggerSound(1, upgradeEvents$));
    const alarmSounds$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (aduState, alerterState, upgradeSound) => {
                    return {
                        tms:
                            ((aduState?.atcAlarm || aduState?.acsesAlarm || alerterState?.alarm) ?? false) ||
                            upgradeSound,
                        awsWarnCount: (aduState?.atcAlarm || aduState?.acsesAlarm) ?? false,
                    };
                },
                aduState,
                alerterState,
                frp.stepper(upgradeSound$, false)
            )
        )
    );
    alarmSounds$(({ tms, awsWarnCount }) => {
        me.rv.SetControlValue("TMS", tms ? 1 : 0);
        me.rv.SetControlValue("AWSWarnCount", awsWarnCount ? 1 : 0);
    });

    // Throttle, dynamic brake, and air brake controls
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
    const throttleAndDynBrake = frp.liftN(
        (isPenaltyBrake, input) => (isPenaltyBrake ? 0 : input),
        isPenaltyBrake,
        () => me.rv.GetControlValue("ThrottleAndBrake") as number
    );
    const throttleAndDynBrake$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(throttleAndDynBrake));
    throttleAndDynBrake$(throttleAndBrake => {
        me.rv.SetControlValue("Regulator", throttleAndBrake);
        me.rv.SetControlValue("DynamicBrake", -throttleAndBrake);
    });
    const airBrake = frp.liftN(
        (isPenaltyBrake, input, fullService) => (isPenaltyBrake ? fullService : input),
        isPenaltyBrake,
        () => me.rv.GetControlValue("VirtualBrake") as number,
        0.85
    );
    const airBrake$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(airBrake));
    airBrake$(brake => {
        me.rv.SetControlValue("TrainBrakeControl", brake);
    });
    const indBrake$ = frp.compose(me.createPlayerWithKeyUpdateStream(), me.mapGetCvStream("VirtualEngineBrakeControl"));
    indBrake$(brake => {
        me.rv.SetControlValue("EngineBrakeControl", brake);
    });

    // Speedometer
    const aSpeedoMph$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(me.createSpeedometerDigitsMphBehavior(3))
    );
    aSpeedoMph$(([[h, t, u]]) => {
        me.rv.SetControlValue("SpeedoHundreds", h);
        me.rv.SetControlValue("SpeedoTens", t);
        me.rv.SetControlValue("SpeedoUnits", u);
    });
    const speedoDots$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(me.createSpeedometerMpsBehavior()),
        frp.map(mps => mps * c.mps.toMph),
        frp.map(mph => Math.round(Math.abs(mph))),
        frp.map(mph => Math.floor(mph / 2))
    );
    speedoDots$(d => {
        me.rv.SetControlValue("SpeedoDots", d);
    });

    // Dome light
    const cabLight = new rw.Light("Cablight");
    const cabLightPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("CabLight"),
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

    // Head-end power
    const hep$ = ps.createHepStream(me, () => (me.rv.GetControlValue("HEP") as number) > 0.5);
    hep$(on => {
        me.rv.SetControlValue("HEP_State", on ? 1 : 0);
    });
    const hepTurnedOn$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.filter(([name, value]) => (name === "HEP" && value === 1) || (name === "HEP_Off" && value === 0))
    );
    hepTurnedOn$(_ => {
        me.rv.SetControlTargetValue("HEP_Off", 0);
    });
    const hepTurnedOff$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.filter(([name, value]) => (name === "HEP" && value === 0) || (name === "HEP_Off" && value === 1))
    );
    hepTurnedOff$(_ => {
        me.rv.SetControlTargetValue("HEP", 0);
    });

    // Headlights
    const headlightsDim = [
        new fx.FadeableLight(me, headlightFadeS, "Headlight_01_Dim"),
        new fx.FadeableLight(me, headlightFadeS, "Headlight_02_Dim"),
    ];
    const headlightsBright = [
        new fx.FadeableLight(me, headlightFadeS, "Headlight_01_Bright"),
        new fx.FadeableLight(me, headlightFadeS, "Headlight_02_Bright"),
    ];
    const headlightsPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("Headlights"),
        frp.map(cv => {
            if (cv > 2.25) {
                return HeadLights.BrightCross;
            } else if (cv > 0.97) {
                return HeadLights.Bright;
            } else if (cv > 0.22) {
                return HeadLights.Dim;
            } else {
                return HeadLights.Off;
            }
        })
    );
    const headlightsAi$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map(au => {
            const [frontCoupled] = au.couplings;
            return !frontCoupled && au.direction === SensedDirection.Forward ? HeadLights.BrightCross : HeadLights.Off;
        })
    );
    const headlightsState$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.map(_ => HeadLights.Off),
        frp.merge(headlightsPlayer$),
        frp.merge(headlightsAi$),
        frp.hub()
    );
    const headlightsState = frp.stepper(headlightsState$, HeadLights.Off);
    headlightsState$(hl => {
        for (const light of headlightsDim) {
            light.setOnOff(hl === HeadLights.Dim);
        }
        for (const light of headlightsBright) {
            light.setOnOff(hl === HeadLights.Bright || hl === HeadLights.BrightCross);
        }
    });

    // Ditch lights
    const ditchLights = [
        new fx.FadeableLight(me, headlightFadeS, "Ditch_L"),
        new fx.FadeableLight(me, headlightFadeS, "Ditch_R"),
    ];
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
        (headlights, pulseLights, autoFlash) => {
            switch (headlights) {
                case HeadLights.Off:
                    return DitchLights.Off;
                case HeadLights.Dim:
                case HeadLights.Bright:
                    return autoFlash ? DitchLights.Flash : DitchLights.Off;
                case HeadLights.BrightCross:
                    return autoFlash || pulseLights ? DitchLights.Flash : DitchLights.Fixed;
            }
        },
        headlightsState,
        () => (me.rv.GetControlValue("DitchLights") as number) > 0.5,
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
    const ditchLights$ = frp.compose(
        me.createAiUpdateStream(),
        frp.merge(me.createPlayerWithoutKeyUpdateStream()),
        frp.map((_): [boolean, boolean] => {
            const ditchOn = frp.snapshot(headlightsState) !== HeadLights.Off;
            return [ditchOn, ditchOn];
        }),
        frp.merge(ditchLightsPlayer$)
    );
    ditchLights$(([l, r]) => {
        const [lightL, lightR] = ditchLights;
        lightL.setOnOff(l);
        lightR.setOnOff(r);
    });
    const ditchNodeLeft$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => {
            const [light] = ditchLights;
            return light.getIntensity() > 0.5;
        }),
        rejectRepeats()
    );
    const ditchNodeRight$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => {
            const [, light] = ditchLights;
            return light.getIntensity() > 0.5;
        }),
        rejectRepeats()
    );
    const ditchNodeAny$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => {
            const [left, right] = ditchLights;
            return left.getIntensity() > 0.5 || right.getIntensity() > 0.5;
        }),
        rejectRepeats()
    );
    ditchNodeLeft$(on => {
        me.rv.ActivateNode("ditch_left", on);
    });
    ditchNodeRight$(on => {
        me.rv.ActivateNode("ditch_right", on);
    });
    ditchNodeAny$(on => {
        me.rv.ActivateNode("lights_dim", on);
    });

    // Rear lights
    const rearLightsDim = [
        new fx.FadeableLight(me, headlightFadeS, "Rearlight_01_Dim"),
        new fx.FadeableLight(me, headlightFadeS, "Rearlight_02_Dim"),
    ];
    const rearLightsBright = [
        new fx.FadeableLight(me, headlightFadeS, "Rearlight_01_Bright"),
        new fx.FadeableLight(me, headlightFadeS, "Rearlight_02_Bright"),
    ];
    const rearLightsPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("Rearlights"),
        frp.map(cv => {
            if (cv > 1.5) {
                return RearLights.Bright;
            } else if (cv > 0.5) {
                return RearLights.Dim;
            } else {
                return RearLights.Off;
            }
        })
    );
    const rearLightsAi$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map(au => {
            const [, rearCoupled] = au.couplings;
            return !rearCoupled && au.direction === SensedDirection.Backward ? RearLights.Bright : RearLights.Off;
        })
    );
    const rearLights$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.map(_ => RearLights.Off),
        frp.merge(rearLightsPlayer$),
        frp.merge(rearLightsAi$)
    );
    rearLights$(rl => {
        for (const light of rearLightsDim) {
            light.setOnOff(rl === RearLights.Dim);
        }
        for (const light of rearLightsBright) {
            light.setOnOff(rl === RearLights.Bright);
        }
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

    // Process OnControlValueChange events.
    const onCvChange$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.reject(([name]) => name === "Bell")
    );
    onCvChange$(([name, value]) => {
        me.rv.SetControlValue(name, value);
    });

    // Set consist brake lights.
    fx.createBrakeLightStreamForEngine(me);

    // Set platform door height.
    fx.setLowPlatformDoorsForEngine(me, true);

    // Enable updates.
    me.e.BeginUpdate();
});
me.setup();
