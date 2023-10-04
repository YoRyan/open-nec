/**
 * Amtrak Bombardier Acela Express
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { fsm, mapBehavior, movingAverage, rejectRepeats } from "lib/frp-extra";
import { ConsistMessage, SensedDirection } from "lib/frp-vehicle";
import * as m from "lib/math";
import { AduAspect } from "lib/nec/adu";
import * as cs from "lib/nec/cabsignals";
import * as adu from "lib/nec/twospeed-adu";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

enum PantographSelect {
    Front = "f",
    Both = "fr",
    Rear = "r",
}

enum DitchLights {
    Off,
    Fixed,
    Flash,
}

/**
 * Consist message ID's are used by the Acela's coaches. Do not change.
 */
enum ConsistMessageId {
    RaisePantographs = 1207,
    PantographSelect = 1208,
    TiltIsolate = 1209,
    Destination = 1210,
}

const destinations: [stop: string, value: number][] = [
    ["(No service)", 24],
    ["Union Station", 3],
    ["New Carrollton", 19],
    ["BWI Airport", 4],
    ["Baltimore Penn", 5],
    ["Wilmington", 6],
    ["Philadelphia", 2],
    ["Trenton", 11],
    ["Metropark", 18],
    ["Newark Penn", 1],
    ["New York", 27],
    ["New Rochelle", 7],
    ["Stamford", 8],
    ["New Haven", 9],
    ["New London", 10],
    ["Providence", 12],
    ["Route 128", 13],
    ["Back Bay", 14],
    ["South Station", 15],
];
const destinationsByStop = destinations.map(([stop]) => stop);
const destinationsByValue = destinations.map(([, value]) => value);

const ditchLightsFadeS = 0.3;
const ditchLightFlashS = 0.5;
const nDisplaySamples = 30;
const destinationScrollS = 0.3;

