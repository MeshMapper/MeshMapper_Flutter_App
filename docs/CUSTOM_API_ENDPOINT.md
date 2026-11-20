# Custom API Endpoint - Third-Party Developer Guide

This document describes the API contract for receiving forwarded wardrive data from MeshMapper. When a user enables "Custom API Endpoint" in MeshMapper settings, every successful wardrive batch upload is also forwarded to your endpoint. This includes offline sessions the user uploads later: each 50-row chunk that uploads is forwarded as its own request.

## Request Format

| Field | Value |
|-------|-------|
| **Method** | `POST` |
| **Content-Type** | `application/json` |
| **Authentication** | `X-API-Key` header (value configured by the user in MeshMapper settings) |

### Request Body

```json
{
  "data": [
    { /* ping object */ },
    { /* ping object */ },
    ...
  ]
}
```

The `data` array contains 1-50 ping objects per batch. During a live session the app uploads about 5 seconds after each TX, DISC, TRACE, DEFER or SCOPES item is queued, and on a 15-second timer otherwise (both stretch to 60 seconds on a constrained link such as satellite). Each successful upload is forwarded once.

## Ping Object Schema

Every ping object contains a `type` field that determines which additional fields are present.

### Common Fields (all types)

| Field | Type | Description |
|-------|------|-------------|
| `type` | `string` | Ping type: `"TX"`, `"RX"`, `"DISC"`, `"TRACE"`, `"DEFER"`, or `"SCOPES"`. A `DEFER` carries only the common `lat`, `lon`, `timestamp`, `contact`, `iata` and `radio_freq` fields plus `held` (see below); it has no `external_antenna`, `noisefloor`, `altitude`, `altitude_ref`, `altitude_acc` or `power`. A `SCOPES` carries only the common `timestamp`, `lat`, `lon`, `contact`, `iata` and `radio_freq` fields plus `public_key` and `scopes` (see below); it has no `external_antenna`, `noisefloor`, `altitude`, `altitude_ref`, `altitude_acc` or `power` either. |
| `lat` | `number` | Latitude (WGS84, decimal degrees) |
| `lon` | `number` | Longitude (WGS84, decimal degrees) |
| `timestamp` | `integer` | Unix timestamp in seconds |
| `external_antenna` | `boolean` | Whether an external antenna is connected to the device |
| `noisefloor` | `integer\|null` | Ambient noise floor in dBm (e.g., -103). Null if unavailable. |
| `altitude` | `integer\|absent` | Altitude of the fix in whole meters (e.g., `123`). Present only together with `altitude_ref`: an altitude whose reference the app could not prove is not sent at all. Absent on `DEFER` and `SCOPES`. |
| `altitude_ref` | `string\|absent` | The reference `altitude` is measured from: `"msl"` (above mean sea level) or `"ellipsoid"` (above the WGS84 ellipsoid). The two differ by the local geoid separation, tens of meters in most places. iPhones always send `msl`; Android phones send `ellipsoid` below Android 14 and either on Android 14 and later, whichever the fix carried. Always present beside `altitude`. |
| `altitude_acc` | `integer\|absent` | Vertical accuracy of the fix in whole meters, about one standard deviation. Present only beside `altitude` and only when the phone knew it. |
| `radio_freq` | `string\|absent` | The radio configuration the item was recorded under, as `freqMHz,bwKHz,SF,CR` (e.g. `"910.525,62.5,7,5"`). Absent when the radio did not report its parameters. Present on every type, `DEFER` included. |
| `power` | `string\|null` | Radio TX power formatted as `"X.Xw"` (e.g., `"0.3w"`, `"1.0w"`, `"2.0w"`). Null if unavailable. |
| `contact` | `string\|absent` | First 8 hex chars of the wardriver's MeshCore device public key (e.g., `"D873B1F2"`). Only present when the user enables "Include Contact Key" in settings. Useful for cross-referencing with MQTT observer data. |
| `iata` | `string\|absent` | MeshMapper zone code (e.g., `"RDU"`, `"MSP"`, `"YOW"`). The wardriver's current zone, or the last zone the app saved when there is no current one. On an offline session upload, it is the zone the upload was made from, for the whole chunk, not where each ping was recorded. |

Earlier builds forwarded an `altitude` with no reference; those bare altitudes are no longer forwarded.

### TX Ping (type: "TX")

A transmitted ping broadcast on the wardriving channel, with repeater echo results.

