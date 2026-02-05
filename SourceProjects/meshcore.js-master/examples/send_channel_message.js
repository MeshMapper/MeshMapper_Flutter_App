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

    // find channel
    const channel = await connection.findChannelByName("Public");
    // const channel = await connection.findChannelBySecret(Buffer.from("8b3387e9c5cdea6ac9e5edbaa115cd72", "hex"));
    if(!channel){
        console.log("Channel not found");
        await connection.close();
        return;
    }

    // send message to channel
    console.log("Sending message...");
    await connection.sendChannelTextMessage(channel.channelIdx, "Hello from MeshCore.js");

    // disconnect
    await connection.close();

});

// connect to meshcore device
await connection.connect();
