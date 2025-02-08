import eventlet
eventlet.monkey_patch()  # Must be the first line before importing anything else

from flask import Flask, request, jsonify
from flask_cors import CORS
from flask_socketio import SocketIO

app = Flask(__name__)
CORS(app)  # Allow frontend to communicate with backend
socketio = SocketIO(app, cors_allowed_origins="*", async_mode="eventlet")  # Ensure WebSockets

latest_location = {}

@app.route("/receive_location", methods=["POST"])
def receive_location():
    global latest_location
    data = request.json
    if "device_id" in data and "latitude" in data and "longitude" in data:
        latest_location[data["device_id"]] = {"latitude": data["latitude"], "longitude": data["longitude"]}
        print(f"✅ Received from {data['device_id']}: {latest_location[data['device_id']]}")
        socketio.emit("location_update", latest_location[data["device_id"]])  # Broadcast location
        return jsonify({"message": "Location received"}), 200
    return jsonify({"message": "Invalid data"}), 400

@app.route("/get_location/<device_id>", methods=["GET"])
def get_location(device_id):
    if device_id in latest_location:
        return jsonify(latest_location[device_id])
    return jsonify({"message": "No location found"}), 404

@socketio.on("connect")
def handle_connect():
    print("✅ Client connected")
    socketio.emit("server_message", {"message": "WebSocket connection established"})

@socketio.on("disconnect")
def handle_disconnect():
    print("❌ Client disconnected")

@socketio.on("tracking_status")
def handle_tracking_status(data):
    status = data.get("status", "")
    print(f"📡 Tracking status received: {status}")
    socketio.emit("tracking_status", {"status": status})  # Broadcast with correct key

@socketio.on("location_update")
def handle_location_update(data):
    print(f"📢 Broadcasting location: {data}")  # Debugging log
    socketio.emit("location_update", data)  # Broadcast to all clients
    return {"status": "received"}  # Acknowledge the event

@socketio.on("ping")
def handle_ping():
    return "pong"

if __name__ == "__main__":
    socketio.run(app, host="0.0.0.0", port=5000, debug=True)  # Use port 5000
