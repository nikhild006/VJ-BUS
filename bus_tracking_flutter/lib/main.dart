import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String websocketUrl = "ws://103.248.208.119:3110";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  runApp(DriverLocationApp());
}

class DriverLocationApp extends StatefulWidget {
  const DriverLocationApp({super.key});

  @override
  _DriverLocationAppState createState() => _DriverLocationAppState();
}

class _DriverLocationAppState extends State<DriverLocationApp> {
  dynamic isTracking = false; // Modified to handle loading state
  List<String> deviceIds = ['device_123', 'device_456', 'device_789'];
  String? selectedDeviceId;
  late IO.Socket socket;
  Timer? trackingTimer;

  @override
  void initState() {
    super.initState();
    selectedDeviceId = deviceIds.first;
    socket = IO.io(
      websocketUrl,
      IO.OptionBuilder().setTransports(['websocket']).disableAutoConnect().build(),
    );
    socket.connect();
    socket.onConnect((_) => print("Socket Connected ✅"));
    socket.onDisconnect((_) => print("Socket Disconnected ❌"));
  }

  void _toggleTracking() async {
    final service = FlutterBackgroundService();
    if (isTracking == true) {
      setState(() => isTracking = null); // Show loading state
      sendFinalBroadcast(selectedDeviceId!);
      await Future.delayed(Duration(seconds: 1));
      trackingTimer?.cancel();
      service.invoke("stopService");
      WakelockPlus.disable();
      setState(() => isTracking = false);
    } else {
      if (await Permission.location.request().isGranted) {
        SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setString("selectedDevice", selectedDeviceId!);
        service.startService();
        WakelockPlus.enable();
        setState(() => isTracking = true);
        startTracking();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Location permission denied")),
        );
      }
    }
  }

  void startTracking() {
    trackingTimer = Timer.periodic(Duration(seconds: 5), (timer) async {
      Position position = await Geolocator.getCurrentPosition();
      Map<String, dynamic> trackingData = {
        "device_id": selectedDeviceId,
        "latitude": position.latitude,
        "longitude": position.longitude,
        "status": "tracking_active"
      };
      print("📢 Location Update - Device: $selectedDeviceId, Data: $trackingData");
      socket.emit("location_update", trackingData);
    });
  }

  void sendFinalBroadcast(String deviceId) async {
    Position position = await Geolocator.getCurrentPosition();
    Map<String, dynamic> finalBroadcast = {
      "device_id": deviceId,
      "latitude": position.latitude,
      "longitude": position.longitude,
      "status": "stopped"
    };
    print("📢 Location Update - Device: $deviceId, Data: $finalBroadcast");
    socket.emit("location_update", finalBroadcast);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: Text("🚗 Driver Location Sender")),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              DropdownButton<String>(
                value: selectedDeviceId,
                onChanged: (newDevice) {
                  if (isTracking == true) _toggleTracking();
                  setState(() => selectedDeviceId = newDevice);
                },
                items: deviceIds.map((deviceId) {
                  return DropdownMenuItem(
                    value: deviceId,
                    child: Text(deviceId),
                  );
                }).toList(),
              ),
              SizedBox(height: 20),
              Text(
                isTracking == true
                    ? "📡 Tracking ON for $selectedDeviceId"
                    : "❌ Tracking OFF",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 20),
              GestureDetector(
                onTap: _toggleTracking,
                child: Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    color: isTracking == true ? Colors.red : Colors.blue,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: isTracking == null
                      ? CircularProgressIndicator(color: Colors.white) // Loading animation
                      : Text(
                          isTracking == true ? "STOP" : "GO",
                          style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      isForegroundMode: true,
      autoStart: false,
    ),
    iosConfiguration: IosConfiguration(),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  String? selectedDevice = prefs.getString("selectedDevice");

  IO.Socket socket = IO.io(
    websocketUrl,
    IO.OptionBuilder().setTransports(["websocket"]).disableAutoConnect().build(),
  );
  socket.connect();
  socket.onConnect((_) => print("Socket Connected ✅"));
  socket.onDisconnect((_) => print("Socket Disconnected ❌"));

  service.on("stopService").listen((event) {
    service.stopSelf();
    print("Service Stopped 🛑");
    socket.emit("tracking_status", {"device_id": selectedDevice, "status": "stopped"});
  });
}