const me = new FrpEngine(() => {
    // Electric power supply
    const electrification = ps.createElectrificationBehaviorWithLua(me, ps.Electrification.Overhead);
    const isPowerAvailable = () => ps.uniModeEngineHasPower(ps.EngineMode.Overhead, electrification);
    // Player pantograph control
    const pantographsUpPlayer = () => (me.rv.GetControlValue("PantographControl") as number) > 0.5;
    const pantographSelectPlayer = () => {
        const cv = me.rv.GetControlValue("SelPanto") as number;
        if (cv < 0.5) {
            return PantographSelect.Front;
        } else if (cv < 1.5) {
            return PantographSelect.Both;
        } else {
            return PantographSelect.Rear;
        }
    };
    const pantographMessagePlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(pantographsUpPlayer),
        frp.map(bool => `${bool}`),
        frp.map((msg): [number, string] => [ConsistMessageId.RaisePantographs, msg]),
        frp.merge(
            frp.compose(
                me.createPlayerWithKeyUpdateStream(),
                mapBehavior(pantographSelectPlayer),
                frp.map(reversePantoSelect), // Assume all helper engines are flipped.
                frp.map((msg): [number, string] => [ConsistMessageId.PantographSelect, msg])
            )
        )
    );
    pantographMessagePlayer$(([id, msg]) => {
        me.rv.SendConsistMessage(id, msg, rw.ConsistDirection.Forward);
        me.rv.SendConsistMessage(id, msg, rw.ConsistDirection.Backward);
    });
    // Helper pantograph control (via consist message)
    const pantographsUpHelper = frp.stepper(
        frp.compose(
            me.createOnConsistMessageStream(),
            frp.filter(([id]) => id === ConsistMessageId.RaisePantographs),
            frp.map(([, msg]) => msg === "true")
        ),
        false
    );
    const pantographSelectHelper = frp.stepper(
        frp.compose(
            me.createOnConsistMessageStream(),
            frp.filter(([id]) => id === ConsistMessageId.PantographSelect),
            frp.map(([, msg]) => msg as PantographSelect)
        ),
        PantographSelect.Rear
    );
    const pantographMessageHelper$ = frp.compose(
        me.createOnConsistMessageStream(),
        frp.filter(([id]) => id === ConsistMessageId.RaisePantographs),
        frp.merge(
            frp.compose(
                me.createOnConsistMessageStream(),
                frp.filter(([id]) => id === ConsistMessageId.PantographSelect),
                // Assume all helper engines are flipped.
                frp.map(([id, msg, dir]): ConsistMessage => [id, reversePantoSelect(msg as PantographSelect), dir])
            )
        )
    );
    pantographMessageHelper$(message => {
        me.rv.SendConsistMessage(...message);
    });
    // Pantograph animations
    const pantographAnims = [new fx.Animation(me, "frontPanto", 2), new fx.Animation(me, "rearPanto", 2)];
    const raisePantographs$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (raise, select): [boolean, PantographSelect] => [raise, select],
                pantographsUpPlayer,
                pantographSelectPlayer
            )
        ),
        frp.merge(
            frp.compose(
                me.createPlayerWithoutKeyUpdateStream(),
                mapBehavior(
                    frp.liftN(
                        (raise, select): [boolean, PantographSelect] => [raise, select],
                        pantographsUpHelper,
                        pantographSelectHelper
                    )
                )
            )
        ),
        frp.map(([raise, select]): [boolean, boolean] => {
            if (!raise) {
                return [false, false];
            } else if (select === PantographSelect.Front) {
                return [true, false];
            } else if (select === PantographSelect.Rear) {
                return [false, true];
            } else {
                return [true, true];
            }
        }),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.map((au): [boolean, boolean] => {
                    switch (au.direction) {
                        // In a standard Acela trainset, both power cars use the
                        // rear panto.
                        case SensedDirection.Forward:
                        case SensedDirection.Backward:
                            return [false, true];
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
        [pantographAnims[0], new rw.Light("Spark"), ["Front_spark01", "Front_spark02"]],
        [pantographAnims[1], new rw.Light("Spark2"), ["Rear_spark01", "Rear_spark02"]],
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

    // Safety systems cut in/out
    const atcCutIn = () => !((me.rv.GetControlValue("ATCCutIn") as number) > 0.5);
    const acsesCutIn = () => !((me.rv.GetControlValue("ACSESCutIn") as number) > 0.5);
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
        equipmentSpeedMps: 150 * c.mph.toMps,
        pulseCodeControlValue: "CurrentAmtrakSignal",
    });
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(state => {
        me.rv.SetControlValue(
            "SigN",
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
            state.aspect === cs.AmtrakAspect.Approach ||
                state.aspect === cs.AmtrakAspect.ApproachMedium ||
                state.aspect === cs.AmtrakAspect.ApproachLimited
                ? 1
                : 0
        );
        me.rv.SetControlValue(
            "SigM",
            state.aspect === cs.AmtrakAspect.ApproachMedium ||
                (state.aspect === cs.AmtrakAspect.ApproachLimited && state.aspectFlashOn)
                ? 1
                : 0
        );
        me.rv.SetControlValue(
            "SigS",
            state.aspect === AduAspect.Stop || state.aspect === cs.AmtrakAspect.Restricting ? 1 : 0
        );
        me.rv.SetControlValue("SigR", state.aspect === cs.AmtrakAspect.Restricting ? 1 : 0);
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
            }[state.aspect]
        );

        if (state.trackSpeedMph !== undefined) {
            const [[h, t, u]] = m.digits(state.trackSpeedMph, 3);
            me.rv.SetControlValue("TSHundreds", h);
            me.rv.SetControlValue("TSTens", t);
            me.rv.SetControlValue("TSUnits", u);
        } else {
            me.rv.SetControlValue("TSHundreds", -1);
            me.rv.SetControlValue("TSTens", -1);
            me.rv.SetControlValue("TSUnits", -1);
        }

        let lamp: number;
        if (state.atcLamp) {
            lamp = 0;
        } else if (state.acsesLamp) {
            lamp = 1;
        } else {
            lamp = -1;
        }
        me.rv.SetControlValue("MaximumSpeedLimitIndicator", lamp);
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
    upgradeEvents$(_ => {
        me.rv.SetControlValue("AWSClearCount", me.rv.GetControlValue("AWSClearCount") === 0 ? 1 : 0);
    });

    // Cruise control
    const cruiseTargetMps = () => {
        const targetMph = me.rv.GetControlValue("CruiseControlSpeed") as number;
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
    const airBrake = frp.liftN(
        (isPenaltyBrake, input, fullService) => (isPenaltyBrake ? fullService : input),
        isPenaltyBrake,
        () => me.rv.GetControlValue("VirtualBrake") as number,
        0.6
    );
    const airBrake$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(airBrake));
    airBrake$(v => {
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
        () => me.rv.GetControlValue("VirtualThrottle") as number
    );
    const throttle$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(throttle));
    throttle$(v => {
        me.rv.SetControlValue("Regulator", v);
    });

    // Cab dome light
    const cabLight = new rw.Light("CabLight");
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

    // Horn rings the bell.
    const bellControl$ = frp.compose(
        me.createOnCvChangeStreamFor("Horn"),
        frp.filter(v => v === 1),
        me.mapAutoBellStream()
    );
    bellControl$(v => {
        me.rv.SetControlValue("Bell", v);
    });

    // Ditch lights
    const ditchLights = [
        new fx.FadeableLight(me, ditchLightsFadeS, "DitchLightLeft"),
        new fx.FadeableLight(me, ditchLightsFadeS, "DitchLightRight"),
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
    const ditchLightsAi$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map((au): [boolean, boolean] => {
            const [frontCoupled] = au.couplings;
            const ditchOn = !frontCoupled && au.direction === SensedDirection.Forward;
            return [ditchOn, ditchOn];
        })
    );
    const ditchLightsHelper$ = frp.compose(
        me.createPlayerWithoutKeyUpdateStream(),
        frp.map((_): [boolean, boolean] => [false, false])
    );
    const ditchLights$ = frp.compose(
        ditchLightsPlayer$,
        frp.map(([l, r]): [boolean, boolean] => [l, r]),
        frp.merge(ditchLightsAi$),
        frp.merge(ditchLightsHelper$)
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
    ditchNodeLeft$(on => {
        me.rv.ActivateNode("LeftOn", on);
        me.rv.ActivateNode("DitchLightsL", on);
    });
    ditchNodeRight$(on => {
        me.rv.ActivateNode("RightOn", on);
        me.rv.ActivateNode("DitchLightsR", on);
    });

    // Driving displays
    const displayUpdate$ = me.createPlayerWithKeyUpdateStream();
    displayUpdate$(_ => {
        const vehicleOn = (me.rv.GetControlValue("Startup") as number) > 0;
        me.rv.SetControlValue("ControlScreenIzq", vehicleOn ? 0 : 1);
        me.rv.SetControlValue("ControlScreenDer", vehicleOn ? 0 : 1);

        let pantoIndicator: number;
        if (!frp.snapshot(pantographsUpPlayer)) {
            pantoIndicator = -1;
        } else {
            const selected = frp.snapshot(pantographSelectPlayer);
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
        me.rv.SetControlValue("LightsIndicator", ditchLights);

        const speedoMph = me.rv.GetControlValue("SpeedometerMPH") as number;
        const [[h, t, u], guide] = m.digits(Math.round(speedoMph), 3);
        me.rv.SetControlValue("SPHundreds", h);
        me.rv.SetControlValue("SPTens", t);
        me.rv.SetControlValue("SPUnits", u);
        me.rv.SetControlValue("SpeedoGuide", guide);

        me.rv.SetControlValue("PowerState", frp.snapshot(cruiseOn) ? 8 : Math.floor(frp.snapshot(throttle) * 6 + 0.5));
    });
    const tractiveEffortKlbs$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => me.eng.GetTractiveEffort() * 300),
        movingAverage(nDisplaySamples)
    );
    tractiveEffortKlbs$(effortKlbs => {
        me.rv.SetControlValue("Effort", effortKlbs);
    });

    // Coupling hatch
    const hatchAnim = new fx.Animation(me, "cone", 2);
    const hatchOpenControl = () => (me.rv.GetControlValue("FrontCone") as number) > 0.5;
    const hatchOpenPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(pu => {
            const [frontCoupled] = pu.couplings;
            return frontCoupled || frp.snapshot(hatchOpenControl);
        })
    );
    const hatchOpen$ = frp.compose(
        me.createAiUpdateStream(),
        frp.merge(me.createPlayerWithoutKeyUpdateStream()),
        frp.map(u => {
            const [frontCoupled] = u.couplings;
            return frontCoupled;
        }),
        frp.merge(hatchOpenPlayer$)
    );
    hatchOpen$(open => {
        hatchAnim.setTargetPosition(open ? 1 : 0);
    });

    // Coach tilt isolate
    const tiltIsolateMessage$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("TiltIsolate"),
        frp.map(v => v > 0.5),
        fsm<boolean | undefined>(undefined),
        frp.filter(([from, to]) => from !== to),
        frp.map(([, to]) => (to ? "1" : "0"))
    );
    // This isn't a particularly important control, so we're not going to bother
    // sending it in the forward direction or forwarding it between helpers.
    tiltIsolateMessage$(msg => {
        me.rv.SendConsistMessage(ConsistMessageId.TiltIsolate, msg, rw.ConsistDirection.Backward);
    });

    // Destination selector
    const destinationMenu = new ui.ScrollingMenu("Set Destination Signs", destinationsByStop);
    const destinationScroll$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("DestJoy"),
        frp.filter(v => v === -1 || v === 1),
        frp.throttle(destinationScrollS * 1000)
    );
    destinationScroll$(move => {
        destinationMenu.scroll(move);
    });
    const destinationTurnedOn$ = frp.compose(
        me.createOnCvChangeStreamFor("DestOnOff"),
        frp.filter(v => v === 1)
    );
    destinationTurnedOn$(_ => {
        destinationMenu.showPopup();
    });
    // Send selected destination to the rest of the train via consist message.
    const destinationMessageAi$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map(_ => destinationsByValue[0]) // No service
    );
    const destinationMessage$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => {
            const signsOn = (me.rv.GetControlValue("DestOnOff") as number) > 0.5;
            const selected = destinationsByValue[destinationMenu.getSelection()];
            return signsOn ? selected : 0;
        }),
        frp.merge(destinationMessageAi$),
        rejectRepeats(),
        frp.map(dest => dest.toString())
    );
    destinationMessage$(msg => {
        me.rv.SendConsistMessage(ConsistMessageId.Destination, msg, rw.ConsistDirection.Forward);
        me.rv.SendConsistMessage(ConsistMessageId.Destination, msg, rw.ConsistDirection.Backward);
    });
    const destinationMessageHelper$ = frp.compose(
        me.createOnConsistMessageStream(),
        // All AI power cars send messages, so there's no need to forward any
        // between them.
        frp.filter(_ => me.rv.GetIsPlayer()),
        frp.filter(([id]) => id === ConsistMessageId.Destination)
    );
    destinationMessageHelper$(message => {
        me.rv.SendConsistMessage(...message);
    });

    // Process OnControlValueChange events.
    const onCvChange$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.reject(([name]) => name === "Bell")
    );
    onCvChange$(([name, value]) => {
        me.rv.SetControlValue(name, value);
    });

    // Enable updates.
    me.e.BeginUpdate();
});
me.setup();

function reversePantoSelect(select: PantographSelect) {
    switch (select) {
        case PantographSelect.Front:
        default:
            return PantographSelect.Rear;
        case PantographSelect.Both:
            return PantographSelect.Both;
        case PantographSelect.Rear:
            return PantographSelect.Front;
    }
}
