import Packet from "../src/packet.js";
import {Advert} from "../src/index.js";

// get raw packet bytes from meshcore url
const advertUrl = "meshcore://1100e04b135959ffac9397b600add84822cb8bf4a050a7f40965dd1ab7aea3ddd3743327e668b5db95bc8fbc3894b115415d6e4cca36f9c9e62e923afd37c3e2a154b27b0c53b6cfddd45bb3faf56fdaf08860d985ca2da44f9dcac1d7d76fc2b86d7b26e004814c69616d20436f74746c6520f09fa4a0";
const advertHex = advertUrl.replaceAll("meshcore://", "");
const bytes = Buffer.from(advertHex, "hex");

// parse packet and advert
const packet = Packet.fromBytes(bytes);
const advert = Advert.fromBytes(packet.payload);

// log it
console.log(advert);
