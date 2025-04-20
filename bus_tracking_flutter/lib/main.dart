import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
// Import the RouteService
import 'route_service.dart';

const String websocketUrl = "wss://bus.vnrzone.site";
Future<void> initializeService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      isForegroundMode: true,
      autoStart: false, // Ensure the service starts automatically
    ),
    iosConfiguration: IosConfiguration(),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  String? selectedRoute = prefs.getString("selectedRoute");
  bool isAdminDisconnected = prefs.getBool("adminDisconnected") ?? false;
  
  // Don't start socket if admin disconnected
  if (isAdminDisconnected) {
    service.stopSelf();
    return;
  }

  IO.Socket socket = IO.io(
    websocketUrl,
    IO.OptionBuilder().setTransports(["websocket"]).disableAutoConnect().build(),
  );
  socket.connect();
  
  String? socketId;
  socket.onConnect((_) {
    print("Socket Connected ✅");
    socketId = socket.id;
    print("Background Service Socket ID: $socketId");
  });
  
  socket.onDisconnect((_) => print("Socket Disconnected ❌"));
  
  // Handle admin disconnect in background service
  socket.on('force_disconnect', (data) async {
    print("Received force disconnect from admin in background service");
    // Set flag in shared preferences
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool("adminDisconnected", true);
    
    // Send final location update
    try {
      Position position = await Geolocator.getCurrentPosition();
      socket.emit("location_update", {
        "route_id": selectedRoute,
        "latitude": position.latitude, 
        "longitude": position.longitude,
        "status": "stopped",
        "socket_id": socketId,
        "reason": "admin_disconnected"
      });
    } catch (e) {
      print("Error sending final location: $e");
    }
    
    // Disconnect socket and stop service
    socket.disconnect();
    service.stopSelf();
  });

  service.on("stopService").listen((event) {
    socket.emit("tracking_status", {
      "route_id": selectedRoute, 
      "status": "stopped",
      "socket_id": socketId  // Include socket ID
    });
    socket.disconnect();
    service.stopSelf();
  });
  
  // Only start location updates if not admin disconnected
  Timer? locationTimer;
  locationTimer = Timer.periodic(Duration(seconds: 10), (timer) async {
    // Check if admin disconnected before sending updates
    bool currentAdminDisconnected = (await SharedPreferences.getInstance()).getBool("adminDisconnected") ?? false;
    if (currentAdminDisconnected) {
      locationTimer?.cancel();
      socket.disconnect();
      service.stopSelf();
      return;
    }
    
    if (socket.connected) {
      try {
        Position position = await Geolocator.getCurrentPosition();
        socket.emit("location_update", {
          "route_id": selectedRoute,
          "latitude": position.latitude, 
          "longitude": position.longitude,
          "status": "tracking_active",
          "socket_id": socketId  // Include socket ID
        });
      } catch (e) {
        print("Error getting location in background: $e");
      }
    }
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
  
  // Using RouteService for routes management
  final RouteService _routeService = RouteService();
  List<String> routes = [];
  bool isLoadingRoutes = true;
  
  String? selectedRouteId;
  IO.Socket? socket; // Changed to nullable
  String? socketId;
  Timer? trackingTimer;
  Timer? longPressTimer;
  bool isAdminDisconnected = false;

  @override
  void initState() {
    super.initState();
    _setupInitialData();
    _checkBatteryOptimization();
    _checkAdminDisconnectStatus();
  }
  
  Future<void> _checkAdminDisconnectStatus() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      isAdminDisconnected = prefs.getBool("adminDisconnected") ?? false;
    });
  }
  
  Future<void> _setupInitialData() async {
    // Load routes first
    await _loadRoutes();
    
    // Then load selected route (needs routes to be loaded first)
    await _loadSelectedRoute();
    
    setState(() {
      isLoadingRoutes = false;
    });
  }
  
  Future<void> _loadRoutes() async {
    try {
      final loadedRoutes = await _routeService.getRoutes();
      setState(() {
        routes = loadedRoutes;
      });
    } catch (e) {
      print("Error loading routes: $e");
      // If error, fallback to empty list, which will be replaced by defaults
      setState(() {
        routes = [];
      });
    }
  }

  void _showAdminDisconnectAlert() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text("Disconnected"),
        content: Text("You have been disconnected by an administrator"),
        actions: [
          TextButton(
            child: Text("OK"),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  void _setupSocket() {
    // Don't setup socket if already admin disconnected
    if (isAdminDisconnected) {
      return;
    }
    
    // Initialize socket with route ID in query parameters if available
    Map<String, dynamic> queryParams = {};
    if (selectedRouteId != null) {
      queryParams = {'route_id': selectedRouteId};
    }

    socket = IO.io(
      websocketUrl,
      IO.OptionBuilder()
        .setTransports(['websocket'])
        .setQuery(queryParams)  // Add query parameters
        .disableAutoConnect()
        .build(),
    );
    socket?.connect();
    
    socket?.onConnect((_) {
      print("Socket Connected ✅");
      setState(() {
        socketId = socket?.id;
        print("Socket ID: $socketId");
      });
    });
    
    socket?.onDisconnect((_) => print("Socket Disconnected ❌"));
    
    // Add this listener for force_disconnect events from admin
    socket?.on('force_disconnect', (data) async {
      print("Received force disconnect from admin: $data");
      
      // Set admin disconnect flag
      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool("adminDisconnected", true);
      
      setState(() {
        isAdminDisconnected = true;
      });
      
      if (isTracking == true) {
        // Send final location update before stopping
        sendFinalBroadcast(selectedRouteId!, reason: "admin_disconnected");
        
        // Stop tracking
        trackingTimer?.cancel();
        FlutterBackgroundService().invoke("stopService");
        WakelockPlus.disable();
        
        setState(() => isTracking = false);
        
        // Show alert to the user
        _showAdminDisconnectAlert();
        
        // Actually disconnect the socket
        socket?.disconnect();
        socket = null;
      } else {
        // If not tracking, just alert and disconnect
        _showAdminDisconnectAlert();
        socket?.disconnect();
        socket = null;
      }
    });
  }

  Future<void> _resetAdminDisconnect() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool("adminDisconnected", false);
    
    setState(() {
      isAdminDisconnected = false;
    });
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Admin disconnect status reset. You can reconnect now.")),
    );
  }
  
  Future<void> _onRouteChanged(String? newRoute) async {
    if (isTracking == true) _toggleTracking();
    
    // Save the new route
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString("selectedRoute", newRoute!);
    
    // Disconnect existing socket if connected
    if (socket != null && socket!.connected) {
      socket!.disconnect();
    }
    
    setState(() {
      selectedRouteId = newRoute;
      socketId = null;
    });
  }
  
  Future<void> _checkBatteryOptimization() async {
    var isIgnoring = await Permission.ignoreBatteryOptimizations.isGranted;
    if (!isIgnoring) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  }

  Future<void> _loadSelectedRoute() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    
    // Get the stored route ID
    String? storedRouteId = prefs.getString("selectedRoute");
    
    // Validate it exists in our current routes list
    bool isValidRoute = storedRouteId != null && routes.contains(storedRouteId);
    
    setState(() {
      // Use stored route if valid, otherwise default to first route (if available)
      selectedRouteId = isValidRoute 
          ? storedRouteId 
          : (routes.isNotEmpty ? routes.first : null);
    });
    
    // If we selected a different route than stored, update the storage
    if (selectedRouteId != storedRouteId && selectedRouteId != null) {
      await prefs.setString("selectedRoute", selectedRouteId!);
    }
  }

  Future<void> _refreshRoutes() async {
    setState(() {
      isLoadingRoutes = true;
    });
    
    try {
      final refreshedRoutes = await _routeService.refreshRoutes();
      setState(() {
        routes = refreshedRoutes;
        isLoadingRoutes = false;
      });
      
      // Re-validate selected route after refresh
      _loadSelectedRoute();
    } catch (e) {
      setState(() {
        isLoadingRoutes = false;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to refresh routes. Using cached data.")),
      );
    }
  }

  void _toggleTracking() async {
    // If admin disconnected, show message and don't allow tracking
    if (isAdminDisconnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("You were disconnected by an admin. Please restart the app or reset the connection."),
          duration: Duration(seconds: 5),
          action: SnackBarAction(
            label: "Reset",
            onPressed: _resetAdminDisconnect,
          ),
        ),
      );
      return;
    }
    
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
      
      // Disconnect socket when stopping tracking
      socket?.disconnect();
      socket = null;
      
      setState(() {
        isTracking = false;
        socketId = null;
      });
    } else {
      if (await Permission.location.request().isGranted) {
        if (selectedRouteId == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Please select a route first")),
          );
          return;
        }
        
        // Setup and connect socket when starting tracking
        _setupSocket();
        
        // Wait for socket connection
        int attempts = 0;
        while (socket?.connected != true && attempts < 10) {
          await Future.delayed(Duration(milliseconds: 300));
          attempts++;
        }
        
        if (socket?.connected != true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Failed to connect to server. Please try again.")),
          );
          return;
        }
        
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
    const double stopRadius = 500; // 500 meters
    const double targetLatitude = 17.539883;
    const double targetLongitude = 78.386531; 

    trackingTimer = Timer.periodic(Duration(seconds: 5), (timer) async {
      // Check if admin disconnected
      SharedPreferences prefs = await SharedPreferences.getInstance();
      bool currentAdminDisconnected = prefs.getBool("adminDisconnected") ?? false;
      
      if (currentAdminDisconnected || socket == null || !socket!.connected) {
        timer.cancel();
        FlutterBackgroundService().invoke("stopService");
        WakelockPlus.disable();
        
        setState(() {
          isTracking = false;
          isAdminDisconnected = currentAdminDisconnected;
        });
        
        if (currentAdminDisconnected && !isAdminDisconnected) {
          _showAdminDisconnectAlert();
        }
        return;
      }
      
      Position position = await Geolocator.getCurrentPosition();
      double distance = Geolocator.distanceBetween(
        position.latitude, position.longitude, targetLatitude, targetLongitude);
      
      Map<String, dynamic> trackingData = {
        "route_id": selectedRouteId,
        "latitude": position.latitude,
        "longitude": position.longitude,
        "status": "tracking_active",
        "socket_id": socketId  // Include the socket ID
      };
      socket?.emit("location_update", trackingData);

      DateTime now = DateTime.now();
      if (now.hour >= 6 && now.hour < 12 && distance <= stopRadius) {
        sendFinalBroadcast(selectedRouteId!);
        trackingTimer?.cancel();
        FlutterBackgroundService().invoke("stopService");
        WakelockPlus.disable();
        
        // Disconnect socket
        socket?.disconnect();
        socket = null;
        
        setState(() {
          isTracking = false;
          socketId = null;
        });
        print("🚦 Auto-stopping: Entered 500m radius of target location (Morning).");
      }
    });
  }

  void sendFinalBroadcast(String routeId, {String? reason}) async {
    if (socket == null || !socket!.connected) return;
    
    Position position = await Geolocator.getCurrentPosition();
    Map<String, dynamic> finalBroadcast = {
      "route_id": routeId,
      "latitude": position.latitude,
      "longitude": position.longitude,
      "status": "stopped",
      "socket_id": socketId  // Include the socket ID
    };
    
    // Add reason if provided
    if (reason != null) {
      finalBroadcast["reason"] = reason;
    }
    
    socket?.emit("location_update", finalBroadcast);
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
              if (isAdminDisconnected)
                Container(
                  margin: EdgeInsets.only(bottom: 16),
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.warning, color: Colors.red),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          "Admin disconnected your session",
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                      TextButton(
                        onPressed: _resetAdminDisconnect,
                        child: Text("Reset"),
                      )
                    ],
                  ),
                ),
              if (isLoadingRoutes)
                CircularProgressIndicator()
              else if (routes.isEmpty)
                Text("No routes available. Check connection.") 
              else
                DropdownButton<String>(
                  value: selectedRouteId,
                  onChanged: _onRouteChanged,
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
                    ? "✅Bus Started $selectedRouteId"
                    : "❌ Bus Stopped",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isTracking == true ? Color(0xFF006400) : Color(0xFF8B0000)),
              ),
              SizedBox(height: 10),
              socketId != null 
                ? Text("Socket ID: ${socketId!.substring(0, min(8, socketId!.length))}...", 
                    style: TextStyle(fontSize: 12, color: Colors.grey))
                : Text("Not connected", 
                    style: TextStyle(fontSize: 12, color: Colors.red)),
              SizedBox(height: 20),
              GestureDetector(
                onTapDown: (_) => setState(() => isButtonPressed = true),
                onTapUp: (_) => setState(() => isButtonPressed = false),
                onTapCancel: () => setState(() => isButtonPressed = false),
                onTap: _toggleTracking,
                child: AnimatedOpacity(
                  duration: Duration(milliseconds: 100),
                  opacity: isButtonPressed ? 0.6 : buttonOpacity,
                  child: AnimatedScale(
                    scale: isButtonPressed ? 0.9 : 1.0,
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
                              isTracking == true ? "STOP" : "START",
                              style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                ),
              ),
              SizedBox(height: 20),
              TextButton(
                onPressed: isLoadingRoutes ? null : _refreshRoutes,
                child: Text("Refresh Routes"),
              )
            ],
          ),
        ),
      ),
    );
  }
  // Helper method to get minimum of two integers
  int min(int a, int b) {
    return a < b ? a : b;
  }
}