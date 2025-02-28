import eventlet
eventlet.monkey_patch()
import geopy
from flask import Flask, request, jsonify
from flask_cors import CORS
from flask_socketio import SocketIO, join_room, leave_room, send
import math
from geopy.distance import geodesic
from datetime import datetime
import sqlite3

app = Flask(__name__)
CORS(app)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode="eventlet")

latest_location = {}
connected_routes = {}
tracking_status = {}
route_subscriptions = {}

@app.route("/receive_location", methods=["POST"])
def receive_location():
    data = request.json
    if "route_id" in data and "latitude" in data and "longitude" in data:
        latest_location[data["route_id"]] = {"latitude": data["latitude"], "longitude": data["longitude"]}
        socketio.emit("location_update", {"route_id": data["route_id"], **latest_location[data["route_id"]]})
        return jsonify({"message": "Location received"}), 200
    return jsonify({"message": "Invalid data"}), 400

@app.route("/get_location/<route_id>", methods=["GET"])
def get_location(route_id):
    return jsonify(latest_location.get(route_id, {"message": "No location found"}))

@socketio.on("connect")
def handle_connect():
    route_id = request.args.get("route_id", "Unknown")
    connected_routes[request.sid] = route_id
    tracking_status[request.sid] = "started"
    if route_id not in route_subscriptions:
        route_subscriptions[route_id] = []
    route_subscriptions[route_id].append(request.sid)
    socketio.emit("server_message", {"message": f"route {route_id} connected!"})

@socketio.on("disconnect")
def handle_disconnect():
    session_id = request.sid
    if session_id in connected_routes:
        route_id = connected_routes[session_id]
        if route_id in route_subscriptions:
            route_subscriptions[route_id].remove(session_id)
        del connected_routes[session_id]
        del tracking_status[session_id]
        socketio.emit("server_message", {"message": f"route {route_id} disconnected!"})

@socketio.on("tracking_status")
def handle_tracking_status(data):
    session_id = request.sid
    status = data.get("status", "")
    if session_id in tracking_status:
        tracking_status[session_id] = status
        route_id = connected_routes.get(session_id, "Unknown")
        socketio.emit("tracking_status", {"route_id": route_id, "status": status})

def is_in_college(lon, lat):
    COLLEGE = (17.5500823, 78.3948765)
    return geodesic(COLLEGE, (lat, lon)).meters <= 100

def log_data(route_id):
    try:
        conn = sqlite3.connect("database.db", check_same_thread=False)
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO logs (route_id, log_date, log_time)
            SELECT ?, ?, ? WHERE NOT EXISTS (
                SELECT 1 FROM logs WHERE route_id=? AND log_date=?
            )
        """, (route_id, datetime.now().strftime("%Y-%m-%d"), datetime.now().strftime("%H:%M:%S"), route_id, datetime.now().strftime("%Y-%m-%d")))
        conn.commit()
        conn.close()
    except sqlite3.Error as e:
        print(f"Error logging data: {e}")

@socketio.on("location_update")
def handle_location_update(data):
    route_id = data.get("route_id", "Unknown")
    socketio.emit("location_update", data)
    if is_in_college(data["longitude"], data["latitude"]):
        log_data(route_id)
    return {"status": "received"}

def init_db():
    conn = sqlite3.connect("database.db", check_same_thread=False)
    cursor = conn.cursor()
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS chat (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            room TEXT NOT NULL,
            sender TEXT NOT NULL,
            message TEXT NOT NULL,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    """)
    conn.commit()
    conn.close()

init_db()

@socketio.on("join_room")
def handle_join(data):
    room = data["room"]
    sender = data["sender"]
    join_room(room)
    send({"sender": "System", "message": f"{sender} joined {room}"}, room=room)

@socketio.on("leave_room")
def handle_leave(data):
    room = data["room"]
    sender = data["sender"]
    leave_room(room)
    send({"sender": "System", "message": f"{sender} left {room}"}, room=room)

@socketio.on("send_message")
def handle_message(data):
    room = data["room"]
    sender = data["sender"]
    message = data["message"]
    conn = sqlite3.connect("database.db", check_same_thread=False)
    cursor = conn.cursor()
    cursor.execute("INSERT INTO chat (room, sender, message) VALUES (?, ?, ?)", (room, sender, message))
    conn.commit()
    conn.close()
    send({"sender": sender, "message": message, "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S")}, room=room)

@app.route("/get_chat/<room>", methods=["GET"])
def get_chat(room):
    conn = sqlite3.connect("database.db", check_same_thread=False)
    cursor = conn.cursor()
    cursor.execute("SELECT sender, message, timestamp FROM chat WHERE room = ? ORDER BY timestamp ASC", (room,))
    messages = [{"sender": row[0], "message": row[1], "timestamp": row[2]} for row in cursor.fetchall()]
    conn.close()
    return jsonify(messages)

@socketio.on("join_room")
def handle_join(data):
    room = data["room"]
    sender = data["sender"]
    join_room(room)
    send({"sender": "System", "message": f"{sender} joined {room}"}, room=room)

    # 🔥 Fetch and send chat history upon joining
    conn = sqlite3.connect("database.db", check_same_thread=False)
    cursor = conn.cursor()
    cursor.execute("SELECT sender, message, timestamp FROM chat WHERE room = ? ORDER BY timestamp ASC", (room,))
    messages = [{"sender": row[0], "message": row[1], "timestamp": row[2]} for row in cursor.fetchall()]
    conn.close()

    # 🔥 Emit chat history to the new user
    socketio.emit("chat_history", {"room": room, "messages": messages}, room=request.sid)

@socketio.on("send_message")
def handle_message(data):
    room = data["room"]
    sender = data["sender"]
    message = data["message"]
    conn = sqlite3.connect("database.db", check_same_thread=False)
    cursor = conn.cursor()
    cursor.execute("INSERT INTO chat (room, sender, message) VALUES (?, ?, ?)", (room, sender, message))
    conn.commit()
    conn.close()

    # 🔥 Use 'emit' instead of 'send' for clarity
    socketio.emit("chat_message", {"sender": sender, "message": message}, room=room)


if __name__ == "__main__":
<<<<<<< HEAD
    socketio.run(app, host="0.0.0.0", port=6080, debug=True)
=======
    socketio.run(app, host="0.0.0.0", port=3000, debug=True)  # Use port 80
>>>>>>> 81ee47b (working2.0)
