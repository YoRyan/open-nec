/**
 * NJ Transit Comet V Cab Car
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

enum DitchLights {
    Off,
    Fixed,
    Flash,
}

const ditchLightsFadeS = 0.3;
const ditchLightFlashS = 0.65;

const me = new FrpEngine(() => {
    // Dual-mode power supply (for the ALP-45 version only)
    let powerAvailable: frp.Behavior<number>;
    if (me.rv.ControlExists("PowerMode")) {
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
            getAiMode: ps.EngineMode.Diesel,
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
            () => (me.rv.GetControlValue("VirtualPantographControl") as number) > 0.5
        );
    } else {
        powerAvailable = 1;
    }

    // Safety systems cut in/out
    // ATC and ACSES controls are reversed for NJT DLC.
    const atcCutIn = () => !((me.rv.GetControlValue("ACSES") as number) > 0.5);
    const acsesCutIn = () => !((me.rv.GetControlValue("ATC") as number) > 0.5);
    ui.createAtcStatusPopup(me, atcCutIn);
    ui.createAcsesStatusPopup(me, acsesCutIn);
    // Some versions of the Comet have no alarm sound, so having an alerter isn't a good idea.
    const alerterCutIn = false;
    ui.createAlerterStatusPopup(me, alerterCutIn);

    // Safety systems and ADU
    const acknowledge = me.createAcknowledgeBehavior();
    const suppression = () => (me.rv.GetControlValue("VirtualBrake") as number) > 0.5;
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
    const alarmsUpdate$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (aduState, alerterState, upgradeSound) => {
                    const awsWarnCount = (aduState?.atcAlarm || aduState?.acsesAlarm || alerterState?.alarm) ?? false;
                    const aws = awsWarnCount || upgradeSound;
                    return { awsWarnCount, aws };
                },
                aduState,
                alerterState,
                frp.stepper(upgradeSound$, false)
            )
        )
    );
    alarmsUpdate$(cvs => {
        me.rv.SetControlValue("AWSWarnCount", cvs.awsWarnCount ? 1 : 0);
        me.rv.SetControlValue("AWS", cvs.aws ? 1 : 0);
    });

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
        me.rv.SetTime("Doors_L", position * 2);
    });
    rightDoor$(position => {
        me.rv.SetTime("Doors_R", position * 2);
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
                (isPenaltyBrake, areDoorsOpen, input) => (isPenaltyBrake || areDoorsOpen ? 0.6 : input),
                isPenaltyBrake,
                areDoorsOpen,
                () => me.rv.GetControlValue("VirtualBrake") as number
            )
        )
    );
    airBrake$(v => {
        me.rv.SetControlValue("TrainBrakeControl", v);
    });
    // DTG's "blended braking" algorithm
    const brakePipePsi = () => me.rv.GetControlValue("AirBrakePipePressurePSI") as number;
    // The GP40 version tops out at 90 psi, which breaks DTG's algorithm and
    // forces the dynamic brake always on (yes, in vanilla, too), so disable
    // blended braking for that version.
    const blendedBrakeEnabled = frp.stepper(
        frp.compose(
            me.createPlayerWithKeyUpdateStream(),
            mapBehavior(brakePipePsi),
            frp.fold((accum: number, psi) => Math.max(accum, psi), 0),
            frp.map(psi => psi > 90)
        ),
        false
    );
    const dynamicBrake$ = frp.compose(
        me.createPlayerWithKeyUpdateStream(),
        mapBehavior(
            frp.liftN(
                (blendEnabled, bpPsi, input) => {
                    if (blendEnabled) {
                        const blended = Math.min((110 - bpPsi) / 16, 1);
                        return Math.max(blended, input);
                    } else {
                        return input;
                    }
                },
                blendedBrakeEnabled,
                brakePipePsi,
                () => -Math.min(me.rv.GetControlValue("ThrottleAndBrake") as number)
            )
        )
    );
    dynamicBrake$(v => {
        me.rv.SetControlValue("DynamicBrake", v);
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
        frp.map(_ => (me.rv.GetControlValue("CabLight") as number) > 0.5),
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
    const areHeadLightsOn = () => (me.rv.GetControlValue("Headlights") as number) > 1.5;
    let ditchLightsSetting: frp.Behavior<DitchLights>;
    if (me.rv.ControlExists("DitchLightSwitch")) {
        ditchLightsSetting = frp.liftN(
            (headLights, cv) => {
                if (!headLights || cv < 0.5) {
                    return DitchLights.Off;
                } else if (cv < 1.5) {
                    return DitchLights.Fixed;
                } else {
                    return DitchLights.Flash;
                }
            },
            areHeadLightsOn,
            () => me.rv.GetControlValue("DitchLightSwitch") as number
        );
    } else {
        // The F40PH version lacks the switch control value.
        ditchLightsSetting = frp.liftN(
            (headLights, cv) => {
                if (!headLights || cv < 0.333) {
                    return DitchLights.Off;
                } else if (cv < 0.667) {
                    return DitchLights.Fixed;
                } else {
                    return DitchLights.Flash;
                }
            },
            areHeadLightsOn,
            () => me.rv.GetControlValue("DitchLights") as number
        );
    }
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

    // Wiper control
    const wipersOn = () => (me.rv.GetControlValue("VirtualWipers") as number) > 0.5;
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
        me.rv.SetControlValue("Wipers", wipe ? 1 : 0);
    });
    // For the F40PH, which maps the V key to the non-virtual control value.
    const setVirtualWipers$ = frp.compose(
        me.createOnCvChangeStreamFor("Wipers"),
        frp.filter(v => v === 0 || v === 1)
    );
    setVirtualWipers$(v => {
        me.rv.SetControlTargetValue("VirtualWipers", v);
    });

    // Head-end power
    const hepLights: rw.Light[] = [];
    for (let i = 0; i < 8; i++) {
        hepLights.push(new rw.Light(`Carriage Light ${i + 1}`));
    }
    const hep$ = frp.compose(
        ps.createHepStream(me, () => (me.rv.GetControlValue("HEP") as number) > 0.5),
        rejectRepeats()
    );
    hep$(on => {
        hepLights.forEach(light => light.Activate(on));
        me.rv.ActivateNode("1_1000_LitInteriorLights", on);
        me.rv.SetControlValue("HEP_State", on ? 1 : 0);
    });
    njt.createHepPopup(me);

    // Link the various virtual controls.
    const reverserControl$ = me.createOnCvChangeStreamFor("UserVirtualReverser");
    reverserControl$(v => {
        me.rv.SetControlValue("Reverser", v);
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

    // Link the control desk switches.
    const setHeadlights$ = frp.compose(
        me.createOnCvChangeStreamFor("HeadlightSwitch"),
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
        me.createOnCvChangeStreamFor("Headlights"),
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
        me.rv.SetControlValue("Headlights", v);
    });
    moveHeadlightSwitch$(v => {
        me.rv.SetControlTargetValue("HeadlightSwitch", v);
    });
    const setDitchLights$ = frp.compose(
        me.createOnCvChangeStreamFor("DitchLightSwitch"),
        frp.map(v => {
            switch (v) {
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
    const moveDitchLightSwitch$ = frp.compose(
        me.createOnCvChangeStreamFor("DitchLights"),
        frp.map(v => {
            switch (v) {
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
    setDitchLights$(v => {
        me.rv.SetControlValue("DitchLights", v);
    });
    moveDitchLightSwitch$(v => {
        me.rv.SetControlTargetValue("DitchLightSwitch", v);
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
    const doorsOpenLight$ = frp.compose(me.createUpdateStream(), mapBehavior(areDoorsOpen), rejectRepeats());
    doorsOpenLight$(on => {
        me.rv.ActivateNode("LightsRed", on);
    });

    // Set platform door height.
    fx.setLowPlatformDoorsForEngine(me, false);

    // Destination signs
    njt.createDestinationSignSelector(me);

    // Set in-cab vehicle number.
    readRvNumber();

    // Enable updates.
    me.e.BeginUpdate();
});
me.setup();

function readRvNumber() {
    const [, , unit] = string.find(me.rv.GetRVNumber(), "(%d+)");
    if (unit !== undefined) {
        const [[tt, h, t, u]] = m.digits(tonumber(unit) as number, 4);
        me.rv.SetControlValue("UN_thousands", tt);
        me.rv.SetControlValue("UN_hundreds", h);
        me.rv.SetControlValue("UN_tens", t);
        me.rv.SetControlValue("UN_units", u);
    }
}
