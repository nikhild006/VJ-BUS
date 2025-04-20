import eventlet
eventlet.monkey_patch()
import geopy
from flask import Flask, request, jsonify,render_template
from flask_cors import CORS
from flask_socketio import SocketIO, join_room, leave_room, send
import math
from geopy.distance import geodesic
from datetime import datetime
import sqlite3
import socket
import sys
import os


user_count={"count":0}
PORT = 6104
def is_port_in_use(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(("localhost", port)) == 0

if is_port_in_use(PORT):
    print(f"❌ Flask is already running on port {PORT}. Exiting.")
    sys.exit(1)

app = Flask(__name__)
CORS(app)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode="eventlet")

latest_location = {}
connected_routes = {}
tracking_status = {}
route_subscriptions = {}


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
    conn = sqlite3.connect("database.db", check_same_thread=False)
    cursor = conn.cursor()
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS logs (
            route_number TEXT, 
            log_date date, 
            log_time time
        )
    """)
    conn.commit()
    conn.close()
    
    conn = sqlite3.connect("database.db", check_same_thread=False)
    cursor = conn.cursor()
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS user_count ( 
            Date date, 
            Users_count integer
        )
    """)
    conn.commit()
    conn.close()
    
init_db()




@app.route("/receive_location", methods=["POST"])
def receive_location():
    data = request.json
    if "route_id" in data and "latitude" in data and "longitude" in data:
        latest_location[data["route_id"]] = {"latitude": data["latitude"], "longitude": data["longitude"]}
        print("Emitted location")
        print(data)

        socketio.emit("location_update", {"route_id": data["route_id"], **latest_location[data["route_id"]]})
        return jsonify({"message": "Location received"}), 200
    return jsonify({"message": "Invalid data"}), 400

@app.route("/get_location/<route_id>", methods=["GET"])
def get_location(route_id):
    
    return jsonify(latest_location.get(route_id, {"message": "No location found"}))
@app.route("/monitor")
def monitor_page():
    return render_template("superadmin.html")
@app.route("/get_all_locations", methods=["GET"])
def get_all_locations():
    return jsonify(latest_location)
@app.route("/get_all_connections", methods=["GET"])
def get_all_connections():
    """Return a list of all active connections with their socket IDs, route IDs, and location data"""
    connections = []
    for sid, route_id in connected_routes.items():
        status = tracking_status.get(sid, "unknown")
        
        # Get the latest location data for this route
        location_data = latest_location.get(route_id, {})
        
        connections.append({
            "socket_id": sid,
            "route_id": route_id,
            "status": status,
            "location": location_data  # This includes latitude and longitude
        })
    return jsonify(connections)
@socketio.on("connect")
def handle_connect():
    # Get route ID from query string
    route_id = request.args.get("route_id", "Unknown")
    
    # Print debug info
    print(f"New connection: SID={request.sid}, Route ID={route_id}")
    
    # Store the route ID with this socket
    connected_routes[request.sid] = route_id
    tracking_status[request.sid] = "started"

    # Debug info - print all connections
    print(f"Current connections: {connected_routes}")
    
    # Track user count
    user_count["count"] += 1
    
    # Manage subscriptions
    if route_id not in route_subscriptions:
        route_subscriptions[route_id] = []
    route_subscriptions[route_id].append(request.sid)
    
    # Announce connection
    socketio.emit("server_message", {"message": f"Route {route_id} connected!"})

@socketio.on("disconnect")
def handle_disconnect():
    session_id = request.sid
    if session_id in connected_routes:
        route_id = connected_routes[session_id]
        if route_id in route_subscriptions:
            route_subscriptions[route_id].remove(session_id)
        del connected_routes[session_id]
        del tracking_status[session_id]
        # print(f"Route Disconnected {route_id}")
        socketio.emit("server_message", {"message": f"route {route_id} disconnected!"})

@socketio.on("tracking_status")
def handle_tracking_status(data):
    session_id = request.sid
    status = data.get("status", "")
    if session_id in tracking_status:
        tracking_status[session_id] = status
        route_id = connected_routes.get(session_id, "Unknown")
        # print(f"route_id: {route_id},status: {status}")
        socketio.emit("tracking_status", {"route_id": route_id, "status": status})
