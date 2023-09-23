/**
 * NJ Transit/MARC MultiLevel Cab Car
 */

import * as ale from "lib/alerter";
import * as c from "lib/constants";
import * as frp from "lib/frp";
import { FrpEngine } from "lib/frp-engine";
import { fsm, mapBehavior, rejectRepeats, rejectUndefined } from "lib/frp-extra";
import { SensedDirection } from "lib/frp-vehicle";
import * as m from "lib/math";
import * as njt from "lib/nec/nj-transit";
import * as adu from "lib/nec/njt-adu";
import * as ps from "lib/power-supply";
import * as rw from "lib/railworks";
import { dieselPowerPct, dualModeOrder, dualModeSwitchS, pantographLowerPosition } from "lib/shared/alp45";
import * as fx from "lib/special-fx";
import * as ui from "lib/ui";

export enum Version {
    Alp45,
    Alp46,
    Marc,
}

const ditchLightsFadeS = 0.3;

export function onInit(me: FrpEngine, version: Version) {
    // Dual-mode power supply (for the ALP-45 version only)
    let powerAvailable: frp.Behavior<number>;
    if (version === Version.Alp45) {
        const electrification = ps.createElectrificationBehaviorWithControlValues(me, {
            [ps.Electrification.Overhead]: ["PowerState", 0],
            [ps.Electrification.ThirdRail]: undefined,
        });
        const modeAuto = () => (me.rv.GetControlValue("PowerSwitchAuto", 0) as number) > 0.5;
        ui.createAutoPowerStatusPopup(me, modeAuto);
        const modeAutoSwitch$ = ps.createDualModeAutoSwitchStream(me, ...dualModeOrder, modeAuto);
        modeAutoSwitch$(mode => {
            me.rv.SetControlValue("PowerMode", 0, mode === ps.EngineMode.Overhead ? 1 : 0);
        });
        const modeSelect = () =>
            (me.rv.GetControlValue("PowerMode", 0) as number) > 0.5 ? ps.EngineMode.Overhead : ps.EngineMode.Diesel;
        const modePosition = ps.createDualModeEngineBehavior(
            me,
            ...dualModeOrder,
            modeSelect,
            modeSelect,
            () => true, // We handle the transition lockout ourselves.
            dualModeSwitchS,
            modeAutoSwitch$,
            () => me.rv.GetControlValue("PowerSwitchState", 0) as number
        );
        const setModePosition$ = frp.compose(
            me.createPlayerWithKeyUpdateStream(),
            mapBehavior(modePosition),
            rejectRepeats()
        );
        setModePosition$(position => {
            me.rv.SetControlValue("PowerSwitchState", 0, position);
        });
        // Power mode switch
        // (The MultiLevel lacks a fault reset control, so we don't simulate the
        // Comet's manual sequence.)
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
        playerSwitchModesEasy$(v => {
            me.rv.SetControlValue("PowerMode", 0, v);
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
            me.rv.SetControlValue("VirtualPantographControl", 0, v);
        });

        powerAvailable = frp.liftN(
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
            () => (me.rv.GetControlValue("VirtualPantographControl", 0) as number) > 0.5
        );
    } else {
        powerAvailable = 1;
    }

    // Safety systems cut in/out
    // ATC and ACSES controls are reversed for NJT DLC.
    const atcCutIn = () => (me.rv.GetControlValue("ACSES", 0) as number) < 0.5;
    const acsesCutIn = () => (me.rv.GetControlValue("ATC", 0) as number) < 0.5;
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    const alerterCutIn = frp.liftN((atcCutIn, acsesCutIn) => atcCutIn || acsesCutIn, atcCutIn, acsesCutIn);
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("VirtualBrake", 0) as number) > 0.5;
    const aSpeedoMph = () => Math.abs(me.rv.GetControlValue("SpeedometerMPH", 0) as number);
    const equipmentSpeedMps = (version === Version.Marc ? 125 : 100) * c.mph.toMps;
    const [aduState$, aduEvents$] = adu.create(me, acknowledge, suppression, atcCutIn, acsesCutIn, equipmentSpeedMps, [
        "ACSES_SpeedSignal",
        0,
    ]);
    const aduStateHub$ = frp.compose(aduState$, frp.hub());
    aduStateHub$(state => {
        const [[h, t, u], guide] = m.digits(Math.round(frp.snapshot(aSpeedoMph)), 3);
        me.rv.SetControlValue("SpeedH", 0, state.clearAspect ? h : -1);
        me.rv.SetControlValue("SpeedT", 0, state.clearAspect ? t : -1);
        me.rv.SetControlValue("SpeedU", 0, state.clearAspect ? u : -1);
        me.rv.SetControlValue("Speed2H", 0, !state.clearAspect ? h : -1);
        me.rv.SetControlValue("Speed2T", 0, !state.clearAspect ? t : -1);
        me.rv.SetControlValue("Speed2U", 0, !state.clearAspect ? u : -1);
        me.rv.SetControlValue("SpeedP", 0, guide);

        me.rv.SetControlValue("ACSES_SpeedGreen", 0, state.masSpeedMph ?? 0);
        me.rv.SetControlValue("ACSES_SpeedRed", 0, state.excessSpeedMph ?? 0);
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
    if (version === Version.Alp45) {
        const awsUpdate$ = frp.compose(
            me.createPlayerWithKeyUpdateStream(),
            mapBehavior(
                frp.liftN(
                    (aduState, alerterState, upgradeSound) => {
                        const alarm = (aduState?.atcAlarm || aduState?.acsesAlarm || alerterState?.alarm) ?? false;
                        return {
                            awsWarnCount: alarm,
                            aws: alarm || upgradeSound,
                        };
                    },
                    aduState,
                    alerterState,
                    frp.stepper(upgradeSound$, false)
                )
            )
        );
        awsUpdate$(cvs => {
            me.rv.SetControlValue("AWSWarnCount", 0, cvs.awsWarnCount ? 1 : 0);
            me.rv.SetControlValue("AWS", 0, cvs.aws ? 1 : 0);
        });
    } else {
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
    }

    // Manual door control
    njt.createManualDoorsPopup(me);
    const passengerDoors = njt.createManualDoorsBehavior(me);
    const areDoorsOpen = frp.liftN(([left, right]) => left > 0 || right > 0, passengerDoors);
    const leftDoor$ = frp.compose(
        me.createUpdateStream(),
        mapBehavior(passengerDoors),
        frp.map(([left]) => left),
        rejectRepeats()
    );
    const rightDoor$ = frp.compose(
        me.createUpdateStream(),
        mapBehavior(passengerDoors),
        frp.map(([, right]) => right),
        rejectRepeats()
    );
    leftDoor$(position => {
        me.rv.SetTime("Doors_L", position);
    });
    rightDoor$(position => {
        me.rv.SetTime("Doors_R", position);
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
                (isPenaltyBrake, available, input) => (isPenaltyBrake ? 0 : available * input),
                isPenaltyBrake,
                powerAvailable,
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
                (isPenaltyBrake, areDoorsOpen, input) => (isPenaltyBrake || areDoorsOpen ? 0.6 : input),
                isPenaltyBrake,
                areDoorsOpen,
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

    // Cab lights
    const domeLights = [new rw.Light("CabLight"), new rw.Light("CabLight2")];
    const cabLightsNonPlayer$ = frp.compose(
        me.createAiUpdateStream(),
        frp.merge(me.createPlayerWithoutKeyUpdateStream()),
        frp.map(_ => false)
    );
    const domeLight$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        frp.map(_ => (me.rv.GetControlValue("CabLight", 0) as number) > 0.5),
        frp.merge(cabLightsNonPlayer$),
        rejectRepeats()
    );
    domeLight$(on => {
        domeLights.forEach(light => light.Activate(on));
        me.rv.ActivateNode("cablights", on);
    });

    // Ditch lights
    const ditchLights = [
        new fx.FadeableLight(me, ditchLightsFadeS, "Ditch_L"),
        new fx.FadeableLight(me, ditchLightsFadeS, "Ditch_R"),
    ];
    const ditchLightsPlayer$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (headLights, ditchLights) => headLights && ditchLights,
                () => (me.rv.GetControlValue("Headlights", 0) as number) > 1.5,
                () => (me.rv.GetControlValue("DitchLights", 0) as number) > 0.5
            )
        ),
        frp.map((ditchOn): [boolean, boolean] => [ditchOn, ditchOn])
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
        me.rv.ActivateNode("ditch_left", on);
    });
    ditchNodeRight$(on => {
        me.rv.ActivateNode("ditch_right", on);
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
    // Wiper control
    const wipersOn = () => (me.rv.GetControlValue("VirtualWipers", 0) as number) > 0.5;
    const wipeWipers$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(wipersOn),
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
    const hepLights: rw.Light[] = [];
    for (let i = 0; i < 8; i++) {
        hepLights.push(new rw.Light(`Carriage Light ${i + 1}`));
    }
    const hep$ = frp.compose(
        ps.createHepStream(me, () => (me.rv.GetControlValue("HEP", 0) as number) > 0.5),
        rejectRepeats()
    );
    hep$(on => {
        hepLights.forEach(light => light.Activate(on));
        me.rv.ActivateNode("1_1000_LitInteriorLights", on);
        me.rv.SetControlValue("HEP_State", 0, on ? 1 : 0);
    });
    njt.createHepPopup(me);

    // Link the various virtual controls.
    const reverserControl$ = me.createOnCvChangeStreamFor("UserVirtualReverser", 0);
    reverserControl$(v => {
        me.rv.SetControlValue("Reverser", 0, v);
    });
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
    const eBrakeControl$ = me.createOnCvChangeStreamFor("VirtualEmergencyBrake", 0);
    eBrakeControl$(v => {
        me.rv.SetControlValue("EmergencyBrake", 0, v);
    });

    // Link the control desk switches.
    const setHeadlights$ = frp.compose(
        me.createOnCvChangeStreamFor("HeadlightSwitch", 0),
        frp.map(v => {
            switch (v) {
                case 0:
                    return 0;
                case 1:
                    return 2;
                case 2:
                    return 3;
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
                case 2:
                    return 1;
                case 3:
                    return 2;
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
    const doorsOpenLight$ = frp.compose(me.createUpdateStream(), mapBehavior(areDoorsOpen), rejectRepeats());
    doorsOpenLight$(on => {
        me.rv.ActivateNode("LightsRed", on);
    });

    // Set platform door height.
    fx.setLowPlatformDoorsForEngine(me, false);

    // Destination signs
    const destinations =
        version === Version.Marc
            ? ["MARC", "No PAX", "Union Station", "Penn Station", "Martin State Airport", "Perryville"]
            : undefined;
    njt.createDestinationSignSelector(me, destinations);

    // Enable updates.
    me.e.BeginUpdate();
}
