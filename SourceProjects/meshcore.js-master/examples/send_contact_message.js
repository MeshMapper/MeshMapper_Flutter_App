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

    // find contact
    const contact = await connection.findContactByName("Liam Cottle 🤠");
    // const contact = await connection.findContactByPublicKeyPrefix([0x70, 0xb7, 0x8b, 0x64]);
    // const contact = await connection.findContactByPublicKeyPrefix(Buffer.from("70b78b64", "hex"));
    // const contact = await connection.findContactByPublicKeyPrefix(Buffer.from("70b78b64782bffb918da2d6432204a149bd232dd66373415b5f7ba24733ba2ef", "hex"));
    if(!contact){
        console.log("Contact not found");
        await connection.close();
        return;
    }

    // send message to contact
    console.log("Sending message...");
    await connection.sendTextMessage(contact.publicKey, "Hello from MeshCore.js");

    // disconnect
    await connection.close();

});

// connect to meshcore device
await connection.connect();