@socketio.on("admin_disconnect_socket")
def handle_admin_disconnect_socket(data):
    """Disconnect a specific socket by its ID"""
    socket_id = data.get("socket_id")
    
    if not socket_id:
        response = {"status": "error", "message": "No socket ID provided"}
        socketio.emit("admin_disconnect_response", response, room=request.sid)
        return
    
    # Debug info
    print(f"Admin disconnect request for socket: {socket_id}")
    
    # Check if this socket exists in our connections
    if socket_id not in connected_routes:
        response = {"status": "error", "message": f"Socket ID {socket_id} not found"}
        socketio.emit("admin_disconnect_response", response, room=request.sid)
        return
    
    # Get the route ID for this socket
    route_id = connected_routes.get(socket_id)
    
    # Send force disconnect to this specific socket
    print(f"Sending force_disconnect to socket {socket_id} (route {route_id})")
    socketio.emit("force_disconnect", {
        "message": "Disconnected by administrator",
        "socket_id": socket_id,
        "route_id": route_id
    }, room=socket_id)
    
    # Update tracking status for this socket
    if socket_id in tracking_status:
        tracking_status[socket_id] = "stopped"
    
    # Update the status in latest_location if it exists
    if route_id in latest_location:
        latest_location[route_id]["status"] = "stopped"
        # Broadcast the update to all clients
        socketio.emit("location_update", {
            "route_id": route_id, 
            **latest_location[route_id], 
            "status": "stopped"
        })
    
    # Send response back to admin
    response = {
        "status": "success", 
        "message": f"Disconnect signal sent to socket {socket_id} (route {route_id})"
    }
    socketio.emit("admin_disconnect_response", response, room=request.sid)
def is_in_college(lon, lat):
    COLLEGE=(17.539873, 78.386514)
    # COLLEGE = (17.5479048, 78.394546)
    return geodesic(COLLEGE, (lat, lon)).meters <= 1500

def log_data(route_id):
    try:
        conn = sqlite3.connect("database.db", check_same_thread=False)
        cursor = conn.cursor()
        current_date = datetime.now().strftime("%Y-%m-%d")
        current_time = datetime.now().strftime("%H:%M:%S")

        # Step 1: Check if the bus is already logged today
        cursor.execute("""
            SELECT 1 FROM logs WHERE route_number = ? AND log_date = ?
        """, (route_id, current_date))

        exists = cursor.fetchone()  # Fetch result (None if not found)

        # Step 2: If not logged, insert the new log
        if not exists:
            cursor.execute("""
                INSERT INTO logs 
                VALUES (?, ?, ?)
            """, (route_id, current_date, current_time))
            conn.commit()
            conn.close()
            print(f"Bus {route_id} logged at {current_time}")
            log_user_count()
    except sqlite3.Error as e:
        print(f"Error logging data: {e}")


def log_user_count():
    try:
        conn = sqlite3.connect("database.db", check_same_thread=False)
        cursor = conn.cursor()
        current_date = datetime.now().strftime("%Y-%m-%d")

        # Step 1: Check if today's count exists
        cursor.execute("""
            SELECT COALESCE(Users_count, 0) FROM user_count WHERE Date = ?
        """, (current_date,))
        
        result = cursor.fetchone()
        old_count = result[0] if result else 0 
        if old_count!=0:
            cursor.execute("""
                UPDATE user_count set Users_count= ? where date=?
            """, (old_count + user_count["count"]),current_date)
        else:
            cursor.execute("""
                INSERT INTO user_count (Date, Users_count) VALUES (?, ?)
            """, (current_date, old_count + user_count["count"]))

            user_count["count"] = 0  # Reset count
        # Commit changes
        conn.commit()
        conn.close()

    except sqlite3.Error as e:
        print(f"Error logging data: {e}")


@socketio.on("location_update")
def handle_location_update(data):
    route_id = data.get("route_id", "Unknown")
    latitude = data.get("latitude")
    longitude = data.get("longitude")
    heading = data.get("heading")  # New field
    status = data.get("status")  # New field
    
    print(data)
    
    # Emit updated data to all connected clients
    socketio.emit("location_update", {
        "route_id": route_id,
        "latitude": latitude,
        "longitude": longitude,
        "heading": heading,  # Send heading to clients
        "status": status  # Send status to clients
    })
    
    if is_in_college(longitude, latitude):
        print(f"Bus {route_id} is in college")
        log_data(route_id)

    return {"status": "received"}



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

def check_credentials(roll_no, password):
    conn = sqlite3.connect("database.db", check_same_thread=False)
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM user_data WHERE roll_no = ?", (roll_no,))
    result = cursor.fetchone()
    print("Result from DB to check",result)
    conn.close()
    if not result or result[2] != password:
        return None ,False
    return result, result[2] == password

@socketio.on("login")
def handle_login(data):
    session_id = request.sid
    roll_no = data.get("roll_no").upper()
    password = data.get("password")
    print("Got from frontend",roll_no,password)
    res,flag=check_credentials(roll_no, password)
    print("Result from function call",res,flag)
    if flag:
        socketio.emit("login_response", {"success": True, "roll_no": res[1], "name":res[0]}, room=session_id)
    else:
        socketio.emit("login_response", {"success": False}, room=session_id)


if __name__ == "__main__":
    socketio.run(app, host="0.0.0.0", port=6104, debug=True)