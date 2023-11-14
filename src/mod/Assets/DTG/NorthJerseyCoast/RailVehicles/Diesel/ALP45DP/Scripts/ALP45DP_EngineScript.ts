/**
 * NJ Transit Bombardier ALP-45DP
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { fsm, mapBehavior, rejectRepeats, rejectUndefined } from "lib/frp-extra";
import { SensedDirection } from "lib/frp-vehicle";
import * as m from "lib/math";
import { AduAspect } from "lib/nec/adu";
import * as cs from "lib/nec/cabsignals";
import * as njt from "lib/nec/nj-transit";
import * as adu from "lib/nec/twospeed-adu";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import { dieselPowerPct, dualModeOrder, dualModeSwitchS, pantographLowerPosition } from "lib/shared/alp45";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

const ditchLightsFadeS = 0.3;
const intWipeTimeS = 3;

const me = new FrpEngine(() => {
    // Dual-mode power supply
    const electrification = ps.createElectrificationBehaviorWithControlValues(me, {
        [ps.Electrification.Overhead]: "PowerState",
        [ps.Electrification.ThirdRail]: undefined,
    });
    const modeAuto = () => (me.rv.GetControlValue("PowerSwitchAuto") as number) > 0.5;
    ui.createAutoPowerStatusPopup(me, modeAuto);
    const modeAutoSwitch$ = ps.createDualModeAutoSwitchStream(me, ...dualModeOrder, modeAuto);
    modeAutoSwitch$(mode => {
        me.rv.SetControlValue("PowerMode", mode === ps.EngineMode.Overhead ? 1 : 0);
    });
    const modeSelect = () =>
        (me.rv.GetControlValue("PowerMode") as number) > 0.5 ? ps.EngineMode.Overhead : ps.EngineMode.Diesel;
    const modePosition = ps.createDualModeEngineBehavior({
        e: me,
        modes: dualModeOrder,
        getPlayerMode: modeSelect,
        getAiMode: modeSelect,
        getPlayerCanSwitch: () => true,
        transitionS: dualModeSwitchS,
        instantSwitch: modeAutoSwitch$,
        positionFromSaveOrConsist: () => me.rv.GetControlValue("PowerSwitchState") as number,
    });
    const setModePosition$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(modePosition),
        rejectRepeats()
    );
    setModePosition$(position => {
        me.rv.SetControlValue("PowerSwitchState", position);
    });
    // Power mode switch
    const canSwitchModes = frp.liftN(
        (controlsSettled, isStopped, throttle) => controlsSettled && isStopped && throttle <= 0,
        me.areControlsSettled,
        () => me.rv.GetSpeed() < c.stopSpeed,
        () => me.rv.GetControlValue("ThrottleAndBrake") as number
    );
    const playerSwitchModesEasy$ = frp.compose(
        me.createOnCvChangeStreamFor("PowerSwitch"),
        frp.filter(v => v === 1),
        frp.map(_ => 1 - (me.rv.GetControlValue("PowerMode") as number)),
        frp.filter(_ => frp.snapshot(canSwitchModes)),
        frp.hub()
    );
    const playerSwitchModes$ = frp.compose(
        me.createOnCvChangeStreamFor("VirtualPantographControl"),
        frp.merge(me.createOnCvChangeStreamFor("PantographSwitch")),
        frp.filter(v => v === 1),
        frp.merge(
            frp.compose(
                me.createOnCvChangeStreamFor("FaultReset"),
                frp.filter(v => v === 1),
                frp.map(_ => 0)
            )
        ),
        frp.filter(_ => frp.snapshot(canSwitchModes)),
        frp.merge(playerSwitchModesEasy$)
    );
    playerSwitchModes$(v => {
        me.rv.SetControlValue("PowerMode", v);
    });
    // Lower the pantograph near the end of the transition to diesel. Raise it
    // when switching to electric using the power switch hotkey.
    const setPantographAuto$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(modePosition),
        fsm(0),
        frp.filter(([from, to]) => from > pantographLowerPosition && to <= pantographLowerPosition),
        frp.map(_ => 0),
        frp.merge(
            frp.compose(
                playerSwitchModesEasy$,
                frp.filter(v => v === 1)
            )
        )
    );
    setPantographAuto$(v => {
        me.rv.SetControlValue("VirtualPantographControl", v);
    });
    // Reset the fault reset switch once pressed.
    const faultReset$ = frp.compose(
        me.createOnCvChangeStreamFor("FaultReset"),
        frp.map(v => (v === 1 ? 0 : undefined)),
        rejectUndefined()
    );
    faultReset$(_ => {
        me.rv.SetControlTargetValue("FaultReset", 0);
    });

    // Safety systems cut in/out
    // ATC and ACSES controls are reversed for NJT DLC.
    const atcCutIn = () => !((me.rv.GetControlValue("ACSES") as number) > 0.5);
    const acsesCutIn = () => !((me.rv.GetControlValue("ATC") as number) > 0.5);
    const updateCutIns$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN((atcCutIn, acsesCutIn): [boolean, boolean] => [atcCutIn, acsesCutIn], atcCutIn, acsesCutIn)
        )
    );
    updateCutIns$(([atc, acses]) => {
        me.rv.SetControlValue("ATC_CutOut", atc ? 0 : 1);
        me.rv.SetControlValue("ACSES_CutIn", acses ? 1 : 0);
        me.rv.SetControlValue("ACSES_CutOut", acses ? 0 : 1);
    });
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("VirtualBrake") as number) > 0.5;
    const [aduState$, aduEvents$] = adu.create({
        atc: cs.njTransitAtc,
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
        const { aspect } = state;
        let signal: number;
        if (aspect === AduAspect.Stop) {
            signal = 8;
        } else if (frp.snapshot(atcCutIn)) {
            signal = {
                [cs.NjTransitAspect.Restricting]: 7,
                [cs.NjTransitAspect.Approach]: 6,
                [cs.NjTransitAspect.ApproachMedium]: 5,
                [cs.NjTransitAspect.ApproachLimited]: 4,
                [cs.NjTransitAspect.CabSpeed60]: 3,
                [cs.NjTransitAspect.CabSpeed80]: 2,
                [cs.NjTransitAspect.Clear]: 1,
            }[aspect];
        } else {
            signal = 0;
        }
        me.rv.SetControlValue("ACSES_SignalDisplay", signal);

        const { trackSpeedMph } = state;
        if (trackSpeedMph !== undefined) {
            const [[h, t, u]] = m.digits(trackSpeedMph, 3);
            me.rv.SetControlValue("ACSES_SpeedH", h);
            me.rv.SetControlValue("ACSES_SpeedT", t);
            me.rv.SetControlValue("ACSES_SpeedU", u);
        } else {
            me.rv.SetControlValue("ACSES_SpeedH", -1);
            me.rv.SetControlValue("ACSES_SpeedT", -1);
            me.rv.SetControlValue("ACSES_SpeedU", -1);
        }

        const { atcLamp, acsesLamp } = state;
        me.rv.SetControlValue("ATC_Node", atcLamp ? 1 : 0);
        me.rv.SetControlValue("ACSES_Node", acsesLamp ? 1 : 0);
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterReset$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.filter(([name]) => name === "ThrottleAndBrake" || name === "VirtualBrake")
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
    const pantographUp = () => (me.rv.GetControlValue("VirtualPantographControl") as number) > 0.5;
    const isPenaltyBrake = frp.liftN(
        (aduState, alerterState) => (aduState?.penaltyBrake || alerterState?.penaltyBrake) ?? false,
        aduState,
        alerterState
    );
    const powerAvailable = frp.liftN(
        (modePosition, pantographUp) => {
            if (modePosition === 0) {
                return dieselPowerPct;
            } else if (modePosition === 1) {
                const haveElectrification = ps.uniModeEngineHasPower(ps.EngineMode.Overhead, electrification);
                return haveElectrification && pantographUp ? 1 : 0;
            } else {
                return 0;
            }
        },
        modePosition,
        pantographUp
    );
    const throttle$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (isPenaltyBrake, available, input) => (isPenaltyBrake ? 0 : available * input),
                isPenaltyBrake,
                powerAvailable,
                () => Math.max(me.rv.GetControlValue("ThrottleAndBrake") as number)
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
                    const blended = Math.min((110 - bpPsi) / 16, 1);
                    return Math.max(blended, input);
                },
                () => me.rv.GetControlValue("AirBrakePipePressurePSI") as number,
                () => -Math.min(me.rv.GetControlValue("ThrottleAndBrake") as number)
            )
        )
    );
    dynamicBrake$(v => {
        me.rv.SetControlValue("DynamicBrake", v);
    });

    // Speedometer
    const speedoMph$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(me.createSpeedometerDigitsMphBehavior(3))
    );
    speedoMph$(([[h, t, u]]) => {
        me.rv.SetControlValue("SpeedH", h);
        me.rv.SetControlValue("SpeedT", t);
        me.rv.SetControlValue("SpeedU", u);
    });

    // Cab lights
    const domeLight = new rw.Light("CabLight");
    const deskLight = new rw.Light("DeskLight");
    const cabLightsNonPlayer$ = frp.compose(
        me.createAiUpdateStream(),
        frp.merge(me.createPlayerWithoutKeyUpdateStream()),
        frp.map(_ => false)
    );
    const domeLight$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("CabLight") as number) > 0.5),
        frp.merge(cabLightsNonPlayer$),
        rejectRepeats()
    );
    const deskLight$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("DeskLight") as number) > 0.5),
        frp.merge(cabLightsNonPlayer$),
        rejectRepeats()
    );
    domeLight$(on => {
        domeLight.Activate(on);
    });
    deskLight$(on => {
        deskLight.Activate(on);
    });
    // The dome light is on by default, which obscures the cab signal aspects.
    const domeLightDefault$ = frp.compose(
        me.createFirstUpdateAfterControlsSettledStream(),
        frp.filter(resumeFromSave => !resumeFromSave),
        frp.map(_ => 0)
    );
    domeLightDefault$(v => {
        me.rv.SetControlValue("CabLight", v);
    });

    // Ditch lights
    const ditchLights = [
        new fx.FadeableLight(me, ditchLightsFadeS, "DitchLight_Left"),
        new fx.FadeableLight(me, ditchLightsFadeS, "DitchLight_Right"),
    ];
    const areHeadLightsOn = () => {
        const cv = me.rv.GetControlValue("Headlights") as number;
        return cv > 0.5 && cv < 1.5;
    };
    const ditchLightsOn$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (headLights, ditchOn) => headLights && ditchOn,
                areHeadLightsOn,
                () => (me.rv.GetControlValue("DitchLights") as number) > 0.5
            )
        ),
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
        )
    );
    ditchLightsOn$(on => {
        ditchLights.forEach(light => light.setOnOff(on));
    });
    const ditchNodes$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => {
            const [light] = ditchLights;
            return light.getIntensity() > 0.5;
        }),
        rejectRepeats()
    );
    ditchNodes$(on => {
        me.rv.ActivateNode("ditch_left", on);
        me.rv.ActivateNode("ditch_right", on);
    });

    // Pantograph animation
    const pantographAnim = new fx.Animation(me, "Pantograph", 2);
    const pantographUp$ = frp.compose(
        me.createPlayerUpdateStream(),
        mapBehavior(pantographUp),
        frp.merge(
            frp.compose(
                me.createAiUpdateStream(),
                frp.map(au => au.direction !== SensedDirection.None),
                frp.map(moving => moving && frp.snapshot(modeSelect) === ps.EngineMode.Overhead)
            )
        )
    );
    pantographUp$(up => {
        pantographAnim.setTargetPosition(up ? 1 : 0);
    });

    // Set the indicated RPM in diesel mode only.
    const trueRpm = () => me.rv.GetControlValue("RPM") as number;
    const dieselRpm = frp.liftN((rpm, modePosition) => (modePosition < 0.3 ? rpm : 0), trueRpm, modePosition);
    const dieselRpm$ = frp.compose(me.createUpdateStream(), mapBehavior(dieselRpm));
    dieselRpm$(rpm => {
        me.rv.SetControlValue("VirtualRPM", rpm);
    });

    // Diesel exhaust
    // Exhaust algorithm copied from that of the GP40PH.
    const exhaustEmitters = [
        new rw.Emitter("Exhaust1"),
        new rw.Emitter("Exhaust2"),
        new rw.Emitter("Exhaust3"),
        new rw.Emitter("Exhaust4"),
    ];
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
                const isDiesel = dieselRpm > 0;
                const rpmScaled = (dieselRpm - 600) / (1800 - 600); // from 0 to 1
                return isDiesel ? rpmScaled * 2 + 1 : 0;
            }, dieselRpm)
        )
    );
    exhaustFanSpeed$(hz => {
        exhaustFans.setFrequency(hz);
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

    // Wiper controls, including intermittent mode
    const wipersOn = () => (me.rv.GetControlValue("VirtualWipers") as number) > 0.5;
    const wipersInt = () => (me.rv.GetControlValue("WipersInt") as number) > 0.5;
    const wipeWipers$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        fx.loopSound(
            intWipeTimeS,
            frp.liftN((wipersOn, wipersInt) => wipersOn && wipersInt, wipersOn, wipersInt)
        ),
        frp.map(play => !play),
        frp.map(intWipe => {
            const fastWipe = !frp.snapshot(wipersInt);
            return frp.snapshot(wipersOn) && (intWipe || fastWipe);
        }),
        frp.merge(
            frp.compose(
                me.createPlayerWithoutKeyUpdateStream(),
                frp.merge(me.createAiUpdateStream()),
                frp.map(_ => false)
            )
        )
    );
    wipeWipers$(wipe => {
        me.rv.SetControlValue("Wipers", wipe ? 1 : 0);
    });

    // Head-end power
    const hep$ = ps.createHepStream(me, () => (me.rv.GetControlValue("HEP") as number) > 0.5);
    hep$(on => {
        me.rv.SetControlValue("HEP_State", on ? 1 : 0);
    });
    njt.createHepPopup(me);

    // Window opening sounds
    const windowOpen$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (left, right) => Math.max(left, right),
                () => me.rv.GetControlValue("WindowLeft") as number,
                () => me.rv.GetControlValue("WindowRight") as number
            )
        )
    );
    windowOpen$(v => {
        me.rv.SetControlValue("ExteriorSounds", v);
    });

    // Link the various virtual controls.
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
    const locoBrakeControl$ = me.createOnCvChangeStreamFor("VirtualEngineBrakeControl");
    locoBrakeControl$(v => {
        me.rv.SetControlValue("EngineBrakeControl", v);
    });
    const eBrakeControl$ = me.createOnCvChangeStreamFor("VirtualEmergencyBrake");
    eBrakeControl$(v => {
        me.rv.SetControlValue("EmergencyBrake", v);
    });

    // Link the control desk switches.
    const setHeadlights$ = frp.compose(
        me.createOnCvChangeStreamFor("HeadlightSwitch"),
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
        me.createOnCvChangeStreamFor("Headlights"),
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
        me.rv.SetControlValue("Headlights", v);
    });
    moveHeadlightSwitch$(v => {
        me.rv.SetControlTargetValue("HeadlightSwitch", v);
    });
    const moveWipersSwitch$ = frp.compose(
        me.createOnCvChangeStreamFor("VirtualWipers"),
        frp.merge(me.createOnCvChangeStreamFor("WipersInt")),
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
        me.rv.SetControlTargetValue("WipersSwitch", v);
    });
    const setPantograph$ = frp.compose(
        me.createOnCvChangeStreamFor("PantographSwitch"),
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
        me.rv.SetControlValue("VirtualPantographControl", v);
        me.rv.SetControlTargetValue("PantographSwitch", 0);
    });
    const setHandBrake$ = frp.compose(
        me.createOnCvChangeStreamFor("HandBrakeSwitch"),
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
        me.rv.SetControlValue("HandBrake", v);
        me.rv.SetControlTargetValue("HandBrakeSwitch", 0);
    });
    const moveDitchLightsSwitch$ = me.createOnCvChangeStreamFor("DitchLights");
    moveDitchLightsSwitch$(v => {
        me.rv.SetControlTargetValue("DitchLightsSwitch", v);
    });
    const moveCabLightSwitch$ = me.createOnCvChangeStreamFor("CabLight");
    moveCabLightSwitch$(v => {
        me.rv.SetControlTargetValue("CabLightSwitch", v);
    });
    const moveInstrumentLightsSwitch$ = me.createOnCvChangeStreamFor("InstrumentLights");
    moveInstrumentLightsSwitch$(v => {
        me.rv.SetControlTargetValue("InstrumentLightsSwitch", v);
    });
    const moveDeskLightSwitch$ = me.createOnCvChangeStreamFor("DeskLight");
    moveDeskLightSwitch$(v => {
        me.rv.SetControlTargetValue("DeskLightSwitch", v);
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
        me.rv.ActivateNode("LightsGreen", !on);
        me.rv.ActivateNode("LightsYellow", on);
    });
    const handBrakeLight$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("HandBrake") as number) > 0),
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
        me.rv.SetControlValue("UnitT", t);
        me.rv.SetControlValue("UnitU", u);
    }
}
