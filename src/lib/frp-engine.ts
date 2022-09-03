/** @noSelfInFile */

import * as frp from "./frp";
import { FrpSource } from "./frp-entity";
import { FrpVehicle, PlayerUpdate } from "./frp-vehicle";
import * as rw from "./railworks";

export class FrpEngine extends FrpVehicle {
    /**
     * Convenient acces to the methods for an engine.
     */
    public eng = new rw.Engine("");

    private playerWithKeyUpdateSource = new FrpSource<PlayerUpdate>();
    private playerWithoutKeyUpdateSource = new FrpSource<PlayerUpdate>();
    private signalMessageSource = new FrpSource<string>();

    constructor(onInit: () => void) {
        super(onInit);

        const playerUpdate$ = this.createPlayerUpdateStream();
        playerUpdate$(pu => {
            if (this.eng.GetIsEngineWithKey()) {
                this.playerWithKeyUpdateSource.call(pu);
            } else {
                this.playerWithoutKeyUpdateSource.call(pu);
            }
        });
    }

    /**
     * Create an event stream that fires while the current rail vehicle is the
     * player-controlled engine.
     * @returns The new stream, which contains some useful vehicle state.
     */
    createPlayerWithKeyUpdateStream() {
        return this.playerWithKeyUpdateSource.createStream();
    }

    /**
     * Create an event stream that fires while the current rail vehicle is a
     * helper in the player train.
     * @returns The new stream, which contains some useful vehicle state.
     */
    createPlayerWithoutKeyUpdateStream() {
        return this.playerWithoutKeyUpdateSource.createStream();
    }

    /**
     * Create an event stream from the OnCustomSignalMessage() callback, which
     * fires when the player-controlled engine receives a custom message from
     * a lineside signal.
     * @returns The new stream of signal messages.
     */
    createOnSignalMessageStream() {
        return this.signalMessageSource.createStream();
    }

    setup() {
        super.setup();

        OnCustomSignalMessage = msg => {
            this.signalMessageSource.call(msg);
        };
    }
}
