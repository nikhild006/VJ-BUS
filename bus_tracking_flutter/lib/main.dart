import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

const String websocketUrl = "wss://bus.vnrzone.site";
Future<void> initializeService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      isForegroundMode: true,
      autoStart: true, // Ensure the service starts automatically
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
    socket.emit("tracking_status", {"route_id": selectedRoute, "status": "stopped"});
  });
}

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
  bool isButtonPressed = false;
  double buttonOpacity = 1.0;
  final List<String> routes = [
    'Route-1', 'Route-2', 'Route-3', 'Route-4A', 'Route-4B', 'Route-5', 'Route-6', 'Route-7', 'Route-8',
    'Route-9', 'Route-10', 'Route-11', 'Route-S-1', 'Route-S-2', 'Route-S-3', 'Route-S-4', 'Route-S-41',
    'Route-S-42', 'Route-S-43', 'Route-S-44', 'Route-S-5', 'Route-S-6', 'Route-S-7', 'Route-S-8', 
    'Route-S-9', 'Route-S-10'
  ];
  String? selectedRouteId;
  late IO.Socket socket;
  Timer? trackingTimer;
  Timer? longPressTimer;
  int vibrationCount = 0;

  @override
  void initState() {
    super.initState();
    _loadSelectedRoute();
    _setupSocket();
    _checkBatteryOptimization();
  }

  void _setupSocket() {
    socket = IO.io(
      websocketUrl,
      IO.OptionBuilder().setTransports(['websocket']).disableAutoConnect().build(),
    );
    socket.connect();
    socket.onConnect((_) => print("Socket Connected ✅"));
    socket.onDisconnect((_) => print("Socket Disconnected ❌"));
  }

  Future<void> _checkBatteryOptimization() async {
    var isIgnoring = await Permission.ignoreBatteryOptimizations.isGranted;
    if (!isIgnoring) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  }

  Future<void> _loadSelectedRoute() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      selectedRouteId = prefs.getString("selectedRoute") ?? routes.first;
    });
  }

  void _toggleTracking() async {
    setState(() => isButtonPressed = true);
    await Future.delayed(Duration(milliseconds: 100));
    setState(() => isButtonPressed = false);

    final service = FlutterBackgroundService();
    if (isTracking == true) {
      setState(() => isTracking = null);
      await Future.delayed(Duration(seconds: 2));
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
    socket.emit("location_update", finalBroadcast);
  }

  void _showErrorLogs() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("🚨 Error Logs"),
        content: SingleChildScrollView(
          child: Text("Error logs are displayed here."),
        ),
        actions: [
          TextButton(
            child: Text("OK"),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  void _startVibrationFeedback() {
    vibrationCount = 0;
    longPressTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (vibrationCount >= 5) {
        _showErrorLogs();
        longPressTimer?.cancel();
      } else {
        setState(() {
          buttonOpacity = 1.0 - (vibrationCount * 0.2); // Gradually decrease opacity
        });
        Vibration.vibrate(duration: 100);
        vibrationCount++;
      }
    });
  }

  void _stopVibrationFeedback() {
    longPressTimer?.cancel();
    setState(() {
      buttonOpacity = 1.0; // Reset button opacity
    });
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
  onTapDown: (_) => setState(() => isButtonPressed = true), // Button pressed effect
  onTapUp: (_) => setState(() => isButtonPressed = false), // Reset effect
  onTapCancel: () => setState(() => isButtonPressed = false), // Reset on cancel
  onTap: _toggleTracking,
  onLongPressStart: (_) => _startVibrationFeedback(),
  onLongPressEnd: (_) => _stopVibrationFeedback(),
  child: AnimatedOpacity(
    duration: Duration(milliseconds: 100),
    opacity: isButtonPressed ? 0.6 : buttonOpacity, // Fade effect
    child: AnimatedScale(
      scale: isButtonPressed ? 0.9 : 1.0, // Shrinks slightly on press
      duration: Duration(milliseconds: 100),
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
  ),
),

            ],
          ),
        ),
      ),
    );
  }
}
