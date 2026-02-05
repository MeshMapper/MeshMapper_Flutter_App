import TCPConnection from "../src/connection/tcp_connection.js";
import CayenneLpp from "../src/cayenne_lpp.js";

// create connection
const connection = new TCPConnection("10.1.0.75", 5000);

// wait until connected
connection.on("connected", async () => {

    // we are now connected
    console.log("Connected");

    // find contact
    // const contact = await connection.findContactByName("Liam's Water Tank");
    // const contact = await connection.findContactByPublicKeyPrefix([0xc9, 0xe1, 0x50, 0x58]);
    // const contact = await connection.findContactByPublicKeyPrefix(Buffer.from("c9e15058", "hex"));
    const contact = await connection.findContactByPublicKeyPrefix(Buffer.from("c9e15058af33781743b222bc98105abe7429cf46f7212f767ff2a7ce1bea5dcb", "hex"));
    if(!contact){
        console.log("Contact not found");
        await connection.close();
        return;
    }

    // get sensor telemetry
    console.log("Fetching telemetry...");
    const telemetry = await connection.getTelemetry(contact.publicKey);

    // disconnect
    await connection.close();

    // parse telemetry
    const parsedTelemetry = CayenneLpp.parse(telemetry.lppSensorData);

    // find telemetry on channel 1
    const selfVoltageTelemetry = parsedTelemetry.find((item) => item.channel === 1 && item.type === CayenneLpp.LPP_VOLTAGE);

    // make sure telemetry found
    if(selfVoltageTelemetry == null){
        console.log("Telemetry Missing");
        return;
    }

    console.log({
        voltage: selfVoltageTelemetry.value,
    });

});

// connect to meshcore device
await connection.connect();
