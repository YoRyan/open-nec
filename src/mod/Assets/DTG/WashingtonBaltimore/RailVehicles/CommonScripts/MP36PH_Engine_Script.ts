/** @noSelfInFile */
/**
 * MARC MPI MP36PH
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { mapBehavior, rejectRepeats } from "lib/frp-extra";
import { SensedDirection } from "lib/frp-vehicle";
import { AduAspect } from "lib/nec/adu";
import * as cs from "lib/nec/cabsignals";
import * as adu from "lib/nec/twospeed-adu";
import * as m from "lib/math";
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
    const advancedBraking = () => me.rv.GetControlValue("BrakeDifficulty", 0) as number;
    const atcCutIn = frp.liftN(ab => ab > 1.5 && ab < 3.5, advancedBraking);
    const acsesCutIn = frp.liftN(ab => (ab > 1.5 && ab < 2.5) || ab > 3.5, advancedBraking);
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("VirtualBrake", 0) as number) >= 0.6;
    const [aduState$, aduEvents$] = adu.create(
        cs.amtrakAtc,
        me,
        acknowledge,
        suppression,
        atcCutIn,
        acsesCutIn,
        100 * c.mph.toMps,
        ["SignalSpeedLimit", 0]
    );
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(state => {
        me.rv.SetControlValue(
            "SigN",
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
            "SigL",
            0,
            state.aspect === cs.AmtrakAspect.Approach ||
                state.aspect === cs.AmtrakAspect.ApproachMedium ||
                state.aspect === cs.AmtrakAspect.ApproachLimited
                ? 1
                : 0
        );
        me.rv.SetControlValue(
            "SigS",
            0,
            state.aspect === AduAspect.Stop || state.aspect === cs.AmtrakAspect.Restricting ? 1 : 0
        );
        me.rv.SetControlValue(
            "SigM",
            0,
            state.aspect === cs.AmtrakAspect.ApproachMedium ||
                (state.aspect === cs.AmtrakAspect.ApproachLimited && state.aspectFlashOn)
                ? 1
                : 0
        );
        me.rv.SetControlValue("SigR", 0, state.aspect === cs.AmtrakAspect.Restricting ? 1 : 0);
        me.rv.SetControlValue(
            "SignalSpeed",
            0,
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
            }[state.aspect]
        );

        if (state.trackSpeedMph !== undefined) {
            const [[h, t, u]] = m.digits(state.trackSpeedMph, 3);
            me.rv.SetControlValue("TSHundreds", 0, h);
            me.rv.SetControlValue("TSTens", 0, t);
            me.rv.SetControlValue("TSUnits", 0, u);
        } else {
            me.rv.SetControlValue("TSHundreds", 0, 0);
            me.rv.SetControlValue("TSTens", 0, -1);
            me.rv.SetControlValue("TSUnits", 0, -1);
        }

        me.rv.SetControlValue(
            "MaximumSpeedLimitIndicator",
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
        frp.filter(([name]) => name === "ThrottleAndBrake" || name === "VirtualBrake")
    );
    const alerterState = frp.stepper(ale.create(me, acknowledge, alerterReset$, alerterCutIn), undefined);
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
                        tms: ((aduState?.alarm || alerterState?.alarm) ?? false) || upgradeSound,
                        awsWarnCount: aduState?.alarm ?? false,
                    };
                },
                aduState,
                alerterState,
                frp.stepper(upgradeSound$, false)
            )
        )
    );
    alarmSounds$(cvs => {
        me.rv.SetControlValue("TMS", 0, cvs.tms ? 1 : 0);
        me.rv.SetControlValue("AWSWarnCount", 0, cvs.awsWarnCount ? 1 : 0);
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
        () => me.rv.GetControlValue("ThrottleAndBrake", 0) as number
    );
    const throttleAndDynBrake$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(throttleAndDynBrake));
    throttleAndDynBrake$(throttleAndBrake => {
        me.rv.SetControlValue("Regulator", 0, throttleAndBrake);
        me.rv.SetControlValue("DynamicBrake", 0, -throttleAndBrake);
    });
    const airBrake = frp.liftN(
        (isPenaltyBrake, input, fullService) => (isPenaltyBrake ? fullService : input),
        isPenaltyBrake,
        () => me.rv.GetControlValue("VirtualBrake", 0) as number,
        0.85
    );
    const airBrake$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(airBrake));
    airBrake$(brake => {
        me.rv.SetControlValue("TrainBrakeControl", 0, brake);
    });
    const indBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("VirtualEngineBrakeControl", 0)
    );
    indBrake$(brake => {
        me.rv.SetControlValue("EngineBrakeControl", 0, brake);
    });

    // Speedometer
    const speedoMph$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("SpeedometerMPH", 0),
        frp.map(mph => Math.abs(mph))
    );
    speedoMph$(mph => {
        const [[h, t, u]] = m.digits(Math.round(mph), 3);
        me.rv.SetControlValue("SpeedoHundreds", 0, h);
        me.rv.SetControlValue("SpeedoTens", 0, t);
        me.rv.SetControlValue("SpeedoUnits", 0, u);
        me.rv.SetControlValue("SpeedoDots", 0, Math.floor(mph / 2));
    });

    // Dome light
    const cabLight = new rw.Light("Cablight");
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

    // Head-end power
    const hep$ = ps.createHepStream(me, () => (me.rv.GetControlValue("HEP", 0) as number) > 0.5);
    hep$(on => {
        me.rv.SetControlValue("HEP_State", 0, on ? 1 : 0);
    });
    const hepTurnedOn$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.filter(([name, , value]) => (name === "HEP" && value === 1) || (name === "HEP_Off" && value === 0))
    );
    hepTurnedOn$(_ => {
        me.rv.SetControlValue("HEP", 0, 1);
        me.rv.SetControlValue("HEP_Off", 0, 0);
    });
    const hepTurnedOff$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.filter(([name, , value]) => (name === "HEP" && value === 0) || (name === "HEP_Off" && value === 1))
    );
    hepTurnedOff$(_ => {
        me.rv.SetControlValue("HEP", 0, 0);
        me.rv.SetControlValue("HEP_Off", 0, 1);
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
        me.mapGetCvStream("Headlights", 0),
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
        () => (me.rv.GetControlValue("DitchLights", 0) as number) > 0.5,
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
        me.mapGetCvStream("Rearlights", 0),
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
        me.createOnCvChangeStreamFor("Horn", 0),
        frp.filter(v => v === 1),
        me.mapAutoBellStream()
    );
    bellControl$(v => {
        me.rv.SetControlValue("Bell", 0, v);
    });

    // Process OnControlValueChange events.
    const onCvChange$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.reject(([name]) => name === "HEP" || name === "HEP_Off"),
        frp.reject(([name]) => name === "Bell")
    );
    onCvChange$(([name, index, value]) => {
        me.rv.SetControlValue(name, index, value);
    });

    // Set consist brake lights.
    fx.createBrakeLightStreamForEngine(me);

    // Enable updates.
    me.e.BeginUpdate();
});
me.setup();
