import TCPConnection from "../src/connection/tcp_connection.js";
import NodeJSSerialConnection from "../src/connection/nodejs_serial_connection.js";

// create connection
// const connection = new TCPConnection("10.1.0.226", 5000);
const connection = new NodeJSSerialConnection("/dev/cu.usbmodem14401");

// wait until connected
connection.on("connected", async () => {

    // we are now connected
    console.log("Connected");

    // find contact
    // const contact = await connection.findContactByName("Liam's Solar Repeater");
    // const contact = await connection.findContactByPublicKeyPrefix([0x93, 0x5c, 0x6b, 0x69]);
    // const contact = await connection.findContactByPublicKeyPrefix(Buffer.from("935c6b69", "hex"));
    const contact = await connection.findContactByPublicKeyPrefix(Buffer.from("935c6b694200644710a374c250c76f7aed9ec2ff3e60261447d4eda7c246ce5d", "hex"));
    if(!contact){
        console.log("Contact not found");
        await connection.close();
        return;
    }

    // login to repeater (with empty guest password)
    console.log("Logging in...");
    await connection.login(contact.publicKey, "");

    // get repeater status
    console.log("Fetching status...");
    const status = await connection.getStatus(contact.publicKey);
    console.log(status);

    // disconnect
    await connection.close();

});

// connect to meshcore device
await connection.connect();