| Field | Type | Description |
|-------|------|-------------|
| `heard_repeats` | `string` | Comma-separated repeater echoes: `"id(snr),id(snr)"` or `"None"` if no repeaters heard. IDs are upper-case hex: 2, 4 or 6 characters depending on the path's bytes per hop (8 is possible). SNR is in dB with two decimals, or `null` when the echo came through the user's own CARpeater (for example `"4E(null)"`). |
| `wire_tag` | `string\|absent` | The encrypted tag the ping carried on air instead of its coordinates (e.g., `"MM:Ab3dEf9hIj"`). Only MeshMapper holds the key that decrypts it. Decrypted, it names the session and the ping that sent it, which is how MeshMapper matches a ping heard by an observer in another region back to its session (cross-region spillover). Can be absent: a TX that carried no tag, for example from an offline session saved by an older app version, has none. |
| `ping_counter` | `integer\|absent` | The ping's number within the user's MeshMapper session. Sent only together with `wire_tag`. |

Echoes that reached the user through more than one repeater are not in `heard_repeats`. They arrive as separate `RX` items at the TX ping's location.

**Example:**

```json
{
  "type": "TX",
  "lat": 45.26974,
  "lon": -75.77746,
  "noisefloor": -103,
  "altitude": 84,
  "altitude_ref": "msl",
  "altitude_acc": 6,
  "radio_freq": "910.525,62.5,7,5",
  "heard_repeats": "4E(12.25),77(8.50)",
  "timestamp": 1768762843,
  "external_antenna": false,
  "power": "0.3w",
  "ping_counter": 42,
  "wire_tag": "MM:Ab3dEf9hIj",
  "contact": "D873B1F2",
  "iata": "YOW"
}
```

**Example (no repeaters heard):**

```json
{
  "type": "TX",
  "lat": 45.27001,
  "lon": -75.77802,
  "noisefloor": -101,
  "altitude": 86,
  "altitude_ref": "msl",
  "altitude_acc": 6,
  "radio_freq": "910.525,62.5,7,5",
  "heard_repeats": "None",
  "timestamp": 1768762873,
  "external_antenna": false,
  "power": "0.3w",
  "ping_counter": 43,
  "wire_tag": "MM:Kl2mNo4pQr",
  "contact": "D873B1F2",
  "iata": "YOW"
}
```

### RX Ping (type: "RX")

A passively observed mesh packet from a nearby repeater, or a TX echo that reached the user through more than one repeater.

| Field | Type | Description |
|-------|------|-------------|
| `heard_repeats` | `string` | Single repeater with SNR: `"id(snr)"` (e.g., `"4E(12.00)"`). Same ID and SNR format as TX, so the SNR can be `null` (`"4E(null)"`). |

**Example:**

```json
{
  "type": "RX",
  "lat": 45.26950,
  "lon": -75.77700,
  "noisefloor": -105,
  "heard_repeats": "4E(12.00)",
  "timestamp": 1768762900,
  "external_antenna": false,
  "power": "0.3w",
  "contact": "D873B1F2",
  "iata": "YOW"
}
```

### DISC Ping (type: "DISC") - Discovery Response

A response from a discovered repeater or room node.

| Field | Type | Description |
|-------|------|-------------|
| `repeater_id` | `string` | Upper-case hex ID of the discovered node: the first 2, 4 or 6 characters of its public key, following the user's path bytes setting (e.g., `"A3B2C1"`). `"None"` for a failed discovery. |
| `node_type` | `string` | Node type: `"REPEATER"` or `"ROOM"`. Absent on failed discovery. |
| `local_snr` | `number` | SNR measured locally (dB). `0` if the stored value could not be read. |
| `local_rssi` | `integer` | RSSI measured locally (dBm, negative). `0` if the stored value could not be read. |
| `remote_snr` | `number` | SNR reported by the remote node (dB). `0` if the stored value could not be read. |
| `public_key` | `string` | Full 32-byte public key of the node (64 upper-case hex chars). |

A failed discovery (no node answered) is only sent when the user or region has **Discovery Drop** on. It carries none of `node_type`, `local_snr`, `local_rssi`, `remote_snr` or `public_key`.

**Example (successful discovery):**

```json
{
  "type": "DISC",
  "lat": 45.26980,
  "lon": -75.77750,
  "noisefloor": -102,
  "repeater_id": "A3B2C1",
  "node_type": "REPEATER",
  "local_snr": 11.75,
  "local_rssi": -85,
  "remote_snr": 9.50,
  "public_key": "A3B2C1D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2",
  "timestamp": 1768762950,
  "external_antenna": true,
  "power": "1.0w",
  "contact": "D873B1F2",
  "iata": "YOW"
}
```

**Example (failed discovery - no nodes responded):**

```json
{
  "type": "DISC",
  "lat": 45.27010,
  "lon": -75.77800,
  "noisefloor": -100,
  "repeater_id": "None",
  "timestamp": 1768762980,
  "external_antenna": true,
  "power": "1.0w",
  "contact": "D873B1F2",
  "iata": "YOW"
}
```

### TRACE Ping (type: "TRACE")

A targeted zero-hop trace to a specific repeater.

