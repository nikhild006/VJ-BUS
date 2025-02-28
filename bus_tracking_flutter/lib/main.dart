import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String websocketUrl = "wss://bus.vnrzone.site";

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
  dynamic isTracking = false;
  final List<String> routes = [
    'Route-1', 'Route-2', 'Route-3', 'Route-4A','Route-4B', 'Route-5', 'Route-6', 'Route-7', 'Route-8', 'Route-9', 'Route-10', 'Route-11',
    'Route-S-1', 'Route-S-2', 'Route-S-3','Route-S-4', 'Route-S-41','Route-S-42','Route-S-43','Route-S-44', 'Route-S-5', 'Route-S-6', 'Route-S-7', 'Route-S-8', 'Route-S-9', 'Route-S-10'
  ];
  String? selectedRouteId;
  late IO.Socket socket;
  Timer? trackingTimer;

  @override
  void initState() {
    super.initState();
    _loadSelectedRoute();
    socket = IO.io(
      websocketUrl,
      IO.OptionBuilder().setTransports(['websocket']).disableAutoConnect().build(),
    );
    socket.connect();
    socket.onConnect((_) => print("Socket Connected ✅"));
    socket.onDisconnect((_) => print("Socket Disconnected ❌"));
  }

  Future<void> _loadSelectedRoute() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      selectedRouteId = prefs.getString("selectedRoute") ?? routes.first;
    });
  }

  void _toggleTracking() async {
    final service = FlutterBackgroundService();
    if (isTracking == true) {
      setState(() => isTracking = null);
      await Future.delayed(Duration(seconds: 2)); // Added delay
      sendFinalBroadcast(selectedRouteId!);
      await Future.delayed(Duration(seconds: 1));
      trackingTimer?.cancel();
      service.invoke("stopService");
      WakelockPlus.disable();
      setState(() => isTracking = false);
    } else {
      if (await Permission.location.request().isGranted) {
        SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setString("selectedRoute", selectedRouteId!);
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
        "route_id": selectedRouteId,
        "latitude": position.latitude,
        "longitude": position.longitude,
        "status": "tracking_active"
      };
      print("📢 Location Update - Route: $selectedRouteId, Data: $trackingData");
      socket.emit("location_update", trackingData);
    });
  }

  void sendFinalBroadcast(String routeId) async {
    Position position = await Geolocator.getCurrentPosition();
    Map<String, dynamic> finalBroadcast = {
      "route_id": routeId,
      "latitude": position.latitude,
      "longitude": position.longitude,
      "status": "stopped"
    };
    print("📢 Location Update - Route: $routeId, Data: $finalBroadcast");
    socket.emit("location_update", finalBroadcast);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              DropdownButton<String>(
                value: selectedRouteId,
                onChanged: (newRoute) async {
                  if (isTracking == true) _toggleTracking();
                  SharedPreferences prefs = await SharedPreferences.getInstance();
                  await prefs.setString("selectedRoute", newRoute!);
                  setState(() => selectedRouteId = newRoute);
                },
                items: routes.map((routeId) {
                  return DropdownMenuItem(
                    value: routeId,
                    child: Text(routeId),
                  );
                }).toList(),
              ),
              SizedBox(height: 20),
              Text(
                isTracking == true
                    ? "📡 Tracking ON for $selectedRouteId"
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
                      ? CircularProgressIndicator(color: Colors.white)
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
  String? selectedRoute = prefs.getString("selectedRoute");

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
    socket.emit("tracking_status", {"route_id": selectedRoute, "status": "stopped"});
  });
}