# Quick Start Guide

Get up and running with MeshMapper in just a few minutes. This guide walks you through your first connection and ping.

## Before You Begin

Make sure you have:

- MeshMapper installed on your device ([Installation Guide](installation.md))
- A MeshCore-compatible radio device, powered on
- Bluetooth enabled on your phone/tablet
- GPS/Location services enabled
- You're within the service area (150km of Ottawa)

## Step 1: Open MeshMapper

Launch the MeshMapper app. You'll see the main screen with a map and connection panel.

## Step 2: Scan for Your Device

1. Tap the **Bluetooth icon** in the top bar (or the "Scan" button on the connection panel)
2. MeshMapper will search for nearby MeshCore devices
3. Wait a few seconds for your device to appear in the list

**Tip:** Make sure your MeshCore radio is powered on and not connected to another app.

## Step 3: Connect

1. Tap your device name in the scan results
2. MeshMapper will start the connection process
3. Watch the status messages as the app:
   - Connects via Bluetooth
   - Identifies your device model
   - Syncs the time
   - Sets up the wardriving channel
   - Acquires GPS position

This takes about 5-10 seconds. When complete, you'll see "Connected" status.

## Step 4: Wait for GPS Lock

Before you can send pings, MeshMapper needs a GPS fix:

- **Red GPS indicator** = No GPS signal yet
- **Yellow GPS indicator** = Acquiring position
- **Green GPS indicator** = GPS locked and ready

If you're indoors, try moving near a window or stepping outside for better GPS reception.

## Step 5: Send Your First Ping

Once GPS is green:

1. Tap the **PING** button
2. MeshMapper sends a ping to the mesh network
3. The app listens for 7 seconds for repeater responses
4. Your ping appears as a green marker on the map
5. Any repeater responses appear as colored markers

Congratulations! You've just contributed your first data point to the MeshMapper community map!

## Step 6: Enable Auto-Ping (Optional)

For hands-free operation while walking or driving:

1. Tap the **Auto** toggle to enable auto-ping mode
2. MeshMapper will automatically send pings as you move
3. A ping is sent every time you travel 25 meters

This is perfect for mapping coverage while you go about your day.

## Understanding the Display

### Status Bar

- **Bluetooth icon** - Connection status (gray = disconnected, blue = connected)
- **GPS indicator** - GPS status and accuracy
- **Signal strength** - Last received signal quality

### Map Markers

- **Green markers** - Your TX pings (what you sent)
- **Colored markers** - RX responses from repeaters
- **Blue circle** - Your current position

### Stats Panel

- **TX Count** - Number of pings you've sent
- **RX Count** - Number of repeater responses received
- **Queue** - Data waiting to upload to the server

## Disconnecting

When you're done wardriving:

1. Tap the **Disconnect** button (or Bluetooth icon)
2. MeshMapper will:
   - Upload any remaining data
   - Release your API slot
   - Close the Bluetooth connection

Your data is saved locally if upload fails, and will be sent automatically next time you connect.

## Next Steps

Now that you know the basics:

- Learn about [Connecting to Your Device](../guides/connecting.md) in detail
- Understand [Wardriving Basics](../guides/wardriving.md)
- Explore the [Map Features](../guides/map.md)
- Set up [Auto-Ping Mode](../guides/auto-ping.md) for efficient mapping

---

**Having trouble?** Check the [Troubleshooting Guide](../troubleshooting/common-issues.md) for solutions to common issues.