| Field | Type | Description |
|-------|------|-------------|
| `repeater_id` | `string` | Hex ID of the targeted repeater. |
| `local_snr` | `number\|null` | SNR measured locally (dB). |
| `local_rssi` | `integer\|null` | RSSI measured locally (dBm, negative). |
| `remote_snr` | `number\|null` | SNR reported by the repeater (dB). |

Only traces the repeater answered are sent.

**Example:**

```json
{
  "type": "TRACE",
  "lat": 45.26990,
  "lon": -75.77730,
  "noisefloor": -104,
  "repeater_id": "4e2f",
  "local_snr": 10.50,
  "local_rssi": -88,
  "remote_snr": 8.25,
  "timestamp": 1768763010,
  "external_antenna": false,
  "power": "0.3w",
  "contact": "D873B1F2",
  "iata": "YOW"
}
```

### DEFER (type: "DEFER")

A square where the app's smart pinging held a TX ping or a discovery request because MeshMapper already had recent coverage there. The app reports it so MeshMapper can credit the square; you receive it because it may help a mapper keeping its own coverage. Discovery requests are only held when the user (or the region) has turned off Delay only flood pings.

**A deferral is unverified.** MeshMapper checks each one against its own coverage data and silently discards any it cannot confirm, but the batch answer does not say which items were kept, and the app forwards the whole batch after the upload succeeds. Treat a `DEFER` as "the app believed this square was covered", not as a confirmed observation.

| Field | Type | Description |
|-------|------|-------------|
| `held` | `string` | Which kind of ping was held: `"tx"` (a channel ping) or `"disc"` (a discovery request). |

The `external_antenna`, `noisefloor`, `altitude`, `altitude_ref`, `altitude_acc` and `power` fields are not present on a `DEFER`. A `DEFER` carries `lat`, `lon`, `timestamp`, `contact`, `iata`, `held` and `radio_freq`. At most one `DEFER` is sent per 300 m square per MeshMapper session.

**Example:**

```json
{
  "type": "DEFER",
  "lat": 45.26974,
  "lon": -75.77746,
  "timestamp": 1757400000,
  "contact": "D873B1F2",
  "iata": "YOW",
  "radio_freq": "910.525,62.5,7,5",
  "held": "tx"
}
```

### SCOPES (type: "SCOPES")

A repeater's answer to a direct scope discovery question, sent after a discovery finds the repeater. The app asks a discovered repeater which regions (flood scopes) it carries, and the repeater answers with a list of region names. A `SCOPES` item is only sent after the `DISC` item for the discovery that found the repeater. If the server stops offering scope discovery, queued `SCOPES` items are dropped and never forwarded.

**A SCOPES answer is unverified.** MeshMapper checks each answer against a discovery the same radio reported and discards any it cannot confirm, but the batch answer does not say which were kept, and the app forwards the whole batch after the upload succeeds. A long answer can also be incomplete: the repeater leaves out names that do not fit in its reply.

| Field | Type | Description |
|-------|------|-------------|
| `public_key` | `string` | Full 32-byte public key of the answering repeater (64 hex chars, upper case). |
| `scopes` | `array of string` | The scope names exactly as the repeater sent them, case-sensitive. Each entry is `"*"` (the repeater passes unscoped traffic) or a name of 1 to 30 bytes that does not start with `#`. May be empty. At most 33 entries. |

`lat` and `lon` are where the discovery that found the repeater was made, not where the answer arrived. `timestamp` is when the answer arrived. The `external_antenna`, `noisefloor`, `altitude`, `altitude_ref`, `altitude_acc` and `power` fields are not present on a `SCOPES` item.

**Example:**

```json
{
  "type": "SCOPES",
  "public_key": "A3B2C1D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2",
  "scopes": ["ROOM1", "*"],
  "timestamp": 1768763050,
  "lat": 45.26980,
  "lon": -75.77750,
  "contact": "D873B1F2",
  "iata": "YOW"
}
```

## Batch Examples

A batch is whatever the app uploaded to MeshMapper in that round, so one request can mix every type above. `DEFER` items only appear while the user has Smart Pinging on (the default) in Active or Hybrid mode, or in Passive mode with Delay only flood pings turned off, so your endpoint must accept batches both with and without them. `SCOPES` items only appear while scope discovery is on, either enforced by the region or switched on by the user, so your endpoint must accept batches with and without them too. Dispatch on `type` and ignore any value you do not handle rather than rejecting the batch: a `4xx` is shown to the user as an error.

**Batch without a DEFER** (a TX ping and a passive RX observation):

