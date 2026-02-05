import TCPConnection from "../src/connection/tcp_connection.js";
import NodeJSSerialConnection from "../src/connection/nodejs_serial_connection.js";
import {BufferUtils} from "../src/index.js";

// create connection
const connection = new TCPConnection("10.1.0.75", 5000);
// const connection = new NodeJSSerialConnection("/dev/cu.usbmodem14401");

// wait until connected
connection.on("connected", async () => {

    // we are now connected
    console.log("Connected");

    // sign data
    try {
        const signature = await connection.sign(Buffer.from("test"));
        const signatureHex = BufferUtils.bytesToHex(signature);
        console.log(signatureHex);
    } catch(e) {
        console.log("failed to sign", e);
    }

    // disconnect
    await connection.close();

});

// connect to meshcore device
await connection.connect();
