/**
 * NJ Transit EMD GP40PH-2B
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { mapBehavior, rejectRepeats } from "lib/frp-extra";
import { SensedDirection } from "lib/frp-vehicle";
import * as m from "lib/math";
import * as njt from "lib/nec/nj-transit";
import * as adu from "lib/nec/njt-adu";
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
    // ATC and ACSES controls are reversed for NJT DLC.
    const atcCutIn = () => !((me.rv.GetControlValue("ACSES") as number) > 0.5);
    const acsesCutIn = () => !((me.rv.GetControlValue("ATC") as number) > 0.5);
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("VirtualBrake") as number) >= 0.5;
    const aSpeedoMph = () => Math.abs(me.rv.GetControlValue("SpeedometerMPH") as number);
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
    aduStateHub$(state => {
        const [[h, t, u], guide] = m.digits(Math.round(frp.snapshot(aSpeedoMph)), 3);
        me.rv.SetControlValue("SpeedH", state.clearAspect ? h : -1);
        me.rv.SetControlValue("SpeedT", state.clearAspect ? t : -1);
        me.rv.SetControlValue("SpeedU", state.clearAspect ? u : -1);
        me.rv.SetControlValue("Speed2H", !state.clearAspect ? h : -1);
        me.rv.SetControlValue("Speed2T", !state.clearAspect ? t : -1);
        me.rv.SetControlValue("Speed2U", !state.clearAspect ? u : -1);
        me.rv.SetControlValue("SpeedP", guide);

        me.rv.SetControlValue("ACSES_SpeedGreen", state.masSpeedMph ?? 0);
        me.rv.SetControlValue("ACSES_SpeedRed", state.excessSpeedMph ?? 0);

        me.rv.SetControlValue("ATC_Node", state.atcLamp ? 1 : 0);
        me.rv.SetControlValue("ACSES_Node", state.acsesLamp ? 1 : 0);
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
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
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
                (bpPsi, input) => {
                    const blended = Math.min((89 - bpPsi) / 16, 1);
                    return Math.max(blended, input);
                },
                () => me.rv.GetControlValue("AirBrakePipePressurePSI") as number,
                () => me.rv.GetControlValue("VirtualDynamicBrake") as number
            )
        )
    );
    dynamicBrake$(v => {
        me.rv.SetControlValue("DynamicBrake", v);
    });

    // Air pressure gauges
    const brakePipes$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => {
            return {
                application: me.rv.GetControlValue("AirBrakePipePressurePSI") as number,
                suppression: me.rv.GetControlValue("MainReservoirPressurePSI") as number,
            };
        })
    );
    brakePipes$(v => {
        me.rv.SetControlValue("ApplicationPipe", v.application);
        me.rv.SetControlValue("SuppressionPipe", v.suppression);
    });

    // Diesel exhaust
    const dieselRpm = () => me.rv.GetControlValue("RPM") as number;
    const exhaustEmitters = [new rw.Emitter("Exhaust"), new rw.Emitter("Exhaust2"), new rw.Emitter("Exhaust3")];
    const exhaustState = frp.liftN((dieselRpm): [rate: number, alpha: number] => {
        const effort = (dieselRpm - 600) / (1500 - 600);
        if (effort < 0.05) {
            return [0.05, 0.2];
        } else if (effort <= 0.25) {
            return [0.01, 0.75];
        } else {
            return [0.005, 1];
        }
    }, dieselRpm);
    const exhaustActive$ = frp.compose(
        me.createUpdateStream(),
        mapBehavior(dieselRpm),
        frp.map(rpm => rpm > 0),
        rejectRepeats()
    );
    const exhaustAlpha$ = frp.compose(
        me.createUpdateStream(),
        mapBehavior(exhaustState),
        frp.map(([, alpha]) => alpha),
        rejectRepeats()
    );
    const exhaustRate$ = frp.compose(
        me.createUpdateStream(),
        mapBehavior(exhaustState),
        frp.map(([rate]) => rate),
        rejectRepeats()
    );
    exhaustActive$(active => {
        exhaustEmitters.forEach(e => e.SetEmitterActive(active));
    });
    exhaustAlpha$(alpha => {
        exhaustEmitters.forEach(e => e.SetEmitterColour(0, 0, 0, alpha));
    });
    exhaustRate$(rate => {
        exhaustEmitters.forEach(e => e.SetEmitterRate(rate));
    });

    // Diesel fans
    const exhaustFans = new fx.LoopingAnimation(me, "Fans", 0.5);
    const exhaustFanSpeed$ = frp.compose(
        me.createUpdateStream(),
        mapBehavior(
            frp.liftN(dieselRpm => {
                const isRunning = dieselRpm > 0;
                const rpmScaled = (dieselRpm - 600) / (1800 - 600); // from 0 to 1
                return isRunning ? rpmScaled * 2 + 1 : 0;
            }, dieselRpm)
        )
    );
    exhaustFanSpeed$(hz => {
        exhaustFans.setFrequency(hz);
    });

    // Cab lights
    const domeLight = new rw.Light("CabLight");
    const domeLight$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("CabLight") as number) > 0.5),
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
        me.rv.ActivateNode("lamp_on_left", on);
        me.rv.ActivateNode("lamp_on_right", on);
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
        me.rv.ActivateNode("numbers_lit", on);
    });

    // Step lights
    const stepLights = [
        new rw.Light("Steplight_FL"),
        new rw.Light("Steplight_FR"),
        new rw.Light("Steplight_RL"),
        new rw.Light("Steplight_RR"),
    ];
    const stepLights$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.merge(me.createAiUpdateStream()),
        frp.map(_ => false),
        frp.merge(
            frp.compose(
                me.createPlayerWithKeyUpdateStream(),
                me.mapGetCvStream("StepsLight"),
                frp.map(v => v > 0.5)
            )
        ),
        rejectRepeats()
    );
    stepLights$(on => {
        stepLights.forEach(light => light.Activate(on));
    });

    // Ditch lights
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
                return DitchLights.Flash;
            } else {
                return DitchLights.Fixed;
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
        }),
        frp.hub()
    );
    const ditchLightsHelper$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.map((_): [boolean, boolean] => [false, false])
    );
    const ditchLightsFront$ = frp.compose(
        ditchLightsPlayer$,
        frp.map(([l, r]): [boolean, boolean] =>
            frp.snapshot(headLightsSetting) === HeadLights.Forward ? [l, r] : [false, false]
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
            frp.snapshot(headLightsSetting) === HeadLights.Backward ? [l, r] : [false, false]
        ),
        frp.merge(ditchLightsHelper$),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.map((_): [boolean, boolean] => [false, false])
            )
        )
    );
    const allDitchLights: [
        onOff$: frp.Stream<[boolean, boolean]>,
        lights: [fx.FadeableLight, fx.FadeableLight],
        nodes: [string, string]
    ][] = [
        [
            ditchLightsFront$,
            [
                new fx.FadeableLight(me, ditchLightsFadeS, "DitchFrontLeft"),
                new fx.FadeableLight(me, ditchLightsFadeS, "DitchFrontRight"),
            ],
            ["ditch_front_left", "ditch_front_right"],
        ],
        [
            ditchLightsRear$,
            [
                new fx.FadeableLight(me, ditchLightsFadeS, "DitchRearLeft"),
                new fx.FadeableLight(me, ditchLightsFadeS, "DitchRearRight"),
            ],
            ["ditch_rear_left", "ditch_rear_right"],
        ],
    ];
    allDitchLights.forEach(([onOff$, [lightL, lightR], [nodeL, nodeR]]) => {
        const setLeft$ = frp.compose(
            onOff$,
            frp.map(([l]) => l)
        );
        const setRight$ = frp.compose(
            onOff$,
            frp.map(([, r]) => r)
        );
        setLeft$(on => {
            lightL.setOnOff(on);
        });
        setRight$(on => {
            lightR.setOnOff(on);
        });

        const nodeLeft$ = frp.compose(
            me.createUpdateStream(),
            frp.map(_ => lightL.getIntensity() > 0.5),
            rejectRepeats()
        );
        const nodeRight$ = frp.compose(
            me.createUpdateStream(),
            frp.map(_ => lightR.getIntensity() > 0.5),
            rejectRepeats()
        );
        nodeLeft$(on => {
            me.rv.ActivateNode(nodeL, on);
        });
        nodeRight$(on => {
            me.rv.ActivateNode(nodeR, on);
        });
    });

    // Strobe lights
    const strobeLights: [light: rw.Light, node: string][] = [
        [new rw.Light("StrobeRearRight"), "strobe_rear_right"],
        [new rw.Light("StrobeRearLeft"), "strobe_rear_left"],
        [new rw.Light("StrobeFrontLeft"), "strobe_front_left"],
        [new rw.Light("StrobeFrontRight"), "strobe_front_right"],
    ];
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
        frp.map(elapsedS => {
            if (elapsedS === undefined) {
                return undefined;
            } else {
                const t = elapsedS % strobeLightCycleS;
                const strobeN = Math.floor(t / (strobeLightFlashS * 2));
                const strobeShow = t % (strobeLightFlashS * 2) < strobeLightFlashS;
                if (strobeN >= strobeLights.length || !strobeShow) {
                    return undefined;
                } else {
                    return strobeN;
                }
            }
        }),
        frp.merge(
            frp.compose(
                me.createPlayerWithoutKeyUpdateStream(),
                frp.merge(me.createAiUpdateStream()),
                frp.map(_ => undefined)
            )
        ),
        frp.hub()
    );
    for (const [i, [light, node]] of strobeLights.entries()) {
        const onOff$ = frp.compose(
            strobeLights$,
            frp.map(n => n === i),
            rejectRepeats()
        );
        onOff$(on => {
            light.Activate(on);
            me.rv.ActivateNode(node, on);
        });
    }

    // Head-end power
    const hep$ = ps.createHepStream(me, () => (me.rv.GetControlValue("HEP") as number) > 0.5);
    hep$(on => {
        me.rv.SetControlValue("HEP_State", on ? 1 : 0);
    });
    njt.createHepPopup(me);

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
    const reverserControl$ = me.createOnCvChangeStreamFor("UserVirtualReverser");
    reverserControl$(v => {
        me.rv.SetControlValue("Reverser", v);
    });
    const engineBrakeControl$ = me.createOnCvChangeStreamFor("VirtualEngineBrakeControl");
    engineBrakeControl$(v => {
        me.rv.SetControlValue("EngineBrakeControl", v);
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

    // Engine start/stop buttons
    const startupButtons$ = frp.compose(
        me.createOnCvChangeStreamFor("EngineStart"),
        frp.filter(v => v === 1),
        frp.merge(
            frp.compose(
                me.createOnCvChangeStreamFor("EngineStop"),
                frp.filter(v => v === 1),
                frp.map(_ => -1)
            )
        )
    );
    startupButtons$(v => {
        me.rv.SetControlValue("VirtualStartup", v);
        me.rv.SetControlValue("Startup", v);
    });

    // Wiper control
    const wipeWipers$ = frp.compose(me.createPlayerWithKeyUpdateStream(), me.mapGetCvStream("VirtualWipers"));
    wipeWipers$(v => {
        me.rv.SetControlValue("Wipers", v);
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
        rejectRepeats()
    );
    brakesAppliedLight$(on => {
        me.rv.ActivateNode("status_green", !on);
        me.rv.ActivateNode("status_yellow", on);
    });
    // We don't currently have a means of communicating with the rest of the
    // consist for the door state, so just turn this light off.
    const doorsOpenLight$ = frp.compose(
        me.createFirstUpdateStream(),
        frp.map(_ => false)
    );
    doorsOpenLight$(on => {
        me.rv.ActivateNode("status_red", on);
    });

    // Set platform door height.
    fx.setLowPlatformDoorsForEngine(me, true);

    // Miscellaneous NJT features
    njt.createDestinationSignSelector(me);
    njt.createManualDoorsPopup(me);

    // Enable updates.
    me.e.BeginUpdate();
});
me.setup();
