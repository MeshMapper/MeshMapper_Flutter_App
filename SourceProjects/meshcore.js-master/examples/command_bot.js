import Constants from "../src/constants.js";
import TCPConnection from "../src/connection/tcp_connection.js";
import NodeJSSerialConnection from "../src/connection/nodejs_serial_connection.js";

// create connection
// const connection = new TCPConnection("10.1.0.226", 5000);
const connection = new NodeJSSerialConnection("/dev/cu.usbmodem14401");

// wait until connected
connection.on("connected", async () => {

    // we are now connected
    console.log("Connected");

    // update clock on meshcore device
    await connection.syncDeviceTime();

    // send flood advert when connected
    await connection.sendFloodAdvert();

});

// listen for new messages
connection.on(Constants.PushCodes.MsgWaiting, async () => {
    try {
        const waitingMessages = await connection.getWaitingMessages();
        for(const message of waitingMessages){
            if(message.contactMessage){
                await onContactMessageReceived(message.contactMessage);
            } else if(message.channelMessage) {
                await onChannelMessageReceived(message.channelMessage);
            }
        }
    } catch(e) {
        console.log(e);
    }
});

async function onContactMessageReceived(message) {

    console.log("Received contact message", message);

    // find first contact matching pub key prefix
    const contact = await connection.findContactByPublicKeyPrefix(message.pubKeyPrefix);
    if(!contact){
        console.log("Did not find contact for received message");
        return;
    }

    // handle commands
    if(message.text === "/ping"){
        await connection.sendTextMessage(contact.publicKey, "PONG! 🏓", Constants.TxtTypes.Plain);
        return;
    }

    // handle commands
    if(message.text === "/date"){
        await connection.sendTextMessage(contact.publicKey, (new Date()).toISOString(), Constants.TxtTypes.Plain);
        return;
    }

    // help menu
    const response = [
        "🤖 Echo Bot Help",
        "/help - show help menu",
        "/ping - replies with pong",
        "/date - replies with current date",
    ].join("\n");

    // fallback to send the help menu
    await connection.sendTextMessage(contact.publicKey, response, Constants.TxtTypes.Plain);

}

async function onChannelMessageReceived(message) {
    console.log(`Received channel message`, message);
}

// todo auto reconnect on disconnect

// connect to meshcore device
await connection.connect();
