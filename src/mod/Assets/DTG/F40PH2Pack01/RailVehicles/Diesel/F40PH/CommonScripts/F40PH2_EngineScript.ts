/**
 * NJ Transit EMD F40PH-2CAT
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { fsm, mapBehavior, rejectRepeats } from "lib/frp-extra";
import { SensedDirection } from "lib/frp-vehicle";
import * as m from "lib/math";
import { AduAspect } from "lib/nec/adu";
import * as cs from "lib/nec/cabsignals";
import * as njt from "lib/nec/nj-transit";
import * as adu from "lib/nec/twospeed-adu";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

enum HeadLights {
    Off,
    Forward,
    Backward,
}

enum DitchLights {
    Off,
    Fixed,
    Flash,
}

const ditchLightsFadeS = 0.3;
const ditchLightFlashS = 0.65;
const strobeLightFlashS = 0.08;
const strobeLightCycleS = 0.8;
const strobeLightBellS = 30;

const me = new FrpEngine(() => {
    // Safety systems cut in/out
    // As in other NJT DLC, the ATC and ACSES controls are reversed. But we need
    // to use the ATC (Ctrl+F) control because there is a model node tied to it.
    const atcCutIn = () => !((me.rv.GetControlValue("ATC") as number) > 0.5);
    ui.createAtcStatusPopup(me, atcCutIn);
    const alerterCutIn = () => !((me.rv.GetControlValue("ACSES") as number) > 0.5);
    ui.createAlerterStatusPopup(me, alerterCutIn);
    const updateCutIns$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(frp.liftN((atcCutIn): [boolean, boolean] => [atcCutIn, false], atcCutIn))
    );
    updateCutIns$(([atc, acses]) => {
        // These have to be reversed too!
        me.rv.SetControlValue("ACSES_CutOut", atc ? 0 : 1);
        me.rv.SetControlValue("ATC_CutOut", acses ? 0 : 1);
    });

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("VirtualBrake") as number) >= 0.5;
    const [aduState$, aduEvents$] = adu.create({
        atc: cs.njTransitAtc,
        e: me,
        acknowledge,
        suppression,
        atcCutIn,
        acsesCutIn: () => false,
        equipmentSpeedMps: 100 * c.mph.toMps,
        pulseCodeControlValue: "ACSES_SpeedMax",
    });
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(state => {
        const { aspect } = state;
        const [ss, sd] = {
            [cs.NjTransitAspect.Clear]: [120, 1],
            [cs.NjTransitAspect.CabSpeed80]: [80, 2],
            [cs.NjTransitAspect.CabSpeed60]: [60, 3],
            [cs.NjTransitAspect.ApproachLimited]: [45, 4],
            [cs.NjTransitAspect.ApproachMedium]: [30, 5],
            [cs.NjTransitAspect.Approach]: [30, 6],
            [cs.NjTransitAspect.Restricting]: [20, 7],
            [AduAspect.Stop]: [20, 7],
        }[aspect];
        me.rv.SetControlValue("ACSES_SpeedSignal", ss);
        me.rv.SetControlValue("ACSES_SignalDisplay", sd);
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
        me.rv.SetControlValue("AWSWarnCount", cvs.awsWarnCount ? 1 : 0);
        me.rv.SetControlValue("ACSES_Alert", cvs.acsesAlert ? 1 : 0);
        me.rv.SetControlValue("ACSES_AlertIncrease", cvs.acsesIncrease ? 1 : 0);
        me.rv.SetControlValue("ACSES_AlertDecrease", cvs.acsesDecrease ? 1 : 0);
    });

    // Throttle, dynamic brake, and air brake controls
    const isPenaltyBrake = () => false;
    const throttle$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (isPenaltyBrake, input) => (isPenaltyBrake ? 0 : input),
                isPenaltyBrake,
                () => Math.max(me.rv.GetControlValue("VirtualThrottle") as number)
            )
        )
    );
    throttle$(v => {
        me.rv.SetControlValue("Regulator", v);
    });
    const airBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (isPenaltyBrake, input) => (isPenaltyBrake ? 0.6 : input),
                isPenaltyBrake,
                () => me.rv.GetControlValue("VirtualBrake") as number
            )
        )
    );
    airBrake$(v => {
        me.rv.SetControlValue("TrainBrakeControl", v);
    });
    // DTG's "blended braking" algorithm
    const dynamicBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                bpPsi => Math.min((110 - bpPsi) / 16, 1),
                () => me.rv.GetControlValue("AirBrakePipePressurePSI") as number
            )
        )
    );
    dynamicBrake$(v => {
        me.rv.SetControlValue("DynamicBrake", v);
    });

    // Speedometer
    const aSpeedoMph$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("SpeedometerMPH"),
        frp.map(mph => Math.abs(mph)),
        frp.map(mph => Math.round(mph))
    );
    aSpeedoMph$(mph => {
        const [[h, t, u]] = m.digits(mph, 3);
        me.rv.SetControlValue("SpeedH", h);
        me.rv.SetControlValue("SpeedT", t);
        me.rv.SetControlValue("SpeedU", u);
    });

    // Diesel exhaust
    const dieselRpm = () => me.rv.GetControlValue("RPM") as number;
    const exhaustEmitters: [rw.Emitter, rw.Emitter] = [new rw.Emitter("Exhaust_01"), new rw.Emitter("Exhaust_02")];
    const exhaustOne$ = frp.compose(
        me.createUpdateStream(),
        mapBehavior(dieselRpm),
        frp.map(rpm => rpm > 180),
        rejectRepeats()
    );
    const exhaustTwo$ = frp.compose(
        me.createUpdateStream(),
        mapBehavior(dieselRpm),
        frp.throttle(0.2),
        fsm(0),
        frp.map(([last, rpm]) => rpm > last),
        rejectRepeats()
    );
    exhaustOne$(on => {
        const [e] = exhaustEmitters;
        e.SetEmitterActive(on);
    });
    exhaustTwo$(on => {
        const [, e] = exhaustEmitters;
        e.SetEmitterActive(on);
    });

    // Cab lights
    const domeLight = new rw.Light("Cablight");
    const domeLight$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("CabLight") as number) > 0.9),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.merge(me.createPlayerWithoutKeyUpdateStream()),
                frp.map(_ => false)
            )
        ),
        rejectRepeats()
    );
    domeLight$(on => {
        domeLight.Activate(on);
        me.rv.ActivateNode("cablights", on);
    });
    const domeLightDefault$ = frp.compose(
        me.createFirstUpdateAfterControlsSettledStream(),
        frp.filter(resumeFromSave => !resumeFromSave),
        frp.map(_ => 0)
    );
    domeLightDefault$(v => {
        me.rv.SetControlValue("CabLight", v);
    });

    // Number lights
    const numberLight$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("NumberLights") as number) > 0.5),
        frp.merge(
            frp.compose(
                me.createPlayerWithoutKeyUpdateStream(),
                frp.map(_ => false)
            )
        ),
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
    numberLight$(on => {
        me.rv.ActivateNode("numbers_on", on);
    });

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
                me.mapGetCvStream("StepLights"),
                frp.map(v => v > 0.5)
            )
        ),
        rejectRepeats()
    );
    stepLights$(on => {
        stepLights.forEach(light => light.Activate(on));
    });

    // Ditch lights
    const ditchLights = [
        new fx.FadeableLight(me, ditchLightsFadeS, "Fwd_Ditch_01"),
        new fx.FadeableLight(me, ditchLightsFadeS, "Fwd_Ditch_02"),
    ];
    const headLightsSetting = frp.liftN(
        cv => {
            if (cv < 0.5) {
                return HeadLights.Off;
            } else if (cv < 1.5) {
                return HeadLights.Forward;
            } else {
                return HeadLights.Backward;
            }
        },
        () => me.rv.GetControlValue("Headlights") as number
    );
    const ditchLightsSetting = frp.liftN(
        (headLights, cv) => {
            if (headLights === HeadLights.Off || cv < 0.5) {
                return DitchLights.Off;
            } else if (cv < 1.5) {
                return DitchLights.Fixed;
            } else {
                return DitchLights.Flash;
            }
        },
        headLightsSetting,
        () => me.rv.GetControlValue("DitchLights") as number
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
            return light.getIntensity() > 0;
        }),
        rejectRepeats()
    );
    const ditchNodeRight$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => {
            const [, light] = ditchLights;
            return light.getIntensity() > 0;
        }),
        rejectRepeats()
    );
    ditchNodeLeft$(on => {
        me.rv.ActivateNode("ditchlight_left", on);
    });
    ditchNodeRight$(on => {
        me.rv.ActivateNode("ditchlight_right", on);
    });

    // Strobe lights
    const strobeLights = [new rw.Light("Strobe_L"), new rw.Light("Strobe_R")];
    const strobeLightsBell = frp.stepper(
        frp.compose(
            me.createPlayerWithKeyUpdateStream(),
            fx.eventStopwatchS(
                frp.compose(
                    me.createPlayerWithKeyUpdateStream(),
                    me.mapGetCvStream("VirtualBell"),
                    frp.filter(v => v > 0.5)
                )
            ),
            frp.map(t => t !== undefined && t < strobeLightBellS)
        ),
        false
    );
    const strobeLights$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        fx.behaviorStopwatchS(strobeLightsBell),
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
        rejectRepeats()
    );
    const strobeLightRight$ = frp.compose(
        strobeLights$,
        frp.map(([, right]) => right),
        rejectRepeats()
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

    // Head-end power
    const hep$ = ps.createHepStream(me, () => (me.rv.GetControlValue("HEP") as number) > 0.5);
    hep$(on => {
        me.rv.SetControlValue("HEP_State", on ? 1 : 0);
    });
    njt.createHepPopup(me);
    const hepStartStop$ = frp.compose(
        me.createOnCvChangeStreamFor("HEPStart"),
        frp.filter(v => v === 1),
        frp.map(_ => 1),
        frp.merge(
            frp.compose(
                me.createOnCvChangeStreamFor("HEPStop"),
                frp.filter(v => v === 1),
                frp.map(_ => 0)
            )
        )
    );
    hepStartStop$(v => {
        me.rv.SetControlValue("HEP", v);
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

    // Link the various virtual controls.
    const engineBrakeControl$ = me.createOnCvChangeStreamFor("VirtualEngineBrakeControl");
    engineBrakeControl$(v => {
        me.rv.SetControlValue("EngineBrakeControl", v);
    });
    const hornControl$ = me.createOnCvChangeStreamFor("VirtualHorn");
    hornControl$(v => {
        me.rv.SetControlValue("Horn", v);
    });
    const sanderControl$ = me.createOnCvChangeStreamFor("VirtualSander");
    sanderControl$(v => {
        me.rv.SetControlValue("Sander", v);
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
    fx.createBrakeLightStreamForEngine(me);

    // Set platform door height.
    fx.setLowPlatformDoorsForEngine(me, true);

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
        const [[h, t, u]] = m.digits(tonumber(unit) as number, 3);
        me.rv.SetControlValue("UN_hundreds", h);
        me.rv.SetControlValue("UN_tens", t);
        me.rv.SetControlValue("UN_units", u);
    }
}
