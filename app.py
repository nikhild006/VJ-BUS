from flask import Flask, render_template,jsonify
import sqlite3
app = Flask(__name__)

def get_db_connection():
    # conn = sqlite3.connect("../database.db")
    conn = sqlite3.connect("database.db")
    conn.row_factory = sqlite3.Row
    return conn

# API for fetching logs
@app.route("/get_logs")
def get_logs():
    conn = get_db_connection()
    logs = conn.execute("SELECT * FROM logs").fetchall()
    conn.close()
    return jsonify([dict(row) for row in logs])


@app.route('/')
def home():
    return render_template('index.html')  # Serves index.html
 
@app.route('/driver')
def driver():
    return render_template('driver.html')  # Serves driver.html

@app.route('/admin')
def admin():
    return render_template('admin.html')  # Serves admin.html


@app.route('/chat')
def chat():
    return render_template('chat.html')


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=3104, debug=True)
