/**
 * NJ Transit Bombardier ALP-45DP
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { fsm, mapBehavior, rejectRepeats, rejectUndefined } from "lib/frp-extra";
import { AduAspect } from "lib/nec/adu";
import * as m from "lib/math";
import * as cs from "lib/nec/cabsignals";
import * as njt from "lib/nec/nj-transit";
import * as adu from "lib/nec/twospeed-adu";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

const dualModeSwitchS = 100;
const dieselPower = 3600 / 5900;
const ditchLightsFadeS = 0.3;
const intWipeTimeS = 3;

const me = new FrpEngine(() => {
    // Dual-mode power supply
    const electrification = ps.createElectrificationBehaviorWithControlValues(me, {
        [ps.Electrification.Overhead]: ["PowerState", 0],
        [ps.Electrification.ThirdRail]: undefined,
    });
    const modeSelect = () =>
        (me.rv.GetControlValue("PowerMode", 0) as number) > 0.5 ? ps.EngineMode.Overhead : ps.EngineMode.Diesel;
    const modeAuto = () => (me.rv.GetControlValue("PowerSwitchAuto", 0) as number) > 0.5;
    ui.createAutoPowerStatusPopup(me, modeAuto);
    const [modePosition$, modeSwitch$] = ps.createDualModeEngineStream(
        me,
        ps.EngineMode.Diesel,
        ps.EngineMode.Overhead,
        modeSelect,
        modeAuto,
        () => true, // We handle the transition lockout ourselves.
        dualModeSwitchS,
        false,
        ["PowerSwitchState", 0]
    );
    modeSwitch$(mode => {
        if (mode === ps.EngineMode.Diesel) {
            me.rv.SetControlValue("PowerMode", 0, 0);
        } else if (mode === ps.EngineMode.Overhead) {
            me.rv.SetControlValue("PowerMode", 0, 1);
        }
    });
    const modePosition = frp.stepper(modePosition$, 0);
    const pantographUp = () => (me.rv.GetControlValue("VirtualPantographControl", 0) as number) > 0.5;
    const powerProportion = frp.liftN(
        (position, pantographUp) => {
            if (position === 0) {
                return dieselPower;
            } else if (position === 1) {
                const haveElectrification = ps.uniModeEngineHasPower(ps.EngineMode.Overhead, electrification);
                return haveElectrification && pantographUp ? 1 : 0;
            } else {
                return 0;
            }
        },
        modePosition,
        pantographUp
    );
    const setPlayerPower$ = frp.compose(me.createPlayerUpdateStream(), mapBehavior(powerProportion));
    setPlayerPower$(power => {
        // Unlike the virtual throttle, this works for helper engines.
        me.eng.SetPowerProportion(-1, power);
    });
    // Power mode switch
    const canSwitchModes = frp.liftN(
        (controlsSettled, isStopped, throttle) => controlsSettled && isStopped && throttle <= 0,
        me.areControlsSettled,
        () => me.rv.GetSpeed() < c.stopSpeed,
        () => me.rv.GetControlValue("ThrottleAndBrake", 0) as number
    );
    const playerSwitchModesEasy$ = frp.compose(
        me.createOnCvChangeStreamFor("PowerSwitch", 0),
        frp.filter(v => v === 1),
        frp.map(_ => 1 - (me.rv.GetControlValue("PowerMode", 0) as number)),
        frp.filter(_ => frp.snapshot(canSwitchModes)),
        frp.hub()
    );
    const playerSwitchModes$ = frp.compose(
        me.createOnCvChangeStreamFor("VirtualPantographControl", 0),
        frp.merge(me.createOnCvChangeStreamFor("PantographSwitch", 0)),
        frp.filter(v => v === 1),
        frp.merge(
            frp.compose(
                me.createOnCvChangeStreamFor("FaultReset", 0),
                frp.filter(v => v === 1),
                frp.map(_ => 0)
            )
        ),
        frp.filter(_ => frp.snapshot(canSwitchModes)),
        frp.merge(playerSwitchModesEasy$)
    );
    playerSwitchModes$(v => {
        me.rv.SetControlValue("PowerMode", 0, v);
    });
    // Lower the pantograph near the end of the transition to diesel. Raise it
    // when switching to electric using the power switch hotkey.
    const setPantographAuto$ = frp.compose(
        modePosition$,
        fsm(0),
        frp.filter(([from, to]) => from > 0.03 && to <= 0.03),
        frp.map(_ => 0),
        frp.merge(
            frp.compose(
                playerSwitchModesEasy$,
                frp.filter(v => v === 1)
            )
        )
    );
    setPantographAuto$(v => {
        me.rv.SetControlValue("VirtualPantographControl", 0, v);
    });
    // Reset the fault reset switch once pressed.
    const faultReset$ = frp.compose(
        me.createOnCvChangeStreamFor("FaultReset", 0),
        frp.map(v => (v === 1 ? 0 : undefined)),
        rejectUndefined()
    );
    faultReset$(_ => {
        me.rv.SetControlTargetValue("FaultReset", 0, 0);
    });

    // Safety systems cut in/out
    // ATC and ACSES controls are reversed for NJT DLC.
    const atcCutIn = () => (me.rv.GetControlValue("ACSES", 0) as number) < 0.5;
    const acsesCutIn = () => (me.rv.GetControlValue("ATC", 0) as number) < 0.5;
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);
    const atcCutIn$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(atcCutIn));
    const acsesCutIn$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(acsesCutIn));
    atcCutIn$(active => {
        me.rv.SetControlValue("ATC_CutOut", 0, active ? 0 : 1);
    });
    acsesCutIn$(active => {
        me.rv.SetControlValue("ACSES_CutIn", 0, active ? 1 : 0);
        me.rv.SetControlValue("ACSES_CutOut", 0, active ? 0 : 1);
    });

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("VirtualBrake", 0) as number) > 0.5;
    const [aduState$, aduEvents$] = adu.create(
        cs.njTransitAtc,
        me,
        acknowledge,
        suppression,
        atcCutIn,
        acsesCutIn,
        100 * c.mph.toMps,
        ["ACSES_SpeedSignal", 0]
    );
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(state => {
        let signal: number;
        if (state.aspect === AduAspect.Stop) {
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
            }[state.aspect];
        } else {
            signal = 0;
        }
        me.rv.SetControlValue("ACSES_SignalDisplay", 0, signal);

        if (state.trackSpeedMph !== undefined) {
            const [[h, t, u]] = m.digits(state.trackSpeedMph, 3);
            me.rv.SetControlValue("ACSES_SpeedH", 0, h);
            me.rv.SetControlValue("ACSES_SpeedT", 0, t);
            me.rv.SetControlValue("ACSES_SpeedU", 0, u);
        } else {
            me.rv.SetControlValue("ACSES_SpeedH", 0, -1);
            me.rv.SetControlValue("ACSES_SpeedT", 0, -1);
            me.rv.SetControlValue("ACSES_SpeedU", 0, -1);
        }

        me.rv.SetControlValue("ATC_Node", 0, state.atcLamp ? 1 : 0);
        me.rv.SetControlValue("ACSES_Node", 0, state.acsesLamp ? 1 : 0);
    });
    const aduState = frp.stepper(aduStateHub$, undefined);
    // Alerter
    const alerterReset$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.filter(([name]) => name === "ThrottleAndBrake" || name === "VirtualBrake")
    );
    const alerterState = frp.stepper(ale.create(me, acknowledge, alerterReset$, alerterCutIn), undefined);
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
                (isPenaltyBrake, isPowerAvailable, input) => (isPenaltyBrake || !isPowerAvailable ? 0 : input),
                isPenaltyBrake,
                frp.liftN(power => power > 0, powerProportion),
                () => Math.max(me.rv.GetControlValue("ThrottleAndBrake", 0) as number, 0)
            )
        )
    );
    throttle$(v => {
        me.rv.SetControlValue("Regulator", 0, v);
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
                () => -Math.min(me.rv.GetControlValue("ThrottleAndBrake", 0) as number, 0)
            )
        )
    );
    dynamicBrake$(v => {
        me.rv.SetControlValue("DynamicBrake", 0, v);
    });

    // Speedometer
    const aSpeedoMph$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        me.mapGetCvStream("SpeedometerMPH", 0),
        frp.map(mph => Math.abs(mph)),
        frp.map(mph => Math.round(mph))
    );
    aSpeedoMph$(mph => {
        const [[h, t, u]] = m.digits(mph, 3);
        me.rv.SetControlValue("SpeedH", 0, h);
        me.rv.SetControlValue("SpeedT", 0, t);
        me.rv.SetControlValue("SpeedU", 0, u);
    });

    // Cab lights
    const domeLight = new rw.Light("CabLight");
    const deskLight = new rw.Light("DeskLight");
    const cabLightsNonPlayer$ = frp.compose(
        me.createAiUpdateStream(),
        frp.map(_ => false)
    );
    const domeLight$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("CabLight", 0) as number) > 0.5),
        frp.merge(cabLightsNonPlayer$),
        rejectRepeats()
    );
    const deskLight$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("DeskLight", 0) as number) > 0.5),
        frp.merge(cabLightsNonPlayer$),
        rejectRepeats()
    );
    domeLight$(on => {
        domeLight.Activate(on);
    });
    deskLight$(on => {
        deskLight.Activate(on);
    });

    // Ditch lights
    const ditchLights = [
        new fx.FadeableLight(me, ditchLightsFadeS, "DitchLight_Left"),
        new fx.FadeableLight(me, ditchLightsFadeS, "DitchLight_Right"),
    ];
    const areHeadLightsOn = () => {
        const cv = me.rv.GetControlValue("Headlights", 0) as number;
        return cv > 0.5 && cv < 1.5;
    };
    const ditchLightsOn$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (headLights, ditchOn) => headLights && ditchOn,
                areHeadLightsOn,
                () => (me.rv.GetControlValue("DitchLights", 0) as number) > 0.5
            )
        ),
        frp.merge(
            frp.compose(
                me.createPlayerWithoutKeyUpdateStream(),
                frp.merge(me.createAiUpdateStream()),
                frp.map(_ => false)
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
                mapBehavior(modeSelect),
                frp.map(mode => mode === ps.EngineMode.Overhead)
            )
        )
    );
    pantographUp$(up => {
        pantographAnim.setTargetPosition(up ? 1 : 0);
    });

    // Set the indicated RPM in diesel mode only.
    const trueRpm = () => me.rv.GetControlValue("RPM", 0) as number;
    const dieselRpm = frp.liftN((rpm, modePosition) => (modePosition < 0.3 ? rpm : 0), trueRpm, modePosition);
    const dieselRpm$ = frp.compose(me.createPlayerWithKeyUpdateStream(), mapBehavior(dieselRpm));
    dieselRpm$(rpm => {
        me.rv.SetControlValue("VirtualRPM", 0, rpm);
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
        me.createOnCvChangeStreamFor("VirtualHorn", 0),
        frp.filter(v => v === 1),
        me.mapAutoBellStream(true)
    );
    virtualBellControl$(v => {
        me.rv.SetControlValue("VirtualBell", 0, v);
    });
    const bellControl$ = frp.compose(me.createPlayerWithKeyUpdateStream(), me.mapGetCvStream("VirtualBell", 0));
    bellControl$(v => {
        me.rv.SetControlValue("Bell", 0, v);
    });

    // Wiper controls, including intermittent mode
    const wipersOn = () => (me.rv.GetControlValue("VirtualWipers", 0) as number) > 0.5;
    const wipersInt = () => (me.rv.GetControlValue("WipersInt", 0) as number) > 0.5;
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
        me.rv.SetControlValue("Wipers", 0, wipe ? 1 : 0);
    });

    // Head-end power
    const hep$ = ps.createHepStream(me, () => (me.rv.GetControlValue("HEP", 0) as number) > 0.5);
    hep$(on => {
        me.rv.SetControlValue("HEP_State", 0, on ? 1 : 0);
    });
    njt.createHepPopup(me);

    // Window opening sounds
    const windowOpen$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (left, right) => Math.max(left, right),
                () => me.rv.GetControlValue("WindowLeft", 0) as number,
                () => me.rv.GetControlValue("WindowRight", 0) as number
            )
        )
    );
    windowOpen$(v => {
        me.rv.SetControlValue("ExteriorSounds", 0, v);
    });

    // Link the various virtual controls.
    const hornControl$ = me.createOnCvChangeStreamFor("VirtualHorn", 0);
    hornControl$(v => {
        me.rv.SetControlValue("Horn", 0, v);
    });
    const startupControl$ = me.createOnCvChangeStreamFor("VirtualStartup", 0);
    startupControl$(v => {
        me.rv.SetControlValue("Startup", 0, v);
    });
    const sanderControl$ = me.createOnCvChangeStreamFor("VirtualSander", 0);
    sanderControl$(v => {
        me.rv.SetControlValue("Sander", 0, v);
    });
    const locoBrakeControl$ = me.createOnCvChangeStreamFor("VirtualEngineBrakeControl", 0);
    locoBrakeControl$(v => {
        me.rv.SetControlValue("EngineBrakeControl", 0, v);
    });
    const eBrakeControl$ = me.createOnCvChangeStreamFor("VirtualEmergencyBrake", 0);
    eBrakeControl$(v => {
        me.rv.SetControlValue("EmergencyBrake", 0, v);
    });

    // Link the control desk switches.
    const setHeadlights$ = frp.compose(
        me.createOnCvChangeStreamFor("HeadlightSwitch", 0),
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
        me.createOnCvChangeStreamFor("Headlights", 0),
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
        me.rv.SetControlValue("Headlights", 0, v);
    });
    moveHeadlightSwitch$(v => {
        me.rv.SetControlTargetValue("HeadlightSwitch", 0, v);
    });
    const moveWipersSwitch$ = frp.compose(
        me.createOnCvChangeStreamFor("VirtualWipers", 0),
        frp.merge(me.createOnCvChangeStreamFor("WipersInt", 0)),
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
        me.rv.SetControlTargetValue("WipersSwitch", 0, v);
    });
    const setPantograph$ = frp.compose(
        me.createOnCvChangeStreamFor("PantographSwitch", 0),
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
        me.rv.SetControlValue("VirtualPantographControl", 0, v);
        me.rv.SetControlTargetValue("PantographSwitch", 0, 0);
    });
    const setHandBrake$ = frp.compose(
        me.createOnCvChangeStreamFor("HandBrakeSwitch", 0),
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
        me.rv.SetControlValue("HandBrake", 0, v);
        me.rv.SetControlTargetValue("HandBrakeSwitch", 0, 0);
    });
    const moveDitchLightsSwitch$ = me.createOnCvChangeStreamFor("DitchLights", 0);
    moveDitchLightsSwitch$(v => {
        me.rv.SetControlTargetValue("DitchLightsSwitch", 0, v);
    });
    const moveCabLightSwitch$ = me.createOnCvChangeStreamFor("CabLight", 0);
    moveCabLightSwitch$(v => {
        me.rv.SetControlTargetValue("CabLightSwitch", 0, v);
    });
    const moveInstrumentLightsSwitch$ = me.createOnCvChangeStreamFor("InstrumentLights", 0);
    moveInstrumentLightsSwitch$(v => {
        me.rv.SetControlTargetValue("InstrumentLightsSwitch", 0, v);
    });
    const moveDeskLightSwitch$ = me.createOnCvChangeStreamFor("DeskLight", 0);
    moveDeskLightSwitch$(v => {
        me.rv.SetControlTargetValue("DeskLightSwitch", 0, v);
    });

    // Process OnControlValueChange events.
    const onCvChange$ = frp.compose(
        me.createOnCvChangeStream(),
        frp.reject(([name]) => name === "VirtualBell")
    );
    onCvChange$(([name, index, value]) => {
        me.rv.SetControlValue(name, index, value);
    });

    // Set consist brake lights.
    const brakesAppliedLight$ = frp.compose(
        fx.createBrakeLightStreamForEngine(me, () => (me.rv.GetControlValue("TrainBrakeControl", 0) as number) > 0),
        rejectRepeats()
    );
    brakesAppliedLight$(on => {
        me.rv.ActivateNode("LightsGreen", !on);
        me.rv.ActivateNode("LightsYellow", on);
    });
    const handBrakeLight$ = frp.compose(
        me.createUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("HandBrake", 0) as number) > 0),
        rejectRepeats()
    );
    handBrakeLight$(on => {
        me.rv.ActivateNode("LightsBlue", on);
    });

    // Set platform door height.
    fx.setLowPlatformDoorsForEngine(me, false);

    // Miscellaneous NJT features
    njt.createDestinationSignStream(me);
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
        me.rv.SetControlValue("UnitT", 0, t);
        me.rv.SetControlValue("UnitU", 0, u);
    }
}