```json
{
  "data": [
    {
      "type": "TX",
      "lat": 45.26974,
      "lon": -75.77746,
      "noisefloor": -103,
      "altitude": 84,
      "altitude_ref": "msl",
      "altitude_acc": 6,
      "radio_freq": "910.525,62.5,7,5",
      "heard_repeats": "4E(12.25),77(8.50)",
      "timestamp": 1768762843,
      "external_antenna": false,
      "power": "0.3w",
      "ping_counter": 42,
      "wire_tag": "MM:Ab3dEf9hIj",
      "contact": "D873B1F2",
      "iata": "YOW"
    },
    {
      "type": "RX",
      "lat": 45.26950,
      "lon": -75.77700,
      "noisefloor": -105,
      "heard_repeats": "4E(12.00)",
      "timestamp": 1768762900,
      "external_antenna": false,
      "power": "0.3w",
      "contact": "D873B1F2",
      "iata": "YOW"
    }
  ]
}
```

**Batch with a DEFER** (the next TX ping was held because the square already had recent coverage, while passive RX logging carried on):

```json
{
  "data": [
    {
      "type": "DEFER",
      "lat": 45.27210,
      "lon": -75.78120,
      "timestamp": 1768762933,
      "contact": "D873B1F2",
      "iata": "YOW",
      "radio_freq": "910.525,62.5,7,5",
      "held": "tx"
    },
    {
      "type": "RX",
      "lat": 45.27222,
      "lon": -75.78140,
      "noisefloor": -104,
      "heard_repeats": "77(9.75)",
      "timestamp": 1768762941,
      "external_antenna": false,
      "power": "0.3w",
      "contact": "D873B1F2",
      "iata": "YOW"
    }
  ]
}
```

Note that the `DEFER` has no `noisefloor`, `altitude`, `altitude_ref`, `altitude_acc`, `external_antenna` or `power`, while the `RX` beside it does.

## Expected Response

Your endpoint should return any `2xx` HTTP status code on success. The response body is ignored by MeshMapper.

| Status | MeshMapper Behavior |
|--------|-------------------|
| `200-299` | Logged as success. No further action. |
| `4xx` | Error logged to user's error tab (throttled to once per minute per status code). |
| `5xx` | Error logged to user's error tab (throttled to once per minute per status code). |
| Timeout (>10s) | Error logged as timeout (throttled to once per minute). |
| Network error | Error logged as network error (throttled to once per minute). |

MeshMapper does **not** retry failed custom API requests. Each batch is sent exactly once.

## Configuration Link for End Users

As an endpoint operator, you can generate a configuration link that your users copy to their clipboard. In MeshMapper Settings > API Endpoints, they switch on **Custom API Endpoint** (and accept the "Third-Party Data Sharing" notice), then tap **Import from Clipboard**, which only appears once the switch is on, to auto-fill the URL and API key.

**Format:**

```
meshmapper://custom-api?url=your-server.com/api/wardrive&key=your-api-key-here
```

- `url` — Your endpoint host and path, **without** `https://` (MeshMapper prepends it automatically).
- `key` — The API key the user should send. This will be set as their `X-API-Key` header value.

The link is read as an ordinary URL query, so percent-encode any `&`, `+`, `#` or `%` inside the `url` or `key` values (for example `&` as `%26`). Left unencoded, they cut the value short or change it.

**Example:**

```
meshmapper://custom-api?url=data.myproject.org/ingest/wardrive&key=sk_live_abc123def456
```

The user copies this link, opens MeshMapper Settings > API Endpoints, and taps "Import from Clipboard." Both fields are populated instantly. The endpoint settings can't be changed while an auto mode is running.

## Security Notes

- **HTTPS required**: MeshMapper validates that the configured URL uses HTTPS. HTTP endpoints are rejected at the settings level.
- **API key in header**: The user-configured API key is sent as `X-API-Key` header, not in the request body.
- **No MeshMapper credentials**: The MeshMapper API key and session ID are never included in forwarded requests. You receive only the raw ping data.
- **Contact key is opt-in**: The `contact` field (device public key prefix) is controlled by the user via "Include Contact Key" toggle. It defaults to ON but can be disabled.
- **Fire-and-forget**: Custom API errors never affect MeshMapper's primary data submission. A broken custom endpoint cannot disrupt wardriving.

## Rate and Volume

- **Batch frequency**: About 5 seconds after each TX, DISC, TRACE, DEFER or SCOPES item, and every 15 seconds otherwise (60 seconds on a constrained link). Offline session uploads arrive as a burst of up to 50 items per request.
- **Batch size**: 1-50 ping objects per request (typically 1-10).
- **Session duration**: Wardriving sessions commonly last 30 minutes to several hours.
- **Concurrent users**: Plan for multiple users if distributing your endpoint URL. Each user sends independently.

## Why `meshmapper://` links are paste-only

The `meshmapper://custom-api?...` format is deliberately **not** registered as
an OS URL scheme. Tapping one does nothing; it has to be copied and imported
from Settings. The app registers `meshmapper-auth://callback` instead (portal
sign-in) precisely so that claiming a scheme never hijacks these config links.
