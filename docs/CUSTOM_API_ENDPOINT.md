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
| `type` | `string` | Ping type: `"TX"`, `"RX"`, `"DISC"`, or `"TRACE"` |
| `lat` | `number` | Latitude (WGS84, decimal degrees) |
| `lon` | `number` | Longitude (WGS84, decimal degrees) |
| `timestamp` | `integer` | Unix timestamp in seconds |
| `external_antenna` | `boolean` | Whether an external antenna is connected to the device |
| `noisefloor` | `integer\|null` | Ambient noise floor in dBm (e.g., -103). Null if unavailable. |
| `power` | `string\|null` | Radio TX power formatted as `"X.Xw"` (e.g., `"0.3w"`, `"1.0w"`, `"2.0w"`). Null if unavailable. |
| `contact` | `string\|absent` | First 8 hex chars of the wardriver's MeshCore device public key (e.g., `"D873B1F2"`). Only present when the user enables "Include Contact Key" in settings. Useful for cross-referencing with MQTT observer data. |
| `iata` | `string\|absent` | MeshMapper zone code (e.g., `"RDU"`, `"MSP"`, `"YOW"`). Present when the wardriver is in a zone. |

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
  "power": "0.3w"
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
  "power": "1.0w"
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
  "power": "1.0w"
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
  "power": "0.3w"
}
```

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
- **Fire-and-forget**: Custom API errors never affect MeshMapper's primary data submission. A broken custom endpoint cannot disrupt wardriving.

## Rate and Volume

- **Batch frequency**: Every 15-30 seconds during active wardriving (depends on auto-ping interval and batch timer).
- **Batch size**: 1-50 ping objects per request (typically 1-10).
- **Session duration**: Wardriving sessions commonly last 30 minutes to several hours.
- **Concurrent users**: Plan for multiple users if distributing your endpoint URL. Each user sends independently.
