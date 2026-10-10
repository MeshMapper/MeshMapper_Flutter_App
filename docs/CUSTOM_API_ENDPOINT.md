# Custom API Endpoint - Third-Party Developer Guide

This document describes the API contract for receiving forwarded wardrive data from MeshMapper. When a user enables "Custom API Endpoint" in MeshMapper settings, every successful wardrive batch upload is also forwarded to your endpoint.

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

The `data` array contains 1-50 ping objects per batch. Batches arrive approximately every 15-30 seconds during an active wardriving session.

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
| `iata` | `string\|absent` | MeshMapper zone code (e.g., `"RDU"`, `"MSP"`, `"YOW"`). Present when the wardriver is in a zone. |

Earlier builds forwarded an `altitude` with no reference; those bare altitudes are no longer forwarded.

### TX Ping (type: "TX")

A transmitted ping broadcast on the wardriving channel, with repeater echo results.

| Field | Type | Description |
|-------|------|-------------|
| `heard_repeats` | `string` | Comma-separated repeater echoes: `"id(snr),id(snr)"` or `"None"` if no repeaters heard. IDs are hex strings (1-6 chars). SNR is in dB. |

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
  "heard_repeats": "4e(12.25),77(8.50)",
  "timestamp": 1768762843,
  "external_antenna": false,
  "power": "0.3w",
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
  "contact": "D873B1F2",
  "iata": "YOW"
}
```

### RX Ping (type: "RX")

A passively observed mesh packet from a nearby repeater.

| Field | Type | Description |
|-------|------|-------------|
| `heard_repeats` | `string` | Single repeater with SNR: `"id(snr)"` (e.g., `"4e(12.0)"`). |

**Example:**

```json
{
  "type": "RX",
  "lat": 45.26950,
  "lon": -75.77700,
  "noisefloor": -105,
  "heard_repeats": "4e(12.00)",
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
| `repeater_id` | `string` | Hex ID of the discovered node (e.g., `"a3b2c1"`), or `"None"` for failed discovery. |
| `node_type` | `string` | Node type: `"REPEATER"` or `"ROOM"`. Absent on failed discovery. |
| `local_snr` | `number` | SNR measured locally (dB). |
| `local_rssi` | `integer` | RSSI measured locally (dBm, negative). |
| `remote_snr` | `number` | SNR reported by the remote node (dB). |
| `public_key` | `string` | Full 32-byte public key of the node (64 hex chars). |

**Example (successful discovery):**

```json
{
  "type": "DISC",
  "lat": 45.26980,
  "lon": -75.77750,
  "noisefloor": -102,
  "repeater_id": "a3b2c1",
  "node_type": "REPEATER",
  "local_snr": 11.75,
  "local_rssi": -85,
  "remote_snr": 9.50,
  "public_key": "a3b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2",
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
| `local_snr` | `number` | SNR measured locally (dB). |
| `local_rssi` | `integer` | RSSI measured locally (dBm, negative). |
| `remote_snr` | `number` | SNR reported by the repeater (dB). |

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

A square where the app's smart pinging held a TX ping or a discovery request because MeshMapper already had recent coverage there. The app reports it so MeshMapper can credit the square; you receive it because it may help a mapper keeping its own coverage.

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

A repeater's answer to a direct scope discovery question, sent after a discovery finds the repeater. MeshMapper asks a discovered repeater which channels or contacts it passes, and the repeater answers with a list of scope names.

**A SCOPES answer is unverified.** MeshMapper checks each answer against a discovery the same radio reported and discards any it cannot confirm, but the batch answer does not say which were kept, and the app forwards the whole batch after the upload succeeds. A long answer can also be incomplete: the repeater leaves out names that do not fit in its reply.

| Field | Type | Description |
|-------|------|-------------|
| `public_key` | `string` | Full 32-byte public key of the answering repeater (64 hex chars, upper case). |
| `scopes` | `array of string` | The scope names exactly as the repeater sent them, case-sensitive. `"*"` means the repeater passes unscoped traffic. May be empty. At most 33 entries. |

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

A batch is whatever the app uploaded to MeshMapper in that round, so one request can mix every type above. `DEFER` items only appear from app version 1.4.0 onward, and only while the user has Smart Pinging on (the default) in Active, Passive or Hybrid mode, so your endpoint must accept batches both with and without them. `SCOPES` items only appear from the app version that ships this feature, and only while scope discovery is on, either enforced by the region or switched on by the user, so your endpoint must accept batches with and without them too. Dispatch on `type` and ignore any value you do not handle rather than rejecting the batch: a `4xx` is shown to the user as an error.

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
      "heard_repeats": "4e(12.25),77(8.50)",
      "timestamp": 1768762843,
      "external_antenna": false,
      "power": "0.3w",
      "contact": "D873B1F2",
      "iata": "YOW"
    },
    {
      "type": "RX",
      "lat": 45.26950,
      "lon": -75.77700,
      "noisefloor": -105,
      "heard_repeats": "4e(12.00)",
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
| Timeout (>10s) | Error logged as timeout. |
| Network error | Error logged as network error. |

MeshMapper does **not** retry failed custom API requests. Each batch is sent exactly once.

## Configuration Link for End Users

As an endpoint operator, you can generate a configuration link that your users paste into their clipboard. In MeshMapper Settings > API Endpoints, they tap **Import from Clipboard** to auto-fill the URL and API key.

**Format:**

```
meshmapper://custom-api?url=your-server.com/api/wardrive&key=your-api-key-here
```

- `url` — Your endpoint host and path, **without** `https://` (MeshMapper prepends it automatically).
- `key` — The API key the user should send. This will be set as their `X-API-Key` header value.

**Example:**

```
meshmapper://custom-api?url=data.myproject.org/ingest/wardrive&key=sk_live_abc123def456
```

The user copies this link, opens MeshMapper Settings > API Endpoints, and taps "Import from Clipboard." Both fields are populated instantly.

## Security Notes

- **HTTPS required**: MeshMapper validates that the configured URL uses HTTPS. HTTP endpoints are rejected at the settings level.
- **API key in header**: The user-configured API key is sent as `X-API-Key` header, not in the request body.
- **No MeshMapper credentials**: The MeshMapper API key and session ID are never included in forwarded requests. You receive only the raw ping data.
- **Contact key is opt-in**: The `contact` field (device public key prefix) is controlled by the user via "Include Contact Key" toggle. It defaults to ON but can be disabled.
- **Fire-and-forget**: Custom API errors never affect MeshMapper's primary data submission. A broken custom endpoint cannot disrupt wardriving.

## Rate and Volume

- **Batch frequency**: Every 15-30 seconds during active wardriving (depends on auto-ping interval and batch timer).
- **Batch size**: 1-50 ping objects per request (typically 1-10).
- **Session duration**: Wardriving sessions commonly last 30 minutes to several hours.
- **Concurrent users**: Plan for multiple users if distributing your endpoint URL. Each user sends independently.

## Why `meshmapper://` links are paste-only

The `meshmapper://custom-api?...` format is deliberately **not** registered as
an OS URL scheme. Tapping one does nothing; it has to be copied and imported
from Settings. The app registers `meshmapper-auth://callback` instead (portal
sign-in) precisely so that claiming a scheme never hijacks these config links.
