import Packet from "../src/packet.js";

const bytes = Buffer.from("0200B401DF6528CC9778A56F36FE9399A5CF6B0C7EDE", "hex");
const packet = Packet.fromBytes(bytes);

console.log(packet);
console.log(packet.parsePayload());
