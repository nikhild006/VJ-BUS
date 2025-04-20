import gspread
from oauth2client.service_account import ServiceAccountCredentials

# Define the scope of the application
scope = ["https://spreadsheets.google.com/feeds", "https://www.googleapis.com/auth/drive"]

# Authenticate using the credentials JSON file
creds = ServiceAccountCredentials.from_json_keyfile_name('vj-bus-457010-4f72b43d1ed7.json', scope)
client = gspread.authorize(creds)

# List of routes to be added as headers
routes = [
    "Route-1 (Patancheru)",
    "Route-2 (LB Nagar)",
    "Route-2A (Nagole)",
    "Route-3 (Yusufguda)",
    "Route-4A (ECIL)",
    "Route-4B (ECIL)",
    "Route-5 (Attapur)",
    "Route-6 (VST)",
    "Route-7 (Kukatpally)",
    "Route-8 (Old Alwal)",
    "Route-9 (KPHB via Nizampet)",
    "Route-10 (Manikonda)",
    "Route-11 (HCU)",
    "Route-S-1 (Patancheru)",
    "Route-S-2/1 (LB Nagar)",
    "Route-S-2/2 (LB Nagar)",
    "Route-S-3/1 (Nagole via Begumpet)",
    "Route-S-3/2 (Nagole via taduband)",
    "Route-S-4 (Yusufguda)",
    "Route-S-5 (Attapur)",
    "Route-S-6 (VST)",
    "Route-S-7 (Kukatpally)",
    "Route-S-8 (KPHB via Nizampet)",
    "Route-S-9 (Manikonda)",
    "Route-S-10 (HCU)",
    "Route-41 (ECIL)",
    "Route-42 (ECIL)",
    "Route-43 (ECIL)",
    "Route-44 (ECIL)"
]


# Your Google Spreadsheet ID (replace with your actual ID)
spreadsheet_id = '1ZoedPcfjfP6UN8iyZ4YRnWI-X-5IjBuOPOp8er8_DiU'

# Open the spreadsheet using its ID
spreadsheet = client.open_by_key(spreadsheet_id)

# Select the first sheet (or any other sheet you want)
worksheet = spreadsheet.get_worksheet(0)

# Update the first row with the route headers
worksheet.append_row(routes)

print("Routes have been added as headers!")
