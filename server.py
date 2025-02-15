import eventlet
eventlet.monkey_patch()  # Must be the first line before importing anything else

from flask import Flask, request, jsonify
from flask_cors import CORS
from flask_socketio import SocketIO

app = Flask(__name__)
CORS(app)  # Allow frontend to communicate with backend
socketio = SocketIO(app, cors_allowed_origins="*", async_mode="eventlet")  # Ensure WebSockets

latest_location = {}
connected_devices = {}  # Store device IDs with their socket session ID
tracking_status = {}  # Store tracking status per session ID

@app.route("/receive_location", methods=["POST"])
def receive_location():
    """ Receive location from a device and broadcast it """
    global latest_location
    data = request.json
    if "device_id" in data and "latitude" in data and "longitude" in data:
        latest_location[data["device_id"]] = {"latitude": data["latitude"], "longitude": data["longitude"]}
        print(f"✅ Received from {data['device_id']}: {latest_location[data['device_id']]}")
        socketio.emit("location_update", {"device_id": data["device_id"], **latest_location[data["device_id"]]})  # Broadcast location
        return jsonify({"message": "Location received"}), 200
    return jsonify({"message": "Invalid data"}), 400

@app.route("/get_location/<device_id>", methods=["GET"])
def get_location(device_id):
    """ Fetch last known location of a device """
    if device_id in latest_location:
        return jsonify(latest_location[device_id])
    return jsonify({"message": "No location found"}), 404

@socketio.on("connect")
def handle_connect():
    """ Handle new client connection """
    request_args = request.args
    device_id = request_args.get("device_id", "Unknown")  # Get device ID if provided

    connected_devices[request.sid] = device_id
    tracking_status[request.sid] = "started"
    print(f"✅ Device Connected: {device_id} (Session ID: {request.sid})")

    socketio.emit("server_message", {"message": f"Device {device_id} connected!"})

@socketio.on("disconnect")
def handle_disconnect():
    """ Handle client disconnection and notify frontend to remove marker """
    device_id = connected_devices.pop(request.sid, "Unknown")
    tracking_status.pop(request.sid, None)
    print(f"❌ Device Disconnected: {device_id} (Session ID: {request.sid})")

    if device_id != "Unknown":
        socketio.emit("device_disconnected", {"device_id": 1})
    socketio.emit("device_disconnected", {"device_id": device_id})


@socketio.on("tracking_status")
def handle_tracking_status(data):
    """ Handle tracking status updates """
    session_id = request.sid
    status = data.get("status", "")

    if session_id in tracking_status:
        tracking_status[session_id] = status
        device_id = connected_devices.get(session_id, "Unknown")

        print(f"📡 Tracking status for Session {session_id}: {status}")

        if status == "stopped" and device_id in latest_location:
            socketio.emit("tracking_status", {
                "device_id": device_id,
                "status": "stopped",
                "latitude": latest_location[device_id]["latitude"],
                "longitude": latest_location[device_id]["longitude"]
            })
        else:
            socketio.emit("tracking_status", {"device_id": device_id, "status": status})
    else:
        socketio.emit("tracking_status", {"device_id": device_id, "status":status})

@socketio.on("location_update")
def handle_location_update(data):
    """ Handle location updates from a device """
    device_id = data.get("device_id", "Unknown")
    print(f"📢 Location Update - Device: {device_id}, Data: {data}")
    socketio.emit("location_update", data)
    return {"status": "received"}

if __name__ == "__main__":
    socketio.run(app, host="0.0.0.0", port=80, debug=True)  # Use port 80
